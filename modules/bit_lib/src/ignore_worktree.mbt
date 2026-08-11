///| Ignore integration for git worktree operations

///|
/// Check if a relative path is ignored by .gitignore files under root.
pub fn is_ignored_path(
  fs : &@bit.RepoFileSystem,
  root : String,
  rel_path : String,
  is_dir : Bool,
) -> Bool raise @bit.GitError {
  // Always ignore .jj directory (Jujutsu VCS)
  if rel_path == ".jj" || rel_path.has_prefix(".jj/") {
    return true
  }
  let matcher = @ignore.Matcher::new()
  let segments = split_path_segments(rel_path)
  let mut base = ""
  // root .gitignore
  let root_ignore = @bit.join_path(root, ".gitignore")
  if fs.is_file(root_ignore) {
    let content = @utf8.decode_lossy(fs.read_file(root_ignore)[:])
    matcher.add_rules(base, content)
  }
  for i in 0..<segments.length() {
    let seg = segments[i]
    base = if base == "" { seg } else { base + "/" + seg }
    let dir_path = @bit.join_path(root, base)
    if fs.is_dir(dir_path) {
      let ignore_path = @bit.join_path(dir_path, ".gitignore")
      if fs.is_file(ignore_path) {
        let content = @utf8.decode_lossy(fs.read_file(ignore_path)[:])
        matcher.add_rules(base, content)
      }
    }
  }
  matcher.is_ignored(rel_path, is_dir)
}

///|
/// List files under root, excluding ignored paths and .git.
pub fn list_working_files(
  fs : &@bit.RepoFileSystem,
  root : String,
) -> Array[String] raise @bit.GitError {
  let matcher = @ignore.Matcher::new()
  let out : Array[String] = []
  walk_dir(fs, root, "", matcher, out)
  out
}

///|
fn walk_dir(
  fs : &@bit.RepoFileSystem,
  root : String,
  rel : String,
  matcher : @ignore.Matcher,
  out : Array[String],
) -> Unit raise @bit.GitError {
  let dir = if rel == "" { root } else { @bit.join_path(root, rel) }
  // Skip submodules (directories containing .git/.bit file or directory)
  if rel != "" {
    let dot_git_marker = @bit.join_path(dir, ".git")
    let bit_marker = @bit.join_path(dir, ".bit")
    if fs.is_file(dot_git_marker) || fs.is_file(bit_marker) {
      return ()
    }
  }
  // Use native readdir_typed if available to avoid per-entry stat syscalls
  let typed = @bitio.readdir_typed(dir)
  match typed {
    Some(typed_entries) =>
      walk_dir_typed(fs, root, rel, dir, matcher, out, typed_entries)
    None => walk_dir_fallback(fs, root, rel, dir, matcher, out)
  }
}

///|
fn walk_dir_typed(
  fs : &@bit.RepoFileSystem,
  root : String,
  rel : String,
  dir : String,
  matcher : @ignore.Matcher,
  out : Array[String],
  typed_entries : Array[(String, Int)],
) -> Unit raise @bit.GitError {
  let mut has_git = false
  let mut has_gitignore = false
  for entry in typed_entries {
    let name = entry.0
    if name == ".git" || name == ".bit" {
      has_git = true
    }
    if name == ".gitignore" {
      has_gitignore = true
    }
    if has_git && has_gitignore {
      break
    }
  }
  if rel != "" && has_git {
    return ()
  }
  let prev_len = matcher.len()
  if has_gitignore {
    let ignore_path = @bit.join_path(dir, ".gitignore")
    let content = @utf8.decode_lossy(fs.read_file(ignore_path)[:])
    matcher.add_rules(rel, content)
  }
  for entry in typed_entries {
    let name = entry.0
    let d_type = entry.1
    if name == ".git" || name == ".bit" || name == ".jj" {
      continue
    }
    let child_rel = if rel == "" { name } else { rel + "/" + name }
    // d_type: 4=DT_DIR, 8=DT_REG, 10=DT_LNK, 0=DT_UNKNOWN
    let is_dir = if d_type == 4 {
      true
    } else if d_type == 10 {
      // A symlink is a worktree entry even when its target is a directory.
      false
    } else if d_type == 0 {
      // DT_UNKNOWN: fall back to stat
      let child_path = @bit.join_path(root, child_rel)
      @bitio.read_symlink_target_path(child_path) is None &&
      fs.is_dir(child_path)
    } else {
      false
    }
    if matcher.is_ignored(child_rel, is_dir) {
      if is_dir && matcher.has_negation() {
        walk_dir(fs, root, child_rel, matcher, out)
      }
      continue
    }
    if is_dir {
      walk_dir(fs, root, child_rel, matcher, out)
    } else {
      out.push(child_rel)
    }
  }
  matcher.truncate(prev_len)
}

///|
fn walk_dir_fallback(
  fs : &@bit.RepoFileSystem,
  root : String,
  rel : String,
  dir : String,
  matcher : @ignore.Matcher,
  out : Array[String],
) -> Unit raise @bit.GitError {
  let entries = fs.readdir(dir)
  let mut has_git = false
  let mut has_gitignore = false
  for name in entries {
    if name == ".git" || name == ".bit" {
      has_git = true
    }
    if name == ".gitignore" {
      has_gitignore = true
    }
    if has_git && has_gitignore {
      break
    }
  }
  if rel != "" && has_git {
    return ()
  }
  let prev_len = matcher.len()
  if has_gitignore {
    let ignore_path = @bit.join_path(dir, ".gitignore")
    let content = @utf8.decode_lossy(fs.read_file(ignore_path)[:])
    matcher.add_rules(rel, content)
  }
  for name in entries {
    if name == "." ||
      name == ".." ||
      name == ".git" ||
      name == ".bit" ||
      name == ".jj" {
      continue
    }
    let child_rel = if rel == "" { name } else { rel + "/" + name }
    let child_path = @bit.join_path(root, child_rel)
    let is_dir = @bitio.read_symlink_target_path(child_path) is None &&
      fs.is_dir(child_path)
    if matcher.is_ignored(child_rel, is_dir) {
      if is_dir && matcher.has_negation() {
        walk_dir(fs, root, child_rel, matcher, out)
      }
      continue
    }
    if is_dir {
      walk_dir(fs, root, child_rel, matcher, out)
    } else {
      out.push(child_rel)
    }
  }
  matcher.truncate(prev_len)
}

///|
fn split_path_segments(path : String) -> Array[String] {
  let out : Array[String] = []
  if path.length() == 0 {
    return out
  }
  for part_view in path.split("/") {
    let part = part_view.to_owned()
    if part.length() == 0 {
      continue
    }
    out.push(part)
  }
  out
}

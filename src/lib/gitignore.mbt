///| Gitignore integration for git worktree operations

///|
/// Check if a relative path is ignored by .gitignore files under root.
pub fn is_ignored_path(
  fs : &@git.RepoFileSystem,
  root : String,
  rel_path : String,
  is_dir : Bool,
) -> Bool raise @git.GitError {
  // Always ignore .jj directory (Jujutsu VCS)
  if rel_path == ".jj" || rel_path.has_prefix(".jj/") {
    return true
  }
  let matcher = @ignore.Matcher::new()
  let segments = split_path_segments(rel_path)
  let mut base = ""
  // root .gitignore
  let root_ignore = join_path(root, ".gitignore")
  if fs.is_file(root_ignore) {
    let content = @utf8.decode_lossy(fs.read_file(root_ignore)[:])
    matcher.add_rules(base, content)
  }
  for i in 0..<segments.length() {
    let seg = segments[i]
    base = if base == "" { seg } else { base + "/" + seg }
    let dir_path = join_path(root, base)
    if fs.is_dir(dir_path) {
      let ignore_path = join_path(dir_path, ".gitignore")
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
  fs : &@git.RepoFileSystem,
  root : String,
) -> Array[String] raise @git.GitError {
  let matcher = @ignore.Matcher::new()
  let out : Array[String] = []
  walk_dir(fs, root, "", matcher, out)
  out
}

///|
fn walk_dir(
  fs : &@git.RepoFileSystem,
  root : String,
  rel : String,
  matcher : @ignore.Matcher,
  out : Array[String],
) -> Unit raise @git.GitError {
  let dir = if rel == "" { root } else { join_path(root, rel) }
  // Skip submodules (directories containing .git file or directory)
  if rel != "" {
    let git_marker = join_path(dir, ".git")
    if fs.is_file(git_marker) {
      return ()
    }
  }
  let entries = fs.readdir(dir)
  if rel != "" && entries_contains(entries, ".git") {
    return ()
  }
  let prev_len = matcher.len()
  if entries_contains(entries, ".gitignore") {
    let ignore_path = join_path(dir, ".gitignore")
    let content = @utf8.decode_lossy(fs.read_file(ignore_path)[:])
    matcher.add_rules(rel, content)
  }
  for name in entries {
    if name == "." || name == ".." || name == ".git" || name == ".jj" {
      continue
    }
    let child_rel = if rel == "" { name } else { rel + "/" + name }
    let child_path = join_path(root, child_rel)
    let is_dir = fs.is_dir(child_path)
    if matcher.is_ignored(child_rel, is_dir) {
      // Still traverse to allow negations in nested .gitignore
      if is_dir {
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
fn entries_contains(entries : Array[String], name : String) -> Bool {
  for item in entries {
    if item == name {
      return true
    }
  }
  false
}

///|
fn split_path_segments(path : String) -> Array[String] {
  let out : Array[String] = []
  if path.length() == 0 {
    return out
  }
  for part_view in path.split("/") {
    let part = part_view.to_string()
    if part.length() == 0 {
      continue
    }
    out.push(part)
  }
  out
}

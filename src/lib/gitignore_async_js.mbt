///| Gitignore integration for git worktree operations (async, js/wasm)

///|
/// List files under root, excluding ignored paths and .git.
pub async fn list_working_files_async(
  fs : &@git.RepoFileSystem,
  root : String,
) -> Array[String] raise @git.GitError {
  ignore(try? @async.with_timeout_opt(0, async fn() { () }))
  let matcher = @ignore.Matcher::new()
  let out : Array[String] = []
  walk_dir_async(fs, root, "", matcher, out)
  out
}

///|
pub async fn working_files_cache(root : String) -> Array[String]? noraise {
  ignore(try? @async.with_timeout_opt(0, async fn() { () }))
  ignore(root)
  None
}

///|
fn walk_dir_async(
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
        walk_dir_async(fs, root, child_rel, matcher, out)
      }
      continue
    }
    if is_dir {
      walk_dir_async(fs, root, child_rel, matcher, out)
    } else {
      out.push(child_rel)
    }
  }
  matcher.truncate(prev_len)
}

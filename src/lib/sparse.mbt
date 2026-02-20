///| Sparse checkout implementation

///|
/// Check if sparse checkout is enabled.
pub fn is_sparse_checkout_enabled(
  rfs : &@bit.RepoFileSystem,
  git_dir : String,
) -> Bool {
  let config_path = join_path(git_dir, "config")
  if not(rfs.is_file(config_path)) {
    return false
  }
  let content = @utf8.decode_lossy(
    (rfs.read_file(config_path) catch { _ => return false })[:],
  )
  let mut in_core = false
  for line_view in content.split("\n") {
    let line = line_view.to_string()
    let trimmed = sparse_trim(line)
    if trimmed == "[core]" {
      in_core = true
      continue
    }
    if trimmed.has_prefix("[") {
      in_core = false
      continue
    }
    if in_core && trimmed.has_prefix("sparseCheckout") {
      if trimmed.contains("true") || trimmed.contains("= true") {
        return true
      }
    }
  }
  false
}

///|
/// Read sparse checkout patterns from .git/info/sparse-checkout.
pub fn read_sparse_patterns(
  rfs : &@bit.RepoFileSystem,
  git_dir : String,
) -> Array[String] raise @bit.GitError {
  let sparse_path = join_path(git_dir, "info/sparse-checkout")
  if not(rfs.is_file(sparse_path)) {
    return []
  }
  let content = rfs.read_file(sparse_path)
  let text = @utf8.decode_lossy(content[:])
  let patterns : Array[String] = []
  for line_view in text.split("\n") {
    let line = sparse_trim(line_view.to_string())
    if line.length() > 0 && not(line.has_prefix("#")) {
      patterns.push(line)
    }
  }
  patterns
}

///|
/// Write sparse checkout patterns to .git/info/sparse-checkout.
pub fn write_sparse_patterns(
  fs : &@bit.FileSystem,
  git_dir : String,
  patterns : Array[String],
) -> Unit raise @bit.GitError {
  let info_dir = join_path(git_dir, "info")
  fs.mkdir_p(info_dir)
  let sparse_path = join_path(git_dir, "info/sparse-checkout")
  let content = patterns
    .iter()
    .fold(init="", fn(acc, p) {
      if acc.length() == 0 {
        p + "\n"
      } else {
        acc + p + "\n"
      }
    })
  fs.write_string(sparse_path, content)
}

///|
/// Initialize sparse checkout.
pub fn sparse_checkout_init(
  fs : &@bit.FileSystem,
  rfs : &@bit.RepoFileSystem,
  root : String,
  cone? : Bool = false,
) -> Unit raise @bit.GitError {
  let git_dir = join_path(root, ".git")
  // Enable sparse checkout in config
  let config_path = join_path(git_dir, "config")
  let mut config = if rfs.is_file(config_path) {
    @utf8.decode_lossy(rfs.read_file(config_path)[:])
  } else {
    "[core]\n"
  }
  // Add sparseCheckout = true if not present
  if not(config.contains("sparseCheckout")) {
    // Find [core] section and add to it
    if config.contains("[core]") {
      config = config.replace(
        old="[core]",
        new="[core]\n\tsparseCheckout = true",
      )
    } else {
      config = config + "[core]\n\tsparseCheckout = true\n"
    }
  }
  // Add cone mode if requested
  if cone && not(config.contains("sparseCheckoutCone")) {
    if config.contains("[core]") {
      config = config.replace(
        old="sparseCheckout = true",
        new="sparseCheckout = true\n\tsparseCheckoutCone = true",
      )
    }
  }
  fs.write_string(config_path, config)
  // Create initial sparse-checkout file with just root
  fs.mkdir_p(join_path(git_dir, "info"))
  let sparse_path = join_path(git_dir, "info/sparse-checkout")
  if not(rfs.is_file(sparse_path)) {
    fs.write_string(sparse_path, "/*\n!/*/\n")
  }
}

///|
/// Set sparse checkout patterns (replaces existing patterns).
pub fn sparse_checkout_set(
  fs : &@bit.FileSystem,
  rfs : &@bit.RepoFileSystem,
  root : String,
  patterns : Array[String],
) -> Unit raise @bit.GitError {
  let git_dir = join_path(root, ".git")
  // Ensure sparse checkout is initialized
  if not(is_sparse_checkout_enabled(rfs, git_dir)) {
    sparse_checkout_init(fs, rfs, root)
  }
  write_sparse_patterns(fs, git_dir, patterns)
  // Update worktree
  sparse_update_worktree(fs, rfs, root)
}

///|
/// Add patterns to sparse checkout.
pub fn sparse_checkout_add(
  fs : &@bit.FileSystem,
  rfs : &@bit.RepoFileSystem,
  root : String,
  new_patterns : Array[String],
) -> Unit raise @bit.GitError {
  let git_dir = join_path(root, ".git")
  // Ensure sparse checkout is initialized
  if not(is_sparse_checkout_enabled(rfs, git_dir)) {
    sparse_checkout_init(fs, rfs, root)
  }
  let existing = read_sparse_patterns(rfs, git_dir)
  for p in new_patterns {
    if not(existing.contains(p)) {
      existing.push(p)
    }
  }
  write_sparse_patterns(fs, git_dir, existing)
  // Update worktree
  sparse_update_worktree(fs, rfs, root)
}

///|
/// Disable sparse checkout.
pub fn sparse_checkout_disable(
  fs : &@bit.FileSystem,
  rfs : &@bit.RepoFileSystem,
  root : String,
) -> Unit raise @bit.GitError {
  let git_dir = join_path(root, ".git")
  // Update config to disable
  let config_path = join_path(git_dir, "config")
  if rfs.is_file(config_path) {
    let config = @utf8.decode_lossy(rfs.read_file(config_path)[:])
    let new_config = config
      .replace(old="sparseCheckout = true", new="sparseCheckout = false")
      .replace(
        old="sparseCheckoutCone = true",
        new="sparseCheckoutCone = false",
      )
    fs.write_string(config_path, new_config)
  }
  // Checkout all files
  let head = resolve_head_commit(rfs, git_dir)
  match head {
    None => ()
    Some(commit_id) => {
      let db = ObjectDb::load(rfs, git_dir)
      let files = collect_tree_files_from_commit(db, rfs, commit_id)
      write_worktree_from_files(db, fs, rfs, root, git_dir, files)
      let entries = tree_files_to_index(db, rfs, files)
      write_index_entries(fs, git_dir, entries)
    }
  }
}

///|
/// Check if a path matches any of the sparse checkout patterns.
pub fn matches_sparse_pattern(path : String, patterns : Array[String]) -> Bool {
  if patterns.length() == 0 {
    return true // No patterns means include everything
  }
  let mut included = false
  for pattern in patterns {
    if pattern.has_prefix("!") {
      // Negation pattern
      let neg_pattern = String::unsafe_substring(
        pattern,
        start=1,
        end=pattern.length(),
      )
      if sparse_path_matches(path, neg_pattern) {
        included = false
      }
    } else if sparse_path_matches(path, pattern) {
      included = true
    }
  }
  included
}

///|
/// Simple glob-like pattern matching for sparse checkout.
fn sparse_path_matches(path : String, pattern : String) -> Bool {
  let normalized_pattern = if pattern.has_prefix("/") &&
    pattern != "/*" &&
    pattern != "!/*/" {
    String::unsafe_substring(pattern, start=1, end=pattern.length())
  } else {
    pattern
  }
  // Handle common patterns:
  // "/*" - match all files in root
  // "!/*/  " - exclude all directories in root
  // "dir/" - match directory and contents
  // "dir/*" - match files in directory
  // "*.txt" - match files ending in .txt
  if normalized_pattern == "/*" {
    // Match files in root (no slash in path)
    return not(path.contains("/"))
  }
  if normalized_pattern == "!/*/" {
    // This is handled by negation in matches_sparse_pattern
    return path.contains("/")
  }
  if normalized_pattern.has_suffix("/") {
    // Directory pattern - match if path starts with this directory
    let dir = String::unsafe_substring(
      normalized_pattern,
      start=0,
      end=normalized_pattern.length() - 1,
    )
    return path == dir || path.has_prefix(dir + "/")
  }
  if normalized_pattern.has_suffix("/*") {
    // Match files directly in directory
    let dir = String::unsafe_substring(
      normalized_pattern,
      start=0,
      end=normalized_pattern.length() - 2,
    )
    if path.has_prefix(dir + "/") {
      let rest = String::unsafe_substring(
        path,
        start=dir.length() + 1,
        end=path.length(),
      )
      return not(rest.contains("/"))
    }
    return false
  }
  if normalized_pattern.has_prefix("*") {
    // Wildcard at start
    let suffix = String::unsafe_substring(
      normalized_pattern,
      start=1,
      end=normalized_pattern.length(),
    )
    return path.has_suffix(suffix)
  }
  if normalized_pattern.has_suffix("*") {
    // Wildcard at end
    let prefix = String::unsafe_substring(
      normalized_pattern,
      start=0,
      end=normalized_pattern.length() - 1,
    )
    return path.has_prefix(prefix)
  }
  if normalized_pattern.contains("**") {
    // Double star matches any path
    let parts = normalized_pattern.split("**")
    let parts_arr : Array[String] = []
    for p in parts {
      parts_arr.push(p.to_string())
    }
    if parts_arr.length() == 2 {
      let prefix = parts_arr[0]
      let suffix = parts_arr[1]
      return (prefix.length() == 0 || path.has_prefix(prefix)) &&
        (suffix.length() == 0 || path.has_suffix(suffix))
    }
  }
  // Exact match or path prefix
  path == normalized_pattern || path.has_prefix(normalized_pattern + "/")
}

///|
/// Update worktree based on sparse checkout patterns.
fn sparse_update_worktree(
  fs : &@bit.FileSystem,
  rfs : &@bit.RepoFileSystem,
  root : String,
) -> Unit raise @bit.GitError {
  let git_dir = join_path(root, ".git")
  let patterns = read_sparse_patterns(rfs, git_dir)
  let head = resolve_head_commit(rfs, git_dir)
  match head {
    None => ()
    Some(commit_id) => {
      let db = ObjectDb::load(rfs, git_dir)
      let all_files = collect_tree_files_from_commit(db, rfs, commit_id)
      // Filter files based on sparse patterns
      let sparse_files : Map[String, TreeFileEntry] = {}
      let skip_paths : Array[String] = []
      for item in all_files.to_array() {
        let (path, entry) = item
        if matches_sparse_pattern(path, patterns) {
          sparse_files[path] = entry
        } else {
          skip_paths.push(path)
        }
      }
      // Remove files not in sparse set
      for item in all_files.to_array() {
        let (path, _) = item
        if not(matches_sparse_pattern(path, patterns)) {
          let file_path = join_path(root, path)
          if rfs.is_file(file_path) {
            fs.remove_file(file_path)
          }
        }
      }
      // Write sparse files
      write_worktree_from_files(db, fs, rfs, root, git_dir, sparse_files)
      write_skip_worktree_paths(fs, git_dir, skip_paths)
      // Update index with sparse skip-worktree entries.
      let skip_set : Map[String, Bool] = {}
      for path in skip_paths {
        skip_set[path] = true
      }
      let all_entries = tree_files_to_index(db, rfs, all_files)
      write_index_entries_with_skip_worktree(fs, git_dir, all_entries, skip_set)
    }
  }
}

///|
fn sparse_trim(s : String) -> String {
  let mut start = 0
  let mut end = s.length()
  while start < end {
    let c = s.unsafe_get(start)
    if c == ' ' || c == '\t' || c == '\n' || c == '\r' {
      start += 1
    } else {
      break
    }
  }
  while end > start {
    let c = s.unsafe_get(end - 1)
    if c == ' ' || c == '\t' || c == '\n' || c == '\r' {
      end -= 1
    } else {
      break
    }
  }
  if start == 0 && end == s.length() {
    s
  } else {
    String::unsafe_substring(s, start~, end~)
  }
}

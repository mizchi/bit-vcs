///| Git worktree administration (git worktree list/add/remove/prune)

///|
/// Information about a worktree.
pub(all) struct WorktreeInfo {
  /// Absolute path to the worktree directory
  path : String
  /// Current HEAD commit id
  head_id : @bit.ObjectId?
  /// Branch name if HEAD points to a branch, None if detached
  branch : String?
  /// True if the worktree is locked
  locked : Bool
  /// True if this is the main worktree (contains .git directory)
  is_main : Bool
  /// True if this entry represents a bare main repository
  is_bare : Bool
}

///|
/// List all worktrees in a repository.
/// Returns the main worktree first, followed by linked worktrees.
pub fn list_worktrees(
  fs : &@bit.RepoFileSystem,
  root : String,
) -> Array[WorktreeInfo] raise @bit.GitError {
  let result : Array[WorktreeInfo] = []
  let linked : Array[WorktreeInfo] = []
  let git_dir = resolve_git_dir(fs, root)
  let main_root = resolve_main_worktree_root(git_dir)
  let main_info = get_main_worktree_info(fs, main_root, git_dir)
  result.push(main_info)
  // Scan .git/worktrees/ for linked worktrees
  let worktrees_dir = join_path(git_dir, "worktrees")
  if !fs.is_dir(worktrees_dir) {
    return result
  }
  let entries = fs.readdir(worktrees_dir)
  for entry in entries {
    if entry == "." || entry == ".." {
      continue
    }
    let admin_dir = join_path(worktrees_dir, entry)
    if !fs.is_dir(admin_dir) {
      continue
    }
    match get_linked_worktree_info(fs, admin_dir) {
      Some(info) => linked.push(info)
      None => continue
    }
  }
  linked.sort_by(fn(a, b) { String::lexical_compare(a.path, b.path) })
  for info in linked {
    result.push(info)
  }
  result
}

///|
fn resolve_main_worktree_root(git_dir : String) -> String {
  if basename(git_dir) == ".git" {
    normalize_path(parent_dir(git_dir))
  } else {
    normalize_path(git_dir)
  }
}

///|
/// Check if a branch is checked out in any worktree.
/// Returns the worktree path if the branch is in use, None otherwise.
pub fn is_branch_checked_out(
  fs : &@bit.RepoFileSystem,
  root : String,
  branch : String,
) -> String? raise @bit.GitError {
  let worktrees = list_worktrees(fs, root)
  for wt in worktrees {
    match wt.branch {
      Some(b) => if b == branch { return Some(wt.path) }
      None => continue
    }
  }
  None
}

///|
/// Check if a branch is checked out in a worktree other than `root` (e.g.
/// after `git worktree add -f` lets two worktrees share one branch, and the
/// current worktree happens to be one of them). Returns the other
/// worktree's path if found, None otherwise.
pub fn is_branch_checked_out_elsewhere(
  fs : &@bit.RepoFileSystem,
  root : String,
  branch : String,
) -> String? raise @bit.GitError {
  let normalized_root = normalize_path(root)
  let worktrees = list_worktrees(fs, root)
  for wt in worktrees {
    match wt.branch {
      Some(b) =>
        if b == branch && normalize_path(wt.path) != normalized_root {
          return Some(wt.path)
        }
      None => continue
    }
  }
  None
}

///|
/// Create a new linked worktree.
pub fn create_worktree(
  fs : &@bit.FileSystem,
  rfs : &@bit.RepoFileSystem,
  root : String,
  worktree_path : String,
  commit_ish : String?,
  detach? : Bool = false,
  force? : Bool = false,
  new_branch~ : String?,
  relative_paths? : Bool? = None,
  orphan? : Bool = false,
) -> Unit raise @bit.GitError {
  let git_dir = resolve_git_dir(rfs, root)
  let common_git_dir = resolve_commondir(rfs, git_dir)
  // Resolve the absolute worktree path
  let abs_wt_path = if worktree_path.has_prefix("/") {
    worktree_path
  } else {
    join_path(root, worktree_path)
  }
  // Check worktree path doesn't already exist as a file
  if rfs.is_file(abs_wt_path) {
    raise @bit.GitError::InvalidObject(
      "'\{worktree_path}' already exists as a file",
    )
  }
  if rfs.is_dir(abs_wt_path) && worktree_dir_has_entries(rfs, abs_wt_path) {
    raise @bit.GitError::InvalidObject("'\{worktree_path}' already exists")
  }
  // Determine the worktree name (basename of path)
  let wt_name = resolve_worktree_admin_name(rfs, git_dir, abs_wt_path)
  // Check if admin directory already exists
  let worktrees_dir = join_path(common_git_dir, "worktrees")
  let admin_dir = join_path(worktrees_dir, wt_name)
  // Determine branch and commit
  let (branch, commit_id) = resolve_worktree_target(
    fs, rfs, root, git_dir, commit_ish, detach, new_branch, orphan,
  )
  // Check branch is not already checked out
  match branch {
    Some(b) => {
      if orphan &&
        resolve_ref(rfs, common_git_dir, "refs/heads/" + b) is Some(_) {
        raise @bit.GitError::InvalidObject(
          "a branch named '\{b}' already exists",
        )
      }
      if !force {
        match is_branch_checked_out(rfs, root, b) {
          Some(path) =>
            raise @bit.GitError::InvalidObject(
              "'\{b}' is already checked out at '\{path}'",
            )
          None => ()
        }
      }
    }
    None => ()
  }
  let use_relative_paths = relative_paths.unwrap_or(
    worktree_use_relative_paths_enabled(rfs, common_git_dir),
  )
  if use_relative_paths {
    worktree_enable_relative_paths(fs, rfs, common_git_dir)
  }
  // Create admin directory
  fs.mkdir_p(admin_dir)
  // Write gitdir file (points to worktree's .git file)
  let gitdir_path = join_path(admin_dir, "gitdir")
  let wt_git_file = join_path(abs_wt_path, ".git")
  if use_relative_paths {
    fs.write_string(
      gitdir_path,
      worktree_compute_relative_path(admin_dir, wt_git_file) + "\n",
    )
  } else {
    fs.write_string(gitdir_path, wt_git_file + "\n")
  }
  // Write HEAD file
  let head_path = join_path(admin_dir, "HEAD")
  match branch {
    Some(b) => fs.write_string(head_path, "ref: refs/heads/" + b + "\n")
    None =>
      match commit_id {
        Some(id) => fs.write_string(head_path, id.to_hex() + "\n")
        None =>
          raise @bit.GitError::InvalidObject(
            "No commit to create worktree from",
          )
      }
  }
  // Write commondir file
  let commondir_path = join_path(admin_dir, "commondir")
  fs.write_string(commondir_path, "../..\n")
  copy_worktree_config(fs, rfs, git_dir, admin_dir)
  // Create worktree directory
  fs.mkdir_p(abs_wt_path)
  // Create .git file in worktree
  if use_relative_paths {
    fs.write_string(
      wt_git_file,
      "gitdir: " + worktree_compute_relative_path(abs_wt_path, admin_dir) + "\n",
    )
  } else {
    fs.write_string(wt_git_file, "gitdir: " + admin_dir + "\n")
  }
  match commit_id {
    Some(id) => {
      let (should_log_head, _) = should_log_ref(rfs, admin_dir, "HEAD", false)
      if should_log_head {
        append_reflog(
          fs,
          rfs,
          admin_dir,
          "HEAD",
          @bit.ObjectId::zero(),
          id,
          "unknown",
          "unknown",
          0L,
          "+0000",
          "worktree add",
        )
      }
    }
    None => ()
  }
  // Checkout files to worktree
  match commit_id {
    Some(id) =>
      checkout_to_worktree(fs, rfs, git_dir, abs_wt_path, admin_dir, id)
    None => ()
  }
}

///|
/// Remove a linked worktree.
pub fn remove_worktree(
  fs : &@bit.FileSystem,
  rfs : &@bit.RepoFileSystem,
  root : String,
  worktree_path : String,
  force? : Bool = false,
  force_level? : Int = 0,
) -> Unit raise @bit.GitError {
  let git_dir = resolve_git_dir(rfs, root)
  let effective_force_level = worktree_effective_force_level(force, force_level)
  // Resolve the absolute worktree path
  let abs_wt_path = if worktree_path.has_prefix("/") {
    worktree_path
  } else {
    normalize_path(join_path(root, worktree_path))
  }
  // Find the admin directory for this worktree
  let admin_dir = find_worktree_admin_dir(rfs, git_dir, abs_wt_path)
  guard admin_dir is Some(admin) else {
    raise @bit.GitError::InvalidObject(
      worktree_not_found_message(worktree_path),
    )
  }
  // Check if locked
  let locked_path = join_path(admin, "locked")
  if rfs.is_file(locked_path) && effective_force_level < 2 {
    raise @bit.GitError::InvalidObject(
      "'\{worktree_path}' is locked; use --force to remove anyway",
    )
  }
  // Remove worktree directory if it exists
  if rfs.is_dir(abs_wt_path) {
    if worktree_contains_nested_git(rfs, abs_wt_path) {
      raise @bit.GitError::InvalidObject(
        "'\{worktree_path}' contains initialized submodules",
      )
    }
    if effective_force_level == 0 &&
      worktree_has_local_changes(rfs, abs_wt_path, admin) {
      raise @bit.GitError::InvalidObject(
        "'\{worktree_path}' contains modified or untracked files; use --force to delete it",
      )
    }
    remove_dir_recursive(fs, rfs, abs_wt_path)
  }
  // Remove admin directory
  remove_dir_recursive(fs, rfs, admin)
  prune_cleanup_worktrees_dir(fs, rfs, join_path(git_dir, "worktrees"), false)
}

///|
/// Prune worktrees with invalid gitdir references.
/// Returns list of pruned admin directory names.
pub fn prune_worktrees(
  fs : &@bit.FileSystem,
  rfs : &@bit.RepoFileSystem,
  root : String,
  dry_run? : Bool = false,
) -> Array[String] raise @bit.GitError {
  let detailed = prune_worktrees_detailed(fs, rfs, root, dry_run~)
  let pruned : Array[String] = []
  for entry in detailed {
    pruned.push(entry.name)
  }
  pruned
}

///|
pub(all) struct PrunedWorktreeEntry {
  name : String
  reason : String
}

///|
pub fn prune_worktrees_detailed(
  fs : &@bit.FileSystem,
  rfs : &@bit.RepoFileSystem,
  root : String,
  dry_run? : Bool = false,
  expire_before_sec? : Int64? = None,
) -> Array[PrunedWorktreeEntry] raise @bit.GitError {
  let git_dir = resolve_git_dir(rfs, root)
  let worktrees_dir = join_path(git_dir, "worktrees")
  let pruned : Array[PrunedWorktreeEntry] = []
  if !rfs.is_dir(worktrees_dir) {
    return pruned
  }
  let seen_worktree_roots : Map[String, Bool] = Map([])
  seen_worktree_roots[resolve_main_worktree_root(git_dir)] = true
  let entries = rfs.readdir(worktrees_dir)
  entries.sort_by(fn(a, b) { String::lexical_compare(a, b) })
  for entry in entries {
    if entry == "." || entry == ".." {
      continue
    }
    let admin_dir = join_path(worktrees_dir, entry)
    if !rfs.is_dir(admin_dir) {
      prune_record(
        fs, rfs, worktrees_dir, admin_dir, entry, "not a valid directory", pruned,
        dry_run,
      )
      continue
    }
    if rfs.is_file(join_path(admin_dir, "locked")) {
      continue
    }
    if prune_admin_dir_is_recent(admin_dir, expire_before_sec~) {
      continue
    }
    let gitdir_path = join_path(admin_dir, "gitdir")
    if !rfs.is_file(gitdir_path) {
      prune_record(
        fs, rfs, worktrees_dir, admin_dir, entry, "gitdir file does not exist", pruned,
        dry_run,
      )
      continue
    }
    let gitdir_content = read_trimmed_file(rfs, gitdir_path) catch {
      _ => {
        prune_record(
          fs, rfs, worktrees_dir, admin_dir, entry, "unable to read gitdir file",
          pruned, dry_run,
        )
        continue
      }
    }
    if gitdir_content.length() == 0 {
      prune_record(
        fs, rfs, worktrees_dir, admin_dir, entry, "invalid gitdir file", pruned,
        dry_run,
      )
      continue
    }
    let resolved_gitdir = prune_resolve_gitdir_path(admin_dir, gitdir_content)
    if resolved_gitdir.length() == 0 {
      prune_record(
        fs, rfs, worktrees_dir, admin_dir, entry, "invalid gitdir file", pruned,
        dry_run,
      )
      continue
    }
    if !rfs.is_file(resolved_gitdir) && !rfs.is_dir(resolved_gitdir) {
      prune_record(
        fs, rfs, worktrees_dir, admin_dir, entry, "gitdir file points to non-existent location",
        pruned, dry_run,
      )
      continue
    }
    let wt_root = normalize_path(parent_dir(resolved_gitdir))
    if seen_worktree_roots.contains(wt_root) {
      prune_record(
        fs, rfs, worktrees_dir, admin_dir, entry, "duplicate entry", pruned, dry_run,
      )
      continue
    }
    seen_worktree_roots[wt_root] = true
  }
  prune_cleanup_worktrees_dir(fs, rfs, worktrees_dir, dry_run)
  pruned
}

///|
fn prune_record(
  fs : &@bit.FileSystem,
  rfs : &@bit.RepoFileSystem,
  worktrees_dir : String,
  admin_path : String,
  entry : String,
  reason : String,
  pruned : Array[PrunedWorktreeEntry],
  dry_run : Bool,
) -> Unit raise @bit.GitError {
  if !dry_run {
    if rfs.is_dir(admin_path) {
      remove_dir_recursive(fs, rfs, admin_path)
    } else if rfs.is_file(admin_path) {
      fs.remove_file(admin_path)
    }
  }
  ignore(worktrees_dir)
  pruned.push({ name: entry, reason })
}

///|
fn prune_cleanup_worktrees_dir(
  fs : &@bit.FileSystem,
  rfs : &@bit.RepoFileSystem,
  worktrees_dir : String,
  dry_run : Bool,
) -> Unit raise @bit.GitError {
  if dry_run || !rfs.is_dir(worktrees_dir) {
    return
  }
  let mut has_entries = false
  for entry in rfs.readdir(worktrees_dir) {
    if entry != "." && entry != ".." {
      has_entries = true
      break
    }
  }
  if !has_entries {
    fs.remove_dir(worktrees_dir) catch {
      _ => ()
    }
  }
}

///|
fn prune_resolve_gitdir_path(
  admin_dir : String,
  gitdir_content : String,
) -> String {
  if gitdir_content.length() == 0 {
    return ""
  }
  if gitdir_content.has_prefix("/") {
    normalize_path(gitdir_content)
  } else {
    normalize_path(join_path(admin_dir, gitdir_content))
  }
}

///|
fn prune_admin_dir_is_recent(
  admin_dir : String,
  expire_before_sec? : Int64? = None,
) -> Bool {
  match expire_before_sec {
    Some(limit) => {
      let candidates = [
        admin_dir,
        join_path(admin_dir, "gitdir"),
        join_path(admin_dir, "HEAD"),
        join_path(admin_dir, "commondir"),
        join_path(admin_dir, "locked"),
      ]
      for path in candidates {
        match @bitio.lstat_entry_meta(path) {
          Some(meta) if meta.mtime_sec.unwrap_or(0).to_int64() > limit =>
            return true
          _ => ()
        }
      }
      false
    }
    None => false
  }
}

///|
/// Lock a worktree to prevent it from being pruned.
pub fn lock_worktree(
  fs : &@bit.FileSystem,
  rfs : &@bit.RepoFileSystem,
  root : String,
  worktree_path : String,
  reason~ : String?,
) -> Unit raise @bit.GitError {
  let git_dir = resolve_git_dir(rfs, root)
  // Resolve absolute path
  let abs_wt_path = if worktree_path.has_prefix("/") {
    worktree_path
  } else {
    normalize_path(join_path(root, worktree_path))
  }
  // Find admin directory
  let admin_dir = find_worktree_admin_dir(rfs, git_dir, abs_wt_path)
  guard admin_dir is Some(admin) else {
    raise @bit.GitError::InvalidObject(
      worktree_not_found_message(worktree_path),
    )
  }
  // Check if already locked
  let locked_path = join_path(admin, "locked")
  if rfs.is_file(locked_path) {
    raise @bit.GitError::InvalidObject("'\{worktree_path}' is already locked")
  }
  // Write lock file
  let content = reason.map(value => value + "\n").unwrap_or("")
  fs.write_string(locked_path, content)
}

///|
/// Unlock a worktree.
pub fn unlock_worktree(
  fs : &@bit.FileSystem,
  rfs : &@bit.RepoFileSystem,
  root : String,
  worktree_path : String,
) -> Unit raise @bit.GitError {
  let git_dir = resolve_git_dir(rfs, root)
  // Resolve absolute path
  let abs_wt_path = if worktree_path.has_prefix("/") {
    worktree_path
  } else {
    normalize_path(join_path(root, worktree_path))
  }
  // Find admin directory
  let admin_dir = find_worktree_admin_dir(rfs, git_dir, abs_wt_path)
  guard admin_dir is Some(admin) else {
    raise @bit.GitError::InvalidObject(
      worktree_not_found_message(worktree_path),
    )
  }
  // Check if locked
  let locked_path = join_path(admin, "locked")
  if !rfs.is_file(locked_path) {
    raise @bit.GitError::InvalidObject("'\{worktree_path}' is not locked")
  }
  // Remove lock file
  fs.remove_file(locked_path)
}

///|
/// Get lock reason for a worktree.
pub fn get_worktree_lock_reason(
  rfs : &@bit.RepoFileSystem,
  root : String,
  worktree_path : String,
) -> String? raise @bit.GitError {
  let git_dir = resolve_git_dir(rfs, root)
  let abs_wt_path = if worktree_path.has_prefix("/") {
    worktree_path
  } else {
    normalize_path(join_path(root, worktree_path))
  }
  let admin_dir = find_worktree_admin_dir(rfs, git_dir, abs_wt_path)
  guard admin_dir is Some(admin) else { return None }
  let locked_path = join_path(admin, "locked")
  if !rfs.is_file(locked_path) {
    return None
  }
  let content = read_trimmed_file(rfs, locked_path)
  if content.length() == 0 {
    Some("")
  } else {
    Some(content)
  }
}

///|
/// Move a worktree to a new location.
pub fn move_worktree(
  fs : &@bit.FileSystem,
  rfs : &@bit.RepoFileSystem,
  root : String,
  source_path : String,
  dest_path : String,
  force? : Bool = false,
  force_level? : Int = 0,
  relative_paths? : Bool? = None,
) -> Unit raise @bit.GitError {
  let git_dir = resolve_git_dir(rfs, root)
  let effective_force_level = worktree_effective_force_level(force, force_level)
  // Resolve absolute paths
  let abs_src = if source_path.has_prefix("/") {
    source_path
  } else {
    normalize_path(join_path(root, source_path))
  }
  let requested_abs_dst = if dest_path.has_prefix("/") {
    dest_path
  } else {
    normalize_path(join_path(root, dest_path))
  }
  let abs_dst = if rfs.is_dir(requested_abs_dst) {
    normalize_path(join_path(requested_abs_dst, basename(abs_src)))
  } else {
    requested_abs_dst
  }
  // Find admin directory
  let admin_dir = find_worktree_admin_dir(rfs, git_dir, abs_src)
  guard admin_dir is Some(admin) else {
    raise @bit.GitError::InvalidObject(worktree_not_found_message(source_path))
  }
  // Check if locked (unless force)
  let locked_path = join_path(admin, "locked")
  if rfs.is_file(locked_path) && effective_force_level < 2 {
    raise @bit.GitError::InvalidObject(
      "'\{source_path}' is locked; use --force to move anyway",
    )
  }
  if worktree_contains_nested_git(rfs, abs_src) {
    raise @bit.GitError::InvalidObject(
      "'\{source_path}' contains initialized submodules",
    )
  }
  match find_worktree_admin_dir(rfs, git_dir, abs_dst) {
    Some(existing_admin) => {
      let dest_locked = rfs.is_file(join_path(existing_admin, "locked"))
      let required_force = if dest_locked { 2 } else { 1 }
      if effective_force_level < required_force {
        if dest_locked {
          raise @bit.GitError::InvalidObject(
            "'\{dest_path}' is locked; use --force to move anyway",
          )
        }
        raise @bit.GitError::InvalidObject("'\{dest_path}' already exists")
      }
      remove_dir_recursive(fs, rfs, existing_admin)
      prune_cleanup_worktrees_dir(
        fs,
        rfs,
        join_path(git_dir, "worktrees"),
        false,
      )
    }
    None => ()
  }
  // Check destination doesn't exist
  if rfs.is_dir(abs_dst) || rfs.is_file(abs_dst) {
    raise @bit.GitError::InvalidObject("'\{dest_path}' already exists")
  }
  // Update gitdir file to point to new location
  let gitdir_path = join_path(admin, "gitdir")
  let new_git_file = join_path(abs_dst, ".git")
  let use_relative_paths = relative_paths.unwrap_or(
    worktree_use_relative_paths_enabled(rfs, git_dir),
  )
  if use_relative_paths {
    fs.write_string(
      gitdir_path,
      worktree_compute_relative_path(admin, new_git_file) + "\n",
    )
  } else {
    fs.write_string(gitdir_path, new_git_file + "\n")
  }
  // Move the worktree directory (by copying and removing)
  copy_dir_recursive_wt(fs, rfs, abs_src, abs_dst)
  remove_dir_recursive(fs, rfs, abs_src)
  // Update .git file in new location
  if use_relative_paths {
    fs.write_string(
      new_git_file,
      "gitdir: " + worktree_compute_relative_path(abs_dst, admin) + "\n",
    )
  } else {
    fs.write_string(new_git_file, "gitdir: " + admin + "\n")
  }
}

///|
fn copy_dir_recursive_wt(
  fs : &@bit.FileSystem,
  rfs : &@bit.RepoFileSystem,
  src : String,
  dst : String,
) -> Unit raise @bit.GitError {
  fs.mkdir_p(dst)
  let entries = rfs.readdir(src)
  for entry in entries {
    if entry == "." || entry == ".." {
      continue
    }
    let src_path = join_path(src, entry)
    let dst_path = join_path(dst, entry)
    if rfs.is_dir(src_path) {
      copy_dir_recursive_wt(fs, rfs, src_path, dst_path)
    } else if rfs.is_file(src_path) {
      let content = rfs.read_file(src_path)
      fs.write_file(dst_path, content)
    }
  }
}

///|
pub(all) struct WorktreeRepairResult {
  repaired : Array[String]
  warnings : Array[String]
} derive(Eq, Debug)

///|
fn worktree_repair_resolve_requested_path(
  root : String,
  path : String,
) -> String {
  if path.has_prefix("/") {
    normalize_path(path)
  } else {
    normalize_path(join_path(root, path))
  }
}

///|
fn worktree_repair_gitfile_target(
  fs : &@bit.RepoFileSystem,
  worktree_path : String,
) -> String? raise @bit.GitError {
  let git_file = join_path(worktree_path, ".git")
  if !fs.is_file(git_file) {
    return None
  }
  let content = read_trimmed_file(fs, git_file)
  if !content.has_prefix("gitdir: ") {
    return None
  }
  let raw = String::unsafe_substring(content, start=8, end=content.length())
  Some(
    if raw.has_prefix("/") {
      normalize_path(raw)
    } else {
      normalize_path(join_path(worktree_path, raw))
    },
  )
}

///|
fn worktree_repair_target_is_repository(
  fs : &@bit.RepoFileSystem,
  target : String,
) -> Bool {
  if !fs.is_dir(target) {
    return false
  }
  if !fs.is_file(join_path(target, "HEAD")) {
    return false
  }
  let common = resolve_commondir(fs, target) catch { _ => target }
  fs.is_dir(join_path(common, "objects"))
}

///|
fn worktree_repair_target_exists(
  fs : &@bit.RepoFileSystem,
  target : String,
) -> Bool {
  fs.is_dir(target) || fs.is_file(target)
}

///|
fn worktree_repair_find_admin_dir(
  fs : &@bit.RepoFileSystem,
  git_dir : String,
  worktree_path : String,
) -> String? raise @bit.GitError {
  match find_worktree_admin_dir(fs, git_dir, worktree_path) {
    Some(admin_dir) => Some(admin_dir)
    None =>
      match worktree_repair_gitfile_target(fs, worktree_path) {
        Some(target) => {
          let candidate = join_path(
            join_path(git_dir, "worktrees"),
            basename(target),
          )
          if fs.is_dir(candidate) {
            Some(candidate)
          } else {
            None
          }
        }
        None => None
      }
  }
}

///|
fn worktree_repair_collect_paths(
  fs : &@bit.RepoFileSystem,
  git_dir : String,
  root : String,
  worktree_paths : Array[String],
) -> Array[String] raise @bit.GitError {
  if worktree_paths.length() > 0 {
    return worktree_paths.map(path => {
      worktree_repair_resolve_requested_path(root, path)
    })
  }
  let worktrees_dir = join_path(git_dir, "worktrees")
  let paths : Array[String] = []
  if fs.is_dir(worktrees_dir) {
    let entries = fs.readdir(worktrees_dir)
    for entry in entries {
      if entry == "." || entry == ".." {
        continue
      }
      let admin_dir = join_path(worktrees_dir, entry)
      let gitdir_path = join_path(admin_dir, "gitdir")
      if !fs.is_file(gitdir_path) {
        continue
      }
      let content = read_trimmed_file(fs, gitdir_path)
      paths.push(worktree_admin_worktree_path(admin_dir, content))
    }
  }
  let current_git_file = join_path(root, ".git")
  if fs.is_dir(root) && fs.is_file(current_git_file) && !paths.contains(root) {
    paths.push(root)
  }
  paths
}

///|
fn worktree_repair_relative_paths_enabled(
  fs : &@bit.RepoFileSystem,
  git_dir : String,
) -> Bool {
  let common_git_dir = resolve_commondir(fs, git_dir) catch { _ => git_dir }
  let config_path = join_path(common_git_dir, "config")
  read_config_bool(fs, config_path, "worktree", "useRelativePaths").unwrap_or(
    false,
  )
}

///|
fn worktree_repair_expected_gitdir_content(
  admin_dir : String,
  worktree_path : String,
  use_relative_paths : Bool,
) -> String {
  let git_file = join_path(worktree_path, ".git")
  if use_relative_paths {
    worktree_compute_relative_path(admin_dir, git_file) + "\n"
  } else {
    git_file + "\n"
  }
}

///|
fn worktree_repair_expected_gitfile_content(
  admin_dir : String,
  worktree_path : String,
  use_relative_paths : Bool,
) -> String {
  if use_relative_paths {
    "gitdir: " + worktree_compute_relative_path(worktree_path, admin_dir) + "\n"
  } else {
    "gitdir: " + admin_dir + "\n"
  }
}

///|
fn worktree_repair_read_file(
  fs : &@bit.RepoFileSystem,
  path : String,
) -> String raise @bit.GitError {
  @utf8.decode_lossy(fs.read_file(path)[:])
}

///|
pub fn repair_worktree_detailed(
  fs : &@bit.FileSystem,
  rfs : &@bit.RepoFileSystem,
  root : String,
  worktree_paths? : Array[String] = [],
  relative_paths? : Bool? = None,
) -> WorktreeRepairResult raise @bit.GitError {
  let git_dir = resolve_git_dir(rfs, root)
  let repaired : Array[String] = []
  let warnings : Array[String] = []
  let worktrees_dir = join_path(git_dir, "worktrees")
  let explicit_paths = worktree_paths.length() > 0
  if !rfs.is_dir(worktrees_dir) && !explicit_paths {
    return { repaired, warnings }
  }
  let paths_to_check = worktree_repair_collect_paths(
    rfs, git_dir, root, worktree_paths,
  )
  let use_relative_paths = relative_paths.unwrap_or(
    worktree_repair_relative_paths_enabled(rfs, git_dir),
  )
  for wt_path in paths_to_check {
    let wt_exists = rfs.is_dir(wt_path)
    let wt_is_file = rfs.is_file(wt_path)
    let wt_git_file = join_path(wt_path, ".git")
    let admin_dir = worktree_repair_find_admin_dir(rfs, git_dir, wt_path)
    if explicit_paths {
      if wt_is_file {
        raise @bit.GitError::InvalidObject("'\{wt_path}' is not a directory")
      }
      if !wt_exists {
        raise @bit.GitError::InvalidObject("'\{wt_path}' is not a valid path")
      }
      if rfs.is_dir(wt_git_file) {
        raise @bit.GitError::InvalidObject(".git is not a file")
      }
      guard admin_dir is Some(admin) else {
        match worktree_repair_gitfile_target(rfs, wt_path) {
          Some(target) =>
            if worktree_repair_target_exists(rfs, target) {
              raise @bit.GitError::InvalidObject(
                ".git file does not reference a repository",
              )
            } else {
              raise @bit.GitError::InvalidObject(".git file broken")
            }
          None =>
            if rfs.is_file(wt_git_file) {
              raise @bit.GitError::InvalidObject(".git file broken")
            } else {
              raise @bit.GitError::InvalidObject(
                "'\{wt_path}' is not a valid path",
              )
            }
        }
      }
      match worktree_repair_gitfile_target(rfs, wt_path) {
        Some(target) =>
          if target != admin &&
            worktree_repair_target_exists(rfs, target) &&
            !worktree_repair_target_is_repository(rfs, target) {
            raise @bit.GitError::InvalidObject(
              ".git file does not reference a repository",
            )
          }
        None => ()
      }
      let expected_gitdir = worktree_repair_expected_gitdir_content(
        admin, wt_path, use_relative_paths,
      )
      let gitdir_path = join_path(admin, "gitdir")
      if !rfs.is_file(gitdir_path) {
        fs.write_string(gitdir_path, expected_gitdir)
        warnings.push("gitdir unreadable: \{gitdir_path}")
        repaired.push("gitdir: \{wt_path}")
      } else {
        let current = worktree_repair_read_file(rfs, gitdir_path)
        if current != expected_gitdir {
          fs.write_string(gitdir_path, expected_gitdir)
          warnings.push("gitdir incorrect: \{gitdir_path}")
          repaired.push("gitdir: \{wt_path}")
        }
      }
      let expected_gitfile = worktree_repair_expected_gitfile_content(
        admin, wt_path, use_relative_paths,
      )
      if !rfs.is_file(wt_git_file) {
        fs.write_string(wt_git_file, expected_gitfile)
        warnings.push(".git file broken: \{wt_path}")
        repaired.push(".git: \{wt_path}")
      } else {
        let current = worktree_repair_read_file(rfs, wt_git_file)
        let status = match worktree_repair_gitfile_target(rfs, wt_path) {
          Some(target) =>
            if target != admin {
              if worktree_repair_target_is_repository(rfs, target) {
                Some("incorrect")
              } else {
                Some("broken")
              }
            } else if current != expected_gitfile {
              Some("incorrect")
            } else {
              None
            }
          None => Some("broken")
        }
        match status {
          Some(kind) => {
            fs.write_string(wt_git_file, expected_gitfile)
            warnings.push(".git file \{kind}: \{wt_path}")
            repaired.push(".git: \{wt_path}")
          }
          None => ()
        }
      }
      continue
    }
    if wt_is_file {
      raise @bit.GitError::InvalidObject("'\{wt_path}' is not a directory")
    }
    if !wt_exists {
      continue
    }
    if rfs.is_dir(wt_git_file) {
      raise @bit.GitError::InvalidObject(".git is not a file")
    }
    guard admin_dir is Some(admin) else { continue }
    let expected_gitdir = worktree_repair_expected_gitdir_content(
      admin, wt_path, use_relative_paths,
    )
    let gitdir_path = join_path(admin, "gitdir")
    if !rfs.is_file(gitdir_path) {
      fs.write_string(gitdir_path, expected_gitdir)
      warnings.push("gitdir unreadable: \{gitdir_path}")
      repaired.push("gitdir: \{wt_path}")
    } else {
      let current = worktree_repair_read_file(rfs, gitdir_path)
      if current != expected_gitdir {
        fs.write_string(gitdir_path, expected_gitdir)
        warnings.push("gitdir incorrect: \{gitdir_path}")
        repaired.push("gitdir: \{wt_path}")
      }
    }
    let expected_gitfile = worktree_repair_expected_gitfile_content(
      admin, wt_path, use_relative_paths,
    )
    if !rfs.is_file(wt_git_file) {
      fs.write_string(wt_git_file, expected_gitfile)
      warnings.push(".git file broken: \{wt_path}")
      repaired.push(".git: \{wt_path}")
    } else {
      let current = worktree_repair_read_file(rfs, wt_git_file)
      let status = match worktree_repair_gitfile_target(rfs, wt_path) {
        Some(target) =>
          if target != admin {
            if worktree_repair_target_is_repository(rfs, target) {
              Some("incorrect")
            } else {
              Some("broken")
            }
          } else if current != expected_gitfile {
            Some("incorrect")
          } else {
            None
          }
        None => Some("broken")
      }
      match status {
        Some(kind) => {
          fs.write_string(wt_git_file, expected_gitfile)
          warnings.push(".git file \{kind}: \{wt_path}")
          repaired.push(".git: \{wt_path}")
        }
        None => ()
      }
    }
  }
  { repaired, warnings }
}

///|
/// Repair worktree administrative files.
pub fn repair_worktree(
  fs : &@bit.FileSystem,
  rfs : &@bit.RepoFileSystem,
  root : String,
  worktree_paths? : Array[String] = [],
) -> Array[String] raise @bit.GitError {
  repair_worktree_detailed(fs, rfs, root, worktree_paths~).repaired
}

///|
/// Check if a worktree is prunable and return the reason.
pub fn get_worktree_prunable_reason(
  rfs : &@bit.RepoFileSystem,
  root : String,
  worktree_path : String,
) -> String? raise @bit.GitError {
  let git_dir = resolve_git_dir(rfs, root)
  let abs_wt_path = if worktree_path.has_prefix("/") {
    worktree_path
  } else {
    normalize_path(join_path(root, worktree_path))
  }
  let admin_dir = find_worktree_admin_dir(rfs, git_dir, abs_wt_path)
  guard admin_dir is Some(admin) else { return None }
  // Check if locked - locked worktrees are not prunable
  let locked_path = join_path(admin, "locked")
  if rfs.is_file(locked_path) {
    return None
  }
  // Check if gitdir file points to non-existent location
  let gitdir_path = join_path(admin, "gitdir")
  if !rfs.is_file(gitdir_path) {
    return Some("gitdir file is missing")
  }
  let gitdir_content = read_trimmed_file(rfs, gitdir_path)
  let wt_git_dir = parent_dir(gitdir_content)
  if !rfs.is_dir(wt_git_dir) {
    return Some("gitdir file points to non-existent location")
  }
  None
}

///|
/// Resolve the actual git directory, handling .git files (for worktrees).
fn resolve_git_dir(
  fs : &@bit.RepoFileSystem,
  root : String,
) -> String raise @bit.GitError {
  if fs.is_file(join_path(root, "HEAD")) &&
    fs.is_dir(join_path(root, "objects")) {
    return root
  }
  let bit_path = join_path(root, ".git")
  if fs.is_dir(bit_path) {
    return bit_path
  }
  if fs.is_file(bit_path) {
    // .git is a file pointing to the real git directory
    let content = read_trimmed_file(fs, bit_path)
    if content.has_prefix("gitdir: ") {
      let target = String::unsafe_substring(
        content,
        start=8,
        end=content.length(),
      )
      // Resolve relative paths
      if target.has_prefix("/") {
        return resolve_commondir(fs, target)
      } else {
        let abs = join_path(root, target)
        return resolve_commondir(fs, abs)
      }
    }
  }
  raise @bit.GitError::InvalidObject("Not a git repository: \{root}")
}

///|
/// Resolve commondir to get the main git directory.
fn resolve_commondir(
  fs : &@bit.RepoFileSystem,
  git_dir : String,
) -> String raise @bit.GitError {
  let commondir_path = join_path(git_dir, "commondir")
  if fs.is_file(commondir_path) {
    let rel = read_trimmed_file(fs, commondir_path)
    if rel.has_prefix("/") {
      return rel
    } else {
      return normalize_path(join_path(git_dir, rel))
    }
  }
  git_dir
}

///|
fn copy_worktree_config(
  fs : &@bit.FileSystem,
  rfs : &@bit.RepoFileSystem,
  source_git_dir : String,
  dest_git_dir : String,
) -> Unit raise @bit.GitError {
  let common_git_dir = resolve_commondir(rfs, source_git_dir)
  let config_path = join_path(common_git_dir, "config")
  if !read_config_bool(rfs, config_path, "extensions", "worktreeconfig").unwrap_or(
      false,
    ) {
    return
  }
  let source_path = join_path(source_git_dir, "config.worktree")
  if !rfs.is_file(source_path) {
    return
  }
  let content = decode_bytes_lossy(rfs.read_file(source_path))
  let filtered = filter_worktree_config_content(content)
  if filtered.length() == 0 {
    return
  }
  fs.write_string(join_path(dest_git_dir, "config.worktree"), filtered)
}

///|
fn filter_worktree_config_content(content : String) -> String {
  let lines : Array[String] = []
  let mut current_section = ""
  for line_view in content.split("\n") {
    let line = line_view.to_owned()
    let trimmed = worktree_trim_whitespace(line)
    if trimmed.has_prefix("[") && trimmed.has_suffix("]") {
      let header = String::unsafe_substring(
        trimmed,
        start=1,
        end=trimmed.length() - 1,
      )
      let section_name = match header.find(" ") {
        Some(idx) => String::unsafe_substring(header, start=0, end=idx)
        None => header
      }
      current_section = section_name.to_lower()
      lines.push(line)
      continue
    }
    if current_section == "core" {
      match filtered_worktree_key_name(trimmed) {
        Some("bare") => continue
        Some("worktree") => continue
        _ => ()
      }
    }
    lines.push(line)
  }
  if lines.length() == 0 {
    ""
  } else {
    lines.join("\n") + "\n"
  }
}

///|
fn filtered_worktree_key_name(line : String) -> String? {
  if line.length() == 0 || line.has_prefix("#") || line.has_prefix(";") {
    return None
  }
  match line.find("=") {
    Some(idx) =>
      Some(
        worktree_trim_whitespace(
          String::unsafe_substring(line, start=0, end=idx),
        ).to_lower(),
      )
    None => None
  }
}

///|
fn get_main_worktree_info(
  fs : &@bit.RepoFileSystem,
  root : String,
  git_dir : String,
) -> WorktreeInfo raise @bit.GitError {
  let is_bare = normalize_path(root) == normalize_path(git_dir) &&
    basename(git_dir) != ".git" &&
    fs.is_file(join_path(git_dir, "HEAD")) &&
    fs.is_dir(join_path(git_dir, "objects"))
  if is_bare {
    return {
      path: normalize_path(root),
      head_id: None,
      branch: None,
      locked: false,
      is_main: true,
      is_bare: true,
    }
  }
  let head_ref = read_head_ref(fs, git_dir)
  let (head_id, branch) = match head_ref {
    Branch(name) =>
      match resolve_ref(fs, git_dir, "refs/heads/" + name) {
        Some(id) => (Some(id), Some(name))
        None => (None, None)
      }
    Detached(id) => (Some(id), None)
  }
  {
    path: normalize_path(root),
    head_id,
    branch,
    locked: false,
    is_main: true,
    is_bare: false,
  }
}

///|
fn get_linked_worktree_info(
  fs : &@bit.RepoFileSystem,
  admin_dir : String,
) -> WorktreeInfo? raise @bit.GitError {
  // Read gitdir to find worktree path
  let gitdir_path = join_path(admin_dir, "gitdir")
  if !fs.is_file(gitdir_path) {
    return None
  }
  let gitdir_content = read_trimmed_file(fs, gitdir_path)
  // gitdir points to worktree/.git file, get parent for worktree path
  let wt_path = worktree_admin_worktree_path(admin_dir, gitdir_content)
  // Read HEAD
  let head_path = join_path(admin_dir, "HEAD")
  let head_content = match read_worktree_head_content(fs, head_path) {
    Some(content) => content
    None => return None
  }
  let (head_id, branch) = if head_content.has_prefix("ref: ") {
    let refname = String::unsafe_substring(
      head_content,
      start=5,
      end=head_content.length(),
    )
    let branch_name = if refname.has_prefix("refs/heads/") {
      String::unsafe_substring(refname, start=11, end=refname.length())
    } else {
      refname
    }
    // Resolve ref from main git directory
    let common_dir = resolve_commondir_from_admin(fs, admin_dir)
    match resolve_ref(fs, common_dir, refname) {
      Some(id) => (Some(id), Some(branch_name))
      None => (None, None)
    }
  } else {
    // Detached HEAD
    let id = @bit.ObjectId::from_hex(head_content)
    (Some(id), None)
  }
  // Check if locked
  let locked = fs.is_file(join_path(admin_dir, "locked"))
  Some({
    path: wt_path,
    head_id,
    branch,
    locked,
    is_main: false,
    is_bare: false,
  })
}

///|
fn read_worktree_head_content(
  fs : &@bit.RepoFileSystem,
  head_path : String,
) -> String? raise @bit.GitError {
  if fs.is_file(head_path) {
    return Some(read_trimmed_file(fs, head_path))
  }
  match @bitio.read_symlink_target_path(head_path) {
    Some(target) =>
      if target.has_prefix("refs/") {
        Some("ref: " + target)
      } else {
        None
      }
    None => None
  }
}

///|
fn worktree_dir_has_entries(
  fs : &@bit.RepoFileSystem,
  path : String,
) -> Bool raise @bit.GitError {
  if !fs.is_dir(path) {
    return false
  }
  for entry in fs.readdir(path) {
    if entry != "." && entry != ".." {
      return true
    }
  }
  false
}

///|
fn resolve_worktree_admin_name(
  fs : &@bit.RepoFileSystem,
  git_dir : String,
  abs_wt_path : String,
) -> String {
  let worktrees_dir = join_path(git_dir, "worktrees")
  let base = worktree_sanitize_admin_component(basename(abs_wt_path))
  let mut index = 0
  let mut candidate = base
  while fs.is_dir(join_path(worktrees_dir, candidate)) {
    index += 1
    candidate = base + index.to_string()
  }
  candidate
}

///|
fn worktree_admin_is_forbidden_ref_char(ch : Char) -> Bool {
  ch.is_control() ||
  ch == ':' ||
  ch == '?' ||
  ch == '[' ||
  ch == '\\' ||
  ch == '^' ||
  ch == '~' ||
  ch == ' ' ||
  ch == '\t' ||
  ch == '*'
}

///|
fn worktree_strip_lock_suffixes(name : String) -> String {
  let mut current = name
  let mut done = false
  while !done {
    match current.strip_suffix(".lock") {
      Some(stripped) => current = stripped.to_owned()
      None => done = true
    }
  }
  current
}

///|
fn worktree_sanitize_admin_component(name : String) -> String {
  if name == "" {
    return name
  }
  let out : Array[Char] = []
  let mut last = Default::default()
  for ch in name.to_array() {
    if ch == '.' && last == '.' {
      last = ch
      continue
    }
    let out_ch = if ch == '{' && last == '@' {
      '-'
    } else if worktree_admin_is_forbidden_ref_char(ch) {
      '-'
    } else {
      ch
    }
    out.push(out_ch)
    last = ch
  }
  if out.length() == 0 {
    return name
  }
  if name.has_prefix(".") {
    out[0] = '-'
  }
  let sanitized = worktree_strip_lock_suffixes(String::from_array(out[:]))
  match sanitized.strip_suffix(".") {
    Some(stripped) => stripped.to_owned()
    None => sanitized
  }
}

///|
fn resolve_commondir_from_admin(
  fs : &@bit.RepoFileSystem,
  admin_dir : String,
) -> String raise @bit.GitError {
  let commondir_path = join_path(admin_dir, "commondir")
  if fs.is_file(commondir_path) {
    let rel = read_trimmed_file(fs, commondir_path)
    if rel.has_prefix("/") {
      return rel
    } else {
      return normalize_path(join_path(admin_dir, rel))
    }
  }
  // Default: ../.. from admin_dir
  normalize_path(join_path(admin_dir, "../.."))
}

///|
fn resolve_worktree_target(
  fs : &@bit.FileSystem,
  rfs : &@bit.RepoFileSystem,
  root : String,
  git_dir : String,
  commit_ish : String?,
  detach : Bool,
  new_branch : String?,
  orphan : Bool,
) -> (String?, @bit.ObjectId?) raise @bit.GitError {
  let resolved_commit_ish = match commit_ish {
    Some("-") =>
      match load_previous_checkout_location(rfs, git_dir) {
        Some(prev) => Some(prev)
        None =>
          raise @bit.GitError::InvalidObject(
            "No previous checkout target available",
          )
      }
    _ => commit_ish
  }
  // If new branch requested, create it
  match new_branch {
    Some(branch_name) => {
      if orphan {
        return (Some(branch_name), None)
      }
      let target = match resolved_commit_ish {
        Some(spec) => rev_parse(rfs, git_dir, spec)
        None =>
          match rev_parse(rfs, git_dir, "HEAD") {
            Some(id) => Some(id)
            None => resolve_head_commit(rfs, git_dir)
          }
      }
      guard target is Some(id) else {
        raise @bit.GitError::InvalidObject(
          "Cannot resolve commit for new branch",
        )
      }
      create_branch_at(
        fs,
        rfs,
        root,
        branch_name,
        id,
        start_point=resolved_commit_ish,
      )
      return (Some(branch_name), Some(id))
    }
    None => ()
  }
  match resolved_commit_ish {
    None => {
      // Use current HEAD
      let head = read_head_ref(rfs, git_dir)
      match head {
        Branch(name) => {
          let id = resolve_ref(rfs, git_dir, "refs/heads/" + name)
          if detach {
            (None, id)
          } else {
            (Some(name), id)
          }
        }
        Detached(id) => (None, Some(id))
      }
    }
    Some(spec) => {
      if spec == "HEAD" || spec == "@" {
        return match read_head_ref(rfs, git_dir) {
          Branch(name) =>
            (None, resolve_ref(rfs, git_dir, "refs/heads/" + name))
          Detached(id) => (None, Some(id))
        }
      }
      // Try to resolve as branch first
      if !detach {
        let branch_ref = "refs/heads/" + spec
        match resolve_ref(rfs, git_dir, branch_ref) {
          Some(id) => return (Some(spec), Some(id))
          None => ()
        }
      }
      // Resolve as commit
      let id = rev_parse(rfs, git_dir, spec)
      (None, id)
    }
  }
}

///|
fn load_previous_checkout_location(
  fs : &@bit.RepoFileSystem,
  git_dir : String,
) -> String? raise @bit.GitError {
  let path = join_path(git_dir, "bit-prev-checkout")
  if !fs.is_file(path) {
    return None
  }
  let prev = worktree_trim_whitespace(read_trimmed_file(fs, path))
  if prev.length() == 0 {
    None
  } else {
    Some(prev)
  }
}

///|
fn checkout_to_worktree(
  fs : &@bit.FileSystem,
  rfs : &@bit.RepoFileSystem,
  git_dir : String,
  worktree_path : String,
  admin_dir : String,
  commit_id : @bit.ObjectId,
) -> Unit raise @bit.GitError {
  let autocrlf = read_autocrlf_setting(rfs, git_dir)
  let core_eol = read_core_eol_setting(rfs, git_dir)
  let db = ObjectDb::load(rfs, git_dir)
  let files = collect_tree_files_from_commit(db, rfs, commit_id)
  // Write files to worktree
  for path, entry in files {
    let abs_path = join_path(worktree_path, path)
    if is_gitlink_mode_int(entry.mode) {
      fs.mkdir_p(abs_path)
      continue
    }
    let dir = parent_dir(abs_path)
    if dir != worktree_path {
      fs.mkdir_p(dir)
    }
    let obj = db.get(rfs, entry.id)
    match obj {
      Some(o) => {
        let attrs = resolve_eol_attrs(rfs, worktree_path, path)
        let output = smudge_for_checkout(o.data, attrs, autocrlf, core_eol~)
        fs.write_file(abs_path, output)
      }
      None => ()
    }
  }
  // Write index for the worktree
  let entries = tree_files_to_index(db, rfs, files)
  let index_path = join_path(admin_dir, "index")
  write_index_entries_to_path(fs, index_path, entries)
}

///|
fn find_worktree_admin_dir(
  fs : &@bit.RepoFileSystem,
  git_dir : String,
  worktree_path : String,
) -> String? raise @bit.GitError {
  let worktrees_dir = join_path(git_dir, "worktrees")
  if !fs.is_dir(worktrees_dir) {
    return None
  }
  let normalized_worktree_path = normalize_path(worktree_path)
  let entries = fs.readdir(worktrees_dir)
  for entry in entries {
    if entry == "." || entry == ".." {
      continue
    }
    let admin_dir = join_path(worktrees_dir, entry)
    if !fs.is_dir(admin_dir) {
      continue
    }
    let gitdir_path = join_path(admin_dir, "gitdir")
    if !fs.is_file(gitdir_path) {
      continue
    }
    let gitdir_content = read_trimmed_file(fs, gitdir_path)
    let wt_path = worktree_admin_worktree_path(admin_dir, gitdir_content)
    if wt_path == worktree_path || wt_path == normalized_worktree_path {
      return Some(admin_dir)
    }
  }
  None
}

///|
fn worktree_effective_force_level(force : Bool, force_level : Int) -> Int {
  if force_level > 0 {
    force_level
  } else if force {
    1
  } else {
    0
  }
}

///|
fn worktree_not_found_message(worktree_path : String) -> String {
  "'\{worktree_path}' is not a working tree"
}

///|
fn worktree_use_relative_paths_enabled(
  fs : &@bit.RepoFileSystem,
  git_dir : String,
) -> Bool {
  let common_git_dir = resolve_commondir(fs, git_dir) catch { _ => git_dir }
  let config_path = join_path(common_git_dir, "config")
  if read_config_bool(fs, config_path, "worktree", "useRelativePaths").unwrap_or(
      false,
    ) {
    return true
  }
  read_config_bool(fs, config_path, "extensions", "relativeworktrees").unwrap_or(
    false,
  )
}

///|
fn worktree_compute_relative_path(
  from_dir : String,
  to_path : String,
) -> String {
  let from_parts = normalize_path(from_dir)
    .split("/")
    .map(fn(v) { v.to_owned() })
    .to_array()
  let to_parts = normalize_path(to_path)
    .split("/")
    .map(fn(v) { v.to_owned() })
    .to_array()
  let mut common = 0
  let min_len = if from_parts.length() < to_parts.length() {
    from_parts.length()
  } else {
    to_parts.length()
  }
  while common < min_len && from_parts[common] == to_parts[common] {
    common += 1
  }
  let result : Array[String] = []
  for i = common; i < from_parts.length(); i = i + 1 {
    if from_parts[i] != "" {
      result.push("..")
    }
  }
  for i = common; i < to_parts.length(); i = i + 1 {
    result.push(to_parts[i])
  }
  if result.length() == 0 {
    "."
  } else {
    result.join("/")
  }
}

///|
fn worktree_enable_relative_paths(
  fs : &@bit.FileSystem,
  rfs : &@bit.RepoFileSystem,
  git_dir : String,
) -> Unit raise @bit.GitError {
  let config_path = join_path(git_dir, "config")
  let content = read_config_content(rfs, git_dir)
  let blocks = if worktree_trim_whitespace(content).length() == 0 {
    []
  } else {
    parse_config_blocks(content)
  }
  let with_core = worktree_upsert_top_level_config_key(
    blocks, "core", "repositoryformatversion", "1",
  )
  let with_extensions = worktree_upsert_top_level_config_key(
    with_core, "extensions", "relativeworktrees", "true",
  )
  fs.write_string(config_path, render_config_blocks(with_extensions))
}

///|
fn worktree_upsert_top_level_config_key(
  blocks : Array[ConfigBlock],
  section : String,
  key : String,
  value : String,
) -> Array[ConfigBlock] {
  let updated : Array[ConfigBlock] = []
  let mut found_section = false
  for block in blocks {
    if block.section == Some(section) && block.name is None {
      found_section = true
      let lines : Array[String] = []
      let mut found_key = false
      for line in block.lines {
        match parse_config_kv(line) {
          Some((existing_key, _)) if existing_key == key => {
            lines.push("\t\{key} = \{value}")
            found_key = true
          }
          _ => lines.push(line)
        }
      }
      if !found_key {
        lines.push("\t\{key} = \{value}")
      }
      updated.push({
        header: block.header,
        section: block.section,
        name: block.name,
        lines,
      })
    } else {
      updated.push(block)
    }
  }
  if !found_section {
    updated.push({
      header: Some("[\{section}]"),
      section: Some(section),
      name: None,
      lines: ["\t\{key} = \{value}"],
    })
  }
  updated
}

///|
fn worktree_contains_nested_git(
  fs : &@bit.RepoFileSystem,
  path : String,
  is_root? : Bool = true,
) -> Bool raise @bit.GitError {
  if !fs.is_dir(path) {
    return false
  }
  for entry in fs.readdir(path) {
    if entry == "." || entry == ".." {
      continue
    }
    let child_path = join_path(path, entry)
    if entry == ".git" {
      if !is_root && (fs.is_file(child_path) || fs.is_dir(child_path)) {
        return true
      }
      continue
    }
    if fs.is_dir(child_path) &&
      worktree_contains_nested_git(fs, child_path, is_root=false) {
      return true
    }
  }
  false
}

///|
fn worktree_has_local_changes(
  fs : &@bit.RepoFileSystem,
  worktree_path : String,
  admin_dir : String,
) -> Bool raise @bit.GitError {
  let index_entries = read_index_entries(fs, admin_dir)
  let tracked_paths : Array[String] = []
  let gitlink_paths : Array[String] = []
  let common_git_dir = resolve_commondir_from_admin(fs, admin_dir)
  let db = ObjectDb::load_lazy(fs, common_git_dir)
  for entry in index_entries {
    tracked_paths.push(entry.path)
    if is_gitlink_mode_int(entry.mode) {
      gitlink_paths.push(entry.path)
      continue
    }
    let file_path = join_path(worktree_path, entry.path)
    if !fs.is_file(file_path) {
      return true
    }
    let file_bytes = fs.read_file(file_path)
    match db.get(fs, entry.id) {
      Some(obj) if obj.obj_type == @bit.ObjectType::Blob =>
        if file_bytes != obj.data {
          return true
        }
      _ => return true
    }
  }
  worktree_has_untracked_files(
    fs, worktree_path, "", tracked_paths, gitlink_paths,
  )
}

///|
fn worktree_has_untracked_files(
  fs : &@bit.RepoFileSystem,
  worktree_path : String,
  rel_path : String,
  tracked_paths : Array[String],
  gitlink_paths : Array[String],
) -> Bool raise @bit.GitError {
  let abs_path = if rel_path.length() == 0 {
    worktree_path
  } else {
    join_path(worktree_path, rel_path)
  }
  if !fs.is_dir(abs_path) {
    return false
  }
  for entry in fs.readdir(abs_path) {
    if entry == "." || entry == ".." {
      continue
    }
    if rel_path.length() == 0 && entry == ".git" {
      continue
    }
    let child_rel = if rel_path.length() == 0 {
      entry
    } else {
      rel_path + "/" + entry
    }
    let child_abs = join_path(abs_path, entry)
    if fs.is_dir(child_abs) {
      if gitlink_paths.contains(child_rel) {
        if worktree_dir_has_entries(fs, child_abs) {
          return true
        }
        continue
      }
      if tracked_paths.contains(child_rel) {
        return true
      }
      if worktree_has_tracked_descendant(tracked_paths, child_rel) {
        if worktree_has_untracked_files(
            fs, worktree_path, child_rel, tracked_paths, gitlink_paths,
          ) {
          return true
        }
      } else {
        return true
      }
    } else if fs.is_file(child_abs) && !tracked_paths.contains(child_rel) {
      return true
    }
  }
  false
}

///|
fn worktree_admin_worktree_path(
  admin_dir : String,
  gitdir_content : String,
) -> String {
  if gitdir_content.length() == 0 {
    ""
  } else {
    prune_resolve_gitdir_path(admin_dir, gitdir_content)
    |> parent_dir
    |> normalize_path
  }
}

///|
fn worktree_has_tracked_descendant(
  tracked_paths : Array[String],
  prefix : String,
) -> Bool {
  let normalized = prefix + "/"
  for path in tracked_paths {
    if path.has_prefix(normalized) {
      return true
    }
  }
  false
}

///|
fn remove_dir_recursive(
  fs : &@bit.FileSystem,
  rfs : &@bit.RepoFileSystem,
  path : String,
) -> Unit raise @bit.GitError {
  if !rfs.is_dir(path) {
    if rfs.is_file(path) {
      fs.remove_file(path)
    }
    return
  }
  let entries = rfs.readdir(path)
  for entry in entries {
    if entry == "." || entry == ".." {
      continue
    }
    let child_path = join_path(path, entry)
    if rfs.is_dir(child_path) {
      remove_dir_recursive(fs, rfs, child_path)
    } else {
      fs.remove_file(child_path)
    }
  }
  fs.remove_dir(path)
}

///|
fn read_trimmed_file(
  fs : &@bit.RepoFileSystem,
  path : String,
) -> String raise @bit.GitError {
  let content = @utf8.decode_lossy(fs.read_file(path)[:])
  worktree_trim_whitespace(content)
}

///|
fn worktree_trim_whitespace(s : String) -> String {
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

///|
fn basename(path : String) -> String {
  match path.rev_find("/") {
    None => path
    Some(idx) =>
      if idx + 1 >= path.length() {
        // Path ends with /
        let trimmed = String::unsafe_substring(path, start=0, end=idx)
        basename(trimmed)
      } else {
        String::unsafe_substring(path, start=idx + 1, end=path.length())
      }
  }
}

///|
fn normalize_path(path : String) -> String {
  let parts : Array[String] = []
  for part_view in path.split("/") {
    let part = part_view.to_owned()
    if part == "" || part == "." {
      continue
    } else if part == ".." {
      if parts.length() > 0 && parts[parts.length() - 1] != ".." {
        let _ = parts.pop()
      } else if !path.has_prefix("/") {
        parts.push(part)
      }
    } else {
      parts.push(part)
    }
  }
  let result = parts.join("/")
  if path.has_prefix("/") {
    "/" + result
  } else {
    result
  }
}

///|
/// Write index entries to a specific path (for worktree index).
fn write_index_entries_to_path(
  fs : &@bit.FileSystem,
  path : String,
  entries : Array[IndexEntry],
) -> Unit raise @bit.GitError {
  let sorted = entries.copy()
  sorted.sort_by((a, b) => String::compare(a.path, b.path))
  // Serialize index
  let buf : Array[Byte] = []
  // Header: DIRC + version 2 + entry count
  buf.push(b'D')
  buf.push(b'I')
  buf.push(b'R')
  buf.push(b'C')
  // Version 2
  buf.push(0)
  buf.push(0)
  buf.push(0)
  buf.push(2)
  // Entry count (big endian)
  let count = sorted.length()
  buf.push(((count >> 24) & 0xff).to_byte())
  buf.push(((count >> 16) & 0xff).to_byte())
  buf.push(((count >> 8) & 0xff).to_byte())
  buf.push((count & 0xff).to_byte())
  for entry in sorted {
    // ctime, mtime (8 bytes each)
    for _ in 0..<16 {
      buf.push(0)
    }
    // dev, ino (4 bytes each)
    for _ in 0..<8 {
      buf.push(0)
    }
    // mode (4 bytes big endian)
    let mode = entry.mode
    buf.push(((mode >> 24) & 0xff).to_byte())
    buf.push(((mode >> 16) & 0xff).to_byte())
    buf.push(((mode >> 8) & 0xff).to_byte())
    buf.push((mode & 0xff).to_byte())
    // uid, gid (4 bytes each)
    for _ in 0..<8 {
      buf.push(0)
    }
    // size (4 bytes big endian)
    let size = entry.size
    buf.push(((size >> 24) & 0xff).to_byte())
    buf.push(((size >> 16) & 0xff).to_byte())
    buf.push(((size >> 8) & 0xff).to_byte())
    buf.push((size & 0xff).to_byte())
    // object id (20 bytes)
    for b in entry.id.bytes {
      buf.push(b)
    }
    // flags (2 bytes): name length in lower 12 bits
    let name_len = entry.path.length()
    let flags = if name_len > 0xfff { 0xfff } else { name_len }
    buf.push(((flags >> 8) & 0xff).to_byte())
    buf.push((flags & 0xff).to_byte())
    // path name
    for c in entry.path {
      buf.push(c.to_int().to_byte())
    }
    buf.push(0) // NUL terminator
    // Pad to 8-byte boundary (62 = fixed part before path)
    let entry_len = 62 + entry.path.length() + 1
    let padding = (8 - entry_len % 8) % 8
    for _ in 0..<padding {
      buf.push(0)
    }
  }
  // Compute checksum
  let data = Bytes::from_array(FixedArray::makei(buf.length(), i => buf[i]))
  let checksum = @bit.sha1(data)
  for b in checksum.bytes {
    buf.push(b)
  }
  let final_data = Bytes::from_array(
    FixedArray::makei(buf.length(), i => buf[i]),
  )
  fs.write_file(path, final_data)
}

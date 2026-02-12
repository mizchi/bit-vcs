///| Git worktree administration (git worktree list/add/remove/prune)

///|
/// Information about a worktree.
pub(all) struct WorktreeInfo {
  /// Absolute path to the worktree directory
  path : String
  /// Current HEAD commit id
  head_id : @git.ObjectId?
  /// Branch name if HEAD points to a branch, None if detached
  branch : String?
  /// True if the worktree is locked
  locked : Bool
  /// True if this is the main worktree (contains .git directory)
  is_main : Bool
}

///|
/// List all worktrees in a repository.
/// Returns the main worktree first, followed by linked worktrees.
pub fn list_worktrees(
  fs : &@git.RepoFileSystem,
  root : String,
) -> Array[WorktreeInfo] raise @git.GitError {
  let result : Array[WorktreeInfo] = []
  let git_dir = resolve_git_dir(fs, root)
  let root_is_bare = normalize_path(git_dir) == normalize_path(root) &&
    fs.is_file(join_path(root, "HEAD")) &&
    fs.is_dir(join_path(root, "objects"))
  // Add main worktree for non-bare repositories.
  if not(root_is_bare) {
    let main_info = get_main_worktree_info(fs, root, git_dir)
    result.push(main_info)
  }
  // Scan .git/worktrees/ for linked worktrees
  let worktrees_dir = join_path(git_dir, "worktrees")
  if not(fs.is_dir(worktrees_dir)) {
    return result
  }
  let entries = fs.readdir(worktrees_dir)
  for entry in entries {
    if entry == "." || entry == ".." {
      continue
    }
    let admin_dir = join_path(worktrees_dir, entry)
    if not(fs.is_dir(admin_dir)) {
      continue
    }
    match get_linked_worktree_info(fs, admin_dir) {
      Some(info) => result.push(info)
      None => continue
    }
  }
  result
}

///|
/// Check if a branch is checked out in any worktree.
/// Returns the worktree path if the branch is in use, None otherwise.
pub fn is_branch_checked_out(
  fs : &@git.RepoFileSystem,
  root : String,
  branch : String,
) -> String? raise @git.GitError {
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
/// Create a new linked worktree.
pub fn create_worktree(
  fs : &@git.FileSystem,
  rfs : &@git.RepoFileSystem,
  root : String,
  worktree_path : String,
  commit_ish : String?,
  detach? : Bool = false,
  new_branch~ : String?,
) -> Unit raise @git.GitError {
  let git_dir = resolve_git_dir(rfs, root)
  // Resolve the absolute worktree path
  let abs_wt_path = if worktree_path.has_prefix("/") {
    worktree_path
  } else {
    join_path(root, worktree_path)
  }
  // Check worktree path doesn't already exist as a file
  if rfs.is_file(abs_wt_path) {
    raise @git.GitError::InvalidObject(
      "'\{worktree_path}' already exists as a file",
    )
  }
  // Determine the worktree name (basename of path)
  let wt_name = basename(abs_wt_path)
  // Check if admin directory already exists
  let worktrees_dir = join_path(git_dir, "worktrees")
  let admin_dir = join_path(worktrees_dir, wt_name)
  if rfs.is_dir(admin_dir) {
    raise @git.GitError::InvalidObject(
      "'\{wt_name}' is already a worktree; use a different path",
    )
  }
  // Determine branch and commit
  let (branch, commit_id) = resolve_worktree_target(
    fs, rfs, root, git_dir, commit_ish, detach, new_branch,
  )
  // Check branch is not already checked out
  match branch {
    Some(b) =>
      match is_branch_checked_out(rfs, root, b) {
        Some(path) =>
          raise @git.GitError::InvalidObject(
            "'\{b}' is already checked out at '\{path}'",
          )
        None => ()
      }
    None => ()
  }
  // Create admin directory
  fs.mkdir_p(admin_dir)
  // Write gitdir file (points to worktree's .git file)
  let gitdir_path = join_path(admin_dir, "gitdir")
  let wt_git_file = join_path(abs_wt_path, ".git")
  fs.write_string(gitdir_path, wt_git_file + "\n")
  // Write HEAD file
  let head_path = join_path(admin_dir, "HEAD")
  match branch {
    Some(b) => fs.write_string(head_path, "ref: refs/heads/" + b + "\n")
    None =>
      match commit_id {
        Some(id) => fs.write_string(head_path, id.to_hex() + "\n")
        None =>
          raise @git.GitError::InvalidObject(
            "No commit to create worktree from",
          )
      }
  }
  // Write commondir file
  let commondir_path = join_path(admin_dir, "commondir")
  fs.write_string(commondir_path, "../..\n")
  // Create worktree directory
  fs.mkdir_p(abs_wt_path)
  // Create .git file in worktree
  fs.write_string(wt_git_file, "gitdir: " + admin_dir + "\n")
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
  fs : &@git.FileSystem,
  rfs : &@git.RepoFileSystem,
  root : String,
  worktree_path : String,
  force? : Bool = false,
) -> Unit raise @git.GitError {
  let git_dir = resolve_git_dir(rfs, root)
  // Resolve the absolute worktree path
  let abs_wt_path = if worktree_path.has_prefix("/") {
    worktree_path
  } else {
    join_path(root, worktree_path)
  }
  // Find the admin directory for this worktree
  let admin_dir = find_worktree_admin_dir(rfs, git_dir, abs_wt_path)
  guard admin_dir is Some(admin) else {
    raise @git.GitError::InvalidObject(
      "'\{worktree_path}' is not a valid worktree",
    )
  }
  // Check if locked
  let locked_path = join_path(admin, "locked")
  if rfs.is_file(locked_path) && not(force) {
    raise @git.GitError::InvalidObject(
      "'\{worktree_path}' is locked; use --force to remove anyway",
    )
  }
  // Remove worktree directory if it exists
  if rfs.is_dir(abs_wt_path) {
    remove_dir_recursive(fs, rfs, abs_wt_path)
  }
  // Remove admin directory
  remove_dir_recursive(fs, rfs, admin)
}

///|
/// Prune worktrees with invalid gitdir references.
/// Returns list of pruned admin directory names.
pub fn prune_worktrees(
  fs : &@git.FileSystem,
  rfs : &@git.RepoFileSystem,
  root : String,
  dry_run? : Bool = false,
) -> Array[String] raise @git.GitError {
  let git_dir = resolve_git_dir(rfs, root)
  let worktrees_dir = join_path(git_dir, "worktrees")
  let pruned : Array[String] = []
  if not(rfs.is_dir(worktrees_dir)) {
    return pruned
  }
  let entries = rfs.readdir(worktrees_dir)
  for entry in entries {
    if entry == "." || entry == ".." {
      continue
    }
    let admin_dir = join_path(worktrees_dir, entry)
    if not(rfs.is_dir(admin_dir)) {
      continue
    }
    // Check if locked
    let locked_path = join_path(admin_dir, "locked")
    if rfs.is_file(locked_path) {
      continue
    }
    // Read gitdir to find worktree path
    let gitdir_path = join_path(admin_dir, "gitdir")
    if not(rfs.is_file(gitdir_path)) {
      // Missing gitdir file - prune
      if not(dry_run) {
        remove_dir_recursive(fs, rfs, admin_dir)
      }
      pruned.push(entry)
      continue
    }
    let gitdir_content = read_trimmed_file(rfs, gitdir_path)
    // gitdir points to worktree/.git file
    // Check if worktree directory exists
    let wt_git_dir = parent_dir(gitdir_content)
    if not(rfs.is_dir(wt_git_dir)) {
      // Worktree directory missing - prune
      if not(dry_run) {
        remove_dir_recursive(fs, rfs, admin_dir)
      }
      pruned.push(entry)
    }
  }
  pruned
}

///|
/// Lock a worktree to prevent it from being pruned.
pub fn lock_worktree(
  fs : &@git.FileSystem,
  rfs : &@git.RepoFileSystem,
  root : String,
  worktree_path : String,
  reason~ : String?,
) -> Unit raise @git.GitError {
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
    raise @git.GitError::InvalidObject(
      "'\{worktree_path}' is not a valid worktree",
    )
  }
  // Check if already locked
  let locked_path = join_path(admin, "locked")
  if rfs.is_file(locked_path) {
    raise @git.GitError::InvalidObject("'\{worktree_path}' is already locked")
  }
  // Write lock file
  let content = reason.unwrap_or("")
  fs.write_string(locked_path, content)
}

///|
/// Unlock a worktree.
pub fn unlock_worktree(
  fs : &@git.FileSystem,
  rfs : &@git.RepoFileSystem,
  root : String,
  worktree_path : String,
) -> Unit raise @git.GitError {
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
    raise @git.GitError::InvalidObject(
      "'\{worktree_path}' is not a valid worktree",
    )
  }
  // Check if locked
  let locked_path = join_path(admin, "locked")
  if not(rfs.is_file(locked_path)) {
    raise @git.GitError::InvalidObject("'\{worktree_path}' is not locked")
  }
  // Remove lock file
  fs.remove_file(locked_path)
}

///|
/// Get lock reason for a worktree.
pub fn get_worktree_lock_reason(
  rfs : &@git.RepoFileSystem,
  root : String,
  worktree_path : String,
) -> String? raise @git.GitError {
  let git_dir = resolve_git_dir(rfs, root)
  let abs_wt_path = if worktree_path.has_prefix("/") {
    worktree_path
  } else {
    normalize_path(join_path(root, worktree_path))
  }
  let admin_dir = find_worktree_admin_dir(rfs, git_dir, abs_wt_path)
  guard admin_dir is Some(admin) else { return None }
  let locked_path = join_path(admin, "locked")
  if not(rfs.is_file(locked_path)) {
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
  fs : &@git.FileSystem,
  rfs : &@git.RepoFileSystem,
  root : String,
  source_path : String,
  dest_path : String,
  force? : Bool = false,
) -> Unit raise @git.GitError {
  let git_dir = resolve_git_dir(rfs, root)
  // Resolve absolute paths
  let abs_src = if source_path.has_prefix("/") {
    source_path
  } else {
    normalize_path(join_path(root, source_path))
  }
  let abs_dst = if dest_path.has_prefix("/") {
    dest_path
  } else {
    normalize_path(join_path(root, dest_path))
  }
  // Find admin directory
  let admin_dir = find_worktree_admin_dir(rfs, git_dir, abs_src)
  guard admin_dir is Some(admin) else {
    raise @git.GitError::InvalidObject(
      "'\{source_path}' is not a valid worktree",
    )
  }
  // Check if locked (unless force)
  let locked_path = join_path(admin, "locked")
  if rfs.is_file(locked_path) && not(force) {
    raise @git.GitError::InvalidObject(
      "'\{source_path}' is locked; use --force to move anyway",
    )
  }
  // Check destination doesn't exist
  if rfs.is_dir(abs_dst) || rfs.is_file(abs_dst) {
    raise @git.GitError::InvalidObject("'\{dest_path}' already exists")
  }
  // Update gitdir file to point to new location
  let gitdir_path = join_path(admin, "gitdir")
  let new_git_file = join_path(abs_dst, ".git")
  fs.write_string(gitdir_path, new_git_file + "\n")
  // Move the worktree directory (by copying and removing)
  copy_dir_recursive_wt(fs, rfs, abs_src, abs_dst)
  remove_dir_recursive(fs, rfs, abs_src)
  // Update .git file in new location
  fs.write_string(new_git_file, "gitdir: " + admin + "\n")
}

///|
fn copy_dir_recursive_wt(
  fs : &@git.FileSystem,
  rfs : &@git.RepoFileSystem,
  src : String,
  dst : String,
) -> Unit raise @git.GitError {
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
/// Repair worktree administrative files.
pub fn repair_worktree(
  fs : &@git.FileSystem,
  rfs : &@git.RepoFileSystem,
  root : String,
  worktree_paths? : Array[String] = [],
) -> Array[String] raise @git.GitError {
  let git_dir = resolve_git_dir(rfs, root)
  let repaired : Array[String] = []
  let worktrees_dir = join_path(git_dir, "worktrees")
  if not(rfs.is_dir(worktrees_dir)) {
    return repaired
  }
  // If specific paths given, repair only those
  let paths_to_check = if worktree_paths.length() > 0 {
    worktree_paths.map(fn(p) {
      if p.has_prefix("/") {
        p
      } else {
        normalize_path(join_path(root, p))
      }
    })
  } else {
    // Repair all worktrees
    let all : Array[String] = []
    let entries = rfs.readdir(worktrees_dir)
    for entry in entries {
      if entry == "." || entry == ".." {
        continue
      }
      let admin_dir = join_path(worktrees_dir, entry)
      let gitdir_path = join_path(admin_dir, "gitdir")
      if rfs.is_file(gitdir_path) {
        let content = read_trimmed_file(rfs, gitdir_path)
        all.push(content |> parent_dir |> normalize_path)
      }
    }
    all
  }
  for wt_path in paths_to_check {
    let admin_dir = find_worktree_admin_dir(rfs, git_dir, wt_path)
    guard admin_dir is Some(admin) else { continue }
    // Check and repair gitdir reference
    let gitdir_path = join_path(admin, "gitdir")
    let wt_git_file = join_path(wt_path, ".git")
    // Update gitdir if worktree exists but gitdir is wrong
    if rfs.is_dir(wt_path) {
      let expected_gitdir = wt_git_file + "\n"
      if rfs.is_file(gitdir_path) {
        let current = rfs.read_file(gitdir_path)
        let current_str = @utf8.decode_lossy(current[:])
        if current_str != expected_gitdir {
          fs.write_string(gitdir_path, expected_gitdir)
          repaired.push("gitdir: \{wt_path}")
        }
      }
    }
    // Check and repair .git file in worktree
    if rfs.is_dir(wt_path) {
      let expected_content = "gitdir: " + admin + "\n"
      if rfs.is_file(wt_git_file) {
        let current = rfs.read_file(wt_git_file)
        let current_str = @utf8.decode_lossy(current[:])
        if current_str != expected_content {
          fs.write_string(wt_git_file, expected_content)
          repaired.push(".git: \{wt_path}")
        }
      } else {
        // .git file missing, create it
        fs.write_string(wt_git_file, expected_content)
        repaired.push(".git (created): \{wt_path}")
      }
    }
  }
  repaired
}

///|
/// Check if a worktree is prunable and return the reason.
pub fn get_worktree_prunable_reason(
  rfs : &@git.RepoFileSystem,
  root : String,
  worktree_path : String,
) -> String? raise @git.GitError {
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
  if not(rfs.is_file(gitdir_path)) {
    return Some("gitdir file is missing")
  }
  let gitdir_content = read_trimmed_file(rfs, gitdir_path)
  let wt_git_dir = parent_dir(gitdir_content)
  if not(rfs.is_dir(wt_git_dir)) {
    return Some("gitdir file points to non-existent location")
  }
  None
}

///|
/// Resolve the actual git directory, handling .git files (for worktrees).
fn resolve_git_dir(
  fs : &@git.RepoFileSystem,
  root : String,
) -> String raise @git.GitError {
  if fs.is_file(join_path(root, "HEAD")) &&
    fs.is_dir(join_path(root, "objects")) {
    return root
  }
  let git_path = join_path(root, ".git")
  if fs.is_dir(git_path) {
    return git_path
  }
  if fs.is_file(git_path) {
    // .git is a file pointing to the real git directory
    let content = read_trimmed_file(fs, git_path)
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
  raise @git.GitError::InvalidObject("Not a git repository: \{root}")
}

///|
/// Resolve commondir to get the main git directory.
fn resolve_commondir(
  fs : &@git.RepoFileSystem,
  git_dir : String,
) -> String raise @git.GitError {
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
fn get_main_worktree_info(
  fs : &@git.RepoFileSystem,
  root : String,
  git_dir : String,
) -> WorktreeInfo raise @git.GitError {
  let head_ref = read_head_ref(fs, git_dir)
  let (head_id, branch) = match head_ref {
    Branch(name) => (resolve_ref(fs, git_dir, "refs/heads/" + name), Some(name))
    Detached(id) => (Some(id), None)
  }
  { path: normalize_path(root), head_id, branch, locked: false, is_main: true }
}

///|
fn get_linked_worktree_info(
  fs : &@git.RepoFileSystem,
  admin_dir : String,
) -> WorktreeInfo? raise @git.GitError {
  // Read gitdir to find worktree path
  let gitdir_path = join_path(admin_dir, "gitdir")
  if not(fs.is_file(gitdir_path)) {
    return None
  }
  let gitdir_content = read_trimmed_file(fs, gitdir_path)
  // gitdir points to worktree/.git file, get parent for worktree path
  let wt_path = gitdir_content |> parent_dir |> normalize_path
  // Read HEAD
  let head_path = join_path(admin_dir, "HEAD")
  if not(fs.is_file(head_path)) {
    return None
  }
  let head_content = read_trimmed_file(fs, head_path)
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
    let id = resolve_ref(fs, common_dir, refname)
    (id, Some(branch_name))
  } else {
    // Detached HEAD
    let id = @git.ObjectId::from_hex(head_content)
    (Some(id), None)
  }
  // Check if locked
  let locked = fs.is_file(join_path(admin_dir, "locked"))
  Some({ path: wt_path, head_id, branch, locked, is_main: false })
}

///|
fn resolve_commondir_from_admin(
  fs : &@git.RepoFileSystem,
  admin_dir : String,
) -> String raise @git.GitError {
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
  fs : &@git.FileSystem,
  rfs : &@git.RepoFileSystem,
  root : String,
  git_dir : String,
  commit_ish : String?,
  detach : Bool,
  new_branch : String?,
) -> (String?, @git.ObjectId?) raise @git.GitError {
  // If new branch requested, create it
  match new_branch {
    Some(branch_name) => {
      let target = match commit_ish {
        Some(spec) => rev_parse(rfs, git_dir, spec)
        None => resolve_head_commit(rfs, git_dir)
      }
      guard target is Some(id) else {
        raise @git.GitError::InvalidObject(
          "Cannot resolve commit for new branch",
        )
      }
      create_branch_at(fs, rfs, root, branch_name, id)
      return (Some(branch_name), Some(id))
    }
    None => ()
  }
  match commit_ish {
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
      // Try to resolve as branch first
      if not(detach) {
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
fn checkout_to_worktree(
  fs : &@git.FileSystem,
  rfs : &@git.RepoFileSystem,
  git_dir : String,
  worktree_path : String,
  admin_dir : String,
  commit_id : @git.ObjectId,
) -> Unit raise @git.GitError {
  let db = ObjectDb::load(rfs, git_dir)
  let files = collect_tree_files_from_commit(db, rfs, commit_id)
  // Write files to worktree
  for item in files.to_array() {
    let (path, entry) = item
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
      Some(o) => fs.write_file(abs_path, o.data)
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
  fs : &@git.RepoFileSystem,
  git_dir : String,
  worktree_path : String,
) -> String? raise @git.GitError {
  let worktrees_dir = join_path(git_dir, "worktrees")
  if not(fs.is_dir(worktrees_dir)) {
    return None
  }
  let entries = fs.readdir(worktrees_dir)
  for entry in entries {
    if entry == "." || entry == ".." {
      continue
    }
    let admin_dir = join_path(worktrees_dir, entry)
    if not(fs.is_dir(admin_dir)) {
      continue
    }
    let gitdir_path = join_path(admin_dir, "gitdir")
    if not(fs.is_file(gitdir_path)) {
      continue
    }
    let gitdir_content = read_trimmed_file(fs, gitdir_path)
    let wt_path = parent_dir(gitdir_content)
    if wt_path == worktree_path ||
      normalize_path(wt_path) == normalize_path(worktree_path) {
      return Some(admin_dir)
    }
  }
  None
}

///|
fn remove_dir_recursive(
  fs : &@git.FileSystem,
  rfs : &@git.RepoFileSystem,
  path : String,
) -> Unit raise @git.GitError {
  if not(rfs.is_dir(path)) {
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
  fs : &@git.RepoFileSystem,
  path : String,
) -> String raise @git.GitError {
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
    let part = part_view.to_string()
    if part == "" || part == "." {
      continue
    } else if part == ".." {
      if parts.length() > 0 && parts[parts.length() - 1] != ".." {
        let _ = parts.pop()
      } else if not(path.has_prefix("/")) {
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
  fs : &@git.FileSystem,
  path : String,
  entries : Array[IndexEntry],
) -> Unit raise @git.GitError {
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
  let checksum = @git.sha1(data)
  for b in checksum.bytes {
    buf.push(b)
  }
  let final_data = Bytes::from_array(
    FixedArray::makei(buf.length(), i => buf[i]),
  )
  fs.write_file(path, final_data)
}

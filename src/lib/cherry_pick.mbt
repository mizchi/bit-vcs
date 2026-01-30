///| Git cherry-pick implementation

///|
pub enum CherryPickStatus {
  Success
  Conflict
}

///|
pub struct CherryPickResult {
  status : CherryPickStatus
  commit_id : @git.ObjectId?
  conflicts : Array[String]
}

///|
/// Cherry-pick a single commit onto current HEAD.
pub fn cherry_pick(
  fs : &@git.FileSystem,
  rfs : &@git.RepoFileSystem,
  root : String,
  commit_id : @git.ObjectId,
  author : String,
  timestamp : Int64,
) -> CherryPickResult raise @git.GitError {
  let git_dir = join_path(root, ".git")
  // Get current HEAD
  let head = resolve_head_commit(rfs, git_dir)
  guard head is Some(head_id) else {
    raise @git.GitError::InvalidObject("HEAD not found")
  }
  let db = ObjectDb::load(rfs, git_dir)
  // Read the commit to cherry-pick
  let commit_obj = db.get(rfs, commit_id)
  guard commit_obj is Some(obj) else {
    raise @git.GitError::InvalidObject("Commit not found")
  }
  if obj.obj_type != @git.ObjectType::Commit {
    raise @git.GitError::InvalidObject("Not a commit")
  }
  let commit_info = @git.parse_commit(obj.data)
  // Get the parent of the cherry-picked commit
  if commit_info.parents.length() == 0 {
    raise @git.GitError::InvalidObject(
      "Cannot cherry-pick initial commit without parent",
    )
  }
  let parent_id = commit_info.parents[0]
  // Get file trees
  let head_files = collect_tree_files_from_commit(db, rfs, head_id)
  let commit_files = collect_tree_files(db, rfs, commit_info.tree)
  let parent_files = collect_tree_files_from_commit(db, rfs, parent_id)
  // Compute the patch (diff between parent and commit)
  let added_files : Map[String, TreeFileEntry] = {}
  let modified_files : Map[String, TreeFileEntry] = {}
  let deleted_files : Array[String] = []
  // Find added and modified files
  for entry in commit_files.iter() {
    let (path, file_entry) = entry
    match parent_files.get(path) {
      None => added_files[path] = file_entry
      Some(parent_entry) =>
        if parent_entry.id != file_entry.id {
          modified_files[path] = file_entry
        }
    }
  }
  // Find deleted files
  for entry in parent_files.iter() {
    let (path, _) = entry
    if not(commit_files.contains(path)) {
      deleted_files.push(path)
    }
  }
  // Apply the patch to head_files
  let result_files : Map[String, TreeFileEntry] = {}
  let conflicts : Array[String] = []
  // Copy head files
  for entry in head_files.iter() {
    let (path, file_entry) = entry
    result_files[path] = file_entry
  }
  // Apply added files (check for conflicts)
  for entry in added_files.iter() {
    let (path, file_entry) = entry
    if result_files.contains(path) {
      // File already exists - conflict
      conflicts.push(path)
    } else {
      result_files[path] = file_entry
    }
  }
  // Apply modified files (check for conflicts)
  for entry in modified_files.iter() {
    let (path, file_entry) = entry
    match result_files.get(path) {
      None => {
        // File doesn't exist in head - add it
        result_files[path] = file_entry
      }
      Some(head_entry) => {
        // Check if head has the same content as parent
        match parent_files.get(path) {
          Some(parent_entry) if parent_entry.id == head_entry.id => {
            // No conflict - head hasn't changed the file
            result_files[path] = file_entry
          }
          _ => {
            // Conflict - both sides modified
            conflicts.push(path)
            // Keep the cherry-picked version for now (simple approach)
            result_files[path] = file_entry
          }
        }
      }
    }
  }
  // Apply deletions (check for conflicts)
  for path in deleted_files {
    match result_files.get(path) {
      Some(head_entry) => {
        // Check if head has the same content as parent
        match parent_files.get(path) {
          Some(parent_entry) if parent_entry.id == head_entry.id => {
            // No conflict - safe to delete
            let _ = result_files.remove(path)

          }
          _ => {
            // Conflict - head modified a file that was deleted
            conflicts.push(path)
            let _ = result_files.remove(path)

          }
        }
      }
      None => () // Already deleted
    }
  }
  if conflicts.length() > 0 {
    // Write the result to worktree but don't commit
    write_worktree_from_files(db, fs, rfs, git_dir, root, result_files)
    let result_entries = tree_files_to_index(db, rfs, result_files)
    write_index_entries(fs, git_dir, result_entries)
    return { status: CherryPickStatus::Conflict, commit_id: None, conflicts }
  }
  // Write result tree
  let result_entries = tree_files_to_index(db, rfs, result_files)
  write_index_entries(fs, git_dir, result_entries)
  let result_tree = write_tree_from_index(fs, git_dir, result_entries)
  // Extract original commit message
  let commit_text = @utf8.decode_lossy(obj.data[:])
  let msg_start = commit_text.find("\n\n")
  let message = match msg_start {
    Some(idx) =>
      String::unsafe_substring(
        commit_text,
        start=idx + 2,
        end=commit_text.length(),
      )
    None => "Cherry-picked from \{commit_id.to_hex()}"
  }
  // Create new commit
  let new_commit = @git.Commit::new(
    result_tree,
    [head_id],
    author,
    timestamp,
    "+0000",
    author,
    timestamp,
    "+0000",
    message,
  )
  let (new_id, new_data) = @git.create_commit(new_commit)
  write_object_bytes(fs, git_dir, new_id, new_data)
  // Update HEAD
  update_head_ref(fs, rfs, git_dir, new_id)
  // Update worktree
  write_worktree_from_files(db, fs, rfs, git_dir, root, result_files)
  { status: CherryPickStatus::Success, commit_id: Some(new_id), conflicts: [] }
}

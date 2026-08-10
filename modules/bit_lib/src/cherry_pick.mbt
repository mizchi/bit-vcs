///| Git cherry-pick implementation

///|
pub enum CherryPickStatus {
  Success
  Conflict
}

///|
pub struct CherryPickResult {
  status : CherryPickStatus
  commit_id : @bit.ObjectId?
  conflicts : Array[String]
}

///|
/// Cherry-pick a single commit onto current HEAD.
pub fn cherry_pick(
  fs : &@bit.FileSystem,
  rfs : &@bit.RepoFileSystem,
  root : String,
  commit_id : @bit.ObjectId,
  author : String,
  timestamp : Int64,
  allow_empty? : Bool = false,
  no_commit? : Bool = false,
  message_suffix? : String = "",
  signoff_committer? : String = "",
) -> CherryPickResult raise @bit.GitError {
  let git_marker = join_path(root, ".git")
  let git_dir = if rfs.is_file(git_marker) {
    resolve_gitdir(rfs, git_marker)
  } else {
    git_marker
  }
  let db = ObjectDb::load(rfs, git_dir)
  // Read the commit to cherry-pick
  let commit_obj = db.get(rfs, commit_id)
  guard commit_obj is Some(obj) else {
    raise @bit.GitError::InvalidObject("Commit not found")
  }
  if obj.obj_type != @bit.ObjectType::Commit {
    raise @bit.GitError::InvalidObject("Not a commit")
  }
  let commit_info = @bit.parse_commit(obj.data)
  let raw_message = cherry_pick_extract_message(obj.data, commit_id)
  let msg_with_suffix = if message_suffix.length() > 0 {
    let trimmed = cherry_pick_trim_trailing_newlines(raw_message)
    trimmed + "\n" + message_suffix + "\n"
  } else {
    raw_message
  }
  let message = if signoff_committer.length() > 0 {
    commit_apply_signoff(msg_with_suffix, committer=signoff_committer)
  } else {
    msg_with_suffix
  }
  let head = resolve_head_commit(rfs, git_dir)
  if head is None {
    if commit_info.parents.length() == 0 {
      let result_files = collect_tree_files(db, rfs, commit_info.tree)
      return cherry_pick_write_result_commit(
        db,
        fs,
        rfs,
        root,
        git_dir,
        result_files,
        [],
        author,
        timestamp,
        message,
      )
    }
    ignore(allow_empty)
    raise @bit.GitError::InvalidObject("HEAD not found")
  }
  guard head is Some(head_id) else {
    raise @bit.GitError::InvalidObject("HEAD not found")
  }
  // Get the parent of the cherry-picked commit
  if commit_info.parents.length() == 0 {
    let result_files = collect_tree_files(db, rfs, commit_info.tree)
    return cherry_pick_write_result_commit(
      db,
      fs,
      rfs,
      root,
      git_dir,
      result_files,
      [head_id],
      author,
      timestamp,
      message,
    )
  }
  let parent_id = commit_info.parents[0]
  // Get file trees
  let head_files = collect_tree_files_from_commit(db, rfs, head_id)
  let commit_files = collect_tree_files(db, rfs, commit_info.tree)
  let parent_files = collect_tree_files_from_commit(db, rfs, parent_id)
  // Compute the patch (diff between parent and commit)
  let added_files : Map[String, TreeFileEntry] = Map([])
  let modified_files : Map[String, TreeFileEntry] = Map([])
  let deleted_files : Array[String] = []
  // Find added and modified files
  for entry in commit_files.iter() {
    let (path, file_entry) = entry
    match parent_files.get(path) {
      None => added_files[path] = file_entry
      Some(parent_entry) =>
        if parent_entry.id != file_entry.id ||
          parent_entry.mode != file_entry.mode {
          modified_files[path] = file_entry
        }
    }
  }
  // Find deleted files
  for entry in parent_files.iter() {
    let (path, _) = entry
    if !commit_files.contains(path) {
      deleted_files.push(path)
    }
  }
  // Apply the patch to head_files
  let result_files : Map[String, TreeFileEntry] = Map([])
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
      None =>
        // File doesn't exist in head - add it
        result_files[path] = file_entry
      Some(head_entry) =>
        // Check if head has the same content and mode as parent
        match parent_files.get(path) {
          Some(parent_entry) if parent_entry.id == head_entry.id &&
            parent_entry.mode == head_entry.mode =>
            // No conflict - head hasn't changed the file
            result_files[path] = file_entry
          _ => {
            // Conflict - both sides modified
            conflicts.push(path)
            // Keep the cherry-picked version for now (simple approach)
            result_files[path] = file_entry
          }
        }
    }
  }
  // Apply deletions (check for conflicts)
  for path in deleted_files {
    match result_files.get(path) {
      Some(head_entry) =>
        // Check if head has the same content and mode as parent
        match parent_files.get(path) {
          Some(parent_entry) if parent_entry.id == head_entry.id &&
            parent_entry.mode == head_entry.mode => {
            // No conflict - safe to delete
            let _ = result_files.remove(path)
          }
          _ => {
            // Conflict - head modified a file that was deleted
            conflicts.push(path)
            let _ = result_files.remove(path)
          }
        }
      None => () // Already deleted
    }
  }
  if conflicts.length() > 0 {
    // Write the result to worktree but don't commit
    write_worktree_from_files(db, fs, rfs, root, git_dir, result_files)
    let result_entries = tree_files_to_index(db, rfs, result_files)
    write_index_entries(fs, git_dir, result_entries)
    return { status: CherryPickStatus::Conflict, commit_id: None, conflicts }
  }
  if no_commit {
    // Apply changes to worktree and index but skip creating a commit
    write_worktree_from_files(db, fs, rfs, root, git_dir, result_files)
    let result_entries = tree_files_to_index(db, rfs, result_files)
    write_index_entries(fs, git_dir, result_entries)
    return { status: CherryPickStatus::Success, commit_id: None, conflicts: [] }
  }
  cherry_pick_write_result_commit(
    db,
    fs,
    rfs,
    root,
    git_dir,
    result_files,
    [head_id],
    author,
    timestamp,
    message,
  )
}

///|
fn cherry_pick_extract_message(
  data : Bytes,
  commit_id : @bit.ObjectId,
) -> String {
  let commit_text = @utf8.decode_lossy(data[:])
  let msg_start = commit_text.find("\n\n")
  match msg_start {
    Some(idx) =>
      String::unsafe_substring(
        commit_text,
        start=idx + 2,
        end=commit_text.length(),
      )
    None => "Cherry-picked from \{commit_id.to_hex()}"
  }
}

///|
fn cherry_pick_write_result_commit(
  db : ObjectDb,
  fs : &@bit.FileSystem,
  rfs : &@bit.RepoFileSystem,
  root : String,
  git_dir : String,
  result_files : Map[String, TreeFileEntry],
  parents : Array[@bit.ObjectId],
  author : String,
  timestamp : Int64,
  message : String,
) -> CherryPickResult raise @bit.GitError {
  let object_git_dir = resolve_common_git_dir(rfs, git_dir)
  let result_entries = tree_files_to_index(db, rfs, result_files)
  write_index_entries(fs, git_dir, result_entries)
  let result_tree = write_tree_from_index(fs, rfs, git_dir, result_entries)
  let new_commit = @bit.Commit::new(
    result_tree, parents, author, timestamp, "+0000", author, timestamp, "+0000",
    message,
  )
  let (new_id, new_data) = @bit.create_commit(new_commit)
  write_object_bytes(fs, object_git_dir, new_id, new_data)
  update_head_ref(fs, rfs, git_dir, new_id)
  write_worktree_from_files(db, fs, rfs, root, git_dir, result_files)
  { status: CherryPickStatus::Success, commit_id: Some(new_id), conflicts: [] }
}

///|
fn cherry_pick_trim_trailing_newlines(s : String) -> String {
  let chars = s.to_array()
  let mut end = chars.length()
  while end > 0 && (chars[end - 1] == '\n' || chars[end - 1] == '\r') {
    end -= 1
  }
  let result = StringBuilder::new()
  for i in 0..<end {
    result.write_char(chars[i])
  }
  result.to_string()
}

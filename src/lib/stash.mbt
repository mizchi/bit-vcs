///| Git stash implementation

///|
pub struct StashEntry {
  id : @git.ObjectId
  message : String
}

///|
/// List all stash entries.
pub fn stash_list(
  fs : &@git.RepoFileSystem,
  git_dir : String,
) -> Array[StashEntry] raise @git.GitError {
  let stash_ref_path = git_dir + "/refs/stash"
  if not(fs.is_file(stash_ref_path)) {
    return []
  }
  // Read reflog for stash
  let reflog_path = git_dir + "/logs/refs/stash"
  if not(fs.is_file(reflog_path)) {
    // Just return the current stash
    let content = @utf8.decode_lossy(fs.read_file(stash_ref_path)[:])
    let hex = content.trim_end(chars="\n\r ").to_string()
    let id = @git.ObjectId::from_hex(hex)
    return [{ id, message: "WIP on HEAD" }]
  }
  let log_content = @utf8.decode_lossy(fs.read_file(reflog_path)[:])
  let entries : Array[StashEntry] = []
  for line_view in log_content.split("\n") {
    let line = line_view.to_string()
    if line.length() == 0 {
      continue
    }
    // Format: <old-sha> <new-sha> <name> <email> <timestamp> <tz>\t<message>
    let tab_idx = line.find("\t")
    match tab_idx {
      None => continue
      Some(idx) => {
        let prefix = String::unsafe_substring(line, start=0, end=idx)
        let message = String::unsafe_substring(
          line,
          start=idx + 1,
          end=line.length(),
        )
        let parts = prefix.split(" ").map(v => v.to_string()).collect()
        if parts.length() >= 2 {
          let new_sha = parts[1]
          let id = @git.ObjectId::from_hex(new_sha) catch { _ => continue }
          entries.push({ id, message })
        }
      }
    }
  }
  // Reverse to show newest first
  entries.rev_in_place()
  entries
}

///|
/// Push current changes to stash.
pub async fn stash_push(
  fs : &@git.FileSystem,
  rfs : &@git.RepoFileSystem,
  root : String,
  message : String,
  author : String,
  timestamp : Int64,
) -> @git.ObjectId? raise @git.GitError {
  let git_dir = join_path(root, ".git")
  // Check if there are changes
  let st = status(rfs, root)
  if st.staged_added.length() == 0 &&
    st.staged_modified.length() == 0 &&
    st.staged_deleted.length() == 0 &&
    st.unstaged_modified.length() == 0 &&
    st.unstaged_deleted.length() == 0 {
    return None
  }
  // Get current HEAD
  let head = resolve_head_commit(rfs, git_dir)
  guard head is Some(head_id) else {
    raise @git.GitError::InvalidObject("HEAD not found")
  }
  // Create tree from current index
  let index_entries = read_index_entries(rfs, git_dir)
  let index_tree = write_tree_from_index(fs, git_dir, index_entries)
  // Create tree from worktree (also writes blobs to object store)
  let worktree_entries = build_worktree_index(
    fs, rfs, git_dir, root, index_entries,
  )
  let worktree_tree = write_tree_from_index(fs, git_dir, worktree_entries)
  // Create index commit (index state)
  let index_commit = @git.Commit::new(
    index_tree,
    [head_id],
    author,
    timestamp,
    "+0000",
    author,
    timestamp,
    "+0000",
    "index on HEAD",
  )
  let (index_commit_id, index_commit_data) = @git.create_commit(index_commit)
  write_object_bytes(fs, git_dir, index_commit_id, index_commit_data)
  // Create stash commit (worktree state) with 2 parents: HEAD and index commit
  let stash_msg = if message.length() > 0 { message } else { "WIP on HEAD" }
  let stash_commit = @git.Commit::new(
    worktree_tree,
    [head_id, index_commit_id],
    author,
    timestamp,
    "+0000",
    author,
    timestamp,
    "+0000",
    stash_msg,
  )
  let (stash_id, stash_data) = @git.create_commit(stash_commit)
  write_object_bytes(fs, git_dir, stash_id, stash_data)
  // Update refs/stash
  let stash_ref_path = git_dir + "/refs/stash"
  // Read old stash id for reflog
  let old_id = if rfs.is_file(stash_ref_path) {
    let content = @utf8.decode_lossy(rfs.read_file(stash_ref_path)[:])
    let hex = content.trim_end(chars="\n\r ").to_string()
    @git.ObjectId::from_hex(hex) catch {
      _ => @git.ObjectId::zero()
    }
  } else {
    @git.ObjectId::zero()
  }
  fs.write_string(stash_ref_path, stash_id.to_hex() + "\n")
  // Append to reflog
  let reflog_dir = git_dir + "/logs/refs"
  fs.mkdir_p(reflog_dir)
  let reflog_path = reflog_dir + "/stash"
  let reflog_entry = "\{old_id.to_hex()} \{stash_id.to_hex()} \{author} \{timestamp} +0000\t\{stash_msg}\n"
  let existing = if rfs.is_file(reflog_path) {
    @utf8.decode_lossy(rfs.read_file(reflog_path)[:])
  } else {
    ""
  }
  fs.write_string(reflog_path, existing + reflog_entry)
  // Reset worktree to HEAD
  let db = ObjectDb::load(rfs, git_dir)
  let head_files = collect_tree_files_from_commit(db, rfs, head_id)
  write_worktree_from_files(db, fs, rfs, root, git_dir, head_files)
  // Reset index to HEAD
  let head_entries = tree_files_to_index(db, rfs, head_files)
  write_index_entries(fs, git_dir, head_entries)
  Some(stash_id)
}

///|
fn build_worktree_index(
  fs : &@git.FileSystem,
  rfs : &@git.RepoFileSystem,
  git_dir : String,
  root : String,
  index_entries : Array[IndexEntry],
) -> Array[IndexEntry] raise @git.GitError {
  let result : Array[IndexEntry] = []
  for e in index_entries {
    let abs = join_path(root, e.path)
    if rfs.is_file(abs) {
      let content = rfs.read_file(abs)
      // Write blob to object store
      let id = write_loose_object(fs, git_dir, @git.ObjectType::Blob, content)
      result.push({
        path: e.path,
        id,
        mode: e.mode,
        size: content.length(),
        mtime_sec: 0,
        mtime_nsec: 0,
      })
    }
    // Skip deleted files
  }
  result
}

///|
/// Apply stash entry (optionally dropping it).
pub fn stash_apply(
  fs : &@git.FileSystem,
  rfs : &@git.RepoFileSystem,
  root : String,
  index : Int,
  drop : Bool,
) -> Unit raise @git.GitError {
  let git_dir = join_path(root, ".git")
  let entries = stash_list(rfs, git_dir)
  if index >= entries.length() {
    raise @git.GitError::InvalidObject("No stash entry at index \{index}")
  }
  let entry = entries[index]
  // Get stash commit
  let db = ObjectDb::load(rfs, git_dir)
  let obj = db.get(rfs, entry.id)
  guard obj is Some(stash_obj) else {
    raise @git.GitError::InvalidObject("Stash object not found")
  }
  if stash_obj.obj_type != @git.ObjectType::Commit {
    raise @git.GitError::InvalidObject("Invalid stash entry")
  }
  let commit_info = @git.parse_commit(stash_obj.data)
  // Apply worktree state from stash
  let stash_files = collect_tree_files(db, rfs, commit_info.tree)
  write_worktree_from_files(
    db,
    fs,
    rfs,
    root,
    git_dir,
    stash_files,
    remove_missing=false,
  )
  // Also update index from first parent's second parent (index commit) if exists
  if commit_info.parents.length() >= 2 {
    let index_commit_id = commit_info.parents[1]
    let index_obj = db.get(rfs, index_commit_id)
    match index_obj {
      Some(idx_obj) if idx_obj.obj_type == @git.ObjectType::Commit => {
        let idx_info = @git.parse_commit(idx_obj.data)
        let idx_files = collect_tree_files(db, rfs, idx_info.tree)
        let idx_entries = tree_files_to_index(db, rfs, idx_files)
        write_index_entries(fs, git_dir, idx_entries)
      }
      _ => ()
    }
  }
  if drop {
    stash_drop_at(fs, rfs, git_dir, index)
  }
}

///|
/// Drop stash entry at index.
pub fn stash_drop(
  fs : &@git.FileSystem,
  rfs : &@git.RepoFileSystem,
  root : String,
  index : Int,
) -> Unit raise @git.GitError {
  let git_dir = join_path(root, ".git")
  stash_drop_at(fs, rfs, git_dir, index)
}

///|
fn stash_drop_at(
  fs : &@git.FileSystem,
  rfs : &@git.RepoFileSystem,
  git_dir : String,
  index : Int,
) -> Unit raise @git.GitError {
  let entries = stash_list(rfs, git_dir)
  if index >= entries.length() {
    raise @git.GitError::InvalidObject("No stash entry at index \{index}")
  }
  // Rebuild reflog without the entry
  let reflog_path = git_dir + "/logs/refs/stash"
  if not(rfs.is_file(reflog_path)) {
    // Only one entry, just remove refs/stash
    let stash_ref = git_dir + "/refs/stash"
    fs.remove_file(stash_ref)
    return ()
  }
  let log_content = @utf8.decode_lossy(rfs.read_file(reflog_path)[:])
  let lines : Array[String] = []
  for line_view in log_content.split("\n") {
    let line = line_view.to_string()
    if line.length() > 0 {
      lines.push(line)
    }
  }
  // Reverse to get newest first, then remove at index
  lines.rev_in_place()
  if index < lines.length() {
    let _ = lines.remove(index)
  }
  if lines.length() == 0 {
    // No more entries
    fs.remove_file(reflog_path)
    fs.remove_file(git_dir + "/refs/stash")
  } else {
    // Reverse back and write
    lines.rev_in_place()
    let new_content = lines
      .iter()
      .fold(init="", (acc, line) => acc + line + "\n")
    fs.write_string(reflog_path, new_content)
    // Update refs/stash to newest entry (last line has newest)
    let newest = lines[lines.length() - 1]
    let parts = newest.split(" ").map(v => v.to_string()).collect()
    if parts.length() >= 2 {
      let new_id = parts[1]
      fs.write_string(git_dir + "/refs/stash", new_id + "\n")
    }
  }
}

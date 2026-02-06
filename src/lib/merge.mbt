///| Merge implementation with content-level 3-way merge

///|
pub enum MergeStatus {
  AlreadyUpToDate
  FastForward
  Merged
  Conflicted
}

///|
pub struct MergeResult {
  status : MergeStatus
  commit_id : @git.ObjectId?
  conflicts : Array[String]
}

///|
pub fn merge(
  fs : &@git.FileSystem,
  rfs : &@git.RepoFileSystem,
  root : String,
  target : @git.ObjectId,
  message : String,
  author : String,
  timestamp : Int64,
) -> MergeResult raise @git.GitError {
  let git_dir = join_path(root, ".git")
  let head = match resolve_head_commit(rfs, git_dir) {
    None => raise @git.GitError::InvalidObject("HEAD not found")
    Some(id) => id
  }
  if head == target {
    return { status: AlreadyUpToDate, commit_id: Some(head), conflicts: [] }
  }
  let db = ObjectDb::load(rfs, git_dir)
  if merge_is_ancestor(db, rfs, head, target) {
    let _ = reset(fs, rfs, root, target.to_hex(), ResetMode::Hard)
    return { status: FastForward, commit_id: Some(target), conflicts: [] }
  }
  if merge_is_ancestor(db, rfs, target, head) {
    return { status: AlreadyUpToDate, commit_id: Some(head), conflicts: [] }
  }
  let base = merge_find_base(db, rfs, head, target)
  let base_files = match base {
    None => {}
    Some(id) => collect_tree_files_from_commit(db, rfs, id)
  }
  let ours = collect_tree_files_from_commit(db, rfs, head)
  let theirs = collect_tree_files_from_commit(db, rfs, target)
  let file_result = merge_files(base_files, ours, theirs)
  let merged = file_result.merged
  let conflicts = file_result.conflicts
  // Try content-level merge for files modified on both sides
  for candidate in file_result.needs_content_merge {
    let base_content = match candidate.base_id {
      Some(id) => merge_get_blob_text(db, rfs, id)
      None => ""
    }
    let ours_content = merge_get_blob_text(db, rfs, candidate.ours_id)
    let theirs_content = merge_get_blob_text(db, rfs, candidate.theirs_id)
    // Skip binary files
    let ours_data = merge_get_blob_data(db, rfs, candidate.ours_id)
    let theirs_data = merge_get_blob_data(db, rfs, candidate.theirs_id)
    if is_binary_content(ours_data) || is_binary_content(theirs_data) {
      conflicts.push(candidate.path)
      continue
    }
    let result = content_merge(
      base_content,
      ours_content,
      theirs_content,
      ContentMergeOptions::default(),
    )
    if result.has_conflicts {
      // Write conflict markers to worktree
      let full_path = join_path(root, candidate.path)
      let dir = rebase_parent_dir(full_path)
      fs.mkdir_p(dir)
      fs.write_string(full_path, result.content)
      conflicts.push(candidate.path)
    } else {
      // Clean merge - create new blob
      let content_bytes = @utf8.encode(result.content)
      let (blob_id, compressed) = @git.create_blob(content_bytes)
      write_object_bytes(fs, git_dir, blob_id, compressed)
      merged[candidate.path] = { id: blob_id, mode: candidate.mode }
    }
  }
  if conflicts.length() > 0 {
    conflicts.sort()
    return { status: Conflicted, commit_id: None, conflicts }
  }
  write_worktree_from_files(
    db,
    fs,
    rfs,
    root,
    git_dir,
    merged,
    remove_missing=true,
  )
  let entries = tree_files_to_index(db, rfs, merged)
  write_index_entries(fs, git_dir, entries)
  let tree_id = write_tree_from_index(fs, git_dir, entries)
  let commit = @git.Commit::new(
    tree_id,
    [head, target],
    author,
    timestamp,
    "+0000",
    author,
    timestamp,
    "+0000",
    message,
  )
  let (commit_id, compressed) = @git.create_commit(commit)
  write_object_bytes(fs, git_dir, commit_id, compressed)
  update_head_ref(fs, rfs, git_dir, commit_id)
  { status: Merged, commit_id: Some(commit_id), conflicts: [] }
}

///|
fn merge_is_ancestor(
  db : ObjectDb,
  fs : &@git.RepoFileSystem,
  ancestor : @git.ObjectId,
  commit_id : @git.ObjectId,
) -> Bool raise @git.GitError {
  let stack : Array[@git.ObjectId] = [commit_id]
  let seen : Map[String, Bool] = {}
  while stack.length() > 0 {
    let id = match stack.pop() {
      None => raise @git.GitError::InvalidObject("Empty stack")
      Some(v) => v
    }
    let hex = id.to_hex()
    if seen.contains(hex) {
      continue
    }
    seen[hex] = true
    if id == ancestor {
      return true
    }
    let parents = merge_commit_parents(db, fs, id)
    for p in parents {
      stack.push(p)
    }
  }
  false
}

///|
fn merge_find_base(
  db : ObjectDb,
  fs : &@git.RepoFileSystem,
  a : @git.ObjectId,
  b : @git.ObjectId,
) -> @git.ObjectId? raise @git.GitError {
  let seen : Map[String, Bool] = {}
  let stack_a : Array[@git.ObjectId] = [a]
  while stack_a.length() > 0 {
    let id = match stack_a.pop() {
      None => raise @git.GitError::InvalidObject("Empty stack")
      Some(v) => v
    }
    let hex = id.to_hex()
    if seen.contains(hex) {
      continue
    }
    seen[hex] = true
    let parents = merge_commit_parents(db, fs, id)
    for p in parents {
      stack_a.push(p)
    }
  }
  let stack_b : Array[@git.ObjectId] = [b]
  while stack_b.length() > 0 {
    let id = match stack_b.pop() {
      None => raise @git.GitError::InvalidObject("Empty stack")
      Some(v) => v
    }
    let hex = id.to_hex()
    if seen.contains(hex) {
      return Some(id)
    }
    let parents = merge_commit_parents(db, fs, id)
    for p in parents {
      stack_b.push(p)
    }
  }
  None
}

///|
fn merge_commit_parents(
  db : ObjectDb,
  fs : &@git.RepoFileSystem,
  commit_id : @git.ObjectId,
) -> Array[@git.ObjectId] raise @git.GitError {
  let obj = db.get(fs, commit_id)
  match obj {
    None => raise @git.GitError::InvalidObject("Missing commit object")
    Some(o) => {
      if o.obj_type != @git.ObjectType::Commit {
        raise @git.GitError::InvalidObject("Object is not a commit")
      }
      let info = @git.parse_commit(o.data)
      info.parents
    }
  }
}

///|
priv struct MergeFilesResult {
  merged : Map[String, TreeFileEntry]
  conflicts : Array[String]
  needs_content_merge : Array[ContentMergeCandidate]
}

///|
priv struct ContentMergeCandidate {
  path : String
  base_id : @git.ObjectId?
  ours_id : @git.ObjectId
  theirs_id : @git.ObjectId
  mode : Int
}

///|
fn merge_files(
  base : Map[String, TreeFileEntry],
  ours : Map[String, TreeFileEntry],
  theirs : Map[String, TreeFileEntry],
) -> MergeFilesResult {
  let merged : Map[String, TreeFileEntry] = {}
  let conflicts : Array[String] = []
  let needs_content_merge : Array[ContentMergeCandidate] = []
  let all_paths : Map[String, Bool] = {}
  for item in base.to_array() {
    let (path, _) = item
    all_paths[path] = true
  }
  for item in ours.to_array() {
    let (path, _) = item
    all_paths[path] = true
  }
  for item in theirs.to_array() {
    let (path, _) = item
    all_paths[path] = true
  }
  for item in all_paths.to_array() {
    let (path, _) = item
    let b = base.get(path)
    let o = ours.get(path)
    let t = theirs.get(path)
    if merge_entry_eq(o, t) {
      match o {
        None => ()
        Some(v) => merged[path] = v
      }
    } else if merge_entry_eq(o, b) {
      match t {
        None => ()
        Some(v) => merged[path] = v
      }
    } else if merge_entry_eq(t, b) {
      match o {
        None => ()
        Some(v) => merged[path] = v
      }
    } else {
      // Both sides modified - try content merge if both have the file
      match (o, t) {
        (Some(ours_entry), Some(theirs_entry)) => {
          let base_id = match b {
            Some(base_entry) => Some(base_entry.id)
            None => None
          }
          needs_content_merge.push({
            path,
            base_id,
            ours_id: ours_entry.id,
            theirs_id: theirs_entry.id,
            mode: ours_entry.mode,
          })
        }
        _ =>
          // One side deleted, other modified - file-level conflict
          conflicts.push(path)
      }
    }
  }
  { merged, conflicts, needs_content_merge }
}

///|
fn merge_get_blob_text(
  db : ObjectDb,
  fs : &@git.RepoFileSystem,
  id : @git.ObjectId,
) -> String {
  get_blob_content(db, fs, id)
}

///|
fn merge_get_blob_data(
  db : ObjectDb,
  fs : &@git.RepoFileSystem,
  id : @git.ObjectId,
) -> Bytes {
  let obj = db.get(fs, id) catch { _ => return Bytes::default() }
  match obj {
    Some(o) =>
      if o.obj_type == @git.ObjectType::Blob {
        o.data
      } else {
        Bytes::default()
      }
    None => Bytes::default()
  }
}

///|
fn merge_entry_eq(a : TreeFileEntry?, b : TreeFileEntry?) -> Bool {
  match (a, b) {
    (None, None) => true
    (Some(x), Some(y)) => x.id == y.id && x.mode == y.mode
    _ => false
  }
}

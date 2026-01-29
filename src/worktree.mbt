///| Working tree operations: status, add, commit

///|
pub struct Status {
  staged_added : Array[String]
  staged_modified : Array[String]
  staged_deleted : Array[String]
  unstaged_modified : Array[String]
  unstaged_deleted : Array[String]
  untracked : Array[String]
}

///|
/// Get status similar to `git status --porcelain` buckets.
pub fn status(fs : &RepoFileSystem, root : String) -> Status raise GitError {
  let git_dir = join_path(root, ".git")
  let index_entries = read_index_entries(fs, git_dir)
  let index_map : Map[String, IndexEntry] = {}
  for e in index_entries {
    index_map[e.path] = e
  }
  let untracked : Array[String] = []
  let unstaged_modified : Array[String] = []
  let unstaged_deleted : Array[String] = []
  let files = list_working_files(fs, root)
  let visited : Map[String, Bool] = {}
  for path in files {
    visited[path] = true
    match index_map.get(path) {
      None => untracked.push(path)
      Some(entry) => {
        let abs = join_path(root, path)
        let content = fs.read_file(abs)
        let id = hash_blob(content)
        if id != entry.id {
          unstaged_modified.push(path)
        }
      }
    }
  }
  for item in index_map.to_array() {
    let (path, _) = item
    if not(visited.contains(path)) {
      let abs = join_path(root, path)
      if not(fs.is_file(abs)) {
        unstaged_deleted.push(path)
      }
    }
  }
  let head_entries = read_head_tree_entries(fs, git_dir)
  let staged_added : Array[String] = []
  let staged_modified : Array[String] = []
  let staged_deleted : Array[String] = []
  for item in index_map.to_array() {
    let (path, entry) = item
    match head_entries.get(path) {
      None => staged_added.push(path)
      Some(h) =>
        if h.id != entry.id || h.mode != entry.mode {
          staged_modified.push(path)
        }
    }
  }
  for item in head_entries.to_array() {
    let (path, _) = item
    if not(index_map.contains(path)) {
      staged_deleted.push(path)
    }
  }
  staged_added.sort()
  staged_modified.sort()
  staged_deleted.sort()
  unstaged_modified.sort()
  unstaged_deleted.sort()
  untracked.sort()
  {
    staged_added,
    staged_modified,
    staged_deleted,
    unstaged_modified,
    unstaged_deleted,
    untracked,
  }
}

///|
/// Format status in porcelain-like lines.
pub fn status_porcelain(
  fs : &RepoFileSystem,
  root : String,
) -> Array[String] raise GitError {
  let s = status(fs, root)
  status_porcelain_from(s)
}

///|
pub fn status_porcelain_from(s : Status) -> Array[String] {
  let xmap : Map[String, Char] = {}
  let ymap : Map[String, Char] = {}
  for p in s.staged_added {
    xmap[p] = 'A'
  }
  for p in s.staged_modified {
    xmap[p] = 'M'
  }
  for p in s.staged_deleted {
    xmap[p] = 'D'
  }
  for p in s.unstaged_modified {
    ymap[p] = 'M'
  }
  for p in s.unstaged_deleted {
    ymap[p] = 'D'
  }
  let paths : Map[String, Bool] = {}
  for p in s.staged_added {
    paths[p] = true
  }
  for p in s.staged_modified {
    paths[p] = true
  }
  for p in s.staged_deleted {
    paths[p] = true
  }
  for p in s.unstaged_modified {
    paths[p] = true
  }
  for p in s.unstaged_deleted {
    paths[p] = true
  }
  let out : Array[String] = []
  let list : Array[String] = []
  for item in paths.to_array() {
    let (p, _) = item
    list.push(p)
  }
  list.sort()
  for p in list {
    let x = match xmap.get(p) {
      Some(c) => c
      None => ' '
    }
    let y = match ymap.get(p) {
      Some(c) => c
      None => ' '
    }
    out.push("\{x}\{y} \{p}")
  }
  for p in s.untracked {
    out.push("?? \{p}")
  }
  out
}

///|
/// Add files to index (like `git add`).
pub fn add_paths(
  fs : &FileSystem,
  rfs : &RepoFileSystem,
  root : String,
  paths : Array[String],
) -> Unit raise GitError {
  let git_dir = join_path(root, ".git")
  let entries = read_index_entries(rfs, git_dir)
  let map : Map[String, IndexEntry] = {}
  for e in entries {
    map[e.path] = e
  }
  let all_paths = expand_paths(rfs, root, paths)
  for path in all_paths {
    let abs = join_path(root, path)
    if rfs.is_file(abs) {
      let content = rfs.read_file(abs)
      let id = write_loose_object(fs, git_dir, ObjectType::Blob, content)
      let size = content.length()
      map[path] = { path, id, mode: default_file_mode(), size }
    } else {
      map.remove(path)
    }
  }
  let out : Array[IndexEntry] = []
  for item in map.to_array() {
    let (_, entry) = item
    out.push(entry)
  }
  write_index_entries(fs, git_dir, out)
}

///|
/// Commit current index and update HEAD.
pub fn commit(
  fs : &FileSystem,
  rfs : &RepoFileSystem,
  root : String,
  message : String,
  author : String,
  timestamp : Int64,
) -> ObjectId raise GitError {
  let git_dir = join_path(root, ".git")
  let entries = read_index_entries(rfs, git_dir)
  if entries.length() == 0 {
    raise GitError::InvalidObject("Empty index")
  }
  let tree_id = write_tree_from_index(fs, git_dir, entries)
  let parent = resolve_head_commit(rfs, git_dir)
  let parents = match parent {
    Some(p) => [p]
    None => []
  }
  let commit = Commit::new(
    tree_id, parents, author, timestamp, "+0000", author, timestamp, "+0000", message,
  )
  let (commit_id, compressed) = create_commit(commit)
  write_object_bytes(fs, git_dir, commit_id, compressed)
  update_head_ref(fs, rfs, git_dir, commit_id)
  commit_id
}

///|
fn expand_paths(
  fs : &RepoFileSystem,
  root : String,
  paths : Array[String],
) -> Array[String] raise GitError {
  let result : Array[String] = []
  let all = list_working_files(fs, root)
  for p in paths {
    let path = normalize_rel_path(p)
    let abs = join_path(root, path)
    if fs.is_dir(abs) {
      let prefix = if path.has_suffix("/") { path } else { path + "/" }
      for f in all {
        if f.has_prefix(prefix) {
          result.push(f)
        }
      }
    } else {
      result.push(path)
    }
  }
  result
}

///|
fn normalize_rel_path(path : String) -> String {
  if path.has_prefix("./") {
    String::unsafe_substring(path, start=2, end=path.length())
  } else {
    path
  }
}

///|
fn default_file_mode() -> Int {
  33188 // 0o100644
}

///|
pub fn write_loose_object(
  fs : &FileSystem,
  git_dir : String,
  obj_type : ObjectType,
  content : Bytes,
) -> ObjectId raise GitError {
  let (id, compressed) = create_object(obj_type, content)
  write_object_bytes(fs, git_dir, id, compressed)
  id
}

///|
pub fn write_object_bytes(
  fs : &FileSystem,
  git_dir : String,
  id : ObjectId,
  compressed : Bytes,
) -> Unit raise GitError {
  let hex = id.to_hex()
  let dir = join_path(
    git_dir,
    "objects/" + String::unsafe_substring(hex, start=0, end=2),
  )
  fs.mkdir_p(dir)
  let path = join_path(
    git_dir,
    "objects/" +
    String::unsafe_substring(hex, start=0, end=2) +
    "/" +
    String::unsafe_substring(hex, start=2, end=hex.length()),
  )
  fs.write_file(path, compressed)
}

///|
pub fn resolve_head_commit(
  fs : &RepoFileSystem,
  git_dir : String,
) -> ObjectId? raise GitError {
  match read_head_ref(fs, git_dir) {
    Branch(name) => resolve_ref(fs, git_dir, "refs/heads/" + name)
    Detached(id) => Some(id)
  }
}

///|
pub fn update_head_ref(
  fs : &FileSystem,
  rfs : &RepoFileSystem,
  git_dir : String,
  commit_id : ObjectId,
) -> Unit raise GitError {
  let head_path = join_path(git_dir, "HEAD")
  let head = read_head_ref(rfs, git_dir) catch {
    _ => HeadRef::Detached(commit_id)
  }
  match head {
    Branch(name) => {
      let ref_path = join_path(git_dir, "refs/heads/" + name)
      let dir = parent_dir(ref_path)
      fs.mkdir_p(dir)
      fs.write_string(ref_path, commit_id.to_hex() + "\n")
    }
    Detached(_) => fs.write_string(head_path, commit_id.to_hex() + "\n")
  }
}

///|
pub fn write_tree_from_index(
  fs : &FileSystem,
  git_dir : String,
  entries : Array[IndexEntry],
) -> ObjectId raise GitError {
  let rel_entries = entries.map(fn(e) { e })
  write_tree_from_entries(fs, git_dir, rel_entries)
}

///|
fn write_tree_from_entries(
  fs : &FileSystem,
  git_dir : String,
  entries : Array[IndexEntry],
) -> ObjectId raise GitError {
  let file_entries : Array[TreeEntry] = []
  let dir_map : Map[String, Array[IndexEntry]] = {}
  for e in entries {
    match split_first(e.path) {
      (name, None) => {
        let mode = mode_to_string(e.mode)
        file_entries.push(TreeEntry::new(mode, name, e.id))
      }
      (name, Some(rest)) =>
        match dir_map.get(name) {
          Some(list) =>
            list.push({ path: rest, id: e.id, mode: e.mode, size: e.size })
          None =>
            dir_map[name] = [
              { path: rest, id: e.id, mode: e.mode, size: e.size },
            ]
        }
    }
  }
  for item in dir_map.to_array() {
    let (dir_name, list) = item
    let sub_id = write_tree_from_entries(fs, git_dir, list)
    file_entries.push(TreeEntry::new("040000", dir_name, sub_id))
  }
  file_entries.sort_by(fn(a, b) { String::compare(a.name, b.name) })
  let (tree_id, compressed) = create_tree(file_entries)
  write_object_bytes(fs, git_dir, tree_id, compressed)
  tree_id
}

///|
fn split_first(path : String) -> (String, String?) {
  match path.find("/") {
    None => (path, None)
    Some(idx) => {
      let name = String::unsafe_substring(path, start=0, end=idx)
      let rest = String::unsafe_substring(
        path,
        start=idx + 1,
        end=path.length(),
      )
      (name, Some(rest))
    }
  }
}

///|
fn mode_to_string(mode : Int) -> String {
  if mode == default_file_mode() {
    "100644"
  } else {
    to_octal_string(mode)
  }
}

///|
fn to_octal_string(value : Int) -> String {
  if value == 0 {
    return "0"
  }
  let digits : Array[Char] = []
  let mut v = value
  while v > 0 {
    let d = v % 8
    digits.push((d + '0'.to_int()).unsafe_to_char())
    v = v / 8
  }
  let rev = digits.rev()
  let sb = StringBuilder::new()
  for c in rev {
    sb.write_char(c)
  }
  sb.to_string()
}

///|
fn read_head_tree_entries(
  fs : &RepoFileSystem,
  git_dir : String,
) -> Map[String, HeadEntry] raise GitError {
  let result : Map[String, HeadEntry] = {}
  let head = resolve_head_commit(fs, git_dir)
  match head {
    None => return result
    Some(commit_id) => {
      let db = ObjectDb::load(fs, git_dir)
      let commit_obj = db.get(fs, commit_id)
      match commit_obj {
        None => return result
        Some(obj) => {
          if obj.obj_type != ObjectType::Commit {
            raise GitError::InvalidObject("Object is not a commit")
          }
          let info = parse_commit(obj.data)
          collect_tree_entries_db(db, fs, info.tree, "", result)
        }
      }
    }
  }
  result
}

///|
priv struct HeadEntry {
  id : ObjectId
  mode : Int
}

///|
fn collect_tree_entries_db(
  db : ObjectDb,
  fs : &RepoFileSystem,
  tree_id : ObjectId,
  prefix : String,
  out : Map[String, HeadEntry],
) -> Unit raise GitError {
  let tree_obj = db.get(fs, tree_id)
  match tree_obj {
    None => raise GitError::InvalidObject("Missing tree object")
    Some(obj) => {
      if obj.obj_type != ObjectType::Tree {
        raise GitError::InvalidObject("Object is not a tree")
      }
      let entries = parse_tree(obj.data)
      for entry in entries {
        let path = if prefix.length() == 0 {
          entry.name
        } else {
          prefix + "/" + entry.name
        }
        if is_tree_mode(entry.mode) {
          collect_tree_entries_db(db, fs, entry.id, path, out)
        } else {
          let mode = worktree_parse_octal(entry.mode)
          out[path] = { id: entry.id, mode }
        }
      }
    }
  }
}

///|
fn worktree_parse_octal(s : String) -> Int {
  let mut result = 0
  for c in s {
    if c < '0' || c > '7' {
      continue
    }
    result = result * 8 + (c.to_int() - '0'.to_int())
  }
  result
}

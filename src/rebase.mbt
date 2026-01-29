///| Rebase and fast-forward helpers

///|
pub fn fast_forward_to(
  fs : &FileSystem,
  rfs : &RepoFileSystem,
  root : String,
  target : ObjectId,
) -> Unit raise GitError {
  let git_dir = join_path(root, ".git")
  let db = ObjectDb::load(rfs, git_dir)
  let tree_map = rebase_tree_map(db, rfs, target)
  rebase_update_head(fs, rfs, git_dir, target)
  rebase_write_worktree(fs, db, rfs, root, tree_map)
  let entries = rebase_map_to_index(db, rfs, tree_map)
  write_index_entries(fs, git_dir, entries)
}

///|
/// Rebase current HEAD onto upstream commit (linear, no conflicts).
pub fn rebase_onto(
  fs : &FileSystem,
  rfs : &RepoFileSystem,
  root : String,
  upstream : ObjectId,
) -> ObjectId raise GitError {
  let git_dir = join_path(root, ".git")
  let head = resolve_head_commit(rfs, git_dir)
  match head {
    None => {
      fast_forward_to(fs, rfs, root, upstream)
      return upstream
    }
    Some(h) => {
      if h == upstream {
        return h
      }
      let db = ObjectDb::load(rfs, git_dir)
      let chain = rebase_collect_chain(db, rfs, h, upstream)
      let base_map = rebase_tree_map(db, rfs, upstream)
      let mut parent = upstream
      for commit_id in chain {
        let info = rebase_parse_commit_full(db, rfs, commit_id)
        let parent_id = if info.parents.length() > 0 {
          info.parents[0]
        } else {
          raise GitError::InvalidObject("Cannot rebase root commit")
        }
        let parent_map = rebase_tree_map(db, rfs, parent_id)
        let commit_map = rebase_tree_map(db, rfs, info.tree)
        let changes = rebase_diff_maps(parent_map, commit_map)
        rebase_apply_changes(base_map, parent_map, changes)
        let new_tree = rebase_write_tree_from_map(fs, git_dir, base_map)
        let new_commit = Commit::new(
          new_tree,
          [parent],
          info.author,
          info.author_time,
          info.author_tz,
          info.committer,
          info.commit_time,
          info.committer_tz,
          info.message,
        )
        let (new_id, compressed) = create_commit(new_commit)
        rebase_write_object(fs, git_dir, new_id, compressed)
        parent = new_id
      }
      rebase_update_head(fs, rfs, git_dir, parent)
      rebase_write_worktree(fs, db, rfs, root, base_map)
      let entries = rebase_map_to_index(db, rfs, base_map)
      write_index_entries(fs, git_dir, entries)
      parent
    }
  }
}

///|
priv struct RebaseCommitInfo {
  tree : ObjectId
  parents : Array[ObjectId]
  author : String
  author_time : Int64
  author_tz : String
  committer : String
  commit_time : Int64
  committer_tz : String
  message : String
}

///|
priv struct TreeEntryInfo {
  id : ObjectId
  mode : Int
}

///|
priv struct Change {
  path : String
  kind : ChangeKind
  entry : TreeEntryInfo?
}

///|
priv enum ChangeKind {
  Added
  Modified
  Deleted
}

///|
fn rebase_collect_chain(
  db : ObjectDb,
  fs : &RepoFileSystem,
  head : ObjectId,
  upstream : ObjectId,
) -> Array[ObjectId] raise GitError {
  let list : Array[ObjectId] = []
  let mut current = head
  while true {
    if current == upstream {
      break
    }
    list.push(current)
    let obj = db.get(fs, current)
    match obj {
      None => raise GitError::InvalidObject("Missing commit object")
      Some(o) => {
        if o.obj_type != ObjectType::Commit {
          raise GitError::InvalidObject("Object is not a commit")
        }
        let info = parse_commit(o.data)
        if info.parents.length() == 0 {
          raise GitError::InvalidObject("Upstream not found in history")
        }
        current = info.parents[0]
      }
    }
  }
  list.rev()
}

///|
fn rebase_tree_map(
  db : ObjectDb,
  fs : &RepoFileSystem,
  commit_id : ObjectId,
) -> Map[String, TreeEntryInfo] raise GitError {
  let result : Map[String, TreeEntryInfo] = {}
  let commit_obj = db.get(fs, commit_id)
  match commit_obj {
    None => raise GitError::InvalidObject("Missing commit object")
    Some(obj) => {
      if obj.obj_type != ObjectType::Commit {
        raise GitError::InvalidObject("Object is not a commit")
      }
      let info = parse_commit(obj.data)
      rebase_collect_tree(db, fs, info.tree, "", result)
    }
  }
  result
}

///|
fn rebase_collect_tree(
  db : ObjectDb,
  fs : &RepoFileSystem,
  tree_id : ObjectId,
  prefix : String,
  out : Map[String, TreeEntryInfo],
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
        if rebase_is_tree_mode(entry.mode) {
          rebase_collect_tree(db, fs, entry.id, path, out)
        } else {
          let mode = rebase_parse_octal(entry.mode)
          out[path] = { id: entry.id, mode }
        }
      }
    }
  }
}

///|
fn rebase_diff_maps(
  parent_map : Map[String, TreeEntryInfo],
  commit_map : Map[String, TreeEntryInfo],
) -> Array[Change] {
  let changes : Array[Change] = []
  let paths : Map[String, Bool] = {}
  for item in parent_map.to_array() {
    let (p, _) = item
    paths[p] = true
  }
  for item in commit_map.to_array() {
    let (p, _) = item
    paths[p] = true
  }
  let list : Array[String] = []
  for item in paths.to_array() {
    let (p, _) = item
    list.push(p)
  }
  list.sort()
  for path in list {
    match (parent_map.get(path), commit_map.get(path)) {
      (None, Some(e)) =>
        changes.push({ path, kind: ChangeKind::Added, entry: Some(e) })
      (Some(_), None) =>
        changes.push({ path, kind: ChangeKind::Deleted, entry: None })
      (Some(p), Some(c)) =>
        if p.id != c.id || p.mode != c.mode {
          changes.push({ path, kind: ChangeKind::Modified, entry: Some(c) })
        }
      _ => ()
    }
  }
  changes
}

///|
fn rebase_apply_changes(
  base : Map[String, TreeEntryInfo],
  parent_map : Map[String, TreeEntryInfo],
  changes : Array[Change],
) -> Unit raise GitError {
  for ch in changes {
    let path = ch.path
    match ch.kind {
      ChangeKind::Added => {
        if base.contains(path) {
          raise GitError::InvalidObject("Rebase conflict: \{path}")
        }
        base[path] = ch.entry.unwrap()
      }
      ChangeKind::Deleted =>
        match (base.get(path), parent_map.get(path)) {
          (Some(b), Some(p)) => {
            if b.id != p.id || b.mode != p.mode {
              raise GitError::InvalidObject("Rebase conflict: \{path}")
            }
            base.remove(path)
          }
          (None, None) => ()
          _ => raise GitError::InvalidObject("Rebase conflict: \{path}")
        }
      ChangeKind::Modified => {
        let entry = ch.entry.unwrap()
        match (base.get(path), parent_map.get(path)) {
          (Some(b), Some(p)) => {
            if b.id != p.id || b.mode != p.mode {
              raise GitError::InvalidObject("Rebase conflict: \{path}")
            }
            base[path] = entry
          }
          (None, None) => base[path] = entry
          _ => raise GitError::InvalidObject("Rebase conflict: \{path}")
        }
      }
    }
  }
}

///|
fn rebase_write_tree_from_map(
  fs : &FileSystem,
  git_dir : String,
  map : Map[String, TreeEntryInfo],
) -> ObjectId raise GitError {
  let entries : Array[IndexEntry] = []
  for item in map.to_array() {
    let (path, e) = item
    entries.push({ path, id: e.id, mode: e.mode, size: 0 })
  }
  let rel_entries = entries.map(fn(e) { e })
  rebase_write_tree_recursive(fs, git_dir, rel_entries)
}

///|
fn rebase_write_tree_recursive(
  fs : &FileSystem,
  git_dir : String,
  entries : Array[IndexEntry],
) -> ObjectId raise GitError {
  let file_entries : Array[TreeEntry] = []
  let dir_map : Map[String, Array[IndexEntry]] = {}
  for e in entries {
    match rebase_split_first(e.path) {
      (name, None) => {
        let mode = rebase_mode_to_string(e.mode)
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
    let sub_id = rebase_write_tree_recursive(fs, git_dir, list)
    file_entries.push(TreeEntry::new("040000", dir_name, sub_id))
  }
  file_entries.sort_by(fn(a, b) { String::compare(a.name, b.name) })
  let (tree_id, compressed) = create_tree(file_entries)
  rebase_write_object(fs, git_dir, tree_id, compressed)
  tree_id
}

///|
fn rebase_write_worktree(
  fs : &FileSystem,
  db : ObjectDb,
  rfs : &RepoFileSystem,
  root : String,
  map : Map[String, TreeEntryInfo],
) -> Unit raise GitError {
  for item in map.to_array() {
    let (path, info) = item
    let obj = db.get(rfs, info.id)
    match obj {
      Some(o) => {
        if o.obj_type != ObjectType::Blob {
          raise GitError::InvalidObject("Object is not a blob")
        }
        let full = join_path(root, path)
        let dir = rebase_parent_dir(full)
        fs.mkdir_p(dir)
        fs.write_file(full, o.data)
      }
      None => raise GitError::InvalidObject("Missing blob object")
    }
  }
}

///|
fn rebase_map_to_index(
  db : ObjectDb,
  fs : &RepoFileSystem,
  map : Map[String, TreeEntryInfo],
) -> Array[IndexEntry] raise GitError {
  let entries : Array[IndexEntry] = []
  for item in map.to_array() {
    let (path, e) = item
    let obj = db.get(fs, e.id)
    match obj {
      Some(o) => {
        if o.obj_type != ObjectType::Blob {
          raise GitError::InvalidObject("Object is not a blob")
        }
        entries.push({ path, id: e.id, mode: e.mode, size: o.data.length() })
      }
      None => raise GitError::InvalidObject("Missing blob object")
    }
  }
  entries.sort_by(fn(a, b) { String::compare(a.path, b.path) })
  entries
}

///|
fn rebase_update_head(
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
      let dir = rebase_parent_dir(ref_path)
      fs.mkdir_p(dir)
      fs.write_string(ref_path, commit_id.to_hex() + "\n")
    }
    Detached(_) => fs.write_string(head_path, commit_id.to_hex() + "\n")
  }
}

///|
fn rebase_parse_commit_full(
  db : ObjectDb,
  fs : &RepoFileSystem,
  commit_id : ObjectId,
) -> RebaseCommitInfo raise GitError {
  let obj = db.get(fs, commit_id)
  match obj {
    None => raise GitError::InvalidObject("Missing commit object")
    Some(o) => {
      if o.obj_type != ObjectType::Commit {
        raise GitError::InvalidObject("Object is not a commit")
      }
      rebase_parse_commit_content(o.data)
    }
  }
}

///|
fn rebase_parse_commit_content(data : Bytes) -> RebaseCommitInfo raise GitError {
  let text = @utf8.decode_lossy(data[:])
  let mut header = text
  let mut message = ""
  match text.find("\n\n") {
    None => ()
    Some(idx) => {
      header = String::unsafe_substring(text, start=0, end=idx)
      message = String::unsafe_substring(text, start=idx + 2, end=text.length())
    }
  }
  let mut tree_id : ObjectId? = None
  let parents : Array[ObjectId] = []
  let mut author = ""
  let mut author_time = 0L
  let mut author_tz = "+0000"
  let mut committer = ""
  let mut commit_time = 0L
  let mut committer_tz = "+0000"
  for line_view in header.split("\n") {
    let line = line_view.to_string()
    if line.has_prefix("tree ") {
      let hex = String::unsafe_substring(line, start=5, end=line.length())
      tree_id = Some(ObjectId::from_hex(hex))
    } else if line.has_prefix("parent ") {
      let hex = String::unsafe_substring(line, start=7, end=line.length())
      parents.push(ObjectId::from_hex(hex))
    } else if line.has_prefix("author ") {
      let rest = String::unsafe_substring(line, start=7, end=line.length())
      let (name, time, tz) = rebase_parse_sig_line(rest)
      author = name
      author_time = time
      author_tz = tz
    } else if line.has_prefix("committer ") {
      let rest = String::unsafe_substring(line, start=10, end=line.length())
      let (name, time, tz) = rebase_parse_sig_line(rest)
      committer = name
      commit_time = time
      committer_tz = tz
    }
  }
  match tree_id {
    None => raise GitError::InvalidObject("Missing tree in commit")
    Some(tree) =>
      {
        tree,
        parents,
        author,
        author_time,
        author_tz,
        committer,
        commit_time,
        committer_tz,
        message,
      }
  }
}

///|
fn rebase_parse_sig_line(line : String) -> (String, Int64, String) {
  let last = line.rev_find(" ")
  if last is None {
    return (line, 0L, "+0000")
  }
  let tz_idx = last.unwrap()
  let before_tz = String::unsafe_substring(line, start=0, end=tz_idx)
  let tz = String::unsafe_substring(line, start=tz_idx + 1, end=line.length())
  let last2 = before_tz.rev_find(" ")
  if last2 is None {
    return (before_tz, 0L, tz)
  }
  let time_idx = last2.unwrap()
  let name = String::unsafe_substring(before_tz, start=0, end=time_idx)
  let time_str = String::unsafe_substring(
    before_tz,
    start=time_idx + 1,
    end=before_tz.length(),
  )
  let time = rebase_parse_int64(time_str)
  (name, time, tz)
}

///|
fn rebase_parse_int64(s : String) -> Int64 {
  let mut result = 0L
  for c in s {
    if c < '0' || c > '9' {
      continue
    }
    let digit = c.to_int() - '0'.to_int()
    result = result * 10L + digit.to_int64()
  }
  result
}

///|
fn rebase_write_object(
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
fn rebase_split_first(path : String) -> (String, String?) {
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
fn rebase_mode_to_string(mode : Int) -> String {
  if mode == 33188 {
    "100644"
  } else {
    rebase_to_octal_string(mode)
  }
}

///|
fn rebase_to_octal_string(value : Int) -> String {
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
fn rebase_is_tree_mode(mode : String) -> Bool {
  mode == "40000" || mode == "040000"
}

///|
fn rebase_parse_octal(s : String) -> Int {
  let mut result = 0
  for c in s {
    if c < '0' || c > '7' {
      continue
    }
    result = result * 8 + (c.to_int() - '0'.to_int())
  }
  result
}

///|
fn rebase_parent_dir(path : String) -> String {
  match path.rev_find("/") {
    None => "/"
    Some(0) => "/"
    Some(i) => String::unsafe_substring(path, start=0, end=i)
  }
}

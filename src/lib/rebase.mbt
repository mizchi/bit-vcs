///| Rebase and fast-forward helpers

///|
pub struct RebaseState {
  onto : @git.ObjectId
  orig_head : @git.ObjectId
  head_name : String // "refs/heads/main" or "" for detached
  todo : Array[@git.ObjectId]
  done : Array[@git.ObjectId]
  current : @git.ObjectId?
  message : String
  author : String
  author_time : Int64
  author_tz : String
}

///|
pub struct RebaseResult {
  status : RebaseStatus
  commit_id : @git.ObjectId?
  conflicts : Array[String]
}

///|
pub enum RebaseStatus {
  Complete
  Conflict
  NothingToRebase
}

///|
pub fn fast_forward_to(
  fs : &@git.FileSystem,
  rfs : &@git.RepoFileSystem,
  root : String,
  target : @git.ObjectId,
) -> Unit raise @git.GitError {
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
  fs : &@git.FileSystem,
  rfs : &@git.RepoFileSystem,
  root : String,
  upstream : @git.ObjectId,
) -> @git.ObjectId raise @git.GitError {
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
          raise @git.GitError::InvalidObject("Cannot rebase root commit")
        }
        let parent_map = rebase_tree_map(db, rfs, parent_id)
        let commit_map = rebase_tree_map_from_tree(db, rfs, info.tree)
        let changes = rebase_diff_maps(parent_map, commit_map)
        rebase_apply_changes(base_map, parent_map, changes)
        let new_tree = rebase_write_tree_from_map(fs, git_dir, base_map)
        let new_commit = @git.Commit::new(
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
        let (new_id, compressed) = @git.create_commit(new_commit)
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
  tree : @git.ObjectId
  parents : Array[@git.ObjectId]
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
  id : @git.ObjectId
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
  fs : &@git.RepoFileSystem,
  head : @git.ObjectId,
  upstream : @git.ObjectId,
) -> Array[@git.ObjectId] raise @git.GitError {
  // Find the merge base between head and upstream
  let merge_base = find_merge_base(db, fs, head, upstream)
  guard merge_base is Some(base) else {
    raise @git.GitError::InvalidObject("No common ancestor found")
  }
  // Collect commits from head to merge base (exclusive)
  let list : Array[@git.ObjectId] = []
  let mut current = head
  while current != base {
    list.push(current)
    let obj = db.get(fs, current)
    match obj {
      None => raise @git.GitError::InvalidObject("Missing commit object")
      Some(o) => {
        if o.obj_type != @git.ObjectType::Commit {
          raise @git.GitError::InvalidObject("Object is not a commit")
        }
        let info = @git.parse_commit(o.data)
        if info.parents.length() == 0 {
          raise @git.GitError::InvalidObject("Reached root without finding base")
        }
        current = info.parents[0]
      }
    }
  }
  list.rev()
}

///|
/// Find the merge base (common ancestor) of two commits.
fn find_merge_base(
  db : ObjectDb,
  fs : &@git.RepoFileSystem,
  commit1 : @git.ObjectId,
  commit2 : @git.ObjectId,
) -> @git.ObjectId? raise @git.GitError {
  // Collect all ancestors of commit1
  let ancestors1 : Map[String, Bool] = {}
  collect_ancestors(db, fs, commit1, ancestors1)
  // Walk commit2's history and find first common ancestor
  let visited : Map[String, Bool] = {}
  let queue : Array[@git.ObjectId] = [commit2]
  while queue.length() > 0 {
    let c = queue.remove(0)
    let hex = c.to_hex()
    if visited.contains(hex) {
      continue
    }
    visited[hex] = true
    if ancestors1.contains(hex) {
      return Some(c)
    }
    let obj = db.get(fs, c)
    match obj {
      None => continue
      Some(o) => {
        if o.obj_type != @git.ObjectType::Commit {
          continue
        }
        let info = @git.parse_commit(o.data)
        for parent in info.parents {
          queue.push(parent)
        }
      }
    }
  }
  None
}

///|
/// Collect all ancestors of a commit into a set.
fn collect_ancestors(
  db : ObjectDb,
  fs : &@git.RepoFileSystem,
  commit : @git.ObjectId,
  out : Map[String, Bool],
) -> Unit raise @git.GitError {
  let queue : Array[@git.ObjectId] = [commit]
  while queue.length() > 0 {
    let c = queue.remove(0)
    let hex = c.to_hex()
    if out.contains(hex) {
      continue
    }
    out[hex] = true
    let obj = db.get(fs, c)
    match obj {
      None => continue
      Some(o) => {
        if o.obj_type != @git.ObjectType::Commit {
          continue
        }
        let info = @git.parse_commit(o.data)
        for parent in info.parents {
          queue.push(parent)
        }
      }
    }
  }
}

///|
fn rebase_tree_map(
  db : ObjectDb,
  fs : &@git.RepoFileSystem,
  commit_id : @git.ObjectId,
) -> Map[String, TreeEntryInfo] raise @git.GitError {
  let result : Map[String, TreeEntryInfo] = {}
  let commit_obj = db.get(fs, commit_id)
  match commit_obj {
    None => raise @git.GitError::InvalidObject("Missing commit object")
    Some(obj) => {
      if obj.obj_type != @git.ObjectType::Commit {
        raise @git.GitError::InvalidObject("Object is not a commit")
      }
      let info = @git.parse_commit(obj.data)
      rebase_collect_tree(db, fs, info.tree, "", result)
    }
  }
  result
}

///|
/// Build tree map directly from a tree ID (not a commit ID).
fn rebase_tree_map_from_tree(
  db : ObjectDb,
  fs : &@git.RepoFileSystem,
  tree_id : @git.ObjectId,
) -> Map[String, TreeEntryInfo] raise @git.GitError {
  let result : Map[String, TreeEntryInfo] = {}
  rebase_collect_tree(db, fs, tree_id, "", result)
  result
}

///|
fn rebase_collect_tree(
  db : ObjectDb,
  fs : &@git.RepoFileSystem,
  tree_id : @git.ObjectId,
  prefix : String,
  out : Map[String, TreeEntryInfo],
) -> Unit raise @git.GitError {
  let tree_obj = db.get(fs, tree_id)
  match tree_obj {
    None => raise @git.GitError::InvalidObject("Missing tree object")
    Some(obj) => {
      if obj.obj_type != @git.ObjectType::Tree {
        raise @git.GitError::InvalidObject("Object is not a tree")
      }
      let entries = @git.parse_tree(obj.data)
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
) -> Unit raise @git.GitError {
  for ch in changes {
    let path = ch.path
    match ch.kind {
      ChangeKind::Added => {
        if base.contains(path) {
          raise @git.GitError::InvalidObject("Rebase conflict: \{path}")
        }
        base[path] = ch.entry.unwrap()
      }
      ChangeKind::Deleted =>
        match (base.get(path), parent_map.get(path)) {
          (Some(b), Some(p)) => {
            if b.id != p.id || b.mode != p.mode {
              raise @git.GitError::InvalidObject("Rebase conflict: \{path}")
            }
            base.remove(path)
          }
          (None, None) => ()
          _ => raise @git.GitError::InvalidObject("Rebase conflict: \{path}")
        }
      ChangeKind::Modified => {
        let entry = ch.entry.unwrap()
        match (base.get(path), parent_map.get(path)) {
          (Some(b), Some(p)) => {
            if b.id != p.id || b.mode != p.mode {
              raise @git.GitError::InvalidObject("Rebase conflict: \{path}")
            }
            base[path] = entry
          }
          (None, None) => base[path] = entry
          _ => raise @git.GitError::InvalidObject("Rebase conflict: \{path}")
        }
      }
    }
  }
}

///|
fn rebase_write_tree_from_map(
  fs : &@git.FileSystem,
  git_dir : String,
  map : Map[String, TreeEntryInfo],
) -> @git.ObjectId raise @git.GitError {
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
  fs : &@git.FileSystem,
  git_dir : String,
  entries : Array[IndexEntry],
) -> @git.ObjectId raise @git.GitError {
  let file_entries : Array[@git.TreeEntry] = []
  let dir_map : Map[String, Array[IndexEntry]] = {}
  for e in entries {
    match rebase_split_first(e.path) {
      (name, None) => {
        let mode = rebase_mode_to_string(e.mode)
        file_entries.push(@git.TreeEntry::new(mode, name, e.id))
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
    file_entries.push(@git.TreeEntry::new("040000", dir_name, sub_id))
  }
  file_entries.sort_by(fn(a, b) { String::compare(a.name, b.name) })
  let (tree_id, compressed) = @git.create_tree(file_entries)
  rebase_write_object(fs, git_dir, tree_id, compressed)
  tree_id
}

///|
fn rebase_write_worktree(
  fs : &@git.FileSystem,
  db : ObjectDb,
  rfs : &@git.RepoFileSystem,
  root : String,
  map : Map[String, TreeEntryInfo],
) -> Unit raise @git.GitError {
  rebase_write_worktree_except(fs, db, rfs, root, map, [])
}

///|
/// Write worktree from map, skipping files in the except list.
fn rebase_write_worktree_except(
  fs : &@git.FileSystem,
  db : ObjectDb,
  rfs : &@git.RepoFileSystem,
  root : String,
  map : Map[String, TreeEntryInfo],
  except : Array[String],
) -> Unit raise @git.GitError {
  let except_set : Map[String, Bool] = {}
  for path in except {
    except_set[path] = true
  }
  for item in map.to_array() {
    let (path, info) = item
    if except_set.contains(path) {
      continue // Skip conflicting files
    }
    let obj = db.get(rfs, info.id)
    match obj {
      Some(o) => {
        if o.obj_type != @git.ObjectType::Blob {
          raise @git.GitError::InvalidObject("Object is not a blob")
        }
        let full = join_path(root, path)
        let dir = rebase_parent_dir(full)
        fs.mkdir_p(dir)
        fs.write_file(full, o.data)
      }
      None => raise @git.GitError::InvalidObject("Missing blob object")
    }
  }
}

///|
fn rebase_map_to_index(
  db : ObjectDb,
  fs : &@git.RepoFileSystem,
  map : Map[String, TreeEntryInfo],
) -> Array[IndexEntry] raise @git.GitError {
  let entries : Array[IndexEntry] = []
  for item in map.to_array() {
    let (path, e) = item
    let obj = db.get(fs, e.id)
    match obj {
      Some(o) => {
        if o.obj_type != @git.ObjectType::Blob {
          raise @git.GitError::InvalidObject("Object is not a blob")
        }
        entries.push({ path, id: e.id, mode: e.mode, size: o.data.length() })
      }
      None => raise @git.GitError::InvalidObject("Missing blob object")
    }
  }
  entries.sort_by(fn(a, b) { String::compare(a.path, b.path) })
  entries
}

///|
fn rebase_update_head(
  fs : &@git.FileSystem,
  rfs : &@git.RepoFileSystem,
  git_dir : String,
  commit_id : @git.ObjectId,
) -> Unit raise @git.GitError {
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
  fs : &@git.RepoFileSystem,
  commit_id : @git.ObjectId,
) -> RebaseCommitInfo raise @git.GitError {
  let obj = db.get(fs, commit_id)
  match obj {
    None => raise @git.GitError::InvalidObject("Missing commit object")
    Some(o) => {
      if o.obj_type != @git.ObjectType::Commit {
        raise @git.GitError::InvalidObject("Object is not a commit")
      }
      rebase_parse_commit_content(o.data)
    }
  }
}

///|
fn rebase_parse_commit_content(
  data : Bytes,
) -> RebaseCommitInfo raise @git.GitError {
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
  let mut tree_id : @git.ObjectId? = None
  let parents : Array[@git.ObjectId] = []
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
      tree_id = Some(@git.ObjectId::from_hex(hex))
    } else if line.has_prefix("parent ") {
      let hex = String::unsafe_substring(line, start=7, end=line.length())
      parents.push(@git.ObjectId::from_hex(hex))
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
    None => raise @git.GitError::InvalidObject("Missing tree in commit")
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
  fs : &@git.FileSystem,
  git_dir : String,
  id : @git.ObjectId,
  compressed : Bytes,
) -> Unit raise @git.GitError {
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

// ============================================================================
// Rebase with conflict handling
// ============================================================================

///|
/// Check if a rebase is in progress.
pub fn is_rebase_in_progress(
  fs : &@git.RepoFileSystem,
  git_dir : String,
) -> Bool {
  let state_dir = join_path(git_dir, "rebase-merge")
  fs.is_dir(state_dir)
}

///|
/// Save rebase state to .git/rebase-merge/
fn save_rebase_state(
  fs : &@git.FileSystem,
  git_dir : String,
  state : RebaseState,
) -> Unit raise @git.GitError {
  let state_dir = join_path(git_dir, "rebase-merge")
  fs.mkdir_p(state_dir)
  fs.write_string(join_path(state_dir, "onto"), state.onto.to_hex() + "\n")
  fs.write_string(
    join_path(state_dir, "orig-head"),
    state.orig_head.to_hex() + "\n",
  )
  fs.write_string(join_path(state_dir, "head-name"), state.head_name + "\n")
  // Write todo list
  let todo_lines = state.todo.map(fn(id) { "pick " + id.to_hex() })
  fs.write_string(join_path(state_dir, "git-rebase-todo"), todo_lines.join("\n") +
    "\n")
  // Write done list
  let done_lines = state.done.map(fn(id) { "pick " + id.to_hex() })
  fs.write_string(
    join_path(state_dir, "done"),
    if done_lines.length() > 0 { done_lines.join("\n") + "\n" } else { "" },
  )
  // Write current commit info
  match state.current {
    Some(id) => {
      fs.write_string(join_path(state_dir, "stopped-sha"), id.to_hex() + "\n")
      fs.write_string(join_path(state_dir, "message"), state.message)
      fs.write_string(join_path(state_dir, "author-script"), "GIT_AUTHOR_NAME='\{state.author}'\nGIT_AUTHOR_DATE='\{state.author_time} \{state.author_tz}'\n")
    }
    None => ()
  }
}

///|
/// Load rebase state from .git/rebase-merge/
pub fn load_rebase_state(
  fs : &@git.RepoFileSystem,
  git_dir : String,
) -> RebaseState? raise @git.GitError {
  let state_dir = join_path(git_dir, "rebase-merge")
  if not(fs.is_dir(state_dir)) {
    return None
  }
  let onto_hex = read_file_trimmed(fs, join_path(state_dir, "onto"))
  let orig_head_hex = read_file_trimmed(fs, join_path(state_dir, "orig-head"))
  let head_name = read_file_trimmed(fs, join_path(state_dir, "head-name"))
  let todo = parse_todo_file(fs, join_path(state_dir, "git-rebase-todo"))
  let done = parse_todo_file(fs, join_path(state_dir, "done"))
  let current = if fs.is_file(join_path(state_dir, "stopped-sha")) {
    let hex = read_file_trimmed(fs, join_path(state_dir, "stopped-sha"))
    Some(@git.ObjectId::from_hex(hex))
  } else {
    None
  }
  let message = if fs.is_file(join_path(state_dir, "message")) {
    @utf8.decode_lossy(fs.read_file(join_path(state_dir, "message"))[:])
  } else {
    ""
  }
  Some(
    {
      onto: @git.ObjectId::from_hex(onto_hex),
      orig_head: @git.ObjectId::from_hex(orig_head_hex),
      head_name,
      todo,
      done,
      current,
      message,
      author: "",
      author_time: 0L,
      author_tz: "+0000",
    },
  )
}

///|
fn read_file_trimmed(fs : &@git.RepoFileSystem, path : String) -> String {
  let content = @utf8.decode_lossy(
    (fs.read_file(path) catch { _ => Bytes::default() })[:],
  )
  let mut end = content.length()
  while end > 0 {
    let c = content.unsafe_get(end - 1)
    if c == '\n' || c == '\r' || c == ' ' || c == '\t' {
      end -= 1
    } else {
      break
    }
  }
  String::unsafe_substring(content, start=0, end~)
}

///|
fn parse_todo_file(
  fs : &@git.RepoFileSystem,
  path : String,
) -> Array[@git.ObjectId] {
  let result : Array[@git.ObjectId] = []
  if not(fs.is_file(path)) {
    return result
  }
  let content = @utf8.decode_lossy(
    (fs.read_file(path) catch { _ => Bytes::default() })[:],
  )
  for line_view in content.split("\n") {
    let line = line_view.to_string()
    if line.length() == 0 || line.has_prefix("#") {
      continue
    }
    // Format: "pick <sha>" or just "<sha>"
    let parts = line.split(" ").map(fn(v) { v.to_string() }).collect()
    if parts.length() >= 2 && parts[0] == "pick" {
      let id = @git.ObjectId::from_hex(parts[1]) catch { _ => continue }
      result.push(id)
    } else if parts.length() >= 1 && parts[0].length() == 40 {
      let id = @git.ObjectId::from_hex(parts[0]) catch { _ => continue }
      result.push(id)
    }
  }
  result
}

///|
/// Clear rebase state (remove .git/rebase-merge/)
pub fn clear_rebase_state(
  fs : &@git.FileSystem,
  rfs : &@git.RepoFileSystem,
  git_dir : String,
) -> Unit raise @git.GitError {
  let state_dir = join_path(git_dir, "rebase-merge")
  if not(rfs.is_dir(state_dir)) {
    return ()
  }
  // Remove all files in state_dir
  let files = rfs.readdir(state_dir)
  for file in files {
    fs.remove_file(join_path(state_dir, file))
  }
  // Remove the directory
  fs.remove_dir(state_dir)
}

///|
/// Start a rebase operation. Returns RebaseResult indicating status.
pub fn rebase_start(
  fs : &@git.FileSystem,
  rfs : &@git.RepoFileSystem,
  root : String,
  upstream : @git.ObjectId,
) -> RebaseResult raise @git.GitError {
  let git_dir = join_path(root, ".git")
  // Check if rebase already in progress
  if is_rebase_in_progress(rfs, git_dir) {
    raise @git.GitError::InvalidObject(
      "A rebase is already in progress. Use --continue, --abort, or --skip.",
    )
  }
  let head = resolve_head_commit(rfs, git_dir)
  match head {
    None => {
      fast_forward_to(fs, rfs, root, upstream)
      return { status: RebaseStatus::Complete, commit_id: Some(upstream), conflicts: [] }
    }
    Some(h) => {
      if h == upstream {
        return { status: RebaseStatus::NothingToRebase, commit_id: Some(h), conflicts: [] }
      }
      let db = ObjectDb::load(rfs, git_dir)
      let chain = rebase_collect_chain(db, rfs, h, upstream)
      if chain.length() == 0 {
        return { status: RebaseStatus::NothingToRebase, commit_id: Some(h), conflicts: [] }
      }
      // Get head name for later restoration
      let head_name = match read_head_ref(rfs, git_dir) {
        HeadRef::Branch(name) => "refs/heads/" + name
        HeadRef::Detached(_) => ""
      }
      // Create initial state
      let state : RebaseState = {
        onto: upstream,
        orig_head: h,
        head_name,
        todo: chain,
        done: [],
        current: None,
        message: "",
        author: "",
        author_time: 0L,
        author_tz: "+0000",
      }
      save_rebase_state(fs, git_dir, state)
      // Move HEAD to upstream before applying commits
      // This is crucial for correct conflict markers (HEAD = upstream, not feature branch)
      rebase_update_head(fs, rfs, git_dir, upstream)
      let upstream_map = rebase_tree_map(db, rfs, upstream)
      rebase_write_worktree(fs, db, rfs, root, upstream_map)
      let entries = rebase_map_to_index(db, rfs, upstream_map)
      write_index_entries(fs, git_dir, entries)
      // Start applying commits
      rebase_apply_next(fs, rfs, root, state)
    }
  }
}

///|
/// Continue rebase after resolving conflicts.
pub fn rebase_continue(
  fs : &@git.FileSystem,
  rfs : &@git.RepoFileSystem,
  root : String,
) -> RebaseResult raise @git.GitError {
  let git_dir = join_path(root, ".git")
  let state = load_rebase_state(rfs, git_dir)
  guard state is Some(s) else {
    raise @git.GitError::InvalidObject("No rebase in progress")
  }
  // Commit the resolved changes
  guard s.current is Some(current_id) else {
    raise @git.GitError::InvalidObject("No commit to continue")
  }
  let db = ObjectDb::load(rfs, git_dir)
  let info = rebase_parse_commit_full(db, rfs, current_id)
  // Get current HEAD as parent
  let head = resolve_head_commit(rfs, git_dir)
  guard head is Some(parent) else {
    raise @git.GitError::InvalidObject("No HEAD commit")
  }
  // Build tree from current index
  let entries = read_index_entries(rfs, git_dir)
  let new_tree = write_tree_from_entries(fs, git_dir, entries)
  // Create new commit with original author info
  let new_commit = @git.Commit::new(
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
  let (new_id, compressed) = @git.create_commit(new_commit)
  rebase_write_object(fs, git_dir, new_id, compressed)
  rebase_update_head(fs, rfs, git_dir, new_id)
  // Update state: move current to done, clear current
  let new_done = s.done.copy()
  new_done.push(current_id)
  let new_state : RebaseState = {
    onto: s.onto,
    orig_head: s.orig_head,
    head_name: s.head_name,
    todo: s.todo,
    done: new_done,
    current: None,
    message: "",
    author: "",
    author_time: 0L,
    author_tz: "+0000",
  }
  save_rebase_state(fs, git_dir, new_state)
  // Continue with next commits
  rebase_apply_next(fs, rfs, root, new_state)
}

///|
/// Abort the current rebase and restore original state.
pub fn rebase_abort(
  fs : &@git.FileSystem,
  rfs : &@git.RepoFileSystem,
  root : String,
) -> Unit raise @git.GitError {
  let git_dir = join_path(root, ".git")
  let state = load_rebase_state(rfs, git_dir)
  guard state is Some(s) else {
    raise @git.GitError::InvalidObject("No rebase in progress")
  }
  // Restore original HEAD
  let head_path = join_path(git_dir, "HEAD")
  if s.head_name.length() > 0 {
    fs.write_string(head_path, "ref: " + s.head_name + "\n")
    let ref_path = join_path(git_dir, s.head_name)
    let dir = rebase_parent_dir(ref_path)
    fs.mkdir_p(dir)
    fs.write_string(ref_path, s.orig_head.to_hex() + "\n")
  } else {
    fs.write_string(head_path, s.orig_head.to_hex() + "\n")
  }
  // Restore worktree to original HEAD
  let db = ObjectDb::load(rfs, git_dir)
  let tree_map = rebase_tree_map(db, rfs, s.orig_head)
  rebase_write_worktree(fs, db, rfs, root, tree_map)
  let entries = rebase_map_to_index(db, rfs, tree_map)
  write_index_entries(fs, git_dir, entries)
  // Clear rebase state
  clear_rebase_state(fs, rfs, git_dir)
}

///|
/// Skip the current commit and continue rebase.
pub fn rebase_skip(
  fs : &@git.FileSystem,
  rfs : &@git.RepoFileSystem,
  root : String,
) -> RebaseResult raise @git.GitError {
  let git_dir = join_path(root, ".git")
  let state = load_rebase_state(rfs, git_dir)
  guard state is Some(s) else {
    raise @git.GitError::InvalidObject("No rebase in progress")
  }
  guard s.current is Some(current_id) else {
    raise @git.GitError::InvalidObject("No commit to skip")
  }
  // Move current to done (skipped)
  let new_done = s.done.copy()
  new_done.push(current_id)
  let new_state : RebaseState = {
    onto: s.onto,
    orig_head: s.orig_head,
    head_name: s.head_name,
    todo: s.todo,
    done: new_done,
    current: None,
    message: "",
    author: "",
    author_time: 0L,
    author_tz: "+0000",
  }
  save_rebase_state(fs, git_dir, new_state)
  // Reset worktree to current HEAD
  let db = ObjectDb::load(rfs, git_dir)
  let head = resolve_head_commit(rfs, git_dir)
  guard head is Some(h) else {
    raise @git.GitError::InvalidObject("No HEAD commit")
  }
  let tree_map = rebase_tree_map(db, rfs, h)
  rebase_write_worktree(fs, db, rfs, root, tree_map)
  let entries = rebase_map_to_index(db, rfs, tree_map)
  write_index_entries(fs, git_dir, entries)
  // Continue with next commits
  rebase_apply_next(fs, rfs, root, new_state)
}

///|
/// Apply the next commit in the todo list.
fn rebase_apply_next(
  fs : &@git.FileSystem,
  rfs : &@git.RepoFileSystem,
  root : String,
  state : RebaseState,
) -> RebaseResult raise @git.GitError {
  let git_dir = join_path(root, ".git")
  let db = ObjectDb::load(rfs, git_dir)
  // Find the next commit to apply
  let next_idx = state.done.length()
  if next_idx >= state.todo.length() {
    // All done, finalize rebase
    clear_rebase_state(fs, rfs, git_dir)
    // Restore branch ref if applicable
    let head = resolve_head_commit(rfs, git_dir)
    guard head is Some(final_id) else {
      raise @git.GitError::InvalidObject("No HEAD after rebase")
    }
    if state.head_name.length() > 0 {
      let head_path = join_path(git_dir, "HEAD")
      fs.write_string(head_path, "ref: " + state.head_name + "\n")
      let ref_path = join_path(git_dir, state.head_name)
      fs.write_string(ref_path, final_id.to_hex() + "\n")
    }
    return { status: RebaseStatus::Complete, commit_id: head, conflicts: [] }
  }
  let commit_id = state.todo[next_idx]
  let info = rebase_parse_commit_full(db, rfs, commit_id)
  let parent_id = if info.parents.length() > 0 {
    info.parents[0]
  } else {
    raise @git.GitError::InvalidObject("Cannot rebase root commit")
  }
  // Get current HEAD as the base
  let head = resolve_head_commit(rfs, git_dir)
  guard head is Some(base_id) else {
    raise @git.GitError::InvalidObject("No HEAD commit")
  }
  let base_map = rebase_tree_map(db, rfs, base_id)
  let parent_map = rebase_tree_map(db, rfs, parent_id)
  let commit_map = rebase_tree_map_from_tree(db, rfs, info.tree)
  let changes = rebase_diff_maps(parent_map, commit_map)
  // Try to apply changes, detecting conflicts
  let conflicts = rebase_apply_changes_with_conflicts(
    db, rfs, fs, root, base_map, parent_map, changes,
  )
  if conflicts.length() > 0 {
    // Conflict detected - save state and stop
    let new_state : RebaseState = {
      onto: state.onto,
      orig_head: state.orig_head,
      head_name: state.head_name,
      todo: state.todo,
      done: state.done,
      current: Some(commit_id),
      message: info.message,
      author: info.author,
      author_time: info.author_time,
      author_tz: info.author_tz,
    }
    save_rebase_state(fs, git_dir, new_state)
    // Write partially merged state to worktree and index (skip conflicting files)
    rebase_write_worktree_except(fs, db, rfs, root, base_map, conflicts)
    let entries = rebase_map_to_index(db, rfs, base_map)
    write_index_entries(fs, git_dir, entries)
    return { status: RebaseStatus::Conflict, commit_id: Some(commit_id), conflicts }
  }
  // No conflicts - create new commit
  let new_tree = rebase_write_tree_from_map(fs, git_dir, base_map)
  let new_commit = @git.Commit::new(
    new_tree,
    [base_id],
    info.author,
    info.author_time,
    info.author_tz,
    info.committer,
    info.commit_time,
    info.committer_tz,
    info.message,
  )
  let (new_id, compressed) = @git.create_commit(new_commit)
  rebase_write_object(fs, git_dir, new_id, compressed)
  rebase_update_head(fs, rfs, git_dir, new_id)
  // Update state and continue
  let new_done = state.done.copy()
  new_done.push(commit_id)
  let new_state : RebaseState = {
    onto: state.onto,
    orig_head: state.orig_head,
    head_name: state.head_name,
    todo: state.todo,
    done: new_done,
    current: None,
    message: "",
    author: "",
    author_time: 0L,
    author_tz: "+0000",
  }
  save_rebase_state(fs, git_dir, new_state)
  // Recursively apply next
  rebase_apply_next(fs, rfs, root, new_state)
}

///|
/// Apply changes with conflict detection and conflict markers.
fn rebase_apply_changes_with_conflicts(
  db : ObjectDb,
  rfs : &@git.RepoFileSystem,
  fs : &@git.FileSystem,
  root : String,
  base : Map[String, TreeEntryInfo],
  parent_map : Map[String, TreeEntryInfo],
  changes : Array[Change],
) -> Array[String] raise @git.GitError {
  let conflicts : Array[String] = []
  for ch in changes {
    let path = ch.path
    match ch.kind {
      ChangeKind::Added => {
        if base.contains(path) {
          // Conflict: file exists in base but commit adds it
          let base_entry = base.get(path).unwrap()
          let new_entry = ch.entry.unwrap()
          if base_entry.id != new_entry.id {
            // Write conflict markers
            write_conflict_file(
              db, rfs, fs, root, path, Some(base_entry), None, Some(new_entry),
            )
            conflicts.push(path)
          }
          // If same content, just keep base version
        } else {
          base[path] = ch.entry.unwrap()
        }
      }
      ChangeKind::Deleted =>
        match (base.get(path), parent_map.get(path)) {
          (Some(b), Some(p)) => {
            if b.id != p.id || b.mode != p.mode {
              // Conflict: base modified, but commit deletes
              conflicts.push(path)
              // Keep base version with marker
              write_conflict_file(db, rfs, fs, root, path, Some(b), Some(p), None)
            } else {
              base.remove(path)
            }
          }
          (None, None) => ()
          (Some(b), None) => {
            // File in base but not in parent - conflict
            conflicts.push(path)
            write_conflict_file(db, rfs, fs, root, path, Some(b), None, None)
          }
          (None, Some(_)) =>
            // File in parent but not base - already deleted, nothing to do
            ()
        }
      ChangeKind::Modified => {
        let entry = ch.entry.unwrap()
        match (base.get(path), parent_map.get(path)) {
          (Some(b), Some(p)) => {
            if b.id != p.id || b.mode != p.mode {
              // Three-way conflict: base, parent, and commit all different
              write_conflict_file(
                db, rfs, fs, root, path, Some(b), Some(p), Some(entry),
              )
              conflicts.push(path)
            } else {
              // Base matches parent, apply modification
              base[path] = entry
            }
          }
          (None, None) => base[path] = entry
          (None, Some(p)) => {
            // File was deleted in base but modified in commit
            write_conflict_file(
              db, rfs, fs, root, path, None, Some(p), Some(entry),
            )
            conflicts.push(path)
            base[path] = entry
          }
          (Some(b), None) => {
            // File added in base, modified in commit (from nothing to something)
            if b.id != entry.id {
              write_conflict_file(
                db, rfs, fs, root, path, Some(b), None, Some(entry),
              )
              conflicts.push(path)
            }
            // Keep entry as the result
            base[path] = entry
          }
        }
      }
    }
  }
  conflicts
}

///|
/// Write a file with conflict markers.
fn write_conflict_file(
  db : ObjectDb,
  rfs : &@git.RepoFileSystem,
  fs : &@git.FileSystem,
  root : String,
  path : String,
  ours : TreeEntryInfo?,
  base : TreeEntryInfo?,
  theirs : TreeEntryInfo?,
) -> Unit raise @git.GitError {
  let full_path = join_path(root, path)
  let dir = rebase_parent_dir(full_path)
  fs.mkdir_p(dir)
  // Get content from each version
  let ours_content = match ours {
    Some(e) => get_blob_content(db, rfs, e.id)
    None => ""
  }
  let base_content = match base {
    Some(e) => get_blob_content(db, rfs, e.id)
    None => ""
  }
  let theirs_content = match theirs {
    Some(e) => get_blob_content(db, rfs, e.id)
    None => ""
  }
  // Write conflict markers
  let merged = "<<<<<<< HEAD\n" +
    ours_content +
    (if ours_content.length() > 0 && not(ours_content.has_suffix("\n")) {
      "\n"
    } else {
      ""
    }) +
    "||||||| parent\n" +
    base_content +
    (if base_content.length() > 0 && not(base_content.has_suffix("\n")) {
      "\n"
    } else {
      ""
    }) +
    "=======\n" +
    theirs_content +
    (if theirs_content.length() > 0 && not(theirs_content.has_suffix("\n")) {
      "\n"
    } else {
      ""
    }) +
    ">>>>>>> incoming\n"
  fs.write_string(full_path, merged)
}

///|
fn get_blob_content(
  db : ObjectDb,
  fs : &@git.RepoFileSystem,
  id : @git.ObjectId,
) -> String {
  let obj = db.get(fs, id) catch { _ => return "" }
  match obj {
    Some(o) =>
      if o.obj_type == @git.ObjectType::Blob {
        @utf8.decode_lossy(o.data[:])
      } else {
        ""
      }
    None => ""
  }
}

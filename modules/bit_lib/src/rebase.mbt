///| Rebase and fast-forward helpers

///|
pub struct RebaseState {
  onto : @bit.ObjectId
  orig_head : @bit.ObjectId
  head_name : String // "refs/heads/main" or "" for detached
  todo : Array[@bit.ObjectId]
  done : Array[@bit.ObjectId]
  current : @bit.ObjectId?
  message : String
  author : String
  author_time : Int64
  author_tz : String
  // old commit id -> new (rewritten) commit id, in application order.
  // Mirrors git's .git/rebase-merge/rewritten-list.
  rewritten : Array[(@bit.ObjectId, @bit.ObjectId)]
}

///|
pub struct RebaseResult {
  status : RebaseStatus
  commit_id : @bit.ObjectId?
  conflicts : Array[String]
  // old commit id -> new (rewritten) commit id, populated once the rebase
  // completes. Empty for fast-forward / nothing-to-rebase results, since no
  // commit ids change in those cases.
  rewritten : Array[(@bit.ObjectId, @bit.ObjectId)]
}

///|
pub enum RebaseStatus {
  Complete
  Conflict
  NothingToRebase
}

///|
/// Resolves the actual `.git` directory for `root`, following the
/// `gitdir: <path>` pointer file used by linked worktrees (where
/// `<root>/.git` is a file, not a directory, and the real admin dir lives
/// under the main repo's `.git/worktrees/<name>`).
fn rebase_resolve_git_dir(rfs : &@bit.RepoFileSystem, root : String) -> String {
  let default_git_dir = join_path(root, ".git")
  if rfs.is_file(default_git_dir) {
    resolve_gitdir(rfs, default_git_dir)
  } else {
    default_git_dir
  }
}

///|
pub async fn fast_forward_to(
  fs : &@bit.FileSystem,
  rfs : &@bit.RepoFileSystem,
  root : String,
  target : @bit.ObjectId,
  run_filter_cmd? : FilterCmd,
) -> Unit raise @bit.GitError {
  let git_dir = rebase_resolve_git_dir(rfs, root)
  let db = ObjectDb::load(rfs, git_dir)
  let tree_map = rebase_tree_map(db, rfs, target)
  rebase_update_head(fs, rfs, git_dir, target)
  rebase_write_worktree_filtered(fs, db, rfs, root, git_dir, tree_map, run_filter_cmd?)
  let entries = rebase_map_to_index(db, rfs, tree_map)
  write_index_entries(fs, git_dir, entries)
}

///|
/// Rebase current HEAD onto upstream commit (linear, no conflicts).
pub async fn rebase_onto(
  fs : &@bit.FileSystem,
  rfs : &@bit.RepoFileSystem,
  root : String,
  upstream : @bit.ObjectId,
  run_filter_cmd? : FilterCmd,
) -> @bit.ObjectId raise @bit.GitError {
  let git_dir = rebase_resolve_git_dir(rfs, root)
  let head = resolve_head_commit(rfs, git_dir)
  match head {
    None => {
      fast_forward_to(fs, rfs, root, upstream, run_filter_cmd?)
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
          raise @bit.GitError::InvalidObject("Cannot rebase root commit")
        }
        let parent_map = rebase_tree_map(db, rfs, parent_id)
        let commit_map = rebase_tree_map_from_tree(db, rfs, info.tree)
        let changes = rebase_diff_maps(parent_map, commit_map)
        rebase_apply_changes(base_map, parent_map, changes)
        let new_tree = rebase_write_tree_from_map(fs, rfs, git_dir, base_map)
        let new_commit = @bit.Commit::new(
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
        let (new_id, compressed) = @bit.create_commit(new_commit)
        rebase_write_object(fs, rfs, git_dir, new_id, compressed)
        parent = new_id
      }
      rebase_update_head(fs, rfs, git_dir, parent)
      rebase_write_worktree_filtered(fs, db, rfs, root, git_dir, base_map, run_filter_cmd?)
      let entries = rebase_map_to_index(db, rfs, base_map)
      write_index_entries(fs, git_dir, entries)
      parent
    }
  }
}

///|
priv struct RebaseCommitInfo {
  tree : @bit.ObjectId
  parents : Array[@bit.ObjectId]
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
  id : @bit.ObjectId
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
  fs : &@bit.RepoFileSystem,
  head : @bit.ObjectId,
  upstream : @bit.ObjectId,
) -> Array[@bit.ObjectId] raise @bit.GitError {
  // Find the merge base between head and upstream
  let merge_base = find_merge_base(db, fs, head, upstream)
  guard merge_base is Some(base) else {
    raise @bit.GitError::InvalidObject("No common ancestor found")
  }
  // Collect commits from head to merge base (exclusive)
  let list : Array[@bit.ObjectId] = []
  let mut current = head
  while current != base {
    list.push(current)
    let obj = db.get(fs, current)
    match obj {
      None => raise @bit.GitError::InvalidObject("Missing commit object")
      Some(o) => {
        if o.obj_type != @bit.ObjectType::Commit {
          raise @bit.GitError::InvalidObject("Object is not a commit")
        }
        let info = @bit.parse_commit(o.data)
        if info.parents.length() == 0 {
          raise @bit.GitError::InvalidObject(
            "Reached root without finding base",
          )
        }
        current = info.parents[0]
      }
    }
  }
  list.rev()
}

///|
/// Collect all commits from head to the root (initial commit with no parents).
/// Returns commits in chronological order (oldest first).
fn rebase_collect_chain_to_root(
  db : ObjectDb,
  fs : &@bit.RepoFileSystem,
  head : @bit.ObjectId,
) -> Array[@bit.ObjectId] raise @bit.GitError {
  let list : Array[@bit.ObjectId] = []
  let mut current = head
  while true {
    list.push(current)
    let obj = db.get(fs, current)
    match obj {
      None => raise @bit.GitError::InvalidObject("Missing commit object")
      Some(o) => {
        if o.obj_type != @bit.ObjectType::Commit {
          raise @bit.GitError::InvalidObject("Object is not a commit")
        }
        let info = @bit.parse_commit(o.data)
        if info.parents.length() == 0 {
          break // Reached the root commit
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
  fs : &@bit.RepoFileSystem,
  commit1 : @bit.ObjectId,
  commit2 : @bit.ObjectId,
) -> @bit.ObjectId? raise @bit.GitError {
  // Collect all ancestors of commit1
  let ancestors1 : Map[String, Bool] = Map([])
  collect_ancestors(db, fs, commit1, ancestors1)
  // Walk commit2's history and find first common ancestor
  let visited : Map[String, Bool] = Map([])
  let queue : Array[@bit.ObjectId] = [commit2]
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
        if o.obj_type != @bit.ObjectType::Commit {
          continue
        }
        let info = @bit.parse_commit(o.data)
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
  fs : &@bit.RepoFileSystem,
  commit : @bit.ObjectId,
  out : Map[String, Bool],
) -> Unit raise @bit.GitError {
  let queue : Array[@bit.ObjectId] = [commit]
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
        if o.obj_type != @bit.ObjectType::Commit {
          continue
        }
        let info = @bit.parse_commit(o.data)
        for parent in info.parents {
          queue.push(parent)
        }
      }
    }
  }
}

///|
/// Refuse to move HEAD onto `target_map` if doing so would silently
/// overwrite an untracked file on disk, mirroring the check an ordinary
/// checkout performs. Only paths `target_map` actually writes are checked
/// (not a full worktree scan), since those are the only ones about to be
/// clobbered by `rebase_write_worktree`.
fn rebase_check_untracked_conflicts(
  rfs : &@bit.RepoFileSystem,
  git_dir : String,
  root : String,
  target_map : Map[String, TreeEntryInfo],
) -> Unit raise @bit.GitError {
  let index_paths : Map[String, Bool] = Map([])
  for entry in read_index_entries(rfs, git_dir) {
    index_paths[entry.path] = true
  }
  let conflicts : Array[String] = []
  for pair in target_map.to_array() {
    let path = pair.0
    if !index_paths.contains(path) && rfs.is_file(join_path(root, path)) {
      conflicts.push(path)
    }
  }
  if conflicts.length() > 0 {
    conflicts.sort()
    let listed = conflicts.map(p => "\t" + p).join("\n")
    raise @bit.GitError::InvalidObject(
      "The following untracked working tree files would be overwritten by checkout:\n\{listed}\nPlease move or remove them before you switch branches.\nAborting",
    )
  }
}

///|
fn rebase_tree_map(
  db : ObjectDb,
  fs : &@bit.RepoFileSystem,
  commit_id : @bit.ObjectId,
) -> Map[String, TreeEntryInfo] raise @bit.GitError {
  let result : Map[String, TreeEntryInfo] = Map([])
  let commit_obj = db.get(fs, commit_id)
  match commit_obj {
    None => raise @bit.GitError::InvalidObject("Missing commit object")
    Some(obj) => {
      if obj.obj_type != @bit.ObjectType::Commit {
        raise @bit.GitError::InvalidObject("Object is not a commit")
      }
      let info = @bit.parse_commit(obj.data)
      rebase_collect_tree(db, fs, info.tree, "", result)
    }
  }
  result
}

///|
/// Build tree map directly from a tree ID (not a commit ID).
fn rebase_tree_map_from_tree(
  db : ObjectDb,
  fs : &@bit.RepoFileSystem,
  tree_id : @bit.ObjectId,
) -> Map[String, TreeEntryInfo] raise @bit.GitError {
  let result : Map[String, TreeEntryInfo] = Map([])
  rebase_collect_tree(db, fs, tree_id, "", result)
  result
}

///|
fn rebase_collect_tree(
  db : ObjectDb,
  fs : &@bit.RepoFileSystem,
  tree_id : @bit.ObjectId,
  prefix : String,
  out : Map[String, TreeEntryInfo],
) -> Unit raise @bit.GitError {
  let tree_obj = db.get(fs, tree_id)
  match tree_obj {
    None => raise @bit.GitError::InvalidObject("Missing tree object")
    Some(obj) => {
      if obj.obj_type != @bit.ObjectType::Tree {
        raise @bit.GitError::InvalidObject("Object is not a tree")
      }
      let entries = @bit.parse_tree(obj.data)
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
  let paths : Map[String, Bool] = Map([])
  for p in parent_map.keys() {
    paths[p] = true
  }
  for p in commit_map.keys() {
    paths[p] = true
  }
  let list = paths.keys().to_array()
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
) -> Unit raise @bit.GitError {
  for ch in changes {
    let path = ch.path
    match ch.kind {
      ChangeKind::Added => {
        if base.contains(path) {
          raise @bit.GitError::InvalidObject("Rebase conflict: \{path}")
        }
        base[path] = ch.entry.unwrap()
      }
      ChangeKind::Deleted =>
        match (base.get(path), parent_map.get(path)) {
          (Some(b), Some(p)) => {
            if b.id != p.id || b.mode != p.mode {
              raise @bit.GitError::InvalidObject("Rebase conflict: \{path}")
            }
            base.remove(path)
          }
          (None, None) => ()
          _ => raise @bit.GitError::InvalidObject("Rebase conflict: \{path}")
        }
      ChangeKind::Modified => {
        let entry = ch.entry.unwrap()
        match (base.get(path), parent_map.get(path)) {
          (Some(b), Some(p)) => {
            if b.id != p.id || b.mode != p.mode {
              raise @bit.GitError::InvalidObject("Rebase conflict: \{path}")
            }
            base[path] = entry
          }
          (None, None) => base[path] = entry
          _ => raise @bit.GitError::InvalidObject("Rebase conflict: \{path}")
        }
      }
    }
  }
}

///|
fn rebase_write_tree_from_map(
  fs : &@bit.FileSystem,
  rfs : &@bit.RepoFileSystem,
  git_dir : String,
  map : Map[String, TreeEntryInfo],
) -> @bit.ObjectId raise @bit.GitError {
  let entries : Array[IndexEntry] = []
  for path, e in map {
    entries.push({
      path,
      id: e.id,
      mode: e.mode,
      size: 0,
      mtime_sec: 0,
      mtime_nsec: 0,
      intent_to_add: false,
      dev: 0,
      ino: 0,
      uid: 0,
      gid: 0,
    })
  }
  entries.sort_by((a, b) => String::lexical_compare(a.path, b.path))
  let rel_entries = entries.map(e => e)
  rebase_write_tree_recursive(fs, rfs, git_dir, rel_entries)
}

///|
fn rebase_write_tree_recursive(
  fs : &@bit.FileSystem,
  rfs : &@bit.RepoFileSystem,
  git_dir : String,
  entries : Array[IndexEntry],
) -> @bit.ObjectId raise @bit.GitError {
  let file_entries : Array[@bit.TreeEntry] = []
  let dir_map : Map[String, Array[IndexEntry]] = Map([])
  for e in entries {
    match rebase_split_first(e.path) {
      (name, None) => {
        let mode = rebase_mode_to_string(e.mode)
        file_entries.push(@bit.TreeEntry::new(mode, name, e.id))
      }
      (name, Some(rest)) =>
        match dir_map.get(name) {
          Some(list) =>
            list.push({
              path: rest,
              id: e.id,
              mode: e.mode,
              size: e.size,
              mtime_sec: e.mtime_sec,
              mtime_nsec: e.mtime_nsec,
              intent_to_add: e.intent_to_add,
              dev: e.dev,
              ino: e.ino,
              uid: e.uid,
              gid: e.gid,
            })
          None =>
            dir_map[name] = [
              {
                path: rest,
                id: e.id,
                mode: e.mode,
                size: e.size,
                mtime_sec: e.mtime_sec,
                mtime_nsec: e.mtime_nsec,
                intent_to_add: e.intent_to_add,
                dev: e.dev,
                ino: e.ino,
                uid: e.uid,
                gid: e.gid,
              },
            ]
        }
    }
  }
  for dir_name, list in dir_map {
    let sub_id = rebase_write_tree_recursive(fs, rfs, git_dir, list)
    file_entries.push(@bit.TreeEntry::new("040000", dir_name, sub_id))
  }
  file_entries.sort_by((a, b) => String::lexical_compare(a.name, b.name))
  let (tree_id, compressed) = @bit.create_tree(file_entries)
  rebase_write_object(fs, rfs, git_dir, tree_id, compressed)
  tree_id
}

///|
fn rebase_write_worktree(
  fs : &@bit.FileSystem,
  db : ObjectDb,
  rfs : &@bit.RepoFileSystem,
  root : String,
  git_dir : String,
  map : Map[String, TreeEntryInfo],
) -> Unit raise @bit.GitError {
  let files : Map[String, TreeFileEntry] = Map([])
  for path, info in map {
    files[path] = { id: info.id, mode: info.mode }
  }
  tree_ops_remove_missing_paths(fs, rfs, root, git_dir, files, false)
  rebase_write_worktree_except(fs, db, rfs, root, git_dir, map, [])
}

///|
/// Write worktree from map, skipping files in the except list.
fn rebase_write_worktree_except(
  fs : &@bit.FileSystem,
  db : ObjectDb,
  rfs : &@bit.RepoFileSystem,
  root : String,
  git_dir : String,
  map : Map[String, TreeEntryInfo],
  except : Array[String],
) -> Unit raise @bit.GitError {
  let autocrlf = read_autocrlf_setting(rfs, git_dir)
  let core_eol = read_core_eol_setting(rfs, git_dir)
  let except_set : Map[String, Bool] = Map([])
  for path in except {
    except_set[path] = true
  }
  for path, info in map {
    if except_set.contains(path) {
      continue // Skip conflicting files
    }
    let full = join_path(root, path)
    if is_gitlink_mode_int(info.mode) {
      fs.mkdir_p(full)
      continue
    }
    if rfs.is_dir(full) {
      let bit_marker = join_path(full, ".git")
      if rfs.is_file(bit_marker) || rfs.is_dir(bit_marker) {
        raise @bit.GitError::InvalidObject(
          "Refusing to overwrite submodule: \{path}",
        )
      }
    }
    let obj = db.get(rfs, info.id)
    match obj {
      Some(o) => {
        if o.obj_type != @bit.ObjectType::Blob {
          raise @bit.GitError::InvalidObject("Object is not a blob")
        }
        let dir = rebase_parent_dir(full)
        fs.mkdir_p(dir)
        let attrs = resolve_eol_attrs(rfs, root, path)
        let output = smudge_for_checkout(o.data, attrs, autocrlf, core_eol~)
        fs.write_file(full, output)
      }
      None => raise @bit.GitError::InvalidObject("Missing blob object")
    }
  }
}

///|
/// Same as `rebase_write_worktree`, but also runs the external filter
/// driver's smudge command (from `.gitattributes`' `filter=name`) on each
/// blob before writing it, matching git's checkout-time content conversion.
async fn rebase_write_worktree_filtered(
  fs : &@bit.FileSystem,
  db : ObjectDb,
  rfs : &@bit.RepoFileSystem,
  root : String,
  git_dir : String,
  map : Map[String, TreeEntryInfo],
  run_filter_cmd? : FilterCmd,
) -> Unit raise @bit.GitError {
  let files : Map[String, TreeFileEntry] = Map([])
  for path, info in map {
    files[path] = { id: info.id, mode: info.mode }
  }
  tree_ops_remove_missing_paths(fs, rfs, root, git_dir, files, false)
  rebase_write_worktree_except_filtered(
    fs, db, rfs, root, git_dir, map, [], run_filter_cmd?,
  )
}

///|
/// Same as `rebase_write_worktree_except`, but also runs the external
/// filter driver's smudge command on each blob before writing it.
async fn rebase_write_worktree_except_filtered(
  fs : &@bit.FileSystem,
  db : ObjectDb,
  rfs : &@bit.RepoFileSystem,
  root : String,
  git_dir : String,
  map : Map[String, TreeEntryInfo],
  except : Array[String],
  run_filter_cmd? : FilterCmd,
) -> Unit raise @bit.GitError {
  let autocrlf = read_autocrlf_setting(rfs, git_dir)
  let core_eol = read_core_eol_setting(rfs, git_dir)
  let except_set : Map[String, Bool] = Map([])
  for path in except {
    except_set[path] = true
  }
  for path, info in map {
    if except_set.contains(path) {
      continue // Skip conflicting files
    }
    let full = join_path(root, path)
    if is_gitlink_mode_int(info.mode) {
      fs.mkdir_p(full)
      continue
    }
    if rfs.is_dir(full) {
      let bit_marker = join_path(full, ".git")
      if rfs.is_file(bit_marker) || rfs.is_dir(bit_marker) {
        raise @bit.GitError::InvalidObject(
          "Refusing to overwrite submodule: \{path}",
        )
      }
    }
    let obj = db.get(rfs, info.id)
    match obj {
      Some(o) => {
        if o.obj_type != @bit.ObjectType::Blob {
          raise @bit.GitError::InvalidObject("Object is not a blob")
        }
        let dir = rebase_parent_dir(full)
        fs.mkdir_p(dir)
        let attrs = resolve_eol_attrs(rfs, root, path)
        let filtered = apply_filter_smudge(
          rfs, o.data, attrs, root, git_dir, run_filter_cmd,
        )
        let output = smudge_for_checkout(filtered, attrs, autocrlf, core_eol~)
        fs.write_file(full, output)
      }
      None => raise @bit.GitError::InvalidObject("Missing blob object")
    }
  }
}

///|
fn rebase_map_to_index(
  db : ObjectDb,
  fs : &@bit.RepoFileSystem,
  map : Map[String, TreeEntryInfo],
) -> Array[IndexEntry] raise @bit.GitError {
  let entries : Array[IndexEntry] = []
  for path, e in map {
    if is_gitlink_mode_int(e.mode) {
      entries.push({
        path,
        id: e.id,
        mode: e.mode,
        size: 0,
        mtime_sec: 0,
        mtime_nsec: 0,
        intent_to_add: false,
        dev: 0,
        ino: 0,
        uid: 0,
        gid: 0,
      })
      continue
    }
    let obj = db.get(fs, e.id)
    match obj {
      Some(o) => {
        if o.obj_type != @bit.ObjectType::Blob {
          raise @bit.GitError::InvalidObject("Object is not a blob")
        }
        entries.push({
          path,
          id: e.id,
          mode: e.mode,
          size: o.data.length(),
          mtime_sec: 0,
          mtime_nsec: 0,
          intent_to_add: false,
          dev: 0,
          ino: 0,
          uid: 0,
          gid: 0,
        })
      }
      None => raise @bit.GitError::InvalidObject("Missing blob object")
    }
  }
  entries.sort_by((a, b) => String::compare(a.path, b.path))
  entries
}

///|
fn rebase_update_head(
  fs : &@bit.FileSystem,
  rfs : &@bit.RepoFileSystem,
  git_dir : String,
  commit_id : @bit.ObjectId,
) -> Unit raise @bit.GitError {
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
  fs : &@bit.RepoFileSystem,
  commit_id : @bit.ObjectId,
) -> RebaseCommitInfo raise @bit.GitError {
  let obj = db.get(fs, commit_id)
  match obj {
    None => raise @bit.GitError::InvalidObject("Missing commit object")
    Some(o) => {
      if o.obj_type != @bit.ObjectType::Commit {
        raise @bit.GitError::InvalidObject("Object is not a commit")
      }
      rebase_parse_commit_content(o.data)
    }
  }
}

///|
fn rebase_parse_commit_content(
  data : Bytes,
) -> RebaseCommitInfo raise @bit.GitError {
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
  let mut tree_id : @bit.ObjectId? = None
  let parents : Array[@bit.ObjectId] = []
  let mut author = ""
  let mut author_time = 0L
  let mut author_tz = "+0000"
  let mut committer = ""
  let mut commit_time = 0L
  let mut committer_tz = "+0000"
  for line_view in header.split("\n") {
    let line = line_view.to_owned()
    if line.has_prefix("tree ") {
      let hex = String::unsafe_substring(line, start=5, end=line.length())
      tree_id = hex |> @bit.ObjectId::from_hex |> Some
    } else if line.has_prefix("parent ") {
      let hex = String::unsafe_substring(line, start=7, end=line.length())
      parents.push(@bit.ObjectId::from_hex(hex))
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
    None => raise @bit.GitError::InvalidObject("Missing tree in commit")
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
  fs : &@bit.FileSystem,
  rfs : &@bit.RepoFileSystem,
  git_dir : String,
  id : @bit.ObjectId,
  compressed : Bytes,
) -> Unit raise @bit.GitError {
  // A linked worktree's git dir has no objects/ of its own; write through
  // to the shared object store (main repo's git dir via "commondir").
  let git_dir = object_storage_git_dir(rfs, git_dir)
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
  fs.write_file(path, compressed) catch {
    // Loose objects may already exist as read-only files.
    @bit.GitError::IoError(msg) if msg.contains("Permission denied") => {
      fs.remove_file(path) catch {
        _ => raise @bit.GitError::IoError(msg)
      }
      fs.write_file(path, compressed)
    }
    err => raise err
  }
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
  @string_utils.mode_to_string(mode)
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
  fs : &@bit.RepoFileSystem,
  git_dir : String,
) -> Bool {
  let state_dir = join_path(git_dir, "rebase-merge")
  fs.is_dir(state_dir)
}

///|
/// Save rebase state to .git/rebase-merge/
fn save_rebase_state(
  fs : &@bit.FileSystem,
  git_dir : String,
  state : RebaseState,
) -> Unit raise @bit.GitError {
  let state_dir = join_path(git_dir, "rebase-merge")
  fs.mkdir_p(state_dir)
  fs.write_string(join_path(state_dir, "onto"), state.onto.to_hex() + "\n")
  fs.write_string(
    join_path(state_dir, "orig-head"),
    state.orig_head.to_hex() + "\n",
  )
  fs.write_string(join_path(state_dir, "head-name"), state.head_name + "\n")
  // Write todo list
  let todo_lines = state.todo.map(id => "pick " + id.to_hex())
  fs.write_string(
    join_path(state_dir, "git-rebase-todo"),
    todo_lines.join("\n") + "\n",
  )
  // Write done list
  let done_lines = state.done.map(id => "pick " + id.to_hex())
  fs.write_string(
    join_path(state_dir, "done"),
    if done_lines.length() > 0 {
      done_lines.join("\n") + "\n"
    } else {
      ""
    },
  )
  // Write current commit info
  match state.current {
    Some(id) => {
      fs.write_string(join_path(state_dir, "stopped-sha"), id.to_hex() + "\n")
      // REBASE_HEAD points to the commit being applied (used by hooks/tools)
      fs.write_string(join_path(git_dir, "REBASE_HEAD"), id.to_hex() + "\n")
      fs.write_string(join_path(state_dir, "message"), state.message)
      fs.write_string(
        join_path(state_dir, "author-script"),
        "GIT_AUTHOR_NAME='\{state.author}'\nGIT_AUTHOR_DATE='\{state.author_time} \{state.author_tz}'\n",
      )
    }
    None => ()
  }
  // Write rewritten-list: "<old sha> <new sha>" per line, matching git's
  // own on-disk format (used to drive notes.rewrite.rebase copying).
  if state.rewritten.length() > 0 {
    let rewritten_lines = state.rewritten.map(pair => pair.0.to_hex() +
      " " +
      pair.1.to_hex())
    fs.write_string(
      join_path(state_dir, "rewritten-list"),
      rewritten_lines.join("\n") + "\n",
    )
  }
}

///|
/// Load rebase state from .git/rebase-merge/
pub fn load_rebase_state(
  fs : &@bit.RepoFileSystem,
  git_dir : String,
) -> RebaseState? raise @bit.GitError {
  let state_dir = join_path(git_dir, "rebase-merge")
  if !fs.is_dir(state_dir) {
    return None
  }
  let onto_hex = read_file_trimmed(fs, join_path(state_dir, "onto"))
  let orig_head_hex = read_file_trimmed(fs, join_path(state_dir, "orig-head"))
  let head_name = read_file_trimmed(fs, join_path(state_dir, "head-name"))
  let todo = parse_todo_file(fs, join_path(state_dir, "git-rebase-todo"))
  let done = parse_todo_file(fs, join_path(state_dir, "done"))
  let current = if fs.is_file(join_path(state_dir, "stopped-sha")) {
    let hex = read_file_trimmed(fs, join_path(state_dir, "stopped-sha"))
    hex |> @bit.ObjectId::from_hex |> Some
  } else {
    None
  }
  let message = if fs.is_file(join_path(state_dir, "message")) {
    @utf8.decode_lossy(fs.read_file(join_path(state_dir, "message"))[:])
  } else {
    ""
  }
  let rewritten_list_path = join_path(state_dir, "rewritten-list")
  let rewritten : Array[(@bit.ObjectId, @bit.ObjectId)] = if fs.is_file(
    rewritten_list_path,
  ) {
    let content = @utf8.decode_lossy(fs.read_file(rewritten_list_path)[:])
    let out : Array[(@bit.ObjectId, @bit.ObjectId)] = []
    for line_view in content.split("\n") {
      let line = line_view.to_owned()
      if line.length() == 0 {
        continue
      }
      match line.find(" ") {
        Some(idx) => {
          let old_hex = String::unsafe_substring(line, start=0, end=idx)
          let new_hex = String::unsafe_substring(
            line,
            start=idx + 1,
            end=line.length(),
          )
          out.push(
            (@bit.ObjectId::from_hex(old_hex), @bit.ObjectId::from_hex(new_hex)),
          )
        }
        None => ()
      }
    }
    out
  } else {
    []
  }
  Some({
    onto: @bit.ObjectId::from_hex(onto_hex),
    orig_head: @bit.ObjectId::from_hex(orig_head_hex),
    head_name,
    todo,
    done,
    current,
    message,
    author: "",
    author_time: 0L,
    author_tz: "+0000",
    rewritten,
  })
}

///|
fn read_file_trimmed(fs : &@bit.RepoFileSystem, path : String) -> String {
  let content = @utf8.decode_lossy(
    (fs.read_file(path) catch { _ => Default::default() })[:],
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
  fs : &@bit.RepoFileSystem,
  path : String,
) -> Array[@bit.ObjectId] {
  let result : Array[@bit.ObjectId] = []
  if !fs.is_file(path) {
    return result
  }
  let content = @utf8.decode_lossy(
    (fs.read_file(path) catch { _ => Default::default() })[:],
  )
  for line_view in content.split("\n") {
    let line = line_view.to_owned()
    if line.length() == 0 || line.has_prefix("#") {
      continue
    }
    // Format: "pick <sha>" or just "<sha>"
    let parts = line.split(" ").map(v => v.to_owned()).collect()
    if parts.length() >= 2 && parts[0] == "pick" {
      let id = @bit.ObjectId::from_hex(parts[1]) catch { _ => continue }
      result.push(id)
    } else if parts.length() >= 1 &&
      (parts[0].length() == 40 || parts[0].length() == 64) {
      let id = @bit.ObjectId::from_hex(parts[0]) catch { _ => continue }
      result.push(id)
    }
  }
  result
}

///|
/// Clear rebase state (remove .git/rebase-merge/)
pub fn clear_rebase_state(
  fs : &@bit.FileSystem,
  rfs : &@bit.RepoFileSystem,
  git_dir : String,
) -> Unit raise @bit.GitError {
  let state_dir = join_path(git_dir, "rebase-merge")
  if !rfs.is_dir(state_dir) {
    return ()
  }
  // Remove all files in state_dir
  let files = rfs.readdir(state_dir)
  for file in files {
    let path = join_path(state_dir, file)
    if rfs.is_dir(path) {
      fs.remove_dir(path) catch {
        _ => ()
      }
    } else {
      fs.remove_file(path) catch {
        _ => ()
      }
    }
  }
  // Remove the directory
  fs.remove_dir(state_dir) catch {
    _ => ()
  }
  // Remove REBASE_HEAD from git_dir root (written on conflict)
  let rebase_head = join_path(git_dir, "REBASE_HEAD")
  if rfs.is_file(rebase_head) {
    fs.remove_file(rebase_head) catch {
      _ => ()
    }
  }
}

///|
/// Start a rebase operation. Returns RebaseResult indicating status.
pub async fn rebase_start(
  fs : &@bit.FileSystem,
  rfs : &@bit.RepoFileSystem,
  root : String,
  upstream : @bit.ObjectId,
  run_filter_cmd? : FilterCmd,
) -> RebaseResult raise @bit.GitError {
  rebase_start_with_onto(fs, rfs, root, upstream, upstream, run_filter_cmd?)
}

///|
/// Start a rebase operation with an explicit new base.
pub async fn rebase_start_with_onto(
  fs : &@bit.FileSystem,
  rfs : &@bit.RepoFileSystem,
  root : String,
  onto : @bit.ObjectId,
  upstream : @bit.ObjectId,
  force_rebase? : Bool = false,
  run_filter_cmd? : FilterCmd,
) -> RebaseResult raise @bit.GitError {
  let git_dir = rebase_resolve_git_dir(rfs, root)
  // Check if rebase already in progress
  if is_rebase_in_progress(rfs, git_dir) {
    raise @bit.GitError::InvalidObject(
      "A rebase is already in progress. Use --continue, --abort, or --skip.",
    )
  }
  let head = resolve_head_commit(rfs, git_dir)
  match head {
    None => {
      fast_forward_to(fs, rfs, root, onto, run_filter_cmd?)
      return {
        status: RebaseStatus::Complete,
        commit_id: Some(onto),
        conflicts: [],
        rewritten: [],
      }
    }
    Some(h) => {
      if !force_rebase && h == onto && h == upstream {
        return {
          status: RebaseStatus::NothingToRebase,
          commit_id: Some(h),
          conflicts: [],
          rewritten: [],
        }
      }
      let db = ObjectDb::load(rfs, git_dir)
      let chain = rebase_collect_chain(db, rfs, h, upstream)
      if chain.length() == 0 {
        if !force_rebase {
          if h != onto {
            fast_forward_to(fs, rfs, root, onto, run_filter_cmd?)
            return {
              status: RebaseStatus::Complete,
              commit_id: Some(onto),
              conflicts: [],
              rewritten: [],
            }
          }
          return {
            status: RebaseStatus::NothingToRebase,
            commit_id: Some(h),
            conflicts: [],
            rewritten: [],
          }
        }
      }
      // Get head name for later restoration
      let head_name = match read_head_ref(rfs, git_dir) {
        HeadRef::Branch(name) => "refs/heads/" + name
        HeadRef::Detached(_) => ""
      }
      let onto_map = rebase_tree_map(db, rfs, onto)
      rebase_check_untracked_conflicts(rfs, git_dir, root, onto_map)
      // Create initial state
      let state : RebaseState = {
        onto,
        orig_head: h,
        head_name,
        todo: chain,
        done: [],
        current: None,
        message: "",
        author: "",
        author_time: 0L,
        author_tz: "+0000",
        rewritten: [],
      }
      save_rebase_state(fs, git_dir, state)
      // Move HEAD to the new base before applying commits.
      rebase_update_head(fs, rfs, git_dir, onto)
      rebase_write_worktree_filtered(fs, db, rfs, root, git_dir, onto_map, run_filter_cmd?)
      let entries = rebase_map_to_index(db, rfs, onto_map)
      write_index_entries(fs, git_dir, entries)
      // Start applying commits
      rebase_apply_next(fs, rfs, root, state, run_filter_cmd?)
    }
  }
}

///|
/// Continue rebase after resolving conflicts.
pub async fn rebase_continue(
  fs : &@bit.FileSystem,
  rfs : &@bit.RepoFileSystem,
  root : String,
  run_filter_cmd? : FilterCmd,
) -> RebaseResult raise @bit.GitError {
  let git_dir = rebase_resolve_git_dir(rfs, root)
  let state = load_rebase_state(rfs, git_dir)
  guard state is Some(s) else {
    raise @bit.GitError::InvalidObject("No rebase in progress")
  }
  // Commit the resolved changes
  guard s.current is Some(current_id) else {
    raise @bit.GitError::InvalidObject("No commit to continue")
  }
  let db = ObjectDb::load(rfs, git_dir)
  let info = rebase_parse_commit_full(db, rfs, current_id)
  // Get current HEAD as parent
  let head = resolve_head_commit(rfs, git_dir)
  guard head is Some(parent) else {
    raise @bit.GitError::InvalidObject("No HEAD commit")
  }
  // Build tree from current index
  let entries = read_index_entries(rfs, git_dir)
  let new_tree = write_tree_from_entries(fs, rfs, git_dir, entries, None)
  // Create new commit with original author info
  let new_commit = @bit.Commit::new(
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
  let (new_id, compressed) = @bit.create_commit(new_commit)
  rebase_write_object(fs, rfs, git_dir, new_id, compressed)
  rebase_update_head(fs, rfs, git_dir, new_id)
  // Update state: move current to done, clear current
  let new_done = s.done.copy()
  new_done.push(current_id)
  let new_todo = s.todo.copy()
  if new_todo.length() > 0 {
    ignore(new_todo.remove(0))
  }
  let new_rewritten = s.rewritten.copy()
  new_rewritten.push((current_id, new_id))
  let new_state : RebaseState = {
    onto: s.onto,
    orig_head: s.orig_head,
    head_name: s.head_name,
    todo: new_todo,
    done: new_done,
    current: None,
    message: "",
    author: "",
    author_time: 0L,
    author_tz: "+0000",
    rewritten: new_rewritten,
  }
  save_rebase_state(fs, git_dir, new_state)
  // Continue with next commits
  rebase_apply_next(fs, rfs, root, new_state, run_filter_cmd?)
}

///|
/// Abort the current rebase and restore original state.
pub async fn rebase_abort(
  fs : &@bit.FileSystem,
  rfs : &@bit.RepoFileSystem,
  root : String,
  run_filter_cmd? : FilterCmd,
) -> Unit raise @bit.GitError {
  let git_dir = rebase_resolve_git_dir(rfs, root)
  let state = load_rebase_state(rfs, git_dir)
  guard state is Some(s) else {
    raise @bit.GitError::InvalidObject("No rebase in progress")
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
  rebase_write_worktree_filtered(fs, db, rfs, root, git_dir, tree_map, run_filter_cmd?) catch {
    _ => ()
  }
  let entries = rebase_map_to_index(db, rfs, tree_map) catch { _ => [] }
  write_index_entries(fs, git_dir, entries) catch {
    _ => ()
  }
  // Clear rebase state
  clear_rebase_state(fs, rfs, git_dir)
}

///|
/// Skip the current commit and continue rebase.
pub async fn rebase_skip(
  fs : &@bit.FileSystem,
  rfs : &@bit.RepoFileSystem,
  root : String,
  run_filter_cmd? : FilterCmd,
) -> RebaseResult raise @bit.GitError {
  let git_dir = rebase_resolve_git_dir(rfs, root)
  let state = load_rebase_state(rfs, git_dir)
  guard state is Some(s) else {
    raise @bit.GitError::InvalidObject("No rebase in progress")
  }
  guard s.current is Some(_) else {
    raise @bit.GitError::InvalidObject("No commit to skip")
  }
  // Drop the current commit from the remaining todo list.
  let new_todo = s.todo.copy()
  if new_todo.length() > 0 {
    ignore(new_todo.remove(0))
  }
  let new_state : RebaseState = {
    onto: s.onto,
    orig_head: s.orig_head,
    head_name: s.head_name,
    todo: new_todo,
    done: s.done,
    current: None,
    message: "",
    author: "",
    author_time: 0L,
    author_tz: "+0000",
    rewritten: s.rewritten,
  }
  save_rebase_state(fs, git_dir, new_state)
  // Reset worktree to current HEAD
  let db = ObjectDb::load(rfs, git_dir)
  let head = resolve_head_commit(rfs, git_dir)
  guard head is Some(h) else {
    raise @bit.GitError::InvalidObject("No HEAD commit")
  }
  let tree_map = rebase_tree_map(db, rfs, h)
  rebase_write_worktree_filtered(fs, db, rfs, root, git_dir, tree_map, run_filter_cmd?)
  let entries = rebase_map_to_index(db, rfs, tree_map)
  write_index_entries(fs, git_dir, entries)
  // Continue with next commits
  rebase_apply_next(fs, rfs, root, new_state, run_filter_cmd?)
}

///|
fn rebase_tree_entry_matches(
  lhs : TreeEntryInfo?,
  rhs : TreeEntryInfo?,
) -> Bool {
  match (lhs, rhs) {
    (Some(left), Some(right)) => left.id == right.id && left.mode == right.mode
    (None, None) => true
    _ => false
  }
}

///|
fn rebase_compute_patch_id(
  db : ObjectDb,
  fs : &@bit.RepoFileSystem,
  commit_id : @bit.ObjectId,
) -> String {
  let obj = db.get(fs, commit_id) catch { _ => return commit_id.to_hex() }
  match obj {
    Some(o) if o.obj_type == @bit.ObjectType::Commit => {
      let info = @bit.parse_commit(o.data) catch {
        _ => return commit_id.to_hex()
      }
      let tree_entries = rebase_get_patch_tree_entries(db, fs, info.tree, "")
      let parent_entries : Array[(String, String)] = if info.parents.length() >
        0 {
        let parent_obj = db.get(fs, info.parents[0]) catch {
          _ => return commit_id.to_hex()
        }
        match parent_obj {
          Some(parent_commit) if parent_commit.obj_type ==
            @bit.ObjectType::Commit => {
            let parent_info = @bit.parse_commit(parent_commit.data) catch {
              _ => return commit_id.to_hex()
            }
            rebase_get_patch_tree_entries(db, fs, parent_info.tree, "")
          }
          _ => []
        }
      } else {
        []
      }
      let diff = rebase_compute_patch_tree_diff(parent_entries, tree_entries)
      diff.sort_by((a, b) => a.0.compare(b.0))
      let parts : Array[String] = []
      for item in diff {
        let (path, change) = item
        parts.push(path + ":" + change)
      }
      let content = parts.join("\n")
      let bytes = Bytes::from_array(
        FixedArray::makei(content.length(), fn(i) {
          content[i].to_int().to_byte()
        }),
      )
      @bit.sha1(bytes).to_hex()
    }
    _ => commit_id.to_hex()
  }
}

///|
fn rebase_get_patch_tree_entries(
  db : ObjectDb,
  fs : &@bit.RepoFileSystem,
  tree_id : @bit.ObjectId,
  prefix : String,
) -> Array[(String, String)] {
  let result : Array[(String, String)] = []
  let obj = db.get(fs, tree_id) catch { _ => return result }
  match obj {
    Some(o) if o.obj_type == @bit.ObjectType::Tree => {
      let entries = @bit.parse_tree(o.data) catch { _ => return result }
      for entry in entries {
        let path = if prefix.length() == 0 {
          entry.name
        } else {
          prefix + "/" + entry.name
        }
        if entry.mode.has_prefix("04") {
          for sub in rebase_get_patch_tree_entries(db, fs, entry.id, path) {
            result.push(sub)
          }
        } else {
          result.push((path, entry.id.to_hex() + ":" + entry.mode))
        }
      }
    }
    _ => ()
  }
  result
}

///|
fn rebase_compute_patch_tree_diff(
  parent : Array[(String, String)],
  current : Array[(String, String)],
) -> Array[(String, String)] {
  let parent_map : Map[String, String] = Map([])
  for item in parent {
    let (path, id) = item
    parent_map[path] = id
  }
  let diff : Array[(String, String)] = []
  for item in current {
    let (path, id) = item
    match parent_map.get(path) {
      Some(parent_id) => if parent_id != id { diff.push((path, "M:" + id)) }
      None => diff.push((path, "A:" + id))
    }
  }
  let current_map : Map[String, String] = Map([])
  for item in current {
    let (path, id) = item
    current_map[path] = id
  }
  for item in parent {
    let (path, _) = item
    if !current_map.contains(path) {
      diff.push((path, "D"))
    }
  }
  diff
}

///|
fn rebase_patch_id_exists_in_ancestors(
  db : ObjectDb,
  fs : &@bit.RepoFileSystem,
  commit_id : @bit.ObjectId,
  head_id : @bit.ObjectId,
) -> Bool raise @bit.GitError {
  let target_patch_id = rebase_compute_patch_id(db, fs, commit_id)
  let visited : Map[String, Bool] = Map([])
  let queue : Array[@bit.ObjectId] = [head_id]
  while queue.length() > 0 {
    let current = queue.remove(0)
    let hex = current.to_hex()
    if visited.contains(hex) {
      continue
    }
    visited[hex] = true
    if rebase_compute_patch_id(db, fs, current) == target_patch_id {
      return true
    }
    let obj = db.get(fs, current)
    match obj {
      Some(o) if o.obj_type == @bit.ObjectType::Commit => {
        let info = @bit.parse_commit(o.data)
        for parent in info.parents {
          queue.push(parent)
        }
      }
      _ => ()
    }
  }
  false
}

///|
fn rebase_change_already_applied(
  db : ObjectDb,
  rfs : &@bit.RepoFileSystem,
  base : Map[String, TreeEntryInfo],
  parent_map : Map[String, TreeEntryInfo],
  ch : Change,
) -> Bool {
  let current = base.get(ch.path)
  match ch.kind {
    ChangeKind::Added => rebase_tree_entry_matches(current, ch.entry)
    ChangeKind::Deleted => current is None
    ChangeKind::Modified =>
      match (current, parent_map.get(ch.path), ch.entry) {
        (Some(base_entry), Some(parent_entry), Some(target_entry)) => {
          if base_entry.id == target_entry.id &&
            base_entry.mode == target_entry.mode {
            return true
          }
          if base_entry.mode != parent_entry.mode ||
            base_entry.mode != target_entry.mode {
            return false
          }
          let base_data = rebase_get_blob_data(db, rfs, base_entry.id)
          let parent_data = rebase_get_blob_data(db, rfs, parent_entry.id)
          let target_data = rebase_get_blob_data(db, rfs, target_entry.id)
          if @diff3.is_binary_content(base_data) ||
            @diff3.is_binary_content(parent_data) ||
            @diff3.is_binary_content(target_data) {
            return false
          }
          let base_content = get_blob_content(db, rfs, base_entry.id)
          let parent_content = get_blob_content(db, rfs, parent_entry.id)
          let target_content = get_blob_content(db, rfs, target_entry.id)
          let merge_result = @diff3.content_merge(
            parent_content,
            base_content,
            target_content,
            @diff3.ContentMergeOptions::default(),
          )
          !merge_result.has_conflicts && merge_result.content == base_content
        }
        _ => false
      }
  }
}

///|
fn rebase_changes_already_applied(
  db : ObjectDb,
  rfs : &@bit.RepoFileSystem,
  base : Map[String, TreeEntryInfo],
  parent_map : Map[String, TreeEntryInfo],
  changes : Array[Change],
) -> Bool {
  if changes.length() == 0 {
    return false
  }
  for ch in changes {
    if !rebase_change_already_applied(db, rfs, base, parent_map, ch) {
      return false
    }
  }
  true
}

///|
/// Apply the next commit in the todo list.
async fn rebase_apply_next(
  fs : &@bit.FileSystem,
  rfs : &@bit.RepoFileSystem,
  root : String,
  state : RebaseState,
  run_filter_cmd? : FilterCmd,
) -> RebaseResult raise @bit.GitError {
  let git_dir = rebase_resolve_git_dir(rfs, root)
  let db = ObjectDb::load(rfs, git_dir)
  if state.todo.length() == 0 {
    // All done, finalize rebase
    // Restore branch ref if applicable
    let head = resolve_head_commit(rfs, git_dir)
    guard head is Some(final_id) else {
      raise @bit.GitError::InvalidObject("No HEAD after rebase")
    }
    let final_tree_map = rebase_tree_map(db, rfs, final_id)
    rebase_write_worktree_filtered(fs, db, rfs, root, git_dir, final_tree_map, run_filter_cmd?)
    let final_entries = rebase_map_to_index(db, rfs, final_tree_map)
    write_index_entries(fs, git_dir, final_entries)
    clear_rebase_state(fs, rfs, git_dir)
    if state.head_name.length() > 0 {
      let head_path = join_path(git_dir, "HEAD")
      fs.write_string(head_path, "ref: " + state.head_name + "\n")
      let ref_path = join_path(git_dir, state.head_name)
      fs.write_string(ref_path, final_id.to_hex() + "\n")
    }
    return {
      status: RebaseStatus::Complete,
      commit_id: head,
      conflicts: [],
      rewritten: state.rewritten,
    }
  }
  let commit_id = state.todo[0]
  let info = rebase_parse_commit_full(db, rfs, commit_id)
  let parent_id = if info.parents.length() > 0 {
    info.parents[0]
  } else {
    raise @bit.GitError::InvalidObject("Cannot rebase root commit")
  }
  // Get current HEAD as the base
  let head = resolve_head_commit(rfs, git_dir)
  guard head is Some(base_id) else {
    raise @bit.GitError::InvalidObject("No HEAD commit")
  }
  let base_map = rebase_tree_map(db, rfs, base_id)
  let parent_map = rebase_tree_map(db, rfs, parent_id)
  let commit_map = rebase_tree_map_from_tree(db, rfs, info.tree)
  let changes = rebase_diff_maps(parent_map, commit_map)
  if rebase_patch_id_exists_in_ancestors(db, rfs, commit_id, base_id) ||
    rebase_changes_already_applied(db, rfs, base_map, parent_map, changes) {
    let new_todo = state.todo.copy()
    ignore(new_todo.remove(0))
    let new_state : RebaseState = {
      onto: state.onto,
      orig_head: state.orig_head,
      head_name: state.head_name,
      todo: new_todo,
      done: state.done,
      current: None,
      message: "",
      author: "",
      author_time: 0L,
      author_tz: "+0000",
      rewritten: state.rewritten,
    }
    save_rebase_state(fs, git_dir, new_state)
    return rebase_apply_next(fs, rfs, root, new_state, run_filter_cmd?)
  }
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
      rewritten: state.rewritten,
    }
    save_rebase_state(fs, git_dir, new_state)
    // Write partially merged state to worktree and index (skip conflicting files)
    rebase_write_worktree_except_filtered(
      fs, db, rfs, root, git_dir, base_map, conflicts, run_filter_cmd?,
    )
    let entries = rebase_map_to_index(db, rfs, base_map)
    write_index_entries(fs, git_dir, entries)
    return {
      status: RebaseStatus::Conflict,
      commit_id: Some(commit_id),
      conflicts,
      rewritten: state.rewritten,
    }
  }
  // No conflicts - create new commit
  let new_tree = rebase_write_tree_from_map(fs, rfs, git_dir, base_map)
  let new_commit = @bit.Commit::new(
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
  let (new_id, compressed) = @bit.create_commit(new_commit)
  rebase_write_object(fs, rfs, git_dir, new_id, compressed)
  rebase_update_head(fs, rfs, git_dir, new_id)
  // Update state and continue
  let new_done = state.done.copy()
  new_done.push(commit_id)
  let new_todo = state.todo.copy()
  ignore(new_todo.remove(0))
  let new_rewritten = state.rewritten.copy()
  new_rewritten.push((commit_id, new_id))
  let new_state : RebaseState = {
    onto: state.onto,
    orig_head: state.orig_head,
    head_name: state.head_name,
    todo: new_todo,
    done: new_done,
    current: None,
    message: "",
    author: "",
    author_time: 0L,
    author_tz: "+0000",
    rewritten: new_rewritten,
  }
  save_rebase_state(fs, git_dir, new_state)
  // Recursively apply next
  rebase_apply_next(fs, rfs, root, new_state, run_filter_cmd?)
}

///|
/// Apply changes with conflict detection and conflict markers.
fn rebase_apply_changes_with_conflicts(
  db : ObjectDb,
  rfs : &@bit.RepoFileSystem,
  fs : &@bit.FileSystem,
  root : String,
  base : Map[String, TreeEntryInfo],
  parent_map : Map[String, TreeEntryInfo],
  changes : Array[Change],
) -> Array[String] raise @bit.GitError {
  let conflicts : Array[String] = []
  for ch in changes {
    let path = ch.path
    match ch.kind {
      ChangeKind::Added =>
        if base.contains(path) {
          // Conflict: file exists in base but commit adds it
          let base_entry = base.get(path).unwrap()
          let new_entry = ch.entry.unwrap()
          if base_entry.id != new_entry.id {
            // Write conflict markers
            write_conflict_file(
              db,
              rfs,
              fs,
              root,
              path,
              Some(base_entry),
              None,
              Some(new_entry),
            )
            conflicts.push(path)
          }
          // If same content, just keep base version
        } else {
          base[path] = ch.entry.unwrap()
        }
      ChangeKind::Deleted =>
        match (base.get(path), parent_map.get(path)) {
          (Some(b), Some(p)) =>
            if b.id != p.id || b.mode != p.mode {
              // Conflict: base modified, but commit deletes
              conflicts.push(path)
              // Keep base version with marker
              write_conflict_file(
                db,
                rfs,
                fs,
                root,
                path,
                Some(b),
                Some(p),
                None,
              )
            } else {
              base.remove(path)
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
          (Some(b), Some(p)) =>
            if b.id != p.id || b.mode != p.mode {
              // Try content-level merge before falling back to conflict markers
              let merge_base_content = get_blob_content(db, rfs, p.id)
              let ours_content = get_blob_content(db, rfs, b.id)
              let theirs_content = get_blob_content(db, rfs, entry.id)
              let ours_data = rebase_get_blob_data(db, rfs, b.id)
              let theirs_data = rebase_get_blob_data(db, rfs, entry.id)
              if @diff3.is_binary_content(ours_data) ||
                @diff3.is_binary_content(theirs_data) {
                write_conflict_file(
                  db,
                  rfs,
                  fs,
                  root,
                  path,
                  Some(b),
                  Some(p),
                  Some(entry),
                )
                conflicts.push(path)
              } else {
                let merge_result = @diff3.content_merge(
                  merge_base_content,
                  ours_content,
                  theirs_content,
                  @diff3.ContentMergeOptions::default(),
                )
                if merge_result.has_conflicts {
                  // Write conflict markers
                  let full_path = join_path(root, path)
                  let dir = rebase_parent_dir(full_path)
                  fs.mkdir_p(dir)
                  fs.write_string(full_path, merge_result.content)
                  conflicts.push(path)
                } else {
                  // Clean merge - create new blob and update base map
                  let content_bytes = @utf8.encode(merge_result.content)
                  let (blob_id, compressed) = @bit.create_blob(content_bytes)
                  rebase_write_object(
                    fs,
                    rfs,
                    rebase_resolve_git_dir(rfs, root),
                    blob_id,
                    compressed,
                  )
                  base[path] = { id: blob_id, mode: entry.mode }
                }
              }
            } else {
              // Base matches parent, apply modification
              base[path] = entry
            }
          (None, None) => base[path] = entry
          (None, Some(p)) => {
            // File was deleted in base but modified in commit
            write_conflict_file(
              db,
              rfs,
              fs,
              root,
              path,
              None,
              Some(p),
              Some(entry),
            )
            conflicts.push(path)
            base[path] = entry
          }
          (Some(b), None) => {
            // File added in base, modified in commit (from nothing to something)
            if b.id != entry.id {
              write_conflict_file(
                db,
                rfs,
                fs,
                root,
                path,
                Some(b),
                None,
                Some(entry),
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
/// Write a file with conflict markers using content_merge with diff3 style.
fn write_conflict_file(
  db : ObjectDb,
  rfs : &@bit.RepoFileSystem,
  fs : &@bit.FileSystem,
  root : String,
  path : String,
  ours : TreeEntryInfo?,
  base : TreeEntryInfo?,
  theirs : TreeEntryInfo?,
) -> Unit raise @bit.GitError {
  let full_path = join_path(root, path)
  let dir = rebase_parent_dir(full_path)
  fs.mkdir_p(dir)
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
  let opts : @diff3.ContentMergeOptions = {
    conflict_style: @diff3.ConflictStyle::Diff3,
    ours_label: "HEAD",
    base_label: "parent",
    theirs_label: "incoming",
    marker_size: 7,
    favor: @diff3.MergeFavor::NoFavor,
  }
  let result = @diff3.content_merge(
    base_content, ours_content, theirs_content, opts,
  )
  fs.write_string(full_path, result.content)
}

///|
fn rebase_get_blob_data(
  db : ObjectDb,
  fs : &@bit.RepoFileSystem,
  id : @bit.ObjectId,
) -> Bytes {
  let obj = db.get(fs, id) catch { _ => return Default::default() }
  match obj {
    Some(o) =>
      if o.obj_type == @bit.ObjectType::Blob {
        o.data
      } else {
        Default::default()
      }
    None => Default::default()
  }
}

///|
fn get_blob_content(
  db : ObjectDb,
  fs : &@bit.RepoFileSystem,
  id : @bit.ObjectId,
) -> String {
  let obj = db.get(fs, id) catch { _ => return "" }
  match obj {
    Some(o) =>
      if o.obj_type == @bit.ObjectType::Blob {
        @utf8.decode_lossy(o.data[:])
      } else {
        ""
      }
    None => ""
  }
}

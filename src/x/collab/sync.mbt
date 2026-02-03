///| PR System sync operations (fetch/push)

///|
pub struct PrSyncResult {
  success : Bool
  message : String
  local_commit : @git.ObjectId?
  remote_commit : @git.ObjectId?
}

///|
pub fn PrSyncResult::success(self : PrSyncResult) -> Bool {
  self.success
}

///|
pub fn PrSyncResult::message(self : PrSyncResult) -> String {
  self.message
}

///|
pub fn PrSyncResult::local_commit(self : PrSyncResult) -> @git.ObjectId? {
  self.local_commit
}

///|
pub fn PrSyncResult::remote_commit(self : PrSyncResult) -> @git.ObjectId? {
  self.remote_commit
}

///|
/// Push _collab branch to remote
pub async fn Collab::push(
  self : Collab,
  rfs : &@git.RepoFileSystem,
  remote_url : String,
) -> PrSyncResult raise @git.GitError {
  let local_commit = get_collab_commit(rfs, self.git_dir)
  guard local_commit is Some(local_id) else {
    return {
      success: false,
      message: "No local _collab branch found",
      local_commit: None,
      remote_commit: None,
    }
  }
  // Collect all objects reachable from _collab
  let db = @lib.ObjectDb::load(rfs, self.git_dir)
  let objects = @lib.collect_reachable_objects(db, rfs, local_id)
  let pack = @git.create_packfile(objects)
  // Discover remote refs
  let remote = @git.Remote::new(remote_url)
  let refs = @git.discover_receive_refs_http(remote)
  let (old_id, ref_name) = find_remote_collab_ref(refs)
  // Push
  let req = @git.PushRequest::new(old_id, local_id, ref_name, pack)
  let result = @git.push(remote, req)
  if result.has_prefix("unpack ok") ||
    result.has_prefix("ok ") ||
    result.has_prefix("Push successful") {
    {
      success: true,
      message: "Push successful",
      local_commit: Some(local_id),
      remote_commit: Some(local_id),
    }
  } else {
    {
      success: false,
      message: "Push failed: \{result}",
      local_commit: Some(local_id),
      remote_commit: None,
    }
  }
}

///|
/// Fetch _collab branch from remote and merge
pub async fn Collab::fetch(
  self : Collab,
  fs : &@git.FileSystem,
  rfs : &@git.RepoFileSystem,
  remote_url : String,
) -> PrSyncResult raise @git.GitError {
  // Discover remote refs
  let (refs, _, _, _) = @git.discover_upload_refs_http(remote_url, true)
  let remote_id = find_upload_collab_ref(refs)
  guard remote_id is Some((rid, ref_name)) else {
    return {
      success: false,
      message: "No remote _collab branch found",
      local_commit: get_collab_commit(rfs, self.git_dir),
      remote_commit: None,
    }
  }
  // Fetch pack
  let pack = @git.fetch_pack_http(remote_url, [rid], true)
  let objects = @git.parse_packfile(pack)
  @git.write_packfile_with_index(fs, self.git_dir, pack, objects)
  // Update remote tracking ref
  let remote_short = short_ref_name(ref_name)
  let remote_ref_path = join_path(
    self.git_dir,
    "refs/remotes/origin/" + remote_short,
  )
  let dir = parent_path(remote_ref_path)
  fs.mkdir_p(dir)
  fs.write_string(remote_ref_path, rid.to_hex() + "\n")
  // Get local commit
  let local_commit = get_collab_commit(rfs, self.git_dir)
  match local_commit {
    None => {
      // No local _collab, just set to remote
      write_collab_ref(fs, rfs, self.git_dir, rid)
      // Reload counter
      self.next_id = load_counter(rfs, self.git_dir)
      {
        success: true,
        message: "Fetched remote _collab branch",
        local_commit: Some(rid),
        remote_commit: Some(rid),
      }
    }
    Some(lid) =>
      if lid == rid {
        {
          success: true,
          message: "Already up to date",
          local_commit: Some(lid),
          remote_commit: Some(rid),
        }
      } else {
        // Need to merge
        merge_collab_branches(self, fs, rfs, lid, rid)
      }
  }
}

///|
/// Merge remote _collab into local _collab
fn merge_collab_branches(
  prs : Collab,
  fs : &@git.FileSystem,
  rfs : &@git.RepoFileSystem,
  local_id : @git.ObjectId,
  remote_id : @git.ObjectId,
) -> PrSyncResult raise @git.GitError {
  let db = @lib.ObjectDb::load(rfs, prs.git_dir)
  // Check if fast-forward possible (local is ancestor of remote)
  if is_collab_ancestor(db, rfs, local_id, remote_id) {
    // Fast-forward to remote
    write_collab_ref(fs, rfs, prs.git_dir, remote_id)
    prs.next_id = load_counter(rfs, prs.git_dir)
    return {
      success: true,
      message: "Fast-forward to remote",
      local_commit: Some(remote_id),
      remote_commit: Some(remote_id),
    }
  }
  // Check if remote is ancestor of local (nothing to do, just push later)
  if is_collab_ancestor(db, rfs, remote_id, local_id) {
    return {
      success: true,
      message: "Local is ahead of remote",
      local_commit: Some(local_id),
      remote_commit: Some(remote_id),
    }
  }
  // Need real merge - collect PR data from both
  let local_tree = get_commit_tree(db, rfs, local_id)
  guard local_tree is Some(ltree) else {
    raise @git.GitError::InvalidObject("Cannot read local _collab tree")
  }
  let remote_tree = get_commit_tree(db, rfs, remote_id)
  guard remote_tree is Some(rtree) else {
    raise @git.GitError::InvalidObject("Cannot read remote _collab tree")
  }
  // Merge the trees
  let merged_tree_id = merge_collab_trees(
    fs,
    rfs,
    prs.git_dir,
    db,
    ltree,
    rtree,
  )
  // Create merge commit
  let commit = @git.Commit::new(
    merged_tree_id,
    [local_id, remote_id],
    "Collab <collab@local>",
    0L,
    "+0000",
    "Collab <collab@local>",
    0L,
    "+0000",
    "Merge remote _collab branch\n",
  )
  let (commit_id, commit_compressed) = @git.create_commit(commit)
  write_object_bytes(fs, prs.git_dir, commit_id, commit_compressed)
  // Update ref
  write_collab_ref(fs, rfs, prs.git_dir, commit_id)
  // Reload counter
  prs.next_id = load_counter(rfs, prs.git_dir)
  {
    success: true,
    message: "Merged remote _collab branch",
    local_commit: Some(commit_id),
    remote_commit: Some(remote_id),
  }
}

///|
fn merge_collab_trees(
  fs : &@git.FileSystem,
  rfs : &@git.RepoFileSystem,
  git_dir : String,
  db : @lib.ObjectDb,
  local_tree : @git.ObjectId,
  remote_tree : @git.ObjectId,
) -> @git.ObjectId raise @git.GitError {
  // Read both root trees
  let local_entries = read_tree_entries(db, rfs, local_tree)
  let remote_entries = read_tree_entries(db, rfs, remote_tree)
  // Build entry maps
  let local_map : Map[String, @git.TreeEntry] = {}
  for e in local_entries {
    local_map[e.name] = e
  }
  let remote_map : Map[String, @git.TreeEntry] = {}
  for e in remote_entries {
    remote_map[e.name] = e
  }
  // Merge entries
  let merged : Array[@git.TreeEntry] = []
  // Process 'meta' - merge counters
  let local_meta = local_map.get("meta")
  let remote_meta = remote_map.get("meta")
  let merged_meta = merge_meta_trees(
    fs, rfs, git_dir, db, local_meta, remote_meta,
  )
  merged.push(@git.TreeEntry::new("040000", "meta", merged_meta))
  // Process 'events' - union of all events
  let local_events = local_map.get("events")
  let remote_events = remote_map.get("events")
  let merged_events = merge_content_addressed_dir(
    fs, rfs, git_dir, db, local_events, remote_events,
  )
  merged.push(@git.TreeEntry::new("040000", "events", merged_events))
  // Preserve other entries (local wins on conflict)
  let other_map : Map[String, @git.TreeEntry] = {}
  for entry in remote_entries {
    if entry.name != "meta" && entry.name != "events" {
      other_map[entry.name] = entry
    }
  }
  for entry in local_entries {
    if entry.name != "meta" && entry.name != "events" {
      other_map[entry.name] = entry
    }
  }
  for item in other_map.to_array() {
    let (_, entry) = item
    merged.push(entry)
  }
  merged.sort_by(fn(a, b) { String::compare(a.name, b.name) })
  let (tree_id, compressed) = @git.create_tree(merged)
  write_object_bytes(fs, git_dir, tree_id, compressed)
  tree_id
}

///|
fn merge_meta_trees(
  fs : &@git.FileSystem,
  rfs : &@git.RepoFileSystem,
  git_dir : String,
  db : @lib.ObjectDb,
  local_meta : @git.TreeEntry?,
  remote_meta : @git.TreeEntry?,
) -> @git.ObjectId raise @git.GitError {
  // Get counters from both
  let local_counter = match local_meta {
    Some(m) => read_counter_from_meta(db, rfs, m.id)
    None => 1
  }
  let remote_counter = match remote_meta {
    Some(m) => read_counter_from_meta(db, rfs, m.id)
    None => 1
  }
  let local_issue_counter = match local_meta {
    Some(m) => read_issue_counter_from_meta(db, rfs, m.id)
    None => 1
  }
  let remote_issue_counter = match remote_meta {
    Some(m) => read_issue_counter_from_meta(db, rfs, m.id)
    None => 1
  }
  // Use max to avoid collisions
  let merged_counter = if local_counter > remote_counter {
    local_counter
  } else {
    remote_counter
  }
  let merged_issue_counter = if local_issue_counter > remote_issue_counter {
    local_issue_counter
  } else {
    remote_issue_counter
  }
  // Build merged meta entries (preserve unknown keys)
  let local_entries = match local_meta {
    Some(m) => read_tree_entries(db, rfs, m.id)
    None => []
  }
  let remote_entries = match remote_meta {
    Some(m) => read_tree_entries(db, rfs, m.id)
    None => []
  }
  let meta_map : Map[String, @git.TreeEntry] = {}
  for e in local_entries {
    meta_map[e.name] = e
  }
  for e in remote_entries {
    if not(meta_map.contains(e.name)) {
      meta_map[e.name] = e
    }
  }
  let counter_content = merged_counter.to_string() + "\n"
  let (counter_id, counter_compressed) = @git.create_blob_string(
    counter_content,
  )
  write_object_bytes(fs, git_dir, counter_id, counter_compressed)
  let issue_counter_content = merged_issue_counter.to_string() + "\n"
  let (issue_counter_id, issue_counter_compressed) = @git.create_blob_string(
    issue_counter_content,
  )
  write_object_bytes(fs, git_dir, issue_counter_id, issue_counter_compressed)
  meta_map["counter"] = @git.TreeEntry::new("100644", "counter", counter_id)
  meta_map["issue_counter"] = @git.TreeEntry::new(
    "100644", "issue_counter", issue_counter_id,
  )
  let meta_entries : Array[@git.TreeEntry] = []
  for item in meta_map.to_array() {
    let (_, entry) = item
    meta_entries.push(entry)
  }
  meta_entries.sort_by(fn(a, b) { String::compare(a.name, b.name) })
  let (meta_id, meta_compressed) = @git.create_tree(meta_entries)
  write_object_bytes(fs, git_dir, meta_id, meta_compressed)
  meta_id
}

///|
fn read_counter_from_meta(
  db : @lib.ObjectDb,
  rfs : &@git.RepoFileSystem,
  meta_tree : @git.ObjectId,
) -> Int raise @git.GitError {
  let counter_id = find_tree_entry(db, rfs, meta_tree, "counter")
  guard counter_id is Some(cid) else { return 1 }
  let obj = db.get(rfs, cid)
  guard obj is Some(blob) else { return 1 }
  let text = @utf8.decode_lossy(blob.data[:])
  parse_int(trim_whitespace(text))
}

///|
fn read_issue_counter_from_meta(
  db : @lib.ObjectDb,
  rfs : &@git.RepoFileSystem,
  meta_tree : @git.ObjectId,
) -> Int raise @git.GitError {
  let counter_id = find_tree_entry(db, rfs, meta_tree, "issue_counter")
  guard counter_id is Some(cid) else { return 1 }
  let obj = db.get(rfs, cid)
  guard obj is Some(blob) else { return 1 }
  let text = @utf8.decode_lossy(blob.data[:])
  parse_int(trim_whitespace(text))
}

///|
fn merge_content_addressed_dir(
  fs : &@git.FileSystem,
  _rfs : &@git.RepoFileSystem,
  git_dir : String,
  db : @lib.ObjectDb,
  local_dir : @git.TreeEntry?,
  remote_dir : @git.TreeEntry?,
) -> @git.ObjectId raise @git.GitError {
  let local_entries = match local_dir {
    Some(d) => {
      let obj = db.get(_rfs, d.id)
      match obj {
        Some(o) => @git.parse_tree(o.data)
        None => []
      }
    }
    None => []
  }
  let remote_entries = match remote_dir {
    Some(d) => {
      let obj = db.get(_rfs, d.id)
      match obj {
        Some(o) => @git.parse_tree(o.data)
        None => []
      }
    }
    None => []
  }
  // Union by name (content-addressed, so same name = same content)
  let all : Map[String, @git.TreeEntry] = {}
  for e in local_entries {
    all[e.name] = e
  }
  for e in remote_entries {
    all[e.name] = e
  }
  let merged : Array[@git.TreeEntry] = []
  for item in all.to_array() {
    let (_, e) = item
    merged.push(e)
  }
  merged.sort_by(fn(a, b) { String::compare(a.name, b.name) })
  let (tree_id, compressed) = @git.create_tree(merged)
  write_object_bytes(fs, git_dir, tree_id, compressed)
  tree_id
}

///|

///|
fn read_tree_entries(
  db : @lib.ObjectDb,
  rfs : &@git.RepoFileSystem,
  tree_id : @git.ObjectId,
) -> Array[@git.TreeEntry] raise @git.GitError {
  let obj = db.get(rfs, tree_id)
  match obj {
    Some(o) => @git.parse_tree(o.data)
    None => []
  }
}

///|
fn is_collab_ancestor(
  db : @lib.ObjectDb,
  rfs : &@git.RepoFileSystem,
  ancestor : @git.ObjectId,
  commit : @git.ObjectId,
) -> Bool raise @git.GitError {
  if ancestor == commit {
    return true
  }
  let stack : Array[@git.ObjectId] = [commit]
  let seen : Map[String, Bool] = {}
  while stack.length() > 0 {
    let id = stack.pop()
    guard id is Some(current) else { break }
    let hex = current.to_hex()
    if seen.contains(hex) {
      continue
    }
    seen[hex] = true
    if current == ancestor {
      return true
    }
    let obj = db.get(rfs, current)
    guard obj is Some(o) else { continue }
    if o.obj_type != @git.ObjectType::Commit {
      continue
    }
    let info = @git.parse_commit(o.data)
    for p in info.parents {
      stack.push(p)
    }
  }
  false
}

///|
fn find_remote_collab_ref(
  refs : Array[(@git.ObjectId, String)],
) -> (@git.ObjectId, String) {
  for item in refs {
    let (id, name) = item
    if name == collab_ref {
      return (id, collab_ref)
    }
  }
  for item in refs {
    let (id, name) = item
    if name == legacy_den_ref {
      return (id, legacy_den_ref)
    }
  }
  (@git.ObjectId::zero(), collab_ref)
}

///|
fn find_upload_collab_ref(
  refs : Array[(@git.ObjectId, String)],
) -> (@git.ObjectId, String)? {
  for item in refs {
    let (id, name) = item
    if name == collab_ref {
      return Some((id, collab_ref))
    }
  }
  for item in refs {
    let (id, name) = item
    if name == legacy_den_ref {
      return Some((id, legacy_den_ref))
    }
  }
  None
}

///|
fn short_ref_name(refname : String) -> String {
  if refname.has_prefix("refs/heads/") {
    String::unsafe_substring(refname, start=11, end=refname.length())
  } else {
    refname
  }
}

///|
fn parent_path(path : String) -> String {
  match path.rev_find("/") {
    None => "/"
    Some(0) => "/"
    Some(i) => String::unsafe_substring(path, start=0, end=i)
  }
}

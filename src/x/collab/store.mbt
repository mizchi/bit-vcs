///| Collab notes storage (ObjectStore + RefStore based)
///
/// ## Vector Clock Merge Semantics
///
/// - Clock merge: take max of each node's counter
/// - Same-key conflict: higher timestamp wins; if equal, lexicographic node name wins
/// - Tombstone: deleted=true marks logical deletion; compaction is not yet implemented

///|
let collab_notes_ns : String = "bit-collab"

///|
let collab_notes_ref : String = "refs/notes/" + collab_notes_ns

///|
pub fn collab_notes_ref_name() -> String {
  collab_notes_ref
}

///|
pub fn collab_notes_ns_name() -> String {
  collab_notes_ns
}

///|
pub fn pr_meta_key(pr_id : String) -> String {
  "collab/pr/" + pr_id + "/meta"
}

///|
pub fn pr_comment_prefix(pr_id : String) -> String {
  "collab/pr/" + pr_id + "/comment/"
}

///|
pub fn pr_comment_key(pr_id : String, comment_id : String) -> String {
  pr_comment_prefix(pr_id) + comment_id
}

///|
pub fn pr_review_prefix(pr_id : String) -> String {
  "collab/pr/" + pr_id + "/review/"
}

///|
pub fn pr_review_key(pr_id : String, review_id : String) -> String {
  pr_review_prefix(pr_id) + review_id
}

///|
pub fn issue_meta_key(issue_id : String) -> String {
  "collab/issue/" + issue_id + "/meta"
}

///|
pub fn issue_comment_prefix(issue_id : String) -> String {
  "collab/issue/" + issue_id + "/comment/"
}

///|
pub fn issue_comment_key(issue_id : String, comment_id : String) -> String {
  issue_comment_prefix(issue_id) + comment_id
}

///|
pub struct CollabRecord {
  version : Int
  key : String
  kind : String
  clock : Map[String, Int64]
  timestamp : Int64
  node : String
  deleted : Bool
  payload : String
}

///|
pub fn CollabRecord::new(
  key : String,
  kind : String,
  payload : String,
  node : String,
  timestamp : Int64,
  clock? : Map[String, Int64] = {},
  deleted? : Bool = false,
  version? : Int = 1,
) -> CollabRecord {
  { version, key, kind, clock, timestamp, node, deleted, payload }
}

///|
pub fn CollabRecord::serialize(self : CollabRecord) -> String {
  let sb = StringBuilder::new()
  sb.write_string("version ")
  sb.write_string(self.version.to_string())
  sb.write_char('\n')
  sb.write_string("key ")
  sb.write_string(self.key)
  sb.write_char('\n')
  sb.write_string("kind ")
  sb.write_string(self.kind)
  sb.write_char('\n')
  sb.write_string("clock ")
  sb.write_string(clock_to_string(self.clock))
  sb.write_char('\n')
  sb.write_string("timestamp ")
  sb.write_string(self.timestamp.to_string())
  sb.write_char('\n')
  sb.write_string("node ")
  sb.write_string(self.node)
  sb.write_char('\n')
  sb.write_string("deleted ")
  sb.write_string(if self.deleted { "1" } else { "0" })
  sb.write_char('\n')
  sb.write_char('\n')
  sb.write_string(self.payload)
  sb.to_string()
}

///|
pub fn parse_collab_record(text : String) -> CollabRecord {
  let mut version = 0
  let mut key = ""
  let mut kind = ""
  let mut clock = {}
  let mut timestamp : Int64 = 0
  let mut node = ""
  let mut deleted = false
  let payload_lines : Array[String] = []
  let mut in_body = false
  for line_view in text.split("\n") {
    let line = line_view.to_string()
    if in_body {
      payload_lines.push(line)
      continue
    }
    if line.length() == 0 {
      in_body = true
      continue
    }
    let space = line.find(" ")
    match space {
      None => continue
      Some(idx) => {
        let k = String::unsafe_substring(line, start=0, end=idx)
        let v = String::unsafe_substring(line, start=idx + 1, end=line.length())
        match k {
          "version" => version = parse_int(v)
          "key" => key = v
          "kind" => kind = v
          "clock" => clock = parse_clock(v)
          "timestamp" => timestamp = parse_int64(v)
          "node" => node = v
          "deleted" => deleted = v == "1" || v == "true" || v == "yes"
          _ => ()
        }
      }
    }
  }
  CollabRecord::new(
    key,
    kind,
    payload_lines.join("\n"),
    node,
    timestamp,
    clock~,
    deleted~,
    version~,
  )
}

///|
fn parse_clock(s : String) -> Map[String, Int64] {
  let result : Map[String, Int64] = {}
  if s.length() == 0 {
    return result
  }
  for part_view in s.split(",") {
    let part = part_view.to_string()
    if part.length() == 0 {
      continue
    }
    let eq = part.find("=")
    match eq {
      None => continue
      Some(idx) => {
        let key = String::unsafe_substring(part, start=0, end=idx)
        let value = String::unsafe_substring(
          part,
          start=idx + 1,
          end=part.length(),
        )
        let parsed = parse_int64(value)
        result[key] = parsed
      }
    }
  }
  result
}

///|
fn clock_to_string(clock : Map[String, Int64]) -> String {
  if clock.length() == 0 {
    return ""
  }
  let items = clock.to_array()
  items.sort_by((a, b) => String::compare(a.0, b.0))
  let parts : Array[String] = []
  for item in items {
    let (key, value) = item
    parts.push(key + "=" + value.to_string())
  }
  parts.join(",")
}

///|
fn compare_clock(a : Map[String, Int64], b : Map[String, Int64]) -> Int {
  let keys : Map[String, Bool] = {}
  for item in a.to_array() {
    let (key, _) = item
    keys[key] = true
  }
  for item in b.to_array() {
    let (key, _) = item
    keys[key] = true
  }
  let mut a_gt = false
  let mut b_gt = false
  for item in keys.to_array() {
    let (key, _) = item
    let va = a.get(key).unwrap_or(0)
    let vb = b.get(key).unwrap_or(0)
    if va > vb {
      a_gt = true
    } else if vb > va {
      b_gt = true
    }
  }
  if a_gt && not(b_gt) {
    1
  } else if b_gt && not(a_gt) {
    -1
  } else {
    0
  }
}

///|
fn record_is_newer(a : CollabRecord, b : CollabRecord) -> Bool {
  let cmp = compare_clock(a.clock, b.clock)
  if cmp > 0 {
    return true
  }
  if cmp < 0 {
    return false
  }
  if a.timestamp != b.timestamp {
    return a.timestamp > b.timestamp
  }
  String::compare(a.node, b.node) >= 0
}

///|
fn is_valid_record(record : CollabRecord) -> Bool {
  record.key.length() > 0 && record.kind.length() > 0
}

///|
pub fn merge_record_bytes(ours : Bytes, theirs : Bytes) -> Bytes {
  let ours_text = @utf8.decode_lossy(ours[:])
  let theirs_text = @utf8.decode_lossy(theirs[:])
  let ours_record = parse_collab_record(ours_text)
  let theirs_record = parse_collab_record(theirs_text)
  if (ours_record |> is_valid_record |> not) && is_valid_record(theirs_record) {
    return theirs
  }
  if (theirs_record |> is_valid_record |> not) {
    return ours
  }
  let winner = if record_is_newer(theirs_record, ours_record) {
    theirs_record
  } else {
    ours_record
  }
  @utf8.encode(winner.serialize())
}

///|
pub struct CollabStore {
  node_id : String
  entries : Map[String, @git.ObjectId] // entry_name -> blob_id
  mut head : @git.ObjectId? // current notes commit
}

///|
pub fn CollabStore::load(
  objects : &@lib.ObjectStore,
  refs : &@lib.RefStore,
  node_id? : String = "local",
) -> CollabStore raise @git.GitError {
  let node = node_id
  let commit = refs.resolve(collab_notes_ref)
  let entries : Map[String, @git.ObjectId] = {}
  let head = match commit {
    Some(cid) => {
      let obj = objects.get(cid)
      guard obj is Some(commit_obj) else { None }
      let info = @git.parse_commit(commit_obj.data)
      let tree_obj = objects.get(info.tree)
      guard tree_obj is Some(tobj) else { None }
      let tree_entries = @git.parse_tree(tobj.data)
      for entry in tree_entries {
        entries[entry.name] = entry.id
      }
      Some(cid)
    }
    None => None
  }
  { node_id: node, entries, head }
}

///|
pub fn CollabStore::node_id(self : CollabStore) -> String {
  self.node_id
}

///|
pub fn CollabStore::get_record(
  self : CollabStore,
  objects : &@lib.ObjectStore,
  key : String,
) -> CollabRecord? {
  let target_id = key_to_target_id(key)
  let entry_name = target_id.to_hex()
  let blob_id = self.entries.get(entry_name)
  match blob_id {
    None => None
    Some(bid) => {
      let obj = objects.get(bid) catch { _ => None }
      match obj {
        None => None
        Some(blob_obj) => {
          let text = @utf8.decode_lossy(blob_obj.data[:])
          let record = parse_collab_record(text)
          if record.deleted {
            None
          } else {
            Some(record)
          }
        }
      }
    }
  }
}

///|
pub fn CollabStore::put_record(
  self : CollabStore,
  objects : &@lib.ObjectStore,
  refs : &@lib.RefStore,
  clock : &@lib.Clock,
  key : String,
  kind : String,
  payload : String,
  node : String,
) -> CollabRecord raise @git.GitError {
  let timestamp = clock.now()
  let existing = self.get_record(objects, key)
  let base_clock = match existing {
    Some(r) => r.clock
    None => {}
  }
  let next_clock = increment_clock(base_clock, node)
  let record = CollabRecord::new(
    key,
    kind,
    payload,
    node,
    timestamp,
    clock=next_clock,
    deleted=false,
  )
  let target_id = key_to_target_id(key)
  // Store the key blob
  let key_bytes = @utf8.encode(key)
  ignore(objects.put(@git.ObjectType::Blob, key_bytes))
  // Store the record blob
  let record_text = record.serialize()
  let record_bytes = @utf8.encode(record_text)
  let record_blob_id = objects.put(@git.ObjectType::Blob, record_bytes)
  self.entries[target_id.to_hex()] = record_blob_id
  let _ = commit_notes(self, objects, refs, "Update " + kind, timestamp)
  record
}

///|
pub fn CollabStore::delete_record(
  self : CollabStore,
  objects : &@lib.ObjectStore,
  refs : &@lib.RefStore,
  clock : &@lib.Clock,
  key : String,
  kind : String,
  node : String,
) -> CollabRecord raise @git.GitError {
  let timestamp = clock.now()
  let existing = self.get_record(objects, key)
  let base_clock = match existing {
    Some(r) => r.clock
    None => {}
  }
  let next_clock = increment_clock(base_clock, node)
  let record = CollabRecord::new(
    key,
    kind,
    "",
    node,
    timestamp,
    clock=next_clock,
    deleted=true,
  )
  let target_id = key_to_target_id(key)
  // Store the key blob
  let key_bytes = @utf8.encode(key)
  ignore(objects.put(@git.ObjectType::Blob, key_bytes))
  // Store the record blob
  let record_text = record.serialize()
  let record_bytes = @utf8.encode(record_text)
  let record_blob_id = objects.put(@git.ObjectType::Blob, record_bytes)
  self.entries[target_id.to_hex()] = record_blob_id
  let _ = commit_notes(self, objects, refs, "Delete " + kind, timestamp)
  record
}

///|
pub fn CollabStore::list_records(
  self : CollabStore,
  objects : &@lib.ObjectStore,
  prefix : String,
  include_deleted? : Bool = false,
) -> Array[CollabRecord] {
  let result : Array[CollabRecord] = []
  let include_deleted_val = include_deleted
  for item in self.entries.to_array() {
    let (_, blob_id) = item
    let obj = objects.get(blob_id) catch { _ => None }
    match obj {
      None => ()
      Some(blob_obj) => {
        let text = @utf8.decode_lossy(blob_obj.data[:])
        let record = parse_collab_record(text)
        if not(record.key.has_prefix(prefix)) {
          continue
        }
        if not(include_deleted_val) && record.deleted {
          continue
        }
        result.push(record)
      }
    }
  }
  result
}

///|
fn increment_clock(
  clock : Map[String, Int64],
  node : String,
) -> Map[String, Int64] {
  let next = clock
  let current = next.get(node).unwrap_or(0)
  next[node] = current + 1
  next
}

///|
fn key_to_target_id(key : String) -> @git.ObjectId {
  let (id, _compressed) = @git.create_blob_string(key)
  id
}

///|
fn commit_notes(
  store : CollabStore,
  objects : &@lib.ObjectStore,
  refs : &@lib.RefStore,
  message : String,
  timestamp : Int64,
) -> @git.ObjectId raise @git.GitError {
  // Build tree from entries
  let tree_entries : Array[@git.TreeEntry] = []
  for item in store.entries.to_array() {
    let (name, blob_id) = item
    tree_entries.push(@git.TreeEntry::new("100644", name, blob_id))
  }
  tree_entries.sort_by((a, b) => String::compare(a.name, b.name))
  let tree_bytes = @git.serialize_tree(tree_entries)
  let tree_id = objects.put(@git.ObjectType::Tree, tree_bytes)
  // Create commit
  let parents = match store.head {
    Some(p) => [p]
    None => []
  }
  let commit = @git.Commit::new(
    tree_id,
    parents,
    "Collab <collab@local>",
    timestamp,
    "+0000",
    "Collab <collab@local>",
    timestamp,
    "+0000",
    message + "\n",
  )
  let commit_bytes = @git.serialize_commit_content(commit)
  let commit_id = objects.put(@git.ObjectType::Commit, commit_bytes)
  store.head = Some(commit_id)
  refs.update(collab_notes_ref, Some(commit_id))
  commit_id
}

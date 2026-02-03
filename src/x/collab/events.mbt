///| Collab event log helpers (append-only)

///|
pub struct CollabEvent {
  kind : String
  entity : String
  timestamp : Int64
  payload : String
}

///|
pub fn CollabEvent::new(
  kind : String,
  entity : String,
  timestamp : Int64,
  payload : String,
) -> CollabEvent {
  { kind, entity, timestamp, payload }
}

///|
pub fn CollabEvent::kind(self : CollabEvent) -> String {
  self.kind
}

///|
pub fn CollabEvent::entity(self : CollabEvent) -> String {
  self.entity
}

///|
pub fn CollabEvent::timestamp(self : CollabEvent) -> Int64 {
  self.timestamp
}

///|
pub fn CollabEvent::payload(self : CollabEvent) -> String {
  self.payload
}

///|
fn CollabEvent::serialize(self : CollabEvent) -> String {
  let sb = StringBuilder::new()
  sb.write_string("kind ")
  sb.write_string(self.kind)
  sb.write_char('\n')
  sb.write_string("entity ")
  sb.write_string(self.entity)
  sb.write_char('\n')
  sb.write_string("ts ")
  sb.write_string(self.timestamp.to_string())
  sb.write_char('\n')
  sb.write_char('\n')
  sb.write_string(self.payload)
  sb.to_string()
}

///|
fn parse_collab_event(text : String) -> CollabEvent raise @git.GitError {
  let mut kind = ""
  let mut entity = ""
  let mut ts : Int64 = 0
  let body_lines : Array[String] = []
  let mut in_body = false
  for line_view in text.split("\n") {
    let line = line_view.to_string()
    if in_body {
      body_lines.push(line)
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
        let key = String::unsafe_substring(line, start=0, end=idx)
        let value = String::unsafe_substring(
          line,
          start=idx + 1,
          end=line.length(),
        )
        match key {
          "kind" => kind = value
          "entity" => entity = value
          "ts" => ts = parse_int64(value)
          _ => ()
        }
      }
    }
  }
  if kind.length() == 0 {
    raise @git.GitError::InvalidObject("Invalid event: missing kind")
  }
  CollabEvent::new(kind, entity, ts, body_lines.join("\n"))
}

///|
fn load_events(
  backing_fs : &@git.RepoFileSystem,
  git_dir : String,
) -> Array[CollabEvent] raise @git.GitError {
  let events : Array[CollabEvent] = []
  let db = @lib.ObjectDb::load_lazy(backing_fs, git_dir)
  let collab_commit = get_collab_commit(backing_fs, git_dir)
  guard collab_commit is Some(commit_id) else { return events }
  let collab_tree = get_commit_tree(db, backing_fs, commit_id)
  guard collab_tree is Some(tree_id) else { return events }
  let events_tree_id = find_tree_entry(db, backing_fs, tree_id, "events")
  guard events_tree_id is Some(eid) else { return events }
  let obj = db.get(backing_fs, eid)
  guard obj is Some(tree_obj) else { return events }
  let entries = @git.parse_tree(tree_obj.data)
  for entry in entries {
    let data_obj = db.get(backing_fs, entry.id)
    guard data_obj is Some(blob_obj) else { continue }
    let text = @utf8.decode_lossy(blob_obj.data[:])
    let event = parse_collab_event(text) catch { _ => continue }
    events.push(event)
  }
  events
}

///|
fn append_event(
  fs : &@git.FileSystem,
  backing_fs : &@git.RepoFileSystem,
  git_dir : String,
  event : CollabEvent,
  counter? : Int? = None,
  issue_counter? : Int? = None,
) -> Unit raise @git.GitError {
  let event_text = event.serialize()
  let (event_blob_id, event_compressed) = @git.create_blob_string(event_text)
  write_object_bytes(fs, git_dir, event_blob_id, event_compressed)
  let event_name = event_blob_id.to_hex()
  let db = @lib.ObjectDb::load_lazy(backing_fs, git_dir)
  let collab_commit = get_collab_commit(backing_fs, git_dir)
  guard collab_commit is Some(commit_id) else {
    raise @git.GitError::InvalidObject("_collab branch not found")
  }
  let collab_tree = get_commit_tree(db, backing_fs, commit_id)
  guard collab_tree is Some(root_tree_id) else {
    raise @git.GitError::InvalidObject("_collab tree not found")
  }
  let root_obj = db.get(backing_fs, root_tree_id)
  guard root_obj is Some(root_tree_obj) else {
    raise @git.GitError::InvalidObject("Cannot read root tree")
  }
  let root_entries = @git.parse_tree(root_tree_obj.data)
  let mut events_tree_id = @git.ObjectId::zero()
  let mut meta_tree_id = @git.ObjectId::zero()
  let rest_entries : Array[@git.TreeEntry] = []
  for entry in root_entries {
    match entry.name {
      "events" => events_tree_id = entry.id
      "meta" => meta_tree_id = entry.id
      _ => rest_entries.push(entry)
    }
  }
  let events_entries = if events_tree_id != @git.ObjectId::zero() {
    read_tree_entries(db, backing_fs, events_tree_id)
  } else {
    []
  }
  let mut exists = false
  for entry in events_entries {
    if entry.name == event_name {
      exists = true
      break
    }
  }
  let new_events_entries : Array[@git.TreeEntry] = []
  for entry in events_entries {
    new_events_entries.push(entry)
  }
  if not(exists) {
    new_events_entries.push(
      @git.TreeEntry::new("100644", event_name, event_blob_id),
    )
  }
  new_events_entries.sort_by(fn(a, b) { String::compare(a.name, b.name) })
  let (new_events_tree_id, new_events_compressed) = @git.create_tree(
    new_events_entries,
  )
  write_object_bytes(fs, git_dir, new_events_tree_id, new_events_compressed)
  let meta_entries = if meta_tree_id != @git.ObjectId::zero() {
    read_tree_entries(db, backing_fs, meta_tree_id)
  } else {
    []
  }
  let meta_map : Map[String, @git.TreeEntry] = {}
  for entry in meta_entries {
    meta_map[entry.name] = entry
  }
  match counter {
    Some(value) => {
      let (counter_id, counter_compressed) = @git.create_blob_string(
        value.to_string() + "\n",
      )
      write_object_bytes(fs, git_dir, counter_id, counter_compressed)
      meta_map["counter"] = @git.TreeEntry::new("100644", "counter", counter_id)
    }
    None =>
      if not(meta_map.contains("counter")) {
        let (counter_id, counter_compressed) = @git.create_blob_string("1\n")
        write_object_bytes(fs, git_dir, counter_id, counter_compressed)
        meta_map["counter"] = @git.TreeEntry::new(
          "100644", "counter", counter_id,
        )
      }
  }
  match issue_counter {
    Some(value) => {
      let (counter_id, counter_compressed) = @git.create_blob_string(
        value.to_string() + "\n",
      )
      write_object_bytes(fs, git_dir, counter_id, counter_compressed)
      meta_map["issue_counter"] = @git.TreeEntry::new(
        "100644", "issue_counter", counter_id,
      )
    }
    None =>
      if not(meta_map.contains("issue_counter")) {
        let (counter_id, counter_compressed) = @git.create_blob_string("1\n")
        write_object_bytes(fs, git_dir, counter_id, counter_compressed)
        meta_map["issue_counter"] = @git.TreeEntry::new(
          "100644", "issue_counter", counter_id,
        )
      }
  }
  let new_meta_entries : Array[@git.TreeEntry] = []
  for item in meta_map.to_array() {
    let (_, entry) = item
    new_meta_entries.push(entry)
  }
  new_meta_entries.sort_by(fn(a, b) { String::compare(a.name, b.name) })
  let (new_meta_tree_id, new_meta_compressed) = @git.create_tree(
    new_meta_entries,
  )
  write_object_bytes(fs, git_dir, new_meta_tree_id, new_meta_compressed)
  let new_root_entries : Array[@git.TreeEntry] = []
  for entry in rest_entries {
    new_root_entries.push(entry)
  }
  new_root_entries.push(
    @git.TreeEntry::new("040000", "events", new_events_tree_id),
  )
  new_root_entries.push(@git.TreeEntry::new("040000", "meta", new_meta_tree_id))
  new_root_entries.sort_by(fn(a, b) { String::compare(a.name, b.name) })
  let (new_root_tree_id, new_root_compressed) = @git.create_tree(
    new_root_entries,
  )
  write_object_bytes(fs, git_dir, new_root_tree_id, new_root_compressed)
  let commit = @git.Commit::new(
    new_root_tree_id,
    [commit_id],
    "Collab <collab@local>",
    0L,
    "+0000",
    "Collab <collab@local>",
    0L,
    "+0000",
    "Append collab event\n",
  )
  let (new_commit_id, commit_compressed) = @git.create_commit(commit)
  write_object_bytes(fs, git_dir, new_commit_id, commit_compressed)
  write_collab_ref(fs, backing_fs, git_dir, new_commit_id)
}

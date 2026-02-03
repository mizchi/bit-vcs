///| Git Notes operations (Git compatible + Collab integration)

///|

///| Notes are stored in refs/notes/<ns> (Git standard)

///| Default ns is "commits"

///|
/// The notes ref prefix
let notes_ref_prefix : String = "refs/notes/"

///|
/// Add a note to a commit (Git compatible)
pub fn Collab::add_note(
  self : Collab,
  fs : &@git.FileSystem,
  backing_fs : &@git.RepoFileSystem,
  commit_id : @git.ObjectId,
  body : String,
  author : String,
  timestamp : Int64,
  ns? : String = "commits",
) -> Note raise @git.GitError {
  let note = Note::new(commit_id, body, author, timestamp, ns~)
  let event = CollabEvent::new(
    "note",
    "note/" + commit_id.to_hex(),
    timestamp,
    note.serialize(),
  )
  append_event(fs, backing_fs, self.git_dir, event)
  note
}

///|
/// Add a plain note (Git standard, no metadata)
pub fn Collab::add_note_plain(
  self : Collab,
  fs : &@git.FileSystem,
  backing_fs : &@git.RepoFileSystem,
  commit_id : @git.ObjectId,
  body : String,
  ns? : String = "commits",
) -> Unit raise @git.GitError {
  let (blob_id, compressed) = @git.create_blob_string(body)
  write_object_bytes(fs, self.git_dir, blob_id, compressed)
  update_notes_tree(fs, backing_fs, self.git_dir, commit_id, blob_id, ns)
}

///|
/// Get a note for a commit
pub fn Collab::get_note(
  self : Collab,
  backing_fs : &@git.RepoFileSystem,
  commit_id : @git.ObjectId,
  ns? : String = "commits",
) -> Note? raise @git.GitError {
  let events = load_events(backing_fs, self.git_dir)
  let mut latest_ts : Int64 = -1
  let mut latest_note : Note? = None
  for event in events {
    match event.kind() {
      "note" => {
        let note = parse_note(event.payload())
        if note.ns != ns {
          continue
        }
        if note.commit_id != commit_id {
          continue
        }
        let ts = event.timestamp()
        if ts >= latest_ts {
          latest_ts = ts
          latest_note = Some(note)
        }
      }
      "note.remove" => {
        let remove = parse_note_remove_payload(event.payload())
        match remove {
          Some((cid, remove_ns)) =>
            if cid == commit_id && remove_ns == ns {
              let ts = event.timestamp()
              if ts >= latest_ts {
                latest_ts = ts
                latest_note = None
              }
            }
          None => ()
        }
      }
      _ => ()
    }
  }
  latest_note
}

///|
/// List all notes in a ns
pub fn Collab::list_notes(
  self : Collab,
  backing_fs : &@git.RepoFileSystem,
  ns? : String = "commits",
) -> Array[Note] raise @git.GitError {
  let events = load_events(backing_fs, self.git_dir)
  let latest_ts : Map[String, Int64] = {}
  let latest_note : Map[String, Note] = {}
  for event in events {
    match event.kind() {
      "note" => {
        let note = parse_note(event.payload())
        if note.ns != ns {
          continue
        }
        let key = note.commit_id.to_hex()
        let ts = event.timestamp()
        match latest_ts.get(key) {
          Some(existing_ts) =>
            if ts >= existing_ts {
              latest_ts[key] = ts
              latest_note[key] = note
            }
          None => {
            latest_ts[key] = ts
            latest_note[key] = note
          }
        }
      }
      "note.remove" => {
        let remove = parse_note_remove_payload(event.payload())
        match remove {
          Some((cid, remove_ns)) =>
            if remove_ns == ns {
              let key = cid.to_hex()
              let ts = event.timestamp()
              match latest_ts.get(key) {
                Some(existing_ts) =>
                  if ts >= existing_ts {
                    latest_ts[key] = ts
                    latest_note.remove(key)
                  }
                None => {
                  latest_ts[key] = ts
                  latest_note.remove(key)
                }
              }
            }
          None => ()
        }
      }
      _ => ()
    }
  }
  let result : Array[Note] = []
  for item in latest_note.to_array() {
    let (_, note) = item
    result.push(note)
  }
  result.sort_by(fn(a, b) {
    if a.created_at < b.created_at {
      -1
    } else if a.created_at > b.created_at {
      1
    } else {
      0
    }
  })
  result
}

///|
/// Remove a note from a commit
pub fn Collab::remove_note(
  self : Collab,
  fs : &@git.FileSystem,
  backing_fs : &@git.RepoFileSystem,
  commit_id : @git.ObjectId,
  timestamp : Int64,
  ns? : String = "commits",
) -> Unit raise @git.GitError {
  let payload = serialize_note_remove_payload(commit_id, ns)
  let event = CollabEvent::new(
    "note.remove",
    "note/" + commit_id.to_hex(),
    timestamp,
    payload,
  )
  append_event(fs, backing_fs, self.git_dir, event)
}

///|
fn short_hex_note(hex : String, n : Int) -> String {
  if hex.length() <= n {
    hex
  } else {
    String::unsafe_substring(hex, start=0, end=n)
  }
}

///|
fn get_notes_commit(
  backing_fs : &@git.RepoFileSystem,
  git_dir : String,
  ns : String,
) -> @git.ObjectId? raise @git.GitError {
  let ref_name = notes_ref_prefix + ns
  @lib.resolve_ref(backing_fs, git_dir, ref_name)
}

///|
fn get_notes_tree(
  backing_fs : &@git.RepoFileSystem,
  git_dir : String,
  ns : String,
) -> @git.ObjectId? raise @git.GitError {
  let commit_id = get_notes_commit(backing_fs, git_dir, ns)
  guard commit_id is Some(cid) else { return None }
  let db = @lib.ObjectDb::load_lazy(backing_fs, git_dir)
  let obj = db.get(backing_fs, cid)
  guard obj is Some(commit_obj) else { return None }
  let info = @git.parse_commit(commit_obj.data)
  Some(info.tree)
}

///|

///|
fn update_notes_tree(
  fs : &@git.FileSystem,
  backing_fs : &@git.RepoFileSystem,
  git_dir : String,
  commit_id : @git.ObjectId,
  blob_id : @git.ObjectId,
  ns : String,
) -> Unit raise @git.GitError {
  let db = @lib.ObjectDb::load_lazy(backing_fs, git_dir)
  let commit_hex = commit_id.to_hex()
  // Get existing tree or create empty
  let existing_tree_id = get_notes_tree(backing_fs, git_dir, ns)
  let entries : Array[@git.TreeEntry] = match existing_tree_id {
    Some(tid) => {
      let obj = db.get(backing_fs, tid)
      match obj {
        Some(tree_obj) => @git.parse_tree(tree_obj.data)
        None => []
      }
    }
    None => []
  }
  // Add or update entry (direct mode, no fanout for simplicity)
  let new_entries : Array[@git.TreeEntry] = []
  let mut found = false
  for entry in entries {
    if entry.name == commit_hex {
      new_entries.push(@git.TreeEntry::new("100644", commit_hex, blob_id))
      found = true
    } else {
      new_entries.push(entry)
    }
  }
  if not(found) {
    new_entries.push(@git.TreeEntry::new("100644", commit_hex, blob_id))
  }
  new_entries.sort_by(fn(a, b) { String::compare(a.name, b.name) })
  let (new_tree_id, tree_compressed) = @git.create_tree(new_entries)
  write_object_bytes(fs, git_dir, new_tree_id, tree_compressed)
  // Create commit
  let parents = match get_notes_commit(backing_fs, git_dir, ns) {
    Some(p) => [p]
    None => []
  }
  let commit = @git.Commit::new(
    new_tree_id,
    parents,
    "Collab <collab@local>",
    0L,
    "+0000",
    "Collab <collab@local>",
    0L,
    "+0000",
    "Add note for \{short_hex_note(commit_hex, 8)}...\n",
  )
  let (new_commit_id, commit_compressed) = @git.create_commit(commit)
  write_object_bytes(fs, git_dir, new_commit_id, commit_compressed)
  // Update ref
  let ref_path = join_path(git_dir, notes_ref_prefix + ns)
  let refs_dir = join_path(git_dir, "refs/notes")
  fs.mkdir_p(refs_dir)
  fs.write_string(ref_path, new_commit_id.to_hex() + "\n")
}

///|

///|
fn serialize_note_remove_payload(
  commit_id : @git.ObjectId,
  ns : String,
) -> String {
  let sb = StringBuilder::new()
  sb.write_string("commit ")
  sb.write_string(commit_id.to_hex())
  sb.write_char('\n')
  sb.write_string("ns ")
  sb.write_string(ns)
  sb.write_char('\n')
  sb.to_string()
}

///|
fn parse_note_remove_payload(text : String) -> (@git.ObjectId, String)? {
  let mut commit_hex = ""
  let mut ns = "commits"
  for line_view in text.split("\n") {
    let line = line_view.to_string()
    if line.length() == 0 {
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
          "commit" => commit_hex = value
          "ns" => ns = value
          _ => ()
        }
      }
    }
  }
  if commit_hex.length() == 0 {
    return None
  }
  let result : Result[@git.ObjectId, Error] = try? @git.ObjectId::from_hex(
    commit_hex,
  )
  match result {
    Ok(id) => Some((id, ns))
    Err(_) => None
  }
}

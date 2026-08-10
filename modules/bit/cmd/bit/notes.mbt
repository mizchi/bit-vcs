///|
async fn handle_notes(args : Array[String]) -> Unit raise Error {
  let root = get_work_root()
  let fs = OsFs::new()
  let wfs : &@bitcore.FileSystem = fs
  let rfs : &@bitcore.RepoFileSystem = fs
  let git_dir = resolve_git_dir(rfs, root)
  let common_git_dir = notes_resolve_common_git_dir(rfs, git_dir)
  let mut ref_name : String? = None
  let rest : Array[String] = []
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    match arg {
      "--ref" if i + 1 < args.length() => {
        ref_name = Some(args[i + 1])
        i += 2
        continue
      }
      _ if arg.has_prefix("--ref=") => {
        ref_name = Some(string_slice_from(arg, 6))
        i += 1
        continue
      }
      _ => {
        rest.push(arg)
        i += 1
        continue
      }
    }
  }
  let notes_ref = normalize_notes_ref(ref_name)
  // Parse subcommand
  let subcmd = rest.get(0).unwrap_or("list")
  let subargs : Array[String] = []
  for i in 1..<rest.length() {
    subargs.push(rest[i])
  }
  match subcmd {
    "list" => notes_list(rfs, git_dir, common_git_dir, notes_ref)
    "show" => {
      let commit_ref = subargs.get(0).unwrap_or("HEAD")
      notes_show(rfs, git_dir, common_git_dir, notes_ref, commit_ref)
    }
    "add" => {
      let mut message : String? = None
      let mut force = false
      let mut commit_ref = "HEAD"
      let mut i = 0
      while i < subargs.length() {
        let arg = subargs[i]
        match arg {
          "-m" | "--message" if i + 1 < subargs.length() => {
            message = Some(subargs[i + 1])
            i += 2
            continue
          }
          _ if arg.has_prefix("-m") => {
            message = Some(string_slice_from(arg, 2))
            i += 1
            continue
          }
          _ if arg.has_prefix("--message=") => {
            message = Some(string_slice_from(arg, 10))
            i += 1
            continue
          }
          "-f" | "--force" => {
            force = true
            i += 1
            continue
          }
          _ if !arg.has_prefix("-") => {
            commit_ref = arg
            i += 1
            continue
          }
          _ => i += 1
        }
      }
      guard message is Some(msg) else {
        @stdio.stderr.write("error: notes add requires -m <message>")
        @sys.exit(1)
      }
      notes_add(
        wfs, rfs, git_dir, common_git_dir, notes_ref, commit_ref, msg, force,
      )
    }
    "append" => {
      let mut message : String? = None
      let mut commit_ref = "HEAD"
      let mut i = 0
      while i < subargs.length() {
        let arg = subargs[i]
        match arg {
          "-m" | "--message" if i + 1 < subargs.length() => {
            message = Some(subargs[i + 1])
            i += 2
            continue
          }
          _ if arg.has_prefix("-m") => {
            message = Some(string_slice_from(arg, 2))
            i += 1
            continue
          }
          _ if arg.has_prefix("--message=") => {
            message = Some(string_slice_from(arg, 10))
            i += 1
            continue
          }
          _ if !arg.has_prefix("-") => {
            commit_ref = arg
            i += 1
            continue
          }
          _ => i += 1
        }
      }
      guard message is Some(msg) else {
        @stdio.stderr.write("error: notes append requires -m <message>")
        @sys.exit(1)
      }
      notes_append(
        wfs, rfs, git_dir, common_git_dir, notes_ref, commit_ref, msg,
      )
    }
    "edit" => {
      let mut message : String? = None
      let mut commit_ref = "HEAD"
      let mut i = 0
      while i < subargs.length() {
        let arg = subargs[i]
        match arg {
          "-m" | "--message" if i + 1 < subargs.length() => {
            message = Some(subargs[i + 1])
            i += 2
            continue
          }
          _ if arg.has_prefix("-m") => {
            message = Some(string_slice_from(arg, 2))
            i += 1
            continue
          }
          _ if arg.has_prefix("--message=") => {
            message = Some(string_slice_from(arg, 10))
            i += 1
            continue
          }
          _ if !arg.has_prefix("-") => {
            commit_ref = arg
            i += 1
            continue
          }
          _ => i += 1
        }
      }
      guard message is Some(msg) else {
        @stdio.stderr.write("error: notes edit requires -m <message>")
        @sys.exit(1)
      }
      notes_add(
        wfs, rfs, git_dir, common_git_dir, notes_ref, commit_ref, msg, true,
      )
    }
    "copy" => {
      let mut force = false
      let mut from_ref : String? = None
      let mut to_ref : String? = None
      let mut i = 0
      while i < subargs.length() {
        let arg = subargs[i]
        match arg {
          "-f" | "--force" => {
            force = true
            i += 1
            continue
          }
          _ if !arg.has_prefix("-") => {
            if from_ref is None {
              from_ref = Some(arg)
            } else if to_ref is None {
              to_ref = Some(arg)
            }
            i += 1
            continue
          }
          _ => i += 1
        }
      }
      guard from_ref is Some(from_commit) else {
        @stdio.stderr.write("usage: git notes copy <from> <to>")
        @sys.exit(1)
      }
      guard to_ref is Some(to_commit) else {
        @stdio.stderr.write("usage: git notes copy <from> <to>")
        @sys.exit(1)
      }
      notes_copy(
        wfs, rfs, git_dir, common_git_dir, notes_ref, from_commit, to_commit, force,
      )
    }
    "merge" => {
      let mut strategy : String? = None
      let mut other_ref : String? = None
      let mut i = 0
      while i < subargs.length() {
        let arg = subargs[i]
        match arg {
          "-s" if i + 1 < subargs.length() => {
            strategy = Some(subargs[i + 1])
            i += 2
            continue
          }
          "--strategy" if i + 1 < subargs.length() => {
            strategy = Some(subargs[i + 1])
            i += 2
            continue
          }
          _ if arg.has_prefix("--strategy=") => {
            strategy = Some(string_slice_from(arg, 11))
            i += 1
            continue
          }
          _ if !arg.has_prefix("-") => {
            other_ref = Some(arg)
            i += 1
            continue
          }
          _ => i += 1
        }
      }
      guard other_ref is Some(other_name) else {
        @stdio.stderr.write("usage: git notes merge <ref>")
        @sys.exit(1)
      }
      match strategy {
        Some(s) =>
          if s != "ours" &&
            s != "theirs" &&
            s != "union" &&
            s != "cat_sort_uniq" {
            @stdio.stderr.write("error: unsupported merge strategy: \{s}")
            @sys.exit(1)
          }
        None => ()
      }
      let other_notes_ref = other_name |> Some |> normalize_notes_ref
      notes_merge(
        wfs, rfs, git_dir, common_git_dir, notes_ref, other_notes_ref, strategy,
      )
    }
    "rewrite" => {
      let mut force = false
      let mut use_stdin = false
      let mut from_ref : String? = None
      let mut to_ref : String? = None
      let mut i = 0
      while i < subargs.length() {
        let arg = subargs[i]
        match arg {
          "--stdin" => {
            use_stdin = true
            i += 1
            continue
          }
          "-f" | "--force" => {
            force = true
            i += 1
            continue
          }
          _ if !arg.has_prefix("-") => {
            if from_ref is None {
              from_ref = Some(arg)
            } else if to_ref is None {
              to_ref = Some(arg)
            }
            i += 1
            continue
          }
          _ => i += 1
        }
      }
      if use_stdin {
        if from_ref is Some(_) || to_ref is Some(_) {
          @stdio.stderr.write(
            "usage: git notes rewrite [--stdin] [-f] [<from> <to>]",
          )
          @sys.exit(1)
        }
        let data = read_all_stdin()
        let text = decode_bytes(data)
        let lines = split_lines(text)
        for line in lines {
          let parts = split_whitespace_tokens(line)
          if parts.length() != 2 {
            @stdio.stderr.write("error: invalid rewrite line: \{line}")
            @sys.exit(1)
          }
          let from = parts[0]
          let to = parts[1]
          notes_rewrite(
            wfs, rfs, git_dir, common_git_dir, notes_ref, from, to, force,
          )
        }
        return
      }
      guard from_ref is Some(from_commit) else {
        @stdio.stderr.write("usage: git notes rewrite <from> <to>")
        @sys.exit(1)
      }
      guard to_ref is Some(to_commit) else {
        @stdio.stderr.write("usage: git notes rewrite <from> <to>")
        @sys.exit(1)
      }
      notes_rewrite(
        wfs, rfs, git_dir, common_git_dir, notes_ref, from_commit, to_commit, force,
      )
    }
    "remove" => {
      let commit_ref = subargs.get(0).unwrap_or("HEAD")
      notes_remove(wfs, rfs, git_dir, common_git_dir, notes_ref, commit_ref)
    }
    "prune" => notes_prune(wfs, rfs, git_dir, common_git_dir, notes_ref)
    _ => {
      @stdio.stderr.write(
        "usage: git notes [--ref <name>] [list | show | add | append | edit | copy | merge | rewrite | remove | prune]",
      )
      @sys.exit(1)
    }
  }
}

///|
async fn notes_list(
  rfs : &@bitcore.RepoFileSystem,
  git_dir : String,
  common_git_dir : String,
  notes_ref : String,
) -> Unit raise Error {
  guard @bitlib.resolve_ref(rfs, git_dir, notes_ref) is Some(commit_id) else {
    return
  }
  let db = @bitlib.ObjectDb::load(rfs, common_git_dir)
  let obj = db.get(rfs, commit_id)
  guard obj is Some(o) else { return }
  let commit_info = @bitcore.parse_commit(o.data)
  let collected = notes_collect_all(rfs, db, commit_info.tree)
  for pair in collected {
    let (hex, id) = pair
    print_line("\{id.to_hex()} \{hex}")
  }
}

///|
async fn notes_show(
  rfs : &@bitcore.RepoFileSystem,
  git_dir : String,
  common_git_dir : String,
  notes_ref : String,
  commit_ref : String,
) -> Unit raise Error {
  // Resolve target commit
  let target_id = @bitrepo.rev_parse(rfs, git_dir, commit_ref)
  guard target_id is Some(tid) else {
    raise @bitcore.GitError::InvalidObject("unknown revision: \{commit_ref}")
  }
  let target_hex = tid.to_hex()
  // Check if notes ref exists
  guard @bitlib.resolve_ref(rfs, git_dir, notes_ref) is Some(commit_id) else {
    @stdio.stderr.write("error: no note found for \{target_hex}")
    @sys.exit(1)
  }
  let db = @bitlib.ObjectDb::load(rfs, common_git_dir)
  let obj = db.get(rfs, commit_id)
  guard obj is Some(o) else {
    @stdio.stderr.write("error: notes ref corrupt")
    @sys.exit(1)
  }
  let commit_info = @bitcore.parse_commit(o.data)
  // Find entry matching target commit (supports any fanout depth).
  match notes_lookup_blob(rfs, db, commit_info.tree, target_hex) {
    Some(blob_id) => {
      let note_obj = db.get(rfs, blob_id)
      guard note_obj is Some(no) else {
        @stdio.stderr.write("error: note blob corrupt")
        @sys.exit(1)
      }
      no.data |> decode_bytes |> print_line
      return
    }
    None => ()
  }
  @stdio.stderr.write("error: no note found for \{target_hex}")
  @sys.exit(1)
}

///|
/// Lookup a note blob ID for `commit_hex` in the given notes tree, supporting
/// any fanout depth. Returns None if the note isn't present.
fn notes_lookup_blob(
  rfs : &@bitcore.RepoFileSystem,
  db : @bitlib.ObjectDb,
  tree_id : @bitcore.ObjectId,
  commit_hex : String,
) -> @bitcore.ObjectId? raise Error {
  let obj = db.get(rfs, tree_id)
  guard obj is Some(o) else { return None }
  let entries = @bitcore.parse_tree(o.data)
  for e in entries {
    if e.name == commit_hex {
      return Some(e.id)
    }
    if (e.mode == "40000" || e.mode == "040000") &&
      commit_hex.length() > e.name.length() &&
      string_slice_to(commit_hex, e.name.length()) == e.name {
      let rest = string_slice_from(commit_hex, e.name.length())
      return notes_lookup_blob(rfs, db, e.id, rest)
    }
  }
  None
}

///|
/// Recursively collect all (full_commit_hex, blob_id) pairs from a notes tree.
fn notes_collect_all(
  rfs : &@bitcore.RepoFileSystem,
  db : @bitlib.ObjectDb,
  tree_id : @bitcore.ObjectId,
) -> Array[(String, @bitcore.ObjectId)] raise Error {
  let result : Array[(String, @bitcore.ObjectId)] = []
  notes_walk_tree(rfs, db, tree_id, "", result)
  result
}

///|
fn notes_walk_tree(
  rfs : &@bitcore.RepoFileSystem,
  db : @bitlib.ObjectDb,
  tree_id : @bitcore.ObjectId,
  prefix : String,
  out : Array[(String, @bitcore.ObjectId)],
) -> Unit raise Error {
  let obj = db.get(rfs, tree_id)
  guard obj is Some(o) else { return }
  let entries = @bitcore.parse_tree(o.data)
  for e in entries {
    if e.mode == "40000" || e.mode == "040000" {
      notes_walk_tree(rfs, db, e.id, prefix + e.name, out)
    } else {
      out.push((prefix + e.name, e.id))
    }
  }
}

///|
/// Threshold above which the notes tree is rebalanced into 1-level fanout
/// (subdirs named with the first 2 hex chars of the commit OID). Matches
/// the conventional 256-entry boundary used by upstream git.
let notes_fanout_threshold : Int = 256

///|
/// Build and write a notes tree for the given (commit_hex, blob_id) entries.
/// Picks fanout 0 when entries.length() <= notes_fanout_threshold, otherwise
/// fanout 1. Returns the root tree id.
fn notes_write_tree(
  wfs : &@bitcore.FileSystem,
  common_git_dir : String,
  notes : Array[(String, @bitcore.ObjectId)],
) -> @bitcore.ObjectId raise Error {
  if notes.length() <= notes_fanout_threshold {
    let entries : Array[@bitcore.TreeEntry] = []
    for pair in notes {
      let (hex, id) = pair
      entries.push(@bitcore.TreeEntry::new("100644", hex, id))
    }
    entries.sort_by((a, b) => a.name.compare(b.name))
    let (tree_id, tree_data) = @bitcore.create_tree(entries)
    @bitlib.write_object_bytes(wfs, common_git_dir, tree_id, tree_data)
    return tree_id
  }
  // Fanout 1: group by first 2 hex chars.
  let groups : Map[String, Array[@bitcore.TreeEntry]] = Map([])
  for pair in notes {
    let (hex, id) = pair
    let prefix = string_slice_to(hex, 2)
    let suffix = string_slice_from(hex, 2)
    let existing = groups.get(prefix)
    match existing {
      Some(g) => g.push(@bitcore.TreeEntry::new("100644", suffix, id))
      None => {
        let g : Array[@bitcore.TreeEntry] = []
        g.push(@bitcore.TreeEntry::new("100644", suffix, id))
        groups[prefix] = g
      }
    }
  }
  let prefixes : Array[String] = []
  for prefix, _ in groups {
    prefixes.push(prefix)
  }
  prefixes.sort()
  let top_entries : Array[@bitcore.TreeEntry] = []
  for prefix in prefixes {
    let group = groups.get(prefix).unwrap()
    group.sort_by((a, b) => a.name.compare(b.name))
    let (sub_id, sub_data) = @bitcore.create_tree(group)
    @bitlib.write_object_bytes(wfs, common_git_dir, sub_id, sub_data)
    top_entries.push(@bitcore.TreeEntry::new("40000", prefix, sub_id))
  }
  let (tree_id, tree_data) = @bitcore.create_tree(top_entries)
  @bitlib.write_object_bytes(wfs, common_git_dir, tree_id, tree_data)
  tree_id
}

///|
async fn notes_add(
  wfs : &@bitcore.FileSystem,
  rfs : &@bitcore.RepoFileSystem,
  git_dir : String,
  common_git_dir : String,
  notes_ref : String,
  commit_ref : String,
  message : String,
  force : Bool,
) -> Unit raise Error {
  // Resolve target commit
  let target_id = @bitrepo.rev_parse(rfs, git_dir, commit_ref)
  guard target_id is Some(tid) else {
    raise @bitcore.GitError::InvalidObject("unknown revision: \{commit_ref}")
  }
  let target_hex = tid.to_hex()
  // Create blob for note content
  let note_content = @utf8.encode(message)
  let note_id = @bitlib.write_loose_object(
    wfs,
    common_git_dir,
    @bitcore.ObjectType::Blob,
    note_content,
  )
  // Collect all existing notes (recursively across any fanout depth).
  let notes : Array[(String, @bitcore.ObjectId)] = []
  let mut parent_commit : @bitcore.ObjectId? = None
  if @bitlib.resolve_ref(rfs, git_dir, notes_ref) is Some(commit_id) {
    parent_commit = Some(commit_id)
    let db = @bitlib.ObjectDb::load(rfs, common_git_dir)
    let obj = db.get(rfs, commit_id)
    match obj {
      Some(o) => {
        let commit_info = @bitcore.parse_commit(o.data)
        let collected = notes_collect_all(rfs, db, commit_info.tree)
        for pair in collected {
          let (hex, id) = pair
          if hex == target_hex {
            if !force {
              @stdio.stderr.write(
                "error: note already exists for \{target_hex}",
              )
              @stdio.stderr.write("Use -f to overwrite existing note")
              @sys.exit(1)
            }
            // Skip existing note (will be replaced)
          } else {
            notes.push((hex, id))
          }
        }
      }
      None => ()
    }
  }
  // Add new note entry, then write tree at the appropriate fanout level.
  notes.push((target_hex, note_id))
  let tree_id = notes_write_tree(wfs, common_git_dir, notes)
  // Create commit
  let author = get_author_string()
  let timestamp = @sys.get_env_var("GIT_COMMITTER_DATE")
    .map(parse_commit_date)
    .unwrap_or(get_current_timestamp())
  let parents = match parent_commit {
    Some(p) => [p]
    None => []
  }
  let commit = @bitcore.Commit::new(
    tree_id, parents, author, timestamp, "+0000", author, timestamp, "+0000", "Notes added by 'git notes add'\n",
  )
  let (commit_id, commit_data) = @bitcore.create_commit(commit)
  @bitlib.write_object_bytes(wfs, common_git_dir, commit_id, commit_data)
  notes_update_ref(wfs, rfs, common_git_dir, notes_ref, commit_id)
}

///|
async fn notes_append(
  wfs : &@bitcore.FileSystem,
  rfs : &@bitcore.RepoFileSystem,
  git_dir : String,
  common_git_dir : String,
  notes_ref : String,
  commit_ref : String,
  message : String,
) -> Unit raise Error {
  // Resolve target commit
  let target_id = @bitrepo.rev_parse(rfs, git_dir, commit_ref)
  guard target_id is Some(tid) else {
    raise @bitcore.GitError::InvalidObject("unknown revision: \{commit_ref}")
  }
  let target_hex = tid.to_hex()
  // Collect existing notes (across any fanout), capture current text if any.
  let notes : Array[(String, @bitcore.ObjectId)] = []
  let mut parent_commit : @bitcore.ObjectId? = None
  let mut existing_text : String? = None
  if @bitlib.resolve_ref(rfs, git_dir, notes_ref) is Some(commit_id) {
    parent_commit = Some(commit_id)
    let db = @bitlib.ObjectDb::load(rfs, common_git_dir)
    let obj = db.get(rfs, commit_id)
    guard obj is Some(o) else {
      @stdio.stderr.write("error: notes ref corrupt")
      @sys.exit(1)
    }
    let commit_info = @bitcore.parse_commit(o.data)
    let collected = notes_collect_all(rfs, db, commit_info.tree)
    for pair in collected {
      let (hex, id) = pair
      if hex == target_hex {
        let note_obj = db.get(rfs, id)
        guard note_obj is Some(no) else {
          @stdio.stderr.write("error: note blob corrupt")
          @sys.exit(1)
        }
        existing_text = no.data |> decode_bytes |> Some
      } else {
        notes.push((hex, id))
      }
    }
  }
  let new_text = match existing_text {
    Some(text) => {
      let sep = if text == "" || text.has_suffix("\n") { "" } else { "\n" }
      text + sep + message
    }
    None => message
  }
  // Create blob for note content
  let note_content = @utf8.encode(new_text)
  let note_id = @bitlib.write_loose_object(
    wfs,
    common_git_dir,
    @bitcore.ObjectType::Blob,
    note_content,
  )
  // Add new note entry, write tree at appropriate fanout.
  notes.push((target_hex, note_id))
  let tree_id = notes_write_tree(wfs, common_git_dir, notes)
  // Create commit
  let author = get_author_string()
  let timestamp = get_current_timestamp()
  let parents = match parent_commit {
    Some(p) => [p]
    None => []
  }
  let commit = @bitcore.Commit::new(
    tree_id, parents, author, timestamp, "+0000", author, timestamp, "+0000", "Notes appended by 'git notes append'\n",
  )
  let (commit_id, commit_data) = @bitcore.create_commit(commit)
  @bitlib.write_object_bytes(wfs, common_git_dir, commit_id, commit_data)
  notes_update_ref(wfs, rfs, common_git_dir, notes_ref, commit_id)
}

///|
async fn notes_copy(
  wfs : &@bitcore.FileSystem,
  rfs : &@bitcore.RepoFileSystem,
  git_dir : String,
  common_git_dir : String,
  notes_ref : String,
  from_ref : String,
  to_ref : String,
  force : Bool,
) -> Unit raise Error {
  // Resolve commits
  let from_id = @bitrepo.rev_parse(rfs, git_dir, from_ref)
  guard from_id is Some(fid) else {
    raise @bitcore.GitError::InvalidObject("unknown revision: \{from_ref}")
  }
  let to_id = @bitrepo.rev_parse(rfs, git_dir, to_ref)
  guard to_id is Some(tid) else {
    raise @bitcore.GitError::InvalidObject("unknown revision: \{to_ref}")
  }
  let from_hex = fid.to_hex()
  let to_hex = tid.to_hex()
  if from_hex == to_hex {
    @stdio.stderr.write("error: note already exists for \{to_hex}")
    @sys.exit(1)
  }
  // Load notes tree
  guard @bitlib.resolve_ref(rfs, git_dir, notes_ref) is Some(commit_id) else {
    @stdio.stderr.write("error: no note found for \{from_hex}")
    @sys.exit(1)
  }
  let db = @bitlib.ObjectDb::load(rfs, common_git_dir)
  let obj = db.get(rfs, commit_id)
  guard obj is Some(o) else {
    @stdio.stderr.write("error: notes ref corrupt")
    @sys.exit(1)
  }
  let commit_info = @bitcore.parse_commit(o.data)
  let collected = notes_collect_all(rfs, db, commit_info.tree)
  let notes : Array[(String, @bitcore.ObjectId)] = []
  let mut source_blob : @bitcore.ObjectId? = None
  let mut dest_exists = false
  for pair in collected {
    let (hex, id) = pair
    if hex == from_hex {
      source_blob = Some(id)
      notes.push((hex, id))
    } else if hex == to_hex {
      dest_exists = true
      if force {
        // skip existing destination (will be replaced below)
      } else {
        notes.push((hex, id))
      }
    } else {
      notes.push((hex, id))
    }
  }
  guard source_blob is Some(src_id) else {
    @stdio.stderr.write("error: no note found for \{from_hex}")
    @sys.exit(1)
  }
  if dest_exists && !force {
    @stdio.stderr.write("error: note already exists for \{to_hex}")
    @sys.exit(1)
  }
  notes.push((to_hex, src_id))
  let tree_id = notes_write_tree(wfs, common_git_dir, notes)
  let author = get_author_string()
  let timestamp = @sys.get_env_var("GIT_COMMITTER_DATE")
    .map(parse_commit_date)
    .unwrap_or(get_current_timestamp())
  let commit = @bitcore.Commit::new(
    tree_id,
    [commit_id],
    author,
    timestamp,
    "+0000",
    author,
    timestamp,
    "+0000",
    "Notes copied by 'git notes copy'\n",
  )
  let (new_commit_id, commit_data) = @bitcore.create_commit(commit)
  @bitlib.write_object_bytes(wfs, common_git_dir, new_commit_id, commit_data)
  notes_update_ref(wfs, rfs, common_git_dir, notes_ref, new_commit_id)
}

///|
async fn notes_remove(
  wfs : &@bitcore.FileSystem,
  rfs : &@bitcore.RepoFileSystem,
  git_dir : String,
  common_git_dir : String,
  notes_ref : String,
  commit_ref : String,
) -> Unit raise Error {
  // Resolve target commit
  let target_id = @bitrepo.rev_parse(rfs, git_dir, commit_ref)
  guard target_id is Some(tid) else {
    raise @bitcore.GitError::InvalidObject("unknown revision: \{commit_ref}")
  }
  let target_hex = tid.to_hex()
  // Check if notes ref exists
  guard @bitlib.resolve_ref(rfs, git_dir, notes_ref) is Some(commit_id) else {
    @stdio.stderr.write("error: no note found for \{target_hex}")
    @sys.exit(1)
  }
  let db = @bitlib.ObjectDb::load(rfs, common_git_dir)
  let obj = db.get(rfs, commit_id)
  guard obj is Some(o) else {
    @stdio.stderr.write("error: notes ref corrupt")
    @sys.exit(1)
  }
  let commit_info = @bitcore.parse_commit(o.data)
  let collected = notes_collect_all(rfs, db, commit_info.tree)
  // Filter out target entry
  let mut found = false
  let notes : Array[(String, @bitcore.ObjectId)] = []
  for pair in collected {
    let (hex, id) = pair
    if hex == target_hex {
      found = true
    } else {
      notes.push((hex, id))
    }
  }
  if !found {
    @stdio.stderr.write("error: no note found for \{target_hex}")
    @sys.exit(1)
  }
  let tree_id = notes_write_tree(wfs, common_git_dir, notes)
  // Create commit
  let author = get_author_string()
  let timestamp = @sys.get_env_var("GIT_COMMITTER_DATE")
    .map(parse_commit_date)
    .unwrap_or(get_current_timestamp())
  let commit = @bitcore.Commit::new(
    tree_id,
    [commit_id],
    author,
    timestamp,
    "+0000",
    author,
    timestamp,
    "+0000",
    "Notes removed by 'git notes remove'\n",
  )
  let (new_commit_id, commit_data) = @bitcore.create_commit(commit)
  @bitlib.write_object_bytes(wfs, common_git_dir, new_commit_id, commit_data)
  notes_update_ref(wfs, rfs, common_git_dir, notes_ref, new_commit_id)
  print_line("Removing note for \{target_hex}")
}

///|
async fn notes_prune(
  wfs : &@bitcore.FileSystem,
  rfs : &@bitcore.RepoFileSystem,
  git_dir : String,
  common_git_dir : String,
  notes_ref : String,
) -> Unit raise Error {
  // Check if notes ref exists
  guard @bitlib.resolve_ref(rfs, git_dir, notes_ref) is Some(commit_id) else {
    return
  }
  let db = @bitlib.ObjectDb::load(rfs, common_git_dir)
  let obj = db.get(rfs, commit_id)
  guard obj is Some(o) else { return }
  let commit_info = @bitcore.parse_commit(o.data)
  let collected = notes_collect_all(rfs, db, commit_info.tree)
  // Filter entries where the referenced commit still exists
  let notes : Array[(String, @bitcore.ObjectId)] = []
  let mut pruned = 0
  for pair in collected {
    let (hex, id) = pair
    let ref_id = @bitcore.ObjectId::from_hex(hex)
    let ref_obj = db.get(rfs, ref_id) catch {
      err if @async.is_cancellation_error(err) => raise err
      _ => None
    }
    match ref_obj {
      Some(_) => notes.push((hex, id))
      None => pruned += 1
    }
  }
  if pruned == 0 {
    return
  }
  let tree_id = notes_write_tree(wfs, common_git_dir, notes)
  // Create commit
  let author = get_author_string()
  let timestamp = @sys.get_env_var("GIT_COMMITTER_DATE")
    .map(parse_commit_date)
    .unwrap_or(get_current_timestamp())
  let commit = @bitcore.Commit::new(
    tree_id,
    [commit_id],
    author,
    timestamp,
    "+0000",
    author,
    timestamp,
    "+0000",
    "Notes pruned by 'git notes prune'\n",
  )
  let (new_commit_id, commit_data) = @bitcore.create_commit(commit)
  @bitlib.write_object_bytes(wfs, common_git_dir, new_commit_id, commit_data)
  notes_update_ref(wfs, rfs, common_git_dir, notes_ref, new_commit_id)
  print_line("Pruned \{pruned} notes")
}

///|
async fn load_notes_tree(
  rfs : &@bitcore.RepoFileSystem,
  git_dir : String,
  common_git_dir : String,
  notes_ref : String,
) -> (@bitcore.ObjectId, Array[@bitcore.TreeEntry])? raise Error {
  guard @bitlib.resolve_ref(rfs, git_dir, notes_ref) is Some(commit_id) else {
    return None
  }
  let db = @bitlib.ObjectDb::load(rfs, common_git_dir)
  let obj = db.get(rfs, commit_id)
  guard obj is Some(o) else {
    @stdio.stderr.write("error: notes ref corrupt")
    @sys.exit(1)
    return None
  }
  let commit_info = @bitcore.parse_commit(o.data)
  let tree_obj = db.get(rfs, commit_info.tree)
  guard tree_obj is Some(to) else {
    @stdio.stderr.write("error: notes tree corrupt")
    @sys.exit(1)
    return None
  }
  let entries = @bitcore.parse_tree(to.data)
  Some((commit_id, entries))
}

///|
async fn note_text(
  db : @bitlib.ObjectDb,
  rfs : &@bitcore.RepoFileSystem,
  entry : @bitcore.TreeEntry,
) -> String raise Error {
  let obj = db.get(rfs, entry.id)
  guard obj is Some(o) else {
    @stdio.stderr.write("error: note blob corrupt")
    @sys.exit(1)
    return ""
  }
  decode_bytes(o.data)
}

///|
fn merge_notes_union(ours : String, theirs : String) -> String {
  if ours == "" {
    return theirs
  }
  if theirs == "" {
    return ours
  }
  let sep = if ours.has_suffix("\n") { "" } else { "\n" }
  ours + sep + theirs
}

///|
fn join_lines(lines : Array[String]) -> String {
  let mut out = ""
  let mut first = true
  for line in lines {
    if first {
      out = line
      first = false
    } else {
      out = out + "\n" + line
    }
  }
  out
}

///|
fn merge_notes_cat_sort_uniq(ours : String, theirs : String) -> String {
  let lines : Array[String] = []
  for line in split_lines(ours) {
    if line != "" {
      lines.push(line)
    }
  }
  for line in split_lines(theirs) {
    if line != "" {
      lines.push(line)
    }
  }
  if lines.length() == 0 {
    return ""
  }
  lines.sort()
  let uniq : Array[String] = []
  let mut prev : String? = None
  for line in lines {
    match prev {
      Some(p) if p == line => ()
      _ => {
        uniq.push(line)
        prev = Some(line)
      }
    }
  }
  join_lines(uniq)
}

///|
fn split_whitespace_tokens(line : String) -> Array[String] {
  let tokens : Array[String] = []
  let mut current = StringBuilder::new()
  let mut in_token = false
  for c in line {
    if c == ' ' || c == '\t' {
      if in_token {
        tokens.push(current.to_string())
        current = StringBuilder::new()
        in_token = false
      }
    } else {
      current.write_char(c)
      in_token = true
    }
  }
  if in_token {
    tokens.push(current.to_string())
  }
  tokens
}

///|
async fn notes_merge(
  wfs : &@bitcore.FileSystem,
  rfs : &@bitcore.RepoFileSystem,
  git_dir : String,
  common_git_dir : String,
  notes_ref : String,
  other_notes_ref : String,
  strategy : String?,
) -> Unit raise Error {
  let current = load_notes_tree(rfs, git_dir, common_git_dir, notes_ref)
  let other = load_notes_tree(rfs, git_dir, common_git_dir, other_notes_ref)
  guard other is Some((other_commit_id, other_entries)) else {
    @stdio.stderr.write("error: no notes found to merge")
    @sys.exit(1)
  }
  match current {
    None => {
      notes_update_ref(wfs, rfs, common_git_dir, notes_ref, other_commit_id)
      return
    }
    Some((current_commit_id, current_entries)) => {
      let db = @bitlib.ObjectDb::load(rfs, common_git_dir)
      let entries : Map[String, @bitcore.TreeEntry] = Map([])
      for e in current_entries {
        entries.set(e.name, e)
      }
      let mut conflicts = 0
      for e in other_entries {
        match entries.get(e.name) {
          None => entries.set(e.name, e)
          Some(existing) =>
            if existing.id == e.id {
              ()
            } else if strategy == Some("theirs") {
              entries.set(e.name, e)
            } else if strategy == Some("ours") {
              ()
            } else if strategy == Some("union") {
              let ours = note_text(db, rfs, existing)
              let theirs = note_text(db, rfs, e)
              let merged = merge_notes_union(ours, theirs)
              let merged_content = @utf8.encode(merged)
              let merged_id = @bitlib.write_loose_object(
                wfs,
                common_git_dir,
                @bitcore.ObjectType::Blob,
                merged_content,
              )
              entries.set(
                e.name,
                @bitcore.TreeEntry::new("100644", e.name, merged_id),
              )
            } else if strategy == Some("cat_sort_uniq") {
              let ours = note_text(db, rfs, existing)
              let theirs = note_text(db, rfs, e)
              let merged = merge_notes_cat_sort_uniq(ours, theirs)
              let merged_content = @utf8.encode(merged)
              let merged_id = @bitlib.write_loose_object(
                wfs,
                common_git_dir,
                @bitcore.ObjectType::Blob,
                merged_content,
              )
              entries.set(
                e.name,
                @bitcore.TreeEntry::new("100644", e.name, merged_id),
              )
            } else {
              conflicts += 1
            }
        }
      }
      if conflicts > 0 {
        @stdio.stderr.write("error: notes merge conflict")
        @sys.exit(1)
      }
      let merged_entries : Array[@bitcore.TreeEntry] = []
      entries.each((_k, v) => merged_entries.push(v))
      merged_entries.sort_by((a, b) => a.name.compare(b.name))
      let (tree_id, tree_data) = @bitcore.create_tree(merged_entries)
      @bitlib.write_object_bytes(wfs, common_git_dir, tree_id, tree_data)
      let author = get_author_string()
      let timestamp = get_current_timestamp()
      let current_hex = current_commit_id.to_hex()
      let other_hex = other_commit_id.to_hex()
      let parents = if current_hex == other_hex {
        [current_commit_id]
      } else {
        [current_commit_id, other_commit_id]
      }
      let commit = @bitcore.Commit::new(
        tree_id, parents, author, timestamp, "+0000", author, timestamp, "+0000",
        "Notes merged by 'git notes merge'\n",
      )
      let (new_commit_id, commit_data) = @bitcore.create_commit(commit)
      @bitlib.write_object_bytes(
        wfs, common_git_dir, new_commit_id, commit_data,
      )
      notes_update_ref(wfs, rfs, common_git_dir, notes_ref, new_commit_id)
    }
  }
}

///|
async fn notes_rewrite(
  wfs : &@bitcore.FileSystem,
  rfs : &@bitcore.RepoFileSystem,
  git_dir : String,
  common_git_dir : String,
  notes_ref : String,
  from_ref : String,
  to_ref : String,
  force : Bool,
) -> Unit raise Error {
  let from_id = @bitrepo.rev_parse(rfs, git_dir, from_ref)
  guard from_id is Some(fid) else {
    raise @bitcore.GitError::InvalidObject("unknown revision: \{from_ref}")
  }
  let to_id = @bitrepo.rev_parse(rfs, git_dir, to_ref)
  guard to_id is Some(tid) else {
    raise @bitcore.GitError::InvalidObject("unknown revision: \{to_ref}")
  }
  let from_hex = fid.to_hex()
  let to_hex = tid.to_hex()
  if from_hex == to_hex {
    return
  }
  let current = load_notes_tree(rfs, git_dir, common_git_dir, notes_ref)
  guard current is Some((current_commit_id, current_entries)) else { return }
  let entries : Map[String, @bitcore.TreeEntry] = Map([])
  let mut source : @bitcore.TreeEntry? = None
  let mut dest_exists = false
  for e in current_entries {
    if e.name == from_hex {
      source = Some(e)
    } else if e.name == to_hex {
      dest_exists = true
      entries.set(e.name, e)
    } else {
      entries.set(e.name, e)
    }
  }
  guard source is Some(src) else { return }
  if dest_exists && !force {
    @stdio.stderr.write("error: note already exists for \{to_hex}")
    @sys.exit(1)
  }
  entries.remove(from_hex)
  entries.set(to_hex, @bitcore.TreeEntry::new("100644", to_hex, src.id))
  let rewritten_entries : Array[@bitcore.TreeEntry] = []
  entries.each((_k, v) => rewritten_entries.push(v))
  rewritten_entries.sort_by((a, b) => a.name.compare(b.name))
  let (tree_id, tree_data) = @bitcore.create_tree(rewritten_entries)
  @bitlib.write_object_bytes(wfs, common_git_dir, tree_id, tree_data)
  let author = get_author_string()
  let timestamp = get_current_timestamp()
  let commit = @bitcore.Commit::new(
    tree_id,
    [current_commit_id],
    author,
    timestamp,
    "+0000",
    author,
    timestamp,
    "+0000",
    "Notes rewritten by 'git notes rewrite'\n",
  )
  let (new_commit_id, commit_data) = @bitcore.create_commit(commit)
  @bitlib.write_object_bytes(wfs, common_git_dir, new_commit_id, commit_data)
  notes_update_ref(wfs, rfs, common_git_dir, notes_ref, new_commit_id)
}

///|
/// Resolve the common git dir for shared refs and objects. A linked
/// worktree's git dir contains a "commondir" file pointing at the main
/// repository's git dir; plain repositories resolve to themselves.
fn notes_resolve_common_git_dir(
  rfs : &@bitcore.RepoFileSystem,
  git_dir : String,
) -> String {
  let commondir_path = git_dir + "/commondir"
  if !rfs.is_file(commondir_path) {
    return git_dir
  }
  let raw = @utf8.decode_lossy(
    (rfs.read_file(commondir_path) catch { _ => Default::default() })[:],
  )
  let rel = trim_string(raw)
  if rel.length() == 0 {
    return git_dir
  }
  if rel.has_prefix("/") {
    normalize_path(rel)
  } else {
    normalize_path(git_dir + "/" + rel)
  }
}

///|
/// Point `notes_ref` at `commit_id` as a loose ref under the common git dir,
/// creating parent directories as needed. A loose ref shadows any stale
/// packed-refs entry for the same name.
fn notes_update_ref(
  wfs : &@bitcore.FileSystem,
  rfs : &@bitcore.RepoFileSystem,
  common_git_dir : String,
  notes_ref : String,
  commit_id : @bitcore.ObjectId,
) -> Unit raise Error {
  let ref_path = common_git_dir + "/" + notes_ref
  match ref_path.rev_find("/") {
    Some(i) => {
      let dir = String::unsafe_substring(ref_path, start=0, end=i)
      if dir.length() > 0 && !rfs.is_dir(dir) {
        wfs.mkdir_p(dir)
      }
    }
    None => ()
  }
  wfs.write_string(ref_path, commit_id.to_hex() + "\n")
}

///|
/// Handle git bisect command

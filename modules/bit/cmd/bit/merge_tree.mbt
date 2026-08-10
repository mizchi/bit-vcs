///| merge-tree: perform merge without touching index or working tree

///|
priv struct MergeTreeEntry {
  id : @bitcore.ObjectId
  mode : Int
}

///|
async fn handle_merge_tree(args : Array[String]) -> Unit raise Error {
  let fs = OsFs::new()
  let git_dir = find_git_dir(fs)
  let mut nul_term = false
  let mut name_only = false
  let mut show_messages = true
  let mut allow_unrelated = false
  let positional : Array[String] = []
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    match arg {
      "-h" | "--help" => {
        print_line(
          "usage: git merge-tree [--write-tree] [<options>] <branch1> <branch2>",
        )
        return
      }
      "--write-tree" => () // default in modern mode, accepted but no-op
      "-z" => nul_term = true
      "--name-only" => name_only = true
      "--messages" => show_messages = true
      "--no-messages" => show_messages = false
      "--allow-unrelated-histories" => allow_unrelated = true
      _ if arg.has_prefix("-") => warn_unimplemented_arg("merge-tree", arg)
      _ => positional.push(arg)
    }
    i += 1
  }
  if positional.length() < 2 {
    eprint_line("usage: git merge-tree [--write-tree] <branch1> <branch2>")
    @sys.exit(128)
    return
  }
  let branch1_name = positional[0]
  let branch2_name = positional[1]
  // Resolve refs to commit OIDs
  let ours_id = merge_tree_resolve_ref(fs, git_dir, branch1_name)
  let theirs_id = merge_tree_resolve_ref(fs, git_dir, branch2_name)
  let db = @bitlib.ObjectDb::load(fs, git_dir)
  // Find merge base
  let base_id = merge_tree_find_base(db, fs, ours_id, theirs_id)
  if base_id is None && !allow_unrelated {
    eprint_line(
      "fatal: refusing to merge unrelated histories (use --allow-unrelated-histories to override)",
    )
    @sys.exit(128)
    return
  }
  // Collect tree files for base, ours, theirs and convert to our own entry type
  let base_files = match base_id {
    Some(id) =>
      merge_tree_convert_files(
        @bitlib.collect_tree_files_from_commit(db, fs, id),
      )
    None => Map([])
  }
  let ours_files = merge_tree_convert_files(
    @bitlib.collect_tree_files_from_commit(db, fs, ours_id),
  )
  let theirs_files = merge_tree_convert_files(
    @bitlib.collect_tree_files_from_commit(db, fs, theirs_id),
  )
  // Perform file-level merge
  let merge_result = merge_tree_merge_files(
    base_files, ours_files, theirs_files,
  )
  let merged = merge_result.merged
  let conflicts = merge_result.conflicts
  let needs_content_merge = merge_result.needs_content_merge
  // Perform content-level merge for files modified on both sides
  for candidate in needs_content_merge {
    let base_content = match candidate.base_id {
      Some(id) => merge_tree_get_blob_text(db, fs, id)
      None => ""
    }
    let ours_content = merge_tree_get_blob_text(db, fs, candidate.ours_id)
    let theirs_content = merge_tree_get_blob_text(db, fs, candidate.theirs_id)
    // Check for binary content
    let ours_data = merge_tree_get_blob_data(db, fs, candidate.ours_id)
    let theirs_data = merge_tree_get_blob_data(db, fs, candidate.theirs_id)
    if merge_tree_is_binary(ours_data) || merge_tree_is_binary(theirs_data) {
      conflicts.push(candidate.path)
      // For binary conflicts, keep ours side in result tree
      merged[candidate.path] = { id: candidate.ours_id, mode: candidate.mode }
      continue
    }
    let result = @diff3.content_merge(
      base_content,
      ours_content,
      theirs_content,
      @diff3.ContentMergeOptions::default(),
    )
    if result.has_conflicts {
      // Write conflict-marker content as blob
      let content_bytes = @utf8.encode(result.content)
      let (blob_id, compressed) = @bitcore.create_blob(content_bytes)
      @bitlib.write_object_bytes(fs, git_dir, blob_id, compressed)
      merged[candidate.path] = { id: blob_id, mode: candidate.mode }
      conflicts.push(candidate.path)
    } else {
      // Clean merge - create new blob
      let content_bytes = @utf8.encode(result.content)
      let (blob_id, compressed) = @bitcore.create_blob(content_bytes)
      @bitlib.write_object_bytes(fs, git_dir, blob_id, compressed)
      merged[candidate.path] = { id: blob_id, mode: candidate.mode }
    }
  }
  // Build result tree from merged files
  let tree_id = merge_tree_write_tree(fs, git_dir, merged)
  // Output
  let line_sep = if nul_term { "\u0000" } else { "\n" }
  print_str(tree_id.to_hex())
  print_str(line_sep)
  if conflicts.length() > 0 {
    conflicts.sort()
    if show_messages {
      if name_only {
        for path in conflicts {
          print_str(path)
          print_str(line_sep)
        }
      } else {
        // Print conflict info messages
        for path in conflicts {
          print_str("CONFLICT (content): Merge conflict in ")
          print_str(path)
          print_str(line_sep)
        }
      }
    }
    @sys.exit(1)
  }
}

///|
fn merge_tree_convert_files(
  files : Map[String, @bitlib.TreeFileEntry],
) -> Map[String, MergeTreeEntry] {
  let out : Map[String, MergeTreeEntry] = Map([])
  for path, entry in files {
    out[path] = { id: entry.id, mode: entry.mode }
  }
  out
}

///|
async fn merge_tree_resolve_ref(
  fs : OsFs,
  git_dir : String,
  name : String,
) -> @bitcore.ObjectId raise Error {
  match @bitrepo.rev_parse(fs, git_dir, name) {
    Some(id) => id
    None => {
      eprint_line("fatal: Not a valid object name \{name}")
      @sys.exit(128)
      return @bitcore.ObjectId::from_hex(
        "0000000000000000000000000000000000000000",
      )
    }
  }
}

///|
fn merge_tree_find_base(
  db : @bitlib.ObjectDb,
  fs : &@bitcore.RepoFileSystem,
  a : @bitcore.ObjectId,
  b : @bitcore.ObjectId,
) -> @bitcore.ObjectId? raise Error {
  // BFS from a to collect all ancestors
  let seen : Map[String, Bool] = Map([])
  let stack_a : Array[@bitcore.ObjectId] = [a]
  while stack_a.length() > 0 {
    let id = stack_a.pop().unwrap()
    let hex = id.to_hex()
    if seen.contains(hex) {
      continue
    }
    seen[hex] = true
    let parents = merge_tree_commit_parents(db, fs, id)
    for p in parents {
      stack_a.push(p)
    }
  }
  // BFS from b to find first ancestor in a's set
  let stack_b : Array[@bitcore.ObjectId] = [b]
  let seen_b : Map[String, Bool] = Map([])
  while stack_b.length() > 0 {
    let id = stack_b.pop().unwrap()
    let hex = id.to_hex()
    if seen_b.contains(hex) {
      continue
    }
    seen_b[hex] = true
    if seen.contains(hex) {
      return Some(id)
    }
    let parents = merge_tree_commit_parents(db, fs, id)
    for p in parents {
      stack_b.push(p)
    }
  }
  None
}

///|
fn merge_tree_commit_parents(
  db : @bitlib.ObjectDb,
  fs : &@bitcore.RepoFileSystem,
  commit_id : @bitcore.ObjectId,
) -> Array[@bitcore.ObjectId] raise Error {
  let obj = db.get(fs, commit_id)
  match obj {
    None => raise @bitcore.GitError::InvalidObject("Missing commit object")
    Some(o) => {
      if o.obj_type != @bitcore.ObjectType::Commit {
        raise @bitcore.GitError::InvalidObject("Object is not a commit")
      }
      @bitcore.parse_commit(o.data).parents
    }
  }
}

///|
priv struct MergeTreeFilesResult {
  merged : Map[String, MergeTreeEntry]
  conflicts : Array[String]
  needs_content_merge : Array[MergeTreeContentCandidate]
}

///|
priv struct MergeTreeContentCandidate {
  path : String
  base_id : @bitcore.ObjectId?
  ours_id : @bitcore.ObjectId
  theirs_id : @bitcore.ObjectId
  mode : Int
}

///|
fn merge_tree_merge_files(
  base : Map[String, MergeTreeEntry],
  ours : Map[String, MergeTreeEntry],
  theirs : Map[String, MergeTreeEntry],
) -> MergeTreeFilesResult {
  let merged : Map[String, MergeTreeEntry] = Map([])
  let conflicts : Array[String] = []
  let needs_content_merge : Array[MergeTreeContentCandidate] = []
  let all_paths : Map[String, Bool] = Map([])
  for path in base.keys() {
    all_paths[path] = true
  }
  for path in ours.keys() {
    all_paths[path] = true
  }
  for path in theirs.keys() {
    all_paths[path] = true
  }
  for path in all_paths.keys() {
    let b = base.get(path)
    let o = ours.get(path)
    let t = theirs.get(path)
    if merge_tree_entry_eq(o, t) {
      // Both sides same (or both absent)
      match o {
        None => ()
        Some(v) => merged[path] = v
      }
    } else if merge_tree_entry_eq(o, b) {
      // Only theirs changed
      match t {
        None => ()
        Some(v) => merged[path] = v
      }
    } else if merge_tree_entry_eq(t, b) {
      // Only ours changed
      match o {
        None => ()
        Some(v) => merged[path] = v
      }
    } else {
      // Both sides modified differently
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
          // One side deleted, other modified
          conflicts.push(path)
      }
    }
  }
  { merged, conflicts, needs_content_merge }
}

///|
fn merge_tree_entry_eq(a : MergeTreeEntry?, b : MergeTreeEntry?) -> Bool {
  match (a, b) {
    (None, None) => true
    (Some(x), Some(y)) => x.id == y.id && x.mode == y.mode
    _ => false
  }
}

///|
fn merge_tree_get_blob_text(
  db : @bitlib.ObjectDb,
  fs : &@bitcore.RepoFileSystem,
  id : @bitcore.ObjectId,
) -> String {
  let obj = db.get(fs, id) catch { _ => return "" }
  match obj {
    Some(o) if o.obj_type == @bitcore.ObjectType::Blob =>
      @utf8.decode_lossy(o.data[:])
    _ => ""
  }
}

///|
fn merge_tree_get_blob_data(
  db : @bitlib.ObjectDb,
  fs : &@bitcore.RepoFileSystem,
  id : @bitcore.ObjectId,
) -> Bytes {
  let obj = db.get(fs, id) catch { _ => return Default::default() }
  match obj {
    Some(o) if o.obj_type == @bitcore.ObjectType::Blob => o.data
    _ => Default::default()
  }
}

///|
fn merge_tree_is_binary(data : Bytes) -> Bool {
  let check_len = if data.length() < 8000 { data.length() } else { 8000 }
  for i in 0..<check_len {
    if data[i] == b'\x00' {
      return true
    }
  }
  false
}

///|
fn merge_tree_write_tree(
  fs : OsFs,
  git_dir : String,
  files : Map[String, MergeTreeEntry],
) -> @bitcore.ObjectId raise Error {
  // Build hierarchical tree structure from flat path map
  let file_entries : Array[@bitcore.TreeEntry] = []
  let dir_map : Map[String, Map[String, MergeTreeEntry]] = Map([])
  let items = files.to_array()
  for item in items {
    let (path, info) = item
    match path.find("/") {
      None => {
        let mode = merge_tree_mode_to_string(info.mode)
        file_entries.push(@bitcore.TreeEntry::new(mode, path, info.id))
      }
      Some(slash_idx) => {
        let dir_name = String::unsafe_substring(path, start=0, end=slash_idx)
        let rest = String::unsafe_substring(
          path,
          start=slash_idx + 1,
          end=path.length(),
        )
        match dir_map.get(dir_name) {
          Some(sub) => sub[rest] = info
          None => {
            let sub : Map[String, MergeTreeEntry] = Map([])
            sub[rest] = info
            dir_map[dir_name] = sub
          }
        }
      }
    }
  }
  // Recursively write subtrees
  for dir_name, sub_files in dir_map {
    let sub_tree_id = merge_tree_write_tree(fs, git_dir, sub_files)
    file_entries.push(@bitcore.TreeEntry::new("40000", dir_name, sub_tree_id))
  }
  // Sort entries by git tree sort order
  file_entries.sort_by(fn(a, b) {
    let a_key = if a.mode == "40000" { a.name + "/" } else { a.name }
    let b_key = if b.mode == "40000" { b.name + "/" } else { b.name }
    String::compare(a_key, b_key)
  })
  let (tree_id, compressed) = @bitcore.create_tree(file_entries)
  @bitlib.write_object_bytes(fs, git_dir, tree_id, compressed)
  tree_id
}

///|
fn merge_tree_mode_to_string(mode : Int) -> String {
  @string_utils.mode_to_string(mode)
}

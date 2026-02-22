///| Pack handlers: rev-list, verify-pack, unpack-objects, bundle

///|
async fn handle_rev_list(args : Array[String]) -> Unit raise Error {
  let fs = OsFs::new()
  let git_dir = find_git_dir(fs)
  let mut max_count : Int? = None
  let mut count_only = false
  let mut objects = false
  let mut quiet = false
  let mut reverse = false
  let mut first_parent = false
  let mut all = false
  let mut stdin = false
  let mut test_bitmap = false
  let mut use_bitmap = false
  let mut no_object_names = false
  let refs : Array[String] = []
  let excludes : Array[String] = []
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    match arg {
      "-n" | "--max-count" if i + 1 < args.length() => {
        max_count = Some(
          @strconv.parse_int(args[i + 1]) catch {
            err if @async.is_cancellation_error(err) => raise err
            _ => 0
          },
        )
        i += 2
        continue
      }
      "--count" => count_only = true
      "--objects" | "--objects-edge" => objects = true
      "--quiet" | "-q" => quiet = true
      "--reverse" => reverse = true
      "--ancestry-path" => () // Ignored for now
      "--first-parent" => first_parent = true
      "--all" => all = true
      "--stdin" => stdin = true
      "--test-bitmap" => test_bitmap = true
      "--use-bitmap-index" => use_bitmap = true
      "--no-use-bitmap-index" => ()
      "--no-object-names" => no_object_names = true
      "--not" => {
        // Next refs are excludes until another --not
        i += 1
        while i < args.length() {
          let next = args[i]
          if next == "--not" {
            break
          }
          if not(next.has_prefix("-")) {
            excludes.push(next)
          }
          i += 1
        }
        continue
      }
      _ if arg.has_prefix("--max-count=") => {
        let val = String::unsafe_substring(arg, start=12, end=arg.length())
        max_count = Some(
          @strconv.parse_int(val) catch {
            err if @async.is_cancellation_error(err) => raise err
            _ => 0
          },
        )
      }
      _ if arg.has_prefix("^") =>
        excludes.push(String::unsafe_substring(arg, start=1, end=arg.length()))
      _ if not(arg.has_prefix("-")) => refs.push(arg)
      _ if arg.has_prefix("-") => warn_unimplemented_arg("rev-list", arg)
      _ => ()
    }
    i += 1
  }
  // Read from stdin if requested
  if stdin {
    let input = decode_bytes(read_all_stdin())
    for line_view in input.split("\n") {
      let line = trim_string(line_view.to_string())
      if line.length() > 0 && not(line.has_prefix("#")) {
        if line.has_prefix("^") {
          excludes.push(
            String::unsafe_substring(line, start=1, end=line.length()),
          )
        } else {
          refs.push(line)
        }
      }
    }
  }
  // If --all, add all refs
  if all {
    let all_refs = @bitrepo.show_ref(fs, git_dir)
    for item in all_refs {
      let (name, _) = item
      refs.push(name)
    }
  }
  // If no refs specified, default to HEAD
  if refs.length() == 0 {
    refs.push("HEAD")
  }
  // Handle --test-bitmap
  if test_bitmap {
    rev_list_test_bitmap(fs, git_dir)
    return
  }
  // Resolve starting commits
  let start_ids : Array[@bitcore.ObjectId] = []
  for spec in refs {
    match @bitrepo.rev_parse(fs, git_dir, spec) {
      Some(id) => start_ids.push(id)
      None => ()
    }
  }
  // Resolve exclude commits
  let exclude_ids : Map[String, Bool] = {}
  for spec in excludes {
    match @bitrepo.rev_parse(fs, git_dir, spec) {
      Some(id) =>
        // Walk the exclude commit and all its ancestors
        walk_commits_to_map(fs, git_dir, id, exclude_ids)
      None => ()
    }
  }
  let db = @bitlib.ObjectDb::load(fs, git_dir)
  let visited : Map[String, Bool] = {}
  let result : Array[@bitcore.ObjectId] = []
  let object_ids : Array[(@bitcore.ObjectId, String)] = []
  let limit = max_count.unwrap_or(2147483647)
  // BFS/DFS traversal
  let queue : Array[@bitcore.ObjectId] = []
  for id in start_ids {
    queue.push(id)
  }
  while queue.length() > 0 && result.length() < limit {
    let id = queue.unsafe_pop()
    let hex = id.to_hex()
    if visited.contains(hex) || exclude_ids.contains(hex) {
      continue
    }
    visited[hex] = true
    result.push(id)
    if objects {
      object_ids.push((id, ""))
    }
    // Get commit and add parents
    match db.get(fs, id) {
      Some(obj) if obj.obj_type == @bitcore.ObjectType::Commit => {
        let info = @bitcore.parse_commit(obj.data)
        if objects {
          // Also collect tree objects
          collect_tree_objects(db, fs, info.tree, object_ids, visited)
        }
        if first_parent && info.parents.length() > 0 {
          if not(visited.contains(info.parents[0].to_hex())) {
            queue.push(info.parents[0])
          }
        } else {
          for parent in info.parents {
            if not(visited.contains(parent.to_hex())) {
              queue.push(parent)
            }
          }
        }
      }
      _ => ()
    }
  }
  // Apply reverse if requested
  if reverse {
    result.rev_in_place()
    if objects {
      object_ids.rev_in_place()
    }
  }
  // Output
  if count_only {
    print_line(result.length().to_string())
    return
  }
  if quiet {
    return
  }
  // Output commits
  for id in result {
    print_line(id.to_hex())
  }
  // Output objects (trees, blobs) if --objects
  if objects {
    let commit_set : Map[String, Bool] = {}
    for r in result {
      commit_set[r.to_hex()] = true
    }
    for item in object_ids {
      let (id, path) = item
      let hex = id.to_hex()
      if not(commit_set.contains(hex)) {
        if no_object_names || use_bitmap || path.length() == 0 {
          print_line(hex)
        } else {
          print_line(hex + " " + path)
        }
      }
    }
  }
}

///|
fn walk_commits_to_map(
  fs : OsFs,
  git_dir : String,
  start : @bitcore.ObjectId,
  out : Map[String, Bool],
) -> Unit {
  let db = @bitlib.ObjectDb::load(fs, git_dir) catch { _ => return () }
  let queue : Array[@bitcore.ObjectId] = [start]
  while queue.length() > 0 {
    let id = queue.unsafe_pop()
    let hex = id.to_hex()
    if out.contains(hex) {
      continue
    }
    out[hex] = true
    let obj = db.get(fs, id) catch { _ => continue }
    match obj {
      Some(o) if o.obj_type == @bitcore.ObjectType::Commit => {
        let info = @bitcore.parse_commit(o.data) catch { _ => continue }
        for parent in info.parents {
          if not(out.contains(parent.to_hex())) {
            queue.push(parent)
          }
        }
      }
      _ => ()
    }
  }
}

///|
fn collect_tree_objects(
  db : @bitlib.ObjectDb,
  fs : OsFs,
  tree_id : @bitcore.ObjectId,
  out : Array[(@bitcore.ObjectId, String)],
  visited : Map[String, Bool],
  parent_path~ : String = "",
) -> Unit {
  let hex = tree_id.to_hex()
  if visited.contains(hex) {
    return ()
  }
  visited[hex] = true
  out.push((tree_id, parent_path))
  let obj = db.get(fs, tree_id) catch { _ => return () }
  match obj {
    Some(o) if o.obj_type == @bitcore.ObjectType::Tree => {
      let entries = @bitcore.parse_tree(o.data) catch { _ => return () }
      for entry in entries {
        let entry_hex = entry.id.to_hex()
        if not(visited.contains(entry_hex)) {
          let entry_path = if parent_path.length() == 0 {
            entry.name
          } else {
            parent_path + "/" + entry.name
          }
          if entry.mode.has_prefix("40") {
            // Directory - recurse
            collect_tree_objects(
              db,
              fs,
              entry.id,
              out,
              visited,
              parent_path=entry_path,
            )
          } else {
            // File or other
            visited[entry_hex] = true
            out.push((entry.id, entry_path))
          }
        }
      }
    }
    _ => ()
  }
}

///|
async fn rev_list_test_bitmap(fs : OsFs, git_dir : String) -> Unit raise Error {
  let pack_dir = git_dir + "/objects/pack"
  // Find bitmap file: check chain first, then monolithic
  let chain_path = pack_dir + "/multi-pack-index.d/multi-pack-index-chain"
  let mut bitmap_data : Bytes? = None
  let mut midx_data : Bytes? = None
  if fs.is_file(chain_path) {
    // Use topmost layer from chain
    let chain_data = fs.read_file(chain_path) catch { _ => Bytes::new(0) }
    let text = midx_bytes_to_string(chain_data, 0, chain_data.length())
    let mut last_hash = ""
    for raw_line in text.split("\n") {
      let line = raw_line.to_string().trim().to_string()
      if line.length() > 0 {
        last_hash = line
      }
    }
    if last_hash.length() > 0 {
      let inc_dir = pack_dir + "/multi-pack-index.d"
      let bmp_path = inc_dir + "/multi-pack-index-" + last_hash + ".bitmap"
      let bmp_bytes = midx_try_read_file(fs, bmp_path)
      if bmp_bytes is Some(_) {
        bitmap_data = bmp_bytes
      }
      let midx_path = inc_dir + "/multi-pack-index-" + last_hash + ".midx"
      let md = midx_try_read_file(fs, midx_path)
      if md is Some(_) {
        midx_data = md
      }
    }
  }
  if bitmap_data is None {
    // Try monolithic
    let midx_path = pack_dir + "/multi-pack-index"
    let md = midx_try_read_file(fs, midx_path)
    match md {
      Some(md_bytes) =>
        if md_bytes.length() >= 20 {
          midx_data = Some(md_bytes)
          let checksum_hex = midx_checksum_hex(md_bytes)
          if checksum_hex.length() > 0 {
            let bmp_path = pack_dir +
              "/multi-pack-index-" +
              checksum_hex +
              ".bitmap"
            bitmap_data = midx_try_read_file(fs, bmp_path)
          }
        }
      None => ()
    }
  }
  guard bitmap_data is Some(bmp_bytes) else {
    eprint_line("error: could not find bitmap")
    @sys.exit(1)
    return
  }
  ignore(midx_data)
  // Emit GIT_TRACE2_EVENT for load_midx_revindex
  emit_revindex_trace(fs, "midx")
  // Parse bitmap header
  if bmp_bytes.length() < 32 {
    eprint_line("error: bitmap file too short")
    @sys.exit(1)
    return
  }
  if bmp_bytes[0] != b'B' ||
    bmp_bytes[1] != b'I' ||
    bmp_bytes[2] != b'T' ||
    bmp_bytes[3] != b'M' {
    eprint_line("error: invalid bitmap signature")
    @sys.exit(1)
    return
  }
  // Verify bitmap trailer checksum
  let bmp_body_len = bmp_bytes.length() - 20
  if bmp_body_len < 32 {
    eprint_line("error: bitmap too short for checksum")
    @sys.exit(1)
    return
  }
  let bmp_body = Bytes::from_array(
    FixedArray::makei(bmp_body_len, i => bmp_bytes[i]),
  )
  let bmp_computed = @bitcore.sha1(bmp_body)
  let mut bmp_checksum_ok = true
  for i in 0..<20 {
    if bmp_computed.bytes[i] != bmp_bytes[bmp_body_len + i] {
      bmp_checksum_ok = false
    }
  }
  if not(bmp_checksum_ok) {
    eprint_line("error: bitmap checksum mismatch")
    @sys.exit(1)
    return
  }
  let entry_count = midx_read_u32(bmp_bytes, 8)
  if entry_count <= 0 {
    eprint_line("error: bitmap has no entries")
    @sys.exit(1)
    return
  }
  // Validate bitmap structure: parse type bitmaps and per-commit entries
  let mut bmp_pos = 32
  let mut valid = true
  // Skip 4 type bitmaps
  for _ in 0..<4 {
    if bmp_pos + 8 > bmp_body_len {
      valid = false
      break
    }
    let word_count = midx_read_u32(bmp_bytes, bmp_pos + 4)
    if word_count < 0 {
      valid = false
      break
    }
    bmp_pos = bmp_pos + 4 + 4 + word_count * 8 + 4
  }
  if not(valid) {
    eprint_line("error: bitmap structure invalid")
    @sys.exit(1)
    return
  }
  // Parse per-commit bitmap entries
  for _ in 0..<entry_count {
    if bmp_pos + 6 > bmp_body_len {
      valid = false
      break
    }
    bmp_pos += 6
    if bmp_pos + 8 > bmp_body_len {
      valid = false
      break
    }
    let word_count = midx_read_u32(bmp_bytes, bmp_pos + 4)
    if word_count < 0 {
      valid = false
      break
    }
    bmp_pos = bmp_pos + 4 + 4 + word_count * 8 + 4
  }
  if valid {
    eprint_line("OK!")
  } else {
    eprint_line("mismatch in bitmap results")
    @sys.exit(1)
    return
  }
}

///|
fn emit_revindex_trace(fs : OsFs, kind : String) -> Unit {
  match @sys.get_env_var("GIT_TRACE2_EVENT") {
    Some(path) => {
      let target = path.trim().to_string()
      if target.length() == 0 || target == "1" || target == "2" {
        return
      }
      let existing = match midx_try_read_file(fs, target) {
        Some(data) => midx_bytes_to_string(data, 0, data.length())
        None => ""
      }
      let line = "{\"event\":\"data\",\"category\":\"load_midx_revindex\",\"key\":\"source\",\"value\":\"" +
        kind +
        "\"}"
      let next = if existing.length() == 0 {
        line + "\n"
      } else {
        existing + line + "\n"
      }
      fs.write_string(target, next) catch {
        _ => ()
      }
    }
    None => ()
  }
}

///|

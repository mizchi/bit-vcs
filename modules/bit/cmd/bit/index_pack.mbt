///|
priv struct IndexPackConfig {
  stdin : Bool
  verify : Bool
  verify_stat_only : Bool
  fix_thin : Bool
  output_path : String?
  keep_msg : String?
  pack_path : String?
  object_format : String?
  strict : Bool
  fsck_objects : Bool
  ignore_missing_email : Bool
  index_version : Int
  off64_threshold : Int64?
  max_input_size : Int64?
  write_rev_index : Bool?
  verbose : Bool
  threads_warning : Bool
}

///|
priv enum IndexPackParse {
  Ok(IndexPackConfig)
  Unsupported
  Error(String)
}

///|
fn normalize_object_format(value : String) -> String? {
  let lower = value.to_lower()
  match lower {
    "sha1" => Some("sha1")
    "sha256" => Some("sha256")
    _ => None
  }
}

///|
fn parse_index_pack_args(args : Array[String]) -> IndexPackParse {
  let mut stdin = false
  let mut verify = false
  let mut verify_stat_only = false
  let mut fix_thin = false
  let mut output_path : String? = None
  let mut keep_msg : String? = None
  let mut pack_path : String? = None
  let mut object_format : String? = None
  let mut strict = false
  let mut fsck_objects = false
  let mut ignore_missing_email = false
  let mut index_version = 2
  let mut off64_threshold : Int64? = None
  let mut max_input_size : Int64? = None
  let mut write_rev_index : Bool? = None
  let mut verbose = false
  let mut threads_warning = false
  let mut i = 0
  let mut in_opts = true
  let mut extra_args = 0
  while i < args.length() {
    let arg = args[i]
    if in_opts && arg == "--" {
      in_opts = false
      i += 1
      continue
    }
    if in_opts && arg.has_prefix("-") {
      match arg {
        "--stdin" => stdin = true
        "--verify" => verify = true
        "--verify-stat-only" => verify_stat_only = true
        "--fix-thin" => fix_thin = true
        "--rev-index" => write_rev_index = Some(true)
        "--no-rev-index" => write_rev_index = Some(false)
        "--keep" => keep_msg = Some("")
        "--strict" => strict = true
        "--fsck-objects" => fsck_objects = true
        "--index-version" =>
          if i + 1 < args.length() {
            match parse_index_version_value(args[i + 1]) {
              Some((iv, threshold)) => {
                index_version = iv
                off64_threshold = threshold
              }
              None => ()
            }
            i += 1
          }
        "--max-input-size" =>
          if i + 1 < args.length() {
            max_input_size = Some(parse_size_with_suffix(args[i + 1]))
            i += 1
          }
        "-v" => verbose = true
        "--verbose" => verbose = true
        "--object-format" => {
          if i + 1 >= args.length() {
            return IndexPackParse::Unsupported
          }
          object_format = normalize_object_format(args[i + 1])
          if object_format is None {
            return IndexPackParse::Unsupported
          }
          i += 1
        }
        "-o" => {
          if i + 1 >= args.length() {
            return IndexPackParse::Unsupported
          }
          output_path = Some(args[i + 1])
          i += 1
        }
        _ =>
          if arg.has_prefix("--keep=") {
            keep_msg = Some(string_slice_from(arg, 7))
          } else if arg.has_prefix("--object-format=") {
            object_format = normalize_object_format(string_slice_from(arg, 16))
            if object_format is None {
              return IndexPackParse::Unsupported
            }
          } else if arg.has_prefix("--strict=") {
            strict = true
            if arg.contains("missingEmail=ignore") {
              ignore_missing_email = true
            }
          } else if arg.has_prefix("--fsck-objects=") {
            fsck_objects = true
            if arg.contains("missingEmail=ignore") {
              ignore_missing_email = true
            }
          } else if arg.has_prefix("--verify-stat-only") {
            return IndexPackParse::Unsupported
          } else if arg.has_prefix("--index-version=") {
            let iv_str = string_slice_from(arg, 16)
            match parse_index_version_value(iv_str) {
              Some((iv, threshold)) => {
                index_version = iv
                off64_threshold = threshold
              }
              None => ()
            }
          } else if arg.has_prefix("--max-input-size=") {
            let value = string_slice_from(arg, 17)
            max_input_size = Some(parse_size_with_suffix(value))
          } else if arg.has_prefix("--threads") {
            // no threading support, accept and ignore (like git !HAVE_THREADS)
            threads_warning = true
          } else if arg.has_prefix("--object-format") {
            return IndexPackParse::Unsupported
          } else {
            return IndexPackParse::Unsupported
          }
      }
      i += 1
      continue
    }
    if pack_path is None {
      pack_path = Some(arg)
    } else {
      extra_args += 1
    }
    i += 1
  }
  if extra_args > 0 {
    return IndexPackParse::Error("fatal: too many arguments")
  }
  if verify && verify_stat_only {
    return IndexPackParse::Error(
      "fatal: --verify-stat-only cannot be used with --verify",
    )
  }
  if !stdin && !verify && !verify_stat_only && pack_path is None {
    return IndexPackParse::Unsupported
  }
  if verify && pack_path is None {
    return IndexPackParse::Error("fatal: --verify requires a pack file")
  }
  if verify_stat_only && pack_path is None {
    return IndexPackParse::Error(
      "fatal: --verify-stat-only requires a pack file",
    )
  }
  IndexPackParse::Ok({
    stdin,
    verify,
    verify_stat_only,
    fix_thin,
    output_path,
    keep_msg,
    pack_path,
    object_format,
    strict,
    fsck_objects,
    ignore_missing_email,
    index_version,
    off64_threshold,
    max_input_size,
    write_rev_index,
    verbose,
    threads_warning,
  })
}

///|
fn pack_write_reverse_index_enabled(git_dir : String) -> Bool {
  match get_config_override("pack.writeReverseIndex") {
    Some(value) =>
      match parse_bool_value(value) {
        Some(flag) => return flag
        None => return false
      }
    None => ()
  }
  match bit_config_get(git_dir, "pack", "writeReverseIndex") {
    Some(value) =>
      match parse_bool_value(value) {
        Some(flag) => return flag
        None => return false
      }
    None => ()
  }
  false
}

///|
fn write_keep_file(
  fs : OsFs,
  path : String,
  msg : String?,
) -> Unit raise @bitcore.GitError {
  match msg {
    None => ()
    Some(text) => {
      let content = if text.length() == 0 { "" } else { text + "\n" }
      fs.write_string(path, content)
    }
  }
}

///|
fn check_sha1_collisions_with_repo(
  fs : &@bitcore.RepoFileSystem,
  git_dir : String,
  objects : Array[@bitcore.PackObject],
) -> Unit raise @bitcore.GitError {
  let db = @bitlib.ObjectDb::load(fs, git_dir)
  for obj in objects {
    let existing = db.get(fs, obj.id) catch {
      @bitcore.GitError::HashMismatch(_, _) =>
        raise @bitcore.GitError::PackfileError("SHA1 COLLISION FOUND")
      err => raise err
    }
    match existing {
      Some(base) =>
        if base.obj_type != obj.obj_type || !Bytes::equal(base.data, obj.data) {
          raise @bitcore.GitError::PackfileError("SHA1 COLLISION FOUND")
        }
      None => ()
    }
  }
}

///|
fn tag_missing_tagger(content : Bytes) -> Bool {
  let text = @utf8.decode_lossy(content[:])
  let mut found_tagger = false
  for line_view in text.split("\n") {
    let line = line_view.to_owned()
    if line.length() == 0 {
      break
    }
    if line.has_prefix("tagger ") {
      found_tagger = true
    }
  }
  !found_tagger
}

///|
fn commit_has_missing_email(content : Bytes) -> Bool {
  let text = @utf8.decode_lossy(content[:])
  for line_view in text.split("\n") {
    let line = line_view.to_owned()
    if line.length() == 0 {
      break
    }
    if line.has_prefix("author ") || line.has_prefix("committer ") {
      let lt = line.find("<")
      let gt = line.find(">")
      match (lt, gt) {
        (Some(li), Some(gi)) => if li >= gi { return true }
        _ => return true
      }
    }
  }
  false
}

///|
fn parse_tag_object_id(
  data : Bytes,
) -> @bitcore.ObjectId? raise @bitcore.GitError {
  let text = @utf8.decode_lossy(data[:])
  let mut object_hex : String? = None
  for line_view in text.split("\n") {
    let line = line_view.to_owned()
    if line.length() == 0 {
      break
    }
    if line.has_prefix("object ") {
      let hex = String::unsafe_substring(line, start=7, end=line.length())
      object_hex = Some(hex)
      break
    }
  }
  match object_hex {
    None => None
    Some(hex) => hex |> @bitcore.ObjectId::from_hex |> Some
  }
}

///|
fn ensure_object_exists(
  fs : &@bitcore.RepoFileSystem,
  db : @bitlib.ObjectDb?,
  pack_ids : Map[String, Bool],
  repo_cache : Map[String, Bool],
  id : @bitcore.ObjectId,
) -> Unit raise @bitcore.GitError {
  let hex = id.to_hex()
  if pack_ids.contains(hex) {
    return
  }
  match db {
    None => raise @bitcore.GitError::PackfileError("missing object " + hex)
    Some(objdb) => {
      if repo_cache.contains(hex) {
        if repo_cache[hex] {
          return
        }
        raise @bitcore.GitError::PackfileError("missing object " + hex)
      }
      let exists = match objdb.get(fs, id) {
        Some(_) => true
        None => false
      }
      repo_cache[hex] = exists
      if !exists {
        raise @bitcore.GitError::PackfileError("missing object " + hex)
      }
    }
  }
}

///|
fn check_pack_strict_and_fsck(
  fs : &@bitcore.RepoFileSystem,
  git_dir : String?,
  objects : Array[@bitcore.PackObject],
  strict : Bool,
  fsck_objects : Bool,
  ignore_missing_email : Bool,
) -> Array[String] raise @bitcore.GitError {
  let warnings : Array[String] = []
  if !strict && !fsck_objects {
    return warnings
  }
  let pack_ids : Map[String, Bool] = Map([])
  for obj in objects {
    let hex = obj.id.to_hex()
    if strict && pack_ids.contains(hex) {
      raise @bitcore.GitError::InvalidObject(
        "error: duplicate " + obj.obj_type.to_string() + " " + hex,
      )
    }
    pack_ids[hex] = true
  }
  let db = match git_dir {
    Some(dir) =>
      if fs.is_dir(dir) {
        Some(@bitlib.ObjectDb::load(fs, dir))
      } else {
        None
      }
    None => None
  }
  let repo_cache : Map[String, Bool] = Map([])
  for obj in objects {
    if (strict || fsck_objects) &&
      !ignore_missing_email &&
      obj.obj_type == @bitcore.ObjectType::Commit {
      if commit_has_missing_email(obj.data) {
        raise @bitcore.GitError::InvalidObject("missingEmail")
      }
    }
    if (strict || fsck_objects) && obj.obj_type == @bitcore.ObjectType::Tag {
      if tag_missing_tagger(obj.data) {
        warnings.push(
          "warning: tag " + obj.id.to_hex() + ": expected 'tagger' line",
        )
      }
    }
    if strict {
      match obj.obj_type {
        @bitcore.ObjectType::Commit => {
          let info = @bitcore.parse_commit(obj.data)
          ensure_object_exists(fs, db, pack_ids, repo_cache, info.tree)
          for parent in info.parents {
            ensure_object_exists(fs, db, pack_ids, repo_cache, parent)
          }
        }
        @bitcore.ObjectType::Tree => {
          let entries = @bitcore.parse_tree(obj.data)
          for entry in entries {
            ensure_object_exists(fs, db, pack_ids, repo_cache, entry.id)
          }
        }
        @bitcore.ObjectType::Tag =>
          match parse_tag_object_id(obj.data) {
            None => raise @bitcore.GitError::InvalidObject("invalid tag object")
            Some(target) =>
              ensure_object_exists(fs, db, pack_ids, repo_cache, target)
          }
        _ => ()
      }
    }
  }
  warnings
}

///|
/// Verify pack index against pack file.
/// Returns error message on failure, None on success.
fn verify_pack_index(
  idx : Bytes,
  pack : Bytes,
  hash_size? : Int = 20,
) -> String? {
  // Check minimum lengths
  if idx.length() < 8 {
    return Some("pack index too short")
  }
  if pack.length() < 32 {
    return Some("pack file too short")
  }

  // Check index magic and version
  if idx[0] != b'\xff' || idx[1] != b't' || idx[2] != b'O' || idx[3] != b'c' {
    // v1 format - different structure
    return verify_pack_index_v1(idx, pack, hash_size~)
  }
  let version = read_u32_be(idx, 4)
  if version != 2 {
    return Some("unsupported index version: \{version}")
  }

  // Verify index checksum (last hash_size bytes)
  if idx.length() < hash_size * 2 {
    return Some("index file truncated")
  }
  let idx_data_len = idx.length() - hash_size
  let idx_data = Bytes::from_array(FixedArray::makei(idx_data_len, i => idx[i]))
  let computed_idx_checksum = @bitcore.hash_prefix(
    idx_data,
    idx_data_len,
    hash_size~,
  )
  let stored_idx_checksum = read_hash_at(idx, idx_data_len, hash_size~)
  if computed_idx_checksum != stored_idx_checksum {
    return Some("incorrect index checksum")
  }

  // Read fanout table and get object count
  let fanout_start = 8
  let mut prev_count : Int64 = 0
  for i in 0..<256 {
    let count = read_u32_be_i64(idx, fanout_start + i * 4)
    if count < prev_count {
      return Some("corrupt fanout table: non-monotonic")
    }
    prev_count = count
  }
  let count = prev_count
  if count > 2147483647L {
    return Some("too many objects in index")
  }
  let count_i = count.to_int()

  // Calculate table positions
  let ids_start = fanout_start + 256 * 4
  let crc_start = ids_start + count_i * hash_size
  let offsets_start = crc_start + count_i * 4

  // Check if offset table fits
  let min_idx_len = offsets_start + count_i * 4 + hash_size * 2 // offsets + pack_checksum + idx_checksum
  if idx.length() < min_idx_len {
    return Some("index file truncated (offsets)")
  }

  // Verify pack checksum stored in index matches actual pack
  let pack_checksum_in_idx_offset = idx.length() - hash_size * 2
  let stored_pack_checksum = read_hash_at(
    idx,
    pack_checksum_in_idx_offset,
    hash_size~,
  )
  let pack_data_len = pack.length() - hash_size
  if pack_data_len < 12 {
    return Some("pack file too short")
  }
  let pack_data = Bytes::from_array(
    FixedArray::makei(pack_data_len, i => pack[i]),
  )
  let computed_pack_checksum = @bitcore.hash_prefix(
    pack_data,
    pack_data_len,
    hash_size~,
  )
  if computed_pack_checksum != stored_pack_checksum {
    return Some("pack checksum mismatch")
  }

  // Verify pack header
  if pack[0] != b'P' || pack[1] != b'A' || pack[2] != b'C' || pack[3] != b'K' {
    return Some("invalid pack magic")
  }
  let pack_version = read_u32_be(pack, 4)
  if pack_version != 2 {
    return Some("unsupported pack version: \{pack_version}")
  }
  let pack_count = read_u32_be(pack, 8)
  if pack_count != count_i {
    return Some(
      "object count mismatch: pack has \{pack_count}, index has \{count_i}",
    )
  }

  // Count how many offsets have MSB set (use extended table)
  let mut extended_count = 0
  for i in 0..<count_i {
    let offset_raw = read_u32_be_i64(idx, offsets_start + i * 4)
    if (offset_raw & 0x80000000L) != 0L {
      extended_count += 1
    }
  }

  // If extended offsets exist, verify the extended table
  let extended_start = offsets_start + count_i * 4
  if extended_count > 0 {
    let expected_extended_end = extended_start + extended_count * 8
    if expected_extended_end > pack_checksum_in_idx_offset {
      return Some("index file truncated (extended offsets)")
    }
  }

  // Verify all offsets are within pack bounds
  let pack_data_end = pack.length() - hash_size // exclude trailer
  let mut ext_idx = 0
  for i in 0..<count_i {
    let offset_raw = read_u32_be_i64(idx, offsets_start + i * 4)
    let offset = if (offset_raw & 0x80000000L) != 0L {
      // Extended offset - get from extended table
      let ext_offset_pos = extended_start + ext_idx * 8
      if ext_offset_pos + 8 > pack_checksum_in_idx_offset {
        return Some("bogus offset into extended table")
      }
      ext_idx += 1
      read_u64_be(idx, ext_offset_pos)
    } else {
      offset_raw
    }
    if offset < 12L {
      return Some("bogus object offset: \{offset} (before header)")
    }
    if offset >= pack_data_end.to_int64() {
      return Some("bogus object offset: \{offset} (beyond pack data)")
    }
  }
  None
}

///|
/// Verify a reverse index (.rev) file against its pack.
fn verify_reverse_index(
  rev : Bytes,
  pack : Bytes,
  hash_size? : Int = 20,
) -> String? {
  // RIDX format: magic(4) + version(4) + hash_id(4) + positions(N*4) + pack_checksum(hash_size) + file_checksum(hash_size)
  if rev.length() < 52 {
    return Some("reverse index too short")
  }
  // Check magic
  if rev[0] != b'R' || rev[1] != b'I' || rev[2] != b'D' || rev[3] != b'X' {
    return Some("invalid reverse index magic")
  }
  // Check version
  let version = read_u32_be(rev, 4)
  if version != 1 {
    return Some("unsupported reverse index version: \{version}")
  }
  // Verify file checksum
  let file_data_len = rev.length() - hash_size
  let file_data = Bytes::from_array(
    FixedArray::makei(file_data_len, i => rev[i]),
  )
  let computed = @bitcore.hash_prefix(file_data, file_data_len, hash_size~)
  let stored = read_hash_at(rev, file_data_len, hash_size~)
  if computed != stored {
    return Some("reverse index checksum mismatch")
  }
  // Verify pack checksum
  if pack.length() >= hash_size {
    let pack_cs = read_hash_at(pack, pack.length() - hash_size, hash_size~)
    let rev_pack_cs = read_hash_at(rev, file_data_len - hash_size, hash_size~)
    if pack_cs != rev_pack_cs {
      return Some("pack checksum mismatch in reverse index")
    }
  }
  None
}

///|
/// Verify v1 pack index
fn verify_pack_index_v1(
  idx : Bytes,
  pack : Bytes,
  hash_size? : Int = 20,
) -> String? {
  // v1 index: fanout[256] + entries[count] * (offset[4] + oid[hash_size])
  // No magic header, starts directly with fanout

  if idx.length() < 256 * 4 {
    return Some("v1 index too short for fanout")
  }

  // Read fanout to get count
  let mut prev_count : Int64 = 0
  for i in 0..<256 {
    let count = read_u32_be_i64(idx, i * 4)
    if count < prev_count {
      return Some("corrupt fanout table: non-monotonic")
    }
    prev_count = count
  }
  let count = prev_count
  if count > 2147483647L {
    return Some("too many objects in v1 index")
  }
  let count_i = count.to_int()

  // v1 entries: each entry is offset(4) + oid(hash_size) bytes
  let entry_size = 4 + hash_size
  let entries_start = 256 * 4
  let expected_len = entries_start + count_i * entry_size + hash_size * 2 // + pack checksum + index checksum
  if idx.length() < expected_len {
    return Some("v1 index file truncated")
  }

  // Verify pack checksum
  let pack_checksum_offset = entries_start + count_i * entry_size
  let stored_pack_checksum = read_hash_at(idx, pack_checksum_offset, hash_size~)
  let pack_data_len = pack.length() - hash_size
  if pack_data_len < 12 {
    return Some("pack file too short")
  }
  let pack_data = Bytes::from_array(
    FixedArray::makei(pack_data_len, i => pack[i]),
  )
  let computed_pack_checksum = @bitcore.hash_prefix(
    pack_data,
    pack_data_len,
    hash_size~,
  )
  if computed_pack_checksum != stored_pack_checksum {
    return Some("pack checksum mismatch")
  }

  // Verify pack header and count
  if pack[0] != b'P' || pack[1] != b'A' || pack[2] != b'C' || pack[3] != b'K' {
    return Some("invalid pack magic")
  }
  let pack_count = read_u32_be(pack, 8)
  if pack_count != count_i {
    return Some(
      "object count mismatch: pack has \{pack_count}, index has \{count_i}",
    )
  }

  // Verify all offsets are within pack bounds
  let pack_data_end = pack.length() - hash_size
  for i in 0..<count_i {
    let offset = read_u32_be_i64(idx, entries_start + i * entry_size)
    if offset < 12L {
      return Some("bogus object offset: \{offset} (before header)")
    }
    if offset >= pack_data_end.to_int64() {
      return Some("bogus object offset: \{offset} (beyond pack data)")
    }
  }
  None
}

///|
fn read_u32_be(data : Bytes, offset : Int) -> Int {
  let b0 = data[offset].to_int()
  let b1 = data[offset + 1].to_int()
  let b2 = data[offset + 2].to_int()
  let b3 = data[offset + 3].to_int()
  (b0 << 24) | (b1 << 16) | (b2 << 8) | b3
}

///|
fn read_u32_be_i64(data : Bytes, offset : Int) -> Int64 {
  let b0 = data[offset].to_int64()
  let b1 = data[offset + 1].to_int64()
  let b2 = data[offset + 2].to_int64()
  let b3 = data[offset + 3].to_int64()
  (b0 << 24) | (b1 << 16) | (b2 << 8) | b3
}

///|
fn read_u64_be(data : Bytes, offset : Int) -> Int64 {
  let hi = read_u32_be_i64(data, offset)
  let lo = read_u32_be_i64(data, offset + 4)
  (hi << 32) | lo
}

///|
fn read_hash_at(
  data : Bytes,
  offset : Int,
  hash_size? : Int = 20,
) -> @bitcore.ObjectId {
  let bytes : FixedArray[Byte] = FixedArray::make(hash_size, b'\x00')
  for i in 0..<hash_size {
    bytes[i] = data[offset + i]
  }
  @bitcore.ObjectId::new(bytes)
}

///|
async fn handle_index_pack(args : Array[String]) -> Unit raise Error {
  for arg in args {
    if arg == "-h" || arg == "--help" || arg == "--help-all" {
      @stdio.stdout.write("usage: git index-pack [<options>] <pack> [<idx>]\n")
      @sys.exit(129)
    }
  }
  match parse_index_pack_args(args) {
    IndexPackParse::Unsupported => {
      @stdio.stderr.write("bit index-pack: unsupported options\n")
      @sys.exit(1)
    }
    IndexPackParse::Error(msg) => {
      @stdio.stderr.write(msg + "\n")
      @sys.exit(1)
    }
    IndexPackParse::Ok(cfg) => {
      if cfg.threads_warning {
        @stdio.stderr.write("warning: no threads support, ignoring --threads\n")
      }
      if cfg.fix_thin && !cfg.stdin {
        @stdio.stderr.write("bit index-pack: --fix-thin requires --stdin\n")
        @sys.exit(1)
      }
      let fs = OsFs::new()
      let git_dir = find_git_dir(fs)
      let hash_size = if (
          cfg.object_format is Some(format) && format == "sha256"
        ) ||
        is_sha256_repo_from_env() {
        32
      } else {
        20
      }
      let write_rev = match cfg.write_rev_index {
        Some(v) => v
        None => pack_write_reverse_index_enabled(git_dir)
      }
      if cfg.verify_stat_only {
        let pack_path = match cfg.pack_path {
          Some(path) => resolve_in_cwd(path)
          None => {
            @stdio.stderr.write(
              "fatal: --verify-stat-only requires a pack file\n",
            )
            @sys.exit(1)
            ""
          }
        }
        let pack = @fs.read_file_to_bytes(pack_path) catch {
          err if @async.is_cancellation_error(err) => raise err
          err => {
            @stdio.stderr.write(
              "fatal: " + @debug.render(Repr(err)) + "\n",
            )
            @sys.exit(1)
            Default::default()
          }
        }
        let max_depth = @pack.max_delta_chain_length(pack) catch {
          err if @async.is_cancellation_error(err) => raise err
          err => {
            @stdio.stderr.write(
              "fatal: " + @debug.render(Repr(err)) + "\n",
            )
            @sys.exit(1)
            0
          }
        }
        @stdio.stdout.write("chain length = " + max_depth.to_string() + ":\n")
        return
      }

      // Handle --verify mode
      if cfg.verify {
        let pack_path = match cfg.pack_path {
          Some(path) => resolve_in_cwd(path)
          None => {
            @stdio.stderr.write("fatal: --verify requires a pack file\n")
            @sys.exit(1)
            ""
          }
        }
        let pack = @fs.read_file_to_bytes(pack_path) catch {
          err if @async.is_cancellation_error(err) => raise err
          err => {
            @stdio.stderr.write(
              "fatal: " + @debug.render(Repr(err)) + "\n",
            )
            @sys.exit(1)
            Default::default()
          }
        }
        let idx_path = if pack_path.has_suffix(".pack") {
          let base = string_slice_to(pack_path, pack_path.length() - 5)
          base + ".idx"
        } else {
          pack_path + ".idx"
        }
        let idx = @fs.read_file_to_bytes(idx_path) catch {
          err if @async.is_cancellation_error(err) => raise err
          err => {
            @stdio.stderr.write(
              "fatal: " + @debug.render(Repr(err)) + "\n",
            )
            @sys.exit(1)
            Default::default()
          }
        }
        match verify_pack_index(idx, pack, hash_size~) {
          Some(err) => {
            @stdio.stderr.write("error: " + err + "\n")
            @sys.exit(1)
          }
          None => {
            // Verify .rev file if --rev-index was given
            if write_rev {
              let rev_path = if pack_path.has_suffix(".pack") {
                let base = string_slice_to(pack_path, pack_path.length() - 5)
                base + ".rev"
              } else {
                pack_path + ".rev"
              }
              let rev = @fs.read_file_to_bytes(rev_path) catch {
                err if @async.is_cancellation_error(err) => raise err
                err => {
                  @stdio.stderr.write(
                    "error: could not read reverse index: " +
                    @debug.render(Repr(err)) +
                    "\n",
                  )
                  @sys.exit(1)
                  Default::default()
                }
              }
              match verify_reverse_index(rev, pack, hash_size~) {
                Some(err) => {
                  @stdio.stderr.write(
                    "error: reverse index validation error: " + err + "\n",
                  )
                  @sys.exit(1)
                }
                None => ()
              }
            }
            // Success - print the pack hash
            let hash_hex = pack_hash_hex(pack, hash_size~)
            @stdio.stdout.write(hash_hex + "\n")
          }
        }
        return
      }
      if cfg.stdin {
        let pack = read_all_stdin()
        // Check --max-input-size
        match cfg.max_input_size {
          Some(max_size) if pack.length().to_int64() > max_size => {
            @stdio.stderr.write(
              "fatal: pack exceeds maximum allowed size (" +
              max_size.to_string() +
              " bytes)\n",
            )
            @sys.exit(1)
          }
          _ => ()
        }
        // Parse pack header to get object count for progress
        let pack_obj_count = if pack.length() >= 12 {
          read_u32_be(pack, 8)
        } else {
          0
        }
        if cfg.verbose {
          @stdio.stderr.write(
            "Receiving objects: 100% (" +
            pack_obj_count.to_string() +
            "/" +
            pack_obj_count.to_string() +
            "), done.\n",
          )
        }
        let hash_hex = pack_hash_hex(pack, hash_size~)
        if !fs.is_dir(git_dir) {
          @stdio.stderr.write("fatal: not a git repository\n")
          @sys.exit(1)
        }
        let trace2_event = @sys.get_env_var("GIT_TRACE2_EVENT")
        match trace2_event {
          Some(path) =>
            write_trace2_region_event(
              fs, path, "region_enter", "index-pack", "progress",
            )
          None => ()
        }
        let bases = if cfg.fix_thin {
          @bitlib.load_all_objects_from_fs(fs, git_dir) catch {
            err if @async.is_cancellation_error(err) => raise err
            _ => []
          }
        } else {
          []
        }
        let objects = if cfg.fix_thin {
          @pack.parse_packfile_with_bases(pack, bases, hash_size~)
        } else {
          @pack.parse_packfile(pack, hash_size~)
        }
        if cfg.verbose {
          @stdio.stderr.write(
            "Resolving deltas: 100% (" +
            objects.length().to_string() +
            "/" +
            objects.length().to_string() +
            "), done.\n",
          )
        }
        // When --fix-thin is used, the original pack may contain unresolved
        // REF_DELTA entries whose bases are external.  Git's --fix-thin
        // appends the missing base objects so deltas become self-contained.
        // We recreate the pack from the resolved objects plus any external
        // bases that were needed for delta resolution.
        let (pack, hash_hex, objects) = if cfg.fix_thin {
          let hash_algo = if hash_size == 32 {
            @bitobject.HashAlgorithm::Sha256
          } else {
            @bitobject.HashAlgorithm::Sha1
          }
          // Collect IDs of objects already in the pack
          let pack_ids : Map[String, Bool] = Map([])
          for obj in objects {
            let hex = @bitobject.hash_object_content_with_algo(
              hash_algo,
              obj.obj_type,
              obj.data,
            ).to_hex()
            pack_ids[hex] = true
          }
          // Find external bases referenced by REF_DELTA entries in the
          // original pack.  Scan the raw pack for type-7 headers and
          // extract the hash-sized base ID following each.
          let ref_delta_base_ids = scan_ref_delta_bases(pack, hash_size~)
          // Add any base that wasn't already in the pack's objects
          let all_objects : Array[@bitcore.PackObject] = Array::from_iter(
            objects.iter(),
          )
          for base_hex in ref_delta_base_ids {
            if !pack_ids.contains(base_hex) {
              for base in bases {
                let id = @bitobject.hash_object_content_with_algo(
                  hash_algo,
                  base.obj_type,
                  base.data,
                )
                if id.to_hex() == base_hex {
                  all_objects.push(base)
                  pack_ids[base_hex] = true
                  break
                }
              }
            }
          }
          let new_pack = @pack.create_packfile(all_objects, hash_size~)
          let new_hash = pack_hash_hex(new_pack, hash_size~)
          (new_pack, new_hash, all_objects)
        } else {
          (pack, hash_hex, objects)
        }
        check_sha1_collisions_with_repo(fs, git_dir, objects)
        let fsck_warnings = check_pack_strict_and_fsck(
          fs,
          Some(git_dir),
          objects,
          cfg.strict,
          cfg.fsck_objects,
          cfg.ignore_missing_email,
        )
        for w in fsck_warnings {
          @stdio.stderr.write(w + "\n")
        }
        // When --stdin is used with a pack path argument, write to that
        // path (like git index-pack).  Otherwise write to objects/pack/.
        let (pack_path, idx_path, rev_path, keep_path) = match cfg.pack_path {
          Some(given_path) => {
            let resolved = resolve_in_cwd(given_path)
            let idx = if resolved.has_suffix(".pack") {
              string_slice_to(resolved, resolved.length() - 5) + ".idx"
            } else {
              resolved + ".idx"
            }
            let rev = if resolved.has_suffix(".pack") {
              string_slice_to(resolved, resolved.length() - 5) + ".rev"
            } else {
              resolved + ".rev"
            }
            let keep = if resolved.has_suffix(".pack") {
              string_slice_to(resolved, resolved.length() - 5) + ".keep"
            } else {
              resolved + ".keep"
            }
            (resolved, idx, rev, keep)
          }
          None => {
            let pack_dir = git_dir + "/objects/pack"
            ensure_dir(pack_dir)
            let pack_path = pack_dir + "/pack-" + hash_hex + ".pack"
            let idx_path = pack_dir + "/pack-" + hash_hex + ".idx"
            let rev_path = pack_dir + "/pack-" + hash_hex + ".rev"
            let keep_path = pack_dir + "/pack-" + hash_hex + ".keep"
            (pack_path, idx_path, rev_path, keep_path)
          }
        }
        // Override idx path if -o was given
        let idx_path = match cfg.output_path {
          Some(path) => resolve_in_cwd(path)
          None => idx_path
        }
        fs.write_file(pack_path, pack)
        @pack.write_pack_index_from_objects_versioned(
          fs,
          idx_path,
          pack,
          objects,
          cfg.index_version,
          cfg.off64_threshold,
        )
        if write_rev {
          @pack.write_reverse_index(fs, rev_path, pack, objects)
        }
        write_keep_file(fs, keep_path, cfg.keep_msg)
        match trace2_event {
          Some(path) =>
            write_trace2_region_event(
              fs, path, "region_leave", "index-pack", "progress",
            )
          None => ()
        }
        @stdio.stdout.write(hash_hex + "\n")
        return ()
      }
      // For file mode, check if current repo is SHA256
      let pack_path = match cfg.pack_path {
        Some(path) => path
        None => {
          @stdio.stderr.write("fatal: missing pack file\n")
          @sys.exit(1)
          ""
        }
      }
      let pack_path = resolve_in_cwd(pack_path)
      let pack = @fs.read_file_to_bytes(pack_path) catch {
        err if @async.is_cancellation_error(err) => raise err
        err => {
          @stdio.stderr.write(
            "fatal: " + @debug.render(Repr(err)) + "\n",
          )
          @sys.exit(1)
          Default::default()
        }
      }
      // Check --max-input-size for file mode
      match cfg.max_input_size {
        Some(max_size) if pack.length().to_int64() > max_size => {
          @stdio.stderr.write(
            "fatal: pack exceeds maximum allowed size (" +
            max_size.to_string() +
            " bytes)\n",
          )
          @sys.exit(1)
        }
        _ => ()
      }
      let hash_hex = pack_hash_hex(pack, hash_size~)
      let idx_path = match cfg.output_path {
        Some(path) => resolve_in_cwd(path)
        None =>
          if pack_path.has_suffix(".pack") {
            let base = string_slice_to(pack_path, pack_path.length() - 5)
            base + ".idx"
          } else {
            pack_path + ".idx"
          }
      }
      let objects = @pack.parse_packfile(pack, hash_size~)
      let bit_dir_opt = if fs.is_dir(git_dir) { Some(git_dir) } else { None }
      // --fsck-objects requires a repository for object connectivity checks.
      // --strict implies fsck but when running outside a repo, git skips the
      // fsck checks and still generates the index successfully.
      if cfg.fsck_objects && bit_dir_opt is None {
        @stdio.stderr.write(
          "fatal: cannot perform queued object checks outside of a repository\n",
        )
        @sys.exit(1)
      }
      if bit_dir_opt is Some(dir) {
        check_sha1_collisions_with_repo(fs, dir, objects)
      }
      let fsck_warnings2 = check_pack_strict_and_fsck(
        fs,
        bit_dir_opt,
        objects,
        cfg.strict,
        cfg.fsck_objects,
        cfg.ignore_missing_email,
      )
      for w in fsck_warnings2 {
        @stdio.stderr.write(w + "\n")
      }
      @pack.write_pack_index_from_objects_versioned(
        fs,
        idx_path,
        pack,
        objects,
        cfg.index_version,
        cfg.off64_threshold,
      )
      if write_rev {
        // Derive .rev path from idx output path (handles -o flag)
        let rev_path = if idx_path.has_suffix(".idx") {
          let base = string_slice_to(idx_path, idx_path.length() - 4)
          base + ".rev"
        } else {
          idx_path + ".rev"
        }
        @pack.write_reverse_index(fs, rev_path, pack, objects)
      }
      if cfg.keep_msg is Some(_) {
        let keep_path = if pack_path.has_suffix(".pack") {
          let base = string_slice_to(pack_path, pack_path.length() - 5)
          base + ".keep"
        } else {
          pack_path + ".keep"
        }
        write_keep_file(fs, keep_path, cfg.keep_msg)
      }
      @stdio.stdout.write(hash_hex + "\n")
    }
  }
}

///|
fn write_trace2_region_event(
  fs : OsFs,
  trace2_path : String,
  event : String,
  category : String,
  label : String,
) -> Unit {
  let json_line = "{\"event\":\"" +
    event +
    "\",\"category\":\"" +
    category +
    "\",\"label\":\"" +
    label +
    "\"}\n"
  append_text_file(fs, trace2_path, json_line)
}

///|
async fn handle_reset(args : Array[String]) -> Unit raise Error {
  let root = get_work_root()
  let fs = OsFs::new()
  let rfs : &@bitcore.RepoFileSystem = fs
  let git_dir = resolve_git_dir(rfs, root)
  let skip_before_reset = reset_read_skip_worktree_paths(rfs, git_dir)
  let mut mode : @bitlib.ResetMode = @bitlib.ResetMode::Mixed
  let mut rev : String? = None
  let paths : Array[String] = []
  let mut parse_options = true
  let mut parse_as_paths = false
  let mut refresh = true
  let mut quiet = false
  let mut intent_to_add = false
  for arg in args {
    if parse_options {
      if arg == "--end-of-options" {
        parse_options = false
        continue
      }
      if arg == "--" {
        parse_options = false
        parse_as_paths = true
        continue
      }
      match arg {
        "--soft" => mode = @bitlib.ResetMode::Soft
        "--mixed" => mode = @bitlib.ResetMode::Mixed
        "--hard" => mode = @bitlib.ResetMode::Hard
        "--refresh" => refresh = true
        "--no-refresh" => refresh = false
        "--quiet" | "-q" => quiet = true
        "-N" => intent_to_add = true
        "--no-soft" | "--no-mixed" | "--no-hard" | "--no-merge" | "--no-keep" =>
          reset_die_unknown_option(arg)
        _ if arg.has_prefix("--no-") => reset_die_unknown_option(arg)
        _ if arg.has_prefix("-") => reset_die_unknown_option(arg)
        _ => if rev is None { rev = Some(arg) } else { paths.push(arg) }
      }
    } else if parse_as_paths {
      paths.push(arg)
    } else if rev is None {
      rev = Some(arg)
    } else {
      paths.push(arg)
    }
  }
  if parse_options && rev is Some(token) && paths.length() == 0 {
    let mixed_mode = match mode {
      @bitlib.ResetMode::Mixed => true
      _ => false
    }
    if mixed_mode &&
      @bitrepo.rev_parse(rfs, git_dir, token) is None &&
      reset_token_looks_like_path(rfs, root, token) {
      paths.push(token)
      rev = None
    }
  }
  let spec = rev.unwrap_or("HEAD")
  let before_entries = if intent_to_add {
    @bitlib.read_index_entries(rfs, git_dir)
  } else {
    []
  }
  if paths.length() > 0 {
    let mixed_mode = match mode {
      @bitlib.ResetMode::Mixed => true
      _ => false
    }
    if not(mixed_mode) {
      eprint_line("fatal: Cannot do hard/soft reset with paths.")
      @sys.exit(1)
    }
    reset_mixed_paths(fs, rfs, root, git_dir, spec, paths)
    if refresh {
      ignore(
        reset_refresh_index_entries(
          fs,
          rfs,
          root,
          git_dir,
          skip_override=Some(skip_before_reset),
        ),
      )
    }
    return
  }
  let soft_mode = match mode {
    @bitlib.ResetMode::Soft => true
    _ => false
  }
  if soft_mode && reset_soft_blocked(rfs, git_dir) {
    eprint_line("fatal: Cannot do a soft reset in the middle of a merge.")
    @sys.exit(1)
  }
  let orig_head = @bitlib.resolve_ref(rfs, git_dir, "HEAD")
  let commit_id = @bitlib.reset(fs, rfs, root, spec, mode)
  reset_write_orig_head(fs, git_dir, orig_head)
  let mixed_mode = match mode {
    @bitlib.ResetMode::Mixed => true
    _ => false
  }
  if mixed_mode {
    if intent_to_add {
      reset_apply_intent_to_add(fs, rfs, root, git_dir, before_entries)
    }
    if refresh {
      let changed = reset_refresh_index_entries(
        fs,
        rfs,
        root,
        git_dir,
        skip_override=Some(skip_before_reset),
      )
      if not(quiet) && changed.length() > 0 {
        print_line("Unstaged changes after reset:")
        for path in changed {
          print_line("M\t" + path)
        }
      }
    }
  }
  let hard_mode = match mode {
    @bitlib.ResetMode::Hard => true
    _ => false
  }
  if hard_mode {
    let short_id = String::unsafe_substring(commit_id.to_hex(), start=0, end=7)
    let subject = reset_commit_subject_bytes(rfs, git_dir, commit_id)
    reset_print_hard_reset_message(short_id, subject)
  }
}

///|
async fn reset_die_unknown_option(arg : String) -> Unit raise Error {
  let opt = if arg.has_prefix("--") {
    String::unsafe_substring(arg, start=2, end=arg.length())
  } else if arg.has_prefix("-") {
    String::unsafe_substring(arg, start=1, end=arg.length())
  } else {
    arg
  }
  eprint_line("error: unknown option '\{opt}'")
  @sys.exit(1)
}

///|
fn reset_mixed_paths(
  fs : &@bitcore.FileSystem,
  rfs : &@bitcore.RepoFileSystem,
  root : String,
  git_dir : String,
  spec : String,
  paths : Array[String],
) -> Unit raise Error {
  let target = match @bitrepo.rev_parse(rfs, git_dir, spec) {
    Some(id) => id
    None => raise @bitcore.GitError::InvalidObject("Invalid ref: \{spec}")
  }
  let object_git_dir = reset_resolve_common_git_dir(rfs, git_dir)
  let db = @bitlib.ObjectDb::load_lazy(rfs, object_git_dir)
  let tree_files = reset_collect_tree_files_from_target(db, rfs, target)
  let normalized_paths : Array[String] = []
  for raw in paths {
    let p = reset_normalize_path(raw)
    if p.length() > 0 {
      normalized_paths.push(p)
    }
  }
  let current_entries = @bitlib.read_index_entries(rfs, git_dir)
  let out_map : Map[String, @bitlib.IndexEntry] = {}
  for entry in current_entries {
    if not(reset_pathspec_matches_any(normalized_paths, entry.path)) {
      out_map[entry.path] = entry
    }
  }
  for item in tree_files.to_array() {
    let (path, info) = item
    if not(reset_pathspec_matches_any(normalized_paths, path)) {
      continue
    }
    let size = if info.mode == 0o160000 {
      0
    } else {
      match db.get(rfs, info.id) {
        Some(obj) => obj.data.length()
        None =>
          raise @bitcore.GitError::InvalidObject(
            "Missing blob object: " + info.id.to_hex(),
          )
      }
    }
    out_map[path] = @bitlib.IndexEntry::new(path, info.id, info.mode, size)
  }
  let out : Array[@bitlib.IndexEntry] = []
  for item in out_map.to_array() {
    let (_, entry) = item
    out.push(entry)
  }
  @bitlib.write_index_entries(fs, git_dir, out)
  ignore(root)
}

///|
fn reset_pathspec_matches_any(pathspecs : Array[String], path : String) -> Bool {
  for spec in pathspecs {
    if reset_pathspec_matches(spec, path) {
      return true
    }
  }
  false
}

///|
fn reset_pathspec_matches(spec : String, path : String) -> Bool {
  if spec == "." {
    return true
  }
  if path == spec {
    return true
  }
  path.has_prefix(spec + "/")
}

///|
fn reset_normalize_path(path : String) -> String {
  if path.has_prefix("./") {
    String::unsafe_substring(path, start=2, end=path.length())
  } else {
    path
  }
}

///|
fn reset_token_looks_like_path(
  fs : &@bitcore.RepoFileSystem,
  root : String,
  token : String,
) -> Bool {
  let path = reset_normalize_path(token)
  if path == "." {
    return true
  }
  if path.length() == 0 {
    return false
  }
  let abs = root + "/" + path
  fs.is_file(abs) || fs.is_dir(abs)
}

///|
fn reset_collect_tree_files_from_target(
  db : @bitlib.ObjectDb,
  fs : &@bitcore.RepoFileSystem,
  target : @bitcore.ObjectId,
) -> Map[String, @bitlib.TreeFileEntry] raise Error {
  match db.get(fs, target) {
    Some(obj) =>
      match obj.obj_type {
        @bitcore.ObjectType::Tree => @bitlib.collect_tree_files(db, fs, target)
        @bitcore.ObjectType::Commit =>
          @bitlib.collect_tree_files_from_commit(db, fs, target)
        _ =>
          raise @bitcore.GitError::InvalidObject("Invalid reset target object")
      }
    None =>
      raise @bitcore.GitError::InvalidObject("Missing reset target object")
  }
}

///|
fn reset_apply_intent_to_add(
  fs : &@bitcore.FileSystem,
  rfs : &@bitcore.RepoFileSystem,
  root : String,
  git_dir : String,
  before_entries : Array[@bitlib.IndexEntry],
) -> Unit raise Error {
  let after_entries = @bitlib.read_index_entries(rfs, git_dir)
  let after_map : Map[String, Bool] = {}
  for entry in after_entries {
    after_map[entry.path] = true
  }
  let merged : Array[@bitlib.IndexEntry] = []
  merged.append(after_entries)
  let zero = reset_zero_oid()
  for entry in before_entries {
    if after_map.contains(entry.path) {
      continue
    }
    let abs = root + "/" + entry.path
    if not(rfs.is_file(abs)) {
      continue
    }
    merged.push(
      @bitlib.IndexEntry::new(
        entry.path,
        zero,
        entry.mode,
        0,
        mtime_sec=0,
        mtime_nsec=0,
      ),
    )
  }
  @bitlib.write_index_entries(fs, git_dir, merged)
}

///|
fn reset_zero_oid() -> @bitcore.ObjectId {
  @bitcore.ObjectId::new(FixedArray::make(20, b'\x00'))
}

///|
async fn reset_refresh_index_entries(
  fs : &@bitcore.FileSystem,
  rfs : &@bitcore.RepoFileSystem,
  root : String,
  git_dir : String,
  skip_override? : Map[String, Bool]? = None,
) -> Array[String] raise Error {
  let entries = @bitlib.read_index_entries(rfs, git_dir)
  let skip = reset_read_skip_worktree_paths(rfs, git_dir)
  match skip_override {
    Some(extra) =>
      for item in extra.to_array() {
        let (path, enabled) = item
        if enabled {
          skip[path] = true
        }
      }
    None => ()
  }
  let updated : Array[@bitlib.IndexEntry] = []
  let changed_map : Map[String, Bool] = {}
  for entry in entries {
    let abs = root + "/" + entry.path
    let mut out_entry = entry
    let mut changed = false
    if not(rfs.is_file(abs)) {
      changed = true
    } else {
      let content = rfs.read_file(abs) catch {
        _ => {
          changed = true
          Bytes::default()
        }
      }
      if not(changed) {
        let id = @bitcore.hash_blob(content)
        if id == entry.id {
          let mut mtime_sec = entry.mtime_sec
          let mut mtime_nsec = entry.mtime_nsec
          let mtime_result : Result[(Int64, Int), Error] = try? @asyncfs.mtime(
            abs,
            follow_symlink=false,
          )
          match mtime_result {
            Ok((sec, nsec)) => {
              mtime_sec = sec.to_int()
              mtime_nsec = nsec
            }
            Err(_) => ()
          }
          out_entry = @bitlib.IndexEntry::new(
            entry.path,
            entry.id,
            entry.mode,
            content.length(),
            mtime_sec~,
            mtime_nsec~,
          )
        } else {
          changed = true
        }
      }
    }
    if changed && not(skip.contains(entry.path)) {
      changed_map[entry.path] = true
    }
    updated.push(out_entry)
  }
  @bitlib.write_index_entries(fs, git_dir, updated)
  let changed : Array[String] = []
  for item in changed_map.to_array() {
    let (path, _) = item
    changed.push(path)
  }
  changed.sort_by((a, b) => String::compare(a, b))
  changed
}

///|
fn reset_read_skip_worktree_paths(
  fs : &@bitcore.RepoFileSystem,
  git_dir : String,
) -> Map[String, Bool] {
  let out : Map[String, Bool] = {}
  let sidecar_path = git_dir + "/bit-skip-worktree"
  if fs.is_file(sidecar_path) {
    let text = decode_bytes(
      fs.read_file(sidecar_path) catch {
        _ => Bytes::default()
      },
    )
    for line_view in text.split("\n") {
      let line = trim_string(line_view.to_string())
      if line.length() > 0 {
        out[line] = true
      }
    }
  }
  let index_path = git_dir + "/index"
  if not(fs.is_file(index_path)) {
    return out
  }
  let data = fs.read_file(index_path) catch { _ => return out }
  if data.length() < 12 + 20 {
    return out
  }
  if not(
      data[0] == b'D' && data[1] == b'I' && data[2] == b'R' && data[3] == b'C',
    ) {
    return out
  }
  let count = reset_read_u32_be(data, 8)
  let mut offset = 12
  for _ in 0..<count {
    if offset + 62 > data.length() {
      return out
    }
    let flags = reset_read_u16_be(data, offset + 60)
    let stage = (flags >> 12) & 0x3
    let has_extended = (flags & 0x4000) != 0
    let ext_flags = if has_extended {
      reset_read_u16_be(data, offset + 62)
    } else {
      0
    }
    let fixed_size = if has_extended { 64 } else { 62 }
    let path_start = offset + fixed_size
    let mut i = path_start
    while i < data.length() && data[i] != b'\x00' {
      i += 1
    }
    if i >= data.length() {
      return out
    }
    if stage == 0 && has_extended && (ext_flags & 0x4000) != 0 {
      let path_bytes : Array[Byte] = []
      for j in path_start..<i {
        path_bytes.push(data[j])
      }
      out[decode_bytes(bytes_from_array(path_bytes))] = true
    }
    let path_len = i - path_start
    let entry_size = (fixed_size + path_len + 1 + 7) / 8 * 8
    offset += entry_size
  }
  out
}

///|
fn reset_soft_blocked(fs : &@bitcore.RepoFileSystem, git_dir : String) -> Bool {
  if fs.is_file(git_dir + "/MERGE_HEAD") {
    return true
  }
  reset_index_has_unmerged_entries(fs, git_dir)
}

///|
fn reset_index_has_unmerged_entries(
  fs : &@bitcore.RepoFileSystem,
  git_dir : String,
) -> Bool {
  let path = git_dir + "/index"
  if not(fs.is_file(path)) {
    return false
  }
  let data = fs.read_file(path) catch { _ => return false }
  if data.length() < 12 + 20 {
    return false
  }
  if not(
      data[0] == b'D' && data[1] == b'I' && data[2] == b'R' && data[3] == b'C',
    ) {
    return false
  }
  let count = reset_read_u32_be(data, 8)
  let mut offset = 12
  for _ in 0..<count {
    if offset + 62 > data.length() {
      return false
    }
    let flags = reset_read_u16_be(data, offset + 60)
    let stage = (flags >> 12) & 0x3
    if stage != 0 {
      return true
    }
    let has_extended = (flags & 0x4000) != 0
    let fixed_size = if has_extended { 64 } else { 62 }
    let path_start = offset + fixed_size
    let mut i = path_start
    while i < data.length() && data[i] != b'\x00' {
      i += 1
    }
    if i >= data.length() {
      return false
    }
    let path_len = i - path_start
    let entry_size = (fixed_size + path_len + 1 + 7) / 8 * 8
    offset += entry_size
  }
  false
}

///|
fn reset_read_u32_be(data : Bytes, start : Int) -> Int {
  if start < 0 || start + 4 > data.length() {
    return 0
  }
  (data[start].to_int() << 24) |
  (data[start + 1].to_int() << 16) |
  (data[start + 2].to_int() << 8) |
  data[start + 3].to_int()
}

///|
fn reset_read_u16_be(data : Bytes, start : Int) -> Int {
  if start < 0 || start + 2 > data.length() {
    return 0
  }
  (data[start].to_int() << 8) | data[start + 1].to_int()
}

///|
fn reset_write_orig_head(
  fs : &@bitcore.FileSystem,
  git_dir : String,
  head : @bitcore.ObjectId?,
) -> Unit raise Error {
  match head {
    Some(id) => fs.write_string(git_dir + "/ORIG_HEAD", id.to_hex() + "\n")
    None => ()
  }
}

///|
async fn reset_print_hard_reset_message(
  short_id : String,
  subject : Bytes,
) -> Unit {
  let prefix = if subject.length() > 0 {
    "HEAD is now at \{short_id} "
  } else {
    "HEAD is now at \{short_id}"
  }
  let out : Array[Byte] = []
  for c in prefix {
    out.push(c.to_int().to_byte())
  }
  for b in subject {
    out.push(b)
  }
  out.push(b'\n')
  @stdio.stdout.write(bytes_from_array(out))
}

///|
fn reset_commit_subject_bytes(
  fs : &@bitcore.RepoFileSystem,
  git_dir : String,
  commit_id : @bitcore.ObjectId,
) -> Bytes raise Error {
  let object_git_dir = reset_resolve_common_git_dir(fs, git_dir)
  let db = @bitlib.ObjectDb::load_lazy(fs, object_git_dir)
  match db.get(fs, commit_id) {
    Some(obj) => {
      let (subject, commit_encoding) = reset_extract_commit_subject_and_encoding(
        obj.data,
      )
      let output_encoding = reset_log_output_encoding()
      let source_encoding = reset_detect_commit_subject_encoding(
        subject, commit_encoding,
      )
      reset_convert_encoding(subject, source_encoding, output_encoding)
    }
    None => Bytes::default()
  }
}

///|
fn reset_extract_commit_subject_and_encoding(data : Bytes) -> (Bytes, String?) {
  let mut offset = 0
  let mut encoding : String? = None
  while offset <= data.length() {
    let line_start = offset
    while offset < data.length() && data[offset] != b'\n' {
      offset += 1
    }
    let mut line_end = offset
    if line_end > line_start && data[line_end - 1] == b'\r' {
      line_end -= 1
    }
    let line = decode_bytes(reset_slice_bytes(data, line_start, line_end))
    if line.length() == 0 {
      let subject_start = if offset < data.length() {
        offset + 1
      } else {
        offset
      }
      let mut subject_end = subject_start
      while subject_end < data.length() && data[subject_end] != b'\n' {
        subject_end += 1
      }
      if subject_end > subject_start && data[subject_end - 1] == b'\r' {
        subject_end -= 1
      }
      return (reset_slice_bytes(data, subject_start, subject_end), encoding)
    }
    if line.has_prefix("encoding ") {
      encoding = Some(
        trim_string(String::unsafe_substring(line, start=9, end=line.length())),
      )
    }
    if offset < data.length() {
      offset += 1
    } else {
      break
    }
  }
  (Bytes::default(), encoding)
}

///|
fn reset_log_output_encoding() -> String {
  let overrides = @bitlib.parse_config_overrides()
  match overrides.get("i18n.logoutputencoding") {
    Some(value) => {
      let trimmed = trim_string(value)
      if trimmed.length() > 0 {
        trimmed
      } else {
        "UTF-8"
      }
    }
    None => "UTF-8"
  }
}

///|
fn reset_detect_commit_subject_encoding(
  subject : Bytes,
  explicit_encoding : String?,
) -> String {
  match explicit_encoding {
    Some(value) => value
    None =>
      if reset_is_valid_utf8_bytes(subject) {
        "UTF-8"
      } else {
        "ISO-8859-1"
      }
  }
}

///|
fn reset_is_valid_utf8_bytes(data : Bytes) -> Bool {
  if data.length() == 0 {
    return true
  }
  let decoder = @encoding.decoder(@encoding.Encoding::UTF8)
  ignore(decoder.decode(data[:])) catch {
    _ => return false
  }
  true
}

///|
fn reset_convert_encoding(
  data : Bytes,
  source_encoding : String,
  target_encoding : String,
) -> Bytes {
  if data.length() == 0 {
    return data
  }
  let source = reset_normalize_encoding_name(source_encoding)
  let target = reset_normalize_encoding_name(target_encoding)
  if source == target || target.length() == 0 {
    return data
  }
  if reset_is_iso_8859_1(source) && reset_is_utf8(target) {
    return reset_iso_8859_1_to_utf8(data)
  }
  if reset_is_utf8(source) && reset_is_iso_8859_1(target) {
    return reset_utf8_to_iso_8859_1(data)
  }
  if reset_is_iso_8859_1(source) && reset_is_iso_8859_1(target) {
    return data
  }
  if reset_is_iso_8859_1(target) {
    return reset_utf8_to_iso_8859_1(data)
  }
  data
}

///|
fn reset_is_utf8(encoding : String) -> Bool {
  encoding == "utf8"
}

///|
fn reset_is_iso_8859_1(encoding : String) -> Bool {
  encoding == "iso88591" || encoding == "latin1" || encoding == "latin"
}

///|
fn reset_normalize_encoding_name(value : String) -> String {
  let trimmed = trim_string(value).to_lower()
  let out = StringBuilder::new()
  for c in trimmed {
    if c == '-' || c == '_' || c == ' ' {
      continue
    }
    out.write_char(c)
  }
  out.to_string()
}

///|
fn reset_iso_8859_1_to_utf8(data : Bytes) -> Bytes {
  let out : Array[Byte] = []
  for b in data {
    let value = b.to_int()
    if value < 0x80 {
      out.push(b)
    } else {
      out.push((0xC0 | (value >> 6)).to_byte())
      out.push((0x80 | (value & 0x3F)).to_byte())
    }
  }
  bytes_from_array(out)
}

///|
fn reset_utf8_to_iso_8859_1(data : Bytes) -> Bytes {
  let text = decode_bytes(data)
  let out : Array[Byte] = []
  for c in text {
    let code = c.to_int()
    if code <= 0xFF {
      out.push(code.to_byte())
    } else {
      out.push(b'?')
    }
  }
  bytes_from_array(out)
}

///|
fn reset_slice_bytes(data : Bytes, start : Int, end : Int) -> Bytes {
  let mut safe_start = start
  let mut safe_end = end
  if safe_start < 0 {
    safe_start = 0
  }
  if safe_end < safe_start {
    safe_end = safe_start
  }
  if safe_start > data.length() {
    safe_start = data.length()
  }
  if safe_end > data.length() {
    safe_end = data.length()
  }
  let len = safe_end - safe_start
  if len <= 0 {
    return Bytes::default()
  }
  Bytes::from_array(FixedArray::makei(len, i => data[safe_start + i]))
}

///|
fn reset_resolve_common_git_dir(
  fs : &@bitcore.RepoFileSystem,
  git_dir : String,
) -> String {
  let commondir_path = git_dir + "/commondir"
  if not(fs.is_file(commondir_path)) {
    return git_dir
  }
  let raw = decode_bytes(
    fs.read_file(commondir_path) catch {
      _ => return git_dir
    },
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

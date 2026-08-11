///|
pub(all) struct StorageInitArgs {
  quiet : Bool
  default_branch : String
  ref_format : String
  object_format : String
}

///|
pub(all) struct StorageAddArgs {
  add_all : Bool
  paths : Array[String]
}

///|
pub(all) struct StorageCommitArgs {
  message : String
  all_modified : Bool
  allow_empty : Bool
  quiet : Bool
  encoding : String
}

///|
pub(all) struct StorageStatusArgs {
  porcelain : Bool
  short : Bool
  show_branch : Bool
}

///|
pub(all) struct StorageLogArgs {
  oneline : Bool
  max_count : Int
}

///|
pub(all) struct StorageHashObjectArgs {
  write_object : Bool
  stdin_mode : Bool
  stdin_paths : Bool
  no_filters : Bool
  literally : Bool
  obj_type : @bit.ObjectType
  paths : Array[String]
  object_format : String
  path_hint : String
}

///|
pub(all) struct StorageWriteTreeArgs {
  prefix : String?
  missing_ok : Bool
}

///|
pub(all) struct StorageUpdateRefArgs {
  delete_mode : Bool
  refname : String
  new_value : String?
  old_value : String?
}

///|
pub(all) enum StorageCommand {
  Init(StorageInitArgs)
  Add(StorageAddArgs)
  Commit(StorageCommitArgs)
  Status(StorageStatusArgs)
  Log(StorageLogArgs)
  HashObject(StorageHashObjectArgs)
  WriteTree(StorageWriteTreeArgs)
  UpdateRef(StorageUpdateRefArgs)
}

///|
pub fn run_storage_command(
  fs : &@bit.FileSystem,
  rfs : &@bit.RepoFileSystem,
  root : String,
  command : StorageCommand,
) -> Unit raise Error {
  match command {
    StorageCommand::Init(args) => storage_handle_init(fs, rfs, root, args)
    StorageCommand::Add(args) => storage_handle_add(fs, rfs, root, args)
    StorageCommand::Commit(args) => storage_handle_commit(fs, rfs, root, args)
    StorageCommand::Status(args) => storage_handle_status(rfs, root, args)
    StorageCommand::Log(args) => storage_handle_log(rfs, root, args)
    StorageCommand::HashObject(args) =>
      storage_handle_hash_object(fs, rfs, root, args)
    StorageCommand::WriteTree(args) =>
      storage_handle_write_tree(fs, rfs, root, args)
    StorageCommand::UpdateRef(args) =>
      storage_handle_update_ref(fs, rfs, root, args)
  }
}

///|
fn storage_trim_string(s : String) -> String {
  @string_utils.trim_string(s)
}

///|
fn storage_decode_bytes(data : Bytes) -> String {
  @utf8.decode_lossy(data[:])
}

///|
fn storage_normalize_path(path : String) -> String {
  let parts : Array[String] = []
  for part_view in path.split("/") {
    let part = part_view.to_owned()
    if part == "" || part == "." {
      continue
    } else if part == ".." {
      if parts.length() > 0 && parts[parts.length() - 1] != ".." {
        let _ = parts.pop()
      } else if !path.has_prefix("/") {
        parts.push(part)
      }
    } else {
      parts.push(part)
    }
  }
  let result = parts.join("/")
  if path.has_prefix("/") {
    if result.length() == 0 {
      "/"
    } else {
      "/" + result
    }
  } else if result.length() == 0 {
    "."
  } else {
    result
  }
}

///|
fn storage_is_bare_repo_dir(rfs : &@bit.RepoFileSystem, path : String) -> Bool {
  rfs.is_file(path + "/HEAD") && rfs.is_dir(path + "/objects")
}

///|
fn storage_default_repo_marker_path(
  rfs : &@bit.RepoFileSystem,
  root : String,
) -> String {
  if storage_is_bare_repo_dir(rfs, root) {
    root
  } else {
    root + "/.git"
  }
}

///|
fn storage_resolve_git_dir(rfs : &@bit.RepoFileSystem, root : String) -> String {
  let default_git_dir = storage_default_repo_marker_path(rfs, root)
  match @sys.get_env_var("GIT_DIR") {
    Some(dir) => {
      let resolved = if dir.has_prefix("/") {
        dir
      } else {
        storage_normalize_path(root + "/" + dir)
      }
      if rfs.is_file(resolved) {
        @bitlib.resolve_gitdir(rfs, resolved)
      } else if rfs.is_dir(resolved) {
        resolved
      } else if storage_is_bare_repo_dir(rfs, root) {
        root
      } else {
        resolved
      }
    }
    None =>
      if rfs.is_file(default_git_dir) {
        @bitlib.resolve_gitdir(rfs, default_git_dir)
      } else if rfs.is_dir(default_git_dir) {
        default_git_dir
      } else if storage_is_bare_repo_dir(rfs, root) {
        root
      } else {
        default_git_dir
      }
  }
}

///|
fn storage_parse_git_env_timestamp(raw : String) -> Int64? {
  let mut token : String? = None
  for part_view in raw.split(" ") {
    let part = part_view.to_owned()
    if part.length() > 0 {
      token = Some(part)
      break
    }
  }
  match token {
    Some(part) =>
      if part.has_prefix("@") {
        let numeric = String::unsafe_substring(part, start=1, end=part.length())
        let parsed = @string.parse_int64(numeric) catch { _ => return None }
        Some(parsed)
      } else {
        // Plain integer epoch first; otherwise fall back to a human-readable
        // ISO date such as "2005-05-26 23:30" (git accepts these in
        // GIT_AUTHOR_DATE / GIT_COMMITTER_DATE).
        let parsed = @string.parse_int64(part) catch { _ => -1L }
        if parsed >= 0L {
          return Some(parsed)
        }
        storage_parse_iso_date_timestamp(raw)
      }
    None => None
  }
}

///|
/// Parse a human-readable ISO date into a Unix timestamp (seconds).
/// Formats: "2005-05-26 23:30", "2005-05-26T23:00", "2005-05-26 23:00:30",
/// optionally followed by a timezone offset such as " -0500".
fn storage_parse_iso_date_timestamp(raw : String) -> Int64? {
  let s = raw.trim().to_owned()
  if s.length() < 16 {
    return None
  }
  if s[4] != '-' || s[7] != '-' {
    return None
  }
  let sep = s[10]
  if sep != ' ' && sep != 'T' {
    return None
  }
  let year = @string.parse_int64(String::unsafe_substring(s, start=0, end=4)) catch {
    _ => return None
  }
  let month = @string.parse_int64(String::unsafe_substring(s, start=5, end=7)) catch {
    _ => return None
  }
  let day = @string.parse_int64(String::unsafe_substring(s, start=8, end=10)) catch {
    _ => return None
  }
  let time_str = String::unsafe_substring(s, start=11, end=s.length())
  let mut time_end = time_str.length()
  for i = 0; i < time_str.length(); i = i + 1 {
    let c = time_str[i]
    if c == ' ' || c == '+' || c == '-' {
      time_end = i
      break
    }
  }
  let time_part = String::unsafe_substring(time_str, start=0, end=time_end)
  if time_part.length() < 5 || time_part[2] != ':' {
    return None
  }
  let hour = @string.parse_int64(
    String::unsafe_substring(time_part, start=0, end=2),
  ) catch {
    _ => return None
  }
  let minute = @string.parse_int64(
    String::unsafe_substring(time_part, start=3, end=5),
  ) catch {
    _ => return None
  }
  let second = if time_part.length() >= 8 && time_part[5] == ':' {
    @string.parse_int64(String::unsafe_substring(time_part, start=6, end=8)) catch {
      _ => 0L
    }
  } else {
    0L
  }
  let days = storage_days_from_epoch(year, month, day)
  let mut ts = days * 86400L + hour * 3600L + minute * 60L + second
  let after_time = String::unsafe_substring(
    s,
    start=11 + time_end,
    end=s.length(),
  )
  ts = ts - storage_parse_iso_tz_offset_seconds(after_time)
  Some(ts)
}

///|
fn storage_parse_iso_tz_offset_seconds(s : String) -> Int64 {
  let t = s.trim().to_owned()
  if t.length() < 5 {
    return 0L
  }
  let sign : Int64 = if t[0] == '-' {
    -1L
  } else if t[0] == '+' {
    1L
  } else {
    return 0L
  }
  let (hh_str, mm_str) = if t.length() >= 6 && t[3] == ':' {
    (
      String::unsafe_substring(t, start=1, end=3),
      String::unsafe_substring(t, start=4, end=6),
    )
  } else {
    (
      String::unsafe_substring(t, start=1, end=3),
      String::unsafe_substring(t, start=3, end=5),
    )
  }
  let hh = @string.parse_int64(hh_str) catch { _ => return 0L }
  let mm = @string.parse_int64(mm_str) catch { _ => return 0L }
  sign * (hh * 3600L + mm * 60L)
}

///|
fn storage_days_from_epoch(year : Int64, month : Int64, day : Int64) -> Int64 {
  let month_days : Array[Int64] = [
    0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334,
  ]
  let y = year
  let m = month
  let mut days = 365L * (y - 1970L)
  if y > 1970L {
    days = days + (y - 1969L) / 4L - (y - 1901L) / 100L + (y - 1601L) / 400L
  } else {
    days = days - (1970L - y) / 4L + (1970L - y) / 100L - (1970L - y) / 400L
  }
  days = days + month_days[(m - 1L).to_int()]
  if m > 2L {
    let is_leap = (y % 4L == 0L && y % 100L != 0L) || y % 400L == 0L
    if is_leap {
      days = days + 1L
    }
  }
  days + day - 1L
}

///|
fn storage_get_current_timestamp() -> Int64 {
  // @env.now() returns milliseconds as UInt64; convert to seconds as Int64
  let ms = @env.now()
  (ms / 1000UL).reinterpret_as_int64()
}

///|
fn storage_get_author_string() -> String {
  match @sys.get_env_var("GIT_AUTHOR_NAME") {
    Some(name) => {
      let email = @sys.get_env_var("GIT_AUTHOR_EMAIL").unwrap_or("unknown")
      name + " <" + email + ">"
    }
    None => storage_get_user_from_config()
  }
}

///|
fn storage_get_user_from_config() -> String {
  // env BIT_COMMIT_AUTHOR is set by cmd/bit commit handler
  // to pass resolved author from git config
  match @sys.get_env_var("BIT_COMMIT_AUTHOR") {
    Some(a) if a.length() > 0 => return a
    _ => ()
  }
  match @sys.get_env_var("USER") {
    Some(user) => user + " <" + user + "@localhost>"
    None => "Unknown <unknown@localhost>"
  }
}

///|
fn storage_get_committer_string() -> String {
  match @sys.get_env_var("GIT_COMMITTER_NAME") {
    Some(name) => {
      let email = @sys.get_env_var("GIT_COMMITTER_EMAIL").unwrap_or("unknown")
      name + " <" + email + ">"
    }
    None =>
      // env BIT_COMMIT_COMMITTER is set by cmd/bit commit handler
      match @sys.get_env_var("BIT_COMMIT_COMMITTER") {
        Some(c) if c.length() > 0 => c
        _ => storage_get_author_string()
      }
  }
}

///|
fn storage_get_commit_timestamp() -> Int64 {
  match @sys.get_env_var("GIT_COMMITTER_DATE") {
    Some(raw) =>
      match storage_parse_git_env_timestamp(raw) {
        Some(ts) => ts
        None => storage_get_current_timestamp()
      }
    None => storage_get_current_timestamp()
  }
}

///|
fn storage_get_author_timestamp() -> Int64 {
  match @sys.get_env_var("GIT_AUTHOR_DATE") {
    Some(raw) =>
      match storage_parse_git_env_timestamp(raw) {
        Some(ts) => ts
        None => storage_get_commit_timestamp()
      }
    None => storage_get_commit_timestamp()
  }
}

///|
fn storage_is_valid_timezone_token(token : String) -> Bool {
  if token.length() != 5 {
    return false
  }
  let sign = token[0]
  if sign != '+' && sign != '-' {
    return false
  }
  for i in 1..<5 {
    let ch = token[i]
    if ch < '0' || ch > '9' {
      return false
    }
  }
  true
}

///|
fn storage_parse_git_env_timezone(raw : String) -> String? {
  let fields : Array[String] = []
  for part_view in raw.split(" ") {
    let part = part_view.to_owned()
    if part.length() > 0 {
      fields.push(part)
    }
  }
  if fields.length() < 2 {
    return None
  }
  let tz = fields[fields.length() - 1]
  if storage_is_valid_timezone_token(tz) {
    Some(tz)
  } else {
    None
  }
}

///|
fn storage_get_commit_timezone() -> String {
  match @sys.get_env_var("GIT_COMMITTER_DATE") {
    Some(raw) =>
      match storage_parse_git_env_timezone(raw) {
        Some(tz) => tz
        None => "+0000"
      }
    None => "+0000"
  }
}

///|
fn storage_get_author_timezone() -> String {
  match @sys.get_env_var("GIT_AUTHOR_DATE") {
    Some(raw) =>
      match storage_parse_git_env_timezone(raw) {
        Some(tz) => tz
        None => storage_get_commit_timezone()
      }
    None => storage_get_commit_timezone()
  }
}

///|
fn storage_hash_object_validate_content(
  obj_type : @bit.ObjectType,
  content : Bytes,
) -> Unit raise @bit.GitError {
  match obj_type {
    @bit.ObjectType::Commit => {
      let text = @utf8.decode_lossy(content[:])
      if !text.has_prefix("tree ") {
        raise @bit.GitError::InvalidObject("corrupt commit")
      }
    }
    @bit.ObjectType::Tag => {
      let text = @utf8.decode_lossy(content[:])
      if !text.has_prefix("object ") {
        raise @bit.GitError::InvalidObject("corrupt tag")
      }
    }
    _ => ()
  }
}

///|
fn storage_read_all_stdin() -> Bytes raise Error {
  raise @bit.GitError::InvalidObject(
    "hash-object: stdin is not supported in storage runtime",
  )
}

///|
fn storage_is_reftable_repo(
  rfs : &@bit.RepoFileSystem,
  git_dir : String,
) -> Bool {
  if rfs.is_dir(git_dir + "/reftable") {
    return true
  }
  match
    @bitlib.read_config_value(
      rfs,
      git_dir + "/config",
      "extensions",
      "refstorage",
    ) {
    Some(value) => value.to_lower() == "reftable"
    None => false
  }
}

///|
fn storage_parent_dir(path : String) -> String {
  if path.length() == 0 || path == "/" {
    return "/"
  }
  match path.rev_find("/") {
    None => ""
    Some(0) => "/"
    Some(i) => String::unsafe_substring(path, start=0, end=i)
  }
}

///|
fn storage_read_ref_value(
  rfs : &@bit.RepoFileSystem,
  git_dir : String,
  refname : String,
) -> @bit.ObjectId? {
  storage_read_ref_value_inner(rfs, git_dir, refname, 0)
}

///|
fn storage_read_ref_value_inner(
  rfs : &@bit.RepoFileSystem,
  git_dir : String,
  refname : String,
  depth : Int,
) -> @bit.ObjectId? {
  if depth > 8 {
    return None
  }
  let ref_path = git_dir + "/" + refname
  if rfs.is_file(ref_path) {
    let content = storage_decode_bytes(rfs.read_file(ref_path)) catch {
      _ => return None
    }
    let hex = storage_trim_string(content)
    if hex.has_prefix("ref: ") {
      let target = String::unsafe_substring(hex, start=5, end=hex.length())
      return storage_read_ref_value_inner(rfs, git_dir, target, depth + 1)
    }
    (@bit.ObjectId::from_hex(hex) |> Some) catch {
      _ => None
    }
  } else {
    @bitlib.resolve_ref(rfs, git_dir, refname) catch {
      _ => None
    }
  }
}

///|
fn storage_fail_unsupported_mode(
  cmd : String,
  detail : String,
) -> Unit raise Error {
  raise @bit.GitError::InvalidObject(
    cmd + ": mode is not supported in storage runtime: " + detail,
  )
}

///|
fn storage_runtime_is_quiet() -> Bool {
  match @sys.get_env_var("BIT_STORAGE_RUNTIME_QUIET") {
    Some(value) => {
      let normalized = storage_trim_string(value).to_lower()
      normalized == "1" || normalized == "true" || normalized == "yes"
    }
    None => false
  }
}

///|
fn storage_print_line(text : String) -> Unit {
  if storage_runtime_is_quiet() {
    return
  }
  println(text)
}

///|
fn storage_handle_init(
  fs : &@bit.FileSystem,
  rfs : &@bit.RepoFileSystem,
  root : String,
  args : StorageInitArgs,
) -> Unit raise Error {
  let ref_format = args.ref_format.to_lower()
  let object_format = args.object_format.to_lower()
  if ref_format != "files" {
    storage_fail_unsupported_mode("init", "--ref-format=" + ref_format)
  }
  if object_format != "sha1" {
    storage_fail_unsupported_mode("init", "--object-format=" + object_format)
  }
  let default_branch = if args.default_branch.length() == 0 {
    "main"
  } else {
    args.default_branch
  }
  let opts : @bitlib.InitOptions = {
    default_branch,
    bare: false,
    separate_git_dir: None,
    template_dir: None,
    ref_format,
    object_format,
    is_reinit: false,
    git_dir: None,
    work_tree: None,
    shared: None,
  }
  @bitrepo.init_repo_with_options_with_repo_fs(fs, rfs, root, opts)
  if !args.quiet {
    let git_dir = storage_resolve_git_dir(rfs, root)
    storage_print_line("Initialized empty Git repository in " + git_dir + "/")
  }
}

///|
fn storage_handle_add(
  fs : &@bit.FileSystem,
  rfs : &@bit.RepoFileSystem,
  root : String,
  args : StorageAddArgs,
) -> Unit raise Error {
  let git_dir = storage_resolve_git_dir(rfs, root)
  let algo = storage_resolve_hash_algorithm(rfs, git_dir, "")
  if args.add_all {
    let add_all_paths = storage_collect_add_all_paths(rfs, root)
    if add_all_paths.length() > 0 {
      @bitlib.add_paths(fs, rfs, root, add_all_paths, algo~)
    }
    return
  }
  if args.paths.length() == 0 {
    raise @bit.GitError::InvalidObject("add requires pathspec")
  }
  @bitlib.add_paths(fs, rfs, root, args.paths, algo~)
}

///|
fn storage_collect_add_all_paths(
  rfs : &@bit.RepoFileSystem,
  root : String,
) -> Array[String] raise Error {
  let snapshot = storage_collect_status_snapshot(rfs, root)
  let paths : Array[String] = []
  for p in snapshot.untracked {
    paths.push(p)
  }
  for p in snapshot.unstaged_modified {
    paths.push(p)
  }
  for p in snapshot.unstaged_deleted {
    paths.push(p)
  }
  paths
}

///|
fn storage_collect_commit_all_modified_paths(
  rfs : &@bit.RepoFileSystem,
  root : String,
) -> Array[String] raise Error {
  let snapshot = storage_collect_status_snapshot(rfs, root)
  let paths : Array[String] = []
  for p in snapshot.unstaged_modified {
    paths.push(p)
  }
  for p in snapshot.unstaged_deleted {
    paths.push(p)
  }
  paths
}

///|
fn storage_handle_commit(
  fs : &@bit.FileSystem,
  rfs : &@bit.RepoFileSystem,
  root : String,
  args : StorageCommitArgs,
) -> Unit raise Error {
  let git_dir = storage_resolve_git_dir(rfs, root)
  let algo = storage_resolve_hash_algorithm(rfs, git_dir, "")
  guard args.message.length() > 0 else {
    raise @bit.GitError::InvalidObject(
      "storage runtime commit requires -m/--message",
    )
  }
  if args.all_modified {
    let all_modified_paths = storage_collect_commit_all_modified_paths(
      rfs, root,
    )
    if all_modified_paths.length() > 0 {
      @bitlib.add_paths(fs, rfs, root, all_modified_paths)
    }
  }
  let author_timestamp = storage_get_author_timestamp()
  let author_timezone = storage_get_author_timezone()
  let timestamp = storage_get_commit_timestamp()
  let timezone = storage_get_commit_timezone()
  let committer = storage_get_committer_string()
  let committer_timestamp = timestamp
  let commit_id = @bitlib.commit(
    fs,
    rfs,
    root,
    args.message,
    storage_get_author_string(),
    author_timestamp,
    committer~,
    committer_timestamp~,
    allow_empty=args.allow_empty,
    timezone~,
    encoding=args.encoding,
    author_timezone=Some(author_timezone),
    committer_timezone=Some(timezone),
    algo~,
  )
  if !args.quiet {
    let short_id = String::unsafe_substring(commit_id.to_hex(), start=0, end=7)
    let first_line = match args.message.find("\n") {
      Some(idx) => String::unsafe_substring(args.message, start=0, end=idx)
      None => args.message
    }
    storage_print_line("[" + short_id + "] " + first_line)
  }
}

///|
priv struct StorageStatusSnapshot {
  staged_added : Array[String]
  staged_modified : Array[String]
  staged_deleted : Array[String]
  unstaged_modified : Array[String]
  unstaged_deleted : Array[String]
  untracked : Array[String]
}

///|
fn storage_parse_octal_mode(s : String) -> Int {
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
fn storage_is_tree_mode(mode : String) -> Bool {
  mode == "040000" || mode == "40000"
}

///|
fn storage_file_mode_kind(mode : Int) -> Int {
  mode & 0o170000
}

///|
fn storage_resolve_common_git_dir(
  rfs : &@bit.RepoFileSystem,
  git_dir : String,
) -> String {
  let commondir_path = git_dir + "/commondir"
  if !rfs.is_file(commondir_path) {
    return git_dir
  }
  let raw = storage_decode_bytes(
    rfs.read_file(commondir_path) catch {
      _ => Default::default()
    },
  )
  let rel = storage_trim_string(raw)
  if rel.length() == 0 {
    return git_dir
  }
  if rel.has_prefix("/") {
    storage_normalize_path(rel)
  } else {
    storage_normalize_path(git_dir + "/" + rel)
  }
}

///|
fn storage_collect_staged_changes_db(
  db : @bitlib.ObjectDb,
  rfs : &@bit.RepoFileSystem,
  tree_id : @bit.ObjectId,
  prefix : String,
  index_map : Map[String, @bitlib.IndexEntry],
  staged_modified : Array[String],
  staged_deleted : Array[String],
) -> Unit raise Error {
  let tree_obj = db.get(rfs, tree_id)
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
        if storage_is_tree_mode(entry.mode) {
          storage_collect_staged_changes_db(
            db,
            rfs,
            entry.id,
            path,
            index_map,
            staged_modified,
            staged_deleted,
          )
        } else {
          let mode = storage_parse_octal_mode(entry.mode)
          match index_map.get(path) {
            Some(index_entry) => {
              if index_entry.id != entry.id || index_entry.mode != mode {
                staged_modified.push(path)
              }
              index_map.remove(path)
            }
            None => staged_deleted.push(path)
          }
        }
      }
    }
  }
}

///|
fn storage_collect_staged_changes_from_head(
  rfs : &@bit.RepoFileSystem,
  git_dir : String,
  index_map : Map[String, @bitlib.IndexEntry],
  staged_modified : Array[String],
  staged_deleted : Array[String],
) -> Unit raise Error {
  match @bitlib.resolve_head_commit(rfs, git_dir) {
    None => ()
    Some(commit_id) => {
      let common_git_dir = storage_resolve_common_git_dir(rfs, git_dir)
      let db = @bitlib.ObjectDb::load_lazy(rfs, common_git_dir)
      match db.get(rfs, commit_id) {
        None => ()
        Some(obj) => {
          if obj.obj_type != @bit.ObjectType::Commit {
            raise @bit.GitError::InvalidObject("Object is not a commit")
          }
          let info = @bit.parse_commit(obj.data)
          storage_collect_staged_changes_db(
            db,
            rfs,
            info.tree,
            "",
            index_map,
            staged_modified,
            staged_deleted,
          )
        }
      }
    }
  }
}

///|
fn storage_collect_status_snapshot(
  rfs : &@bit.RepoFileSystem,
  root : String,
) -> StorageStatusSnapshot raise Error {
  let git_dir = storage_resolve_git_dir(rfs, root)
  let common_git_dir = storage_resolve_common_git_dir(rfs, git_dir)
  let core_filemode = @bitlib.core_filemode_enabled(rfs, common_git_dir)
  let entries = @bitlib.read_index_entries(rfs, git_dir)
  let index_map : Map[String, @bitlib.IndexEntry] = Map([])
  for entry in entries {
    index_map[entry.path] = entry
  }
  let files = @bitlib.list_working_files(rfs, root)
  files.sort()
  let visited : Map[String, Bool] = Map([])
  let untracked : Array[String] = []
  let unstaged_modified : Array[String] = []
  for rel_path in files {
    visited[rel_path] = true
    match index_map.get(rel_path) {
      Some(index_entry) => {
        let abs_path = root + "/" + rel_path
        let mut changed = false
        let content : Bytes? = match
          @io.worktree_entry_meta_sync(rfs, abs_path) {
          None => None
          Some(info) => {
            let kind_changed = storage_file_mode_kind(info.mode) !=
              storage_file_mode_kind(index_entry.mode)
            if kind_changed || (core_filemode && info.mode != index_entry.mode) {
              changed = true
            }
            match info.kind {
              @io.WorktreeKindMeta::Regular => {
                let bytes = rfs.read_file(abs_path) catch {
                  _ => {
                    changed = true
                    Bytes::new(0)
                  }
                }
                Some(bytes)
              }
              @io.WorktreeKindMeta::Symlink =>
                @io.read_symlink_target_path(abs_path).map(fn(target) {
                  @utf8.encode(target)
                })
            }
          }
        }
        match content {
          Some(bytes) =>
            if @bit.hash_blob(bytes) != index_entry.id {
              changed = true
            }
          None => changed = true
        }
        if changed {
          unstaged_modified.push(rel_path)
        }
      }
      None => untracked.push(rel_path)
    }
  }
  let unstaged_deleted : Array[String] = []
  for entry in entries {
    if visited.get(entry.path) is Some(_) {
      continue
    }
    let abs_path = root + "/" + entry.path
    if !rfs.is_file(abs_path) {
      unstaged_deleted.push(entry.path)
    }
  }
  let staged_index_map : Map[String, @bitlib.IndexEntry] = Map([])
  for entry in entries {
    staged_index_map[entry.path] = entry
  }
  let staged_modified : Array[String] = []
  let staged_deleted : Array[String] = []
  storage_collect_staged_changes_from_head(
    rfs, git_dir, staged_index_map, staged_modified, staged_deleted,
  )
  let staged_added : Array[String] = []
  for path in staged_index_map.keys() {
    staged_added.push(path)
  }
  staged_added.sort()
  staged_modified.sort()
  staged_deleted.sort()
  unstaged_modified.sort()
  unstaged_deleted.sort()
  untracked.sort()
  let snapshot : StorageStatusSnapshot = {
    staged_added,
    staged_modified,
    staged_deleted,
    unstaged_modified,
    unstaged_deleted,
    untracked,
  }
  snapshot
}

///|
fn storage_status_porcelain_branch_line(
  rfs : &@bit.RepoFileSystem,
  git_dir : String,
) -> String raise Error {
  match @bitlib.read_head_ref(rfs, git_dir) {
    @bitlib.HeadRef::Branch(name) => "## " + name
    @bitlib.HeadRef::Detached(id) => {
      let short_id = String::unsafe_substring(id.to_hex(), start=0, end=7)
      "## HEAD (detached at " + short_id + ")"
    }
  }
}

///|
fn storage_status_porcelain_lines(
  rfs : &@bit.RepoFileSystem,
  root : String,
  show_branch : Bool,
) -> Array[String] raise Error {
  let git_dir = storage_resolve_git_dir(rfs, root)
  let out : Array[String] = []
  if show_branch {
    out.push(storage_status_porcelain_branch_line(rfs, git_dir))
  }
  let status = storage_collect_status_snapshot(rfs, root)
  let xmap : Map[String, Char] = Map([])
  let ymap : Map[String, Char] = Map([])
  for p in status.staged_added {
    xmap[p] = 'A'
  }
  for p in status.staged_modified {
    xmap[p] = 'M'
  }
  for p in status.staged_deleted {
    xmap[p] = 'D'
  }
  for p in status.unstaged_modified {
    ymap[p] = 'M'
  }
  for p in status.unstaged_deleted {
    ymap[p] = 'D'
  }
  let paths : Map[String, Bool] = Map([])
  for p in status.staged_added {
    paths[p] = true
  }
  for p in status.staged_modified {
    paths[p] = true
  }
  for p in status.staged_deleted {
    paths[p] = true
  }
  for p in status.unstaged_modified {
    paths[p] = true
  }
  for p in status.unstaged_deleted {
    paths[p] = true
  }
  let lines : Array[String] = []
  let merged_paths = paths.keys().to_array()
  merged_paths.sort()
  for path in merged_paths {
    let x = xmap.get(path).unwrap_or(' ')
    let y = ymap.get(path).unwrap_or(' ')
    lines.push("\{x}\{y} \{path}")
  }
  for path in status.untracked {
    lines.push("?? \{path}")
  }
  for line in lines {
    out.push(line)
  }
  out
}

///|
fn storage_status_text_lines(
  rfs : &@bit.RepoFileSystem,
  root : String,
) -> Array[String] raise Error {
  let git_dir = storage_resolve_git_dir(rfs, root)
  let out : Array[String] = []
  match @bitlib.read_head_ref(rfs, git_dir) {
    @bitlib.HeadRef::Branch(name) => out.push("On branch " + name)
    @bitlib.HeadRef::Detached(id) => {
      let short_id = String::unsafe_substring(id.to_hex(), start=0, end=7)
      out.push("HEAD detached at " + short_id)
    }
  }
  let status = storage_collect_status_snapshot(rfs, root)
  let has_staged = status.staged_added.length() > 0 ||
    status.staged_modified.length() > 0 ||
    status.staged_deleted.length() > 0
  let has_unstaged = status.unstaged_modified.length() > 0 ||
    status.unstaged_deleted.length() > 0
  if has_staged {
    out.push("")
    out.push("Changes to be committed:")
    for path in status.staged_added {
      out.push("  staged: " + path)
    }
    for path in status.staged_modified {
      out.push("  staged: " + path)
    }
    for path in status.staged_deleted {
      out.push("  staged: " + path)
    }
  }
  if has_unstaged {
    out.push("")
    out.push("Changes not staged for commit:")
    for path in status.unstaged_modified {
      out.push("  modified: " + path)
    }
    for path in status.unstaged_deleted {
      out.push("  deleted: " + path)
    }
  }
  if status.untracked.length() > 0 {
    out.push("")
    out.push("Untracked files:")
    for path in status.untracked {
      out.push("  " + path)
    }
  }
  if !has_staged && !has_unstaged && status.untracked.length() == 0 {
    out.push("")
    out.push("nothing to commit, working tree clean")
  }
  out
}

///|
fn storage_handle_status(
  rfs : &@bit.RepoFileSystem,
  root : String,
  args : StorageStatusArgs,
) -> Unit raise Error {
  let lines = if args.porcelain || args.short {
    storage_status_porcelain_lines(rfs, root, args.show_branch)
  } else {
    storage_status_text_lines(rfs, root)
  }
  for line in lines {
    storage_print_line(line)
  }
}

///|
fn storage_handle_log(
  rfs : &@bit.RepoFileSystem,
  root : String,
  args : StorageLogArgs,
) -> Unit raise Error {
  let git_dir = storage_resolve_git_dir(rfs, root)
  if args.oneline {
    let lines = @bitlib.log_head_oneline(rfs, git_dir, max_count=args.max_count)
    for line in lines {
      storage_print_line(line)
    }
    return
  }
  let entries = @bitlib.log_head(rfs, git_dir, max_count=args.max_count)
  for entry in entries {
    storage_print_line("commit " + entry.id.to_hex())
    storage_print_line("Author: " + entry.author)
    storage_print_line("")
    storage_print_line("    " + entry.message)
    storage_print_line("")
  }
}

///|
fn storage_handle_hash_object(
  fs : &@bit.FileSystem,
  rfs : &@bit.RepoFileSystem,
  root : String,
  args : StorageHashObjectArgs,
) -> Unit raise Error {
  let cwd = match @sys.get_env_var("GIT_SHIM_PWD") {
    Some(path) => path
    None =>
      match @env.current_dir() {
        Some(path) => path
        None => root
      }
  }
  let git_dir = if args.write_object {
    storage_resolve_git_dir(rfs, root)
  } else {
    root + "/.git"
  }
  // compatObjectFormat is ignored — we write sha1 objects regardless.
  ignore(storage_read_compat_object_format(rfs, git_dir))
  let algo = storage_resolve_hash_algorithm(rfs, git_dir, args.object_format)
  if args.stdin_mode {
    let content = storage_read_all_stdin()
    if !args.literally {
      storage_hash_object_validate_content(args.obj_type, content)
    }
    let id = @object.hash_object_content_with_algo(algo, args.obj_type, content)
    if args.write_object {
      let (_, compressed) = @object.create_object_with_algo(
        algo,
        args.obj_type,
        content,
      )
      @bitlib.write_object_bytes(fs, git_dir, id, compressed)
    }
    storage_print_line(id.to_hex())
    if args.paths.length() == 0 && !args.stdin_paths {
      return
    }
  }
  if args.stdin_paths {
    let stdin_content = storage_read_all_stdin()
    let text = @string_utils.decode_bytes(stdin_content)
    let autocrlf = @bitlib.read_autocrlf_setting(rfs, git_dir)
    for line_view in text.split("\n") {
      let line = line_view.to_owned()
      if line.length() == 0 {
        continue
      }
      let abs = if line.has_prefix("/") {
        storage_normalize_path(line)
      } else {
        storage_normalize_path(cwd + "/" + line)
      }
      let content = rfs.read_file(abs)
      let prefix_len = root.length() + 1
      let rel_path = if abs.has_prefix(root + "/") {
        abs[prefix_len:].to_owned()
      } else {
        abs
      }
      let attrs = if args.no_filters {
        @bitlib.resolve_eol_attrs(rfs, root, "")
      } else {
        @bitlib.resolve_eol_attrs(rfs, root, rel_path)
      }
      let normalized = if args.no_filters {
        content
      } else {
        @bitlib.clean_for_storage(content, attrs, autocrlf)
      }
      let id = @object.hash_object_content_with_algo(
        algo,
        args.obj_type,
        normalized,
      )
      if args.write_object {
        let (_, compressed) = @object.create_object_with_algo(
          algo,
          args.obj_type,
          normalized,
        )
        @bitlib.write_object_bytes(fs, git_dir, id, compressed)
      }
      storage_print_line(id.to_hex())
    }
    return
  }
  let autocrlf = @bitlib.read_autocrlf_setting(rfs, git_dir)
  for path in args.paths {
    let abs = if path.has_prefix("/") {
      storage_normalize_path(path)
    } else {
      storage_normalize_path(cwd + "/" + path)
    }
    let content = rfs.read_file(abs)
    let prefix_len = root.length() + 1
    let rel_path = if abs.has_prefix(root + "/") {
      abs[prefix_len:].to_owned()
    } else {
      abs
    }
    let filter_rel = if args.path_hint.length() > 0 {
      args.path_hint
    } else {
      rel_path
    }
    let attrs = if args.no_filters {
      @bitlib.resolve_eol_attrs(rfs, root, "")
    } else {
      @bitlib.resolve_eol_attrs(rfs, root, filter_rel)
    }
    let normalized = if args.no_filters {
      content
    } else {
      @bitlib.clean_for_storage(content, attrs, autocrlf)
    }
    if !args.literally {
      storage_hash_object_validate_content(args.obj_type, normalized)
    }
    let id = @object.hash_object_content_with_algo(
      algo,
      args.obj_type,
      normalized,
    )
    if args.write_object {
      let (_, compressed) = @object.create_object_with_algo(
        algo,
        args.obj_type,
        normalized,
      )
      @bitlib.write_object_bytes(fs, git_dir, id, compressed)
    }
    storage_print_line(id.to_hex())
  }
}

///|
fn storage_read_compat_object_format(
  rfs : &@bit.RepoFileSystem,
  git_dir : String,
) -> String? {
  let overrides = @bitlib.parse_config_overrides()
  match overrides.get("extensions.compatobjectformat") {
    Some(value) => Some(value)
    None =>
      @bitlib.read_config_value(
        rfs,
        git_dir + "/config",
        "extensions",
        "compatobjectformat",
      )
  }
}

///|
fn storage_resolve_hash_algorithm(
  rfs : &@bit.RepoFileSystem,
  git_dir : String,
  explicit_format : String,
) -> @object.HashAlgorithm {
  if explicit_format.length() > 0 {
    return if explicit_format.to_lower() == "sha256" {
      @object.HashAlgorithm::Sha256
    } else {
      @object.HashAlgorithm::Sha1
    }
  }
  match
    @bitlib.read_config_value(
      rfs,
      git_dir + "/config",
      "extensions",
      "objectformat",
    ) {
    Some(value) =>
      if value.to_lower() == "sha256" {
        @object.HashAlgorithm::Sha256
      } else {
        @object.HashAlgorithm::Sha1
      }
    None => @object.HashAlgorithm::Sha1
  }
}

///|
fn storage_handle_write_tree(
  fs : &@bit.FileSystem,
  rfs : &@bit.RepoFileSystem,
  root : String,
  args : StorageWriteTreeArgs,
) -> Unit raise Error {
  let git_dir = storage_resolve_git_dir(rfs, root)
  let algo = storage_resolve_hash_algorithm(rfs, git_dir, "")
  let entries = @bitlib.read_index_entries(rfs, git_dir)
  let tree_id = @bitlib.write_tree_from_index(
    fs,
    rfs,
    git_dir,
    entries,
    prefix=args.prefix,
    missing_ok=args.missing_ok,
    algo~,
  )
  storage_print_line(tree_id.to_hex())
}

///|
fn storage_handle_update_ref(
  fs : &@bit.FileSystem,
  rfs : &@bit.RepoFileSystem,
  root : String,
  args : StorageUpdateRefArgs,
) -> Unit raise Error {
  let git_dir = storage_resolve_git_dir(rfs, root)
  if storage_is_reftable_repo(rfs, git_dir) {
    storage_fail_unsupported_mode("update-ref", "reftable repository")
  }
  if args.delete_mode {
    storage_verify_old_ref_value(rfs, git_dir, args.refname, args.old_value)
    let ref_path = git_dir + "/" + args.refname
    if rfs.is_file(ref_path) {
      fs.remove_file(ref_path)
    }
    return
  }
  guard args.new_value is Some(raw_new_value) else {
    raise @bit.GitError::InvalidObject(
      "usage: update-ref <refname> <newvalue> [<oldvalue>]",
    )
  }
  let new_value = if raw_new_value == "@" { "HEAD" } else { raw_new_value }
  storage_verify_old_ref_value(rfs, git_dir, args.refname, args.old_value)
  let new_id = storage_resolve_object_id(rfs, git_dir, new_value)
  let ref_path = git_dir + "/" + args.refname
  let dir = storage_parent_dir(ref_path)
  if dir.length() > 0 && !rfs.is_dir(dir) {
    fs.mkdir_p(dir)
  }
  fs.write_string(ref_path, new_id.to_hex() + "\n")
}

///|
fn storage_verify_old_ref_value(
  rfs : &@bit.RepoFileSystem,
  git_dir : String,
  refname : String,
  old_value : String?,
) -> Unit raise Error {
  match old_value {
    Some(expected_hex) => {
      let expected = @bit.ObjectId::from_hex(expected_hex)
      let current = storage_read_ref_value(rfs, git_dir, refname)
      match current {
        Some(cur_id) =>
          if cur_id.to_hex() != expected.to_hex() {
            raise @bit.GitError::InvalidObject(
              "update-ref oldvalue mismatch for " + refname,
            )
          }
        None =>
          if expected.to_hex() != @bit.ObjectId::zero().to_hex() {
            raise @bit.GitError::InvalidObject(
              "update-ref expected existing ref: " + refname,
            )
          }
      }
    }
    None => ()
  }
}

///|
fn storage_resolve_object_id(
  rfs : &@bit.RepoFileSystem,
  git_dir : String,
  spec : String,
) -> @bit.ObjectId raise Error {
  @bit.ObjectId::from_hex(spec) catch {
    _ =>
      match @bitrepo.rev_parse(rfs, git_dir, spec) {
        Some(id) => id
        None => raise @bit.GitError::InvalidObject("unknown revision: " + spec)
      }
  }
}

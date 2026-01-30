///|
pub struct OsFs {
  dummy : Int
}

///|
pub fn OsFs::new() -> OsFs {
  { dummy: 0 }
}

///|
fn io_error(err : @fs.IOError) -> @git.GitError {
  @git.GitError::IoError(err.to_string())
}

///|
fn bytes_from_array(arr : Array[Byte]) -> Bytes {
  Bytes::from_array(FixedArray::makei(arr.length(), fn(i) { arr[i] }))
}

///|
fn str_to_bytes(s : String) -> Bytes {
  let arr : Array[Byte] = []
  for c in s {
    arr.push(c.to_int().to_byte())
  }
  bytes_from_array(arr)
}

///|
async fn print_line(s : String) -> Unit {
  @stdio.stdout.write(str_to_bytes(s + "\n"))
}

///|
async fn print_str(s : String) -> Unit {
  @stdio.stdout.write(str_to_bytes(s))
}

///|
async fn eprint_line(s : String) -> Unit {
  @stdio.stderr.write(str_to_bytes(s + "\n"))
}

///|
fn decode_bytes(data : Bytes) -> String {
  @encoding.decoder(@encoding.Encoding::UTF8).decode_lossy(data[:])
}

///|
fn trim_string(s : String) -> String {
  let mut start = 0
  let mut end = s.length()
  while start < end {
    let c = s.unsafe_get(start)
    if c == ' ' || c == '\t' || c == '\n' || c == '\r' {
      start += 1
    } else {
      break
    }
  }
  while end > start {
    let c = s.unsafe_get(end - 1)
    if c == ' ' || c == '\t' || c == '\n' || c == '\r' {
      end -= 1
    } else {
      break
    }
  }
  if start == 0 && end == s.length() {
    s
  } else {
    String::unsafe_substring(s, start~, end~)
  }
}

///|
priv struct ShowCommitInfo {
  author : String
  timestamp : Int64
  message : String
}

///|
fn parse_show_commit(data : Bytes) -> ShowCommitInfo {
  let text = decode_bytes(data)
  let mut author = ""
  let mut timestamp = 0L
  let mut in_message = false
  let message_lines : Array[String] = []
  for line_view in text.split("\n") {
    let line = line_view.to_string()
    if in_message {
      message_lines.push(line)
      continue
    }
    if line.length() == 0 {
      in_message = true
      continue
    }
    if line.has_prefix("author ") {
      let rest = String::unsafe_substring(line, start=7, end=line.length())
      // format: Name <email> 1700000000 +0000
      let mut last_space = rest.rev_find(" ")
      if last_space is Some(tz_idx) {
        let before_tz = String::unsafe_substring(rest, start=0, end=tz_idx)
        last_space = before_tz.rev_find(" ")
        if last_space is Some(time_idx) {
          author = String::unsafe_substring(before_tz, start=0, end=time_idx)
          let time_str = String::unsafe_substring(
            before_tz,
            start=time_idx + 1,
            end=before_tz.length(),
          )
          for c in time_str {
            if c >= '0' && c <= '9' {
              let digit = c.to_int() - '0'.to_int()
              timestamp = timestamp * 10L + digit.to_int64()
            }
          }
        } else {
          author = before_tz
        }
      } else {
        author = rest
      }
    }
  }
  let message = if message_lines.length() > 0 {
    message_lines
    .iter()
    .fold(init="", fn(acc, line) {
      if acc.length() == 0 {
        line
      } else {
        acc + "\n" + line
      }
    })
  } else {
    ""
  }
  { author, timestamp, message }
}

///|
fn parent_dir(path : String) -> String {
  if path.length() == 0 || path == "/" {
    return "/"
  }
  let sep = @path.sep.to_string()
  match path.rev_find(sep) {
    None => ""
    Some(idx) => if idx == 0 { sep } else { (try! path[:idx]).to_string() }
  }
}

///|
fn ensure_dir(path : String) -> Unit raise @git.GitError {
  if path.length() == 0 || path == "/" || path == "." {
    return ()
  }
  if @fs.path_exists(path) {
    let is_dir = @fs.is_dir(path) catch { _ => false }
    if is_dir {
      return ()
    }
    raise @git.GitError::IoError("path exists and is not dir: " + path)
  }
  let parent = parent_dir(path)
  if parent.length() > 0 && parent != path {
    ensure_dir(parent)
  }
  @fs.create_dir(path) catch {
    err => raise io_error(err)
  }
}

///|
pub impl @git.FileSystem for OsFs with mkdir_p(_self, path) {
  ensure_dir(path)
}

///|
pub impl @git.FileSystem for OsFs with write_file(_self, path, content) {
  @fs.write_bytes_to_file(path, content) catch {
    err => raise io_error(err)
  }
}

///|
pub impl @git.FileSystem for OsFs with write_string(_self, path, content) {
  @fs.write_string_to_file(path, content) catch {
    err => raise io_error(err)
  }
}

///|
pub impl @git.FileSystem for OsFs with remove_file(_self, path) {
  @fs.remove_file(path) catch {
    err => raise io_error(err)
  }
}

///|
pub impl @git.RepoFileSystem for OsFs with read_file(_self, path) {
  @fs.read_file_to_bytes(path) catch {
    err => raise io_error(err)
  }
}

///|
pub impl @git.RepoFileSystem for OsFs with readdir(_self, path) {
  @fs.read_dir(path) catch {
    err => raise io_error(err)
  }
}

///|
pub impl @git.RepoFileSystem for OsFs with is_dir(_self, path) {
  @fs.is_dir(path) catch {
    _ => false
  }
}

///|
pub impl @git.RepoFileSystem for OsFs with is_file(_self, path) {
  @fs.is_file(path) catch {
    _ => false
  }
}

///|
fn real_git_path() -> String {
  match @sys.get_env_var("SHIM_REAL_GIT") {
    Some(path) => path
    None =>
      match @sys.get_env_var("GIT_SHIM_REAL_GIT") {
        Some(path) => path
        None => "git"
      }
  }
}

///|
fn collect_args(args : Array[String], start : Int) -> Array[String] {
  let out : Array[String] = []
  let len = args.length()
  for i in start..<len {
    out.push(args[i])
  }
  out
}

///|
fn prepend_arg(first : String, rest : Array[String]) -> Array[String] {
  let out : Array[String] = [first]
  out.append(rest)
  out
}

///|
async fn read_all_stdin() -> Bytes {
  let out : Array[Byte] = []
  while true {
    let chunk = @stdio.stdin.read_some(max_len=8192)
    match chunk {
      None => break
      Some(bytes) =>
        for b in bytes {
          out.push(b)
        }
    }
  }
  bytes_from_array(out)
}

///|
async fn run_system_git(args : Array[String]) -> Unit {
  let git = real_git_path()
  let status = @process.run(
    git,
    args,
    inherit_env=true,
    stdin=@stdio.stdin,
    stdout=@stdio.stdout,
    stderr=@stdio.stderr,
  )
  @sys.exit(status)
}

///|
fn parse_receive_pack_args(args : Array[String]) -> (Bool, String)? {
  let mut advertise = false
  let mut repo : String? = None
  for arg in args {
    if arg == "--advertise-refs" {
      advertise = true
      continue
    }
    if arg == "--stateless-rpc" {
      continue
    }
    if arg.has_prefix("--") {
      continue
    }
    if repo is None {
      repo = Some(arg)
    }
  }
  match repo {
    None => None
    Some(path) => Some((advertise, path))
  }
}

///|
fn normalize_repo_root(path : String) -> String {
  if path == ".git" {
    return "."
  }
  if path.has_suffix("/.git") && path.length() > 5 {
    return (try! path[:path.length() - 5]).to_string()
  }
  path
}

///|
fn parse_upload_pack_args(args : Array[String]) -> (Bool, String)? {
  let mut advertise = false
  let mut repo : String? = None
  for arg in args {
    if arg == "--advertise-refs" {
      advertise = true
      continue
    }
    if arg == "--stateless-rpc" {
      continue
    }
    if arg.has_prefix("--") {
      continue
    }
    if repo is None {
      repo = Some(arg)
    }
  }
  match repo {
    None => None
    Some(path) => Some((advertise, path))
  }
}

///|
async fn handle_upload_pack(args : Array[String]) -> Unit {
  guard parse_upload_pack_args(args) is Some((advertise, repo_path)) else {
    raise @git.GitError::ProtocolError("missing repository path")
  }
  if repo_path.has_suffix(".git") && !repo_path.has_suffix("/.git") {
    run_system_git(prepend_arg("upload-pack", args))
    return ()
  }
  let root = normalize_repo_root(repo_path)
  let fs = OsFs::new()
  if advertise {
    let out = @gitlib.build_upload_pack_advertisement(fs, root)
    @stdio.stdout.write(out)
  } else {
    let input = read_all_stdin()
    let req = @gitlib.parse_upload_pack_request(input)
    let out = @gitlib.upload_pack(fs, root, req)
    @stdio.stdout.write(out)
  }
}

///|
async fn handle_receive_pack(args : Array[String]) -> Unit {
  guard parse_receive_pack_args(args) is Some((advertise, repo_path)) else {
    raise @git.GitError::ProtocolError("missing repository path")
  }
  if repo_path.has_suffix(".git") && !repo_path.has_suffix("/.git") {
    run_system_git(prepend_arg("receive-pack", args))
    return ()
  }
  let root = normalize_repo_root(repo_path)
  let fs = OsFs::new()
  if advertise {
    let out = @gitlib.build_receive_pack_advertisement(fs, root)
    @stdio.stdout.write(out)
  } else {
    let input = read_all_stdin()
    let out = @gitlib.receive_pack(fs, fs, root, input)
    @stdio.stdout.write(out)
  }
}

///|
fn get_work_root() -> String {
  match @sys.get_env_var("GIT_SHIM_CWD") {
    Some(dir) => dir
    None =>
      match @sys.get_env_var("GIT_WORK_TREE") {
        Some(dir) => dir
        None => "."
      }
  }
}

///|
async fn handle_init(args : Array[String]) -> Unit raise Error {
  let root = get_work_root()
  let path = if args.length() > 0 {
    let arg = args[0]
    if arg.has_prefix("/") {
      arg
    } else {
      root + "/" + arg
    }
  } else {
    root
  }
  let fs = OsFs::new()
  @gitlib.init_repo(fs, path)
  print_line("Initialized empty Git repository in " + path + "/.git/")
}

///|
async fn handle_clone(args : Array[String]) -> Unit raise Error {
  // Parse: git clone <url> [<directory>]
  let root = get_work_root()
  let mut url : String? = None
  let mut dest : String? = None
  for arg in args {
    if arg.has_prefix("-") {
      continue
    }
    if url is None {
      url = Some(arg)
    } else if dest is None {
      dest = Some(arg)
    }
  }
  guard url is Some(remote_url) else {
    raise @git.GitError::InvalidObject("repository URL required")
  }
  // Derive destination from URL if not specified
  let relative_target = match dest {
    Some(d) => d
    None => {
      // Extract repo name from URL
      let name = if remote_url.has_suffix(".git") {
        String::unsafe_substring(
          remote_url,
          start=0,
          end=remote_url.length() - 4,
        )
      } else {
        remote_url
      }
      match name.rev_find("/") {
        Some(i) =>
          String::unsafe_substring(name, start=i + 1, end=name.length())
        None => name
      }
    }
  }
  let target = if relative_target.has_prefix("/") {
    relative_target
  } else {
    root + "/" + relative_target
  }
  print_line("Cloning into '\{relative_target}'...")
  let fs = OsFs::new()
  // Use existing clone_http_to_fs from @git package
  let refs = @git.clone_http_to_fs(remote_url, true, fs, target)
  if refs.length() > 0 {
    print_line("done.")
  } else {
    raise @git.GitError::InvalidObject("Clone failed: no refs found")
  }
}

///|
async fn handle_status(args : Array[String]) -> Unit raise Error {
  let root = get_work_root()
  let fs = OsFs::new()
  let mut porcelain = false
  let mut short = false
  for arg in args {
    if arg == "--porcelain" || arg == "--porcelain=v1" {
      porcelain = true
    }
    if arg == "-s" || arg == "--short" {
      short = true
    }
  }
  if porcelain || short {
    let lines = @gitlib.status_porcelain(fs, root)
    for line in lines {
      print_line(line)
    }
  } else {
    let text = @gitlib.status_text(fs, root)
    print_str(text)
  }
}

///|
fn handle_add(args : Array[String]) -> Unit raise Error {
  let root = get_work_root()
  let fs = OsFs::new()
  let paths : Array[String] = []
  for arg in args {
    if not(arg.has_prefix("-")) {
      paths.push(arg)
    }
  }
  if paths.length() == 0 {
    raise @git.GitError::InvalidObject("Nothing specified, nothing added.")
  }
  @gitlib.add_paths(fs, fs, root, paths)
}

///|
async fn handle_commit(args : Array[String]) -> Unit raise Error {
  let root = get_work_root()
  let fs = OsFs::new()
  let mut message : String? = None
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    if arg == "-m" && i + 1 < args.length() {
      message = Some(args[i + 1])
      i += 2
      continue
    }
    if arg.has_prefix("-m") {
      message = Some((try! arg[2:]).to_string())
      i += 1
      continue
    }
    if arg.has_prefix("--message=") {
      message = Some((try! arg[10:]).to_string())
      i += 1
      continue
    }
    i += 1
  }
  guard message is Some(msg) else {
    raise @git.GitError::InvalidObject("No commit message specified")
  }
  let author = match @sys.get_env_var("GIT_AUTHOR_NAME") {
    Some(name) => {
      let email = @sys.get_env_var("GIT_AUTHOR_EMAIL").unwrap_or("unknown")
      name + " <" + email + ">"
    }
    None =>
      match @sys.get_env_var("USER") {
        Some(u) => u + " <" + u + "@localhost>"
        None => "Unknown <unknown@localhost>"
      }
  }
  // Use GIT_COMMITTER_DATE if set, otherwise use current time from FFI
  let timestamp : Int64 = match @sys.get_env_var("GIT_COMMITTER_DATE") {
    Some(s) => {
      // Simple parse: expect unix timestamp as string
      let n = @strconv.parse_int64(s) catch { _ => get_current_timestamp() }
      n
    }
    None => get_current_timestamp()
  }
  let commit_id = @gitlib.commit(fs, fs, root, msg, author, timestamp)
  let short_id = (try! commit_id.to_hex()[:7]).to_string()
  let first_line = match msg.find("\n") {
    Some(idx) => (try! msg[:idx]).to_string()
    None => msg
  }
  print_line("[" + short_id + "] " + first_line)
}

///|
async fn handle_log(args : Array[String]) -> Unit raise Error {
  let root = get_work_root()
  let git_dir = root + "/.git"
  let fs = OsFs::new()
  let mut oneline = false
  let mut max_count = 10
  for arg in args {
    if arg == "--oneline" {
      oneline = true
    }
    if arg.has_prefix("-n") {
      let num_str = (try! arg[2:]).to_string()
      max_count = @strconv.parse_int(num_str)
    }
    if arg.has_prefix("--max-count=") {
      let num_str = (try! arg[12:]).to_string()
      max_count = @strconv.parse_int(num_str)
    }
  }
  if oneline {
    let lines = @gitlib.log_head_oneline(fs, git_dir, max_count~)
    for line in lines {
      print_line(line)
    }
  } else {
    let entries = @gitlib.log_head(fs, git_dir, max_count~)
    for entry in entries {
      print_line("commit " + entry.id.to_hex())
      print_line("Author: " + entry.author)
      print_line("")
      print_line("    " + entry.message)
      print_line("")
    }
  }
}

///|
async fn handle_branch(args : Array[String]) -> Unit raise Error {
  let root = get_work_root()
  let git_dir = root + "/.git"
  let fs = OsFs::new()
  let mut list_mode = true
  let mut new_branch : String? = None
  let mut delete_branch : String? = None
  let mut force_delete = false
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    if arg == "-d" || arg == "--delete" {
      if i + 1 < args.length() {
        delete_branch = Some(args[i + 1])
        list_mode = false
        i += 2
        continue
      }
    }
    if arg == "-D" {
      force_delete = true
      if i + 1 < args.length() {
        delete_branch = Some(args[i + 1])
        list_mode = false
        i += 2
        continue
      }
    }
    if not(arg.has_prefix("-")) {
      new_branch = Some(arg)
      list_mode = false
    }
    i += 1
  }
  match delete_branch {
    Some(name) => {
      @gitlib.delete_branch(fs, fs, root, name, force=force_delete)
      print_line("Deleted branch \{name}")
    }
    None =>
      match new_branch {
        Some(name) => @gitlib.create_branch(fs, fs, root, name)
        None =>
          if list_mode {
            let lines = @gitlib.list_branches_text(fs, git_dir)
            for line in lines {
              print_line(line)
            }
          }
      }
  }
}

///|
async fn handle_diff(args : Array[String]) -> Unit raise Error {
  let root = get_work_root()
  let fs = OsFs::new()
  let mut cached = false
  for arg in args {
    if arg == "--cached" || arg == "--staged" {
      cached = true
    }
  }
  let files = if cached {
    @gitlib.diff_index(fs, root)
  } else {
    @gitlib.diff_worktree(fs, root)
  }
  let lines = @gitlib.diff_text(files)
  for line in lines {
    print_line(line)
  }
}

///|
fn handle_checkout(args : Array[String]) -> Unit raise Error {
  let root = get_work_root()
  let git_dir = root + "/.git"
  let fs = OsFs::new()
  // Parse arguments: look for -- separator
  let mut saw_separator = false
  let targets : Array[String] = []
  for arg in args {
    if arg == "--" {
      saw_separator = true
      continue
    }
    if arg.has_prefix("-") {
      continue
    }
    targets.push(arg)
  }
  if targets.length() == 0 {
    raise @git.GitError::InvalidObject("No target specified for checkout")
  }
  // If -- was used, treat all targets as file paths
  if saw_separator {
    @gitlib.restore_paths(fs, fs, root, targets)
    return ()
  }
  // Single target: determine if it's a branch or file
  if targets.length() == 1 {
    let target = targets[0]
    let is_file = fs.is_file(root + "/" + target)
    let is_branch = @gitlib.resolve_ref(fs, git_dir, "refs/heads/" + target)
      is Some(_)
    if is_file && is_branch {
      // Ambiguous - default to branch (like git)
      let _ = @gitlib.checkout(fs, fs, root, target)

    } else if is_file {
      // Restore single file
      @gitlib.restore_paths(fs, fs, root, [target])
    } else {
      // Try as branch/commit
      let _ = @gitlib.checkout(fs, fs, root, target)

    }
  } else {
    // Multiple targets: treat as file paths
    @gitlib.restore_paths(fs, fs, root, targets)
  }
}

///|
async fn handle_fetch(args : Array[String]) -> Unit raise Error {
  let root = get_work_root()
  let git_dir = root + "/.git"
  let fs = OsFs::new()
  // Read remote URL from config (simple parsing)
  let config_path = git_dir + "/config"
  let mut remote_url : String? = None
  if fs.is_file(config_path) {
    let config_content = decode_bytes(fs.read_file(config_path))
    let mut in_remote_section = false
    for line_view in config_content.split("\n") {
      let line = trim_string(line_view.to_string())
      if line.has_prefix("[remote ") {
        in_remote_section = true
        continue
      }
      if line.has_prefix("[") {
        in_remote_section = false
        continue
      }
      if in_remote_section && line.has_prefix("url = ") {
        remote_url = Some(
          String::unsafe_substring(line, start=6, end=line.length()),
        )
        break
      }
    }
  }
  // Override with command line argument
  for arg in args {
    if not(arg.has_prefix("-")) {
      remote_url = Some(arg)
      break
    }
  }
  guard remote_url is Some(url) else {
    raise @git.GitError::InvalidObject("No remote configured")
  }
  print_line("Fetching from \{url}...")
  // Fetch refs and pack
  let (refs, _caps, _version, symrefs) = @git.discover_upload_refs_http(
    url, true,
  )
  let default_ref = @git.select_default_ref(refs, symrefs)
  match default_ref {
    None => {
      print_line("No refs to fetch")
      return ()
    }
    Some((refname, commit_id)) => {
      let pack = @git.fetch_pack_http(url, [commit_id], true)
      let objects = @git.parse_packfile(pack)
      @git.write_packfile_with_index(fs, git_dir, pack, objects)
      // Update remote tracking ref
      let remote_ref = if refname.has_prefix("refs/heads/") {
        let name = String::unsafe_substring(
          refname,
          start=11,
          end=refname.length(),
        )
        "refs/remotes/origin/" + name
      } else {
        "refs/remotes/origin/HEAD"
      }
      let remote_path = git_dir + "/" + remote_ref
      let dir = match remote_path.rev_find("/") {
        None => ""
        Some(i) => String::unsafe_substring(remote_path, start=0, end=i)
      }
      if dir.length() > 0 {
        fs.mkdir_p(dir)
      }
      fs.write_string(remote_path, commit_id.to_hex() + "\n")
      print_line("From \{url}")
      print_line(" * [new branch] \{refname} -> \{remote_ref}")
    }
  }
}

///|
async fn handle_show(args : Array[String]) -> Unit raise Error {
  let root = get_work_root()
  let git_dir = root + "/.git"
  let fs = OsFs::new()
  // Parse: git show [<commit>]
  let mut rev = "HEAD"
  for arg in args {
    if not(arg.has_prefix("-")) {
      rev = arg
      break
    }
  }
  // Resolve revision
  let id = @gitlib.rev_parse(fs, git_dir, rev)
  guard id is Some(commit_id) else {
    raise @git.GitError::InvalidObject("unknown revision: \{rev}")
  }
  // Load object
  let db = @gitlib.ObjectDb::load(fs, git_dir)
  let obj = db.get(fs, commit_id)
  guard obj is Some(o) else {
    raise @git.GitError::InvalidObject(
      "Object not found: \{commit_id.to_hex()}",
    )
  }
  if o.obj_type != @git.ObjectType::Commit {
    raise @git.GitError::InvalidObject("Not a commit: \{commit_id.to_hex()}")
  }
  // Parse commit for tree/parents
  let commit_info = @git.parse_commit(o.data)
  // Parse full commit details
  let show_info = parse_show_commit(o.data)
  // Print commit info
  print_line("commit \{commit_id.to_hex()}")
  print_line("Author: \{show_info.author}")
  print_line("Date:   \{show_info.timestamp}")
  print_line("")
  // Print message with indentation
  for line_view in show_info.message.split("\n") {
    print_line("    \{line_view.to_string()}")
  }
  print_line("")
  // Show diff against parent (simplified)
  if commit_info.parents.length() > 0 {
    let parent_id = commit_info.parents[0]
    let parent_files = @gitlib.collect_tree_files_from_commit(db, fs, parent_id)
    let current_files = @gitlib.collect_tree_files_from_commit(
      db, fs, commit_id,
    )
    // Show changed files
    for item in current_files.to_array() {
      let (path, entry) = item
      match parent_files.get(path) {
        None => print_line("diff --git a/\{path} b/\{path}\nnew file")
        Some(parent_entry) =>
          if entry.id != parent_entry.id {
            print_line("diff --git a/\{path} b/\{path}")
          }
      }
    }
    for item in parent_files.to_array() {
      let (path, _) = item
      if not(current_files.contains(path)) {
        print_line("diff --git a/\{path} b/\{path}\ndeleted file")
      }
    }
  }
}

///|
async fn handle_pull(args : Array[String]) -> Unit raise Error {
  let root = get_work_root()
  let git_dir = root + "/.git"
  let fs = OsFs::new()
  // Read remote URL from config
  let config_path = git_dir + "/config"
  let mut remote_url : String? = None
  if fs.is_file(config_path) {
    let config_content = decode_bytes(fs.read_file(config_path))
    let mut in_remote_section = false
    for line_view in config_content.split("\n") {
      let line = trim_string(line_view.to_string())
      if line.has_prefix("[remote ") {
        in_remote_section = true
        continue
      }
      if line.has_prefix("[") {
        in_remote_section = false
        continue
      }
      if in_remote_section && line.has_prefix("url = ") {
        remote_url = Some(
          String::unsafe_substring(line, start=6, end=line.length()),
        )
        break
      }
    }
  }
  // Override with command line argument
  let mut rebase = false
  for arg in args {
    if arg == "--rebase" || arg == "-r" {
      rebase = true
      continue
    }
    if not(arg.has_prefix("-")) {
      remote_url = Some(arg)
      break
    }
  }
  guard remote_url is Some(url) else {
    raise @git.GitError::InvalidObject("No remote configured")
  }
  print_line("Pulling from \{url}...")
  let result = @gitlib.pull_http(fs, fs, root, url, true, rebase~)
  match result {
    None => print_line("Already up to date.")
    Some(id) => print_line("Updated to \{id.to_hex()}")
  }
}

///|
fn handle_reset(args : Array[String]) -> Unit raise Error {
  let root = get_work_root()
  let fs = OsFs::new()
  let mut mode : @gitlib.ResetMode = @gitlib.ResetMode::Mixed
  let mut rev = "HEAD"
  for arg in args {
    if arg == "--soft" {
      mode = @gitlib.ResetMode::Soft
      continue
    }
    if arg == "--mixed" {
      mode = @gitlib.ResetMode::Mixed
      continue
    }
    if arg == "--hard" {
      mode = @gitlib.ResetMode::Hard
      continue
    }
    if not(arg.has_prefix("-")) {
      rev = arg
    }
  }
  let commit_id = @gitlib.reset(fs, fs, root, rev, mode)
  let short_id = String::unsafe_substring(commit_id.to_hex(), start=0, end=7)
  println("HEAD is now at \{short_id}")
}

///|
async fn handle_merge(args : Array[String]) -> Unit raise Error {
  let root = get_work_root()
  let git_dir = root + "/.git"
  let fs = OsFs::new()
  let mut target_ref : String? = None
  let mut message : String? = None
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    if arg == "-m" && i + 1 < args.length() {
      message = Some(args[i + 1])
      i += 2
      continue
    }
    if arg.has_prefix("-m") {
      message = Some((try! arg[2:]).to_string())
      i += 1
      continue
    }
    if not(arg.has_prefix("-")) {
      target_ref = Some(arg)
    }
    i += 1
  }
  guard target_ref is Some(refspec) else {
    raise @git.GitError::InvalidObject("No commit to merge specified")
  }
  // Resolve target
  let target_id = @gitlib.rev_parse(fs, git_dir, refspec)
  guard target_id is Some(tid) else {
    raise @git.GitError::InvalidObject("unknown revision: \{refspec}")
  }
  let author = match @sys.get_env_var("GIT_AUTHOR_NAME") {
    Some(name) => {
      let email = @sys.get_env_var("GIT_AUTHOR_EMAIL").unwrap_or("unknown")
      name + " <" + email + ">"
    }
    None =>
      match @sys.get_env_var("USER") {
        Some(u) => u + " <" + u + "@localhost>"
        None => "Unknown <unknown@localhost>"
      }
  }
  let timestamp = match @sys.get_env_var("GIT_COMMITTER_DATE") {
    Some(s) => @strconv.parse_int64(s) catch { _ => get_current_timestamp() }
    None => get_current_timestamp()
  }
  let msg = message.unwrap_or("Merge \{refspec}")
  let result = @gitlib.merge(fs, fs, root, tid, msg, author, timestamp)
  match result.status {
    @gitlib.MergeStatus::AlreadyUpToDate => print_line("Already up to date.")
    @gitlib.MergeStatus::FastForward =>
      match result.commit_id {
        Some(id) => {
          let short = String::unsafe_substring(id.to_hex(), start=0, end=7)
          print_line("Fast-forward to \{short}")
        }
        None => print_line("Fast-forward")
      }
    @gitlib.MergeStatus::Merged =>
      match result.commit_id {
        Some(id) => {
          let short = String::unsafe_substring(id.to_hex(), start=0, end=7)
          print_line("Merge made by the 'ort' strategy. [\{short}]")
        }
        None => print_line("Merged")
      }
    @gitlib.MergeStatus::Conflicted => {
      print_line("CONFLICT (content): Merge conflict in the following files:")
      for path in result.conflicts {
        print_line("  \{path}")
      }
      print_line("Automatic merge failed; fix conflicts and then commit.")
    }
  }
}

///|
fn handle_switch(args : Array[String]) -> Unit raise Error {
  let root = get_work_root()
  let fs = OsFs::new()
  let mut branch : String? = None
  let mut create = false
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    if arg == "-c" || arg == "--create" {
      create = true
      if i + 1 < args.length() && not(args[i + 1].has_prefix("-")) {
        branch = Some(args[i + 1])
        i += 2
        continue
      }
      i += 1
      continue
    }
    if not(arg.has_prefix("-")) {
      branch = Some(arg)
    }
    i += 1
  }
  guard branch is Some(name) else {
    raise @git.GitError::InvalidObject("No branch specified")
  }
  @gitlib.switch_branch(fs, fs, root, name, create~)
  if create {
    println("Switched to a new branch '\{name}'")
  } else {
    println("Switched to branch '\{name}'")
  }
}

///|
async fn handle_sparse_checkout(args : Array[String]) -> Unit raise Error {
  let root = get_work_root()
  let git_dir = root + "/.git"
  let fs = OsFs::new()
  if args.length() == 0 {
    raise @git.GitError::InvalidObject(
      "usage: git sparse-checkout <init|set|add|list|disable>",
    )
  }
  let subcmd = args[0]
  let rest = if args.length() > 1 {
    let arr : Array[String] = []
    for i in 1..<args.length() {
      arr.push(args[i])
    }
    arr
  } else {
    []
  }
  match subcmd {
    "init" => {
      let cone = rest.contains("--cone")
      @gitlib.sparse_checkout_init(fs, fs, root, cone~)
      print_line("Sparse checkout initialized")
    }
    "set" => {
      let patterns : Array[String] = []
      for arg in rest {
        if not(arg.has_prefix("-")) {
          patterns.push(arg)
        }
      }
      if patterns.length() == 0 {
        raise @git.GitError::InvalidObject("patterns required for set")
      }
      @gitlib.sparse_checkout_set(fs, fs, root, patterns)
      print_line("Sparse checkout patterns set")
    }
    "add" => {
      let patterns : Array[String] = []
      for arg in rest {
        if not(arg.has_prefix("-")) {
          patterns.push(arg)
        }
      }
      if patterns.length() == 0 {
        raise @git.GitError::InvalidObject("patterns required for add")
      }
      @gitlib.sparse_checkout_add(fs, fs, root, patterns)
      print_line("Sparse checkout patterns added")
    }
    "list" => {
      let patterns = @gitlib.read_sparse_patterns(fs, git_dir)
      for p in patterns {
        print_line(p)
      }
    }
    "disable" => {
      @gitlib.sparse_checkout_disable(fs, fs, root)
      print_line("Sparse checkout disabled")
    }
    _ =>
      raise @git.GitError::InvalidObject(
        "unknown sparse-checkout subcommand: \{subcmd}",
      )
  }
}

///|
async fn handle_config(args : Array[String]) -> Unit raise Error {
  let root = get_work_root()
  let git_dir = root + "/.git"
  let fs = OsFs::new()
  let config_path = git_dir + "/config"
  // Parse arguments
  let mut get_mode = false
  let mut get_bool = false
  let mut key : String? = None
  let mut value : String? = None
  for arg in args {
    if arg == "--get" {
      get_mode = true
      continue
    }
    if arg == "--bool" {
      get_bool = true
      continue
    }
    if arg.has_prefix("-") {
      continue
    }
    if key is None {
      key = Some(arg)
    } else if value is None {
      value = Some(arg)
    }
  }
  guard key is Some(k) else {
    raise @git.GitError::InvalidObject("key required")
  }
  if get_mode || value is None {
    // Read config
    if not(fs.is_file(config_path)) {
      raise @git.GitError::InvalidObject("config not found")
    }
    let content = decode_bytes(fs.read_file(config_path))
    let parts = k.split(".")
    let parts_arr : Array[String] = []
    for p in parts {
      parts_arr.push(p.to_string())
    }
    if parts_arr.length() != 2 {
      raise @git.GitError::InvalidObject("invalid key format")
    }
    let section = parts_arr[0]
    let name = parts_arr[1]
    let mut in_section = false
    for line_view in content.split("\n") {
      let line = trim_string(line_view.to_string())
      if line.has_prefix("[") && line.has_suffix("]") {
        let sec_name = String::unsafe_substring(
          line,
          start=1,
          end=line.length() - 1,
        )
        in_section = sec_name == section ||
          sec_name.has_prefix(section + " ") ||
          sec_name.has_prefix(section + "\t")
        continue
      }
      if in_section && line.has_prefix(name + " = ") {
        let val = String::unsafe_substring(
          line,
          start=name.length() + 3,
          end=line.length(),
        )
        if get_bool {
          if val == "true" || val == "1" {
            print_line("true")
          } else {
            print_line("false")
          }
        } else {
          print_line(val)
        }
        return
      }
      if in_section && line.has_prefix(name + "=") {
        let val = String::unsafe_substring(
          line,
          start=name.length() + 1,
          end=line.length(),
        )
        if get_bool {
          if val == "true" || val == "1" {
            print_line("true")
          } else {
            print_line("false")
          }
        } else {
          print_line(val)
        }
        return
      }
    }
    // Key not found
    raise @git.GitError::InvalidObject("key not found: " + k)
  } else {
    // Write config - fallback to system git for now
    raise @git.GitError::InvalidObject("config write not implemented")
  }
}

///|
async fn handle_rev_parse(args : Array[String]) -> Unit raise Error {
  let root = get_work_root()
  let git_dir = root + "/.git"
  let fs = OsFs::new()
  for arg in args {
    if arg == "--git-dir" {
      print_line(git_dir)
      continue
    }
    if arg == "--show-toplevel" {
      let abs = if root == "." {
        match @sys.get_env_var("PWD") {
          Some(pwd) => pwd
          None => root
        }
      } else {
        root
      }
      print_line(abs)
      continue
    }
    if arg.has_prefix("-") {
      continue
    }
    let id = @gitlib.rev_parse(fs, git_dir, arg)
    match id {
      Some(oid) => print_line(oid.to_hex())
      None => raise @git.GitError::InvalidObject("unknown revision: " + arg)
    }
  }
}

///|
async fn main_async() -> Unit {
  let args = @sys.get_cli_args()
  if args.length() < 2 {
    eprint_line("git-shim: missing subcommand")
    @sys.exit(2)
  }
  // Handle --version early
  if args.length() >= 2 && (args[1] == "--version" || args[1] == "version") {
    print_line("git version 2.47.0 (git-shim)")
    return ()
  }
  let full_args = collect_args(args, 1)
  let mut i = 1
  let mut in_opts = true
  let mut cwd : String? = None
  let mut unsupported_global = false
  let mut subcmd : String? = None
  let mut rest : Array[String] = []
  while i < args.length() {
    let arg = args[i]
    if in_opts && arg == "--" {
      in_opts = false
      i += 1
      continue
    }
    if in_opts && arg == "-C" {
      if i + 1 >= args.length() {
        run_system_git(full_args)
      }
      let raw = args[i + 1]
      let resolved = if raw.has_prefix("/") {
        raw
      } else {
        match @sys.get_env_var("GIT_SHIM_PWD") {
          None => raw
          Some(base) => base + "/" + raw
        }
      }
      cwd = Some(resolved)
      i += 2
      continue
    }
    if in_opts && arg == "-c" {
      unsupported_global = true
      if i + 1 >= args.length() {
        run_system_git(full_args)
      }
      i += 2
      continue
    }
    if in_opts &&
      (
        arg == "--git-dir" ||
        arg == "--work-tree" ||
        arg == "--namespace" ||
        arg == "--super-prefix" ||
        arg == "--git-path"
      ) {
      unsupported_global = true
      if i + 1 >= args.length() {
        run_system_git(full_args)
      }
      i += 2
      continue
    }
    if in_opts &&
      (
        arg.has_prefix("--git-dir=") ||
        arg.has_prefix("--work-tree=") ||
        arg.has_prefix("--namespace=") ||
        arg.has_prefix("--super-prefix=") ||
        arg.has_prefix("--git-path=")
      ) {
      unsupported_global = true
      i += 1
      continue
    }
    if in_opts && arg.has_prefix("-") {
      i += 1
      continue
    }
    subcmd = Some(arg)
    rest = collect_args(args, i + 1)
    break
  }
  match subcmd {
    None => {
      eprint_line("git-shim: missing subcommand")
      @sys.exit(2)
    }
    Some(cmd) => {
      if unsupported_global {
        run_system_git(full_args)
      }
      match cwd {
        None => ()
        Some(dir) => {
          @sys.set_env_var("GIT_SHIM_CWD", dir)
          if @sys.get_env_var("GIT_DIR") is None {
            @sys.set_env_var("GIT_DIR", dir + "/.git")
          }
          if @sys.get_env_var("GIT_WORK_TREE") is None {
            @sys.set_env_var("GIT_WORK_TREE", dir)
          }
        }
      }
      let subcmd = cmd
      match subcmd {
        "receive-pack" =>
          handle_receive_pack(rest) catch {
            err => {
              eprint_line("receive-pack failed: " + err.to_string())
              @sys.exit(1)
            }
          }
        "git-receive-pack" =>
          handle_receive_pack(rest) catch {
            err => {
              eprint_line("receive-pack failed: " + err.to_string())
              @sys.exit(1)
            }
          }
        "pack-objects" =>
          handle_pack_objects(rest) catch {
            err => {
              eprint_line("pack-objects failed: " + err.to_string())
              @sys.exit(1)
            }
          }
        "index-pack" =>
          handle_index_pack(rest) catch {
            err => {
              eprint_line("index-pack failed: " + err.to_string())
              @sys.exit(1)
            }
          }
        "upload-pack" =>
          handle_upload_pack(rest) catch {
            err => {
              eprint_line("upload-pack failed: " + err.to_string())
              @sys.exit(1)
            }
          }
        "git-upload-pack" =>
          handle_upload_pack(rest) catch {
            err => {
              eprint_line("upload-pack failed: " + err.to_string())
              @sys.exit(1)
            }
          }
        "clone" =>
          handle_clone(rest) catch {
            err => {
              eprint_line("clone failed: " + err.to_string())
              @sys.exit(1)
            }
          }
        "fetch" =>
          handle_fetch(rest) catch {
            err => {
              eprint_line("fetch failed: " + err.to_string())
              @sys.exit(1)
            }
          }
        "init" =>
          handle_init(rest) catch {
            err => {
              eprint_line("init failed: " + err.to_string())
              @sys.exit(1)
            }
          }
        "status" =>
          handle_status(rest) catch {
            err => {
              eprint_line("status failed: " + err.to_string())
              @sys.exit(1)
            }
          }
        "add" =>
          handle_add(rest) catch {
            err => {
              eprint_line("add failed: " + err.to_string())
              @sys.exit(1)
            }
          }
        "commit" =>
          handle_commit(rest) catch {
            err => {
              eprint_line("commit failed: " + err.to_string())
              @sys.exit(1)
            }
          }
        "log" =>
          handle_log(rest) catch {
            err => {
              eprint_line("log failed: " + err.to_string())
              @sys.exit(1)
            }
          }
        "show" =>
          handle_show(rest) catch {
            err => {
              eprint_line("show failed: " + err.to_string())
              @sys.exit(1)
            }
          }
        "branch" =>
          handle_branch(rest) catch {
            _ => run_system_git(prepend_arg("branch", rest))
          }
        "diff" =>
          handle_diff(rest) catch {
            err => {
              eprint_line("diff failed: " + err.to_string())
              @sys.exit(1)
            }
          }
        "checkout" =>
          handle_checkout(rest) catch {
            _ => run_system_git(prepend_arg("checkout", rest))
          }
        "pull" =>
          handle_pull(rest) catch {
            err => {
              eprint_line("pull failed: " + err.to_string())
              @sys.exit(1)
            }
          }
        "reset" =>
          handle_reset(rest) catch {
            err => {
              eprint_line("reset failed: " + err.to_string())
              @sys.exit(1)
            }
          }
        "merge" =>
          handle_merge(rest) catch {
            _ => run_system_git(prepend_arg("merge", rest))
          }
        "switch" =>
          handle_switch(rest) catch {
            _ => run_system_git(prepend_arg("switch", rest))
          }
        "rev-parse" =>
          handle_rev_parse(rest) catch {
            _ => run_system_git(prepend_arg("rev-parse", rest))
          }
        "version" | "--version" => print_line("git version 2.47.0 (git-shim)")
        "config" =>
          handle_config(rest) catch {
            _ => run_system_git(prepend_arg("config", rest))
          }
        "sparse-checkout" =>
          handle_sparse_checkout(rest) catch {
            err => {
              eprint_line("sparse-checkout failed: " + err.to_string())
              @sys.exit(1)
            }
          }
        _ => run_system_git(prepend_arg(subcmd, rest))
      }
    }
  }
}

///|
fn main {
  @async.run_async_main(main_async)
}

///|
fn resolve_real_git_for_blame() -> String {
  match @sys.get_env_var("SHIM_REAL_GIT") {
    Some(path) =>
      if path.length() > 0 {
        path
      } else {
        @sys.get_env_var("GIT_SHIM_REAL_GIT").unwrap_or("/usr/bin/git")
      }
    None => @sys.get_env_var("GIT_SHIM_REAL_GIT").unwrap_or("/usr/bin/git")
  }
}

///|
async fn delegate_blame_to_real_git(args : Array[String], cwd : String) -> Unit {
  if git_fallback_disabled() {
    exit_no_git_fallback("git blame")
  }
  let argv : Array[String] = ["blame"]
  for arg in args {
    argv.push(arg)
  }
  let code = @process.run(
    resolve_real_git_for_blame(),
    argv,
    inherit_env=true,
    cwd~,
    stdin=@stdio.stdin,
    stdout=@stdio.stdout,
    stderr=@stdio.stderr,
  )
  @sys.exit(code)
}

///|
fn blame_builtin_supports_args(
  fs : &@bitcore.RepoFileSystem,
  root : String,
  args : Array[String],
) -> Bool {
  if !fs.is_dir(root + "/.git") {
    return false
  }
  let mut saw_double_dash = false
  let mut positional_count = 0
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    if saw_double_dash {
      positional_count += 1
      i += 1
      continue
    }
    match arg {
      "-l"
      | "--incremental"
      | "-w"
      | "-M"
      | "-C"
      | "--textconv"
      | "--no-textconv" => i += 1
      "-L" => {
        if i + 1 >= args.length() {
          return false
        }
        i += 2
      }
      "--" => {
        saw_double_dash = true
        i += 1
      }
      _ if arg.has_prefix("-L") => i += 1
      _ if arg.has_prefix("-") => return false
      _ => {
        positional_count += 1
        i += 1
      }
    }
  }
  positional_count == 1
}

///|
fn blame_read_path_diff_driver(
  fs : &@bitcore.RepoFileSystem,
  root : String,
  path : String,
) -> String? {
  let normalized = if path.has_prefix("/") {
    String::unsafe_substring(path, start=1, end=path.length())
  } else if path.has_prefix("./") {
    String::unsafe_substring(path, start=2, end=path.length())
  } else {
    path
  }
  let attr_path = root + "/.gitattributes"
  if !fs.is_file(attr_path) {
    return None
  }
  let text = decode_bytes(
    fs.read_file(attr_path) catch {
      _ => Default::default()
    },
  )
  let mut diff_driver : String? = None
  for line_view in text.split("\n") {
    let line = trim_string(line_view.to_owned())
    if line.length() == 0 || line.has_prefix("#") {
      continue
    }
    let tokens = line.split(" ")
    let words : Array[String] = []
    for token_view in tokens {
      let token = trim_string(token_view.to_owned())
      if token.length() > 0 {
        words.push(token)
      }
    }
    if words.length() < 2 {
      continue
    }
    if !cat_file_attr_pattern_matches(normalized, words[0]) {
      continue
    }
    let mut j = 1
    while j < words.length() {
      let token = words[j]
      if token.has_prefix("diff=") {
        let value = trim_string(
          String::unsafe_substring(token, start=5, end=token.length()),
        )
        if value.length() > 0 {
          diff_driver = Some(value)
        }
      }
      j += 1
    }
  }
  diff_driver
}

///|
fn blame_resolve_textconv_command(
  fs : &@bitcore.RepoFileSystem,
  root : String,
  git_dir : String,
  path : String,
) -> String? {
  match blame_read_path_diff_driver(fs, root, path) {
    Some(driver) => {
      let config_path = git_dir + "/config"
      let section = "diff \"" + driver + "\""
      match @bitlib.read_config_value(fs, config_path, section, "textconv") {
        Some(cmd) => {
          let trimmed = trim_string(cmd)
          if trimmed.length() > 0 {
            Some(trimmed)
          } else {
            None
          }
        }
        None => None
      }
    }
    None => None
  }
}

///|
fn blame_effective_textconv_command(
  fs : &@bitcore.RepoFileSystem,
  root : String,
  git_dir : String,
  path : String,
  textconv_override : Bool?,
) -> String? {
  match textconv_override {
    Some(enabled) =>
      if enabled {
        blame_resolve_textconv_command(fs, root, git_dir, path)
      } else {
        None
      }
    None => blame_resolve_textconv_command(fs, root, git_dir, path)
  }
}

///|
fn blame_config_get(
  fs : &@bitcore.RepoFileSystem,
  git_dir : String,
  section : String,
  key : String,
) -> String? {
  let content = fs.read_file(git_dir + "/config") catch { _ => return None }
  let content = decode_bytes(content)
  @config_parse.get_config_value_from_content(
    content,
    section + "." + key,
    None,
    false,
  )
}

///|
fn blame_repo_prefers_real_git(
  fs : &@bitcore.RepoFileSystem,
  git_dir : String,
) -> Bool {
  match blame_config_get(fs, git_dir, "blame", "showEmail") {
    Some(value) => {
      let normalized = trim_string(value).to_lower()
      normalized.length() == 0 ||
      normalized == "true" ||
      normalized == "yes" ||
      normalized == "on" ||
      normalized == "1"
    }
    None => false
  }
}

///|
fn blame_repo_requires_real_git(
  fs : &@bitcore.RepoFileSystem,
  root : String,
  git_dir : String,
  args : Array[String],
) -> Bool {
  if !blame_builtin_supports_args(fs, root, args) {
    return true
  }
  if blame_repo_prefers_real_git(fs, git_dir) {
    return true
  }
  false
}

///|
async fn handle_blame(args : Array[String]) -> Unit raise Error {
  let root = get_work_root()
  let git_dir = root + "/.git"
  let fs = OsFs::new()
  let rfs : &@bitcore.RepoFileSystem = fs
  if blame_repo_requires_real_git(rfs, root, git_dir, args) {
    delegate_blame_to_real_git(args, root)
    return
  }
  // Parse options
  let mut long_sha = false
  let mut porcelain = false
  let mut incremental = false
  let mut ignore_whitespace = false
  let mut detect_moves = false
  let mut detect_copies = false
  let mut textconv_override : Bool? = None
  let mut line_start = 0
  let mut line_end = 0
  let mut commit_ref = "HEAD"
  let positionals : Array[String] = []
  let mut saw_double_dash = false
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    match arg {
      "-l" => {
        long_sha = true
        i += 1
      }
      "--porcelain" | "-p" => {
        porcelain = true
        i += 1
      }
      "--incremental" => {
        incremental = true
        i += 1
      }
      "-w" => {
        ignore_whitespace = true
        i += 1
      }
      "-M" => {
        detect_moves = true
        i += 1
      }
      "-C" => {
        detect_copies = true
        i += 1
      }
      "--textconv" => {
        textconv_override = Some(true)
        i += 1
      }
      "--no-textconv" => {
        textconv_override = Some(false)
        i += 1
      }
      "-L" if i + 1 < args.length() => {
        let range = args[i + 1]
        let parsed = parse_line_range(range)
        line_start = parsed.0
        line_end = parsed.1
        i += 2
      }
      _ if arg.has_prefix("-L") => {
        let range = String::unsafe_substring(arg, start=2, end=arg.length())
        let parsed = parse_line_range(range)
        line_start = parsed.0
        line_end = parsed.1
        i += 1
      }
      "--" => {
        saw_double_dash = true
        i += 1
      }
      _ if saw_double_dash || !arg.has_prefix("-") => {
        positionals.push(arg)
        i += 1
      }
      _ => i += 1
    }
  }
  let file_path = match positionals.length() {
    0 => None
    1 => Some(positionals[0])
    _ => {
      commit_ref = positionals[0]
      Some(positionals[positionals.length() - 1])
    }
  }
  guard file_path is Some(path) else {
    @stdio.stderr.write("fatal: no file specified")
    @sys.exit(128)
  }
  // Get blame info
  let blame_opts = BlameOptions::new(
    ignore_whitespace, detect_moves, detect_copies,
  )
  let textconv_command = blame_effective_textconv_command(
    rfs, root, git_dir, path, textconv_override,
  )
  let blame_lines = compute_blame_with_opts(
    fs, rfs, git_dir, root, commit_ref, path, blame_opts, textconv_command,
  )
  // Apply line range filter
  let filtered = if line_start > 0 {
    let end_val = if line_end > 0 { line_end } else { blame_lines.length() }
    let end_clamped = if end_val < blame_lines.length() {
      end_val
    } else {
      blame_lines.length()
    }
    let result : Array[BlameLine] = []
    for idx in (line_start - 1)..<end_clamped {
      result.push(blame_lines[idx])
    }
    result
  } else {
    blame_lines
  }
  // Output
  if incremental {
    output_blame_incremental(filtered)
  } else if porcelain {
    output_blame_porcelain(filtered)
  } else {
    output_blame_standard(filtered, long_sha)
  }
}

///|
struct BlameOptions {
  ignore_whitespace : Bool
  detect_moves : Bool
  detect_copies : Bool
}

///|
fn BlameOptions::new(
  ignore_whitespace : Bool,
  detect_moves : Bool,
  detect_copies : Bool,
) -> BlameOptions {
  { ignore_whitespace, detect_moves, detect_copies }
}

///|
struct BlameLine {
  commit_id : @bitcore.ObjectId
  author : String
  author_time : Int64
  author_tz : String
  line_no : Int
  content : String
  is_boundary : Bool
}

///|
fn BlameLine::new(
  commit_id : @bitcore.ObjectId,
  author : String,
  author_time : Int64,
  author_tz : String,
  line_no : Int,
  content : String,
  is_boundary : Bool,
) -> BlameLine {
  { commit_id, author, author_time, author_tz, line_no, content, is_boundary }
}

///|
fn parse_line_range(range : String) -> (Int, Int) {
  // Parse "start,end" format
  match range.find(",") {
    Some(idx) => {
      let start_str = String::unsafe_substring(range, start=0, end=idx)
      let end_str = String::unsafe_substring(
        range,
        start=idx + 1,
        end=range.length(),
      )
      (parse_int(start_str), parse_int(end_str))
    }
    None => (parse_int(range), 0)
  }
}

///|
async fn compute_blame_with_opts(
  fs : OsFs,
  rfs : &@bitcore.RepoFileSystem,
  git_dir : String,
  root : String,
  commit_ref : String,
  file_path : String,
  opts : BlameOptions,
  textconv_command : String?,
) -> Array[BlameLine] raise Error {
  let db = @bitlib.ObjectDb::load(rfs, git_dir)
  // Get target commit
  let target_id = @bitrepo.rev_parse(rfs, git_dir, commit_ref)
  guard target_id is Some(tid) else {
    raise @bitcore.GitError::InvalidObject("unknown revision: \{commit_ref}")
  }
  // Get file content at target commit
  let file_content = blame_get_file_at_commit_for_display(
    fs, db, rfs, root, git_dir, tid, file_path, textconv_command,
  )
  guard file_content is Some(content) else {
    raise @bitcore.GitError::InvalidObject("file not found: \{file_path}")
  }
  let lines = split_lines(content)
  if lines.length() == 0 {
    return []
  }
  // Build commit history for this file
  let history = build_file_history(db, rfs, tid, file_path)
  // For -M/-C: also collect other files in commits
  let other_files : Map[String, Array[(String, @bitcore.ObjectId)]] = Map([])
  if opts.detect_moves || opts.detect_copies {
    collect_other_files(db, rfs, history, file_path, other_files)
  }
  // Attribute each line to a commit
  let result : Array[BlameLine] = []
  for line_idx in 0..<lines.length() {
    let line = lines[line_idx]
    let blame = blame_find_line_origin_with_opts(
      fs, db, rfs, root, git_dir, history, file_path, line, line_idx, opts, other_files,
      textconv_command,
    )
    result.push(
      BlameLine::new(
        blame.0,
        blame.1,
        blame.2,
        blame.3,
        line_idx + 1,
        line,
        blame.4,
      ),
    )
  }
  result
}

///|
fn collect_other_files(
  db : @bitlib.ObjectDb,
  rfs : &@bitcore.RepoFileSystem,
  history : Array[@bitcore.ObjectId],
  exclude_path : String,
  result : Map[String, Array[(String, @bitcore.ObjectId)]],
) -> Unit {
  for commit_id in history {
    let obj = db.get(rfs, commit_id) catch { _ => continue }
    guard obj is Some(o) else { continue }
    let info = @bitcore.parse_commit(o.data) catch { _ => continue }
    let files = collect_files_in_tree(db, rfs, info.tree, "") catch {
      _ => continue
    }
    for file_entry in files {
      let (path, blob_id) = file_entry
      if path != exclude_path {
        let hex = commit_id.to_hex()
        match result.get(hex) {
          Some(arr) => arr.push((path, blob_id))
          None => result[hex] = [(path, blob_id)]
        }
      }
    }
  }
}

///|
fn collect_files_in_tree(
  db : @bitlib.ObjectDb,
  rfs : &@bitcore.RepoFileSystem,
  tree_id : @bitcore.ObjectId,
  prefix : String,
) -> Array[(String, @bitcore.ObjectId)] raise Error {
  let result : Array[(String, @bitcore.ObjectId)] = []
  let tree_obj = db.get(rfs, tree_id)
  guard tree_obj is Some(to) else { return result }
  let entries = @bitcore.parse_tree(to.data)
  for entry in entries {
    let path = if prefix.length() > 0 {
      prefix + "/" + entry.name
    } else {
      entry.name
    }
    if entry.mode.has_prefix("100") {
      // Regular file
      result.push((path, entry.id))
    } else if entry.mode == "40000" {
      // Directory - recurse
      let sub_files = collect_files_in_tree(db, rfs, entry.id, path)
      for f in sub_files {
        result.push(f)
      }
    }
  }
  result
}

///|
async fn blame_get_file_at_commit_for_display(
  fs : OsFs,
  db : @bitlib.ObjectDb,
  rfs : &@bitcore.RepoFileSystem,
  root : String,
  git_dir : String,
  commit_id : @bitcore.ObjectId,
  file_path : String,
  textconv_command : String?,
) -> String? raise Error {
  let data = get_file_blob_at_commit(db, rfs, commit_id, file_path)
  guard data is Some(blob_data) else { return None }
  let display_data = match textconv_command {
    Some(command) =>
      cat_file_run_textconv(fs, root, git_dir, command, blob_data)
    None => blob_data
  }
  display_data |> decode_bytes |> Some
}

///|
fn get_file_at_commit(
  db : @bitlib.ObjectDb,
  rfs : &@bitcore.RepoFileSystem,
  commit_id : @bitcore.ObjectId,
  file_path : String,
) -> String? raise Error {
  let data = get_file_blob_at_commit(db, rfs, commit_id, file_path)
  match data {
    Some(blob_data) => blob_data |> decode_bytes |> Some
    None => None
  }
}

///|
fn get_file_blob_at_commit(
  db : @bitlib.ObjectDb,
  rfs : &@bitcore.RepoFileSystem,
  commit_id : @bitcore.ObjectId,
  file_path : String,
) -> Bytes? raise Error {
  let obj = db.get(rfs, commit_id)
  guard obj is Some(o) else { return None }
  let info = @bitcore.parse_commit(o.data)
  // Walk tree to find file
  let blob_id = find_blob_in_tree(db, rfs, info.tree, file_path)
  guard blob_id is Some(bid) else { return None }
  let blob = db.get(rfs, bid)
  guard blob is Some(b) else { return None }
  Some(b.data)
}

///|
fn find_blob_in_tree(
  db : @bitlib.ObjectDb,
  rfs : &@bitcore.RepoFileSystem,
  tree_id : @bitcore.ObjectId,
  path : String,
) -> @bitcore.ObjectId? raise Error {
  let tree_obj = db.get(rfs, tree_id)
  guard tree_obj is Some(to) else { return None }
  let entries = @bitcore.parse_tree(to.data)
  // Split path into components
  let parts = split_path(path)
  if parts.length() == 0 {
    return None
  }
  let first = parts[0]
  for entry in entries {
    if entry.name == first {
      if parts.length() == 1 {
        // Found the file
        return Some(entry.id)
      } else {
        // Need to traverse subtree
        let rest = join_path(parts, 1)
        return find_blob_in_tree(db, rfs, entry.id, rest)
      }
    }
  }
  None
}

///|
fn split_path(path : String) -> Array[String] {
  let result : Array[String] = []
  let mut start_pos = 0
  for i in 0..<path.length() {
    if path[i] == '/' {
      if i > start_pos {
        result.push(String::unsafe_substring(path, start=start_pos, end=i))
      }
      start_pos = i + 1
    }
  }
  if start_pos < path.length() {
    result.push(
      String::unsafe_substring(path, start=start_pos, end=path.length()),
    )
  }
  result
}

///|
fn join_path(parts : Array[String], start_idx : Int) -> String {
  let result : Array[String] = []
  for i in start_idx..<parts.length() {
    result.push(parts[i])
  }
  result.join("/")
}

///|
fn split_lines(content : String) -> Array[String] {
  let result : Array[String] = []
  for line_view in content.split("\n") {
    result.push(line_view.to_owned())
  }
  // Remove trailing empty line if content ends with newline
  if result.length() > 0 && result[result.length() - 1] == "" {
    ignore(result.pop())
  }
  result
}

///|
fn build_file_history(
  db : @bitlib.ObjectDb,
  rfs : &@bitcore.RepoFileSystem,
  start : @bitcore.ObjectId,
  file_path : String,
) -> Array[@bitcore.ObjectId] raise Error {
  // Walk commit history, collecting commits that touch the file
  let result : Array[@bitcore.ObjectId] = []
  let visited : Map[String, Bool] = Map([])
  let queue : Array[@bitcore.ObjectId] = [start]
  while queue.length() > 0 {
    let current = queue.pop()
    guard current is Some(cid) else { break }
    let hex = cid.to_hex()
    if visited.get(hex).unwrap_or(false) {
      continue
    }
    visited[hex] = true
    // Check if file exists at this commit
    let content = get_file_at_commit(db, rfs, cid, file_path)
    if content is Some(_) {
      result.push(cid)
    }
    // Add parents
    let obj = db.get(rfs, cid)
    match obj {
      Some(o) => {
        let info = @bitcore.parse_commit(o.data)
        for p in info.parents {
          queue.push(p)
        }
      }
      None => ()
    }
  }
  result
}

///|
async fn blame_find_line_origin_with_opts(
  fs : OsFs,
  db : @bitlib.ObjectDb,
  rfs : &@bitcore.RepoFileSystem,
  root : String,
  git_dir : String,
  history : Array[@bitcore.ObjectId],
  file_path : String,
  line : String,
  _line_idx : Int,
  opts : BlameOptions,
  other_files : Map[String, Array[(String, @bitcore.ObjectId)]],
  textconv_command : String?,
) -> (@bitcore.ObjectId, String, Int64, String, Bool) raise Error {
  // Find oldest commit in history that contains this line
  let mut best_commit = history[0]
  let mut is_boundary = false
  let compare_line = if opts.ignore_whitespace {
    normalize_whitespace(line)
  } else {
    line
  }
  for i in 0..<history.length() {
    let commit_id = history[i]
    let content = blame_get_file_at_commit_for_display(
      fs, db, rfs, root, git_dir, commit_id, file_path, textconv_command,
    )
    match content {
      Some(c) => {
        let lines = split_lines(c)
        let mut found = false
        for l in lines {
          let compare_l = if opts.ignore_whitespace {
            normalize_whitespace(l)
          } else {
            l
          }
          if compare_l == compare_line {
            found = true
            break
          }
        }
        if found {
          best_commit = commit_id
          // Check if this is the first commit (boundary)
          if i == history.length() - 1 {
            is_boundary = true
          }
        } else {
          // Line doesn't exist in this commit
          // For -M/-C: check other files in this commit
          if opts.detect_moves || opts.detect_copies {
            let hex = commit_id.to_hex()
            match other_files.get(hex) {
              Some(files) =>
                for file_entry in files {
                  let (other_path, blob_id) = file_entry
                  let other_content = get_blob_content(db, rfs, blob_id)
                  match other_content {
                    Some(oc) => {
                      let other_lines = split_lines(oc)
                      for ol in other_lines {
                        let compare_ol = if opts.ignore_whitespace {
                          normalize_whitespace(ol)
                        } else {
                          ol
                        }
                        if compare_ol == compare_line {
                          // Found in another file - attribute to this commit
                          best_commit = commit_id
                          if i == history.length() - 1 {
                            is_boundary = true
                          }
                          break
                        }
                      }
                      ignore(other_path)
                    }
                    None => ()
                  }
                }
              None => ()
            }
          }
          break
        }
      }
      None => break
    }
  }
  // Get commit info - parse author from raw data
  let obj = db.get(rfs, best_commit)
  guard obj is Some(o) else {
    return (best_commit, "unknown", 0L, "+0000", is_boundary)
  }
  // Extract author line from commit object
  let commit_text = decode_bytes(o.data)
  let author_line = extract_author_line(commit_text)
  // Parse author info
  let (author_name, author_time, author_tz) = parse_author_info(author_line)
  (best_commit, author_name, author_time, author_tz, is_boundary)
}

///|
fn normalize_whitespace(s : String) -> String {
  // Collapse all whitespace to single spaces and trim
  let result = StringBuilder::new()
  let mut in_space = true // Start true to trim leading spaces
  for c in s {
    if c == ' ' || c == '\t' {
      if !in_space {
        result.write_char(' ')
        in_space = true
      }
    } else {
      result.write_char(c)
      in_space = false
    }
  }
  // Trim trailing space
  let str = result.to_string()
  if str.length() > 0 && str[str.length() - 1] == ' ' {
    String::unsafe_substring(str, start=0, end=str.length() - 1)
  } else {
    str
  }
}

///|
fn get_blob_content(
  db : @bitlib.ObjectDb,
  rfs : &@bitcore.RepoFileSystem,
  blob_id : @bitcore.ObjectId,
) -> String? raise Error {
  let blob = db.get(rfs, blob_id)
  guard blob is Some(b) else { return None }
  b.data |> decode_bytes |> Some
}

///|
fn extract_author_line(commit_text : String) -> String {
  for line_view in commit_text.split("\n") {
    let line = line_view.to_owned()
    if line.has_prefix("author ") {
      return String::unsafe_substring(line, start=7, end=line.length())
    }
    if line.length() == 0 {
      break
    }
  }
  "unknown"
}

///|
fn parse_author_info(author : String) -> (String, Int64, String) {
  // Format: "Name <email> timestamp tz"
  match author.rev_find(">") {
    Some(email_end) => {
      let name_part = String::unsafe_substring(
        author,
        start=0,
        end=email_end + 1,
      )
      let name = match name_part.find("<") {
        Some(idx) =>
          trim_string(String::unsafe_substring(name_part, start=0, end=idx))
        None => name_part
      }
      let time_part = String::unsafe_substring(
        author,
        start=email_end + 2,
        end=author.length(),
      )
      // Parse "timestamp tz"
      match time_part.find(" ") {
        Some(space_idx) => {
          let ts_str = String::unsafe_substring(
            time_part,
            start=0,
            end=space_idx,
          )
          let tz = String::unsafe_substring(
            time_part,
            start=space_idx + 1,
            end=time_part.length(),
          )
          let timestamp = ts_str |> trim_string |> parse_int64
          (name, timestamp, trim_string(tz))
        }
        None => (name, 0L, "+0000")
      }
    }
    None => (author, 0L, "+0000")
  }
}

///|
async fn output_blame_standard(
  lines : Array[BlameLine],
  long_sha : Bool,
) -> Unit raise Error {
  // Find max author name length for alignment
  let mut max_author = 0
  for line in lines {
    if line.author.length() > max_author {
      max_author = line.author.length()
    }
  }
  // Find max line number width
  let max_line_no = if lines.length() > 0 {
    lines[lines.length() - 1].line_no
  } else {
    0
  }
  let line_width = int_width(max_line_no)
  for line in lines {
    let sha = if long_sha {
      line.commit_id.to_hex()
    } else {
      let hex = line.commit_id.to_hex()
      String::unsafe_substring(hex, start=0, end=8)
    }
    let prefix = if line.is_boundary { "^" } else { "" }
    let date_str = format_timestamp(line.author_time, line.author_tz)
    let padded_author = pad_right(line.author, max_author)
    let padded_line_no = pad_left(line.line_no.to_string(), line_width)
    print_line(
      "\{prefix}\{sha} (\{padded_author} \{date_str} \{padded_line_no}) \{line.content}",
    )
  }
}

///|
async fn output_blame_porcelain(lines : Array[BlameLine]) -> Unit raise Error {
  for line in lines {
    let sha = line.commit_id.to_hex()
    print_line("\{sha} \{line.line_no} \{line.line_no} 1")
    print_line("author \{line.author}")
    print_line("author-time \{line.author_time}")
    print_line("author-tz \{line.author_tz}")
    if line.is_boundary {
      print_line("boundary")
    }
    print_line("\t\{line.content}")
  }
}

///|
async fn output_blame_incremental(lines : Array[BlameLine]) -> Unit raise Error {
  // Incremental format: each entry is immediately flushed
  // Track which commits we've already output headers for
  let seen_commits : Map[String, Bool] = Map([])
  for line in lines {
    let sha = line.commit_id.to_hex()
    print_line("\{sha} \{line.line_no} \{line.line_no} 1")
    // Only output full header for first occurrence of each commit
    if !seen_commits.get(sha).unwrap_or(false) {
      seen_commits[sha] = true
      print_line("author \{line.author}")
      print_line("author-time \{line.author_time}")
      print_line("author-tz \{line.author_tz}")
      if line.is_boundary {
        print_line("boundary")
      }
    }
    print_line("\t\{line.content}")
  }
}

///|
fn format_timestamp(ts : Int64, tz : String) -> String {
  // Convert Unix timestamp to YYYY-MM-DD HH:MM:SS format
  // Simplified: just output timestamp as date string
  let secs = ts.to_int()
  // Calculate date parts (simplified, assumes UTC)
  let days = secs / 86400
  let time_of_day = secs % 86400
  let hours = time_of_day / 3600
  let minutes = time_of_day % 3600 / 60
  let seconds = time_of_day % 60
  // Calculate year/month/day from days since epoch (1970-01-01)
  let (year, month, day) = days_to_date(days)
  let y = pad_left_zero(year.to_string(), 4)
  let m = pad_left_zero(month.to_string(), 2)
  let d = pad_left_zero(day.to_string(), 2)
  let h = pad_left_zero(hours.to_string(), 2)
  let mi = pad_left_zero(minutes.to_string(), 2)
  let s = pad_left_zero(seconds.to_string(), 2)
  "\{y}-\{m}-\{d} \{h}:\{mi}:\{s} \{tz}"
}

///|
fn pad_left_zero(s : String, width : Int) -> String {
  if s.length() >= width {
    return s
  }
  let padding = width - s.length()
  let mut result = ""
  for _ in 0..<padding {
    result = result + "0"
  }
  result + s
}

///|
fn days_to_date(days : Int) -> (Int, Int, Int) {
  // Convert days since epoch to (year, month, day)
  let mut remaining = days
  let mut year = 1970
  while true {
    let days_in_year = if is_leap_year(year) { 366 } else { 365 }
    if remaining < days_in_year {
      break
    }
    remaining = remaining - days_in_year
    year = year + 1
  }
  // Now find month and day
  let days_in_months = if is_leap_year(year) {
    [31, 29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
  } else {
    [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
  }
  let mut month = 1
  for m in days_in_months {
    if remaining < m {
      break
    }
    remaining = remaining - m
    month = month + 1
  }
  (year, month, remaining + 1)
}

///|
fn is_leap_year(year : Int) -> Bool {
  (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
}

///|
fn int_width(n : Int) -> Int {
  if n == 0 {
    return 1
  }
  let mut width = 0
  let mut val = n
  while val > 0 {
    width = width + 1
    val = val / 10
  }
  width
}

///|
fn pad_left(s : String, width : Int) -> String {
  if s.length() >= width {
    return s
  }
  let padding = width - s.length()
  let mut result = ""
  for _ in 0..<padding {
    result = result + " "
  }
  result + s
}

///|
fn pad_right(s : String, width : Int) -> String {
  if s.length() >= width {
    return s
  }
  let padding = width - s.length()
  let mut result = s
  for _ in 0..<padding {
    result = result + " "
  }
  result
}

///|
/// Handle diff for subdir-clone with upstream ref

///| Git log helpers

///|
pub struct LogEntry {
  id : @bit.ObjectId
  message : String
  // Full commit message body (every line, trailing blank lines stripped); the
  // multi-line default log format prints these, while `message` is the subject.
  body_lines : Array[String]
  author : String
  timestamp : Int64
  // Author timezone offset (e.g. "+0900"), needed to render the "Date:" line.
  date_tz : String
  tree : @bit.ObjectId
  parent_tree : @bit.ObjectId?
}

///|
/// Read commit history from HEAD.
pub fn log_head(
  fs : &@bit.RepoFileSystem,
  git_dir : String,
  max_count? : Int = 100,
  since? : Int64 = 0L,
  until? : Int64 = 9223372036854775807L,
  include_parent_tree? : Bool = false,
) -> Array[LogEntry] raise @bit.GitError {
  let result : Array[LogEntry] = []
  let mut current = resolve_head_commit(fs, git_dir)
  let mut count = 0
  let object_git_dir = log_resolve_common_git_dir(fs, git_dir)
  let db = ObjectDb::load_lazy(fs, object_git_dir)
  while count < max_count {
    match current {
      None => break
      Some(id) => {
        let obj = db.get(fs, id)
        match obj {
          None => break
          Some(o) => {
            if o.obj_type != @bit.ObjectType::Commit {
              raise @bit.GitError::InvalidObject("Object is not a commit")
            }
            let info = @bit.parse_commit(o.data)
            let parents = log_resolve_parents(fs, git_dir, id, info.parents)
            let entry = parse_log_entry(id, o.data, info.tree)
            // Get parent tree for diff (only when needed for --stat/--patch)
            let parent_tree : @bit.ObjectId? = if include_parent_tree &&
              parents.length() > 0 {
              let parent_obj = db.get(fs, parents[0])
              match parent_obj {
                Some(po) => {
                  let parent_info = @bit.parse_commit(po.data)
                  Some(parent_info.tree)
                }
                None => None
              }
            } else {
              None
            }
            // Filter by since/until
            if entry.timestamp < since {
              // Older than since, stop traversal
              break
            }
            if entry.timestamp <= until {
              result.push({ ..entry, parent_tree, })
              count += 1
            }
            current = if parents.length() > 0 { Some(parents[0]) } else { None }
          }
        }
      }
    }
  }
  result
}

///|
/// Format like `git log --oneline`.
pub fn log_head_oneline(
  fs : &@bit.RepoFileSystem,
  git_dir : String,
  max_count? : Int = 100,
  since? : Int64 = 0L,
  until? : Int64 = 9223372036854775807L,
) -> Array[String] raise @bit.GitError {
  let entries = log_head(fs, git_dir, max_count~, since~, until~)
  let lines : Array[String] = []
  for e in entries {
    let short = @bithash.short_hex(e.id.to_hex(), 7)
    lines.push("\{short} \{e.message}")
  }
  lines
}

///|
fn parse_log_entry(
  id : @bit.ObjectId,
  data : Bytes,
  tree : @bit.ObjectId,
) -> LogEntry {
  let text = @utf8.decode_lossy(data[:])
  let lines = text.split("\n")
  let mut author = ""
  let mut timestamp = 0L
  let mut date_tz = "+0000"
  let mut in_message = false
  let message_lines : Array[String] = []
  for line_view in lines {
    let line = line_view.to_owned()
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
      let (name, time, tz) = parse_author_line(rest)
      author = name
      timestamp = time
      date_tz = tz
    }
  }
  let message = if message_lines.length() > 0 { message_lines[0] } else { "" }
  // Drop trailing blank lines (git strips them before printing the body).
  let mut body_end = message_lines.length()
  while body_end > 0 && message_lines[body_end - 1] == "" {
    body_end -= 1
  }
  let body_lines : Array[String] = []
  for i in 0..<body_end {
    body_lines.push(message_lines[i])
  }
  {
    id,
    message,
    body_lines,
    author,
    timestamp,
    date_tz,
    tree,
    parent_tree: None,
  }
}

///|
fn parse_author_line(line : String) -> (String, Int64, String) {
  // format: Name <email> 1700000000 +0000
  let mut last_space = line.rev_find(" ")
  if last_space is None {
    return (line, 0L, "+0000")
  }
  let tz_idx = last_space.unwrap()
  let tz_str = String::unsafe_substring(
    line,
    start=tz_idx + 1,
    end=line.length(),
  )
  let tz = if tz_str.length() >= 4 &&
    (tz_str.has_prefix("+") || tz_str.has_prefix("-")) {
    tz_str
  } else {
    "+0000"
  }
  let before_tz = String::unsafe_substring(line, start=0, end=tz_idx)
  last_space = before_tz.rev_find(" ")
  if last_space is None {
    return (before_tz, 0L, tz)
  }
  let time_idx = last_space.unwrap()
  let name = String::unsafe_substring(before_tz, start=0, end=time_idx)
  let time_str = String::unsafe_substring(
    before_tz,
    start=time_idx + 1,
    end=before_tz.length(),
  )
  let ts = parse_int64(time_str)
  (name, ts, tz)
}

///|
fn parse_int64(s : String) -> Int64 {
  let mut result = 0L
  for c in s {
    if c < '0' || c > '9' {
      continue
    }
    let digit = c.to_int() - '0'.to_int()
    result = result * 10L + digit.to_int64()
  }
  result
}

///|
fn log_resolve_parents(
  fs : &@bit.RepoFileSystem,
  git_dir : String,
  commit_id : @bit.ObjectId,
  default_parents : Array[@bit.ObjectId],
) -> Array[@bit.ObjectId] {
  match log_read_graft_parents(fs, git_dir, commit_id) {
    Some(parents) => parents
    None => default_parents
  }
}

///|
fn log_read_graft_parents(
  fs : &@bit.RepoFileSystem,
  git_dir : String,
  commit_id : @bit.ObjectId,
) -> Array[@bit.ObjectId]? {
  let graft_path = join_path(
    log_resolve_common_git_dir(fs, git_dir),
    "info/grafts",
  )
  if !fs.is_file(graft_path) {
    return None
  }
  let content = decode_bytes_lossy(
    fs.read_file(graft_path) catch {
      _ => return None
    },
  )
  let commit_hex = commit_id.to_hex()
  for line_view in content.split("\n") {
    let line = @string_utils.trim_string(line_view.to_owned())
    if line.length() == 0 || line.has_prefix("#") {
      continue
    }
    let tokens : Array[String] = []
    for token_view in line.split(" ") {
      let token = @string_utils.trim_string(token_view.to_owned())
      if token.length() > 0 {
        tokens.push(token)
      }
    }
    if tokens.length() == 0 || tokens[0] != commit_hex {
      continue
    }
    let parents : Array[@bit.ObjectId] = []
    for i in 1..<tokens.length() {
      let parent_hex = tokens[i]
      if parent_hex.length() == 40 || parent_hex.length() == 64 {
        let parent_id = @bit.ObjectId::from_hex(parent_hex) catch {
          _ => continue
        }
        parents.push(parent_id)
      }
    }
    return Some(parents)
  }
  None
}

///|
fn log_resolve_common_git_dir(
  fs : &@bit.RepoFileSystem,
  git_dir : String,
) -> String {
  let commondir_path = join_path(git_dir, "commondir")
  if !fs.is_file(commondir_path) {
    return git_dir
  }
  let raw = @utf8.decode_lossy(
    (fs.read_file(commondir_path) catch { _ => Default::default() })[:],
  )
  let rel = @string_utils.trim_string(raw)
  if rel.length() == 0 {
    return git_dir
  }
  if rel.has_prefix("/") {
    normalize_path(rel)
  } else {
    normalize_path(join_path(git_dir, rel))
  }
}

///|

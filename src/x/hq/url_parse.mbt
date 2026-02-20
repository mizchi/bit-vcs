///|
/// Parse a repository URL or shorthand into RepoPath
///
/// Supported formats:
/// - user/repo
/// - user/repo/path/to/subdir (slash separator for subdir)
/// - user/repo:path/to/subdir (colon separator for subdir)
/// - github.com/user/repo
/// - github.com/user/repo:path/to/subdir
/// - gitlab.com/user/repo
/// - https://github.com/user/repo
/// - https://github.com/user/repo/tree/main/path/to/subdir
/// - git@github.com:user/repo.git
pub fn parse_repo_url(input : String) -> RepoPath? {
  let input = input.trim().to_string()
  if input.is_empty() {
    return None
  }
  // Handle git@ SSH URLs
  if input.has_prefix("git@") {
    return parse_ssh_url(input)
  }
  // Handle https:// URLs
  if input.has_prefix("https://") || input.has_prefix("http://") {
    return parse_https_url(input)
  }
  // Handle shorthand: user/repo or host/user/repo
  parse_shorthand(input)
}

///|
fn parse_ssh_url(input : String) -> RepoPath? {
  // git@github.com:user/repo.git
  // git@gitlab.com:user/repo.git
  let without_prefix = slice_from(input, 4) // remove "git@"
  let colon_idx = find_char(without_prefix, ':')
  guard colon_idx is Some(idx) else { return None }
  let host = slice_to(without_prefix, idx)
  let path = slice_from(without_prefix, idx + 1)
  // Remove .git suffix if present
  let path = if path.has_suffix(".git") {
    slice_to(path, path.length() - 4)
  } else {
    path
  }
  let parts = path.split("/").collect()
  if parts.length() < 2 {
    return None
  }
  let user = parts[0].to_string()
  let repo = parts[1].to_string()
  let subdir : String? = if parts.length() > 2 {
    Some(join_parts(parts, 2, parts.length()))
  } else {
    None
  }
  // Normalize github.com
  let normalized_host : String? = if host == "github.com" {
    None
  } else {
    Some(host)
  }
  Some(RepoPath::new(user, repo, host=normalized_host, subdir~))
}

///|
fn parse_https_url(input : String) -> RepoPath? {
  // https://github.com/user/repo
  // https://github.com/user/repo.git
  // https://github.com/user/repo/tree/branch/path/to/subdir
  let without_protocol = if input.has_prefix("https://") {
    slice_from(input, 8)
  } else {
    slice_from(input, 7) // http://
  }
  let parts = without_protocol.split("/").collect()
  if parts.length() < 3 {
    return None
  }
  let host = parts[0].to_string()
  let user = parts[1].to_string()
  let mut repo = parts[2].to_string()
  // Remove .git suffix
  if repo.has_suffix(".git") {
    repo = slice_to(repo, repo.length() - 4)
  }
  // Check for /tree/branch/path or /blob/branch/path pattern
  let subdir : String? = if parts.length() > 4 &&
    (parts[3].to_string() == "tree" || parts[3].to_string() == "blob") {
    // parts[4] is branch, parts[5:] is path
    if parts.length() > 5 {
      Some(join_parts(parts, 5, parts.length()))
    } else {
      None
    }
  } else if parts.length() > 3 {
    // Direct path after repo
    Some(join_parts(parts, 3, parts.length()))
  } else {
    None
  }
  // Normalize github.com
  let normalized_host : String? = if host == "github.com" {
    None
  } else {
    Some(host)
  }
  Some(RepoPath::new(user, repo, host=normalized_host, subdir~))
}

///|
fn parse_shorthand(input : String) -> RepoPath? {
  // user/repo
  // user/repo:path/to/subdir (colon separator for subdir)
  // user/repo/path/to/subdir (slash separator for subdir)
  // github.com/user/repo
  // gitlab.com/user/repo:path

  // Check for subdir separator ':'
  let (repo_part, explicit_subdir) = match find_char(input, ':') {
    Some(idx) => {
      let rp = slice_to(input, idx)
      let sd = slice_from(input, idx + 1)
      (rp, if sd.is_empty() { None } else { Some(sd) })
    }
    None => (input, None)
  }
  let parts = repo_part.split("/").filter(s => s.length() > 0).collect()
  if parts.length() < 2 {
    return None
  }
  // Check if first part looks like a host (contains a dot)
  let first = parts[0].to_string()
  if first.contains(".") {
    // host/user/repo format
    if parts.length() < 3 {
      return None
    }
    let host = first
    let user = parts[1].to_string()
    let repo = parts[2].to_string()
    let subdir = match explicit_subdir {
      Some(sd) => Some(sd)
      None =>
        if parts.length() > 3 {
          Some(join_parts(parts, 3, parts.length()))
        } else {
          None
        }
    }
    // Normalize github.com
    let normalized_host : String? = if host == "github.com" {
      None
    } else {
      Some(host)
    }
    Some(RepoPath::new(user, repo, host=normalized_host, subdir~))
  } else {
    // user/repo format (github.com implicit)
    let user = parts[0].to_string()
    let repo = parts[1].to_string()
    let subdir = match explicit_subdir {
      Some(sd) => Some(sd)
      None =>
        if parts.length() > 2 {
          Some(join_parts(parts, 2, parts.length()))
        } else {
          None
        }
    }
    Some(RepoPath::new(user, repo, subdir~))
  }
}

///|
/// Find index of character in string
fn find_char(s : String, c : Char) -> Int? {
  for i = 0; i < s.length(); i = i + 1 {
    match s.get_char(i) {
      Some(ch) if ch == c => return Some(i)
      _ => ()
    }
  }
  None
}

///|
/// Join array of string views from start to end with "/"
fn join_parts(parts : Array[StringView], start : Int, end : Int) -> String {
  let buf = StringBuilder::new()
  for i = start; i < end; i = i + 1 {
    if i > start {
      buf.write_char('/')
    }
    buf.write_string(parts[i].to_string())
  }
  buf.to_string()
}

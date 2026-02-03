///| Remote operation handlers: remote, upload-pack, receive-pack, fetch, pull, push, clone

///|
/// Clone target result
pub(all) enum GitHubShorthand {
  /// Full repo clone: user/repo → https://github.com/user/repo
  Repo(String, String?) // github_url, ref?
  /// Subdir clone: user/repo:path → https://github.com/user/repo, path
  Subdir(String, String, String?) // github_url, subdir_path, ref?
  /// Single file fetch: raw URL, filename
  File(String, String) // raw_url, filename
} derive(Eq, Show)

///|
/// Parse clone shorthand or GitHub browser URL
///
/// Supports:
/// 1. user/repo → Repo clone (GitHub)
/// 2. user/repo:path → Subdir clone with sparse checkout
/// 3. user/repo@ref → Repo clone at ref
/// 4. user/repo@ref:path → Subdir clone at ref
/// 5. gitlab.com/user/repo → Repo clone (other hosts)
/// 6. gitlab.com/user/repo:path → Subdir clone (other hosts)
/// 7. https://github.com/user/repo/tree/branch/path → Subdir clone
/// 8. https://github.com/user/repo/blob/branch/path → Single file fetch
///
/// Examples:
/// - "user/repo" → Repo("https://github.com/user/repo")
/// - "user/repo:src" → Subdir("https://github.com/user/repo", "src")
/// - "user/repo@main" → Repo("https://github.com/user/repo", Some("main"))
/// - "user/repo@main:src" → Subdir("https://github.com/user/repo", "src", Some("main"))
/// - "gitlab.com/user/repo" → Repo("https://gitlab.com/user/repo")
/// - "https://github.com/user/repo/tree/main/src" → Subdir(url, "src")
pub fn parse_github_shorthand(url : String) -> GitHubShorthand? {
  // Check for GitHub browser URL first
  if url.has_prefix("https://github.com/") {
    return parse_github_browser_url(url)
  }
  // Skip if it looks like a local path or full URL
  if url.has_prefix("./") ||
    url.has_prefix("/") ||
    url.has_prefix("../") ||
    url.has_prefix("https://") ||
    url.has_prefix("http://") ||
    url.has_prefix("git@") ||
    url.has_suffix(".git") {
    return None
  }
  // Check for subdir separator ':'
  let (repo_part, subdir) = match url.find(":") {
    Some(idx) => {
      let rp = String::unsafe_substring(url, start=0, end=idx)
      let sd = String::unsafe_substring(url, start=idx + 1, end=url.length())
      (rp, if sd.is_empty() { None } else { Some(sd) })
    }
    None => (url, None)
  }
  // Extract @ref from repo part
  let (repo_base, ref_spec) = match repo_part.rev_find("@") {
    Some(idx) => {
      let base = String::unsafe_substring(repo_part, start=0, end=idx)
      let rf = String::unsafe_substring(
        repo_part,
        start=idx + 1,
        end=repo_part.length(),
      )
      (base, if rf.is_empty() { None } else { Some(rf) })
    }
    None => (repo_part, None)
  }
  // Split repo part by /
  let parts : Array[String] = repo_base
    .split("/")
    .filter(fn(s) { s.length() > 0 })
    .map(fn(s) { s.to_string() })
    .collect()
  // Determine host and user/repo
  let (host, owner, repo) = if parts.length() == 2 {
    // user/repo → GitHub
    ("github.com", parts[0], parts[1])
  } else if parts.length() == 3 && parts[0].contains(".") {
    // host.com/user/repo
    (parts[0], parts[1], parts[2])
  } else {
    return None
  }
  let clone_url = "https://\{host}/\{owner}/\{repo}"
  match subdir {
    Some(sd) => Some(Subdir(clone_url, sd, ref_spec))
    None => Some(Repo(clone_url, ref_spec))
  }
}

///|
/// Check if shorthand conflicts with local directory
/// Returns the conflicting path if ambiguous
pub fn check_shorthand_ambiguity(
  url : String,
  dir_exists : (String) -> Bool,
) -> String? {
  // Only check for shorthand patterns (not full URLs)
  if url.has_prefix("https://") ||
    url.has_prefix("http://") ||
    url.has_prefix("git@") ||
    url.has_prefix("file://") ||
    url.has_prefix("./") ||
    url.has_prefix("/") ||
    url.has_prefix("../") ||
    url.has_suffix(".git") {
    return None
  }
  if url.find("/") is None && url.find(":") is None {
    return None
  }
  // Extract repo part (before ':' if present)
  let repo_part = match url.find(":") {
    Some(idx) => String::unsafe_substring(url, start=0, end=idx)
    None => url
  }
  // Strip @ref if present
  let repo_base = match repo_part.rev_find("@") {
    Some(idx) => String::unsafe_substring(repo_part, start=0, end=idx)
    None => repo_part
  }
  // Check first component
  let first_slash = repo_base.find("/")
  let first_part = match first_slash {
    Some(idx) => String::unsafe_substring(repo_base, start=0, end=idx)
    None => repo_base
  }
  if dir_exists(first_part) {
    return Some(first_part)
  }
  // Check full repo path (user/repo part)
  let parts : Array[String] = repo_base
    .split("/")
    .filter(fn(s) { s.length() > 0 })
    .map(fn(s) { s.to_string() })
    .collect()
  if parts.length() >= 2 {
    let two_parts = parts[0] + "/" + parts[1]
    if dir_exists(two_parts) {
      return Some(two_parts)
    }
  }
  None
}

///|
/// Parse GitHub browser URL (tree/blob)
/// https://github.com/user/repo/tree/branch/path → Subdir
/// https://github.com/user/repo/blob/branch/path → File
fn parse_github_browser_url(url : String) -> GitHubShorthand? {
  // Remove https://github.com/
  let path = String::unsafe_substring(url, start=19, end=url.length())
  let parts : Array[String] = path
    .split("/")
    .filter(fn(s) { s.length() > 0 })
    .map(fn(s) { s.to_string() })
    .collect()
  // Need at least: user/repo/tree|blob/branch/path
  // parts[0] = user, parts[1] = repo, parts[2] = tree|blob, parts[3] = branch, parts[4+] = path
  if parts.length() < 5 {
    return None
  }
  let owner = parts[0]
  let repo = parts[1]
  let kind = parts[2] // "tree" or "blob"
  let branch = parts[3]
  // Build path from remaining parts
  let path_parts : Array[String] = []
  for i = 4; i < parts.length(); i = i + 1 {
    path_parts.push(parts[i])
  }
  let subpath = path_parts.join("/")
  let github_url = "https://github.com/\{owner}/\{repo}"
  if kind == "tree" {
    // Directory → subdir clone
    Some(Subdir(github_url, subpath, Some(branch)))
  } else if kind == "blob" {
    // File → raw fetch
    let raw_url = "https://raw.githubusercontent.com/\{owner}/\{repo}/\{branch}/\{subpath}"
    let filename = parts[parts.length() - 1]
    Some(File(raw_url, filename))
  } else {
    None
  }
}

///|
fn parse_object_id_hex(text : String) -> @git.ObjectId? {
  let parsed : Result[@git.ObjectId, Error] = try? @git.ObjectId::from_hex(text)
  match parsed {
    Ok(id) => Some(id)
    Err(_) => None
  }
}

///|
fn is_hex_char(c : Char) -> Bool {
  (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F')
}

///|
fn is_hex_string(s : String) -> Bool {
  if s.length() == 0 {
    return false
  }
  for c in s {
    if not(is_hex_char(c)) {
      return false
    }
  }
  true
}

///|
fn lower_hex_string(s : String) -> String {
  let out = StringBuilder::new()
  for c in s {
    if c >= 'A' && c <= 'F' {
      out.write_char((c.to_int() + 32).unsafe_to_char())
    } else {
      out.write_char(c)
    }
  }
  out.to_string()
}

///|
async fn resolve_remote_ref_id(
  remote_url : String,
  ref_spec : String,
) -> (@git.ObjectId, String?)? raise Error {
  match parse_object_id_hex(ref_spec) {
    Some(id) => return Some((id, None))
    None => ()
  }
  let (refs, _caps, _version, symrefs) = @git.discover_upload_refs_http(
    remote_url, true,
  )
  if is_hex_string(ref_spec) && ref_spec.length() >= 4 {
    let needle = lower_hex_string(ref_spec)
    let matches : Array[@git.ObjectId] = []
    for item in refs {
      let (id, _name) = item
      if id.to_hex().has_prefix(needle) {
        matches.push(id)
      }
    }
    if matches.length() == 1 {
      return Some((matches[0], None))
    }
    if matches.length() > 1 {
      raise @git.GitError::InvalidObject("short hash is ambiguous: " + ref_spec)
    }
  }
  if ref_spec == "HEAD" {
    match @git.select_default_ref(refs, symrefs) {
      Some((refname, id)) =>
        if refname.has_prefix("refs/heads/") {
          let branch = String::unsafe_substring(
            refname,
            start=11,
            end=refname.length(),
          )
          return Some((id, Some(branch)))
        } else {
          return Some((id, None))
        }
      None => return None
    }
  }
  let candidates : Array[String] = []
  if ref_spec.has_prefix("refs/") {
    candidates.push(ref_spec)
  } else {
    candidates.push("refs/heads/" + ref_spec)
    candidates.push("refs/tags/" + ref_spec)
    candidates.push(ref_spec)
  }
  for cand in candidates {
    for item in refs {
      let (id, name) = item
      if name == cand {
        if name.has_prefix("refs/heads/") {
          let branch = String::unsafe_substring(
            name,
            start=11,
            end=name.length(),
          )
          return Some((id, Some(branch)))
        }
        return Some((id, None))
      }
    }
  }
  None
}

///|
/// Fetch a raw file from URL and save to local path
async fn fetch_raw_file(url : String, target : String) -> Unit raise Error {
  let root = get_work_root()
  let target_path = if target.has_prefix("/") {
    target
  } else {
    root + "/" + target
  }
  // Use HTTP fetch
  let headers : Map[String, String] = {}
  let (response, content) = @git.native_http_get(url, headers)
  if response.code != 200 {
    raise @git.GitError::InvalidObject(
      "HTTP \{response.code}: failed to fetch \{url}",
    )
  }
  // Write to file
  let fs = OsFs::new()
  fs.write_file(target_path, content)
  print_line("Saved to '\{target}'")
}

///|
async fn die_remote(code : Int, msg : String) -> Unit {
  eprint_line(msg)
  @sys.exit(code)
}

///|
async fn handle_remote(args : Array[String]) -> Unit raise Error {
  let root = get_work_root()
  let git_dir = root + "/.git"
  let fs = OsFs::new()
  if args.length() == 0 {
    // List remotes
    let remotes = list_remotes(fs, git_dir)
    for name in remotes {
      print_line(name)
    }
    return ()
  }
  let subcmd = args[0]
  match subcmd {
    "add" => {
      let mut fetch_after_add = false
      let positional : Array[String] = []
      for i in 1..<args.length() {
        let arg = args[i]
        match arg {
          "-f" | "--fetch" => fetch_after_add = true
          _ if arg.has_prefix("-") => warn_unimplemented_arg("remote add", arg)
          _ => positional.push(arg)
        }
      }
      if positional.length() < 2 {
        raise @git.GitError::InvalidObject("usage: git remote add <name> <url>")
      }
      let name = positional[0]
      let url = positional[1]
      if not(is_valid_remote_name(name)) {
        die_remote(1, "fatal: '\{name}' is not a valid remote name")
      }
      let blocks = parse_config_blocks(read_config_content(fs, git_dir))
      if config_has_remote_section(blocks, name) ||
        legacy_remote_exists(fs, git_dir, name) {
        die_remote(3, "error: remote \{name} already exists.")
      }
      remote_add(fs, fs, git_dir, name, url)
      if fetch_after_add {
        fetch_from_remote(fs, git_dir, root, name, url)
      }
    }
    "remove" | "rm" => {
      if args.length() < 2 {
        raise @git.GitError::InvalidObject("usage: git remote remove <name>")
      }
      let name = args[1]
      let blocks = parse_config_blocks(read_config_content(fs, git_dir))
      if not(config_has_remote_section(blocks, name)) &&
        not(legacy_remote_exists(fs, git_dir, name)) {
        die_remote(2, "error: No such remote: '\{name}'")
      }
      remote_remove(fs, fs, git_dir, name)
    }
    "rename" => {
      let positional : Array[String] = []
      for i in 1..<args.length() {
        let arg = args[i]
        match arg {
          "--progress" => ()
          _ if arg.has_prefix("-") =>
            warn_unimplemented_arg("remote rename", arg)
          _ => positional.push(arg)
        }
      }
      if positional.length() < 2 {
        raise @git.GitError::InvalidObject(
          "usage: git remote rename <old> <new>",
        )
      }
      let old_name = positional[0]
      let new_name = positional[1]
      if not(is_valid_remote_name(new_name)) {
        die_remote(1, "fatal: '\{new_name}' is not a valid remote name")
      }
      let blocks = parse_config_blocks(read_config_content(fs, git_dir))
      let old_exists = config_has_remote_section(blocks, old_name) ||
        legacy_remote_exists(fs, git_dir, old_name)
      if not(old_exists) {
        die_remote(2, "error: No such remote: '\{old_name}'")
      }
      let new_exists = config_has_remote_section(blocks, new_name) ||
        legacy_remote_exists(fs, git_dir, new_name)
      if old_name != new_name && new_exists {
        die_remote(3, "error: remote \{new_name} already exists.")
      }
      remote_rename(fs, fs, git_dir, old_name, new_name)
    }
    "-v" | "--verbose" => {
      // List remotes with URLs
      let remotes = list_remotes_verbose(fs, git_dir)
      for item in remotes {
        let (name, line) = item
        print_line("\{name}\t\{line}")
      }
    }
    "show" => {
      let mut no_query = false
      let targets : Array[String] = []
      for i in 1..<args.length() {
        let arg = args[i]
        match arg {
          "-n" | "--no-query" => no_query = true
          _ if arg.has_prefix("-") => warn_unimplemented_arg("remote show", arg)
          _ => targets.push(arg)
        }
      }
      let names = if targets.length() > 0 {
        targets
      } else {
        list_remotes(fs, git_dir)
      }
      for i in 0..<names.length() {
        if i > 0 {
          print_line("")
        }
        remote_show(fs, git_dir, root, names[i], no_query)
      }
    }
    "get-url" => {
      if args.length() < 2 {
        raise @git.GitError::InvalidObject("usage: git remote get-url <name>")
      }
      let name = args[1]
      let url = get_remote_url(fs, git_dir, name)
      match url {
        Some(u) => print_line(u)
        None => raise @git.GitError::InvalidObject("No such remote '\{name}'")
      }
    }
    "set-url" => {
      if args.length() < 3 {
        raise @git.GitError::InvalidObject(
          "usage: git remote set-url <name> <newurl>",
        )
      }
      let name = args[1]
      let url = args[2]
      remote_set_url(fs, fs, git_dir, name, url)
    }
    "prune" => {
      let mut dry_run = false
      let targets : Array[String] = []
      for i in 1..<args.length() {
        let arg = args[i]
        match arg {
          "-n" | "--dry-run" => dry_run = true
          _ if arg.has_prefix("-") =>
            warn_unimplemented_arg("remote prune", arg)
          _ => targets.push(arg)
        }
      }
      if targets.length() == 0 {
        raise @git.GitError::InvalidObject("usage: git remote prune <name>")
      }
      for name in targets {
        remote_prune(fs, git_dir, root, name, dry_run)
      }
    }
    "update" => {
      let mut prune = false
      let targets : Array[String] = []
      for i in 1..<args.length() {
        let arg = args[i]
        match arg {
          "-p" | "--prune" => prune = true
          _ if arg.has_prefix("-") =>
            warn_unimplemented_arg("remote update", arg)
          _ => targets.push(arg)
        }
      }
      remote_update(fs, git_dir, root, targets, prune)
    }
    "set-head" => {
      let mut mode : String? = None
      let positional : Array[String] = []
      for i in 1..<args.length() {
        let arg = args[i]
        match arg {
          "--delete" => mode = Some("delete")
          "--auto" => mode = Some("auto")
          _ if arg.has_prefix("-") =>
            warn_unimplemented_arg("remote set-head", arg)
          _ => positional.push(arg)
        }
      }
      if positional.length() == 0 {
        raise @git.GitError::InvalidObject(
          "usage: git remote set-head <name> <branch>",
        )
      }
      let name = positional[0]
      match mode {
        Some("delete") => remote_set_head_delete(fs, git_dir, name)
        Some("auto") => remote_set_head_auto(fs, git_dir, root, name)
        _ =>
          if positional.length() >= 2 {
            remote_set_head_explicit(fs, git_dir, name, positional[1])
          } else {
            raise @git.GitError::InvalidObject(
              "usage: git remote set-head <name> <branch>",
            )
          }
      }
    }
    _ =>
      raise @git.GitError::InvalidObject("Unknown remote subcommand: \{subcmd}")
  }
}

///|
struct RemoteConfig {
  urls : Array[String]
  pushurls : Array[String]
  fetch : Array[String]
  push : Array[String]
  mut promisor : Bool
  mut partial_clone_filter : String?
}

///|
struct BranchConfig {
  name : String
  mut remote : String?
  merges : Array[String]
  mut rebase : Bool?
}

///|
struct FetchRefspec {
  negative : Bool
  src : String
  dst : String
}

///|
struct PushRefspec {
  force : Bool
  src : String
  dst : String
}

///|
fn config_strip_quotes(s : String) -> String {
  let t = s.trim().to_string()
  if t.length() >= 2 && t.has_prefix("\"") && t.has_suffix("\"") {
    String::unsafe_substring(t, start=1, end=t.length() - 1)
  } else {
    t
  }
}

///|
struct ConfigBlock {
  mut header : String?
  section : String?
  name : String?
  mut lines : Array[String]
}

///|
fn parse_section_header(line : String) -> (String, String?) {
  let body = String::unsafe_substring(line, start=1, end=line.length() - 1)
  match body.find(" ") {
    Some(idx) => {
      let sec = String::unsafe_substring(body, start=0, end=idx).to_lower()
      let name_part = String::unsafe_substring(
        body,
        start=idx + 1,
        end=body.length(),
      )
      (sec, Some(config_strip_quotes(name_part)))
    }
    None => (body.to_lower(), None)
  }
}

///|
fn parse_config_kv(line : String) -> (String, String)? {
  let trimmed = trim_string(line)
  if trimmed.length() == 0 || trimmed.has_prefix("#") || trimmed.has_prefix(";") {
    return None
  }
  match trimmed.find("=") {
    Some(eq_idx) => {
      let key = trim_string(
        String::unsafe_substring(trimmed, start=0, end=eq_idx),
      ).to_lower()
      let value = trim_string(
        String::unsafe_substring(
          trimmed,
          start=eq_idx + 1,
          end=trimmed.length(),
        ),
      )
      Some((key, value))
    }
    None => None
  }
}

///|
fn parse_config_blocks(content : String) -> Array[ConfigBlock] {
  let blocks : Array[ConfigBlock] = []
  let mut current : ConfigBlock = {
    header: None,
    section: None,
    name: None,
    lines: [],
  }
  for line_view in content.split("\n") {
    let line = line_view.to_string()
    let trimmed = trim_string(line)
    if trimmed.has_prefix("[") && trimmed.has_suffix("]") {
      if current.header is Some(_) || current.lines.length() > 0 {
        blocks.push(current)
      }
      let (section, name) = parse_section_header(trimmed)
      current = {
        header: Some(trimmed),
        section: Some(section),
        name,
        lines: [],
      }
      continue
    }
    current.lines.push(line)
  }
  if current.header is Some(_) || current.lines.length() > 0 {
    blocks.push(current)
  }
  blocks
}

///|
fn render_config_blocks(blocks : Array[ConfigBlock]) -> String {
  let lines : Array[String] = []
  for block in blocks {
    match block.header {
      Some(h) => lines.push(h)
      None => ()
    }
    for line in block.lines {
      lines.push(line)
    }
  }
  let mut content = lines.join("\n")
  if content.length() > 0 && not(content.has_suffix("\n")) {
    content = content + "\n"
  }
  content
}

///|
fn config_has_remote_section(
  blocks : Array[ConfigBlock],
  name : String,
) -> Bool {
  for block in blocks {
    if block.section == Some("remote") && block.name == Some(name) {
      return true
    }
  }
  false
}

///|
fn read_config_content(rfs : &@git.RepoFileSystem, git_dir : String) -> String {
  let config_path = git_dir + "/config"
  if rfs.is_file(config_path) {
    let content = try? rfs.read_file(config_path)
    match content {
      Ok(data) => decode_bytes(data)
      Err(_) => ""
    }
  } else {
    ""
  }
}

///|
fn is_valid_remote_name(name : String) -> Bool {
  if name.length() == 0 {
    return false
  }
  if name.has_suffix("/") || name.has_suffix(".lock") {
    return false
  }
  if name.contains("..") || name.contains("@{") {
    return false
  }
  let invalid = [" ", "\t", "\n", "\r", "~", "^", ":", "?", "*", "[", "\\"]
  for bad in invalid {
    if name.contains(bad) {
      return false
    }
  }
  true
}

///|
fn legacy_remote_exists(fs : OsFs, git_dir : String, name : String) -> Bool {
  fs.is_file(git_dir + "/remotes/" + name) ||
  fs.is_file(git_dir + "/branches/" + name)
}

///|
fn update_fetch_refspec(
  spec : String,
  old_name : String,
  new_name : String,
) -> String {
  let mut prefix = ""
  let mut body = spec
  if body.has_prefix("^") {
    prefix = prefix + "^"
    body = String::unsafe_substring(body, start=1, end=body.length())
  }
  if body.has_prefix("+") {
    prefix = prefix + "+"
    body = String::unsafe_substring(body, start=1, end=body.length())
  }
  let has_colon = body.find(":") is Some(_)
  let (src, dst) = parse_refspec_pair(body)
  let old_prefix = "refs/remotes/" + old_name + "/"
  if dst.has_prefix(old_prefix) {
    let suffix = String::unsafe_substring(
      dst,
      start=old_prefix.length(),
      end=dst.length(),
    )
    let new_dst = "refs/remotes/" + new_name + "/" + suffix
    let new_body = if has_colon { src + ":" + new_dst } else { new_dst }
    prefix + new_body
  } else {
    spec
  }
}

///|
fn collect_ref_names(
  fs : OsFs,
  dir : String,
  prefix : String,
  out : Array[String],
) -> Unit {
  if not(fs.is_dir(dir)) {
    return ()
  }
  let entries = fs.readdir(dir) catch { _ => [] }
  for entry in entries {
    if entry == "." || entry == ".." {
      continue
    }
    let path = dir + "/" + entry
    let name = if prefix.length() == 0 { entry } else { prefix + "/" + entry }
    if fs.is_dir(path) {
      collect_ref_names(fs, path, name, out)
    } else if fs.is_file(path) {
      out.push(name)
    }
  }
}

///|
fn collect_local_branches(fs : OsFs, git_dir : String) -> Array[String] {
  let out : Array[String] = []
  collect_ref_names(fs, git_dir + "/refs/heads", "", out)
  out
}

///|
fn is_remote_namespace(dst : String, remote_name : String) -> Bool {
  let prefix = "refs/remotes/" + remote_name + "/"
  dst.has_prefix(prefix) || dst == "refs/remotes/" + remote_name
}

///|
fn format_remove_warning(branches : Array[String]) -> String {
  if branches.length() == 0 {
    return ""
  }
  let lines : Array[String] = []
  if branches.length() == 1 {
    lines.push(
      "Note: A branch outside the refs/remotes/ hierarchy was not removed;",
    )
    lines.push("to delete it, use:")
  } else {
    lines.push(
      "Note: Some branches outside the refs/remotes/ hierarchy were not removed;",
    )
    lines.push("to delete them, use:")
  }
  for name in branches {
    lines.push("  git branch -d " + name)
  }
  lines.join("\n") + "\n"
}

///|
fn parse_remote_config(
  content : String,
) -> (Map[String, RemoteConfig], Map[String, BranchConfig]) {
  let remotes : Map[String, RemoteConfig] = {}
  let branches : Map[String, BranchConfig] = {}
  let mut current_section : String? = None
  let mut current_name : String? = None
  for line_view in content.split("\n") {
    let line = trim_string(line_view.to_string())
    if line.length() == 0 || line.has_prefix("#") || line.has_prefix(";") {
      continue
    }
    if line.has_prefix("[") && line.has_suffix("]") {
      let body = String::unsafe_substring(line, start=1, end=line.length() - 1)
      match body.find(" ") {
        Some(idx) => {
          let sec = String::unsafe_substring(body, start=0, end=idx).to_lower()
          let name_part = String::unsafe_substring(
            body,
            start=idx + 1,
            end=body.length(),
          )
          let name = config_strip_quotes(name_part)
          current_section = Some(sec)
          current_name = Some(name)
        }
        None => {
          current_section = Some(body.to_lower())
          current_name = None
        }
      }
      continue
    }
    match line.find("=") {
      Some(eq_idx) => {
        let key = trim_string(
          String::unsafe_substring(line, start=0, end=eq_idx),
        ).to_lower()
        let value = trim_string(
          String::unsafe_substring(line, start=eq_idx + 1, end=line.length()),
        )
        match (current_section, current_name) {
          (Some("remote"), Some(name)) => {
            let rc = remotes
              .get(name)
              .unwrap_or({
                urls: [],
                pushurls: [],
                fetch: [],
                push: [],
                promisor: false,
                partial_clone_filter: None,
              })
            match key {
              "url" => rc.urls.push(value)
              "pushurl" => rc.pushurls.push(value)
              "fetch" => rc.fetch.push(value)
              "push" => rc.push.push(value)
              "promisor" => {
                let v = value.to_lower()
                rc.promisor = v == "true" || v == "1" || v == "yes"
              }
              "partialclonefilter" => rc.partial_clone_filter = Some(value)
              _ => ()
            }
            remotes[name] = rc
          }
          (Some("branch"), Some(name)) => {
            let bc = branches
              .get(name)
              .unwrap_or({ name, remote: None, merges: [], rebase: None })
            match key {
              "remote" => bc.remote = Some(value)
              "merge" => {
                let parts = value.split(" ").collect()
                for p_view in parts {
                  let p = p_view.to_string().trim().to_string()
                  if p.length() > 0 {
                    bc.merges.push(p)
                  }
                }
              }
              "rebase" => {
                let v = value.to_lower()
                if v == "true" || v == "1" || v == "yes" {
                  bc.rebase = Some(true)
                } else if v == "false" || v == "0" || v == "no" {
                  bc.rebase = Some(false)
                }
              }
              _ => ()
            }
            branches[name] = bc
          }
          _ => ()
        }
      }
      None => ()
    }
  }
  (remotes, branches)
}

///|
fn read_repo_config(
  fs : &@git.RepoFileSystem,
  git_dir : String,
) -> (Map[String, RemoteConfig], Map[String, BranchConfig]) {
  let config_path = git_dir + "/config"
  if not(fs.is_file(config_path)) {
    return ({}, {})
  }
  let content = decode_bytes(
    fs.read_file(config_path) catch {
      _ => return ({}, {})
    },
  )
  parse_remote_config(content)
}

///|
fn list_remotes(fs : &@git.RepoFileSystem, git_dir : String) -> Array[String] {
  let (remotes, _) = read_repo_config(fs, git_dir)
  let out : Array[String] = []
  for name, _ in remotes {
    out.push(name)
  }
  out.sort()
  out
}

///|
fn list_remotes_verbose(
  fs : &@git.RepoFileSystem,
  git_dir : String,
) -> Array[(String, String)] {
  let (remotes, _) = read_repo_config(fs, git_dir)
  let out : Array[(String, String)] = []
  let names = list_remotes(fs, git_dir)
  for name in names {
    match remotes.get(name) {
      Some(rc) => {
        if rc.urls.length() == 0 {
          continue
        }
        let url = rc.urls[0]
        let filter = if rc.promisor && rc.partial_clone_filter is Some(f) {
          " [" + f + "]"
        } else {
          ""
        }
        out.push((name, url + " (fetch)" + filter))
        let push_urls = if rc.pushurls.length() > 0 {
          rc.pushurls
        } else {
          rc.urls
        }
        for pu in push_urls {
          out.push((name, pu + " (push)"))
        }
      }
      None => ()
    }
  }
  out
}

///|
fn get_remote_url(
  fs : &@git.RepoFileSystem,
  git_dir : String,
  name : String,
) -> String? {
  let config_path = git_dir + "/config"
  if not(fs.is_file(config_path)) {
    return None
  }
  let content = decode_bytes(
    fs.read_file(config_path) catch {
      _ => return None
    },
  )
  let target_section = "[remote \"\{name}\"]"
  let mut in_section = false
  for line_view in content.split("\n") {
    let line = trim_string(line_view.to_string())
    if line == target_section {
      in_section = true
      continue
    }
    if line.has_prefix("[") {
      in_section = false
      continue
    }
    if in_section && line.has_prefix("url = ") {
      return Some(String::unsafe_substring(line, start=6, end=line.length()))
    }
  }
  None
}

///|
fn remote_add(
  fs : &@git.FileSystem,
  rfs : &@git.RepoFileSystem,
  git_dir : String,
  name : String,
  url : String,
) -> Unit raise @git.GitError {
  let config_path = git_dir + "/config"
  // Check if remote already exists
  if get_remote_url(rfs, git_dir, name) is Some(_) {
    raise @git.GitError::InvalidObject("remote '\{name}' already exists")
  }
  // Read existing config or create new
  let existing = if rfs.is_file(config_path) {
    decode_bytes(rfs.read_file(config_path))
  } else {
    ""
  }
  // Append remote section
  let remote_section = "[remote \"\{name}\"]\n\turl = \{url}\n\tfetch = +refs/heads/*:refs/remotes/\{name}/*\n"
  let new_content = if existing.length() > 0 && not(existing.has_suffix("\n")) {
    existing + "\n" + remote_section
  } else {
    existing + remote_section
  }
  fs.write_string(config_path, new_content)
}

///|
async fn remote_remove(
  fs : &@git.FileSystem,
  rfs : &@git.RepoFileSystem,
  git_dir : String,
  name : String,
) -> Unit raise @git.GitError {
  let config_path = git_dir + "/config"
  if not(rfs.is_file(config_path)) {
    raise @git.GitError::InvalidObject("No such remote '\{name}'")
  }
  let content = decode_bytes(rfs.read_file(config_path))
  let (remotes, _) = parse_remote_config(content)
  let warn_branches : Array[String] = []
  match remotes.get(name) {
    Some(rc) => {
      let fetch_specs = parse_fetch_refspecs(rc.fetch)
      if fetch_specs.length() > 0 {
        let branches = collect_local_branches(OsFs::new(), git_dir)
        for branch in branches {
          let refname = "refs/heads/" + branch
          let mut matched = false
          for spec in fetch_specs {
            if spec.negative {
              continue
            }
            let dst = spec.dst
            if dst.length() == 0 || is_remote_namespace(dst, name) {
              continue
            }
            if refspec_capture(dst, refname) is Some(_) {
              matched = true
              break
            }
          }
          if matched {
            warn_branches.push(branch)
          }
        }
      }
    }
    None => ()
  }
  let blocks = parse_config_blocks(content)
  let new_blocks : Array[ConfigBlock] = []
  let mut found = false
  for block in blocks {
    match (block.section, block.name) {
      (Some("remote"), Some(remote_name)) if remote_name == name => {
        found = true
        continue
      }
      (Some("remote"), None) => {
        let updated = block
        let lines : Array[String] = []
        for line in updated.lines {
          match parse_config_kv(line) {
            Some((key, value)) if key == "pushdefault" && value == name => ()
            _ => lines.push(line)
          }
        }
        updated.lines = lines
        new_blocks.push(updated)
      }
      (Some("branch"), Some(_)) => {
        let updated = block
        let mut branch_remote : String? = None
        for line in updated.lines {
          match parse_config_kv(line) {
            Some((key, value)) if key == "remote" => branch_remote = Some(value)
            _ => ()
          }
        }
        let remove_merge = branch_remote == Some(name)
        let lines : Array[String] = []
        for line in updated.lines {
          match parse_config_kv(line) {
            Some((key, value)) if key == "remote" && value == name => ()
            Some((key, value)) if key == "pushremote" && value == name => ()
            Some((key, _)) if remove_merge && key == "merge" => ()
            _ => lines.push(line)
          }
        }
        updated.lines = lines
        new_blocks.push(updated)
      }
      _ => new_blocks.push(block)
    }
  }
  if not(found) {
    raise @git.GitError::InvalidObject("No such remote '\{name}'")
  }
  fs.write_string(config_path, render_config_blocks(new_blocks))
  remove_remote_refs(OsFs::new(), git_dir, name)
  if warn_branches.length() > 0 {
    warn_branches.sort()
    let msg = format_remove_warning(warn_branches)
    @stdio.stderr.write(str_to_bytes(msg)) catch {
      _ => ()
    }
  }
}

///|
fn remote_set_url(
  fs : &@git.FileSystem,
  rfs : &@git.RepoFileSystem,
  git_dir : String,
  name : String,
  url : String,
) -> Unit raise @git.GitError {
  let config_path = git_dir + "/config"
  if not(rfs.is_file(config_path)) {
    raise @git.GitError::InvalidObject("No such remote '\{name}'")
  }
  let content = decode_bytes(rfs.read_file(config_path))
  let target_section = "[remote \"\{name}\"]"
  let lines : Array[String] = []
  let mut in_target_section = false
  let mut found = false
  let mut url_replaced = false
  for line_view in content.split("\n") {
    let line = line_view.to_string()
    let trimmed = trim_string(line)
    if trimmed == target_section {
      in_target_section = true
      found = true
      lines.push(line)
      continue
    }
    if in_target_section && trimmed.has_prefix("[") {
      in_target_section = false
    }
    if in_target_section && trimmed.has_prefix("url = ") && not(url_replaced) {
      lines.push("\turl = \{url}")
      url_replaced = true
      continue
    }
    lines.push(line)
  }
  if not(found) {
    raise @git.GitError::InvalidObject("No such remote '\{name}'")
  }
  let new_content = lines
    .iter()
    .fold(init="", fn(acc, line) {
      if acc == "" {
        line
      } else {
        acc + "\n" + line
      }
    })
  fs.write_string(config_path, new_content)
}

///|
fn set_config_key(
  fs : &@git.FileSystem,
  rfs : &@git.RepoFileSystem,
  git_dir : String,
  section : String,
  name : String,
  key : String,
  value : String,
) -> Unit raise @git.GitError {
  let config_path = git_dir + "/config"
  let target_section = "[\{section} \"\{name}\"]"
  let content = if rfs.is_file(config_path) {
    decode_bytes(rfs.read_file(config_path))
  } else {
    ""
  }
  let lines : Array[String] = []
  let mut in_section = false
  let mut found_section = false
  let mut key_set = false
  for line_view in content.split("\n") {
    let line = line_view.to_string()
    let trimmed = trim_string(line)
    if trimmed == target_section {
      in_section = true
      found_section = true
      lines.push(line)
      continue
    }
    if in_section && trimmed.has_prefix("[") {
      if not(key_set) {
        lines.push("\t\{key} = \{value}")
        key_set = true
      }
      in_section = false
    }
    if in_section && trimmed.has_prefix("\{key} = ") {
      lines.push("\t\{key} = \{value}")
      key_set = true
      continue
    }
    lines.push(line)
  }
  if found_section {
    if in_section && not(key_set) {
      lines.push("\t\{key} = \{value}")
    }
  } else {
    if lines.length() > 0 && trim_string(lines[lines.length() - 1]) != "" {
      lines.push("")
    }
    lines.push(target_section)
    lines.push("\t\{key} = \{value}")
  }
  let new_content = lines
    .iter()
    .fold(init="", fn(acc, line) {
      if acc == "" {
        line
      } else {
        acc + "\n" + line
      }
    })
  fs.write_string(config_path, new_content)
}

///|
fn copy_tree(
  fs : OsFs,
  src : String,
  dest : String,
) -> Unit raise @git.GitError {
  let is_dir = fs.is_dir(src)
  if is_dir {
    ensure_dir(dest)
    let entries = fs.readdir(src) catch { _ => return () }
    for entry in entries {
      if entry == "." || entry == ".." {
        continue
      }
      let src_path = src + "/" + entry
      let dest_path = dest + "/" + entry
      copy_tree(fs, src_path, dest_path)
    }
    return ()
  }
  let is_file = fs.is_file(src)
  if is_file {
    let data = fs.read_file(src)
    let parent = parent_dir(dest)
    if parent.length() > 0 {
      ensure_dir(parent)
    }
    fs.write_file(dest, data)
  }
}

///|
fn remove_tree(fs : OsFs, path : String) -> Unit {
  let is_dir = fs.is_dir(path)
  if is_dir {
    let entries = fs.readdir(path) catch { _ => [] }
    for entry in entries {
      if entry == "." || entry == ".." {
        continue
      }
      remove_tree(fs, path + "/" + entry)
    }
    fs.remove_dir(path) catch {
      _ => ()
    }
    return ()
  }
  let is_file = fs.is_file(path)
  if is_file {
    fs.remove_file(path) catch {
      _ => ()
    }
  }
}

///|
fn move_tree(
  fs : OsFs,
  src : String,
  dest : String,
) -> Unit raise @git.GitError {
  copy_tree(fs, src, dest)
  remove_tree(fs, src)
}

///|
fn remove_remote_refs(fs : OsFs, git_dir : String, name : String) -> Unit {
  let refs_dir = git_dir + "/refs/remotes/" + name
  if fs.is_dir(refs_dir) {
    remove_tree(fs, refs_dir)
  }
  let logs_dir = git_dir + "/logs/refs/remotes/" + name
  if fs.is_dir(logs_dir) {
    remove_tree(fs, logs_dir)
  }
}

///|
fn remote_rename(
  fs : OsFs,
  rfs : &@git.RepoFileSystem,
  git_dir : String,
  old_name : String,
  new_name : String,
) -> Unit raise @git.GitError {
  let config_path = git_dir + "/config"
  let content = read_config_content(rfs, git_dir)
  let blocks = parse_config_blocks(content)
  let mut found_remote = false
  let new_blocks : Array[ConfigBlock] = []
  for block in blocks {
    match (block.section, block.name) {
      (Some("remote"), Some(remote_name)) if remote_name == old_name => {
        let updated = block
        updated.header = Some("[remote \"\{new_name}\"]")
        let lines : Array[String] = []
        for line in updated.lines {
          match parse_config_kv(line) {
            Some((key, value)) if key == "fetch" => {
              let updated_value = update_fetch_refspec(
                value, old_name, new_name,
              )
              lines.push("\tfetch = " + updated_value)
            }
            _ => lines.push(line)
          }
        }
        updated.lines = lines
        new_blocks.push(updated)
        found_remote = true
      }
      (Some("branch"), Some(_)) => {
        let updated = block
        let lines : Array[String] = []
        for line in updated.lines {
          match parse_config_kv(line) {
            Some((key, value)) if key == "remote" && value == old_name =>
              lines.push("\tremote = " + new_name)
            Some((key, value)) if key == "pushremote" && value == old_name =>
              lines.push("\tpushRemote = " + new_name)
            _ => lines.push(line)
          }
        }
        updated.lines = lines
        new_blocks.push(updated)
      }
      (Some("remote"), None) => {
        let updated = block
        let lines : Array[String] = []
        for line in updated.lines {
          match parse_config_kv(line) {
            Some((key, value)) if key == "pushdefault" && value == old_name =>
              lines.push("\tpushDefault = " + new_name)
            _ => lines.push(line)
          }
        }
        updated.lines = lines
        new_blocks.push(updated)
      }
      _ => new_blocks.push(block)
    }
  }
  let legacy_remotes = git_dir + "/remotes/" + old_name
  let legacy_branches = git_dir + "/branches/" + old_name
  if not(found_remote) && fs.is_file(legacy_remotes) {
    let text = decode_bytes(fs.read_file(legacy_remotes))
    let mut url : String? = None
    let fetches : Array[String] = []
    let pushes : Array[String] = []
    for line_view in text.split("\n") {
      let trimmed = trim_string(line_view.to_string())
      if trimmed.has_prefix("URL:") {
        url = Some(
          trim_string(
            String::unsafe_substring(trimmed, start=4, end=trimmed.length()),
          ),
        )
      } else if trimmed.has_prefix("Push:") {
        let val = trim_string(
          String::unsafe_substring(trimmed, start=5, end=trimmed.length()),
        )
        if val.length() > 0 {
          pushes.push(val)
        }
      } else if trimmed.has_prefix("Pull:") {
        let val = trim_string(
          String::unsafe_substring(trimmed, start=5, end=trimmed.length()),
        )
        if val.length() > 0 {
          fetches.push(val)
        }
      }
    }
    match url {
      Some(u) => {
        let lines : Array[String] = []
        lines.push("\turl = " + u)
        for fetch in fetches {
          lines.push("\tfetch = " + fetch)
        }
        for push in pushes {
          lines.push("\tpush = " + push)
        }
        new_blocks.push({
          header: Some("[remote \"\{new_name}\"]"),
          section: Some("remote"),
          name: Some(new_name),
          lines,
        })
        fs.remove_file(legacy_remotes) catch {
          _ => ()
        }
        found_remote = true
      }
      None => ()
    }
  }
  if not(found_remote) && fs.is_file(legacy_branches) {
    let text = decode_bytes(fs.read_file(legacy_branches)).trim().to_string()
    if text.length() > 0 {
      let (url, branch) = match text.find("#") {
        Some(idx) => {
          let u = String::unsafe_substring(text, start=0, end=idx)
          let b = String::unsafe_substring(
            text,
            start=idx + 1,
            end=text.length(),
          )
          (u, b)
        }
        None => (text, "master")
      }
      let branch_name = if branch.length() > 0 { branch } else { "master" }
      let fetch = "refs/heads/" + branch_name + ":refs/heads/" + new_name
      let push = "HEAD:refs/heads/" + branch_name
      let lines : Array[String] = []
      lines.push("\turl = " + url)
      lines.push("\tfetch = " + fetch)
      lines.push("\tpush = " + push)
      new_blocks.push({
        header: Some("[remote \"\{new_name}\"]"),
        section: Some("remote"),
        name: Some(new_name),
        lines,
      })
      fs.remove_file(legacy_branches) catch {
        _ => ()
      }
      found_remote = true
    }
  }
  if not(found_remote) {
    raise @git.GitError::InvalidObject("No such remote '\{old_name}'")
  }
  fs.write_string(config_path, render_config_blocks(new_blocks))
  if old_name != new_name {
    let old_refs = git_dir + "/refs/remotes/" + old_name
    let new_refs = git_dir + "/refs/remotes/" + new_name
    if fs.is_dir(old_refs) {
      move_tree(fs, old_refs, new_refs)
    }
    let old_logs = git_dir + "/logs/refs/remotes/" + old_name
    let new_logs = git_dir + "/logs/refs/remotes/" + new_name
    if fs.is_dir(old_logs) {
      move_tree(fs, old_logs, new_logs)
    }
    let head_path = git_dir + "/refs/remotes/" + new_name + "/HEAD"
    if fs.is_file(head_path) {
      let head_text = decode_bytes(fs.read_file(head_path))
      let old_prefix = "ref: refs/remotes/" + old_name + "/"
      if head_text.has_prefix(old_prefix) {
        let rest = String::unsafe_substring(
          head_text,
          start=old_prefix.length(),
          end=head_text.length(),
        )
        fs.write_string(head_path, "ref: refs/remotes/" + new_name + "/" + rest)
      }
    }
  }
}

///|
enum RemoteHeadState {
  Missing
  Symref(String)
  Detached(String)
  Other(String)
}

///|
fn split_whitespace_all(s : String) -> Array[String] {
  let result : Array[String] = []
  let current = StringBuilder::new()
  let mut in_word = false
  for c in s {
    if c == ' ' || c == '\t' || c == '\n' || c == '\r' {
      if in_word {
        result.push(current.to_string())
        current.reset()
        in_word = false
      }
    } else {
      current.write_char(c)
      in_word = true
    }
  }
  if in_word {
    result.push(current.to_string())
  }
  result
}

///|
fn parse_bool_value(value : String) -> Bool? {
  let lower = value.to_lower()
  if lower == "true" || lower == "1" || lower == "yes" {
    Some(true)
  } else if lower == "false" || lower == "0" || lower == "no" {
    Some(false)
  } else {
    None
  }
}

///|
fn remote_skip_default_update(
  blocks : Array[ConfigBlock],
  name : String,
) -> Bool {
  for block in blocks {
    if block.section == Some("remote") && block.name == Some(name) {
      for line in block.lines {
        match parse_config_kv(line) {
          Some((key, value)) if key == "skipdefaultupdate" =>
            return parse_bool_value(value).unwrap_or(false)
          _ => ()
        }
      }
    }
  }
  false
}

///|
fn read_local_remote_head_state(
  fs : OsFs,
  head_path : String,
  remote_name : String,
) -> RemoteHeadState {
  if not(fs.is_file(head_path)) {
    return RemoteHeadState::Missing
  }
  let content = try? fs.read_file(head_path)
  match content {
    Err(_) => RemoteHeadState::Missing
    Ok(data) => {
      let line = trim_string(decode_bytes(data))
      if line.has_prefix("ref: ") {
        let target = String::unsafe_substring(line, start=5, end=line.length())
        let prefix = "refs/remotes/" + remote_name + "/"
        if target.has_prefix(prefix) {
          let branch = String::unsafe_substring(
            target,
            start=prefix.length(),
            end=target.length(),
          )
          RemoteHeadState::Symref(branch)
        } else {
          RemoteHeadState::Other(target)
        }
      } else {
        RemoteHeadState::Detached(line)
      }
    }
  }
}

///|
fn read_remote_head_branch(fs : OsFs, remote_git_dir : String) -> String? {
  let head_path = remote_git_dir + "/HEAD"
  if not(fs.is_file(head_path)) {
    return None
  }
  let content = try? fs.read_file(head_path)
  match content {
    Err(_) => None
    Ok(data) => {
      let line = trim_string(decode_bytes(data))
      if line.has_prefix("ref: ") {
        let refname = String::unsafe_substring(line, start=5, end=line.length())
        if refname.has_prefix("refs/heads/") {
          Some(
            String::unsafe_substring(refname, start=11, end=refname.length()),
          )
        } else {
          None
        }
      } else {
        None
      }
    }
  }
}

///|
fn update_follow_remote_head(
  fs : OsFs,
  git_dir : String,
  name : String,
) -> Unit raise @git.GitError {
  let config_path = git_dir + "/config"
  guard fs.is_file(config_path) else { return () }
  let content = decode_bytes(fs.read_file(config_path))
  let blocks = parse_config_blocks(content)
  let new_blocks : Array[ConfigBlock] = []
  let mut changed = false
  for block in blocks {
    if block.section == Some("remote") && block.name == Some(name) {
      let updated = block
      let lines : Array[String] = []
      for line in updated.lines {
        match parse_config_kv(line) {
          Some((key, value)) if key == "followremotehead" =>
            if value.to_lower() == "always" {
              lines.push("\tfollowRemoteHEAD = warn")
              changed = true
            } else {
              lines.push(line)
            }
          _ => lines.push(line)
        }
      }
      updated.lines = lines
      new_blocks.push(updated)
    } else {
      new_blocks.push(block)
    }
  }
  if changed {
    fs.write_string(config_path, render_config_blocks(new_blocks))
  }
}

///|
fn remove_ref_path(fs : OsFs, path : String) -> Unit {
  if fs.is_dir(path) {
    remove_tree(fs, path)
  } else if fs.is_file(path) {
    fs.remove_file(path) catch {
      _ => ()
    }
  }
}

///|
async fn remote_prune(
  fs : OsFs,
  git_dir : String,
  root : String,
  name : String,
  dry_run : Bool,
) -> Unit raise Error {
  let (remotes, _) = read_repo_config(fs, git_dir)
  let rc = match remotes.get(name) {
    Some(r) => r
    None => raise @git.GitError::InvalidObject("No such remote '\{name}'")
  }
  guard rc.urls.length() > 0 else {
    raise @git.GitError::InvalidObject("No remote configured")
  }
  let url = rc.urls[0]
  print_line("Pruning \{name}")
  print_line("URL: \{url}")
  let local_root = match @sys.get_env_var("GIT_SHIM_PWD") {
    Some(pwd) => pwd
    None => root
  }
  let remote_path = resolve_local_repo_path(fs, local_root, url)
  guard remote_path is Some(path) else { return () }
  let remote_git_dir = detect_git_dir(fs, path).map(fn(pair) { pair.0 })
  guard remote_git_dir is Some(rgd) else { return () }
  let (_, remote_branches) = @gitlib.list_branches(fs, rgd)
  let remote_refs : Map[String, Bool] = {}
  for b in remote_branches {
    remote_refs["refs/heads/" + b.name] = true
  }
  let fetch_specs = parse_fetch_refspecs(rc.fetch)
  if fetch_specs.length() == 0 {
    fetch_specs.push({
      negative: false,
      src: "refs/heads/*",
      dst: "refs/remotes/" + name + "/*",
    })
  }
  let local_refs : Array[String] = []
  collect_ref_names(fs, git_dir + "/refs", "refs", local_refs)
  local_refs.sort()
  let pruned : Array[String] = []
  for local_ref in local_refs {
    if local_ref.has_suffix("/HEAD") {
      continue
    }
    let mut matched = false
    let mut remote_ref : String? = None
    for spec in fetch_specs {
      if spec.negative {
        continue
      }
      if spec.dst.length() == 0 {
        continue
      }
      if refspec_capture(spec.dst, local_ref) is Some(_) {
        matched = true
        remote_ref = refspec_map_dst(spec.dst, spec.src, local_ref)
        break
      }
    }
    if not(matched) {
      continue
    }
    match remote_ref {
      Some(rref) =>
        if not(remote_refs.contains(rref)) {
          let display = local_ref.replace(old="refs/remotes/", new="")
          if dry_run {
            print_line(" * [would prune] \{display}")
          } else {
            remove_ref_path(fs, git_dir + "/" + local_ref)
            remove_ref_path(fs, git_dir + "/logs/" + local_ref)
            print_line(" * [pruned] \{display}")
            pruned.push(local_ref)
          }
        }
      None => ()
    }
  }
  if not(dry_run) {
    let head_path = git_dir + "/refs/remotes/" + name + "/HEAD"
    if fs.is_file(head_path) {
      let state = read_local_remote_head_state(fs, head_path, name)
      match state {
        RemoteHeadState::Symref(branch) => {
          let ref_path = git_dir + "/refs/remotes/" + name + "/" + branch
          if not(fs.is_file(ref_path)) {
            print_line("warning: refs/remotes/\{name}/HEAD has become dangling")
          }
        }
        _ => ()
      }
    }
  }
}

///|
async fn remote_update(
  fs : OsFs,
  git_dir : String,
  root : String,
  targets : Array[String],
  prune : Bool,
) -> Unit raise Error {
  let (remotes, _) = read_repo_config(fs, git_dir)
  let config_path = git_dir + "/config"
  let blocks = parse_config_blocks(read_config_content(fs, git_dir))
  let names : Array[String] = []
  let seen : Map[String, Bool] = {}
  let mut default_update = false
  if targets.length() == 0 {
    default_update = true
    for name, _ in remotes {
      if not(seen.contains(name)) {
        seen[name] = true
        names.push(name)
      }
    }
  } else {
    for target in targets {
      if target == "default" {
        let group = read_config_value(fs, config_path, "remotes", "default")
        match group {
          Some(value) => {
            let items = split_whitespace_all(value)
            for name in items {
              if not(seen.contains(name)) {
                seen[name] = true
                names.push(name)
              }
            }
          }
          None => {
            default_update = true
            for name, _ in remotes {
              if not(seen.contains(name)) {
                seen[name] = true
                names.push(name)
              }
            }
          }
        }
        continue
      }
      let group = read_config_value(fs, config_path, "remotes", target)
      match group {
        Some(value) => {
          let items = split_whitespace_all(value)
          for name in items {
            if not(seen.contains(name)) {
              seen[name] = true
              names.push(name)
            }
          }
        }
        None =>
          if not(seen.contains(target)) {
            seen[target] = true
            names.push(target)
          }
      }
    }
  }
  for name in names {
    if default_update && remote_skip_default_update(blocks, name) {
      continue
    }
    match remotes.get(name) {
      Some(rc) =>
        if rc.urls.length() > 0 {
          let url = rc.urls[0]
          fetch_from_remote(fs, git_dir, root, name, url)
          if prune {
            remote_prune(fs, git_dir, root, name, false)
          }
        }
      None => ()
    }
  }
}

///|
fn remote_set_head_delete(
  fs : OsFs,
  git_dir : String,
  name : String,
) -> Unit raise @git.GitError {
  let head_path = git_dir + "/refs/remotes/" + name + "/HEAD"
  if fs.is_file(head_path) {
    fs.remove_file(head_path)
  }
}

///|
fn remote_set_head_explicit(
  fs : OsFs,
  git_dir : String,
  name : String,
  branch : String,
) -> Unit raise @git.GitError {
  let head_path = git_dir + "/refs/remotes/" + name + "/HEAD"
  let parent = parent_dir(head_path)
  if parent.length() > 0 {
    ensure_dir(parent)
  }
  fs.write_string(head_path, "ref: refs/remotes/" + name + "/" + branch + "\n")
}

///|
async fn remote_set_head_auto(
  fs : OsFs,
  git_dir : String,
  root : String,
  name : String,
) -> Unit raise Error {
  let head_path = git_dir + "/refs/remotes/" + name + "/HEAD"
  if fs.is_file(head_path + ".lock") {
    die_remote(1, "error: Could not set up refs/remotes/\{name}/HEAD")
  }
  let url = get_remote_url(fs, git_dir, name).unwrap_or("")
  if url.length() == 0 {
    raise @git.GitError::InvalidObject("No remote configured")
  }
  let local_root = match @sys.get_env_var("GIT_SHIM_PWD") {
    Some(pwd) => pwd
    None => root
  }
  let remote_path = resolve_local_repo_path(fs, local_root, url)
  guard remote_path is Some(path) else { return () }
  let remote_git_dir = detect_git_dir(fs, path).map(fn(pair) { pair.0 })
  guard remote_git_dir is Some(rgd) else { return () }
  let new_branch = read_remote_head_branch(fs, rgd).unwrap_or("")
  if new_branch.length() == 0 {
    return ()
  }
  let state = read_local_remote_head_state(fs, head_path, name)
  let parent = parent_dir(head_path)
  if parent.length() > 0 {
    ensure_dir(parent)
  }
  fs.write_string(
    head_path,
    "ref: refs/remotes/" + name + "/" + new_branch + "\n",
  )
  let quoted = "'\{name}/HEAD'"
  match state {
    RemoteHeadState::Missing =>
      print_line("\{quoted} is now created and points to '\{new_branch}'")
    RemoteHeadState::Detached(old) =>
      print_line(
        "\{quoted} was detached at '\{old}' and now points to '\{new_branch}'",
      )
    RemoteHeadState::Other(old) =>
      print_line(
        "\{quoted} used to point to '\{old}' (which is not a remote branch), but now points to '\{new_branch}'",
      )
    RemoteHeadState::Symref(old) =>
      if old == new_branch {
        print_line("\{quoted} is unchanged and points to '\{new_branch}'")
      } else {
        print_line(
          "\{quoted} has changed from '\{old}' and now points to '\{new_branch}'",
        )
      }
  }
  update_follow_remote_head(fs, git_dir, name)
}

///|
fn is_http_url(url : String) -> Bool {
  url.has_prefix("http://") || url.has_prefix("https://")
}

///|
fn strip_file_scheme(url : String) -> String? {
  if url.has_prefix("file://") {
    Some(String::unsafe_substring(url, start=7, end=url.length()))
  } else {
    None
  }
}

///|
fn resolve_local_repo_path(fs : OsFs, root : String, url : String) -> String? {
  let raw = match strip_file_scheme(url) {
    Some(path) => path
    None => url
  }
  if is_http_url(raw) || raw.has_prefix("git@") {
    return None
  }
  let candidate = if raw.has_prefix("/") {
    raw
  } else {
    normalize_path(root + "/" + raw)
  }
  let exists = fs.is_dir(candidate)
  if exists {
    Some(candidate)
  } else {
    None
  }
}

///|
fn detect_git_dir(fs : OsFs, path : String) -> (String, Bool)? {
  let bare_head = fs.is_file(path + "/HEAD")
  let bare_objs = fs.is_dir(path + "/objects")
  if bare_head && bare_objs {
    return Some((path, true))
  }
  let git_path = path + "/.git"
  if fs.is_dir(git_path) || fs.is_file(git_path) {
    let resolved = resolve_gitdir(fs, git_path)
    return Some((resolved, false))
  }
  None
}

///|
fn write_ref_file(
  fs : OsFs,
  git_dir : String,
  refname : String,
  id : @git.ObjectId,
) -> Unit raise @git.GitError {
  let path = git_dir + "/" + refname
  let dir = parent_dir(path)
  if dir.length() > 0 {
    ensure_dir(dir)
  }
  fs.write_string(path, id.to_hex() + "\n")
}

///|
fn write_symref_file(
  fs : OsFs,
  git_dir : String,
  refname : String,
  target : String,
) -> Unit raise @git.GitError {
  let path = git_dir + "/" + refname
  let dir = parent_dir(path)
  if dir.length() > 0 {
    ensure_dir(dir)
  }
  fs.write_string(path, "ref: " + target + "\n")
}

///|
fn clone_local_repo(
  fs : OsFs,
  src_path : String,
  dest_path : String,
  remote_url : String,
  bare : Bool,
  filter : @git.FilterSpec,
) -> Unit raise Error {
  guard detect_git_dir(fs, src_path) is Some((src_git_dir, _)) else {
    raise @git.GitError::InvalidObject("Not a git repository: \{src_path}")
  }
  let (head_ref, branches) = @gitlib.list_branches(fs, src_git_dir)
  let (default_branch, head_id) = match head_ref {
    @gitlib.HeadRef::Branch(name) => {
      let refname = "refs/heads/" + name
      let id = match @gitlib.resolve_ref(fs, src_git_dir, refname) {
        Some(v) => v
        None =>
          raise @git.GitError::InvalidObject("Invalid HEAD ref: \{refname}")
      }
      (name, id)
    }
    @gitlib.HeadRef::Detached(id) => ("main", id)
  }
  @gitlib.init_repo(fs, dest_path, default_branch~, bare~)
  let dest_git_dir = if bare { dest_path } else { dest_path + "/.git" }
  // Copy object database
  copy_tree(fs, src_git_dir + "/objects", dest_git_dir + "/objects")
  // Set local HEAD branch to source HEAD
  write_ref_file(fs, dest_git_dir, "refs/heads/" + default_branch, head_id)
  // Configure origin
  remote_add(fs, fs, dest_git_dir, "origin", remote_url)
  if not(bare) {
    set_config_key(
      fs, fs, dest_git_dir, "branch", default_branch, "remote", "origin",
    )
    set_config_key(
      fs,
      fs,
      dest_git_dir,
      "branch",
      default_branch,
      "merge",
      "refs/heads/" + default_branch,
    )
  }
  // Set remote tracking refs
  for b in branches {
    write_ref_file(fs, dest_git_dir, "refs/remotes/origin/" + b.name, b.id)
  }
  write_symref_file(
    fs,
    dest_git_dir,
    "refs/remotes/origin/HEAD",
    "refs/remotes/origin/" + default_branch,
  )
  // Partial clone markers
  if filter.is_partial() {
    set_config_key(fs, fs, dest_git_dir, "remote", "origin", "promisor", "true")
    set_config_key(
      fs,
      fs,
      dest_git_dir,
      "remote",
      "origin",
      "partialCloneFilter",
      filter.to_string(),
    )
    let promisor_path = dest_git_dir + "/objects/info/promisor"
    fs.write_string(promisor_path, remote_url + "\n")
  }
  // Copy working tree for non-bare
  if not(bare) {
    let entries = fs.readdir(src_path) catch { _ => [] }
    for entry in entries {
      if entry == ".git" {
        continue
      }
      copy_tree(fs, src_path + "/" + entry, dest_path + "/" + entry)
    }
    let db = @gitlib.ObjectDb::load(fs, dest_git_dir)
    let files = @gitlib.collect_tree_files_from_commit(db, fs, head_id)
    let index_entries = @gitlib.tree_files_to_index(db, fs, files)
    @gitlib.write_index_entries(fs, dest_git_dir, index_entries)
  }
}

///|
fn fetch_local_repo(
  fs : OsFs,
  src_path : String,
  git_dir : String,
  remote_name : String,
) -> Unit raise Error {
  guard detect_git_dir(fs, src_path) is Some((src_git_dir, _)) else {
    raise @git.GitError::InvalidObject("Not a git repository: \{src_path}")
  }
  copy_tree(fs, src_git_dir + "/objects", git_dir + "/objects")
  let (head_ref, branches) = @gitlib.list_branches(fs, src_git_dir)
  for b in branches {
    write_ref_file(
      fs,
      git_dir,
      "refs/remotes/" + remote_name + "/" + b.name,
      b.id,
    )
  }
  match head_ref {
    @gitlib.HeadRef::Branch(name) =>
      write_symref_file(
        fs,
        git_dir,
        "refs/remotes/" + remote_name + "/HEAD",
        "refs/remotes/" + remote_name + "/" + name,
      )
    _ => ()
  }
}

///|
async fn fetch_from_remote(
  fs : OsFs,
  git_dir : String,
  root : String,
  remote_name : String,
  remote_url : String,
) -> Unit raise Error {
  let local_root = match @sys.get_env_var("GIT_SHIM_PWD") {
    Some(pwd) => pwd
    None => root
  }
  match resolve_local_repo_path(fs, local_root, remote_url) {
    Some(src_path) => {
      fetch_local_repo(fs, src_path, git_dir, remote_name)
      return ()
    }
    None => ()
  }
  // Fallback to HTTP fetch
  let (refs, _caps, _version, symrefs) = @git.discover_upload_refs_http(
    remote_url, true,
  )
  let default_ref = @git.select_default_ref(refs, symrefs)
  match default_ref {
    None => {
      print_line("No refs to fetch")
      return ()
    }
    Some((refname, commit_id)) => {
      let remote_ref = if refname.has_prefix("refs/heads/") {
        let name = String::unsafe_substring(
          refname,
          start=11,
          end=refname.length(),
        )
        "refs/remotes/" + remote_name + "/" + name
      } else {
        "refs/remotes/" + remote_name + "/HEAD"
      }
      let remote_path = git_dir + "/" + remote_ref
      let mut prev_id : @git.ObjectId? = None
      if fs.is_file(remote_path) {
        let content = decode_bytes(
          fs.read_file(remote_path) catch {
            _ => Bytes::default()
          },
        )
        let hex = trim_string(content)
        if hex.length() > 0 {
          prev_id = Some(@git.ObjectId::from_hex(hex)) catch { _ => None }
        }
      }
      if prev_id is Some(pid) && pid == commit_id {
        return ()
      }
      print_line("Fetching from \{remote_url}...")
      let pack = @git.fetch_pack_http(remote_url, [commit_id], true)
      let objects = @git.parse_packfile(pack)
      @git.write_packfile_with_index(fs, git_dir, pack, objects)
      let dir = match remote_path.rev_find("/") {
        None => ""
        Some(i) => String::unsafe_substring(remote_path, start=0, end=i)
      }
      if dir.length() > 0 {
        fs.mkdir_p(dir)
      }
      fs.write_string(remote_path, commit_id.to_hex() + "\n")
      print_line("From \{remote_url}")
      match prev_id {
        None => print_line(" * [new branch] \{refname} -> \{remote_ref}")
        Some(pid) =>
          print_line(
            "   \{pid.to_hex()}..\{commit_id.to_hex()}  \{refname} -> \{remote_ref}",
          )
      }
    }
  }
}

///|
fn parse_refspec_pair(spec : String) -> (String, String) {
  match spec.find(":") {
    Some(idx) => {
      let src = if idx == 0 {
        ""
      } else {
        String::unsafe_substring(spec, start=0, end=idx)
      }
      let dst = if idx + 1 >= spec.length() {
        ""
      } else {
        String::unsafe_substring(spec, start=idx + 1, end=spec.length())
      }
      (src, dst)
    }
    None => (spec, spec)
  }
}

///|
fn parse_fetch_refspecs(specs : Array[String]) -> Array[FetchRefspec] {
  let out : Array[FetchRefspec] = []
  for raw in specs {
    let mut negative = false
    let mut s = raw
    if s.has_prefix("^") {
      negative = true
      s = String::unsafe_substring(s, start=1, end=s.length())
    }
    if s.has_prefix("+") {
      s = String::unsafe_substring(s, start=1, end=s.length())
    }
    let (src, dst) = parse_refspec_pair(s)
    out.push({ negative, src, dst })
  }
  out
}

///|
fn parse_push_refspecs(specs : Array[String]) -> Array[PushRefspec] {
  let out : Array[PushRefspec] = []
  for raw in specs {
    let mut force = false
    let mut s = raw
    if s.has_prefix("+") {
      force = true
      s = String::unsafe_substring(s, start=1, end=s.length())
    }
    let (src, dst) = parse_refspec_pair(s)
    out.push({ force, src, dst })
  }
  out
}

///|
fn refspec_capture(pattern : String, refname : String) -> String? {
  match pattern.find("*") {
    None => if pattern == refname { Some("") } else { None }
    Some(idx) => {
      let prefix = String::unsafe_substring(pattern, start=0, end=idx)
      let suffix = String::unsafe_substring(
        pattern,
        start=idx + 1,
        end=pattern.length(),
      )
      if refname.has_prefix(prefix) &&
        refname.has_suffix(suffix) &&
        refname.length() >= prefix.length() + suffix.length() {
        let mid = String::unsafe_substring(
          refname,
          start=prefix.length(),
          end=refname.length() - suffix.length(),
        )
        Some(mid)
      } else {
        None
      }
    }
  }
}

///|
fn refspec_map_dst(
  src_pat : String,
  dst_pat : String,
  refname : String,
) -> String? {
  match refspec_capture(src_pat, refname) {
    None => None
    Some(mid) =>
      match dst_pat.find("*") {
        Some(idx) => {
          let prefix = String::unsafe_substring(dst_pat, start=0, end=idx)
          let suffix = String::unsafe_substring(
            dst_pat,
            start=idx + 1,
            end=dst_pat.length(),
          )
          Some(prefix + mid + suffix)
        }
        None => Some(dst_pat)
      }
  }
}

///|
fn list_remote_tracking_refs(
  fs : OsFs,
  git_dir : String,
  remote_name : String,
) -> Map[String, @git.ObjectId] {
  let refs_dir = git_dir + "/refs/remotes/" + remote_name
  let out : Map[String, @git.ObjectId] = {}
  if not(fs.is_dir(refs_dir)) {
    return out
  }
  let stack : Array[(String, String)] = [(refs_dir, "")]
  while stack.length() > 0 {
    let (dir, prefix) = stack.pop().unwrap_or(("", ""))
    if dir.length() == 0 {
      continue
    }
    let entries = fs.readdir(dir) catch { _ => [] }
    for entry in entries {
      if entry == "." || entry == ".." {
        continue
      }
      let path = dir + "/" + entry
      let name = if prefix.length() == 0 { entry } else { prefix + "/" + entry }
      if fs.is_dir(path) {
        stack.push((path, name))
      } else if fs.is_file(path) {
        if name == "HEAD" {
          continue
        }
        let content = decode_bytes(fs.read_file(path) catch { _ => continue })
        let hex = trim_string(content)
        if hex.length() > 0 {
          let id = @git.ObjectId::from_hex(hex) catch { _ => continue }
          out[name] = id
        }
      }
    }
  }
  out
}

///|
fn normalize_remote_branch_name(refname : String) -> String {
  if refname.has_prefix("refs/heads/") {
    String::unsafe_substring(refname, start=11, end=refname.length())
  } else {
    refname
  }
}

///|
fn is_ancestor_commit(
  db : @gitlib.ObjectDb,
  fs : &@git.RepoFileSystem,
  ancestor : @git.ObjectId,
  commit_id : @git.ObjectId,
) -> Bool {
  let stack : Array[@git.ObjectId] = [commit_id]
  let seen : Map[String, Bool] = {}
  while stack.length() > 0 {
    let id = stack.pop().unwrap_or(ancestor)
    let hex = id.to_hex()
    if seen.contains(hex) {
      continue
    }
    seen[hex] = true
    if id == ancestor {
      return true
    }
    let obj = db.get(fs, id) catch { _ => continue }
    guard obj is Some(o) else { continue }
    let info = @git.parse_commit(o.data) catch { _ => continue }
    for p in info.parents {
      stack.push(p)
    }
  }
  false
}

///|
fn format_push_lines(
  lines : Array[(String, String, String, String?)],
  include_status : Bool,
) -> Array[String] {
  let out : Array[String] = []
  if lines.length() == 0 {
    return out
  }
  let mut max_src = 0
  for item in lines {
    let (src, _action, _dst, _status) = item
    if src.length() > max_src {
      max_src = src.length()
    }
  }
  for item in lines {
    let (src, action, dst, status) = item
    let mut base = src
    if src.length() < max_src {
      let mut pad = ""
      for _ in 0..<(max_src - src.length()) {
        pad = pad + " "
      }
      base = base + pad
    }
    let mut line = "    " + base + " " + action + " " + dst
    if include_status && status is Some(st) {
      let target_col = 24
      let current = line.length() - 4
      if current < target_col {
        let mut pad = ""
        for _ in 0..<(target_col - current) {
          pad = pad + " "
        }
        line = line + pad + st
      } else {
        line = line + " " + st
      }
    }
    out.push(line)
  }
  out
}

///|
async fn remote_show(
  fs : OsFs,
  git_dir : String,
  root : String,
  name : String,
  no_query : Bool,
) -> Unit raise Error {
  let (remotes, branches) = read_repo_config(fs, git_dir)
  guard remotes.get(name) is Some(rc) else {
    raise @git.GitError::InvalidObject("No such remote '\{name}'")
  }
  let fetch_url = if rc.urls.length() > 0 { rc.urls[0] } else { "" }
  let push_url = if rc.pushurls.length() > 0 {
    rc.pushurls[0]
  } else {
    fetch_url
  }
  print_line("* remote \{name}")
  print_line("  Fetch URL: \{fetch_url}")
  print_line("  Push  URL: \{push_url}")
  let local_root = match @sys.get_env_var("GIT_SHIM_PWD") {
    Some(pwd) => pwd
    None => root
  }
  let remote_path = if no_query {
    None
  } else {
    resolve_local_repo_path(fs, local_root, fetch_url)
  }
  let remote_git_dir = match remote_path {
    Some(p) => detect_git_dir(fs, p).map(fn(pair) { pair.0 })
    None => None
  }
  let head_branch = match remote_git_dir {
    Some(rgd) =>
      match @gitlib.read_head_ref(fs, rgd) {
        @gitlib.HeadRef::Branch(b) => b
        _ => "(unknown)"
      }
    None => "(not queried)"
  }
  print_line("  HEAD branch: \{head_branch}")
  if no_query || remote_git_dir is None {
    print_line("  Remote branches: (status not queried)")
    let local_refs = list_remote_tracking_refs(fs, git_dir, name)
    let keys : Array[String] = []
    for k, _ in local_refs {
      keys.push(k)
    }
    keys.sort()
    for k in keys {
      print_line("    \{k}")
    }
  } else {
    print_line("  Remote branches:")
    let rgd = remote_git_dir.unwrap_or("")
    let (_rhead, remote_branches) = @gitlib.list_branches(fs, rgd)
    let remote_map : Map[String, @git.ObjectId] = {}
    for b in remote_branches {
      remote_map[b.name] = b.id
    }
    let local_refs = list_remote_tracking_refs(fs, git_dir, name)
    let fetch_specs = parse_fetch_refspecs(rc.fetch)
    if fetch_specs.length() == 0 {
      fetch_specs.push({
        negative: false,
        src: "refs/heads/*",
        dst: "refs/remotes/" + name + "/*",
      })
    }
    let negative_specs : Array[FetchRefspec] = []
    let positive_specs : Array[FetchRefspec] = []
    for s in fetch_specs {
      if s.negative {
        negative_specs.push(s)
      } else {
        positive_specs.push(s)
      }
    }
    let remote_names : Array[String] = []
    for rname, _ in remote_map {
      remote_names.push(rname)
    }
    remote_names.sort()
    let emitted : Map[String, Bool] = {}
    for rname in remote_names {
      let full_ref = "refs/heads/" + rname
      let mut excluded = false
      for s in negative_specs {
        if refspec_capture(s.src, full_ref) is Some(_) {
          excluded = true
          break
        }
      }
      if excluded {
        if local_refs.contains(rname) {
          print_line("    \{rname} stale (use 'git remote prune' to remove)")
        } else {
          print_line("    \{rname} skipped")
        }
        emitted[rname] = true
        continue
      }
      let mut dest_ok = false
      for s in positive_specs {
        if refspec_map_dst(s.src, s.dst, full_ref) is Some(_) {
          dest_ok = true
          break
        }
      }
      if not(dest_ok) {
        continue
      }
      if local_refs.contains(rname) {
        print_line("    \{rname} tracked")
      } else {
        print_line(
          "    \{rname} new (next fetch will store in remotes/\{name})",
        )
      }
      emitted[rname] = true
    }
    for lname, _ in local_refs {
      if not(emitted.contains(lname)) {
        print_line("    \{lname} stale (use 'git remote prune' to remove)")
      }
    }
  }
  let pull_branches : Array[BranchConfig] = []
  for _, bc in branches {
    if bc.remote is Some(rn) && rn == name && bc.merges.length() > 0 {
      pull_branches.push(bc)
    }
  }
  if pull_branches.length() > 0 {
    print_line("  Local branches configured for 'git pull':")
    pull_branches.sort_by(fn(a, b) { a.name.compare(b.name) })
    for bc in pull_branches {
      let branch = bc.name
      let merge_target = normalize_remote_branch_name(bc.merges[0])
      match bc.rebase {
        Some(true) => {
          let padded = pad_right(branch, 8)
          print_line("    \{padded}rebases onto remote \{merge_target}")
        }
        _ => {
          let padded = pad_right(branch, 8)
          print_line("    \{padded} merges with remote \{merge_target}")
          if bc.merges.length() > 1 {
            for i in 1..<bc.merges.length() {
              let m = normalize_remote_branch_name(bc.merges[i])
              print_line("                and with remote \{m}")
            }
          }
        }
      }
    }
  }
  if rc.push.length() > 0 || no_query {
    let status_query = not(no_query) && remote_git_dir is Some(_)
    if status_query {
      print_line("  Local refs configured for 'git push':")
    } else {
      print_line("  Local refs configured for 'git push' (status not queried):")
    }
    let push_specs = parse_push_refspecs(rc.push)
    if push_specs.length() == 0 {
      push_specs.push({ force: false, src: "", dst: "" })
    }
    let push_lines : Array[(String, String, String, String?)] = []
    let local_db = @gitlib.ObjectDb::load(fs, git_dir)
    let remote_db = match remote_git_dir {
      Some(rgd) => Some(@gitlib.ObjectDb::load(fs, rgd))
      None => None
    }
    for spec in push_specs {
      let src_display = if spec.src.length() == 0 {
        "(matching)"
      } else {
        spec.src
      }
      let dst_display = if spec.dst.length() == 0 {
        "(matching)"
      } else {
        spec.dst
      }
      if status_query && spec.src.length() == 0 {
        continue
      }
      if status_query &&
        spec.src.has_prefix("refs/") &&
        not(spec.src.has_prefix("refs/heads/")) {
        continue
      }
      let action = if spec.force { "forces to" } else { "pushes to" }
      let status = if status_query {
        let src_ref = if spec.src.has_prefix("refs/") {
          spec.src
        } else {
          "refs/heads/" + spec.src
        }
        let dst_ref = if spec.dst.length() == 0 {
          src_ref
        } else if spec.dst.has_prefix("refs/") {
          spec.dst
        } else {
          "refs/heads/" + spec.dst
        }
        let local_id = @gitlib.resolve_ref(fs, git_dir, src_ref)
        let remote_id = match remote_git_dir {
          Some(rgd) => @gitlib.resolve_ref(fs, rgd, dst_ref)
          None => None
        }
        match (local_id, remote_id, remote_git_dir, remote_db) {
          (Some(lid), Some(rid), Some(_), Some(rdb)) =>
            if lid == rid {
              Some("(up to date)")
            } else if is_ancestor_commit(rdb, fs, lid, rid) {
              Some("(local out of date)")
            } else if is_ancestor_commit(local_db, fs, rid, lid) {
              Some("(fast-forwardable)")
            } else {
              Some("(local out of date)")
            }
          (Some(_), None, _, _) => Some("(create)")
          _ => None
        }
      } else {
        None
      }
      push_lines.push((src_display, action, dst_display, status))
    }
    let formatted = format_push_lines(push_lines, status_query)
    for line in formatted {
      print_line(line)
    }
  }
}

///|
fn parse_pack_args(args : Array[String]) -> (Bool, String)? {
  let mut advertise = false
  let mut repo : String? = None
  for arg in args {
    match arg {
      "--advertise-refs" => advertise = true
      "--stateless-rpc" => continue
      _ if arg.has_prefix("--") => continue
      _ => if repo is None { repo = Some(arg) }
    }
  }
  match repo {
    Some(path) => Some((advertise, path))
    None => None
  }
}

///|
async fn handle_upload_pack(args : Array[String]) -> Unit {
  // Handle -h option
  for arg in args {
    if arg == "-h" {
      print_line(
        "usage: git upload-pack [--[no-]strict] [--timeout=<n>] [--stateless-rpc]",
      )
      print_line("                       [--advertise-refs] <dir>")
      @sys.exit(129)
    }
  }
  // Parse config overrides from environment variable
  let cmdline_config = parse_config_overrides()
  guard parse_pack_args(args) is Some((advertise, repo_path)) else {
    raise @git.GitError::ProtocolError("missing repository path")
  }
  let root = if repo_path.has_suffix(".git") && !repo_path.has_suffix("/.git") {
    // Bare repository with .git suffix
    repo_path
  } else {
    normalize_repo_root(repo_path)
  }
  let fs = OsFs::new()
  let git_dir = if root.has_suffix(".git") && !root.has_suffix("/.git") {
    root
  } else {
    root + "/.git"
  }
  if is_sha256_repo(git_dir) {
    match real_git_path() {
      Some(real_git) => {
        let real_args = real_git_args_from_cli()
        let code = @process.run(real_git, real_args)
        @sys.exit(code)
      }
      None => {
        @stdio.stderr.write("bit: SHA256 repositories are not supported\n")
        @sys.exit(1)
      }
    }
  }
  if advertise {
    let out = @gitlib.build_upload_pack_advertisement(fs, root)
    @stdio.stdout.write(out)
  } else {
    let input = read_all_stdin()
    // Check protocol version from GIT_PROTOCOL environment variable
    let protocol_version = get_protocol_version()
    if protocol_version == 2 {
      // Protocol v2: parse and handle v2 request
      let req = @gitlib.parse_upload_pack_request_v2(input)
      let config = build_upload_pack_config_with_overrides(
        fs, root, cmdline_config,
      )
      let out = @gitlib.upload_pack_v2(fs, root, req, config)
      @stdio.stdout.write(out)
    } else {
      // Protocol v1: use existing handler
      let req = @gitlib.parse_upload_pack_request(input)
      let out = @gitlib.upload_pack(fs, root, req)
      @stdio.stdout.write(out)
    }
  }
}

///|
/// Parse config overrides from GIT_CONFIG_OVERRIDES environment variable
fn parse_config_overrides() -> Map[String, String] {
  let config : Map[String, String] = {}
  let overrides = @sys.get_env_var("GIT_CONFIG_OVERRIDES")
  guard overrides is Some(env_value) else { return config }
  // Parse key=value pairs separated by newlines
  for line in split_by_newline(env_value) {
    if line.length() == 0 {
      continue
    }
    match line.find("=") {
      Some(idx) => {
        let key = String::unsafe_substring(line, start=0, end=idx).to_lower()
        let value = String::unsafe_substring(
          line,
          start=idx + 1,
          end=line.length(),
        )
        config[key] = value
      }
      None =>
        // Key without = means the key is present but with no value
        config[line.to_lower()] = ""
    }
  }
  config
}

///|
fn get_protocol_version() -> Int {
  // Check GIT_PROTOCOL environment variable for version=2
  let git_protocol = @sys.get_env_var("GIT_PROTOCOL")
  match git_protocol {
    Some(val) => if val.contains("version=2") { 2 } else { 1 }
    None => 1
  }
}

///|
fn build_upload_pack_config_with_overrides(
  fs : &@git.RepoFileSystem,
  root : String,
  overrides : Map[String, String],
) -> @gitlib.UploadPackConfig {
  let git_dir = if root.has_suffix(".git") { root } else { root + "/.git" }
  let config_path = git_dir + "/config"

  // Read allow_filter from file, then check cmdline override
  let allow_filter = match overrides.get("uploadpack.allowfilter") {
    Some(v) => {
      let lower = v.to_lower()
      lower == "true" || lower == "1" || lower == "yes"
    }
    None =>
      read_config_bool(fs, config_path, "uploadpack", "allowfilter").unwrap_or(
        true,
      )
  }

  // Read blobpackfileuri from cmdline first, then file
  // Note: -c uploadpack.blobpackfileuri (without =) means key is present but empty
  // -c uploadpack.blobpackfileuri=anything means key has value
  let blob_packfile_uri = match overrides.get("uploadpack.blobpackfileuri") {
    Some(v) =>
      if v.length() > 0 {
        Some(v)
      } else {
        // Empty value means key was present but no value - still enable the feature
        // Actually git requires a non-empty value, so empty means disabled
        None
      }
    None => read_config_value(fs, config_path, "uploadpack", "blobpackfileuri")
  }
  @gitlib.UploadPackConfig::new(allow_filter, blob_packfile_uri)
}

///|
fn read_config_value(
  fs : &@git.RepoFileSystem,
  config_path : String,
  section : String,
  name : String,
) -> String? {
  guard fs.is_file(config_path) else { return None }
  let content = try? fs.read_file(config_path)
  guard content is Ok(content) else { return None }
  let content_str = @utf8.decode_lossy(content[:])
  // Simple config parsing - look for key = value in section
  let section_lower = section.to_lower()
  let name_lower = name.to_lower()
  let mut in_section = false
  let lines = split_by_newline(content_str)
  for line in lines {
    let trimmed = trim_whitespace(line)
    if trimmed.has_prefix("[") && trimmed.has_suffix("]") {
      let sec = String::unsafe_substring(
        trimmed,
        start=1,
        end=trimmed.length() - 1,
      )
      in_section = sec.to_lower() == section_lower
    } else if in_section {
      match trimmed.find("=") {
        Some(idx) => {
          let k = trim_whitespace(
            String::unsafe_substring(trimmed, start=0, end=idx),
          )
          let v = trim_whitespace(
            String::unsafe_substring(
              trimmed,
              start=idx + 1,
              end=trimmed.length(),
            ),
          )
          if k.to_lower() == name_lower {
            return Some(v)
          }
        }
        None => ()
      }
    }
  }
  None
}

///|
fn split_by_newline(s : String) -> Array[String] {
  let result : Array[String] = []
  let mut start = 0
  let len = s.length()
  for i in 0..<len {
    if s[i] == '\n' {
      result.push(String::unsafe_substring(s, start~, end=i))
      start = i + 1
    }
  }
  if start < len {
    result.push(String::unsafe_substring(s, start~, end=len))
  }
  result
}

///|
fn trim_whitespace(s : String) -> String {
  let mut start = 0
  let mut end = s.length()
  while start < end && (s[start] == ' ' || s[start] == '\t' || s[start] == '\r') {
    start += 1
  }
  while end > start &&
        (s[end - 1] == ' ' || s[end - 1] == '\t' || s[end - 1] == '\r') {
    end -= 1
  }
  if start == 0 && end == s.length() {
    s
  } else {
    String::unsafe_substring(s, start~, end~)
  }
}

///|
fn read_config_bool(
  fs : &@git.RepoFileSystem,
  config_path : String,
  section : String,
  name : String,
) -> Bool? {
  match read_config_value(fs, config_path, section, name) {
    Some(v) => {
      let lower = v.to_lower()
      if lower == "true" || lower == "1" || lower == "yes" {
        Some(true)
      } else if lower == "false" || lower == "0" || lower == "no" {
        Some(false)
      } else {
        None
      }
    }
    None => None
  }
}

///|
async fn handle_receive_pack(args : Array[String]) -> Unit {
  // Handle -h option
  for arg in args {
    if arg == "-h" {
      print_line("usage: git receive-pack <git-dir>")
      @sys.exit(129)
    }
  }
  guard parse_pack_args(args) is Some((advertise, repo_path)) else {
    raise @git.GitError::ProtocolError("missing repository path")
  }
  let root = if repo_path.has_suffix(".git") && !repo_path.has_suffix("/.git") {
    // Bare repository with .git suffix
    repo_path
  } else {
    normalize_repo_root(repo_path)
  }
  let fs = OsFs::new()
  let git_dir = if root.has_suffix(".git") && !root.has_suffix("/.git") {
    root
  } else {
    root + "/.git"
  }
  if is_sha256_repo(git_dir) {
    match real_git_path() {
      Some(real_git) => {
        let real_args = real_git_args_from_cli()
        let code = @process.run(real_git, real_args)
        @sys.exit(code)
      }
      None => {
        @stdio.stderr.write("bit: SHA256 repositories are not supported\n")
        @sys.exit(1)
      }
    }
  }
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
/// Parse filter specification from command line
fn parse_filter_spec(spec : String) -> @git.FilterSpec {
  if spec == "blob:none" {
    @git.FilterSpec::BlobNone
  } else if spec.has_prefix("blob:limit=") {
    let limit_str = String::unsafe_substring(spec, start=11, end=spec.length())
    let limit = @strconv.parse_int64(limit_str) catch { _ => 0L }
    @git.FilterSpec::BlobLimit(limit)
  } else if spec.has_prefix("tree:") {
    let depth_str = String::unsafe_substring(spec, start=5, end=spec.length())
    let depth = @strconv.parse_int(depth_str) catch { _ => 0 }
    @git.FilterSpec::TreeDepth(depth)
  } else {
    @git.FilterSpec::NoFilter
  }
}

///|
async fn handle_clone(args : Array[String]) -> Unit raise Error {
  let root = get_work_root()
  let mut url : String? = None
  let mut dest : String? = None
  let mut depth = 0
  let mut filter = @git.FilterSpec::NoFilter
  let mut bare = false
  let mut ref_spec : String? = None
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    if arg == "--depth" && i + 1 < args.length() {
      // Parse depth value
      let depth_str = args[i + 1]
      depth = @strconv.parse_int(depth_str) catch { _ => 0 }
      i += 2
      continue
    }
    if arg.has_prefix("--depth=") {
      let depth_str = String::unsafe_substring(arg, start=8, end=arg.length())
      depth = @strconv.parse_int(depth_str) catch { _ => 0 }
      i += 1
      continue
    }
    if arg == "--bare" {
      bare = true
      i += 1
      continue
    }
    // Parse --filter option
    if arg == "--filter" && i + 1 < args.length() {
      filter = parse_filter_spec(args[i + 1])
      i += 2
      continue
    }
    if arg.has_prefix("--filter=") {
      let filter_str = String::unsafe_substring(arg, start=9, end=arg.length())
      filter = parse_filter_spec(filter_str)
      i += 1
      continue
    }
    if arg.has_prefix("-") {
      warn_unimplemented_arg("clone", arg)
      i += 1
      continue
    }
    if url is None {
      url = Some(arg)
    } else if dest is None {
      dest = Some(arg)
    }
    i += 1
  }
  guard url is Some(remote_url) else {
    raise @git.GitError::InvalidObject("repository URL required")
  }
  // Check for ambiguity with local directories
  let fs = OsFs::new()
  match check_shorthand_ambiguity(remote_url, fn(p) { fs.is_dir(p) }) {
    Some(conflict_path) =>
      raise @git.GitError::InvalidObject(
        "Ambiguous: '\{conflict_path}' exists locally. Use full URL or ./\{remote_url} for local path.",
      )
    None => ()
  }
  // Check for shorthand (user/repo, user/repo:path, or browser URL)
  match parse_github_shorthand(remote_url) {
    Some(Repo(github_url, refname)) => {
      // user/repo → normal clone from GitHub
      print_line("Shorthand: \{github_url}")
      url = Some(github_url)
      ref_spec = refname
    }
    Some(Subdir(github_url, subdir, refname)) => {
      // user/repo:path or /tree/ URL → subdir clone
      print_line("Subdir clone: \{github_url} → \{subdir}")
      return subdir_clone(github_url, subdir, dest, refname)
    }
    Some(File(raw_url, filename)) => {
      // /blob/ URL → single file fetch
      let target_file = match dest {
        Some(d) => d
        None => filename
      }
      print_line("Fetching file: \{raw_url}")
      return fetch_raw_file(raw_url, target_file)
    }
    None => ()
  }
  // Re-extract remote_url after potential shorthand expansion
  guard url is Some(remote_url) else {
    raise @git.GitError::InvalidObject("repository URL required")
  }
  // Derive destination from URL if not specified
  let relative_target = match dest {
    Some(d) => d
    None => {
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
  // Show what kind of clone we're doing
  let clone_type = if filter.is_partial() {
    "partial clone (\{filter.to_string()})"
  } else if depth > 0 {
    "shallow clone (depth=\{depth})"
  } else {
    "full clone"
  }
  print_line("Cloning into '\{relative_target}'... (\{clone_type})")
  let fs = OsFs::new()
  let local_root = match @sys.get_env_var("GIT_SHIM_PWD") {
    Some(pwd) => pwd
    None => root
  }
  match resolve_local_repo_path(fs, local_root, remote_url) {
    Some(src_path) => {
      let remote_display = if remote_url.has_prefix("file://") {
        remote_url
      } else if remote_url.has_prefix("/") {
        remote_url
      } else {
        normalize_path(local_root + "/" + remote_url)
      }
      clone_local_repo(fs, src_path, target, remote_display, bare, filter)
      if not(bare) && not(filter.is_partial()) {
        let git_dir = target + "/.git"
        match @gitlib.resolve_head_commit(fs, git_dir) {
          Some(commit_id) =>
            @gitlib.apply_worktree_modes_from_commit(
              fs, fs, target, git_dir, commit_id,
            )
          None => ()
        }
      }
      if ref_spec is Some(refname) && not(bare) && not(filter.is_partial()) {
        let _ = @gitlib.checkout(fs, fs, target, refname)

      }
      print_line("done.")
    }
    None => {
      let refs = @git.clone_http_to_fs(
        remote_url,
        true,
        fs,
        target,
        depth~,
        filter~,
      )
      if not(bare) && not(filter.is_partial()) {
        let git_dir = target + "/.git"
        match @gitlib.resolve_head_commit(fs, git_dir) {
          Some(commit_id) =>
            @gitlib.apply_worktree_modes_from_commit(
              fs, fs, target, git_dir, commit_id,
            )
          None => ()
        }
      }
      if refs.length() > 0 {
        if ref_spec is Some(refname) && not(bare) && not(filter.is_partial()) {
          match resolve_remote_ref_id(remote_url, refname) {
            Some((commit_id, branch)) => {
              let git_dir = target + "/.git"
              let mut db = @gitlib.ObjectDb::load_lazy(fs, git_dir)
              if db.get(fs, commit_id) is None {
                let pack = @git.fetch_pack_http(remote_url, [commit_id], true)
                let objects = @git.parse_packfile(pack)
                @git.write_packfile_with_index(fs, git_dir, pack, objects)
                db = @gitlib.ObjectDb::load_lazy(fs, git_dir)
              }
              match branch {
                Some(name) => {
                  fs.mkdir_p(git_dir + "/refs/heads") catch {
                    _ => ()
                  }
                  fs.write_string(
                    git_dir + "/refs/heads/" + name,
                    commit_id.to_hex() + "\n",
                  ) catch {
                    _ => ()
                  }
                  let _ = @gitlib.checkout(fs, fs, target, name)

                }
                None => {
                  let _ = @gitlib.checkout(fs, fs, target, commit_id.to_hex())

                }
              }
            }
            None =>
              raise @git.GitError::InvalidObject("Unknown ref: " + refname)
          }
        }
        print_line("done.")
      } else {
        raise @git.GitError::InvalidObject("Clone failed: no refs found")
      }
    }
  }
}

///|
async fn handle_fetch(args : Array[String]) -> Unit raise Error {
  let root = get_work_root()
  let git_dir = root + "/.git"
  let fs = OsFs::new()
  let (remotes, _) = read_repo_config(fs, git_dir)
  // Read remote URL - prefer subdir-clone remote, then config
  let mut remote_name = "origin"
  let mut remote_url : String? = get_effective_remote_url(fs, git_dir)
  // Override with command line argument
  for arg in args {
    if not(arg.has_prefix("-")) {
      match remotes.get(arg) {
        Some(rc) => {
          remote_name = arg
          if rc.urls.length() > 0 {
            remote_url = Some(rc.urls[0])
          }
        }
        None => remote_url = Some(arg)
      }
      break
    }
    warn_unimplemented_arg("fetch", arg)
  }
  guard remote_url is Some(url) else {
    raise @git.GitError::InvalidObject("No remote configured")
  }
  fetch_from_remote(fs, git_dir, root, remote_name, url)
}

///|
async fn handle_pull(args : Array[String]) -> Unit raise Error {
  let root = get_work_root()
  let git_dir = root + "/.git"
  let fs = OsFs::new()
  // Read remote URL - prefer subdir-clone remote, then config
  let mut remote_url : String? = get_effective_remote_url(fs, git_dir)
  let mut rebase = false
  for arg in args {
    match arg {
      "--rebase" | "-r" => rebase = true
      _ if arg.has_prefix("-") => {
        warn_unimplemented_arg("pull", arg)
        continue
      }
      _ => {
        remote_url = Some(arg)
        break
      }
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
async fn handle_push(args : Array[String]) -> Unit raise Error {
  let root = get_work_root()
  let git_dir = root + "/.git"
  let fs = OsFs::new()
  // Check if this is a subdir-clone
  let subdir_remote = match get_subdir_info(fs, git_dir) {
    Some((remote, _, _)) => Some(remote)
    None => None
  }
  // Parse arguments
  let mut remote_name = "origin"
  let mut refspec : String? = None
  let mut force = false
  let mut set_upstream = false
  for arg in args {
    match arg {
      "-f" | "--force" => force = true
      "-u" | "--set-upstream" => set_upstream = true
      _ if arg.has_prefix("-") => warn_unimplemented_arg("push", arg)
      _ =>
        if refspec is None {
          // First non-option is either remote or refspec
          // Check if it's a known remote
          let url = get_remote_url(fs, git_dir, arg)
          if url is Some(_) {
            remote_name = arg
          } else {
            refspec = Some(arg)
          }
        } else {
          // Second non-option is refspec
          refspec = Some(arg)
        }
    }
  }
  // Get remote URL - prefer subdir-clone remote
  let remote_url = match subdir_remote {
    Some(url) => Some(url)
    None => get_remote_url(fs, git_dir, remote_name)
  }
  guard remote_url is Some(url) else {
    raise @git.GitError::InvalidObject("No such remote: \{remote_name}")
  }
  // Determine refspec
  let refname = match refspec {
    Some(r) => if r.has_prefix("refs/") { r } else { "refs/heads/" + r }
    None => {
      // Use current branch
      let head_ref = @gitlib.read_head_ref(fs, git_dir)
      match head_ref {
        @gitlib.HeadRef::Branch(branch) => "refs/heads/" + branch
        @gitlib.HeadRef::Detached(_) =>
          raise @git.GitError::InvalidObject(
            "Cannot push from detached HEAD without refspec",
          )
      }
    }
  }
  // Check if this is a subdir-clone - if so, transform commits before push
  match get_subdir_info(fs, git_dir) {
    Some((remote_url, subdir_path, base_hex)) => {
      print_line("Pushing subdir-clone to \{remote_url}...")
      print_line("  Subdirectory: \{subdir_path}")
      handle_subdir_push(
        fs, root, git_dir, remote_url, subdir_path, base_hex, refname, force,
      ) catch {
        err => raise err
      }
    }
    None => {
      print_line("Pushing to \{url}...")
      ignore(force) // TODO: implement force push
      let result = @gitlib.push_http(fs, root, url, refname)
      print_line(result)
    }
  }
  if set_upstream {
    // TODO: set tracking branch
    print_line("Branch '\{refname}' set up to track remote branch.")
  }
}

///|
/// Handle push for subdir-clone repositories
/// Transforms local commits to fit the original repository structure
async fn handle_subdir_push(
  fs : OsFs,
  root : String,
  git_dir : String,
  remote_url : String,
  subdir_path : String,
  base_hex : String,
  refname : String,
  _force : Bool,
) -> Unit raise Error {
  // Step 1: Get local HEAD commit
  let local_head_opt = @gitlib.rev_parse(fs, git_dir, "HEAD") catch {
    _ => raise @git.GitError::InvalidObject("Cannot resolve HEAD")
  }
  guard local_head_opt is Some(local_head) else {
    raise @git.GitError::InvalidObject("HEAD not found")
  }
  print_line("  Local HEAD: \{local_head.to_hex()}")
  // Step 2: Get the initial commit (first commit in the subdir-clone)
  let initial_commit = find_initial_subdir_commit(fs, git_dir) catch {
    _ => raise @git.GitError::InvalidObject("Cannot find initial commit")
  }
  print_line("  Initial commit: \{initial_commit.to_hex()}")
  // Step 3: Collect local commits since initial
  let local_commits = collect_commits_since(
    fs, git_dir, initial_commit, local_head,
  ) catch {
    err => raise err
  }
  if local_commits.length() == 0 {
    print_line("Nothing to push.")
    return
  }
  print_line("  Found \{local_commits.length()} local commits to transform")
  // Step 4: Get upstream base commit
  let upstream_base = @git.ObjectId::from_hex(base_hex) catch {
    _ => raise @git.GitError::InvalidObject("Cannot parse base commit")
  }
  print_line("  Upstream base: \{upstream_base.to_hex()}")
  // Step 5: Fetch upstream base commit and its tree from remote
  print_line("  Fetching upstream objects...")
  let pack = @git.fetch_pack_http(remote_url, [upstream_base], true)
  let objects = @git.parse_packfile(pack)
  @git.write_packfile_with_index(fs, git_dir, pack, objects)
  print_line("  Fetched \{objects.length()} objects")
  // Step 6: Reload ObjectDb to pick up new packfile, then transform commits
  let db = @gitlib.ObjectDb::load(fs, git_dir)
  let mut parent : @git.ObjectId = upstream_base
  for commit_id in local_commits {
    let new_commit = transform_subdir_commit(
      fs, db, git_dir, commit_id, parent, subdir_path,
    ) catch {
      err => raise err
    }
    print_line("  Transformed: \{commit_id.to_hex()} -> \{new_commit.to_hex()}")
    parent = new_commit
  }
  // Step 7: Push the transformed commits (tree only, not parent history)
  let transformed_head : @git.ObjectId = parent
  print_line("  Pushing transformed commits...")
  let result = @gitlib.push_http_tree_only(
    fs, root, remote_url, transformed_head, upstream_base, refname,
  )
  print_line("  \{result}")
  // Step 8: Update base commit
  update_subdir_base(fs, git_dir, transformed_head.to_hex())
  print_line("done.")
}

///|
/// Find the initial commit of a subdir-clone (the "cloned from" commit)
fn find_initial_subdir_commit(
  fs : OsFs,
  git_dir : String,
) -> @git.ObjectId raise @git.GitError {
  let db = @gitlib.ObjectDb::load_lazy(fs, git_dir)
  // Start from HEAD and walk back to find root commit
  let head_opt = @gitlib.rev_parse(fs, git_dir, "HEAD") catch {
    _ => raise @git.GitError::InvalidObject("Cannot resolve HEAD")
  }
  guard head_opt is Some(head) else {
    raise @git.GitError::InvalidObject("HEAD not found")
  }
  let mut current : @git.ObjectId = head
  let mut prev : @git.ObjectId = current
  while true {
    let obj = db.get(fs, current)
    guard obj is Some(o) else { break }
    let info = @git.parse_commit(o.data) catch { _ => break }
    if info.parents.length() == 0 {
      // Found root commit
      return current
    }
    prev = current
    current = info.parents[0]
  }
  prev
}

///|
/// Collect commits from start (exclusive) to end (inclusive)
fn collect_commits_since(
  fs : OsFs,
  git_dir : String,
  start : @git.ObjectId,
  end : @git.ObjectId,
) -> Array[@git.ObjectId] raise @git.GitError {
  let result : Array[@git.ObjectId] = []
  let db = @gitlib.ObjectDb::load_lazy(fs, git_dir)
  let mut current : @git.ObjectId = end
  let start_hex = start.to_hex()
  while true {
    let hex = current.to_hex()
    if hex == start_hex {
      break
    }
    result.push(current)
    let obj = db.get(fs, current)
    guard obj is Some(o) else { break }
    let info = @git.parse_commit(o.data) catch { _ => break }
    if info.parents.length() == 0 {
      break
    }
    current = info.parents[0]
  }
  // Reverse to get oldest first
  result.rev_in_place()
  result
}

///|
/// Transform a subdir-clone commit to fit the original repository structure
fn transform_subdir_commit(
  fs : OsFs,
  db : @gitlib.ObjectDb,
  git_dir : String,
  local_commit : @git.ObjectId,
  upstream_parent : @git.ObjectId,
  subdir_path : String,
) -> @git.ObjectId raise @git.GitError {
  // Get local commit info
  let local_obj = db.get(fs, local_commit)
  guard local_obj is Some(lo) else {
    raise @git.GitError::InvalidObject("Cannot find local commit")
  }
  let local_info = @git.parse_commit(lo.data) catch { err => raise err }
  let (author, message) = parse_commit_author_message(lo.data)
  // Get upstream parent's tree
  let upstream_obj = db.get(fs, upstream_parent)
  guard upstream_obj is Some(uo) else {
    raise @git.GitError::InvalidObject("Cannot find upstream commit")
  }
  let upstream_info = @git.parse_commit(uo.data) catch { err => raise err }
  // The local commit's tree IS the subdirectory content
  let new_subdir_tree = local_info.tree
  // Replace the subdirectory in the upstream tree
  let new_root_tree = replace_tree_at_path(
    fs,
    db,
    git_dir,
    upstream_info.tree,
    subdir_path,
    new_subdir_tree,
  ) catch {
    err => raise err
  }
  // Create new commit with the transformed tree
  let timestamp = get_current_timestamp()
  let new_commit = @subdir.create_commit_in_repo(
    fs, git_dir, new_root_tree, upstream_parent, message, author, timestamp,
  ) catch {
    _ => raise @git.GitError::InvalidObject("Cannot create commit")
  }
  new_commit
}

///|
/// Replace a subtree at a given path within a root tree
fn replace_tree_at_path(
  fs : OsFs,
  db : @gitlib.ObjectDb,
  git_dir : String,
  root_tree : @git.ObjectId,
  path : String,
  new_subtree : @git.ObjectId,
) -> @git.ObjectId raise @git.GitError {
  let path_parts : Array[String] = path
    .split("/")
    .filter(fn(s) { s.length() > 0 })
    .map(fn(s) { s.to_string() })
    .collect()
  if path_parts.length() == 0 {
    return new_subtree
  }
  replace_tree_recursive_push(
    fs, db, git_dir, root_tree, path_parts, 0, new_subtree,
  )
}

///|
fn replace_tree_recursive_push(
  fs : OsFs,
  db : @gitlib.ObjectDb,
  git_dir : String,
  current_tree : @git.ObjectId,
  path_parts : Array[String],
  depth : Int,
  new_leaf : @git.ObjectId,
) -> @git.ObjectId raise @git.GitError {
  // Read current tree
  let tree_obj = db.get(fs, current_tree)
  guard tree_obj is Some(to) else {
    raise @git.GitError::InvalidObject("Cannot find tree")
  }
  let entries = @git.parse_tree(to.data) catch { err => raise err }
  // Build new entries
  let new_entries : Array[@git.TreeEntry] = []
  let target_name = path_parts[depth]
  let is_last = depth == path_parts.length() - 1
  for entry in entries {
    if entry.name == target_name {
      if is_last {
        // Replace with new subtree
        new_entries.push(@git.TreeEntry::new(entry.mode, entry.name, new_leaf))
      } else {
        // Recurse
        let new_child = replace_tree_recursive_push(
          fs,
          db,
          git_dir,
          entry.id,
          path_parts,
          depth + 1,
          new_leaf,
        ) catch {
          err => raise err
        }
        new_entries.push(@git.TreeEntry::new(entry.mode, entry.name, new_child))
      }
    } else {
      new_entries.push(entry)
    }
  }
  // Create new tree and write it
  let (tree_id, tree_data) = @git.create_tree(new_entries)
  write_object_to_repo(fs, git_dir, tree_id, tree_data) catch {
    _ => raise @git.GitError::InvalidObject("Cannot write tree")
  }
  tree_id
}

///|
/// Write an object (already compressed) to the repository
fn write_object_to_repo(
  fs : OsFs,
  git_dir : String,
  id : @git.ObjectId,
  compressed_data : Bytes,
) -> Unit raise @git.GitError {
  let hex = id.to_hex()
  let dir_name = String::unsafe_substring(hex, start=0, end=2)
  let file_name = String::unsafe_substring(hex, start=2, end=40)
  let dir_path = git_dir + "/objects/" + dir_name
  let file_path = dir_path + "/" + file_name
  // Create directory if needed
  fs.mkdir_p(dir_path) catch {
    _ => ()
  }
  // Write already-compressed data
  fs.write_file(file_path, compressed_data) catch {
    _ => raise @git.GitError::IoError("Cannot write object")
  }
}

///|
fn read_remote_url_from_config(
  fs : &@git.RepoFileSystem,
  git_dir : String,
) -> String? {
  let config_path = git_dir + "/config"
  if not(fs.is_file(config_path)) {
    return None
  }
  let config_content = decode_bytes(
    fs.read_file(config_path) catch {
      _ => return None
    },
  )
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
      return Some(String::unsafe_substring(line, start=6, end=line.length()))
    }
  }
  None
}

///| Core handlers: init, status, add, commit, log, show

///|
async fn handle_init(args : Array[String]) -> Unit raise Error {
  let root = get_work_root()
  let fs = OsFs::new()
  // Parse options
  let mut bare = false
  let mut initial_branch : String? = None
  let mut target_dir : String? = None
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    match arg {
      "--bare" => bare = true
      "-b" if i + 1 < args.length() => {
        initial_branch = Some(args[i + 1])
        i += 1
      }
      _ if arg.has_prefix("--initial-branch=") =>
        initial_branch = Some((try! arg[17:]).to_string())
      _ if not(arg.has_prefix("-")) => target_dir = Some(arg)
      _ => () // Ignore other options
    }
    i += 1
  }
  // Check GIT_DIR and GIT_WORK_TREE environment variables
  let git_dir_env = @sys.get_env_var("GIT_DIR")
  let work_tree_env = @sys.get_env_var("GIT_WORK_TREE")
  // Determine the target path and git directory
  let (path, effective_git_dir) : (String, String?) = match
    (target_dir, git_dir_env) {
    (Some(dir), _) => {
      let p = if dir.has_prefix("/") { dir } else { root + "/" + dir }
      (p, None)
    }
    (None, Some(gd)) => {
      // When GIT_DIR is set without target
      let g = if gd.has_prefix("/") { gd } else { root + "/" + gd }
      // If GIT_WORK_TREE is also set, it's not bare (work tree exists)
      // If only GIT_DIR is set, it's a bare repo
      if work_tree_env is Some(_) {
        (root, Some(g))
      } else {
        (g, Some(g))
      }
    }
    (None, None) => (root, None)
  }
  // Determine if bare: only bare if explicitly requested or GIT_DIR without GIT_WORK_TREE
  if git_dir_env is Some(_) && work_tree_env is None && target_dir is None {
    bare = true
  }
  // If GIT_WORK_TREE is set with --bare, that's an error
  if bare && work_tree_env is Some(_) {
    eprint_line(
      "fatal: GIT_WORK_TREE (or --work-tree=<directory>) not allowed without specifying a repository to work with",
    )
    @sys.exit(128)
  }
  // Determine default branch
  let branch = match initial_branch {
    Some(b) => b
    None => "main"
  }
  // Determine actual git directory path for output message
  let actual_git_dir = match effective_git_dir {
    Some(gd) => gd
    None => if bare { path } else { path + "/.git" }
  }
  // Check if this is a reinit (repository already exists)
  let is_reinit = fs.is_dir(actual_git_dir) && fs.is_file(actual_git_dir + "/HEAD")
  // Initialize repository (init_repo handles both new and reinit)
  @gitlib.init_repo(fs, path, default_branch=branch, bare=bare)
  // Print appropriate message
  let verb = if is_reinit { "Reinitialized existing" } else { "Initialized empty" }
  if bare {
    print_line(verb + " Git repository in " + actual_git_dir + "/")
  } else {
    print_line(verb + " Git repository in " + actual_git_dir + "/")
  }
}

///|
async fn handle_status(args : Array[String]) -> Unit raise Error {
  let root = get_work_root()
  let git_dir = root + "/.git"
  let fs = OsFs::new()
  let mut porcelain = false
  let mut short = false
  let mut show_branch = false
  for arg in args {
    match arg {
      "--porcelain" | "--porcelain=v1" => porcelain = true
      "-s" | "--short" => short = true
      "-b" | "--branch" => show_branch = true
      "-sb" => {
        short = true
        show_branch = true
      }
      _ => ()
    }
  }
  if porcelain || short {
    if show_branch {
      let head = @gitlib.read_head_ref(fs, git_dir) catch { _ => return () }
      match head {
        @gitlib.HeadRef::Branch(name) => print_line("## \{name}")
        @gitlib.HeadRef::Detached(id) =>
          print_line("## HEAD (detached at \{id.to_hex()[:7].to_string()})")
      }
    }
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
  let paths = args.iter().filter(fn(arg) { not(arg.has_prefix("-")) }).collect()
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
  let mut all_modified = false
  let mut amend = false
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    match arg {
      "-m" if i + 1 < args.length() => {
        message = Some(args[i + 1])
        i += 2
        continue
      }
      _ if arg.has_prefix("-m") => {
        message = Some((try! arg[2:]).to_string())
        i += 1
        continue
      }
      _ if arg.has_prefix("--message=") => {
        message = Some((try! arg[10:]).to_string())
        i += 1
        continue
      }
      "-a" | "--all" => all_modified = true
      "--amend" => amend = true
      _ => ()
    }
    i += 1
  }
  // If -a flag, stage all modified files
  if all_modified {
    let status = @gitlib.status(fs, root)
    let paths_to_add : Array[String] = []
    for p in status.unstaged_modified {
      paths_to_add.push(p)
    }
    for p in status.unstaged_deleted {
      paths_to_add.push(p)
    }
    if paths_to_add.length() > 0 {
      @gitlib.add_paths(fs, fs, root, paths_to_add)
    }
  }
  // For amend, get previous message if none specified
  if amend && message is None {
    message = get_head_commit_message(fs, root)
  }
  guard message is Some(msg) else {
    raise @git.GitError::InvalidObject("No commit message specified")
  }
  let author = get_author_string()
  let timestamp = get_commit_timestamp()
  let commit_id = if amend {
    @gitlib.commit_amend(fs, fs, root, msg, author, timestamp)
  } else {
    @gitlib.commit(fs, fs, root, msg, author, timestamp)
  }
  let short_id = (try! commit_id.to_hex()[:7]).to_string()
  let first_line = match msg.find("\n") {
    Some(idx) => (try! msg[:idx]).to_string()
    None => msg
  }
  print_line("[" + short_id + "] " + first_line)
}

///|
fn get_head_commit_message(fs : &@git.RepoFileSystem, root : String) -> String? {
  let git_dir = root + "/.git"
  let head = @gitlib.resolve_head_commit(fs, git_dir) catch { _ => return None }
  guard head is Some(commit_id) else { return None }
  let db = @gitlib.ObjectDb::load(fs, git_dir) catch { _ => return None }
  let obj = db.get(fs, commit_id) catch { _ => return None }
  guard obj is Some(o) else { return None }
  // Extract message from raw commit data (after blank line)
  let text = decode_bytes(o.data)
  let mut in_message = false
  let msg_lines : Array[String] = []
  for line_view in text.split("\n") {
    let line = line_view.to_string()
    if in_message {
      msg_lines.push(line)
      continue
    }
    if line.length() == 0 {
      in_message = true
    }
  }
  if msg_lines.length() > 0 {
    Some(msg_lines.join("\n"))
  } else {
    None
  }
}

///|
async fn handle_log(args : Array[String]) -> Unit raise Error {
  let root = get_work_root()
  let git_dir = root + "/.git"
  let fs = OsFs::new()
  let mut oneline = false
  let mut max_count = 10
  for arg in args {
    match arg {
      "--oneline" => oneline = true
      _ if arg.has_prefix("-n") => {
        let num_str = (try! arg[2:]).to_string()
        max_count = @strconv.parse_int(num_str)
      }
      _ if arg.has_prefix("--max-count=") => {
        let num_str = (try! arg[12:]).to_string()
        max_count = @strconv.parse_int(num_str)
      }
      _ => ()
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
  let message = message_lines.join("\n")
  { author, timestamp, message }
}

///|
async fn handle_show(args : Array[String]) -> Unit raise Error {
  let root = get_work_root()
  let git_dir = root + "/.git"
  let fs = OsFs::new()
  // Parse: git show [--pretty=<format>] [<commit>]
  let mut rev = "HEAD"
  let mut pretty_raw = false
  for arg in args {
    if arg == "--pretty=raw" || arg == "--format=raw" {
      pretty_raw = true
    } else if not(arg.has_prefix("-")) {
      rev = arg
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
  // If --pretty=raw, output raw commit object content
  if pretty_raw {
    print_line("commit \{commit_id.to_hex()}")
    // Output the raw commit object as text
    let text = decode_bytes(o.data)
    print_str(text)
    if not(text.has_suffix("\n")) {
      print_line("")
    }
    return ()
  }
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

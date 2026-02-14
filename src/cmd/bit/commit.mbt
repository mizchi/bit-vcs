///|

///|
async fn show_commit_command_help() -> Unit {
  show_simple_command_help(
    "git commit [<options>]",
    summary="Record changes to the repository.",
  )
}

///|
async fn handle_commit(args : Array[String]) -> Unit raise Error {
  if commit_should_delegate_to_real_git(args) {
    delegate_to_real_git("commit", args)
  }
  let root = get_work_root()
  let fs = OsFs::new()
  let commit_message_encoding = resolve_commit_message_encoding()
  let mut message : String? = None
  let mut all_modified = false
  let mut amend = false
  let mut allow_empty = false
  let mut no_verify = false
  let mut quiet = false
  let mut author_override : String? = None
  let mut date_override : String? = None
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    match arg {
      "-m" if i + 1 < args.length() => {
        message = Some(args[i + 1])
        i += 2
        continue
      }
      "-am" | "-ma" if i + 1 < args.length() => {
        all_modified = true
        message = Some(args[i + 1])
        i += 2
        continue
      }
      "--author" if i + 1 < args.length() => {
        author_override = Some(args[i + 1])
        i += 2
        continue
      }
      "--date" if i + 1 < args.length() => {
        date_override = Some(args[i + 1])
        i += 2
        continue
      }
      "-F" if i + 1 < args.length() => {
        message = Some(
          read_commit_message_from_file(
            fs,
            root,
            args[i + 1],
            commit_message_encoding,
          ),
        )
        i += 2
        continue
      }
      "-C" if i + 1 < args.length() => {
        message = read_commit_message_from_revision(fs, root, args[i + 1])
        i += 2
        continue
      }
      _ if arg.has_prefix("-m") => {
        message = Some((try! arg[2:]).to_string())
        i += 1
        continue
      }
      _ if arg.has_prefix("-am") || arg.has_prefix("-ma") => {
        all_modified = true
        message = Some((try! arg[3:]).to_string())
        i += 1
        continue
      }
      _ if arg.has_prefix("--message=") => {
        message = Some((try! arg[10:]).to_string())
        i += 1
        continue
      }
      _ if arg.has_prefix("--author=") => {
        author_override = Some((try! arg[9:]).to_string())
        i += 1
        continue
      }
      _ if arg.has_prefix("--date=") => {
        date_override = Some((try! arg[7:]).to_string())
        i += 1
        continue
      }
      _ if arg.has_prefix("-F") => {
        let file = (try! arg[2:]).to_string()
        message = Some(
          read_commit_message_from_file(fs, root, file, commit_message_encoding),
        )
        i += 1
        continue
      }
      _ if arg.has_prefix("-C") => {
        let spec = (try! arg[2:]).to_string()
        message = read_commit_message_from_revision(fs, root, spec)
        i += 1
        continue
      }
      "-a" | "--all" => all_modified = true
      "--amend" => amend = true
      "--allow-empty" => allow_empty = true
      "--no-verify" => no_verify = true
      "-q" | "--quiet" => quiet = true
      _ if arg.has_prefix("-") => warn_unimplemented_arg("commit", arg)
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
      @gitlib.add_paths_async(fs, fs, root, paths_to_add)
    }
  }
  // Open editor when message is not specified.
  if message is None {
    let initial_message = if amend {
      get_head_commit_message(fs, root)
    } else {
      None
    }
    message = read_commit_message_from_editor(fs, root, initial_message~)
  }
  guard message is Some(msg) else {
    raise @git.GitError::InvalidObject(
      "Aborting commit due to empty commit message.",
    )
  }
  let default_author = get_author_string()
  let default_timestamp = get_commit_timestamp()
  let author = match author_override {
    Some(a) => a
    None => default_author
  }
  let author_timestamp = match date_override {
    Some(d) => parse_commit_date(d)
    None => default_timestamp
  }
  // Committer is always the current user
  let committer = get_committer_string()
  let committer_timestamp = default_timestamp
  let git_dir = resolve_git_dir(fs, root)
  if not(no_verify) {
    let hook_status = run_pre_commit_hook(fs, root, git_dir)
    if hook_status != 0 {
      raise @git.GitError::InvalidObject("pre-commit hook failed")
    }
  }
  let commit_id = if amend {
    @gitlib.commit_amend(
      fs,
      fs,
      root,
      msg,
      author,
      author_timestamp,
      committer~,
      committer_timestamp~,
    )
  } else {
    @gitlib.commit(
      fs,
      fs,
      root,
      msg,
      author,
      author_timestamp,
      committer~,
      committer_timestamp~,
      allow_empty~,
    )
  }
  let short_id = (try! commit_id.to_hex()[:7]).to_string()
  let first_line = match msg.find("\n") {
    Some(idx) => (try! msg[:idx]).to_string()
    None => msg
  }
  // Show subdir-clone context if applicable
  if not(quiet) {
    match get_subdir_info(fs, git_dir) {
      Some((_, path, _)) =>
        print_line("[" + short_id + " (subdir: " + path + ")] " + first_line)
      None => print_line("[" + short_id + "] " + first_line)
    }
  }
}

///|
fn commit_should_delegate_to_real_git(args : Array[String]) -> Bool {
  guard is_real_git_delegate_enabled() else { return false }
  let mut expect_value = false
  for arg in args {
    if expect_value {
      expect_value = false
      continue
    }
    if arg == "--" {
      // `git commit -- <pathspec>` requires full pathspec semantics.
      return true
    }
    if arg == "-S" ||
      arg == "--gpg-sign" ||
      arg == "--no-gpg-sign" ||
      arg.has_prefix("-S") ||
      arg.has_prefix("--gpg-sign=") {
      // Keep signature compatibility by delegating signed commits.
      return true
    }
    if arg == "-m" ||
      arg == "--message" ||
      arg == "-F" ||
      arg == "--file" ||
      arg == "-C" ||
      arg == "--reuse-message" ||
      arg == "-c" ||
      arg == "--reedit-message" ||
      arg == "--author" ||
      arg == "--date" {
      expect_value = true
      continue
    }
    if arg.has_prefix("--message=") ||
      arg.has_prefix("--author=") ||
      arg.has_prefix("--date=") ||
      arg.has_prefix("--file=") ||
      arg.has_prefix("--reuse-message=") ||
      arg.has_prefix("--reedit-message=") {
      continue
    }
    if arg.has_prefix("-m") ||
      arg.has_prefix("-F") ||
      arg.has_prefix("-C") ||
      arg.has_prefix("-c") ||
      arg.has_prefix("-am") ||
      arg.has_prefix("-ma") {
      continue
    }
    if arg.has_prefix("-") {
      continue
    }
    return true
  }
  false
}

///|
async fn read_commit_message_from_file(
  fs : &@git.RepoFileSystem,
  root : String,
  file : String,
  encoding : String,
) -> String raise Error {
  if file == "-" {
    return decode_commit_message_bytes(read_all_stdin(), encoding)
  }
  let path = if file.has_prefix("/") { file } else { root + "/" + file }
  decode_commit_message_bytes(fs.read_file(path), encoding)
}

///|
fn read_commit_message_from_revision(
  fs : &@git.RepoFileSystem,
  root : String,
  spec : String,
) -> String? raise Error {
  let git_dir = resolve_git_dir(fs, root)
  let commit_id = @gitrepo.rev_parse(fs, git_dir, spec)
  match commit_id {
    Some(id) => {
      let db = @gitlib.ObjectDb::load_lazy(fs, git_dir)
      match db.get(fs, id) {
        Some(obj) => Some(extract_commit_message(obj.data))
        None => None
      }
    }
    None => None
  }
}

///|
fn resolve_commit_message_encoding() -> String {
  let overrides = @gitlib.parse_config_overrides()
  match overrides.get("i18n.commitencoding") {
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
fn decode_commit_message_bytes(data : Bytes, encoding : String) -> String {
  if is_iso_8859_1_encoding(encoding) {
    let out = StringBuilder::new()
    for b in data {
      out.write_char(b.to_int().unsafe_to_char())
    }
    out.to_string()
  } else {
    decode_bytes(data)
  }
}

///|
fn is_iso_8859_1_encoding(encoding : String) -> Bool {
  let normalized = normalize_commit_encoding_name(encoding)
  normalized == "iso88591" || normalized == "latin1" || normalized == "latin"
}

///|
fn normalize_commit_encoding_name(value : String) -> String {
  let out = StringBuilder::new()
  for c in trim_string(value).to_lower() {
    if c == '-' || c == '_' || c == ' ' {
      continue
    }
    out.write_char(c)
  }
  out.to_string()
}

///|
fn abs_path(path : String) -> String {
  if path.has_prefix("/") {
    return path
  }
  let cwd = match @env.current_dir() {
    Some(dir) => dir
    None => "."
  }
  normalize_path(cwd + "/" + path)
}

///|
async fn run_pre_commit_hook(fs : OsFs, root : String, git_dir : String) -> Int {
  let hook_git_dir = abs_path(git_dir)
  let hook_path = hook_git_dir + "/hooks/pre-commit"
  if not(fs.is_file(hook_path)) {
    return 0
  }
  let work_root = abs_path(root)
  @process.run(hook_path, [], inherit_env=true, cwd=work_root) catch {
    _ => 1
  }
}

///|
fn parse_commit_date(date_str : String) -> Int64 {
  // Support common formats:
  // - Unix timestamp: "1234567890"
  // - @timestamp: "@1234567890"
  // - ISO 8601: "2024-01-01T12:00:00"
  if date_str.has_prefix("@") {
    let ts_str = try date_str[1:] catch {
      _ => return 0L
    } noraise {
      s => s.to_string()
    }
    return parse_int64(ts_str)
  }
  // Try parsing as unix timestamp
  if date_str.iter().all(c => c >= '0' && c <= '9') {
    return parse_int64(date_str)
  }
  // Fallback to current time if format not recognized
  get_commit_timestamp()
}

///|
fn parse_int64(s : String) -> Int64 {
  let mut result = 0L
  for c in s {
    if c >= '0' && c <= '9' {
      result = result * 10L + (c.to_int() - '0'.to_int()).to_int64()
    }
  }
  result
}

///|
async fn handle_update_ref(args : Array[String]) -> Unit raise Error {
  if is_real_git_delegate_enabled() {
    delegate_to_real_git("update-ref", args)
  }
  let root = get_work_root()
  let git_dir = root + "/.git"
  let fs = OsFs::new()
  let mut delete_mode = false
  let mut create_reflog = false
  let mut no_deref = false
  let mut message : String? = None
  let positional : Array[String] = []
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    match arg {
      "-d" | "--delete" => delete_mode = true
      "--create-reflog" => create_reflog = true
      "--no-deref" => no_deref = true
      "-m" if i + 1 < args.length() => {
        message = Some(args[i + 1])
        i += 1
      }
      _ if not(arg.has_prefix("-")) => positional.push(arg)
      _ if arg.has_prefix("-") => warn_unimplemented_arg("update-ref", arg)
      _ => ()
    }
    i += 1
  }
  ignore(no_deref)
  // Check if bare repo
  let is_bare = fs.is_file(git_dir + "/config") &&
    not(fs.is_dir(root + "/.git"))
  let actual_git_dir = if is_bare { root } else { git_dir }
  // Get current timestamp for reflog
  let timestamp = get_current_timestamp()
  let timezone = "+0000"
  let (author, email) = get_author_info(fs, actual_git_dir)
  if delete_mode {
    if positional.length() < 1 {
      raise @git.GitError::InvalidObject("usage: git update-ref -d <refname>")
    }
    let refname = positional[0]
    let old_value : String? = if positional.length() >= 2 {
      Some(positional[1])
    } else {
      None
    }
    let ref_path = actual_git_dir + "/" + refname
    // Check oldvalue if specified
    if old_value is Some(ov) {
      let current = read_ref_value(fs, actual_git_dir, refname)
      match current {
        Some(cur_id) =>
          if cur_id.to_hex() != ov {
            @stdio.stderr.write(
              "error: cannot lock ref '\{refname}': is at \{cur_id.to_hex()} but expected \{ov}",
            )
            @sys.exit(1)
          }
        None => {
          @stdio.stderr.write(
            "error: cannot lock ref '\{refname}': unable to resolve reference",
          )
          @sys.exit(1)
        }
      }
    }
    // Get old value for reflog before deleting
    let old_id = read_ref_value(fs, actual_git_dir, refname).unwrap_or(
      @git.ObjectId::zero(),
    )
    // Delete the ref
    if fs.is_file(ref_path) {
      fs.remove_file(ref_path)
    }
    // Write reflog entry for deletion
    let rfs : &@git.RepoFileSystem = fs
    let wfs : &@git.FileSystem = fs
    let (should_log, _) = @gitrepo.should_log_ref(
      rfs, actual_git_dir, refname, is_bare,
    )
    if should_log || @gitrepo.reflog_exists(rfs, actual_git_dir, refname) {
      let msg = message.unwrap_or("update-ref: delete")
      @gitrepo.append_reflog(
        wfs,
        rfs,
        actual_git_dir,
        refname,
        old_id,
        @git.ObjectId::zero(),
        author,
        email,
        timestamp,
        timezone,
        msg,
      )
    }
    return ()
  }
  if positional.length() < 2 {
    raise @git.GitError::InvalidObject(
      "usage: git update-ref <refname> <newvalue> [<oldvalue>]",
    )
  }
  let refname = positional[0]
  let new_value = positional[1]
  let old_value : String? = if positional.length() >= 3 {
    Some(positional[2])
  } else {
    None
  }
  let new_id = @git.ObjectId::from_hex(new_value) catch {
    _ =>
      match @gitrepo.rev_parse(fs, actual_git_dir, new_value) {
        Some(id) => id
        None =>
          raise @git.GitError::InvalidObject("unknown revision: " + new_value)
      }
  }
  // Get current value
  let current_id = read_ref_value(fs, actual_git_dir, refname)
  // Check oldvalue if specified
  match old_value {
    Some(ov) => {
      let expected_id = @git.ObjectId::from_hex(ov)
      match current_id {
        Some(cur_id) =>
          if cur_id.to_hex() != expected_id.to_hex() {
            @stdio.stderr.write(
              "error: cannot lock ref '\{refname}': is at \{cur_id.to_hex()} but expected \{expected_id.to_hex()}",
            )
            @sys.exit(1)
          }
        None =>
          if expected_id.to_hex() != @git.ObjectId::zero().to_hex() {
            @stdio.stderr.write(
              "error: cannot lock ref '\{refname}': unable to resolve reference '\{refname}'",
            )
            @sys.exit(1)
          }
      }
    }
    None => ()
  }
  let ref_path = actual_git_dir + "/" + refname
  // Ensure parent directory exists
  let dir = match ref_path.rev_find("/") {
    None => ""
    Some(i) => String::unsafe_substring(ref_path, start=0, end=i)
  }
  if dir.length() > 0 && not(fs.is_dir(dir)) {
    fs.mkdir_p(dir)
  }
  // Write the ref
  fs.write_string(ref_path, new_id.to_hex() + "\n")
  // Handle reflog
  let rfs : &@git.RepoFileSystem = fs
  let wfs : &@git.FileSystem = fs
  let (should_log, always) = @gitrepo.should_log_ref(
    rfs, actual_git_dir, refname, is_bare,
  )
  if create_reflog {
    // Create reflog if requested
    @gitrepo.create_reflog(wfs, rfs, actual_git_dir, refname)
  }
  if should_log ||
    always ||
    create_reflog ||
    @gitrepo.reflog_exists(rfs, actual_git_dir, refname) {
    let old_id = current_id.unwrap_or(@git.ObjectId::zero())
    let msg = message.unwrap_or("update-ref: updating")
    @gitrepo.append_reflog(
      wfs, rfs, actual_git_dir, refname, old_id, new_id, author, email, timestamp,
      timezone, msg,
    )
  }
}

///|
fn read_ref_value(
  fs : &@git.RepoFileSystem,
  git_dir : String,
  refname : String,
) -> @git.ObjectId? {
  let ref_path = git_dir + "/" + refname
  if fs.is_file(ref_path) {
    let content = decode_bytes(fs.read_file(ref_path)) catch {
      _ => return None
    }
    let hex = trim_chars(content, " \t\r\n")
    if hex.has_prefix("ref: ") {
      // Symbolic ref - resolve it
      let target = String::unsafe_substring(hex, start=5, end=hex.length())
      return read_ref_value(fs, git_dir, target)
    }
    (hex |> @git.ObjectId::from_hex |> Some) catch {
      _ => None
    }
  } else {
    // Check packed-refs
    @gitlib.resolve_ref(fs, git_dir, refname) catch {
      _ => None
    }
  }
}

///|
fn get_author_info(
  fs : &@git.RepoFileSystem,
  git_dir : String,
) -> (String, String) {
  // Try to get from config or environment
  let config_path = git_dir + "/config"
  let mut name = "Unknown"
  let mut email = "unknown@unknown"
  // Check environment variables first
  if @sys.get_env_var("GIT_COMMITTER_NAME") is Some(n) {
    name = n
  }
  if @sys.get_env_var("GIT_COMMITTER_EMAIL") is Some(e) {
    email = e
  }
  // If not in env, try config
  if name == "Unknown" || email == "unknown@unknown" {
    if fs.is_file(config_path) {
      let content = decode_bytes(fs.read_file(config_path)) catch {
        _ => return (name, email)
      }
      let mut in_user = false
      for line_view in content.split("\n") {
        let line = trim_chars(line_view.to_string(), " \t\r")
        if line.has_prefix("[user]") {
          in_user = true
          continue
        }
        if line.has_prefix("[") {
          in_user = false
          continue
        }
        if in_user {
          if line.has_prefix("name") {
            let eq_idx = line.find("=")
            match eq_idx {
              Some(i) =>
                name = trim_chars(
                  String::unsafe_substring(line, start=i + 1, end=line.length()),
                  " \t",
                )
              None => ()
            }
          }
          if line.has_prefix("email") {
            let eq_idx = line.find("=")
            match eq_idx {
              Some(i) =>
                email = trim_chars(
                  String::unsafe_substring(line, start=i + 1, end=line.length()),
                  " \t",
                )
              None => ()
            }
          }
        }
      }
    }
  }
  (name, email)
}

///|

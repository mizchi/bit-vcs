///|
fn update_ref_storage_runtime_parsed_args(
  args : Array[String],
) -> @runtime.StorageUpdateRefArgs? {
  let parsed = storage_runtime_parse_command("update-ref", args) catch {
    _ => return None
  }
  match parsed {
    @runtime.StorageCommand::UpdateRef(update_args) => Some(update_args)
    _ => None
  }
}

///|
fn update_ref_should_use_storage_runtime_args(args : Array[String]) -> Bool {
  update_ref_storage_runtime_parsed_args(args) is Some(_)
}

///|
fn update_ref_storage_runtime_delegate_args(
  fs : &@bitcore.RepoFileSystem,
  git_dir : String,
  is_bare : Bool,
  args : Array[String],
) -> @runtime.StorageUpdateRefArgs? {
  let parsed = match update_ref_storage_runtime_parsed_args(args) {
    Some(value) => value
    None => return None
  }
  // Keep cmd implementation for delete/reflog/symbolic-ref sensitive paths.
  if parsed.delete_mode {
    return None
  }
  let normalized_refname = @bitlib.normalize_repo_path(parsed.refname) catch {
    _ => return None
  }
  if not(parsed.refname.has_prefix("refs/")) {
    return None
  }
  if not(normalized_refname.has_prefix("refs/")) {
    return None
  }
  if resolve_symbolic_ref_target(fs, git_dir, normalized_refname) is Some(_) {
    return None
  }
  let (should_log, always) = @bitrepo.should_log_ref(
    fs, git_dir, normalized_refname, is_bare,
  ) catch {
    _ => return None
  }
  if should_log ||
    always ||
    @bitrepo.reflog_exists(fs, git_dir, normalized_refname) {
    return None
  }
  Some(parsed)
}

///|
async fn handle_update_ref(args : Array[String]) -> Unit raise Error {
  let root = get_work_root()
  let fs = OsFs::new()
  let rfs : &@bitcore.RepoFileSystem = fs
  let git_dir = resolve_git_dir(rfs, root)
  if is_reftable_repo(rfs, git_dir) {
    eprint_line(
      "fatal: update-ref on reftable repository is not supported in standalone mode",
    )
    @sys.exit(1)
  }
  let is_bare = is_bare_repo_dir(root)
  if update_ref_should_use_storage_runtime_args(args) {
    match
      update_ref_storage_runtime_delegate_args(rfs, git_dir, is_bare, args) {
      Some(update_args) => {
        @runtime.run_storage_command(
          fs,
          rfs,
          root,
          @runtime.StorageCommand::UpdateRef(update_args),
        )
        return
      }
      None => ()
    }
  }
  let mut delete_mode = false
  let mut create_reflog = false
  let mut no_deref = false
  let mut stdin_mode = false
  let mut message : String? = None
  let positional : Array[String] = []
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    match arg {
      "-d" | "--delete" => delete_mode = true
      "--create-reflog" => create_reflog = true
      "--no-deref" => no_deref = true
      "--stdin" => stdin_mode = true
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
  let actual_git_dir = git_dir
  let head_target = resolve_symbolic_ref_target(fs, actual_git_dir, "HEAD")
  // Get current timestamp for reflog
  let timestamp = get_current_timestamp()
  let timezone = "+0000"
  let (author, email) = get_author_info(fs, actual_git_dir)
  if stdin_mode {
    let input = decode_bytes(read_all_stdin())
    let mut stdin_no_deref = no_deref
    let mut stdin_create_reflog = create_reflog
    for line_view in input.split("\n") {
      let line = trim_chars(line_view.to_string(), " \t\r\n")
      if line.length() == 0 {
        continue
      }
      let tokens = update_ref_split_stdin_tokens(line)
      if tokens.length() == 0 {
        continue
      }
      let cmd = tokens[0]
      match cmd {
        "option" => {
          if tokens.length() != 2 {
            eprint_line("fatal: update-ref: option requires one argument")
            @sys.exit(128)
          }
          match tokens[1] {
            "no-deref" => stdin_no_deref = true
            "create-reflog" => stdin_create_reflog = true
            _ => {
              eprint_line("fatal: update-ref: unknown option: " + tokens[1])
              @sys.exit(128)
            }
          }
        }
        "start" | "prepare" | "commit" | "abort" => ()
        "create" => {
          if tokens.length() != 3 {
            eprint_line("fatal: update-ref: create requires <ref> <newvalue>")
            @sys.exit(128)
          }
          let cmd_args = update_ref_stdin_base_args(
            stdin_no_deref, stdin_create_reflog, message,
          )
          cmd_args.push(tokens[1])
          cmd_args.push(tokens[2])
          cmd_args.push(@bitcore.ObjectId::zero().to_hex())
          handle_update_ref(cmd_args)
        }
        "update" => {
          if tokens.length() != 3 && tokens.length() != 4 {
            eprint_line(
              "fatal: update-ref: update requires <ref> <newvalue> [<oldvalue>]",
            )
            @sys.exit(128)
          }
          let cmd_args = update_ref_stdin_base_args(
            stdin_no_deref, stdin_create_reflog, message,
          )
          cmd_args.push(tokens[1])
          cmd_args.push(tokens[2])
          if tokens.length() == 4 {
            cmd_args.push(tokens[3])
          }
          handle_update_ref(cmd_args)
        }
        "delete" => {
          if tokens.length() != 2 && tokens.length() != 3 {
            eprint_line("fatal: update-ref: delete requires <ref> [<oldvalue>]")
            @sys.exit(128)
          }
          let cmd_args = update_ref_stdin_base_args(
            stdin_no_deref, stdin_create_reflog, message,
          )
          cmd_args.push("-d")
          cmd_args.push(tokens[1])
          if tokens.length() == 3 {
            cmd_args.push(tokens[2])
          }
          handle_update_ref(cmd_args)
        }
        "verify" => {
          if tokens.length() != 2 && tokens.length() != 3 {
            eprint_line("fatal: update-ref: verify requires <ref> [<oldvalue>]")
            @sys.exit(128)
          }
          let refname = normalize_update_ref_name(tokens[1])
          let refname = resolve_update_target_ref(
            fs, actual_git_dir, refname, stdin_no_deref,
          )
          let current_id = read_ref_value(fs, actual_git_dir, refname)
          let ok = match tokens.length() {
            2 => current_id is Some(_)
            _ => {
              let expected_id = @bitcore.ObjectId::from_hex(tokens[2]) catch {
                _ => @bitcore.ObjectId::zero()
              }
              match current_id {
                Some(cur_id) => cur_id.to_hex() == expected_id.to_hex()
                None =>
                  expected_id.to_hex() == @bitcore.ObjectId::zero().to_hex()
              }
            }
          }
          if not(ok) {
            eprint_line("fatal: update-ref: verify failed for " + tokens[1])
            @sys.exit(1)
          }
        }
        _ => {
          eprint_line("fatal: update-ref: unknown command: " + cmd)
          @sys.exit(128)
        }
      }
    }
    return ()
  }
  if delete_mode {
    if positional.length() < 1 {
      raise @bitcore.GitError::InvalidObject(
        "usage: git update-ref -d <refname>",
      )
    }
    let input_refname = normalize_update_ref_name(positional[0])
    let refname = resolve_update_target_ref(
      fs, actual_git_dir, input_refname, no_deref,
    )
    if not(no_deref) &&
      has_symbolic_ref_cycle(fs, actual_git_dir, input_refname) {
      @stdio.stderr.write(
        "error: cannot lock ref '\{input_refname}': unable to resolve reference '\{input_refname}'",
      )
      @sys.exit(1)
    }
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
      @bitcore.ObjectId::zero(),
    )
    // Delete the ref
    if fs.is_file(ref_path) {
      fs.remove_file(ref_path)
    }
    delete_packed_ref_entry(fs, actual_git_dir, refname)
    // Write reflog entry for deletion
    let rfs : &@bitcore.RepoFileSystem = fs
    let wfs : &@bitcore.FileSystem = fs
    let (should_log, _) = @bitrepo.should_log_ref(
      rfs, actual_git_dir, refname, is_bare,
    )
    let should_head_log = should_update_head_reflog(
      input_refname, refname, no_deref, head_target,
    )
    let msg = message.unwrap_or("update-ref: delete")
    if should_log || @bitrepo.reflog_exists(rfs, actual_git_dir, refname) {
      @bitrepo.append_reflog(
        wfs,
        rfs,
        actual_git_dir,
        refname,
        old_id,
        @bitcore.ObjectId::zero(),
        author,
        email,
        timestamp,
        timezone,
        msg,
      )
    }
    if should_head_log {
      @bitrepo.append_reflog(
        wfs,
        rfs,
        actual_git_dir,
        "HEAD",
        old_id,
        @bitcore.ObjectId::zero(),
        author,
        email,
        timestamp,
        timezone,
        msg,
      )
    }
    if refname != "HEAD" {
      @bitrepo.delete_reflog(wfs, rfs, actual_git_dir, refname)
    }
    return ()
  }
  if positional.length() < 2 {
    raise @bitcore.GitError::InvalidObject(
      "usage: git update-ref <refname> <newvalue> [<oldvalue>]",
    )
  }
  let input_refname = normalize_update_ref_name(positional[0])
  let refname = resolve_update_target_ref(
    fs, actual_git_dir, input_refname, no_deref,
  )
  if not(no_deref) && has_symbolic_ref_cycle(fs, actual_git_dir, input_refname) {
    @stdio.stderr.write(
      "error: cannot lock ref '\{input_refname}': unable to resolve reference '\{input_refname}'",
    )
    @sys.exit(1)
  }
  let new_value = if positional[1] == "@" { "HEAD" } else { positional[1] }
  let old_value : String? = if positional.length() >= 3 {
    Some(positional[2])
  } else {
    None
  }
  let new_id = @bitcore.ObjectId::from_hex(new_value) catch {
    _ =>
      match @bitrepo.rev_parse(fs, actual_git_dir, new_value) {
        Some(id) => id
        None =>
          raise @bitcore.GitError::InvalidObject(
            "unknown revision: " + new_value,
          )
      }
  }
  // Get current value
  let current_id = read_ref_value(fs, actual_git_dir, refname)
  // Check oldvalue if specified
  match old_value {
    Some(ov) => {
      let expected_id = @bitcore.ObjectId::from_hex(ov)
      match current_id {
        Some(cur_id) =>
          if cur_id.to_hex() != expected_id.to_hex() {
            @stdio.stderr.write(
              "error: cannot lock ref '\{refname}': is at \{cur_id.to_hex()} but expected \{expected_id.to_hex()}",
            )
            @sys.exit(1)
          }
        None =>
          if expected_id.to_hex() != @bitcore.ObjectId::zero().to_hex() {
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
  let rfs : &@bitcore.RepoFileSystem = fs
  let wfs : &@bitcore.FileSystem = fs
  let (should_log, always) = @bitrepo.should_log_ref(
    rfs, actual_git_dir, refname, is_bare,
  )
  if create_reflog {
    // Create reflog if requested
    @bitrepo.create_reflog(wfs, rfs, actual_git_dir, refname)
  }
  let should_head_log = should_update_head_reflog(
    input_refname, refname, no_deref, head_target,
  )
  if should_log ||
    always ||
    create_reflog ||
    should_head_log ||
    @bitrepo.reflog_exists(rfs, actual_git_dir, refname) {
    let old_id = current_id.unwrap_or(@bitcore.ObjectId::zero())
    let msg = message.unwrap_or("update-ref: updating")
    if should_log ||
      always ||
      create_reflog ||
      @bitrepo.reflog_exists(rfs, actual_git_dir, refname) {
      @bitrepo.append_reflog(
        wfs, rfs, actual_git_dir, refname, old_id, new_id, author, email, timestamp,
        timezone, msg,
      )
    }
    if should_head_log {
      @bitrepo.append_reflog(
        wfs, rfs, actual_git_dir, "HEAD", old_id, new_id, author, email, timestamp,
        timezone, msg,
      )
    }
  }
}

///|
fn normalize_update_ref_name(
  refname : String,
) -> String raise @bitcore.GitError {
  let normalized = @bitlib.normalize_repo_path(refname) catch {
    _ => raise @bitcore.GitError::InvalidObject("invalid refname: " + refname)
  }
  if normalized == "HEAD" || normalized.has_prefix("refs/") {
    normalized
  } else {
    raise @bitcore.GitError::InvalidObject("invalid refname: " + refname)
  }
}

///|
fn resolve_update_target_ref(
  fs : &@bitcore.RepoFileSystem,
  git_dir : String,
  refname : String,
  no_deref : Bool,
) -> String {
  if no_deref {
    return refname
  }
  resolve_symbolic_ref_target(fs, git_dir, refname).unwrap_or(refname)
}

///|
fn resolve_symbolic_ref_target(
  fs : &@bitcore.RepoFileSystem,
  git_dir : String,
  refname : String,
) -> String? {
  let mut current = refname
  let mut depth = 0
  while depth < 8 {
    let ref_path = git_dir + "/" + current
    if not(fs.is_file(ref_path)) {
      return if current == refname { None } else { Some(current) }
    }
    let content = decode_bytes(fs.read_file(ref_path)) catch {
      _ => return if current == refname { None } else { Some(current) }
    }
    let line = trim_chars(content, " \t\r\n")
    if not(line.has_prefix("ref: ")) {
      return if current == refname { None } else { Some(current) }
    }
    current = String::unsafe_substring(line, start=5, end=line.length())
    depth += 1
  }
  if current == refname {
    None
  } else {
    Some(current)
  }
}

///|
fn should_update_head_reflog(
  input_refname : String,
  refname : String,
  no_deref : Bool,
  head_target : String?,
) -> Bool {
  if no_deref {
    return false
  }
  if refname == "HEAD" {
    return false
  }
  if input_refname == "HEAD" {
    return true
  }
  match head_target {
    Some(head_ref) => head_ref == refname
    None => false
  }
}

///|
fn delete_packed_ref_entry(
  fs : OsFs,
  git_dir : String,
  refname : String,
) -> Unit raise Error {
  let packed_refs_path = git_dir + "/packed-refs"
  if not(fs.is_file(packed_refs_path)) {
    return ()
  }
  let content = decode_bytes(fs.read_file(packed_refs_path)) catch {
    _ => return ()
  }
  let lines : Array[String] = []
  let mut removed = false
  let mut skip_peeled = false
  for line_view in content.split("\n") {
    let line = line_view.to_string()
    if skip_peeled && line.has_prefix("^") {
      skip_peeled = false
      removed = true
      continue
    }
    skip_peeled = false
    if line.length() > 0 &&
      not(line.has_prefix("#")) &&
      not(line.has_prefix("^")) {
      let space_idx = line.find(" ")
      match space_idx {
        Some(i) => {
          let packed_ref = String::unsafe_substring(
            line,
            start=i + 1,
            end=line.length(),
          )
          if packed_ref == refname {
            removed = true
            skip_peeled = true
            continue
          }
        }
        None => ()
      }
    }
    lines.push(line)
  }
  if removed {
    fs.write_string(packed_refs_path, lines.join("\n"))
  }
}

///|
fn has_symbolic_ref_cycle(
  fs : &@bitcore.RepoFileSystem,
  git_dir : String,
  refname : String,
) -> Bool {
  let visited : Array[String] = []
  let mut current = refname
  let mut depth = 0
  while depth < 16 {
    for prev in visited {
      if prev == current {
        return true
      }
    }
    visited.push(current)
    let ref_path = git_dir + "/" + current
    if not(fs.is_file(ref_path)) {
      return false
    }
    let content = decode_bytes(fs.read_file(ref_path)) catch {
      _ => return false
    }
    let line = trim_chars(content, " \t\r\n")
    if not(line.has_prefix("ref: ")) {
      return false
    }
    current = String::unsafe_substring(line, start=5, end=line.length())
    depth += 1
  }
  true
}

///|
fn read_ref_value(
  fs : &@bitcore.RepoFileSystem,
  git_dir : String,
  refname : String,
) -> @bitcore.ObjectId? {
  read_ref_value_inner(fs, git_dir, refname, 0)
}

///|
fn read_ref_value_inner(
  fs : &@bitcore.RepoFileSystem,
  git_dir : String,
  refname : String,
  depth : Int,
) -> @bitcore.ObjectId? {
  if depth > 8 {
    return None
  }
  let ref_path = git_dir + "/" + refname
  if fs.is_file(ref_path) {
    let content = decode_bytes(fs.read_file(ref_path)) catch {
      _ => return None
    }
    let hex = trim_chars(content, " \t\r\n")
    if hex.has_prefix("ref: ") {
      // Symbolic ref - resolve it
      let target = String::unsafe_substring(hex, start=5, end=hex.length())
      return read_ref_value_inner(fs, git_dir, target, depth + 1)
    }
    (hex |> @bitcore.ObjectId::from_hex |> Some) catch {
      _ => None
    }
  } else {
    // Check packed-refs
    @bitlib.resolve_ref(fs, git_dir, refname) catch {
      _ => None
    }
  }
}

///|
fn get_author_info(
  fs : &@bitcore.RepoFileSystem,
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
fn update_ref_split_stdin_tokens(line : String) -> Array[String] {
  let tokens : Array[String] = []
  for token_view in line.split(" ") {
    let token = trim_string(token_view.to_string())
    if token.length() > 0 {
      tokens.push(token)
    }
  }
  tokens
}

///|
fn update_ref_stdin_base_args(
  no_deref : Bool,
  create_reflog : Bool,
  message : String?,
) -> Array[String] {
  let args : Array[String] = []
  if no_deref {
    args.push("--no-deref")
  }
  if create_reflog {
    args.push("--create-reflog")
  }
  match message {
    Some(msg) => {
      args.push("-m")
      args.push(msg)
    }
    None => ()
  }
  args
}

///|

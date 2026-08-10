///|

///|
async fn show_commit_command_help() -> Unit {
  show_simple_command_help(
    "git commit [<options>]",
    summary="Record changes to the repository.",
  )
}

///|
fn commit_need_real_git() -> Bool {
  false
}

///|
fn commit_storage_runtime_parsed_args(
  args : Array[String],
) -> @runtime.StorageCommitArgs? {
  if commit_need_real_git() {
    return None
  }
  let parsed = storage_runtime_parse_command("commit", args) catch {
    _ => return None
  }
  match parsed {
    @runtime.StorageCommand::Commit(commit_args) => Some(commit_args)
    _ => None
  }
}

///|
fn commit_should_use_storage_runtime(args : Array[String]) -> Bool {
  commit_storage_runtime_parsed_args(args) is Some(_)
}

///|
fn commit_has_no_verify_flag(args : Array[String]) -> Bool {
  for arg in args {
    if arg == "--no-verify" {
      return true
    }
  }
  false
}

///|
fn commit_has_merge_state(fs : OsFs, git_dir : String) -> Bool {
  fs.is_file(git_dir + "/MERGE_HEAD") ||
  fs.is_file(git_dir + "/MERGE_MSG") ||
  fs.is_file(git_dir + "/MERGE_MODE") ||
  fs.is_file(git_dir + "/SQUASH_MSG")
}

///|
fn commit_storage_runtime_delegate_args(
  fs : OsFs,
  git_dir : String,
  args : Array[String],
) -> @runtime.StorageCommitArgs? {
  let parsed = match commit_storage_runtime_parsed_args(args) {
    Some(value) => value
    None => return None
  }
  if commit_has_merge_state(fs, git_dir) {
    return None
  }
  if !commit_has_no_verify_flag(args) {
    // Check for hooks in default location and core.hooksPath
    let common_git_dir = resolve_common_git_dir(fs, git_dir)
    let has_hooks_path_config = @bitlib.read_config_value(
        fs,
        common_git_dir + "/config",
        "core",
        "hookspath",
      )
      is Some(_)
    if has_hooks_path_config || fs.is_file(common_git_dir + "/hooks/pre-commit") {
      return None
    }
  }
  if !parsed.quiet && get_subdir_info(fs, git_dir) is Some(_) {
    return None
  }
  Some({
    message: parsed.message,
    all_modified: parsed.all_modified,
    allow_empty: parsed.allow_empty,
    quiet: parsed.quiet,
    encoding: resolve_commit_message_encoding(git_dir),
  })
}

///|
async fn handle_commit(args : Array[String]) -> Unit raise Error {
  let root = get_work_root()
  let fs = OsFs::new()
  let rfs : &@bitcore.RepoFileSystem = fs
  let git_dir = resolve_git_dir(rfs, root)
  ignore(commit_args_require_standalone_error(args))

  if commit_should_use_storage_runtime(args) &&
    !commit_signing_requested(git_dir, args) {
    match commit_storage_runtime_delegate_args(fs, git_dir, args) {
      Some(commit_args) => {
        // Pass resolved author/committer to storage_runtime via env bridge
        @sys.set_env_var("BIT_COMMIT_AUTHOR", get_author_string())
        @sys.set_env_var("BIT_COMMIT_COMMITTER", get_committer_string())
        @runtime.run_storage_command(
          fs,
          rfs,
          root,
          @runtime.StorageCommand::Commit(commit_args),
        )
        return
      }
      None => ()
    }
  }
  let commit_message_encoding = resolve_commit_message_encoding(git_dir)
  // Track message source for mutual exclusivity checks
  let messages : Array[String] = []
  let mut message_source : String = "" // "m", "F", "C", "c"
  let mut all_modified = false
  let mut amend = false
  let mut allow_empty = false
  let mut allow_empty_message = false
  let mut no_verify = false
  let mut no_edit = false
  let mut quiet = false
  let mut signoff = false
  let mut gpg_sign : Bool? = None
  let mut signing_key : String? = None
  let mut cleanup_mode = "default"
  let mut author_override : String? = None
  let mut date_override : String? = None
  let mut edit_flag : Bool? = None
  let pathspecs : Array[String] = []
  let mut end_of_options = false
  let mut include_mode = false
  let mut only_mode = false
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    if end_of_options {
      pathspecs.push(arg)
      i += 1
      continue
    }
    match arg {
      "--" => {
        end_of_options = true
        i += 1
        continue
      }
      "-m" if i + 1 < args.length() => {
        commit_check_message_source_conflict(message_source, "m")
        message_source = "m"
        messages.push(args[i + 1])
        i += 2
        continue
      }
      "--message" if i + 1 < args.length() => {
        commit_check_message_source_conflict(message_source, "m")
        message_source = "m"
        messages.push(args[i + 1])
        i += 2
        continue
      }
      "-am" | "-ma" if i + 1 < args.length() => {
        commit_check_message_source_conflict(message_source, "m")
        message_source = "m"
        all_modified = true
        messages.push(args[i + 1])
        i += 2
        continue
      }
      "-qm" | "-mq" if i + 1 < args.length() => {
        commit_check_message_source_conflict(message_source, "m")
        message_source = "m"
        quiet = true
        messages.push(args[i + 1])
        i += 2
        continue
      }
      "-qam" | "-qma" | "-aqm" | "-amq" | "-maq" | "-mqa" if i + 1 <
        args.length() => {
        commit_check_message_source_conflict(message_source, "m")
        message_source = "m"
        all_modified = true
        quiet = true
        messages.push(args[i + 1])
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
        commit_check_message_source_conflict(message_source, "F")
        message_source = "F"
        messages.push(
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
        commit_check_message_source_conflict(message_source, "C")
        message_source = "C"
        let rev_msg = read_commit_message_from_revision(fs, root, args[i + 1])
        match rev_msg {
          Some(m) => messages.push(m)
          None => {
            eprint_line("fatal: could not lookup commit \{args[i + 1]}")
            @sys.exit(128)
          }
        }
        i += 2
        continue
      }
      "-c" if i + 1 < args.length() => {
        commit_check_message_source_conflict(message_source, "c")
        message_source = "c"
        let rev_msg = read_commit_message_from_revision(fs, root, args[i + 1])
        match rev_msg {
          Some(m) => messages.push(m)
          None => {
            eprint_line("fatal: could not lookup commit \{args[i + 1]}")
            @sys.exit(128)
          }
        }
        edit_flag = Some(true)
        i += 2
        continue
      }
      _ if arg.has_prefix("-m") && !arg.has_prefix("-ma") => {
        commit_check_message_source_conflict(message_source, "m")
        message_source = "m"
        messages.push(string_slice_from(arg, 2))
        i += 1
        continue
      }
      _ if arg.has_prefix("-am") || arg.has_prefix("-ma") => {
        commit_check_message_source_conflict(message_source, "m")
        message_source = "m"
        all_modified = true
        messages.push(string_slice_from(arg, 3))
        i += 1
        continue
      }
      _ if arg.has_prefix("--message=") => {
        commit_check_message_source_conflict(message_source, "m")
        message_source = "m"
        messages.push(string_slice_from(arg, 10))
        i += 1
        continue
      }
      _ if arg.has_prefix("--author=") => {
        author_override = Some(string_slice_from(arg, 9))
        i += 1
        continue
      }
      _ if arg.has_prefix("--date=") => {
        date_override = Some(string_slice_from(arg, 7))
        i += 1
        continue
      }
      _ if arg.has_prefix("-F") => {
        commit_check_message_source_conflict(message_source, "F")
        message_source = "F"
        let file = string_slice_from(arg, 2)
        messages.push(
          read_commit_message_from_file(fs, root, file, commit_message_encoding),
        )
        i += 1
        continue
      }
      _ if arg.has_prefix("-C") => {
        commit_check_message_source_conflict(message_source, "C")
        message_source = "C"
        let spec = string_slice_from(arg, 2)
        let rev_msg = read_commit_message_from_revision(fs, root, spec)
        match rev_msg {
          Some(m) => messages.push(m)
          None => {
            eprint_line("fatal: could not lookup commit \{spec}")
            @sys.exit(128)
          }
        }
        i += 1
        continue
      }
      _ if arg.has_prefix("-c") && arg.length() > 2 => {
        commit_check_message_source_conflict(message_source, "c")
        message_source = "c"
        let spec = string_slice_from(arg, 2)
        let rev_msg = read_commit_message_from_revision(fs, root, spec)
        match rev_msg {
          Some(m) => messages.push(m)
          None => {
            eprint_line("fatal: could not lookup commit \{spec}")
            @sys.exit(128)
          }
        }
        edit_flag = Some(true)
        i += 1
        continue
      }
      "-a" | "--all" => all_modified = true
      "--amend" => amend = true
      "--allow-empty" => allow_empty = true
      "--allow-empty-message" => allow_empty_message = true
      "-S" | "--gpg-sign" => gpg_sign = Some(true)
      "--no-gpg-sign" => {
        gpg_sign = Some(false)
        signing_key = None
      }
      "--no-verify" | "-n" => no_verify = true
      "--no-edit" => no_edit = true
      "--edit" | "-e" => edit_flag = Some(true)
      "-q" | "--quiet" => quiet = true
      "-s" | "--signoff" => signoff = true
      "--no-signoff" => signoff = false
      "--cleanup" if i + 1 < args.length() => {
        match commit_normalize_cleanup_mode(args[i + 1]) {
          Some(mode) => cleanup_mode = mode
          None => {
            eprint_line("fatal: invalid cleanup mode `\{args[i + 1]}`")
            @sys.exit(128)
          }
        }
        i += 2
        continue
      }
      "-i" | "--include" => include_mode = true
      "-o" | "--only" => only_mode = true
      "--dry-run"
      | "--short"
      | "--porcelain"
      | "--long"
      | "--status"
      | "--no-status" => ()
      "-t" | "--template" if i + 1 < args.length() => {
        i += 2
        continue
      }
      _ if arg.has_prefix("--cleanup=") => {
        let value = string_slice_from(arg, 10)
        match commit_normalize_cleanup_mode(value) {
          Some(mode) => cleanup_mode = mode
          None => {
            eprint_line("fatal: invalid cleanup mode `\{value}`")
            @sys.exit(128)
          }
        }
        i += 1
        continue
      }
      _ if arg.has_prefix("--gpg-sign=") => {
        gpg_sign = Some(true)
        let value = string_slice_from(arg, 11)
        if value.length() > 0 {
          signing_key = Some(value)
        }
        i += 1
        continue
      }
      _ if arg.has_prefix("-S") => {
        gpg_sign = Some(true)
        let value = string_slice_from(arg, 2)
        if value.length() > 0 {
          signing_key = Some(value)
        }
        i += 1
        continue
      }
      _ if arg.has_prefix("--template=") || arg.has_prefix("-t") => ()
      _ if arg.has_prefix("-") => warn_unimplemented_arg("commit", arg)
      _ => pathspecs.push(arg)
    }
    i += 1
  }
  // Validate --include and --only don't mix
  if include_mode && only_mode {
    eprint_line(
      "fatal: options '-i/--include' and '-o/--only' cannot be used together",
    )
    @sys.exit(128)
  }
  // Validate -a and pathspecs don't mix
  if all_modified && pathspecs.length() > 0 {
    eprint_line(
      "fatal: paths '\{pathspecs[0]} ...' with -a does not make sense",
    )
    @sys.exit(128)
  }
  let git_dir = resolve_git_dir(fs, root)
  let merge_heads = read_merge_head_ids(fs, git_dir)
  let should_cleanup_merge_state = merge_heads.length() > 0 ||
    fs.is_file(git_dir + "/MERGE_MSG") ||
    fs.is_file(git_dir + "/MERGE_MODE") ||
    fs.is_file(git_dir + "/SQUASH_MSG")
  // If -a flag, stage all modified files
  if all_modified {
    let status = @bitlib.status(fs, root)
    let paths_to_add : Array[String] = []
    for p in status.unstaged_modified {
      paths_to_add.push(p)
    }
    for p in status.unstaged_deleted {
      paths_to_add.push(p)
    }
    if paths_to_add.length() > 0 {
      @bitlib.add_paths_async(fs, fs, root, paths_to_add)
    }
  }
  // Handle pathspec-based partial commit (--include / --only / positional args)
  if pathspecs.length() > 0 {
    commit_handle_pathspec_staging(
      fs, rfs, root, git_dir, pathspecs, include_mode, only_mode,
    )
  }
  // Build final message
  let mut message : String? = if messages.length() > 0 {
    Some(messages.join("\n\n"))
  } else {
    None
  }
  // Open editor when message is not specified.
  let should_edit = match edit_flag {
    Some(v) => v
    None => message is None
  }
  if message is None {
    if no_edit {
      message = resolve_no_edit_commit_message(fs, root, git_dir, amend)
    } else {
      let initial_message = if amend {
        get_head_commit_message(fs, root)
      } else {
        None
      }
      message = read_commit_message_from_editor(
        fs,
        root,
        initial_message~,
        allow_empty_message~,
      )
    }
  } else if should_edit && !no_edit {
    // -c or --edit: open editor with existing message
    message = read_commit_message_from_editor(
      fs,
      root,
      initial_message=message,
      allow_empty_message~,
    )
  }
  guard message is Some(msg) else {
    raise @bitcore.GitError::InvalidObject(
      "Aborting commit due to empty commit message.",
    )
  }
  // Validate empty message
  let stripped_msg = commit_prepare_message_for_validation(msg, cleanup_mode)
  if stripped_msg.length() == 0 && !allow_empty_message {
    eprint_line("Aborting commit due to empty commit message.")
    @sys.exit(1)
  }
  // Apply --signoff
  let msg = if signoff { commit_apply_signoff(msg) } else { msg }
  let default_author = get_author_string()
  let default_author_timestamp = get_author_timestamp()
  let author_timezone = get_author_timezone()
  let default_timestamp = get_commit_timestamp()
  let commit_timezone = get_commit_timezone()
  let author = match author_override {
    Some(a) => a
    None => default_author
  }
  let author_timestamp = match date_override {
    Some(d) => parse_commit_date(d)
    None => default_author_timestamp
  }
  let resolved_author_timezone = match date_override {
    Some(d) => parse_git_env_timezone(d).unwrap_or(author_timezone)
    None => author_timezone
  }
  // Committer is always the current user
  let committer = get_committer_string()
  let committer_timestamp = default_timestamp
  let commit_algo = signing_repo_hash_algorithm(fs, git_dir)
  let should_sign = match gpg_sign {
    Some(flag) => flag
    None => signing_commit_config_enabled(git_dir)
  }
  if !no_verify {
    let hook_status = run_pre_commit_hook(fs, root, git_dir)
    if hook_status != 0 {
      raise @bitcore.GitError::InvalidObject("pre-commit hook failed")
    }
  }
  let commit_id = if amend {
    if should_sign {
      commit_signed_amend(
        fs,
        fs,
        root,
        msg,
        author,
        author_timestamp,
        committer~,
        committer_timestamp~,
        timezone=commit_timezone,
        encoding=commit_message_encoding,
        author_timezone=resolved_author_timezone,
        committer_timezone=commit_timezone,
        algo=commit_algo,
        signing_key_override=signing_key,
      )
    } else {
      @bitlib.commit_amend(
        fs,
        fs,
        root,
        msg,
        author,
        author_timestamp,
        committer~,
        committer_timestamp~,
        timezone=commit_timezone,
        encoding=commit_message_encoding,
        author_timezone=Some(resolved_author_timezone),
        committer_timezone=Some(commit_timezone),
        algo=commit_algo,
      )
    }
  } else if merge_heads.length() > 0 {
    commit_with_merge_heads(
      fs,
      fs,
      root,
      msg,
      author,
      author_timestamp,
      committer,
      committer_timestamp,
      merge_heads,
      allow_empty,
      encoding=commit_message_encoding,
      author_timezone=resolved_author_timezone,
      committer_timezone=commit_timezone,
      algo=commit_algo,
      sign=should_sign,
      signing_fs=if should_sign { Some(fs) } else { None },
      signing_key_override=signing_key,
    )
  } else if should_sign {
    commit_signed(
      fs,
      fs,
      root,
      msg,
      author,
      author_timestamp,
      committer~,
      committer_timestamp~,
      allow_empty~,
      timezone=commit_timezone,
      encoding=commit_message_encoding,
      author_timezone=resolved_author_timezone,
      committer_timezone=commit_timezone,
      algo=commit_algo,
      signing_key_override=signing_key,
    )
  } else {
    @bitlib.commit(
      fs,
      fs,
      root,
      msg,
      author,
      author_timestamp,
      committer~,
      committer_timestamp~,
      allow_empty~,
      timezone=commit_timezone,
      encoding=commit_message_encoding,
      author_timezone=Some(resolved_author_timezone),
      committer_timezone=Some(commit_timezone),
      algo=commit_algo,
    )
  }
  if should_cleanup_merge_state {
    cleanup_merge_state_files(fs, git_dir)
  }
  // Build output like git: [branch (root-commit) short_id] first_line
  let short_id = string_slice_to(commit_id.to_hex(), 7)
  let first_line = match msg.find("\n") {
    Some(idx) => string_slice_to(msg, idx)
    None => msg
  }
  if !quiet {
    let branch_name = commit_get_current_branch(rfs, git_dir)
    let head_parent = @bitlib.resolve_head_commit(rfs, git_dir)
    let is_root = head_parent is None && !amend
    let branch_display = match branch_name {
      Some(name) => if is_root { name + " (root-commit)" } else { name }
      None => if is_root { "(root-commit)" } else { "HEAD" }
    }
    match get_subdir_info(fs, git_dir) {
      Some((_, path, _)) =>
        print_line(
          "[\{branch_display} (subdir: \{path}) \{short_id}] \{first_line}",
        )
      None => print_line("[\{branch_display} \{short_id}] \{first_line}")
    }
    // Show diffstat summary
    commit_show_diffstat(fs, rfs, root, git_dir, commit_id)
  }
  // Restore index from backup if --only mode was used
  if pathspecs.length() > 0 && only_mode {
    commit_restore_index_backup(fs, git_dir)
  }
}

///|
fn resolve_no_edit_commit_message(
  fs : &@bitcore.RepoFileSystem,
  root : String,
  git_dir : String,
  amend : Bool,
) -> String? raise Error {
  let merge_head_path = git_dir + "/MERGE_HEAD"
  let squash_msg_path = git_dir + "/SQUASH_MSG"
  let merge_msg_path = git_dir + "/MERGE_MSG"
  if fs.is_file(merge_head_path) {
    if fs.is_file(merge_msg_path) {
      return Some(decode_bytes(fs.read_file(merge_msg_path)))
    }
    if amend {
      return get_head_commit_message(fs, root)
    }
    return None
  }
  if fs.is_file(squash_msg_path) {
    let squash_msg = decode_bytes(fs.read_file(squash_msg_path))
    if fs.is_file(merge_msg_path) {
      let merge_msg = decode_bytes(fs.read_file(merge_msg_path))
      return Some(join_commit_messages(squash_msg, merge_msg))
    }
    return Some(squash_msg)
  }
  if fs.is_file(merge_msg_path) {
    return Some(decode_bytes(fs.read_file(merge_msg_path)))
  }
  if amend {
    return get_head_commit_message(fs, root)
  }
  None
}

///|
fn join_commit_messages(primary : String, secondary : String) -> String {
  if primary.length() == 0 {
    return secondary
  }
  if secondary.length() == 0 {
    return primary
  }
  if primary.has_suffix("\n") || secondary.has_prefix("\n") {
    primary + secondary
  } else {
    primary + "\n" + secondary
  }
}

///|
fn read_merge_head_ids(
  fs : &@bitcore.RepoFileSystem,
  git_dir : String,
) -> Array[@bitcore.ObjectId] raise Error {
  let path = git_dir + "/MERGE_HEAD"
  if !fs.is_file(path) {
    return []
  }
  let ids : Array[@bitcore.ObjectId] = []
  let content = decode_bytes(fs.read_file(path))
  for line_view in content.split("\n") {
    let line = trim_string(line_view.to_owned())
    if line.length() == 0 {
      continue
    }
    let id = @bitcore.ObjectId::from_hex(line) catch {
      _ => raise @bitcore.GitError::InvalidObject("invalid MERGE_HEAD: \{line}")
    }
    ids.push(id)
  }
  ids
}

///|
fn commit_subject_line(message : String) -> String {
  match message.find("\n") {
    Some(idx) => string_slice_to(message, idx)
    None => message
  }
}

///|
fn commit_reflog_identity(identity : String) -> (String, String) {
  let trimmed = identity.trim().to_owned()
  match trimmed.find("<") {
    Some(start) =>
      match trimmed.find(">") {
        Some(end) if end > start => {
          let name = string_slice_to(trimmed, start).trim().to_owned()
          let email = String::unsafe_substring(trimmed, start=start + 1, end~)
          (if name.length() == 0 { "unknown" } else { name }, email)
        }
        _ => (trimmed, "unknown")
      }
    None => (trimmed, "unknown")
  }
}

///|
fn commit_append_update_reflogs(
  fs : &@bitcore.FileSystem,
  rfs : &@bitcore.RepoFileSystem,
  git_dir : String,
  old_id : @bitcore.ObjectId,
  new_id : @bitcore.ObjectId,
  message : String,
  committer : String,
  timestamp : Int64,
  timezone : String,
) -> Unit raise Error {
  let (name, email) = commit_reflog_identity(committer)
  let (should_log_head, _) = @bitlib.should_log_ref(rfs, git_dir, "HEAD", false)
  if should_log_head {
    @bitlib.append_reflog(
      fs, rfs, git_dir, "HEAD", old_id, new_id, name, email, timestamp, timezone,
      message,
    )
  }
  match @bitlib.read_head_ref(rfs, git_dir) {
    @bitlib.HeadRef::Branch(branch_name) => {
      let refname = "refs/heads/" + branch_name
      let (should_log_branch, _) = @bitlib.should_log_ref(
        rfs, git_dir, refname, false,
      )
      if should_log_branch {
        @bitlib.append_reflog(
          fs, rfs, git_dir, refname, old_id, new_id, name, email, timestamp, timezone,
          message,
        )
      }
    }
    _ => ()
  }
}

///|
async fn commit_write_object(
  fs : &@bitcore.FileSystem,
  rfs : &@bitcore.RepoFileSystem,
  root : String,
  git_dir : String,
  commit : @bitcore.Commit,
  entries : Array[@bitlib.IndexEntry],
  tree_id : @bitcore.ObjectId,
  old_id : @bitcore.ObjectId?,
  reflog_message : String,
  committer : String,
  committer_timestamp : Int64,
  committer_timezone : String,
  algo : @bitobject.HashAlgorithm,
  sign? : Bool = false,
  signing_fs? : OsFs? = None,
  signing_key_override? : String? = None,
) -> @bitcore.ObjectId raise Error {
  let payload = @bitobject.serialize_commit_content(commit)
  let final_payload = if sign {
    let signing_fs = match signing_fs {
      Some(real_fs) => real_fs
      None =>
        raise @bitcore.GitError::InvalidObject(
          "signing requires native filesystem access",
        )
    }
    let signature = signing_sign_payload(
      signing_fs, root, git_dir, payload, signing_key_override,
    )
    signing_inject_commit_signature(payload, signature)
  } else {
    payload
  }
  let (commit_id, compressed) = @bitobject.create_object_with_algo(
    algo,
    @bitcore.ObjectType::Commit,
    final_payload,
  )
  @bitlib.write_object_bytes(fs, git_dir, commit_id, compressed)
  @bitlib.update_head_ref(fs, rfs, git_dir, commit_id)
  commit_append_update_reflogs(
    fs,
    rfs,
    git_dir,
    old_id.unwrap_or(@bitcore.ObjectId::zero()),
    commit_id,
    reflog_message,
    committer,
    committer_timestamp,
    committer_timezone,
  )
  if entries.length() > 0 {
    @bitlib.write_index_entries_with_tree(fs, rfs, git_dir, entries, tree_id)
  }
  commit_id
}

///|
async fn commit_signed(
  fs : OsFs,
  rfs : &@bitcore.RepoFileSystem,
  root : String,
  message : String,
  author : String,
  author_timestamp : Int64,
  committer? : String = author,
  committer_timestamp? : Int64 = author_timestamp,
  allow_empty? : Bool = false,
  timezone? : String = "+0000",
  encoding? : String = "UTF-8",
  author_timezone? : String = "+0000",
  committer_timezone? : String = "+0000",
  algo? : @bitobject.HashAlgorithm = @bitobject.HashAlgorithm::Sha1,
  signing_key_override? : String? = None,
) -> @bitcore.ObjectId raise Error {
  ignore(timezone)
  let git_dir = resolve_git_dir(rfs, root)
  let parent = @bitlib.resolve_head_commit(rfs, git_dir)
  let entries = @bitlib.read_index_entries(rfs, git_dir)
  let tree_id = if entries.length() == 0 {
    if !allow_empty {
      raise @bitcore.GitError::InvalidObject("Empty index")
    }
    match parent {
      Some(parent_id) => {
        let db = @bitlib.ObjectDb::load_lazy(rfs, git_dir)
        let parent_tree = match db.get(rfs, parent_id) {
          Some(obj) if obj.obj_type == @bitcore.ObjectType::Commit =>
            (@bitcore.parse_commit(obj.data).tree |> Some) catch {
              _ => None
            }
          _ => None
        }
        match parent_tree {
          Some(tree) => tree
          None => {
            let (empty_tree_id, empty_tree_compressed) = @bitobject.create_tree_with_algo(
              algo,
              [],
            )
            @bitlib.write_object_bytes(
              fs, git_dir, empty_tree_id, empty_tree_compressed,
            )
            empty_tree_id
          }
        }
      }
      None => {
        let (empty_tree_id, empty_tree_compressed) = @bitobject.create_tree_with_algo(
          algo,
          [],
        )
        @bitlib.write_object_bytes(
          fs, git_dir, empty_tree_id, empty_tree_compressed,
        )
        empty_tree_id
      }
    }
  } else {
    @bitlib.write_tree_from_index(
      fs,
      rfs,
      git_dir,
      entries,
      missing_ok=true,
      algo~,
    )
  }
  let parents = match parent {
    Some(parent_id) => [parent_id]
    None => []
  }
  let commit = @bitcore.Commit::new(
    tree_id,
    parents,
    author,
    author_timestamp,
    author_timezone,
    committer,
    committer_timestamp,
    committer_timezone,
    message,
    encoding~,
  )
  commit_write_object(
    fs,
    rfs,
    root,
    git_dir,
    commit,
    entries,
    tree_id,
    parent,
    if parent is None {
      "commit (initial): " + commit_subject_line(message)
    } else {
      "commit: " + commit_subject_line(message)
    },
    committer,
    committer_timestamp,
    committer_timezone,
    algo,
    sign=true,
    signing_fs=Some(fs),
    signing_key_override~,
  )
}

///|
async fn commit_signed_amend(
  fs : OsFs,
  rfs : &@bitcore.RepoFileSystem,
  root : String,
  message : String,
  author : String,
  author_timestamp : Int64,
  committer? : String = author,
  committer_timestamp? : Int64 = author_timestamp,
  timezone? : String = "+0000",
  encoding? : String = "UTF-8",
  author_timezone? : String = "+0000",
  committer_timezone? : String = "+0000",
  algo? : @bitobject.HashAlgorithm = @bitobject.HashAlgorithm::Sha1,
  signing_key_override? : String? = None,
) -> @bitcore.ObjectId raise Error {
  ignore(timezone)
  let git_dir = resolve_git_dir(rfs, root)
  let entries = @bitlib.read_index_entries(rfs, git_dir)
  if entries.length() == 0 {
    raise @bitcore.GitError::InvalidObject("Empty index")
  }
  let tree_id = @bitlib.write_tree_from_index(fs, rfs, git_dir, entries, algo~)
  let current_head = @bitlib.resolve_head_commit(rfs, git_dir)
  let parents = match current_head {
    Some(head_id) => {
      let db = @bitlib.ObjectDb::load_lazy(rfs, git_dir)
      match db.get(rfs, head_id) {
        Some(obj) => @bitcore.parse_commit(obj.data).parents catch { _ => [] }
        None => []
      }
    }
    None => []
  }
  let commit = @bitcore.Commit::new(
    tree_id,
    parents,
    author,
    author_timestamp,
    author_timezone,
    committer,
    committer_timestamp,
    committer_timezone,
    message,
    encoding~,
  )
  commit_write_object(
    fs,
    rfs,
    root,
    git_dir,
    commit,
    entries,
    tree_id,
    current_head,
    "commit (amend): " + commit_subject_line(message),
    committer,
    committer_timestamp,
    committer_timezone,
    algo,
    sign=true,
    signing_fs=Some(fs),
    signing_key_override~,
  )
}

///|
async fn commit_with_merge_heads(
  fs : &@bitcore.FileSystem,
  rfs : &@bitcore.RepoFileSystem,
  root : String,
  message : String,
  author : String,
  author_timestamp : Int64,
  committer : String,
  committer_timestamp : Int64,
  merge_heads : Array[@bitcore.ObjectId],
  allow_empty : Bool,
  encoding? : String = "UTF-8",
  author_timezone? : String = "+0000",
  committer_timezone? : String = "+0000",
  algo? : @bitobject.HashAlgorithm = @bitobject.HashAlgorithm::Sha1,
  sign? : Bool = false,
  signing_fs? : OsFs? = None,
  signing_key_override? : String? = None,
) -> @bitcore.ObjectId raise Error {
  let git_dir = resolve_git_dir(rfs, root)
  let head_parent = @bitlib.resolve_head_commit(rfs, git_dir)
  let entries = @bitlib.read_index_entries(rfs, git_dir)
  let tree_id = if entries.length() == 0 {
    if !allow_empty {
      raise @bitcore.GitError::InvalidObject("Empty index")
    }
    match head_parent {
      Some(parent_id) => {
        let db = @bitlib.ObjectDb::load_lazy(rfs, git_dir)
        let parent_tree = match db.get(rfs, parent_id) {
          Some(obj) if obj.obj_type == @bitcore.ObjectType::Commit =>
            (@bitcore.parse_commit(obj.data).tree |> Some) catch {
              _ => None
            }
          _ => None
        }
        match parent_tree {
          Some(tree) => tree
          None => {
            let (empty_tree_id, empty_tree_compressed) = @bitobject.create_tree_with_algo(
              algo,
              [],
            )
            @bitlib.write_object_bytes(
              fs, git_dir, empty_tree_id, empty_tree_compressed,
            )
            empty_tree_id
          }
        }
      }
      None => {
        let (empty_tree_id, empty_tree_compressed) = @bitobject.create_tree_with_algo(
          algo,
          [],
        )
        @bitlib.write_object_bytes(
          fs, git_dir, empty_tree_id, empty_tree_compressed,
        )
        empty_tree_id
      }
    }
  } else {
    @bitlib.write_tree_from_index(
      fs,
      rfs,
      git_dir,
      entries,
      missing_ok=true,
      algo~,
    )
  }
  let parents : Array[@bitcore.ObjectId] = []
  let seen : Map[String, Bool] = Map([])
  match head_parent {
    Some(parent_id) => {
      parents.push(parent_id)
      seen[parent_id.to_hex()] = true
    }
    None => ()
  }
  for merge_head in merge_heads {
    let hex = merge_head.to_hex()
    if seen.contains(hex) {
      continue
    }
    seen[hex] = true
    parents.push(merge_head)
  }
  let commit = @bitcore.Commit::new(
    tree_id,
    parents,
    author,
    author_timestamp,
    author_timezone,
    committer,
    committer_timestamp,
    committer_timezone,
    message,
    encoding~,
  )
  commit_write_object(
    fs,
    rfs,
    root,
    git_dir,
    commit,
    entries,
    tree_id,
    head_parent,
    if head_parent is None {
      "commit (initial): " + commit_subject_line(message)
    } else if merge_heads.length() > 0 {
      // A commit recording MERGE_HEAD parents is a merge; git tags its reflog
      // entry with the "(merge)" qualifier.
      "commit (merge): " + commit_subject_line(message)
    } else {
      "commit: " + commit_subject_line(message)
    },
    committer,
    committer_timestamp,
    committer_timezone,
    algo,
    sign~,
    signing_fs~,
    signing_key_override~,
  )
}

///|
fn cleanup_merge_state_files(
  fs : &@bitcore.FileSystem,
  git_dir : String,
) -> Unit raise Error {
  let files = ["MERGE_HEAD", "MERGE_MSG", "MERGE_MODE", "SQUASH_MSG"]
  for file in files {
    fs.remove_file(git_dir + "/" + file) catch {
      err if @async.is_cancellation_error(err) => raise err
      _ => ()
    }
  }
}

///|
fn commit_args_require_standalone_error(_args : Array[String]) -> Bool {
  false
}

///|
fn commit_signing_requested(git_dir : String, args : Array[String]) -> Bool {
  match commit_signing_override(args) {
    Some(flag) => flag
    None => {
      let fs = OsFs::new()
      signing_commit_config_enabled(resolve_common_git_dir(fs, git_dir))
    }
  }
}

///|
fn commit_signing_override(args : Array[String]) -> Bool? {
  for arg in args {
    if arg == "--no-gpg-sign" {
      return Some(false)
    }
    if arg == "-S" ||
      arg == "--gpg-sign" ||
      arg.has_prefix("-S") ||
      arg.has_prefix("--gpg-sign=") {
      return Some(true)
    }
  }
  None
}

///|
async fn commit_check_message_source_conflict(
  current_source : String,
  new_source : String,
) -> Unit raise Error {
  if current_source.length() == 0 {
    return
  }
  // -m can be used multiple times
  if current_source == "m" && new_source == "m" {
    return
  }
  let source_name = fn(s : String) -> String {
    match s {
      "m" => "-m"
      "F" => "-F"
      "C" => "-C"
      "c" => "-c"
      _ => s
    }
  }
  eprint_line(
    "fatal: options '\{source_name(current_source)}' and '\{source_name(new_source)}' cannot be used together",
  )
  @sys.exit(128)
}

///|
fn commit_strip_message(msg : String) -> String {
  @bitlib.commit_strip_message(msg)
}

///|
fn commit_normalize_cleanup_mode(value : String) -> String? {
  match value {
    "strip" | "whitespace" | "verbatim" | "scissors" | "default" => Some(value)
    _ => None
  }
}

///|
fn commit_prepare_message_for_validation(
  msg : String,
  cleanup_mode : String,
) -> String {
  if cleanup_mode == "verbatim" {
    msg
  } else {
    commit_strip_message(msg)
  }
}

///|
fn commit_apply_signoff(msg : String) -> String {
  let committer = get_committer_string()
  @bitlib.commit_apply_signoff(msg, committer~)
}

///|
fn commit_is_trailer_line(line : String) -> Bool {
  @bitlib.commit_is_trailer_line(line)
}

///|
fn commit_get_current_branch(
  rfs : &@bitcore.RepoFileSystem,
  git_dir : String,
) -> String? {
  let head_path = git_dir + "/HEAD"
  let content = decode_bytes(rfs.read_file(head_path)) catch {
    _ => return None
  }
  let trimmed = trim_string(content)
  if trimmed.has_prefix("ref: refs/heads/") {
    Some(string_slice_from(trimmed, 16))
  } else {
    None
  }
}

///|
async fn commit_show_diffstat(
  _fs : OsFs,
  rfs : &@bitcore.RepoFileSystem,
  _root : String,
  git_dir : String,
  commit_id : @bitcore.ObjectId,
) -> Unit raise Error {
  // Show summary of files changed
  let db = @bitlib.ObjectDb::load_lazy(rfs, git_dir)
  let commit_obj = match db.get(rfs, commit_id) {
    Some(obj) => obj
    None => return
  }
  let commit = @bitcore.parse_commit(commit_obj.data) catch { _ => return }
  let tree_id = commit.tree
  let parent_tree_id : @bitcore.ObjectId? = if commit.parents.length() > 0 {
    match db.get(rfs, commit.parents[0]) {
      Some(parent_obj) =>
        Some(@bitcore.parse_commit(parent_obj.data).tree) catch {
          _ => None
        }
      None => None
    }
  } else {
    None
  }
  // Count files by comparing tree entries
  let new_entries = commit_collect_tree_entries(rfs, db, tree_id)
  let old_entries = match parent_tree_id {
    Some(pid) => commit_collect_tree_entries(rfs, db, pid)
    None => Map([])
  }
  let mut files_changed = 0
  let mut insertions = 0
  let mut deletions = 0
  let creates : Array[String] = []
  // Check new/modified files
  for path, new_id in new_entries {
    match old_entries.get(path) {
      Some(old_id) =>
        if old_id.to_hex() != new_id.to_hex() {
          files_changed += 1
        }
      None => {
        files_changed += 1
        creates.push(path)
      }
    }
  }
  // Check deleted files
  for path, _ in old_entries {
    if !new_entries.contains(path) {
      files_changed += 1
    }
  }
  // For a simple diffstat, count blob size differences
  for path, new_id in new_entries {
    match old_entries.get(path) {
      Some(old_id) =>
        if old_id.to_hex() != new_id.to_hex() {
          let new_size = commit_blob_line_count(rfs, db, new_id)
          let old_size = commit_blob_line_count(rfs, db, old_id)
          if new_size > old_size {
            insertions += new_size - old_size
          } else {
            deletions += old_size - new_size
          }
        }
      None => insertions += commit_blob_line_count(rfs, db, new_id)
    }
  }
  for path, old_id in old_entries {
    if !new_entries.contains(path) {
      deletions += commit_blob_line_count(rfs, db, old_id)
    }
  }
  if files_changed > 0 {
    let parts : Array[String] = []
    let files_s = if files_changed > 1 { "s" } else { "" }
    parts.push(" \{files_changed} file\{files_s} changed")
    if insertions > 0 {
      let ins_s = if insertions > 1 { "s" } else { "" }
      parts.push(" \{insertions} insertion\{ins_s}(+)")
    }
    if deletions > 0 {
      let del_s = if deletions > 1 { "s" } else { "" }
      parts.push(" \{deletions} deletion\{del_s}(-)")
    }
    print_line(parts.join(","))
  }
  for path in creates {
    print_line(" create mode 100644 \{path}")
  }
}

///|
fn commit_collect_tree_entries(
  rfs : &@bitcore.RepoFileSystem,
  db : @bitlib.ObjectDb,
  tree_id : @bitcore.ObjectId,
) -> Map[String, @bitcore.ObjectId] raise Error {
  let result : Map[String, @bitcore.ObjectId] = Map([])
  commit_collect_tree_entries_recursive(rfs, db, tree_id, "", result)
  result
}

///|
fn commit_collect_tree_entries_recursive(
  rfs : &@bitcore.RepoFileSystem,
  db : @bitlib.ObjectDb,
  tree_id : @bitcore.ObjectId,
  prefix : String,
  result : Map[String, @bitcore.ObjectId],
) -> Unit raise Error {
  let tree_obj = match db.get(rfs, tree_id) {
    Some(obj) => obj
    None => return
  }
  let entries = @bitcore.parse_tree(tree_obj.data) catch { _ => return }
  for entry in entries {
    let path = if prefix.length() > 0 {
      prefix + "/" + entry.name
    } else {
      entry.name
    }
    if entry.mode == "40000" || entry.mode == "040000" {
      commit_collect_tree_entries_recursive(rfs, db, entry.id, path, result)
    } else {
      result[path] = entry.id
    }
  }
}

///|
fn commit_blob_line_count(
  rfs : &@bitcore.RepoFileSystem,
  db : @bitlib.ObjectDb,
  blob_id : @bitcore.ObjectId,
) -> Int raise Error {
  match db.get(rfs, blob_id) {
    Some(obj) => {
      let mut count = 0
      for b in obj.data {
        if b == b'\n' {
          count += 1
        }
      }
      // Count final line without newline
      if obj.data.length() > 0 && obj.data[obj.data.length() - 1] != b'\n' {
        count += 1
      }
      count
    }
    None => 0
  }
}

///|
async fn commit_handle_pathspec_staging(
  fs : OsFs,
  _rfs : &@bitcore.RepoFileSystem,
  root : String,
  git_dir : String,
  pathspecs : Array[String],
  _include_mode : Bool,
  only_mode : Bool,
) -> Unit raise Error {
  // For --only mode, save the current index and create a temporary one
  // with only the specified paths
  if only_mode {
    commit_save_index_backup(fs, git_dir)
  }
  // Validate pathspecs exist in index or working tree
  let entries = @bitlib.read_index_entries(fs, git_dir)
  let index_paths : Map[String, Bool] = Map([])
  for e in entries {
    index_paths[e.path] = true
  }
  for pathspec in pathspecs {
    let rel_path = commit_resolve_pathspec(root, pathspec)
    // Check if path exists in index or as a file
    if !index_paths.contains(rel_path) && !fs.is_file(root + "/" + rel_path) {
      eprint_line(
        "error: pathspec '\{pathspec}' did not match any file(s) known to git",
      )
      @sys.exit(1)
    }
  }
  // Stage the specified paths
  let paths_to_add : Array[String] = []
  for pathspec in pathspecs {
    let rel_path = commit_resolve_pathspec(root, pathspec)
    paths_to_add.push(rel_path)
  }
  if paths_to_add.length() > 0 {
    @bitlib.add_paths_async(fs, fs, root, paths_to_add)
    stage_submodule_gitlinks(fs, root, paths_to_add)
  }
}

///|
fn commit_resolve_pathspec(root : String, pathspec : String) -> String {
  // Resolve pathspec relative to root
  if pathspec.has_prefix("/") {
    return pathspec
  }
  // Get relative path from current directory
  let cwd = match @env.current_dir() {
    Some(dir) => dir
    None => root
  }
  let abs = normalize_path(cwd + "/" + pathspec)
  if abs.has_prefix(root + "/") {
    string_slice_from(abs, root.length() + 1)
  } else {
    pathspec
  }
}

///|
fn commit_save_index_backup(fs : OsFs, git_dir : String) -> Unit raise Error {
  let index_path = git_dir + "/index"
  let backup_path = git_dir + "/index.commit-backup"
  if fs.is_file(index_path) {
    let data = (fs : &@bitcore.RepoFileSystem).read_file(index_path)
    (fs : &@bitcore.FileSystem).write_file(backup_path, data)
  }
}

///|
fn commit_restore_index_backup(fs : OsFs, git_dir : String) -> Unit raise Error {
  let backup_path = git_dir + "/index.commit-backup"
  let index_path = git_dir + "/index"
  if fs.is_file(backup_path) {
    let data = (fs : &@bitcore.RepoFileSystem).read_file(backup_path)
    (fs : &@bitcore.FileSystem).write_file(index_path, data)
    (fs : &@bitcore.FileSystem).remove_file(backup_path) catch {
      err if @async.is_cancellation_error(err) => raise err
      _ => ()
    }
  }
}

///|
async fn read_commit_message_from_file(
  fs : &@bitcore.RepoFileSystem,
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
  fs : &@bitcore.RepoFileSystem,
  root : String,
  spec : String,
) -> String? raise Error {
  let git_dir = resolve_git_dir(fs, root)
  let commit_id = @bitrepo.rev_parse(fs, git_dir, spec)
  match commit_id {
    Some(id) => {
      let db = @bitlib.ObjectDb::load_lazy(fs, git_dir)
      match db.get(fs, id) {
        Some(obj) => Some(extract_commit_message(obj.data))
        None => None
      }
    }
    None => None
  }
}

///|
fn resolve_commit_message_encoding(git_dir : String) -> String {
  let overrides = @bitlib.parse_config_overrides()
  match overrides.get("i18n.commitencoding") {
    Some(value) => {
      let trimmed = trim_string(value)
      if trimmed.length() > 0 {
        trimmed
      } else {
        "UTF-8"
      }
    }
    None => {
      let fs = OsFs::new()
      let common_git_dir = resolve_common_git_dir(fs, git_dir)
      match bit_config_get(common_git_dir, "i18n", "commitEncoding") {
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
  }
}

///|
fn decode_commit_message_bytes(data : Bytes, encoding : String) -> String {
  @bitlib.decode_commit_message_bytes(data, encoding)
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
  let work_root = abs_path(root)
  run_hook(fs, work_root, hook_git_dir, "pre-commit", work_root)
}

///|
fn parse_commit_date(date_str : String) -> Int64 {
  // Support common formats:
  // - Unix timestamp: "1234567890"
  // - @timestamp: "@1234567890"
  // - ISO 8601: "2024-01-01T12:00:00"
  if date_str.has_prefix("@") {
    let ts_str = string_slice_from(date_str, 1)
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
    } else {
      break
    }
  }
  result
}

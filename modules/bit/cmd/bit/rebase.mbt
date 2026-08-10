///|
async fn delegate_rebase_to_real_git(
  args : Array[String],
  cwd : String,
) -> Unit {
  if git_fallback_disabled() {
    exit_no_git_fallback("git rebase")
  }
  let argv : Array[String] = ["rebase"]
  for arg in args {
    argv.push(arg)
  }
  let code = @process.run(
    resolve_real_git_for_dispatch(),
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
fn rebase_short_option_cluster_contains(arg : String, flag : UInt16) -> Bool {
  if arg.length() < 2 || arg.unsafe_get(0) != ('-' : UInt16) {
    return false
  }
  if arg.length() >= 2 && arg.unsafe_get(1) == ('-' : UInt16) {
    return false
  }
  let mut i = 1
  while i < arg.length() {
    if arg.unsafe_get(i) == flag {
      return true
    }
    i += 1
  }
  false
}

///|
fn rebase_is_inline_signing_arg(arg : String) -> Bool {
  arg.has_prefix("-S") && !arg.has_prefix("--")
}

///|
fn rebase_signing_override(args : Array[String]) -> Bool? {
  let mut result : Bool? = None
  for arg in args {
    if arg == "--no-gpg-sign" {
      result = Some(false)
      continue
    }
    if rebase_is_inline_signing_arg(arg) ||
      rebase_short_option_cluster_contains(arg, ('S' : UInt16)) ||
      arg == "--gpg-sign" ||
      arg.has_prefix("--gpg-sign=") {
      result = Some(true)
    }
  }
  result
}

///|
fn rebase_uses_rebase_merges_mode(args : Array[String]) -> Bool {
  for arg in args {
    if arg == "--rebase-merges" ||
      arg == "--preserve-merges" ||
      arg.has_prefix("--rebase-merges=") {
      return true
    }
  }
  false
}

///|
fn rebase_has_complex_mode_args(args : Array[String]) -> Bool {
  for arg in args {
    // --rebase-merges is now natively supported, so not listed here
    if arg == "--update-refs" ||
      arg == "--no-update-refs" ||
      (
        rebase_short_option_cluster_contains(arg, ('x' : UInt16)) &&
        arg != "-x" &&
        !rebase_is_inline_signing_arg(arg)
      ) ||
      arg == "--strategy" ||
      arg.has_prefix("--strategy=") ||
      arg == "-X" ||
      arg.has_prefix("-X") ||
      arg == "--root" {
      return true
    }
  }
  false
}

///|
fn rebase_has_state_action_args(args : Array[String]) -> Bool {
  for arg in args {
    if arg == "--continue" || arg == "--abort" || arg == "--skip" {
      return true
    }
  }
  false
}

///|
fn rebase_merge_dir_uses_real_git_interactive_state(
  rfs : &@bitcore.RepoFileSystem,
  rebase_merge_dir : String,
) -> Bool {
  rfs.is_file(rebase_merge_dir + "/interactive") ||
  rfs.is_file(rebase_merge_dir + "/git-rebase-todo.backup") ||
  rfs.is_file(rebase_merge_dir + "/msgnum") ||
  rfs.is_file(rebase_merge_dir + "/end")
}

///|
fn rebase_requires_real_git(
  args : Array[String],
  git_dir? : String = "",
) -> Bool {
  if rebase_has_complex_mode_args(args) {
    return true
  }
  let signing_requested = match rebase_signing_override(args) {
    Some(flag) => flag
    None => git_dir.length() > 0 && signing_commit_config_enabled(git_dir)
  }
  if signing_requested && rebase_uses_rebase_merges_mode(args) {
    return true
  }
  if git_dir.length() > 0 && rebase_has_state_action_args(args) {
    let fs = OsFs::new()
    let rfs : &@bitcore.RepoFileSystem = fs
    let rebase_merge_dir = git_dir + "/rebase-merge"
    if rfs.is_dir(rebase_merge_dir) &&
      rebase_merge_dir_uses_real_git_interactive_state(rfs, rebase_merge_dir) {
      return true
    }
  }
  false
}

///|
fn rebase_signing_state_path(git_dir : String) -> String {
  git_dir + "/rebase-merge/bit-gpg-sign"
}

///|
fn rebase_read_signing_state(
  rfs : &@bitcore.RepoFileSystem,
  git_dir : String,
) -> (Bool, String?) {
  let path = rebase_signing_state_path(git_dir)
  if !rfs.is_file(path) {
    return (false, None)
  }
  let value = trim_string(
    decode_bytes(rfs.read_file(path) catch { _ => Default::default() }),
  )
  (true, if value.length() > 0 { Some(value) } else { None })
}

///|
fn rebase_write_signing_state(
  fs : &@bitcore.FileSystem,
  git_dir : String,
  signing_key : String?,
) -> Unit {
  fs.mkdir_p(git_dir + "/rebase-merge") catch {
    _ => ()
  }
  let value = match signing_key {
    Some(key) => key
    None => ""
  }
  fs.write_string(rebase_signing_state_path(git_dir), value + "\n") catch {
    _ => ()
  }
}

///|
fn rebase_clear_signing_state(
  fs : &@bitcore.FileSystem,
  git_dir : String,
) -> Unit {
  fs.remove_file(rebase_signing_state_path(git_dir)) catch {
    _ => ()
  }
}

///|
fn rebase_commit_header_value(data : Bytes, prefix : String) -> String? {
  let text = decode_bytes(data)
  for line_view in text.split("\n") {
    let line = line_view.to_owned()
    if line.length() == 0 {
      break
    }
    if line.has_prefix(prefix) {
      return Some(
        String::unsafe_substring(line, start=prefix.length(), end=line.length()),
      )
    }
  }
  None
}

///|
fn rebase_commit_identity(
  data : Bytes,
  prefix : String,
) -> (String, Int64, String) raise Error {
  let raw = match rebase_commit_header_value(data, prefix) {
    Some(value) => value
    None =>
      raise @bitcore.GitError::InvalidObject(
        "Missing \{prefix.trim().to_owned()} header",
      )
  }
  let (name, email, timestamp, timezone) = parse_ident_parts(raw)
  let identity = if email.length() > 0 {
    name + " <" + email + ">"
  } else {
    name
  }
  (identity, timestamp, timezone)
}

///|
async fn rebase_write_signed_commit_object(
  fs : OsFs,
  root : String,
  git_dir : String,
  commit : @bitcore.Commit,
  algo : @bitobject.HashAlgorithm,
  signing_key_override : String?,
) -> @bitcore.ObjectId raise Error {
  let payload = @bitobject.serialize_commit_content(commit)
  let signature = signing_sign_payload(
    fs, root, git_dir, payload, signing_key_override,
  )
  let signed_payload = signing_inject_commit_signature(payload, signature)
  let (commit_id, compressed) = @bitobject.create_object_with_algo(
    algo,
    @bitcore.ObjectType::Commit,
    signed_payload,
  )
  @bitlib.write_object_bytes(fs, git_dir, commit_id, compressed)
  commit_id
}

///|
async fn rebase_sign_rewritten_commits(
  fs : OsFs,
  rfs : &@bitcore.RepoFileSystem,
  root : String,
  git_dir : String,
  base_id : @bitcore.ObjectId,
  final_id : @bitcore.ObjectId,
  signing_key_override : String?,
  algo : @bitobject.HashAlgorithm,
) -> @bitcore.ObjectId raise Error {
  let db = @bitlib.ObjectDb::load(rfs, git_dir)
  let chain = collect_rebase_commits(db, rfs, final_id, base_id)
  if chain.length() == 0 {
    return final_id
  }
  let mut parent = base_id
  let mut signed_id = final_id
  for commit_id in chain {
    let obj = db.get(rfs, commit_id)
    guard obj is Some(o) else {
      raise @bitcore.GitError::InvalidObject(
        "Cannot read rebased commit: \{commit_id.to_hex()}",
      )
    }
    let info = @bitcore.parse_commit(o.data)
    let (author, author_time, author_tz) = rebase_commit_identity(
      o.data,
      "author ",
    )
    let (committer, commit_time, committer_tz) = rebase_commit_identity(
      o.data,
      "committer ",
    )
    let parents = if info.parents.length() == 0 {
      []
    } else {
      let ps : Array[@bitcore.ObjectId] = [parent]
      for i in 1..<info.parents.length() {
        ps.push(info.parents[i])
      }
      ps
    }
    let encoding = rebase_commit_header_value(o.data, "encoding ").unwrap_or(
      "UTF-8",
    )
    let commit = @bitcore.Commit::new(
      info.tree,
      parents,
      author,
      author_time,
      author_tz,
      committer,
      commit_time,
      committer_tz,
      extract_commit_message(o.data),
      encoding~,
    )
    signed_id = rebase_write_signed_commit_object(
      fs, root, git_dir, commit, algo, signing_key_override,
    )
    parent = signed_id
  }
  signed_id
}

///|
async fn rebase_sign_complete_result(
  fs : OsFs,
  rfs : &@bitcore.RepoFileSystem,
  root : String,
  git_dir : String,
  base_id : @bitcore.ObjectId,
  result : @bitlib.RebaseResult,
  signing_key_override : String?,
  algo : @bitobject.HashAlgorithm,
) -> @bitcore.ObjectId? raise Error {
  match result.status {
    @bitlib.RebaseStatus::Complete =>
      match result.commit_id {
        Some(final_id) => {
          let signed_id = rebase_sign_rewritten_commits(
            fs, rfs, root, git_dir, base_id, final_id, signing_key_override, algo,
          )
          if signed_id != final_id {
            let wfs : &@bitcore.FileSystem = fs
            @bitlib.update_head_ref(wfs, rfs, git_dir, signed_id)
          }
          Some(signed_id)
        }
        None => None
      }
    _ => None
  }
}

///|
async fn rebase_sign_complete_interactive_result(
  fs : OsFs,
  rfs : &@bitcore.RepoFileSystem,
  root : String,
  git_dir : String,
  base_id : @bitcore.ObjectId,
  result : @bitlib.InteractiveRebaseResult,
  signing_key_override : String?,
  algo : @bitobject.HashAlgorithm,
) -> @bitcore.ObjectId? raise Error {
  match result.status {
    @bitlib.IRBComplete =>
      match result.commit_id {
        Some(final_id) => {
          let signed_id = rebase_sign_rewritten_commits(
            fs, rfs, root, git_dir, base_id, final_id, signing_key_override, algo,
          )
          if signed_id != final_id {
            let wfs : &@bitcore.FileSystem = fs
            @bitlib.update_head_ref(wfs, rfs, git_dir, signed_id)
          }
          Some(signed_id)
        }
        None => None
      }
    _ => None
  }
}

///|
fn rebase_update_signing_state_for_result(
  fs : &@bitcore.FileSystem,
  git_dir : String,
  should_sign : Bool,
  signing_key : String?,
  result : @bitlib.RebaseResult,
) -> Unit {
  match result.status {
    @bitlib.RebaseStatus::Conflict =>
      if should_sign {
        rebase_write_signing_state(fs, git_dir, signing_key)
      } else {
        rebase_clear_signing_state(fs, git_dir)
      }
    _ => rebase_clear_signing_state(fs, git_dir)
  }
}

///|
fn rebase_update_signing_state_for_interactive_result(
  fs : &@bitcore.FileSystem,
  git_dir : String,
  should_sign : Bool,
  signing_key : String?,
  result : @bitlib.InteractiveRebaseResult,
) -> Unit {
  match result.status {
    @bitlib.IRBConflict =>
      if should_sign {
        rebase_write_signing_state(fs, git_dir, signing_key)
      } else {
        rebase_clear_signing_state(fs, git_dir)
      }
    @bitlib.IRBStopped =>
      if should_sign {
        rebase_write_signing_state(fs, git_dir, signing_key)
      } else {
        rebase_clear_signing_state(fs, git_dir)
      }
    _ => rebase_clear_signing_state(fs, git_dir)
  }
}

///|
async fn handle_rebase(args : Array[String]) -> Unit raise Error {
  let root = get_work_root()
  let fs = OsFs::new()
  let git_dir = resolve_git_dir(fs, root)
  if rebase_args_require_standalone_error(args) {
    eprint_line(
      "fatal: interactive/step rebase mode is not supported in standalone mode",
    )
    @sys.exit(1)
  }
  if rebase_requires_real_git(args, git_dir~) {
    delegate_rebase_to_real_git(args, root)
    return
  }
  check_and_exit_unsupported_attrs(root)
  let wfs : &@bitcore.FileSystem = fs
  let rfs : &@bitcore.RepoFileSystem = fs
  let filter_cmd = @bitlib.FilterCmd::{ run: @bitlibnative.run_filter_command }
  // Parse arguments
  let mut do_continue = false
  let mut do_abort = false
  let mut do_skip = false
  let mut do_quit = false
  let mut interactive = false
  let mut use_apply_backend = false
  let mut force_rebase = false
  let mut autosquash = false
  let mut no_autosquash = false
  let mut autostash = false
  let mut quiet = false
  let mut update_refs : Bool? = None
  let exec_cmds : Array[String] = []
  let mut root_mode = false
  let mut rebase_merges = false
  let mut strategy : String? = None
  let strategy_options : Array[String] = []
  let mut onto : String? = None
  let mut upstream : String? = None
  // git rebase [<upstream>] [<branch>]: a second positional arg means
  // "switch to <branch> first, then rebase it onto <upstream>".
  let mut switch_to_branch : String? = None
  let mut gpg_sign : Bool? = None
  let mut signing_key : String? = None
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    match arg {
      "--continue" => {
        do_continue = true
        i += 1
      }
      "--abort" => {
        do_abort = true
        i += 1
      }
      "--skip" => {
        do_skip = true
        i += 1
      }
      "--quit" => {
        do_quit = true
        i += 1
      }
      "-i" | "--interactive" => {
        interactive = true
        i += 1
      }
      "--autosquash" => {
        autosquash = true
        no_autosquash = false
        i += 1
      }
      "--no-autosquash" => {
        no_autosquash = true
        autosquash = false
        i += 1
      }
      "--autostash" => {
        autostash = true
        i += 1
      }
      "--no-autostash" => {
        autostash = false
        i += 1
      }
      "-q" | "--quiet" => {
        quiet = true
        i += 1
      }
      "--no-quiet" => {
        quiet = false
        i += 1
      }
      "--keep-empty" | "--no-keep-empty" =>
        // Accepted but not specially handled (bit keeps empty commits by default)
        i += 1
      "-S" | "--gpg-sign" => {
        gpg_sign = Some(true)
        i += 1
      }
      "--no-gpg-sign" => {
        gpg_sign = Some(false)
        signing_key = None
        i += 1
      }
      _ if arg.has_prefix("--gpg-sign=") => {
        gpg_sign = Some(true)
        let value = String::unsafe_substring(arg, start=11, end=arg.length())
        if value.length() > 0 {
          signing_key = Some(value)
        }
        i += 1
      }
      _ if arg.has_prefix("-S") && !arg.has_prefix("--") && arg.length() > 2 => {
        gpg_sign = Some(true)
        signing_key = Some(
          String::unsafe_substring(arg, start=2, end=arg.length()),
        )
        i += 1
      }
      "--show-current-patch" => {
        // Show the patch being applied during a stopped rebase
        let stopped_path = git_dir + "/rebase-merge/stopped-sha"
        if rfs.is_file(stopped_path) {
          let hex = trim_string(decode_bytes(rfs.read_file(stopped_path)))
          if @sys.get_env_var("GIT_TRACE") is Some(v) && v != "" && v != "0" {
            let backend_path = git_dir + "/rebase-merge/backend"
            let use_apply = rfs.is_file(backend_path) &&
              trim_string(decode_bytes(rfs.read_file(backend_path))) == "apply"
            let show_target = if use_apply { hex } else { "REBASE_HEAD" }
            eprint_line("trace: run_command: git show \{show_target} --")
          }
          handle_show([hex])
        } else {
          eprint_line("fatal: No rebase in progress?")
          @sys.exit(1)
        }
        return
      }
      "--edit-todo" => {
        // Edit the todo list of an in-progress interactive rebase
        let seq_editor = make_sequence_editor_callback(fs, git_dir)
        let todo_path = git_dir + "/rebase-merge/git-rebase-todo"
        if !(rfs as &@bitcore.RepoFileSystem).is_file(todo_path) {
          eprint_line("fatal: No rebase in progress?")
          @sys.exit(1)
        }
        let content = decode_bytes(
          (rfs as &@bitcore.RepoFileSystem).read_file(todo_path),
        )
        match seq_editor(content) {
          Some(edited) =>
            (fs as &@bitcore.FileSystem).write_string(todo_path, edited)
          None => ()
        }
        return
      }
      "--force-rebase" | "--no-ff" | "-f" => {
        force_rebase = true
        i += 1
      }
      "--no-force-rebase" | "--ff" => {
        force_rebase = false
        i += 1
      }
      // --stat/--no-stat/--diffstat/--no-diffstat: show diffstat after rebase
      // bit does not yet show diffstats, accept for compatibility
      "--stat" | "--diffstat" | "--no-stat" | "--no-diffstat" => i += 1
      // Backend selection flags: bit runs a single (merge-style) backend
      // internally; --apply/--merge only affect what --show-current-patch
      // reports (git show <hex> vs git show REBASE_HEAD) for compatibility.
      "--apply" => {
        use_apply_backend = true
        i += 1
      }
      "--merge" => {
        use_apply_backend = false
        i += 1
      }
      _ if arg.has_prefix("--backend=") => i += 1
      "--exec" | "-x" if i + 1 < args.length() => {
        exec_cmds.push(args[i + 1])
        interactive = true // --exec implies -i
        i += 2
      }
      _ if arg.has_prefix("--exec=") => {
        let cmd = String::unsafe_substring(arg, start=7, end=arg.length())
        if cmd.length() > 0 {
          exec_cmds.push(cmd)
          interactive = true
        }
        i += 1
      }
      "--update-refs" => {
        update_refs = Some(true)
        i += 1
      }
      "--no-update-refs" => {
        update_refs = Some(false)
        i += 1
      }
      "--root" => {
        root_mode = true
        i += 1
      }
      "--rebase-merges" | "--preserve-merges" => {
        rebase_merges = true
        interactive = true // --rebase-merges implies -i
        i += 1
      }
      _ if arg.has_prefix("--rebase-merges=") => {
        // --rebase-merges=rebase-cousins or --rebase-merges=no-rebase-cousins
        rebase_merges = true
        interactive = true
        i += 1
      }
      "--no-rebase-merges" => {
        rebase_merges = false
        i += 1
      }
      "--strategy" if i + 1 < args.length() => {
        strategy = Some(args[i + 1])
        i += 2
      }
      _ if arg.has_prefix("--strategy=") => {
        let val = String::unsafe_substring(arg, start=11, end=arg.length())
        strategy = Some(val)
        i += 1
      }
      "-X" if i + 1 < args.length() => {
        strategy_options.push(args[i + 1])
        i += 2
      }
      _ if arg.has_prefix("-X") && arg.length() > 2 => {
        let val = String::unsafe_substring(arg, start=2, end=arg.length())
        strategy_options.push(val)
        i += 1
      }
      "--onto" if i + 1 < args.length() => {
        onto = Some(args[i + 1])
        i += 2
      }
      // Silently accepted compat flags
      "--reschedule-failed-exec" | "--no-reschedule-failed-exec" => i += 1
      "--reset-author-date"
      | "--ignore-date"
      | "--committer-date-is-author-date" => i += 1
      "--signoff" | "--no-signoff" => i += 1
      "--ignore-whitespace" => i += 1
      _ if arg.has_prefix("--whitespace=") => i += 1
      _ if arg.has_prefix("--empty=") => i += 1
      // Bare "-" is the "previous branch" revision shorthand, not an option.
      "-" => {
        if upstream is None {
          upstream = Some(arg)
        } else if switch_to_branch is None {
          switch_to_branch = Some(arg)
        }
        i += 1
      }
      _ if !arg.has_prefix("-") => {
        if upstream is None {
          upstream = Some(arg)
        } else if switch_to_branch is None {
          switch_to_branch = Some(arg)
        }
        i += 1
      }
      _ if arg.has_prefix("-") => {
        warn_unimplemented_arg("rebase", arg)
        i += 1
      }
      _ => i += 1
    }
  }
  // "-" / "@{-1}" mean "the branch checked out before the current one",
  // same as `git checkout -`.
  match upstream {
    Some(u) if u == "-" || u == "@{-1}" =>
      match load_previous_checkout_location(rfs, git_dir) {
        Some(prev) => upstream = Some(prev)
        None =>
          raise @bitcore.GitError::InvalidObject(
            "No previous branch to rebase onto",
          )
      }
    _ => ()
  }
  let (stored_signing, stored_signing_key) = rebase_read_signing_state(
    rfs, git_dir,
  )
  let should_sign = match gpg_sign {
    Some(flag) => flag
    None => stored_signing || signing_commit_config_enabled(git_dir)
  }
  let effective_signing_key = match signing_key {
    Some(key) => Some(key)
    None => if should_sign { stored_signing_key } else { None }
  }
  let commit_algo = signing_repo_hash_algorithm(fs, git_dir)
  // Validate exec commands
  for cmd in exec_cmds {
    if cmd.trim().to_owned().length() == 0 {
      eprint_line("error: empty exec command")
      @sys.exit(1)
    }
  }
  // Check if this is a subdir-clone and handle specially
  if is_subdir_clone(fs, git_dir) {
    handle_subdir_rebase(fs, root, git_dir, upstream) catch {
      e => raise e
    }
    return
  }
  // Handle --quit: drop rebase state without restoring the original branch
  // or working tree (unlike --abort).
  if do_quit {
    if @bitlib.is_interactive_rebase_in_progress(rfs, git_dir) ||
      @bitlib.is_rebase_in_progress(rfs, git_dir) {
      @bitlib.clear_rebase_state(wfs, rfs, git_dir)
      rebase_clear_signing_state(wfs, git_dir)
    } else {
      eprint_line("fatal: no rebase in progress")
      @sys.exit(1)
    }
    return ()
  }
  // Handle --continue (works for both regular and interactive)
  if do_continue {
    if @bitlib.is_interactive_rebase_in_progress(rfs, git_dir) {
      let state_before = @bitlib.load_interactive_rebase_state(rfs, git_dir)
      let msg_editor = make_message_editor_callback(fs, git_dir)
      let exec_runner = make_exec_runner_callback(root)
      let result = @bitlib.interactive_rebase_continue_impl(
        wfs,
        rfs,
        root,
        msg_editor,
        exec_runner=Some(exec_runner),
      )
      if should_sign {
        match state_before {
          Some(state) =>
            ignore(
              rebase_sign_complete_interactive_result(
                fs,
                rfs,
                root,
                git_dir,
                state.onto,
                result,
                effective_signing_key,
                commit_algo,
              ),
            )
          None => ()
        }
      }
      rebase_update_signing_state_for_interactive_result(
        wfs, git_dir, should_sign, effective_signing_key, result,
      )
      print_interactive_rebase_result(result, quiet~)
    } else {
      let state_before = @bitlib.load_rebase_state(rfs, git_dir)
      let result = @bitlib.rebase_continue(fs, fs, root, run_filter_cmd=filter_cmd)
      let signed_id = if should_sign {
        match state_before {
          Some(state) =>
            rebase_sign_complete_result(
              fs,
              rfs,
              root,
              git_dir,
              state.onto,
              result,
              effective_signing_key,
              commit_algo,
            )
          None => None
        }
      } else {
        None
      }
      rebase_update_signing_state_for_result(
        wfs, git_dir, should_sign, effective_signing_key, result,
      )
      print_rebase_result_with_commit(result, signed_id, quiet~)
    }
    return ()
  }
  // Handle --abort
  if do_abort {
    if @bitlib.is_interactive_rebase_in_progress(rfs, git_dir) {
      @bitlib.interactive_rebase_abort_impl(wfs, rfs, root)
      rebase_clear_signing_state(wfs, git_dir)
      print_line("Rebase aborted")
    } else {
      @bitlib.rebase_abort(fs, fs, root, run_filter_cmd=filter_cmd) catch {
        _ => @bitlib.clear_rebase_state(fs, fs, git_dir)
      }
      rebase_clear_signing_state(wfs, git_dir)
      print_line("Rebase aborted")
    }
    return ()
  }
  // Handle --skip
  if do_skip {
    if @bitlib.is_interactive_rebase_in_progress(rfs, git_dir) {
      let state_before = @bitlib.load_interactive_rebase_state(rfs, git_dir)
      let msg_editor = make_message_editor_callback(fs, git_dir)
      let exec_runner = make_exec_runner_callback(root)
      let result = @bitlib.interactive_rebase_skip_impl(
        wfs,
        rfs,
        root,
        msg_editor,
        exec_runner=Some(exec_runner),
      )
      if should_sign {
        match state_before {
          Some(state) =>
            ignore(
              rebase_sign_complete_interactive_result(
                fs,
                rfs,
                root,
                git_dir,
                state.onto,
                result,
                effective_signing_key,
                commit_algo,
              ),
            )
          None => ()
        }
      }
      rebase_update_signing_state_for_interactive_result(
        wfs, git_dir, should_sign, effective_signing_key, result,
      )
      print_interactive_rebase_result(result, quiet~)
    } else {
      let state_before = @bitlib.load_rebase_state(rfs, git_dir)
      let result = @bitlib.rebase_skip(fs, fs, root, run_filter_cmd=filter_cmd)
      let signed_id = if should_sign {
        match state_before {
          Some(state) =>
            rebase_sign_complete_result(
              fs,
              rfs,
              root,
              git_dir,
              state.onto,
              result,
              effective_signing_key,
              commit_algo,
            )
          None => None
        }
      } else {
        None
      }
      rebase_update_signing_state_for_result(
        wfs, git_dir, should_sign, effective_signing_key, result,
      )
      print_rebase_result_with_commit(result, signed_id, quiet~)
    }
    return ()
  }
  // rebase.backend config (apply/ort): bit has a unified backend, accept and ignore
  ignore(
    @bitlib.read_config_value(rfs, git_dir + "/config", "rebase", "backend"),
  )
  // rebase.stat: bit does not yet show diffstats, accept config for compat
  ignore(@bitlib.read_config_value(rfs, git_dir + "/config", "rebase", "stat"))
  // Also check rebase.autoStash config
  if !autostash {
    match
      @bitlib.read_config_value(rfs, git_dir + "/config", "rebase", "autostash") {
      Some(v) => if v.to_lower() == "true" { autostash = true }
      None => ()
    }
  }
  // Check rebase.updateRefs config if not set by flag
  let effective_update_refs = match update_refs {
    Some(v) => v
    None =>
      match
        @bitlib.read_config_value(
          rfs,
          git_dir + "/config",
          "rebase",
          "updateRefs",
        ) {
        Some(v) => v.to_lower() == "true"
        None => false
      }
  }
  // A second positional arg: switch to it first (like `bit checkout
  // <branch>`), so the rebase below operates on it as the current HEAD.
  // Reuses checkout's own worktree-lock / detached-HEAD / dirty-tree rules.
  // Unlike plain checkout, this check is unconditional even when the
  // target is already the current branch: rebase is about to rewrite the
  // branch's history, which is unsafe if another worktree also has it
  // checked out (e.g. via `git worktree add -f`, which lets one branch be
  // shared by two worktrees).
  match switch_to_branch {
    Some(target) => {
      match @bitlib.is_branch_checked_out_elsewhere(rfs, root, target) {
        Some(path) =>
          raise @bitcore.GitError::InvalidObject(
            "'\{target}' is already used by worktree at '\{path}'",
          )
        None => ()
      }
      handle_checkout([target])
    }
    None => ()
  }
  // Require a clean worktree/index before starting a new rebase, unless
  // --autostash (or rebase.autoStash) will stash the dirty state for us.
  if !autostash {
    let pre_status = @bitlib.status(rfs, root)
    let unstaged_dirty = pre_status.unstaged_modified.length() > 0 ||
      pre_status.unstaged_deleted.length() > 0
    let staged_dirty = pre_status.staged_added.length() > 0 ||
      pre_status.staged_modified.length() > 0 ||
      pre_status.staged_deleted.length() > 0
    if unstaged_dirty || staged_dirty {
      let mut message = "cannot rebase: "
      if unstaged_dirty {
        message += "You have unstaged changes.\n"
        if staged_dirty {
          message += "additionally, your index contains uncommitted changes.\n"
        }
      } else {
        message += "Your index contains uncommitted changes.\n"
      }
      message += "Please commit or stash them."
      raise @bitcore.GitError::InvalidObject(message)
    }
  }
  // Autostash: save dirty state before rebase
  let mut autostash_oid : @bitcore.ObjectId? = None
  if autostash {
    let author = get_author_string()
    let timestamp = get_commit_timestamp()
    let stash_id = @bitlib.stash_push(
      wfs, rfs, root, author, "autostash", timestamp,
    ) catch {
      _ => None
    }
    match stash_id {
      Some(id) => {
        autostash_oid = Some(id)
        eprint_line(
          "Created autostash: \{String::unsafe_substring(id.to_hex(), start=0, end=7)}",
        )
      }
      None => () // nothing to stash
    }
  }
  // Start new rebase
  // Resolve upstream: --root mode doesn't need an upstream argument
  // fork_point_ref is set only when the upstream was auto-resolved (no
  // explicit <upstream> given), matching git's rule that --fork-point
  // detection only kicks in by default in that case.
  let mut fork_point_ref : String? = None
  let id : @bitcore.ObjectId = if root_mode {
    // Use empty tree OID as a sentinel; actual root handling is in the lib layer
    @bitcore.ObjectId::from_hex("4b825dc642cb6eb9a060e54bf899d15363647a20")
  } else {
    let effective_upstream = match upstream {
      Some(u) => Some(u)
      None => {
        let resolved = rebase_resolve_default_upstream(rfs, git_dir)
        fork_point_ref = resolved
        resolved
      }
    }
    guard effective_upstream is Some(ref_name) else {
      raise @bitcore.GitError::InvalidObject(
        "usage: git rebase [-i] <upstream>",
      )
    }
    let upstream_id = @bitrepo.rev_parse(fs, git_dir, ref_name)
    guard upstream_id is Some(uid) else {
      raise @bitcore.GitError::InvalidObject("unknown revision: \{ref_name}")
    }
    uid
  }
  // Suppress unused warnings for strategy/strategy_options (accepted but not yet wired)
  ignore(strategy)
  ignore(strategy_options)
  if interactive {
    // Interactive rebase
    let onto_id = match onto {
      Some(o) => {
        let oid = @bitrepo.rev_parse(rfs, git_dir, o)
        match oid {
          Some(x) => x
          None => id
        }
      }
      None => id
    }
    // Read autosquash config
    let auto_squash_config = match
      @bitlib.read_config_value(
        rfs,
        git_dir + "/config",
        "rebase",
        "autosquash",
      ) {
      Some(v) => v.to_lower() == "true"
      None => false
    }
    let effective_autosquash = if no_autosquash {
      false
    } else {
      autosquash || auto_squash_config
    }
    // Build editor callbacks
    let seq_editor = make_sequence_editor_callback(fs, git_dir)
    let msg_editor = make_message_editor_callback(fs, git_dir)
    let exec_runner = make_exec_runner_callback(root)
    let result = @bitlib.interactive_rebase_start(
      wfs,
      rfs,
      root,
      id,
      onto_id,
      seq_editor,
      msg_editor,
      autosquash=effective_autosquash,
      exec_runner=Some(exec_runner),
      exec_cmds~,
      update_refs=effective_update_refs,
      root_mode~,
      rebase_merges~,
    )
    if should_sign {
      ignore(
        rebase_sign_complete_interactive_result(
          fs, rfs, root, git_dir, onto_id, result, effective_signing_key, commit_algo,
        ),
      )
    }
    rebase_update_signing_state_for_interactive_result(
      wfs, git_dir, should_sign, effective_signing_key, result,
    )
    print_interactive_rebase_result(result, quiet~)
    // Autostash pop on success
    if autostash_oid is Some(_) && result.status is @bitlib.IRBComplete {
      rebase_autostash_pop(wfs, rfs, root)
    }
  } else {
    let (base_id, result) = match onto {
      Some(o) => {
        let onto_id = @bitrepo.rev_parse(fs, git_dir, o)
        guard onto_id is Some(oid) else {
          raise @bitcore.GitError::InvalidObject("unknown revision: \{o}")
        }
        (
          oid,
          @bitlib.rebase_start_with_onto(
            fs, fs, root, oid, id, force_rebase~, run_filter_cmd=filter_cmd,
          ),
        )
      }
      None => {
        let exclude_from = match fork_point_ref {
          Some(ref_name) => {
            let head_id = @bitrepo.rev_parse(fs, git_dir, "HEAD")
            match head_id {
              Some(hid) =>
                match rebase_fork_point(rfs, git_dir, ref_name, hid) {
                  Some(fp) => fp
                  None => id
                }
              None => id
            }
          }
          None => id
        }
        (
          id,
          @bitlib.rebase_start_with_onto(
            fs, fs, root, id, exclude_from, force_rebase~,
            run_filter_cmd=filter_cmd,
          ),
        )
      }
    }
    if result.status is @bitlib.RebaseStatus::Conflict {
      wfs.write_string(
        git_dir + "/rebase-merge/backend",
        if use_apply_backend { "apply" } else { "merge" },
      ) catch {
        _ => ()
      }
    }
    let signed_id = if should_sign {
      rebase_sign_complete_result(
        fs, rfs, root, git_dir, base_id, result, effective_signing_key, commit_algo,
      )
    } else {
      None
    }
    rebase_update_signing_state_for_result(
      wfs, git_dir, should_sign, effective_signing_key, result,
    )
    print_rebase_result_with_commit(result, signed_id, quiet~)
    if result.status is @bitlib.RebaseStatus::Complete {
      rebase_copy_notes_after_rewrite(wfs, rfs, git_dir, result.rewritten)
    }
    // Autostash pop on success
    if autostash_oid is Some(_) &&
      result.status is @bitlib.RebaseStatus::Complete {
      rebase_autostash_pop(wfs, rfs, root)
    }
  }
}

///|
/// notes.rewrite.rebase (default true) + notes.rewriteRef: after a
/// successful rebase, copy each rewritten commit's note (if any) from its
/// old id to its new id, for every notes ref selected by notes.rewriteRef
/// (exact ref names, or a "refs/notes/*"-style prefix glob).
async fn rebase_copy_notes_after_rewrite(
  wfs : &@bitcore.FileSystem,
  rfs : &@bitcore.RepoFileSystem,
  git_dir : String,
  rewritten : Array[(@bitcore.ObjectId, @bitcore.ObjectId)],
) -> Unit raise Error {
  if rewritten.length() == 0 {
    return
  }
  let enabled = match
    @bitlib.read_config_value(
      rfs,
      git_dir + "/config",
      "notes",
      "rewrite.rebase",
    ) {
    Some(v) => v.to_lower() != "false"
    None => true
  }
  if !enabled {
    return
  }
  let patterns = @bitlib.read_config_values(
    rfs,
    git_dir + "/config",
    "notes",
    "rewriteRef",
  )
  if patterns.length() == 0 {
    return
  }
  let common_git_dir = notes_resolve_common_git_dir(rfs, git_dir)
  let target_refs = rebase_resolve_notes_rewrite_refs(
    rfs, common_git_dir, patterns,
  )
  for notes_ref in target_refs {
    for pair in rewritten {
      let (old_id, new_id) = pair
      if rebase_note_exists(rfs, git_dir, common_git_dir, notes_ref, old_id.to_hex()) {
        // force=true: internal rewrite copying (unlike `git notes copy`) is
        // not asking the user to confirm, and a rebase can deterministically
        // reproduce the same new commit id it produced last time (e.g. when
        // replaying the exact same commit onto the exact same base again),
        // in which case the destination note already legitimately exists.
        notes_copy(
          wfs, rfs, git_dir, common_git_dir, notes_ref, old_id.to_hex(), new_id.to_hex(),
          true,
        )
      }
    }
  }
}

///|
fn rebase_resolve_notes_rewrite_refs(
  rfs : &@bitcore.RepoFileSystem,
  common_git_dir : String,
  patterns : Array[String],
) -> Array[String] {
  let seen : Map[String, Bool] = Map([])
  let out : Array[String] = []
  for pattern in patterns {
    if pattern.has_suffix("/*") {
      let prefix = String::unsafe_substring(
        pattern,
        start=0,
        end=pattern.length() - 1,
      )
      let refs = @bitlib.list_refs_with_ids(rfs, common_git_dir, Some(prefix))
      for pair in refs.to_array() {
        let name = pair.0
        if !seen.contains(name) {
          seen[name] = true
          out.push(name)
        }
      }
    } else if !seen.contains(pattern) {
      seen[pattern] = true
      out.push(pattern)
    }
  }
  out
}

///|
fn rebase_note_exists(
  rfs : &@bitcore.RepoFileSystem,
  git_dir : String,
  common_git_dir : String,
  notes_ref : String,
  hex : String,
) -> Bool {
  let commit_id = @bitlib.resolve_ref(rfs, git_dir, notes_ref) catch {
    _ => None
  }
  guard commit_id is Some(cid) else { return false }
  let db = @bitlib.ObjectDb::load(rfs, common_git_dir) catch {
    _ => return false
  }
  let obj = db.get(rfs, cid) catch { _ => None }
  guard obj is Some(o) else { return false }
  let commit_info = @bitcore.parse_commit(o.data) catch { _ => return false }
  let collected = notes_collect_all(rfs, db, commit_info.tree) catch {
    _ => return false
  }
  for pair in collected {
    if pair.0 == hex {
      return true
    }
  }
  false
}

///|
async fn rebase_autostash_pop(
  fs : &@bitcore.FileSystem,
  rfs : &@bitcore.RepoFileSystem,
  root : String,
) -> Unit {
  @bitlib.stash_apply(fs, rfs, root, 0, true) catch {
    _ => {
      eprint_line("warning: could not apply autostash")
      return
    }
  }
  eprint_line("Applied autostash.")
}

///|
/// Create a sequence editor callback using GIT_SEQUENCE_EDITOR or EDITOR.
/// Writes content to the todo file, invokes editor, reads back result.
async fn make_sequence_editor_callback(
  fs : OsFs,
  git_dir : String,
) -> async (String) -> String? {
  let editor_cmd = resolve_sequence_editor()
  async fn(content : String) -> String? {
    let path = git_dir + "/rebase-merge/git-rebase-todo"
    let wfs : &@bitcore.FileSystem = fs
    wfs.mkdir_p(git_dir + "/rebase-merge")
    wfs.write_string(path, content) catch {
      _ => return None
    }
    match editor_cmd {
      None => Some(content)
      Some(cmd) => {
        let code = run_editor_on_path(cmd, path)
        if code != 0 {
          return None
        }
        let edited = decode_bytes(
          (fs as &@bitcore.RepoFileSystem).read_file(path) catch {
            _ => return None
          },
        )
        Some(edited)
      }
    }
  }
}

///|
/// Create a commit message editor callback.
async fn make_message_editor_callback(
  fs : OsFs,
  git_dir : String,
) -> async (String) -> String? {
  let editor_cmd = resolve_commit_editor()
  async fn(content : String) -> String? {
    let path = git_dir + "/COMMIT_EDITMSG"
    let template = commit_edit_buffer_template(Some(content))
    (fs as &@bitcore.FileSystem).write_string(path, template) catch {
      _ => return None
    }
    match editor_cmd {
      None => Some(content)
      Some(cmd) => {
        let code = run_editor_on_path(cmd, path)
        if code != 0 {
          return None
        }
        let edited = decode_bytes(
          (fs as &@bitcore.RepoFileSystem).read_file(path) catch {
            _ => return None
          },
        )
        normalize_commit_edit_buffer(edited)
      }
    }
  }
}

///|
/// Create an exec runner callback that runs shell commands in the repo root.
async fn make_exec_runner_callback(root : String) -> async (String) -> Int {
  async fn(cmd : String) -> Int {
    @process.run(
      "/bin/sh",
      ["-c", cmd],
      inherit_env=true,
      stdin=@stdio.stdin,
      stdout=@stdio.stdout,
      stderr=@stdio.stderr,
      cwd=root,
    )
  }
}

///|
async fn print_interactive_rebase_result(
  result : @bitlib.InteractiveRebaseResult,
  quiet? : Bool = false,
) -> Unit {
  match result.status {
    @bitlib.IRBComplete =>
      if !quiet {
        print_line("Successfully rebased and updated refs/heads.")
      }
    @bitlib.IRBConflict => {
      print_line(result.message)
      print_line("Resolve conflicts, then run \"git rebase --continue\".")
      @sys.exit(1)
    }
    @bitlib.IRBStopped => {
      print_line(result.message)
      if result.exit_code != 0 {
        @sys.exit(result.exit_code)
      }
    }
    @bitlib.IRBAborted =>
      if result.message.length() > 0 {
        eprint_line(result.message)
        @sys.exit(1)
      } else {
        print_line("Rebase aborted.")
      }
  }
}

///|
fn rebase_args_require_standalone_error(_args : Array[String]) -> Bool {
  false
}

///|
/// When no `<upstream>` argument is given, git defaults to the current
/// branch's configured upstream (`branch.<name>.merge`), same as `@{upstream}`.
fn rebase_resolve_default_upstream(
  rfs : &@bitcore.RepoFileSystem,
  git_dir : String,
) -> String? {
  let head_ref = @bitlib.read_head_ref(rfs, git_dir) catch { _ => return None }
  guard head_ref is @bitlib.HeadRef::Branch(branch) else { return None }
  let (_remotes, branches) = @bitlib.read_repo_config(rfs, git_dir)
  match branches.get(branch) {
    Some(cfg) if cfg.merges.length() > 0 => Some(cfg.merges[0])
    _ => None
  }
}

///|
/// git merge-base --fork-point semantics: when no explicit <upstream> is
/// given, `git rebase` doesn't just exclude commits reachable from
/// @{upstream}'s *current* tip — it walks @{upstream}'s reflog to find where
/// the current branch actually forked from it, since @{upstream} may have
/// since moved (e.g. been reset backward). That reflog-derived commit, not
/// the live tip, is the correct exclusion baseline for "which commits does
/// this rebase need to replay" — the target to attach onto is still the
/// live tip.
///
/// Algorithm: collect every commit ever recorded in upstream_ref's reflog
/// (old + new id per entry), keep the ones that are ancestors of `head_id`,
/// then keep only the "maximal" ones among those — not themselves an
/// ancestor of another qualifying candidate. If exactly one remains, that's
/// the fork point; otherwise (none, or an ambiguous multiple) there's no
/// unique fork point and the caller should fall back to the plain tip.
fn rebase_fork_point(
  rfs : &@bitcore.RepoFileSystem,
  git_dir : String,
  upstream_ref : String,
  head_id : @bitcore.ObjectId,
) -> @bitcore.ObjectId? {
  let entries = @bitlib.read_reflog(rfs, git_dir, upstream_ref) catch {
    _ => []
  }
  if entries.length() == 0 {
    return None
  }
  let seen : Map[String, Bool] = Map([])
  let candidates : Array[@bitcore.ObjectId] = []
  for entry in entries {
    for id in [entry.old_id, entry.new_id] {
      let hex = id.to_hex()
      if !seen.contains(hex) {
        seen[hex] = true
        candidates.push(id)
      }
    }
  }
  let qualifying : Array[@bitcore.ObjectId] = []
  for candidate in candidates {
    if @bitlib.is_ancestor_of(rfs, git_dir, candidate, head_id) {
      qualifying.push(candidate)
    }
  }
  let maximal : Array[@bitcore.ObjectId] = []
  for a in qualifying {
    let mut dominated = false
    for b in qualifying {
      if a != b && @bitlib.is_ancestor_of(rfs, git_dir, a, b) {
        dominated = true
        break
      }
    }
    if !dominated {
      maximal.push(a)
    }
  }
  if maximal.length() == 1 {
    Some(maximal[0])
  } else {
    None
  }
}

///|
async fn interactive_rebase_start(
  wfs : &@bitcore.FileSystem,
  rfs : &@bitcore.RepoFileSystem,
  root : String,
  git_dir : String,
  upstream : @bitcore.ObjectId,
  onto : @bitcore.ObjectId,
) -> Unit raise Error {
  let db = @bitlib.ObjectDb::load(rfs, git_dir)
  // Get HEAD
  let head = @bitrepo.rev_parse(rfs, git_dir, "HEAD")
  guard head is Some(h) else {
    raise @bitcore.GitError::InvalidObject("Cannot resolve HEAD")
  }
  // Collect commits to rebase
  let commits = collect_rebase_commits(db, rfs, h, upstream)
  if commits.length() == 0 {
    print_line("Current branch is up to date.")
    return
  }
  // Create rebase-merge directory
  let rebase_dir = git_dir + "/rebase-merge"
  wfs.mkdir_p(rebase_dir)
  // Save state
  wfs.write_string(rebase_dir + "/head-name", get_current_branch(rfs, git_dir))
  wfs.write_string(rebase_dir + "/orig-head", h.to_hex() + "\n")
  wfs.write_string(rebase_dir + "/onto", onto.to_hex() + "\n")
  // Generate todo file
  let todo = generate_rebase_todo(db, rfs, commits)
  let todo_path = rebase_dir + "/git-rebase-todo"
  wfs.write_string(todo_path, todo)
  // Also save done file (empty initially)
  wfs.write_string(rebase_dir + "/done", "")
  // Checkout onto
  ignore(
    run_checkout_with_sensitive_hooks(
      wfs,
      rfs,
      root,
      onto.to_hex(),
      detach=true,
    ),
  )
  let edited = edit_rebase_todo(todo_path)
  if edited {
    interactive_rebase_continue(wfs, rfs, root, git_dir)
    return
  }
  print_line("Interactive rebase started.")
  print_line("")
  print_line("Edit the todo file at: \{todo_path}")
  print_line("")
  print_line("Commands:")
  print_line(" p, pick   = use commit")
  print_line(" r, reword = use commit, but edit commit message")
  print_line(" e, edit   = use commit, but stop for amending")
  print_line(" s, squash = use commit, but meld into previous commit")
  print_line(" f, fixup  = like squash, but discard commit message")
  print_line(" d, drop   = remove commit")
  print_line("")
  print_line(
    "Set GIT_SEQUENCE_EDITOR (or EDITOR), then run 'git rebase --continue'.",
  )
}

///|
fn collect_rebase_commits(
  db : @bitlib.ObjectDb,
  rfs : &@bitcore.RepoFileSystem,
  head : @bitcore.ObjectId,
  upstream : @bitcore.ObjectId,
) -> Array[@bitcore.ObjectId] raise Error {
  let result : Array[@bitcore.ObjectId] = []
  let upstream_hex = upstream.to_hex()
  let mut current = head
  while current.to_hex() != upstream_hex {
    result.push(current)
    let obj = db.get(rfs, current)
    guard obj is Some(o) else { break }
    let info = @bitcore.parse_commit(o.data)
    if info.parents.length() == 0 {
      break
    }
    current = info.parents[0]
  }
  // Reverse to get chronological order (oldest first)
  result.rev_in_place()
  result
}

///|
fn generate_rebase_todo(
  db : @bitlib.ObjectDb,
  rfs : &@bitcore.RepoFileSystem,
  commits : Array[@bitcore.ObjectId],
) -> String raise Error {
  let sb = StringBuilder::new()
  for commit in commits {
    let full_hex = commit.to_hex()
    let obj = db.get(rfs, commit)
    let subject = match obj {
      Some(o) => {
        let msg = extract_commit_message(o.data)
        get_first_line(msg)
      }
      None => "???"
    }
    sb.write_string("pick ")
    sb.write_string(full_hex)
    sb.write_string(" ")
    sb.write_string(subject)
    sb.write_string("\n")
  }
  sb.write_string("\n")
  sb.write_string("# Rebase commands:\n")
  sb.write_string("# p, pick = use commit\n")
  sb.write_string("# r, reword = use commit, but edit the commit message\n")
  sb.write_string("# e, edit = use commit, but stop for amending\n")
  sb.write_string("# s, squash = use commit, but meld into previous commit\n")
  sb.write_string(
    "# f, fixup = like squash, but discard this commit's log message\n",
  )
  sb.write_string("# d, drop = remove commit\n")
  sb.write_string("#\n")
  sb.write_string("# Lines starting with '#' will be ignored.\n")
  sb.to_string()
}

///|
fn get_current_branch(
  rfs : &@bitcore.RepoFileSystem,
  git_dir : String,
) -> String {
  let head_path = git_dir + "/HEAD"
  if rfs.is_file(head_path) {
    let content = trim_string(
      decode_bytes(rfs.read_file(head_path) catch { _ => return "HEAD" }),
    )
    if content.has_prefix("ref: refs/heads/") {
      return String::unsafe_substring(content, start=16, end=content.length())
    }
  }
  "HEAD"
}

///|
async fn interactive_rebase_continue(
  wfs : &@bitcore.FileSystem,
  rfs : &@bitcore.RepoFileSystem,
  root : String,
  git_dir : String,
) -> Unit raise Error {
  let rebase_dir = git_dir + "/rebase-merge"
  let todo_path = rebase_dir + "/git-rebase-todo"
  let done_path = rebase_dir + "/done"
  // Read todo file
  let todo_content = if rfs.is_file(todo_path) {
    decode_bytes(rfs.read_file(todo_path))
  } else {
    ""
  }
  // Parse todo entries
  let entries = parse_rebase_todo(todo_content)
  if entries.length() == 0 {
    // Rebase complete
    interactive_rebase_finish(wfs, rfs, root, git_dir)
    return
  }
  // Process first entry
  let entry = entries[0]
  let db = @bitlib.ObjectDb::load(rfs, git_dir)
  let author = get_author_string()
  let timestamp = get_commit_timestamp()
  match entry.command {
    "pick" | "p" => {
      // Cherry-pick the commit
      let result = cherry_pick_commit(
        wfs,
        rfs,
        root,
        git_dir,
        db,
        entry.commit_ref,
      )
      if result.has_conflict {
        print_line(
          "CONFLICT: Resolve conflicts then run 'git rebase --continue'",
        )
        return
      }
      // Move to done
      move_todo_to_done(wfs, rfs, rebase_dir, entry)
      // Continue with next
      interactive_rebase_continue(wfs, rfs, root, git_dir)
    }
    "reword" | "r" => {
      // Cherry-pick then prompt for new message
      let result = cherry_pick_commit(
        wfs,
        rfs,
        root,
        git_dir,
        db,
        entry.commit_ref,
      )
      if result.has_conflict {
        print_line(
          "CONFLICT: Resolve conflicts then run 'git rebase --continue'",
        )
        return
      }
      // For reword, we need to amend with new message
      // In non-interactive mode, just use original message
      print_line("Reword: commit \{entry.commit_ref}")
      print_line(
        "(In this implementation, edit the commit message manually with 'git commit --amend')",
      )
      move_todo_to_done(wfs, rfs, rebase_dir, entry)
      interactive_rebase_continue(wfs, rfs, root, git_dir)
    }
    "edit" | "e" => {
      // Cherry-pick then stop
      let result = cherry_pick_commit(
        wfs,
        rfs,
        root,
        git_dir,
        db,
        entry.commit_ref,
      )
      if result.has_conflict {
        print_line(
          "CONFLICT: Resolve conflicts then run 'git rebase --continue'",
        )
        return
      }
      move_todo_to_done(wfs, rfs, rebase_dir, entry)
      print_line("Stopped at \{entry.commit_ref}")
      print_line(
        "You can amend the commit now, then run 'git rebase --continue'",
      )
    }
    "squash" | "s" => {
      // Cherry-pick and squash into previous
      squash_commit(
        wfs,
        rfs,
        root,
        git_dir,
        db,
        entry.commit_ref,
        author,
        timestamp,
        false,
      )
      move_todo_to_done(wfs, rfs, rebase_dir, entry)
      interactive_rebase_continue(wfs, rfs, root, git_dir)
    }
    "fixup" | "f" => {
      // Cherry-pick and fixup (squash without message)
      squash_commit(
        wfs,
        rfs,
        root,
        git_dir,
        db,
        entry.commit_ref,
        author,
        timestamp,
        true,
      )
      move_todo_to_done(wfs, rfs, rebase_dir, entry)
      interactive_rebase_continue(wfs, rfs, root, git_dir)
    }
    "drop" | "d" => {
      // Skip this commit
      print_line("Dropping \{entry.commit_ref}")
      move_todo_to_done(wfs, rfs, rebase_dir, entry)
      interactive_rebase_continue(wfs, rfs, root, git_dir)
    }
    _ => {
      // Unknown command, skip
      move_todo_to_done(wfs, rfs, rebase_dir, entry)
      interactive_rebase_continue(wfs, rfs, root, git_dir)
    }
  }
  ignore(done_path)
}

///|
struct RebaseTodoEntry {
  command : String
  commit_ref : String
  message : String
}

///|
fn parse_rebase_todo(content : String) -> Array[RebaseTodoEntry] {
  let result : Array[RebaseTodoEntry] = []
  for line_view in content.split("\n") {
    let line = trim_string(line_view.to_owned())
    // Skip comments and empty lines
    if line.length() == 0 || line.has_prefix("#") {
      continue
    }
    // Parse "command commit message"
    let parts = split_whitespace(line, 3)
    if parts.length() >= 2 {
      result.push({
        command: parts[0],
        commit_ref: parts[1],
        message: if parts.length() > 2 {
          parts[2]
        } else {
          ""
        },
      })
    }
  }
  result
}

///|
fn split_whitespace(s : String, max_parts : Int) -> Array[String] {
  let result : Array[String] = []
  let current = StringBuilder::new()
  let mut in_word = false
  for c in s {
    if c == ' ' || c == '\t' {
      if in_word {
        result.push(current.to_string())
        if result.length() >= max_parts - 1 {
          // Rest of string goes into last part
          let rest = get_rest_after_parts(s, result.length())
          if rest.length() > 0 {
            result.push(rest)
          }
          return result
        }
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
fn get_rest_after_parts(s : String, num_parts : Int) -> String {
  let mut parts_found = 0
  let mut i = 0
  let mut in_word = false
  while i < s.length() {
    let c = s[i]
    if c == ' ' || c == '\t' {
      if in_word {
        parts_found += 1
        if parts_found >= num_parts {
          // Skip whitespace and return rest
          while i < s.length() && (s[i] == ' ' || s[i] == '\t') {
            i += 1
          }
          return String::unsafe_substring(s, start=i, end=s.length())
        }
        in_word = false
      }
    } else {
      in_word = true
    }
    i += 1
  }
  ""
}

///|
fn move_todo_to_done(
  wfs : &@bitcore.FileSystem,
  rfs : &@bitcore.RepoFileSystem,
  rebase_dir : String,
  entry : RebaseTodoEntry,
) -> Unit {
  let todo_path = rebase_dir + "/git-rebase-todo"
  let done_path = rebase_dir + "/done"
  // Append to done
  let done_content = if rfs.is_file(done_path) {
    decode_bytes(rfs.read_file(done_path) catch { _ => return })
  } else {
    ""
  }
  let new_done = done_content +
    entry.command +
    " " +
    entry.commit_ref +
    " " +
    entry.message +
    "\n"
  wfs.write_string(done_path, new_done) catch {
    _ => ()
  }
  // Remove first line from todo
  let todo_content = if rfs.is_file(todo_path) {
    decode_bytes(rfs.read_file(todo_path) catch { _ => return })
  } else {
    ""
  }
  let new_todo = remove_first_non_comment_line(todo_content)
  wfs.write_string(todo_path, new_todo) catch {
    _ => ()
  }
}

///|
fn remove_first_non_comment_line(content : String) -> String {
  let lines : Array[String] = []
  let mut skipped_first = false
  for line_view in content.split("\n") {
    let line = line_view.to_owned()
    if !skipped_first {
      let trimmed = trim_string(line)
      if trimmed.length() > 0 && !trimmed.has_prefix("#") {
        skipped_first = true
        continue
      }
    }
    lines.push(line)
  }
  lines.join("\n")
}

///|
struct CherryPickResult {
  has_conflict : Bool
}

///|
async fn cherry_pick_commit(
  wfs : &@bitcore.FileSystem,
  rfs : &@bitcore.RepoFileSystem,
  root : String,
  git_dir : String,
  db : @bitlib.ObjectDb,
  commit_ref : String,
) -> CherryPickResult raise Error {
  // Resolve commit
  let commit_id = @bitrepo.rev_parse(rfs, git_dir, commit_ref)
  guard commit_id is Some(cid) else {
    raise @bitcore.GitError::InvalidObject("Cannot resolve: \{commit_ref}")
  }
  let obj = db.get(rfs, cid)
  guard obj is Some(o) else {
    raise @bitcore.GitError::InvalidObject("Cannot read commit: \{commit_ref}")
  }
  let info = @bitcore.parse_commit(o.data)
  let message = extract_commit_message(o.data)
  let author_line = extract_author_line_from_bytes(o.data)
  let timestamp = get_commit_timestamp()
  // Simple cherry-pick: apply changes from commit
  // For now, create a new commit with the same tree
  // (This is simplified - real cherry-pick should apply diff)
  let head = @bitrepo.rev_parse(rfs, git_dir, "HEAD")
  guard head is Some(h) else {
    raise @bitcore.GitError::InvalidObject("Cannot resolve HEAD")
  }
  // Create commit
  let commit = @bitcore.Commit::new(
    info.tree,
    [h],
    author_line,
    timestamp,
    "+0000",
    author_line,
    timestamp,
    "+0000",
    message,
  )
  let (new_commit_id, commit_data) = @bitcore.create_commit(commit)
  @bitlib.write_object_bytes(wfs, git_dir, new_commit_id, commit_data)
  // Update HEAD
  wfs.write_string(git_dir + "/HEAD", new_commit_id.to_hex() + "\n")
  // Checkout the tree
  ignore(
    run_checkout_with_sensitive_hooks(
      wfs,
      rfs,
      root,
      new_commit_id.to_hex(),
      detach=true,
    ),
  )
  let short = String::unsafe_substring(new_commit_id.to_hex(), start=0, end=7)
  print_line("[\{short}] \{get_first_line(message)}")
  { has_conflict: false }
}

///|
async fn squash_commit(
  wfs : &@bitcore.FileSystem,
  rfs : &@bitcore.RepoFileSystem,
  root : String,
  git_dir : String,
  db : @bitlib.ObjectDb,
  commit_ref : String,
  author : String,
  timestamp : Int64,
  fixup : Bool,
) -> Unit raise Error {
  // Get commit to squash
  let commit_id = @bitrepo.rev_parse(rfs, git_dir, commit_ref)
  guard commit_id is Some(cid) else { return }
  let obj = db.get(rfs, cid)
  guard obj is Some(o) else { return }
  let info = @bitcore.parse_commit(o.data)
  let squash_msg = extract_commit_message(o.data)
  // Get current HEAD
  let head = @bitrepo.rev_parse(rfs, git_dir, "HEAD")
  guard head is Some(h) else { return }
  let head_obj = db.get(rfs, h)
  guard head_obj is Some(ho) else { return }
  let head_info = @bitcore.parse_commit(ho.data)
  let head_msg = extract_commit_message(ho.data)
  // New message: combine or just use head's
  let new_msg = if fixup { head_msg } else { head_msg + "\n\n" + squash_msg }
  // Create new commit with squashed changes
  // Use squashed commit's tree (simplified)
  let commit = @bitcore.Commit::new(
    info.tree,
    head_info.parents,
    author,
    timestamp,
    "+0000",
    author,
    timestamp,
    "+0000",
    new_msg,
  )
  let (new_commit_id, commit_data) = @bitcore.create_commit(commit)
  @bitlib.write_object_bytes(wfs, git_dir, new_commit_id, commit_data)
  // Update HEAD
  wfs.write_string(git_dir + "/HEAD", new_commit_id.to_hex() + "\n")
  ignore(
    run_checkout_with_sensitive_hooks(
      wfs,
      rfs,
      root,
      new_commit_id.to_hex(),
      detach=true,
    ),
  )
  let short = String::unsafe_substring(new_commit_id.to_hex(), start=0, end=7)
  if fixup {
    print_line("[\{short}] fixup")
  } else {
    print_line("[\{short}] squash")
  }
}

///|
async fn interactive_rebase_finish(
  wfs : &@bitcore.FileSystem,
  rfs : &@bitcore.RepoFileSystem,
  _root : String,
  git_dir : String,
) -> Unit raise Error {
  let rebase_dir = git_dir + "/rebase-merge"
  let head_name_path = rebase_dir + "/head-name"
  // Get current HEAD
  let head = @bitrepo.rev_parse(rfs, git_dir, "HEAD")
  guard head is Some(h) else { return }
  // Restore branch pointer
  if rfs.is_file(head_name_path) {
    let branch = rfs.read_file(head_name_path) |> decode_bytes |> trim_string
    if branch != "HEAD" {
      wfs.write_string(git_dir + "/refs/heads/" + branch, h.to_hex() + "\n")
      wfs.write_string(git_dir + "/HEAD", "ref: refs/heads/" + branch + "\n")
    }
  }
  // Clean up
  cleanup_rebase_dir(wfs, rfs, rebase_dir)
  print_line("Successfully rebased.")
}

///|
fn cleanup_rebase_dir(
  wfs : &@bitcore.FileSystem,
  rfs : &@bitcore.RepoFileSystem,
  rebase_dir : String,
) -> Unit {
  let files = rfs.readdir(rebase_dir) catch { _ => return }
  for file in files {
    wfs.remove_file(rebase_dir + "/" + file) catch {
      _ => ()
    }
  }
  wfs.remove_file(rebase_dir) catch {
    _ => ()
  }
}

///|
async fn print_rebase_result_with_commit(
  result : @bitlib.RebaseResult,
  commit_id_override : @bitcore.ObjectId?,
  quiet? : Bool = false,
) -> Unit {
  match result.status {
    @bitlib.RebaseStatus::Complete => {
      if quiet {
        return
      }
      let display_commit_id = if commit_id_override is Some(id) {
        Some(id)
      } else {
        result.commit_id
      }
      match display_commit_id {
        Some(id) => {
          let short = String::unsafe_substring(id.to_hex(), start=0, end=7)
          print_line("Successfully rebased and updated refs. [\{short}]")
        }
        None => print_line("Successfully rebased.")
      }
    }
    @bitlib.RebaseStatus::NothingToRebase =>
      if !quiet {
        print_line("Current branch is up to date.")
      }
    @bitlib.RebaseStatus::Conflict => {
      print_line("CONFLICT: Merge conflict in:")
      for path in result.conflicts {
        print_line("  \{path}")
      }
      print_line("")
      print_line("Resolve all conflicts, then run \"git rebase --continue\".")
      print_line(
        "To abort and return to the original state, run \"git rebase --abort\".",
      )
      print_line("To skip this commit, run \"git rebase --skip\".")
      @sys.exit(1)
    }
  }
}

///|
async fn print_rebase_result(result : @bitlib.RebaseResult) -> Unit {
  print_rebase_result_with_commit(result, None)
}

///|
async fn handle_subdir_rebase(
  fs : OsFs,
  root : String,
  git_dir : String,
  upstream : String?,
) -> Unit raise Error {
  // Read subdir metadata
  let (_remote_url, subdir_path, base_hex) = match
    read_subdir_attributes(fs, git_dir) {
    Some(info) => info
    None => {
      print_line("Error: not a subdir-clone repository")
      return
    }
  }
  let target_ref = upstream.unwrap_or("origin/main")
  print_line("Rebasing subdir-clone onto \{target_ref}...")
  print_line("  Subdirectory: \{subdir_path}")
  print_line("  Base commit: \{base_hex}")
  // Step 1: Fetch from origin
  print_line("  Fetching from origin...")
  let _ = run_git_command(["-C", root, "fetch", "origin"], cwd=None)
  // Step 2: Resolve upstream ref
  let upstream_path = git_dir + "/refs/remotes/" + target_ref
  let upstream_bytes = fs.read_file(upstream_path) catch {
    err => {
      if @async.is_being_cancelled() || @async.is_cancellation_error(err) {
        raise err
      }
      print_line("Error: cannot resolve ref: \{target_ref}")
      print_line("Make sure it exists (e.g., origin/main)")
      return
    }
  }
  let upstream_hex = subdir_bytes_to_string(upstream_bytes)
    .trim(chars=" \n\t")
    .to_owned()
  print_line("  Upstream: \{upstream_hex}")
  // Step 3: Find commits affecting subdirectory
  print_line("  Finding changes to \{subdir_path}...")
  let db = @bitlib.ObjectDb::load_lazy(fs, git_dir)
  let commits = find_subdir_affecting_commits(
    db, fs, base_hex, upstream_hex, subdir_path,
  ) catch {
    err => raise err
  }
  if commits.length() == 0 {
    print_line("Already up to date. No changes to \{subdir_path}.")
    update_subdir_base(fs, git_dir, upstream_hex)
    return
  }
  print_line("  Found \{commits.length()} commits affecting \{subdir_path}")
  // Step 4: Apply each commit
  for commit_info in commits {
    print_line("  Applying: \{commit_info.message}")
    apply_subdir_change(fs, db, root, git_dir, commit_info) catch {
      err => raise err
    }
  }
  // Step 5: Update base commit
  update_subdir_base(fs, git_dir, upstream_hex)
  // Step 6: Reset index
  let _ = run_git_command(["-C", root, "reset", "HEAD"], cwd=None)
  print_line("done.")
  print_line("")
  print_line("Successfully rebased onto \{target_ref}")
}

///|
struct SubdirChangeInfo {
  id : @bitcore.ObjectId
  subdir_tree : @bitcore.ObjectId
  message : String
  author : String
}

///|
fn find_subdir_affecting_commits(
  db : @bitlib.ObjectDb,
  fs : OsFs,
  base_hex : String,
  target_hex : String,
  subdir_path : String,
) -> Array[SubdirChangeInfo] raise @bitcore.GitError {
  let result : Array[SubdirChangeInfo] = []
  let base_id = @bitcore.ObjectId::from_hex(base_hex) catch {
    _ => raise @bitcore.GitError::InvalidObject("Invalid base: " + base_hex)
  }
  let target_id = @bitcore.ObjectId::from_hex(target_hex) catch {
    _ => raise @bitcore.GitError::InvalidObject("Invalid target: " + target_hex)
  }
  // Get base subdir tree
  let base_subdir = get_commit_subdir_tree(db, fs, base_id, subdir_path) catch {
    err => raise err
  }
  // Walk from target to base, collect commits
  let commits_to_check : Array[@bitcore.ObjectId] = []
  let visited : Map[String, Bool] = Map([])
  let mut current = target_id
  while true {
    let hex = current.to_hex()
    if visited.contains(hex) || hex == base_hex {
      break
    }
    visited[hex] = true
    commits_to_check.push(current)
    let obj = db.get(fs, current)
    guard obj is Some(o) else { break }
    let info = @bitcore.parse_commit(o.data) catch { err => raise err }
    if info.parents.length() == 0 {
      break
    }
    current = info.parents[0]
  }
  // Process oldest first
  let mut prev_tree = base_subdir
  let mut i = commits_to_check.length() - 1
  while i >= 0 {
    let commit_id = commits_to_check[i]
    let curr_tree = get_commit_subdir_tree(db, fs, commit_id, subdir_path) catch {
      _ => {
        i -= 1
        continue
      }
    }
    // Check if changed
    let changed = match (prev_tree, curr_tree) {
      (Some(p), Some(c)) => p.to_hex() != c.to_hex()
      (None, Some(_)) => true
      _ => false
    }
    if changed {
      guard curr_tree is Some(tree) else {
        i -= 1
        continue
      }
      // Get commit info
      let obj = db.get(fs, commit_id)
      guard obj is Some(o) else {
        i -= 1
        continue
      }
      let (author, message) = parse_commit_author_message(o.data)
      result.push({ id: commit_id, subdir_tree: tree, message, author })
      prev_tree = curr_tree
    }
    i -= 1
  }
  result
}

///|
fn get_commit_subdir_tree(
  db : @bitlib.ObjectDb,
  fs : OsFs,
  commit_id : @bitcore.ObjectId,
  subdir_path : String,
) -> @bitcore.ObjectId? raise @bitcore.GitError {
  let obj = db.get(fs, commit_id)
  guard obj is Some(o) else { return None }
  let info = @bitcore.parse_commit(o.data) catch { err => raise err }
  find_tree_subtree(db, fs, info.tree, subdir_path) catch {
    err => raise err
  }
}

///|
fn find_tree_subtree(
  db : @bitlib.ObjectDb,
  fs : OsFs,
  tree_id : @bitcore.ObjectId,
  path : String,
) -> @bitcore.ObjectId? raise @bitcore.GitError {
  let parts : Array[String] = []
  for p in path.split("/") {
    let s = p.to_owned()
    if s.length() > 0 {
      parts.push(s)
    }
  }
  let mut current = tree_id
  for part in parts {
    let obj = db.get(fs, current)
    guard obj is Some(o) else { return None }
    let entries = @bitcore.parse_tree(o.data) catch { err => raise err }
    let mut found = false
    for entry in entries {
      if entry.name == part {
        current = entry.id
        found = true
        break
      }
    }
    if !found {
      return None
    }
  }
  Some(current)
}

///|
fn parse_commit_author_message(content : Bytes) -> (String, String) {
  let text = @utf8.decode_lossy(content[:])
  let mut author = ""
  let mut in_message = false
  let message = StringBuilder::new()
  for line_view in text.split("\n") {
    let line = line_view.to_owned()
    if in_message {
      message.write_string(line)
      message.write_char('\n')
      continue
    }
    if line.length() == 0 {
      in_message = true
      continue
    }
    if line.has_prefix("author ") {
      author = String::unsafe_substring(line, start=7, end=line.length())
    }
  }
  (author, message.to_string().trim(chars=" \n\t").to_owned())
}

///|
fn apply_subdir_change(
  fs : OsFs,
  db : @bitlib.ObjectDb,
  worktree : String,
  git_dir : String,
  info : SubdirChangeInfo,
) -> Unit raise @bitcore.GitError {
  // Clear worktree (keep .git)
  let entries = fs.readdir(worktree) catch { _ => [] }
  for entry in entries {
    if entry == ".git" {
      continue
    }
    let path = worktree + "/" + entry
    if fs.is_dir(path) {
      subdir_clear_dir(fs, path)
    } else {
      fs.remove_file(path) catch {
        _ => ()
      }
    }
  }
  // Write new tree
  subdir_write_tree(db, fs, info.subdir_tree, worktree) catch {
    err => raise err
  }
  // Create commit
  let timestamp = get_current_timestamp()
  let message = info.message + "\n\n(rebased from " + info.id.to_hex() + ")\n"
  // Get current HEAD
  let head_bytes = fs.read_file(git_dir + "/HEAD") catch {
    _ => raise @bitcore.GitError::IoError("Failed to read HEAD")
  }
  let head_text = subdir_bytes_to_string(head_bytes)
    .trim(chars=" \n\t")
    .to_owned()
  let parent_id = if head_text.has_prefix("ref: ") {
    let ref_name = String::unsafe_substring(
      head_text,
      start=5,
      end=head_text.length(),
    )
    let ref_bytes = fs.read_file(git_dir + "/" + ref_name) catch {
      _ => raise @bitcore.GitError::IoError("Failed to read ref")
    }
    let ref_hex = subdir_bytes_to_string(ref_bytes)
      .trim(chars=" \n\t")
      .to_owned()
    @bitcore.ObjectId::from_hex(ref_hex) catch {
      _ => raise @bitcore.GitError::InvalidObject("Invalid ref")
    }
  } else {
    @bitcore.ObjectId::from_hex(head_text) catch {
      _ => raise @bitcore.GitError::InvalidObject("Invalid HEAD")
    }
  }
  let commit = @bitcore.Commit::new(
    info.subdir_tree,
    [parent_id],
    info.author,
    timestamp,
    "+0000",
    info.author,
    timestamp,
    "+0000",
    message,
  )
  let (new_id, commit_bytes) = @bitcore.create_commit(commit)
  @bitlib.write_object_bytes(fs, git_dir, new_id, commit_bytes) catch {
    _ => raise @bitcore.GitError::IoError("Failed to write commit")
  }
  // Update HEAD
  let ref_path = git_dir + "/refs/heads/main"
  fs.write_file(ref_path, subdir_string_to_bytes(new_id.to_hex() + "\n")) catch {
    _ => ()
  }
}

///|
fn subdir_clear_dir(fs : OsFs, path : String) -> Unit {
  let entries = fs.readdir(path) catch { _ => return }
  for entry in entries {
    let child = path + "/" + entry
    if fs.is_dir(child) {
      subdir_clear_dir(fs, child)
    } else {
      fs.remove_file(child) catch {
        _ => ()
      }
    }
  }
  fs.remove_dir(path) catch {
    _ => ()
  }
}

///|
fn subdir_write_tree(
  db : @bitlib.ObjectDb,
  fs : OsFs,
  tree_id : @bitcore.ObjectId,
  dir : String,
) -> Unit raise @bitcore.GitError {
  let obj = db.get(fs, tree_id)
  guard obj is Some(o) else { return }
  let entries = @bitcore.parse_tree(o.data) catch { err => raise err }
  for entry in entries {
    let path = dir + "/" + entry.name
    if entry.mode == "40000" || entry.mode == "040000" {
      fs.mkdir_p(path) catch {
        _ => ()
      }
      subdir_write_tree(db, fs, entry.id, path) catch {
        err => raise err
      }
    } else {
      let blob = db.get(fs, entry.id)
      guard blob is Some(b) else { continue }
      fs.write_file(path, b.data) catch {
        _ => ()
      }
    }
  }
}

///|
fn subdir_bytes_to_string(bytes : Bytes) -> String {
  let result = StringBuilder::new()
  for i in 0..<bytes.length() {
    result.write_char(bytes[i].to_int().unsafe_to_char())
  }
  result.to_string()
}

///|
fn subdir_string_to_bytes(s : String) -> Bytes {
  let bytes : Array[Byte] = []
  for c in s {
    bytes.push(c.to_int().to_byte())
  }
  Bytes::from_array(bytes)
}

///|

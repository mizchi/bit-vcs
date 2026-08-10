///|
async fn handle_pull(args : Array[String]) -> Unit raise Error {
  let fs = OsFs::new()
  let rfs : &@bitcore.RepoFileSystem = fs
  let root = get_work_root()
  let git_dir = root + "/.git"
  if rfs.is_file(git_dir) {
    let gitfile = decode_bytes(
      rfs.read_file(git_dir) catch {
        _ => Default::default()
      },
    )
    ignore(gitfile)
  }
  let git_dir = if rfs.is_file(git_dir) {
    @bitlib.resolve_gitdir(rfs, git_dir)
  } else {
    git_dir
  }
  let (remotes, branches) = @bitlib.read_repo_config(fs, git_dir)
  // Read remote URL - prefer subdir-clone remote, then config
  let mut remote_name = "origin"
  let mut remote_url : String? = get_effective_remote_url(fs, git_dir)
  let mut cli_rebase_behavior : (Bool, Bool)? = None
  let mut autostash : Bool? = None
  let mut verify_signatures : Bool? = None
  let mut quiet = false
  let mut arg_remote : String? = None
  let arg_refspecs : Array[String] = []
  let mut pull_adhoc_remote = false
  let mut relay_preferred_sender_opt : String? = None
  let mut relay_preferred_repo_opt : String? = None
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    match arg {
      "--rebase" | "-r" => {
        cli_rebase_behavior = Some((true, false))
        i += 1
      }
      "--no-rebase" => {
        cli_rebase_behavior = Some((false, false))
        i += 1
      }
      _ if arg.has_prefix("--rebase=") => {
        let value = String::unsafe_substring(arg, start=9, end=arg.length())
        cli_rebase_behavior = Some(
          pull_parse_rebase_behavior_value(value, "--rebase"),
        )
        i += 1
      }
      "--autostash" => {
        autostash = Some(true)
        i += 1
      }
      "--no-autostash" => {
        autostash = Some(false)
        i += 1
      }
      "--verify-signatures" => {
        verify_signatures = Some(true)
        i += 1
      }
      "--no-verify-signatures" => {
        verify_signatures = Some(false)
        i += 1
      }
      "--relay-sender" if i + 1 < args.length() => {
        relay_preferred_sender_opt = Some(args[i + 1])
        i += 2
      }
      "--relay-sender" =>
        raise @bitcore.GitError::InvalidObject(
          "pull: --relay-sender requires a value",
        )
      "--relay-repo" if i + 1 < args.length() => {
        relay_preferred_repo_opt = Some(args[i + 1])
        i += 2
      }
      "--relay-repo" =>
        raise @bitcore.GitError::InvalidObject(
          "pull: --relay-repo requires a value",
        )
      _ if arg.has_prefix("--relay-sender=") => {
        relay_preferred_sender_opt = Some(
          String::unsafe_substring(arg, start=15, end=arg.length()),
        )
        i += 1
      }
      _ if arg.has_prefix("--relay-repo=") => {
        relay_preferred_repo_opt = Some(
          String::unsafe_substring(arg, start=13, end=arg.length()),
        )
        i += 1
      }
      "--ff"
      | "-f"
      | "--force"
      | "--no-ff"
      | "--ff-only"
      | "--squash"
      | "--no-squash"
      | "--no-commit"
      | "--stat"
      | "--no-stat"
      | "--verbose"
      | "-v"
      | "--progress"
      | "--no-progress"
      | "--allow-unrelated-histories" =>
        // no-value flags, ignore
        i += 1
      "--quiet" | "-q" => {
        quiet = true
        i += 1
      }
      "-s"
      | "--strategy"
      | "-X"
      | "--strategy-option"
      | "--depth"
      | "--deepen"
      | "--shallow-since"
      | "--shallow-exclude"
      | "-o"
      | "--server-option"
      | "--negotiation-tip"
      | "--upload-pack"
      | "--recurse-submodules"
      | "--refmap"
      | "--cleanup"
      | "--log" if i + 1 < args.length() =>
        // flags that consume the next argument as value
        i += 2
      _ if arg.has_prefix("-s") || arg.has_prefix("-X") =>
        // -sours or -Xpatience form (value concatenated)
        i += 1
      _ if arg.has_prefix("--strategy=") ||
        arg.has_prefix("--strategy-option=") ||
        arg.has_prefix("--depth=") ||
        arg.has_prefix("--recurse-submodules=") ||
        arg.has_prefix("--cleanup=") ||
        arg.has_prefix("--log=") ||
        arg.has_prefix("--refmap=") =>
        // --key=value form, single arg
        i += 1
      _ if arg.has_prefix("-") => {
        warn_unimplemented_arg("pull", arg)
        i += 1
      }
      _ => {
        if arg_remote is None {
          arg_remote = Some(arg)
        } else {
          arg_refspecs.push(arg)
        }
        i += 1
      }
    }
  }
  let arg_refspec = arg_refspecs.get(0)
  let explicit_refspec = pull_parse_explicit_refspec(arg_refspec)
  // Apply explicit remote argument
  match arg_remote {
    Some(r) =>
      match remotes.get(r) {
        Some(rc) => {
          remote_name = r
          pull_adhoc_remote = false
          if rc.urls.length() > 0 {
            remote_url = Some(rc.urls[0])
          }
        }
        None => {
          // `git pull <url> ...` should not overwrite origin tracking refs.
          remote_name = "__pull_tmp__"
          remote_url = Some(r)
          pull_adhoc_remote = true
        }
      }
    None => ()
  }
  // Resolve upstream from branch config when available
  let head_ref = @bitlib.read_head_ref(fs, git_dir)
  let current_head_target = match head_ref {
    @bitlib.HeadRef::Branch(branch) => "refs/heads/" + branch
    @bitlib.HeadRef::Detached(_) => "HEAD"
  }
  let mut current_branch_remote_cfg : String? = None
  let mut current_branch_rebase_cfg : Bool? = None
  let mut current_branch_has_merge = false
  let mut merge_ref : String? = None
  match head_ref {
    @bitlib.HeadRef::Branch(branch) => {
      match branches.get(branch) {
        Some(cfg) => {
          current_branch_remote_cfg = cfg.remote
          current_branch_rebase_cfg = cfg.rebase
          current_branch_has_merge = cfg.merges.length() > 0
          if cfg.remote is Some(r) && arg_remote is None {
            if r == "." {
              // branch.*.remote=. pulls from the current repository without
              // requiring a configured [remote "."]. Keep its temporary refs
              // isolated like `git pull . ...`.
              remote_name = "__pull_tmp__"
              pull_adhoc_remote = true
              remote_url = Some(".")
            } else {
              remote_name = r
              pull_adhoc_remote = false
              match @bitlib.get_remote_url(fs, git_dir, r) {
                Some(u) => remote_url = Some(u)
                None => ()
              }
            }
          }
          let use_branch_merge = match arg_remote {
            None => true
            Some(explicit_remote) => cfg.remote == Some(explicit_remote)
          }
          if use_branch_merge && cfg.merges.length() > 0 {
            merge_ref = Some(cfg.merges[0])
          }
        }
        None => ()
      }
      if merge_ref is None && arg_refspec is None && arg_remote is None {
        merge_ref = Some("refs/heads/" + branch)
      }
    }
    _ => ()
  }
  let (rebase, interactive_rebase) = pull_resolve_rebase_behavior(
    fs, git_dir, current_branch_rebase_cfg, cli_rebase_behavior,
  )
  match verify_signatures {
    Some(true) if rebase =>
      eprint_line("warning: ignoring --verify-signatures for rebase")
    _ => ()
  }
  // Apply explicit refspec argument
  match explicit_refspec.merge_ref {
    Some(r) => merge_ref = Some(r)
    None => ()
  }
  let target_ref = pull_target_ref(
    remote_name,
    merge_ref,
    explicit_refspec.target_ref,
  )
  let upstream_ref = pull_upstream_ref(
    remote_name,
    merge_ref,
    explicit_refspec.upstream_ref,
  )
  let fetch_refspecs = pull_fetch_refspecs(
    explicit_refspec.fetch_refspecs,
    merge_ref,
    target_ref,
  )
  guard remote_url is Some(initial_url) else {
    raise @bitcore.GitError::InvalidObject("No remote configured")
  }
  let mut pull_url = initial_url
  if pull_remote_uses_relay_signaling(pull_url) {
    let preferred_sender = match
      pull_normalize_optional_value(relay_preferred_sender_opt) {
      Some(value) => Some(value)
      None => pull_relay_preferred_sender()
    }
    let preferred_repo = match
      pull_normalize_optional_value(relay_preferred_repo_opt) {
      Some(value) => Some(value)
      None => pull_relay_preferred_repo()
    }
    let (relay_sender, relay_fetch_url) = resolve_pull_remote_via_relay(
      pull_url,
      preferred_sender~,
      preferred_repo~,
    )
    if !quiet {
      print_line("Relay peer selected: \{relay_sender} -> \{relay_fetch_url}")
    }
    pull_url = relay_fetch_url
  }
  let pre_fetch_head = @bitlib.resolve_ref(fs, git_dir, "HEAD")
  let pre_fetch_target_id = @bitlib.resolve_ref(fs, git_dir, target_ref)
  match
    pull_pre_fetch_validation_error(
      head_ref is @bitlib.HeadRef::Detached(_),
      arg_remote,
      arg_refspec,
      current_branch_remote_cfg,
      current_branch_has_merge,
      merge_ref,
      pre_fetch_head is Some(_),
    ) {
    Some(message) => raise @bitcore.GitError::InvalidObject(message)
    None => ()
  }
  match
    pull_in_progress_error(
      @bitlib.read_unmerged_paths(rfs, git_dir).length() > 0,
      rfs.is_file(git_dir + "/MERGE_HEAD"),
    ) {
    Some(message) => raise @bitcore.GitError::InvalidObject(message)
    None => ()
  }
  let fetch_updates_checked_out_head = explicit_refspec.target_ref is Some(_) &&
    target_ref == current_head_target
  let autostash_enabled = pull_autostash_enabled(fs, git_dir, rebase, autostash)
  if pre_fetch_head is Some(_) &&
    !fetch_updates_checked_out_head &&
    !autostash_enabled &&
    pull_has_uncommitted_changes(@bitlib.status(fs, root)) {
    raise @bitcore.GitError::InvalidObject(
      "Cannot pull because you have uncommitted changes.",
    )
  }
  if rebase && arg_refspecs.length() > 1 {
    raise @bitcore.GitError::InvalidObject(
      "Cannot rebase onto multiple branches.",
    )
  }
  if pre_fetch_head is None && arg_refspecs.length() > 1 {
    raise @bitcore.GitError::InvalidObject(
      "Cannot merge multiple branches into empty HEAD.",
    )
  }
  let bare_repo = @bitlib.is_bare_git_dir(git_dir)
  let initial_unborn_status = if pre_fetch_head is None && !bare_repo {
    Some(@bitlib.status(fs, root))
  } else {
    None
  }
  let initial_unborn_entries = if pre_fetch_head is None && !bare_repo {
    @bitlib.read_index_entries(fs, git_dir)
  } else {
    []
  }
  if pre_fetch_head is None && rebase && initial_unborn_entries.length() > 0 {
    raise @bitcore.GitError::InvalidObject(
      "Updating an unborn branch with changes added to the index.",
    )
  }
  let pre_fetch_checked_out_head_status = if pre_fetch_head is Some(_) &&
    fetch_updates_checked_out_head &&
    !bare_repo {
    Some(@bitlib.status(fs, root))
  } else {
    None
  }
  if !quiet {
    print_line("Fetching from \{pull_url}...")
  }
  fetch_from_remote(
    fs,
    git_dir,
    root,
    remote_name,
    pull_url,
    fetch_refspecs,
    update_head_ok=explicit_refspec.target_ref is Some(_),
    quiet~,
  )
  let mut target_id = @bitlib.resolve_ref(fs, git_dir, target_ref)
  if target_id is None {
    target_id = resolve_fetch_head_oid(fs, git_dir)
    match (target_id, explicit_refspec.target_ref) {
      (Some(id), Some(explicit_target)) =>
        if explicit_target.has_prefix("refs/") {
          write_ref_file(fs, git_dir, explicit_target, id)
        }
      _ => ()
    }
  }
  if target_id is None {
    match @bitlib.resolve_local_repo_path(fs, root, pull_url) {
      Some(src_path) =>
        match @bitlib.detect_git_dir(fs, src_path) {
          Some((src_git_dir, _)) =>
            match @bitlib.resolve_ref(fs, src_git_dir, upstream_ref) {
              Some(id) => {
                @bitlib.copy_tree(
                  fs,
                  fs,
                  src_git_dir + "/objects",
                  git_dir + "/objects",
                )
                write_ref_file(fs, git_dir, target_ref, id)
                target_id = Some(id)
              }
              None => ()
            }
          None => ()
        }
      None =>
        match resolve_remote_ref_id(pull_url, upstream_ref) {
          Some((id, _)) => {
            let haves = match pre_fetch_target_id {
              Some(have) => [have]
              None =>
                match pre_fetch_head {
                  Some(have) => [have]
                  None => []
                }
            }
            let shallow = @repo.read_shallow_boundaries(fs, git_dir)
            let pack = @bitnative.fetch_pack_http(
              pull_url,
              [id],
              true,
              haves~,
              shallow~,
            )
            let objects = @pack.parse_packfile(pack)
            @pack.write_packfile_with_index(fs, git_dir, pack, objects)
            write_ref_file(fs, git_dir, target_ref, id)
            target_id = Some(id)
          }
          None => ()
        }
    }
  }
  guard target_id is Some(tid) else {
    raise @bitcore.GitError::InvalidObject(
      pull_missing_target_error_message(
        arg_refspec,
        merge_ref,
        explicit_refspec.fetch_refspecs,
        target_ref,
      ),
    )
  }
  let db = @bitlib.ObjectDb::load(fs, git_dir)
  let target_modes = collect_commit_tree_modes(db, fs, tid)
  match (pre_fetch_head, pre_fetch_checked_out_head_status) {
    (Some(old_id), Some(status)) =>
      if old_id != tid {
        if !quiet {
          eprint_line("fetch updated the current branch head")
        }
        if !pull_can_fast_forward_checked_out_head(status, target_modes) {
          if pull_adhoc_remote {
            @bitlib.remove_remote_refs(fs, fs, git_dir, remote_name)
          }
          raise @bitcore.GitError::InvalidObject(
            "Cannot fast-forward your working tree",
          )
        }
        pull_update_checked_out_head_worktree(fs, git_dir, root, tid)
        pull_append_fast_forward_reflog(
          fs, fs, git_dir, current_head_target, old_id, tid, args,
        )
        if pull_adhoc_remote {
          @bitlib.remove_remote_refs(fs, fs, git_dir, remote_name)
        }
        return
      }
    _ => ()
  }
  match pre_fetch_head {
    Some(head_id) => {
      let head_modes = collect_commit_tree_modes(db, fs, head_id)
      match
        find_submodule_replaced_with_non_submodule(head_modes, target_modes) {
        Some(path) =>
          raise @bitcore.GitError::InvalidObject(
            "Refusing to replace submodule '\{path}' with non-submodule entry",
          )
        None => ()
      }
    }
    None => ()
  }
  if pre_fetch_head is None {
    let head_target = match @bitlib.read_head_ref(fs, git_dir) {
      @bitlib.HeadRef::Branch(branch) =>
        resolve_initial_pull_head_target(Some(branch))
      @bitlib.HeadRef::Detached(_) => resolve_initial_pull_head_target(None)
    }
    let preserved_entries : Array[@bitlib.IndexEntry] = []
    let preserved_files : Map[String, Bytes] = Map([])
    if !bare_repo {
      let current_status = match initial_unborn_status {
        Some(status) => status
        None => @bitlib.status(fs, root)
      }
      let conflicting_paths = pull_collect_initial_conflicting_paths(
        current_status, target_modes,
      )
      if conflicting_paths.length() > 0 {
        raise @bitcore.GitError::InvalidObject(
          "Pulling into an unborn branch would overwrite local changes: " +
          conflicting_paths[0],
        )
      }
      for
        entry in pull_collect_initial_preserved_index_entries(
          initial_unborn_entries, target_modes,
        ) {
        preserved_entries.push(entry)
      }
      let preserved_paths : Array[String] = []
      for entry in preserved_entries {
        preserved_paths.push(entry.path)
      }
      for path in current_status.untracked {
        if !target_modes.contains(path) {
          preserved_paths.push(path)
        }
      }
      for path, data in pull_snapshot_worktree_files(fs, root, preserved_paths) {
        preserved_files[path] = data
      }
    }
    if head_target == "HEAD" {
      fs.write_string(git_dir + "/HEAD", tid.to_hex() + "\n")
    } else {
      write_ref_file(fs, git_dir, head_target, tid)
    }
    if !bare_repo {
      if head_target.has_prefix("refs/heads/") {
        let branch = String::unsafe_substring(
          head_target,
          start="refs/heads/".length(),
          end=head_target.length(),
        )
        ignore(run_checkout_with_sensitive_hooks(fs, fs, root, branch))
      } else {
        ignore(run_checkout_with_sensitive_hooks(fs, fs, root, tid.to_hex()))
      }
      pull_restore_initial_checkout_state(
        fs, fs, git_dir, root, preserved_entries, preserved_files,
      )
    }
    match pre_fetch_head {
      Some(old_id) =>
        pull_append_fast_forward_reflog(
          fs, fs, git_dir, head_target, old_id, tid, args,
        )
      None => ()
    }
    if !quiet {
      print_line("Fast-forward")
    }
    if pull_adhoc_remote {
      @bitlib.remove_remote_refs(fs, fs, git_dir, remote_name)
    }
    return
  }
  let author = get_author_string()
  let timestamp = get_commit_timestamp()
  let autostash_state = if autostash_enabled && pre_fetch_head is Some(_) {
    pull_create_autostash(fs, fs, root, git_dir, author, timestamp)
  } else {
    None
  }
  if rebase {
    let reflog_refs : Array[String] = [target_ref]
    if pull_url == "." && upstream_ref != target_ref {
      reflog_refs.push(upstream_ref)
    }
    let rebase_upstream = match pre_fetch_head {
      Some(head_id) =>
        pull_resolve_rebase_upstream(
          fs, git_dir, head_id, reflog_refs, tid, pre_fetch_target_id,
        )
      None => tid
    }
    if interactive_rebase {
      interactive_rebase_start(fs, fs, root, git_dir, rebase_upstream, tid)
      if !rfs.is_dir(git_dir + "/rebase-merge") {
        pull_apply_autostash(fs, fs, git_dir, root, autostash_state, quiet)
      }
    } else {
      let filter_cmd = @bitlib.FilterCmd::{ run: @bitlibnative.run_filter_command }
      let result = @bitlib.rebase_start_with_onto(
        fs, fs, root, tid, rebase_upstream, run_filter_cmd=filter_cmd,
      )
      match result.status {
        @bitlib.RebaseStatus::Complete =>
          match result.commit_id {
            Some(id) => {
              if id == tid {
                match pre_fetch_head {
                  Some(old_id) if old_id != id =>
                    pull_append_fast_forward_reflog(
                      fs, fs, git_dir, current_head_target, old_id, id, args,
                    )
                  _ => ()
                }
                if !quiet {
                  print_line("Fast-forward")
                }
              } else if !quiet {
                print_line("Updated to \{id.to_hex()}")
              }
              pull_apply_autostash(
                fs, fs, git_dir, root, autostash_state, quiet,
              )
            }
            None => {
              if !quiet {
                print_line("Successfully rebased.")
              }
              pull_apply_autostash(
                fs, fs, git_dir, root, autostash_state, quiet,
              )
            }
          }
        @bitlib.RebaseStatus::NothingToRebase => {
          if !quiet {
            print_line("Current branch is up to date.")
          }
          pull_apply_autostash(fs, fs, git_dir, root, autostash_state, quiet)
        }
        @bitlib.RebaseStatus::Conflict => {
          pull_eprint_rebase_conflict(result.conflicts)
          raise @bitcore.GitError::InvalidObject("Rebase conflict")
        }
      }
    }
    return
  }
  let msg = "Merge " + target_ref
  let result = run_merge_with_sensitive_hooks(
    fs,
    fs,
    root,
    tid,
    msg,
    author,
    timestamp,
    theirs_label=target_ref,
  )
  match result.status {
    @bitlib.MergeStatus::AlreadyUpToDate =>
      if !quiet {
        print_line("Already up to date.")
      }
    @bitlib.MergeStatus::FastForward =>
      match result.commit_id {
        Some(id) => {
          match pre_fetch_head {
            Some(old_id) =>
              pull_append_fast_forward_reflog(
                fs, fs, git_dir, current_head_target, old_id, id, args,
              )
            None => ()
          }
          let short = String::unsafe_substring(id.to_hex(), start=0, end=7)
          if !quiet {
            print_line("Fast-forward to \{short}")
          }
        }
        None => {
          match pre_fetch_head {
            Some(old_id) =>
              pull_append_fast_forward_reflog(
                fs, fs, git_dir, current_head_target, old_id, tid, args,
              )
            None => ()
          }
          if !quiet {
            print_line("Fast-forward")
          }
        }
      }
    @bitlib.MergeStatus::Merged =>
      match result.commit_id {
        Some(id) => {
          let short = String::unsafe_substring(id.to_hex(), start=0, end=7)
          if !quiet {
            print_line("Merge made by the 'ort' strategy. [\{short}]")
          }
        }
        None => if !quiet { print_line("Merged") }
      }
    @bitlib.MergeStatus::Conflicted => {
      print_line("CONFLICT (content): Merge conflict in the following files:")
      for path in result.conflicts {
        print_line("  \{path}")
      }
      print_line("Automatic merge failed; fix conflicts and then commit.")
    }
  }
  match result.status {
    @bitlib.MergeStatus::Conflicted => ()
    _ => pull_apply_autostash(fs, fs, git_dir, root, autostash_state, quiet)
  }
  if pull_adhoc_remote {
    @bitlib.remove_remote_refs(fs, fs, git_dir, remote_name)
  }
  let exit_code = pull_merge_status_exit_code(result.status)
  if exit_code != 0 {
    @sys.exit(exit_code)
  }
}

///|
fn pull_parse_rebase_behavior_value(
  value : String,
  source : String,
) -> (Bool, Bool) raise @bitcore.GitError {
  let lower = value.trim().to_lower()
  match lower {
    "true" | "1" | "yes" | "on" | "" | "merges" | "m" | "preserve" =>
      (true, false)
    "false" | "0" | "no" | "off" => (false, false)
    "interactive" | "i" => (true, true)
    _ =>
      raise @bitcore.GitError::InvalidObject(
        "Invalid value for \{source}: \{value}",
      )
  }
}

///|
fn pull_resolve_rebase_behavior(
  fs : &@bitcore.RepoFileSystem,
  git_dir : String,
  branch_rebase : Bool?,
  cli_behavior : (Bool, Bool)?,
) -> (Bool, Bool) raise @bitcore.GitError {
  match cli_behavior {
    Some(behavior) => behavior
    None =>
      match branch_rebase {
        Some(true) => (true, false)
        Some(false) => (false, false)
        None => {
          let pull_rebase_values = read_config_values(
            fs, git_dir, "pull", "rebase",
          )
          guard pull_rebase_values.length() > 0 else { return (false, false) }
          pull_parse_rebase_behavior_value(
            pull_rebase_values[pull_rebase_values.length() - 1],
            "pull.rebase",
          )
        }
      }
  }
}

///|
fn pull_autostash_enabled(
  fs : &@bitcore.RepoFileSystem,
  git_dir : String,
  rebase : Bool,
  cli_value : Bool?,
) -> Bool {
  match cli_value {
    Some(value) => value
    None => {
      let config_path = git_dir + "/config"
      match @bitlib.read_config_value(fs, config_path, "pull", "autostash") {
        Some(value) => parse_config_bool_string(Some(value))
        None =>
          if rebase {
            @bitlib.read_config_bool(fs, config_path, "rebase", "autostash").unwrap_or(
              false,
            )
          } else {
            @bitlib.read_config_bool(fs, config_path, "merge", "autostash").unwrap_or(
              false,
            )
          }
      }
    }
  }
}

///|
fn pull_has_uncommitted_changes(status : @bitlib.Status) -> Bool {
  status.staged_added.length() > 0 ||
  status.staged_modified.length() > 0 ||
  status.staged_deleted.length() > 0 ||
  status.unstaged_modified.length() > 0 ||
  status.unstaged_deleted.length() > 0
}

///|
fn pull_resolve_rebase_upstream(
  fs : &@bitcore.RepoFileSystem,
  git_dir : String,
  head_id : @bitcore.ObjectId,
  reflog_refs : Array[String],
  target_id : @bitcore.ObjectId,
  pre_fetch_target_id : @bitcore.ObjectId?,
) -> @bitcore.ObjectId {
  match pre_fetch_target_id {
    Some(id) if id != target_id &&
      @bitlib.is_ancestor_of(fs, git_dir, id, head_id) => return id
    _ => ()
  }
  for refname in reflog_refs {
    let entries = @bitlib.read_reflog(fs, git_dir, refname) catch { _ => [] }
    let mut i = entries.length()
    while i > 0 {
      i -= 1
      let entry = entries[i]
      if entry.old_id != target_id &&
        @bitlib.is_ancestor_of(fs, git_dir, entry.old_id, head_id) {
        return entry.old_id
      }
      if entry.new_id != target_id &&
        @bitlib.is_ancestor_of(fs, git_dir, entry.new_id, head_id) {
        return entry.new_id
      }
    }
  }
  target_id
}

///|
async fn pull_apply_autostash(
  fs : &@bitcore.FileSystem,
  rfs : &@bitcore.RepoFileSystem,
  git_dir : String,
  root : String,
  state : PullAutostashState?,
  quiet : Bool,
) -> Unit raise Error {
  match state {
    None => return
    Some(state) => {
      @bitlib.stash_drop(fs, rfs, root, 0)
      let restored_index_paths : Map[String, Bool] = Map([])
      for entry in state.index_entries {
        restored_index_paths[entry.path] = true
      }
      let deleted_paths : Map[String, Bool] = Map([])
      for path in state.deleted_paths {
        deleted_paths[path] = true
      }
      let merged_entries : Array[@bitlib.IndexEntry] = []
      for entry in @bitlib.read_index_entries(rfs, git_dir) {
        if restored_index_paths.contains(entry.path) ||
          deleted_paths.contains(entry.path) {
          continue
        }
        merged_entries.push(entry)
      }
      for entry in state.index_entries {
        merged_entries.push(entry)
      }
      @bitlib.write_index_entries(fs, git_dir, merged_entries)
      for path, data in state.worktree_files {
        match pull_parent_dir(path) {
          Some(parent) => fs.mkdir_p(root + "/" + parent)
          None => ()
        }
        fs.write_file(root + "/" + path, data)
      }
      for path in state.deleted_paths {
        let abs = root + "/" + path
        if rfs.is_file(abs) || rfs.is_dir(abs) {
          fs.remove_file(abs) catch {
            _ => ()
          }
        }
      }
      if !quiet {
        print_line("Applied autostash.")
      }
    }
  }
}

///|
async fn pull_eprint_rebase_conflict(
  conflicts : Array[String],
) -> Unit raise Error {
  eprint_line("CONFLICT: Merge conflict in:")
  for path in conflicts {
    eprint_line("  \{path}")
  }
  eprint_line("")
  eprint_line(
    "Resolve all conflicts manually, then run \"git rebase --continue\".",
  )
  eprint_line(
    "To abort and return to the original state, run \"git rebase --abort\".",
  )
  eprint_line("To skip this commit, run \"git rebase --skip\".")
}

///|
async fn pull_create_autostash(
  fs : &@bitcore.FileSystem,
  rfs : &@bitcore.RepoFileSystem,
  root : String,
  git_dir : String,
  author : String,
  timestamp : Int64,
) -> PullAutostashState? raise Error {
  let status = @bitlib.status(rfs, root)
  let state = pull_capture_autostash_state(rfs, root, git_dir, status)
  match @bitlib.stash_push(fs, rfs, root, "autostash", author, timestamp) {
    Some(_) => Some(state)
    None => None
  }
}

///|
fn pull_capture_autostash_state(
  fs : &@bitcore.RepoFileSystem,
  root : String,
  git_dir : String,
  status : @bitlib.Status,
) -> PullAutostashState raise Error {
  let staged_paths : Map[String, Bool] = Map([])
  let worktree_paths : Map[String, Bool] = Map([])
  let deleted_paths : Map[String, Bool] = Map([])
  for path in status.staged_added {
    staged_paths[path] = true
    worktree_paths[path] = true
  }
  for path in status.staged_modified {
    staged_paths[path] = true
    worktree_paths[path] = true
  }
  for path in status.unstaged_modified {
    worktree_paths[path] = true
  }
  for path in status.staged_deleted {
    deleted_paths[path] = true
  }
  for path in status.unstaged_deleted {
    deleted_paths[path] = true
  }
  let index_entries : Array[@bitlib.IndexEntry] = []
  for entry in @bitlib.read_index_entries(fs, git_dir) {
    if staged_paths.contains(entry.path) {
      index_entries.push(entry)
    }
  }
  let worktree_path_list : Array[String] = []
  for path, _ in worktree_paths {
    worktree_path_list.push(path)
  }
  let deleted_path_list : Array[String] = []
  for path, _ in deleted_paths {
    deleted_path_list.push(path)
  }
  {
    index_entries,
    worktree_files: pull_snapshot_worktree_files(fs, root, worktree_path_list),
    deleted_paths: deleted_path_list,
  }
}

///|
fn pull_remote_uses_relay_signaling(remote_url : String) -> Bool {
  remote_url.has_prefix("relay+http://") ||
  remote_url.has_prefix("relay+https://") ||
  remote_url.has_prefix("relay://")
}

///|
fn pull_in_progress_error(
  has_unmerged : Bool,
  has_merge_head : Bool,
) -> String? {
  if has_unmerged {
    Some("Pulling is not possible because you have unmerged files.")
  } else if has_merge_head {
    Some("You have not concluded your merge (MERGE_HEAD exists).")
  } else {
    None
  }
}

///|
fn pull_update_checked_out_head_worktree(
  fs : OsFs,
  git_dir : String,
  root : String,
  new_id : @bitcore.ObjectId,
) -> Unit raise @bitcore.GitError {
  let db = @bitlib.ObjectDb::load(fs, git_dir)
  let files = @bitlib.collect_tree_files_from_commit(db, fs, new_id)
  @bitlib.write_worktree_from_files(
    db,
    fs,
    fs,
    root,
    git_dir,
    files,
    remove_missing=true,
    preserve_removed_gitlinks=true,
  )
  let entries = @bitlib.tree_files_to_index(db, fs, files)
  @bitlib.write_index_entries(fs, git_dir, entries)
}

///|
fn pull_merge_status_exit_code(status : @bitlib.MergeStatus) -> Int {
  match status {
    @bitlib.MergeStatus::Conflicted => 1
    _ => 0
  }
}

///|
fn pull_can_fast_forward_checked_out_head(
  status : @bitlib.Status,
  target_modes : Map[String, Int],
) -> Bool {
  status.staged_added.length() == 0 &&
  status.staged_modified.length() == 0 &&
  status.staged_deleted.length() == 0 &&
  status.unstaged_modified.length() == 0 &&
  status.unstaged_deleted.length() == 0 &&
  pull_collect_initial_conflicting_paths(status, target_modes).length() == 0
}

///|
fn pull_normalize_optional_value(value : String?) -> String? {
  match value {
    Some(raw) => {
      let normalized = raw.trim(chars=" \n\r\t").to_owned()
      if normalized.length() == 0 {
        None
      } else {
        Some(normalized)
      }
    }
    None => None
  }
}

///|
priv struct PullExplicitRefspec {
  fetch_refspecs : Array[String]
  merge_ref : String?
  target_ref : String?
  upstream_ref : String?
}

///|
priv struct PullAutostashState {
  index_entries : Array[@bitlib.IndexEntry]
  worktree_files : Map[String, Bytes]
  deleted_paths : Array[String]
}

///|
fn pull_strip_force_prefix(spec : String) -> String {
  if spec.has_prefix("+") {
    String::unsafe_substring(spec, start=1, end=spec.length())
  } else {
    spec
  }
}

///|
fn pull_normalize_explicit_source_ref(src : String) -> String {
  if src.has_prefix("refs/") {
    src
  } else {
    "refs/heads/" + src
  }
}

///|
fn pull_parse_explicit_refspec(spec : String?) -> PullExplicitRefspec {
  match spec {
    None =>
      {
        fetch_refspecs: [],
        merge_ref: None,
        target_ref: None,
        upstream_ref: None,
      }
    Some(raw_spec) => {
      let parse_spec = pull_strip_force_prefix(raw_spec)
      if parse_spec.find(":") is Some(_) {
        let (src, dst) = @bitlib.parse_refspec_pair(parse_spec)
        let source_ref = if src.length() == 0 {
          None
        } else {
          Some(pull_normalize_explicit_source_ref(src))
        }
        let target_ref = if dst.length() == 0 {
          None
        } else {
          Some(normalize_fetch_destination_ref(dst, source_ref))
        }
        {
          fetch_refspecs: [raw_spec],
          merge_ref: source_ref,
          target_ref,
          upstream_ref: source_ref,
        }
      } else {
        let merge_ref = if parse_spec.has_prefix("refs/") {
          Some(parse_spec)
        } else {
          Some("refs/heads/" + parse_spec)
        }
        {
          fetch_refspecs: [],
          merge_ref,
          target_ref: None,
          upstream_ref: merge_ref,
        }
      }
    }
  }
}

///|
fn pull_collect_initial_conflicting_paths(
  status : @bitlib.Status,
  target_modes : Map[String, Int],
) -> Array[String] {
  let conflicts : Map[String, Bool] = Map([])
  for path in status.untracked {
    if target_modes.contains(path) {
      conflicts[path] = true
    }
  }
  for path in status.staged_added {
    if target_modes.contains(path) {
      conflicts[path] = true
    }
  }
  for path in status.staged_modified {
    if target_modes.contains(path) {
      conflicts[path] = true
    }
  }
  for path in status.staged_deleted {
    if target_modes.contains(path) {
      conflicts[path] = true
    }
  }
  for path in status.unstaged_modified {
    if target_modes.contains(path) {
      conflicts[path] = true
    }
  }
  for path in status.unstaged_deleted {
    if target_modes.contains(path) {
      conflicts[path] = true
    }
  }
  let out = Array::from_iter(conflicts.keys())
  out.sort()
  out
}

///|
fn pull_collect_initial_preserved_index_entries(
  entries : Array[@bitlib.IndexEntry],
  target_modes : Map[String, Int],
) -> Array[@bitlib.IndexEntry] {
  let preserved : Array[@bitlib.IndexEntry] = []
  for entry in entries {
    if !target_modes.contains(entry.path) {
      preserved.push(entry)
    }
  }
  preserved
}

///|
fn pull_parent_dir(path : String) -> String? {
  match path.rev_find("/") {
    Some(idx) if idx > 0 =>
      Some(String::unsafe_substring(path, start=0, end=idx))
    _ => None
  }
}

///|
fn pull_snapshot_worktree_files(
  fs : &@bitcore.RepoFileSystem,
  root : String,
  paths : Array[String],
) -> Map[String, Bytes] {
  let snapshot : Map[String, Bytes] = Map([])
  for path in paths {
    let full_path = root + "/" + path
    if fs.is_file(full_path) {
      snapshot[path] = fs.read_file(full_path) catch { _ => Default::default() }
    }
  }
  snapshot
}

///|
fn pull_restore_initial_checkout_state(
  fs : &@bitcore.RepoFileSystem,
  file_fs : &@bitcore.FileSystem,
  git_dir : String,
  root : String,
  preserved_entries : Array[@bitlib.IndexEntry],
  preserved_files : Map[String, Bytes],
) -> Unit raise Error {
  if preserved_entries.length() > 0 {
    let merged_entries = @bitlib.read_index_entries(fs, git_dir)
    for entry in preserved_entries {
      merged_entries.push(entry)
    }
    @bitlib.write_index_entries(file_fs, git_dir, merged_entries)
  }
  for path, data in preserved_files {
    let full_path = root + "/" + path
    match pull_parent_dir(full_path) {
      Some(parent) => file_fs.mkdir_p(parent)
      None => ()
    }
    file_fs.write_file(full_path, data)
  }
}

///|
fn pull_pre_fetch_validation_error(
  head_is_detached : Bool,
  arg_remote : String?,
  arg_refspec : String?,
  current_branch_remote_cfg : String?,
  current_branch_has_merge : Bool,
  merge_ref : String?,
  has_head : Bool,
) -> String? {
  if head_is_detached && arg_refspec is None {
    Some("You are not currently on a branch.")
  } else if arg_remote is None &&
    arg_refspec is None &&
    current_branch_remote_cfg is Some(_) &&
    !current_branch_has_merge &&
    has_head {
    Some("There is no tracking information for the current branch.")
  } else if arg_remote is Some(_) && merge_ref is None && has_head {
    Some("Please specify a branch on the command line.")
  } else {
    None
  }
}

///|
fn pull_has_wildcard_refspec(refspecs : Array[String]) -> Bool {
  for refspec in refspecs {
    if refspec.contains("*") {
      return true
    }
  }
  false
}

///|
fn pull_missing_target_error_message(
  arg_refspec : String?,
  merge_ref : String?,
  fetch_refspecs : Array[String],
  target_ref : String,
) -> String {
  if arg_refspec is None && merge_ref is Some(merge_target) {
    "Your configuration specifies to merge with the ref '\{merge_target}', but no such ref was fetched."
  } else if pull_has_wildcard_refspec(fetch_refspecs) {
    "There are no candidates for merging among the refs that you just fetched."
  } else {
    "Unknown ref: " + target_ref
  }
}

///|
fn pull_target_ref(
  remote_name : String,
  merge_ref : String?,
  explicit_target_ref : String?,
) -> String {
  match explicit_target_ref {
    Some(r) => r
    None =>
      match merge_ref {
        Some(r) =>
          if r.has_prefix("refs/remotes/") {
            r
          } else if r.has_prefix("refs/heads/") {
            let name = String::unsafe_substring(r, start=11, end=r.length())
            "refs/remotes/" + remote_name + "/" + name
          } else if r.has_prefix("refs/") {
            r
          } else {
            "refs/remotes/" + remote_name + "/" + r
          }
        None => "refs/remotes/" + remote_name + "/HEAD"
      }
  }
}

///|
fn pull_upstream_ref(
  remote_name : String,
  merge_ref : String?,
  explicit_upstream_ref : String?,
) -> String {
  match explicit_upstream_ref {
    Some(r) => r
    None =>
      match merge_ref {
        Some(r) => {
          let remote_prefix = "refs/remotes/" + remote_name + "/"
          if r.has_prefix("refs/heads/") {
            r
          } else if r.has_prefix(remote_prefix) {
            let name = String::unsafe_substring(
              r,
              start=remote_prefix.length(),
              end=r.length(),
            )
            "refs/heads/" + name
          } else if r.has_prefix("refs/") {
            r
          } else {
            "refs/heads/" + r
          }
        }
        None => "HEAD"
      }
  }
}

///|
fn pull_fetch_refspecs(
  explicit_fetch_refspecs : Array[String],
  merge_ref : String?,
  target_ref : String,
) -> Array[String] {
  let refspecs : Array[String] = []
  for refspec in explicit_fetch_refspecs {
    refspecs.push(refspec)
  }
  if refspecs.length() > 0 {
    return refspecs
  }
  match merge_ref {
    Some(refname) =>
      if refname.has_prefix("refs/heads/") {
        refspecs.push(refname + ":" + target_ref)
      }
    None => ()
  }
  refspecs
}

///|
fn pull_reflog_action(args : Array[String]) -> String {
  if args.is_empty() {
    "pull"
  } else {
    "pull " + args.join(" ")
  }
}

///|
fn pull_reflog_identity() -> (String, String) {
  let name = match @sys.get_env_var("GIT_COMMITTER_NAME") {
    Some(n) => n
    None => @sys.get_env_var("USER").unwrap_or("Unknown")
  }
  let email = match @sys.get_env_var("GIT_COMMITTER_EMAIL") {
    Some(e) => e
    None =>
      match @sys.get_env_var("USER") {
        Some(u) => u + "@localhost"
        None => "unknown@localhost"
      }
  }
  (name, email)
}

///|
fn pull_append_fast_forward_reflog(
  fs : &@bitcore.FileSystem,
  rfs : &@bitcore.RepoFileSystem,
  git_dir : String,
  head_target : String,
  old_id : @bitcore.ObjectId,
  new_id : @bitcore.ObjectId,
  args : Array[String],
) -> Unit raise Error {
  let (name, email) = pull_reflog_identity()
  let timestamp = get_commit_timestamp()
  let timezone = get_commit_timezone()
  let message = pull_reflog_action(args) + ": Fast-forward"
  let (should_log_head, _) = @bitlib.should_log_ref(rfs, git_dir, "HEAD", false)
  if should_log_head {
    @bitlib.append_reflog(
      fs, rfs, git_dir, "HEAD", old_id, new_id, name, email, timestamp, timezone,
      message,
    )
  }
  if head_target.has_prefix("refs/heads/") {
    let (should_log_branch, _) = @bitlib.should_log_ref(
      rfs, git_dir, head_target, false,
    )
    if should_log_branch {
      @bitlib.append_reflog(
        fs, rfs, git_dir, head_target, old_id, new_id, name, email, timestamp, timezone,
        message,
      )
    }
  }
}

///|
fn pull_relay_preferred_sender() -> String? {
  pull_normalize_optional_value(@sys.get_env_var("BIT_RELAY_PULL_SENDER"))
}

///|
fn pull_relay_preferred_repo() -> String? {
  pull_normalize_optional_value(@sys.get_env_var("BIT_RELAY_PULL_REPO"))
}

///|
fn pull_select_relay_peer(
  peers : Array[(String, String, String?)],
  preferred_sender~ : String?,
  preferred_repo~ : String?,
) -> (String, String)? {
  match preferred_sender {
    Some(target_sender) =>
      for peer in peers {
        let (sender, fetch_url, _repo) = peer
        if sender == target_sender {
          return Some((sender, fetch_url))
        }
      }
    None => ()
  }
  match preferred_repo {
    Some(target_repo) =>
      for peer in peers {
        let (sender, fetch_url, repo) = peer
        if repo == Some(target_repo) {
          return Some((sender, fetch_url))
        }
      }
    None => ()
  }
  if peers.length() == 0 {
    None
  } else {
    let (sender, fetch_url, _repo) = peers[0]
    Some((sender, fetch_url))
  }
}

///|
async fn resolve_pull_remote_via_relay(
  relay_remote_url : String,
  preferred_sender~ : String?,
  preferred_repo~ : String?,
) -> (String, String) raise Error {
  let peers = @hub_native.relay_list_clone_peers(
    relay_remote_url,
    auth_token=None,
  )
  guard pull_select_relay_peer(peers, preferred_sender~, preferred_repo~)
    is Some((sender, fetch_url)) else {
    raise @bitcore.GitError::InvalidObject(
      "No pull peers announced via relay: \{relay_remote_url}",
    )
  }
  (sender, fetch_url)
}

///|
enum PushDefaultMode {
  Upstream
  Current
  Matching
  Simple
  Nothing
}

///|
struct PushTargetPlan {
  remote_name : String
  source_ref : String
  dest_ref : String
  auto_set_upstream : Bool
  delete_ref : Bool
}

///|
enum PushSourceKind {
  Branch
  Tag
  Other
}

///|
struct PushRefPlan {
  source_ref : String
  dest_ref : String
  delete_ref : Bool
  force : Bool
}

///|
struct PushParsedRefspec {
  force : Bool
  src : String
  dst : String
  has_explicit_destination : Bool
}

///|
struct PushPorcelainLine {
  flag : String
  src : String
  dst : String
  status : String
}

///|
fn format_push_porcelain_line(
  flag : String,
  src : String,
  dst : String,
  status : String,
) -> String {
  flag + "\t" + src + ":" + dst + "\t" + status
}

///|
fn classify_push_porcelain_success(
  old_id : @bitcore.ObjectId,
  new_id : @bitcore.ObjectId,
  delete_ref : Bool,
  force_update : Bool,
) -> (String, String) {
  if delete_ref {
    if old_id == @bitcore.ObjectId::zero() {
      ("=", "[up to date]")
    } else {
      ("-", "[deleted]")
    }
  } else if old_id == new_id {
    ("=", "[up to date]")
  } else if old_id == @bitcore.ObjectId::zero() {
    ("*", "[new reference]")
  } else if force_update {
    ("+", "[forced update]")
  } else {
    (" ", "[updated]")
  }
}

///|
fn select_push_rejection_status(
  non_fast_forward : Bool,
  tag_conflict : Bool,
  deny_current_branch : Bool,
  hidden_ref : Bool,
) -> String? {
  if hidden_ref {
    Some("[remote rejected] (deny updating a hidden ref)")
  } else if non_fast_forward {
    Some("[rejected] (non-fast-forward)")
  } else if tag_conflict {
    Some("[rejected] (already exists)")
  } else if deny_current_branch {
    Some("[remote rejected] (branch is currently checked out)")
  } else {
    None
  }
}

///|
fn hidden_pattern_matches_ref(refname : String, pattern : String) -> Bool {
  if pattern.length() == 0 {
    return false
  }
  if pattern.has_suffix("/") {
    return refname.has_prefix(pattern)
  }
  refname == pattern || refname.has_prefix(pattern + "/")
}

///|
fn is_hidden_ref(refname : String, patterns : Array[String]) -> Bool {
  let mut hidden = false
  for raw_pattern in patterns {
    let pattern = trim_string(raw_pattern)
    if pattern.length() == 0 {
      continue
    }
    if pattern.has_prefix("!") {
      let unhide_pattern = String::unsafe_substring(
        pattern,
        start=1,
        end=pattern.length(),
      )
      if hidden_pattern_matches_ref(refname, unhide_pattern) {
        hidden = false
      }
      continue
    }
    if hidden_pattern_matches_ref(refname, pattern) {
      hidden = true
    }
  }
  hidden
}

///|
fn read_config_values(
  fs : &@bitcore.RepoFileSystem,
  git_dir : String,
  section : String,
  key : String,
) -> Array[String] {
  let values : Array[String] = []
  let config_path = git_dir + "/config"
  if !fs.is_file(config_path) {
    return values
  }
  let content = decode_bytes(
    fs.read_file(config_path) catch {
      _ => Default::default()
    },
  )
  let section_lower = section.to_lower()
  let key_lower = key.to_lower()
  let blocks = @bitlib.parse_config_blocks(content)
  for block in blocks {
    if block.section != Some(section_lower) {
      continue
    }
    for line in block.lines {
      match @bitlib.parse_config_kv(line) {
        Some((parsed_key, parsed_value)) =>
          if parsed_key == key_lower {
            values.push(parsed_value)
          }
        None => ()
      }
    }
  }
  values
}

///|
fn read_hide_refs(
  fs : &@bitcore.RepoFileSystem,
  git_dir : String,
  sections : Array[String],
) -> Array[String] {
  let patterns : Array[String] = []
  for section in sections {
    let values = read_config_values(fs, git_dir, section, "hiderefs")
    for value in values {
      patterns.push(value)
    }
  }
  patterns
}

///|
fn prune_source_ref_for_destination(
  src_pattern : String,
  dst_pattern : String,
  dst_ref : String,
) -> String? {
  @bitlib.refspec_map_dst(dst_pattern, src_pattern, dst_ref)
}

///|
fn parse_push_default_mode(value : String?) -> PushDefaultMode {
  match value {
    Some(v) =>
      match v.to_lower() {
        "upstream" => PushDefaultMode::Upstream
        "current" => PushDefaultMode::Current
        "matching" => PushDefaultMode::Matching
        "nothing" => PushDefaultMode::Nothing
        _ => PushDefaultMode::Simple
      }
    None => PushDefaultMode::Simple
  }
}

///|
fn resolve_remote_push_refmap_destination(
  source_token : String,
  source_ref : String,
  current_branch : String,
  remote_push_specs : Array[String],
) -> String? {
  let source_candidates = fetch_source_candidates(source_token)
  if !source_candidates.contains(source_ref) {
    source_candidates.push(source_ref)
  }
  if source_ref == "HEAD" {
    let current_ref = "refs/heads/" + current_branch
    if !source_candidates.contains(current_ref) {
      source_candidates.push(current_ref)
    }
  }
  let parsed_specs = @bitlib.parse_push_refspecs(remote_push_specs)
  for spec in parsed_specs {
    if spec.src.length() == 0 || spec.dst.length() == 0 {
      continue
    }
    for source_candidate in source_candidates {
      match @bitlib.refspec_map_dst(spec.src, spec.dst, source_candidate) {
        Some(mapped) => return Some(mapped)
        None => ()
      }
    }
  }
  None
}

///|
fn infer_colonless_push_destination_token(
  source_token : String,
  source_ref : String,
  source_kind : PushSourceKind,
  current_branch : String,
  push_default_mode : PushDefaultMode,
  branch_merge : String?,
  remote_push_specs : Array[String],
) -> String {
  match
    resolve_remote_push_refmap_destination(
      source_token, source_ref, current_branch, remote_push_specs,
    ) {
    Some(mapped) => mapped
    None => {
      let source_is_current_branch = source_ref == "HEAD" ||
        source_ref == "refs/heads/" + current_branch
      let source_is_branch = match source_kind {
        PushSourceKind::Branch => true
        _ => false
      }
      let mode_is_upstream = match push_default_mode {
        PushDefaultMode::Upstream => true
        _ => false
      }
      if mode_is_upstream && source_is_branch && source_is_current_branch {
        match branch_merge {
          Some(merge_ref) => merge_ref
          None => source_token
        }
      } else {
        source_token
      }
    }
  }
}

///|
fn parse_config_bool_string(value : String?) -> Bool {
  match value {
    Some(v) => {
      let lower = v.to_lower()
      lower == "true" || lower == "1" || lower == "yes"
    }
    None => false
  }
}

///|
fn looks_like_object_id(token : String) -> Bool {
  ignore(@bitcore.ObjectId::from_hex(token) catch { _ => return false })
  true
}

///|
fn fetch_source_candidates(source : String) -> Array[String] {
  let candidates : Array[String] = [source]
  if source.length() == 0 ||
    source.contains("*") ||
    source.has_prefix("refs/") ||
    source == "HEAD" ||
    source == "@" ||
    looks_like_object_id(source) {
    return candidates
  }
  candidates.push("refs/heads/" + source)
  candidates.push("refs/tags/" + source)
  candidates
}

///|
fn normalize_push_ref_token(
  token : String,
  current_branch : String,
  for_destination : Bool,
) -> String {
  if token == "HEAD" || token == "@" {
    if for_destination {
      "refs/heads/" + current_branch
    } else {
      "HEAD"
    }
  } else if token.has_prefix("refs/") {
    token
  } else if !for_destination &&
    (token.contains("^") || token.contains("~") || looks_like_object_id(token)) {
    token
  } else {
    "refs/heads/" + token
  }
}

///|
fn select_current_like_remote(
  remotes : Array[String],
  branch_remote : String?,
  remote_pushdefault : String?,
) -> String raise @bitcore.GitError {
  match remote_pushdefault {
    Some(name) => name
    None =>
      match branch_remote {
        Some(name) => name
        None =>
          if remotes.length() == 1 {
            remotes[0]
          } else if remotes.contains("origin") {
            "origin"
          } else {
            raise @bitcore.GitError::InvalidObject("No such remote: origin")
          }
      }
  }
}

///|
fn parse_remote_helper_url(url : String) -> (String, String)? {
  match url.find("::") {
    Some(idx) =>
      if idx == 0 || idx + 2 >= url.length() {
        None
      } else {
        Some(
          (
            String::unsafe_substring(url, start=0, end=idx),
            String::unsafe_substring(url, start=idx + 2, end=url.length()),
          ),
        )
      }
    None => None
  }
}

///|
fn read_url_rewrite_rules(
  fs : &@bitcore.RepoFileSystem,
  git_dir : String,
) -> Array[(String, String, Bool)] {
  let config_path = git_dir + "/config"
  let rules : Array[(String, String, Bool)] = []
  if !fs.is_file(config_path) {
    return rules
  }
  let content = decode_bytes(
    fs.read_file(config_path) catch {
      _ => Default::default()
    },
  )
  let blocks = @bitlib.parse_config_blocks(content)
  for block in blocks {
    if block.section != Some("url") {
      continue
    }
    guard block.name is Some(base) else { continue }
    for line in block.lines {
      match @bitlib.parse_config_kv(line) {
        Some((key, value)) =>
          if key == "insteadof" {
            rules.push((base, value, false))
          } else if key == "pushinsteadof" {
            rules.push((base, value, true))
          }
        None => ()
      }
    }
  }
  rules
}

///|
fn rewrite_url_by_rules(
  url : String,
  rules : Array[(String, String, Bool)],
  for_push : Bool,
) -> String {
  let mut best_base : String? = None
  let mut best_prefix_len = -1
  let mut best_push_only = false
  for i in 0..<rules.length() {
    let (base, prefix, push_only) = rules[i]
    if push_only && !for_push {
      continue
    }
    if !url.has_prefix(prefix) {
      continue
    }
    let prefix_len = prefix.length()
    if prefix_len > best_prefix_len ||
      (prefix_len == best_prefix_len && push_only && !best_push_only) {
      best_base = Some(base)
      best_prefix_len = prefix_len
      best_push_only = push_only
    }
  }
  match best_base {
    Some(base) =>
      if best_prefix_len < 0 || best_prefix_len >= url.length() {
        base
      } else {
        base +
        String::unsafe_substring(url, start=best_prefix_len, end=url.length())
      }
    None => url
  }
}

///|
fn branch_name_from_head_ref(refname : String) -> String? {
  if refname.has_prefix("refs/heads/") {
    Some(String::unsafe_substring(refname, start=11, end=refname.length()))
  } else {
    None
  }
}

///|
fn resolve_push_target_plan(
  explicit_remote : String?,
  explicit_refspec : String?,
  current_branch : String,
  remotes : Array[String],
  branch_remote : String?,
  branch_merge : String?,
  push_default : String?,
  remote_pushdefault : String?,
  auto_setup_remote : Bool,
) -> PushTargetPlan raise @bitcore.GitError {
  let mode = parse_push_default_mode(push_default)
  let mode_is_upstream = match mode {
    PushDefaultMode::Upstream => true
    _ => false
  }
  let mode_is_nothing = match mode {
    PushDefaultMode::Nothing => true
    _ => false
  }
  let current_ref = "refs/heads/" + current_branch
  let triangular = match (remote_pushdefault, branch_remote) {
    (Some(pushdefault), Some(upstream_remote)) => pushdefault != upstream_remote
    _ => false
  }
  if explicit_refspec is Some(spec) {
    let remote_name = match explicit_remote {
      Some(name) => name
      None =>
        match mode {
          PushDefaultMode::Upstream =>
            match branch_remote {
              Some(name) => name
              None =>
                raise @bitcore.GitError::InvalidObject(
                  "No upstream configured for current branch",
                )
            }
          PushDefaultMode::Simple if !triangular =>
            match branch_remote {
              Some(name) => name
              None =>
                raise @bitcore.GitError::InvalidObject(
                  "No upstream configured for current branch",
                )
            }
          PushDefaultMode::Nothing =>
            raise @bitcore.GitError::InvalidObject(
              "push.default is set to nothing; specify a refspec",
            )
          _ =>
            select_current_like_remote(
              remotes, branch_remote, remote_pushdefault,
            )
        }
    }
    if mode_is_upstream &&
      explicit_remote is Some(requested) &&
      branch_remote is Some(upstream_remote) &&
      requested != upstream_remote {
      raise @bitcore.GitError::InvalidObject(
        "Cannot push to remote '\{requested}' because branch tracks '\{upstream_remote}'",
      )
    }
    let (raw_src_raw, raw_dst) = @bitlib.parse_refspec_pair(spec)
    let raw_src = strip_push_force_prefix(raw_src_raw)
    if raw_src.length() == 0 && raw_dst.length() == 0 {
      return {
        remote_name,
        source_ref: current_ref,
        dest_ref: current_ref,
        auto_set_upstream: false,
        delete_ref: false,
      }
    }
    if looks_like_object_id(raw_src) &&
      raw_dst.length() > 0 &&
      !raw_dst.has_prefix("refs/") {
      raise @bitcore.GitError::InvalidObject(
        "Cannot infer destination ref from source object id",
      )
    }
    if raw_src.length() == 0 && raw_dst.length() > 0 {
      let dest_ref = normalize_push_ref_token(raw_dst, current_branch, true)
      return {
        remote_name,
        source_ref: "",
        dest_ref,
        auto_set_upstream: false,
        delete_ref: true,
      }
    }
    guard raw_src.length() > 0 else {
      raise @bitcore.GitError::InvalidObject(
        "Perhaps you should specify a branch.",
      )
    }
    let source_ref = normalize_push_ref_token(raw_src, current_branch, false)
    let dest_ref = if raw_dst.length() == 0 {
      normalize_push_ref_token(raw_src, current_branch, true)
    } else {
      normalize_push_ref_token(raw_dst, current_branch, true)
    }
    return {
      remote_name,
      source_ref,
      dest_ref,
      auto_set_upstream: false,
      delete_ref: false,
    }
  }
  if mode_is_nothing {
    raise @bitcore.GitError::InvalidObject(
      "push.default is set to nothing; specify a refspec",
    )
  }
  if mode_is_upstream && explicit_remote is None && triangular {
    raise @bitcore.GitError::InvalidObject(
      "Cannot use upstream push.default in triangular workflow",
    )
  }
  let remote_name = match explicit_remote {
    Some(name) => name
    None =>
      match mode {
        PushDefaultMode::Upstream =>
          match branch_remote {
            Some(name) => name
            None =>
              raise @bitcore.GitError::InvalidObject(
                "No upstream configured for current branch",
              )
          }
        PushDefaultMode::Simple if !triangular =>
          match branch_remote {
            Some(name) => name
            None =>
              raise @bitcore.GitError::InvalidObject(
                "No upstream configured for current branch",
              )
          }
        _ =>
          select_current_like_remote(remotes, branch_remote, remote_pushdefault)
      }
  }
  if mode_is_upstream &&
    explicit_remote is Some(requested) &&
    branch_remote is Some(upstream_remote) &&
    requested != upstream_remote {
    raise @bitcore.GitError::InvalidObject(
      "Cannot push to remote '\{requested}' because branch tracks '\{upstream_remote}'",
    )
  }
  let mut dest_ref = current_ref
  let mut auto_set_upstream_needed = false
  match mode {
    PushDefaultMode::Upstream =>
      match branch_merge {
        Some(merge_ref) => dest_ref = merge_ref
        None =>
          if auto_setup_remote && branch_remote is Some(_) {
            auto_set_upstream_needed = true
          } else {
            raise @bitcore.GitError::InvalidObject(
              "No upstream configured for current branch",
            )
          }
      }
    PushDefaultMode::Simple =>
      if triangular && explicit_remote is None {
        dest_ref = current_ref
      } else {
        match branch_merge {
          Some(merge_ref) =>
            if merge_ref != current_ref {
              raise @bitcore.GitError::InvalidObject(
                "Simple push requires upstream branch name to match current branch",
              )
            } else {
              dest_ref = merge_ref
            }
          None =>
            if auto_setup_remote && branch_remote is Some(_) {
              auto_set_upstream_needed = true
            } else {
              raise @bitcore.GitError::InvalidObject(
                "No upstream configured for current branch",
              )
            }
        }
      }
    PushDefaultMode::Matching =>
      if branch_merge is None {
        raise @bitcore.GitError::InvalidObject(
          "Perhaps you should specify a branch.",
        )
      }
    _ => ()
  }
  {
    remote_name,
    source_ref: current_ref,
    dest_ref,
    auto_set_upstream: auto_set_upstream_needed,
    delete_ref: false,
  }
}

///|
fn resolve_push_positionals(
  positionals : Array[String],
  is_known_remote : (String) -> Bool,
) -> (String?, String?) {
  if positionals.length() == 0 {
    (None, None)
  } else if positionals.length() == 1 {
    let first = positionals[0]
    if is_known_remote(first) {
      (Some(first), None)
    } else {
      (None, Some(first))
    }
  } else {
    (Some(positionals[0]), Some(positionals[positionals.length() - 1]))
  }
}

///|
fn resolve_push_positionals_multi(
  positionals : Array[String],
  is_known_remote : (String) -> Bool,
) -> (String?, Array[String]) {
  if positionals.length() == 0 {
    (None, [])
  } else if positionals.length() == 1 {
    let first = positionals[0]
    if is_known_remote(first) {
      (Some(first), [])
    } else {
      (None, [first])
    }
  } else {
    let refspecs : Array[String] = []
    for i in 1..<positionals.length() {
      refspecs.push(positionals[i])
    }
    (Some(positionals[0]), refspecs)
  }
}

///|
fn parse_push_refspecs_with_presence(
  specs : Array[String],
) -> Array[PushParsedRefspec] {
  let out : Array[PushParsedRefspec] = []
  for raw in specs {
    let mut force = false
    let mut value = raw
    if value.has_prefix("+") {
      force = true
      value = String::unsafe_substring(value, start=1, end=value.length())
    }
    let has_explicit_destination = value.find(":") is Some(_)
    let (src, dst) = @bitlib.parse_refspec_pair(value)
    out.push({ force, src, dst, has_explicit_destination })
  }
  out
}

///|
fn ensure_matching_refspec_has_candidates(
  parsed_specs : Array[PushParsedRefspec],
  plan_count : Int,
) -> Unit raise @bitcore.GitError {
  if plan_count > 0 {
    return ()
  }
  for spec in parsed_specs {
    if spec.src.length() == 0 && spec.dst.length() == 0 {
      raise @bitcore.GitError::InvalidObject(
        "Perhaps you should specify a branch.",
      )
    }
  }
}

///|
fn strip_push_force_prefix(source_spec : String) -> String {
  if source_spec.has_prefix("+") {
    String::unsafe_substring(source_spec, start=1, end=source_spec.length())
  } else {
    source_spec
  }
}

///|
fn option_name_without_prefix(arg : String) -> String {
  if arg.has_prefix("--") {
    String::unsafe_substring(arg, start=2, end=arg.length())
  } else if arg.has_prefix("-") {
    String::unsafe_substring(arg, start=1, end=arg.length())
  } else {
    arg
  }
}

///|
fn is_ambiguous_push_source_refspec(
  source_spec : String,
  has_head_ref : Bool,
  has_tag_ref : Bool,
) -> Bool {
  if source_spec.length() == 0 ||
    source_spec == "HEAD" ||
    source_spec == "@" ||
    source_spec.has_prefix("refs/") ||
    source_spec.contains("^") ||
    source_spec.contains("~") ||
    source_spec.contains(":") {
    false
  } else {
    has_head_ref && has_tag_ref
  }
}

///|
fn resolve_push_source_ref(
  fs : &@bitcore.RepoFileSystem,
  git_dir : String,
  source_token : String,
) -> (String, PushSourceKind) raise @bitcore.GitError {
  if source_token == "HEAD" || source_token == "@" {
    ("HEAD", PushSourceKind::Branch)
  } else if source_token.has_prefix("refs/") {
    if source_token.has_prefix("refs/tags/") {
      (source_token, PushSourceKind::Tag)
    } else if source_token.has_prefix("refs/heads/") {
      (source_token, PushSourceKind::Branch)
    } else {
      (source_token, PushSourceKind::Other)
    }
  } else if source_token.contains("^") ||
    source_token.contains("~") ||
    looks_like_object_id(source_token) {
    (source_token, PushSourceKind::Other)
  } else {
    let branch_ref = "refs/heads/" + source_token
    if @bitlib.resolve_ref(fs, git_dir, branch_ref) is Some(_) {
      (branch_ref, PushSourceKind::Branch)
    } else {
      let tag_ref = "refs/tags/" + source_token
      if @bitlib.resolve_ref(fs, git_dir, tag_ref) is Some(_) {
        (tag_ref, PushSourceKind::Tag)
      } else {
        ("refs/heads/" + source_token, PushSourceKind::Branch)
      }
    }
  }
}

///|
fn resolve_push_source_id(
  fs : &@bitcore.RepoFileSystem,
  git_dir : String,
  source_ref : String,
) -> @bitcore.ObjectId raise @bitcore.GitError {
  match source_ref {
    "HEAD" =>
      match @bitlib.resolve_head_commit(fs, git_dir) {
        Some(id) => id
        None => raise @bitcore.GitError::InvalidObject("HEAD not found")
      }
    _ =>
      match @bitlib.resolve_ref(fs, git_dir, source_ref) {
        Some(id) => id
        None =>
          match @bitrepo.rev_parse(fs, git_dir, source_ref) {
            Some(id) => id
            None =>
              if looks_like_object_id(source_ref) {
                @bitcore.ObjectId::from_hex(source_ref) catch {
                  _ =>
                    raise @bitcore.GitError::InvalidObject(
                      "Cannot resolve source ref: " + source_ref,
                    )
                }
              } else {
                raise @bitcore.GitError::InvalidObject(
                  "Cannot resolve source ref: " + source_ref,
                )
              }
          }
      }
  }
}

///|
fn is_invalid_push_destination_refname(
  refname : String,
  allow_onelevel : Bool,
) -> Bool {
  if !refname.has_prefix("refs/") {
    return true
  }
  let rest = String::unsafe_substring(refname, start=5, end=refname.length())
  if rest.length() == 0 || rest.has_suffix("/") {
    return true
  }
  if !allow_onelevel && !rest.contains("/") {
    return true
  }
  false
}

///|
fn resolve_push_destination_ref(
  fs : &@bitcore.RepoFileSystem,
  remote_git_dir : String,
  source_kind : PushSourceKind,
  destination_token : String,
  current_branch : String,
  allow_onelevel : Bool,
  prefer_source_kind : Bool,
) -> String raise @bitcore.GitError {
  if destination_token == "HEAD" || destination_token == "@" {
    return "refs/heads/" + current_branch
  }
  if destination_token.has_prefix("refs/") {
    if is_invalid_push_destination_refname(destination_token, allow_onelevel) {
      raise @bitcore.GitError::InvalidObject(
        "Invalid refspec destination: " + destination_token,
      )
    }
    return destination_token
  }
  let candidate_heads = "refs/heads/" + destination_token
  let candidate_tags = "refs/tags/" + destination_token
  let candidate_remotes = "refs/remotes/" + destination_token
  let matched : Array[String] = []
  if @bitlib.resolve_ref(fs, remote_git_dir, candidate_heads) is Some(_) {
    matched.push(candidate_heads)
  }
  if @bitlib.resolve_ref(fs, remote_git_dir, candidate_tags) is Some(_) {
    matched.push(candidate_tags)
  }
  if @bitlib.resolve_ref(fs, remote_git_dir, candidate_remotes) is Some(_) {
    matched.push(candidate_remotes)
  }
  if matched.length() > 1 {
    if prefer_source_kind {
      match source_kind {
        PushSourceKind::Branch =>
          if matched.contains(candidate_heads) {
            return candidate_heads
          }
        PushSourceKind::Tag =>
          if matched.contains(candidate_tags) {
            return candidate_tags
          }
        _ => ()
      }
    }
    raise @bitcore.GitError::InvalidObject(
      "dst refspec '\{destination_token}' matches more than one",
    )
  }
  if matched.length() == 1 {
    return matched[0]
  }
  match source_kind {
    PushSourceKind::Tag => candidate_tags
    _ => candidate_heads
  }
}

///|
fn read_branch_pushremote(
  fs : &@bitcore.RepoFileSystem,
  git_dir : String,
  branch_name : String,
) -> String? {
  let content = @bitlib.read_config_content(fs, git_dir)
  let blocks = @bitlib.parse_config_blocks(content)
  for block in blocks {
    if block.section != Some("branch") || block.name != Some(branch_name) {
      continue
    }
    for line in block.lines {
      match @bitlib.parse_config_kv(line) {
        Some((key, value)) if key == "pushremote" => return Some(value)
        _ => ()
      }
    }
  }
  None
}

///|
fn ensure_no_empty_branch_config(
  fs : &@bitcore.FileSystem,
  rfs : &@bitcore.RepoFileSystem,
  git_dir : String,
) -> Unit raise @bitcore.GitError {
  let content = @bitlib.read_config_content(rfs, git_dir)
  let blocks = @bitlib.parse_config_blocks(content)
  let filtered : Array[@bitlib.ConfigBlock] = []
  let mut found_invalid = false
  for block in blocks {
    if block.section == Some("branch") && block.name == Some("") {
      found_invalid = true
      continue
    }
    filtered.push(block)
  }
  if found_invalid {
    let config_path = git_dir + "/config"
    fs.write_string(config_path, @bitlib.render_config_blocks(filtered))
    raise @bitcore.GitError::InvalidObject("bad config variable .branch..")
  }
}

///|
enum DenyCurrentBranchDecision {
  Allow
  Warn
  UpdateInstead(String)
}

///|
fn enforce_receive_deny_current_branch(
  deny_current_branch : String?,
  checked_out_worktree : String?,
  dest_ref : String,
) -> DenyCurrentBranchDecision raise @bitcore.GitError {
  guard checked_out_worktree is Some(worktree_path) else {
    return DenyCurrentBranchDecision::Allow
  }
  match deny_current_branch {
    Some(mode) =>
      if mode == "false" || mode == "ignore" {
        DenyCurrentBranchDecision::Allow
      } else if mode == "warn" {
        DenyCurrentBranchDecision::Warn
      } else if mode == "updateinstead" {
        DenyCurrentBranchDecision::UpdateInstead(worktree_path)
      } else {
        raise @bitcore.GitError::InvalidObject(
          "refusing to update checked out branch: " + dest_ref,
        )
      }
    None =>
      raise @bitcore.GitError::InvalidObject(
        "refusing to update checked out branch: " + dest_ref,
      )
  }
}

///|
struct PushResolvedUpdate {
  old_id : @bitcore.ObjectId
  new_id : @bitcore.ObjectId
  refname : String
  delete_ref : Bool
  should_apply : Bool
  force_update : Bool
  update_instead_worktree : String?
}

///|
fn is_invalid_nonexistent_delete(row : PushResolvedUpdate) -> Bool {
  row.delete_ref &&
  row.old_id == @bitcore.ObjectId::zero() &&
  row.new_id == @bitcore.ObjectId::zero()
}

///|
fn resolve_ref_canonical_name_inner(
  fs : &@bitcore.RepoFileSystem,
  git_dir : String,
  refname : String,
  depth : Int,
) -> String {
  if depth > 8 {
    return refname
  }
  let normalized = if refname == "HEAD" {
    "HEAD"
  } else {
    let normalized = @bitlib.normalize_repo_path(refname) catch {
      _ => return refname
    }
    if normalized.has_prefix("refs/") {
      normalized
    } else {
      return refname
    }
  }
  let path = git_dir + "/" + normalized
  if !fs.is_file(path) {
    return normalized
  }
  let line = decode_bytes(fs.read_file(path) catch { _ => return normalized })
    .trim()
    .to_owned()
  if !line.has_prefix("ref: ") {
    return normalized
  }
  let target = String::unsafe_substring(line, start=5, end=line.length())
  resolve_ref_canonical_name_inner(fs, git_dir, target, depth + 1)
}

///|
fn resolve_ref_canonical_name(
  fs : &@bitcore.RepoFileSystem,
  git_dir : String,
  refname : String,
) -> String {
  resolve_ref_canonical_name_inner(fs, git_dir, refname, 0)
}

///|
fn ensure_consistent_alias_updates(
  fs : &@bitcore.RepoFileSystem,
  git_dir : String,
  rows : Array[PushResolvedUpdate],
) -> Unit raise @bitcore.GitError {
  let canonical_updates : Map[String, (@bitcore.ObjectId, String)] = Map([])
  for row in rows {
    let canonical = resolve_ref_canonical_name(fs, git_dir, row.refname)
    match canonical_updates.get(canonical) {
      Some((known_id, known_refname)) =>
        if known_id != row.new_id {
          raise @bitcore.GitError::InvalidObject(
            "refusing inconsistent update: " +
            known_refname +
            " and " +
            row.refname,
          )
        }
      None => canonical_updates[canonical] = (row.new_id, row.refname)
    }
  }
}

///|
fn order_pre_receive_rows(
  rows : Array[PushResolvedUpdate],
) -> Array[PushResolvedUpdate] {
  let existing_or_nondelete : Array[PushResolvedUpdate] = []
  let nonexistent_deletes : Array[PushResolvedUpdate] = []
  for row in rows {
    if is_invalid_nonexistent_delete(row) {
      nonexistent_deletes.push(row)
    } else {
      existing_or_nondelete.push(row)
    }
  }
  existing_or_nondelete.sort_by(fn(a, b) { a.refname.compare(b.refname) })
  let ordered : Array[PushResolvedUpdate] = []
  for row in existing_or_nondelete {
    ordered.push(row)
  }
  for row in nonexistent_deletes {
    ordered.push(row)
  }
  ordered
}

///|
fn order_update_rows(
  rows : Array[PushResolvedUpdate],
) -> Array[PushResolvedUpdate] {
  let deletes : Array[PushResolvedUpdate] = []
  let updates : Array[PushResolvedUpdate] = []
  for row in rows {
    if row.delete_ref {
      deletes.push(row)
    } else {
      updates.push(row)
    }
  }
  let ordered : Array[PushResolvedUpdate] = []
  for row in deletes {
    ordered.push(row)
  }
  for row in updates {
    ordered.push(row)
  }
  ordered
}

///|
fn format_push_hook_line(row : PushResolvedUpdate) -> String {
  row.old_id.to_hex() + " " + row.new_id.to_hex() + " " + row.refname
}

///|
fn resolve_push_hook_git_dir(git_dir : String) -> String {
  if git_dir.has_prefix("/") {
    return git_dir
  }
  let cwd = match @env.current_dir() {
    Some(dir) => dir
    None => "."
  }
  normalize_path(cwd + "/" + git_dir)
}

///|
async fn run_push_hook_with_stdin(
  fs : OsFs,
  git_dir : String,
  hook_name : String,
  lines : Array[String],
) -> Int {
  let hook_git_dir = resolve_push_hook_git_dir(git_dir)
  let hook_path = hook_git_dir + "/hooks/" + hook_name
  if !fs.is_file(hook_path) {
    return 0
  }
  let stdin_path = hook_git_dir +
    "/hooks/.bit-" +
    hook_name +
    "-" +
    @async.now().to_string() +
    ".stdin"
  let text = if lines.length() > 0 { lines.join("\n") + "\n" } else { "" }
  fs.write_string(stdin_path, text) catch {
    _ => return 1
  }
  let stdin = @process.redirect_from_file(stdin_path) catch {
    _ => {
      fs.remove_file(stdin_path) catch {
        _ => ()
      }
      return 1
    }
  }
  let code = @process.run(
    hook_path,
    [],
    inherit_env=true,
    stdin~,
    cwd=hook_git_dir,
  ) catch {
    _ => 1
  }
  fs.remove_file(stdin_path) catch {
    _ => ()
  }
  code
}

///|
async fn run_push_hook_with_args(
  fs : OsFs,
  git_dir : String,
  hook_name : String,
  args : Array[String],
) -> Int {
  let hook_git_dir = resolve_push_hook_git_dir(git_dir)
  run_hook(fs, hook_git_dir, hook_git_dir, hook_name, hook_git_dir, args~)
}

///|
fn is_worktree_status_clean(status : @bitlib.Status) -> Bool {
  status.staged_added.length() == 0 &&
  status.staged_modified.length() == 0 &&
  status.staged_deleted.length() == 0 &&
  status.unstaged_modified.length() == 0 &&
  status.unstaged_deleted.length() == 0 &&
  status.untracked.length() == 0
}

///|
async fn apply_update_instead_worktree(
  fs : OsFs,
  repo_git_dir : String,
  worktree_path : String,
  new_id : @bitcore.ObjectId,
) -> Unit raise @bitcore.GitError {
  let status = @bitlib.status(fs, worktree_path)
  if !is_worktree_status_clean(status) {
    raise @bitcore.GitError::InvalidObject("working tree has pending changes")
  }
  let worktree_git_dir = match @bitlib.detect_git_dir(fs, worktree_path) {
    Some((dir, _)) => dir
    None => repo_git_dir
  }
  let db = @bitlib.ObjectDb::load(fs, repo_git_dir)
  let files = @bitlib.collect_tree_files_from_commit(db, fs, new_id)
  @bitlib.write_worktree_from_files(
    db,
    fs,
    fs,
    worktree_path,
    worktree_git_dir,
    files,
    remove_missing=true,
  )
  let entries = @bitlib.tree_files_to_index(db, fs, files)
  @bitlib.write_index_entries(fs, worktree_git_dir, entries)
}

///|
async fn run_push_to_checkout_hook(
  fs : OsFs,
  git_dir : String,
  worktree_path : String,
  new_id : @bitcore.ObjectId,
) -> Int {
  let hook_git_dir = resolve_push_hook_git_dir(git_dir)
  let hook_path = hook_git_dir + "/hooks/push-to-checkout"
  if !fs.is_file(hook_path) {
    return -1
  }
  let worktree_git_dir = match @bitlib.detect_git_dir(fs, worktree_path) {
    Some((dir, _)) => resolve_push_hook_git_dir(dir)
    None => hook_git_dir
  }
  let extra_env : Map[String, String] = Map([])
  extra_env["GIT_SHIM_PWD"] = worktree_path
  extra_env["GIT_SHIM_CWD"] = worktree_path
  extra_env["GIT_DIR"] = worktree_git_dir
  extra_env["GIT_WORK_TREE"] = worktree_path
  extra_env["GIT_COMMON_DIR"] = hook_git_dir
  let code = @process.run(
    hook_path,
    [new_id.to_hex()],
    extra_env~,
    inherit_env=true,
    cwd=worktree_path,
  ) catch {
    _ => 1
  }
  code
}

///|

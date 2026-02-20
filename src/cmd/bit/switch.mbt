///|
async fn handle_switch(args : Array[String]) -> Unit raise Error {
  let root = get_work_root()
  let fs = OsFs::new()
  let rfs : &@bitcore.RepoFileSystem = fs
  let git_dir = resolve_git_dir(rfs, root)
  if fs.is_file(git_dir + "/MERGE_HEAD") {
    eprint_line("fatal: cannot switch branch while merging")
    @sys.exit(1)
  }
  let mut branch : String? = None
  let mut branch_from_option = false
  let mut create = false
  let mut force_create = false
  let mut detach = false
  let mut orphan = false
  let mut discard_changes = false
  let mut ignore_other_worktrees = false
  let mut track_mode : String? = None
  let mut guess_mode : Bool? = None
  let positional : Array[String] = []
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    match arg {
      "-c" | "--create" => {
        create = true
        force_create = false
        if i + 1 < args.length() && not(args[i + 1].has_prefix("-")) {
          branch = Some(args[i + 1])
          branch_from_option = true
          i += 2
          continue
        }
      }
      "-C" => {
        create = true
        force_create = true
        if i + 1 < args.length() && not(args[i + 1].has_prefix("-")) {
          branch = Some(args[i + 1])
          branch_from_option = true
          i += 2
          continue
        }
      }
      "-d" | "--detach" => detach = true
      "--orphan" => {
        orphan = true
        if i + 1 < args.length() && not(args[i + 1].has_prefix("-")) {
          branch = Some(args[i + 1])
          branch_from_option = true
          i += 2
          continue
        }
      }
      "--discard-changes" => discard_changes = true
      "--ignore-other-worktrees" => ignore_other_worktrees = true
      "--track" => track_mode = Some("direct")
      "--guess" => guess_mode = Some(true)
      "--no-guess" => guess_mode = Some(false)
      _ if arg.has_prefix("--track=") => {
        let mode = String::unsafe_substring(arg, start=8, end=arg.length())
        if mode == "direct" || mode == "inherit" {
          track_mode = Some(mode)
        } else {
          warn_unimplemented_arg("switch", arg)
        }
      }
      _ if not(arg.has_prefix("-")) => positional.push(arg)
      _ if arg.has_prefix("-") => warn_unimplemented_arg("switch", arg)
      _ => ()
    }
    i += 1
  }
  if orphan {
    if branch is None {
      if positional.length() == 0 {
        raise @bitcore.GitError::InvalidObject("No branch specified")
      }
      branch = Some(positional[0])
    }
    let extra_args = if branch_from_option {
      positional.length()
    } else if positional.length() > 0 {
      positional.length() - 1
    } else {
      0
    }
    if extra_args > 0 {
      raise @bitcore.GitError::InvalidObject(
        "orphan mode does not accept start-point",
      )
    }
    guard branch is Some(name) else {
      raise @bitcore.GitError::InvalidObject("No branch specified")
    }
    let branch_name = normalize_switch_branch_ref(name)
    if not(ignore_other_worktrees) {
      match switch_branch_in_use_path(rfs, root, branch_name) {
        Some(_) => {
          eprint_line(
            "fatal: '\{branch_name}' is already checked out at another worktree",
          )
          @sys.exit(1)
        }
        None => ()
      }
    }
    ignore(discard_changes)
    switch_write_head_ref(fs, git_dir, branch_name)
    @bitlib.write_index_entries(fs, git_dir, [])
    println("Switched to a new branch '\{branch_name}'")
    return
  }
  if create {
    if branch is None {
      if positional.length() == 0 {
        raise @bitcore.GitError::InvalidObject("No branch specified")
      }
      branch = Some(positional[0])
    }
    let start_point = if branch_from_option {
      if positional.length() > 0 {
        Some(positional[0])
      } else {
        None
      }
    } else if positional.length() > 1 {
      Some(positional[1])
    } else {
      None
    }
    guard branch is Some(name) else {
      raise @bitcore.GitError::InvalidObject("No branch specified")
    }
    let branch_name = normalize_switch_branch_ref(name)
    if not(ignore_other_worktrees) {
      match switch_branch_in_use_path(rfs, root, branch_name) {
        Some(_) => {
          eprint_line(
            "fatal: '\{branch_name}' is already checked out at another worktree",
          )
          @sys.exit(1)
        }
        None => ()
      }
    }
    let refname = branch_name
    if @bitlib.resolve_ref(rfs, git_dir, refname) is Some(_) &&
      not(force_create) {
      raise @bitcore.GitError::InvalidObject(
        "branch '\{branch_name}' already exists",
      )
    }
    let target_id = match start_point {
      Some(spec) =>
        match @bitrepo.rev_parse(rfs, git_dir, spec) {
          Some(id) => Some(id)
          None =>
            raise @bitcore.GitError::InvalidObject("unknown revision: \{spec}")
        }
      None => @bitlib.resolve_ref(rfs, git_dir, "HEAD")
    }
    let previous_location = current_checkout_location(rfs, git_dir)
    match target_id {
      Some(id) => {
        @bitlib.create_branch_at(fs, rfs, root, branch_name, id)
        switch_apply_tracking_config(
          fs, rfs, git_dir, branch_name, start_point, track_mode,
        )
        @bitlib.switch_branch(fs, rfs, root, branch_name)
      }
      None => {
        let ref_path = git_dir + "/" + refname
        ensure_dir(parent_dir(ref_path))
        fs.write_string(ref_path, "")
        switch_apply_tracking_config(
          fs, rfs, git_dir, branch_name, start_point, track_mode,
        )
        switch_write_head_ref(fs, git_dir, branch_name)
      }
    }
    save_previous_checkout_location(fs, git_dir, previous_location)
    println("Switched to a new branch '\{branch_name}'")
    return
  }
  if detach {
    let target = if positional.length() > 0 { positional[0] } else { "HEAD" }
    let previous_location = current_checkout_location(rfs, git_dir)
    ignore(checkout_with_promisor_retry(fs, root, target, detach=true))
    save_previous_checkout_location(fs, git_dir, previous_location)
    return
  }
  let target = if positional.length() > 0 {
    resolve_checkout_target(rfs, git_dir, positional[0])
  } else {
    raise @bitcore.GitError::InvalidObject("No branch specified")
  }
  let target_ref = normalize_switch_branch_ref(target)
  let local_branch_exists = @bitlib.resolve_ref(rfs, git_dir, target_ref)
    is Some(_)
  if local_branch_exists {
    if not(ignore_other_worktrees) {
      match switch_branch_in_use_path(rfs, root, target_ref) {
        Some(_) => {
          eprint_line(
            "fatal: '\{target}' is already checked out at another worktree",
          )
          @sys.exit(1)
        }
        None => ()
      }
    }
    let previous_location = current_checkout_location(rfs, git_dir)
    ignore(checkout_with_promisor_retry(fs, root, target))
    save_previous_checkout_location(fs, git_dir, previous_location)
    println("Switched to branch '\{target}'")
    return
  }
  let guess = switch_effective_guess(rfs, git_dir, guess_mode)
  if guess &&
    @bitlib.resolve_ref(rfs, git_dir, "refs/remotes/origin/" + target)
    is Some(_) {
    let previous_location = current_checkout_location(rfs, git_dir)
    ignore(checkout_with_promisor_retry(fs, root, target))
    save_previous_checkout_location(fs, git_dir, previous_location)
    println("Switched to branch '\{target}'")
    return
  }
  if @bitrepo.rev_parse(rfs, git_dir, target) is Some(_) {
    eprint_line("fatal: a branch is expected, got '\{target}'")
    if switch_should_suggest_detach(rfs, git_dir) {
      eprint_line("hint: try again with the --detach option")
    }
    @sys.exit(1)
  }
  raise @bitcore.GitError::InvalidObject("Invalid ref: \{target}")
}

///|
fn normalize_switch_branch_ref(name : String) -> String raise @bitcore.GitError {
  let normalized = @bitlib.normalize_repo_path(name) catch {
    _ => raise @bitcore.GitError::InvalidObject("invalid branch name: " + name)
  }
  if normalized.has_prefix("refs/heads/") {
    normalized
  } else {
    "refs/heads/" + normalized
  }
}

///|
fn switch_write_head_ref(
  fs : &@bitcore.FileSystem,
  git_dir : String,
  branch : String,
) -> Unit raise Error {
  fs.write_string(git_dir + "/HEAD", "ref: " + branch + "\n")
}

///|
fn switch_branch_in_use_path(
  fs : &@bitcore.RepoFileSystem,
  root : String,
  branch : String,
) -> String? raise Error {
  match @bitlib.is_branch_checked_out(fs, root, branch) {
    Some(path) =>
      if normalize_path(path) == normalize_path(root) {
        None
      } else {
        Some(path)
      }
    None => None
  }
}

///|
fn switch_get_config_value(
  fs : &@bitcore.RepoFileSystem,
  git_dir : String,
  key : String,
) -> String? raise Error {
  match get_config_override(key) {
    Some(value) => Some(value)
    None => get_config_value(fs, git_dir + "/config", key)
  }
}

///|
fn switch_parse_bool(value : String) -> Bool? {
  let normalized = trim_string(value).to_lower()
  if normalized == "true" ||
    normalized == "yes" ||
    normalized == "on" ||
    normalized == "1" {
    Some(true)
  } else if normalized == "false" ||
    normalized == "no" ||
    normalized == "off" ||
    normalized == "0" {
    Some(false)
  } else {
    None
  }
}

///|
fn switch_effective_guess(
  fs : &@bitcore.RepoFileSystem,
  git_dir : String,
  guess_mode : Bool?,
) -> Bool raise Error {
  match guess_mode {
    Some(value) => value
    None =>
      match switch_get_config_value(fs, git_dir, "checkout.guess") {
        Some(value) => switch_parse_bool(value).unwrap_or(true)
        None => true
      }
  }
}

///|
fn switch_should_suggest_detach(
  fs : &@bitcore.RepoFileSystem,
  git_dir : String,
) -> Bool raise Error {
  match switch_get_config_value(fs, git_dir, "advice.suggestDetachingHead") {
    Some(value) => switch_parse_bool(value).unwrap_or(true)
    None => true
  }
}

///|
fn switch_start_branch_name(
  fs : &@bitcore.RepoFileSystem,
  git_dir : String,
  start_point : String?,
) -> String? raise Error {
  match start_point {
    Some(spec) =>
      if spec.has_prefix("refs/heads/") {
        Some(String::unsafe_substring(spec, start=11, end=spec.length()))
      } else if @bitlib.resolve_ref(fs, git_dir, "refs/heads/" + spec)
        is Some(_) {
        Some(spec)
      } else {
        None
      }
    None =>
      match @bitlib.read_head_ref(fs, git_dir) {
        @bitlib.HeadRef::Branch(name) => Some(name)
        @bitlib.HeadRef::Detached(_) => None
      }
  }
}

///|
fn switch_apply_tracking_config(
  fs : &@bitcore.FileSystem,
  rfs : &@bitcore.RepoFileSystem,
  git_dir : String,
  branch : String,
  start_point : String?,
  track_mode : String?,
) -> Unit raise Error {
  let mut mode = track_mode
  if mode is None {
    mode = match
      switch_get_config_value(rfs, git_dir, "branch.autoSetupMerge") {
      Some(value) if value.to_lower() == "inherit" => Some("inherit")
      _ => None
    }
  }
  let source_branch = switch_start_branch_name(rfs, git_dir, start_point)
  match mode {
    Some("direct") =>
      match source_branch {
        Some(source) => {
          @bitlib.set_config_key(
            fs, rfs, git_dir, "branch", branch, "remote", ".",
          )
          @bitlib.set_config_key(
            fs,
            rfs,
            git_dir,
            "branch",
            branch,
            "merge",
            "refs/heads/" + source,
          )
        }
        None => ()
      }
    Some("inherit") =>
      match source_branch {
        Some(source) => {
          let (_remotes, branches) = @bitlib.read_repo_config(rfs, git_dir)
          match branches.get(source) {
            Some(cfg) => {
              match cfg.remote {
                Some(remote) =>
                  @bitlib.set_config_key(
                    fs, rfs, git_dir, "branch", branch, "remote", remote,
                  )
                None => ()
              }
              if cfg.merges.length() > 0 {
                @bitlib.set_config_key(
                  fs,
                  rfs,
                  git_dir,
                  "branch",
                  branch,
                  "merge",
                  cfg.merges[0],
                )
              }
            }
            None => ()
          }
        }
        None => ()
      }
    _ => ()
  }
}

///|

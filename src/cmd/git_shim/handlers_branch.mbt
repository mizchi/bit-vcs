///| Branch handlers: branch, checkout, switch, reset, rebase

///|
async fn handle_branch(args : Array[String]) -> Unit raise Error {
  let root = get_work_root()
  let git_dir = root + "/.git"
  let fs = OsFs::new()
  let mut list_mode = true
  let mut new_branch : String? = None
  let mut delete_branch : String? = None
  let mut force_delete = false
  let mut show_all = false
  let mut show_remotes = false
  let mut verbose = false
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    match arg {
      "-d" | "--delete" if i + 1 < args.length() => {
        delete_branch = Some(args[i + 1])
        list_mode = false
        i += 2
        continue
      }
      "-D" if i + 1 < args.length() => {
        force_delete = true
        delete_branch = Some(args[i + 1])
        list_mode = false
        i += 2
        continue
      }
      "-a" | "--all" => show_all = true
      "-r" | "--remotes" => show_remotes = true
      "-v" | "--verbose" => verbose = true
      _ if not(arg.has_prefix("-")) => {
        new_branch = Some(arg)
        list_mode = false
      }
      _ => ()
    }
    i += 1
  }
  match delete_branch {
    Some(name) => {
      @gitlib.delete_branch(fs, fs, root, name, force=force_delete)
      print_line("Deleted branch \{name}")
    }
    None =>
      match new_branch {
        Some(name) => @gitlib.create_branch(fs, fs, root, name)
        None =>
          if list_mode {
            // List local branches
            if not(show_remotes) {
              let lines = if verbose {
                @gitlib.list_branches_verbose(fs, git_dir)
              } else {
                @gitlib.list_branches_text(fs, git_dir)
              }
              for line in lines {
                print_line(line)
              }
            }
            // List remote branches
            if show_all || show_remotes {
              let remotes = @gitlib.list_remote_branches(fs, git_dir)
              for line in remotes {
                print_line(line)
              }
            }
          }
      }
  }
}

///|
fn handle_checkout(args : Array[String]) -> Unit raise Error {
  let root = get_work_root()
  let git_dir = root + "/.git"
  let fs = OsFs::new()
  // Parse arguments
  let mut saw_separator = false
  let mut create_branch = false
  let mut force_create = false
  let targets : Array[String] = []
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    match arg {
      "--" => saw_separator = true
      "-b" => create_branch = true
      "-B" => {
        create_branch = true
        force_create = true
      }
      _ if arg.has_prefix("-") => ()
      _ => targets.push(arg)
    }
    i += 1
  }
  if targets.length() == 0 {
    raise @git.GitError::InvalidObject("No target specified for checkout")
  }
  // git checkout -b <branch> [start-point]
  if create_branch {
    let branch_name = targets[0]
    let start_point = if targets.length() > 1 { Some(targets[1]) } else { None }
    // Check if branch already exists
    let branch_exists = @gitlib.resolve_ref(
        fs,
        git_dir,
        "refs/heads/" + branch_name,
      )
      is Some(_)
    if branch_exists && not(force_create) {
      raise @git.GitError::InvalidObject(
        "branch '\{branch_name}' already exists",
      )
    }
    // For start point, first checkout to that commit, then create branch
    match start_point {
      Some(ref_name) => {
        let commit_id = @gitlib.rev_parse(fs, git_dir, ref_name)
        guard commit_id is Some(_) else {
          raise @git.GitError::InvalidObject("unknown revision: \{ref_name}")
        }
        // Checkout the start point first (detached)
        let _ = @gitlib.checkout(fs, fs, root, ref_name, detach=true)
        // Then create and switch to new branch
        @gitlib.switch_branch(fs, fs, root, branch_name, create=true)
      }
      None =>
        // Use switch_branch which handles both atomically
        @gitlib.switch_branch(fs, fs, root, branch_name, create=true)
    }
    return ()
  }
  // If -- was used, treat all targets as file paths
  if saw_separator {
    @gitlib.restore_paths(fs, fs, root, targets)
    return ()
  }
  // Single target: determine if it's a branch or file
  if targets.length() == 1 {
    let target = targets[0]
    let is_file = fs.is_file(root + "/" + target)
    let is_branch = @gitlib.resolve_ref(fs, git_dir, "refs/heads/" + target)
      is Some(_)
    if is_file && is_branch {
      // Ambiguous - default to branch (like git)
      let _ = @gitlib.checkout(fs, fs, root, target)

    } else if is_file {
      // Restore single file
      @gitlib.restore_paths(fs, fs, root, [target])
    } else {
      // Try as branch/commit
      let _ = @gitlib.checkout(fs, fs, root, target)

    }
  } else {
    // Multiple targets: treat as file paths
    @gitlib.restore_paths(fs, fs, root, targets)
  }
}

///|
fn handle_switch(args : Array[String]) -> Unit raise Error {
  let root = get_work_root()
  let fs = OsFs::new()
  let mut branch : String? = None
  let mut create = false
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    match arg {
      "-c" | "--create" => {
        create = true
        if i + 1 < args.length() && not(args[i + 1].has_prefix("-")) {
          branch = Some(args[i + 1])
          i += 2
          continue
        }
      }
      _ if not(arg.has_prefix("-")) => branch = Some(arg)
      _ => ()
    }
    i += 1
  }
  guard branch is Some(name) else {
    raise @git.GitError::InvalidObject("No branch specified")
  }
  @gitlib.switch_branch(fs, fs, root, name, create~)
  if create {
    println("Switched to a new branch '\{name}'")
  } else {
    println("Switched to branch '\{name}'")
  }
}

///|
fn handle_reset(args : Array[String]) -> Unit raise Error {
  let root = get_work_root()
  let fs = OsFs::new()
  let mut mode : @gitlib.ResetMode = @gitlib.ResetMode::Mixed
  let mut rev = "HEAD"
  for arg in args {
    match arg {
      "--soft" => mode = @gitlib.ResetMode::Soft
      "--mixed" => mode = @gitlib.ResetMode::Mixed
      "--hard" => mode = @gitlib.ResetMode::Hard
      _ if not(arg.has_prefix("-")) => rev = arg
      _ => ()
    }
  }
  let commit_id = @gitlib.reset(fs, fs, root, rev, mode)
  let short_id = String::unsafe_substring(commit_id.to_hex(), start=0, end=7)
  println("HEAD is now at \{short_id}")
}

///|
async fn handle_rebase(args : Array[String]) -> Unit raise Error {
  let root = get_work_root()
  let git_dir = root + "/.git"
  let fs = OsFs::new()
  // Parse arguments
  let mut do_continue = false
  let mut do_abort = false
  let mut do_skip = false
  let mut upstream : String? = None
  for arg in args {
    match arg {
      "--continue" => do_continue = true
      "--abort" => do_abort = true
      "--skip" => do_skip = true
      _ if not(arg.has_prefix("-")) => upstream = Some(arg)
      _ => ()
    }
  }
  // Handle --continue
  if do_continue {
    let result = @gitlib.rebase_continue(fs, fs, root)
    print_rebase_result(result)
    return ()
  }
  // Handle --abort
  if do_abort {
    @gitlib.rebase_abort(fs, fs, root)
    print_line("Rebase aborted")
    return ()
  }
  // Handle --skip
  if do_skip {
    let result = @gitlib.rebase_skip(fs, fs, root)
    print_rebase_result(result)
    return ()
  }
  // Start new rebase
  guard upstream is Some(ref_name) else {
    raise @git.GitError::InvalidObject("usage: git rebase <upstream>")
  }
  let upstream_id = @gitlib.rev_parse(fs, git_dir, ref_name)
  guard upstream_id is Some(id) else {
    raise @git.GitError::InvalidObject("unknown revision: \{ref_name}")
  }
  let result = @gitlib.rebase_start(fs, fs, root, id)
  print_rebase_result(result)
}

///|
async fn print_rebase_result(result : @gitlib.RebaseResult) -> Unit {
  match result.status {
    @gitlib.RebaseStatus::Complete => {
      match result.commit_id {
        Some(id) => {
          let short = String::unsafe_substring(id.to_hex(), start=0, end=7)
          print_line("Successfully rebased and updated refs. [\{short}]")
        }
        None => print_line("Successfully rebased.")
      }
    }
    @gitlib.RebaseStatus::NothingToRebase =>
      print_line("Current branch is up to date.")
    @gitlib.RebaseStatus::Conflict => {
      print_line("CONFLICT: Merge conflict in:")
      for path in result.conflicts {
        print_line("  \{path}")
      }
      print_line("")
      print_line("Resolve all conflicts, then run \"git rebase --continue\".")
      print_line("To abort and return to the original state, run \"git rebase --abort\".")
      print_line("To skip this commit, run \"git rebase --skip\".")
    }
  }
}

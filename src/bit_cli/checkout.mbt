///|
async fn handle_checkout(args : Array[String]) -> Unit raise Error {
  let root = get_work_root()
  let git_dir = root + "/.git"
  let fs = OsFs::new()
  let rfs : &@git.RepoFileSystem = fs
  let git_dir = if rfs.is_file(git_dir) {
    @gitlib.resolve_gitdir(rfs, git_dir)
  } else {
    git_dir
  }
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
      _ if arg.has_prefix("-") => warn_unimplemented_arg("checkout", arg)
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
        let commit_id = @gitrepo.rev_parse(fs, git_dir, ref_name)
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

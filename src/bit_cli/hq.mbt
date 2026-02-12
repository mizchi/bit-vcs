///|
/// hq command handler - ghq-compatible repository management

///|
async fn print_hq_usage() -> Unit {
  let usage =
    #|Usage: bit hq <command> [options]
    #|
    #|ghq-compatible repository management. Clones repositories to ~/bhq.
    #|
    #|Commands:
    #|  get <repo>     Clone repository
    #|  list [query]   List local repositories
    #|  root           Show root directory
    #|
    #|Examples:
    #|  bit hq get mizchi/git                  # → ~/bhq/mizchi/git
    #|  bit hq get github.com/mizchi/git       # → ~/bhq/mizchi/git (normalized)
    #|  bit hq get gitlab.com/user/repo        # → ~/bhq/gitlab.com/user/repo
    #|  bit hq get mizchi/monorepo/src/lib     # sparse checkout src/lib only
    #|  bit hq get -u mizchi/git               # update if exists
    #|  bit hq get --shallow mizchi/git        # depth=1 clone
    #|  bit hq list                            # list all repos
    #|  bit hq list mizchi                     # filter by query
    #|  bit hq root                            # show ~/bhq
    #|
    #|Environment:
    #|  BHQ_ROOT       Override root directory (default: ~/bhq)
  print_line(usage)
}

///|
async fn print_hq_get_usage() -> Unit {
  let usage =
    #|Usage: bit hq get [options] <repo>
    #|
    #|Clone repository to bhq root directory.
    #|
    #|Arguments:
    #|  <repo>    Repository URL or shorthand:
    #|            - user/repo              → github.com/user/repo
    #|            - user/repo/path         → sparse checkout path
    #|            - github.com/user/repo   → normalized to user/repo
    #|            - gitlab.com/user/repo   → keeps host prefix
    #|            - https://github.com/... → full URL
    #|            - git@github.com:...     → SSH URL
    #|
    #|Options:
    #|  -u, --update     Update if already exists (git pull)
    #|  --shallow        Shallow clone (--depth=1)
    #|  -p, --ssh        Use SSH protocol
    #|  -b, --branch     Clone specific branch
    #|
    #|Examples:
    #|  bit hq get mizchi/git
    #|  bit hq get -u mizchi/git
    #|  bit hq get --shallow mizchi/git
    #|  bit hq get mizchi/monorepo/packages/core  # sparse checkout
  print_line(usage)
}

///|
/// Main hq command handler
async fn handle_hq(args : Array[String]) -> Unit raise Error {
  if args.length() == 0 {
    print_hq_usage()
    return
  }
  let subcmd = args[0]
  let rest : Array[String] = args[1:].iter().map(s => s).collect()
  match subcmd {
    "get" => handle_hq_get(rest)
    "list" => handle_hq_list(rest)
    "root" => handle_hq_root(rest)
    "-h" | "--help" | "help" => print_hq_usage()
    _ => {
      eprint_line("bit hq: unknown subcommand '\{subcmd}'")
      print_hq_usage()
    }
  }
}

///|
/// hq get command handler
async fn handle_hq_get(args : Array[String]) -> Unit raise Error {
  let mut url : String? = None
  let mut update = false
  let mut shallow = false
  let mut ssh = false
  let mut branch : String? = None
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    match arg {
      "-h" | "--help" => {
        print_hq_get_usage()
        return
      }
      "-u" | "--update" => update = true
      "--shallow" => shallow = true
      "-p" | "--ssh" => ssh = true
      "-b" | "--branch" =>
        if i + 1 < args.length() {
          i += 1
          branch = Some(args[i])
        }
      _ if arg.has_prefix("-") => warn_unimplemented_arg("hq get", arg)
      _ => if url is None { url = Some(arg) }
    }
    i += 1
  }
  guard url is Some(repo_url) else {
    print_hq_get_usage()
    return
  }
  // Parse repository URL
  let repo = @hq.parse_repo_url(repo_url)
  guard repo is Some(r) else {
    eprint_line("bit hq get: invalid repository '\{repo_url}'")
    return
  }
  // Load configuration
  let config = @hq.load_config(get_env_hq, get_git_config_hq)
  let options = @hq.HqGetOptions::new(update~, shallow~, ssh~, branch~)
  let local_path = r.local_path(config.root)
  // Check if exists
  let fs = OsFs::new()
  let exists = fs.is_dir(local_path)
  if exists {
    if update {
      // Update existing
      print_line("Updating \{contract_path_hq(local_path)}...")
      let code = run_git_command(
        ["-C", local_path, "pull", "--ff-only"],
        cwd=None,
      )
      if code == 0 {
        print_line("Updated \{contract_path_hq(local_path)}")
      } else {
        eprint_line("bit hq get: failed to update")
      }
    } else {
      print_line(
        "Already exists: \{contract_path_hq(local_path)} (use -u to update)",
      )
    }
    return
  }
  // Clone
  print_line(
    "Cloning \{r.clone_url(ssh=ssh)} to \{contract_path_hq(local_path)}...",
  )
  // Create parent directories
  let parent = get_parent_dir(local_path)
  fs.mkdir_p(parent) catch {
    err => {
      if @async.is_being_cancelled() || @async.is_cancellation_error(err) {
        raise err
      }
      ()
    }
  }
  let clone_args : Array[String] = ["clone"]
  if options.shallow {
    clone_args.push("--depth=1")
  }
  if r.needs_sparse() {
    clone_args.push("--filter=blob:none")
    clone_args.push("--no-checkout")
  }
  match options.branch {
    Some(b) => {
      clone_args.push("--branch")
      clone_args.push(b)
    }
    None => ()
  }
  clone_args.push(r.clone_url(ssh~))
  clone_args.push(local_path)
  let code = run_git_command(clone_args, cwd=None)
  if code != 0 {
    eprint_line("bit hq get: clone failed")
    return
  }
  // Handle sparse checkout
  if r.needs_sparse() {
    let subdir = r.subdir.unwrap_or("")
    let _ = run_git_command(
      ["-C", local_path, "sparse-checkout", "init", "--cone"],
      cwd=None,
    )
    let _ = run_git_command(
      ["-C", local_path, "sparse-checkout", "set", subdir],
      cwd=None,
    )
    let _ = run_git_command(["-C", local_path, "checkout"], cwd=None)
  }
  print_line("Cloned to \{contract_path_hq(local_path)}")
}

///|
/// hq list command handler
async fn handle_hq_list(args : Array[String]) -> Unit {
  let query : String? = if args.length() > 0 && not(args[0].has_prefix("-")) {
    Some(args[0])
  } else {
    None
  }
  let config = @hq.load_config(get_env_hq, get_git_config_hq)
  let fs = OsFs::new()
  // Simple recursive directory listing
  let repos = list_repos_recursive(fs, config.root, "", query)
  for repo in repos {
    print_line(repo)
  }
}

///|
fn list_repos_recursive(
  fs : OsFs,
  root : String,
  rel_path : String,
  query : String?,
) -> Array[String] {
  let repos : Array[String] = []
  let current = if rel_path.is_empty() { root } else { root + "/" + rel_path }
  // Check if this is a git repo
  if fs.is_dir(current + "/.git") {
    // Apply query filter
    match query {
      Some(q) if not(rel_path.contains(q)) => ()
      _ => repos.push(rel_path)
    }
    return repos
  }
  // List subdirectories
  let entries = fs.readdir(current) catch { _ => return repos }
  for entry in entries {
    if entry.has_prefix(".") {
      continue
    }
    let child_path = current + "/" + entry
    if fs.is_dir(child_path) {
      let new_rel = if rel_path.is_empty() {
        entry
      } else {
        rel_path + "/" + entry
      }
      let sub_repos = list_repos_recursive(fs, root, new_rel, query)
      for r in sub_repos {
        repos.push(r)
      }
    }
  }
  repos
}

///|
/// hq root command handler
async fn handle_hq_root(_args : Array[String]) -> Unit {
  let config = @hq.load_config(get_env_hq, get_git_config_hq)
  config.root |> contract_path_hq |> print_line
}

///|
/// Get environment variable
fn get_env_hq(key : String) -> String? {
  @sys.get_env_var(key)
}

///|
/// Get git config value (sync version using cached values)
fn get_git_config_hq(_key : String) -> String? {
  // For simplicity, we don't read git config in sync mode
  // The default ~/bhq will be used
  None
}

///|
/// Get home directory
fn get_home_dir_hq() -> String {
  @sys.get_env_var("HOME").unwrap_or("/home/user")
}

///|
/// Contract path with ~ for display
fn contract_path_hq(path : String) -> String {
  let home = get_home_dir_hq()
  @hq.contract_home(path, home)
}

///|
/// Get parent directory
fn get_parent_dir(path : String) -> String {
  match path.rev_find("/") {
    Some(idx) =>
      if idx == 0 {
        "/"
      } else {
        String::unsafe_substring(path, start=0, end=idx)
      }
    None => "."
  }
}

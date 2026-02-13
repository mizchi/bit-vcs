///|

///|
async fn show_init_command_help() -> Unit {
  show_simple_command_help(
    "git init [<options>] [<directory>]",
    summary="Create an empty Git repository or reinitialize an existing one.",
  )
}

///|
async fn handle_init(args : Array[String]) -> Unit raise Error {
  if is_real_git_delegate_enabled() {
    delegate_to_real_git("init", args)
  }
  let root = match @sys.get_env_var("GIT_SHIM_CWD") {
    Some(dir) => dir
    None =>
      match @sys.get_env_var("GIT_WORK_TREE") {
        Some(dir) => dir
        None => @sys.get_env_var("GIT_SHIM_PWD").unwrap_or(".")
      }
  }
  let fs = OsFs::new()
  // Parse options
  let mut bare = false
  let mut quiet = false
  let mut initial_branch : String? = None
  let mut target_dir : String? = None
  let mut separate_git_dir : String? = None
  let mut template_dir : String? = None
  let mut use_bit = false
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    match arg {
      "--bare" => bare = true
      "--bit" => use_bit = true
      "-q" | "--quiet" => quiet = true
      "-b" if i + 1 < args.length() => {
        initial_branch = Some(args[i + 1])
        i += 1
      }
      "--separate-git-dir" if i + 1 < args.length() => {
        separate_git_dir = Some(args[i + 1])
        i += 1
      }
      "--template" if i + 1 < args.length() => {
        template_dir = Some(args[i + 1])
        i += 1
      }
      _ if arg.has_prefix("--initial-branch=") =>
        initial_branch = Some((try! arg[17:]).to_string())
      _ if arg.has_prefix("--separate-git-dir=") =>
        separate_git_dir = Some((try! arg[19:]).to_string())
      _ if arg.has_prefix("--template=") =>
        template_dir = Some((try! arg[11:]).to_string())
      _ if not(arg.has_prefix("-")) => target_dir = Some(arg)
      _ if arg.has_prefix("-") => warn_unimplemented_arg("init", arg)
      _ => ()
    }
    i += 1
  }
  // Check GIT_DIR and GIT_WORK_TREE environment variables
  let git_dir_env = @sys.get_env_var("GIT_DIR")
  let work_tree_env = @sys.get_env_var("GIT_WORK_TREE")
  // Check GIT_TEMPLATE_DIR environment variable
  if template_dir is None {
    template_dir = @sys.get_env_var("GIT_TEMPLATE_DIR")
  }
  // Determine the target path and git directory
  let (path, effective_git_dir) : (String, String?) = match
    (target_dir, git_dir_env) {
    (Some(dir), _) => {
      let p = if dir.has_prefix("/") { dir } else { root + "/" + dir }
      (p, None)
    }
    (None, Some(gd)) => {
      // When GIT_DIR is set without target
      let g = if gd.has_prefix("/") { gd } else { root + "/" + gd }
      // If GIT_WORK_TREE is also set, it's not bare (work tree exists)
      // If only GIT_DIR is set, it's a bare repo
      if work_tree_env is Some(_) {
        (root, Some(g))
      } else {
        (g, Some(g))
      }
    }
    (None, None) => (root, None)
  }
  // Determine if bare: only bare if explicitly requested or GIT_DIR without GIT_WORK_TREE
  if git_dir_env is Some(_) && work_tree_env is None && target_dir is None {
    bare = true
  }
  // If GIT_WORK_TREE is set with --bare, that's an error
  if bare && work_tree_env is Some(_) {
    eprint_line(
      "fatal: GIT_WORK_TREE (or --work-tree=<directory>) not allowed without specifying a repository to work with",
    )
    @sys.exit(128)
  }
  // Resolve separate_git_dir to absolute path
  let resolved_sep_git_dir : String? = match separate_git_dir {
    Some(d) => Some(if d.has_prefix("/") { d } else { root + "/" + d })
    None =>
      if use_bit && not(bare) && effective_git_dir is None {
        Some(path + "/.bit")
      } else {
        None
      }
  }
  // Determine default branch
  let branch = initial_branch.unwrap_or("main")
  // Determine actual git directory path for output message
  let actual_git_dir = match (resolved_sep_git_dir, effective_git_dir) {
    (Some(sep), _) => sep
    (None, Some(gd)) => gd
    (None, None) => if bare { path } else { path + "/.git" }
  }
  // Check if this is a reinit (repository already exists)
  let is_reinit = fs.is_dir(actual_git_dir) &&
    fs.is_file(actual_git_dir + "/HEAD")
  // Build init options
  let opts : @gitlib.InitOptions = {
    default_branch: branch,
    bare,
    separate_git_dir: resolved_sep_git_dir,
    template_dir,
  }
  // Initialize repository
  @gitrepo.init_repo_with_options(fs, path, opts)
  // Apply template if specified
  match template_dir {
    Some(tpl) =>
      if fs.is_dir(tpl) {
        @gitrepo.apply_template(fs, fs, actual_git_dir, tpl)
      }
    None => ()
  }
  // Print appropriate message (unless quiet)
  if not(quiet) {
    let verb = if is_reinit {
      "Reinitialized existing"
    } else {
      "Initialized empty"
    }
    print_line(verb + " Git repository in " + actual_git_dir + "/")
  }
}

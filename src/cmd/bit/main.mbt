///| Git-shim main entry point and command dispatcher

///|
async fn show_help() -> Unit {
  let help =
    #|usage: bit [-v | --version] [-h | --help] [-C <path>]
    #|           <command> [<args>]
    #|
    #|bit is a Git implementation in MoonBit.
    #|Unsupported commands will fail with an error.
    #|
    #|start a working area
    #|   clone      Clone a repository into a new directory
    #|   init       Create an empty Git repository
    #|
    #|work on the current change
    #|   add        Add file contents to the index
    #|   mv         Move or rename a file, a directory, or a symlink
    #|   rm         Remove files from the working tree and from the index
    #|
    #|examine the history and state
    #|   diff       Show changes between commits, commit and working tree, etc
    #|   log        Show commit logs
    #|   show       Show various types of objects
    #|   status     Show the working tree status
    #|   tree       List tree entries from a remote repository (porcelain)
    #|   cat        Show file contents from a remote repository
    #|
    #|grow, mark and tweak your common history
    #|   branch        List, create, or delete branches
    #|   show-branches Show branches and their commits
    #|   cherry-pick Apply the changes from some existing commits
    #|   commit      Record changes to the repository
    #|   checkout    Switch branches or restore working tree files
    #|   merge       Join two or more development histories together
    #|   rebase      Reapply commits on top of another base tip
    #|   ai           AI helpers (rebase, merge, commit, cherry-pick, revert)
    #|   rebase-ai    AI-assisted rebase conflict resolution (OpenRouter kimi-k2, alias for ai rebase)
    #|   reset       Reset current HEAD to the specified state
    #|   stash       Stash the changes in a dirty working directory
    #|   switch      Switch branches
    #|   tag         Create, list, delete tag objects
    #|
    #|hub
    #|   fetch       Download objects and refs from another repository
    #|   pull        Fetch from and integrate with another repository
    #|   push        Update remote refs along with associated objects
    #|   remote      Manage set of tracked repositories
    #|
    #|work with multiple working trees
    #|   worktree    Manage multiple working trees
    #|
    #|experimental
    #|   hub          Manage pull requests and issues
    #|   pr           Shortcut for 'hub pr' (gh-like)
    #|   issue        Shortcut for 'hub issue' (gh-like)
    #|   mcp          Run bit MCP server (stdio)
    #|   workspace    Manage hierarchical bit workspace projects
    #|   ws           Shortcut for 'workspace'
    #|   repo         Run regular bit command without workspace translation
    #|   subdir-clone  Clone subdirectory as independent repository
    #|   hq            ghq-compatible repository management (~/bhq)
    #|
    #|setup
    #|   completion    Generate shell completion scripts (bash/zsh)
    #|   x/hooks       Manage hooks used by bit commands (experimental; do not overuse hooks as automation)
    #|
    #|low-level / plumbing
    #|   bundle          Create, verify, list-heads, and unbundle Git bundles
    #|   cat-file        Provide content or type info for repository objects
    #|   config          Get and set repository options
    #|   hash-object     Compute object ID and optionally creates a blob
    #|   index-pack      Build pack index file for an existing packed archive
    #|   ls-files        Show information about files in the index
    #|   ls-tree         List the contents of a tree object
    #|   pack-objects    Create a packed archive of objects
    #|   receive-pack    Receive what is pushed into the repository
    #|   rev-list        List commit objects in reverse chronological order
    #|   rev-parse       Parse revision specifications
    #|   show-ref        List references in a local repository
    #|   symbolic-ref    Read, modify and delete symbolic refs
    #|   unpack-objects  Unpack objects from a packed archive
    #|   update-ref      Update the object name stored in a ref safely
    #|   upload-pack     Send objects packed back to git-fetch-pack
    #|   verify-pack     Validate packed Git archive files
    #|   write-tree      Create a tree object from the current index
    #|
    #|See 'git help <command>' for more information on a specific command.
  print_line(help)
}

///|
async fn show_simple_command_help(usage : String, summary? : String) -> Unit {
  let mut help = "usage: " + usage
  if summary is Some(text) {
    help = help + "\n\n" + text
  }
  print_line(help)
}

///|
fn show_command_help_specs() -> Array[(String, String, String)] {
  [
    ("help", "git help [-a | -g | -c] [<command>]", "Show help information."),
    (
      "clone", "git clone [<options>] [--] <repo> [<dir>]", "Clone a repository into a new directory.",
    ),
    (
      "tree", "bit tree [<options>] <repo>[:<path>] [<pathspec>...]", "List tree entries from a remote repository (porcelain).",
    ),
    (
      "cat", "bit cat <repo>:<path>", "Show file contents from a remote repository.",
    ),
    (
      "diff", "git diff [<options>] [--] [<pathspec>...]", "Show changes between commits, commit and working tree, etc.",
    ),
    (
      "diff-files", "git diff-files [<options>] [<pathspec>...]", "Compare files in the working tree and index.",
    ),
    (
      "diff-index", "git diff-index [<options>] <tree-ish> [--] [<pathspec>...]",
      "Compare tree object with working tree and index.",
    ),
    (
      "branch", "git branch [<options>] [<branchname>]", "List, create, or delete branches.",
    ),
    (
      "show-branches", "git show-branch [<options>] [<branch>...]", "Show branches and their commits.",
    ),
    (
      "show-branch", "git show-branch [<options>] [<branch>...]", "Show branches and their commits.",
    ),
    (
      "checkout", "git checkout [<options>] <branch>", "Switch branches or restore working tree files.",
    ),
    ("switch", "git switch [<options>] <branch>", "Switch branches."),
    (
      "reset", "git reset [<options>] [<commit>]", "Reset current HEAD to the specified state.",
    ),
    (
      "rebase", "git rebase [<options>] <upstream> [<branch>]", "Reapply commits on top of another base tip.",
    ),
    (
      "ai", "bit ai <command> [<args>]", "AI helpers (rebase, merge, commit, cherry-pick, revert).",
    ),
    (
      "merge", "git merge [<options>] <commit>...", "Join two or more development histories together.",
    ),
    (
      "stash", "git stash [<options>] [<message>]", "Stash the changes in a dirty working directory.",
    ),
    (
      "cherry-pick", "git cherry-pick [<options>] <commit>...", "Apply the changes from existing commits.",
    ),
    (
      "tag", "git tag [<options>] [<name> [<commit>]]", "Create, list, delete tag objects.",
    ),
    (
      "fetch", "git fetch [<options>] [<repository> [<refspec>...]]", "Download objects and refs from another repository.",
    ),
    (
      "pull", "git pull [<options>] [<repository> [<refspec>...]]", "Fetch from and integrate with another repository.",
    ),
    (
      "push", "git push [<options>] [<repository> [<refspec>...]]", "Update remote refs along with associated objects.",
    ),
    (
      "remote", "git remote [<command>] [<args>]", "Manage set of tracked repositories.",
    ),
    (
      "mv", "git mv <source> <destination>", "Move or rename a file, a directory, or a symlink.",
    ),
    (
      "rm", "git rm [<options>] <file>...", "Remove files from the working tree and from the index.",
    ),
    (
      "bundle", "git bundle <command> [<args>]", "Create, verify, list-heads, and unbundle Git bundles.",
    ),
    (
      "clean", "git clean [<options>] [--] <pathspec>...", "Remove untracked files from the working tree.",
    ),
    (
      "cat-file", "git cat-file <type> <object>", "Provide content or type info for repository objects.",
    ),
    (
      "config", "git config [<options>] <name> [<value>]", "Get and set repository options.",
    ),
    (
      "describe", "git describe [<options>] <commit-ish>", "Give an object a human readable name based on a ref.",
    ),
    (
      "format-patch", "git format-patch [<options>] <since>..<until>", "Prepare patches for e-mail submission.",
    ),
    (
      "fsck", "git fsck [<options>]", "Verify the connectivity and validity of objects.",
    ),
    (
      "gc", "git gc [<options>]", "Cleanup unnecessary files and optimize the local repository.",
    ),
    (
      "grep", "git grep [<options>] <pattern> [--] <pathspec>...", "Print lines matching a pattern.",
    ),
    (
      "hash-object", "git hash-object [<options>] <file>...", "Compute object ID and optionally creates a blob.",
    ),
    (
      "index-pack", "git index-pack [<options>] <pack> [<idx>]", "Build pack index file for an existing packed archive.",
    ),
    (
      "ls-files", "git ls-files [<options>] [<file>...]", "Show information about files in the index.",
    ),
    (
      "ls-tree", "git ls-tree [<options>] <tree-ish> [<path>...]", "List the contents of a tree object.",
    ),
    (
      "pack-objects", "git pack-objects [<options>] <base-name>", "Create a packed archive of objects.",
    ),
    (
      "pack-refs", "git pack-refs [<options>]", "Pack heads and tags for efficient repository access.",
    ),
    (
      "prune", "git prune [<options>]", "Prune all unreachable objects from the object database.",
    ),
    ("reflog", "git reflog [<options>] [<ref>]", "Manage reflog information."),
    (
      "repack", "git repack [<options>]", "Pack unpacked objects in a repository.",
    ),
    (
      "revert", "git revert [<options>] <commit>...", "Revert some existing commits.",
    ),
    ("notes", "git notes [<command>] [<args>]", "Add or inspect object notes."),
    (
      "bisect", "git bisect [<options>] <subcommand> [<args>]", "Find by binary search the change that introduced a bug.",
    ),
    (
      "blame", "git blame [<options>] <file>", "Show what revision and author last modified each line.",
    ),
    (
      "receive-pack", "git receive-pack <git-dir>", "Receive what is pushed into the repository.",
    ),
    (
      "git-receive-pack", "git receive-pack <git-dir>", "Receive what is pushed into the repository.",
    ),
    (
      "rev-list", "git rev-list [<options>] <commit>...", "List commit objects in reverse chronological order.",
    ),
    (
      "rev-parse", "git rev-parse [<options>] <arg>...", "Parse revision specifications.",
    ),
    (
      "request-pull", "git request-pull <start> <url> [<end>]", "Generate a summary of pending changes.",
    ),
    (
      "send-pack", "git send-pack [<options>] <repository> [<refspec>...]", "Push objects over git protocol to another repository.",
    ),
    (
      "show-ref", "git show-ref [<options>] [<pattern>...]", "List references in a local repository.",
    ),
    (
      "shortlog", "git shortlog [<options>] [<revision-range>]", "Summarize git log output.",
    ),
    (
      "symbolic-ref", "git symbolic-ref [<options>] <name> [<ref>]", "Read, modify and delete symbolic refs.",
    ),
    (
      "submodule", "git submodule [<command>] [<args>]", "Initialize, update or inspect submodules.",
    ),
    (
      "sparse-checkout", "git sparse-checkout [<command>] [<args>]", "Initialize and modify the sparse-checkout config.",
    ),
    (
      "read-tree", "git read-tree [<options>] <tree-ish>", "Read tree information into the index.",
    ),
    (
      "update-index", "git update-index [<options>] [--] <file>...", "Register file contents in the index.",
    ),
    (
      "mktree", "git mktree [<options>]", "Build a tree-object from ls-tree formatted text.",
    ),
    (
      "maintenance", "git maintenance [<command>] [<options>]", "Run tasks to optimize Git repository data.",
    ),
    (
      "unpack-objects", "git unpack-objects [<options>]", "Unpack objects from a packed archive.",
    ),
    (
      "update-ref", "git update-ref [<options>] <refname> <newvalue> [<oldvalue>]",
      "Update the object name stored in a ref safely.",
    ),
    (
      "upload-pack", "git upload-pack [<options>] <git-dir>", "Send objects packed back to git-fetch-pack.",
    ),
    (
      "git-upload-pack", "git upload-pack [<options>] <git-dir>", "Send objects packed back to git-fetch-pack.",
    ),
    (
      "verify-pack", "git verify-pack [<options>] <pack>...", "Validate packed Git archive files.",
    ),
    (
      "write-tree", "git write-tree", "Create a tree object from the current index.",
    ),
    (
      "range-diff", "git range-diff [<options>] <range1> <range2>", "Compare two commit ranges.",
    ),
    (
      "multi-pack-index", "git multi-pack-index [<options>] <subcommand>", "Write and verify multi-pack-indexes.",
    ),
    (
      "cherry", "git cherry [<options>] <upstream> [<head>]", "Find commits yet to be applied to upstream.",
    ),
    (
      "am", "git am [<options>] <mbox>", "Apply a series of patches from a mailbox.",
    ),
    (
      "apply", "git apply [<options>] <patch>...", "Apply a patch to files and/or to the index.",
    ),
    (
      "completion", "bit completion <bash|zsh>", "Generate shell completion scripts.\n\nInstall:\n  bash: eval \"$(bit completion bash)\"\n  zsh:  eval \"$(bit completion zsh)\"",
    ),
    (
      "x/hooks", "bit/x/hooks <subcommand> [<args>]", "Manage hooks used by bit commands. Experimental: avoid overusing hooks as automation.",
    ),
    (
      "x/doc", "bit/x/doc <subcommand> [<args>]", "Experimental wiki-like docs and memo storage inside .bit/docs.",
    ),
    (
      "shell", "bit shell [--login] [<path>]", "Start an interactive bit shell with command forwarding.",
    ),
    ("version", "git version", "Show version information."),
  ]
}

///|
fn help_text_opt_in_enabled() -> Bool {
  match @sys.get_env_var("BIT_HELP_FULL") {
    Some(value) => {
      let normalized = value.to_lower()
      normalized == "1" || normalized == "true" || normalized == "yes"
    }
    None => false
  }
}

///|
fn help_text_external_dir() -> String? {
  match @sys.get_env_var("BIT_HELP_TEXT_DIR") {
    Some(value) => if value.length() > 0 { Some(value) } else { None }
    None => None
  }
}

///|
fn help_text_detail_key(cmd : String) -> String {
  match cmd {
    "show-branches" => "show-branch"
    "git-upload-pack" => "upload-pack"
    "git-receive-pack" => "receive-pack"
    _ => cmd
  }
}

///|
fn load_opt_in_help_text(cmd : String) -> String? {
  if not(help_text_opt_in_enabled()) {
    return None
  }
  let dir = match help_text_external_dir() {
    Some(path) => path
    None => return None
  }
  // Help details are loaded from external text files so default binaries do
  // not grow with long-form help text.
  let path = normalize_path(dir + "/" + help_text_detail_key(cmd) + ".txt")
  let fs = OsFs::new()
  let bytes = fs.read_file(path) catch { _ => return None }
  let text = decode_bytes(bytes) |> trim_string
  if text.length() == 0 {
    None
  } else {
    Some(text)
  }
}

///|
async fn show_command_help_from_specs(cmd : String, silent : Bool) -> Bool {
  for spec in show_command_help_specs() {
    if spec.0 == cmd {
      if not(silent) {
        let summary = match load_opt_in_help_text(spec.0) {
          Some(details) => spec.2 + "\n\n" + details
          None => spec.2
        }
        show_simple_command_help(spec.1, summary~)
      }
      return true
    }
  }
  false
}

///|
async fn show_command_help(cmd : String, silent? : Bool = false) -> Bool {
  match cmd {
    "hq" => {
      if not(silent) {
        print_hq_usage()
      }
      true
    }
    "subdir-clone" => {
      if not(silent) {
        print_subdir_clone_usage()
      }
      true
    }
    "worktree" => {
      if not(silent) {
        show_worktree_help()
      }
      true
    }
    "hub" => {
      if not(silent) {
        print_hub_usage()
      }
      true
    }
    "pr" => {
      if not(silent) {
        print_hub_pr_usage()
      }
      true
    }
    "issue" => {
      if not(silent) {
        print_hub_issue_usage()
      }
      true
    }
    "mcp" => {
      if not(silent) {
        print_mcp_usage()
      }
      true
    }
    "workspace" | "ws" => {
      if not(silent) {
        print_workspace_usage()
      }
      true
    }
    "repo" => {
      if not(silent) {
        print_repo_usage()
      }
      true
    }
    "init" => {
      if not(silent) {
        show_init_command_help()
      }
      true
    }
    "status" => {
      if not(silent) {
        show_status_command_help()
      }
      true
    }
    "add" => {
      if not(silent) {
        show_add_command_help()
      }
      true
    }
    "commit" => {
      if not(silent) {
        show_commit_command_help()
      }
      true
    }
    "log" => {
      if not(silent) {
        show_log_command_help()
      }
      true
    }
    "show" => {
      if not(silent) {
        show_show_command_help()
      }
      true
    }
    "x/hooks" => {
      if not(silent) {
        print_x_hooks_usage()
      }
      true
    }
    "rebase-ai" => {
      if not(silent) {
        show_simple_command_help(
          "git rebase-ai [<options>] <upstream>",
          summary="Rebase with AI conflict resolution (OpenRouter moonshotai/kimi-k2, supports --agent-loop).",
        )
      }
      true
    }
    "ai" => {
      if not(silent) {
        show_simple_command_help(
          "bit ai <command> [<args>]",
          summary="AI helpers.\n\nSubcommands:\n  rebase   AI-assisted rebase conflict resolution\n  merge    AI-assisted merge conflict resolution\n  cherry-pick AI-assisted cherry-pick conflict resolution\n  revert   AI-assisted revert conflict resolution\n  commit   AI-assisted commit message workflow",
        )
      }
      true
    }
    _ => show_command_help_from_specs(cmd, silent)
  }
}

///|
async fn handle_help(args : Array[String]) -> Unit {
  if args.length() == 0 {
    show_help()
    return
  }
  let cmd = args[0]
  if (cmd |> show_command_help |> not) {
    eprint_line("warning: help for '\{cmd}' is not implemented")
  }
}

///|
async fn main_async() -> Unit {
  let args = @sys.get_cli_args()
  run_main_for_args(args)
}

///|
async fn run_main_for_args(args : Array[String]) -> Unit {
  @bootstrap.init_stdin_guard()
  if args.length() < 2 {
    show_help()
    return ()
  }
  @bitnative.init_native_io()
  // Handle --version and --help early (can appear anywhere before command)
  for i in 1..<args.length() {
    match args[i] {
      "--version" | "version" => {
        print_line("git version 2.47.0 (bit)")
        return ()
      }
      "-h" | "--help" => {
        show_help()
        return ()
      }
      _ if not(args[i].has_prefix("-")) => break // Stop at first non-option
      _ => continue
    }
  }
  let opts = parse_global_options(args)
  guard opts.subcmd is Some(cmd) else {
    eprint_line("bit: missing subcommand")
    @sys.exit(2)
  }
  if opts.unsupported_global {
    eprint_line("bit: unsupported global option")
    @sys.exit(1)
  }
  match opts.git_dir {
    Some(dir) => {
      @sys.set_env_var("GIT_DIR", dir)
      @sys.set_env_var("GIT_SHIM_EXPLICIT_GIT_DIR", "1")
    }
    None => @sys.unset_env_var("GIT_SHIM_EXPLICIT_GIT_DIR")
  }
  match opts.work_tree {
    Some(dir) => @sys.set_env_var("GIT_WORK_TREE", dir)
    None => ()
  }
  // Store config overrides in environment variable for handlers to access
  if opts.config_overrides.length() > 0 {
    let encoded : Array[String] = []
    for pair in opts.config_overrides {
      // Encode as key=value, separated by newlines
      encoded.push(pair.0 + "=" + pair.1)
    }
    @sys.set_env_var("GIT_CONFIG_OVERRIDES", encoded.join("\n"))
  }
  let fs = OsFs::new()
  // Set working directory if -C was used
  match opts.cwd {
    Some(dir) => {
      @sys.set_env_var("GIT_SHIM_CWD", dir)
      if @sys.get_env_var("GIT_DIR") is None {
        @sys.set_env_var("GIT_DIR", default_repo_marker_path(fs, dir))
      }
      if @sys.get_env_var("GIT_WORK_TREE") is None {
        @sys.set_env_var("GIT_WORK_TREE", dir)
      }
    }
    None => ()
  }
  let aliases = load_global_aliases(fs)
  apply_alias_overrides(aliases, opts.config_overrides)
  let (alias_cmd, alias_rest) = match resolve_alias(aliases, cmd, opts.rest) {
    Resolved(resolved_cmd, resolved_rest) => (resolved_cmd, resolved_rest)
    Shell(cmdline) => {
      eprint_line("warning: shell alias is not supported: \{cmdline}")
      @sys.exit(1)
      (cmd, opts.rest)
    }
  }
  // If --bare was passed globally, prepend it to rest for init command
  let effective_rest = if opts.bare && alias_cmd == "init" {
    prepend_arg("--bare", alias_rest)
  } else {
    alias_rest
  }
  let (dispatch_cmd, dispatch_rest) = workspace_translate_implicit_command(
    opts.cwd,
    alias_cmd,
    effective_rest,
  )
  dispatch_command(dispatch_cmd, dispatch_rest) catch {
    err => {
      if @async.is_being_cancelled() || @async.is_cancellation_error(err) {
        raise err
      }
      exit_with_error("dispatch", err)
    }
  }
}

///|
struct GlobalOptions {
  subcmd : String?
  rest : Array[String]
  cwd : String?
  git_dir : String?
  work_tree : String?
  unsupported_global : Bool
  bare : Bool
  config_overrides : Array[(String, String)]
}

///|
fn resolve_global_path(raw : String, cwd : String?) -> String {
  if raw.has_prefix("/") {
    return raw
  }
  let base_dir = match cwd {
    Some(dir) => Some(dir)
    None =>
      match @sys.get_env_var("GIT_SHIM_PWD") {
        Some(dir) => Some(dir)
        None =>
          match @env.current_dir() {
            Some(dir) => Some(dir)
            None => @sys.get_env_var("PWD")
          }
      }
  }
  match base_dir {
    Some(base) => normalize_path(base + "/" + raw)
    None => raw
  }
}

///|
fn parse_global_options(args : Array[String]) -> GlobalOptions {
  let mut i = 1
  let mut in_opts = true
  let mut cwd : String? = None
  let mut git_dir : String? = None
  let mut work_tree : String? = None
  let mut unsupported_global = false
  let mut bare = false
  let mut subcmd : String? = None
  let mut rest : Array[String] = []
  let config_overrides : Array[(String, String)] = []
  while i < args.length() {
    let arg = args[i]
    if in_opts && arg == "--" {
      in_opts = false
      i += 1
      continue
    }
    if in_opts && arg == "--bare" {
      bare = true
      i += 1
      continue
    }
    if in_opts && arg == "-C" && i + 1 < args.length() {
      let raw = args[i + 1]
      cwd = Some(resolve_global_path(raw, cwd))
      i += 2
      continue
    }
    if in_opts && arg == "--git-dir" && i + 1 < args.length() {
      git_dir = Some(resolve_global_path(args[i + 1], cwd))
      i += 2
      continue
    }
    if in_opts && arg.has_prefix("--git-dir=") {
      let raw = String::unsafe_substring(arg, start=10, end=arg.length())
      git_dir = Some(resolve_global_path(raw, cwd))
      i += 1
      continue
    }
    if in_opts && arg == "--work-tree" && i + 1 < args.length() {
      work_tree = Some(resolve_global_path(args[i + 1], cwd))
      i += 2
      continue
    }
    if in_opts && arg.has_prefix("--work-tree=") {
      let raw = String::unsafe_substring(arg, start=12, end=arg.length())
      work_tree = Some(resolve_global_path(raw, cwd))
      i += 1
      continue
    }
    if in_opts && arg == "-c" && i + 1 < args.length() {
      // Parse -c key=value
      let kv = args[i + 1]
      match kv.find("=") {
        Some(eq_idx) => {
          let key = String::unsafe_substring(kv, start=0, end=eq_idx)
          let value = String::unsafe_substring(
            kv,
            start=eq_idx + 1,
            end=kv.length(),
          )
          config_overrides.push((key, value))
        }
        None =>
          // `-c key` is interpreted as boolean true by git.
          config_overrides.push((kv, "true"))
      }
      i += 2
      continue
    }
    if in_opts && is_unsupported_global_flag(arg) {
      unsupported_global = true
      if not(arg.contains("=")) && i + 1 < args.length() {
        i += 2
      } else {
        i += 1
      }
      continue
    }
    if in_opts && arg.has_prefix("-") {
      i += 1
      continue
    }
    subcmd = Some(arg)
    rest = collect_args(args, i + 1)
    break
  }
  {
    subcmd,
    rest,
    cwd,
    git_dir,
    work_tree,
    unsupported_global,
    bare,
    config_overrides,
  }
}

///|
fn is_unsupported_global_flag(arg : String) -> Bool {
  arg == "--namespace" ||
  arg == "--super-prefix" ||
  arg == "--git-path" ||
  arg.has_prefix("--namespace=") ||
  arg.has_prefix("--super-prefix=") ||
  arg.has_prefix("--git-path=")
}

///|
async fn dispatch_command(
  cmd : String,
  rest : Array[String],
) -> Unit raise Error {
  let normalized_cmd = normalize_dispatch_command(cmd)
  if not(command_handles_builtin_help(normalized_cmd)) {
    for arg in rest {
      if arg == "-h" || arg == "--help" {
        if (normalized_cmd |> show_command_help |> not) {
          eprint_line(
            "warning: help for '\{normalized_cmd}' is not implemented",
          )
        }
        return ()
      }
    }
  }
  dispatch_known_command(normalized_cmd, rest) catch {
    err => {
      if @async.is_being_cancelled() || @async.is_cancellation_error(err) {
        raise err
      }
      exit_with_error(command_error_name(normalized_cmd), err)
    }
  }
}

///|
fn normalize_dispatch_command(cmd : String) -> String {
  for
    entry in [
      ("git-receive-pack", "receive-pack"),
      ("git-upload-pack", "upload-pack"),
      ("show-branch", "show-branches"),
      ("--version", "version"),
      ("ws", "workspace"),
    ] {
    if cmd == entry.0 {
      return entry.1
    }
  }
  cmd
}

///|
fn command_handles_builtin_help(cmd : String) -> Bool {
  for
    name in [
      "receive-pack", "upload-pack", "pack-objects", "index-pack", "scalar", "branch",
      "merge",
    ] {
    if cmd == name {
      return true
    }
  }
  false
}

///|
fn command_error_name(cmd : String) -> String {
  if cmd == "subdir-clone" {
    "subdir"
  } else {
    cmd
  }
}

///|
async fn dispatch_known_command(
  cmd : String,
  rest : Array[String],
) -> Unit raise Error {
  match cmd {
    "help" => handle_help(rest)
    // Pack operations
    "receive-pack" => handle_receive_pack(rest)
    "upload-pack" => handle_upload_pack(rest)
    "pack-objects" => handle_pack_objects(rest)
    "index-pack" => handle_index_pack(rest)
    // Remote operations
    "remote" => handle_remote(rest)
    "clone" => handle_clone(rest)
    "fetch" => handle_fetch(rest)
    "pull" => handle_pull(rest)
    "push" => handle_push(rest)
    // Core operations
    "init" => handle_init(rest)
    "status" => handle_status(rest)
    "add" => handle_add(rest)
    "commit" => handle_commit(rest)
    "log" => handle_log(rest)
    "show" => handle_show(rest)
    "tree" => handle_tree(rest)
    "cat" => handle_cat(rest)
    // Branch operations
    "branch" => handle_branch(rest)
    "checkout" => handle_checkout(rest)
    "switch" => handle_switch(rest)
    "reset" => handle_reset(rest)
    "rebase" => handle_rebase(rest)
    "ai" => handle_ai(rest)
    "rebase-ai" => handle_rebase_ai(rest)
    "stash" => handle_stash(rest)
    "cherry-pick" => handle_cherry_pick(rest)
    "show-branches" => handle_show_branches(rest)
    // Misc operations
    "diff" => handle_diff(rest)
    "diff-files" => handle_diff_files(rest)
    "diff-index" => handle_diff_index(rest)
    "merge" => handle_merge(rest)
    "tag" => handle_tag(rest)
    "rm" => handle_rm(rest)
    "mv" => handle_mv(rest)
    "config" => handle_config(rest)
    "subdir-clone" => handle_subdir_clone(rest)
    "hub" => handle_hub(rest)
    "pr" => handle_hub_pr(rest)
    "issue" => handle_hub_issue(rest)
    "mcp" => handle_mcp(rest)
    "workspace" => handle_workspace(rest)
    "repo" => handle_repo(rest)
    "hq" => handle_hq(rest)
    "sparse-checkout" => handle_sparse_checkout(rest)
    "rev-parse" => handle_rev_parse(rest)
    "cat-file" => handle_cat_file(rest)
    "ls-files" => handle_ls_files(rest)
    "hash-object" => handle_hash_object(rest)
    "ls-tree" => handle_ls_tree(rest)
    "write-tree" => handle_write_tree(rest)
    "show-ref" => handle_show_ref(rest)
    "update-ref" => handle_update_ref(rest)
    "symbolic-ref" => handle_symbolic_ref(rest)
    "reflog" => handle_reflog(rest)
    "worktree" => handle_worktree(rest)
    "gc" => handle_gc(rest)
    "clean" => handle_clean(rest)
    "grep" => handle_grep(rest)
    "submodule" => handle_submodule(rest)
    "revert" => handle_revert(rest)
    "notes" => handle_notes(rest)
    "bisect" => handle_bisect(rest)
    "describe" => handle_describe(rest)
    "blame" => handle_blame(rest)
    "format-patch" => handle_format_patch(rest)
    "shortlog" => handle_shortlog(rest)
    "am" => handle_am(rest)
    "apply" => handle_apply(rest)
    "fsck" => handle_fsck(rest)
    "prune" => handle_prune(rest)
    "pack-refs" => handle_pack_refs(rest)
    "repack" => handle_repack(rest)
    "maintenance" => handle_maintenance(rest)
    "rev-list" => handle_rev_list(rest)
    "verify-pack" => handle_verify_pack(rest)
    "unpack-objects" => handle_unpack_objects(rest)
    "bundle" => handle_bundle(rest)
    "read-tree" => handle_read_tree(rest)
    "update-index" => handle_update_index(rest)
    "mktree" => handle_mktree(rest)
    "request-pull" => handle_request_pull(rest)
    "send-pack" => handle_send_pack(rest)
    "range-diff" => handle_range_diff(rest)
    "multi-pack-index" => handle_multi_pack_index(rest)
    "cherry" => handle_cherry(rest)
    "completion" => handle_completion(rest)
    "x/hooks" => handle_x_hooks(rest)
    "x/doc" => handle_x_doc(rest)
    "scalar" => handle_scalar(rest)
    "shell" => handle_shell(rest)
    "version" => print_line("git version 2.47.0 (bit)")
    // Error for unknown commands
    _ => {
      eprint_line("bit: '\{cmd}' is not a bit command")
      @sys.exit(1)
    }
  }
}

///|
async fn exit_with_error(cmd : String, err : Error) -> Unit {
  let msg = format_error_message(err)
  eprint_line("\{cmd} failed: \{msg}")
  @sys.exit(1)
}

///|
fn format_error_message(err : Error) -> String {
  match err {
    @bitcore.GitError::ProtocolError(msg) => msg
    @bitcore.GitError::InvalidObject(msg) => msg
    @bitcore.GitError::PackfileError(msg) => msg
    @bitcore.GitError::HashMismatch(_, _) => "hash mismatch"
    @bitcore.GitError::IoError(msg) => msg
    _ => err.to_string()
  }
}

///|
fn main {
  @async.run_async_main(main_async)
}

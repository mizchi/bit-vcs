///| Worktree handlers: worktree list/add/remove/prune/lock/unlock/move/repair

///|
/// Get absolute work root path for worktree operations
fn get_absolute_work_root() -> String {
  let root = get_work_root()
  let base = match @sys.get_env_var("GIT_SHIM_PWD") {
    Some(pwd) => Some(pwd)
    None => @sys.get_env_var("PWD")
  }
  if root == "." {
    // Use GIT_SHIM_PWD or PWD if available
    base.unwrap_or(".")
  } else if root.has_prefix("/") {
    root
  } else {
    // Relative path, try to make it absolute
    match base {
      Some(pwd) => pwd + "/" + root
      None => root
    }
  }
}

///|
fn get_absolute_worktree_cwd() -> String {
  let from_hint = fn(path : String) {
    if path.has_prefix("/") {
      normalize_path(path)
    } else {
      normalize_path(get_absolute_work_root() + "/" + path)
    }
  }
  if @sys.get_env_var("GIT_SHIM_CALLER_PWD") is Some(_) {
    return match @sys.get_env_var("GIT_SHIM_CWD") {
      Some(path) => from_hint(path)
      None =>
        match @sys.get_env_var("GIT_SHIM_PWD") {
          Some(path) => from_hint(path)
          None => get_absolute_work_root()
        }
    }
  }
  match @sys.get_env_var("PWD") {
    Some(path) => from_hint(path)
    None =>
      match @env.current_dir() {
        Some(path) => normalize_path(path)
        None => get_absolute_work_root()
      }
  }
}

///|
fn worktree_resolve_common_git_dir(
  fs : &@bitcore.RepoFileSystem,
  git_dir : String,
) -> String {
  let commondir_path = git_dir + "/commondir"
  if !fs.is_file(commondir_path) {
    return git_dir
  }
  let raw = decode_bytes(
    fs.read_file(commondir_path) catch {
      _ => return git_dir
    },
  )
  let rel = trim_string(raw)
  if rel.length() == 0 {
    return git_dir
  }
  if rel.has_prefix("/") {
    normalize_path(rel)
  } else {
    normalize_path(git_dir + "/" + rel)
  }
}

///|
fn worktree_quote_path_enabled(
  fs : &@bitcore.RepoFileSystem,
  root : String,
) -> Bool {
  let git_dir = resolve_git_dir(fs, root)
  let common_git_dir = worktree_resolve_common_git_dir(fs, git_dir)
  @bitlib.read_config_bool(fs, common_git_dir + "/config", "core", "quotepath").unwrap_or(
    true,
  )
}

///|
fn worktree_quote_path(path : String) -> String {
  let encoded = @utf8.encode(path)
  let mut needs_quote = false
  for b in encoded {
    let v = b.to_int()
    if v < 0x20 || v >= 0x7f || v == '\\'.to_int() || v == '"'.to_int() {
      needs_quote = true
      break
    }
  }
  if !needs_quote {
    return path
  }
  let buf = StringBuilder::new()
  buf.write_char('"')
  for b in encoded {
    let v = b.to_int()
    if v == '"'.to_int() {
      buf.write_string("\\\"")
    } else if v == '\\'.to_int() {
      buf.write_string("\\\\")
    } else if v == '\n'.to_int() {
      buf.write_string("\\n")
    } else if v == '\r'.to_int() {
      buf.write_string("\\r")
    } else if v == '\t'.to_int() {
      buf.write_string("\\t")
    } else if v < 0x20 || v >= 0x7f {
      buf.write_char('\\')
      buf.write_char((((v >> 6) & 7) + '0'.to_int()).unsafe_to_char())
      buf.write_char((((v >> 3) & 7) + '0'.to_int()).unsafe_to_char())
      buf.write_char(((v & 7) + '0'.to_int()).unsafe_to_char())
    } else {
      buf.write_char(b.to_char())
    }
  }
  buf.write_char('"')
  buf.to_string()
}

///|
fn worktree_display_path(path : String, quote_path : Bool) -> String {
  if quote_path {
    worktree_quote_path(path)
  } else {
    path
  }
}

///|
fn worktree_locked_reason_needs_quote(reason : String) -> Bool {
  for c in reason {
    match c {
      '\n' | '\r' | '\\' | '"' => return true
      _ => ()
    }
  }
  false
}

///|
fn worktree_format_locked_porcelain(reason : String?) -> String? {
  match reason {
    None => None
    Some(r) =>
      if r.length() == 0 {
        Some("locked")
      } else if worktree_locked_reason_needs_quote(r) {
        Some("locked \"" + escape_lock_reason(r) + "\"")
      } else {
        Some("locked " + r)
      }
  }
}

///|
fn worktree_verbose_locked_suffix(reason : String?) -> String {
  match reason {
    Some(r) if r.length() > 0 => ""
    _ => " locked"
  }
}

///|
fn worktree_default_branch_display(wt : @bitlib.WorktreeInfo) -> String {
  if wt.is_bare {
    "(bare)"
  } else {
    match wt.branch {
      Some(b) => "[\{b}]"
      None =>
        match wt.head_id {
          Some(_) => "(detached HEAD)"
          None => "(error)"
        }
    }
  }
}

///|
fn infer_default_worktree_branch_name(path : String) -> String {
  let trimmed = if path.has_suffix("/") && path.length() > 1 {
    String::unsafe_substring(path, start=0, end=path.length() - 1)
  } else {
    path
  }
  match trimmed.rev_find("/") {
    Some(idx) =>
      String::unsafe_substring(trimmed, start=idx + 1, end=trimmed.length())
    None => trimmed
  }
}

///|
fn worktree_has_ref_files(
  fs : &@bitcore.RepoFileSystem,
  dir : String,
) -> Bool raise Error {
  if !fs.is_dir(dir) {
    return false
  }
  for entry in fs.readdir(dir) {
    if entry == "." || entry == ".." {
      continue
    }
    let path = dir + "/" + entry
    if fs.is_file(path) {
      return true
    }
    if fs.is_dir(path) && worktree_has_ref_files(fs, path) {
      return true
    }
  }
  false
}

///|
fn worktree_guess_remote_enabled(
  fs : &@bitcore.RepoFileSystem,
  git_dir : String,
  guess_remote : Bool?,
) -> Bool {
  guess_remote.unwrap_or(
    @bitlib.read_config_bool(fs, git_dir + "/config", "worktree", "guessRemote").unwrap_or(
      false,
    ),
  )
}

///|
enum WorktreeLocalRefsStatus {
  Available
  InvalidHead(String, String)
  Missing
}

///|
struct WorktreeRemoteGuess {
  remote_name : String
  refname : String
}

///|
fn worktree_head_contents(
  fs : &@bitcore.RepoFileSystem,
  git_dir : String,
) -> String raise Error {
  trim_chars(@utf8.decode_lossy(fs.read_file(git_dir + "/HEAD")[:]), " \t\r\n")
}

///|
fn worktree_local_refs_status(
  fs : &@bitcore.RepoFileSystem,
  git_dir : String,
  common_git_dir : String,
) -> WorktreeLocalRefsStatus raise Error {
  if @bitlib.resolve_head_commit(fs, git_dir) is Some(_) {
    return WorktreeLocalRefsStatus::Available
  }
  let (_, local_branches) = @bitlib.list_branches(fs, common_git_dir)
  if local_branches.length() > 0 {
    return WorktreeLocalRefsStatus::InvalidHead(
      normalize_path(git_dir + "/HEAD"),
      worktree_head_contents(fs, git_dir),
    )
  }
  WorktreeLocalRefsStatus::Missing
}

///|
async fn worktree_print_invalid_head_warning(
  path : String,
  contents : String,
) -> Unit {
  eprint_line("warning: HEAD points to an invalid (or orphaned) reference.")
  eprint_line("warning: HEAD path: '\{path}'")
  eprint_line("warning: HEAD contents: '\{contents}'")
}

///|
async fn worktree_print_orphan_hint(
  path : String,
  new_branch : String?,
) -> Unit {
  eprint_line(
    "hint: If you meant to create a worktree containing a new unborn branch",
  )
  eprint_line(
    "hint: (branch with no commits) for this repository, you can do so",
  )
  eprint_line("hint: using the --orphan flag:")
  eprint_line("hint: ")
  match new_branch {
    Some(branch) =>
      eprint_line("hint:     git worktree add --orphan -b \{branch} \{path}")
    None => eprint_line("hint:     git worktree add --orphan \{path}")
  }
}

///|
fn worktree_checkout_default_remote(
  fs : &@bitcore.RepoFileSystem,
  git_dir : String,
) -> String? {
  @bitlib.read_config_value(
    fs,
    git_dir + "/config",
    "checkout",
    "defaultRemote",
  )
}

///|
fn worktree_guess_remote_branch(
  fs : &@bitcore.RepoFileSystem,
  git_dir : String,
  branch : String,
) -> WorktreeRemoteGuess? raise Error {
  let matches : Array[WorktreeRemoteGuess] = []
  for remote_name in @bitlib.list_remotes(fs, git_dir) {
    let refname = "refs/remotes/" + remote_name + "/" + branch
    if @bitlib.resolve_ref(fs, git_dir, refname) is Some(_) {
      matches.push({ remote_name, refname })
    }
  }
  if matches.length() == 1 {
    return Some(matches[0])
  }
  match worktree_checkout_default_remote(fs, git_dir) {
    Some(default_remote) =>
      for candidate in matches {
        if candidate.remote_name == default_remote {
          return Some(candidate)
        }
      }
    None => ()
  }
  None
}

///|
async fn worktree_should_infer_orphan(
  fs : &@bitcore.RepoFileSystem,
  git_dir : String,
  common_git_dir : String,
  quiet : Bool,
  no_checkout : Bool,
  force : Bool,
  guess_remote : Bool?,
  track_requested : Bool,
  check_remote_refs : Bool,
) -> Bool raise Error {
  match worktree_local_refs_status(fs, git_dir, common_git_dir) {
    WorktreeLocalRefsStatus::Available => return false
    WorktreeLocalRefsStatus::InvalidHead(path, contents) => {
      if !quiet {
        worktree_print_invalid_head_warning(path, contents)
      }
      return false
    }
    WorktreeLocalRefsStatus::Missing => ()
  }
  let guess_enabled = worktree_guess_remote_enabled(
    fs, common_git_dir, guess_remote,
  )
  if check_remote_refs && guess_enabled {
    if worktree_has_ref_files(fs, common_git_dir + "/refs/remotes") {
      return false
    }
    if !force && @bitlib.list_remotes(fs, common_git_dir).length() > 0 {
      eprint_line(
        "fatal: No local or remote refs exist despite at least one remote present, stopping; use 'add -f' to override or fetch a remote first",
      )
      @sys.exit(128)
    }
  }
  if !quiet {
    eprint_line("No possible source branch, inferring '--orphan'")
  }
  if track_requested {
    eprint_line(
      "fatal: options '--orphan' and '--track' cannot be used together",
    )
    @sys.exit(128)
  }
  if no_checkout {
    eprint_line(
      "fatal: options '--orphan' and '--no-checkout' cannot be used together",
    )
    @sys.exit(128)
  }
  true
}

///|
async fn handle_worktree(args : Array[String]) -> Unit raise Error {
  if args.length() == 0 {
    show_worktree_help()
    return ()
  }
  let passthrough : Array[String] = []
  let mut subcmd : String? = None
  let rest : Array[String] = []
  for arg in args {
    if subcmd is None {
      match arg {
        "list"
        | "add"
        | "remove"
        | "prune"
        | "lock"
        | "unlock"
        | "move"
        | "repair" => subcmd = Some(arg)
        _ => passthrough.push(arg)
      }
    } else {
      rest.push(arg)
    }
  }
  guard subcmd is Some(subcommand) else {
    eprint_line("Unknown worktree subcommand: " + args[0])
    show_worktree_help()
    @sys.exit(1)
  }
  let normalized_args : Array[String] = []
  for arg in passthrough {
    normalized_args.push(arg)
  }
  for arg in rest {
    normalized_args.push(arg)
  }
  match subcommand {
    "list" => handle_worktree_list(normalized_args)
    "add" => handle_worktree_add(normalized_args)
    "remove" => handle_worktree_remove(normalized_args)
    "prune" => handle_worktree_prune(normalized_args)
    "lock" => handle_worktree_lock(normalized_args)
    "unlock" => handle_worktree_unlock(normalized_args)
    "move" => handle_worktree_move(normalized_args)
    "repair" => handle_worktree_repair(normalized_args)
    _ => {
      eprint_line("Unknown worktree subcommand: \{subcommand}")
      show_worktree_help()
      @sys.exit(1)
    }
  }
}

///|
async fn show_worktree_help() -> Unit {
  let help =
    #|usage: git worktree <command> [<args>]
    #|
    #|Commands:
    #|   list          List all worktrees
    #|   add           Create a new worktree
    #|   remove        Remove a worktree
    #|   prune         Prune worktree information
    #|   lock          Lock a worktree
    #|   unlock        Unlock a worktree
    #|   move          Move a worktree
    #|   repair        Repair worktree administrative files
    #|
    #|See 'git worktree <command> -h' for more information.
  print_line(help)
}

///|
async fn handle_worktree_list(args : Array[String]) -> Unit raise Error {
  let root = get_absolute_work_root()
  let fs = OsFs::new()
  let mut porcelain = false
  let mut nul_terminated = false
  let mut verbose = false
  for arg in args {
    match arg {
      "--porcelain" => porcelain = true
      "-z" => nul_terminated = true
      "--verbose" | "-v" => verbose = true
      _ => ()
    }
  }
  // -z requires --porcelain
  if nul_terminated && !porcelain {
    eprint_line("fatal: -z requires --porcelain")
    @sys.exit(1)
  }
  // --verbose and --porcelain are mutually exclusive
  if verbose && porcelain {
    eprint_line("fatal: --verbose and --porcelain are mutually exclusive")
    @sys.exit(1)
  }
  let worktrees = @bitlib.list_worktrees(fs, root)
  let quote_path = worktree_quote_path_enabled(fs, root)
  let mut path_width = 0
  for wt in worktrees {
    let width = worktree_display_path(wt.path, quote_path).length()
    if width > path_width {
      path_width = width
    }
  }
  if porcelain {
    for wt in worktrees {
      let sep = if nul_terminated { "\u{00}" } else { "\n" }
      let end = if nul_terminated { "\u{00}" } else { "\n" }
      print_str("worktree \{wt.path}\{sep}")
      if wt.is_bare {
        print_str("bare\{sep}")
        print_str(end)
        continue
      }
      let head_hex = match wt.head_id {
        Some(id) => id.to_hex()
        None => "0000000000000000000000000000000000000000"
      }
      print_str("HEAD \{head_hex}\{sep}")
      if wt.branch is Some(b) {
        print_str("branch refs/heads/\{b}\{sep}")
      } else if wt.head_id is Some(_) {
        print_str("detached\{sep}")
      }
      if wt.locked {
        let reason = @bitlib.get_worktree_lock_reason(fs, root, wt.path)
        match worktree_format_locked_porcelain(reason) {
          Some(line) => print_str("\{line}\{sep}")
          None => print_str("locked\{sep}")
        }
      }
      if !wt.is_main {
        let prunable = @bitlib.get_worktree_prunable_reason(fs, root, wt.path)
        match prunable {
          Some(r) => print_str("prunable \{r}\{sep}")
          None => ()
        }
      }
      print_str(end)
    }
  } else if verbose {
    for wt in worktrees {
      let display_path = worktree_display_path(wt.path, quote_path)
      let padding = " ".repeat(path_width - display_path.length() + 1)
      let branch_str = worktree_default_branch_display(wt)
      if wt.is_bare {
        print_line("\{display_path}\{padding}\{branch_str}")
        continue
      }
      let commit_str = match wt.head_id {
        Some(id) => string_slice_to(id.to_hex(), 7)
        None => "0000000"
      }
      let lock_reason = if wt.locked {
        @bitlib.get_worktree_lock_reason(fs, root, wt.path)
      } else {
        None
      }
      let locked_str = if wt.locked {
        worktree_verbose_locked_suffix(lock_reason)
      } else {
        ""
      }
      print_line(
        "\{display_path}\{padding}\{commit_str} \{branch_str}\{locked_str}",
      )
      if wt.locked {
        match lock_reason {
          Some(r) => if r.length() > 0 { print_line("\tlocked: \{r}") }
          None => ()
        }
      }
      if !wt.is_main {
        let prunable = @bitlib.get_worktree_prunable_reason(fs, root, wt.path)
        match prunable {
          Some(r) => print_line("\tprunable: \{r}")
          None => ()
        }
      }
    }
  } else {
    for wt in worktrees {
      let display_path = worktree_display_path(wt.path, quote_path)
      let padding = " ".repeat(path_width - display_path.length() + 1)
      let branch_str = worktree_default_branch_display(wt)
      if wt.is_bare {
        print_line("\{display_path}\{padding}\{branch_str}")
        continue
      }
      let commit_str = match wt.head_id {
        Some(id) => string_slice_to(id.to_hex(), 7)
        None => "0000000"
      }
      let mut suffix = ""
      if wt.locked {
        suffix = suffix + " locked"
      }
      if !wt.is_main {
        let prunable = @bitlib.get_worktree_prunable_reason(fs, root, wt.path)
        if prunable is Some(_) {
          suffix = suffix + " prunable"
        }
      }
      print_line(
        "\{display_path}\{padding}\{commit_str} \{branch_str}\{suffix}",
      )
    }
  }
}

///|
fn escape_lock_reason(reason : String) -> String {
  let sb = StringBuilder::new()
  for c in reason {
    match c {
      '\n' => {
        sb.write_char('\\')
        sb.write_char('n')
      }
      '\r' => {
        sb.write_char('\\')
        sb.write_char('r')
      }
      '\\' => {
        sb.write_char('\\')
        sb.write_char('\\')
      }
      '"' => {
        sb.write_char('\\')
        sb.write_char('"')
      }
      _ => sb.write_char(c)
    }
  }
  sb.to_string()
}

///|
fn worktree_parse_expire_before_sec(value : String) -> Int64? {
  if value == "now" {
    return Some(get_current_timestamp())
  }
  if value.has_suffix(".days.ago") {
    let count_str = String::unsafe_substring(
      value,
      start=0,
      end=value.length() - 9,
    )
    if count_str.length() == 0 {
      return None
    }
    let mut days = 0L
    for c in count_str {
      if c < '0' || c > '9' {
        return None
      }
      let digit = c.to_int() - '0'.to_int()
      days = days * 10L + digit.to_int64()
    }
    Some(get_current_timestamp() - days * 86400L)
  } else {
    None
  }
}

///|
async fn handle_worktree_add(args : Array[String]) -> Unit raise Error {
  let root = get_absolute_work_root()
  let cwd = get_absolute_worktree_cwd()
  let fs = OsFs::new()
  // Parse arguments
  let mut detach = false
  let mut force = false
  let mut lock = false
  let mut quiet = false
  let mut orphan = false
  let mut no_checkout = false
  let mut track_requested = false
  let mut no_track = false
  let mut relative_paths : Bool? = None
  let mut guess_remote : Bool? = None
  let mut lock_reason : String? = None
  let mut new_branch : String? = None
  let mut new_branch_opt : String? = None
  let mut path : String? = None
  let mut commit_ish : String? = None
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    match arg {
      "--detach" | "-d" => detach = true
      "--force" | "-f" => force = true
      "--quiet" | "-q" => quiet = true
      "--lock" => lock = true
      "--orphan" => orphan = true
      "--no-checkout" => no_checkout = true
      "--track" => track_requested = true
      _ if arg.has_prefix("--track=") => track_requested = true
      "--no-track" => no_track = true
      "--relative-paths" => relative_paths = Some(true)
      "--no-relative-paths" => relative_paths = Some(false)
      "--guess-remote" => guess_remote = Some(true)
      "--no-guess-remote" => guess_remote = Some(false)
      "--checkout" => ()
      "--reason" if i + 1 < args.length() => {
        lock_reason = Some(args[i + 1])
        i += 2
        continue
      }
      "-b" if i + 1 < args.length() => {
        if new_branch_opt is Some(existing) && existing != "-b" {
          eprint_line(
            "fatal: options '\{existing}' and '-b' cannot be used together",
          )
          @sys.exit(128)
        }
        new_branch = Some(args[i + 1])
        new_branch_opt = Some("-b")
        i += 2
        continue
      }
      "-B" if i + 1 < args.length() => {
        if new_branch_opt is Some(existing) && existing != "-B" {
          eprint_line(
            "fatal: options '\{existing}' and '-B' cannot be used together",
          )
          @sys.exit(128)
        }
        new_branch = Some(args[i + 1])
        new_branch_opt = Some("-B")
        i += 2
        continue
      }
      "-" =>
        if path is None {
          path = Some(arg)
        } else if commit_ish is None {
          commit_ish = Some(arg)
        }
      _ if arg.has_prefix("-b") => new_branch = Some(string_slice_from(arg, 2))
      _ if arg.has_prefix("-") => warn_unimplemented_arg("worktree", arg)
      _ =>
        if path is None {
          path = Some(arg)
        } else if commit_ish is None {
          commit_ish = Some(arg)
        }
    }
    i += 1
  }
  guard path is Some(wt_path) else {
    eprint_line("usage: git worktree add [<options>] <path> [<commit-ish>]")
    @sys.exit(1)
  }
  if lock_reason is Some(_) && !lock {
    eprint_line("fatal: --reason requires --lock")
    @sys.exit(1)
  }
  if detach && new_branch_opt is Some(opt) {
    eprint_line(
      "fatal: options '\{opt}' and '--detach' cannot be used together",
    )
    @sys.exit(128)
  }
  if orphan && detach {
    eprint_line(
      "fatal: options '--orphan' and '--detach' cannot be used together",
    )
    @sys.exit(128)
  }
  if orphan && no_checkout {
    eprint_line(
      "fatal: options '--orphan' and '--no-checkout' cannot be used together",
    )
    @sys.exit(128)
  }
  if orphan && commit_ish is Some(_) {
    eprint_line(
      "fatal: options '--orphan' and '<commit-ish>' cannot be used together",
    )
    @sys.exit(128)
  }
  let git_dir = resolve_git_dir(fs, root)
  let common_git_dir = worktree_resolve_common_git_dir(fs, git_dir)
  let used_new_branch_options = new_branch_opt is Some(_)
  let mut branch = commit_ish.unwrap_or("HEAD")
  let mut tracking_remote : String? = None
  let mut tracking_merge : String? = None
  if orphan && new_branch is None {
    new_branch = Some(infer_default_worktree_branch_name(wt_path))
  } else if orphan {
    ()
  } else if detach {
    if branch == "HEAD" {
      match worktree_local_refs_status(fs, git_dir, common_git_dir) {
        WorktreeLocalRefsStatus::InvalidHead(path, contents) if !quiet =>
          worktree_print_invalid_head_warning(path, contents)
        _ => ()
      }
    }
  } else if commit_ish is None && new_branch is Some(_) {
    orphan = worktree_should_infer_orphan(
      fs, git_dir, common_git_dir, quiet, no_checkout, force, guess_remote, track_requested,
      false,
    )
  } else if commit_ish is None {
    let dwim_branch = infer_default_worktree_branch_name(wt_path)
    if @bitlib.resolve_ref(fs, common_git_dir, "refs/heads/" + dwim_branch)
      is Some(_) {
      branch = dwim_branch
    } else {
      let guess_enabled = worktree_guess_remote_enabled(
        fs, common_git_dir, guess_remote,
      )
      if guess_enabled {
        match worktree_guess_remote_branch(fs, common_git_dir, dwim_branch) {
          Some(remote_guess) => {
            branch = remote_guess.refname
            new_branch = Some(dwim_branch)
            if !no_track {
              tracking_remote = Some(remote_guess.remote_name)
              tracking_merge = Some("refs/heads/" + dwim_branch)
            }
          }
          None => {
            new_branch = Some(dwim_branch)
            orphan = worktree_should_infer_orphan(
              fs, git_dir, common_git_dir, quiet, no_checkout, force, guess_remote,
              track_requested, true,
            )
          }
        }
      } else {
        new_branch = Some(dwim_branch)
        orphan = worktree_should_infer_orphan(
          fs, git_dir, common_git_dir, quiet, no_checkout, force, guess_remote, track_requested,
          true,
        )
      }
    }
  } else if !detach {
    if branch != "-" && @bitlib.rev_parse(fs, common_git_dir, branch) is None {
      match worktree_guess_remote_branch(fs, common_git_dir, branch) {
        Some(remote_guess) => {
          let branch_name = branch
          new_branch = Some(branch_name)
          branch = remote_guess.refname
          if !no_track {
            tracking_remote = Some(remote_guess.remote_name)
            tracking_merge = Some("refs/heads/" + branch_name)
          }
        }
        None => ()
      }
    }
    if branch == "HEAD" {
      match worktree_local_refs_status(fs, git_dir, common_git_dir) {
        WorktreeLocalRefsStatus::InvalidHead(path, contents) if !quiet =>
          worktree_print_invalid_head_warning(path, contents)
        _ => ()
      }
    }
  }
  if !orphan &&
    branch != "-" &&
    @bitlib.rev_parse(fs, common_git_dir, branch) is None {
    if !quiet && commit_ish is None {
      let hint_branch = if used_new_branch_options { new_branch } else { None }
      worktree_print_orphan_hint(wt_path, hint_branch)
    }
    eprint_line("fatal: invalid reference: \{branch}")
    @sys.exit(128)
  }
  let resolved_wt_path = if wt_path.has_prefix("/") {
    normalize_path(wt_path)
  } else {
    normalize_path(cwd + "/" + wt_path)
  }
  @bitlib.create_worktree(
    fs,
    fs,
    root,
    resolved_wt_path,
    if orphan {
      None
    } else if branch == "HEAD" && commit_ish is None {
      None
    } else {
      Some(branch)
    },
    detach~,
    force~,
    new_branch~,
    relative_paths~,
    orphan~,
    checkout_files=!no_checkout,
  )
  if !orphan && !no_checkout {
    let worktree_git_dir = resolve_git_dir(fs, resolved_wt_path)
    match @bitlib.resolve_head_commit(fs, worktree_git_dir) {
      Some(commit_id) =>
        @bitlibnative.apply_worktree_modes_from_commit(
          fs, fs, resolved_wt_path, common_git_dir, commit_id,
        )
      None => ()
    }
  }
  if lock {
    @bitlib.lock_worktree(fs, fs, root, resolved_wt_path, reason=lock_reason)
  }
  match (new_branch, tracking_remote, tracking_merge) {
    (Some(branch_name), Some(remote_name), Some(merge_ref)) => {
      @bitlib.set_config_key(
        fs, fs, common_git_dir, "branch", branch_name, "remote", remote_name,
      )
      @bitlib.set_config_key(
        fs, fs, common_git_dir, "branch", branch_name, "merge", merge_ref,
      )
    }
    _ => ()
  }
  // Print success message
  if !quiet {
    match (new_branch, detach, commit_ish, branch) {
      (Some(b), _, _, _) => print_line("Preparing worktree (new branch '\{b}')")
      (None, true, _, _) => print_line("Preparing worktree (detached HEAD)")
      (None, false, Some(spec), _) =>
        print_line("Preparing worktree (checking out '\{spec}')")
      (None, false, None, spec) if spec != "HEAD" =>
        print_line("Preparing worktree (checking out '\{spec}')")
      _ => print_line("Preparing worktree (HEAD)")
    }
    print_line("HEAD is now at \{wt_path}")
  }
}

///|
async fn handle_worktree_remove(args : Array[String]) -> Unit raise Error {
  let root = get_absolute_work_root()
  let fs = OsFs::new()
  let mut force_count = 0
  let mut path : String? = None
  for arg in args {
    match arg {
      "--force" | "-f" => force_count += 1
      _ if !arg.has_prefix("-") => path = Some(arg)
      _ if arg.has_prefix("-") => warn_unimplemented_arg("worktree", arg)
      _ => ()
    }
  }
  guard path is Some(wt_path) else {
    eprint_line("usage: git worktree remove [--force] <worktree>")
    @sys.exit(1)
  }
  @bitlib.remove_worktree(fs, fs, root, wt_path, force_level=force_count)
  print_line("Removed worktree '\{wt_path}'")
}

///|
async fn handle_worktree_prune(args : Array[String]) -> Unit raise Error {
  let root = get_absolute_work_root()
  let fs = OsFs::new()
  let mut dry_run = false
  let mut verbose = false
  let mut expire_before_sec : Int64? = None
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    match arg {
      "--dry-run" | "-n" => dry_run = true
      "--verbose" | "-v" => verbose = true
      "--expire" if i + 1 < args.length() => {
        expire_before_sec = worktree_parse_expire_before_sec(args[i + 1])
        i += 2
        continue
      }
      _ if arg.has_prefix("--expire=") =>
        expire_before_sec = worktree_parse_expire_before_sec(
          String::unsafe_substring(arg, start=9, end=arg.length()),
        )
      _ if !arg.has_prefix("-") => {
        eprint_line("fatal: too many arguments")
        @sys.exit(128)
      }
      _ if arg.has_prefix("-") => warn_unimplemented_arg("worktree", arg)
      _ => ()
    }
    i += 1
  }
  let pruned = @bitlib.prune_worktrees_detailed(
    fs,
    fs,
    root,
    dry_run~,
    expire_before_sec~,
  )
  if pruned.length() == 0 {
    if verbose {
      eprint_line("Nothing to prune")
    }
  } else {
    for entry in pruned {
      let suffix = if entry.reason.length() > 0 {
        ": " + entry.reason
      } else {
        ""
      }
      if dry_run {
        if verbose {
          eprint_line("Would remove worktrees/\{entry.name}\{suffix}")
        } else {
          print_line("Would remove worktrees/\{entry.name}")
        }
      } else if verbose {
        eprint_line("Removing worktrees/\{entry.name}\{suffix}")
      } else {
        print_line("Removing worktrees/\{entry.name}")
      }
    }
  }
}

///|
async fn handle_worktree_lock(args : Array[String]) -> Unit raise Error {
  let root = get_absolute_work_root()
  let fs = OsFs::new()
  let mut path : String? = None
  let mut reason : String? = None
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    match arg {
      "--reason" if i + 1 < args.length() => {
        reason = Some(args[i + 1])
        i += 2
        continue
      }
      _ if arg.has_prefix("--reason=") =>
        reason = Some(string_slice_from(arg, 9))
      _ if !arg.has_prefix("-") => path = Some(arg)
      _ if arg.has_prefix("-") => warn_unimplemented_arg("worktree", arg)
      _ => ()
    }
    i += 1
  }
  guard path is Some(wt_path) else {
    eprint_line("usage: git worktree lock [--reason <string>] <worktree>")
    @sys.exit(1)
  }
  @bitlib.lock_worktree(fs, fs, root, wt_path, reason~)
}

///|
async fn handle_worktree_unlock(args : Array[String]) -> Unit raise Error {
  let root = get_absolute_work_root()
  let fs = OsFs::new()
  let mut path : String? = None
  for arg in args {
    if !arg.has_prefix("-") {
      path = Some(arg)
    } else {
      warn_unimplemented_arg("worktree", arg)
    }
  }
  guard path is Some(wt_path) else {
    eprint_line("usage: git worktree unlock <worktree>")
    @sys.exit(1)
  }
  @bitlib.unlock_worktree(fs, fs, root, wt_path)
}

///|
async fn handle_worktree_move(args : Array[String]) -> Unit raise Error {
  let root = get_absolute_work_root()
  let fs = OsFs::new()
  let mut force_count = 0
  let mut relative_paths : Bool? = None
  let positional : Array[String] = []
  for arg in args {
    match arg {
      "--force" | "-f" => force_count += 1
      "--relative-paths" => relative_paths = Some(true)
      "--no-relative-paths" => relative_paths = Some(false)
      _ if !arg.has_prefix("-") => positional.push(arg)
      _ if arg.has_prefix("-") => warn_unimplemented_arg("worktree", arg)
      _ => ()
    }
  }
  if positional.length() != 2 {
    eprint_line("usage: git worktree move [--force] <worktree> <new-path>")
    @sys.exit(1)
  }
  let source = positional[0]
  let dest = positional[1]
  @bitlib.move_worktree(
    fs,
    fs,
    root,
    source,
    dest,
    force_level=force_count,
    relative_paths~,
  )
  print_line("Moving '\{source}' to '\{dest}'")
}

///|
async fn handle_worktree_repair(args : Array[String]) -> Unit raise Error {
  let root = get_absolute_work_root()
  let fs = OsFs::new()
  let paths : Array[String] = []
  let mut relative_paths : Bool? = None
  for arg in args {
    match arg {
      "--relative-paths" => relative_paths = Some(true)
      "--no-relative-paths" => relative_paths = Some(false)
      _ if !arg.has_prefix("-") => paths.push(arg)
      _ => warn_unimplemented_arg("worktree", arg)
    }
  }
  let result = @bitlib.repair_worktree_detailed(
    fs,
    fs,
    root,
    worktree_paths=paths,
    relative_paths~,
  )
  for warning in result.warnings {
    eprint_line(warning)
  }
}

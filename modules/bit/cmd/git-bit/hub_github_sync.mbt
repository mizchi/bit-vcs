///| GitHub sync subcommands for `git-bit issue sync`

///|
fn print_hub_issue_sync_usage() -> Unit {
  println("Usage: git-bit issue sync <subcommand> [<args>]")
  println("")
  println("Subcommands:")
  println(
    "  pull --repo <owner/repo> [--include-prs] [--comments append-only|full|no-delete]",
  )
  println(
    "  push --github --repo <owner/repo> [--apply] [--force-remote] [--include-prs] [--comments append-only|full|no-delete]",
  )
  println("  status --repo <owner/repo>")
  println("  install-hook                            (install git hook)")
}

///|
priv struct HubIssueSyncPushOptions {
  repo : String?
  github_flag : Bool
  apply : Bool
  include_prs : Bool
  comments_mode : String
  force_remote : Bool
  help : Bool
}

///|
fn parse_hub_issue_sync_push_options(
  args : Array[String],
) -> HubIssueSyncPushOptions {
  let mut repo : String? = None
  let mut github_flag = false
  let mut apply = false
  let mut include_prs = false
  let mut comments_mode = "append-only"
  let mut force_remote = false
  let mut help = false
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    if arg == "--repo" && i + 1 < args.length() {
      i += 1
      repo = Some(args[i])
    } else if arg.has_prefix("--repo=") {
      repo = Some(String::unsafe_substring(arg, start=7, end=arg.length()))
    } else if arg == "--github" {
      github_flag = true
    } else if arg == "--apply" {
      apply = true
    } else if arg == "--include-prs" {
      include_prs = true
    } else if arg == "--comments" && i + 1 < args.length() {
      i += 1
      comments_mode = args[i]
    } else if arg.has_prefix("--comments=") {
      comments_mode = String::unsafe_substring(arg, start=11, end=arg.length())
    } else if arg == "--force-remote" {
      force_remote = true
    } else if arg == "-h" || arg == "--help" {
      help = true
    }
    i += 1
  }
  { repo, github_flag, apply, include_prs, comments_mode, force_remote, help }
}

///|
priv struct HubIssueSyncBidirectionalOptions {
  repo : String?
  github_flag : Bool
  apply : Bool
  conflict : String
  comments_mode : String
  include_prs : Bool
  since : String
  state : String
  force_remote : Bool
  help : Bool
}

///|
fn parse_hub_issue_sync_bidirectional_options(
  args : Array[String],
) -> HubIssueSyncBidirectionalOptions {
  let mut repo : String? = None
  let mut github_flag = false
  let mut apply = false
  let mut conflict = "newer-wins"
  let mut comments_mode = "append-only"
  let mut include_prs = false
  let mut since = ""
  let mut state = "all"
  let mut force_remote = false
  let mut help = false
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    if arg == "--repo" && i + 1 < args.length() {
      i += 1
      repo = Some(args[i])
    } else if arg.has_prefix("--repo=") {
      repo = Some(String::unsafe_substring(arg, start=7, end=arg.length()))
    } else if arg == "--github" {
      github_flag = true
    } else if arg == "--apply" {
      apply = true
    } else if arg == "--conflict" && i + 1 < args.length() {
      i += 1
      conflict = args[i]
    } else if arg.has_prefix("--conflict=") {
      conflict = String::unsafe_substring(arg, start=11, end=arg.length())
    } else if arg == "--comments" && i + 1 < args.length() {
      i += 1
      comments_mode = args[i]
    } else if arg.has_prefix("--comments=") {
      comments_mode = String::unsafe_substring(arg, start=11, end=arg.length())
    } else if arg == "--include-prs" {
      include_prs = true
    } else if arg == "--since" && i + 1 < args.length() {
      i += 1
      since = args[i]
    } else if arg.has_prefix("--since=") {
      since = String::unsafe_substring(arg, start=8, end=arg.length())
    } else if arg == "--state" && i + 1 < args.length() {
      i += 1
      state = args[i]
    } else if arg.has_prefix("--state=") {
      state = String::unsafe_substring(arg, start=8, end=arg.length())
    } else if arg == "--force-remote" {
      force_remote = true
    } else if arg == "-h" || arg == "--help" {
      help = true
    }
    i += 1
  }
  {
    repo,
    github_flag,
    apply,
    conflict,
    comments_mode,
    include_prs,
    since,
    state,
    force_remote,
    help,
  }
}

///|
async fn handle_hub_issue_sync(args : Array[String]) -> Unit raise Error {
  if args.length() == 0 {
    print_hub_issue_sync_usage()
    return ()
  }
  let subcmd = args[0]
  let rest = collect_args(args, 1)
  match subcmd {
    "pull" => handle_hub_issue_sync_pull(rest)
    "push" => {
      if !github_sync_write_enabled() {
        github_sync_write_disabled_message("push")
        return ()
      }
      handle_hub_issue_sync_push(rest)
    }
    "status" => handle_hub_issue_sync_status(rest)
    "install-hook" => {
      if !github_sync_write_enabled() {
        github_sync_write_disabled_message("install-hook")
        return ()
      }
      handle_hub_issue_sync_install_hook(rest)
    }
    "help" | "-h" | "--help" => print_hub_issue_sync_usage()
    _ => {
      // Bidirectional includes push — check write access
      if !github_sync_write_enabled() {
        github_sync_write_disabled_message("sync")
        return ()
      }
      handle_hub_issue_sync_bidirectional(args)
    }
  }
}

///|
async fn handle_hub_issue_sync_pull(args : Array[String]) -> Unit raise Error {
  let mut repo : String? = None
  let mut since = ""
  let mut state = "all"
  let mut conflict = "newer-wins"
  let mut include_prs = false
  let mut comments_mode = "append-only"
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    if arg == "--repo" && i + 1 < args.length() {
      i += 1
      repo = Some(args[i])
    } else if arg.has_prefix("--repo=") {
      repo = Some(String::unsafe_substring(arg, start=7, end=arg.length()))
    } else if arg == "--since" && i + 1 < args.length() {
      i += 1
      since = args[i]
    } else if arg.has_prefix("--since=") {
      since = String::unsafe_substring(arg, start=8, end=arg.length())
    } else if arg == "--state" && i + 1 < args.length() {
      i += 1
      state = args[i]
    } else if arg.has_prefix("--state=") {
      state = String::unsafe_substring(arg, start=8, end=arg.length())
    } else if arg == "--conflict" && i + 1 < args.length() {
      i += 1
      conflict = args[i]
    } else if arg.has_prefix("--conflict=") {
      conflict = String::unsafe_substring(arg, start=11, end=arg.length())
    } else if arg == "--include-prs" {
      include_prs = true
    } else if arg == "--comments" && i + 1 < args.length() {
      i += 1
      comments_mode = args[i]
    } else if arg.has_prefix("--comments=") {
      comments_mode = String::unsafe_substring(arg, start=11, end=arg.length())
    } else if arg == "-h" || arg == "--help" {
      print_hub_issue_sync_usage()
      return ()
    }
    i += 1
  }
  let root = get_work_root()
  let git_dir = resolve_hub_git_dir(root)
  let fs = OsFs::new()
  let resolved_repo = resolve_github_repo(fs, git_dir, repo)
  let (objects, refs, clock) = make_hub_stores(git_dir)
  let hub = load_hub_store(objects, refs)
  print_line("Pulling issues from GitHub \{resolved_repo}...")
  let result = @hub_native.github_sync_pull_issues(
    hub, objects, refs, clock, resolved_repo, since, state, conflict,
  )
  print_line("Issues pull complete:")
  print_line("  Created: \{result.created}")
  print_line("  Updated: \{result.updated}")
  print_line("  Skipped: \{result.skipped}")
  if result.conflicts.length() > 0 {
    print_line("  Conflicts (manual review needed):")
    for c in result.conflicts {
      print_line("    \{c}")
    }
  }
  // Pull comments for synced issues
  let links = hub.list_sync_links(objects, repo=resolved_repo)
  let mut total_comments_created = 0
  let mut total_comments_updated = 0
  let mut total_comments_deleted = 0
  for link in links {
    if link.local_kind() == "issue" || link.local_kind() == "pr" {
      let cr = @hub_native.github_sync_pull_comments(
        hub,
        objects,
        refs,
        clock,
        resolved_repo,
        link.local_id(),
        link.remote_number(),
        comments_mode,
      )
      total_comments_created += cr.created()
      total_comments_updated += cr.updated()
      total_comments_deleted += cr.deleted()
      if cr.errors().length() > 0 {
        for err in cr.errors() {
          print_line("  Comment error: \{err}")
        }
      }
    }
  }
  if total_comments_created > 0 ||
    total_comments_updated > 0 ||
    total_comments_deleted > 0 {
    print_line("")
    print_line("Comments pull complete:")
    print_line("  Created: \{total_comments_created}")
    print_line("  Updated: \{total_comments_updated}")
    print_line("  Deleted: \{total_comments_deleted}")
  }
  if include_prs {
    print_line("")
    print_line("Pulling PRs from GitHub \{resolved_repo}...")
    let pr_result = @hub_native.github_sync_pull_prs(
      hub, objects, refs, clock, resolved_repo, since, state, conflict,
    )
    print_line("PRs pull complete:")
    print_line("  Created: \{pr_result.created}")
    print_line("  Updated: \{pr_result.updated}")
    print_line("  Skipped: \{pr_result.skipped}")
    if pr_result.conflicts.length() > 0 {
      print_line("  Conflicts (manual review needed):")
      for c in pr_result.conflicts {
        print_line("    \{c}")
      }
    }
  }
}

///|
async fn handle_hub_issue_sync_push(args : Array[String]) -> Unit raise Error {
  let options = parse_hub_issue_sync_push_options(args)
  if options.help {
    print_hub_issue_sync_usage()
    return ()
  }
  if !options.github_flag {
    eprint_line("Error: --github flag required for push (safety measure)")
    eprint_line(
      "Usage: git-bit issue sync push --github --repo <owner/repo> [--apply]",
    )
    @sys.exit(1)
  }
  let root = get_work_root()
  let git_dir = resolve_hub_git_dir(root)
  let fs = OsFs::new()
  let resolved_repo = resolve_github_repo(fs, git_dir, options.repo)
  if !options.force_remote {
    let can_push = @hub_native.github_check_repo_push_permission(resolved_repo) catch {
      _ => false
    }
    if !can_push {
      eprint_line(
        "Error: push requires GitHub write access to the remote repository",
      )
      eprint_line(
        "Repository '\{resolved_repo}' is not writable by the authenticated GitHub user",
      )
      eprint_line("Use --force-remote to override (not recommended)")
      @sys.exit(1)
    }
  }
  let (objects, refs, clock) = make_hub_stores(git_dir)
  let hub = load_hub_store(objects, refs)
  let changes = @hub_native.github_sync_plan_push(hub, objects, resolved_repo)
  let pr_changes = if options.include_prs {
    @hub_native.github_sync_plan_push_prs(hub, objects, resolved_repo)
  } else {
    []
  }
  if changes.length() == 0 && pr_changes.length() == 0 {
    print_line("Nothing to push to \{resolved_repo}")
    return ()
  }
  // Display issue plan
  if changes.length() > 0 {
    print_line("Issue changes to push to GitHub (\{resolved_repo}):")
    print_line("")
    for change in changes {
      print_push_change(change, "issue")
    }
    print_line("")
  }
  // Display PR plan
  if pr_changes.length() > 0 {
    print_line("PR changes to push to GitHub (\{resolved_repo}):")
    print_line("")
    for change in pr_changes {
      print_push_change(change, "PR")
    }
    print_line("")
  }
  if !options.apply {
    print_line("Run with --apply to execute these changes.")
    return ()
  }
  // Execute issues
  if changes.length() > 0 {
    print_line("Pushing issues to GitHub...")
    let result = @hub_native.github_sync_execute_push(
      hub, objects, refs, clock, resolved_repo, changes,
    )
    print_line("Issue push complete:")
    print_line("  Created: \{result.created}")
    print_line("  Updated: \{result.updated}")
    if result.errors.length() > 0 {
      print_line("  Errors:")
      for err in result.errors {
        print_line("    \{err}")
      }
    }
  }
  // Execute PRs
  if pr_changes.length() > 0 {
    print_line("Pushing PR updates to GitHub...")
    let pr_result = @hub_native.github_sync_execute_push_prs(
      hub, objects, refs, clock, resolved_repo, pr_changes,
    )
    print_line("PR push complete:")
    print_line("  Created: \{pr_result.created}")
    print_line("  Updated: \{pr_result.updated}")
    if pr_result.errors.length() > 0 {
      print_line("  Errors:")
      for err in pr_result.errors {
        print_line("    \{err}")
      }
    }
  }
  // Push comments for synced issues/PRs
  let links = hub.list_sync_links(objects, repo=resolved_repo)
  let mut total_comments_created = 0
  let mut total_comments_updated = 0
  for link in links {
    if link.local_kind() == "issue" || link.local_kind() == "pr" {
      let cr = @hub_native.github_sync_push_comments(
        hub,
        objects,
        refs,
        clock,
        resolved_repo,
        link.local_id(),
        link.remote_number(),
        options.comments_mode,
        options.apply,
      )
      total_comments_created += cr.created()
      total_comments_updated += cr.updated()
      if cr.errors().length() > 0 {
        for err in cr.errors() {
          print_line("  Comment error: \{err}")
        }
      }
    }
  }
  if total_comments_created > 0 || total_comments_updated > 0 {
    print_line("")
    print_line("Comments push complete:")
    print_line("  Created: \{total_comments_created}")
    print_line("  Updated: \{total_comments_updated}")
  }
}

///|
async fn print_push_change(
  change : @hub_native.SyncPushChange,
  kind : String,
) -> Unit raise Error {
  let prefix = if change.is_destructive { "  ! " } else { "  " }
  match change.action {
    "create" => {
      print_line("\{prefix}CREATE \{kind} \"\{change.title}\"")
      if change.labels_change.length() > 0 {
        print_line("    labels: \{change.labels_change}")
      }
    }
    "update" => {
      print_line(
        "\{prefix}UPDATE \{kind} #\{change.remote_number} \"\{change.title}\"",
      )
      if change.state_change.length() > 0 {
        print_line("    state: \{change.state_change}")
      }
      if change.title_change.length() > 0 {
        print_line("    title: \{change.title_change}")
      }
      if change.labels_change.length() > 0 {
        print_line("    labels: \{change.labels_change}")
      }
    }
    _ => ()
  }
}

///|
async fn handle_hub_issue_sync_install_hook(
  _args : Array[String],
) -> Unit raise Error {
  let root = get_work_root()
  let git_dir = resolve_hub_git_dir(root)
  let fs = OsFs::new()
  let hooks_dir = git_dir + "/hooks"
  let hook_path = hooks_dir + "/post-push"
  // Detect repo from git remote
  let repo = resolve_github_repo(fs, git_dir, None)
  let hook_line = "bit issue sync push --github --repo \"\{repo}\" --apply --comments append-only\n"
  let hook_content = "#!/bin/sh\n# Auto-sync bit issues to GitHub after push\n" +
    hook_line
  // Check if hook already exists
  if fs.is_file(hook_path) {
    let existing = decode_bytes(
      fs.read_file(hook_path) catch {
        _ => Default::default()
      },
    )
    if existing.contains("bit issue sync") {
      print_line("Hook already installed at \{hook_path}")
      return ()
    }
    // Append to existing hook
    fs.write_string(hook_path, existing.to_string() + "\n" + hook_line) catch {
      err => {
        eprint_line("Error writing hook: \{err}")
        @sys.exit(1)
      }
    }
    print_line("Appended sync hook to \{hook_path}")
  } else {
    fs.mkdir_p(hooks_dir) catch {
      _ => ()
    }
    fs.write_string(hook_path, hook_content) catch {
      err => {
        eprint_line("Error writing hook: \{err}")
        @sys.exit(1)
      }
    }
    print_line("Created sync hook at \{hook_path}")
  }
  // Make executable
  let _ = @process.collect_output("chmod", ["+x", hook_path], inherit_env=true)
}

///|
async fn handle_hub_issue_sync_bidirectional(
  args : Array[String],
) -> Unit raise Error {
  let options = parse_hub_issue_sync_bidirectional_options(args)
  if options.help {
    print_hub_issue_sync_usage()
    return ()
  }
  if !options.github_flag {
    eprint_line("Error: --github flag required for bidirectional sync")
    eprint_line(
      "Usage: git-bit issue sync --github --repo <owner/repo> [--apply]",
    )
    @sys.exit(1)
  }
  let root = get_work_root()
  let git_dir = resolve_hub_git_dir(root)
  let fs = OsFs::new()
  let resolved_repo = resolve_github_repo(fs, git_dir, options.repo)
  if !options.force_remote {
    let can_push = @hub_native.github_check_repo_push_permission(resolved_repo) catch {
      _ => false
    }
    if !can_push {
      eprint_line(
        "Error: bidirectional sync requires GitHub write access to the remote repository",
      )
      eprint_line(
        "Repository '\{resolved_repo}' is not writable by the authenticated GitHub user",
      )
      eprint_line("Use --force-remote to override (not recommended)")
      @sys.exit(1)
    }
  }
  let (objects, refs, clock) = make_hub_stores(git_dir)
  let hub = load_hub_store(objects, refs)
  // Phase 1: Pull (always executes)
  print_line("=== Pull (GitHub → bit) ===")
  print_line("Pulling issues from GitHub \{resolved_repo}...")
  let pull_result = @hub_native.github_sync_pull_issues(
    hub,
    objects,
    refs,
    clock,
    resolved_repo,
    options.since,
    options.state,
    options.conflict,
  )
  print_line("Issues pull complete:")
  print_line("  Created: \{pull_result.created}")
  print_line("  Updated: \{pull_result.updated}")
  print_line("  Skipped: \{pull_result.skipped}")
  if pull_result.conflicts.length() > 0 {
    print_line("  Conflicts (manual review needed):")
    for c in pull_result.conflicts {
      print_line("    \{c}")
    }
  }
  // Pull comments
  let links = hub.list_sync_links(objects, repo=resolved_repo)
  let mut total_pull_comments_created = 0
  let mut total_pull_comments_updated = 0
  let mut total_pull_comments_deleted = 0
  for link in links {
    if link.local_kind() == "issue" || link.local_kind() == "pr" {
      let cr = @hub_native.github_sync_pull_comments(
        hub,
        objects,
        refs,
        clock,
        resolved_repo,
        link.local_id(),
        link.remote_number(),
        options.comments_mode,
      )
      total_pull_comments_created += cr.created()
      total_pull_comments_updated += cr.updated()
      total_pull_comments_deleted += cr.deleted()
      if cr.errors().length() > 0 {
        for err in cr.errors() {
          print_line("  Comment error: \{err}")
        }
      }
    }
  }
  if total_pull_comments_created > 0 ||
    total_pull_comments_updated > 0 ||
    total_pull_comments_deleted > 0 {
    print_line("")
    print_line("Comments pull complete:")
    print_line("  Created: \{total_pull_comments_created}")
    print_line("  Updated: \{total_pull_comments_updated}")
    print_line("  Deleted: \{total_pull_comments_deleted}")
  }
  if options.include_prs {
    print_line("")
    print_line("Pulling PRs from GitHub \{resolved_repo}...")
    let pr_result = @hub_native.github_sync_pull_prs(
      hub,
      objects,
      refs,
      clock,
      resolved_repo,
      options.since,
      options.state,
      options.conflict,
    )
    print_line("PRs pull complete:")
    print_line("  Created: \{pr_result.created}")
    print_line("  Updated: \{pr_result.updated}")
    print_line("  Skipped: \{pr_result.skipped}")
    if pr_result.conflicts.length() > 0 {
      print_line("  Conflicts (manual review needed):")
      for c in pr_result.conflicts {
        print_line("    \{c}")
      }
    }
  }
  // Phase 2: Push
  print_line("")
  print_line("=== Push (bit → GitHub) ===")
  let changes = @hub_native.github_sync_plan_push(hub, objects, resolved_repo)
  let pr_changes = if options.include_prs {
    @hub_native.github_sync_plan_push_prs(hub, objects, resolved_repo)
  } else {
    []
  }
  if changes.length() == 0 && pr_changes.length() == 0 {
    print_line("Nothing to push to \{resolved_repo}")
    return ()
  }
  if changes.length() > 0 {
    print_line("Issue changes to push to GitHub (\{resolved_repo}):")
    print_line("")
    for change in changes {
      print_push_change(change, "issue")
    }
    print_line("")
  }
  if pr_changes.length() > 0 {
    print_line("PR changes to push to GitHub (\{resolved_repo}):")
    print_line("")
    for change in pr_changes {
      print_push_change(change, "PR")
    }
    print_line("")
  }
  if !options.apply {
    print_line("Run with --apply to execute push changes.")
    return ()
  }
  // Execute push
  if changes.length() > 0 {
    print_line("Pushing issues to GitHub...")
    let result = @hub_native.github_sync_execute_push(
      hub, objects, refs, clock, resolved_repo, changes,
    )
    print_line("Issue push complete:")
    print_line("  Created: \{result.created}")
    print_line("  Updated: \{result.updated}")
    if result.errors.length() > 0 {
      print_line("  Errors:")
      for err in result.errors {
        print_line("    \{err}")
      }
    }
  }
  if pr_changes.length() > 0 {
    print_line("Pushing PR updates to GitHub...")
    let pr_result = @hub_native.github_sync_execute_push_prs(
      hub, objects, refs, clock, resolved_repo, pr_changes,
    )
    print_line("PR push complete:")
    print_line("  Created: \{pr_result.created}")
    print_line("  Updated: \{pr_result.updated}")
    if pr_result.errors.length() > 0 {
      print_line("  Errors:")
      for err in pr_result.errors {
        print_line("    \{err}")
      }
    }
  }
  // Push comments
  let push_links = hub.list_sync_links(objects, repo=resolved_repo)
  let mut total_push_comments_created = 0
  let mut total_push_comments_updated = 0
  for link in push_links {
    if link.local_kind() == "issue" || link.local_kind() == "pr" {
      let cr = @hub_native.github_sync_push_comments(
        hub,
        objects,
        refs,
        clock,
        resolved_repo,
        link.local_id(),
        link.remote_number(),
        options.comments_mode,
        options.apply,
      )
      total_push_comments_created += cr.created()
      total_push_comments_updated += cr.updated()
      if cr.errors().length() > 0 {
        for err in cr.errors() {
          print_line("  Comment error: \{err}")
        }
      }
    }
  }
  if total_push_comments_created > 0 || total_push_comments_updated > 0 {
    print_line("")
    print_line("Comments push complete:")
    print_line("  Created: \{total_push_comments_created}")
    print_line("  Updated: \{total_push_comments_updated}")
  }
}

///|
async fn handle_hub_issue_sync_status(args : Array[String]) -> Unit raise Error {
  let mut repo : String? = None
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    if arg == "--repo" && i + 1 < args.length() {
      i += 1
      repo = Some(args[i])
    } else if arg.has_prefix("--repo=") {
      repo = Some(String::unsafe_substring(arg, start=7, end=arg.length()))
    } else if arg == "-h" || arg == "--help" {
      print_hub_issue_sync_usage()
      return ()
    }
    i += 1
  }
  let root = get_work_root()
  let git_dir = resolve_hub_git_dir(root)
  let fs = OsFs::new()
  let resolved_repo = resolve_github_repo(fs, git_dir, repo)
  let (objects, refs, _clock) = make_hub_stores(git_dir)
  let hub = load_hub_store(objects, refs)
  let links = hub.list_sync_links(objects, repo=resolved_repo)
  if links.length() == 0 {
    print_line("No sync links found for \{resolved_repo}")
    print_line("")
    print_line(
      "Run `git-bit issue sync pull --repo \{resolved_repo}` to pull issues from GitHub.",
    )
    return ()
  }
  print_line("Sync status for \{resolved_repo}")
  print_line("  Linked items: \{links.length()}")
  print_line("")
  // Show recent sync links (up to 20)
  let limit = if links.length() > 20 { 20 } else { links.length() }
  for idx = 0; idx < limit; idx = idx + 1 {
    let link = links[idx]
    let kind = link.local_kind()
    let num = link.remote_number()
    let local_id_short = if link.local_id().length() > 8 {
      String::unsafe_substring(link.local_id(), start=0, end=8)
    } else {
      link.local_id()
    }
    let pull_ts = link.last_pull_at()
    let push_ts = link.last_push_at()
    let pull_str = if pull_ts > 0L {
      format_timestamp_iso(pull_ts, "+0000")
    } else {
      "never"
    }
    let push_str = if push_ts > 0L {
      format_timestamp_iso(push_ts, "+0000")
    } else {
      "never"
    }
    print_line(
      "  \{kind} #\{num} <-> \{local_id_short}  pulled: \{pull_str}  pushed: \{push_str}",
    )
  }
  if links.length() > limit {
    print_line("  ... and \{links.length() - limit} more")
  }
}

///|
fn github_sync_write_enabled() -> Bool {
  match @sys.get_env_var("BIT_GITHUB_SYNC_WRITE") {
    Some(v) => v == "1" || v == "true"
    None => false
  }
}

///|
async fn github_sync_write_disabled_message(
  command : String,
) -> Unit raise Error {
  eprint_line(
    "Error: 'bit issue sync \{command}' is currently disabled (writes to GitHub)",
  )
  eprint_line("")
  eprint_line("Read-only commands are available:")
  eprint_line("  bit issue sync pull --repo <owner/repo>   (GitHub → bit)")
  eprint_line("  bit issue sync status --repo <owner/repo>")
  eprint_line("")
  eprint_line("To enable write operations, set: export BIT_GITHUB_SYNC_WRITE=1")
  @sys.exit(1)
}

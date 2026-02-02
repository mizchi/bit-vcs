///|
fn print_collab_usage() -> Unit {
  println("Usage: bit collab <subcommand> [<args>]")
  println("")
  println("Subcommands:")
  println("  init          Initialize collab metadata")
  println("  pr            Manage pull requests")
  println("  issue         Manage issues")
  println("  note          Manage notes")
  println("  sync          Sync collab refs with remotes")
  println("  help          Show this help")
  println("")
  println("Run 'bit collab <subcommand> -h' for details.")
}

///|
fn print_collab_pr_usage() -> Unit {
  println("Usage: bit collab pr <subcommand> [<args>]")
  println("")
  println("Subcommands:")
  println("  list [--state <open|closed|merged>]")
  println("  get <id>")
  println(
    "  create --title <title> [--body <body>] --source <branch> --target <branch>",
  )
  println(
    "  update <id> [--title <title>] [--body <body>] [--label <label>...]",
  )
  println("  close <id>")
  println("  merge <id> [--strategy <merge|squash|ff>]")
  println(
    "  comment add <pr-id> --body <body> [--reply-to <id>] [--file <path>] [--line <n>] [--commit <hex>]",
  )
  println("  comment list <pr-id>")
  println(
    "  review submit <pr-id> --verdict <approved|comment|request-changes> --commit <hex> [--body <body>]",
  )
  println("  review list <pr-id>")
}

///|
fn print_collab_issue_usage() -> Unit {
  println("Usage: bit collab issue <subcommand> [<args>]")
  println("")
  println("Subcommands:")
  println("  list [--state <open|closed>]")
  println("  get <id>")
  println(
    "  create --title <title> [--body <body>] [--label <label>...] [--assignee <user>...]",
  )
  println(
    "  update <id> [--title <title>] [--body <body>] [--label <label>...] [--assignee <user>...]",
  )
  println("  close <id>")
  println("  comment add <issue-id> --body <body> [--reply-to <id>]")
  println("  comment list <issue-id>")
  println("  link <issue-id> <pr-id>")
}

///|
fn print_collab_note_usage() -> Unit {
  println("Usage: bit collab note <subcommand> [<args>]")
  println("")
  println("Subcommands:")
  println("  add <commit> [--body <body>] [--ns <name>]")
  println("  get <commit> [--ns <name>]")
  println("  list [--ns <name>]")
  println("  remove <commit> [--ns <name>]")
}

///|
fn print_collab_sync_usage() -> Unit {
  println("Usage: bit collab sync <subcommand> [<args>]")
  println("")
  println("Subcommands:")
  println("  push [<remote-url>]")
  println("  fetch [<remote-url>]")
}

///|
async fn handle_collab(args : Array[String]) -> Unit raise Error {
  if args.length() == 0 {
    print_collab_usage()
    return ()
  }
  let subcmd = args[0]
  let rest = collect_args(args, 1)
  match subcmd {
    "help" | "-h" | "--help" => print_collab_usage()
    "init" => handle_collab_init(rest)
    "pr" => handle_collab_pr(rest)
    "issue" => handle_collab_issue(rest)
    "note" => handle_collab_note(rest)
    "sync" => handle_collab_sync(rest)
    _ => {
      eprint_line("bit collab: unknown subcommand '\{subcmd}'")
      print_collab_usage()
      @sys.exit(1)
    }
  }
}

///|
async fn handle_collab_init(args : Array[String]) -> Unit raise Error {
  for arg in args {
    if arg.has_prefix("-") {
      warn_unimplemented_arg("collab init", arg)
    }
  }
  let root = get_work_root()
  let git_dir = root + "/.git"
  let fs = OsFs::new()
  let _ = @collab.Collab::init(fs, fs, git_dir)
  print_line("Initialized collab metadata")
}

///|
async fn handle_collab_pr(args : Array[String]) -> Unit raise Error {
  if args.length() == 0 {
    print_collab_pr_usage()
    return ()
  }
  let subcmd = args[0]
  let rest = collect_args(args, 1)
  match subcmd {
    "list" => handle_collab_pr_list(rest)
    "get" => handle_collab_pr_get(rest)
    "create" => handle_collab_pr_create(rest)
    "update" => handle_collab_pr_update(rest)
    "close" => handle_collab_pr_close(rest)
    "merge" => handle_collab_pr_merge(rest)
    "comment" => handle_collab_pr_comment(rest)
    "review" => handle_collab_pr_review(rest)
    "help" | "-h" | "--help" => print_collab_pr_usage()
    _ => {
      eprint_line("bit collab pr: unknown subcommand '\{subcmd}'")
      print_collab_pr_usage()
      @sys.exit(1)
    }
  }
}

///|
async fn handle_collab_pr_list(args : Array[String]) -> Unit raise Error {
  let mut state : @collab.PrState? = None
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    match arg {
      "--state" if i + 1 < args.length() => {
        let value = args[i + 1]
        match parse_pr_state(value) {
          Some(s) => state = Some(s)
          None =>
            raise @git.GitError::InvalidObject("Unknown PR state: \{value}")
        }
        i += 2
        continue
      }
      _ if arg.has_prefix("--state=") => {
        let value = String::unsafe_substring(arg, start=8, end=arg.length())
        match parse_pr_state(value) {
          Some(s) => state = Some(s)
          None =>
            raise @git.GitError::InvalidObject("Unknown PR state: \{value}")
        }
        i += 1
        continue
      }
      _ if arg.has_prefix("-") => warn_unimplemented_arg("collab pr list", arg)
      _ => warn_unimplemented_arg("collab pr list", arg)
    }
    i += 1
  }
  let root = get_work_root()
  let git_dir = root + "/.git"
  let fs = OsFs::new()
  let collab = @collab.Collab::load(fs, git_dir)
  let prs = collab.list_prs(fs, state~)
  if prs.length() == 0 {
    print_line("No pull requests")
    return ()
  }
  for pr in prs {
    print_line(format_pr_summary(pr))
  }
}

///|
async fn handle_collab_pr_get(args : Array[String]) -> Unit raise Error {
  if args.length() == 0 {
    print_collab_pr_usage()
    return ()
  }
  let first = args[0]
  if first == "-h" || first == "--help" || first == "help" {
    print_collab_pr_usage()
    return ()
  }
  let mut pr_id : String? = None
  for arg in args {
    if arg.has_prefix("-") {
      warn_unimplemented_arg("collab pr get", arg)
      continue
    }
    if pr_id is None {
      pr_id = Some(arg)
    } else {
      warn_unimplemented_arg("collab pr get", arg)
    }
  }
  guard pr_id is Some(id) else {
    raise @git.GitError::InvalidObject("PR id is required")
  }
  let root = get_work_root()
  let git_dir = root + "/.git"
  let fs = OsFs::new()
  let collab = @collab.Collab::load(fs, git_dir)
  let pr = collab.get_pr(fs, id)
  guard pr is Some(val) else {
    raise @git.GitError::InvalidObject("PR not found: \{id}")
  }
  print_line(val.serialize())
}

///|
async fn handle_collab_pr_create(args : Array[String]) -> Unit raise Error {
  let mut title : String? = None
  let mut body : String? = None
  let mut source_branch : String? = None
  let mut target_branch : String? = None
  let positionals : Array[String] = []
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    match arg {
      "-t" | "--title" if i + 1 < args.length() => {
        title = Some(args[i + 1])
        i += 2
        continue
      }
      "-m" | "--message" | "--body" if i + 1 < args.length() => {
        body = Some(args[i + 1])
        i += 2
        continue
      }
      "--source" if i + 1 < args.length() => {
        source_branch = Some(args[i + 1])
        i += 2
        continue
      }
      "--target" if i + 1 < args.length() => {
        target_branch = Some(args[i + 1])
        i += 2
        continue
      }
      _ if arg.has_prefix("--title=") => {
        title = Some(String::unsafe_substring(arg, start=8, end=arg.length()))
        i += 1
        continue
      }
      _ if arg.has_prefix("--body=") => {
        body = Some(String::unsafe_substring(arg, start=7, end=arg.length()))
        i += 1
        continue
      }
      _ if arg.has_prefix("--message=") => {
        body = Some(String::unsafe_substring(arg, start=10, end=arg.length()))
        i += 1
        continue
      }
      _ if arg.has_prefix("--source=") => {
        source_branch = Some(
          String::unsafe_substring(arg, start=9, end=arg.length()),
        )
        i += 1
        continue
      }
      _ if arg.has_prefix("--target=") => {
        target_branch = Some(
          String::unsafe_substring(arg, start=9, end=arg.length()),
        )
        i += 1
        continue
      }
      _ if arg.has_prefix("-") => {
        warn_unimplemented_arg("collab pr create", arg)
        i += 1
        continue
      }
      _ => {
        positionals.push(arg)
        i += 1
        continue
      }
    }
  }
  if source_branch is None && positionals.length() > 0 {
    source_branch = Some(positionals[0])
  }
  if target_branch is None && positionals.length() > 1 {
    target_branch = Some(positionals[1])
  }
  guard title is Some(t) else {
    raise @git.GitError::InvalidObject("Missing --title")
  }
  guard source_branch is Some(src) else {
    raise @git.GitError::InvalidObject("Missing --source")
  }
  guard target_branch is Some(tgt) else {
    raise @git.GitError::InvalidObject("Missing --target")
  }
  let pr_body = match body {
    Some(b) => b
    None => ""
  }
  let root = get_work_root()
  let git_dir = root + "/.git"
  let fs = OsFs::new()
  let collab = @collab.Collab::init(fs, fs, git_dir)
  let pr = collab.create_pr(
    fs,
    fs,
    t,
    pr_body,
    src,
    tgt,
    get_author_string(),
    get_commit_timestamp(),
  )
  print_line(pr.serialize())
}

///|
async fn handle_collab_pr_update(args : Array[String]) -> Unit raise Error {
  if args.length() == 0 {
    print_collab_pr_usage()
    return ()
  }
  let mut pr_id : String? = None
  let mut title : String? = None
  let mut body : String? = None
  let labels : Array[String] = []
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    match arg {
      "-t" | "--title" if i + 1 < args.length() => {
        title = Some(args[i + 1])
        i += 2
        continue
      }
      "-m" | "--message" | "--body" if i + 1 < args.length() => {
        body = Some(args[i + 1])
        i += 2
        continue
      }
      "--label" if i + 1 < args.length() => {
        labels.push(args[i + 1])
        i += 2
        continue
      }
      _ if arg.has_prefix("--title=") => {
        title = Some(String::unsafe_substring(arg, start=8, end=arg.length()))
        i += 1
        continue
      }
      _ if arg.has_prefix("--body=") => {
        body = Some(String::unsafe_substring(arg, start=7, end=arg.length()))
        i += 1
        continue
      }
      _ if arg.has_prefix("--message=") => {
        body = Some(String::unsafe_substring(arg, start=10, end=arg.length()))
        i += 1
        continue
      }
      _ if arg.has_prefix("--label=") => {
        labels.push(String::unsafe_substring(arg, start=8, end=arg.length()))
        i += 1
        continue
      }
      _ if arg.has_prefix("-") => {
        warn_unimplemented_arg("collab pr update", arg)
        i += 1
        continue
      }
      _ => {
        if pr_id is None {
          pr_id = Some(arg)
        } else {
          warn_unimplemented_arg("collab pr update", arg)
        }
        i += 1
        continue
      }
    }
  }
  guard pr_id is Some(id) else {
    raise @git.GitError::InvalidObject("PR id is required")
  }
  let label_option = if labels.length() > 0 { Some(labels) } else { None }
  let root = get_work_root()
  let git_dir = root + "/.git"
  let fs = OsFs::new()
  let collab = @collab.Collab::init(fs, fs, git_dir)
  let pr = collab.update_pr(
    fs,
    fs,
    id,
    get_commit_timestamp(),
    title~,
    body~,
    labels=label_option,
  )
  print_line(pr.serialize())
}

///|
async fn handle_collab_pr_close(args : Array[String]) -> Unit raise Error {
  if args.length() == 0 {
    print_collab_pr_usage()
    return ()
  }
  let mut pr_id : String? = None
  for arg in args {
    if arg.has_prefix("-") {
      warn_unimplemented_arg("collab pr close", arg)
      continue
    }
    if pr_id is None {
      pr_id = Some(arg)
    } else {
      warn_unimplemented_arg("collab pr close", arg)
    }
  }
  guard pr_id is Some(id) else {
    raise @git.GitError::InvalidObject("PR id is required")
  }
  let root = get_work_root()
  let git_dir = root + "/.git"
  let fs = OsFs::new()
  let collab = @collab.Collab::init(fs, fs, git_dir)
  collab.close_pr(fs, fs, id, get_commit_timestamp())
  print_line("Closed PR #\{id}")
}

///|
async fn handle_collab_pr_merge(args : Array[String]) -> Unit raise Error {
  if args.length() == 0 {
    print_collab_pr_usage()
    return ()
  }
  let mut pr_id : String? = None
  let mut strategy : @collab.PrMergeStrategy? = None
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    match arg {
      "--strategy" if i + 1 < args.length() => {
        let value = args[i + 1]
        match parse_merge_strategy(value) {
          Some(s) => strategy = Some(s)
          None =>
            raise @git.GitError::InvalidObject(
              "Unknown merge strategy: \{value}",
            )
        }
        i += 2
        continue
      }
      _ if arg.has_prefix("--strategy=") => {
        let value = String::unsafe_substring(arg, start=11, end=arg.length())
        match parse_merge_strategy(value) {
          Some(s) => strategy = Some(s)
          None =>
            raise @git.GitError::InvalidObject(
              "Unknown merge strategy: \{value}",
            )
        }
        i += 1
        continue
      }
      _ if arg.has_prefix("-") => {
        warn_unimplemented_arg("collab pr merge", arg)
        i += 1
        continue
      }
      _ => {
        if pr_id is None {
          pr_id = Some(arg)
        } else {
          warn_unimplemented_arg("collab pr merge", arg)
        }
        i += 1
        continue
      }
    }
  }
  guard pr_id is Some(id) else {
    raise @git.GitError::InvalidObject("PR id is required")
  }
  let root = get_work_root()
  let git_dir = root + "/.git"
  let fs = OsFs::new()
  let collab = @collab.Collab::init(fs, fs, git_dir)
  let result = match strategy {
    Some(s) =>
      collab.merge_pr(
        fs,
        fs,
        id,
        get_author_string(),
        get_commit_timestamp(),
        strategy=s,
      )
    None =>
      collab.merge_pr(fs, fs, id, get_author_string(), get_commit_timestamp())
  }
  if result.success() {
    print_line(result.message())
    match result.commit_id() {
      Some(cid) => print_line("Merge commit: \{cid.to_hex()}")
      None => ()
    }
  } else {
    eprint_line(result.message())
    for conflict in result.conflicts() {
      eprint_line("conflict: \{conflict}")
    }
    @sys.exit(1)
  }
}

///|
async fn handle_collab_pr_comment(args : Array[String]) -> Unit raise Error {
  if args.length() == 0 {
    print_collab_pr_usage()
    return ()
  }
  let subcmd = args[0]
  let rest = collect_args(args, 1)
  match subcmd {
    "add" => handle_collab_pr_comment_add(rest)
    "list" => handle_collab_pr_comment_list(rest)
    "help" | "-h" | "--help" => print_collab_pr_usage()
    _ => {
      eprint_line("bit collab pr comment: unknown subcommand '\{subcmd}'")
      print_collab_pr_usage()
      @sys.exit(1)
    }
  }
}

///|
async fn handle_collab_pr_comment_add(args : Array[String]) -> Unit raise Error {
  let mut pr_id : String? = None
  let mut body : String? = None
  let mut reply_to : String? = None
  let mut file_path : String? = None
  let mut line_number : Int? = None
  let mut commit_id : @git.ObjectId? = None
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    match arg {
      "-m" | "--message" | "--body" if i + 1 < args.length() => {
        body = Some(args[i + 1])
        i += 2
        continue
      }
      "--reply-to" if i + 1 < args.length() => {
        reply_to = Some(args[i + 1])
        i += 2
        continue
      }
      "--file" if i + 1 < args.length() => {
        file_path = Some(args[i + 1])
        i += 2
        continue
      }
      "--line" if i + 1 < args.length() => {
        line_number = Some(@strconv.parse_int(args[i + 1]))
        i += 2
        continue
      }
      "--commit" if i + 1 < args.length() => {
        commit_id = Some(@git.ObjectId::from_hex(args[i + 1]))
        i += 2
        continue
      }
      _ if arg.has_prefix("--body=") => {
        body = Some(String::unsafe_substring(arg, start=7, end=arg.length()))
        i += 1
        continue
      }
      _ if arg.has_prefix("--message=") => {
        body = Some(String::unsafe_substring(arg, start=10, end=arg.length()))
        i += 1
        continue
      }
      _ if arg.has_prefix("--reply-to=") => {
        reply_to = Some(
          String::unsafe_substring(arg, start=11, end=arg.length()),
        )
        i += 1
        continue
      }
      _ if arg.has_prefix("--file=") => {
        file_path = Some(
          String::unsafe_substring(arg, start=7, end=arg.length()),
        )
        i += 1
        continue
      }
      _ if arg.has_prefix("--line=") => {
        let value = String::unsafe_substring(arg, start=7, end=arg.length())
        line_number = Some(@strconv.parse_int(value))
        i += 1
        continue
      }
      _ if arg.has_prefix("--commit=") => {
        let value = String::unsafe_substring(arg, start=9, end=arg.length())
        commit_id = Some(@git.ObjectId::from_hex(value))
        i += 1
        continue
      }
      _ if arg.has_prefix("-") => {
        warn_unimplemented_arg("collab pr comment add", arg)
        i += 1
        continue
      }
      _ => {
        if pr_id is None {
          pr_id = Some(arg)
        } else {
          warn_unimplemented_arg("collab pr comment add", arg)
        }
        i += 1
        continue
      }
    }
  }
  guard pr_id is Some(id) else {
    raise @git.GitError::InvalidObject("PR id is required")
  }
  guard body is Some(msg) else {
    raise @git.GitError::InvalidObject("Missing --body")
  }
  let root = get_work_root()
  let git_dir = root + "/.git"
  let fs = OsFs::new()
  let collab = @collab.Collab::init(fs, fs, git_dir)
  let comment = collab.add_comment(
    fs,
    fs,
    id,
    get_author_string(),
    msg,
    get_commit_timestamp(),
    reply_to~,
    file_path~,
    line_number~,
    commit_id~,
  )
  print_line(comment.serialize())
}

///|
async fn handle_collab_pr_comment_list(
  args : Array[String],
) -> Unit raise Error {
  if args.length() == 0 {
    print_collab_pr_usage()
    return ()
  }
  let mut pr_id : String? = None
  for arg in args {
    if arg.has_prefix("-") {
      warn_unimplemented_arg("collab pr comment list", arg)
      continue
    }
    if pr_id is None {
      pr_id = Some(arg)
    } else {
      warn_unimplemented_arg("collab pr comment list", arg)
    }
  }
  guard pr_id is Some(id) else {
    raise @git.GitError::InvalidObject("PR id is required")
  }
  let root = get_work_root()
  let git_dir = root + "/.git"
  let fs = OsFs::new()
  let collab = @collab.Collab::load(fs, git_dir)
  let comments = collab.list_comments(fs, id)
  if comments.length() == 0 {
    print_line("No comments")
    return ()
  }
  for comment in comments {
    print_line(comment.serialize())
  }
}

///|
async fn handle_collab_pr_review(args : Array[String]) -> Unit raise Error {
  if args.length() == 0 {
    print_collab_pr_usage()
    return ()
  }
  let subcmd = args[0]
  let rest = collect_args(args, 1)
  match subcmd {
    "submit" => handle_collab_pr_review_submit(rest)
    "list" => handle_collab_pr_review_list(rest)
    "help" | "-h" | "--help" => print_collab_pr_usage()
    _ => {
      eprint_line("bit collab pr review: unknown subcommand '\{subcmd}'")
      print_collab_pr_usage()
      @sys.exit(1)
    }
  }
}

///|
async fn handle_collab_pr_review_submit(
  args : Array[String],
) -> Unit raise Error {
  let mut pr_id : String? = None
  let mut verdict : @collab.ReviewVerdict? = None
  let mut body : String? = None
  let mut commit_id : @git.ObjectId? = None
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    match arg {
      "--verdict" if i + 1 < args.length() => {
        let value = args[i + 1]
        match parse_review_verdict(value) {
          Some(v) => verdict = Some(v)
          None =>
            raise @git.GitError::InvalidObject(
              "Unknown review verdict: \{value}",
            )
        }
        i += 2
        continue
      }
      "--commit" if i + 1 < args.length() => {
        commit_id = Some(@git.ObjectId::from_hex(args[i + 1]))
        i += 2
        continue
      }
      "-m" | "--message" | "--body" if i + 1 < args.length() => {
        body = Some(args[i + 1])
        i += 2
        continue
      }
      _ if arg.has_prefix("--verdict=") => {
        let value = String::unsafe_substring(arg, start=10, end=arg.length())
        match parse_review_verdict(value) {
          Some(v) => verdict = Some(v)
          None =>
            raise @git.GitError::InvalidObject(
              "Unknown review verdict: \{value}",
            )
        }
        i += 1
        continue
      }
      _ if arg.has_prefix("--commit=") => {
        let value = String::unsafe_substring(arg, start=9, end=arg.length())
        commit_id = Some(@git.ObjectId::from_hex(value))
        i += 1
        continue
      }
      _ if arg.has_prefix("--body=") => {
        body = Some(String::unsafe_substring(arg, start=7, end=arg.length()))
        i += 1
        continue
      }
      _ if arg.has_prefix("--message=") => {
        body = Some(String::unsafe_substring(arg, start=10, end=arg.length()))
        i += 1
        continue
      }
      _ if arg.has_prefix("-") => {
        warn_unimplemented_arg("collab pr review submit", arg)
        i += 1
        continue
      }
      _ => {
        if pr_id is None {
          pr_id = Some(arg)
        } else {
          warn_unimplemented_arg("collab pr review submit", arg)
        }
        i += 1
        continue
      }
    }
  }
  guard pr_id is Some(id) else {
    raise @git.GitError::InvalidObject("PR id is required")
  }
  guard verdict is Some(v) else {
    raise @git.GitError::InvalidObject("Missing --verdict")
  }
  guard commit_id is Some(cid) else {
    raise @git.GitError::InvalidObject("Missing --commit")
  }
  let review_body = match body {
    Some(b) => b
    None => ""
  }
  let root = get_work_root()
  let git_dir = root + "/.git"
  let fs = OsFs::new()
  let collab = @collab.Collab::init(fs, fs, git_dir)
  let review = collab.submit_review(
    fs,
    fs,
    id,
    get_author_string(),
    v,
    review_body,
    cid,
    get_commit_timestamp(),
  )
  print_line(review.serialize())
}

///|
async fn handle_collab_pr_review_list(args : Array[String]) -> Unit raise Error {
  if args.length() == 0 {
    print_collab_pr_usage()
    return ()
  }
  let mut pr_id : String? = None
  for arg in args {
    if arg.has_prefix("-") {
      warn_unimplemented_arg("collab pr review list", arg)
      continue
    }
    if pr_id is None {
      pr_id = Some(arg)
    } else {
      warn_unimplemented_arg("collab pr review list", arg)
    }
  }
  guard pr_id is Some(id) else {
    raise @git.GitError::InvalidObject("PR id is required")
  }
  let root = get_work_root()
  let git_dir = root + "/.git"
  let fs = OsFs::new()
  let collab = @collab.Collab::load(fs, git_dir)
  let reviews = collab.list_reviews(fs, id)
  if reviews.length() == 0 {
    print_line("No reviews")
    return ()
  }
  for review in reviews {
    print_line(review.serialize())
  }
}

///|
async fn handle_collab_issue(args : Array[String]) -> Unit raise Error {
  if args.length() == 0 {
    print_collab_issue_usage()
    return ()
  }
  let subcmd = args[0]
  let rest = collect_args(args, 1)
  match subcmd {
    "list" => handle_collab_issue_list(rest)
    "get" => handle_collab_issue_get(rest)
    "create" => handle_collab_issue_create(rest)
    "update" => handle_collab_issue_update(rest)
    "close" => handle_collab_issue_close(rest)
    "comment" => handle_collab_issue_comment(rest)
    "link" => handle_collab_issue_link(rest)
    "help" | "-h" | "--help" => print_collab_issue_usage()
    _ => {
      eprint_line("bit collab issue: unknown subcommand '\{subcmd}'")
      print_collab_issue_usage()
      @sys.exit(1)
    }
  }
}

///|
async fn handle_collab_issue_list(args : Array[String]) -> Unit raise Error {
  let mut state : @collab.IssueState? = None
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    match arg {
      "--state" if i + 1 < args.length() => {
        let value = args[i + 1]
        match parse_issue_state(value) {
          Some(s) => state = Some(s)
          None =>
            raise @git.GitError::InvalidObject("Unknown issue state: \{value}")
        }
        i += 2
        continue
      }
      _ if arg.has_prefix("--state=") => {
        let value = String::unsafe_substring(arg, start=8, end=arg.length())
        match parse_issue_state(value) {
          Some(s) => state = Some(s)
          None =>
            raise @git.GitError::InvalidObject("Unknown issue state: \{value}")
        }
        i += 1
        continue
      }
      _ if arg.has_prefix("-") =>
        warn_unimplemented_arg("collab issue list", arg)
      _ => warn_unimplemented_arg("collab issue list", arg)
    }
    i += 1
  }
  let root = get_work_root()
  let git_dir = root + "/.git"
  let fs = OsFs::new()
  let collab = @collab.Collab::load(fs, git_dir)
  let issues = collab.list_issues(fs, state~)
  if issues.length() == 0 {
    print_line("No issues")
    return ()
  }
  for issue in issues {
    print_line(format_issue_summary(issue))
  }
}

///|
async fn handle_collab_issue_get(args : Array[String]) -> Unit raise Error {
  if args.length() == 0 {
    print_collab_issue_usage()
    return ()
  }
  let mut issue_id : String? = None
  for arg in args {
    if arg.has_prefix("-") {
      warn_unimplemented_arg("collab issue get", arg)
      continue
    }
    if issue_id is None {
      issue_id = Some(arg)
    } else {
      warn_unimplemented_arg("collab issue get", arg)
    }
  }
  guard issue_id is Some(id) else {
    raise @git.GitError::InvalidObject("Issue id is required")
  }
  let root = get_work_root()
  let git_dir = root + "/.git"
  let fs = OsFs::new()
  let collab = @collab.Collab::load(fs, git_dir)
  let issue = collab.get_issue(fs, id)
  guard issue is Some(val) else {
    raise @git.GitError::InvalidObject("Issue not found: \{id}")
  }
  print_line(val.serialize())
}

///|
async fn handle_collab_issue_create(args : Array[String]) -> Unit raise Error {
  let mut title : String? = None
  let mut body : String? = None
  let labels : Array[String] = []
  let assignees : Array[String] = []
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    match arg {
      "-t" | "--title" if i + 1 < args.length() => {
        title = Some(args[i + 1])
        i += 2
        continue
      }
      "-m" | "--message" | "--body" if i + 1 < args.length() => {
        body = Some(args[i + 1])
        i += 2
        continue
      }
      "--label" if i + 1 < args.length() => {
        labels.push(args[i + 1])
        i += 2
        continue
      }
      "--assignee" if i + 1 < args.length() => {
        assignees.push(args[i + 1])
        i += 2
        continue
      }
      _ if arg.has_prefix("--title=") => {
        title = Some(String::unsafe_substring(arg, start=8, end=arg.length()))
        i += 1
        continue
      }
      _ if arg.has_prefix("--body=") => {
        body = Some(String::unsafe_substring(arg, start=7, end=arg.length()))
        i += 1
        continue
      }
      _ if arg.has_prefix("--message=") => {
        body = Some(String::unsafe_substring(arg, start=10, end=arg.length()))
        i += 1
        continue
      }
      _ if arg.has_prefix("--label=") => {
        labels.push(String::unsafe_substring(arg, start=8, end=arg.length()))
        i += 1
        continue
      }
      _ if arg.has_prefix("--assignee=") => {
        assignees.push(
          String::unsafe_substring(arg, start=11, end=arg.length()),
        )
        i += 1
        continue
      }
      _ if arg.has_prefix("-") => {
        warn_unimplemented_arg("collab issue create", arg)
        i += 1
        continue
      }
      _ => {
        warn_unimplemented_arg("collab issue create", arg)
        i += 1
        continue
      }
    }
  }
  guard title is Some(t) else {
    raise @git.GitError::InvalidObject("Missing --title")
  }
  let issue_body = match body {
    Some(b) => b
    None => ""
  }
  let root = get_work_root()
  let git_dir = root + "/.git"
  let fs = OsFs::new()
  let collab = @collab.Collab::init(fs, fs, git_dir)
  let issue = collab.create_issue(
    fs,
    fs,
    t,
    issue_body,
    get_author_string(),
    get_commit_timestamp(),
    labels~,
    assignees~,
  )
  print_line(issue.serialize())
}

///|
async fn handle_collab_issue_update(args : Array[String]) -> Unit raise Error {
  if args.length() == 0 {
    print_collab_issue_usage()
    return ()
  }
  let mut issue_id : String? = None
  let mut title : String? = None
  let mut body : String? = None
  let labels : Array[String] = []
  let assignees : Array[String] = []
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    match arg {
      "-t" | "--title" if i + 1 < args.length() => {
        title = Some(args[i + 1])
        i += 2
        continue
      }
      "-m" | "--message" | "--body" if i + 1 < args.length() => {
        body = Some(args[i + 1])
        i += 2
        continue
      }
      "--label" if i + 1 < args.length() => {
        labels.push(args[i + 1])
        i += 2
        continue
      }
      "--assignee" if i + 1 < args.length() => {
        assignees.push(args[i + 1])
        i += 2
        continue
      }
      _ if arg.has_prefix("--title=") => {
        title = Some(String::unsafe_substring(arg, start=8, end=arg.length()))
        i += 1
        continue
      }
      _ if arg.has_prefix("--body=") => {
        body = Some(String::unsafe_substring(arg, start=7, end=arg.length()))
        i += 1
        continue
      }
      _ if arg.has_prefix("--message=") => {
        body = Some(String::unsafe_substring(arg, start=10, end=arg.length()))
        i += 1
        continue
      }
      _ if arg.has_prefix("--label=") => {
        labels.push(String::unsafe_substring(arg, start=8, end=arg.length()))
        i += 1
        continue
      }
      _ if arg.has_prefix("--assignee=") => {
        assignees.push(
          String::unsafe_substring(arg, start=11, end=arg.length()),
        )
        i += 1
        continue
      }
      _ if arg.has_prefix("-") => {
        warn_unimplemented_arg("collab issue update", arg)
        i += 1
        continue
      }
      _ => {
        if issue_id is None {
          issue_id = Some(arg)
        } else {
          warn_unimplemented_arg("collab issue update", arg)
        }
        i += 1
        continue
      }
    }
  }
  guard issue_id is Some(id) else {
    raise @git.GitError::InvalidObject("Issue id is required")
  }
  let label_option = if labels.length() > 0 { Some(labels) } else { None }
  let assignee_option = if assignees.length() > 0 {
    Some(assignees)
  } else {
    None
  }
  let root = get_work_root()
  let git_dir = root + "/.git"
  let fs = OsFs::new()
  let collab = @collab.Collab::init(fs, fs, git_dir)
  let issue = collab.update_issue(
    fs,
    fs,
    id,
    get_commit_timestamp(),
    title~,
    body~,
    labels=label_option,
    assignees=assignee_option,
  )
  print_line(issue.serialize())
}

///|
async fn handle_collab_issue_close(args : Array[String]) -> Unit raise Error {
  if args.length() == 0 {
    print_collab_issue_usage()
    return ()
  }
  let mut issue_id : String? = None
  for arg in args {
    if arg.has_prefix("-") {
      warn_unimplemented_arg("collab issue close", arg)
      continue
    }
    if issue_id is None {
      issue_id = Some(arg)
    } else {
      warn_unimplemented_arg("collab issue close", arg)
    }
  }
  guard issue_id is Some(id) else {
    raise @git.GitError::InvalidObject("Issue id is required")
  }
  let root = get_work_root()
  let git_dir = root + "/.git"
  let fs = OsFs::new()
  let collab = @collab.Collab::init(fs, fs, git_dir)
  collab.close_issue(fs, fs, id, get_commit_timestamp())
  print_line("Closed issue #\{id}")
}

///|
async fn handle_collab_issue_comment(args : Array[String]) -> Unit raise Error {
  if args.length() == 0 {
    print_collab_issue_usage()
    return ()
  }
  let subcmd = args[0]
  let rest = collect_args(args, 1)
  match subcmd {
    "add" => handle_collab_issue_comment_add(rest)
    "list" => handle_collab_issue_comment_list(rest)
    "help" | "-h" | "--help" => print_collab_issue_usage()
    _ => {
      eprint_line("bit collab issue comment: unknown subcommand '\{subcmd}'")
      print_collab_issue_usage()
      @sys.exit(1)
    }
  }
}

///|
async fn handle_collab_issue_comment_add(
  args : Array[String],
) -> Unit raise Error {
  let mut issue_id : String? = None
  let mut body : String? = None
  let mut reply_to : String? = None
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    match arg {
      "-m" | "--message" | "--body" if i + 1 < args.length() => {
        body = Some(args[i + 1])
        i += 2
        continue
      }
      "--reply-to" if i + 1 < args.length() => {
        reply_to = Some(args[i + 1])
        i += 2
        continue
      }
      _ if arg.has_prefix("--body=") => {
        body = Some(String::unsafe_substring(arg, start=7, end=arg.length()))
        i += 1
        continue
      }
      _ if arg.has_prefix("--message=") => {
        body = Some(String::unsafe_substring(arg, start=10, end=arg.length()))
        i += 1
        continue
      }
      _ if arg.has_prefix("--reply-to=") => {
        reply_to = Some(
          String::unsafe_substring(arg, start=11, end=arg.length()),
        )
        i += 1
        continue
      }
      _ if arg.has_prefix("-") => {
        warn_unimplemented_arg("collab issue comment add", arg)
        i += 1
        continue
      }
      _ => {
        if issue_id is None {
          issue_id = Some(arg)
        } else {
          warn_unimplemented_arg("collab issue comment add", arg)
        }
        i += 1
        continue
      }
    }
  }
  guard issue_id is Some(id) else {
    raise @git.GitError::InvalidObject("Issue id is required")
  }
  guard body is Some(msg) else {
    raise @git.GitError::InvalidObject("Missing --body")
  }
  let root = get_work_root()
  let git_dir = root + "/.git"
  let fs = OsFs::new()
  let collab = @collab.Collab::init(fs, fs, git_dir)
  let comment = collab.add_issue_comment(
    fs,
    fs,
    id,
    get_author_string(),
    msg,
    get_commit_timestamp(),
    reply_to~,
  )
  print_line(comment.serialize())
}

///|
async fn handle_collab_issue_comment_list(
  args : Array[String],
) -> Unit raise Error {
  if args.length() == 0 {
    print_collab_issue_usage()
    return ()
  }
  let mut issue_id : String? = None
  for arg in args {
    if arg.has_prefix("-") {
      warn_unimplemented_arg("collab issue comment list", arg)
      continue
    }
    if issue_id is None {
      issue_id = Some(arg)
    } else {
      warn_unimplemented_arg("collab issue comment list", arg)
    }
  }
  guard issue_id is Some(id) else {
    raise @git.GitError::InvalidObject("Issue id is required")
  }
  let root = get_work_root()
  let git_dir = root + "/.git"
  let fs = OsFs::new()
  let collab = @collab.Collab::load(fs, git_dir)
  let comments = collab.list_issue_comments(fs, id)
  if comments.length() == 0 {
    print_line("No comments")
    return ()
  }
  for comment in comments {
    print_line(comment.serialize())
  }
}

///|
async fn handle_collab_issue_link(args : Array[String]) -> Unit raise Error {
  if args.length() < 2 {
    print_collab_issue_usage()
    return ()
  }
  let issue_id = args[0]
  let pr_id = args[1]
  let root = get_work_root()
  let git_dir = root + "/.git"
  let fs = OsFs::new()
  let collab = @collab.Collab::init(fs, fs, git_dir)
  collab.link_pr_to_issue(fs, fs, issue_id, pr_id, get_commit_timestamp())
  print_line("Linked PR #\{pr_id} to issue #\{issue_id}")
}

///|
async fn handle_collab_note(args : Array[String]) -> Unit raise Error {
  if args.length() == 0 {
    print_collab_note_usage()
    return ()
  }
  let subcmd = args[0]
  let rest = collect_args(args, 1)
  match subcmd {
    "add" => handle_collab_note_add(rest)
    "get" => handle_collab_note_get(rest)
    "list" => handle_collab_note_list(rest)
    "remove" => handle_collab_note_remove(rest)
    "help" | "-h" | "--help" => print_collab_note_usage()
    _ => {
      eprint_line("bit collab note: unknown subcommand '\{subcmd}'")
      print_collab_note_usage()
      @sys.exit(1)
    }
  }
}

///|
async fn handle_collab_note_add(args : Array[String]) -> Unit raise Error {
  if args.length() == 0 {
    print_collab_note_usage()
    return ()
  }
  let mut commit_hex : String? = None
  let mut body : String? = None
  let mut ns : String? = None
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    match arg {
      "-m" | "--message" | "--body" if i + 1 < args.length() => {
        body = Some(args[i + 1])
        i += 2
        continue
      }
      "--ns" if i + 1 < args.length() => {
        ns = Some(args[i + 1])
        i += 2
        continue
      }
      _ if arg.has_prefix("--body=") => {
        body = Some(String::unsafe_substring(arg, start=7, end=arg.length()))
        i += 1
        continue
      }
      _ if arg.has_prefix("--message=") => {
        body = Some(String::unsafe_substring(arg, start=10, end=arg.length()))
        i += 1
        continue
      }
      _ if arg.has_prefix("--ns=") => {
        ns = Some(String::unsafe_substring(arg, start=5, end=arg.length()))
        i += 1
        continue
      }
      _ if arg.has_prefix("-") => {
        warn_unimplemented_arg("collab note add", arg)
        i += 1
        continue
      }
      _ => {
        if commit_hex is None {
          commit_hex = Some(arg)
        } else {
          warn_unimplemented_arg("collab note add", arg)
        }
        i += 1
        continue
      }
    }
  }
  guard commit_hex is Some(hex) else {
    raise @git.GitError::InvalidObject("Commit id is required")
  }
  let note_body = match body {
    Some(b) => b
    None => {
      let input = read_all_stdin()
      let text = decode_bytes(input)
      if text.length() == 0 {
        raise @git.GitError::InvalidObject("Missing --body")
      }
      text
    }
  }
  let root = get_work_root()
  let git_dir = root + "/.git"
  let fs = OsFs::new()
  let collab = @collab.Collab::init(fs, fs, git_dir)
  let note = collab.add_note(
    fs,
    fs,
    @git.ObjectId::from_hex(hex),
    note_body,
    get_author_string(),
    get_commit_timestamp(),
    ns=note_ns(ns),
  )
  print_line(note.serialize())
}

///|
async fn handle_collab_note_get(args : Array[String]) -> Unit raise Error {
  if args.length() == 0 {
    print_collab_note_usage()
    return ()
  }
  let mut commit_hex : String? = None
  let mut ns : String? = None
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    match arg {
      "--ns" if i + 1 < args.length() => {
        ns = Some(args[i + 1])
        i += 2
        continue
      }
      _ if arg.has_prefix("--ns=") => {
        ns = Some(String::unsafe_substring(arg, start=5, end=arg.length()))
        i += 1
        continue
      }
      _ if arg.has_prefix("-") => {
        warn_unimplemented_arg("collab note get", arg)
        i += 1
        continue
      }
      _ => {
        if commit_hex is None {
          commit_hex = Some(arg)
        } else {
          warn_unimplemented_arg("collab note get", arg)
        }
        i += 1
        continue
      }
    }
  }
  guard commit_hex is Some(hex) else {
    raise @git.GitError::InvalidObject("Commit id is required")
  }
  let root = get_work_root()
  let git_dir = root + "/.git"
  let fs = OsFs::new()
  let collab = @collab.Collab::load(fs, git_dir)
  let note = collab.get_note(fs, @git.ObjectId::from_hex(hex), ns=note_ns(ns))
  guard note is Some(val) else {
    raise @git.GitError::InvalidObject("Note not found for \{hex}")
  }
  print_line(val.serialize())
}

///|
async fn handle_collab_note_list(args : Array[String]) -> Unit raise Error {
  let mut ns : String? = None
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    match arg {
      "--ns" if i + 1 < args.length() => {
        ns = Some(args[i + 1])
        i += 2
        continue
      }
      _ if arg.has_prefix("--ns=") => {
        ns = Some(String::unsafe_substring(arg, start=5, end=arg.length()))
        i += 1
        continue
      }
      _ if arg.has_prefix("-") => {
        warn_unimplemented_arg("collab note list", arg)
        i += 1
        continue
      }
      _ => {
        warn_unimplemented_arg("collab note list", arg)
        i += 1
        continue
      }
    }
  }
  let root = get_work_root()
  let git_dir = root + "/.git"
  let fs = OsFs::new()
  let collab = @collab.Collab::load(fs, git_dir)
  let notes = collab.list_notes(fs, ns=note_ns(ns))
  if notes.length() == 0 {
    print_line("No notes")
    return ()
  }
  for note in notes {
    print_line(note.serialize())
  }
}

///|
async fn handle_collab_note_remove(args : Array[String]) -> Unit raise Error {
  if args.length() == 0 {
    print_collab_note_usage()
    return ()
  }
  let mut commit_hex : String? = None
  let mut ns : String? = None
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    match arg {
      "--ns" if i + 1 < args.length() => {
        ns = Some(args[i + 1])
        i += 2
        continue
      }
      _ if arg.has_prefix("--ns=") => {
        ns = Some(String::unsafe_substring(arg, start=5, end=arg.length()))
        i += 1
        continue
      }
      _ if arg.has_prefix("-") => {
        warn_unimplemented_arg("collab note remove", arg)
        i += 1
        continue
      }
      _ => {
        if commit_hex is None {
          commit_hex = Some(arg)
        } else {
          warn_unimplemented_arg("collab note remove", arg)
        }
        i += 1
        continue
      }
    }
  }
  guard commit_hex is Some(hex) else {
    raise @git.GitError::InvalidObject("Commit id is required")
  }
  let root = get_work_root()
  let git_dir = root + "/.git"
  let fs = OsFs::new()
  let collab = @collab.Collab::init(fs, fs, git_dir)
  collab.remove_note(fs, fs, @git.ObjectId::from_hex(hex), ns=note_ns(ns))
  print_line("Removed note for \{hex}")
}

///|
async fn handle_collab_sync(args : Array[String]) -> Unit raise Error {
  if args.length() == 0 {
    print_collab_sync_usage()
    return ()
  }
  let subcmd = args[0]
  let rest = collect_args(args, 1)
  match subcmd {
    "push" => handle_collab_sync_push(rest)
    "fetch" => handle_collab_sync_fetch(rest)
    "help" | "-h" | "--help" => print_collab_sync_usage()
    _ => {
      eprint_line("bit collab sync: unknown subcommand '\{subcmd}'")
      print_collab_sync_usage()
      @sys.exit(1)
    }
  }
}

///|
async fn handle_collab_sync_push(args : Array[String]) -> Unit raise Error {
  let root = get_work_root()
  let git_dir = root + "/.git"
  let fs = OsFs::new()
  let mut remote_url : String? = get_effective_remote_url(fs, git_dir)
  for arg in args {
    if not(arg.has_prefix("-")) {
      remote_url = Some(arg)
      break
    }
    warn_unimplemented_arg("collab sync push", arg)
  }
  guard remote_url is Some(url) else {
    raise @git.GitError::InvalidObject("No remote configured")
  }
  let collab = @collab.Collab::load(fs, git_dir)
  let result = collab.push(fs, url)
  if result.success() {
    print_line(result.message())
  } else {
    eprint_line(result.message())
    @sys.exit(1)
  }
}

///|
async fn handle_collab_sync_fetch(args : Array[String]) -> Unit raise Error {
  let root = get_work_root()
  let git_dir = root + "/.git"
  let fs = OsFs::new()
  let mut remote_url : String? = get_effective_remote_url(fs, git_dir)
  for arg in args {
    if not(arg.has_prefix("-")) {
      remote_url = Some(arg)
      break
    }
    warn_unimplemented_arg("collab sync fetch", arg)
  }
  guard remote_url is Some(url) else {
    raise @git.GitError::InvalidObject("No remote configured")
  }
  let collab = @collab.Collab::load(fs, git_dir)
  let result = collab.fetch(fs, fs, url)
  if result.success() {
    print_line(result.message())
  } else {
    eprint_line(result.message())
    @sys.exit(1)
  }
}

///|
fn parse_pr_state(value : String) -> @collab.PrState? {
  match value {
    "open" => Some(@collab.PrState::Open)
    "closed" => Some(@collab.PrState::Closed)
    "merged" => Some(@collab.PrState::Merged)
    _ => None
  }
}

///|
fn parse_issue_state(value : String) -> @collab.IssueState? {
  match value {
    "open" => Some(@collab.IssueState::Open)
    "closed" => Some(@collab.IssueState::Closed)
    _ => None
  }
}

///|
fn parse_review_verdict(value : String) -> @collab.ReviewVerdict? {
  match value {
    "approved" | "approve" => Some(@collab.ReviewVerdict::Approved)
    "comment" => Some(@collab.ReviewVerdict::Comment)
    "request-changes" | "request_changes" =>
      Some(@collab.ReviewVerdict::RequestChanges)
    _ => None
  }
}

///|
fn parse_merge_strategy(value : String) -> @collab.PrMergeStrategy? {
  match value {
    "merge" => Some(@collab.PrMergeStrategy::Merge)
    "squash" => Some(@collab.PrMergeStrategy::Squash)
    "ff" | "fast-forward" | "fastforward" =>
      Some(@collab.PrMergeStrategy::FastForward)
    _ => None
  }
}

///|
fn format_pr_summary(pr : @collab.PullRequest) -> String {
  let id = pr.id()
  let title = pr.title()
  let state = pr.state().to_string()
  "#\{id} [\{state}] \{title}"
}

///|
fn format_issue_summary(issue : @collab.Issue) -> String {
  let id = issue.id()
  let title = issue.title()
  let state = issue.state().to_string()
  "#\{id} [\{state}] \{title}"
}

///|
fn note_ns(ns : String?) -> String {
  match ns {
    Some(value) => value
    None => "commits"
  }
}

///|
struct OsObjectStore {
  git_dir : String
}

///|
impl @gitlib.ObjectStore for OsObjectStore with get(self, id) {
  let fs = OsFs::new()
  let db = @gitlib.ObjectDb::load_lazy(fs, self.git_dir)
  db.get(fs, id)
}

///|
impl @gitlib.ObjectStore for OsObjectStore with put(self, obj_type, content) {
  let fs = OsFs::new()
  let (id, compressed) = @git.create_object(obj_type, content)
  let hex = id.to_hex()
  let dir = self.git_dir +
    "/objects/" +
    String::unsafe_substring(hex, start=0, end=2)
  let path = dir + "/" + String::unsafe_substring(hex, start=2, end=40)
  fs.mkdir_p(dir)
  fs.write_file(path, compressed)
  id
}

///|
impl @gitlib.ObjectStore for OsObjectStore with has(self, id) {
  let fs = OsFs::new()
  let db = @gitlib.ObjectDb::load_lazy(fs, self.git_dir)
  let obj = db.get(fs, id)
  obj is Some(_)
}

///|
struct OsRefStore {
  git_dir : String
}

///|
impl @gitlib.RefStore for OsRefStore with resolve(self, ref_name) {
  let fs = OsFs::new()
  @gitlib.resolve_ref(fs, self.git_dir, ref_name)
}

///|
impl @gitlib.RefStore for OsRefStore with update(self, ref_name, id) {
  let fs = OsFs::new()
  match id {
    Some(commit_id) => {
      let ref_path = self.git_dir + "/" + ref_name
      let dir = os_parent_path(ref_path)
      fs.mkdir_p(dir)
      fs.write_string(ref_path, commit_id.to_hex() + "\n")
    }
    None => ()
  }
}

///|
impl @gitlib.RefStore for OsRefStore with list(self, _prefix) {
  ignore(self)
  []
}

///|
fn os_parent_path(path : String) -> String {
  match path.rev_find("/") {
    None => "."
    Some(0) => "."
    Some(idx) => String::unsafe_substring(path, start=0, end=idx)
  }
}

///|
struct OsClock {
  time : Int64
}

///|
impl @gitlib.Clock for OsClock with now(self) {
  self.time
}

///|
fn make_collab_stores(
  git_dir : String,
) -> (&@gitlib.ObjectStore, &@gitlib.RefStore, &@gitlib.Clock) {
  let objects : OsObjectStore = { git_dir, }
  let refs : OsRefStore = { git_dir, }
  let clock : OsClock = { time: get_commit_timestamp() }
  (objects, refs, clock)
}

///|
fn load_collab_store(
  objects : &@gitlib.ObjectStore,
  refs : &@gitlib.RefStore,
) -> @collab.Collab raise @git.GitError {
  @collab.Collab::load(
    objects,
    refs,
    signing_key=get_collab_signing_key(),
    require_signed=get_collab_require_signed(),
  )
}

///|
fn init_collab_store(
  objects : &@gitlib.ObjectStore,
  refs : &@gitlib.RefStore,
) -> @collab.Collab raise @git.GitError {
  @collab.Collab::init(
    objects,
    refs,
    signing_key=get_collab_signing_key(),
    require_signed=get_collab_require_signed(),
  )
}

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
  println("  dump          Dump raw collab records from notes")
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
  println(
    "  import [--repo <owner/repo>] [--state <open|closed|merged|all>] [--limit <n>]",
  )
  println("  get <id>")
  println(
    "  create --title <title> [--body <body>] --source <branch> --target <branch> [--source-repo <owner/repo>] [--source-ref <ref>]",
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
  println(
    "  import [--repo <owner/repo>] [--state <open|closed|all>] [--limit <n>]",
  )
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
fn print_collab_dump_usage() -> Unit {
  println("Usage: bit collab dump [<prefix>] [<options>]")
  println("")
  println("Options:")
  println("  --prefix <prefix>       Filter by key prefix (default: collab/)")
  println("  --raw                   Print full serialized CollabRecord bodies")
  println("  --include-deleted       Include tombstoned records")
  println("  -h, --help              Show this help")
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
    "dump" => handle_collab_dump(rest)
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
  let (objects, refs, _clock) = make_collab_stores(git_dir)
  let _ = init_collab_store(objects, refs)
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
    "import" => handle_collab_pr_import(rest)
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
        if parse_pr_state(value) is Some(s) {
          state = Some(s)
        } else {
          raise @git.GitError::InvalidObject("Unknown PR state: \{value}")
        }
        i += 2
        continue
      }
      "--state" =>
        raise @git.GitError::InvalidObject(
          "collab pr list: --state requires a value",
        )
      _ if arg.has_prefix("--state=") => {
        let value = String::unsafe_substring(arg, start=8, end=arg.length())
        if parse_pr_state(value) is Some(s) {
          state = Some(s)
        } else {
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
  let (objects, refs, _clock) = make_collab_stores(git_dir)
  let collab = load_collab_store(objects, refs)
  let prs = collab.list_prs(objects, state~)
  if prs.length() == 0 {
    print_line("No pull requests")
    return ()
  }
  for pr in prs {
    pr |> format_pr_summary |> print_line
  }
}

///|
async fn handle_collab_pr_import(args : Array[String]) -> Unit raise Error {
  let mut repo : String? = None
  let mut state = "all"
  let mut limit = 100
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    match arg {
      "-h" | "--help" | "help" => {
        print_collab_pr_usage()
        return ()
      }
      "--repo" if i + 1 < args.length() => {
        repo = Some(args[i + 1])
        i += 2
        continue
      }
      "--repo" =>
        raise @git.GitError::InvalidObject(
          "collab pr import: --repo requires a value",
        )
      _ if arg.has_prefix("--repo=") => {
        repo = Some(String::unsafe_substring(arg, start=7, end=arg.length()))
        i += 1
        continue
      }
      "--state" if i + 1 < args.length() => {
        state = args[i + 1]
        i += 2
        continue
      }
      "--state" =>
        raise @git.GitError::InvalidObject(
          "collab pr import: --state requires a value",
        )
      _ if arg.has_prefix("--state=") => {
        state = String::unsafe_substring(arg, start=8, end=arg.length())
        i += 1
        continue
      }
      "--limit" if i + 1 < args.length() => {
        limit = @strconv.parse_int(args[i + 1]) catch {
          _ =>
            raise @git.GitError::InvalidObject("Invalid limit: \{args[i + 1]}")
        }
        i += 2
        continue
      }
      "--limit" =>
        raise @git.GitError::InvalidObject(
          "collab pr import: --limit requires a value",
        )
      _ if arg.has_prefix("--limit=") => {
        let value = String::unsafe_substring(arg, start=8, end=arg.length())
        limit = @strconv.parse_int(value) catch {
          _ => raise @git.GitError::InvalidObject("Invalid limit: \{value}")
        }
        i += 1
        continue
      }
      _ if arg.has_prefix("-") =>
        warn_unimplemented_arg("collab pr import", arg)
      _ => warn_unimplemented_arg("collab pr import", arg)
    }
    i += 1
  }
  let state_value = state.to_lower()
  match state_value {
    "open" | "closed" | "merged" | "all" => ()
    _ => raise @git.GitError::InvalidObject("Unknown PR state: \{state}")
  }
  if limit <= 0 {
    raise @git.GitError::InvalidObject("Limit must be positive")
  }
  let root = get_work_root()
  let git_dir = root + "/.git"
  let fs = OsFs::new()
  let repo_name = resolve_github_repo(fs, git_dir, repo)
  let (stdout, _stderr) = gh_pr_list(repo_name, state_value, limit)
  let prs = parse_gh_prs(stdout)
  if prs.length() == 0 {
    print_line("No pull requests to import")
    return ()
  }
  let (objects, refs, clock) = make_collab_stores(git_dir)
  let collab = init_collab_store(objects, refs)
  let stats = collab.import_prs(objects, refs, clock, prs)
  print_line(
    "Imported PRs: created \{stats.created()}, updated \{stats.updated()}",
  )
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
  let (objects, refs, _clock) = make_collab_stores(git_dir)
  let collab = load_collab_store(objects, refs)
  let pr = collab.get_pr(objects, id)
  guard pr is Some(val) else {
    raise @git.GitError::InvalidObject("PR not found: \{id}")
  }
  print_line(val.serialize())
}

///|
fn normalize_branch_ref(ref_name : String) -> String {
  if ref_name.has_prefix("refs/") {
    ref_name
  } else {
    "refs/heads/" + ref_name
  }
}

///|
fn infer_source_repo_name(fs : OsFs, git_dir : String) -> String? {
  let remote_url = get_effective_remote_url(fs, git_dir)
  guard remote_url is Some(url) else { return None }
  match @hq.parse_repo_url(url) {
    Some(parsed) => {
      let full_name = parsed.full_name()
      if full_name.length() == 0 {
        None
      } else {
        Some(full_name)
      }
    }
    None => None
  }
}

///|
async fn handle_collab_pr_create(args : Array[String]) -> Unit raise Error {
  let mut title : String? = None
  let mut body : String? = None
  let mut source_branch : String? = None
  let mut target_branch : String? = None
  let mut source_repo : String? = None
  let mut source_ref : String? = None
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
      "--source-repo" if i + 1 < args.length() => {
        source_repo = Some(args[i + 1])
        i += 2
        continue
      }
      "--source-ref" if i + 1 < args.length() => {
        source_ref = Some(args[i + 1])
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
      _ if arg.has_prefix("--source-repo=") => {
        source_repo = Some(
          String::unsafe_substring(arg, start=14, end=arg.length()),
        )
        i += 1
        continue
      }
      _ if arg.has_prefix("--source-ref=") => {
        source_ref = Some(
          String::unsafe_substring(arg, start=13, end=arg.length()),
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
  let pr_body = body.unwrap_or("")
  let root = get_work_root()
  let git_dir = root + "/.git"
  let (objects, refs, clock) = make_collab_stores(git_dir)
  let fs = OsFs::new()
  let source_repo_value = match source_repo {
    Some(repo) => if repo.length() == 0 { None } else { Some(repo) }
    None => infer_source_repo_name(fs, git_dir)
  }
  let source_ref_value = match source_ref {
    Some(ref_name) =>
      if ref_name.length() == 0 {
        Some(normalize_branch_ref(src))
      } else {
        Some(normalize_branch_ref(ref_name))
      }
    None => Some(normalize_branch_ref(src))
  }
  let collab = init_collab_store(objects, refs)
  let pr = collab.create_pr(
    objects,
    refs,
    clock,
    t,
    pr_body,
    src,
    tgt,
    get_author_string(),
    source_repo=source_repo_value,
    source_ref=source_ref_value,
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
  let (objects, refs, clock) = make_collab_stores(git_dir)
  let collab = init_collab_store(objects, refs)
  let pr = collab.update_pr(
    objects,
    refs,
    clock,
    id,
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
  let (objects, refs, clock) = make_collab_stores(git_dir)
  let collab = init_collab_store(objects, refs)
  collab.close_pr(objects, refs, clock, id)
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
  let (objects, refs, clock) = make_collab_stores(git_dir)
  let collab = init_collab_store(objects, refs)
  let result = match strategy {
    Some(s) =>
      collab.merge_pr(objects, refs, clock, id, get_author_string(), strategy=s)
    None => collab.merge_pr(objects, refs, clock, id, get_author_string())
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
        line_number = args[i + 1] |> @strconv.parse_int |> Some
        i += 2
        continue
      }
      "--commit" if i + 1 < args.length() => {
        commit_id = args[i + 1] |> @git.ObjectId::from_hex |> Some
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
        line_number = value |> @strconv.parse_int |> Some
        i += 1
        continue
      }
      _ if arg.has_prefix("--commit=") => {
        let value = String::unsafe_substring(arg, start=9, end=arg.length())
        commit_id = value |> @git.ObjectId::from_hex |> Some
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
  let (objects, refs, clock) = make_collab_stores(git_dir)
  let collab = init_collab_store(objects, refs)
  let comment = collab.add_comment(
    objects,
    refs,
    clock,
    id,
    get_author_string(),
    msg,
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
  let (objects, refs, _clock) = make_collab_stores(git_dir)
  let collab = load_collab_store(objects, refs)
  let comments = collab.list_comments(objects, id)
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
        commit_id = args[i + 1] |> @git.ObjectId::from_hex |> Some
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
        commit_id = value |> @git.ObjectId::from_hex |> Some
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
  let review_body = body.unwrap_or("")
  let root = get_work_root()
  let git_dir = root + "/.git"
  let (objects, refs, clock) = make_collab_stores(git_dir)
  let collab = init_collab_store(objects, refs)
  let review = collab.submit_review(
    objects,
    refs,
    clock,
    id,
    get_author_string(),
    v,
    review_body,
    cid,
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
  let (objects, refs, _clock) = make_collab_stores(git_dir)
  let collab = load_collab_store(objects, refs)
  let reviews = collab.list_reviews(objects, id)
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
    "import" => handle_collab_issue_import(rest)
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
        if parse_issue_state(value) is Some(s) {
          state = Some(s)
        } else {
          raise @git.GitError::InvalidObject("Unknown issue state: \{value}")
        }
        i += 2
        continue
      }
      "--state" =>
        raise @git.GitError::InvalidObject(
          "collab issue list: --state requires a value",
        )
      _ if arg.has_prefix("--state=") => {
        let value = String::unsafe_substring(arg, start=8, end=arg.length())
        if parse_issue_state(value) is Some(s) {
          state = Some(s)
        } else {
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
  let (objects, refs, _clock) = make_collab_stores(git_dir)
  let collab = load_collab_store(objects, refs)
  let issues = collab.list_issues(objects, state~)
  if issues.length() == 0 {
    print_line("No issues")
    return ()
  }
  for issue in issues {
    issue |> format_issue_summary |> print_line
  }
}

///|
async fn handle_collab_issue_import(args : Array[String]) -> Unit raise Error {
  let mut repo : String? = None
  let mut state = "all"
  let mut limit = 100
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    match arg {
      "-h" | "--help" | "help" => {
        print_collab_issue_usage()
        return ()
      }
      "--repo" if i + 1 < args.length() => {
        repo = Some(args[i + 1])
        i += 2
        continue
      }
      "--repo" =>
        raise @git.GitError::InvalidObject(
          "collab issue import: --repo requires a value",
        )
      _ if arg.has_prefix("--repo=") => {
        repo = Some(String::unsafe_substring(arg, start=7, end=arg.length()))
        i += 1
        continue
      }
      "--state" if i + 1 < args.length() => {
        state = args[i + 1]
        i += 2
        continue
      }
      "--state" =>
        raise @git.GitError::InvalidObject(
          "collab issue import: --state requires a value",
        )
      _ if arg.has_prefix("--state=") => {
        state = String::unsafe_substring(arg, start=8, end=arg.length())
        i += 1
        continue
      }
      "--limit" if i + 1 < args.length() => {
        limit = @strconv.parse_int(args[i + 1]) catch {
          _ =>
            raise @git.GitError::InvalidObject("Invalid limit: \{args[i + 1]}")
        }
        i += 2
        continue
      }
      "--limit" =>
        raise @git.GitError::InvalidObject(
          "collab issue import: --limit requires a value",
        )
      _ if arg.has_prefix("--limit=") => {
        let value = String::unsafe_substring(arg, start=8, end=arg.length())
        limit = @strconv.parse_int(value) catch {
          _ => raise @git.GitError::InvalidObject("Invalid limit: \{value}")
        }
        i += 1
        continue
      }
      _ if arg.has_prefix("-") =>
        warn_unimplemented_arg("collab issue import", arg)
      _ => warn_unimplemented_arg("collab issue import", arg)
    }
    i += 1
  }
  let state_value = state.to_lower()
  match state_value {
    "open" | "closed" | "all" => ()
    _ => raise @git.GitError::InvalidObject("Unknown issue state: \{state}")
  }
  if limit <= 0 {
    raise @git.GitError::InvalidObject("Limit must be positive")
  }
  let root = get_work_root()
  let git_dir = root + "/.git"
  let fs = OsFs::new()
  let repo_name = resolve_github_repo(fs, git_dir, repo)
  let (stdout, _stderr) = gh_issue_list(repo_name, state_value, limit)
  let issues = parse_gh_issues(stdout)
  if issues.length() == 0 {
    print_line("No issues to import")
    return ()
  }
  let (objects, refs, clock) = make_collab_stores(git_dir)
  let collab = init_collab_store(objects, refs)
  let stats = collab.import_issues(objects, refs, clock, issues)
  print_line(
    "Imported issues: created \{stats.created()}, updated \{stats.updated()}",
  )
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
  let (objects, refs, _clock) = make_collab_stores(git_dir)
  let collab = load_collab_store(objects, refs)
  let issue = collab.get_issue(objects, id)
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
  let issue_body = body.unwrap_or("")
  let root = get_work_root()
  let git_dir = root + "/.git"
  let (objects, refs, clock) = make_collab_stores(git_dir)
  let collab = init_collab_store(objects, refs)
  let issue = collab.create_issue(
    objects,
    refs,
    clock,
    t,
    issue_body,
    get_author_string(),
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
  let (objects, refs, clock) = make_collab_stores(git_dir)
  let collab = init_collab_store(objects, refs)
  let issue = collab.update_issue(
    objects,
    refs,
    clock,
    id,
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
  let (objects, refs, clock) = make_collab_stores(git_dir)
  let collab = init_collab_store(objects, refs)
  collab.close_issue(objects, refs, clock, id)
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
  let (objects, refs, clock) = make_collab_stores(git_dir)
  let collab = init_collab_store(objects, refs)
  let comment = collab.add_issue_comment(
    objects,
    refs,
    clock,
    id,
    get_author_string(),
    msg,
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
  let (objects, refs, _clock) = make_collab_stores(git_dir)
  let collab = load_collab_store(objects, refs)
  let comments = collab.list_issue_comments(objects, id)
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
  let (objects, refs, clock) = make_collab_stores(git_dir)
  let collab = init_collab_store(objects, refs)
  collab.link_pr_to_issue(objects, refs, clock, issue_id, pr_id)
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
  let (objects, refs, clock) = make_collab_stores(git_dir)
  let collab = init_collab_store(objects, refs)
  let note = collab.add_note(
    objects,
    refs,
    clock,
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
  let (objects, refs, _clock) = make_collab_stores(git_dir)
  let collab = load_collab_store(objects, refs)
  let note = collab.get_note(
    objects,
    refs,
    @git.ObjectId::from_hex(hex),
    ns=note_ns(ns),
  )
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
  let (objects, refs, _clock) = make_collab_stores(git_dir)
  let collab = load_collab_store(objects, refs)
  let notes = collab.list_notes(objects, refs, ns=note_ns(ns))
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
  let (objects, refs, clock) = make_collab_stores(git_dir)
  let collab = init_collab_store(objects, refs)
  collab.remove_note(
    objects,
    refs,
    clock,
    @git.ObjectId::from_hex(hex),
    ns=note_ns(ns),
  )
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
  let (objects, refs, _clock) = make_collab_stores(git_dir)
  let collab = load_collab_store(objects, refs)
  let result = @collab_native.collab_push(collab, fs, git_dir, url)
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
  let (objects, refs, _clock) = make_collab_stores(git_dir)
  let collab = load_collab_store(objects, refs)
  let result = @collab_native.collab_fetch(collab, fs, fs, git_dir, url)
  if result.success() {
    print_line(result.message())
  } else {
    eprint_line(result.message())
    @sys.exit(1)
  }
}

///|
struct CollabDumpOptions {
  prefix : String
  raw : Bool
  include_deleted : Bool
}

///|
fn parse_collab_dump_options(
  args : Array[String],
) -> CollabDumpOptions raise @git.GitError {
  let mut prefix = "collab/"
  let mut raw = false
  let mut include_deleted = false
  let mut i = 0
  let mut used_positional_prefix = false
  while i < args.length() {
    let arg = args[i]
    match arg {
      "--prefix" if i + 1 < args.length() => {
        prefix = args[i + 1]
        i += 2
        continue
      }
      "--prefix" =>
        raise @git.GitError::InvalidObject(
          "collab dump: --prefix requires a value",
        )
      _ if arg.has_prefix("--prefix=") => {
        prefix = String::unsafe_substring(arg, start=9, end=arg.length())
        i += 1
        continue
      }
      "--raw" => {
        raw = true
        i += 1
        continue
      }
      "--include-deleted" => {
        include_deleted = true
        i += 1
        continue
      }
      "-h" | "--help" | "help" => {
        i += 1
        continue
      }
      _ if arg.has_prefix("-") =>
        raise @git.GitError::InvalidObject("Unknown collab dump option: \{arg}")
      _ => {
        if used_positional_prefix {
          raise @git.GitError::InvalidObject(
            "collab dump: unexpected positional argument: \{arg}",
          )
        }
        prefix = arg
        used_positional_prefix = true
        i += 1
        continue
      }
    }
  }
  { prefix, raw, include_deleted }
}

///|
fn format_collab_record_summary(record : @collab.CollabRecord) -> String {
  let deleted_text = if record.deleted { "1" } else { "0" }
  "kind=\{record.kind} key=\{record.key} node=\{record.node} ts=\{record.timestamp} deleted=\{deleted_text}"
}

///|
async fn handle_collab_dump(args : Array[String]) -> Unit raise Error {
  if args.length() > 0 {
    let first = args[0]
    if first == "help" || first == "-h" || first == "--help" {
      print_collab_dump_usage()
      return ()
    }
  }
  let options = parse_collab_dump_options(args)
  let root = get_work_root()
  let git_dir = root + "/.git"
  let (objects, refs, _clock) = make_collab_stores(git_dir)
  let store = @collab.CollabStore::load(
    objects,
    refs,
    signing_key=get_collab_signing_key(),
    require_signed=get_collab_require_signed(),
  )
  let records = store.list_records(
    objects,
    options.prefix,
    include_deleted=options.include_deleted,
  )
  if records.length() == 0 {
    print_line("No collab records for prefix: \{options.prefix}")
    return ()
  }
  records.sort_by(fn(a, b) {
    if a.key < b.key {
      -1
    } else if a.key > b.key {
      1
    } else {
      0
    }
  })
  for rec in records {
    if options.raw {
      print_line("---")
      print_line(format_collab_record_summary(rec))
      print_line(rec.serialize())
    } else {
      print_line(format_collab_record_summary(rec))
    }
  }
}

///|
fn resolve_github_repo(
  fs : OsFs,
  git_dir : String,
  repo : String?,
) -> String raise @git.GitError {
  match repo {
    Some(name) => name
    None => {
      let remote_url = get_effective_remote_url(fs, git_dir)
      guard remote_url is Some(url) else {
        raise @git.GitError::InvalidObject("No remote configured; use --repo")
      }
      match @hq.parse_repo_url(url) {
        Some(parsed) => {
          let host = parsed.host_name()
          if host != "github.com" {
            raise @git.GitError::InvalidObject(
              "Only github.com is supported for gh import",
            )
          }
          parsed.full_name()
        }
        None =>
          raise @git.GitError::InvalidObject("Cannot parse remote URL: \{url}")
      }
    }
  }
}

///|
async fn gh_pr_list(
  repo : String,
  state : String,
  limit : Int,
) -> (String, String) raise @git.GitError {
  let fields = "number,title,body,headRefName,headRefOid,headRepository,baseRefName,baseRefOid,author,createdAt,updatedAt,state,labels"
  let jq = "[.[] | {id:(.number|tostring), title:.title, body:(.body // \"\"), source_branch:.headRefName, source_ref:(if (.headRefName // \"\") == \"\" then \"\" else (\"refs/heads/\" + .headRefName) end), source_repo:((.headRepository // {}) | .nameWithOwner // \"\"), source_commit:.headRefOid, target_branch:.baseRefName, target_commit:.baseRefOid, author:(.author.login // \"unknown\"), created_at:(.createdAt|fromdateiso8601), updated_at:(.updatedAt|fromdateiso8601), state:(.state|ascii_downcase), labels:(.labels|map(.name))}]"
  let args = [
    "pr",
    "list",
    "--state",
    state,
    "--limit",
    limit.to_string(),
    "--json",
    fields,
    "--jq",
    jq,
    "--repo",
    repo,
  ]
  gh_collect_output(args)
}

///|
async fn gh_issue_list(
  repo : String,
  state : String,
  limit : Int,
) -> (String, String) raise @git.GitError {
  let fields = "number,title,body,author,createdAt,updatedAt,state,labels,assignees"
  let jq = "[.[] | {id:(.number|tostring), title:.title, body:(.body // \"\"), author:(.author.login // \"unknown\"), created_at:(.createdAt|fromdateiso8601), updated_at:(.updatedAt|fromdateiso8601), state:(.state|ascii_downcase), labels:(.labels|map(.name)), assignees:(.assignees|map(.login))}]"
  let args = [
    "issue",
    "list",
    "--state",
    state,
    "--limit",
    limit.to_string(),
    "--json",
    fields,
    "--jq",
    jq,
    "--repo",
    repo,
  ]
  gh_collect_output(args)
}

///|
async fn gh_collect_output(
  args : Array[String],
) -> (String, String) raise @git.GitError {
  let (code, stdout, stderr) = @process.collect_output(
    "gh",
    args,
    inherit_env=true,
  ) catch {
    err => raise @git.GitError::IoError("gh failed: \{err}")
  }
  let out = stdout.text() catch {
    err if @async.is_cancellation_error(err) =>
      raise @git.GitError::IoError(err.to_string())
    _ => ""
  }
  let err_text = stderr.text() catch {
    err if @async.is_cancellation_error(err) =>
      raise @git.GitError::IoError(err.to_string())
    _ => ""
  }
  if code != 0 {
    let message = trim_string(err_text)
    raise @git.GitError::InvalidObject("gh failed (\{code}): \{message}")
  }
  (out, err_text)
}

///|
fn parse_json_array(text : String) -> Array[Json] raise @git.GitError {
  let parsed = @json.parse(text) catch {
    err =>
      raise @git.GitError::InvalidObject(
        "Invalid JSON from gh: \{err.to_string()}",
      )
  }
  match parsed {
    Json::Array(items) => items
    _ => raise @git.GitError::InvalidObject("Expected JSON array from gh")
  }
}

///|
fn json_get_string(
  obj : Map[String, Json],
  key : String,
  fallback : String,
) -> String {
  match obj.get(key) {
    Some(Json::String(value)) => value
    Some(Json::Number(value, ..)) => value.to_string()
    Some(Json::True) => "true"
    Some(Json::False) => "false"
    _ => fallback
  }
}

///|
fn json_get_int64(
  obj : Map[String, Json],
  key : String,
  fallback : Int64,
) -> Int64 {
  match obj.get(key) {
    Some(Json::Number(value, ..)) => value.to_int64()
    Some(Json::String(value)) =>
      @strconv.parse_int64(value) catch {
        _ => fallback
      }
    _ => fallback
  }
}

///|
fn json_get_string_array(
  obj : Map[String, Json],
  key : String,
) -> Array[String] {
  match obj.get(key) {
    Some(Json::Array(items)) => {
      let out : Array[String] = []
      for item in items {
        match item {
          Json::String(value) => out.push(value)
          _ => ()
        }
      }
      out
    }
    _ => []
  }
}

///|
fn parse_gh_prs(
  text : String,
) -> Array[@collab.PullRequest] raise @git.GitError {
  let items = parse_json_array(text)
  let out : Array[@collab.PullRequest] = []
  for item in items {
    match item {
      Json::Object(obj) => {
        let id = json_get_string(obj, "id", "")
        if id.length() == 0 {
          continue
        }
        let title = json_get_string(obj, "title", "")
        let body = json_get_string(obj, "body", "")
        let source_branch = json_get_string(obj, "source_branch", "")
        let source_ref_raw = json_get_string(obj, "source_ref", "")
        let source_repo_raw = json_get_string(obj, "source_repo", "")
        let target_branch = json_get_string(obj, "target_branch", "")
        let source_hex = json_get_string(obj, "source_commit", "")
        let target_hex = json_get_string(obj, "target_commit", "")
        if source_branch.length() == 0 || target_branch.length() == 0 {
          raise @git.GitError::InvalidObject("Missing branch name for PR \{id}")
        }
        let source_commit = @git.ObjectId::from_hex(source_hex) catch {
          _ =>
            raise @git.GitError::InvalidObject(
              "Invalid source commit for PR \{id}",
            )
        }
        let target_commit = @git.ObjectId::from_hex(target_hex) catch {
          _ =>
            raise @git.GitError::InvalidObject(
              "Invalid target commit for PR \{id}",
            )
        }
        let author = json_get_string(obj, "author", "unknown")
        let created_at = json_get_int64(obj, "created_at", 0L)
        let updated_at = json_get_int64(obj, "updated_at", created_at)
        let labels = json_get_string_array(obj, "labels")
        let state_raw = json_get_string(obj, "state", "open").to_lower()
        let state = match parse_pr_state(state_raw) {
          Some(s) => s
          None => @collab.PrState::Open
        }
        let source_repo = if source_repo_raw.length() == 0 {
          None
        } else {
          Some(source_repo_raw)
        }
        let source_ref = if source_ref_raw.length() == 0 {
          None
        } else {
          Some(source_ref_raw)
        }
        let pr = @collab.PullRequest::new(
          id,
          title,
          body,
          source_branch,
          source_commit,
          target_branch,
          target_commit,
          author,
          created_at,
          updated_at,
          state,
          labels,
          source_repo~,
          source_ref~,
        )
        out.push(pr)
      }
      _ => ()
    }
  }
  out
}

///|
fn parse_gh_issues(text : String) -> Array[@collab.Issue] raise @git.GitError {
  let items = parse_json_array(text)
  let out : Array[@collab.Issue] = []
  for item in items {
    match item {
      Json::Object(obj) => {
        let id = json_get_string(obj, "id", "")
        if id.length() == 0 {
          continue
        }
        let title = json_get_string(obj, "title", "")
        let body = json_get_string(obj, "body", "")
        let author = json_get_string(obj, "author", "unknown")
        let created_at = json_get_int64(obj, "created_at", 0L)
        let updated_at = json_get_int64(obj, "updated_at", created_at)
        let labels = json_get_string_array(obj, "labels")
        let assignees = json_get_string_array(obj, "assignees")
        let state_raw = json_get_string(obj, "state", "open").to_lower()
        let state = match parse_issue_state(state_raw) {
          Some(s) => s
          None => @collab.IssueState::Open
        }
        let issue = @collab.Issue::new(
          id,
          title,
          body,
          author,
          created_at,
          updated_at,
          state,
          labels~,
          assignees~,
        )
        out.push(issue)
      }
      _ => ()
    }
  }
  out
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
  ns.unwrap_or("commits")
}

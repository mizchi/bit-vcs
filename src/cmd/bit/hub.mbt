///|
struct OsObjectStore {
  git_dir : String
}

///|
impl @bitlib.ObjectStore for OsObjectStore with get(self, id) {
  let fs = OsFs::new()
  let db = @bitlib.ObjectDb::load_lazy(fs, self.git_dir)
  db.get(fs, id)
}

///|
impl @bitlib.ObjectStore for OsObjectStore with put(self, obj_type, content) {
  let fs = OsFs::new()
  let (id, compressed) = @bitcore.create_object(obj_type, content)
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
impl @bitlib.ObjectStore for OsObjectStore with has(self, id) {
  let fs = OsFs::new()
  let db = @bitlib.ObjectDb::load_lazy(fs, self.git_dir)
  let obj = db.get(fs, id)
  obj is Some(_)
}

///|
struct OsRefStore {
  git_dir : String
}

///|
impl @bitlib.RefStore for OsRefStore with resolve(self, ref_name) {
  let fs = OsFs::new()
  @bitlib.resolve_ref(fs, self.git_dir, ref_name)
}

///|
impl @bitlib.RefStore for OsRefStore with update(self, ref_name, id) {
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
impl @bitlib.RefStore for OsRefStore with list(self, _prefix) {
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
impl @bitlib.Clock for OsClock with now(self) {
  self.time
}

///|
fn make_hub_stores(
  git_dir : String,
) -> (&@bitlib.ObjectStore, &@bitlib.RefStore, &@bitlib.Clock) {
  let objects : OsObjectStore = { git_dir, }
  let refs : OsRefStore = { git_dir, }
  let clock : OsClock = { time: get_commit_timestamp() }
  (objects, refs, clock)
}

///|
fn load_hub_store(
  objects : &@bitlib.ObjectStore,
  refs : &@bitlib.RefStore,
) -> @hub.Hub raise @bitcore.GitError {
  @hub.Hub::load(
    objects,
    refs,
    signing_key=get_hub_signing_key(),
    require_signed=get_hub_require_signed(),
  )
}

///|
fn init_hub_store(
  objects : &@bitlib.ObjectStore,
  refs : &@bitlib.RefStore,
) -> @hub.Hub raise @bitcore.GitError {
  @hub.Hub::init(
    objects,
    refs,
    signing_key=get_hub_signing_key(),
    require_signed=get_hub_require_signed(),
  )
}

///|
fn print_hub_usage() -> Unit {
  println("Usage: bit hub <subcommand> [<args>]")
  println("")
  println("Subcommands:")
  println("  init          Initialize hub metadata")
  println("  pr            Manage pull requests")
  println("  issue         Manage issues")
  println("  work-item     Manage unified issue/pull-request view")
  println("  note          Manage notes")
  println("  sync          Sync hub refs with remotes")
  println("  dump          Dump raw hub records from notes")
  println("  search        Search hub entities")
  println("  help          Show this help")
  println("")
  println("Run 'bit hub <subcommand> -h' for details.")
}

///|
fn print_hub_pr_usage() -> Unit {
  println("Usage: bit hub pr <subcommand> [<args>]")
  println("")
  println("Subcommands:")
  println(
    "  list [--state <open|closed|merged> | --open | --closed | --merged] [--limit <n>]",
  )
  println("  status")
  println(
    "  import [--repo <owner/repo>] [--state <open|closed|merged|all>] [--limit <n>]",
  )
  println("  get <id>")
  println("  view <id>                             (alias: get)")
  println(
    "  propose --title <title> [--body <body>] (--source|--head) <branch> (--target|--base) <branch> [--source-repo <owner/repo>] [--source-ref <ref>]",
  )
  println("  proposals [--state <open|closed|merged>] [--limit <n>]")
  println("  proposal ...                          (alias: proposals)")
  println("  import-proposal <id>")
  println(
    "  create --title <title> [--body <body>] (--source|--head) <branch> (--target|--base) <branch> [--source-repo <owner/repo>] [--source-ref <ref>]",
  )
  println(
    "  update <id> [--title <title>] [--body <body>] [--label <label>...]",
  )
  println("  edit <id> ...                         (alias: update)")
  println("  close <id>")
  println("  reopen <id>")
  println("  merge <id> [--strategy <merge|squash|ff>] [--merge|--squash|--ff]")
  println(
    "  comment add <pr-id> --body <body> [--reply-to <id>] [--file <path>] [--line <n>] [--commit <hex>]",
  )
  println(
    "  comment <pr-id> --body <body> ...    (gh-style alias: comment add)",
  )
  println("  comment list <pr-id>")
  println(
    "  review submit <pr-id> --verdict <approved|comment|request-changes> --commit <hex> [--body <body>]",
  )
  println(
    "  review <pr-id> (--approve|--comment|--request-changes|--verdict <v>) --commit <hex> [--body <body>]",
  )
  println("  review list <pr-id>")
  println(
    "  workflow submit <pr-id> --task <task> --status <pending|running|success|failed> [--fingerprint <value>] [--txn <id>] [--author <name>] [--summary <text>]",
  )
  println("  workflow list <pr-id>")
}

///|
fn print_hub_issue_usage() -> Unit {
  println("Usage: bit hub issue <subcommand> [<args>]")
  println("")
  println("Subcommands:")
  println("  list [--state <open|closed> | --open | --closed] [--limit <n>]")
  println(
    "  import [--repo <owner/repo>] [--state <open|closed|all>] [--limit <n>]",
  )
  println("  get <id>")
  println("  view <id>                             (alias: get)")
  println(
    "  create --title <title> [--body <body>] [--label <label>...] [--assignee <user>...]",
  )
  println(
    "  update <id> [--title <title>] [--body <body>] [--label <label>...] [--assignee <user>...]",
  )
  println("  edit <id> ...                         (alias: update)")
  println("  close <id>")
  println("  reopen <id>")
  println("  comment add <issue-id> --body <body> [--reply-to <id>]")
  println(
    "  comment <issue-id> --body <body> ...  (gh-style alias: comment add)",
  )
  println("  comment list <issue-id>")
  println("  link <issue-id> <pr-id>")
}

///|
fn print_hub_work_item_usage() -> Unit {
  println("Usage: bit hub work-item <subcommand> [<args>]")
  println("")
  println("Subcommands:")
  println(
    "  list [--state <open|closed|merged> | --open | --closed | --merged] [--kind <issue|pr|pull-request> | --issue | --pr] [--limit <n>]",
  )
  println("  get <id>")
  println("  view <id>                             (alias: get)")
}

///|
fn print_hub_note_usage() -> Unit {
  println("Usage: bit hub note <subcommand> [<args>]")
  println("")
  println("Subcommands:")
  println("  add <commit> [--body <body>] [--ns <name>]")
  println("  get <commit> [--ns <name>]")
  println("  list [--ns <name>]")
  println("  remove <commit> [--ns <name>]")
}

///|
fn print_hub_sync_usage() -> Unit {
  println("Usage: bit hub sync <subcommand> [<args>]")
  println("")
  println("Subcommands:")
  println(
    "  push [<remote-url>] [--auth-token <token>] [--signing-key <key>] [--require-signed|--allow-unsigned]",
  )
  println(
    "  fetch [<remote-url>] [--auth-token <token>] [--signing-key <key>] [--require-signed|--allow-unsigned]",
  )
  println("")
  println("Remote URL:")
  println("  - Smart HTTP remote: https://host/repo.git")
  println("  - Relay explicit: relay+http(s)://host")
  println("  - Relay fallback: http(s)://host (when info/refs returns 404)")
}

///|
fn print_hub_dump_usage() -> Unit {
  println("Usage: bit hub dump [<prefix>] [<options>]")
  println("")
  println("Options:")
  println("  --prefix <prefix>       Filter by key prefix (default: hub/)")
  println("  --raw                   Print full serialized HubRecord bodies")
  println("  --include-deleted       Include tombstoned records")
  println("  -h, --help              Show this help")
}

///|
fn print_hub_search_usage() -> Unit {
  println("Usage: bit hub search [<query>...] [<options>]")
  println("")
  println("Options:")
  println(
    "  --type <pr|issue|pr-comment|pr-review|issue-comment|comment|review|all>",
  )
  println("  --state <open|closed|merged|all>")
  println("  --author <author>")
  println("  --label <label>         (repeatable)")
  println("  --limit <n>")
  println("  -h, --help              Show this help")
}

///|
fn default_hub_merge_policy() -> @hub.PrMergePolicy {
  @hub.PrMergePolicy::default()
}

///|
fn default_hub_merge_policy_toml() -> String {
  let template =
    #|# Hub merge policy
    #|# required_approvals: minimum number of latest approved reviews
    #|# allow_request_changes: allow merge while latest review requests changes
    #|# require_signed_records: require PR metadata and reviews to be signed
    #|# required_workflows: workflow task names that must be latest-success
    #|[merge]
    #|required_approvals = 0
    #|allow_request_changes = true
    #|require_signed_records = false
    #|required_workflows = []
  template
}

///|
fn parse_merge_policy_bool(
  value : String,
  key : String,
) -> Bool raise @bitcore.GitError {
  let normalized = value.to_lower()
  match normalized {
    "true" | "1" | "yes" => true
    "false" | "0" | "no" => false
    _ =>
      raise @bitcore.GitError::InvalidObject(
        "hub merge policy: '\{key}' must be true or false: \{value}",
      )
  }
}

///|
fn parse_merge_policy_string_array(
  value : String,
  key : String,
) -> Array[String] raise @bitcore.GitError {
  let parsed = @json.parse(value) catch {
    _ =>
      raise @bitcore.GitError::InvalidObject(
        "hub merge policy: '\{key}' must be JSON string array: \{value}",
      )
  }
  match parsed {
    Json::Array(items) => {
      let out : Array[String] = []
      for item in items {
        match item {
          Json::String(text) => out.push(text)
          _ =>
            raise @bitcore.GitError::InvalidObject(
              "hub merge policy: '\{key}' must contain only strings",
            )
        }
      }
      out
    }
    _ =>
      raise @bitcore.GitError::InvalidObject(
        "hub merge policy: '\{key}' must be string array",
      )
  }
}

///|
fn parse_hub_merge_policy_toml(
  content : String,
) -> @hub.PrMergePolicy raise @bitcore.GitError {
  let mut required_approvals = 0
  let mut allow_request_changes = true
  let mut require_signed_records = false
  let mut required_workflows : Array[String] = []
  let mut in_merge_section = false
  for line_view in content.split("\n") {
    let raw_line = line_view.to_string()
    let line = trim_string(raw_line)
    if line.length() == 0 || line.has_prefix("#") || line.has_prefix(";") {
      continue
    }
    if line.has_prefix("[") && line.has_suffix("]") {
      let section_name = trim_string(
        String::unsafe_substring(line, start=1, end=line.length() - 1),
      )
      in_merge_section = section_name == "merge"
      continue
    }
    if not(in_merge_section) {
      continue
    }
    let eq_idx = line.find("=")
    guard eq_idx is Some(i) else {
      raise @bitcore.GitError::InvalidObject(
        "hub merge policy: expected key=value in [merge]: \{line}",
      )
    }
    let key = trim_string(String::unsafe_substring(line, start=0, end=i))
    let value_part = trim_string(
      String::unsafe_substring(line, start=i + 1, end=line.length()),
    )
    let value = match value_part.find("#") {
      Some(comment_start) =>
        trim_string(
          String::unsafe_substring(value_part, start=0, end=comment_start),
        )
      None => value_part
    }
    match key {
      "required_approvals" => {
        let parsed = @strconv.parse_int(value) catch {
          _ =>
            raise @bitcore.GitError::InvalidObject(
              "hub merge policy: required_approvals must be int: \{value}",
            )
        }
        if parsed < 0 {
          raise @bitcore.GitError::InvalidObject(
            "hub merge policy: required_approvals must be >= 0",
          )
        }
        required_approvals = parsed
      }
      "allow_request_changes" =>
        allow_request_changes = parse_merge_policy_bool(value, key)
      "require_signed_records" =>
        require_signed_records = parse_merge_policy_bool(value, key)
      "required_workflows" =>
        required_workflows = parse_merge_policy_string_array(value, key)
      _ =>
        raise @bitcore.GitError::InvalidObject(
          "hub merge policy: unknown key in [merge]: \{key}",
        )
    }
  }
  @hub.PrMergePolicy::new(
    required_approvals,
    allow_request_changes,
    require_signed_records,
    required_workflows~,
  )
}

///|
fn hub_merge_policy_path(git_dir : String) -> String {
  git_dir + "/hub/policy.toml"
}

///|
fn ensure_hub_merge_policy_file(
  fs : OsFs,
  git_dir : String,
) -> Unit raise @bitcore.GitError {
  let policy_path = hub_merge_policy_path(git_dir)
  if fs.is_file(policy_path) {
    return ()
  }
  fs.mkdir_p(git_dir + "/hub")
  fs.write_string(policy_path, default_hub_merge_policy_toml())
}

///|
fn load_hub_merge_policy(
  fs : OsFs,
  git_dir : String,
) -> @hub.PrMergePolicy raise @bitcore.GitError {
  let policy_path = hub_merge_policy_path(git_dir)
  if not(fs.is_file(policy_path)) {
    return default_hub_merge_policy()
  }
  let content = decode_bytes(fs.read_file(policy_path))
  parse_hub_merge_policy_toml(content)
}

///|
enum HubSearchType {
  Pr
  Issue
  PrComment
  PrReview
  IssueComment
}

///|
struct HubSearchOptions {
  query : String?
  types : Array[HubSearchType]
  state : String?
  author : String?
  labels : Array[String]
  limit : Int?
}

///|
fn all_hub_search_types() -> Array[HubSearchType] {
  [
    HubSearchType::Pr,
    HubSearchType::Issue,
    HubSearchType::PrComment,
    HubSearchType::PrReview,
    HubSearchType::IssueComment,
  ]
}

///|
fn hub_search_type_eq(a : HubSearchType, b : HubSearchType) -> Bool {
  match (a, b) {
    (HubSearchType::Pr, HubSearchType::Pr) => true
    (HubSearchType::Issue, HubSearchType::Issue) => true
    (HubSearchType::PrComment, HubSearchType::PrComment) => true
    (HubSearchType::PrReview, HubSearchType::PrReview) => true
    (HubSearchType::IssueComment, HubSearchType::IssueComment) => true
    _ => false
  }
}

///|
fn hub_search_has_type(types : Array[HubSearchType], t : HubSearchType) -> Bool {
  for existing in types {
    if hub_search_type_eq(existing, t) {
      return true
    }
  }
  false
}

///|
fn push_unique_search_type(
  types : Array[HubSearchType],
  t : HubSearchType,
) -> Unit {
  if not(hub_search_has_type(types, t)) {
    types.push(t)
  }
}

///|
fn append_hub_search_types_by_token(
  out : Array[HubSearchType],
  token : String,
) -> Bool {
  match token {
    "all" => {
      for t in all_hub_search_types() {
        push_unique_search_type(out, t)
      }
      true
    }
    "pr" => {
      push_unique_search_type(out, HubSearchType::Pr)
      true
    }
    "issue" => {
      push_unique_search_type(out, HubSearchType::Issue)
      true
    }
    "pr-comment" => {
      push_unique_search_type(out, HubSearchType::PrComment)
      true
    }
    "pr-review" | "review" => {
      push_unique_search_type(out, HubSearchType::PrReview)
      true
    }
    "issue-comment" => {
      push_unique_search_type(out, HubSearchType::IssueComment)
      true
    }
    "comment" => {
      push_unique_search_type(out, HubSearchType::PrComment)
      push_unique_search_type(out, HubSearchType::IssueComment)
      true
    }
    _ => false
  }
}

///|
fn parse_hub_search_types(value : String) -> Array[HubSearchType]? {
  let out : Array[HubSearchType] = []
  for part_view in value.split(",") {
    let token = trim_string(part_view.to_string()).to_lower()
    if token.length() == 0 {
      continue
    }
    if not(append_hub_search_types_by_token(out, token)) {
      return None
    }
  }
  if out.length() == 0 {
    None
  } else {
    Some(out)
  }
}

///|
fn parse_hub_search_state(value : String) -> String? {
  let normalized = value.to_lower()
  match normalized {
    "open" | "closed" | "merged" | "all" => Some(normalized)
    _ => None
  }
}

///|
fn parse_hub_search_options(
  args : Array[String],
) -> HubSearchOptions raise @bitcore.GitError {
  let query_parts : Array[String] = []
  let mut types = all_hub_search_types()
  let mut type_filter_set = false
  let mut state : String? = None
  let mut author : String? = None
  let labels : Array[String] = []
  let mut limit : Int? = None
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    match arg {
      "--type" if i + 1 < args.length() => {
        let value = args[i + 1]
        let parsed = parse_hub_search_types(value)
        guard parsed is Some(parsed_types) else {
          raise @bitcore.GitError::InvalidObject(
            "Unknown hub search type: \{value}",
          )
        }
        if not(type_filter_set) {
          types = []
          type_filter_set = true
        }
        for t in parsed_types {
          push_unique_search_type(types, t)
        }
        i += 2
        continue
      }
      "--type" =>
        raise @bitcore.GitError::InvalidObject(
          "hub search: --type requires a value",
        )
      _ if arg.has_prefix("--type=") => {
        let value = String::unsafe_substring(arg, start=7, end=arg.length())
        let parsed = parse_hub_search_types(value)
        guard parsed is Some(parsed_types) else {
          raise @bitcore.GitError::InvalidObject(
            "Unknown hub search type: \{value}",
          )
        }
        if not(type_filter_set) {
          types = []
          type_filter_set = true
        }
        for t in parsed_types {
          push_unique_search_type(types, t)
        }
        i += 1
        continue
      }
      "--state" if i + 1 < args.length() => {
        let value = args[i + 1]
        let parsed = parse_hub_search_state(value)
        guard parsed is Some(s) else {
          raise @bitcore.GitError::InvalidObject(
            "Unknown hub search state: \{value}",
          )
        }
        state = Some(s)
        i += 2
        continue
      }
      "--state" =>
        raise @bitcore.GitError::InvalidObject(
          "hub search: --state requires a value",
        )
      _ if arg.has_prefix("--state=") => {
        let value = String::unsafe_substring(arg, start=8, end=arg.length())
        let parsed = parse_hub_search_state(value)
        guard parsed is Some(s) else {
          raise @bitcore.GitError::InvalidObject(
            "Unknown hub search state: \{value}",
          )
        }
        state = Some(s)
        i += 1
        continue
      }
      "--open" | "--closed" | "--merged" => {
        let parsed = parse_hub_search_state(
          String::unsafe_substring(arg, start=2, end=arg.length()),
        )
        guard parsed is Some(s) else { panic() }
        state = Some(s)
        i += 1
        continue
      }
      "--author" if i + 1 < args.length() => {
        author = Some(args[i + 1])
        i += 2
        continue
      }
      "--author" =>
        raise @bitcore.GitError::InvalidObject(
          "hub search: --author requires a value",
        )
      _ if arg.has_prefix("--author=") => {
        author = Some(String::unsafe_substring(arg, start=9, end=arg.length()))
        i += 1
        continue
      }
      "--label" if i + 1 < args.length() => {
        labels.push(args[i + 1])
        i += 2
        continue
      }
      "--label" =>
        raise @bitcore.GitError::InvalidObject(
          "hub search: --label requires a value",
        )
      _ if arg.has_prefix("--label=") => {
        labels.push(String::unsafe_substring(arg, start=8, end=arg.length()))
        i += 1
        continue
      }
      "--limit" if i + 1 < args.length() => {
        limit = Some(parse_positive_list_limit(args[i + 1]))
        i += 2
        continue
      }
      "--limit" =>
        raise @bitcore.GitError::InvalidObject(
          "hub search: --limit requires a value",
        )
      _ if arg.has_prefix("--limit=") => {
        let value = String::unsafe_substring(arg, start=8, end=arg.length())
        limit = Some(parse_positive_list_limit(value))
        i += 1
        continue
      }
      "-h" | "--help" | "help" => {
        i += 1
        continue
      }
      _ if arg.has_prefix("-") =>
        raise @bitcore.GitError::InvalidObject(
          "Unknown hub search option: \{arg}",
        )
      _ => {
        query_parts.push(arg)
        i += 1
        continue
      }
    }
  }
  let query = if query_parts.length() == 0 {
    None
  } else {
    Some(query_parts.join(" "))
  }
  { query, types, state, author, labels, limit }
}

///|
fn matches_author_filter(author_filter : String?, actual : String) -> Bool {
  match author_filter {
    Some(author) => actual.to_lower().contains(author.to_lower())
    None => true
  }
}

///|
fn matches_labels_filter(
  required_labels : Array[String],
  labels : Array[String],
) -> Bool {
  if required_labels.length() == 0 {
    return true
  }
  let lower_labels : Array[String] = []
  for label in labels {
    lower_labels.push(label.to_lower())
  }
  for required in required_labels {
    if not(lower_labels.contains(required.to_lower())) {
      return false
    }
  }
  true
}

///|
fn matches_query_filter(query : String?, fields : Array[String]) -> Bool {
  match query {
    None => true
    Some(raw_query) => {
      let needle = raw_query.to_lower()
      for field in fields {
        if field.to_lower().contains(needle) {
          return true
        }
      }
      false
    }
  }
}

///|
fn matches_pr_state_filter(
  state_filter : String?,
  state : @hub.PrState,
) -> Bool {
  match state_filter {
    None => true
    Some("all") => true
    Some(value) => state.to_string() == value
  }
}

///|
fn matches_issue_state_filter(
  state_filter : String?,
  state : @hub.IssueState,
) -> Bool {
  match state_filter {
    None => true
    Some("all") => true
    Some("merged") => false
    Some(value) => state.to_string() == value
  }
}

///|
fn search_limit_reached(limit : Int?, current : Int) -> Bool {
  match limit {
    Some(max) => current >= max
    None => false
  }
}

///|
fn preview_text(text : String) -> String {
  match text.find("\n") {
    Some(idx) => String::unsafe_substring(text, start=0, end=idx)
    None => text
  }
}

///|
async fn handle_hub_search(args : Array[String]) -> Unit raise Error {
  if args.length() > 0 {
    match args[0] {
      "-h" | "--help" | "help" => {
        print_hub_search_usage()
        return ()
      }
      _ => ()
    }
  }
  let options = parse_hub_search_options(args)
  let include_pr = hub_search_has_type(options.types, HubSearchType::Pr)
  let include_issue = hub_search_has_type(options.types, HubSearchType::Issue)
  let include_pr_comment = hub_search_has_type(
    options.types,
    HubSearchType::PrComment,
  )
  let include_pr_review = hub_search_has_type(
    options.types,
    HubSearchType::PrReview,
  )
  let include_issue_comment = hub_search_has_type(
    options.types,
    HubSearchType::IssueComment,
  )

  let root = get_work_root()
  let git_dir = root + "/.git"
  let (objects, refs, _clock) = make_hub_stores(git_dir)
  let hub = load_hub_store(objects, refs)
  let results : Array[String] = []

  if include_pr || include_pr_comment || include_pr_review {
    let prs = hub.list_prs(objects)
    for pr in prs {
      if search_limit_reached(options.limit, results.length()) {
        break
      }
      if not(matches_pr_state_filter(options.state, pr.state())) {
        continue
      }
      if not(matches_labels_filter(options.labels, pr.labels())) {
        continue
      }
      if include_pr &&
        matches_author_filter(options.author, pr.author()) &&
        matches_query_filter(options.query, [
          pr.id(),
          pr.title(),
          pr.body(),
          pr.author(),
          pr.labels().join(","),
        ]) {
        results.push("pr #\{pr.id()} [\{pr.state().to_string()}] \{pr.title()}")
      }
      if include_pr_comment {
        let comments = hub.list_comments(objects, pr.id())
        for comment in comments {
          if search_limit_reached(options.limit, results.length()) {
            break
          }
          if not(matches_author_filter(options.author, comment.author())) {
            continue
          }
          if matches_query_filter(options.query, [
              comment.id(),
              comment.pr_id(),
              comment.author(),
              comment.body(),
            ]) {
            results.push(
              "pr-comment #\{comment.pr_id()}/\{comment.id()} \{comment.author()}: \{preview_text(comment.body())}",
            )
          }
        }
      }
      if include_pr_review {
        let reviews = hub.list_reviews(objects, pr.id())
        for review in reviews {
          if search_limit_reached(options.limit, results.length()) {
            break
          }
          if not(matches_author_filter(options.author, review.author())) {
            continue
          }
          if matches_query_filter(options.query, [
              review.id(),
              review.pr_id(),
              review.author(),
              review.verdict().to_string(),
              review.body(),
            ]) {
            results.push(
              "pr-review #\{review.pr_id()}/\{review.id()} \{review.author()} [\{review.verdict().to_string()}]: \{preview_text(review.body())}",
            )
          }
        }
      }
    }
  }

  if include_issue || include_issue_comment {
    let issues = hub.list_issues(objects)
    for issue in issues {
      if search_limit_reached(options.limit, results.length()) {
        break
      }
      if not(matches_issue_state_filter(options.state, issue.state())) {
        continue
      }
      if not(matches_labels_filter(options.labels, issue.labels())) {
        continue
      }
      if include_issue &&
        matches_author_filter(options.author, issue.author()) &&
        matches_query_filter(options.query, [
          issue.id(),
          issue.title(),
          issue.body(),
          issue.author(),
          issue.labels().join(","),
          issue.assignees().join(","),
        ]) {
        results.push(
          "issue #\{issue.id()} [\{issue.state().to_string()}] \{issue.title()}",
        )
      }
      if include_issue_comment {
        let comments = hub.list_issue_comments(objects, issue.id())
        for comment in comments {
          if search_limit_reached(options.limit, results.length()) {
            break
          }
          if not(matches_author_filter(options.author, comment.author())) {
            continue
          }
          if matches_query_filter(options.query, [
              comment.id(),
              comment.issue_id(),
              comment.author(),
              comment.body(),
            ]) {
            results.push(
              "issue-comment #\{comment.issue_id()}/\{comment.id()} \{comment.author()}: \{preview_text(comment.body())}",
            )
          }
        }
      }
    }
  }

  if results.length() == 0 {
    print_line("No matches")
    return ()
  }
  for result in results {
    print_line(result)
  }
}

///|
async fn handle_hub(args : Array[String]) -> Unit raise Error {
  if args.length() == 0 {
    print_hub_usage()
    return ()
  }
  let subcmd = args[0]
  let rest = collect_args(args, 1)
  match subcmd {
    "help" | "-h" | "--help" => print_hub_usage()
    "init" => handle_hub_init(rest)
    "pr" => handle_hub_pr(rest)
    "issue" => handle_hub_issue(rest)
    "work-item" | "workitem" | "item" => handle_hub_work_item(rest)
    "note" => handle_hub_note(rest)
    "sync" => handle_hub_sync(rest)
    "dump" => handle_hub_dump(rest)
    "search" => handle_hub_search(rest)
    _ => {
      eprint_line("bit hub: unknown subcommand '\{subcmd}'")
      print_hub_usage()
      @sys.exit(1)
    }
  }
}

///|
async fn handle_hub_init(args : Array[String]) -> Unit raise Error {
  for arg in args {
    if arg.has_prefix("-") {
      warn_unimplemented_arg("hub init", arg)
    }
  }
  let root = get_work_root()
  let git_dir = root + "/.git"
  let fs = OsFs::new()
  let (objects, refs, _clock) = make_hub_stores(git_dir)
  let _ = init_hub_store(objects, refs)
  ensure_hub_merge_policy_file(fs, git_dir)
  print_line("Initialized hub metadata")
}

///|
async fn handle_hub_pr(args : Array[String]) -> Unit raise Error {
  if args.length() == 0 {
    print_hub_pr_usage()
    return ()
  }
  let subcmd = normalize_hub_pr_subcommand(args[0])
  let rest = collect_args(args, 1)
  match subcmd {
    "list" => handle_hub_pr_list(rest)
    "proposals" => handle_hub_pr_proposals(rest)
    "status" => handle_hub_pr_status(rest)
    "get" => handle_hub_pr_get(rest)
    "import" => handle_hub_pr_import(rest)
    "import-proposal" => handle_hub_pr_import_proposal(rest)
    "propose" => handle_hub_pr_propose(rest)
    "create" => handle_hub_pr_create(rest)
    "update" => handle_hub_pr_update(rest)
    "close" => handle_hub_pr_close(rest)
    "reopen" => handle_hub_pr_reopen(rest)
    "merge" => handle_hub_pr_merge(rest)
    "comment" => handle_hub_pr_comment(rest)
    "review" => handle_hub_pr_review(rest)
    "workflow" => handle_hub_pr_workflow(rest)
    "help" | "-h" | "--help" => print_hub_pr_usage()
    _ => {
      eprint_line("bit hub pr: unknown subcommand '\{subcmd}'")
      print_hub_pr_usage()
      @sys.exit(1)
    }
  }
}

///|
struct HubPrListOptions {
  state : @hub.PrState?
  limit : Int?
}

///|
fn parse_positive_list_limit(value : String) -> Int raise @bitcore.GitError {
  let parsed = @strconv.parse_int(value) catch {
    _ => raise @bitcore.GitError::InvalidObject("Invalid limit: \{value}")
  }
  if parsed <= 0 {
    raise @bitcore.GitError::InvalidObject("Limit must be positive")
  }
  parsed
}

///|
fn parse_hub_pr_list_options(
  args : Array[String],
) -> HubPrListOptions raise @bitcore.GitError {
  let common = parse_hub_list_options(args, "hub pr list", "PR", true, false)
  let state = match common.state {
    None => None
    Some(work_item_state) => Some(work_item_state.to_pr_state())
  }
  { state, limit: common.limit }
}

///|
async fn handle_hub_pr_list(args : Array[String]) -> Unit raise Error {
  let options = parse_hub_pr_list_options(args)
  let root = get_work_root()
  let git_dir = root + "/.git"
  let (objects, refs, _clock) = make_hub_stores(git_dir)
  let hub = load_hub_store(objects, refs)
  let prs = hub.list_prs(objects, state=options.state)
  let raw_limit = options.limit.unwrap_or(prs.length())
  let limit = if raw_limit < prs.length() { raw_limit } else { prs.length() }
  if limit == 0 {
    print_line("No pull requests")
    return ()
  }
  let mut i = 0
  while i < limit {
    prs[i] |> format_pr_summary |> print_line
    i += 1
  }
}

///|
async fn handle_hub_pr_proposals(args : Array[String]) -> Unit raise Error {
  let options = parse_hub_pr_list_options(args)
  let root = get_work_root()
  let git_dir = root + "/.git"
  let (objects, refs, _clock) = make_hub_stores(git_dir)
  let hub = load_hub_store(objects, refs)
  let candidates = hub.list_pr_proposals(objects)
  let prs : Array[@hub.PullRequest] = []
  for pr in candidates {
    match options.state {
      None => prs.push(pr)
      Some(s) => if pr.state() == s { prs.push(pr) }
    }
  }
  let raw_limit = options.limit.unwrap_or(prs.length())
  let limit = if raw_limit < prs.length() { raw_limit } else { prs.length() }
  if limit == 0 {
    print_line("No pull request proposals")
    return ()
  }
  let mut i = 0
  while i < limit {
    prs[i] |> format_pr_summary |> print_line
    i += 1
  }
}

///|
async fn handle_hub_pr_status(args : Array[String]) -> Unit raise Error {
  for arg in args {
    match arg {
      "help" | "-h" | "--help" => {
        print_hub_pr_usage()
        return ()
      }
      _ if arg.has_prefix("-") => warn_unimplemented_arg("hub pr status", arg)
      _ => warn_unimplemented_arg("hub pr status", arg)
    }
  }
  let root = get_work_root()
  let git_dir = root + "/.git"
  let (objects, refs, _clock) = make_hub_stores(git_dir)
  let hub = load_hub_store(objects, refs)
  let open_prs = hub.list_prs(objects, state=Some(@hub.PrState::Open))
  if open_prs.length() == 0 {
    print_line("No open pull requests")
    return ()
  }
  let branch_ids : Array[String] = []
  match detect_current_branch_name(git_dir) {
    Some(branch) => {
      print_line("Current branch: \{branch}")
      let mut branch_count = 0
      for pr in open_prs {
        if pr_matches_branch(pr, branch) {
          branch_ids.push(pr.id())
          branch_count += 1
          pr |> format_pr_summary |> print_line
        }
      }
      if branch_count == 0 {
        print_line("No open pull request for current branch")
      }
    }
    None => print_line("Current branch: (detached HEAD)")
  }
  let author = get_author_string()
  let mut mine_count = 0
  for pr in open_prs {
    if pr.author() == author && not(branch_ids.contains(pr.id())) {
      if mine_count == 0 {
        print_line("Open pull requests authored by \{author}:")
      }
      mine_count += 1
      pr |> format_pr_summary |> print_line
    }
  }
  if mine_count == 0 {
    print_line("No open pull requests authored by \{author}")
  }
}

///|
async fn handle_hub_pr_import(args : Array[String]) -> Unit raise Error {
  let mut repo : String? = None
  let mut state = "all"
  let mut limit = 100
  let mut provider = GitHubImportProvider::GhCli
  let mut input_path : String? = None
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    match arg {
      "-h" | "--help" | "help" => {
        print_hub_pr_usage()
        return ()
      }
      "--repo" if i + 1 < args.length() => {
        repo = Some(args[i + 1])
        i += 2
        continue
      }
      "--repo" =>
        raise @bitcore.GitError::InvalidObject(
          "hub pr import: --repo requires a value",
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
        raise @bitcore.GitError::InvalidObject(
          "hub pr import: --state requires a value",
        )
      _ if arg.has_prefix("--state=") => {
        state = String::unsafe_substring(arg, start=8, end=arg.length())
        i += 1
        continue
      }
      "--limit" if i + 1 < args.length() => {
        limit = @strconv.parse_int(args[i + 1]) catch {
          _ =>
            raise @bitcore.GitError::InvalidObject(
              "Invalid limit: \{args[i + 1]}",
            )
        }
        i += 2
        continue
      }
      "--limit" =>
        raise @bitcore.GitError::InvalidObject(
          "hub pr import: --limit requires a value",
        )
      "--provider" if i + 1 < args.length() => {
        provider = parse_github_import_provider_option(args[i + 1])
        i += 2
        continue
      }
      "--provider" =>
        raise @bitcore.GitError::InvalidObject(
          "hub pr import: --provider requires a value",
        )
      "--input" if i + 1 < args.length() => {
        input_path = Some(args[i + 1])
        i += 2
        continue
      }
      "--input" =>
        raise @bitcore.GitError::InvalidObject(
          "hub pr import: --input requires a value",
        )
      _ if arg.has_prefix("--limit=") => {
        let value = String::unsafe_substring(arg, start=8, end=arg.length())
        limit = @strconv.parse_int(value) catch {
          _ => raise @bitcore.GitError::InvalidObject("Invalid limit: \{value}")
        }
        i += 1
        continue
      }
      _ if arg.has_prefix("--provider=") => {
        let value = String::unsafe_substring(arg, start=11, end=arg.length())
        provider = parse_github_import_provider_option(value)
        i += 1
        continue
      }
      _ if arg.has_prefix("--input=") => {
        input_path = Some(
          String::unsafe_substring(arg, start=8, end=arg.length()),
        )
        i += 1
        continue
      }
      _ if arg.has_prefix("-") => warn_unimplemented_arg("hub pr import", arg)
      _ => warn_unimplemented_arg("hub pr import", arg)
    }
    i += 1
  }
  let state_value = state.to_lower()
  match state_value {
    "open" | "closed" | "merged" | "all" => ()
    _ => raise @bitcore.GitError::InvalidObject("Unknown PR state: \{state}")
  }
  if limit <= 0 {
    raise @bitcore.GitError::InvalidObject("Limit must be positive")
  }
  let root = get_work_root()
  let git_dir = root + "/.git"
  let fs = OsFs::new()
  let (stdout, _stderr) = match provider {
    GitHubImportProvider::GhCli => {
      let repo_name = resolve_github_repo(fs, git_dir, repo)
      gh_pr_list(repo_name, state_value, limit)
    }
    GitHubImportProvider::JsonFile =>
      read_import_json_from_file(fs, "hub pr import", input_path)
  }
  let prs = parse_gh_prs(stdout)
  if prs.length() == 0 {
    print_line("No pull requests to import")
    return ()
  }
  let (objects, refs, clock) = make_hub_stores(git_dir)
  let hub = init_hub_store(objects, refs)
  let stats = hub.import_prs(objects, refs, clock, prs)
  print_line(
    "Imported PRs: created \{stats.created()}, updated \{stats.updated()}",
  )
}

///|
async fn handle_hub_pr_import_proposal(
  args : Array[String],
) -> Unit raise Error {
  if args.length() == 0 {
    print_hub_pr_usage()
    return ()
  }
  let first = args[0]
  if first == "-h" || first == "--help" || first == "help" {
    print_hub_pr_usage()
    return ()
  }
  let mut proposal_id : String? = None
  for arg in args {
    if arg.has_prefix("-") {
      warn_unimplemented_arg("hub pr import-proposal", arg)
      continue
    }
    if proposal_id is None {
      proposal_id = Some(arg)
    } else {
      warn_unimplemented_arg("hub pr import-proposal", arg)
    }
  }
  guard proposal_id is Some(id) else {
    raise @bitcore.GitError::InvalidObject("Proposal id is required")
  }
  let root = get_work_root()
  let git_dir = root + "/.git"
  let (objects, refs, clock) = make_hub_stores(git_dir)
  let hub = init_hub_store(objects, refs)
  let proposals = hub.list_pr_proposals(objects)
  let mut selected : @hub.PullRequest? = None
  for proposal in proposals {
    if proposal.id() == id {
      selected = Some(proposal)
      break
    }
  }
  guard selected is Some(pr) else {
    raise @bitcore.GitError::InvalidObject("PR proposal not found: \{id}")
  }
  let stats = hub.import_prs(objects, refs, clock, [pr])
  print_line(
    "Imported proposal as PR: created \{stats.created()}, updated \{stats.updated()}",
  )
}

///|
async fn handle_hub_pr_get(args : Array[String]) -> Unit raise Error {
  if args.length() == 0 {
    print_hub_pr_usage()
    return ()
  }
  let first = args[0]
  if first == "-h" || first == "--help" || first == "help" {
    print_hub_pr_usage()
    return ()
  }
  let mut pr_id : String? = None
  for arg in args {
    if arg.has_prefix("-") {
      warn_unimplemented_arg("hub pr get", arg)
      continue
    }
    if pr_id is None {
      pr_id = Some(arg)
    } else {
      warn_unimplemented_arg("hub pr get", arg)
    }
  }
  guard pr_id is Some(id) else {
    raise @bitcore.GitError::InvalidObject("PR id is required")
  }
  let root = get_work_root()
  let git_dir = root + "/.git"
  let (objects, refs, _clock) = make_hub_stores(git_dir)
  let hub = load_hub_store(objects, refs)
  let pr = hub.get_pr(objects, id)
  guard pr is Some(val) else {
    raise @bitcore.GitError::InvalidObject("PR not found: \{id}")
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
struct HubPrCreateOptions {
  title : String
  body : String
  source_branch : String
  target_branch : String
  source_repo : String?
  source_ref : String?
}

///|
async fn parse_hub_pr_create_options(
  args : Array[String],
  warn_context : String,
) -> HubPrCreateOptions raise Error {
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
      "-t" | "--title" =>
        raise @bitcore.GitError::InvalidObject(
          "\{warn_context}: --title requires a value",
        )
      "-m" | "-b" | "--message" | "--body" if i + 1 < args.length() => {
        body = Some(args[i + 1])
        i += 2
        continue
      }
      "-m" | "-b" | "--message" | "--body" =>
        raise @bitcore.GitError::InvalidObject(
          "\{warn_context}: --body requires a value",
        )
      "--source" | "--head" if i + 1 < args.length() => {
        source_branch = Some(args[i + 1])
        i += 2
        continue
      }
      "--source" | "--head" =>
        raise @bitcore.GitError::InvalidObject(
          "\{warn_context}: --source requires a value",
        )
      "--target" | "--base" if i + 1 < args.length() => {
        target_branch = Some(args[i + 1])
        i += 2
        continue
      }
      "--target" | "--base" =>
        raise @bitcore.GitError::InvalidObject(
          "\{warn_context}: --target requires a value",
        )
      "--source-repo" if i + 1 < args.length() => {
        source_repo = Some(args[i + 1])
        i += 2
        continue
      }
      "--source-repo" =>
        raise @bitcore.GitError::InvalidObject(
          "\{warn_context}: --source-repo requires a value",
        )
      "--source-ref" if i + 1 < args.length() => {
        source_ref = Some(args[i + 1])
        i += 2
        continue
      }
      "--source-ref" =>
        raise @bitcore.GitError::InvalidObject(
          "\{warn_context}: --source-ref requires a value",
        )
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
      _ if arg.has_prefix("--head=") => {
        source_branch = Some(
          String::unsafe_substring(arg, start=7, end=arg.length()),
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
      _ if arg.has_prefix("--base=") => {
        target_branch = Some(
          String::unsafe_substring(arg, start=7, end=arg.length()),
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
        warn_unimplemented_arg(warn_context, arg)
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
    raise @bitcore.GitError::InvalidObject("Missing --title")
  }
  guard source_branch is Some(src) else {
    raise @bitcore.GitError::InvalidObject("Missing --source")
  }
  guard target_branch is Some(tgt) else {
    raise @bitcore.GitError::InvalidObject("Missing --target")
  }
  {
    title: t,
    body: body.unwrap_or(""),
    source_branch: src,
    target_branch: tgt,
    source_repo,
    source_ref,
  }
}

///|
async fn handle_hub_pr_create(args : Array[String]) -> Unit raise Error {
  let options = parse_hub_pr_create_options(args, "hub pr create")
  let root = get_work_root()
  let git_dir = root + "/.git"
  let (objects, refs, clock) = make_hub_stores(git_dir)
  let fs = OsFs::new()
  let source_repo_value = match options.source_repo {
    Some(repo) => if repo.length() == 0 { None } else { Some(repo) }
    None => infer_source_repo_name(fs, git_dir)
  }
  let source_ref_value = match options.source_ref {
    Some(ref_name) =>
      if ref_name.length() == 0 {
        Some(normalize_branch_ref(options.source_branch))
      } else {
        Some(normalize_branch_ref(ref_name))
      }
    None => Some(normalize_branch_ref(options.source_branch))
  }
  let hub = init_hub_store(objects, refs)
  let pr = hub.create_pr(
    objects,
    refs,
    clock,
    options.title,
    options.body,
    options.source_branch,
    options.target_branch,
    get_author_string(),
    source_repo=source_repo_value,
    source_ref=source_ref_value,
  )
  print_line(pr.serialize())
}

///|
async fn handle_hub_pr_propose(args : Array[String]) -> Unit raise Error {
  let options = parse_hub_pr_create_options(args, "hub pr propose")
  let root = get_work_root()
  let git_dir = root + "/.git"
  let (objects, refs, clock) = make_hub_stores(git_dir)
  let fs = OsFs::new()
  let source_repo_value = match options.source_repo {
    Some(repo) => if repo.length() == 0 { None } else { Some(repo) }
    None => infer_source_repo_name(fs, git_dir)
  }
  let source_ref_value = match options.source_ref {
    Some(ref_name) =>
      if ref_name.length() == 0 {
        Some(normalize_branch_ref(options.source_branch))
      } else {
        Some(normalize_branch_ref(ref_name))
      }
    None => Some(normalize_branch_ref(options.source_branch))
  }
  let hub = init_hub_store(objects, refs)
  let proposal = hub.propose_pr(
    objects,
    refs,
    clock,
    options.title,
    options.body,
    options.source_branch,
    options.target_branch,
    get_author_string(),
    source_repo=source_repo_value,
    source_ref=source_ref_value,
  )
  print_line(proposal.serialize())
}

///|
async fn handle_hub_pr_update(args : Array[String]) -> Unit raise Error {
  if args.length() == 0 {
    print_hub_pr_usage()
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
      "-t" | "--title" =>
        raise @bitcore.GitError::InvalidObject(
          "hub pr update: --title requires a value",
        )
      "-m" | "-b" | "--message" | "--body" if i + 1 < args.length() => {
        body = Some(args[i + 1])
        i += 2
        continue
      }
      "-m" | "-b" | "--message" | "--body" =>
        raise @bitcore.GitError::InvalidObject(
          "hub pr update: --body requires a value",
        )
      "--label" | "-l" if i + 1 < args.length() => {
        labels.push(args[i + 1])
        i += 2
        continue
      }
      "--label" | "-l" =>
        raise @bitcore.GitError::InvalidObject(
          "hub pr update: --label requires a value",
        )
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
        warn_unimplemented_arg("hub pr update", arg)
        i += 1
        continue
      }
      _ => {
        if pr_id is None {
          pr_id = Some(arg)
        } else {
          warn_unimplemented_arg("hub pr update", arg)
        }
        i += 1
        continue
      }
    }
  }
  guard pr_id is Some(id) else {
    raise @bitcore.GitError::InvalidObject("PR id is required")
  }
  let label_option = if labels.length() > 0 { Some(labels) } else { None }
  let root = get_work_root()
  let git_dir = root + "/.git"
  let (objects, refs, clock) = make_hub_stores(git_dir)
  let hub = init_hub_store(objects, refs)
  let pr = hub.update_pr(
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
async fn handle_hub_pr_close(args : Array[String]) -> Unit raise Error {
  if args.length() == 0 {
    print_hub_pr_usage()
    return ()
  }
  let mut pr_id : String? = None
  for arg in args {
    if arg.has_prefix("-") {
      warn_unimplemented_arg("hub pr close", arg)
      continue
    }
    if pr_id is None {
      pr_id = Some(arg)
    } else {
      warn_unimplemented_arg("hub pr close", arg)
    }
  }
  guard pr_id is Some(id) else {
    raise @bitcore.GitError::InvalidObject("PR id is required")
  }
  let root = get_work_root()
  let git_dir = root + "/.git"
  let (objects, refs, clock) = make_hub_stores(git_dir)
  let hub = init_hub_store(objects, refs)
  hub.close_pr(objects, refs, clock, id)
  print_line("Closed PR #\{id}")
}

///|
async fn handle_hub_pr_reopen(args : Array[String]) -> Unit raise Error {
  if args.length() == 0 {
    print_hub_pr_usage()
    return ()
  }
  let mut pr_id : String? = None
  for arg in args {
    if arg.has_prefix("-") {
      warn_unimplemented_arg("hub pr reopen", arg)
      continue
    }
    if pr_id is None {
      pr_id = Some(arg)
    } else {
      warn_unimplemented_arg("hub pr reopen", arg)
    }
  }
  guard pr_id is Some(id) else {
    raise @bitcore.GitError::InvalidObject("PR id is required")
  }
  let root = get_work_root()
  let git_dir = root + "/.git"
  let (objects, refs, clock) = make_hub_stores(git_dir)
  let hub = init_hub_store(objects, refs)
  hub.reopen_pr(objects, refs, clock, id)
  print_line("Reopened PR #\{id}")
}

///|
async fn handle_hub_pr_merge(args : Array[String]) -> Unit raise Error {
  if args.length() == 0 {
    print_hub_pr_usage()
    return ()
  }
  let mut pr_id : String? = None
  let mut strategy : @hub.PrMergeStrategy? = None
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    if parse_merge_strategy_flag(arg) is Some(flag_strategy) {
      strategy = Some(flag_strategy)
      i += 1
      continue
    }
    match arg {
      "--rebase" =>
        raise @bitcore.GitError::InvalidObject(
          "Merge strategy 'rebase' is not supported",
        )
      "--strategy" if i + 1 < args.length() => {
        let value = args[i + 1]
        match parse_merge_strategy(value) {
          Some(s) => strategy = Some(s)
          None =>
            raise @bitcore.GitError::InvalidObject(
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
            raise @bitcore.GitError::InvalidObject(
              "Unknown merge strategy: \{value}",
            )
        }
        i += 1
        continue
      }
      _ if arg.has_prefix("-") => {
        warn_unimplemented_arg("hub pr merge", arg)
        i += 1
        continue
      }
      _ => {
        if pr_id is None {
          pr_id = Some(arg)
        } else {
          warn_unimplemented_arg("hub pr merge", arg)
        }
        i += 1
        continue
      }
    }
  }
  guard pr_id is Some(id) else {
    raise @bitcore.GitError::InvalidObject("PR id is required")
  }
  let root = get_work_root()
  let git_dir = root + "/.git"
  let fs = OsFs::new()
  let (objects, refs, clock) = make_hub_stores(git_dir)
  let hub = init_hub_store(objects, refs)
  let merge_policy = load_hub_merge_policy(fs, git_dir)
  hub.check_merge_policy(
    objects,
    refs,
    id,
    merge_policy,
    signing_key=get_hub_signing_key(),
  )
  let result = match strategy {
    Some(s) =>
      hub.merge_pr(objects, refs, clock, id, get_author_string(), strategy=s)
    None => hub.merge_pr(objects, refs, clock, id, get_author_string())
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
async fn handle_hub_pr_comment(args : Array[String]) -> Unit raise Error {
  if args.length() == 0 {
    print_hub_pr_usage()
    return ()
  }
  let first = args[0]
  let subcmd = resolve_hub_comment_subcommand(first)
  let rest = if subcmd == first { collect_args(args, 1) } else { args }
  match subcmd {
    "add" => handle_hub_pr_comment_add(rest)
    "list" => handle_hub_pr_comment_list(rest)
    "help" | "-h" | "--help" => print_hub_pr_usage()
    _ => {
      eprint_line("bit hub pr comment: unknown subcommand '\{subcmd}'")
      print_hub_pr_usage()
      @sys.exit(1)
    }
  }
}

///|
async fn handle_hub_pr_comment_add(args : Array[String]) -> Unit raise Error {
  let mut pr_id : String? = None
  let mut body : String? = None
  let mut reply_to : String? = None
  let mut file_path : String? = None
  let mut line_number : Int? = None
  let mut commit_id : @bitcore.ObjectId? = None
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    match arg {
      "-m" | "-b" | "--message" | "--body" if i + 1 < args.length() => {
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
        commit_id = args[i + 1] |> @bitcore.ObjectId::from_hex |> Some
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
        commit_id = value |> @bitcore.ObjectId::from_hex |> Some
        i += 1
        continue
      }
      _ if arg.has_prefix("-") => {
        warn_unimplemented_arg("hub pr comment add", arg)
        i += 1
        continue
      }
      _ => {
        if pr_id is None {
          pr_id = Some(arg)
        } else {
          warn_unimplemented_arg("hub pr comment add", arg)
        }
        i += 1
        continue
      }
    }
  }
  guard pr_id is Some(id) else {
    raise @bitcore.GitError::InvalidObject("PR id is required")
  }
  guard body is Some(msg) else {
    raise @bitcore.GitError::InvalidObject("Missing --body")
  }
  let root = get_work_root()
  let git_dir = root + "/.git"
  let (objects, refs, clock) = make_hub_stores(git_dir)
  let hub = init_hub_store(objects, refs)
  let comment = hub.add_comment(
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
async fn handle_hub_pr_comment_list(args : Array[String]) -> Unit raise Error {
  if args.length() == 0 {
    print_hub_pr_usage()
    return ()
  }
  let mut pr_id : String? = None
  for arg in args {
    if arg.has_prefix("-") {
      warn_unimplemented_arg("hub pr comment list", arg)
      continue
    }
    if pr_id is None {
      pr_id = Some(arg)
    } else {
      warn_unimplemented_arg("hub pr comment list", arg)
    }
  }
  guard pr_id is Some(id) else {
    raise @bitcore.GitError::InvalidObject("PR id is required")
  }
  let root = get_work_root()
  let git_dir = root + "/.git"
  let (objects, refs, _clock) = make_hub_stores(git_dir)
  let hub = load_hub_store(objects, refs)
  let comments = hub.list_comments(objects, id)
  if comments.length() == 0 {
    print_line("No comments")
    return ()
  }
  for comment in comments {
    print_line(comment.serialize())
  }
}

///|
async fn handle_hub_pr_review(args : Array[String]) -> Unit raise Error {
  if args.length() == 0 {
    print_hub_pr_usage()
    return ()
  }
  let first = args[0]
  let subcmd = resolve_hub_review_subcommand(first)
  let rest = if subcmd == first { collect_args(args, 1) } else { args }
  match subcmd {
    "submit" => handle_hub_pr_review_submit(rest)
    "list" => handle_hub_pr_review_list(rest)
    "help" | "-h" | "--help" => print_hub_pr_usage()
    _ => {
      eprint_line("bit hub pr review: unknown subcommand '\{subcmd}'")
      print_hub_pr_usage()
      @sys.exit(1)
    }
  }
}

///|
async fn handle_hub_pr_review_submit(args : Array[String]) -> Unit raise Error {
  let mut pr_id : String? = None
  let mut verdict : @hub.ReviewVerdict? = None
  let mut body : String? = None
  let mut commit_id : @bitcore.ObjectId? = None
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    if parse_review_verdict_flag(arg) is Some(flag_verdict) {
      verdict = Some(flag_verdict)
      i += 1
      continue
    }
    match arg {
      "--verdict" if i + 1 < args.length() => {
        let value = args[i + 1]
        match parse_review_verdict(value) {
          Some(v) => verdict = Some(v)
          None =>
            raise @bitcore.GitError::InvalidObject(
              "Unknown review verdict: \{value}",
            )
        }
        i += 2
        continue
      }
      "--verdict" =>
        raise @bitcore.GitError::InvalidObject(
          "hub pr review submit: --verdict requires a value",
        )
      "--commit" if i + 1 < args.length() => {
        commit_id = args[i + 1] |> @bitcore.ObjectId::from_hex |> Some
        i += 2
        continue
      }
      "--commit" =>
        raise @bitcore.GitError::InvalidObject(
          "hub pr review submit: --commit requires a value",
        )
      "-m" | "-b" | "--message" | "--body" if i + 1 < args.length() => {
        body = Some(args[i + 1])
        i += 2
        continue
      }
      "-m" | "-b" | "--message" | "--body" =>
        raise @bitcore.GitError::InvalidObject(
          "hub pr review submit: --body requires a value",
        )
      _ if arg.has_prefix("--verdict=") => {
        let value = String::unsafe_substring(arg, start=10, end=arg.length())
        match parse_review_verdict(value) {
          Some(v) => verdict = Some(v)
          None =>
            raise @bitcore.GitError::InvalidObject(
              "Unknown review verdict: \{value}",
            )
        }
        i += 1
        continue
      }
      _ if arg.has_prefix("--commit=") => {
        let value = String::unsafe_substring(arg, start=9, end=arg.length())
        commit_id = value |> @bitcore.ObjectId::from_hex |> Some
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
        warn_unimplemented_arg("hub pr review submit", arg)
        i += 1
        continue
      }
      _ => {
        if pr_id is None {
          pr_id = Some(arg)
        } else {
          warn_unimplemented_arg("hub pr review submit", arg)
        }
        i += 1
        continue
      }
    }
  }
  guard pr_id is Some(id) else {
    raise @bitcore.GitError::InvalidObject("PR id is required")
  }
  guard verdict is Some(v) else {
    raise @bitcore.GitError::InvalidObject("Missing --verdict")
  }
  guard commit_id is Some(cid) else {
    raise @bitcore.GitError::InvalidObject("Missing --commit")
  }
  let review_body = body.unwrap_or("")
  let root = get_work_root()
  let git_dir = root + "/.git"
  let (objects, refs, clock) = make_hub_stores(git_dir)
  let hub = init_hub_store(objects, refs)
  let review = hub.submit_review(
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
async fn handle_hub_pr_review_list(args : Array[String]) -> Unit raise Error {
  if args.length() == 0 {
    print_hub_pr_usage()
    return ()
  }
  let mut pr_id : String? = None
  for arg in args {
    if arg.has_prefix("-") {
      warn_unimplemented_arg("hub pr review list", arg)
      continue
    }
    if pr_id is None {
      pr_id = Some(arg)
    } else {
      warn_unimplemented_arg("hub pr review list", arg)
    }
  }
  guard pr_id is Some(id) else {
    raise @bitcore.GitError::InvalidObject("PR id is required")
  }
  let root = get_work_root()
  let git_dir = root + "/.git"
  let (objects, refs, _clock) = make_hub_stores(git_dir)
  let hub = load_hub_store(objects, refs)
  let reviews = hub.list_reviews(objects, id)
  if reviews.length() == 0 {
    print_line("No reviews")
    return ()
  }
  for review in reviews {
    print_line(review.serialize())
  }
}

///|
async fn handle_hub_pr_workflow(args : Array[String]) -> Unit raise Error {
  if args.length() == 0 {
    print_hub_pr_usage()
    return ()
  }
  let subcmd = args[0]
  let rest = collect_args(args, 1)
  match subcmd {
    "submit" => handle_hub_pr_workflow_submit(rest)
    "list" => handle_hub_pr_workflow_list(rest)
    "help" | "-h" | "--help" => print_hub_pr_usage()
    _ => {
      eprint_line("bit hub pr workflow: unknown subcommand '\{subcmd}'")
      print_hub_pr_usage()
      @sys.exit(1)
    }
  }
}

///|
async fn handle_hub_pr_workflow_submit(
  args : Array[String],
) -> Unit raise Error {
  let mut pr_id : String? = None
  let mut task : String? = None
  let mut status : @hub.PrWorkflowStatus? = None
  let mut workspace_fingerprint = ""
  let mut txn_id : String? = None
  let mut author : String? = None
  let mut summary = ""
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    match arg {
      "--task" if i + 1 < args.length() => {
        task = Some(args[i + 1])
        i += 2
        continue
      }
      "--status" if i + 1 < args.length() => {
        let raw = args[i + 1]
        match @hub.parse_pr_workflow_status(raw) {
          Some(value) => status = Some(value)
          None =>
            raise @bitcore.GitError::InvalidObject(
              "Unknown workflow status: \{raw}",
            )
        }
        i += 2
        continue
      }
      "--fingerprint" if i + 1 < args.length() => {
        workspace_fingerprint = args[i + 1]
        i += 2
        continue
      }
      "--txn" if i + 1 < args.length() => {
        txn_id = Some(args[i + 1])
        i += 2
        continue
      }
      "--author" if i + 1 < args.length() => {
        author = Some(args[i + 1])
        i += 2
        continue
      }
      "-m" | "--summary" | "--body" if i + 1 < args.length() => {
        summary = args[i + 1]
        i += 2
        continue
      }
      _ if arg.has_prefix("--task=") => {
        task = Some(String::unsafe_substring(arg, start=7, end=arg.length()))
        i += 1
        continue
      }
      _ if arg.has_prefix("--status=") => {
        let raw = String::unsafe_substring(arg, start=9, end=arg.length())
        match @hub.parse_pr_workflow_status(raw) {
          Some(value) => status = Some(value)
          None =>
            raise @bitcore.GitError::InvalidObject(
              "Unknown workflow status: \{raw}",
            )
        }
        i += 1
        continue
      }
      _ if arg.has_prefix("--fingerprint=") => {
        workspace_fingerprint = String::unsafe_substring(
          arg,
          start=14,
          end=arg.length(),
        )
        i += 1
        continue
      }
      _ if arg.has_prefix("--txn=") => {
        txn_id = Some(String::unsafe_substring(arg, start=6, end=arg.length()))
        i += 1
        continue
      }
      _ if arg.has_prefix("--author=") => {
        author = Some(String::unsafe_substring(arg, start=9, end=arg.length()))
        i += 1
        continue
      }
      _ if arg.has_prefix("--summary=") => {
        summary = String::unsafe_substring(arg, start=10, end=arg.length())
        i += 1
        continue
      }
      _ if arg.has_prefix("--body=") => {
        summary = String::unsafe_substring(arg, start=7, end=arg.length())
        i += 1
        continue
      }
      _ if arg.has_prefix("-") => {
        warn_unimplemented_arg("hub pr workflow submit", arg)
        i += 1
        continue
      }
      _ => {
        if pr_id is None {
          pr_id = Some(arg)
        } else {
          warn_unimplemented_arg("hub pr workflow submit", arg)
        }
        i += 1
        continue
      }
    }
  }
  guard pr_id is Some(id) else {
    raise @bitcore.GitError::InvalidObject("PR id is required")
  }
  guard task is Some(task_name) else {
    raise @bitcore.GitError::InvalidObject("Missing --task")
  }
  guard status is Some(workflow_status) else {
    raise @bitcore.GitError::InvalidObject("Missing --status")
  }
  let root = get_work_root()
  let git_dir = root + "/.git"
  let (objects, refs, clock) = make_hub_stores(git_dir)
  let hub = init_hub_store(objects, refs)
  let workflow = hub.record_pr_workflow(
    objects,
    refs,
    clock,
    id,
    task_name,
    workflow_status,
    workspace_fingerprint,
    author.unwrap_or(get_author_string()),
    txn_id~,
    summary~,
  )
  let txn_text = workflow.txn_id().unwrap_or("")
  print_line(
    "pr workflow \{id} task=\{workflow.task()} status=\{workflow.status().to_string()} fingerprint=\{workflow.workspace_fingerprint()} txn=\{txn_text}",
  )
}

///|
async fn handle_hub_pr_workflow_list(args : Array[String]) -> Unit raise Error {
  let mut pr_id : String? = None
  for arg in args {
    if arg.has_prefix("-") {
      warn_unimplemented_arg("hub pr workflow list", arg)
      continue
    }
    if pr_id is None {
      pr_id = Some(arg)
    } else {
      warn_unimplemented_arg("hub pr workflow list", arg)
    }
  }
  guard pr_id is Some(id) else {
    raise @bitcore.GitError::InvalidObject("PR id is required")
  }
  let root = get_work_root()
  let git_dir = root + "/.git"
  let (objects, refs, _clock) = make_hub_stores(git_dir)
  let hub = load_hub_store(objects, refs)
  let workflows = hub.list_pr_workflows(objects, id)
  if workflows.length() == 0 {
    print_line("No workflows")
    return ()
  }
  for workflow in workflows {
    let txn_text = workflow.txn_id().unwrap_or("")
    print_line(
      "pr=\{id} task=\{workflow.task()} status=\{workflow.status().to_string()} fingerprint=\{workflow.workspace_fingerprint()} txn=\{txn_text} updated=\{workflow.updated_at().to_string()} author=\{workflow.author()}",
    )
  }
}

///|
async fn handle_hub_issue(args : Array[String]) -> Unit raise Error {
  if args.length() == 0 {
    print_hub_issue_usage()
    return ()
  }
  let subcmd = normalize_hub_issue_subcommand(args[0])
  let rest = collect_args(args, 1)
  match subcmd {
    "list" => handle_hub_issue_list(rest)
    "get" => handle_hub_issue_get(rest)
    "import" => handle_hub_issue_import(rest)
    "create" => handle_hub_issue_create(rest)
    "update" => handle_hub_issue_update(rest)
    "close" => handle_hub_issue_close(rest)
    "reopen" => handle_hub_issue_reopen(rest)
    "comment" => handle_hub_issue_comment(rest)
    "link" => handle_hub_issue_link(rest)
    "help" | "-h" | "--help" => print_hub_issue_usage()
    _ => {
      eprint_line("bit hub issue: unknown subcommand '\{subcmd}'")
      print_hub_issue_usage()
      @sys.exit(1)
    }
  }
}

///|
async fn handle_hub_work_item(args : Array[String]) -> Unit raise Error {
  if args.length() == 0 {
    print_hub_work_item_usage()
    return ()
  }
  let subcmd = normalize_hub_work_item_subcommand(args[0])
  let rest = collect_args(args, 1)
  match subcmd {
    "list" => handle_hub_work_item_list(rest)
    "get" => handle_hub_work_item_get(rest)
    "help" | "-h" | "--help" => print_hub_work_item_usage()
    _ => {
      eprint_line("bit hub work-item: unknown subcommand '\{subcmd}'")
      print_hub_work_item_usage()
      @sys.exit(1)
    }
  }
}

///|
struct HubWorkItemListOptions {
  state : @hub.WorkItemState?
  kind : @hub.WorkItemKind?
  limit : Int?
}

///|
struct HubIssueListOptions {
  state : @hub.IssueState?
  limit : Int?
}

///|
fn parse_work_item_state_for_list(
  value : String,
  unknown_state_label : String,
  allow_merged : Bool,
) -> @hub.WorkItemState raise @bitcore.GitError {
  let state = parse_work_item_state(value)
  guard state is Some(parsed) else {
    raise @bitcore.GitError::InvalidObject(
      "Unknown \{unknown_state_label} state: \{value}",
    )
  }
  if not(allow_merged) && parsed == @hub.WorkItemState::Merged {
    raise @bitcore.GitError::InvalidObject(
      "Unknown \{unknown_state_label} state: \{value}",
    )
  }
  parsed
}

///|
fn parse_hub_list_options(
  args : Array[String],
  context : String,
  unknown_state_label : String,
  allow_merged : Bool,
  allow_kind : Bool,
) -> HubWorkItemListOptions raise @bitcore.GitError {
  let mut state : @hub.WorkItemState? = None
  let mut kind : @hub.WorkItemKind? = None
  let mut limit : Int? = None
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    if allow_kind {
      if parse_work_item_state_flag(arg) is Some(flag_state) {
        state = Some(flag_state)
        i += 1
        continue
      }
    } else if allow_merged {
      if parse_pr_state_flag(arg) is Some(flag_state) {
        state = Some(flag_state.to_work_item_state())
        i += 1
        continue
      }
    } else if parse_issue_state_flag(arg) is Some(flag_state) {
      state = Some(flag_state.to_work_item_state())
      i += 1
      continue
    }
    if allow_kind {
      if parse_work_item_kind_flag(arg) is Some(flag_kind) {
        kind = Some(flag_kind)
        i += 1
        continue
      }
    }
    match arg {
      "--state" if i + 1 < args.length() => {
        state = Some(
          parse_work_item_state_for_list(
            args[i + 1],
            unknown_state_label,
            allow_merged,
          ),
        )
        i += 2
        continue
      }
      "--state" =>
        raise @bitcore.GitError::InvalidObject(
          "\{context}: --state requires a value",
        )
      _ if arg.has_prefix("--state=") => {
        let value = String::unsafe_substring(arg, start=8, end=arg.length())
        state = Some(
          parse_work_item_state_for_list(
            value, unknown_state_label, allow_merged,
          ),
        )
        i += 1
        continue
      }
      "--kind" if allow_kind && i + 1 < args.length() => {
        let value = args[i + 1]
        if parse_work_item_kind(value) is Some(k) {
          kind = Some(k)
        } else {
          raise @bitcore.GitError::InvalidObject(
            "Unknown work item kind: \{value}",
          )
        }
        i += 2
        continue
      }
      "--kind" if allow_kind =>
        raise @bitcore.GitError::InvalidObject(
          "\{context}: --kind requires a value",
        )
      _ if allow_kind && arg.has_prefix("--kind=") => {
        let value = String::unsafe_substring(arg, start=7, end=arg.length())
        if parse_work_item_kind(value) is Some(k) {
          kind = Some(k)
        } else {
          raise @bitcore.GitError::InvalidObject(
            "Unknown work item kind: \{value}",
          )
        }
        i += 1
        continue
      }
      "--limit" | "-L" if i + 1 < args.length() => {
        limit = Some(parse_positive_list_limit(args[i + 1]))
        i += 2
        continue
      }
      "--limit" | "-L" =>
        raise @bitcore.GitError::InvalidObject(
          "\{context}: --limit requires a value",
        )
      _ if arg.has_prefix("--limit=") => {
        let value = String::unsafe_substring(arg, start=8, end=arg.length())
        limit = Some(parse_positive_list_limit(value))
        i += 1
        continue
      }
      _ if arg.has_prefix("-") => ()
      _ => ()
    }
    i += 1
  }
  { state, kind, limit }
}

///|
fn parse_hub_issue_list_options(
  args : Array[String],
) -> HubIssueListOptions raise @bitcore.GitError {
  let common = parse_hub_list_options(
    args, "hub issue list", "issue", false, false,
  )
  let state = match common.state {
    None => None
    Some(work_item_state) => work_item_state.to_issue_state()
  }
  { state, limit: common.limit }
}

///|
fn parse_hub_work_item_list_options(
  args : Array[String],
) -> HubWorkItemListOptions raise @bitcore.GitError {
  parse_hub_list_options(args, "hub work-item list", "work item", true, true)
}

///|
async fn handle_hub_issue_list(args : Array[String]) -> Unit raise Error {
  let options = parse_hub_issue_list_options(args)
  let root = get_work_root()
  let git_dir = root + "/.git"
  let (objects, refs, _clock) = make_hub_stores(git_dir)
  let hub = load_hub_store(objects, refs)
  let issues = hub.list_issues(objects, state=options.state)
  let raw_limit = options.limit.unwrap_or(issues.length())
  let limit = if raw_limit < issues.length() {
    raw_limit
  } else {
    issues.length()
  }
  if limit == 0 {
    print_line("No issues")
    return ()
  }
  let mut i = 0
  while i < limit {
    issues[i] |> format_issue_summary |> print_line
    i += 1
  }
}

///|
async fn handle_hub_work_item_list(args : Array[String]) -> Unit raise Error {
  let options = parse_hub_work_item_list_options(args)
  let root = get_work_root()
  let git_dir = root + "/.git"
  let (objects, refs, _clock) = make_hub_stores(git_dir)
  let hub = load_hub_store(objects, refs)
  let items = hub.list_work_items(
    objects,
    state=options.state,
    kind=options.kind,
  )
  let raw_limit = options.limit.unwrap_or(items.length())
  let limit = if raw_limit < items.length() {
    raw_limit
  } else {
    items.length()
  }
  if limit == 0 {
    print_line("No work items")
    return ()
  }
  let mut i = 0
  while i < limit {
    items[i] |> format_work_item_summary |> print_line
    i += 1
  }
}

///|
async fn handle_hub_issue_import(args : Array[String]) -> Unit raise Error {
  let mut repo : String? = None
  let mut state = "all"
  let mut limit = 100
  let mut provider = GitHubImportProvider::GhCli
  let mut input_path : String? = None
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    match arg {
      "-h" | "--help" | "help" => {
        print_hub_issue_usage()
        return ()
      }
      "--repo" if i + 1 < args.length() => {
        repo = Some(args[i + 1])
        i += 2
        continue
      }
      "--repo" =>
        raise @bitcore.GitError::InvalidObject(
          "hub issue import: --repo requires a value",
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
        raise @bitcore.GitError::InvalidObject(
          "hub issue import: --state requires a value",
        )
      _ if arg.has_prefix("--state=") => {
        state = String::unsafe_substring(arg, start=8, end=arg.length())
        i += 1
        continue
      }
      "--limit" if i + 1 < args.length() => {
        limit = @strconv.parse_int(args[i + 1]) catch {
          _ =>
            raise @bitcore.GitError::InvalidObject(
              "Invalid limit: \{args[i + 1]}",
            )
        }
        i += 2
        continue
      }
      "--limit" =>
        raise @bitcore.GitError::InvalidObject(
          "hub issue import: --limit requires a value",
        )
      "--provider" if i + 1 < args.length() => {
        provider = parse_github_import_provider_option(args[i + 1])
        i += 2
        continue
      }
      "--provider" =>
        raise @bitcore.GitError::InvalidObject(
          "hub issue import: --provider requires a value",
        )
      "--input" if i + 1 < args.length() => {
        input_path = Some(args[i + 1])
        i += 2
        continue
      }
      "--input" =>
        raise @bitcore.GitError::InvalidObject(
          "hub issue import: --input requires a value",
        )
      _ if arg.has_prefix("--limit=") => {
        let value = String::unsafe_substring(arg, start=8, end=arg.length())
        limit = @strconv.parse_int(value) catch {
          _ => raise @bitcore.GitError::InvalidObject("Invalid limit: \{value}")
        }
        i += 1
        continue
      }
      _ if arg.has_prefix("--provider=") => {
        let value = String::unsafe_substring(arg, start=11, end=arg.length())
        provider = parse_github_import_provider_option(value)
        i += 1
        continue
      }
      _ if arg.has_prefix("--input=") => {
        input_path = Some(
          String::unsafe_substring(arg, start=8, end=arg.length()),
        )
        i += 1
        continue
      }
      _ if arg.has_prefix("-") =>
        warn_unimplemented_arg("hub issue import", arg)
      _ => warn_unimplemented_arg("hub issue import", arg)
    }
    i += 1
  }
  let state_value = state.to_lower()
  match state_value {
    "open" | "closed" | "all" => ()
    _ => raise @bitcore.GitError::InvalidObject("Unknown issue state: \{state}")
  }
  if limit <= 0 {
    raise @bitcore.GitError::InvalidObject("Limit must be positive")
  }
  let root = get_work_root()
  let git_dir = root + "/.git"
  let fs = OsFs::new()
  let (stdout, _stderr) = match provider {
    GitHubImportProvider::GhCli => {
      let repo_name = resolve_github_repo(fs, git_dir, repo)
      gh_issue_list(repo_name, state_value, limit)
    }
    GitHubImportProvider::JsonFile =>
      read_import_json_from_file(fs, "hub issue import", input_path)
  }
  let issues = parse_gh_issues(stdout)
  if issues.length() == 0 {
    print_line("No issues to import")
    return ()
  }
  let (objects, refs, clock) = make_hub_stores(git_dir)
  let hub = init_hub_store(objects, refs)
  let stats = hub.import_issues(objects, refs, clock, issues)
  print_line(
    "Imported issues: created \{stats.created()}, updated \{stats.updated()}",
  )
}

///|
async fn handle_hub_issue_get(args : Array[String]) -> Unit raise Error {
  if args.length() == 0 {
    print_hub_issue_usage()
    return ()
  }
  let mut issue_id : String? = None
  for arg in args {
    if arg.has_prefix("-") {
      warn_unimplemented_arg("hub issue get", arg)
      continue
    }
    if issue_id is None {
      issue_id = Some(arg)
    } else {
      warn_unimplemented_arg("hub issue get", arg)
    }
  }
  guard issue_id is Some(id) else {
    raise @bitcore.GitError::InvalidObject("Issue id is required")
  }
  let root = get_work_root()
  let git_dir = root + "/.git"
  let (objects, refs, _clock) = make_hub_stores(git_dir)
  let hub = load_hub_store(objects, refs)
  let issue = hub.get_issue(objects, id)
  guard issue is Some(val) else {
    raise @bitcore.GitError::InvalidObject("Issue not found: \{id}")
  }
  print_line(val.serialize())
}

///|
async fn handle_hub_work_item_get(args : Array[String]) -> Unit raise Error {
  if args.length() == 0 {
    print_hub_work_item_usage()
    return ()
  }
  let first = args[0]
  if first == "-h" || first == "--help" || first == "help" {
    print_hub_work_item_usage()
    return ()
  }
  let mut work_item_id : String? = None
  for arg in args {
    if arg.has_prefix("-") {
      warn_unimplemented_arg("hub work-item get", arg)
      continue
    }
    if work_item_id is None {
      work_item_id = Some(arg)
    } else {
      warn_unimplemented_arg("hub work-item get", arg)
    }
  }
  guard work_item_id is Some(id) else {
    raise @bitcore.GitError::InvalidObject("Work item id is required")
  }
  let root = get_work_root()
  let git_dir = root + "/.git"
  let (objects, refs, _clock) = make_hub_stores(git_dir)
  let hub = load_hub_store(objects, refs)
  let work_item = hub.get_work_item(objects, id)
  guard work_item is Some(val) else {
    raise @bitcore.GitError::InvalidObject("Work item not found: \{id}")
  }
  print_line(format_work_item_detail(val))
}

///|
async fn handle_hub_issue_create(args : Array[String]) -> Unit raise Error {
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
      "-m" | "-b" | "--message" | "--body" if i + 1 < args.length() => {
        body = Some(args[i + 1])
        i += 2
        continue
      }
      "--label" | "-l" if i + 1 < args.length() => {
        labels.push(args[i + 1])
        i += 2
        continue
      }
      "--assignee" | "-a" if i + 1 < args.length() => {
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
        warn_unimplemented_arg("hub issue create", arg)
        i += 1
        continue
      }
      _ => {
        warn_unimplemented_arg("hub issue create", arg)
        i += 1
        continue
      }
    }
  }
  guard title is Some(t) else {
    raise @bitcore.GitError::InvalidObject("Missing --title")
  }
  let issue_body = body.unwrap_or("")
  let root = get_work_root()
  let git_dir = root + "/.git"
  let (objects, refs, clock) = make_hub_stores(git_dir)
  let hub = init_hub_store(objects, refs)
  let issue = hub.create_issue(
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
async fn handle_hub_issue_update(args : Array[String]) -> Unit raise Error {
  if args.length() == 0 {
    print_hub_issue_usage()
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
      "-m" | "-b" | "--message" | "--body" if i + 1 < args.length() => {
        body = Some(args[i + 1])
        i += 2
        continue
      }
      "--label" | "-l" if i + 1 < args.length() => {
        labels.push(args[i + 1])
        i += 2
        continue
      }
      "--assignee" | "-a" if i + 1 < args.length() => {
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
        warn_unimplemented_arg("hub issue update", arg)
        i += 1
        continue
      }
      _ => {
        if issue_id is None {
          issue_id = Some(arg)
        } else {
          warn_unimplemented_arg("hub issue update", arg)
        }
        i += 1
        continue
      }
    }
  }
  guard issue_id is Some(id) else {
    raise @bitcore.GitError::InvalidObject("Issue id is required")
  }
  let label_option = if labels.length() > 0 { Some(labels) } else { None }
  let assignee_option = if assignees.length() > 0 {
    Some(assignees)
  } else {
    None
  }
  let root = get_work_root()
  let git_dir = root + "/.git"
  let (objects, refs, clock) = make_hub_stores(git_dir)
  let hub = init_hub_store(objects, refs)
  let issue = hub.update_issue(
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
async fn handle_hub_issue_close(args : Array[String]) -> Unit raise Error {
  if args.length() == 0 {
    print_hub_issue_usage()
    return ()
  }
  let mut issue_id : String? = None
  for arg in args {
    if arg.has_prefix("-") {
      warn_unimplemented_arg("hub issue close", arg)
      continue
    }
    if issue_id is None {
      issue_id = Some(arg)
    } else {
      warn_unimplemented_arg("hub issue close", arg)
    }
  }
  guard issue_id is Some(id) else {
    raise @bitcore.GitError::InvalidObject("Issue id is required")
  }
  let root = get_work_root()
  let git_dir = root + "/.git"
  let (objects, refs, clock) = make_hub_stores(git_dir)
  let hub = init_hub_store(objects, refs)
  hub.close_issue(objects, refs, clock, id)
  print_line("Closed issue #\{id}")
}

///|
async fn handle_hub_issue_reopen(args : Array[String]) -> Unit raise Error {
  if args.length() == 0 {
    print_hub_issue_usage()
    return ()
  }
  let mut issue_id : String? = None
  for arg in args {
    if arg.has_prefix("-") {
      warn_unimplemented_arg("hub issue reopen", arg)
      continue
    }
    if issue_id is None {
      issue_id = Some(arg)
    } else {
      warn_unimplemented_arg("hub issue reopen", arg)
    }
  }
  guard issue_id is Some(id) else {
    raise @bitcore.GitError::InvalidObject("Issue id is required")
  }
  let root = get_work_root()
  let git_dir = root + "/.git"
  let (objects, refs, clock) = make_hub_stores(git_dir)
  let hub = init_hub_store(objects, refs)
  hub.reopen_issue(objects, refs, clock, id)
  print_line("Reopened issue #\{id}")
}

///|
async fn handle_hub_issue_comment(args : Array[String]) -> Unit raise Error {
  if args.length() == 0 {
    print_hub_issue_usage()
    return ()
  }
  let first = args[0]
  let subcmd = resolve_hub_comment_subcommand(first)
  let rest = if subcmd == first { collect_args(args, 1) } else { args }
  match subcmd {
    "add" => handle_hub_issue_comment_add(rest)
    "list" => handle_hub_issue_comment_list(rest)
    "help" | "-h" | "--help" => print_hub_issue_usage()
    _ => {
      eprint_line("bit hub issue comment: unknown subcommand '\{subcmd}'")
      print_hub_issue_usage()
      @sys.exit(1)
    }
  }
}

///|
async fn handle_hub_issue_comment_add(args : Array[String]) -> Unit raise Error {
  let mut issue_id : String? = None
  let mut body : String? = None
  let mut reply_to : String? = None
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    match arg {
      "-m" | "-b" | "--message" | "--body" if i + 1 < args.length() => {
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
        warn_unimplemented_arg("hub issue comment add", arg)
        i += 1
        continue
      }
      _ => {
        if issue_id is None {
          issue_id = Some(arg)
        } else {
          warn_unimplemented_arg("hub issue comment add", arg)
        }
        i += 1
        continue
      }
    }
  }
  guard issue_id is Some(id) else {
    raise @bitcore.GitError::InvalidObject("Issue id is required")
  }
  guard body is Some(msg) else {
    raise @bitcore.GitError::InvalidObject("Missing --body")
  }
  let root = get_work_root()
  let git_dir = root + "/.git"
  let (objects, refs, clock) = make_hub_stores(git_dir)
  let hub = init_hub_store(objects, refs)
  let comment = hub.add_issue_comment(
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
async fn handle_hub_issue_comment_list(
  args : Array[String],
) -> Unit raise Error {
  if args.length() == 0 {
    print_hub_issue_usage()
    return ()
  }
  let mut issue_id : String? = None
  for arg in args {
    if arg.has_prefix("-") {
      warn_unimplemented_arg("hub issue comment list", arg)
      continue
    }
    if issue_id is None {
      issue_id = Some(arg)
    } else {
      warn_unimplemented_arg("hub issue comment list", arg)
    }
  }
  guard issue_id is Some(id) else {
    raise @bitcore.GitError::InvalidObject("Issue id is required")
  }
  let root = get_work_root()
  let git_dir = root + "/.git"
  let (objects, refs, _clock) = make_hub_stores(git_dir)
  let hub = load_hub_store(objects, refs)
  let comments = hub.list_issue_comments(objects, id)
  if comments.length() == 0 {
    print_line("No comments")
    return ()
  }
  for comment in comments {
    print_line(comment.serialize())
  }
}

///|
async fn handle_hub_issue_link(args : Array[String]) -> Unit raise Error {
  if args.length() < 2 {
    print_hub_issue_usage()
    return ()
  }
  let issue_id = args[0]
  let pr_id = args[1]
  let root = get_work_root()
  let git_dir = root + "/.git"
  let (objects, refs, clock) = make_hub_stores(git_dir)
  let hub = init_hub_store(objects, refs)
  hub.link_pr_to_issue(objects, refs, clock, issue_id, pr_id)
  print_line("Linked PR #\{pr_id} to issue #\{issue_id}")
}

///|
async fn handle_hub_note(args : Array[String]) -> Unit raise Error {
  if args.length() == 0 {
    print_hub_note_usage()
    return ()
  }
  let subcmd = args[0]
  let rest = collect_args(args, 1)
  match subcmd {
    "add" => handle_hub_note_add(rest)
    "get" => handle_hub_note_get(rest)
    "list" => handle_hub_note_list(rest)
    "remove" => handle_hub_note_remove(rest)
    "help" | "-h" | "--help" => print_hub_note_usage()
    _ => {
      eprint_line("bit hub note: unknown subcommand '\{subcmd}'")
      print_hub_note_usage()
      @sys.exit(1)
    }
  }
}

///|
async fn handle_hub_note_add(args : Array[String]) -> Unit raise Error {
  if args.length() == 0 {
    print_hub_note_usage()
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
        warn_unimplemented_arg("hub note add", arg)
        i += 1
        continue
      }
      _ => {
        if commit_hex is None {
          commit_hex = Some(arg)
        } else {
          warn_unimplemented_arg("hub note add", arg)
        }
        i += 1
        continue
      }
    }
  }
  guard commit_hex is Some(hex) else {
    raise @bitcore.GitError::InvalidObject("Commit id is required")
  }
  let note_body = match body {
    Some(b) => b
    None => {
      let input = read_all_stdin()
      let text = decode_bytes(input)
      if text.length() == 0 {
        raise @bitcore.GitError::InvalidObject("Missing --body")
      }
      text
    }
  }
  let root = get_work_root()
  let git_dir = root + "/.git"
  let (objects, refs, clock) = make_hub_stores(git_dir)
  let hub = init_hub_store(objects, refs)
  let note = hub.add_note(
    objects,
    refs,
    clock,
    @bitcore.ObjectId::from_hex(hex),
    note_body,
    get_author_string(),
    get_commit_timestamp(),
    ns=note_ns(ns),
  )
  print_line(note.serialize())
}

///|
async fn handle_hub_note_get(args : Array[String]) -> Unit raise Error {
  if args.length() == 0 {
    print_hub_note_usage()
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
        warn_unimplemented_arg("hub note get", arg)
        i += 1
        continue
      }
      _ => {
        if commit_hex is None {
          commit_hex = Some(arg)
        } else {
          warn_unimplemented_arg("hub note get", arg)
        }
        i += 1
        continue
      }
    }
  }
  guard commit_hex is Some(hex) else {
    raise @bitcore.GitError::InvalidObject("Commit id is required")
  }
  let root = get_work_root()
  let git_dir = root + "/.git"
  let (objects, refs, _clock) = make_hub_stores(git_dir)
  let hub = load_hub_store(objects, refs)
  let note = hub.get_note(
    objects,
    refs,
    @bitcore.ObjectId::from_hex(hex),
    ns=note_ns(ns),
  )
  guard note is Some(val) else {
    raise @bitcore.GitError::InvalidObject("Note not found for \{hex}")
  }
  print_line(val.serialize())
}

///|
async fn handle_hub_note_list(args : Array[String]) -> Unit raise Error {
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
        warn_unimplemented_arg("hub note list", arg)
        i += 1
        continue
      }
      _ => {
        warn_unimplemented_arg("hub note list", arg)
        i += 1
        continue
      }
    }
  }
  let root = get_work_root()
  let git_dir = root + "/.git"
  let (objects, refs, _clock) = make_hub_stores(git_dir)
  let hub = load_hub_store(objects, refs)
  let notes = hub.list_notes(objects, refs, ns=note_ns(ns))
  if notes.length() == 0 {
    print_line("No notes")
    return ()
  }
  for note in notes {
    print_line(note.serialize())
  }
}

///|
async fn handle_hub_note_remove(args : Array[String]) -> Unit raise Error {
  if args.length() == 0 {
    print_hub_note_usage()
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
        warn_unimplemented_arg("hub note remove", arg)
        i += 1
        continue
      }
      _ => {
        if commit_hex is None {
          commit_hex = Some(arg)
        } else {
          warn_unimplemented_arg("hub note remove", arg)
        }
        i += 1
        continue
      }
    }
  }
  guard commit_hex is Some(hex) else {
    raise @bitcore.GitError::InvalidObject("Commit id is required")
  }
  let root = get_work_root()
  let git_dir = root + "/.git"
  let (objects, refs, clock) = make_hub_stores(git_dir)
  let hub = init_hub_store(objects, refs)
  hub.remove_note(
    objects,
    refs,
    clock,
    @bitcore.ObjectId::from_hex(hex),
    ns=note_ns(ns),
  )
  print_line("Removed note for \{hex}")
}

///|
async fn handle_hub_sync(args : Array[String]) -> Unit raise Error {
  if args.length() == 0 {
    print_hub_sync_usage()
    return ()
  }
  let subcmd = args[0]
  let rest = collect_args(args, 1)
  match subcmd {
    "push" => handle_hub_sync_push(rest)
    "fetch" => handle_hub_sync_fetch(rest)
    "help" | "-h" | "--help" => print_hub_sync_usage()
    _ => {
      eprint_line("bit hub sync: unknown subcommand '\{subcmd}'")
      print_hub_sync_usage()
      @sys.exit(1)
    }
  }
}

///|
struct HubSyncRuntimeOptions {
  remote_url : String?
  auth_token : String?
  signing_key : String?
  require_signed : Bool?
  conflict_policy : @hub.RecordMergePolicy?
}

///|
fn parse_hub_conflict_policy(
  value : String,
) -> @hub.RecordMergePolicy raise @bitcore.GitError {
  match @hub.parse_record_merge_policy(value) {
    Some(policy) => policy
    None =>
      raise @bitcore.GitError::InvalidObject(
        "Unknown hub conflict policy: \{value}",
      )
  }
}

///|
fn parse_hub_sync_runtime_options(
  args : Array[String],
  default_remote_url? : String? = None,
) -> HubSyncRuntimeOptions raise @bitcore.GitError {
  let mut remote_url = default_remote_url
  let mut auth_token : String? = None
  let mut signing_key : String? = None
  let mut require_signed : Bool? = None
  let mut conflict_policy : @hub.RecordMergePolicy? = None
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    match arg {
      "--auth-token" if i + 1 < args.length() => {
        auth_token = Some(args[i + 1])
        i += 2
        continue
      }
      "--auth-token" =>
        raise @bitcore.GitError::InvalidObject(
          "hub sync: --auth-token requires a value",
        )
      "--signing-key" | "--sign-key" if i + 1 < args.length() => {
        signing_key = Some(args[i + 1])
        i += 2
        continue
      }
      "--signing-key" | "--sign-key" =>
        raise @bitcore.GitError::InvalidObject(
          "hub sync: --signing-key requires a value",
        )
      "--require-signed" => {
        require_signed = Some(true)
        i += 1
        continue
      }
      "--allow-unsigned" => {
        require_signed = Some(false)
        i += 1
        continue
      }
      "--conflict-policy" if i + 1 < args.length() => {
        conflict_policy = Some(parse_hub_conflict_policy(args[i + 1]))
        i += 2
        continue
      }
      "--conflict-policy" =>
        raise @bitcore.GitError::InvalidObject(
          "hub sync: --conflict-policy requires a value",
        )
      _ if arg.has_prefix("--auth-token=") => {
        auth_token = Some(
          String::unsafe_substring(arg, start=13, end=arg.length()),
        )
        i += 1
        continue
      }
      _ if arg.has_prefix("--signing-key=") => {
        signing_key = Some(
          String::unsafe_substring(arg, start=14, end=arg.length()),
        )
        i += 1
        continue
      }
      _ if arg.has_prefix("--sign-key=") => {
        signing_key = Some(
          String::unsafe_substring(arg, start=11, end=arg.length()),
        )
        i += 1
        continue
      }
      _ if arg.has_prefix("--conflict-policy=") => {
        let value = String::unsafe_substring(arg, start=18, end=arg.length())
        conflict_policy = Some(parse_hub_conflict_policy(value))
        i += 1
        continue
      }
      _ if arg.has_prefix("-") =>
        raise @bitcore.GitError::InvalidObject(
          "Unknown hub sync option: \{arg}",
        )
      _ => {
        remote_url = Some(arg)
        i += 1
        continue
      }
    }
  }
  { remote_url, auth_token, signing_key, require_signed, conflict_policy }
}

///|
async fn handle_hub_sync_push(args : Array[String]) -> Unit raise Error {
  let root = get_work_root()
  let git_dir = root + "/.git"
  let fs = OsFs::new()
  let options = parse_hub_sync_runtime_options(
    args,
    default_remote_url=get_effective_remote_url(fs, git_dir),
  )
  guard options.remote_url is Some(url) else {
    raise @bitcore.GitError::InvalidObject("No remote configured")
  }
  let (objects, refs, _clock) = make_hub_stores(git_dir)
  let hub = load_hub_store(objects, refs)
  let result = @hub_native.hub_push(
    hub,
    fs,
    git_dir,
    url,
    signing_key=options.signing_key,
    require_signed=options.require_signed,
    auth_token=options.auth_token,
    conflict_policy=options.conflict_policy,
  )
  if result.success() {
    print_line(result.message())
  } else {
    eprint_line(result.message())
    @sys.exit(1)
  }
}

///|
fn load_hub_record_store(
  objects : &@bitlib.ObjectStore,
  refs : &@bitlib.RefStore,
) -> @hub.HubStore raise @bitcore.GitError {
  @hub.HubStore::load(
    objects,
    refs,
    signing_key=get_hub_signing_key(),
    require_signed=get_hub_require_signed(),
  )
}

///|
fn select_notify_records(
  records : Array[@hub.HubRecord],
) -> Map[String, @hub.HubRecord] {
  let selected : Map[String, @hub.HubRecord] = {}
  for record in records {
    if @hub.record_notify_topic(record) is Some(_) {
      selected[record.key] = record
    }
  }
  selected
}

///|
fn collect_notify_records_from_store(
  store : @hub.HubStore,
  objects : &@bitlib.ObjectStore,
) -> Map[String, @hub.HubRecord] {
  let records = store.list_records(objects, "hub/")
  select_notify_records(records)
}

///|
fn collect_changed_notify_records(
  before : Map[String, @hub.HubRecord],
  after : Map[String, @hub.HubRecord],
) -> Array[@hub.HubRecord] {
  let changed : Array[@hub.HubRecord] = []
  for key, record in after {
    match before.get(key) {
      Some(prev) =>
        if prev.serialize() != record.serialize() {
          changed.push(record)
        }
      None => changed.push(record)
    }
  }
  changed.sort_by(fn(a, b) {
    if a.key < b.key {
      -1
    } else if a.key > b.key {
      1
    } else {
      0
    }
  })
  changed
}

///|
fn format_hub_notify_message(topic : String, record : @hub.HubRecord) -> String {
  match topic {
    "hub.pr.proposal" => {
      let proposal = @hub.parse_legacy_pull_request(record.payload) catch {
        _ => return "[hub.notify] hub.pr.proposal key=\{record.key}"
      }
      "[hub.notify] hub.pr.proposal #\{proposal.id()} [\{proposal.state().to_string()}] \{proposal.title()}"
    }
    _ => "[hub.notify] \{topic} key=\{record.key}"
  }
}

///|
async fn run_hub_notify_hook(
  fs : OsFs,
  git_dir : String,
  topic : String,
  record : @hub.HubRecord,
) -> Int {
  let hook_path = git_dir + "/hooks/hub-notify"
  if not(fs.is_file(hook_path)) {
    return -1
  }
  @process.run(
    hook_path,
    [topic, record.kind, record.key, record.node],
    inherit_env=true,
    cwd=os_parent_path(git_dir),
  ) catch {
    _ => 1
  }
}

///|
async fn dispatch_hub_notify_events(
  fs : OsFs,
  git_dir : String,
  changed : Array[@hub.HubRecord],
) -> Unit {
  for record in changed {
    match @hub.record_notify_topic(record) {
      Some(topic) => {
        let code = run_hub_notify_hook(fs, git_dir, topic, record)
        if code > 0 {
          eprint_line("bit hub notify: hook failed (\{code}) for \{topic}")
        }
        if code != 0 {
          eprint_line(format_hub_notify_message(topic, record))
        }
      }
      None => ()
    }
  }
}

///|
async fn handle_hub_sync_fetch(args : Array[String]) -> Unit raise Error {
  let root = get_work_root()
  let git_dir = root + "/.git"
  let fs = OsFs::new()
  let options = parse_hub_sync_runtime_options(
    args,
    default_remote_url=get_effective_remote_url(fs, git_dir),
  )
  guard options.remote_url is Some(url) else {
    raise @bitcore.GitError::InvalidObject("No remote configured")
  }
  let (objects, refs, _clock) = make_hub_stores(git_dir)
  let before_store = load_hub_record_store(objects, refs)
  let before_notify = collect_notify_records_from_store(before_store, objects)
  let hub = load_hub_store(objects, refs)
  let result = @hub_native.hub_fetch(
    hub,
    fs,
    fs,
    git_dir,
    url,
    signing_key=options.signing_key,
    require_signed=options.require_signed,
    auth_token=options.auth_token,
    conflict_policy=options.conflict_policy,
  )
  if result.success() {
    let after_store = load_hub_record_store(objects, refs)
    let after_notify = collect_notify_records_from_store(after_store, objects)
    let changed_notify = collect_changed_notify_records(
      before_notify, after_notify,
    )
    dispatch_hub_notify_events(fs, git_dir, changed_notify)
    print_line(result.message())
  } else {
    eprint_line(result.message())
    @sys.exit(1)
  }
}

///|
struct HubDumpOptions {
  prefix : String
  raw : Bool
  include_deleted : Bool
}

///|
fn parse_hub_dump_options(
  args : Array[String],
) -> HubDumpOptions raise @bitcore.GitError {
  let mut prefix = "hub/"
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
        raise @bitcore.GitError::InvalidObject(
          "hub dump: --prefix requires a value",
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
        raise @bitcore.GitError::InvalidObject(
          "Unknown hub dump option: \{arg}",
        )
      _ => {
        if used_positional_prefix {
          raise @bitcore.GitError::InvalidObject(
            "hub dump: unexpected positional argument: \{arg}",
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
fn format_hub_record_summary(record : @hub.HubRecord) -> String {
  let deleted_text = if record.deleted { "1" } else { "0" }
  "kind=\{record.kind} key=\{record.key} node=\{record.node} ts=\{record.timestamp} deleted=\{deleted_text}"
}

///|
async fn handle_hub_dump(args : Array[String]) -> Unit raise Error {
  if args.length() > 0 {
    let first = args[0]
    if first == "help" || first == "-h" || first == "--help" {
      print_hub_dump_usage()
      return ()
    }
  }
  let options = parse_hub_dump_options(args)
  let root = get_work_root()
  let git_dir = root + "/.git"
  let (objects, refs, _clock) = make_hub_stores(git_dir)
  let store = @hub.HubStore::load(
    objects,
    refs,
    signing_key=get_hub_signing_key(),
    require_signed=get_hub_require_signed(),
  )
  let records = store.list_records(
    objects,
    options.prefix,
    include_deleted=options.include_deleted,
  )
  if records.length() == 0 {
    print_line("No hub records for prefix: \{options.prefix}")
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
      print_line(format_hub_record_summary(rec))
      print_line(rec.serialize())
    } else {
      print_line(format_hub_record_summary(rec))
    }
  }
}

///|
enum GitHubImportProvider {
  GhCli
  JsonFile
}

///|
fn parse_github_import_provider(value : String) -> GitHubImportProvider? {
  match value.to_lower() {
    "gh" | "gh-cli" => Some(GitHubImportProvider::GhCli)
    "json-file" | "file" => Some(GitHubImportProvider::JsonFile)
    _ => None
  }
}

///|
fn parse_github_import_provider_option(
  value : String,
) -> GitHubImportProvider raise @bitcore.GitError {
  match parse_github_import_provider(value) {
    Some(provider) => provider
    None =>
      raise @bitcore.GitError::InvalidObject(
        "Unknown GitHub import provider: \{value}",
      )
  }
}

///|
fn read_import_json_from_file(
  fs : OsFs,
  context : String,
  input_path : String?,
) -> (String, String) raise @bitcore.GitError {
  guard input_path is Some(path) else {
    raise @bitcore.GitError::InvalidObject(
      "\{context}: --input requires a file path when --provider=json-file",
    )
  }
  let bytes = fs.read_file(path) catch {
    err =>
      raise @bitcore.GitError::IoError(
        "\{context}: failed to read --input file '\{path}': \{err}",
      )
  }
  (decode_bytes(bytes), "")
}

///|
fn resolve_github_repo(
  fs : OsFs,
  git_dir : String,
  repo : String?,
) -> String raise @bitcore.GitError {
  match repo {
    Some(name) => name
    None => {
      let remote_url = get_effective_remote_url(fs, git_dir)
      guard remote_url is Some(url) else {
        raise @bitcore.GitError::InvalidObject(
          "No remote configured; use --repo",
        )
      }
      match @hq.parse_repo_url(url) {
        Some(parsed) => {
          let host = parsed.host_name()
          if host != "github.com" {
            raise @bitcore.GitError::InvalidObject(
              "Only github.com is supported for gh import",
            )
          }
          parsed.full_name()
        }
        None =>
          raise @bitcore.GitError::InvalidObject(
            "Cannot parse remote URL: \{url}",
          )
      }
    }
  }
}

///|
async fn gh_pr_list(
  repo : String,
  state : String,
  limit : Int,
) -> (String, String) raise @bitcore.GitError {
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
) -> (String, String) raise @bitcore.GitError {
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
) -> (String, String) raise @bitcore.GitError {
  let (code, stdout, stderr) = @process.collect_output(
    "gh",
    args,
    inherit_env=true,
  ) catch {
    err => raise @bitcore.GitError::IoError("gh failed: \{err}")
  }
  let out = stdout.text() catch {
    err if @async.is_cancellation_error(err) =>
      raise @bitcore.GitError::IoError(err.to_string())
    _ => ""
  }
  let err_text = stderr.text() catch {
    err if @async.is_cancellation_error(err) =>
      raise @bitcore.GitError::IoError(err.to_string())
    _ => ""
  }
  if code != 0 {
    let message = trim_string(err_text)
    raise @bitcore.GitError::InvalidObject("gh failed (\{code}): \{message}")
  }
  (out, err_text)
}

///|
fn parse_json_array(text : String) -> Array[Json] raise @bitcore.GitError {
  let parsed = @json.parse(text) catch {
    err =>
      raise @bitcore.GitError::InvalidObject(
        "Invalid JSON from gh: \{err.to_string()}",
      )
  }
  match parsed {
    Json::Array(items) => items
    _ => raise @bitcore.GitError::InvalidObject("Expected JSON array from gh")
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
) -> Array[@hub.PullRequest] raise @bitcore.GitError {
  let items = parse_json_array(text)
  let out : Array[@hub.PullRequest] = []
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
          raise @bitcore.GitError::InvalidObject(
            "Missing branch name for PR \{id}",
          )
        }
        let source_commit = @bitcore.ObjectId::from_hex(source_hex) catch {
          _ =>
            raise @bitcore.GitError::InvalidObject(
              "Invalid source commit for PR \{id}",
            )
        }
        let target_commit = @bitcore.ObjectId::from_hex(target_hex) catch {
          _ =>
            raise @bitcore.GitError::InvalidObject(
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
          None => @hub.PrState::Open
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
        let pr = @hub.PullRequest::new(
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
fn parse_gh_issues(text : String) -> Array[@hub.Issue] raise @bitcore.GitError {
  let items = parse_json_array(text)
  let out : Array[@hub.Issue] = []
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
          None => @hub.IssueState::Open
        }
        let issue = @hub.Issue::new(
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
fn parse_head_branch_name(head_content : String) -> String? {
  let text = trim_string(head_content)
  if text.has_prefix("ref: refs/heads/") {
    Some(String::unsafe_substring(text, start=16, end=text.length()))
  } else {
    None
  }
}

///|
fn detect_current_branch_name(git_dir : String) -> String? {
  let fs = OsFs::new()
  let head_bytes = fs.read_file(git_dir + "/HEAD") catch { _ => return None }
  parse_head_branch_name(decode_bytes(head_bytes))
}

///|
fn pr_matches_branch(pr : @hub.PullRequest, branch : String) -> Bool {
  let source_branch = pr.source_branch()
  let branch_ref = "refs/heads/" + branch
  if source_branch == branch || source_branch == branch_ref {
    return true
  }
  match pr.source_ref() {
    Some(source_ref) => source_ref == branch || source_ref == branch_ref
    None => false
  }
}

///|
fn parse_pr_state_flag(value : String) -> @hub.PrState? {
  match parse_work_item_state_flag(value) {
    Some(work_item_state) => Some(work_item_state.to_pr_state())
    None => None
  }
}

///|
fn parse_issue_state_flag(value : String) -> @hub.IssueState? {
  match parse_work_item_state_flag(value) {
    Some(work_item_state) => work_item_state.to_issue_state()
    None => None
  }
}

///|
fn parse_work_item_state_flag(value : String) -> @hub.WorkItemState? {
  match value {
    "--open" => Some(@hub.WorkItemState::Open)
    "--closed" => Some(@hub.WorkItemState::Closed)
    "--merged" => Some(@hub.WorkItemState::Merged)
    _ => None
  }
}

///|
fn parse_work_item_kind_flag(value : String) -> @hub.WorkItemKind? {
  match value {
    "--issue" => Some(@hub.WorkItemKind::Issue)
    "--pr" | "--pull-request" => Some(@hub.WorkItemKind::PullRequest)
    _ => None
  }
}

///|
fn normalize_hub_pr_subcommand(subcmd : String) -> String {
  match subcmd {
    "view" => "get"
    "edit" => "update"
    "proposal" => "proposals"
    _ => subcmd
  }
}

///|
fn normalize_hub_issue_subcommand(subcmd : String) -> String {
  match subcmd {
    "view" => "get"
    "edit" => "update"
    _ => subcmd
  }
}

///|
fn normalize_hub_work_item_subcommand(subcmd : String) -> String {
  match subcmd {
    "view" => "get"
    _ => subcmd
  }
}

///|
fn resolve_hub_comment_subcommand(subcmd : String) -> String {
  match subcmd {
    "add" | "list" | "help" | "-h" | "--help" => subcmd
    _ => "add"
  }
}

///|
fn resolve_hub_review_subcommand(subcmd : String) -> String {
  match subcmd {
    "submit" | "list" | "help" | "-h" | "--help" => subcmd
    _ => "submit"
  }
}

///|
fn parse_review_verdict_flag(value : String) -> @hub.ReviewVerdict? {
  match value {
    "--approve" | "--approved" => Some(@hub.ReviewVerdict::Approved)
    "--comment" => Some(@hub.ReviewVerdict::Comment)
    "--request-changes" => Some(@hub.ReviewVerdict::RequestChanges)
    _ => None
  }
}

///|
fn parse_merge_strategy_flag(value : String) -> @hub.PrMergeStrategy? {
  match value {
    "--merge" => Some(@hub.PrMergeStrategy::Merge)
    "--squash" => Some(@hub.PrMergeStrategy::Squash)
    "--ff" | "--fast-forward" => Some(@hub.PrMergeStrategy::FastForward)
    _ => None
  }
}

///|
fn parse_pr_state(value : String) -> @hub.PrState? {
  match parse_work_item_state(value) {
    Some(work_item_state) => Some(work_item_state.to_pr_state())
    None => None
  }
}

///|
fn parse_issue_state(value : String) -> @hub.IssueState? {
  match parse_work_item_state(value) {
    Some(work_item_state) => work_item_state.to_issue_state()
    None => None
  }
}

///|
fn parse_work_item_state(value : String) -> @hub.WorkItemState? {
  match value {
    "open" => Some(@hub.WorkItemState::Open)
    "closed" => Some(@hub.WorkItemState::Closed)
    "merged" => Some(@hub.WorkItemState::Merged)
    _ => None
  }
}

///|
fn parse_work_item_kind(value : String) -> @hub.WorkItemKind? {
  match value {
    "issue" => Some(@hub.WorkItemKind::Issue)
    "pr" | "pull-request" | "pullrequest" =>
      Some(@hub.WorkItemKind::PullRequest)
    _ => None
  }
}

///|
fn parse_review_verdict(value : String) -> @hub.ReviewVerdict? {
  match value {
    "approved" | "approve" => Some(@hub.ReviewVerdict::Approved)
    "comment" => Some(@hub.ReviewVerdict::Comment)
    "request-changes" | "request_changes" =>
      Some(@hub.ReviewVerdict::RequestChanges)
    _ => None
  }
}

///|
fn parse_merge_strategy(value : String) -> @hub.PrMergeStrategy? {
  match value {
    "merge" => Some(@hub.PrMergeStrategy::Merge)
    "squash" => Some(@hub.PrMergeStrategy::Squash)
    "ff" | "fast-forward" | "fastforward" =>
      Some(@hub.PrMergeStrategy::FastForward)
    _ => None
  }
}

///|
fn format_pr_summary(pr : @hub.PullRequest) -> String {
  let id = pr.id()
  let title = pr.title()
  let state = pr.state().to_string()
  "#\{id} [\{state}] \{title}"
}

///|
fn format_issue_summary(issue : @hub.Issue) -> String {
  let id = issue.id()
  let title = issue.title()
  let state = issue.state().to_string()
  "#\{id} [\{state}] \{title}"
}

///|
fn format_work_item_summary(item : @hub.WorkItem) -> String {
  let id = item.id()
  let title = item.title()
  let kind = item.kind().to_string()
  let state = item.state().to_string()
  "#\{id} [\{kind}/\{state}] \{title}"
}

///|
fn format_work_item_detail(item : @hub.WorkItem) -> String {
  let sb = StringBuilder::new()
  sb.write_string("id ")
  sb.write_string(item.id())
  sb.write_char('\n')
  sb.write_string("kind ")
  sb.write_string(item.kind().to_string())
  sb.write_char('\n')
  sb.write_string("state ")
  sb.write_string(item.state().to_string())
  sb.write_char('\n')
  sb.write_string("author ")
  sb.write_string(item.author())
  sb.write_char('\n')
  sb.write_string("created-at ")
  sb.write_string(item.created_at().to_string())
  sb.write_char('\n')
  sb.write_string("updated-at ")
  sb.write_string(item.updated_at().to_string())
  sb.write_char('\n')
  for label in item.labels() {
    sb.write_string("label ")
    sb.write_string(label)
    sb.write_char('\n')
  }
  for assignee in item.assignees() {
    sb.write_string("assignee ")
    sb.write_string(assignee)
    sb.write_char('\n')
  }
  for linked_pr in item.linked_prs() {
    sb.write_string("linked-pr ")
    sb.write_string(linked_pr)
    sb.write_char('\n')
  }
  match item.patch() {
    None => ()
    Some(patch) => {
      sb.write_string("source-branch ")
      sb.write_string(patch.source_branch())
      sb.write_char('\n')
      match patch.source_repo() {
        Some(source_repo) => {
          sb.write_string("source-repo ")
          sb.write_string(source_repo)
          sb.write_char('\n')
        }
        None => ()
      }
      match patch.source_ref() {
        Some(source_ref) => {
          sb.write_string("source-ref ")
          sb.write_string(source_ref)
          sb.write_char('\n')
        }
        None => ()
      }
      sb.write_string("source-commit ")
      sb.write_string(patch.source_commit().to_hex())
      sb.write_char('\n')
      sb.write_string("target-branch ")
      sb.write_string(patch.target_branch())
      sb.write_char('\n')
      sb.write_string("target-commit ")
      sb.write_string(patch.target_commit().to_hex())
      sb.write_char('\n')
      for closes_issue in patch.closes_issues() {
        sb.write_string("closes-issue ")
        sb.write_string(closes_issue)
        sb.write_char('\n')
      }
      match patch.merge_commit() {
        Some(merge_commit) => {
          sb.write_string("merge-commit ")
          sb.write_string(merge_commit.to_hex())
          sb.write_char('\n')
        }
        None => ()
      }
    }
  }
  sb.write_string("title ")
  sb.write_string(item.title())
  sb.write_char('\n')
  sb.write_char('\n')
  sb.write_string(item.body())
  sb.to_string()
}

///|
fn note_ns(ns : String?) -> String {
  ns.unwrap_or("commits")
}

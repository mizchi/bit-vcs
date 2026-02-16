///| Hub - Git-native hub system (Pull Requests, Issues)

///|
/// Hub manages Pull Requests and Issues stored in git notes
pub struct Hub {
  mut store : HubStore
}

///|
/// Load an existing Hub from git notes
pub fn Hub::load(
  objects : &@lib.ObjectStore,
  refs : &@lib.RefStore,
  node_id? : String = "local",
  signing_key? : String? = None,
  require_signed? : Bool = false,
) -> Hub raise @git.GitError {
  let store = HubStore::load(
    objects,
    refs,
    node_id~,
    signing_key~,
    require_signed~,
  )
  { store, }
}

///|
/// Reload store from current object/ref state
pub fn Hub::reload_store(
  self : Hub,
  objects : &@lib.ObjectStore,
  refs : &@lib.RefStore,
) -> Unit raise @git.GitError {
  self.store = HubStore::load(
    objects,
    refs,
    node_id=self.store.node_id(),
    signing_key=self.store.signing_key(),
    require_signed=self.store.require_signed(),
  )
}

///|
/// Initialize a new Hub
pub fn Hub::init(
  objects : &@lib.ObjectStore,
  refs : &@lib.RefStore,
  node_id? : String = "local",
  signing_key? : String? = None,
  require_signed? : Bool = false,
) -> Hub raise @git.GitError {
  Hub::load(objects, refs, node_id~, signing_key~, require_signed~)
}

///|
/// Create a new Pull Request
pub fn Hub::create_pr(
  self : Hub,
  objects : &@lib.ObjectStore,
  refs : &@lib.RefStore,
  clock : &@lib.Clock,
  title : String,
  body : String,
  source_branch : String,
  target_branch : String,
  author : String,
  source_repo? : String? = None,
  source_ref? : String? = None,
) -> PullRequest raise @git.GitError {
  let timestamp = clock.now()
  // Resolve source and target commits
  let source_commit = refs.resolve(source_branch) catch {
    _ =>
      raise @git.GitError::InvalidObject(
        "Cannot resolve source branch: \{source_branch}",
      )
  }
  guard source_commit is Some(src_id) else {
    raise @git.GitError::InvalidObject(
      "Source branch not found: \{source_branch}",
    )
  }
  let target_commit = refs.resolve(target_branch) catch {
    _ =>
      raise @git.GitError::InvalidObject(
        "Cannot resolve target branch: \{target_branch}",
      )
  }
  guard target_commit is Some(tgt_id) else {
    raise @git.GitError::InvalidObject(
      "Target branch not found: \{target_branch}",
    )
  }
  // Generate PR ID (stable, content-derived)
  let pr_id = generate_entity_id(
    "pr",
    author,
    timestamp,
    source_branch + "\n" + target_branch + "\n" + title + "\n" + body,
  )
  // Create PullRequest object
  let pr = PullRequest::new(
    pr_id,
    title,
    body,
    source_branch,
    src_id,
    target_branch,
    tgt_id,
    author,
    timestamp,
    timestamp,
    PrState::Open,
    [],
    source_repo~,
    source_ref~,
  )
  ignore(
    self.store.put_record(
      objects,
      refs,
      clock,
      work_item_meta_key(pr_id),
      canonical_work_item_record_kind(),
      pr.to_work_item().serialize(),
      author,
    ),
  )
  pr
}

///|
/// Get a Pull Request by ID
pub fn Hub::get_pr(
  self : Hub,
  objects : &@lib.ObjectStore,
  pr_id : String,
) -> PullRequest? {
  let work_item = self.get_work_item(objects, pr_id)
  match work_item {
    None => None
    Some(item) => item.to_pull_request()
  }
}

///|
/// List Pull Requests, optionally filtered by state
pub fn Hub::list_prs(
  self : Hub,
  objects : &@lib.ObjectStore,
  state? : PrState? = None,
) -> Array[PullRequest] {
  let item_state = match state {
    None => None
    Some(s) => Some(s.to_work_item_state())
  }
  let items = self.list_work_items(
    objects,
    state=item_state,
    kind=Some(WorkItemKind::PullRequest),
  )
  let result : Array[PullRequest] = []
  for item in items {
    match item.to_pull_request() {
      Some(pr) => result.push(pr)
      None => ()
    }
  }
  result
}

///|
/// Update a Pull Request (title, body, labels)
pub fn Hub::update_pr(
  self : Hub,
  objects : &@lib.ObjectStore,
  refs : &@lib.RefStore,
  clock : &@lib.Clock,
  pr_id : String,
  title? : String? = None,
  body? : String? = None,
  labels? : Array[String]? = None,
) -> PullRequest raise @git.GitError {
  let pr = self.get_pr(objects, pr_id)
  guard pr is Some(existing) else {
    raise @git.GitError::InvalidObject("PR not found: \{pr_id}")
  }
  let new_title = match title {
    Some(t) => t
    None => existing.title
  }
  let new_body = match body {
    Some(b) => b
    None => existing.body
  }
  let new_labels = match labels {
    Some(l) => l
    None => existing.labels
  }
  let updated = PullRequest::new(
    existing.id,
    new_title,
    new_body,
    existing.source_branch,
    existing.source_commit,
    existing.target_branch,
    existing.target_commit,
    existing.author,
    existing.created_at,
    clock.now(),
    existing.state,
    new_labels,
    source_repo=existing.source_repo,
    source_ref=existing.source_ref,
  )
  ignore(
    self.store.put_record(
      objects,
      refs,
      clock,
      work_item_meta_key(pr_id),
      canonical_work_item_record_kind(),
      updated.to_work_item().serialize(),
      existing.author,
    ),
  )
  updated
}

///|
/// Close a Pull Request
pub fn Hub::close_pr(
  self : Hub,
  objects : &@lib.ObjectStore,
  refs : &@lib.RefStore,
  clock : &@lib.Clock,
  pr_id : String,
) -> Unit raise @git.GitError {
  let pr = self.get_pr(objects, pr_id)
  guard pr is Some(existing) else {
    raise @git.GitError::InvalidObject("PR not found: \{pr_id}")
  }
  if existing.state != PrState::Open {
    raise @git.GitError::InvalidObject("PR is not open: \{pr_id}")
  }
  // Create updated PR with Closed state
  let updated = PullRequest::new(
    existing.id,
    existing.title,
    existing.body,
    existing.source_branch,
    existing.source_commit,
    existing.target_branch,
    existing.target_commit,
    existing.author,
    existing.created_at,
    clock.now(),
    PrState::Closed,
    existing.labels,
    source_repo=existing.source_repo,
    source_ref=existing.source_ref,
  )
  ignore(
    self.store.put_record(
      objects,
      refs,
      clock,
      work_item_meta_key(pr_id),
      canonical_work_item_record_kind(),
      updated.to_work_item().serialize(),
      existing.author,
    ),
  )
}

///|
/// Reopen a closed Pull Request
pub fn Hub::reopen_pr(
  self : Hub,
  objects : &@lib.ObjectStore,
  refs : &@lib.RefStore,
  clock : &@lib.Clock,
  pr_id : String,
) -> Unit raise @git.GitError {
  let pr = self.get_pr(objects, pr_id)
  guard pr is Some(existing) else {
    raise @git.GitError::InvalidObject("PR not found: \{pr_id}")
  }
  if existing.state != PrState::Closed {
    raise @git.GitError::InvalidObject("PR is not closed: \{pr_id}")
  }
  let updated = PullRequest::new(
    existing.id,
    existing.title,
    existing.body,
    existing.source_branch,
    existing.source_commit,
    existing.target_branch,
    existing.target_commit,
    existing.author,
    existing.created_at,
    clock.now(),
    PrState::Open,
    existing.labels,
    source_repo=existing.source_repo,
    source_ref=existing.source_ref,
  )
  ignore(
    self.store.put_record(
      objects,
      refs,
      clock,
      work_item_meta_key(pr_id),
      canonical_work_item_record_kind(),
      updated.to_work_item().serialize(),
      existing.author,
    ),
  )
}

///|
fn generate_entity_id(
  kind : String,
  author : String,
  timestamp : Int64,
  seed : String,
) -> String {
  let base = kind + "\n" + author + "\n" + timestamp.to_string() + "\n" + seed
  let (id, _compressed) = @git.create_blob_string(base)
  short_hex_id(id.to_hex(), 8)
}

///|
fn short_hex_id(hex : String, n : Int) -> String {
  if hex.length() <= n {
    hex
  } else {
    String::unsafe_substring(hex, start=0, end=n)
  }
}

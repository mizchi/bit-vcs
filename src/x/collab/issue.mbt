///| Issue operations

///|
/// Create a new Issue
pub fn Collab::create_issue(
  self : Collab,
  fs : &@git.FileSystem,
  backing_fs : &@git.RepoFileSystem,
  title : String,
  body : String,
  author : String,
  timestamp : Int64,
  labels? : Array[String] = [],
  assignees? : Array[String] = [],
) -> Issue raise @git.GitError {
  // Load issue counter
  let issue_id = load_issue_counter(backing_fs, self.git_dir).to_string()
  let next_issue_id = load_issue_counter(backing_fs, self.git_dir) + 1
  // Create Issue object
  let issue = Issue::new(
    issue_id,
    title,
    body,
    author,
    timestamp,
    timestamp,
    IssueState::Open,
    labels~,
    assignees~,
  )
  let event = CollabEvent::new(
    "issue",
    "issue/" + issue_id,
    timestamp,
    issue.serialize(),
  )
  append_event(
    fs,
    backing_fs,
    self.git_dir,
    event,
    issue_counter=Some(next_issue_id),
  )
  issue
}

///|
/// Get an Issue by ID
pub fn Collab::get_issue(
  self : Collab,
  backing_fs : &@git.RepoFileSystem,
  issue_id : String,
) -> Issue? raise @git.GitError {
  let events = load_events(backing_fs, self.git_dir)
  let mut latest_ts : Int64 = -1
  let mut latest : Issue? = None
  for event in events {
    if event.kind() != "issue" {
      continue
    }
    let issue = parse_issue(event.payload()) catch { _ => continue }
    if issue.id != issue_id {
      continue
    }
    let ts = event.timestamp()
    if ts >= latest_ts {
      latest_ts = ts
      latest = Some(issue)
    }
  }
  latest
}

///|
/// List Issues, optionally filtered by state
pub fn Collab::list_issues(
  self : Collab,
  backing_fs : &@git.RepoFileSystem,
  state? : IssueState? = None,
) -> Array[Issue] raise @git.GitError {
  let events = load_events(backing_fs, self.git_dir)
  let latest_map : Map[String, Issue] = {}
  let latest_ts : Map[String, Int64] = {}
  for event in events {
    if event.kind() != "issue" {
      continue
    }
    let issue = parse_issue(event.payload()) catch { _ => continue }
    let ts = event.timestamp()
    match latest_ts.get(issue.id) {
      Some(existing_ts) =>
        if ts >= existing_ts {
          latest_ts[issue.id] = ts
          latest_map[issue.id] = issue
        }
      None => {
        latest_ts[issue.id] = ts
        latest_map[issue.id] = issue
      }
    }
  }
  let result : Array[Issue] = []
  for item in latest_map.to_array() {
    let (_, issue) = item
    match state {
      None => result.push(issue)
      Some(s) => if issue.state == s { result.push(issue) }
    }
  }
  result.sort_by(fn(a, b) { parse_int(a.id) - parse_int(b.id) })
  result
}

///|
/// Update an Issue (title, body, labels, assignees)
pub fn Collab::update_issue(
  self : Collab,
  fs : &@git.FileSystem,
  backing_fs : &@git.RepoFileSystem,
  issue_id : String,
  timestamp : Int64,
  title? : String? = None,
  body? : String? = None,
  labels? : Array[String]? = None,
  assignees? : Array[String]? = None,
) -> Issue raise @git.GitError {
  let issue = self.get_issue(backing_fs, issue_id)
  guard issue is Some(existing) else {
    raise @git.GitError::InvalidObject("Issue not found: \{issue_id}")
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
  let new_assignees = match assignees {
    Some(a) => a
    None => existing.assignees
  }
  let updated = Issue::new(
    existing.id,
    new_title,
    new_body,
    existing.author,
    existing.created_at,
    timestamp,
    existing.state,
    labels=new_labels,
    assignees=new_assignees,
    linked_prs=existing.linked_prs,
  )
  let event = CollabEvent::new(
    "issue",
    "issue/" + issue_id,
    timestamp,
    updated.serialize(),
  )
  append_event(fs, backing_fs, self.git_dir, event)
  updated
}

///|
/// Close an Issue
pub fn Collab::close_issue(
  self : Collab,
  fs : &@git.FileSystem,
  backing_fs : &@git.RepoFileSystem,
  issue_id : String,
  timestamp : Int64,
) -> Unit raise @git.GitError {
  let issue = self.get_issue(backing_fs, issue_id)
  guard issue is Some(existing) else {
    raise @git.GitError::InvalidObject("Issue not found: \{issue_id}")
  }
  if existing.state != IssueState::Open {
    raise @git.GitError::InvalidObject("Issue is not open: \{issue_id}")
  }
  // Create updated Issue with Closed state
  let updated = Issue::new(
    existing.id,
    existing.title,
    existing.body,
    existing.author,
    existing.created_at,
    timestamp,
    IssueState::Closed,
    labels=existing.labels,
    assignees=existing.assignees,
    linked_prs=existing.linked_prs,
  )
  let event = CollabEvent::new(
    "issue",
    "issue/" + issue_id,
    timestamp,
    updated.serialize(),
  )
  append_event(fs, backing_fs, self.git_dir, event)
}

///|
/// Add a comment to an Issue
pub fn Collab::add_issue_comment(
  self : Collab,
  fs : &@git.FileSystem,
  backing_fs : &@git.RepoFileSystem,
  issue_id : String,
  author : String,
  body : String,
  timestamp : Int64,
  reply_to? : String? = None,
) -> IssueComment raise @git.GitError {
  // Verify Issue exists
  let issue = self.get_issue(backing_fs, issue_id)
  guard issue is Some(_) else {
    raise @git.GitError::InvalidObject("Issue not found: \{issue_id}")
  }
  // Generate comment ID from content hash
  let comment = IssueComment::new(
    "",
    issue_id,
    author,
    body,
    timestamp,
    reply_to~,
  )
  let comment_data = comment.serialize()
  let (blob_id, compressed) = @git.create_blob_string(comment_data)
  let comment_id = short_hex(blob_id.to_hex(), 8)
  // Create final comment with ID
  let final_comment = IssueComment::new(
    comment_id,
    issue_id,
    author,
    body,
    timestamp,
    reply_to~,
  )
  let event = CollabEvent::new(
    "issue.comment",
    "issue/" + issue_id,
    timestamp,
    final_comment.serialize(),
  )
  append_event(fs, backing_fs, self.git_dir, event)
  ignore(compressed)
  final_comment
}

///|
/// List comments for an Issue
pub fn Collab::list_issue_comments(
  self : Collab,
  backing_fs : &@git.RepoFileSystem,
  issue_id : String,
) -> Array[IssueComment] raise @git.GitError {
  let result : Array[IssueComment] = []
  let events = load_events(backing_fs, self.git_dir)
  for event in events {
    if event.kind() != "issue.comment" {
      continue
    }
    let comment = parse_issue_comment(event.payload()) catch { _ => continue }
    if comment.issue_id != issue_id {
      continue
    }
    result.push(comment)
  }
  result.sort_by(fn(a, b) {
    if a.created_at < b.created_at {
      -1
    } else if a.created_at > b.created_at {
      1
    } else {
      0
    }
  })
  result
}

///|
/// Link a PR to an Issue
pub fn Collab::link_pr_to_issue(
  self : Collab,
  fs : &@git.FileSystem,
  backing_fs : &@git.RepoFileSystem,
  issue_id : String,
  pr_id : String,
  timestamp : Int64,
) -> Unit raise @git.GitError {
  let issue = self.get_issue(backing_fs, issue_id)
  guard issue is Some(existing) else {
    raise @git.GitError::InvalidObject("Issue not found: \{issue_id}")
  }
  // Add PR to linked_prs if not already present
  let linked = existing.linked_prs
  if not(linked.contains(pr_id)) {
    linked.push(pr_id)
  }
  // Create updated Issue
  let updated = Issue::new(
    existing.id,
    existing.title,
    existing.body,
    existing.author,
    existing.created_at,
    timestamp,
    existing.state,
    labels=existing.labels,
    assignees=existing.assignees,
    linked_prs=linked,
  )
  let event = CollabEvent::new(
    "issue",
    "issue/" + issue_id,
    timestamp,
    updated.serialize(),
  )
  append_event(fs, backing_fs, self.git_dir, event)
}

///|
fn load_issue_counter(
  backing_fs : &@git.RepoFileSystem,
  git_dir : String,
) -> Int raise @git.GitError {
  let db = @lib.ObjectDb::load_lazy(backing_fs, git_dir)
  let collab_commit = get_collab_commit(backing_fs, git_dir)
  guard collab_commit is Some(commit_id) else { return 1 }
  let collab_tree = get_commit_tree(db, backing_fs, commit_id)
  guard collab_tree is Some(tree_id) else { return 1 }
  let meta_id = find_tree_entry(db, backing_fs, tree_id, "meta")
  guard meta_id is Some(mid) else { return 1 }
  let counter_id = find_tree_entry(db, backing_fs, mid, "issue_counter")
  guard counter_id is Some(cid) else { return 1 }
  let obj = db.get(backing_fs, cid)
  guard obj is Some(counter_obj) else { return 1 }
  let text = @utf8.decode_lossy(counter_obj.data[:])
  parse_int(trim_whitespace(text))
}

///|

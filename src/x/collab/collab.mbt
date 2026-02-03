///| Collab - Git-native collaboration system (Pull Requests, Issues)

///|
/// The _collab branch reference (preferred)
let collab_ref : String = "refs/heads/_collab"

///|
/// Legacy _den branch reference (read/compat only)
let legacy_den_ref : String = "refs/heads/_den"

///|
/// Collab manages Pull Requests and Issues stored in the _collab branch
pub struct Collab {
  git_dir : String
  mut next_id : Int
}

///|
/// Load an existing Collab from the _collab branch
pub fn Collab::load(
  backing_fs : &@git.RepoFileSystem,
  git_dir : String,
) -> Collab raise @git.GitError {
  let next_id = load_counter(backing_fs, git_dir)
  { git_dir, next_id }
}

///|
/// Initialize a new Collab, creating the _collab branch if needed
pub fn Collab::init(
  fs : &@git.FileSystem,
  backing_fs : &@git.RepoFileSystem,
  git_dir : String,
) -> Collab raise @git.GitError {
  let collab_commit = @lib.resolve_ref(backing_fs, git_dir, collab_ref)
  if collab_commit is None {
    let legacy_commit = @lib.resolve_ref(backing_fs, git_dir, legacy_den_ref)
    match legacy_commit {
      Some(id) => write_collab_ref(fs, backing_fs, git_dir, id)
      None => {
        // Create initial tree structure
        let counter_content = "1\n"
        let (counter_id, counter_compressed) = @git.create_blob_string(
          counter_content,
        )
        write_object_bytes(fs, git_dir, counter_id, counter_compressed)
        let (issue_counter_id, issue_counter_compressed) = @git.create_blob_string(
          counter_content,
        )
        write_object_bytes(
          fs, git_dir, issue_counter_id, issue_counter_compressed,
        )
        // Create meta directory tree with both counters
        let meta_entries = [
          @git.TreeEntry::new("100644", "counter", counter_id),
          @git.TreeEntry::new("100644", "issue_counter", issue_counter_id),
        ]
        let (meta_tree_id, meta_compressed) = @git.create_tree(meta_entries)
        write_object_bytes(fs, git_dir, meta_tree_id, meta_compressed)
        // Create empty events directory
        let (empty_tree_id, empty_compressed) = @git.create_tree([])
        write_object_bytes(fs, git_dir, empty_tree_id, empty_compressed)
        // Create root tree (events + meta)
        let root_entries = [
          @git.TreeEntry::new("040000", "events", empty_tree_id),
          @git.TreeEntry::new("040000", "meta", meta_tree_id),
        ]
        let (root_tree_id, root_compressed) = @git.create_tree(root_entries)
        write_object_bytes(fs, git_dir, root_tree_id, root_compressed)
        // Create initial commit
        let commit = @git.Commit::new(
          root_tree_id,
          [],
          "Collab <collab@local>",
          0L,
          "+0000",
          "Collab <collab@local>",
          0L,
          "+0000",
          "Initialize collab system\n",
        )
        let (commit_id, commit_compressed) = @git.create_commit(commit)
        write_object_bytes(fs, git_dir, commit_id, commit_compressed)
        write_collab_ref(fs, backing_fs, git_dir, commit_id)
      }
    }
  }
  Collab::load(backing_fs, git_dir)
}

///|
/// Create a new Pull Request
pub fn Collab::create_pr(
  self : Collab,
  fs : &@git.FileSystem,
  backing_fs : &@git.RepoFileSystem,
  title : String,
  body : String,
  source_branch : String,
  target_branch : String,
  author : String,
  timestamp : Int64,
) -> PullRequest raise @git.GitError {
  // Resolve source and target commits
  let source_commit = @lib.resolve_ref(backing_fs, self.git_dir, source_branch) catch {
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
  let target_commit = @lib.resolve_ref(backing_fs, self.git_dir, target_branch) catch {
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
  // Generate PR ID
  let pr_id = self.next_id.to_string()
  self.next_id = self.next_id + 1
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
  )
  let event = CollabEvent::new("pr", "pr/" + pr_id, timestamp, pr.serialize())
  append_event(fs, backing_fs, self.git_dir, event, counter=Some(self.next_id))
  pr
}

///|
/// Get a Pull Request by ID
pub fn Collab::get_pr(
  self : Collab,
  backing_fs : &@git.RepoFileSystem,
  pr_id : String,
) -> PullRequest? raise @git.GitError {
  let events = load_events(backing_fs, self.git_dir)
  let mut latest_ts : Int64 = -1
  let mut latest : PullRequest? = None
  for event in events {
    if event.kind() != "pr" {
      continue
    }
    let pr = parse_pull_request(event.payload()) catch { _ => continue }
    if pr.id != pr_id {
      continue
    }
    let ts = event.timestamp()
    if ts >= latest_ts {
      latest_ts = ts
      latest = Some(pr)
    }
  }
  latest
}

///|
/// List Pull Requests, optionally filtered by state
pub fn Collab::list_prs(
  self : Collab,
  backing_fs : &@git.RepoFileSystem,
  state? : PrState? = None,
) -> Array[PullRequest] raise @git.GitError {
  let events = load_events(backing_fs, self.git_dir)
  let latest_map : Map[String, PullRequest] = {}
  let latest_ts : Map[String, Int64] = {}
  for event in events {
    if event.kind() != "pr" {
      continue
    }
    let pr = parse_pull_request(event.payload()) catch { _ => continue }
    let ts = event.timestamp()
    match latest_ts.get(pr.id) {
      Some(existing_ts) =>
        if ts >= existing_ts {
          latest_ts[pr.id] = ts
          latest_map[pr.id] = pr
        }
      None => {
        latest_ts[pr.id] = ts
        latest_map[pr.id] = pr
      }
    }
  }
  let result : Array[PullRequest] = []
  for item in latest_map.to_array() {
    let (_, pr) = item
    match state {
      None => result.push(pr)
      Some(s) => if pr.state == s { result.push(pr) }
    }
  }
  result.sort_by(fn(a, b) { parse_int(a.id) - parse_int(b.id) })
  result
}

///|
/// Update a Pull Request (title, body, labels)
pub fn Collab::update_pr(
  self : Collab,
  fs : &@git.FileSystem,
  backing_fs : &@git.RepoFileSystem,
  pr_id : String,
  timestamp : Int64,
  title? : String? = None,
  body? : String? = None,
  labels? : Array[String]? = None,
) -> PullRequest raise @git.GitError {
  let pr = self.get_pr(backing_fs, pr_id)
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
    timestamp,
    existing.state,
    new_labels,
  )
  let event = CollabEvent::new(
    "pr",
    "pr/" + pr_id,
    timestamp,
    updated.serialize(),
  )
  append_event(fs, backing_fs, self.git_dir, event)
  updated
}

///|
/// Close a Pull Request
pub fn Collab::close_pr(
  self : Collab,
  fs : &@git.FileSystem,
  backing_fs : &@git.RepoFileSystem,
  pr_id : String,
  timestamp : Int64,
) -> Unit raise @git.GitError {
  let pr = self.get_pr(backing_fs, pr_id)
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
    timestamp,
    PrState::Closed,
    existing.labels,
  )
  let event = CollabEvent::new(
    "pr",
    "pr/" + pr_id,
    timestamp,
    updated.serialize(),
  )
  append_event(fs, backing_fs, self.git_dir, event)
}

///|
fn load_counter(
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
  let counter_id = find_tree_entry(db, backing_fs, mid, "counter")
  guard counter_id is Some(cid) else { return 1 }
  let obj = db.get(backing_fs, cid)
  guard obj is Some(counter_obj) else { return 1 }
  let text = @utf8.decode_lossy(counter_obj.data[:])
  parse_int(trim_whitespace(text))
}

///|
fn get_collab_commit(
  backing_fs : &@git.RepoFileSystem,
  git_dir : String,
) -> @git.ObjectId? raise @git.GitError {
  let collab_commit = @lib.resolve_ref(backing_fs, git_dir, collab_ref)
  if collab_commit is Some(_) {
    collab_commit
  } else {
    @lib.resolve_ref(backing_fs, git_dir, legacy_den_ref)
  }
}

///|
fn get_commit_tree(
  db : @lib.ObjectDb,
  backing_fs : &@git.RepoFileSystem,
  commit_id : @git.ObjectId,
) -> @git.ObjectId? raise @git.GitError {
  let obj = db.get(backing_fs, commit_id)
  guard obj is Some(commit_obj) else { return None }
  if commit_obj.obj_type != @git.ObjectType::Commit {
    return None
  }
  let info = @git.parse_commit(commit_obj.data)
  Some(info.tree)
}

///|
fn find_tree_entry(
  db : @lib.ObjectDb,
  backing_fs : &@git.RepoFileSystem,
  tree_id : @git.ObjectId,
  name : String,
) -> @git.ObjectId? raise @git.GitError {
  let obj = db.get(backing_fs, tree_id)
  guard obj is Some(tree_obj) else { return None }
  if tree_obj.obj_type != @git.ObjectType::Tree {
    return None
  }
  let entries = @git.parse_tree(tree_obj.data)
  for entry in entries {
    if entry.name == name {
      return Some(entry.id)
    }
  }
  None
}

///|
fn trim_whitespace(s : String) -> String {
  let chars = s.to_array()
  let mut start = 0
  let mut end = chars.length()
  while start < end {
    let c = chars[start]
    if c == ' ' || c == '\n' || c == '\r' || c == '\t' {
      start = start + 1
    } else {
      break
    }
  }
  while end > start {
    let c = chars[end - 1]
    if c == ' ' || c == '\n' || c == '\r' || c == '\t' {
      end = end - 1
    } else {
      break
    }
  }
  if start >= end {
    ""
  } else {
    String::unsafe_substring(s, start~, end~)
  }
}

///|

///|
fn write_collab_ref(
  fs : &@git.FileSystem,
  backing_fs : &@git.RepoFileSystem,
  git_dir : String,
  commit_id : @git.ObjectId,
) -> Unit raise @git.GitError {
  let refs_dir = join_path(git_dir, "refs/heads")
  fs.mkdir_p(refs_dir)
  fs.write_string(join_path(git_dir, collab_ref), commit_id.to_hex() + "\n")
  let legacy_commit = @lib.resolve_ref(backing_fs, git_dir, legacy_den_ref)
  if legacy_commit is Some(_) {
    fs.write_string(
      join_path(git_dir, legacy_den_ref),
      commit_id.to_hex() + "\n",
    )
  }
}

///|
fn write_object_bytes(
  fs : &@git.FileSystem,
  git_dir : String,
  id : @git.ObjectId,
  compressed : Bytes,
) -> Unit raise @git.GitError {
  let hex = id.to_hex()
  let dir = join_path(
    git_dir,
    "objects/" + String::unsafe_substring(hex, start=0, end=2),
  )
  let path = join_path(dir, String::unsafe_substring(hex, start=2, end=40))
  fs.mkdir_p(dir)
  fs.write_file(path, compressed)
}

///|
fn join_path(a : String, b : String) -> String {
  if a.has_suffix("/") {
    a + b
  } else {
    a + "/" + b
  }
}

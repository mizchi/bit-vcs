///| Import/upsert helpers for external PRs and Issues

///|
pub struct ImportStats {
  created : Int
  updated : Int
}

///|
pub fn ImportStats::new(created : Int, updated : Int) -> ImportStats {
  { created, updated }
}

///|
pub fn ImportStats::created(self : ImportStats) -> Int {
  self.created
}

///|
pub fn ImportStats::updated(self : ImportStats) -> Int {
  self.updated
}

///|
pub fn Collab::import_prs(
  self : Collab,
  fs : &@git.FileSystem,
  backing_fs : &@git.RepoFileSystem,
  prs : Array[PullRequest],
) -> ImportStats raise @git.GitError {
  if prs.length() == 0 {
    return ImportStats::new(0, 0)
  }
  let events = load_events(backing_fs, self.git_dir)
  let latest_ts : Map[String, Int64] = {}
  for event in events {
    if event.kind() != "pr" {
      continue
    }
    let pr = parse_pull_request(event.payload()) catch { _ => continue }
    let ts = event.timestamp()
    match latest_ts.get(pr.id) {
      Some(existing_ts) => if ts >= existing_ts { latest_ts[pr.id] = ts }
      None => latest_ts[pr.id] = ts
    }
  }
  let current = load_counter(backing_fs, self.git_dir)
  let mut max_id = current - 1
  for pr in prs {
    let value = parse_int(pr.id())
    if value > max_id {
      max_id = value
    }
  }
  let mut next_id = current
  if max_id >= next_id {
    next_id = max_id + 1
  }
  let mut created = 0
  let mut updated = 0
  for pr in prs {
    let existing_ts = latest_ts.get(pr.id())
    let event_ts = match existing_ts {
      Some(ts) => if pr.updated_at <= ts { ts + 1 } else { pr.updated_at }
      None => pr.updated_at
    }
    let event = CollabEvent::new(
      "pr",
      "pr/" + pr.id(),
      event_ts,
      pr.serialize(),
    )
    append_event(fs, backing_fs, self.git_dir, event, counter=Some(next_id))
    match existing_ts {
      Some(_) => updated += 1
      None => created += 1
    }
    latest_ts[pr.id()] = event_ts
  }
  if next_id > self.next_id {
    self.next_id = next_id
  }
  ImportStats::new(created, updated)
}

///|
pub fn Collab::import_issues(
  self : Collab,
  fs : &@git.FileSystem,
  backing_fs : &@git.RepoFileSystem,
  issues : Array[Issue],
) -> ImportStats raise @git.GitError {
  if issues.length() == 0 {
    return ImportStats::new(0, 0)
  }
  let events = load_events(backing_fs, self.git_dir)
  let latest_ts : Map[String, Int64] = {}
  for event in events {
    if event.kind() != "issue" {
      continue
    }
    let issue = parse_issue(event.payload()) catch { _ => continue }
    let ts = event.timestamp()
    match latest_ts.get(issue.id) {
      Some(existing_ts) => if ts >= existing_ts { latest_ts[issue.id] = ts }
      None => latest_ts[issue.id] = ts
    }
  }
  let current = load_issue_counter(backing_fs, self.git_dir)
  let mut max_id = current - 1
  for issue in issues {
    let value = parse_int(issue.id())
    if value > max_id {
      max_id = value
    }
  }
  let mut next_id = current
  if max_id >= next_id {
    next_id = max_id + 1
  }
  let mut created = 0
  let mut updated = 0
  for issue in issues {
    let existing_ts = latest_ts.get(issue.id())
    let event_ts = match existing_ts {
      Some(ts) => if issue.updated_at <= ts { ts + 1 } else { issue.updated_at }
      None => issue.updated_at
    }
    let event = CollabEvent::new(
      "issue",
      "issue/" + issue.id(),
      event_ts,
      issue.serialize(),
    )
    append_event(
      fs,
      backing_fs,
      self.git_dir,
      event,
      issue_counter=Some(next_id),
    )
    match existing_ts {
      Some(_) => updated += 1
      None => created += 1
    }
    latest_ts[issue.id()] = event_ts
  }
  ImportStats::new(created, updated)
}

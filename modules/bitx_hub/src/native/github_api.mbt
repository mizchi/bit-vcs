///| GitHub API client functions using `gh` CLI or GITHUB_TOKEN

///|
pub fn github_has_gh_cli() -> Bool {
  match @sys.get_env_var("PATH") {
    None => false
    Some(_) => true // gh availability checked at call time via exit code
  }
}

///|
pub fn github_has_token() -> Bool {
  match @sys.get_env_var("GITHUB_TOKEN") {
    Some(t) => t.length() > 0
    None =>
      match @sys.get_env_var("GH_TOKEN") {
        Some(t) => t.length() > 0
        None => false
      }
  }
}

///|
/// Returns "gh", "token", or raises error
pub fn github_detect_method() -> String {
  if github_has_token() {
    return "token"
  }
  // We'll try gh cli — actual availability checked when called
  "gh"
}

///|
/// Get the authenticated GitHub username
pub async fn github_get_authenticated_user() -> String raise @bit.GitError {
  let out = gh_api_collect_output(["api", "user", "--jq", ".login"])
  out.trim(chars=" \n\r\t").to_owned()
}

///|
/// Check if the authenticated user owns the given repo (owner/repo format)
pub async fn github_check_repo_ownership(
  repo : String,
) -> Bool raise @bit.GitError {
  let slash = repo.find("/")
  let owner = match slash {
    Some(idx) => String::unsafe_substring(repo, start=0, end=idx)
    None => return false
  }
  let user = github_get_authenticated_user()
  user.to_lower() == owner.to_lower()
}

///|
fn github_json_bool(obj : Map[String, Json], key : String) -> Bool {
  match obj.get(key) {
    Some(Json::True) => true
    _ => false
  }
}

///|
fn github_repo_permissions_allow_push(obj : Map[String, Json]) -> Bool {
  match obj.get("permissions") {
    Some(Json::Object(permissions)) =>
      github_json_bool(permissions, "push") ||
      github_json_bool(permissions, "maintain") ||
      github_json_bool(permissions, "admin")
    _ => false
  }
}

///|
/// Check if the authenticated user can push/write to the repo.
/// Uses GitHub's repository permissions so organization repositories work.
pub async fn github_check_repo_push_permission(
  repo : String,
) -> Bool raise @bit.GitError {
  let out = gh_api_collect_output(["api", "repos/\{repo}", "--method", "GET"])
  let obj = parse_json_object_from_api(out)
  github_repo_permissions_allow_push(obj)
}

///|
async fn gh_api_collect_output(
  args : Array[String],
) -> String raise @bit.GitError {
  let (code, stdout, stderr) = @process.collect_output(
    "gh",
    args,
    inherit_env=true,
  ) catch {
    err => raise @bit.GitError::IoError("gh api failed: \{err}")
  }
  let out = stdout.text() catch { _ => "" }
  if code != 0 {
    let err_text = stderr.text() catch { _ => "" }
    let normalized = err_text.trim(chars=" \n\r\t").to_owned()
    raise @bit.GitError::IoError("gh api failed (\{code}): \{normalized}")
  }
  out
}

///|
fn parse_json_array_from_api(text : String) -> Array[Json] raise @bit.GitError {
  let parsed = @json.parse(text) catch {
    err =>
      raise @bit.GitError::InvalidObject(
        "Invalid JSON from gh api: \{err.to_string()}",
      )
  }
  match parsed {
    Json::Array(items) => items
    _ =>
      raise @bit.GitError::InvalidObject(
        "Expected JSON array from gh api, got: \{Repr(parsed)}",
      )
  }
}

///|
fn parse_json_object_from_api(
  text : String,
) -> Map[String, Json] raise @bit.GitError {
  let parsed = @json.parse(text) catch {
    err =>
      raise @bit.GitError::InvalidObject(
        "Invalid JSON from gh api: \{err.to_string()}",
      )
  }
  match parsed {
    Json::Object(obj) => obj
    _ =>
      raise @bit.GitError::InvalidObject(
        "Expected JSON object from gh api, got: \{Repr(parsed)}",
      )
  }
}

///|
/// List issues via gh api repos/{owner}/{repo}/issues
pub async fn github_list_issues(
  repo : String,
  since? : String = "",
  state? : String = "open",
) -> Array[@hub.GhIssue] raise @bit.GitError {
  let args : Array[String] = [
    "api",
    "repos/\{repo}/issues",
    "--paginate",
    "--method",
    "GET",
    "-f",
    "state=\{state}",
    "-f",
    "per_page=100",
  ]
  if since.length() > 0 {
    args.push("-f")
    args.push("since=\{since}")
  }
  let out = gh_api_collect_output(args)
  let items = parse_json_array_from_api(out)
  let issues : Array[@hub.GhIssue] = []
  for item in items {
    match item {
      Json::Object(obj) => {
        // Skip pull requests (GitHub issues API includes PRs)
        match obj.get("pull_request") {
          Some(Json::Object(_)) => continue
          _ => ()
        }
        issues.push(@hub.GhIssue::from_json(obj))
      }
      _ => ()
    }
  }
  issues
}

///|
/// List pull requests via gh api repos/{owner}/{repo}/pulls
pub async fn github_list_prs(
  repo : String,
  since? : String = "",
  state? : String = "open",
) -> Array[@hub.GhPullRequest] raise @bit.GitError {
  let args : Array[String] = [
    "api",
    "repos/\{repo}/pulls",
    "--paginate",
    "--method",
    "GET",
    "-f",
    "state=\{state}",
    "-f",
    "per_page=100",
  ]
  if since.length() > 0 {
    args.push("-f")
    args.push("since=\{since}")
  }
  let out = gh_api_collect_output(args)
  let items = parse_json_array_from_api(out)
  let prs : Array[@hub.GhPullRequest] = []
  for item in items {
    match item {
      Json::Object(obj) => prs.push(@hub.GhPullRequest::from_json(obj))
      _ => ()
    }
  }
  prs
}

///|
/// List comments on an issue/PR via gh api repos/{owner}/{repo}/issues/{number}/comments
pub async fn github_list_comments(
  repo : String,
  number : Int,
  since? : String = "",
) -> Array[@hub.GhComment] raise @bit.GitError {
  let args : Array[String] = [
    "api",
    "repos/\{repo}/issues/\{number}/comments",
    "--paginate",
    "--method",
    "GET",
    "-f",
    "per_page=100",
  ]
  if since.length() > 0 {
    args.push("-f")
    args.push("since=\{since}")
  }
  let out = gh_api_collect_output(args)
  let items = parse_json_array_from_api(out)
  let comments : Array[@hub.GhComment] = []
  for item in items {
    match item {
      Json::Object(obj) => comments.push(@hub.GhComment::from_json(obj))
      _ => ()
    }
  }
  comments
}

///|
/// Create an issue via gh api repos/{owner}/{repo}/issues
pub async fn github_create_issue(
  repo : String,
  title : String,
  body : String,
  labels : Array[String],
  assignees : Array[String],
) -> @hub.GhIssue raise @bit.GitError {
  let args : Array[String] = [
    "api",
    "repos/\{repo}/issues",
    "--method",
    "POST",
    "-f",
    "title=\{title}",
    "-f",
    "body=\{body}",
  ]
  for label in labels {
    args.push("-f")
    args.push("labels[]=\{label}")
  }
  for assignee in assignees {
    args.push("-f")
    args.push("assignees[]=\{assignee}")
  }
  let out = gh_api_collect_output(args)
  let obj = parse_json_object_from_api(out)
  @hub.GhIssue::from_json(obj)
}

///|
/// Update an issue via gh api repos/{owner}/{repo}/issues/{number}
pub async fn github_update_issue(
  repo : String,
  number : Int,
  title? : String = "",
  body? : String = "",
  state? : String = "",
  labels? : Array[String] = [],
  assignees? : Array[String] = [],
) -> @hub.GhIssue raise @bit.GitError {
  let args : Array[String] = [
    "api",
    "repos/\{repo}/issues/\{number}",
    "--method",
    "PATCH",
  ]
  if title.length() > 0 {
    args.push("-f")
    args.push("title=\{title}")
  }
  if body.length() > 0 {
    args.push("-f")
    args.push("body=\{body}")
  }
  if state.length() > 0 {
    args.push("-f")
    args.push("state=\{state}")
  }
  if labels.length() > 0 {
    for label in labels {
      args.push("-f")
      args.push("labels[]=\{label}")
    }
  }
  if assignees.length() > 0 {
    for assignee in assignees {
      args.push("-f")
      args.push("assignees[]=\{assignee}")
    }
  }
  let out = gh_api_collect_output(args)
  let obj = parse_json_object_from_api(out)
  @hub.GhIssue::from_json(obj)
}

///|
/// Create a comment on an issue/PR via gh api repos/{owner}/{repo}/issues/{number}/comments
pub async fn github_create_comment(
  repo : String,
  number : Int,
  body : String,
) -> @hub.GhComment raise @bit.GitError {
  let args : Array[String] = [
    "api",
    "repos/\{repo}/issues/\{number}/comments",
    "--method",
    "POST",
    "-f",
    "body=\{body}",
  ]
  let out = gh_api_collect_output(args)
  let obj = parse_json_object_from_api(out)
  @hub.GhComment::from_json(obj)
}

///|
/// Update a comment via gh api repos/{owner}/{repo}/issues/comments/{comment_id}
pub async fn github_update_comment(
  repo : String,
  comment_id : Int,
  body : String,
) -> @hub.GhComment raise @bit.GitError {
  let args : Array[String] = [
    "api",
    "repos/\{repo}/issues/comments/\{comment_id}",
    "--method",
    "PATCH",
    "-f",
    "body=\{body}",
  ]
  let out = gh_api_collect_output(args)
  let obj = parse_json_object_from_api(out)
  @hub.GhComment::from_json(obj)
}

///|
/// Delete a comment via gh api repos/{owner}/{repo}/issues/comments/{comment_id}
pub async fn github_delete_comment(
  repo : String,
  comment_id : Int,
) -> Unit raise @bit.GitError {
  let args : Array[String] = [
    "api",
    "repos/\{repo}/issues/comments/\{comment_id}",
    "--method",
    "DELETE",
  ]
  ignore(gh_api_collect_output(args))
}

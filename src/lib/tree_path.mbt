///|
fn normalize_repo_path_internal(path : String) -> String {
  let parts : Array[String] = []
  for part_view in path.split("/") {
    let part = part_view.to_string()
    if part == "" || part == "." {
      continue
    } else if part == ".." {
      if parts.length() > 0 && parts[parts.length() - 1] != ".." {
        let _ = parts.pop()

      } else if not(path.has_prefix("/")) {
        parts.push(part)
      }
    } else {
      parts.push(part)
    }
  }
  let result = parts.join("/")
  if path.has_prefix("/") {
    if result.length() == 0 {
      "/"
    } else {
      "/" + result
    }
  } else if result.length() == 0 {
    "."
  } else {
    result
  }
}

///|
pub fn normalize_repo_path(path : String) -> String raise @git.GitError {
  let normalized = normalize_repo_path_internal(path)
  let stripped = if normalized.has_prefix("/") && normalized.length() > 1 {
    (try! normalized[1:]).to_string()
  } else {
    normalized
  }
  if stripped == "." || stripped == "/" || stripped.length() == 0 {
    raise @git.GitError::InvalidObject("path required")
  }
  if stripped == ".." || stripped.has_prefix("../") {
    raise @git.GitError::InvalidObject(
      "path must not traverse outside repository",
    )
  }
  stripped
}

///|
fn split_path_parts(path : String) -> Array[String] {
  path
  .split("/")
  .filter(fn(s) { s.length() > 0 })
  .map(fn(s) { s.to_string() })
  .collect()
}

///|
pub fn find_tree_entry(
  db : ObjectDb,
  fs : &@git.RepoFileSystem,
  tree_id : @git.ObjectId,
  path : String,
) -> @git.TreeEntry? raise @git.GitError {
  let parts = split_path_parts(path)
  if parts.length() == 0 {
    return None
  }
  let mut current = tree_id
  for i in 0..<parts.length() {
    let name = parts[i]
    let obj = db.get(fs, current)
    guard obj is Some(o) else { return None }
    let entries = @git.parse_tree(o.data)
    let mut found : @git.TreeEntry? = None
    for entry in entries {
      if entry.name == name {
        found = Some(entry)
        break
      }
    }
    match found {
      None => return None
      Some(entry) =>
        if i == parts.length() - 1 {
          return Some(entry)
        } else {
          let is_tree = entry.mode == "40000" || entry.mode == "040000"
          if not(is_tree) {
            return None
          }
          current = entry.id
        }
    }
  }
  None
}

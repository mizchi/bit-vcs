///| Shared helper functions for native + js targets

///|
fn io_error(err : @fs.IOError) -> @bitcore.GitError {
  @bitcore.GitError::IoError(@debug.render(Repr(err)))
}

///|
fn collect_args(args : Array[String], start : Int) -> Array[String] {
  let out : Array[String] = []
  for i in start..<args.length() {
    out.push(args[i])
  }
  out
}

///|
fn parent_dir(path : String) -> String {
  if path.length() == 0 || path == "/" {
    return "/"
  }
  let sep = @path.sep.to_string()
  match path.rev_find(sep) {
    None => ""
    Some(idx) => if idx == 0 { sep } else { string_slice_to(path, idx) }
  }
}

///|
fn string_slice_from(text : String, start : Int) -> String {
  String::unsafe_substring(text, start~, end=text.length())
}

///|
fn string_slice_to(text : String, end : Int) -> String {
  let base = string_slice_from(text, 0)
  String::unsafe_substring(base, start=0, end~)
}

///|
fn ensure_dir(path : String) -> Unit raise @bitcore.GitError {
  if path.length() == 0 || path == "/" || path == "." {
    return ()
  }
  if @fs.path_exists(path) {
    let is_dir = @fs.is_dir(path) catch { _ => false }
    if is_dir {
      return ()
    }
    raise @bitcore.GitError::IoError("path exists and is not dir: " + path)
  }
  let parent = parent_dir(path)
  if parent.length() > 0 && parent != path {
    ensure_dir(parent)
  }
  @fs.create_dir(path) catch {
    err => raise io_error(err)
  }
}

///|
fn normalize_path(path : String) -> String {
  let parts : Array[String] = []
  for part_view in path.split("/") {
    let part = part_view.to_owned()
    if part == "" || part == "." {
      continue
    } else if part == ".." {
      if parts.length() > 0 && parts[parts.length() - 1] != ".." {
        let _ = parts.pop()
      } else if !path.has_prefix("/") {
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
fn join_repo_marker(root : String, marker : String) -> String {
  if root == "/" {
    "/" + marker
  } else if root == "." {
    marker
  } else {
    root + "/" + marker
  }
}

///|
fn is_path_prefix(path : String, prefix : String) -> Bool {
  if prefix.length() > path.length() {
    return false
  }
  if prefix == path {
    return true
  }
  path.has_prefix(prefix) &&
  path.length() > prefix.length() &&
  path[prefix.length()] == '/'
}

///|
fn is_bare_repo_dir(path : String) -> Bool {
  let head_ok = @fs.is_file(path + "/HEAD") catch { _ => false }
  let objs_ok = @fs.is_dir(path + "/objects") catch { _ => false }
  head_ok && objs_ok
}

///|
fn find_repo_root(start : String) -> String? {
  let mut current = normalize_path(start)
  if current.length() == 0 {
    current = "."
  }
  let ceiling_dirs : Array[String] = []
  match @sys.get_env_var("GIT_CEILING_DIRECTORIES") {
    Some(raw) =>
      for view in raw.split(":") {
        let dir = view.to_owned()
        if dir.length() == 0 {
          continue
        }
        ceiling_dirs.push(normalize_path(dir))
      }
    None => ()
  }
  // Compute min_offset: longest ceiling that is a strict component-aligned
  // prefix of start (ceiling == start is skipped per git behavior).
  let mut min_ceil_len = 0
  for ceiling in ceiling_dirs {
    if ceiling == current {
      continue // start dir is always searchable
    }
    if is_path_prefix(current, ceiling) && ceiling.length() > min_ceil_len {
      min_ceil_len = ceiling.length()
    }
  }
  let mut last = ""
  while true {
    let bit_path = join_repo_marker(current, ".git")
    let is_git_dir = @fs.is_dir(bit_path) catch { _ => false }
    let is_git_file = if is_git_dir {
      false
    } else {
      @fs.is_file(bit_path) catch {
        _ => false
      }
    }
    if is_git_dir || is_git_file {
      return Some(current)
    }
    let bit_path = join_repo_marker(current, ".bit")
    let is_bit_dir = @fs.is_dir(bit_path) catch { _ => false }
    let is_bit_file = if is_bit_dir {
      false
    } else {
      @fs.is_file(bit_path) catch {
        _ => false
      }
    }
    if is_bit_dir || is_bit_file {
      return Some(current)
    }
    let parent = parent_dir(current)
    let next = if parent.length() == 0 { "." } else { parent }
    if next == current || next == last {
      break
    }
    // Block ascending if we would reach at or above a ceiling directory
    if min_ceil_len > 0 && next.length() <= min_ceil_len {
      return None
    }
    last = current
    current = next
  }
  None
}

///|
fn get_work_root() -> String {
  match @sys.get_env_var("GIT_SHIM_CWD") {
    Some(dir) =>
      // -C dir sets CWD to a subdirectory; find the repo root from there
      if is_bare_repo_dir(dir) {
        dir
      } else {
        find_repo_root(dir).unwrap_or(dir)
      }
    None =>
      match @sys.get_env_var("GIT_WORK_TREE") {
        Some(dir) => dir
        None =>
          match @sys.get_env_var("GIT_DIR") {
            Some(dir) => normalize_repo_root(dir)
            None =>
              match @sys.get_env_var("GIT_SHIM_PWD") {
                Some(pwd) =>
                  if is_bare_repo_dir(pwd) {
                    pwd
                  } else {
                    find_repo_root(pwd).unwrap_or(".")
                  }
                None => {
                  if @sys.get_env_var("PWD") is Some(pwd) {
                    if is_bare_repo_dir(pwd) {
                      return pwd
                    }
                    if find_repo_root(pwd) is Some(root) {
                      return root
                    }
                  }
                  if @env.current_dir() is Some(dir) {
                    if is_bare_repo_dir(dir) {
                      return dir
                    }
                    if find_repo_root(dir) is Some(root) {
                      return root
                    }
                  }
                  if is_bare_repo_dir(".") {
                    return "."
                  }
                  "."
                }
              }
          }
      }
  }
}

///|
fn normalize_repo_root(path : String) -> String {
  if path == ".git" || path == ".bit" {
    return "."
  }
  if path.has_suffix("/.git") && path.length() > 5 {
    return string_slice_to(path, path.length() - 5)
  }
  if path.has_suffix("/.bit") && path.length() > 5 {
    return string_slice_to(path, path.length() - 5)
  }
  path
}

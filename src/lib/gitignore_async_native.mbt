///| Gitignore integration for git worktree operations (async, native)

///|
/// List files under root, excluding ignored paths and .git.
pub async fn list_working_files_async(
  fs : &@git.RepoFileSystem,
  root : String,
) -> Array[String] raise @git.GitError {
  let cache_enabled = cache_enabled_by_env() && cache_available(root)
  let clear_cache = cache_clear_requested()
  if cache_enabled && clear_cache {
    let cache_path = cache_file_path(root)
    ignore(try? @afs.remove(cache_path))
  }
  if cache_enabled {
    if not(clear_cache) {
      match try_read_cache(root) {
        Some(cache) => if validate_cache(root, cache) { return cache.files }
        None => ()
      }
    }
  }
  let matcher = @ignore.Matcher::new()
  let out : Array[String] = []
  let dirs : Array[PathMtime] = []
  let ignores : Array[PathMtime] = []
  walk_dir_async(fs, root, "", matcher, out, cache_enabled, dirs, ignores)
  if cache_enabled {
    write_cache(root, dirs, ignores, out)
  }
  out
}

///|
pub async fn working_files_cache(root : String) -> Array[String]? noraise {
  let cache_enabled = cache_enabled_by_env() && cache_available(root)
  if not(cache_enabled) || cache_clear_requested() {
    return None
  }
  match try_read_cache(root) {
    Some(cache) =>
      if validate_cache(root, cache) {
        Some(cache.files)
      } else {
        None
      }
    None => None
  }
}

///|
async fn walk_dir_async(
  fs : &@git.RepoFileSystem,
  root : String,
  rel : String,
  matcher : @ignore.Matcher,
  out : Array[String],
  cache_enabled : Bool,
  dirs : Array[PathMtime],
  ignores : Array[PathMtime],
) -> Unit raise @git.GitError {
  let dir = if rel == "" { root } else { join_path(root, rel) }
  if cache_enabled {
    let mtime_result : Result[(Int64, Int), Error] = try? @afs.mtime(
      dir,
      follow_symlink=false,
    )
    match mtime_result {
      Ok((sec, nsec)) => {
        let rel_path = if rel == "" { "." } else { rel }
        dirs.push({ path: rel_path, sec: sec.to_int(), nsec })
      }
      Err(_) => ()
    }
  }
  // Skip submodules (directories containing .git file or directory)
  if rel != "" {
    let git_marker = join_path(dir, ".git")
    if fs.is_file(git_marker) {
      return ()
    }
  }
  let entries = fs.readdir(dir)
  if rel != "" && entries_contains(entries, ".git") {
    return ()
  }
  let prev_len = matcher.len()
  if entries_contains(entries, ".gitignore") {
    let ignore_path = join_path(dir, ".gitignore")
    let content = @utf8.decode_lossy(fs.read_file(ignore_path)[:])
    matcher.add_rules(rel, content)
    if cache_enabled {
      let mtime_result : Result[(Int64, Int), Error] = try? @afs.mtime(
        ignore_path,
        follow_symlink=false,
      )
      match mtime_result {
        Ok((sec, nsec)) => {
          let rel_path = if rel == "" {
            ".gitignore"
          } else {
            rel + "/.gitignore"
          }
          ignores.push({ path: rel_path, sec: sec.to_int(), nsec })
        }
        Err(_) => ()
      }
    }
  }
  for name in entries {
    if name == "." || name == ".." || name == ".git" || name == ".jj" {
      continue
    }
    let child_rel = if rel == "" { name } else { rel + "/" + name }
    let child_path = join_path(root, child_rel)
    let mut is_dir = fs.is_dir(child_path)
    if is_dir {
      let kind_result : Result[@afs.FileKind, Error] = try? @afs.kind(
        child_path,
        follow_symlink=false,
      )
      match kind_result {
        Ok(@afs.FileKind::SymLink) => is_dir = false
        Ok(@afs.FileKind::Directory) => ()
        Ok(_) => is_dir = false
        Err(_) => ()
      }
    }
    if matcher.is_ignored(child_rel, is_dir) {
      // Still traverse to allow negations in nested .gitignore
      if is_dir {
        walk_dir_async(
          fs, root, child_rel, matcher, out, cache_enabled, dirs, ignores,
        )
      }
      continue
    }
    if is_dir {
      walk_dir_async(
        fs, root, child_rel, matcher, out, cache_enabled, dirs, ignores,
      )
    } else {
      out.push(child_rel)
    }
  }
  matcher.truncate(prev_len)
}

///|
priv struct PathMtime {
  path : String
  sec : Int
  nsec : Int
}

///|
priv struct WorkingFilesCache {
  dirs : Array[PathMtime]
  ignores : Array[PathMtime]
  files : Array[String]
}

///|
fn cache_enabled_by_env() -> Bool {
  match @sys.get_env_var("BIT_UNTRACKED_CACHE") {
    Some(v) => v != "" && v != "0"
    None => true
  }
}

///|
fn cache_clear_requested() -> Bool {
  match @sys.get_env_var("BIT_UNTRACKED_CACHE_CLEAR") {
    Some(v) => v != "" && v != "0"
    None => false
  }
}

///|
async fn cache_available(root : String) -> Bool noraise {
  let git_dir = join_path(root, ".git")
  let kind_result : Result[@afs.FileKind, Error] = try? @afs.kind(git_dir)
  match kind_result {
    Ok(@afs.FileKind::Directory) => true
    Ok(_) => false
    Err(_) => false
  }
}

///|
fn cache_file_path(root : String) -> String {
  join_path(join_path(root, ".git/bit"), "untracked.cache")
}

///|
async fn try_read_cache(root : String) -> WorkingFilesCache? noraise {
  let cache_path = cache_file_path(root)
  let data_result = try? @afs.read_file(cache_path)
  match data_result {
    Ok(data) => {
      let text = data.text() catch { _ => return None }
      parse_cache(text)
    }
    Err(_) => None
  }
}

///|
fn parse_cache(text : String) -> WorkingFilesCache? {
  let it = text.split("\n").iterator()
  match it.next() {
    Some(v) if v.to_string() == "v1" => ()
    _ => return None
  }
  let dirs_line = match it.next() {
    Some(v) => v.to_string()
    None => return None
  }
  let dirs_count = parse_count(dirs_line, "dirs ")
  guard dirs_count is Some(dir_len) else { return None }
  let dirs : Array[PathMtime] = Array::new(capacity=dir_len)
  for _ in 0..<dir_len {
    let line = match it.next() {
      Some(v) => v
      None => return None
    }
    match parse_mtime_line(line) {
      Some(v) => dirs.push(v)
      None => return None
    }
  }
  let ignores_line = match it.next() {
    Some(v) => v.to_string()
    None => return None
  }
  let ignores_count = parse_count(ignores_line, "ignores ")
  guard ignores_count is Some(ignore_len) else { return None }
  let ignores : Array[PathMtime] = Array::new(capacity=ignore_len)
  for _ in 0..<ignore_len {
    let line = match it.next() {
      Some(v) => v
      None => return None
    }
    match parse_mtime_line(line) {
      Some(v) => ignores.push(v)
      None => return None
    }
  }
  let files_line = match it.next() {
    Some(v) => v.to_string()
    None => return None
  }
  let files_count = parse_count(files_line, "files ")
  guard files_count is Some(file_len) else { return None }
  let files : Array[String] = Array::new(capacity=file_len)
  for _ in 0..<file_len {
    let line = match it.next() {
      Some(v) => v.to_string()
      None => return None
    }
    if line.length() == 0 {
      return None
    }
    files.push(line)
  }
  Some({ dirs, ignores, files })
}

///|
fn parse_count(line : String, prefix : String) -> Int? {
  if not(line.has_prefix(prefix)) {
    return None
  }
  let num = String::unsafe_substring(
    line,
    start=prefix.length(),
    end=line.length(),
  )
  let parsed = try? @strconv.parse_int(num)
  match parsed {
    Ok(v) => Some(v)
    Err(_) => None
  }
}

///|
fn parse_mtime_line(line : StringView) -> PathMtime? {
  let parts = line.split("\t").iterator()
  let path = match parts.next() {
    Some(v) => v.to_string()
    None => return None
  }
  let sec_str = match parts.next() {
    Some(v) => v.to_string()
    None => return None
  }
  let nsec_str = match parts.next() {
    Some(v) => v.to_string()
    None => return None
  }
  let sec_res = try? @strconv.parse_int(sec_str)
  let nsec_res = try? @strconv.parse_int(nsec_str)
  match sec_res {
    Ok(sec) =>
      match nsec_res {
        Ok(nsec) => Some({ path, sec, nsec })
        Err(_) => None
      }
    Err(_) => None
  }
}

///|
async fn validate_cache(
  root : String,
  cache : WorkingFilesCache,
) -> Bool noraise {
  for entry in cache.dirs {
    let abs = if entry.path == "." { root } else { join_path(root, entry.path) }
    let mtime_result : Result[(Int64, Int), Error] = try? @afs.mtime(
      abs,
      follow_symlink=false,
    )
    match mtime_result {
      Ok((sec, nsec)) =>
        if sec.to_int() != entry.sec || nsec != entry.nsec {
          return false
        }
      Err(_) => return false
    }
  }
  for entry in cache.ignores {
    let abs = join_path(root, entry.path)
    let mtime_result : Result[(Int64, Int), Error] = try? @afs.mtime(
      abs,
      follow_symlink=false,
    )
    match mtime_result {
      Ok((sec, nsec)) =>
        if sec.to_int() != entry.sec || nsec != entry.nsec {
          return false
        }
      Err(_) => return false
    }
  }
  true
}

///|
async fn write_cache(
  root : String,
  dirs : Array[PathMtime],
  ignores : Array[PathMtime],
  files : Array[String],
) -> Unit noraise {
  let cache_dir = join_path(root, ".git/bit")
  ignore(try? @afs.mkdir(cache_dir, permission=0o755, recursive=true))
  let cache_path = cache_file_path(root)
  let text = encode_cache(dirs, ignores, files)
  ignore(try? @afs.write_file(cache_path, @utf8.encode(text), create=0o644))
}

///|
fn encode_cache(
  dirs : Array[PathMtime],
  ignores : Array[PathMtime],
  files : Array[String],
) -> String {
  let sb = StringBuilder::new()
  sb.write_string("v1\n")
  sb.write_string("dirs " + dirs.length().to_string() + "\n")
  for d in dirs {
    sb.write_string(
      d.path + "\t" + d.sec.to_string() + "\t" + d.nsec.to_string() + "\n",
    )
  }
  sb.write_string("ignores " + ignores.length().to_string() + "\n")
  for d in ignores {
    sb.write_string(
      d.path + "\t" + d.sec.to_string() + "\t" + d.nsec.to_string() + "\n",
    )
  }
  sb.write_string("files " + files.length().to_string() + "\n")
  let mut i = 0
  while i < files.length() {
    sb.write_string(files[i])
    if i + 1 < files.length() {
      sb.write_char('\n')
    }
    i += 1
  }
  sb.to_string()
}

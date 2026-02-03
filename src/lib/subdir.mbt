///|
/// Write subdir-clone metadata to .git/info/attributes
pub fn write_subdir_attributes(
  fs : &@git.FileSystem,
  git_dir : String,
  remote_url : String,
  subdir_path : String,
  base_commit : @git.ObjectId,
) -> Unit {
  let info_dir = git_dir + "/info"
  fs.mkdir_p(info_dir) catch {
    _ => ()
  }
  let content = StringBuilder::new()
  content.write_string("# subdir-clone metadata\n")
  content.write_string("* subdir-remote=")
  content.write_string(remote_url)
  content.write_string("\n")
  content.write_string("* subdir-path=")
  content.write_string(subdir_path)
  content.write_string("\n")
  content.write_string("* subdir-base=")
  content.write_string(base_commit.to_hex())
  content.write_string("\n")
  let attr_path = info_dir + "/attributes"
  fs.write_file(attr_path, string_to_bytes(content.to_string())) catch {
    _ => ()
  }
}

///|
/// Read subdir-clone metadata from .git/info/attributes
pub fn read_subdir_attributes(
  fs : &@git.RepoFileSystem,
  git_dir : String,
) -> (String, String, String)? {
  let attr_path = git_dir + "/info/attributes"
  let content = fs.read_file(attr_path) catch { _ => return None }
  let text = bytes_to_string(content)
  let mut remote = ""
  let mut path = ""
  let mut base = ""
  for line in text.split("\n") {
    let l = line.to_string()
    if l.has_prefix("* subdir-remote=") {
      remote = String::unsafe_substring(l, start=16, end=l.length())
    } else if l.has_prefix("* subdir-path=") {
      path = String::unsafe_substring(l, start=14, end=l.length())
    } else if l.has_prefix("* subdir-base=") {
      base = String::unsafe_substring(l, start=14, end=l.length())
    }
  }
  if remote.length() > 0 && path.length() > 0 {
    Some((remote, path, base))
  } else {
    None
  }
}

///|
/// Update subdir-base in .git/info/attributes
pub fn update_subdir_base(
  wfs : &@git.FileSystem,
  rfs : &@git.RepoFileSystem,
  git_dir : String,
  new_base : String,
) -> Unit {
  match read_subdir_attributes(rfs, git_dir) {
    Some((remote, path, _)) =>
      write_subdir_attributes(
        wfs,
        git_dir,
        remote,
        path,
        @git.ObjectId::from_hex(new_base) catch {
          _ => return
        },
      )
    None => ()
  }
}

///|
/// Check if current directory is a subdir-clone
pub fn is_subdir_clone(fs : &@git.RepoFileSystem, git_dir : String) -> Bool {
  read_subdir_attributes(fs, git_dir) is Some(_)
}

///|
/// Get effective remote URL - prefers subdir remote over config
pub fn get_effective_remote_url(
  fs : &@git.RepoFileSystem,
  git_dir : String,
) -> String? {
  // First check subdir-clone attributes
  match read_subdir_attributes(fs, git_dir) {
    Some((remote_url, _, _)) => Some(remote_url)
    None => read_remote_url_from_config(fs, git_dir)
  }
}

///|
/// Get subdir info for display (remote, path, base)
pub fn get_subdir_info(
  fs : &@git.RepoFileSystem,
  git_dir : String,
) -> (String, String, String)? {
  read_subdir_attributes(fs, git_dir)
}

///|
/// Get the subdir tree from a commit (for subdir-clone operations)
pub fn get_subdir_tree_from_commit(
  db : ObjectDb,
  fs : &@git.RepoFileSystem,
  commit_id : @git.ObjectId,
  subdir_path : String,
) -> @git.ObjectId? raise @git.GitError {
  let obj = db.get(fs, commit_id)
  guard obj is Some(o) else { return None }
  let info = @git.parse_commit(o.data) catch { err => raise err }
  find_subtree(db, fs, info.tree, subdir_path) catch {
    err => raise err
  }
}

///|
/// Resolve a ref to commit ID, handling both local and remote refs
pub fn resolve_ref_for_subdir(
  fs : &@git.RepoFileSystem,
  git_dir : String,
  refspec : String,
) -> @git.ObjectId? raise @git.GitError {
  // Try direct rev_parse first
  match rev_parse(fs, git_dir, refspec) {
    Some(id) => Some(id)
    None => {
      // Try as remote ref (e.g., origin/main -> refs/remotes/origin/main)
      let remote_path = git_dir + "/refs/remotes/" + refspec
      let bytes = fs.read_file(remote_path) catch { _ => return None }
      let hex = bytes_to_string(bytes).trim(chars=" \n\t").to_string()
      let id = @git.ObjectId::from_hex(hex) catch { _ => return None }
      Some(id)
    }
  }
}

///|
fn find_subtree(
  db : ObjectDb,
  rfs : &@git.RepoFileSystem,
  tree_id : @git.ObjectId,
  path : String,
) -> @git.ObjectId? raise @git.GitError {
  let parts : Array[String] = []
  for p in path.split("/") {
    let s = p.to_string()
    if s.length() > 0 {
      parts.push(s)
    }
  }
  let mut current = tree_id
  for part in parts {
    let obj = db.get(rfs, current)
    guard obj is Some(tree_obj) else { return None }
    let entries = @git.parse_tree(tree_obj.data) catch { err => raise err }
    let mut found = false
    for entry in entries {
      if entry.name == part {
        if entry.mode != "40000" && entry.mode != "040000" {
          return None
        }
        current = entry.id
        found = true
        break
      }
    }
    if not(found) {
      return None
    }
  }
  Some(current)
}

///|
pub fn collect_tree_blobs(
  db : ObjectDb,
  rfs : &@git.RepoFileSystem,
  tree_id : @git.ObjectId,
) -> Array[@git.ObjectId] raise @git.GitError {
  let blobs : Array[@git.ObjectId] = []
  let obj = db.get(rfs, tree_id)
  guard obj is Some(tree_obj) else { return blobs }
  let entries = @git.parse_tree(tree_obj.data) catch { err => raise err }
  for entry in entries {
    if entry.mode == "40000" || entry.mode == "040000" {
      let sub_blobs = collect_tree_blobs(db, rfs, entry.id) catch {
        err => raise err
      }
      for b in sub_blobs {
        blobs.push(b)
      }
    } else {
      blobs.push(entry.id)
    }
  }
  blobs
}

///|
pub fn write_tree_to_worktree(
  db : ObjectDb,
  rfs : &@git.RepoFileSystem,
  wfs : &@git.FileSystem,
  tree_id : @git.ObjectId,
  dir : String,
) -> Unit raise @git.GitError {
  let obj = db.get(rfs, tree_id)
  guard obj is Some(tree_obj) else { return }
  let entries = @git.parse_tree(tree_obj.data) catch { err => raise err }
  for entry in entries {
    let path = dir + "/" + entry.name
    if entry.mode == "40000" || entry.mode == "040000" {
      wfs.mkdir_p(path) catch {
        _ => ()
      }
      write_tree_to_worktree(db, rfs, wfs, entry.id, path) catch {
        err => raise err
      }
    } else {
      let blob_obj = db.get(rfs, entry.id)
      guard blob_obj is Some(blob) else { continue }
      wfs.write_file(path, blob.data) catch {
        _ => ()
      }
    }
  }
}

///|
pub fn move_directory(
  rfs : &@git.RepoFileSystem,
  wfs : &@git.FileSystem,
  src : String,
  dst : String,
) -> Unit {
  wfs.mkdir_p(dst) catch {
    _ => ()
  }
  let entries = rfs.readdir(src) catch { _ => return }
  for entry in entries {
    let src_path = src + "/" + entry
    let dst_path = dst + "/" + entry
    if rfs.is_dir(src_path) {
      move_directory(rfs, wfs, src_path, dst_path)
    } else {
      let content = rfs.read_file(src_path) catch { _ => continue }
      wfs.write_file(dst_path, content) catch {
        _ => ()
      }
    }
  }
}

///|
pub fn subdir_remove_dir(
  rfs : &@git.RepoFileSystem,
  wfs : &@git.FileSystem,
  path : String,
) -> Unit {
  let entries = rfs.readdir(path) catch { _ => return }
  for entry in entries {
    let child_path = path + "/" + entry
    if rfs.is_dir(child_path) {
      subdir_remove_dir(rfs, wfs, child_path)
    } else {
      wfs.remove_file(child_path) catch {
        _ => ()
      }
    }
  }
  wfs.remove_dir(path) catch {
    _ => ()
  }
}

///|
fn string_to_bytes(s : String) -> Bytes {
  let bytes : Array[Byte] = []
  for c in s {
    bytes.push(c.to_int().to_byte())
  }
  Bytes::from_array(bytes)
}

///|
fn bytes_to_string(bytes : Bytes) -> String {
  let result = StringBuilder::new()
  for i = 0; i < bytes.length(); i = i + 1 {
    result.write_char(bytes[i].to_int().unsafe_to_char())
  }
  result.to_string()
}

///|
fn decode_bytes(data : Bytes) -> String {
  bytes_to_string(data)
}

///|
fn trim_string(s : String) -> String {
  let mut start = 0
  let mut end = s.length()
  while start < end {
    let c = s.unsafe_get(start)
    if c == ' ' || c == '\t' || c == '\n' || c == '\r' {
      start += 1
    } else {
      break
    }
  }
  while end > start {
    let c = s.unsafe_get(end - 1)
    if c == ' ' || c == '\t' || c == '\n' || c == '\r' {
      end -= 1
    } else {
      break
    }
  }
  if start == 0 && end == s.length() {
    s
  } else {
    String::unsafe_substring(s, start~, end~)
  }
}

///|
fn read_remote_url_from_config(
  fs : &@git.RepoFileSystem,
  git_dir : String,
) -> String? {
  let config_path = git_dir + "/config"
  if not(fs.is_file(config_path)) {
    return None
  }
  let config_content = decode_bytes(
    fs.read_file(config_path) catch {
      _ => return None
    },
  )
  let mut in_remote_section = false
  for line_view in config_content.split("\n") {
    let line = trim_string(line_view.to_string())
    if line.has_prefix("[remote ") {
      in_remote_section = true
      continue
    }
    if line.has_prefix("[") {
      in_remote_section = false
      continue
    }
    if in_remote_section && line.has_prefix("url = ") {
      return Some(String::unsafe_substring(line, start=6, end=line.length()))
    }
  }
  None
}

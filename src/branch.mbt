///| Git branch listing (refs/heads + packed-refs)

///|
pub enum HeadRef {
  Branch(String)
  Detached(ObjectId)
}

///|
pub struct BranchInfo {
  name : String
  id : ObjectId
  current : Bool
}

///|
/// Read HEAD and return its reference.
pub fn read_head_ref(
  fs : &RepoFileSystem,
  git_dir : String,
) -> HeadRef raise GitError {
  let head_path = join_path(git_dir, "HEAD")
  let line = read_ref_line(fs, head_path)
  if line.has_prefix("ref: ") {
    let refname = String::unsafe_substring(line, start=5, end=line.length())
    let name = if refname.has_prefix("refs/heads/") {
      String::unsafe_substring(refname, start=11, end=refname.length())
    } else {
      refname
    }
    HeadRef::Branch(name)
  } else {
    let id = ObjectId::from_hex(line)
    HeadRef::Detached(id)
  }
}

///|
/// List local branches with current flag.
pub fn list_branches(
  fs : &RepoFileSystem,
  git_dir : String,
) -> (HeadRef, Array[BranchInfo]) raise GitError {
  let head = read_head_ref(fs, git_dir)
  let map : Map[String, ObjectId] = {}
  let heads_dir = join_path(git_dir, "refs/heads")
  if fs.is_dir(heads_dir) {
    collect_loose_heads(fs, heads_dir, "", map)
  }
  let packed_path = join_path(git_dir, "packed-refs")
  if fs.is_file(packed_path) {
    collect_packed_heads(fs, packed_path, map)
  }
  let branches : Array[BranchInfo] = []
  for item in map.to_array() {
    let (name, id) = item
    let current = match head {
      Branch(n) => n == name
      Detached(_) => false
    }
    branches.push({ name, id, current })
  }
  branches.sort_by(fn(a, b) { String::compare(a.name, b.name) })
  (head, branches)
}

///|
/// Format like `git branch` output.
pub fn list_branches_text(
  fs : &RepoFileSystem,
  git_dir : String,
) -> Array[String] raise GitError {
  let (head, branches) = list_branches(fs, git_dir)
  let lines : Array[String] = []
  match head {
    Detached(id) => {
      let short = shorten_hex(id.to_hex(), 7)
      lines.push("* (HEAD detached at \{short})")
    }
    Branch(_) => ()
  }
  for b in branches {
    let mark = if b.current { "*" } else { " " }
    lines.push("\{mark} \{b.name}")
  }
  lines
}

///|
/// Create a local branch pointing at current HEAD.
pub fn create_branch(
  fs : &FileSystem,
  rfs : &RepoFileSystem,
  root : String,
  name : String,
) -> Unit raise GitError {
  let git_dir = join_path(root, ".git")
  let refname = branch_ref_name(name)
  let ref_path = join_path(git_dir, refname)
  let dir = parent_dir(ref_path)
  fs.mkdir_p(dir)
  let head = resolve_head_commit(rfs, git_dir)
  match head {
    None => fs.write_string(ref_path, "")
    Some(id) => fs.write_string(ref_path, id.to_hex() + "\n")
  }
}

///|
/// Switch HEAD to a branch, optionally creating it and checking out files.
pub fn switch_branch(
  fs : &FileSystem,
  rfs : &RepoFileSystem,
  root : String,
  name : String,
  create? : Bool = false,
  checkout? : Bool = true,
) -> Unit raise GitError {
  let git_dir = join_path(root, ".git")
  let refname = branch_ref_name(name)
  let ref_path = join_path(git_dir, refname)
  if create {
    create_branch(fs, rfs, root, name)
  } else if not(rfs.is_file(ref_path)) {
    match resolve_ref(rfs, git_dir, refname) {
      None => raise GitError::InvalidObject("Invalid ref: \{name}")
      Some(_) => ()
    }
  }
  let head_path = join_path(git_dir, "HEAD")
  fs.write_string(head_path, "ref: \{refname}\n")
  if checkout {
    match resolve_ref(rfs, git_dir, refname) {
      None => ()
      Some(id) => {
        let store = load_object_store_from_fs(rfs, git_dir)
        checkout_commit_to_fs(store, id, fs, root)
      }
    }
  }
}

///|
/// Resolve a ref to an object id.
pub fn resolve_ref(
  fs : &RepoFileSystem,
  git_dir : String,
  refname : String,
) -> ObjectId? raise GitError {
  let path = join_path(git_dir, refname)
  if fs.is_file(path) {
    let line = read_ref_line(fs, path)
    return Some(ObjectId::from_hex(line))
  }
  let packed = join_path(git_dir, "packed-refs")
  if fs.is_file(packed) {
    return resolve_packed_ref(fs, packed, refname)
  }
  None
}

///|
fn collect_loose_heads(
  fs : &RepoFileSystem,
  dir : String,
  prefix : String,
  out : Map[String, ObjectId],
) -> Unit raise GitError {
  let entries = fs.readdir(dir)
  for name in entries {
    let path = join_path(dir, name)
    let rel = if prefix == "" { name } else { prefix + "/" + name }
    if fs.is_dir(path) {
      collect_loose_heads(fs, path, rel, out)
    } else if fs.is_file(path) {
      let line = read_ref_line(fs, path)
      let id = ObjectId::from_hex(line)
      out[rel] = id
    }
  }
}

///|
fn collect_packed_heads(
  fs : &RepoFileSystem,
  packed_path : String,
  out : Map[String, ObjectId],
) -> Unit raise GitError {
  let text = @utf8.decode_lossy(fs.read_file(packed_path)[:])
  for line_view in text.split("\n") {
    let line = trim_line(line_view.to_string())
    if line.length() == 0 {
      continue
    }
    if line.has_prefix("#") || line.has_prefix("^") {
      continue
    }
    let space = line.find(" ")
    match space {
      None => continue
      Some(idx) => {
        if idx + 1 >= line.length() {
          continue
        }
        let id_hex = String::unsafe_substring(line, start=0, end=idx)
        let refname = String::unsafe_substring(
          line,
          start=idx + 1,
          end=line.length(),
        )
        if not(refname.has_prefix("refs/heads/")) {
          continue
        }
        let name = String::unsafe_substring(
          refname,
          start=11,
          end=refname.length(),
        )
        if not(out.contains(name)) {
          out[name] = ObjectId::from_hex(id_hex)
        }
      }
    }
  }
}

///|
fn branch_ref_name(name : String) -> String {
  if name.has_prefix("refs/heads/") {
    name
  } else {
    "refs/heads/" + name
  }
}

///|
fn resolve_packed_ref(
  fs : &RepoFileSystem,
  packed_path : String,
  refname : String,
) -> ObjectId? raise GitError {
  let text = @utf8.decode_lossy(fs.read_file(packed_path)[:])
  for line_view in text.split("\n") {
    let line = trim_line(line_view.to_string())
    if line.length() == 0 {
      continue
    }
    if line.has_prefix("#") || line.has_prefix("^") {
      continue
    }
    let space = line.find(" ")
    match space {
      None => continue
      Some(idx) => {
        if idx + 1 >= line.length() {
          continue
        }
        let id_hex = String::unsafe_substring(line, start=0, end=idx)
        let name = String::unsafe_substring(
          line,
          start=idx + 1,
          end=line.length(),
        )
        if name == refname {
          return Some(ObjectId::from_hex(id_hex))
        }
      }
    }
  }
  None
}

///|
fn read_ref_line(fs : &RepoFileSystem, path : String) -> String raise GitError {
  let text = @utf8.decode_lossy(fs.read_file(path)[:])
  for line_view in text.split("\n") {
    let line = trim_line(line_view.to_string())
    if line.length() > 0 {
      return line
    }
  }
  raise GitError::InvalidObject("Empty ref: \{path}")
}

///|
fn trim_line(line : String) -> String {
  let mut s = line
  if s.has_suffix("\r") {
    s = String::unsafe_substring(s, start=0, end=s.length() - 1)
  }
  s
}

///|
fn shorten_hex(hex : String, n : Int) -> String {
  if hex.length() <= n {
    hex
  } else {
    String::unsafe_substring(hex, start=0, end=n)
  }
}

///| High-level push/pull over HTTP (async, wasm)

///|
pub async fn pull_http(
  fs : &FileSystem,
  rfs : &RepoFileSystem,
  root : String,
  remote : String,
  prefer_v2 : Bool,
  rebase? : Bool = false,
) -> ObjectId? raise GitError {
  let (refs, _caps, _version, symrefs) = discover_upload_refs_http(
    remote, prefer_v2,
  )
  let default_ref = select_default_ref(refs, symrefs)
  match default_ref {
    None => return None
    Some((refname, commit_id)) => {
      let pack = fetch_pack_http(remote, [commit_id], prefer_v2)
      let objects = parse_packfile(pack)
      let git_dir = join_path(root, ".git")
      write_packfile_with_index(fs, git_dir, pack, objects)
      // update remote tracking ref
      let remote_ref = sync_remote_refname(refname)
      let remote_path = join_path(git_dir, remote_ref)
      let dir = sync_parent_dir(remote_path)
      fs.mkdir_p(dir)
      fs.write_string(remote_path, commit_id.to_hex() + "\n")
      if rebase {
        let _ = rebase_onto(fs, rfs, root, commit_id)

      } else {
        let head = resolve_head_commit(rfs, git_dir)
        match head {
          None => fast_forward_to(fs, rfs, root, commit_id)
          Some(h) =>
            if sync_is_ancestor(rfs, git_dir, h, commit_id) {
              fast_forward_to(fs, rfs, root, commit_id)
            } else {
              raise GitError::InvalidObject("Non-fast-forward pull")
            }
        }
      }
      Some(commit_id)
    }
  }
}

///|
pub async fn push_http(
  rfs : &RepoFileSystem,
  root : String,
  remote_url : String,
  refname : String,
) -> String raise GitError {
  let git_dir = join_path(root, ".git")
  let head = resolve_head_commit(rfs, git_dir)
  match head {
    None => raise GitError::InvalidObject("HEAD not found")
    Some(head_id) => {
      let db = ObjectDb::load(rfs, git_dir)
      let objects = collect_reachable_objects(db, rfs, head_id)
      let pack = create_packfile(objects)
      let remote = Remote::new(remote_url)
      let refs = discover_receive_refs_http(remote)
      let old_id = sync_find_ref(refs, refname)
      let req = PushRequest::new(old_id, head_id, refname, pack)
      push(remote, req)
    }
  }
}

///|
fn sync_find_ref(refs : Array[(ObjectId, String)], name : String) -> ObjectId {
  for item in refs {
    let (id, refname) = item
    if refname == name {
      return id
    }
  }
  ObjectId::zero()
}

///|
fn sync_is_ancestor(
  fs : &RepoFileSystem,
  git_dir : String,
  base : ObjectId,
  target : ObjectId,
) -> Bool raise GitError {
  let db = ObjectDb::load(fs, git_dir)
  let mut current = target
  while true {
    if current == base {
      return true
    }
    let obj = db.get(fs, current)
    match obj {
      None => return false
      Some(o) => {
        if o.obj_type != ObjectType::Commit {
          return false
        }
        let info = parse_commit(o.data)
        if info.parents.length() == 0 {
          return false
        }
        current = info.parents[0]
      }
    }
  }
  false
}

///|
fn sync_remote_refname(refname : String) -> String {
  if refname.has_prefix("refs/heads/") {
    let name = String::unsafe_substring(refname, start=11, end=refname.length())
    "refs/remotes/origin/" + name
  } else if refname == "HEAD" {
    "refs/remotes/origin/HEAD"
  } else {
    "refs/remotes/origin/" + refname
  }
}

///|
fn sync_parent_dir(path : String) -> String {
  match path.rev_find("/") {
    None => "/"
    Some(0) => "/"
    Some(i) => String::unsafe_substring(path, start=0, end=i)
  }
}

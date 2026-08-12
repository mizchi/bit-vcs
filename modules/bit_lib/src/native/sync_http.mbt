///| High-level push/pull over HTTP (async, native-only)

///|
/// Clone a remote repository via HTTP.
pub async fn clone_http(
  fs : &@bit.FileSystem,
  rfs : &@bit.RepoFileSystem,
  remote_url : String,
  dest : String,
  prefer_v2 : Bool,
) -> @bit.ObjectId? raise @bit.GitError {
  // 1. Create destination directory and init
  fs.mkdir_p(dest)
  @bitlib.init_repo(fs, dest)
  // 2. Save remote URL
  let git_dir = sync_join_path(dest, ".git")
  let config_path = sync_join_path(git_dir, "config")
  let config_content = "[core]\n\trepositoryformatversion = 0\n\tfilemode = true\n\tbare = false\n[remote \"origin\"]\n\turl = \{remote_url}\n\tfetch = +refs/heads/*:refs/remotes/origin/*\n"
  fs.write_string(config_path, config_content)
  // 3. Fetch refs and packfile
  let (refs, _caps, _version, symrefs) = @bitnative.discover_upload_refs_http(
    remote_url, prefer_v2,
  )
  let default_ref = @protocol.select_default_ref(refs, symrefs)
  match default_ref {
    None => return None
    Some((refname, commit_id)) => {
      let pack = @bitnative.fetch_pack_http(remote_url, [commit_id], prefer_v2)
      let objects = @pack.parse_packfile(pack)
      @pack.write_packfile_with_index(fs, git_dir, pack, objects)
      // 4. Update refs
      // Set HEAD to point to default branch
      let branch_name = if refname.has_prefix("refs/heads/") {
        String::unsafe_substring(refname, start=11, end=refname.length())
      } else {
        "main"
      }
      let head_path = sync_join_path(git_dir, "HEAD")
      fs.write_string(head_path, "ref: refs/heads/\{branch_name}\n")
      // Create local branch
      let branch_ref_path = sync_join_path(git_dir, "refs/heads/\{branch_name}")
      let branch_dir = sync_parent_dir(branch_ref_path)
      fs.mkdir_p(branch_dir)
      fs.write_string(branch_ref_path, commit_id.to_hex() + "\n")
      // Create remote tracking ref
      let remote_ref = sync_remote_refname(refname)
      let remote_path = sync_join_path(git_dir, remote_ref)
      let remote_dir = sync_parent_dir(remote_path)
      fs.mkdir_p(remote_dir)
      fs.write_string(remote_path, commit_id.to_hex() + "\n")
      // 5. Checkout working tree
      @bitlib.fast_forward_to(fs, rfs, dest, commit_id)
      Some(commit_id)
    }
  }
}

///|
pub async fn pull_http(
  fs : &@bit.FileSystem,
  rfs : &@bit.RepoFileSystem,
  root : String,
  remote : String,
  prefer_v2 : Bool,
  rebase? : Bool = false,
) -> @bit.ObjectId? raise @bit.GitError {
  let git_dir = sync_join_path(root, ".git")
  // Repository access is synchronous by contract, so collect local
  // negotiation state before starting the asynchronous network exchange.
  let local_head = @bitlib.resolve_head_commit(rfs, git_dir)
  let shallow = @repo.read_shallow_boundaries(rfs, git_dir)
  let (refs, _caps, _version, symrefs) = @bitnative.discover_upload_refs_http(
    remote, prefer_v2,
  )
  let default_ref = @protocol.select_default_ref(refs, symrefs)
  match default_ref {
    None => return None
    Some((refname, commit_id)) => {
      let remote_ref = sync_remote_refname(refname)
      let haves = match @bitlib.resolve_ref(rfs, git_dir, remote_ref) {
        Some(id) => [id]
        None =>
          match local_head {
            Some(id) => [id]
            None => []
          }
      }
      let pack = @bitnative.fetch_pack_http(
        remote,
        [commit_id],
        prefer_v2,
        haves~,
        shallow~,
      )
      let objects = @pack.parse_packfile(pack)
      @pack.write_packfile_with_index(fs, git_dir, pack, objects)
      // update remote tracking ref
      let remote_path = sync_join_path(git_dir, remote_ref)
      let dir = sync_parent_dir(remote_path)
      fs.mkdir_p(dir)
      fs.write_string(remote_path, commit_id.to_hex() + "\n")
      if rebase {
        let _ = @bitlib.rebase_onto(fs, rfs, root, commit_id)
      } else {
        let head = @bitlib.resolve_head_commit(rfs, git_dir)
        match head {
          None => @bitlib.fast_forward_to(fs, rfs, root, commit_id)
          Some(h) =>
            if sync_is_ancestor(rfs, git_dir, h, commit_id) {
              @bitlib.fast_forward_to(fs, rfs, root, commit_id)
            } else {
              raise @bit.GitError::InvalidObject("Non-fast-forward pull")
            }
        }
      }
      Some(commit_id)
    }
  }
}

///|
pub async fn push_http(
  rfs : &@bit.RepoFileSystem,
  root : String,
  remote_url : String,
  refname : String,
  remote_name? : String = "",
  force? : Bool = false,
) -> String raise @bit.GitError {
  let git_dir = sync_join_path(root, ".git")
  let actual_git_dir = if rfs.is_file(git_dir) {
    @bitlib.resolve_gitdir(rfs, git_dir)
  } else {
    git_dir
  }
  let head = @bitlib.resolve_head_commit(rfs, actual_git_dir)
  match head {
    None => raise @bit.GitError::InvalidObject("HEAD not found")
    Some(head_id) => {
      // Discover first so object collection can exclude everything the
      // receiver already advertises. Building a full-history pack before
      // negotiation can retain many gigabytes for a one-commit push.
      let remote = @protocol.Remote::new(remote_url)
      let refs = @bitnative.discover_receive_refs_http(remote)
      let old_id = sync_find_ref(refs, refname)
      if old_id == head_id {
        return "Everything up-to-date"
      }
      // Check fast-forward unless force
      if !force && old_id != @bit.ObjectId::zero() {
        if !sync_is_ancestor(rfs, actual_git_dir, old_id, head_id) {
          raise @bit.GitError::InvalidObject(
            "Updates were rejected because the tip of your current branch is behind\nits remote counterpart. If you want to force the update, use 'git push --force'.",
          )
        }
      }
      let db = @bitlib.ObjectDb::load(rfs, actual_git_dir)
      let objects = @bitlib.collect_reachable_objects_excluding_commits(
        db,
        rfs,
        [head_id],
        sync_remote_have_ids(refs),
      )
      let pack = @pack.create_packfile(objects)
      sync_raise_lfs_upload_errors(
        lfs_upload_pack_objects(
          rfs,
          actual_git_dir,
          remote_url,
          objects,
          remote_name~,
        ),
      )
      let req = @protocol.PushRequest::new(old_id, head_id, refname, pack)
      @bitnative.push(remote, req)
    }
  }
}

///|
/// Push from a specific commit (not HEAD) - used for subdir-clone push
pub async fn push_http_from_commit(
  rfs : &@bit.RepoFileSystem,
  root : String,
  remote_url : String,
  commit_id : @bit.ObjectId,
  refname : String,
) -> String raise @bit.GitError {
  let git_dir = sync_join_path(root, ".git")
  let actual_git_dir = if rfs.is_file(git_dir) {
    @bitlib.resolve_gitdir(rfs, git_dir)
  } else {
    git_dir
  }
  let remote = @protocol.Remote::new(remote_url)
  let refs = @bitnative.discover_receive_refs_http(remote)
  let old_id = sync_find_ref(refs, refname)
  if old_id == commit_id {
    return "Everything up-to-date"
  }
  let db = @bitlib.ObjectDb::load(rfs, actual_git_dir)
  let objects = @bitlib.collect_reachable_objects_excluding_commits(
    db,
    rfs,
    [commit_id],
    sync_remote_have_ids(refs),
  )
  let pack = @pack.create_packfile(objects)
  sync_raise_lfs_upload_errors(
    lfs_upload_pack_objects(rfs, actual_git_dir, remote_url, objects),
  )
  let req = @protocol.PushRequest::new(old_id, commit_id, refname, pack)
  @bitnative.push(remote, req)
}

///|
/// Push a single commit without parent history - used for subdir-clone push
/// where parent commits already exist on remote.
/// Only includes objects that don't exist in the base commit.
pub async fn push_http_tree_only(
  rfs : &@bit.RepoFileSystem,
  root : String,
  remote_url : String,
  commit_id : @bit.ObjectId,
  old_commit_id : @bit.ObjectId,
  refname : String,
) -> String raise @bit.GitError {
  let git_dir = sync_join_path(root, ".git")
  let actual_git_dir = if rfs.is_file(git_dir) {
    @bitlib.resolve_gitdir(rfs, git_dir)
  } else {
    git_dir
  }
  let db = @bitlib.ObjectDb::load(rfs, actual_git_dir)
  // Collect only the diff objects (new/modified since base)
  let objects = @bitlib.collect_diff_objects(db, rfs, old_commit_id, commit_id)
  let pack = @pack.create_packfile(objects)
  sync_raise_lfs_upload_errors(
    lfs_upload_pack_objects(rfs, actual_git_dir, remote_url, objects),
  )
  let remote = @protocol.Remote::new(remote_url)
  let req = @protocol.PushRequest::new(old_commit_id, commit_id, refname, pack)
  @bitnative.push(remote, req)
}

///|
fn sync_raise_lfs_upload_errors(
  errors : Array[LfsUploadError],
) -> Unit raise @bit.GitError {
  if errors.length() == 0 {
    return
  }
  let err = errors[0]
  raise @bit.GitError::InvalidObject(
    "LFS upload failed for \{err.oid}: \{err.message}",
  )
}

///|
fn sync_find_ref(
  refs : Array[(@bit.ObjectId, String)],
  name : String,
) -> @bit.ObjectId {
  for item in refs {
    let (id, refname) = item
    if refname == name {
      return id
    }
  }
  @bit.ObjectId::zero()
}

///|
fn sync_remote_have_ids(
  refs : Array[(@bit.ObjectId, String)],
) -> Array[@bit.ObjectId] {
  let zero = @bit.ObjectId::zero()
  let seen : Map[String, Bool] = Map([])
  let haves : Array[@bit.ObjectId] = []
  for item in refs {
    let (id, _) = item
    let hex = id.to_hex()
    if id != zero && !seen.contains(hex) {
      seen[hex] = true
      haves.push(id)
    }
  }
  haves
}

///|
test "sync_remote_have_ids removes zero and duplicate refs" {
  let first = @bit.ObjectId::from_hex(
    "1111111111111111111111111111111111111111",
  )
  let second = @bit.ObjectId::from_hex(
    "2222222222222222222222222222222222222222",
  )
  let haves = sync_remote_have_ids([
    (first, "HEAD"),
    (first, "refs/heads/main"),
    (@bit.ObjectId::zero(), "refs/heads/unborn"),
    (second, "refs/heads/topic"),
  ])
  assert_eq(haves, [first, second])
}

///|
fn sync_is_ancestor(
  fs : &@bit.RepoFileSystem,
  git_dir : String,
  base : @bit.ObjectId,
  target : @bit.ObjectId,
) -> Bool raise @bit.GitError {
  let db = @bitlib.ObjectDb::load(fs, git_dir)
  let mut current = target
  while true {
    if current == base {
      return true
    }
    let obj = db.get(fs, current)
    match obj {
      None => return false
      Some(o) => {
        if o.obj_type != @bit.ObjectType::Commit {
          return false
        }
        let info = @bit.parse_commit(o.data)
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
fn sync_remote_refname(refname : String) -> String raise @bit.GitError {
  let normalized = @bitlib.normalize_repo_path(refname) catch {
    _ => raise @bit.GitError::InvalidObject("invalid refname: " + refname)
  }
  if normalized == "HEAD" || normalized.has_prefix("refs/") {
    if normalized.has_prefix("refs/heads/") {
      let name = String::unsafe_substring(
        normalized,
        start=11,
        end=normalized.length(),
      )
      "refs/remotes/origin/" + name
    } else if normalized == "HEAD" {
      "refs/remotes/origin/HEAD"
    } else {
      "refs/remotes/origin/" + normalized
    }
  } else {
    raise @bit.GitError::InvalidObject("invalid refname: " + refname)
  }
}

///|
test "sync_remote_refname normalizes and maps refs/heads" {
  assert_eq(sync_remote_refname("refs/heads/main"), "refs/remotes/origin/main")
  assert_eq(sync_remote_refname("HEAD"), "refs/remotes/origin/HEAD")
  assert_eq(
    sync_remote_refname("refs/tags/v1.0.0"),
    "refs/remotes/origin/refs/tags/v1.0.0",
  )
}

///|
test "sync_remote_refname rejects invalid refname" {
  let _ = sync_remote_refname("main") catch { _ => return () }
  assert_true(false)
}

///|
test "sync_remote_refname rejects traversal-like refname" {
  let _ = sync_remote_refname("refs/heads/../../config") catch {
    _ => return ()
  }
  assert_true(false)
}

///|
fn sync_parent_dir(path : String) -> String {
  match path.rev_find("/") {
    None => "/"
    Some(0) => "/"
    Some(i) => String::unsafe_substring(path, start=0, end=i)
  }
}

///|
fn sync_join_path(root : String, path : String) -> String {
  if root.has_suffix("/") {
    root + path
  } else {
    root + "/" + path
  }
}

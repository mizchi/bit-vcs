///| Checkout implementation

///|
/// Restore files from index to working tree (like `git checkout -- <paths>` or `git restore <paths>`).
pub fn restore_paths(
  fs : &@bit.FileSystem,
  rfs : &@bit.RepoFileSystem,
  root : String,
  paths : Array[String],
) -> Unit raise @bit.GitError {
  let git_dir = join_path(root, ".git")
  let actual_git_dir = if rfs.is_file(git_dir) {
    resolve_gitdir(rfs, git_dir)
  } else {
    git_dir
  }
  let object_git_dir = resolve_checkout_common_git_dir(rfs, actual_git_dir)
  let index_entries = read_index_entries(rfs, actual_git_dir)
  let index_map : Map[String, IndexEntry] = {}
  for e in index_entries {
    let safe_path = normalize_checkout_path(e.path)
    index_map[safe_path] = e
  }
  let db = ObjectDb::load(rfs, object_git_dir)
  for path in paths {
    let safe_path = normalize_checkout_path(path)
    match index_map.get(safe_path) {
      None =>
        raise @bit.GitError::InvalidObject(
          "error: pathspec '\{path}' did not match any file(s) known to git",
        )
      Some(entry) => {
        let obj = db.get(rfs, entry.id)
        match obj {
          None =>
            raise @bit.GitError::InvalidObject(
              "Object not found: \{entry.id.to_hex()}",
            )
          Some(o) => {
            let abs_path = join_path(root, safe_path)
            let dir = parent_dir(abs_path)
            if dir.length() > 0 && dir != root {
              fs.mkdir_p(dir)
            }
            fs.write_file(abs_path, o.data)
          }
        }
      }
    }
  }
}

///|
fn normalize_checkout_path(path : String) -> String raise @bit.GitError {
  if path.has_prefix("/") {
    raise @bit.GitError::InvalidObject("path must not be absolute")
  }
  normalize_repo_path(path)
}

///|
pub fn checkout(
  fs : &@bit.FileSystem,
  rfs : &@bit.RepoFileSystem,
  root : String,
  spec : String,
  detach? : Bool = false,
  update_worktree? : Bool = true,
  update_index? : Bool = true,
) -> @bit.ObjectId raise @bit.GitError {
  let git_dir = join_path(root, ".git")
  let actual_git_dir = if rfs.is_file(git_dir) {
    resolve_gitdir(rfs, git_dir)
  } else {
    git_dir
  }
  let object_git_dir = resolve_checkout_common_git_dir(rfs, actual_git_dir)
  let head_path = join_path(actual_git_dir, "HEAD")
  let mut target : @bit.ObjectId? = None
  let mut refname : String? = None
  if not(detach) {
    let name = if spec.has_prefix("refs/") {
      spec
    } else {
      "refs/heads/" + spec
    }
    match resolve_ref(rfs, actual_git_dir, name) {
      Some(id) => {
        target = Some(id)
        refname = Some(name)
      }
      None =>
        if not(spec.has_prefix("refs/")) {
          let remote_ref = "refs/remotes/origin/" + spec
          match resolve_ref(rfs, actual_git_dir, remote_ref) {
            Some(id) => {
              let local_ref = "refs/heads/" + spec
              let ref_path = join_path(actual_git_dir, local_ref)
              let dir = parent_dir(ref_path)
              if dir.length() > 0 {
                fs.mkdir_p(dir)
              }
              fs.write_string(ref_path, id.to_hex() + "\n")
              set_config_key(
                fs, rfs, actual_git_dir, "branch", spec, "remote", "origin",
              )
              set_config_key(
                fs,
                rfs,
                actual_git_dir,
                "branch",
                spec,
                "merge",
                "refs/heads/" + spec,
              )
              target = Some(id)
              refname = Some(local_ref)
            }
            None => ()
          }
        }
    }
  }
  match target {
    None => {
      let resolved = rev_parse(rfs, actual_git_dir, spec)
      match resolved {
        None => raise @bit.GitError::InvalidObject("Invalid ref: \{spec}")
        Some(id) => {
          let peeled_commit = rev_parse(rfs, actual_git_dir, spec + "^{commit}")
          target = Some(peeled_commit.unwrap_or(id))
        }
      }
    }
    Some(_) => ()
  }
  let commit_id = match target {
    None => raise @bit.GitError::InvalidObject("Invalid ref: \{spec}")
    Some(id) => id
  }
  if refname is Some(name) {
    fs.write_string(head_path, "ref: \{name}\n")
  } else {
    fs.write_string(head_path, commit_id.to_hex() + "\n")
  }
  if update_worktree || update_index {
    let db = ObjectDb::load_lazy(rfs, object_git_dir)
    db.set_skip_verify(true)
    let files = collect_tree_files_from_commit(db, rfs, commit_id)
    if update_worktree && update_index {
      // Combined path: read each blob only once
      let entries = write_worktree_and_build_index(
        db,
        fs,
        rfs,
        root,
        actual_git_dir,
        files,
        remove_missing=true,
      )
      write_index_entries(fs, actual_git_dir, entries)
    } else if update_worktree {
      write_worktree_from_files(
        db,
        fs,
        rfs,
        root,
        actual_git_dir,
        files,
        remove_missing=true,
      )
    } else {
      let entries = tree_files_to_index(db, rfs, files)
      write_index_entries(fs, actual_git_dir, entries)
    }
  }
  commit_id
}

///|
fn resolve_checkout_common_git_dir(
  fs : &@bit.RepoFileSystem,
  git_dir : String,
) -> String {
  let commondir_path = join_path(git_dir, "commondir")
  if not(fs.is_file(commondir_path)) {
    return git_dir
  }
  let raw = @utf8.decode_lossy(
    (fs.read_file(commondir_path) catch { _ => Bytes::default() })[:],
  )
  let rel = trim_string(raw)
  if rel.length() == 0 {
    return git_dir
  }
  if rel.has_prefix("/") {
    normalize_path(rel)
  } else {
    normalize_path(join_path(git_dir, rel))
  }
}

///| Collect reachable objects for pack generation

///|
pub fn collect_reachable_objects(
  db : ObjectDb,
  fs : &RepoFileSystem,
  commit_id : ObjectId,
) -> Array[PackObject] raise GitError {
  let seen : Map[String, Bool] = {}
  let out : Array[PackObject] = []
  collect_commit_objects(db, fs, commit_id, seen, out)
  out
}

///|
/// Collect reachable objects from multiple commits (deduplicated).
pub fn collect_reachable_objects_from_commits(
  db : ObjectDb,
  fs : &RepoFileSystem,
  commits : Array[ObjectId],
) -> Array[PackObject] raise GitError {
  let seen : Map[String, Bool] = {}
  let out : Array[PackObject] = []
  for commit_id in commits {
    collect_commit_objects(db, fs, commit_id, seen, out)
  }
  out
}

///|
fn collect_commit_objects(
  db : ObjectDb,
  fs : &RepoFileSystem,
  commit_id : ObjectId,
  seen : Map[String, Bool],
  out : Array[PackObject],
) -> Unit raise GitError {
  let hex = commit_id.to_hex()
  if seen.contains(hex) {
    return
  }
  seen[hex] = true
  let obj = db.get(fs, commit_id)
  match obj {
    None => raise GitError::InvalidObject("Missing commit object")
    Some(o) => {
      if o.obj_type != ObjectType::Commit {
        raise GitError::InvalidObject("Object is not a commit")
      }
      out.push(o)
      let info = parse_commit(o.data)
      collect_tree_objects(db, fs, info.tree, seen, out)
      for p in info.parents {
        collect_commit_objects(db, fs, p, seen, out)
      }
    }
  }
}

///|
fn collect_tree_objects(
  db : ObjectDb,
  fs : &RepoFileSystem,
  tree_id : ObjectId,
  seen : Map[String, Bool],
  out : Array[PackObject],
) -> Unit raise GitError {
  let hex = tree_id.to_hex()
  if seen.contains(hex) {
    return
  }
  seen[hex] = true
  let obj = db.get(fs, tree_id)
  match obj {
    None => raise GitError::InvalidObject("Missing tree object")
    Some(o) => {
      if o.obj_type != ObjectType::Tree {
        raise GitError::InvalidObject("Object is not a tree")
      }
      out.push(o)
      let entries = parse_tree(o.data)
      for entry in entries {
        if collect_is_tree_mode(entry.mode) {
          collect_tree_objects(db, fs, entry.id, seen, out)
        } else {
          collect_blob_object(db, fs, entry.id, seen, out)
        }
      }
    }
  }
}

///|
fn collect_blob_object(
  db : ObjectDb,
  fs : &RepoFileSystem,
  blob_id : ObjectId,
  seen : Map[String, Bool],
  out : Array[PackObject],
) -> Unit raise GitError {
  let hex = blob_id.to_hex()
  if seen.contains(hex) {
    return
  }
  seen[hex] = true
  let obj = db.get(fs, blob_id)
  match obj {
    None => raise GitError::InvalidObject("Missing blob object")
    Some(o) => {
      if o.obj_type != ObjectType::Blob {
        raise GitError::InvalidObject("Object is not a blob")
      }
      out.push(o)
    }
  }
}

///|
fn collect_is_tree_mode(mode : String) -> Bool {
  mode == "40000" || mode == "040000"
}

///| Collect reachable objects for pack generation

///|
/// Collect objects for a single commit without walking parent history.
/// Used for subdir-push where parent history already exists on remote.
pub fn collect_commit_tree_only(
  db : ObjectDb,
  fs : &@bit.RepoFileSystem,
  commit_id : @bit.ObjectId,
) -> Array[@bit.PackObject] raise @bit.GitError {
  let seen : Map[String, Bool] = Map([])
  let out : Array[@bit.PackObject] = []
  let hex = commit_id.to_hex()
  seen[hex] = true
  let obj = db.get(fs, commit_id)
  match obj {
    None => raise @bit.GitError::InvalidObject("Missing commit object")
    Some(o) => {
      if o.obj_type != @bit.ObjectType::Commit {
        raise @bit.GitError::InvalidObject("Object is not a commit")
      }
      out.push(o)
      let info = @bit.parse_commit(o.data)
      collect_tree_objects(db, fs, info.tree, seen, out)
      // Do NOT walk parent commits - they already exist on remote
    }
  }
  out
}

///|
/// Collect diff objects between base and new commit.
/// Only collects objects that don't exist in the base tree.
/// Used for subdir-push where base objects already exist on remote.
pub fn collect_diff_objects(
  db : ObjectDb,
  fs : &@bit.RepoFileSystem,
  base_commit : @bit.ObjectId,
  new_commit : @bit.ObjectId,
) -> Array[@bit.PackObject] raise @bit.GitError {
  // First, collect all object IDs reachable from base (without fetching data)
  let base_ids : Map[String, Bool] = Map([])
  collect_object_ids_only(db, fs, base_commit, base_ids)
  // Now collect new commit's objects, skipping those in base_ids
  let out : Array[@bit.PackObject] = []
  collect_new_commit_objects(db, fs, new_commit, base_ids, out)
  out
}

///|
/// Collect object IDs reachable from a commit (without loading full data).
fn collect_object_ids_only(
  db : ObjectDb,
  fs : &@bit.RepoFileSystem,
  commit_id : @bit.ObjectId,
  seen : Map[String, Bool],
) -> Unit raise @bit.GitError {
  let hex = commit_id.to_hex()
  if seen.contains(hex) {
    return
  }
  seen[hex] = true
  let obj = db.get(fs, commit_id)
  match obj {
    None => () // Object might not exist locally - that's ok
    Some(o) =>
      if o.obj_type == @bit.ObjectType::Commit {
        let info = @bit.parse_commit(o.data)
        collect_tree_ids_only(db, fs, info.tree, seen)
        for p in info.parents {
          collect_object_ids_only(db, fs, p, seen)
        }
      }
  }
}

///|
fn collect_tree_ids_only(
  db : ObjectDb,
  fs : &@bit.RepoFileSystem,
  tree_id : @bit.ObjectId,
  seen : Map[String, Bool],
) -> Unit raise @bit.GitError {
  let hex = tree_id.to_hex()
  if seen.contains(hex) {
    return
  }
  seen[hex] = true
  let obj = db.get(fs, tree_id)
  match obj {
    None => () // Object might not exist locally
    Some(o) =>
      if o.obj_type == @bit.ObjectType::Tree {
        let entries = @bit.parse_tree(o.data)
        for entry in entries {
          if collect_is_gitlink_mode(entry.mode) {
            continue // Skip submodule entries
          }
          if collect_is_tree_mode(entry.mode) {
            collect_tree_ids_only(db, fs, entry.id, seen)
          } else {
            seen[entry.id.to_hex()] = true
          }
        }
      }
  }
}

///|
/// Collect objects from a commit, but only those NOT in the base_ids set.
fn collect_new_commit_objects(
  db : ObjectDb,
  fs : &@bit.RepoFileSystem,
  commit_id : @bit.ObjectId,
  base_ids : Map[String, Bool],
  out : Array[@bit.PackObject],
) -> Unit raise @bit.GitError {
  let hex = commit_id.to_hex()
  if base_ids.contains(hex) {
    return
  }
  let obj = db.get(fs, commit_id)
  match obj {
    None => raise @bit.GitError::InvalidObject("Missing commit object")
    Some(o) => {
      if o.obj_type != @bit.ObjectType::Commit {
        raise @bit.GitError::InvalidObject("Object is not a commit")
      }
      out.push(o)
      let info = @bit.parse_commit(o.data)
      collect_new_tree_objects(db, fs, info.tree, base_ids, out)
      // Do NOT walk parent commits - they're in base_ids
    }
  }
}

///|
fn collect_new_tree_objects(
  db : ObjectDb,
  fs : &@bit.RepoFileSystem,
  tree_id : @bit.ObjectId,
  base_ids : Map[String, Bool],
  out : Array[@bit.PackObject],
) -> Unit raise @bit.GitError {
  let hex = tree_id.to_hex()
  if base_ids.contains(hex) {
    return // Skip trees that exist in base
  }
  let obj = db.get(fs, tree_id)
  match obj {
    None => raise @bit.GitError::InvalidObject("Missing tree object: \{hex}")
    Some(o) => {
      if o.obj_type != @bit.ObjectType::Tree {
        raise @bit.GitError::InvalidObject("Object is not a tree")
      }
      out.push(o)
      let entries = @bit.parse_tree(o.data)
      for entry in entries {
        if collect_is_gitlink_mode(entry.mode) {
          continue // Skip submodule entries (commit refs to external repos)
        }
        let entry_hex = entry.id.to_hex()
        if base_ids.contains(entry_hex) {
          continue // Skip objects that exist in base
        }
        if collect_is_tree_mode(entry.mode) {
          collect_new_tree_objects(db, fs, entry.id, base_ids, out)
        } else {
          collect_new_blob_object(db, fs, entry.id, base_ids, out)
        }
      }
    }
  }
}

///|
fn collect_new_blob_object(
  db : ObjectDb,
  fs : &@bit.RepoFileSystem,
  blob_id : @bit.ObjectId,
  base_ids : Map[String, Bool],
  out : Array[@bit.PackObject],
) -> Unit raise @bit.GitError {
  let hex = blob_id.to_hex()
  if base_ids.contains(hex) {
    return // Skip blobs that exist in base
  }
  let obj = db.get(fs, blob_id)
  match obj {
    None => raise @bit.GitError::InvalidObject("Missing blob object: \{hex}")
    Some(o) => {
      if o.obj_type != @bit.ObjectType::Blob {
        raise @bit.GitError::InvalidObject("Object is not a blob")
      }
      out.push(o)
    }
  }
}

///|
pub fn collect_reachable_objects(
  db : ObjectDb,
  fs : &@bit.RepoFileSystem,
  commit_id : @bit.ObjectId,
) -> Array[@bit.PackObject] raise @bit.GitError {
  let seen : Map[String, Bool] = Map([])
  let out : Array[@bit.PackObject] = []
  collect_commit_objects(db, fs, commit_id, seen, out)
  out
}

///|
/// Collect reachable objects from multiple commits (deduplicated).
pub fn collect_reachable_objects_from_commits(
  db : ObjectDb,
  fs : &@bit.RepoFileSystem,
  commits : Array[@bit.ObjectId],
) -> Array[@bit.PackObject] raise @bit.GitError {
  let seen : Map[String, Bool] = Map([])
  let out : Array[@bit.PackObject] = []
  for commit_id in commits {
    collect_commit_objects(db, fs, commit_id, seen, out)
  }
  out
}

///|
/// Collect objects reachable from `commits`, stopping before any commit in
/// `excluded_commits`. This models upload-pack negotiation: a client's have
/// commits delimit the history it already owns, so their trees and ancestors
/// do not need a separate reachability walk.
pub fn collect_reachable_objects_excluding_commits(
  db : ObjectDb,
  fs : &@bit.RepoFileSystem,
  commits : Array[@bit.ObjectId],
  excluded_commits : Array[@bit.ObjectId],
) -> Array[@bit.PackObject] raise @bit.GitError {
  // Mark the complete object closure already owned by the receiver. Merely
  // stopping the commit walk at a have commit is insufficient: the wanted
  // commit's new tree can still reference unchanged blobs from that commit.
  let seen : Map[String, Bool] = Map([])
  for id in excluded_commits {
    collect_object_ids_only(db, fs, id, seen)
  }
  let out : Array[@bit.PackObject] = []
  for commit_id in commits {
    collect_commit_objects(db, fs, commit_id, seen, out)
  }
  out
}

///|
fn collect_commit_objects(
  db : ObjectDb,
  fs : &@bit.RepoFileSystem,
  commit_id : @bit.ObjectId,
  seen : Map[String, Bool],
  out : Array[@bit.PackObject],
) -> Unit raise @bit.GitError {
  let hex = commit_id.to_hex()
  if seen.contains(hex) {
    return
  }
  seen[hex] = true
  let obj = db.get(fs, commit_id)
  match obj {
    None => raise @bit.GitError::InvalidObject("Missing commit object")
    Some(o) => {
      if o.obj_type != @bit.ObjectType::Commit {
        raise @bit.GitError::InvalidObject("Object is not a commit")
      }
      out.push(o)
      let info = @bit.parse_commit(o.data)
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
  fs : &@bit.RepoFileSystem,
  tree_id : @bit.ObjectId,
  seen : Map[String, Bool],
  out : Array[@bit.PackObject],
) -> Unit raise @bit.GitError {
  let hex = tree_id.to_hex()
  if seen.contains(hex) {
    return
  }
  seen[hex] = true
  let obj = db.get(fs, tree_id)
  match obj {
    None => raise @bit.GitError::InvalidObject("Missing tree object")
    Some(o) => {
      if o.obj_type != @bit.ObjectType::Tree {
        raise @bit.GitError::InvalidObject("Object is not a tree")
      }
      out.push(o)
      let entries = @bit.parse_tree(o.data)
      for entry in entries {
        if collect_is_gitlink_mode(entry.mode) {
          continue // Skip submodule entries (commit refs to external repos)
        } else if collect_is_tree_mode(entry.mode) {
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
  fs : &@bit.RepoFileSystem,
  blob_id : @bit.ObjectId,
  seen : Map[String, Bool],
  out : Array[@bit.PackObject],
) -> Unit raise @bit.GitError {
  let hex = blob_id.to_hex()
  if seen.contains(hex) {
    return
  }
  seen[hex] = true
  let obj = db.get(fs, blob_id)
  match obj {
    None => raise @bit.GitError::InvalidObject("Missing blob object: \{hex}")
    Some(o) => {
      if o.obj_type != @bit.ObjectType::Blob {
        raise @bit.GitError::InvalidObject("Object is not a blob")
      }
      out.push(o)
    }
  }
}

///|
fn collect_is_tree_mode(mode : String) -> Bool {
  mode == "40000" || mode == "040000"
}

///|
fn collect_is_gitlink_mode(mode : String) -> Bool {
  mode == "160000"
}

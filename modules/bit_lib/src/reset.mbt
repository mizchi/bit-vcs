///| Reset implementation

///|
pub(all) enum ResetMode {
  Soft
  Mixed
  Hard
}

///|
pub fn reset(
  fs : &@bit.FileSystem,
  rfs : &@bit.RepoFileSystem,
  root : String,
  spec : String,
  mode : ResetMode,
  committer? : String = "unknown <unknown>",
  timestamp? : Int64 = 0L,
  timezone? : String = "+0000",
) -> @bit.ObjectId raise @bit.GitError {
  let git_dir = join_path(root, ".git")
  let actual_git_dir = if rfs.is_file(git_dir) {
    resolve_gitdir(rfs, git_dir)
  } else {
    git_dir
  }
  let object_git_dir = reset_resolve_common_git_dir(rfs, actual_git_dir)
  let target = match rev_parse(rfs, actual_git_dir, spec) {
    None => raise @bit.GitError::InvalidObject("Invalid ref: \{spec}")
    Some(id) => id
  }
  let old_head = resolve_head_commit(rfs, actual_git_dir).unwrap_or(
    @bit.ObjectId::zero(),
  )
  update_head_ref(fs, rfs, actual_git_dir, target)
  append_head_update_reflogs(
    fs,
    rfs,
    actual_git_dir,
    old_head,
    target,
    "reset: moving to " + spec,
    committer~,
    timestamp~,
    timezone~,
  )
  match mode {
    Soft => target
    Mixed => {
      let db = ObjectDb::load(rfs, object_git_dir)
      let tree_id = reset_resolve_target_tree_id(db, rfs, target)
      let files = collect_tree_files_from_commit(db, rfs, target)
      let entries = tree_files_to_index(db, rfs, files)
      write_index_entries_with_tree(fs, rfs, actual_git_dir, entries, tree_id)
      target
    }
    Hard => {
      let db = ObjectDb::load(rfs, object_git_dir)
      let tree_id = reset_resolve_target_tree_id(db, rfs, target)
      let files = collect_tree_files_from_commit(db, rfs, target)
      write_worktree_from_files(
        db,
        fs,
        rfs,
        root,
        actual_git_dir,
        files,
        remove_missing=true,
      )
      let entries = tree_files_to_index(db, rfs, files)
      write_index_entries_with_tree(fs, rfs, actual_git_dir, entries, tree_id)
      target
    }
  }
}

///|
fn reset_resolve_target_tree_id(
  db : ObjectDb,
  fs : &@bit.RepoFileSystem,
  target : @bit.ObjectId,
) -> @bit.ObjectId raise @bit.GitError {
  match db.get(fs, target) {
    Some(obj) if obj.obj_type == @bit.ObjectType::Commit =>
      @bit.parse_commit(obj.data).tree
    Some(_) => raise @bit.GitError::InvalidObject("Object is not a commit")
    None => raise @bit.GitError::InvalidObject("Missing commit object")
  }
}

///|
fn reset_resolve_common_git_dir(
  fs : &@bit.RepoFileSystem,
  git_dir : String,
) -> String {
  let commondir_path = join_path(git_dir, "commondir")
  if !fs.is_file(commondir_path) {
    return git_dir
  }
  let raw = @utf8.decode_lossy(
    (fs.read_file(commondir_path) catch { _ => Default::default() })[:],
  )
  let rel = @string_utils.trim_string(raw)
  if rel.length() == 0 {
    return git_dir
  }
  if rel.has_prefix("/") {
    normalize_path(rel)
  } else {
    normalize_path(join_path(git_dir, rel))
  }
}

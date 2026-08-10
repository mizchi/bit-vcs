///| Merge implementation with content-level 3-way merge

///|
pub enum MergeStatus {
  AlreadyUpToDate
  FastForward
  Merged
  Conflicted
}

///|
pub struct MergeResult {
  status : MergeStatus
  commit_id : @bit.ObjectId?
  conflicts : Array[String]
  /// Conflict type per path: "content", "rename/delete", "rename/add", etc.
  conflict_types : Map[String, String]
}

///|
priv struct MergePreservedGitlink {
  path : String
  backup_path : String
}

///|
fn merge_preserve_removed_gitlinks(
  fs : &@bit.FileSystem,
  rfs : &@bit.RepoFileSystem,
  root : String,
  git_dir : String,
  files : Map[String, TreeFileEntry],
) -> Array[MergePreservedGitlink] raise @bit.GitError {
  let entries = read_index_entries(rfs, git_dir)
  let preserved : Array[MergePreservedGitlink] = []
  let backup_root = ".bit-merge-preserve"
  let mut backup_index = 0
  for entry in entries {
    if files.contains(entry.path) || !is_gitlink_mode_int(entry.mode) {
      continue
    }
    let full_path = join_path(root, entry.path)
    let git_marker = join_path(full_path, ".git")
    if !rfs.is_dir(full_path) {
      continue
    }
    if !(rfs.is_file(git_marker) || rfs.is_dir(git_marker)) {
      continue
    }
    let backup_path = join_path(backup_root, backup_index.to_string())
    let backup_abs = join_path(root, backup_path)
    mv_copy_directory_recursive(fs, rfs, full_path, backup_abs)
    let backup_gitfile = join_path(backup_abs, ".git")
    if rfs.is_file(git_marker) && rfs.is_file(backup_gitfile) {
      mv_rewrite_gitfile_after_directory_move(
        fs, rfs, full_path, backup_abs, backup_gitfile,
      )
    }
    remove_worktree_path_recursive(fs, rfs, full_path)
    preserved.push({ path: entry.path, backup_path })
    backup_index += 1
  }
  preserved
}

///|
fn merge_restore_preserved_gitlinks(
  fs : &@bit.FileSystem,
  rfs : &@bit.RepoFileSystem,
  root : String,
  preserved : Array[MergePreservedGitlink],
) -> Unit raise @bit.GitError {
  for item in preserved {
    let full_path = join_path(root, item.path)
    if rfs.is_dir(full_path) {
      continue
    }
    let backup_abs = join_path(root, item.backup_path)
    if !rfs.is_dir(backup_abs) {
      continue
    }
    mv_copy_directory_recursive(fs, rfs, backup_abs, full_path)
    let backup_gitfile = join_path(backup_abs, ".git")
    let full_gitfile = join_path(full_path, ".git")
    if rfs.is_file(backup_gitfile) && rfs.is_file(full_gitfile) {
      mv_rewrite_gitfile_after_directory_move(
        fs, rfs, backup_abs, full_path, full_gitfile,
      )
    }
    remove_worktree_path_recursive(fs, rfs, backup_abs)
  }
  let backup_root = join_path(root, ".bit-merge-preserve")
  if rfs.is_dir(backup_root) {
    remove_worktree_path_recursive(fs, rfs, backup_root)
  }
}

///|
fn merge_fast_forward(
  fs : &@bit.FileSystem,
  rfs : &@bit.RepoFileSystem,
  root : String,
  git_dir : String,
  target : @bit.ObjectId,
) -> Unit raise @bit.GitError {
  let db = ObjectDb::load(rfs, git_dir)
  let files = collect_tree_files_from_commit(db, rfs, target)
  let preserved = merge_preserve_removed_gitlinks(fs, rfs, root, git_dir, files)
  write_worktree_from_files(
    db,
    fs,
    rfs,
    root,
    git_dir,
    files,
    remove_missing=true,
    preserve_removed_gitlinks=true,
  )
  let entries = tree_files_to_index(db, rfs, files)
  write_index_entries(fs, git_dir, entries)
  update_head_ref(fs, rfs, git_dir, target)
  merge_restore_preserved_gitlinks(fs, rfs, root, preserved)
}

///|
pub fn merge(
  fs : &@bit.FileSystem,
  rfs : &@bit.RepoFileSystem,
  root : String,
  target : @bit.ObjectId,
  message : String,
  author : String,
  timestamp : Int64,
  ours_label? : String = "HEAD",
  theirs_label? : String = "incoming",
) -> MergeResult raise @bit.GitError {
  let git_dir = join_path(root, ".git")
  let head = match resolve_head_commit(rfs, git_dir) {
    None =>
      match read_head_ref(rfs, git_dir) {
        Branch(_) => {
          merge_fast_forward(fs, rfs, root, git_dir, target)
          return {
            status: FastForward,
            commit_id: Some(target),
            conflicts: [],
            conflict_types: Map([]),
          }
        }
        Detached(_) => raise @bit.GitError::InvalidObject("HEAD not found")
      }
    Some(id) => id
  }
  if head == target {
    return {
      status: AlreadyUpToDate,
      commit_id: Some(head),
      conflicts: [],
      conflict_types: Map([]),
    }
  }
  let db = ObjectDb::load(rfs, git_dir)
  if merge_is_ancestor(db, rfs, head, target) {
    merge_fast_forward(fs, rfs, root, git_dir, target)
    return {
      status: FastForward,
      commit_id: Some(target),
      conflicts: [],
      conflict_types: Map([]),
    }
  }
  if merge_is_ancestor(db, rfs, target, head) {
    return {
      status: AlreadyUpToDate,
      commit_id: Some(head),
      conflicts: [],
      conflict_types: Map([]),
    }
  }
  let base = merge_find_base(db, rfs, head, target)
  let base_files = match base {
    None => Map([])
    Some(id) => collect_tree_files_from_commit(db, rfs, id)
  }
  let ours = collect_tree_files_from_commit(db, rfs, head)
  let theirs = collect_tree_files_from_commit(db, rfs, target)
  let file_result = merge_files(base_files, ours, theirs, db, rfs)
  let merged = file_result.merged
  let conflicts = file_result.conflicts
  let all_conflict_types = file_result.conflict_types
  let rename_conflict_stages : Map[String, (TreeFileEntry, TreeFileEntry)] = Map([],
  )
  // Try content-level merge for files modified on both sides
  for candidate in file_result.needs_content_merge {
    let base_content = match candidate.base_id {
      Some(id) => merge_get_blob_text(db, rfs, id)
      None => ""
    }
    let ours_content = merge_get_blob_text(db, rfs, candidate.ours_id)
    let theirs_content = merge_get_blob_text(db, rfs, candidate.theirs_id)
    // Skip binary files
    let ours_data = merge_get_blob_data(db, rfs, candidate.ours_id)
    let theirs_data = merge_get_blob_data(db, rfs, candidate.theirs_id)
    if @diff3.is_binary_content(ours_data) ||
      @diff3.is_binary_content(theirs_data) {
      conflicts.push(candidate.path)
      if !all_conflict_types.contains(candidate.path) {
        all_conflict_types[candidate.path] = "content"
      }
      continue
    }
    let result = @diff3.content_merge(
      base_content,
      ours_content,
      theirs_content,
      @diff3.ContentMergeOptions::default().with_labels(
        ours=ours_label,
        base="",
        theirs=theirs_label,
      ),
    )
    if result.has_conflicts {
      // Write conflict markers to worktree
      let full_path = join_path(root, candidate.path)
      let dir = rebase_parent_dir(full_path)
      fs.mkdir_p(dir)
      fs.write_string(full_path, result.content)
      conflicts.push(candidate.path)
      if !all_conflict_types.contains(candidate.path) {
        all_conflict_types[candidate.path] = "content"
      }
    } else {
      // Clean merge - create new blob
      let content_bytes = @utf8.encode(result.content)
      let (blob_id, compressed) = @bit.create_blob(content_bytes)
      write_object_bytes(fs, git_dir, blob_id, compressed)
      // If this path has a rename/add conflict, store resolved as stage 2
      if all_conflict_types.get(candidate.path).unwrap_or("") == "rename/add" {
        let resolved_entry : TreeFileEntry = {
          id: blob_id,
          mode: candidate.mode,
        }
        // Find theirs' independently added file for stage 3
        let theirs_added = match theirs.get(candidate.path) {
          Some(e) => e
          None => resolved_entry
        }
        rename_conflict_stages[candidate.path] = (resolved_entry, theirs_added)
        // Write conflict markers for worktree
        let ours_text = merge_get_blob_text(db, rfs, blob_id)
        let theirs_text = match theirs.get(candidate.path) {
          Some(e) => merge_get_blob_text(db, rfs, e.id)
          None => ""
        }
        let conflict_result = @diff3.content_merge(
          "",
          ours_text,
          theirs_text,
          @diff3.ContentMergeOptions::default().with_labels(
            ours=ours_label,
            base="",
            theirs=theirs_label,
          ),
        )
        let full_path = join_path(root, candidate.path)
        let dir = rebase_parent_dir(full_path)
        fs.mkdir_p(dir)
        fs.write_string(full_path, conflict_result.content)
      } else {
        merged[candidate.path] = { id: blob_id, mode: candidate.mode }
      }
    }
  }
  // Handle rename/rename(2to1) conflicts
  for candidate in file_result.rename_2to1 {
    // Resolve ours side: merge(base[ours_old], ours[path], theirs[ours_old])
    let ours_base_id = base_files
      .get(candidate.ours_old_path)
      .map(fn(e) { e.id })
    let ours_at_path = ours.get(candidate.path)
    let theirs_at_ours_old = theirs.get(candidate.ours_old_path)
    let ours_resolved = merge_resolve_rename_content(
      db, rfs, fs, git_dir, ours_base_id, ours_at_path, theirs_at_ours_old,
    )
    // Resolve theirs side: merge(base[theirs_old], ours[theirs_old], theirs[path])
    let theirs_base_id = base_files
      .get(candidate.theirs_old_path)
      .map(fn(e) { e.id })
    let ours_at_theirs_old = ours.get(candidate.theirs_old_path)
    let theirs_at_path = theirs.get(candidate.path)
    let theirs_resolved = merge_resolve_rename_content(
      db, rfs, fs, git_dir, theirs_base_id, ours_at_theirs_old, theirs_at_path,
    )
    // Now merge the two resolved versions
    let ours_text = match ours_resolved {
      Some((id, _)) => merge_get_blob_text(db, rfs, id)
      None =>
        match ours_at_path {
          Some(e) => merge_get_blob_text(db, rfs, e.id)
          None => ""
        }
    }
    let theirs_text = match theirs_resolved {
      Some((id, _)) => merge_get_blob_text(db, rfs, id)
      None =>
        match theirs_at_path {
          Some(e) => merge_get_blob_text(db, rfs, e.id)
          None => ""
        }
    }
    let ours_blob_id = match ours_resolved {
      Some((id, _)) => id
      None =>
        match ours_at_path {
          Some(e) => e.id
          None => @bit.ObjectId::zero()
        }
    }
    let theirs_blob_id = match theirs_resolved {
      Some((id, _)) => id
      None =>
        match theirs_at_path {
          Some(e) => e.id
          None => @bit.ObjectId::zero()
        }
    }
    if ours_blob_id == theirs_blob_id {
      // Same resolved content - no conflict
      merged[candidate.path] = { id: ours_blob_id, mode: candidate.mode }
    } else {
      // Different content - final merge with conflict markers
      // Use common prefix lines as base so shared content stays outside markers
      let common_base = merge_common_line_prefix(ours_text, theirs_text)
      let final_result = @diff3.content_merge(
        common_base,
        ours_text,
        theirs_text,
        @diff3.ContentMergeOptions::default().with_labels(
          ours=ours_label,
          base="",
          theirs=theirs_label,
        ),
      )
      let full_path = join_path(root, candidate.path)
      let dir = rebase_parent_dir(full_path)
      fs.mkdir_p(dir)
      fs.write_string(full_path, final_result.content)
      conflicts.push(candidate.path)
      all_conflict_types[candidate.path] = "rename/rename"
      // Store stage entries for index
      rename_conflict_stages[candidate.path] = (
        { id: ours_blob_id, mode: candidate.mode },
        { id: theirs_blob_id, mode: candidate.mode },
      )
    }
  }
  // Detect file/directory conflicts: a file path that collides with a directory
  let file_dir_renames : Map[String, String] = Map([])
  let merged_paths : Array[String] = []
  for path, _ in merged {
    merged_paths.push(path)
  }
  for path, _ in merged {
    let prefix = path + "/"
    for other_path in merged_paths {
      if other_path.has_prefix(prefix) {
        let new_path = path + "~HEAD"
        file_dir_renames[path] = new_path
        break
      }
    }
  }
  for old_path, new_path in file_dir_renames {
    match merged.get(old_path) {
      Some(entry) => {
        merged.remove(old_path)
        merged[new_path] = entry
        conflicts.push(new_path)
        all_conflict_types[new_path] = "file/directory"
      }
      None => ()
    }
  }
  if conflicts.length() > 0 {
    write_worktree_from_files(
      db,
      fs,
      rfs,
      root,
      git_dir,
      merged,
      remove_missing=false,
    )
    // Remove worktree files for paths that were renamed away
    for path in file_result.removed_paths {
      let full_path = join_path(root, path)
      if rfs.is_file(full_path) {
        fs.remove_file(full_path) catch {
          _ => ()
        }
      }
    }
    let entries = merge_conflicted_index_entries_with_renames(
      db, rfs, base_files, ours, theirs, merged, conflicts, rename_conflict_stages,
    )
    write_index_stage_entries(fs, git_dir, entries)
    fs.write_string(git_dir + "/MERGE_HEAD", target.to_hex() + "\n")
    fs.write_string(git_dir + "/ORIG_HEAD", head.to_hex() + "\n")
    fs.write_string(git_dir + "/MERGE_MSG", message + "\n")
    conflicts.sort()
    return {
      status: Conflicted,
      commit_id: None,
      conflicts,
      conflict_types: all_conflict_types,
    }
  }
  write_worktree_from_files(
    db,
    fs,
    rfs,
    root,
    git_dir,
    merged,
    remove_missing=true,
  )
  let entries = tree_files_to_index(db, rfs, merged)
  write_index_entries(fs, git_dir, entries)
  let tree_id = write_tree_from_index(fs, rfs, git_dir, entries)
  let commit = @bit.Commit::new(
    tree_id,
    [head, target],
    author,
    timestamp,
    "+0000",
    author,
    timestamp,
    "+0000",
    message,
  )
  let (commit_id, compressed) = @bit.create_commit(commit)
  write_object_bytes(fs, git_dir, commit_id, compressed)
  update_head_ref(fs, rfs, git_dir, commit_id)
  {
    status: Merged,
    commit_id: Some(commit_id),
    conflicts: [],
    conflict_types: Map([]),
  }
}

///|
fn merge_tree_file_to_index_entry(
  db : ObjectDb,
  fs : &@bit.RepoFileSystem,
  path : String,
  info : TreeFileEntry,
) -> IndexEntry raise @bit.GitError {
  let files : Map[String, TreeFileEntry] = Map([])
  files[path] = info
  let entries = tree_files_to_index(db, fs, files)
  if entries.length() == 0 {
    raise @bit.GitError::InvalidObject("Missing merge index entry: " + path)
  }
  entries[0]
}

///|
fn merge_is_ancestor(
  db : ObjectDb,
  fs : &@bit.RepoFileSystem,
  ancestor : @bit.ObjectId,
  commit_id : @bit.ObjectId,
) -> Bool raise @bit.GitError {
  merge_base_is_ancestor(db, fs, ancestor, commit_id)
}

///|
fn merge_find_base(
  db : ObjectDb,
  fs : &@bit.RepoFileSystem,
  a : @bit.ObjectId,
  b : @bit.ObjectId,
) -> @bit.ObjectId? raise @bit.GitError {
  let seen : Map[String, Bool] = Map([])
  let stack_a : Array[@bit.ObjectId] = [a]
  while stack_a.length() > 0 {
    let id = match stack_a.pop() {
      None => raise @bit.GitError::InvalidObject("Empty stack")
      Some(v) => v
    }
    let hex = id.to_hex()
    if seen.contains(hex) {
      continue
    }
    seen[hex] = true
    let parents = merge_commit_parents(db, fs, id)
    for p in parents {
      stack_a.push(p)
    }
  }
  let stack_b : Array[@bit.ObjectId] = [b]
  while stack_b.length() > 0 {
    let id = match stack_b.pop() {
      None => raise @bit.GitError::InvalidObject("Empty stack")
      Some(v) => v
    }
    let hex = id.to_hex()
    if seen.contains(hex) {
      return Some(id)
    }
    let parents = merge_commit_parents(db, fs, id)
    for p in parents {
      stack_b.push(p)
    }
  }
  None
}

///|
fn merge_commit_parents(
  db : ObjectDb,
  fs : &@bit.RepoFileSystem,
  commit_id : @bit.ObjectId,
) -> Array[@bit.ObjectId] raise @bit.GitError {
  let obj = db.get(fs, commit_id)
  match obj {
    None => raise @bit.GitError::InvalidObject("Missing commit object")
    Some(o) => {
      if o.obj_type != @bit.ObjectType::Commit {
        raise @bit.GitError::InvalidObject("Object is not a commit")
      }
      let info = @bit.parse_commit(o.data)
      info.parents
    }
  }
}

///|
priv struct MergeFilesResult {
  merged : Map[String, TreeFileEntry]
  conflicts : Array[String]
  needs_content_merge : Array[ContentMergeCandidate]
  rename_2to1 : Array[Rename2to1Candidate]
  /// Conflict type per path (e.g. "rename/delete", "rename/add")
  conflict_types : Map[String, String]
  /// Paths that were renamed away and should be removed from worktree
  removed_paths : Array[String]
}

///|
priv struct ContentMergeCandidate {
  path : String
  base_id : @bit.ObjectId?
  ours_id : @bit.ObjectId
  theirs_id : @bit.ObjectId
  mode : Int
}

///|
/// Two different files both renamed to the same target path.
/// Requires resolving each side's rename/modify first, then merging results.
priv struct Rename2to1Candidate {
  path : String
  ours_old_path : String
  theirs_old_path : String
  mode : Int
}

///|
fn merge_files(
  base : Map[String, TreeFileEntry],
  ours : Map[String, TreeFileEntry],
  theirs : Map[String, TreeFileEntry],
  db : ObjectDb,
  rfs : &@bit.RepoFileSystem,
) -> MergeFilesResult {
  let merged : Map[String, TreeFileEntry] = Map([])
  let conflicts : Array[String] = []
  let needs_content_merge : Array[ContentMergeCandidate] = []
  let rename_2to1 : Array[Rename2to1Candidate] = []
  let conflict_types : Map[String, String] = Map([])
  let removed_paths : Array[String] = []
  // Step 1: Detect renames on each side
  let ours_renames = merge_detect_renames(base, ours, db, rfs)
  let theirs_renames = merge_detect_renames(base, theirs, db, rfs)
  // Paths that are handled by rename logic (skip in normal processing)
  let handled_paths : Map[String, Bool] = Map([])
  // Step 1b: Detect rename/rename(2to1) - different files renamed to same target
  let ours_new_to_old : Map[String, String] = Map([])
  for old_path, new_path in ours_renames.old_to_new {
    ours_new_to_old[new_path] = old_path
  }
  for theirs_old, theirs_new in theirs_renames.old_to_new {
    match ours_new_to_old.get(theirs_new) {
      Some(ours_old) =>
        if ours_old != theirs_old {
          // rename/rename(2to1): different files both renamed to same path
          let mode = match ours.get(theirs_new) {
            Some(e) => e.mode
            None => 0o100644
          }
          rename_2to1.push({
            path: theirs_new,
            ours_old_path: ours_old,
            theirs_old_path: theirs_old,
            mode,
          })
          handled_paths[ours_old] = true
          handled_paths[theirs_old] = true
          handled_paths[theirs_new] = true
          removed_paths.push(ours_old)
          removed_paths.push(theirs_old)
        }
      None => ()
    }
  }
  // Step 2: Process renames on ours side (skip already handled by Step 1b)
  for old_path, new_path in ours_renames.old_to_new {
    if handled_paths.contains(old_path) || handled_paths.contains(new_path) {
      continue
    }
    let base_entry = base.get(old_path)
    let ours_entry = ours.get(new_path)
    // Check if theirs also renamed the same file
    match theirs_renames.old_to_new.get(old_path) {
      Some(theirs_new_path) =>
        if theirs_new_path == new_path {
          // Both sides renamed to same path - check content
          let theirs_entry = theirs.get(theirs_new_path)
          if merge_entry_eq(ours_entry, theirs_entry) {
            // Same rename, same content - take it
            match ours_entry {
              Some(v) => merged[new_path] = v
              None => ()
            }
          } else {
            // Same target path, possibly different content - content merge
            match (ours_entry, theirs_entry) {
              (Some(o), Some(t)) =>
                needs_content_merge.push({
                  path: new_path,
                  base_id: base_entry.map(fn(e) { e.id }),
                  ours_id: o.id,
                  theirs_id: t.id,
                  mode: o.mode,
                })
              _ => ()
            }
          }
          handled_paths[old_path] = true
          handled_paths[new_path] = true
          handled_paths[theirs_new_path] = true
        } else {
          // Renamed to different paths: rename/rename(1to2) conflict
          // Put both versions in merged for worktree
          match ours_entry {
            Some(v) => merged[new_path] = v
            None => ()
          }
          match theirs.get(theirs_new_path) {
            Some(v) => merged[theirs_new_path] = v
            None => ()
          }
          conflicts.push(new_path)
          conflict_types[new_path] = "rename/rename"
          handled_paths[old_path] = true
          handled_paths[new_path] = true
          handled_paths[theirs_new_path] = true
        }
      None => {
        // Only ours renamed. Check what theirs did with old_path
        let is_add_source = ours_renames.add_source_paths.contains(old_path)
        let theirs_entry = theirs.get(old_path)
        match (base_entry, ours_entry, theirs_entry) {
          (Some(b), Some(o), Some(t)) =>
            if b.id == t.id {
              // Theirs didn't modify - just take ours rename
              merged[new_path] = o
            } else if is_add_source &&
              theirs_renames.add_source_paths.contains(old_path) {
              // Both sides replaced old_path with new content; the original
              // was renamed. Handle renamed content at new_path, and the
              // new files at old_path will be merged in Step 4.
              merged[new_path] = o
            } else {
              // Theirs modified at old_path, ours renamed to new_path
              // -> content merge at new_path
              needs_content_merge.push({
                path: new_path,
                base_id: Some(b.id),
                ours_id: o.id,
                theirs_id: t.id,
                mode: o.mode,
              })
            }
          (_, Some(o), None) => {
            // Theirs deleted old_path, ours renamed: rename/delete conflict
            merged[new_path] = o
            conflicts.push(new_path)
            conflict_types[new_path] = "rename/delete"
          }
          _ =>
            match ours_entry {
              Some(v) => merged[new_path] = v
              None => ()
            }
        }
        // For add-source: include the new file at old_path
        if is_add_source {
          match ours.get(old_path) {
            Some(new_file) => merged[old_path] = new_file
            None => ()
          }
        }
        // Check for rename/add-dest: theirs independently added a file at new_path
        if !base.contains(new_path) {
          match theirs.get(new_path) {
            Some(_) => {
              // Theirs added a file at same path as our rename target
              conflicts.push(new_path)
              conflict_types[new_path] = "rename/add"
            }
            None => ()
          }
        }
        handled_paths[old_path] = true
        handled_paths[new_path] = true
        // Only mark old_path for removal if it's a clean rename (no conflict, no add-source)
        if !is_add_source && !conflict_types.contains(new_path) {
          removed_paths.push(old_path)
        }
      }
    }
  }
  // Step 3: Process renames on theirs side (skip already handled)
  for old_path, new_path in theirs_renames.old_to_new {
    if handled_paths.contains(old_path) || handled_paths.contains(new_path) {
      continue
    }
    let base_entry = base.get(old_path)
    let theirs_entry = theirs.get(new_path)
    let is_add_source = theirs_renames.add_source_paths.contains(old_path)
    // ours didn't rename (already checked above)
    let ours_entry = ours.get(old_path)
    match (base_entry, ours_entry, theirs_entry) {
      (Some(b), Some(o), Some(t)) =>
        if b.id == o.id {
          // Ours didn't modify - just take theirs rename
          merged[new_path] = t
        } else if is_add_source &&
          ours_renames.add_source_paths.contains(old_path) {
          // Both sides replaced; handled in Step 2
          merged[new_path] = t
        } else {
          // Ours modified at old_path, theirs renamed to new_path
          // -> content merge at new_path
          needs_content_merge.push({
            path: new_path,
            base_id: Some(b.id),
            ours_id: o.id,
            theirs_id: t.id,
            mode: t.mode,
          })
        }
      (_, None, Some(t)) => {
        // Ours deleted old_path, theirs renamed: rename/delete conflict
        merged[new_path] = t
        conflicts.push(new_path)
        conflict_types[new_path] = "rename/delete"
      }
      _ =>
        match theirs_entry {
          Some(v) => merged[new_path] = v
          None => ()
        }
    }
    // For add-source: include the new file at old_path
    if is_add_source {
      match theirs.get(old_path) {
        Some(new_file) => merged[old_path] = new_file
        None => ()
      }
    }
    // Check for rename/add-dest: ours independently added a file at new_path
    if !base.contains(new_path) {
      match ours.get(new_path) {
        Some(_) => {
          conflicts.push(new_path)
          conflict_types[new_path] = "rename/add"
        }
        None => ()
      }
    }
    handled_paths[old_path] = true
    handled_paths[new_path] = true
    if !is_add_source && !conflict_types.contains(new_path) {
      removed_paths.push(old_path)
    }
  }
  // Step 4: Process remaining paths with standard logic
  let all_paths : Map[String, Bool] = Map([])
  for path, _ in base {
    if !handled_paths.contains(path) {
      all_paths[path] = true
    }
  }
  for path, _ in ours {
    if !handled_paths.contains(path) {
      all_paths[path] = true
    }
  }
  for path, _ in theirs {
    if !handled_paths.contains(path) {
      all_paths[path] = true
    }
  }
  for path, _ in all_paths {
    let b = base.get(path)
    let o = ours.get(path)
    let t = theirs.get(path)
    if merge_entry_eq(o, t) {
      match o {
        None => ()
        Some(v) => merged[path] = v
      }
    } else if merge_entry_eq(o, b) {
      match t {
        None => ()
        Some(v) => merged[path] = v
      }
    } else if merge_entry_eq(t, b) {
      match o {
        None => ()
        Some(v) => merged[path] = v
      }
    } else {
      // Both sides modified - try content merge if both have the file
      match (o, t) {
        (Some(ours_entry), Some(theirs_entry)) => {
          let base_id = match b {
            Some(base_entry) => Some(base_entry.id)
            None => None
          }
          needs_content_merge.push({
            path,
            base_id,
            ours_id: ours_entry.id,
            theirs_id: theirs_entry.id,
            mode: ours_entry.mode,
          })
        }
        _ => {
          // One side deleted, other modified - file-level conflict
          conflicts.push(path)
          conflict_types[path] = "modify/delete"
        }
      }
    }
  }
  {
    merged,
    conflicts,
    needs_content_merge,
    rename_2to1,
    conflict_types,
    removed_paths,
  }
}

///|
fn merge_get_blob_text(
  db : ObjectDb,
  fs : &@bit.RepoFileSystem,
  id : @bit.ObjectId,
) -> String {
  get_blob_content(db, fs, id)
}

///|
fn merge_get_blob_data(
  db : ObjectDb,
  fs : &@bit.RepoFileSystem,
  id : @bit.ObjectId,
) -> Bytes {
  let obj = db.get(fs, id) catch { _ => return Default::default() }
  match obj {
    Some(o) =>
      if o.obj_type == @bit.ObjectType::Blob {
        o.data
      } else {
        Default::default()
      }
    None => Default::default()
  }
}

///|
fn merge_entry_eq(a : TreeFileEntry?, b : TreeFileEntry?) -> Bool {
  match (a, b) {
    (None, None) => true
    (Some(x), Some(y)) => x.id == y.id && x.mode == y.mode
    _ => false
  }
}

///|
/// Extract common prefix lines from two texts for use as merge base.
fn merge_common_line_prefix(a : String, b : String) -> String {
  let a_arr : Array[String] = []
  for part in a.split("\n") {
    a_arr.push(part.to_owned())
  }
  let b_arr : Array[String] = []
  for part in b.split("\n") {
    b_arr.push(part.to_owned())
  }
  let result = StringBuilder::new()
  let limit = if a_arr.length() < b_arr.length() {
    a_arr.length()
  } else {
    b_arr.length()
  }
  let mut count = 0
  for i in 0..<limit {
    if a_arr[i] == b_arr[i] {
      count += 1
    } else {
      break
    }
  }
  for i in 0..<count {
    result.write_string(a_arr[i])
    if i < count - 1 || a.contains("\n") {
      result.write_char('\n')
    }
  }
  result.to_string()
}

///|
/// Resolve a rename's content by doing a 3-way merge.
/// Returns the resolved blob ID if a merge was needed, or None if no merge needed.
fn merge_resolve_rename_content(
  db : ObjectDb,
  rfs : &@bit.RepoFileSystem,
  fs : &@bit.FileSystem,
  git_dir : String,
  base_id : @bit.ObjectId?,
  ours_entry : TreeFileEntry?,
  theirs_entry : TreeFileEntry?,
) -> (@bit.ObjectId, Int)? raise @bit.GitError {
  let ours_id = match ours_entry {
    Some(e) => e.id
    None => return None
  }
  let theirs_id = match theirs_entry {
    Some(e) => e.id
    None => return None
  }
  match base_id {
    Some(b_id) =>
      if b_id == theirs_id {
        // Theirs didn't modify, take ours
        return Some((ours_id, ours_entry.unwrap().mode))
      } else if b_id == ours_id {
        // Ours didn't modify, take theirs
        return Some((theirs_id, theirs_entry.unwrap().mode))
      } else if ours_id == theirs_id {
        return Some((ours_id, ours_entry.unwrap().mode))
      }
    None =>
      if ours_id == theirs_id {
        return Some((ours_id, ours_entry.unwrap().mode))
      }
  }
  // Both modified - content merge
  let base_content = match base_id {
    Some(id) => merge_get_blob_text(db, rfs, id)
    None => ""
  }
  let ours_content = merge_get_blob_text(db, rfs, ours_id)
  let theirs_content = merge_get_blob_text(db, rfs, theirs_id)
  let result = @diff3.content_merge(
    base_content,
    ours_content,
    theirs_content,
    @diff3.ContentMergeOptions::default(),
  )
  let content_bytes = @utf8.encode(result.content)
  let (blob_id, compressed) = @bit.create_blob(content_bytes)
  write_object_bytes(fs, git_dir, blob_id, compressed)
  Some((blob_id, ours_entry.unwrap().mode))
}

///|
/// Create index stage entries for conflicts, including rename/rename(2to1) stages.
fn merge_conflicted_index_entries_with_renames(
  db : ObjectDb,
  fs : &@bit.RepoFileSystem,
  base : Map[String, TreeFileEntry],
  ours : Map[String, TreeFileEntry],
  theirs : Map[String, TreeFileEntry],
  merged : Map[String, TreeFileEntry],
  conflicts : Array[String],
  rename_conflict_stages : Map[String, (TreeFileEntry, TreeFileEntry)],
) -> Array[IndexStageEntry] raise @bit.GitError {
  let out : Array[IndexStageEntry] = []
  let conflict_set : Map[String, Bool] = Map([])
  for path in conflicts {
    conflict_set[path] = true
  }
  let merged_entries = tree_files_to_index(db, fs, merged)
  for entry in merged_entries {
    if !conflict_set.contains(entry.path) {
      out.push({ entry, stage: 0 })
    }
  }
  for path in conflicts {
    match rename_conflict_stages.get(path) {
      Some(stages) => {
        // rename/rename(2to1): stage 2 = resolved ours, stage 3 = resolved theirs
        let (ours_stage, theirs_stage) = stages
        out.push({
          entry: merge_tree_file_to_index_entry(db, fs, path, ours_stage),
          stage: 2,
        })
        out.push({
          entry: merge_tree_file_to_index_entry(db, fs, path, theirs_stage),
          stage: 3,
        })
      }
      None => {
        // Standard conflict: base/ours/theirs at same path
        match base.get(path) {
          Some(info) =>
            out.push({
              entry: merge_tree_file_to_index_entry(db, fs, path, info),
              stage: 1,
            })
          None => ()
        }
        match ours.get(path) {
          Some(info) =>
            out.push({
              entry: merge_tree_file_to_index_entry(db, fs, path, info),
              stage: 2,
            })
          None => ()
        }
        match theirs.get(path) {
          Some(info) =>
            out.push({
              entry: merge_tree_file_to_index_entry(db, fs, path, info),
              stage: 3,
            })
          None => ()
        }
      }
    }
  }
  out
}

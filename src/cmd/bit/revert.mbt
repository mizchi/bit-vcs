///|
async fn handle_revert(args : Array[String]) -> Unit raise Error {
  let root = get_work_root()
  let git_dir = root + "/.git"
  let fs = OsFs::new()
  let mut no_commit = false
  let mut mainline : Int? = None
  let mut do_continue = false
  let mut do_abort = false
  let mut do_skip = false
  let commits : Array[String] = []
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    match arg {
      "-n" | "--no-commit" => no_commit = true
      "-m" if i + 1 < args.length() => {
        mainline = args[i + 1] |> @strconv.parse_int |> Some
        i += 1
      }
      _ if arg.has_prefix("-m") =>
        mainline = Some(
          @strconv.parse_int(
            String::unsafe_substring(arg, start=2, end=arg.length()),
          ),
        )
      "--continue" => do_continue = true
      "--abort" => do_abort = true
      "--skip" => do_skip = true
      _ if not(arg.has_prefix("-")) => commits.push(arg)
      _ => ()
    }
    i += 1
  }
  let rfs : &@bitcore.RepoFileSystem = fs
  let wfs : &@bitcore.FileSystem = fs
  let revert_head_path = git_dir + "/REVERT_HEAD"
  let merge_msg_path = git_dir + "/MERGE_MSG"
  let orig_head_path = git_dir + "/ORIG_HEAD"
  // Handle --abort
  if do_abort {
    if not(rfs.is_file(revert_head_path)) {
      @stdio.stderr.write("error: no revert in progress")
      @sys.exit(1)
    }
    // Restore ORIG_HEAD if exists
    if rfs.is_file(orig_head_path) {
      let orig_hex = trim_chars(
        decode_bytes(rfs.read_file(orig_head_path)),
        " \t\r\n",
      )
      // Reset to ORIG_HEAD
      ignore(@bitlib.reset(wfs, rfs, root, orig_hex, @bitlib.ResetMode::Hard))
      wfs.remove_file(orig_head_path) catch {
        err if @async.is_cancellation_error(err) => raise err
        _ => ()
      }
    }
    // Clean up state files
    wfs.remove_file(revert_head_path) catch {
      err if @async.is_cancellation_error(err) => raise err
      _ => ()
    }
    wfs.remove_file(merge_msg_path) catch {
      err if @async.is_cancellation_error(err) => raise err
      _ => ()
    }
    print_line("Revert aborted.")
    return
  }
  // Handle --skip
  if do_skip {
    if not(rfs.is_file(revert_head_path)) {
      @stdio.stderr.write("error: no revert in progress")
      @sys.exit(1)
    }
    // Clean up state files (skip current revert)
    wfs.remove_file(revert_head_path) catch {
      err if @async.is_cancellation_error(err) => raise err
      _ => ()
    }
    wfs.remove_file(merge_msg_path) catch {
      err if @async.is_cancellation_error(err) => raise err
      _ => ()
    }
    // Reset index to HEAD
    ignore(@bitlib.reset(wfs, rfs, root, "HEAD", @bitlib.ResetMode::Mixed))
    print_line("Revert skipped.")
    return
  }
  // Handle --continue
  if do_continue {
    if not(rfs.is_file(revert_head_path)) {
      @stdio.stderr.write("error: no revert in progress")
      @sys.exit(1)
    }
    // Read the commit message from MERGE_MSG
    let msg = if rfs.is_file(merge_msg_path) {
      decode_bytes(rfs.read_file(merge_msg_path))
    } else {
      "Revert commit\n"
    }
    // Create the commit
    let author = get_author_string()
    let timestamp = get_commit_timestamp()
    let new_commit_id = @bitlib.commit(wfs, rfs, root, msg, author, timestamp)
    let short_id = (try! new_commit_id.to_hex()[:7]).to_string()
    let first_line = match msg.find("\n") {
      Some(idx) => String::unsafe_substring(msg, start=0, end=idx)
      None => msg
    }
    print_line("[\{short_id}] \{first_line}")
    // Clean up state files
    wfs.remove_file(revert_head_path) catch {
      err if @async.is_cancellation_error(err) => raise err
      _ => ()
    }
    wfs.remove_file(merge_msg_path) catch {
      err if @async.is_cancellation_error(err) => raise err
      _ => ()
    }
    wfs.remove_file(orig_head_path) catch {
      err if @async.is_cancellation_error(err) => raise err
      _ => ()
    }
    return
  }
  // Normal revert
  if commits.length() == 0 {
    raise @bitcore.GitError::InvalidObject("usage: git revert <commit>...")
  }
  // Check if revert already in progress
  if rfs.is_file(revert_head_path) {
    @stdio.stderr.write(
      "error: revert already in progress, use --continue, --abort, or --skip",
    )
    @sys.exit(1)
  }
  // Save ORIG_HEAD
  let current_head = @bitlib.resolve_head_commit(rfs, git_dir)
  if current_head is Some(hid) {
    wfs.write_string(orig_head_path, hid.to_hex() + "\n")
  }
  let db = @bitlib.ObjectDb::load(rfs, git_dir)
  for commit_ref in commits {
    // Resolve commit
    let commit_id = @bitrepo.rev_parse(rfs, git_dir, commit_ref)
    guard commit_id is Some(cid) else {
      raise @bitcore.GitError::InvalidObject("unknown revision: \{commit_ref}")
    }
    // Load commit
    let obj = db.get(rfs, cid)
    guard obj is Some(o) else {
      raise @bitcore.GitError::InvalidObject(
        "commit not found: \{cid.to_hex()}",
      )
    }
    let commit_info = @bitcore.parse_commit(o.data)
    // Get parent (for merge commits, use mainline)
    let parent_id : @bitcore.ObjectId? = if commit_info.parents.length() == 0 {
      None
    } else if commit_info.parents.length() > 1 {
      // Merge commit
      match mainline {
        Some(m) =>
          if m < 1 || m > commit_info.parents.length() {
            raise @bitcore.GitError::InvalidObject(
              "mainline must be 1..\{commit_info.parents.length()}",
            )
          } else {
            Some(commit_info.parents[m - 1])
          }
        None =>
          raise @bitcore.GitError::InvalidObject(
            "commit is a merge, -m option required",
          )
      }
    } else {
      Some(commit_info.parents[0])
    }
    // Get trees for commit and parent
    let commit_files = @bitlib.collect_tree_files_from_commit(db, rfs, cid)
    let parent_files : Map[String, @bitlib.TreeFileEntry] = match parent_id {
      Some(pid) => @bitlib.collect_tree_files_from_commit(db, rfs, pid)
      None => {}
    }
    // Apply reverse changes
    let mut has_conflicts = false
    // Files that were added in commit -> delete them
    for item in commit_files.to_array() {
      let (path, _) = item
      if not(parent_files.contains(path)) {
        // File was added in commit, remove it
        let abs_path = root + "/" + path
        if rfs.is_file(abs_path) {
          wfs.remove_file(abs_path)
        }
        // Remove from index
        remove_from_index(wfs, rfs, git_dir, path)
      }
    }
    // Files that were deleted in commit -> restore them
    for item in parent_files.to_array() {
      let (path, entry) = item
      if not(commit_files.contains(path)) {
        // File was deleted in commit, restore it
        let blob_obj = db.get(rfs, entry.id)
        guard blob_obj is Some(bo) else { continue }
        let abs_path = root + "/" + path
        // Ensure parent dir exists
        match abs_path.rev_find("/") {
          Some(idx) => {
            let parent = String::unsafe_substring(abs_path, start=0, end=idx)
            wfs.mkdir_p(parent)
          }
          None => ()
        }
        wfs.write_file(abs_path, bo.data)
        // Add to index
        @bitlib.add_paths_async(wfs, rfs, root, [path])
      }
    }
    // Files that were modified in commit -> restore parent version
    for item in commit_files.to_array() {
      let (path, commit_entry) = item
      match parent_files.get(path) {
        Some(parent_entry) =>
          if commit_entry.id.to_hex() != parent_entry.id.to_hex() {
            // File was modified, restore parent version
            let abs_path = root + "/" + path
            // Check if current file matches commit version (clean revert)
            let current_content = rfs.read_file(abs_path) catch {
              err if @async.is_cancellation_error(err) => raise err
              _ => b""
            }
            let current_id = @bitcore.hash_blob(current_content)
            if current_id.to_hex() != commit_entry.id.to_hex() {
              // Current file differs from commit, potential conflict
              @stdio.stderr.write("warning: \{path} has local modifications")
              has_conflicts = true
              continue
            }
            // Restore parent version
            let blob_obj = db.get(rfs, parent_entry.id)
            guard blob_obj is Some(bo) else { continue }
            wfs.write_file(abs_path, bo.data)
            @bitlib.add_paths_async(wfs, rfs, root, [path])
          }
        None => ()
      }
    }
    // Prepare revert message
    let original_msg = extract_commit_message(o.data)
    let first_line = match original_msg.find("\n") {
      Some(idx) => String::unsafe_substring(original_msg, start=0, end=idx)
      None => original_msg
    }
    let revert_msg = "Revert \"\{first_line}\"\n\nThis reverts commit \{cid.to_hex()}.\n"
    if has_conflicts {
      // Save state for --continue
      wfs.write_string(revert_head_path, cid.to_hex() + "\n")
      wfs.write_string(merge_msg_path, revert_msg)
      @stdio.stderr.write("error: could not revert \{commit_ref}")
      @stdio.stderr.write(
        "hint: after resolving conflicts, run 'git revert --continue'",
      )
      @stdio.stderr.write("hint: to skip this commit, run 'git revert --skip'")
      @stdio.stderr.write("hint: to abort, run 'git revert --abort'")
      @sys.exit(1)
    }
    // Create revert commit unless --no-commit
    if not(no_commit) {
      let author = get_author_string()
      let timestamp = get_commit_timestamp()
      let new_commit_id = @bitlib.commit(
        wfs,
        rfs,
        root,
        revert_msg,
        author,
        timestamp,
        allow_empty=true,
      )
      let short_id = (try! new_commit_id.to_hex()[:7]).to_string()
      print_line("[\{short_id}] Revert \"\{first_line}\"")
    }
  }
  // Clean up ORIG_HEAD on success
  wfs.remove_file(orig_head_path) catch {
    err if @async.is_cancellation_error(err) => raise err
    _ => ()
  }
}

///|
fn extract_commit_message(data : Bytes) -> String {
  let text = decode_bytes(data)
  let mut in_message = false
  let msg_lines : Array[String] = []
  for line_view in text.split("\n") {
    let line = line_view.to_string()
    if in_message {
      msg_lines.push(line)
      continue
    }
    if line.length() == 0 {
      in_message = true
    }
  }
  msg_lines.join("\n")
}

///|
fn remove_from_index(
  wfs : &@bitcore.FileSystem,
  rfs : &@bitcore.RepoFileSystem,
  git_dir : String,
  path : String,
) -> Unit {
  let entries = @bitlib.read_index_entries(rfs, git_dir) catch { _ => return }
  let new_entries : Array[@bitlib.IndexEntry] = []
  for e in entries {
    if e.path != path {
      new_entries.push(e)
    }
  }
  @bitlib.write_index_entries(wfs, git_dir, new_entries) catch {
    _ => ()
  }
}

///|
fn normalize_notes_ref(ref_name : String?) -> String raise @bitcore.GitError {
  let name = ref_name.unwrap_or("commits")
  let normalized = @bitlib.normalize_repo_path(name) catch {
    _ => raise @bitcore.GitError::InvalidObject("invalid notes ref: " + name)
  }
  if normalized.has_prefix("refs/") {
    normalized
  } else {
    "refs/notes/" + normalized
  }
}

///|
/// Handle git notes command

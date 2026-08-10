///|
fn cherry_pick_is_supported_noop_arg(arg : String) -> Bool {
  arg == "--3way" || arg == "--ff"
}

///|
fn cherry_pick_is_positional_arg(arg : String) -> Bool {
  arg == "-" || !arg.has_prefix("-")
}

///|
/// Parses git's `-<n>` shorthand (e.g. `-2`, `-3`) used by `git cherry-pick
/// -<n> <commit>` to mean "the last n commits (first-parent history) ending
/// at <commit>". Returns None for anything else, including the bare `-`
/// (handled separately as a positional arg).
fn cherry_pick_parse_count_arg(arg : String) -> Int? {
  if !arg.has_prefix("-") || arg.length() < 2 {
    return None
  }
  let rest = String::unsafe_substring(arg, start=1, end=arg.length())
  for ch in rest {
    if ch < '0' || ch > '9' {
      return None
    }
  }
  let n = @string.parse_int(rest) catch { _ => -1 }
  if n >= 0 {
    Some(n)
  } else {
    None
  }
}

///|
/// Collects the last `n` commits (first-parent history, oldest first) ending
/// at `target`, for `git cherry-pick -<n> <commit>`.
fn cherry_pick_collect_last_n_commits(
  rfs : &@bitcore.RepoFileSystem,
  git_dir : String,
  target : @bitcore.ObjectId,
  n : Int,
) -> Array[@bitcore.ObjectId] raise Error {
  let db = @bitlib.ObjectDb::load(rfs, git_dir)
  let commits : Array[@bitcore.ObjectId] = []
  let mut current : @bitcore.ObjectId? = Some(target)
  while current is Some(cid) && commits.length() < n {
    commits.push(cid)
    current = match db.get(rfs, cid) {
      Some(obj) if obj.obj_type == @bitcore.ObjectType::Commit => {
        let info = @bitcore.parse_commit(obj.data)
        if info.parents.length() > 0 {
          Some(info.parents[0])
        } else {
          None
        }
      }
      _ => None
    }
  }
  commits.rev_in_place()
  commits
}

///|
fn cherry_pick_collect_linear_replay_commits(
  rfs : &@bitcore.RepoFileSystem,
  git_dir : String,
  stop_exclusive : @bitcore.ObjectId,
  target : @bitcore.ObjectId,
) -> Array[@bitcore.ObjectId] raise Error {
  let db = @bitlib.ObjectDb::load(rfs, git_dir)
  let commits : Array[@bitcore.ObjectId] = []
  let mut current : @bitcore.ObjectId? = Some(target)
  let stop_hex = stop_exclusive.to_hex()
  let mut reached_stop = false
  while current is Some(cid) {
    if cid.to_hex() == stop_hex {
      reached_stop = true
      break
    }
    commits.push(cid)
    current = match db.get(rfs, cid) {
      Some(obj) if obj.obj_type == @bitcore.ObjectType::Commit => {
        let info = @bitcore.parse_commit(obj.data)
        if info.parents.length() > 0 {
          Some(info.parents[0])
        } else {
          None
        }
      }
      _ => None
    }
  }
  if !reached_stop {
    return []
  }
  commits.rev_in_place()
  commits
}

///|
async fn handle_cherry_pick(args : Array[String]) -> Unit raise Error {
  let root = get_work_root()
  check_and_exit_unsupported_attrs(root)
  let fs = OsFs::new()
  let wfs : &@bitcore.FileSystem = fs
  let rfs : &@bitcore.RepoFileSystem = fs
  let git_dir = resolve_git_dir(rfs, root)
  let mut do_abort = false
  let mut use_threeway = false
  let mut allow_empty = false
  let mut no_commit = false
  let mut signoff = false
  let mut add_cherry_pick_note = false
  let unsupported_args : Array[String] = []
  let mut pick_count : Int? = None
  // Parse arguments
  let mut commit_spec : String? = None
  for arg in args {
    if cherry_pick_is_positional_arg(arg) {
      commit_spec = Some(arg)
      break
    }
    if arg == "--abort" {
      do_abort = true
    } else if arg == "--allow-empty" {
      allow_empty = true
    } else if arg == "-n" || arg == "--no-commit" {
      no_commit = true
    } else if arg == "-s" || arg == "--signoff" {
      signoff = true
    } else if arg == "-x" {
      add_cherry_pick_note = true
    } else if cherry_pick_is_supported_noop_arg(arg) {
      use_threeway = true
    } else if cherry_pick_parse_count_arg(arg) is Some(n) {
      pick_count = Some(n)
    } else {
      unsupported_args.push(arg)
    }
  }
  // Handle --abort
  if do_abort {
    ignore(@bitlib.reset(wfs, rfs, root, "HEAD", @bitlib.ResetMode::Hard))
    return
  }
  // Check if subdir-clone and handle specially
  let subdir_info = get_subdir_info(fs, git_dir)
  if unsupported_args.length() > 0 {
    for arg in unsupported_args {
      @stdio.stderr.write("error: cherry-pick: unsupported option '\{arg}'\n")
    }
    @sys.exit(1)
  }
  guard commit_spec is Some(spec) else {
    eprint_line("error: cherry-pick requires a commit argument")
    @sys.exit(1)
  }
  match subdir_info {
    Some((_, subdir_path, _)) => {
      handle_subdir_cherry_pick(fs, root, git_dir, spec, subdir_path) catch {
        err => raise err
      }
      return
    }
    None => ()
  }
  // "-" means previous branch's HEAD — resolve via @{-1}
  let effective_spec = if spec == "-" { "@{-1}" } else { spec }
  // Resolve commit
  let commit_id = @bitrepo.rev_parse(fs, git_dir, effective_spec)
  guard commit_id is Some(cid) else {
    raise @bitcore.GitError::InvalidObject(
      "unknown revision: \{effective_spec}",
    )
  }
  // Validate the commit object
  if subdir_info is None {
    let db = @bitlib.ObjectDb::load(rfs, git_dir)
    let commit_obj = db.get(rfs, cid)
    guard commit_obj is Some(obj) else {
      raise @bitcore.GitError::InvalidObject("Commit not found")
    }
    if obj.obj_type != @bitcore.ObjectType::Commit {
      raise @bitcore.GitError::InvalidObject("Not a commit")
    }
  }
  let commit_ids : Array[@bitcore.ObjectId] = []
  if pick_count is Some(n) {
    let replay_commits = cherry_pick_collect_last_n_commits(
      rfs, git_dir, cid, n,
    )
    if replay_commits.length() > 0 {
      for replay_id in replay_commits {
        commit_ids.push(replay_id)
      }
    } else {
      commit_ids.push(cid)
    }
  } else if use_threeway {
    match @bitlib.resolve_head_commit(rfs, git_dir) {
      Some(head_id) =>
        match rev_parse_find_merge_base(rfs, git_dir, head_id, cid) {
          Some(base_id) => {
            let replay_commits = cherry_pick_collect_linear_replay_commits(
              rfs, git_dir, base_id, cid,
            )
            if replay_commits.length() > 0 {
              for replay_id in replay_commits {
                commit_ids.push(replay_id)
              }
            } else {
              commit_ids.push(cid)
            }
          }
          None => commit_ids.push(cid)
        }
      None => commit_ids.push(cid)
    }
  } else {
    commit_ids.push(cid)
  }
  let author = get_author_string()
  let timestamp = get_commit_timestamp()
  for current_id in commit_ids {
    // Build message suffix for -x flag
    let message_suffix = if add_cherry_pick_note {
      "(cherry picked from commit \{current_id.to_hex()})"
    } else {
      ""
    }
    let signoff_committer = if signoff { get_committer_string() } else { "" }
    let result = @bitlib.cherry_pick(
      fs,
      fs,
      root,
      current_id,
      author,
      timestamp,
      allow_empty~,
      no_commit~,
      message_suffix~,
      signoff_committer~,
    )
    match result.status {
      @bitlib.CherryPickStatus::Success =>
        match result.commit_id {
          Some(id) => {
            let short = String::unsafe_substring(id.to_hex(), start=0, end=7)
            let source = if commit_ids.length() == 1 {
              spec
            } else {
              current_id.to_hex()
            }
            print_line("[\{short}] Cherry-picked from \{source}")
          }
          None => print_line("Cherry-pick successful")
        }
      @bitlib.CherryPickStatus::Conflict => {
        print_line("CONFLICT: Merge conflict in cherry-pick:")
        for path in result.conflicts {
          print_line("  \{path}")
        }
        print_line("")
        print_line(
          "After fixing the conflicts, use \"git commit\" to continue.",
        )
        @sys.exit(1)
      }
    }
  }
}

///|
/// Handle cherry-pick for subdir-clone
async fn handle_subdir_cherry_pick(
  fs : OsFs,
  root : String,
  git_dir : String,
  spec : String,
  subdir_path : String,
) -> Unit raise Error {
  print_line("Cherry-picking from upstream (subdir: \{subdir_path})...")
  // Resolve commit
  let commit_id = resolve_ref_for_subdir(fs, git_dir, spec) catch {
    err => raise err
  }
  guard commit_id is Some(cid) else {
    raise @bitcore.GitError::InvalidObject("unknown revision: \{spec}")
  }
  // Load object database
  let db = @bitlib.ObjectDb::load_lazy(fs, git_dir)
  // Get upstream commit's subdir tree
  let upstream_tree = get_subdir_tree_from_commit(db, fs, cid, subdir_path) catch {
    err => raise err
  }
  guard upstream_tree is Some(utree) else {
    raise @bitcore.GitError::InvalidObject(
      "Subdirectory not found in commit: \{subdir_path}",
    )
  }
  // Get upstream commit's parent subdir tree
  let commit_obj = db.get(fs, cid)
  guard commit_obj is Some(co) else {
    raise @bitcore.GitError::InvalidObject("Cannot read commit")
  }
  let commit_info = @bitcore.parse_commit(co.data) catch { err => raise err }
  let parent_tree = if commit_info.parents.length() > 0 {
    get_subdir_tree_from_commit(db, fs, commit_info.parents[0], subdir_path) catch {
      err if @async.is_cancellation_error(err) => raise err
      _ => None
    }
  } else {
    None
  }
  // Check if this commit changes the subdir
  let changed = match parent_tree {
    Some(pt) => pt.to_hex() != utree.to_hex()
    None => true
  }
  if !changed {
    print_line("Commit \{spec} does not change \{subdir_path}, skipping.")
    return
  }
  // Apply the subdir change
  let (author, message) = parse_commit_author_message(co.data)
  let change_info : SubdirChangeInfo = {
    id: cid,
    subdir_tree: utree,
    message,
    author,
  }
  apply_subdir_change(fs, db, root, git_dir, change_info) catch {
    err => raise err
  }
  print_line("Cherry-picked: \{message}")
}

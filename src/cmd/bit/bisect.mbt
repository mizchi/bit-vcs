///|
async fn handle_bisect(args : Array[String]) -> Unit raise Error {
  let root = get_work_root()
  let fs = OsFs::new()
  let wfs : &@git.FileSystem = fs
  let rfs : &@git.RepoFileSystem = fs
  let git_dir = resolve_git_dir(rfs, root)
  let subcmd = args.get(0).unwrap_or("help")
  match subcmd {
    "start" => bisect_start(wfs, rfs, root, git_dir, args)
    "bad" | "new" => bisect_mark(wfs, rfs, git_dir, args, "bad")
    "good" | "old" => bisect_mark(wfs, rfs, git_dir, args, "good")
    "skip" => bisect_skip(wfs, rfs, git_dir, args)
    "reset" => bisect_reset(wfs, rfs, root, git_dir, args)
    "log" => bisect_log(rfs, git_dir)
    "visualize" | "view" => {
      @stdio.stderr.write("bisect visualize not implemented")
      @sys.exit(1)
    }
    "replay" => {
      @stdio.stderr.write("bisect replay not implemented")
      @sys.exit(1)
    }
    "run" => {
      @stdio.stderr.write("bisect run not implemented")
      @sys.exit(1)
    }
    "help" | _ => {
      print_line("usage: git bisect [start|bad|good|skip|reset|log]")
      print_line("")
      print_line("  start [bad [good...]] - Start bisect session")
      print_line("  bad [commit]          - Mark commit as bad")
      print_line("  good [commit]         - Mark commit as good")
      print_line("  skip [commit]         - Skip commit")
      print_line("  reset [commit]        - End bisect and checkout commit")
      print_line("  log                   - Show bisect log")
    }
  }
}

///|
async fn bisect_start(
  wfs : &@git.FileSystem,
  rfs : &@git.RepoFileSystem,
  _root : String,
  git_dir : String,
  args : Array[String],
) -> Unit raise Error {
  let bisect_start_path = git_dir + "/BISECT_START"
  let bisect_log_path = git_dir + "/BISECT_LOG"
  let bisect_terms_path = git_dir + "/BISECT_TERMS"
  let bisect_refs_dir = git_dir + "/refs/bisect"
  // Check if already in bisect
  if rfs.is_file(bisect_start_path) {
    @stdio.stderr.write("error: bisect already in progress")
    @stdio.stderr.write("use 'git bisect reset' to abort")
    @sys.exit(1)
  }
  // Get current branch
  let head_content = decode_bytes(rfs.read_file(git_dir + "/HEAD"))
  let current_branch = if head_content.has_prefix("ref: refs/heads/") {
    trim_string(
      String::unsafe_substring(
        head_content,
        start=16,
        end=head_content.length(),
      ),
    )
  } else {
    "HEAD"
  }
  // Create bisect directory
  wfs.mkdir_p(bisect_refs_dir)
  // Save start state
  wfs.write_string(bisect_start_path, current_branch + "\n")
  wfs.write_string(bisect_terms_path, "bad\ngood\n")
  wfs.write_string(bisect_log_path, "git bisect start\n")
  print_line("status: waiting for both good and bad commits")
  // Handle optional bad/good arguments
  // git bisect start [bad [good...]] [--] [paths...]
  let mut i = 1
  let mut bad_set = false
  while i < args.length() {
    let arg = args[i]
    if arg == "--" {
      break
    }
    if not(arg.has_prefix("-")) {
      if not(bad_set) {
        // First positional arg is bad commit
        bisect_mark(wfs, rfs, git_dir, ["bad", arg], "bad")
        bad_set = true
      } else {
        // Subsequent args are good commits
        bisect_mark(wfs, rfs, git_dir, ["good", arg], "good")
      }
    }
    i += 1
  }
}

///|
async fn bisect_mark(
  wfs : &@git.FileSystem,
  rfs : &@git.RepoFileSystem,
  git_dir : String,
  args : Array[String],
  mark_type : String,
) -> Unit raise Error {
  let bisect_start_path = git_dir + "/BISECT_START"
  let bisect_log_path = git_dir + "/BISECT_LOG"
  let bisect_refs_dir = git_dir + "/refs/bisect"
  // Check if bisect is in progress
  if not(rfs.is_file(bisect_start_path)) {
    @stdio.stderr.write("error: not in a bisect session")
    @stdio.stderr.write("use 'git bisect start' first")
    @sys.exit(1)
  }
  // Get commit to mark (default HEAD)
  let commit_ref = args.get(1).unwrap_or("HEAD")
  let commit_id = @gitrepo.rev_parse(rfs, git_dir, commit_ref)
  guard commit_id is Some(cid) else {
    raise @git.GitError::InvalidObject("unknown revision: \{commit_ref}")
  }
  let commit_hex = cid.to_hex()
  // Get commit message for log
  let db = @gitlib.ObjectDb::load(rfs, git_dir)
  let obj = db.get(rfs, cid)
  let commit_msg = match obj {
    Some(o) => {
      let msg = extract_commit_message(o.data)
      let first_line = match msg.find("\n") {
        Some(idx) => String::unsafe_substring(msg, start=0, end=idx)
        None => msg
      }
      first_line
    }
    None => ""
  }
  // Write ref
  if mark_type == "bad" {
    wfs.write_string(bisect_refs_dir + "/bad", commit_hex + "\n")
  } else {
    wfs.write_string(bisect_refs_dir + "/good-" + commit_hex, commit_hex + "\n")
  }
  // Append to log
  let log_entry = "# \{mark_type}: [\{commit_hex}] \{commit_msg}\ngit bisect \{mark_type} \{commit_hex}\n"
  let existing_log = decode_bytes(rfs.read_file(bisect_log_path)) catch {
    err if @async.is_cancellation_error(err) => raise err
    _ => ""
  }
  wfs.write_string(bisect_log_path, existing_log + log_entry)
  // Check if we can compute next bisect point
  bisect_next(wfs, rfs, git_dir)
}

///|
async fn bisect_skip(
  wfs : &@git.FileSystem,
  rfs : &@git.RepoFileSystem,
  git_dir : String,
  args : Array[String],
) -> Unit raise Error {
  let bisect_start_path = git_dir + "/BISECT_START"
  let bisect_log_path = git_dir + "/BISECT_LOG"
  let bisect_refs_dir = git_dir + "/refs/bisect"
  // Check if bisect is in progress
  if not(rfs.is_file(bisect_start_path)) {
    @stdio.stderr.write("error: not in a bisect session")
    @sys.exit(1)
  }
  // Get commit to skip (default HEAD)
  let commit_ref = args.get(1).unwrap_or("HEAD")
  let commit_id = @gitrepo.rev_parse(rfs, git_dir, commit_ref)
  guard commit_id is Some(cid) else {
    raise @git.GitError::InvalidObject("unknown revision: \{commit_ref}")
  }
  let commit_hex = cid.to_hex()
  // Write skip ref
  wfs.write_string(bisect_refs_dir + "/skip-" + commit_hex, commit_hex + "\n")
  // Append to log
  let log_entry = "git bisect skip \{commit_hex}\n"
  let existing_log = decode_bytes(rfs.read_file(bisect_log_path)) catch {
    err if @async.is_cancellation_error(err) => raise err
    _ => ""
  }
  wfs.write_string(bisect_log_path, existing_log + log_entry)
  // Compute next
  bisect_next(wfs, rfs, git_dir)
}

///|
async fn bisect_next(
  wfs : &@git.FileSystem,
  rfs : &@git.RepoFileSystem,
  git_dir : String,
) -> Unit raise Error {
  let bisect_refs_dir = git_dir + "/refs/bisect"
  let bisect_expected_path = git_dir + "/BISECT_EXPECTED_REV"
  // Read bad commit
  let bad_path = bisect_refs_dir + "/bad"
  if not(rfs.is_file(bad_path)) {
    print_line("status: waiting for bad commit")
    return
  }
  let bad_hex = rfs.read_file(bad_path) |> decode_bytes |> trim_string
  let bad_id = @git.ObjectId::from_hex(bad_hex)
  // Read good commits
  let good_commits : Array[@git.ObjectId] = []
  let bisect_entries = (rfs : &@git.RepoFileSystem).readdir(bisect_refs_dir) catch {
    err if @async.is_cancellation_error(err) => raise err
    _ => []
  }
  for entry in bisect_entries {
    if entry.has_prefix("good-") {
      let good_hex = trim_string(
        decode_bytes(rfs.read_file(bisect_refs_dir + "/" + entry)),
      )
      good_commits.push(@git.ObjectId::from_hex(good_hex))
    }
  }
  if good_commits.length() == 0 {
    print_line("status: waiting for good commit(s), bad commit known")
    return
  }
  // Read skip commits
  let skip_commits : Array[@git.ObjectId] = []
  for entry in bisect_entries {
    if entry.has_prefix("skip-") {
      let skip_hex = trim_string(
        decode_bytes(rfs.read_file(bisect_refs_dir + "/" + entry)),
      )
      skip_commits.push(@git.ObjectId::from_hex(skip_hex))
    }
  }
  // Get all commits between good and bad using rev-list logic
  let db = @gitlib.ObjectDb::load(rfs, git_dir)
  let candidates = bisect_get_candidates(
    db, rfs, bad_id, good_commits, skip_commits,
  )
  if candidates.length() == 0 {
    // Found the first bad commit
    print_line("\{bad_hex} is the first bad commit")
    return
  }
  // Pick middle commit
  let mid_idx = candidates.length() / 2
  let mid_id = candidates[mid_idx]
  let mid_hex = mid_id.to_hex()
  // Get commit info for output
  let obj = db.get(rfs, mid_id)
  let commit_msg = match obj {
    Some(o) => {
      let msg = extract_commit_message(o.data)
      match msg.find("\n") {
        Some(idx) => String::unsafe_substring(msg, start=0, end=idx)
        None => msg
      }
    }
    None => ""
  }
  // Calculate steps remaining
  let remaining = candidates.length()
  let steps = bisect_steps(remaining)
  // Write expected rev
  wfs.write_string(bisect_expected_path, mid_hex + "\n")
  // Checkout the commit (detached HEAD)
  let root = git_dir + "/.."
  ignore(@gitlib.checkout(wfs, rfs, root, mid_hex, detach=true))
  print_line(
    "Bisecting: \{remaining} revisions left to test after this (roughly \{steps} steps)",
  )
  print_line("[\{mid_hex}] \{commit_msg}")
}

///|
fn bisect_steps(n : Int) -> Int {
  // log2(n) rounded
  if n <= 1 {
    return 0
  }
  let mut steps = 0
  let mut val = n
  while val > 1 {
    val = val / 2
    steps += 1
  }
  steps
}

///|
fn bisect_get_candidates(
  db : @gitlib.ObjectDb,
  rfs : &@git.RepoFileSystem,
  bad : @git.ObjectId,
  goods : Array[@git.ObjectId],
  skips : Array[@git.ObjectId],
) -> Array[@git.ObjectId] raise Error {
  // Get all ancestors of bad that are not ancestors of any good
  let good_set : Map[String, Bool] = {}
  // Mark all good commits and their ancestors
  for g in goods {
    mark_ancestors(db, rfs, g, good_set)
  }
  // Collect candidates: ancestors of bad that are not in good_set
  let candidates : Array[@git.ObjectId] = []
  let visited : Map[String, Bool] = {}
  let queue : Array[@git.ObjectId] = [bad]
  while queue.length() > 0 {
    let current = queue.pop()
    guard current is Some(cid) else { break }
    let hex = cid.to_hex()
    if visited.get(hex).unwrap_or(false) {
      continue
    }
    visited.set(hex, true)
    // Skip if in good set (boundary)
    if good_set.get(hex).unwrap_or(false) {
      continue
    }
    // Skip if in skip list
    let mut is_skipped = false
    for s in skips {
      if s.to_hex() == hex {
        is_skipped = true
        break
      }
    }
    if not(is_skipped) && cid != bad {
      candidates.push(cid)
    }
    // Add parents to queue
    let obj = db.get(rfs, cid)
    match obj {
      Some(o) => {
        let info = @git.parse_commit(o.data)
        for p in info.parents {
          queue.push(p)
        }
      }
      None => ()
    }
  }
  candidates
}

///|
fn mark_ancestors(
  db : @gitlib.ObjectDb,
  rfs : &@git.RepoFileSystem,
  start : @git.ObjectId,
  set : Map[String, Bool],
) -> Unit {
  let queue : Array[@git.ObjectId] = [start]
  while queue.length() > 0 {
    let current = queue.pop()
    guard current is Some(cid) else { break }
    let hex = cid.to_hex()
    if set.get(hex).unwrap_or(false) {
      continue
    }
    set.set(hex, true)
    let obj = db.get(rfs, cid) catch { _ => None }
    match obj {
      Some(o) => {
        let info = @git.parse_commit(o.data) catch { _ => continue }
        for p in info.parents {
          queue.push(p)
        }
      }
      None => ()
    }
  }
}

///|
async fn bisect_reset(
  wfs : &@git.FileSystem,
  rfs : &@git.RepoFileSystem,
  root : String,
  git_dir : String,
  args : Array[String],
) -> Unit raise Error {
  let bisect_start_path = git_dir + "/BISECT_START"
  let bisect_log_path = git_dir + "/BISECT_LOG"
  let bisect_terms_path = git_dir + "/BISECT_TERMS"
  let bisect_expected_path = git_dir + "/BISECT_EXPECTED_REV"
  let bisect_ancestors_path = git_dir + "/BISECT_ANCESTORS_OK"
  let bisect_names_path = git_dir + "/BISECT_NAMES"
  let bisect_refs_dir = git_dir + "/refs/bisect"
  // Check what to checkout
  let checkout_ref = if args.length() > 1 {
    args[1]
  } else if rfs.is_file(bisect_start_path) {
    rfs.read_file(bisect_start_path) |> decode_bytes |> trim_string
  } else {
    "HEAD"
  }
  // Checkout the ref
  if checkout_ref != "HEAD" && checkout_ref.length() > 0 {
    // Try to checkout branch
    if rfs.is_file(git_dir + "/refs/heads/" + checkout_ref) {
      // Checkout the branch (not detached)
      ignore(@gitlib.checkout(wfs, rfs, root, checkout_ref, detach=false))
    } else {
      // Try to checkout as a commit (detached)
      let target = @gitrepo.rev_parse(rfs, git_dir, checkout_ref)
      match target {
        Some(_) =>
          ignore(@gitlib.checkout(wfs, rfs, root, checkout_ref, detach=true))
        None => ()
      }
    }
  }
  // Clean up bisect state files
  wfs.remove_file(bisect_start_path) catch {
    err if @async.is_cancellation_error(err) => raise err
    _ => ()
  }
  wfs.remove_file(bisect_log_path) catch {
    err if @async.is_cancellation_error(err) => raise err
    _ => ()
  }
  wfs.remove_file(bisect_terms_path) catch {
    err if @async.is_cancellation_error(err) => raise err
    _ => ()
  }
  wfs.remove_file(bisect_expected_path) catch {
    err if @async.is_cancellation_error(err) => raise err
    _ => ()
  }
  wfs.remove_file(bisect_ancestors_path) catch {
    err if @async.is_cancellation_error(err) => raise err
    _ => ()
  }
  wfs.remove_file(bisect_names_path) catch {
    err if @async.is_cancellation_error(err) => raise err
    _ => ()
  }
  // Clean up refs/bisect
  let entries = (rfs : &@git.RepoFileSystem).readdir(bisect_refs_dir) catch {
    err if @async.is_cancellation_error(err) => raise err
    _ => []
  }
  for entry in entries {
    wfs.remove_file(bisect_refs_dir + "/" + entry) catch {
      err if @async.is_cancellation_error(err) => raise err
      _ => ()
    }
  }
  wfs.remove_file(bisect_refs_dir) catch {
    err if @async.is_cancellation_error(err) => raise err
    _ => ()
  }
  print_line("Bisect reset")
}

///|
async fn bisect_log(
  rfs : &@git.RepoFileSystem,
  git_dir : String,
) -> Unit raise Error {
  let bisect_log_path = git_dir + "/BISECT_LOG"
  if not(rfs.is_file(bisect_log_path)) {
    @stdio.stderr.write("error: no bisect log found")
    @sys.exit(1)
  }
  let content = decode_bytes(rfs.read_file(bisect_log_path))
  print_line(content)
}

///|
/// Handle git describe command

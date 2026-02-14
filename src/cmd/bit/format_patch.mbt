///|
async fn handle_format_patch(args : Array[String]) -> Unit raise Error {
  let root = get_work_root()
  let git_dir = root + "/.git"
  let fs = OsFs::new()
  let wfs : &@git.FileSystem = fs
  let rfs : &@git.RepoFileSystem = fs
  // Parse options
  let mut output_dir = "."
  let mut start_number = 1
  let mut numbered = false
  let mut stdout_mode = false
  let mut cover_letter = false
  let revisions : Array[String] = []
  let grep_patterns : Array[String] = []
  let mut grep_pattern_type_override : GrepPatternType? = None
  let mut grep_ignore_case = false
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    match arg {
      "-o" | "--output-directory" if i + 1 < args.length() => {
        output_dir = args[i + 1]
        i += 2
      }
      "--start-number" if i + 1 < args.length() => {
        start_number = parse_int(args[i + 1])
        i += 2
      }
      "-n" | "--numbered" => {
        numbered = true
        i += 1
      }
      "--stdout" => {
        stdout_mode = true
        i += 1
      }
      "--cover-letter" => {
        cover_letter = true
        i += 1
      }
      "--grep" if i + 1 < args.length() => {
        grep_patterns.push(args[i + 1])
        i += 2
      }
      _ if arg.has_prefix("--grep=") => {
        grep_patterns.push(String::unsafe_substring(arg, start=7, end=arg.length()))
        i += 1
      }
      "-i" | "--regexp-ignore-case" => {
        grep_ignore_case = true
        i += 1
      }
      "-F" | "--fixed-strings" => {
        grep_pattern_type_override = Some(GrepPatternType::Fixed)
        i += 1
      }
      "-E" | "--extended-regexp" => {
        grep_pattern_type_override = Some(GrepPatternType::Extended)
        i += 1
      }
      "-P" | "--perl-regexp" => {
        grep_pattern_type_override = Some(GrepPatternType::Perl)
        i += 1
      }
      "--basic-regexp" => {
        grep_pattern_type_override = Some(GrepPatternType::Basic)
        i += 1
      }
      _ if arg.has_prefix("-o") => {
        output_dir = String::unsafe_substring(arg, start=2, end=arg.length())
        i += 1
      }
      _ if not(arg.has_prefix("-")) => {
        revisions.push(arg)
        i += 1
      }
      _ => i += 1
    }
  }
  // Parse revision range
  let (base_commit, commits) = parse_format_patch_revisions(
    rfs, git_dir, revisions,
  )
  if commits.length() == 0 {
    @stdio.stderr.write("fatal: no commits specified")
    @sys.exit(128)
  }
  let grep_pattern_type = resolve_grep_pattern_type(
    rfs,
    git_dir,
    grep_pattern_type_override,
  )
  let db = @gitlib.ObjectDb::load(rfs, git_dir)
  let commits = filter_format_patch_commits_by_grep(
    db,
    rfs,
    commits,
    grep_patterns,
    grep_pattern_type,
    grep_ignore_case,
  )
  if commits.length() == 0 {
    return
  }
  // Create output directory if needed
  if not(stdout_mode) && not(rfs.is_dir(output_dir)) {
    wfs.mkdir_p(output_dir)
  }
  let total = commits.length()
  // Generate cover letter if requested
  if cover_letter && not(stdout_mode) {
    let cover_path = output_dir + "/0000-cover-letter.patch"
    let cover_content = generate_cover_letter(commits.length())
    wfs.write_string(cover_path, cover_content)
    print_line(cover_path)
  }
  // Generate patches
  for idx in 0..<commits.length() {
    let commit_id = commits[idx]
    let patch_num = start_number + idx
    let patch = generate_patch(
      db, rfs, commit_id, base_commit, patch_num, total, numbered,
    )
    if stdout_mode {
      print_line(patch)
      if idx < commits.length() - 1 {
        print_line("--")
      }
    } else {
      let filename = format_patch_filename(
        db, rfs, commit_id, patch_num, total, numbered,
      )
      let patch_path = output_dir + "/" + filename
      wfs.write_string(patch_path, patch)
      print_line(patch_path)
    }
  }
  ignore(base_commit)
}

///|
fn parse_format_patch_revisions(
  rfs : &@git.RepoFileSystem,
  git_dir : String,
  revisions : Array[String],
) -> (@git.ObjectId?, Array[@git.ObjectId]) raise Error {
  if revisions.length() == 0 {
    // Default: HEAD~1..HEAD (last commit)
    let head = @gitrepo.rev_parse(rfs, git_dir, "HEAD")
    guard head is Some(h) else { return (None, []) }
    return (None, [h])
  }
  let rev = revisions[0]
  // Check for range notation
  match rev.find("..") {
    Some(idx) => {
      let base_ref = String::unsafe_substring(rev, start=0, end=idx)
      let end_ref = String::unsafe_substring(
        rev,
        start=idx + 2,
        end=rev.length(),
      )
      let base_id = @gitrepo.rev_parse(rfs, git_dir, base_ref)
      let end_id = @gitrepo.rev_parse(
        rfs,
        git_dir,
        if end_ref.length() == 0 {
          "HEAD"
        } else {
          end_ref
        },
      )
      guard base_id is Some(bid) && end_id is Some(eid) else {
        return (None, [])
      }
      // Collect commits from end to base
      let commits = collect_commits_in_range(rfs, git_dir, bid, eid)
      (Some(bid), commits)
    }
    None =>
      // Check for -N notation (last N commits)
      if rev.has_prefix("-") {
        let n = parse_int(
          String::unsafe_substring(rev, start=1, end=rev.length()),
        )
        let commits = collect_last_n_commits(rfs, git_dir, n)
        (None, commits)
      } else {
        // Single commit
        let id = @gitrepo.rev_parse(rfs, git_dir, rev)
        guard id is Some(cid) else { return (None, []) }
        (None, [cid])
      }
  }
}

///|
fn collect_commits_in_range(
  rfs : &@git.RepoFileSystem,
  git_dir : String,
  base : @git.ObjectId,
  end : @git.ObjectId,
) -> Array[@git.ObjectId] raise Error {
  let db = @gitlib.ObjectDb::load(rfs, git_dir)
  let result : Array[@git.ObjectId] = []
  let mut current = end
  let base_hex = base.to_hex()
  while current.to_hex() != base_hex {
    result.push(current)
    let obj = db.get(rfs, current)
    guard obj is Some(o) else { break }
    let info = @git.parse_commit(o.data)
    if info.parents.length() == 0 {
      break
    }
    current = info.parents[0]
  }
  // Reverse to get chronological order
  result.rev_in_place()
  result
}

///|
fn collect_last_n_commits(
  rfs : &@git.RepoFileSystem,
  git_dir : String,
  n : Int,
) -> Array[@git.ObjectId] raise Error {
  let db = @gitlib.ObjectDb::load(rfs, git_dir)
  let head = @gitrepo.rev_parse(rfs, git_dir, "HEAD")
  guard head is Some(h) else { return [] }
  let result : Array[@git.ObjectId] = []
  let mut current = h
  for _ in 0..<n {
    result.push(current)
    let obj = db.get(rfs, current)
    guard obj is Some(o) else { break }
    let info = @git.parse_commit(o.data)
    if info.parents.length() == 0 {
      break
    }
    current = info.parents[0]
  }
  result.rev_in_place()
  result
}

///|
fn filter_format_patch_commits_by_grep(
  db : @gitlib.ObjectDb,
  rfs : &@git.RepoFileSystem,
  commits : Array[@git.ObjectId],
  grep_patterns : Array[String],
  grep_pattern_type : GrepPatternType,
  grep_ignore_case : Bool,
) -> Array[@git.ObjectId] raise Error {
  if grep_patterns.length() == 0 {
    return commits
  }
  let filtered : Array[@git.ObjectId] = []
  for commit_id in commits {
    let obj = db.get(rfs, commit_id)
    guard obj is Some(o) else {
      continue
    }
    if o.obj_type != @git.ObjectType::Commit {
      continue
    }
    let commit_message = extract_commit_message_from_raw(o.data)
    if grep_patterns_match_message(
      commit_message,
      grep_patterns,
      grep_pattern_type,
      grep_ignore_case,
    ) {
      filtered.push(commit_id)
    }
  }
  filtered
}

///|
fn generate_cover_letter(num_patches : Int) -> String {
  let sb = StringBuilder::new()
  sb.write_string(
    "From 0000000000000000000000000000000000000000 Mon Sep 17 00:00:00 2001\n",
  )
  sb.write_string("Subject: [PATCH 0/")
  sb.write_string(num_patches.to_string())
  sb.write_string("] *** SUBJECT HERE ***\n\n")
  sb.write_string("*** BLURB HERE ***\n\n")
  sb.to_string()
}

///|
fn generate_patch(
  db : @gitlib.ObjectDb,
  rfs : &@git.RepoFileSystem,
  commit_id : @git.ObjectId,
  _base : @git.ObjectId?,
  patch_num : Int,
  total : Int,
  numbered : Bool,
) -> String raise Error {
  let obj = db.get(rfs, commit_id)
  guard obj is Some(o) else {
    raise @git.GitError::InvalidObject("commit not found")
  }
  let commit_text = decode_bytes(o.data)
  let info = @git.parse_commit(o.data)
  // Extract commit details
  let author_line = extract_author_line(commit_text)
  let message = extract_commit_message(o.data)
  let subject = get_first_line(message)
  let body = get_rest_lines(message)
  // Build patch header
  let sb = StringBuilder::new()
  sb.write_string("From ")
  sb.write_string(commit_id.to_hex())
  sb.write_string(" Mon Sep 17 00:00:00 2001\n")
  sb.write_string("From: ")
  sb.write_string(author_line)
  sb.write_string("\n")
  // Date from author line
  let (_, author_time, author_tz) = parse_author_info(author_line)
  sb.write_string("Date: ")
  sb.write_string(format_email_date(author_time, author_tz))
  sb.write_string("\n")
  // Subject
  sb.write_string("Subject: ")
  if numbered || total > 1 {
    sb.write_string("[PATCH ")
    sb.write_string(patch_num.to_string())
    sb.write_string("/")
    sb.write_string(total.to_string())
    sb.write_string("] ")
  }
  sb.write_string(subject)
  sb.write_string("\n\n")
  // Body
  if body.length() > 0 {
    sb.write_string(body)
    sb.write_string("\n")
  }
  sb.write_string("---\n")
  // Generate diff
  let parent_id = if info.parents.length() > 0 {
    Some(info.parents[0])
  } else {
    None
  }
  let diff = generate_commit_diff(db, rfs, commit_id, parent_id)
  sb.write_string(diff)
  sb.write_string("\n-- \n2.47.0 (bit)\n\n")
  sb.to_string()
}

///|
fn format_patch_filename(
  db : @gitlib.ObjectDb,
  rfs : &@git.RepoFileSystem,
  commit_id : @git.ObjectId,
  patch_num : Int,
  _total : Int,
  _numbered : Bool,
) -> String raise Error {
  let obj = db.get(rfs, commit_id)
  guard obj is Some(o) else {
    return pad_left_zero(patch_num.to_string(), 4) + "-patch.patch"
  }
  let message = extract_commit_message(o.data)
  let subject = get_first_line(message)
  // Sanitize subject for filename
  let sanitized = sanitize_filename(subject)
  let num_str = pad_left_zero(patch_num.to_string(), 4)
  num_str + "-" + sanitized + ".patch"
}

///|
fn sanitize_filename(s : String) -> String {
  let sb = StringBuilder::new()
  let mut last_was_dash = false
  for c in s {
    if (c >= 'a' && c <= 'z') ||
      (c >= 'A' && c <= 'Z') ||
      (c >= '0' && c <= '9') {
      sb.write_char(c)
      last_was_dash = false
    } else if not(last_was_dash) {
      sb.write_char('-')
      last_was_dash = true
    }
  }
  let result = sb.to_string()
  // Trim trailing dash
  if result.length() > 0 && result[result.length() - 1] == '-' {
    String::unsafe_substring(result, start=0, end=result.length() - 1)
  } else {
    result
  }
}

///|
fn get_first_line(s : String) -> String {
  match s.find("\n") {
    Some(idx) => String::unsafe_substring(s, start=0, end=idx)
    None => s
  }
}

///|
fn get_rest_lines(s : String) -> String {
  match s.find("\n") {
    Some(idx) =>
      trim_string(String::unsafe_substring(s, start=idx + 1, end=s.length()))
    None => ""
  }
}

///|
fn format_email_date(ts : Int64, tz : String) -> String {
  let secs = ts.to_int()
  let days = secs / 86400
  let time_of_day = secs % 86400
  let hours = time_of_day / 3600
  let minutes = time_of_day % 3600 / 60
  let seconds = time_of_day % 60
  let (year, month, day) = days_to_date(days)
  let weekday = (days + 4) % 7 // Jan 1, 1970 was Thursday (4)
  let weekday_names = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
  let month_names = [
    "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov",
    "Dec",
  ]
  let wd = weekday_names[weekday]
  let mn = month_names[month - 1]
  "\{wd}, \{day} \{mn} \{year} \{pad_left_zero(hours.to_string(), 2)}:\{pad_left_zero(minutes.to_string(), 2)}:\{pad_left_zero(seconds.to_string(), 2)} \{tz}"
}

///|
fn generate_commit_diff(
  db : @gitlib.ObjectDb,
  rfs : &@git.RepoFileSystem,
  commit_id : @git.ObjectId,
  parent_id : @git.ObjectId?,
) -> String raise Error {
  let obj = db.get(rfs, commit_id)
  guard obj is Some(o) else { return "" }
  let info = @git.parse_commit(o.data)
  let tree = info.tree
  let parent_tree = match parent_id {
    Some(pid) => {
      let pobj = db.get(rfs, pid)
      match pobj {
        Some(po) => {
          let pinfo = @git.parse_commit(po.data)
          Some(pinfo.tree)
        }
        None => None
      }
    }
    None => None
  }
  // Generate diff between trees
  diff_trees(db, rfs, parent_tree, tree, "")
}

///|
fn diff_trees(
  db : @gitlib.ObjectDb,
  rfs : &@git.RepoFileSystem,
  old_tree : @git.ObjectId?,
  new_tree : @git.ObjectId,
  prefix : String,
) -> String raise Error {
  let sb = StringBuilder::new()
  let new_entries = get_tree_entries(db, rfs, new_tree)
  let old_entries : Map[String, @git.TreeEntry] = {}
  match old_tree {
    Some(ot) => {
      let entries = get_tree_entries(db, rfs, ot)
      for e in entries {
        old_entries[e.name] = e
      }
    }
    None => ()
  }
  // Check for new/modified files
  for entry in new_entries {
    let path = if prefix.length() > 0 {
      prefix + "/" + entry.name
    } else {
      entry.name
    }
    if entry.mode == "40000" {
      // Directory - recurse
      let old_subtree = match old_entries.get(entry.name) {
        Some(oe) if oe.mode == "40000" => Some(oe.id)
        _ => None
      }
      let sub_diff = diff_trees(db, rfs, old_subtree, entry.id, path)
      sb.write_string(sub_diff)
    } else {
      // File
      match old_entries.get(entry.name) {
        Some(oe) if oe.id.to_hex() != entry.id.to_hex() => {
          // Modified
          let diff = diff_blobs(db, rfs, Some(oe.id), entry.id, path)
          sb.write_string(diff)
        }
        None => {
          // New file
          let diff = diff_blobs(db, rfs, None, entry.id, path)
          sb.write_string(diff)
        }
        _ => ()
      }
    }
  }
  // Check for deleted files
  for name, entry in old_entries {
    if entry.mode != "40000" {
      let mut found = false
      for ne in new_entries {
        if ne.name == name {
          found = true
          break
        }
      }
      if not(found) {
        let path = if prefix.length() > 0 { prefix + "/" + name } else { name }
        let diff = diff_blobs(db, rfs, Some(entry.id), entry.id, path) // Deleted
        sb.write_string(diff)
      }
    }
  }
  sb.to_string()
}

///|
fn get_tree_entries(
  db : @gitlib.ObjectDb,
  rfs : &@git.RepoFileSystem,
  tree_id : @git.ObjectId,
) -> Array[@git.TreeEntry] raise Error {
  let obj = db.get(rfs, tree_id)
  guard obj is Some(o) else { return [] }
  @git.parse_tree(o.data)
}

///|
fn diff_blobs(
  db : @gitlib.ObjectDb,
  rfs : &@git.RepoFileSystem,
  old_id : @git.ObjectId?,
  new_id : @git.ObjectId,
  path : String,
) -> String raise Error {
  let sb = StringBuilder::new()
  let old_content = match old_id {
    Some(oid) => {
      let obj = db.get(rfs, oid)
      match obj {
        Some(o) => decode_bytes(o.data)
        None => ""
      }
    }
    None => ""
  }
  let new_obj = db.get(rfs, new_id)
  let new_content = match new_obj {
    Some(o) => decode_bytes(o.data)
    None => ""
  }
  sb.write_string("diff --git a/")
  sb.write_string(path)
  sb.write_string(" b/")
  sb.write_string(path)
  sb.write_string("\n")
  if old_id is None {
    sb.write_string("new file mode 100644\n")
  }
  sb.write_string("--- ")
  if old_id is Some(_) {
    sb.write_string("a/")
    sb.write_string(path)
  } else {
    sb.write_string("/dev/null")
  }
  sb.write_string("\n+++ b/")
  sb.write_string(path)
  sb.write_string("\n")
  // Simple line-by-line diff
  let old_lines = split_lines(old_content)
  let new_lines = split_lines(new_content)
  sb.write_string("@@ -1,")
  sb.write_string(old_lines.length().to_string())
  sb.write_string(" +1,")
  sb.write_string(new_lines.length().to_string())
  sb.write_string(" @@\n")
  for line in old_lines {
    sb.write_string("-")
    sb.write_string(line)
    sb.write_string("\n")
  }
  for line in new_lines {
    sb.write_string("+")
    sb.write_string(line)
    sb.write_string("\n")
  }
  sb.to_string()
}

///|
/// Handle git shortlog command

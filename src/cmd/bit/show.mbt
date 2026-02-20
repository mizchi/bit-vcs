///|

///|
async fn show_show_command_help() -> Unit {
  show_simple_command_help(
    "git show [<options>] [<object>...]",
    summary="Show various types of objects.",
  )
}

///|
priv struct ShowCommitInfo {
  author : String
  timestamp : Int64
  timezone : String
  message : String
}

///|
fn parse_show_commit(data : Bytes) -> ShowCommitInfo {
  let text = decode_bytes(data)
  let mut author = ""
  let mut timestamp = 0L
  let mut timezone = "+0000"
  let mut in_message = false
  let message_lines : Array[String] = []
  for line_view in text.split("\n") {
    let line = line_view.to_string()
    if in_message {
      message_lines.push(line)
      continue
    }
    if line.length() == 0 {
      in_message = true
      continue
    }
    if line.has_prefix("author ") {
      let rest = String::unsafe_substring(line, start=7, end=line.length())
      // format: Name <email> 1700000000 +0000
      let mut last_space = rest.rev_find(" ")
      if last_space is Some(tz_idx) {
        let before_tz = String::unsafe_substring(rest, start=0, end=tz_idx)
        timezone = String::unsafe_substring(
          rest,
          start=tz_idx + 1,
          end=rest.length(),
        )
        last_space = before_tz.rev_find(" ")
        if last_space is Some(time_idx) {
          author = String::unsafe_substring(before_tz, start=0, end=time_idx)
          let time_str = String::unsafe_substring(
            before_tz,
            start=time_idx + 1,
            end=before_tz.length(),
          )
          for c in time_str {
            if c >= '0' && c <= '9' {
              let digit = c.to_int() - '0'.to_int()
              timestamp = timestamp * 10L + digit.to_int64()
            }
          }
        } else {
          author = before_tz
        }
      } else {
        author = rest
      }
    }
  }
  let message = message_lines.join("\n")
  { author, timestamp, timezone, message }
}

///|
fn show_first_message_line(message : String) -> String {
  match message.find("\n") {
    Some(idx) => String::unsafe_substring(message, start=0, end=idx)
    None => message
  }
}

///|
fn format_show_date(timestamp : Int64, timezone : String) -> String {
  let tz_offset = parse_timezone_offset_seconds(timezone)
  let local_seconds = timestamp.to_int() + tz_offset
  let days = local_seconds / 86400
  let time_of_day = local_seconds % 86400
  let hours = time_of_day / 3600
  let minutes = time_of_day % 3600 / 60
  let seconds = time_of_day % 60
  let (year, month, day) = days_to_date(days)
  let weekday = (days + 4) % 7 // Jan 1, 1970 was Thursday.
  let weekday_names = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
  let month_names = [
    "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov",
    "Dec",
  ]
  let wd = weekday_names[weekday]
  let mn = month_names[month - 1]
  "\{wd} \{mn} \{day} \{pad_left_zero(hours.to_string(), 2)}:\{pad_left_zero(minutes.to_string(), 2)}:\{pad_left_zero(seconds.to_string(), 2)} \{year} \{timezone}"
}

///|
fn parse_timezone_offset_seconds(timezone : String) -> Int {
  if timezone.length() != 5 {
    return 0
  }
  let sign = timezone.unsafe_get(0)
  if sign != '+' && sign != '-' {
    return 0
  }
  let hh = String::unsafe_substring(timezone, start=1, end=3)
  let mm = String::unsafe_substring(timezone, start=3, end=5)
  let hours = @strconv.parse_int(hh) catch { _ => return 0 }
  let minutes = @strconv.parse_int(mm) catch { _ => return 0 }
  let total = hours * 3600 + minutes * 60
  if sign == '-' {
    -total
  } else {
    total
  }
}

///|
async fn handle_show(args : Array[String]) -> Unit raise Error {
  let root = get_work_root()
  let fs = OsFs::new()
  let git_dir = resolve_git_dir(fs, root)
  // Parse: git show [--pretty=<format>] [<commit>]
  let mut rev = "HEAD"
  let revs : Array[String] = []
  let mut pretty_raw = false
  let mut pretty_format : String? = None
  let mut quiet = false
  let mut oneline = false
  let grep_patterns : Array[String] = []
  let mut grep_pattern_type_override : GrepPatternType? = None
  let mut grep_ignore_case = false
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    if arg == "--pretty=raw" || arg == "--format=raw" {
      pretty_raw = true
    } else if arg == "-q" ||
      arg == "--quiet" ||
      arg == "-s" ||
      arg == "--no-patch" {
      quiet = true
    } else if arg == "--oneline" {
      oneline = true
    } else if arg.has_prefix("--pretty=format:") {
      pretty_format = Some(
        String::unsafe_substring(arg, start=16, end=arg.length()),
      )
    } else if arg.has_prefix("--pretty=tformat:") {
      pretty_format = Some(
        String::unsafe_substring(arg, start=17, end=arg.length()),
      )
    } else if arg.has_prefix("--pretty=") {
      pretty_format = Some(
        String::unsafe_substring(arg, start=9, end=arg.length()),
      )
    } else if arg.has_prefix("--format=") {
      pretty_format = Some(
        String::unsafe_substring(arg, start=9, end=arg.length()),
      )
    } else if arg == "--grep" && i + 1 < args.length() {
      grep_patterns.push(args[i + 1])
      i += 1
    } else if arg.has_prefix("--grep=") {
      grep_patterns.push(
        String::unsafe_substring(arg, start=7, end=arg.length()),
      )
    } else if arg == "-i" || arg == "--regexp-ignore-case" {
      grep_ignore_case = true
    } else if arg == "-F" || arg == "--fixed-strings" {
      grep_pattern_type_override = Some(GrepPatternType::Fixed)
    } else if arg == "-E" || arg == "--extended-regexp" {
      grep_pattern_type_override = Some(GrepPatternType::Extended)
    } else if arg == "-P" || arg == "--perl-regexp" {
      grep_pattern_type_override = Some(GrepPatternType::Perl)
    } else if arg == "--basic-regexp" {
      grep_pattern_type_override = Some(GrepPatternType::Basic)
    } else if not(arg.has_prefix("-")) {
      rev = arg
      revs.push(arg)
    } else {
      warn_unimplemented_arg("show", arg)
    }
    i += 1
  }
  let grep_pattern_type = resolve_grep_pattern_type(
    fs, git_dir, grep_pattern_type_override,
  )
  if oneline && quiet {
    let targets : Array[String] = if revs.length() > 0 {
      revs
    } else {
      ["HEAD"]
    }
    let db = @bitlib.ObjectDb::load(fs, git_dir)
    for target in targets {
      let id = @bitrepo.rev_parse(fs, git_dir, target)
      guard id is Some(commit_id) else {
        raise @bitcore.GitError::InvalidObject("unknown revision: \{target}")
      }
      let obj = db.get(fs, commit_id)
      guard obj is Some(o) else {
        raise @bitcore.GitError::InvalidObject(
          "Object not found: \{commit_id.to_hex()}",
        )
      }
      if o.obj_type != @bitcore.ObjectType::Commit {
        continue
      }
      let info = parse_show_commit(o.data)
      if not(
          grep_patterns_match_message(
            info.message,
            grep_patterns,
            grep_pattern_type,
            grep_ignore_case,
          ),
        ) {
        continue
      }
      let short = String::unsafe_substring(commit_id.to_hex(), start=0, end=7)
      print_line(short + " " + show_first_message_line(info.message))
    }
    return ()
  }
  // Resolve revision
  let id = @bitrepo.rev_parse(fs, git_dir, rev)
  guard id is Some(commit_id) else {
    raise @bitcore.GitError::InvalidObject("unknown revision: \{rev}")
  }
  // Load object
  let db = @bitlib.ObjectDb::load(fs, git_dir)
  let obj = db.get(fs, commit_id)
  guard obj is Some(o) else {
    raise @bitcore.GitError::InvalidObject(
      "Object not found: \{commit_id.to_hex()}",
    )
  }
  // `git show <blob-ish>` should print blob contents directly.
  if o.obj_type == @bitcore.ObjectType::Blob {
    @stdio.stdout.write(o.data)
    return ()
  }
  if o.obj_type != @bitcore.ObjectType::Commit {
    raise @bitcore.GitError::InvalidObject(
      "Not a commit: \{commit_id.to_hex()}",
    )
  }
  // Parse commit for tree/parents
  let commit_info = @bitcore.parse_commit(o.data)
  // If --pretty=raw, output raw commit object content
  if pretty_raw {
    print_line("commit \{commit_id.to_hex()}")
    // Output the raw commit object as text
    let text = decode_bytes(o.data)
    print_str(text)
    if not(text.has_suffix("\n")) {
      print_line("")
    }
    return ()
  }
  if pretty_format is Some(fmt) {
    match fmt {
      "%h" => {
        let short = String::unsafe_substring(commit_id.to_hex(), start=0, end=7)
        print_line(short)
        return ()
      }
      "%H" => {
        print_line(commit_id.to_hex())
        return ()
      }
      "%s" => {
        let info = parse_show_commit(o.data)
        print_line(show_first_message_line(info.message))
        return ()
      }
      _ => warn_unimplemented_arg("show", "--pretty=format:\{fmt}")
    }
  }
  // Parse full commit details
  let show_info = parse_show_commit(o.data)
  if not(
      grep_patterns_match_message(
        show_info.message,
        grep_patterns,
        grep_pattern_type,
        grep_ignore_case,
      ),
    ) {
    return ()
  }
  // Print commit info
  print_line("commit \{commit_id.to_hex()}")
  print_line("Author: \{show_info.author}")
  print_line(
    "Date:   \{format_show_date(show_info.timestamp, show_info.timezone)}",
  )
  print_line("")
  // Print message with indentation
  for line_view in show_info.message.split("\n") {
    print_line("    \{line_view.to_string()}")
  }
  print_line("")
  // Show diff against parent (simplified)
  if not(quiet) && commit_info.parents.length() > 0 {
    let parent_id = commit_info.parents[0]
    let parent_files = @bitlib.collect_tree_files_from_commit(db, fs, parent_id)
    let current_files = @bitlib.collect_tree_files_from_commit(
      db, fs, commit_id,
    )
    // Show changed files
    for item in current_files.to_array() {
      let (path, entry) = item
      match parent_files.get(path) {
        None => print_line("diff --git a/\{path} b/\{path}\nnew file")
        Some(parent_entry) =>
          if entry.id != parent_entry.id {
            print_line("diff --git a/\{path} b/\{path}")
          }
      }
    }
    for item in parent_files.to_array() {
      let (path, _) = item
      if not(current_files.contains(path)) {
        print_line("diff --git a/\{path} b/\{path}\ndeleted file")
      }
    }
  }
}

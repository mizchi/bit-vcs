///|
priv struct ReflogShowArgs {
  refname : String
  no_abbrev_commit : Bool
  grep_patterns : Array[String]
  grep_pattern_type_override : GrepPatternType?
  grep_ignore_case : Bool
}

///|
async fn handle_reflog(args : Array[String]) -> Unit raise Error {
  let root = get_work_root()
  let git_dir = root + "/.git"
  let fs = OsFs::new()
  let rfs : &@git.RepoFileSystem = fs
  let wfs : &@git.FileSystem = fs
  let empty_grep_patterns : Array[String] = []
  if args.length() == 0 {
    // Default to show HEAD
    show_reflog(
      rfs,
      git_dir,
      "HEAD",
      false,
      empty_grep_patterns,
      GrepPatternType::Basic,
      false,
    )
    return
  }
  let subcmd = args[0]
  let rest : Array[String] = []
  for i in 1..<args.length() {
    rest.push(args[i])
  }
  match subcmd {
    "show" => {
      let parsed = parse_reflog_show_args(rest)
      let grep_pattern_type = resolve_grep_pattern_type(
        rfs,
        git_dir,
        parsed.grep_pattern_type_override,
      )
      show_reflog(
        rfs,
        git_dir,
        parsed.refname,
        parsed.no_abbrev_commit,
        parsed.grep_patterns,
        grep_pattern_type,
        parsed.grep_ignore_case,
      )
    }
    "exists" => {
      if rest.length() == 0 {
        @stdio.stderr.write("usage: git reflog exists <ref>")
        @sys.exit(1)
      }
      let refname = rest[0]
      if @gitrepo.reflog_exists(rfs, git_dir, refname) {
        @sys.exit(0)
      } else {
        @sys.exit(1)
      }
    }
    "delete" => {
      if rest.length() == 0 {
        @stdio.stderr.write("usage: git reflog delete <ref>")
        @sys.exit(1)
      }
      let refname = rest[0]
      @gitrepo.delete_reflog(wfs, rfs, git_dir, refname)
    }
    "expire" =>
      // For now, just a no-op (would need to implement expiry logic)
      ()
    _ => {
      let show_args : Array[String] = []
      show_args.push(subcmd)
      show_args.append(rest)
      let parsed = parse_reflog_show_args(show_args)
      let grep_pattern_type = resolve_grep_pattern_type(
        rfs,
        git_dir,
        parsed.grep_pattern_type_override,
      )
      // Treat as a ref name for show
      show_reflog(
        rfs,
        git_dir,
        parsed.refname,
        parsed.no_abbrev_commit,
        parsed.grep_patterns,
        grep_pattern_type,
        parsed.grep_ignore_case,
      )
    }
  }
}

///|
async fn show_reflog(
  fs : &@git.RepoFileSystem,
  git_dir : String,
  refname : String,
  no_abbrev_commit : Bool,
  grep_patterns : Array[String],
  grep_pattern_type : GrepPatternType,
  grep_ignore_case : Bool,
) -> Unit raise Error {
  let entries = @gitrepo.read_reflog(fs, git_dir, refname)
  if entries.length() == 0 && refname == "HEAD" {
    // Some pure commit paths may not materialize logs/HEAD.
    // Fall back to HEAD history so `reflog --grep` semantics remain usable.
    let max_count = 64
    let commits = @gitlib.log_head(fs, git_dir, max_count~)
    let mut fallback_index = 0
    for entry in commits {
      let message = "commit: " + entry.message
      if not(
        grep_patterns_match_message(
          message,
          grep_patterns,
          grep_pattern_type,
          grep_ignore_case,
        ),
      ) {
        continue
      }
      let sha = if no_abbrev_commit {
        entry.id.to_hex()
      } else {
        String::unsafe_substring(entry.id.to_hex(), start=0, end=7)
      }
      print_line("\{sha} HEAD@{\{fallback_index}}: \{message}")
      fallback_index += 1
    }
    return
  }
  // Show in reverse order (newest first)
  let len = entries.length()
  for i in 0..<len {
    let idx = len - 1 - i
    let entry = entries[idx]
    if not(
      grep_patterns_match_message(
        entry.message,
        grep_patterns,
        grep_pattern_type,
        grep_ignore_case,
      ),
    ) {
      continue
    }
    let sha = if no_abbrev_commit {
      entry.new_id.to_hex()
    } else {
      String::unsafe_substring(entry.new_id.to_hex(), start=0, end=7)
    }
    print_line("\{sha} \{refname}@{\{i}}: \{entry.message}")
  }
}

///|
fn parse_reflog_show_args(args : Array[String]) -> ReflogShowArgs {
  let mut refname = "HEAD"
  let mut no_abbrev_commit = false
  let mut has_refname = false
  let grep_patterns : Array[String] = []
  let mut grep_pattern_type_override : GrepPatternType? = None
  let mut grep_ignore_case = false
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    match arg {
      "--no-abbrev-commit" => no_abbrev_commit = true
      "--grep" if i + 1 < args.length() => {
        grep_patterns.push(args[i + 1])
        i += 1
      }
      _ if arg.has_prefix("--grep=") =>
        grep_patterns.push(String::unsafe_substring(arg, start=7, end=arg.length()))
      "-i" | "--regexp-ignore-case" => grep_ignore_case = true
      "-F" | "--fixed-strings" =>
        grep_pattern_type_override = Some(GrepPatternType::Fixed)
      "-E" | "--extended-regexp" =>
        grep_pattern_type_override = Some(GrepPatternType::Extended)
      "-P" | "--perl-regexp" =>
        grep_pattern_type_override = Some(GrepPatternType::Perl)
      "--basic-regexp" =>
        grep_pattern_type_override = Some(GrepPatternType::Basic)
      _ if arg.has_prefix("-") => ()
      _ =>
        if not(has_refname) {
          refname = arg
          has_refname = true
        }
    }
    i += 1
  }
  {
    refname,
    no_abbrev_commit,
    grep_patterns,
    grep_pattern_type_override,
    grep_ignore_case,
  }
}

///|

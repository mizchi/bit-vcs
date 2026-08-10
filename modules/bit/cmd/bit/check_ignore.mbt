///| git check-ignore - check gitignore rules

///|
async fn handle_check_ignore(args : Array[String]) -> Unit raise Error {
  let fs = OsFs::new()
  let mut verbose = false
  let mut quiet = false
  let mut use_stdin = false
  let mut nul_terminated = false
  let mut non_matching = false
  let mut no_index = false
  let positional : Array[String] = []
  let mut past_dashdash = false
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    if past_dashdash {
      positional.push(arg)
      i += 1
      continue
    }
    match arg {
      "-v" | "--verbose" => verbose = true
      "-q" | "--quiet" => quiet = true
      "--stdin" => use_stdin = true
      "-z" => nul_terminated = true
      "-n" | "--non-matching" => non_matching = true
      "--no-index" => no_index = true
      "--index" => no_index = false
      "-h" | "--help" => {
        show_simple_command_help(
          "git check-ignore [<options>] <pathname>...",
          summary="Check whether paths are excluded by .gitignore.",
        )
        return
      }
      "--" => past_dashdash = true
      _ if arg.has_prefix("-") => warn_unimplemented_arg("check-ignore", arg)
      _ => positional.push(arg)
    }
    i += 1
  }
  match
    check_ignore_validation_error(
      quiet,
      verbose,
      use_stdin,
      nul_terminated,
      non_matching,
      positional.length(),
    ) {
    Some(message) => {
      eprint_line("fatal: " + message)
      @sys.exit(128)
      return
    }
    None => ()
  }
  let paths : Array[String] = []
  paths.append(positional)
  // Read paths from stdin if --stdin
  if use_stdin {
    let data = read_all_stdin()
    let text = decode_bytes(data)
    let sep = if nul_terminated { "\u0000" } else { "\n" }
    for part_view in text.split(sep) {
      let part = part_view.to_owned()
      if part.length() > 0 {
        paths.push(part)
      }
    }
  }
  // Load ignore rules
  let root = get_work_root()
  let git_dir = find_git_dir(fs)
  let cwd_prefix = compute_cwd_prefix(root)
  let tracked_paths = check_ignore_tracked_paths(fs, git_dir, no_index)
  let line_sep = if nul_terminated { "\u0000" } else { "\n" }
  let mut had_match = false
  for path in paths {
    // Normalize path: strip leading ./ if present
    let normalized = check_ignore_repo_relative_path(path, cwd_prefix)
    // Build matcher with all relevant .gitignore files
    let path_matcher = @ignore.Matcher::new()
    check_ignore_add_standard_rules(fs, root, git_dir, path_matcher)
    // Load intermediate .gitignore files
    let segments = check_ignore_split_path(normalized)
    let mut base = ""
    let seg_limit = segments.length() - 1
    for j in 0..<seg_limit {
      base = if base == "" { segments[j] } else { base + "/" + segments[j] }
      check_ignore_add_rules_file(
        fs,
        path_matcher,
        root + "/" + base + "/.gitignore",
        base,
      )
    }
    let is_dir = fs.is_dir(root + "/" + normalized)
    let is_tracked = tracked_paths.contains(normalized)
    let ignored = !is_tracked && path_matcher.is_ignored(normalized, is_dir)
    let match_info = if verbose && !is_tracked {
      Some(check_ignore_find_rule(fs, root, git_dir, normalized, is_dir))
    } else {
      None
    }
    if ignored {
      had_match = true
      if !quiet {
        if verbose {
          // Verbose: show which rule matched
          match match_info {
            Some(info) =>
              print_str(
                info.0 +
                ":" +
                info.1.to_string() +
                ":" +
                info.2 +
                "\t" +
                path +
                line_sep,
              )
            None => ()
          }
        } else {
          print_str(path + line_sep)
        }
      }
    } else if verbose {
      match match_info {
        Some(info) if info.1 > 0 => {
          had_match = true
          print_str(
            info.0 +
            ":" +
            info.1.to_string() +
            ":" +
            info.2 +
            "\t" +
            path +
            line_sep,
          )
        }
        _ if non_matching =>
          // Show non-matching path with :: prefix
          print_str("::\t" + path + line_sep)
        _ => ()
      }
    }
  }
  if !had_match {
    @sys.exit(1)
  }
}

///|
fn check_ignore_validation_error(
  quiet : Bool,
  verbose : Bool,
  use_stdin : Bool,
  nul_terminated : Bool,
  non_matching : Bool,
  positional_len : Int,
) -> String? {
  if quiet && verbose {
    return Some("cannot have both --quiet and --verbose")
  }
  if use_stdin && positional_len > 0 {
    return Some("cannot specify pathnames with --stdin")
  }
  if nul_terminated && !use_stdin {
    return Some("-z only makes sense with --stdin")
  }
  if !use_stdin && positional_len == 0 {
    return Some("no path specified")
  }
  if quiet && positional_len > 1 {
    return Some("--quiet is only valid with a single pathname")
  }
  if non_matching && !verbose {
    return Some("--non-matching is only valid with --verbose")
  }
  None
}

///|
fn check_ignore_repo_relative_path(
  path : String,
  cwd_prefix : String,
) -> String {
  let normalized = if path.has_prefix("./") {
    String::unsafe_substring(path, start=2, end=path.length())
  } else {
    path
  }
  if cwd_prefix.length() == 0 ||
    normalized.has_prefix("../") ||
    normalized == ".." ||
    normalized.has_prefix("/") {
    normalized
  } else {
    cwd_prefix + "/" + normalized
  }
}

///|
fn check_ignore_tracked_paths(
  fs : &@bitcore.RepoFileSystem,
  git_dir : String,
  no_index : Bool,
) -> Map[String, Bool] {
  let tracked : Map[String, Bool] = Map([])
  if no_index {
    return tracked
  }
  let entries = @bitlib.read_index_entries(fs, git_dir) catch { _ => [] }
  for entry in entries {
    tracked[entry.path] = true
  }
  tracked
}

///|
fn check_ignore_add_standard_rules(
  fs : &@bitcore.RepoFileSystem,
  root : String,
  git_dir : String,
  matcher : @ignore.Matcher,
) -> Unit {
  match check_ignore_global_excludes_file(fs, root, git_dir) {
    Some((_, path)) => check_ignore_add_rules_file(fs, matcher, path, "")
    None => ()
  }
  check_ignore_add_rules_file(fs, matcher, git_dir + "/info/exclude", "")
  check_ignore_add_rules_file(fs, matcher, root + "/.gitignore", "")
}

///|
fn check_ignore_global_excludes_file(
  fs : &@bitcore.RepoFileSystem,
  root : String,
  git_dir : String,
) -> (String, String)? {
  let config_path = git_dir + "/config"
  if !fs.is_file(config_path) {
    return None
  }
  match @bitlib.read_config_value(fs, config_path, "core", "excludesfile") {
    Some(raw) =>
      Some((raw, ls_files_resolve_exclude_file_path(root, git_dir, raw)))
    None => None
  }
}

///|
fn check_ignore_add_rules_file(
  fs : &@bitcore.RepoFileSystem,
  matcher : @ignore.Matcher,
  file_path : String,
  base : String,
) -> Unit {
  if fs.is_file(file_path) {
    let content = decode_bytes(
      fs.read_file(file_path) catch {
        _ => Default::default()
      },
    )
    matcher.add_rules(base, content)
  }
}

///|
fn check_ignore_split_path(path : String) -> Array[String] {
  let out : Array[String] = []
  for part_view in path.split("/") {
    let part = part_view.to_owned()
    if part.length() > 0 {
      out.push(part)
    }
  }
  out
}

///|
fn check_ignore_find_rule(
  fs : &@bitcore.RepoFileSystem,
  root : String,
  git_dir : String,
  rel_path : String,
  is_dir : Bool,
) -> (String, Int, String) {
  // Check .gitignore files in order, find the last matching rule
  let mut last_source = ""
  let mut last_linenum = 0
  let mut last_pattern = ""
  // Check global exclude file first (lowest priority)
  match check_ignore_global_excludes_file(fs, root, git_dir) {
    Some((source, path)) => {
      let global_result = check_ignore_scan_file(
        fs, path, source, "", rel_path, is_dir,
      )
      if global_result.1 > 0 {
        last_source = global_result.0
        last_linenum = global_result.1
        last_pattern = global_result.2
      }
    }
    None => ()
  }
  // Check .git/info/exclude
  let exclude_file = git_dir + "/info/exclude"
  let excl_result = check_ignore_scan_file(
    fs, exclude_file, ".git/info/exclude", "", rel_path, is_dir,
  )
  if excl_result.1 > 0 {
    last_source = excl_result.0
    last_linenum = excl_result.1
    last_pattern = excl_result.2
  }
  // Check root .gitignore
  let root_result = check_ignore_scan_file(
    fs,
    root + "/.gitignore",
    ".gitignore",
    "",
    rel_path,
    is_dir,
  )
  if root_result.1 > 0 {
    last_source = root_result.0
    last_linenum = root_result.1
    last_pattern = root_result.2
  }
  // Check intermediate .gitignore files
  let segments = check_ignore_split_path(rel_path)
  let mut base = ""
  let seg_limit = segments.length() - 1
  for j in 0..<seg_limit {
    base = if base == "" { segments[j] } else { base + "/" + segments[j] }
    let dir_result = check_ignore_scan_file(
      fs,
      root + "/" + base + "/.gitignore",
      base + "/.gitignore",
      base,
      rel_path,
      is_dir,
    )
    if dir_result.1 > 0 {
      last_source = dir_result.0
      last_linenum = dir_result.1
      last_pattern = dir_result.2
    }
  }
  (last_source, last_linenum, last_pattern)
}

///|
fn check_ignore_scan_file(
  fs : &@bitcore.RepoFileSystem,
  file_path : String,
  source_name : String,
  base : String,
  rel_path : String,
  is_dir : Bool,
) -> (String, Int, String) {
  let mut result_source = ""
  let mut result_linenum = 0
  let mut result_pattern = ""
  if !fs.is_file(file_path) {
    return (result_source, result_linenum, result_pattern)
  }
  let content = decode_bytes(
    fs.read_file(file_path) catch {
      _ => return (result_source, result_linenum, result_pattern)
    },
  )
  let mut linenum = 0
  for line_view in content.split("\n") {
    linenum += 1
    let mut line = line_view.to_owned()
    if line.has_suffix("\r") {
      line = String::unsafe_substring(line, start=0, end=line.length() - 1)
    }
    let trimmed = line.trim().to_owned()
    if trimmed.length() == 0 || trimmed.has_prefix("#") {
      continue
    }
    // Test if this single rule matches
    let matcher = @ignore.Matcher::new()
    let match_line = if line.has_prefix("!") {
      String::unsafe_substring(line, start=1, end=line.length())
    } else {
      line
    }
    matcher.add_rules(base, match_line)
    if matcher.is_ignored(rel_path, is_dir) {
      result_source = source_name
      result_linenum = linenum
      result_pattern = trimmed
    }
  }
  (result_source, result_linenum, result_pattern)
}

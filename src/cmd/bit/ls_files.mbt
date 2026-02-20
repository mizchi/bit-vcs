///|
async fn handle_ls_files(args : Array[String]) -> Unit raise Error {
  let root = get_work_root()
  let git_dir = root + "/.git"
  let fs = OsFs::new()
  let mut show_stage = false
  let mut show_others = false
  let mut show_deleted = false
  let mut show_directory = false
  let mut no_empty_directory = false
  let mut recurse_submodules = false
  let mut use_nul = false
  let mut error_unmatch = false
  let raw_filters : Array[String] = []
  let mut parse_options = true
  for arg in args {
    if parse_options && arg == "--" {
      parse_options = false
      continue
    }
    if parse_options {
      match arg {
        "-s" | "--stage" => show_stage = true
        "-c" | "--cached" => () // default mode, no-op
        "-o" | "--others" => show_others = true
        "-d" | "--deleted" => show_deleted = true
        "--directory" => show_directory = true
        "--no-empty-directory" => no_empty_directory = true
        "--recurse-submodules" => recurse_submodules = true
        "--error-unmatch" => error_unmatch = true
        "-z" => use_nul = true
        _ if arg.has_prefix("-") => warn_unimplemented_arg("ls-files", arg)
        _ => raw_filters.push(arg)
      }
    } else {
      raw_filters.push(arg)
    }
  }
  let terminator = if use_nul { "\u0000" } else { "\n" }
  let cwd_prefix = compute_cwd_prefix(root)
  let filters = normalize_ls_tree_filters(raw_filters, cwd_prefix)
  let entries = @bitlib.read_index_entries(fs, git_dir)
  if error_unmatch {
    for filter in filters {
      if not(ls_files_filter_has_match(filter, entries)) {
        raise @bitcore.GitError::InvalidObject(
          "pathspec '\{filter}' did not match any files",
        )
      }
    }
  }
  if show_others {
    // Build set of tracked paths and their parent directories
    let tracked : Map[String, Bool] = {}
    let tracked_dirs : Map[String, Bool] = {}
    for e in entries {
      tracked[e.path] = true
      // Mark all parent directories as tracked
      let mut path = e.path
      while true {
        match path.rev_find("/") {
          Some(idx) => {
            let dir = (try! path[:idx]).to_string()
            tracked_dirs[dir] = true
            path = dir
          }
          None => break
        }
      }
    }
    let all_files = @ignore.list_working_files_async(fs, root)
    let untracked_file_set : Map[String, Bool] = {}
    for path in all_files {
      if tracked.contains(path) {
        continue
      }
      untracked_file_set[path] = true
    }
    if show_directory {
      // Show untracked directories and explicit file matches that can bypass
      // directory output.
      let wildcard_file_filters : Array[String] = filters.filter(fn(filter) {
        ls_files_filter_has_wildcard(filter) &&
        ls_files_filter_prefers_file_output(filter)
      })
      let explicit_file_filters : Map[String, Bool] = {}
      for filter in filters {
        if not(ls_files_filter_has_wildcard(filter)) &&
          untracked_file_set.contains(filter) {
          explicit_file_filters[filter] = true
        }
      }
      let outputs : Array[String] = []
      let output_set : Map[String, Bool] = {}
      let compress_dirs : Array[String] = []
      for dir in collect_untracked_dirs(fs, root, tracked_dirs) {
        let out_path = dir + "/"
        let should_output = if filters.length() == 0 {
          let parent = match dir.rev_find("/") {
            Some(idx) => String::unsafe_substring(dir, start=0, end=idx)
            None => ""
          }
          if dir == "" {
            false
          } else {
            parent.length() == 0 || tracked_dirs.contains(parent)
          }
        } else {
          ls_files_matches_filters(out_path, filters)
        }
        if should_output {
          if no_empty_directory &&
            not(ls_files_has_matching_file(dir, all_files, untracked_file_set)) {
            continue
          }
          if not(output_set.contains(out_path)) {
            output_set[out_path] = true
            outputs.push(out_path)
            compress_dirs.push(dir)
          }
        }
      }
      if filters.length() == 0 {
        for file in all_files {
          if not(untracked_file_set.contains(file)) {
            continue
          }
          if ls_files_is_within_untracked_dir(file, compress_dirs) {
            continue
          }
          if not(output_set.contains(file)) {
            output_set[file] = true
            outputs.push(file)
          }
        }
      } else if explicit_file_filters.length() > 0 ||
        wildcard_file_filters.length() > 0 {
        for file in all_files {
          if not(untracked_file_set.contains(file)) {
            continue
          }
          if explicit_file_filters.contains(file) {
            if not(output_set.contains(file)) {
              output_set[file] = true
              outputs.push(file)
            }
            continue
          }
          for filter in wildcard_file_filters {
            if ls_files_pathspec_matches(file, filter) {
              if not(output_set.contains(file)) {
                output_set[file] = true
                outputs.push(file)
              }
              break
            }
          }
        }
      }
      outputs.sort_by(fn(a, b) { ls_files_compare_paths(a, b) })
      for output in outputs {
        print_str(output + terminator)
      }
    } else {
      // Show untracked files
      let outputs : Array[String] = []
      for path in all_files {
        if untracked_file_set.contains(path) &&
          ls_files_matches_filters(path, filters) {
          outputs.push(path)
        }
      }
      outputs.sort_by(fn(a, b) { ls_files_compare_paths(a, b) })
      for output in outputs {
        print_str(output + terminator)
      }
    }
    return ()
  }
  if show_deleted {
    // Show deleted files (in index but not in worktree)
    for e in entries {
      let abs = root + "/" + e.path
      if not(fs.is_file(abs)) && ls_files_matches_filters(e.path, filters) {
        print_str(e.path + terminator)
      }
    }
    return ()
  }
  // Default: show cached (indexed) files
  // Parse submodules first if needed (to skip submodule entries)
  let submodules = if recurse_submodules {
    parse_gitmodules(fs, root)
  } else {
    []
  }
  let submod_paths : Map[String, Bool] = {}
  for submod in submodules {
    submod_paths[submod.path] = true
  }
  if show_stage {
    for e in entries {
      // Skip submodule entries (mode 160000) when recursing
      if recurse_submodules && e.mode == 0o160000 {
        continue
      }
      if not(ls_files_matches_filters(e.path, filters)) {
        continue
      }
      let mode = format_mode(e.mode)
      // Stage is always 0 for normal entries (no merge conflict)
      print_str("\{mode} \{e.id.to_hex()} 0\t\{e.path}" + terminator)
    }
    // Recurse into submodules
    for submod in submodules {
      let sub_git_dir = root + "/" + submod.path + "/.git"
      if fs.is_dir(sub_git_dir) || fs.is_file(sub_git_dir) {
        let actual_git_dir = @bitlib.resolve_gitdir(fs, sub_git_dir)
        let sub_entries = @bitlib.read_index_entries(fs, actual_git_dir)
        for se in sub_entries {
          let mode = format_mode(se.mode)
          let full_path = submod.path + "/" + se.path
          if not(ls_files_matches_filters(full_path, filters)) {
            continue
          }
          print_str("\{mode} \{se.id.to_hex()} 0\t\{full_path}" + terminator)
        }
      }
    }
  } else {
    for e in entries {
      // Skip submodule entries (mode 160000) when recursing
      if recurse_submodules && e.mode == 0o160000 {
        continue
      }
      if not(ls_files_matches_filters(e.path, filters)) {
        continue
      }
      print_str(e.path + terminator)
    }
    // Recurse into submodules
    for submod in submodules {
      let sub_git_dir = root + "/" + submod.path + "/.git"
      if fs.is_dir(sub_git_dir) || fs.is_file(sub_git_dir) {
        let actual_git_dir = @bitlib.resolve_gitdir(fs, sub_git_dir)
        let sub_entries = @bitlib.read_index_entries(fs, actual_git_dir)
        for se in sub_entries {
          let full_path = submod.path + "/" + se.path
          if not(ls_files_matches_filters(full_path, filters)) {
            continue
          }
          print_str(full_path + terminator)
        }
      }
    }
  }
}

///|
struct SubmoduleInfo {
  name : String
  path : String
  url : String
}

///|
/// Parse .gitmodules file to extract submodule info
fn parse_gitmodules(
  fs : &@bitcore.RepoFileSystem,
  root : String,
) -> Array[SubmoduleInfo] {
  let gitmodules_path = root + "/.gitmodules"
  if not(fs.is_file(gitmodules_path)) {
    return []
  }
  let content = decode_bytes(fs.read_file(gitmodules_path)) catch {
    _ => return []
  }
  let result : Array[SubmoduleInfo] = []
  let mut current_name = ""
  let mut current_path = ""
  let mut current_url = ""
  for line_view in content.split("\n") {
    let line = trim_string(line_view.to_string())
    if line.has_prefix("[submodule \"") && line.has_suffix("\"]") {
      // Save previous submodule if any
      if current_name.length() > 0 && current_path.length() > 0 {
        result.push({ name: current_name, path: current_path, url: current_url })
      }
      // Extract name from [submodule "name"]
      current_name = String::unsafe_substring(
        line,
        start=12,
        end=line.length() - 2,
      )
      current_path = ""
      current_url = ""
    } else if line.has_prefix("path") {
      let eq_idx = line.find("=")
      match eq_idx {
        Some(i) =>
          current_path = trim_string(
            String::unsafe_substring(line, start=i + 1, end=line.length()),
          )
        None => ()
      }
    } else if line.has_prefix("url") {
      let eq_idx = line.find("=")
      match eq_idx {
        Some(i) =>
          current_url = trim_string(
            String::unsafe_substring(line, start=i + 1, end=line.length()),
          )
        None => ()
      }
    }
  }
  // Don't forget the last one
  if current_name.length() > 0 && current_path.length() > 0 {
    result.push({ name: current_name, path: current_path, url: current_url })
  }
  result
}

///|
fn parse_pathspec_magic(filter : String) -> (String, Bool) {
  if filter.has_prefix(":!") {
    let rest = String::unsafe_substring(filter, start=2, end=filter.length())
    return (rest, true)
  }
  if filter.has_prefix(":(") {
    match filter.find(")") {
      Some(idx) => {
        let magic = String::unsafe_substring(filter, start=2, end=idx)
        let rest = String::unsafe_substring(
          filter,
          start=idx + 1,
          end=filter.length(),
        )
        let is_exclude = magic.contains("exclude") || magic.contains("!")
        (rest, is_exclude)
      }
      None => (filter, false)
    }
  } else {
    (filter, false)
  }
}

///|
fn normalize_ls_tree_filters(
  filters : Array[String],
  cwd_prefix : String,
) -> Array[String] raise Error {
  let out : Array[String] = []
  for filter in filters {
    let (raw, is_exclude) = parse_pathspec_magic(filter)
    if is_exclude {
      raise @bitcore.GitError::InvalidObject(
        "pathspec magic not supported by this command: 'exclude' (mnemonic: '!')",
      )
    }
    let mut clean = raw
    if clean.has_suffix("/") && clean.length() > 1 {
      clean = String::unsafe_substring(clean, start=0, end=clean.length() - 1)
    }
    let base = if clean == "" || clean == "." {
      cwd_prefix
    } else if clean.has_prefix("/") {
      String::unsafe_substring(clean, start=1, end=clean.length())
    } else if cwd_prefix.length() == 0 {
      clean
    } else {
      cwd_prefix + "/" + clean
    }
    let normalized = normalize_path(base)
    if normalized != "." && normalized.length() > 0 {
      out.push(normalized)
    }
  }
  out
}

///|
fn compute_cwd_prefix(root : String) -> String {
  match @sys.get_env_var("GIT_SHIM_PWD") {
    None => ""
    Some(cwd) => {
      let cwd_abs = normalize_path(cwd)
      let root_abs = if root.has_prefix("/") {
        normalize_path(root)
      } else {
        normalize_path(cwd_abs + "/" + root)
      }
      if cwd_abs == root_abs {
        ""
      } else {
        let root_prefix = if root_abs == "/" { "/" } else { root_abs + "/" }
        if cwd_abs.has_prefix(root_prefix) {
          String::unsafe_substring(
            cwd_abs,
            start=root_prefix.length(),
            end=cwd_abs.length(),
          )
        } else {
          ""
        }
      }
    }
  }
}

///|
fn count_path_segments(path : String) -> Int {
  let mut count = 0
  for part_view in path.split("/") {
    let part = part_view.to_string()
    if part.length() > 0 {
      count += 1
    }
  }
  count
}

///|
fn make_display_path(path : String, cwd_prefix : String) -> String {
  if cwd_prefix.length() == 0 {
    return path
  }
  if path == cwd_prefix {
    return "."
  }
  let prefix = cwd_prefix + "/"
  if path.has_prefix(prefix) {
    return (try! path[prefix.length():]).to_string()
  }
  let depth = count_path_segments(cwd_prefix)
  let mut rel = ""
  for _ in 0..<depth {
    rel = rel + "../"
  }
  rel + path
}

///|
fn ls_files_matches_filters(path : String, filters : Array[String]) -> Bool {
  if filters.length() == 0 {
    return true
  }
  let normalized = if path.has_suffix("/") && path.length() > 1 {
    String::unsafe_substring(path, start=0, end=path.length() - 1)
  } else {
    path
  }
  for filter in filters {
    if ls_files_pathspec_matches(normalized, filter) {
      return true
    }
  }
  false
}

///|
fn ls_files_is_within_untracked_dir(
  file : String,
  dirs : Array[String],
) -> Bool {
  for dir in dirs {
    if file.has_prefix(dir + "/") {
      return true
    }
  }
  false
}

///|
fn ls_files_has_matching_file(
  dir : String,
  files : Array[String],
  untracked_file_set : Map[String, Bool],
) -> Bool {
  let prefix = dir + "/"
  for file in files {
    if untracked_file_set.contains(file) && file.has_prefix(prefix) {
      return true
    }
  }
  false
}

///|
fn ls_files_compare_paths(left : String, right : String) -> Int {
  let left_chars = left.to_array()
  let right_chars = right.to_array()
  let common = if left_chars.length() < right_chars.length() {
    left_chars.length()
  } else {
    right_chars.length()
  }
  for i in 0..<common {
    if left_chars[i] != right_chars[i] {
      if left_chars[i] < right_chars[i] {
        return -1
      } else {
        return 1
      }
    }
  }
  if left_chars.length() == right_chars.length() {
    0
  } else if left_chars.length() < right_chars.length() {
    -1
  } else {
    1
  }
}

///|
fn ls_files_filter_has_match(
  filter : String,
  entries : Array[@bitlib.IndexEntry],
) -> Bool {
  for entry in entries {
    if ls_files_pathspec_matches(entry.path, filter) {
      return true
    }
  }
  false
}

///|
fn ls_files_pathspec_matches(path : String, pattern : String) -> Bool {
  if ls_files_filter_has_wildcard(pattern) {
    ls_files_simple_wildcard_match(path, pattern)
  } else {
    path == pattern || path.has_prefix(pattern + "/")
  }
}

///|
fn ls_files_filter_has_wildcard(pattern : String) -> Bool {
  pattern.find("*") is Some(_) ||
  pattern.find("?") is Some(_) ||
  pattern.find("[") is Some(_)
}

///|
fn ls_files_filter_prefers_file_output(pattern : String) -> Bool {
  // Heuristic for `--directory`:
  // wildcard patterns that have an extension-like final segment are treated as file globs.
  let segment = match pattern.rev_find("/") {
    Some(idx) =>
      String::unsafe_substring(pattern, start=idx + 1, end=pattern.length())
    None => pattern
  }
  segment.contains(".")
}

///|
fn ls_files_simple_wildcard_match(path : String, pattern : String) -> Bool {
  let p_chars = pattern.to_array()
  let t_chars = path.to_array()
  let mut pi = 0
  let mut ti = 0
  let mut star_index = -1
  let mut match_index = 0
  while ti < t_chars.length() {
    if pi < p_chars.length() && p_chars[pi] == '\\' && pi + 1 < p_chars.length() {
      pi += 1
      if pi >= p_chars.length() {
        return false
      }
      if p_chars[pi] != t_chars[ti] {
        return false
      }
      pi += 1
      ti += 1
    } else if pi < p_chars.length() && p_chars[pi] == '?' {
      if ti >= t_chars.length() {
        return false
      }
      pi += 1
      ti += 1
    } else if pi < p_chars.length() && p_chars[pi] == '*' {
      star_index = pi
      match_index = ti
      pi += 1
    } else if pi < p_chars.length() && p_chars[pi] == t_chars[ti] {
      pi += 1
      ti += 1
    } else if star_index != -1 {
      pi = star_index + 1
      match_index += 1
      ti = match_index
    } else {
      return false
    }
  }
  while pi < p_chars.length() && p_chars[pi] == '*' {
    pi += 1
  }
  pi == p_chars.length()
}

///|
/// Collect untracked directories at the top level
fn collect_untracked_dirs(
  fs : &@bitcore.RepoFileSystem,
  root : String,
  tracked_dirs : Map[String, Bool],
) -> Array[String] raise @bitcore.GitError {
  let result : Array[String] = []
  collect_untracked_dirs_recursive(fs, root, "", tracked_dirs, result)
  result.sort_by(fn(a, b) { ls_files_compare_paths(a, b) })
  result
}

///|
fn collect_untracked_dirs_recursive(
  fs : &@bitcore.RepoFileSystem,
  root : String,
  prefix : String,
  tracked_dirs : Map[String, Bool],
  out : Array[String],
) -> Unit raise @bitcore.GitError {
  let dir = if prefix == "" { root } else { root + "/" + prefix }
  if prefix != "" {
    let dot_git_marker = dir + "/.git"
    let bit_marker = dir + "/.bit"
    if fs.is_file(dot_git_marker) ||
      fs.is_dir(dot_git_marker) ||
      fs.is_file(bit_marker) ||
      fs.is_dir(bit_marker) {
      return ()
    }
  }
  let items = fs.readdir(dir)
  for name in items {
    if name == "." || name == ".." || name == ".git" || name == ".bit" {
      continue
    }
    if name == ".jj" {
      continue
    }
    let rel_path = if prefix == "" { name } else { prefix + "/" + name }
    let abs_path = root + "/" + rel_path
    if fs.is_dir(abs_path) {
      collect_untracked_dirs_recursive(fs, root, rel_path, tracked_dirs, out)
    }
  }
  if prefix != "" && not(tracked_dirs.contains(prefix)) {
    out.push(prefix)
  }
}

///|
fn format_mode(mode : Int) -> String {
  // Convert mode to octal string (6 digits)
  let mut n = mode
  let digits : Array[String] = []
  while n > 0 {
    digits.push((n % 8).to_string())
    n = n / 8
  }
  while digits.length() < 6 {
    digits.push("0")
  }
  digits.rev_in_place()
  digits.iter().fold(init="", (acc, d) => acc + d)
}

///|

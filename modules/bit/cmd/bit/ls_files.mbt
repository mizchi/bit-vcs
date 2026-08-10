///|
async fn handle_ls_files(args : Array[String]) -> Unit raise Error {
  let root = get_work_root()
  let fs = OsFs::new()
  let git_dir = resolve_git_dir(fs, root)
  let mut show_stage = false
  let mut show_others = false
  let mut show_ignored = false
  let mut show_deleted = false
  let mut show_modified = false
  let mut show_killed = false
  let mut show_unmerged = false
  let mut show_directory = false
  let mut no_empty_directory = false
  let mut recurse_submodules = false
  let mut use_nul = false
  let mut error_unmatch = false
  let mut show_eol = false
  let mut show_sparse = false
  let mut exclude_standard = false
  let exclude_patterns : Array[String] = []
  let exclude_from_files : Array[String] = []
  let mut exclude_per_directory : String? = None
  let raw_filters : Array[String] = []
  let mut parse_options = true
  let mut pending_value_flag : String? = None
  for arg in args {
    match pending_value_flag {
      Some(flag) => {
        match flag {
          "exclude" => exclude_patterns.push(arg)
          "exclude-from" => exclude_from_files.push(arg)
          "exclude-per-directory" => exclude_per_directory = Some(arg)
          _ => ()
        }
        pending_value_flag = None
        continue
      }
      None => ()
    }
    if parse_options && arg == "--" {
      parse_options = false
      continue
    }
    if parse_options {
      match arg {
        "-s" | "--stage" => show_stage = true
        "-c" | "--cached" => () // default mode, no-op
        "-o" | "--others" => show_others = true
        "-i" | "--ignored" => show_ignored = true
        "-d" | "--deleted" => show_deleted = true
        "-m" | "--modified" => show_modified = true
        "-k" | "--killed" => show_killed = true
        "-u" | "--unmerged" => show_unmerged = true
        "--directory" => show_directory = true
        "--no-empty-directory" => no_empty_directory = true
        "--recurse-submodules" => recurse_submodules = true
        "--error-unmatch" => error_unmatch = true
        "--eol" => show_eol = true
        "--sparse" => show_sparse = true
        "--exclude-standard" => exclude_standard = true
        "--exclude" => pending_value_flag = Some("exclude")
        "--exclude-from" => pending_value_flag = Some("exclude-from")
        "--exclude-per-directory" =>
          pending_value_flag = Some("exclude-per-directory")
        "-z" => use_nul = true
        _ if arg.has_prefix("--exclude=") =>
          exclude_patterns.push(
            String::unsafe_substring(arg, start=10, end=arg.length()),
          )
        _ if arg.has_prefix("--exclude-from=") =>
          exclude_from_files.push(
            String::unsafe_substring(arg, start=15, end=arg.length()),
          )
        _ if arg.has_prefix("--exclude-per-directory=") =>
          exclude_per_directory = Some(
            String::unsafe_substring(arg, start=24, end=arg.length()),
          )
        _ if arg.has_prefix("-") => ls_files_usage_error()
        _ => raw_filters.push(arg)
      }
    } else {
      raw_filters.push(arg)
    }
  }
  if pending_value_flag is Some(_) {
    ls_files_usage_error()
  }
  if recurse_submodules && error_unmatch {
    eprint_line(
      "ls-files --recurse-submodules does not support --error-unmatch",
    )
    @sys.exit(1)
  }
  if recurse_submodules &&
    (
      show_deleted ||
      show_modified ||
      show_others ||
      show_killed ||
      show_unmerged
    ) {
    eprint_line("ls-files --recurse-submodules: unsupported mode")
    @sys.exit(1)
  }
  let terminator = if use_nul { "\u0000" } else { "\n" }
  let cwd_prefix = compute_cwd_prefix(root)
  let root_abs = ls_files_repo_root_abs(root)
  let filters = normalize_ls_files_filters(raw_filters, cwd_prefix, root_abs)
  let path_filters = if raw_filters.length() == 0 && cwd_prefix.length() > 0 {
    [cwd_prefix]
  } else {
    filters
  }
  if show_unmerged {
    let stage_entries = @bitlib.read_index_stage_entries(fs, git_dir)
    let candidate_paths : Array[String] = []
    for item in stage_entries {
      if item.stage != 0 {
        candidate_paths.push(item.entry.path)
      }
    }
    for item in stage_entries {
      if item.stage == 0 ||
        !ls_files_matches_filters(item.entry.path, path_filters) {
        continue
      }
      let mode = format_mode(item.entry.mode)
      let display_path = make_display_path(item.entry.path, cwd_prefix)
      print_str(
        "\{mode} \{item.entry.id.to_hex()} \{item.stage}\t\{display_path}" +
        terminator,
      )
    }
    if error_unmatch {
      let unmatched = ls_files_collect_unmatched_raw_filters(
        raw_filters, cwd_prefix, root_abs, candidate_paths,
      )
      if unmatched.length() > 0 {
        ls_files_exit_error_unmatch(unmatched)
      }
    }
    return ()
  }
  let raw_entries = @bitlib.read_index_entries(fs, git_dir)
  let entries = if show_sparse {
    raw_entries
  } else {
    @bitlib.expand_sparse_index_entries(fs, git_dir, raw_entries)
  }
  if show_eol {
    let db = @bitlib.ObjectDb::load_lazy(fs, git_dir)
    // Tracked entries (cached or deleted)
    for e in entries {
      if !ls_files_matches_filters(e.path, path_filters) {
        continue
      }
      let abs = root + "/" + e.path
      let file_exists = fs.is_file(abs)
      // If show_deleted, only show entries where file is missing
      if show_deleted && file_exists {
        continue
      }
      // Default (cached): skip deleted unless show_deleted
      if !show_deleted && !file_exists && !show_others {

      }
      // still show in default cached mode
      // Detect index EOL from blob content
      let i_eol = match db.get(fs, e.id) {
        Some(obj) if obj.obj_type == @bitcore.ObjectType::Blob =>
          detect_eol_type(obj.data)
        _ => ""
      }
      // Detect worktree EOL from file on disk
      let w_eol = if file_exists {
        let content = fs.read_file(abs) catch { _ => Default::default() }
        detect_eol_type(content)
      } else {
        ""
      }
      // Resolve gitattributes
      let attrs = @bitlib.resolve_eol_attrs(fs, root, e.path)
      let attr_str = format_eol_attr(attrs)
      let display_path = make_display_path(e.path, cwd_prefix)
      print_str(
        "i/\{i_eol}\tw/\{w_eol}\tattr/\{attr_str}\t\{display_path}" + terminator,
      )
    }
    // Untracked files (show_others)
    if show_others {
      let tracked : Map[String, Bool] = Map([])
      for e in entries {
        tracked[e.path] = true
      }
      let all_files = @bitlib.list_working_files_async(fs, root)
      for path in all_files {
        if tracked.contains(path) {
          continue
        }
        if !ls_files_matches_filters(path, path_filters) {
          continue
        }
        let abs = root + "/" + path
        let w_eol = if fs.is_file(abs) {
          let content = fs.read_file(abs) catch { _ => Default::default() }
          detect_eol_type(content)
        } else {
          ""
        }
        let attrs = @bitlib.resolve_eol_attrs(fs, root, path)
        let attr_str = format_eol_attr(attrs)
        let display_path = make_display_path(path, cwd_prefix)
        print_str(
          "i/\tw/\{w_eol}\tattr/\{attr_str}\t\{display_path}" + terminator,
        )
      }
    }
    return ()
  }
  if show_ignored && !show_others {
    let entry_map : Map[String, @bitlib.IndexEntry] = Map([])
    for entry in entries {
      entry_map[entry.path] = entry
    }
    for entry in entries {
      if !ls_files_matches_filters(entry.path, path_filters) {
        continue
      }
      if ls_files_cached_entry_is_ignored(
          fs,
          root,
          git_dir,
          entry_map,
          entry.path,
          exclude_standard,
          exclude_patterns,
          exclude_from_files,
          exclude_per_directory,
        ) {
        print_str(make_display_path(entry.path, cwd_prefix) + terminator)
      }
    }
    return ()
  }
  if show_others {
    // Build set of tracked paths and their parent directories
    let tracked : Map[String, Bool] = Map([])
    let entry_map : Map[String, @bitlib.IndexEntry] = Map([])
    let tracked_dirs : Map[String, Bool] = Map([])
    for e in entries {
      tracked[e.path] = true
      entry_map[e.path] = e
      // Mark all parent directories as tracked
      let mut path = e.path
      while true {
        match path.rev_find("/") {
          Some(idx) => {
            let dir = string_slice_to(path, idx)
            tracked_dirs[dir] = true
            path = dir
          }
          None => break
        }
      }
    }
    let (all_files, ignored_dirs) = ls_files_collect_other_paths(
      fs,
      root,
      git_dir,
      tracked,
      entry_map,
      show_ignored~,
      exclude_standard~,
      exclude_patterns,
      exclude_from_files,
      exclude_per_directory,
    )
    let untracked_file_set : Map[String, Bool] = Map([])
    for path in all_files {
      untracked_file_set[path] = true
    }
    if show_directory {
      // Show untracked directories and explicit file matches that can bypass
      // directory output.
      let wildcard_file_filters : Array[String] = path_filters.filter(fn(
        filter,
      ) {
        let (_raw, is_exclude, _is_icase) = parse_pathspec_magic(filter)
        !is_exclude &&
        ls_files_filter_has_wildcard(filter) &&
        ls_files_filter_prefers_file_output(filter)
      })
      let ignore_file_filters : Array[String] = exclude_patterns.filter(fn(
        pattern,
      ) {
        ls_files_filter_has_wildcard(pattern) &&
        ls_files_filter_prefers_file_output(pattern)
      })
      let disable_directory_compression = show_ignored &&
        path_filters.length() == 0 &&
        ignore_file_filters.length() > 0
      let explicit_file_filters : Map[String, Bool] = Map([])
      for filter in path_filters {
        let (_raw, is_exclude, _is_icase) = parse_pathspec_magic(filter)
        if !is_exclude &&
          !ls_files_filter_has_wildcard(filter) &&
          untracked_file_set.contains(filter) {
          explicit_file_filters[filter] = true
        }
      }
      let outputs : Array[String] = []
      let output_set : Map[String, Bool] = Map([])
      let compress_dirs : Array[String] = []
      for
        dir in ls_files_collect_candidate_dirs(
          all_files, ignored_dirs, tracked_dirs,
        ) {
        if disable_directory_compression {
          continue
        }
        let out_path = dir + "/"
        let should_output = if path_filters.length() == 0 {
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
          ls_files_matches_filters(out_path, path_filters)
        }
        if should_output {
          if no_empty_directory &&
            !ls_files_has_matching_file(dir, all_files, untracked_file_set) {
            continue
          }
          if ls_files_is_within_untracked_dir(dir, compress_dirs) {
            continue
          }
          if !output_set.contains(out_path) {
            output_set[out_path] = true
            outputs.push(out_path)
            compress_dirs.push(dir)
          }
        }
      }
      if path_filters.length() == 0 {
        for file in all_files {
          if !untracked_file_set.contains(file) {
            continue
          }
          if !disable_directory_compression &&
            ls_files_is_within_untracked_dir(file, compress_dirs) {
            continue
          }
          if !output_set.contains(file) {
            output_set[file] = true
            outputs.push(file)
          }
        }
      } else if explicit_file_filters.length() > 0 ||
        wildcard_file_filters.length() > 0 {
        for file in all_files {
          if !untracked_file_set.contains(file) {
            continue
          }
          if explicit_file_filters.contains(file) {
            if !output_set.contains(file) {
              output_set[file] = true
              outputs.push(file)
            }
            continue
          }
          for filter in wildcard_file_filters {
            if ls_files_pathspec_matches(file, filter) {
              if !output_set.contains(file) {
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
        print_str(make_display_path(output, cwd_prefix) + terminator)
      }
      if error_unmatch {
        let unmatched = ls_files_collect_unmatched_raw_filters(
          raw_filters, cwd_prefix, root_abs, all_files,
        )
        if unmatched.length() > 0 {
          ls_files_exit_error_unmatch(unmatched)
        }
      }
    } else {
      // Show untracked files
      let outputs : Array[String] = []
      for path in all_files {
        if untracked_file_set.contains(path) &&
          ls_files_matches_filters(path, path_filters) {
          outputs.push(path)
        }
      }
      outputs.sort_by(fn(a, b) { ls_files_compare_paths(a, b) })
      for output in outputs {
        print_str(make_display_path(output, cwd_prefix) + terminator)
      }
      if error_unmatch {
        let unmatched = ls_files_collect_unmatched_raw_filters(
          raw_filters, cwd_prefix, root_abs, all_files,
        )
        if unmatched.length() > 0 {
          ls_files_exit_error_unmatch(unmatched)
        }
      }
    }
    return ()
  }
  if show_modified || show_killed {
    let outputs : Array[String] = []
    let output_set : Map[String, Bool] = Map([])
    if show_modified {
      let modified_paths = ls_files_collect_modified_paths(fs, root, entries)
      for path in modified_paths {
        if ls_files_matches_filters(path, path_filters) &&
          !output_set.contains(path) {
          output_set[path] = true
          outputs.push(path)
        }
      }
    }
    if show_killed {
      let killed_paths = ls_files_collect_killed_paths(fs, root, entries)
      for path in killed_paths {
        if ls_files_matches_filters(path, path_filters) &&
          !output_set.contains(path) {
          output_set[path] = true
          outputs.push(path)
        }
      }
    }
    outputs.sort_by(fn(a, b) { ls_files_compare_paths(a, b) })
    for output in outputs {
      print_str(make_display_path(output, cwd_prefix) + terminator)
    }
    if error_unmatch {
      let unmatched = ls_files_collect_unmatched_raw_filters(
        raw_filters, cwd_prefix, root_abs, outputs,
      )
      if unmatched.length() > 0 {
        ls_files_exit_error_unmatch(unmatched)
      }
    }
    return ()
  }
  if show_deleted {
    // Show deleted files (in index but not in worktree)
    for e in entries {
      let abs = root + "/" + e.path
      if !fs.is_file(abs) && ls_files_matches_filters(e.path, path_filters) {
        print_str(make_display_path(e.path, cwd_prefix) + terminator)
      }
    }
    return ()
  }
  // Default: show cached (indexed) files, optionally recursing into submodules.
  let tracked_entries = ls_files_collect_cached_entries(
    fs,
    root,
    git_dir,
    "",
    recurse_submodules~,
    show_sparse~,
  )
  let tracked_candidate_paths : Array[String] = []
  for entry in tracked_entries {
    tracked_candidate_paths.push(entry.path)
  }
  if show_stage {
    // Use stage entries to show actual stage numbers (0, 1, 2, 3)
    let stage_entries = @bitlib.read_index_stage_entries(fs, git_dir)
    for item in stage_entries {
      if !ls_files_matches_filters(item.entry.path, path_filters) {
        continue
      }
      let mode = format_mode(item.entry.mode)
      let display_path = make_display_path(item.entry.path, cwd_prefix)
      print_str(
        "\{mode} \{item.entry.id.to_hex()} \{item.stage}\t\{display_path}" +
        terminator,
      )
    }
    if error_unmatch {
      let unmatched = ls_files_collect_unmatched_raw_filters(
        raw_filters, cwd_prefix, root_abs, tracked_candidate_paths,
      )
      if unmatched.length() > 0 {
        ls_files_exit_error_unmatch(unmatched)
      }
    }
  } else {
    for entry in tracked_entries {
      if !ls_files_matches_filters(entry.path, path_filters) {
        continue
      }
      print_str(make_display_path(entry.path, cwd_prefix) + terminator)
    }
    if error_unmatch {
      let unmatched = ls_files_collect_unmatched_raw_filters(
        raw_filters, cwd_prefix, root_abs, tracked_candidate_paths,
      )
      if unmatched.length() > 0 {
        ls_files_exit_error_unmatch(unmatched)
      }
    }
  }
}

///|
async fn ls_files_usage_error() -> Unit {
  eprint_line("usage: git ls-files [<options>] [<file>...]")
  @sys.exit(129)
}

///|
async fn ls_files_exit_error_unmatch(unmatched : Array[String]) -> Unit {
  for raw in unmatched {
    eprint_line(
      "error: pathspec '\{raw}' did not match any file(s) known to git",
    )
  }
  eprint_line("Did you forget to 'git add'?")
  @sys.exit(1)
}

///|
async fn ls_files_collect_killed_paths(
  fs : &@bitcore.RepoFileSystem,
  root : String,
  entries : Array[@bitlib.IndexEntry],
) -> Array[String] raise Error {
  let tracked_modes : Map[String, Int] = Map([])
  let tracked_paths : Array[String] = []
  for entry in entries {
    tracked_modes[entry.path] = entry.mode
    tracked_paths.push(entry.path)
  }
  let visible_paths = @bitlib.list_working_files_async(fs, root)
  let killed : Array[String] = []
  let killed_set : Map[String, Bool] = Map([])
  for path in visible_paths {
    if tracked_modes.contains(path) {
      continue
    }
    let mut current = path
    let mut obstructs = false
    while true {
      match current.rev_find("/") {
        Some(idx) => {
          current = String::unsafe_substring(current, start=0, end=idx)
          match tracked_modes.get(current) {
            Some(mode) => {
              if mode != 0o160000 {
                obstructs = true
              }
              break
            }
            None => ()
          }
        }
        None => break
      }
    }
    if !obstructs {
      let prefix = path + "/"
      for tracked_path in tracked_paths {
        if tracked_path.has_prefix(prefix) {
          obstructs = true
          break
        }
      }
    }
    if obstructs && !killed_set.contains(path) {
      killed_set[path] = true
      killed.push(path)
    }
  }
  killed
}

///|
async fn ls_files_collect_modified_paths(
  fs : &@bitcore.RepoFileSystem,
  root : String,
  entries : Array[@bitlib.IndexEntry],
) -> Array[String] raise Error {
  let modified : Array[String] = []
  let modified_set : Map[String, Bool] = Map([])
  let diffs = @bitdiff.diff_worktree(fs, root)
  for diff in diffs {
    if !modified_set.contains(diff.path) {
      modified_set[diff.path] = true
      modified.push(diff.path)
    }
  }
  for entry in entries {
    if entry.mode != 0o160000 {
      continue
    }
    let sub_git_dir = root + "/" + entry.path + "/.git"
    if !fs.is_dir(sub_git_dir) && !fs.is_file(sub_git_dir) {
      continue
    }
    let actual_git_dir = @bitlib.resolve_gitdir(fs, sub_git_dir)
    match @bitlib.resolve_head_commit(fs, actual_git_dir) {
      Some(head) =>
        if head != entry.id && !modified_set.contains(entry.path) {
          modified_set[entry.path] = true
          modified.push(entry.path)
        }
      None => ()
    }
  }
  modified
}

///|
fn ls_files_repo_root_abs(root : String) -> String {
  if root.has_prefix("/") {
    return normalize_path(root)
  }
  let base_dir = match @sys.get_env_var("GIT_SHIM_PWD") {
    Some(dir) => Some(dir)
    None =>
      match @env.current_dir() {
        Some(dir) => Some(dir)
        None => @sys.get_env_var("PWD")
      }
  }
  match base_dir {
    Some(dir) =>
      if root == "." {
        find_repo_root(dir).unwrap_or(normalize_path(dir))
      } else {
        normalize_path(dir + "/" + root)
      }
    None => normalize_path(root)
  }
}

///|
fn normalize_ls_files_filters(
  filters : Array[String],
  cwd_prefix : String,
  root_abs : String,
) -> Array[String] raise Error {
  let out : Array[String] = []
  for filter in filters {
    let (raw, is_exclude, is_icase) = parse_pathspec_magic(filter)
    let mut clean = raw
    let has_trailing_slash = clean.has_suffix("/") && clean.length() > 1
    if has_trailing_slash {
      clean = String::unsafe_substring(clean, start=0, end=clean.length() - 1)
    }
    let base = if clean == "" || clean == "." {
      cwd_prefix
    } else if clean.has_prefix("/") {
      ls_files_relativize_absolute_filter(clean, root_abs)
    } else if cwd_prefix.length() == 0 {
      clean
    } else {
      cwd_prefix + "/" + clean
    }
    let normalized = normalize_path(base)
    if normalized == ".." || normalized.has_prefix("../") {
      raise @bitcore.GitError::InvalidObject(
        "'\{filter}' is outside repository at '\{normalize_path(cwd_prefix)}'",
      )
    }
    if normalized != "." && normalized.length() > 0 {
      let normalized_filter = if has_trailing_slash {
        normalized + "/"
      } else {
        normalized
      }
      out.push(compose_pathspec_magic(normalized_filter, is_exclude, is_icase))
    }
  }
  out
}

///|
fn compose_pathspec_magic(
  pattern : String,
  is_exclude : Bool,
  is_icase : Bool,
) -> String {
  let magics : Array[String] = []
  if is_icase {
    magics.push("icase")
  }
  if is_exclude {
    magics.push("exclude")
  }
  if magics.length() == 0 {
    pattern
  } else {
    let magic_text = magics.join(",")
    ":(\{magic_text})" + pattern
  }
}

///|
fn ls_files_relativize_absolute_filter(
  raw : String,
  root_abs : String,
) -> String {
  let normalized_filter = normalize_path(raw)
  if normalized_filter == root_abs {
    "."
  } else {
    let root_prefix = if root_abs == "/" { "/" } else { root_abs + "/" }
    if normalized_filter.has_prefix(root_prefix) {
      String::unsafe_substring(
        normalized_filter,
        start=root_prefix.length(),
        end=normalized_filter.length(),
      )
    } else {
      normalized_filter
    }
  }
}

///|
pub(all) struct SubmoduleInfo {
  name : String
  path : String
  url : String
} derive(Eq, Debug)

///|
fn submodule_info_show_string(value : String) -> String {
  let buf = StringBuilder::new()
  buf.write_char('"')
  for c in value {
    if c == '"' {
      buf.write_string("\\\"")
    } else if c == '\\' {
      buf.write_string("\\\\")
    } else if c == '\n' {
      buf.write_string("\\n")
    } else if c == '\r' {
      buf.write_string("\\r")
    } else if c == '\t' {
      buf.write_string("\\t")
    } else {
      buf.write_char(c)
    }
  }
  buf.write_char('"')
  buf.to_string()
}

///|
pub impl Show for SubmoduleInfo with fn output(self, logger) {
  logger.write_string(
    "{name: " +
    submodule_info_show_string(self.name) +
    ", path: " +
    submodule_info_show_string(self.path) +
    ", url: " +
    submodule_info_show_string(self.url) +
    "}",
  )
}

///|
struct LsFilesTrackedEntry {
  path : String
}

///|
fn ls_files_collect_cached_entries(
  fs : &@bitcore.RepoFileSystem,
  root : String,
  git_dir : String,
  prefix : String,
  recurse_submodules? : Bool = false,
  show_sparse? : Bool = false,
) -> Array[LsFilesTrackedEntry] raise Error {
  if recurse_submodules {
    ls_files_validate_repo_config(fs, git_dir)
  }
  let raw_entries = @bitlib.read_index_entries(fs, git_dir)
  let entries = if show_sparse {
    raw_entries
  } else {
    @bitlib.expand_sparse_index_entries(fs, git_dir, raw_entries)
  }
  if !recurse_submodules {
    return entries.map(fn(entry) { { path: prefix + entry.path } })
  }
  let submodules = parse_gitmodules(fs, root)
  let out : Array[LsFilesTrackedEntry] = []
  for entry in entries {
    if entry.mode != 0o160000 {
      out.push({ path: prefix + entry.path })
      continue
    }
    match ls_files_find_submodule_by_path(submodules, entry.path) {
      Some(submodule) => {
        if !ls_files_submodule_is_active(fs, git_dir, submodule.name) {
          out.push({ path: prefix + entry.path })
          continue
        }
        let sub_root = root + "/" + submodule.path
        let sub_git_marker = sub_root + "/.git"
        if !fs.is_dir(sub_git_marker) && !fs.is_file(sub_git_marker) {
          out.push({ path: prefix + entry.path })
          continue
        }
        let sub_git_dir = @bitlib.resolve_gitdir(fs, sub_git_marker)
        for
          sub_entry in ls_files_collect_cached_entries(
            fs,
            sub_root,
            sub_git_dir,
            prefix + submodule.path + "/",
            recurse_submodules=true,
            show_sparse~,
          ) {
          out.push(sub_entry)
        }
      }
      None => out.push({ path: prefix + entry.path })
    }
  }
  out
}

///|
fn ls_files_find_submodule_by_path(
  submodules : Array[SubmoduleInfo],
  path : String,
) -> SubmoduleInfo? {
  for submodule in submodules {
    if submodule.path == path {
      return Some(submodule)
    }
  }
  None
}

///|
fn ls_files_read_config_bool_strict(
  fs : &@bitcore.RepoFileSystem,
  config_path : String,
  section : String,
  name : String,
) -> Bool? raise Error {
  match @bitlib.read_config_value(fs, config_path, section, name) {
    Some(value) => {
      let lower = value.to_lower()
      if lower == "true" || lower == "1" || lower == "yes" {
        Some(true)
      } else if lower == "false" || lower == "0" || lower == "no" {
        Some(false)
      } else {
        raise @bitcore.GitError::InvalidObject(
          "bad boolean config value '\{value}' for '\{section}.\{name}'",
        )
      }
    }
    None => None
  }
}

///|
fn ls_files_validate_repo_config(
  fs : &@bitcore.RepoFileSystem,
  git_dir : String,
) -> Unit raise Error {
  let config_path = git_dir + "/config"
  ignore(ls_files_read_config_bool_strict(fs, config_path, "index", "sparse"))
  let use_worktree_config = ls_files_read_config_bool_strict(
    fs, config_path, "extensions", "worktreeConfig",
  ).unwrap_or(false)
  if use_worktree_config {
    ignore(
      ls_files_read_config_bool_strict(
        fs,
        git_dir + "/config.worktree",
        "index",
        "sparse",
      ),
    )
  }
}

///|
fn ls_files_submodule_is_active(
  fs : &@bitcore.RepoFileSystem,
  git_dir : String,
  name : String,
) -> Bool raise Error {
  ls_files_read_config_bool_strict(
    fs,
    git_dir + "/config",
    "submodule \"\{name}\"",
    "active",
  ).unwrap_or(true)
}

///|
/// Validate a single submodule entry against the rules that prevent
/// path-traversal, hostile URL handling, and arg-injection during
/// `submodule init/update`. Returns true if the entry is safe to
/// consume.
///
/// Rules:
/// - name: non-empty, no NUL / newline / `/` / `..`
/// - path: not absolute, no `..` segments, no `.git` segment
///   (case-insensitive), non-empty
/// - url: must not start with `-` (arg injection), reject `ext::`
///   (git-remote-ext is a remote-helper RCE surface). `file://` is
///   accepted today; tightening it requires a config knob.
///
/// Mirrors the subset of git's CVE-2018-11235 / -17456 / -1387 /
/// 2022-39253 defenses that matters when `bit submodule init/update`
/// consumes attacker-controlled `.gitmodules`.
fn validate_submodule_entry(name : String, path : String, url : String) -> Bool {
  // name: reject empty, traversal patterns, and dangerous chars.
  // Slash IS allowed (git permits names like "nested/sub" to match
  // the path) — we only reject names that begin with "." (matches
  // git's prohibition on .git, .., and dot-prefixed names) and
  // names with "/." or "/../" / trailing "/.."  traversal sequences.
  if name.length() == 0 {
    return false
  }
  if name == ".." || name.has_prefix(".") {
    return false
  }
  if name.contains("/.") || name.has_suffix("/..") {
    return false
  }
  for i in 0..<name.length() {
    let c = name.unsafe_get(i).to_int()
    if c == 0 || c == 0x0A || c == 0x0D || c == 0x5C { // \0 \n \r \\
      return false
    }
  }
  // path
  if path.length() == 0 {
    return false
  }
  if path.has_prefix("/") {
    return false
  }
  // walk path components
  let mut start = 0
  while start <= path.length() {
    let mut end = start
    // 0x2F = '/'
    while end < path.length() && path.unsafe_get(end).to_int() != 0x2F {
      end += 1
    }
    let comp = String::unsafe_substring(path, start~, end~)
    if comp == ".." {
      return false
    }
    // .git (case-insensitive ASCII)
    if comp.length() == 4 && comp.unsafe_get(0).to_int() == 0x2E { // '.'
      let lower = fn(c : Int) -> Int {
        if c >= 0x41 && c <= 0x5A {
          c + 32
        } else {
          c
        }
      }
      let c1 = lower(comp.unsafe_get(1).to_int())
      let c2 = lower(comp.unsafe_get(2).to_int())
      let c3 = lower(comp.unsafe_get(3).to_int())
      if c1 == 0x67 && c2 == 0x69 && c3 == 0x74 { // 'git'
        return false
      }
    }
    if end >= path.length() {
      break
    }
    start = end + 1
  }
  // url
  if url.has_prefix("-") {
    return false
  }
  if url.has_prefix("ext::") {
    return false
  }
  true
}

///|
/// Parse .gitmodules file to extract submodule info. Entries that
/// fail `validate_submodule_entry` are skipped (with a stderr
/// notice), so a malicious .gitmodules can't drive `bit submodule
/// init/update` into writing outside the worktree or running
/// remote-helper commands.
fn parse_gitmodules(
  fs : &@bitcore.RepoFileSystem,
  root : String,
) -> Array[SubmoduleInfo] {
  let gitmodules_path = root + "/.gitmodules"
  if !fs.is_file(gitmodules_path) {
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
    let line = trim_string(line_view.to_owned())
    if line.has_prefix("[submodule \"") && line.has_suffix("\"]") {
      if current_name.length() > 0 &&
        current_path.length() > 0 &&
        validate_submodule_entry(current_name, current_path, current_url) {
        result.push({ name: current_name, path: current_path, url: current_url })
      }
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
  if current_name.length() > 0 &&
    current_path.length() > 0 &&
    validate_submodule_entry(current_name, current_path, current_url) {
    result.push({ name: current_name, path: current_path, url: current_url })
  }
  result
}

///|
fn parse_pathspec_magic(filter : String) -> (String, Bool, Bool) {
  if filter.has_prefix(":!") {
    let rest = String::unsafe_substring(filter, start=2, end=filter.length())
    return (rest, true, false)
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
        let is_icase = magic.contains("icase")
        (rest, is_exclude, is_icase)
      }
      None => (filter, false, false)
    }
  } else {
    (filter, false, false)
  }
}

///|
fn normalize_ls_tree_filters(
  filters : Array[String],
  cwd_prefix : String,
) -> Array[String] raise Error {
  let out : Array[String] = []
  for filter in filters {
    let (raw, is_exclude, _is_icase) = parse_pathspec_magic(filter)
    if is_exclude {
      raise @bitcore.GitError::InvalidObject(
        "pathspec magic not supported by this command: 'exclude' (mnemonic: '!')",
      )
    }
    let mut clean = raw
    // Preserve trailing slash semantics: path/ means "contents of directory"
    let has_trailing_slash = clean.has_suffix("/") && clean.length() > 1
    if has_trailing_slash {
      clean = String::unsafe_substring(clean, start=0, end=clean.length() - 1)
    }
    let base = if clean == "" || clean == "." {
      cwd_prefix
    } else if clean.has_prefix("/") {
      clean
    } else if cwd_prefix.length() == 0 {
      clean
    } else {
      cwd_prefix + "/" + clean
    }
    let normalized = normalize_path(base)
    // Reject paths that escape the tree root (e.g., "../" with --full-tree)
    if normalized == ".." || normalized.has_prefix("../") {
      raise @bitcore.GitError::InvalidObject(
        "'\{filter}' is outside repository at '\{normalize_path(cwd_prefix)}'",
      )
    }
    if normalized != "." && normalized.length() > 0 {
      // Re-append trailing slash to preserve semantics
      if has_trailing_slash {
        out.push(normalized + "/")
      } else {
        out.push(normalized)
      }
    }
  }
  out
}

///|
fn compute_cwd_prefix(root : String) -> String {
  let cwd = match @sys.get_env_var("GIT_SHIM_PWD") {
    Some(dir) => Some(dir)
    None =>
      match @sys.get_env_var("PWD") {
        Some(dir) => Some(dir)
        None => @env.current_dir()
      }
  }
  match cwd {
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
fn make_display_path(path : String, cwd_prefix : String) -> String {
  if cwd_prefix.length() == 0 {
    return path
  }
  let has_trailing_slash = path.has_suffix("/") && path.length() > 1
  let normalized_path = if has_trailing_slash {
    String::unsafe_substring(path, start=0, end=path.length() - 1)
  } else {
    path
  }
  if normalized_path == cwd_prefix {
    return if has_trailing_slash { "./" } else { "." }
  }
  let path_parts : Array[String] = []
  for part_view in normalized_path.split("/") {
    let part = part_view.to_owned()
    if part.length() > 0 {
      path_parts.push(part)
    }
  }
  let cwd_parts : Array[String] = []
  for part_view in cwd_prefix.split("/") {
    let part = part_view.to_owned()
    if part.length() > 0 {
      cwd_parts.push(part)
    }
  }
  let mut common = 0
  while common < path_parts.length() &&
        common < cwd_parts.length() &&
        path_parts[common] == cwd_parts[common] {
    common += 1
  }
  let parts : Array[String] = []
  for _ in common..<cwd_parts.length() {
    parts.push("..")
  }
  for i in common..<path_parts.length() {
    parts.push(path_parts[i])
  }
  let rel = if parts.length() == 0 { "." } else { parts.join("/") }
  if has_trailing_slash && rel != "." {
    rel + "/"
  } else {
    rel
  }
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
  let include_filters : Array[String] = []
  let exclude_filters : Array[String] = []
  for filter in filters {
    let (_raw, is_exclude, _is_icase) = parse_pathspec_magic(filter)
    if is_exclude {
      exclude_filters.push(filter)
    } else {
      include_filters.push(filter)
    }
  }
  let included = if include_filters.length() == 0 {
    true
  } else {
    include_filters
    .iter()
    .any(fn(filter) { ls_files_pathspec_matches(normalized, filter) })
  }
  if !included {
    return false
  }
  !exclude_filters
  .iter()
  .any(fn(filter) { ls_files_pathspec_matches(normalized, filter) })
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
fn ls_files_collect_unmatched_raw_filters(
  raw_filters : Array[String],
  cwd_prefix : String,
  root_abs : String,
  candidate_paths : Array[String],
) -> Array[String] raise Error {
  let unmatched : Array[String] = []
  for raw in raw_filters {
    let normalized_filters = normalize_ls_files_filters(
      [raw],
      cwd_prefix,
      root_abs,
    )
    let include_filters = normalized_filters.filter(fn(filter) {
      let (_raw, is_exclude, _is_icase) = parse_pathspec_magic(filter)
      !is_exclude
    })
    let matched = if include_filters.length() == 0 {
      candidate_paths.length() > 0
    } else {
      include_filters
      .iter()
      .any(fn(filter) {
        candidate_paths
        .iter()
        .any(fn(path) { ls_files_pathspec_matches(path, filter) })
      })
    }
    if !matched {
      unmatched.push(raw)
    }
  }
  unmatched
}

///|
fn ls_files_pathspec_matches(path : String, pattern : String) -> Bool {
  let (raw_pattern, _is_exclude, is_icase) = parse_pathspec_magic(pattern)
  let normalized_pattern = if raw_pattern.has_suffix("/") &&
    raw_pattern.length() > 1 {
    String::unsafe_substring(raw_pattern, start=0, end=raw_pattern.length() - 1)
  } else {
    raw_pattern
  }
  let match_path = if is_icase { path.to_lower() } else { path }
  let match_pattern = if is_icase {
    normalized_pattern.to_lower()
  } else {
    normalized_pattern
  }
  if ls_files_filter_has_wildcard(pattern) {
    ls_files_simple_wildcard_match(match_path, match_pattern)
  } else {
    match_path == match_pattern || match_path.has_prefix(match_pattern + "/")
  }
}

///|
fn ls_files_filter_has_wildcard(pattern : String) -> Bool {
  let (raw_pattern, _is_exclude, _is_icase) = parse_pathspec_magic(pattern)
  raw_pattern.find("*") is Some(_) ||
  raw_pattern.find("?") is Some(_) ||
  raw_pattern.find("[") is Some(_)
}

///|
fn ls_files_filter_prefers_file_output(pattern : String) -> Bool {
  // Heuristic for `--directory`:
  // wildcard patterns that have an extension-like final segment are treated as file globs.
  let (raw_pattern, _is_exclude, _is_icase) = parse_pathspec_magic(pattern)
  let segment = match raw_pattern.rev_find("/") {
    Some(idx) =>
      String::unsafe_substring(
        raw_pattern,
        start=idx + 1,
        end=raw_pattern.length(),
      )
    None => raw_pattern
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
fn ls_files_collect_other_paths(
  fs : &@bitcore.RepoFileSystem,
  root : String,
  git_dir : String,
  tracked : Map[String, Bool],
  entry_map : Map[String, @bitlib.IndexEntry],
  show_ignored? : Bool = false,
  exclude_standard? : Bool = false,
  exclude_patterns : Array[String],
  exclude_from_files : Array[String],
  exclude_per_directory : String?,
) -> (Array[String], Array[String]) raise Error {
  let matcher = @ignore.Matcher::new()
  let db = @bitlib.ObjectDb::load_lazy(fs, git_dir)
  ls_files_add_global_exclude_rules(
    fs, root, git_dir, matcher, exclude_standard, exclude_from_files,
  )
  let per_directory_files : Array[String] = []
  if exclude_standard {
    per_directory_files.push(".gitignore")
  }
  match exclude_per_directory {
    Some(name) =>
      if !per_directory_files.contains(name) {
        per_directory_files.push(name)
      }
    None => ()
  }
  let files : Array[String] = []
  let dirs : Array[String] = []
  ls_files_walk_other_files(
    fs, root, "", tracked, entry_map, matcher, db, per_directory_files, exclude_patterns,
    files, dirs, show_ignored,
  )
  (files, dirs)
}

///|
fn ls_files_add_global_exclude_rules(
  fs : &@bitcore.RepoFileSystem,
  root : String,
  git_dir : String,
  matcher : @ignore.Matcher,
  exclude_standard : Bool,
  exclude_from_files : Array[String],
) -> Unit raise Error {
  if exclude_standard {
    ls_files_add_exclude_file_rules(fs, matcher, git_dir + "/info/exclude")
    let config_path = git_dir + "/config"
    if fs.is_file(config_path) {
      match @bitlib.read_config_value(fs, config_path, "core", "excludesfile") {
        Some(raw) => {
          let resolved = ls_files_resolve_exclude_file_path(root, git_dir, raw)
          ls_files_add_exclude_file_rules(fs, matcher, resolved)
        }
        None => ()
      }
    }
  }
  for raw in exclude_from_files {
    let resolved = ls_files_resolve_exclude_file_path(root, git_dir, raw)
    ls_files_add_exclude_file_rules(fs, matcher, resolved)
  }
}

///|
fn ls_files_add_exclude_file_rules(
  fs : &@bitcore.RepoFileSystem,
  matcher : @ignore.Matcher,
  path : String,
) -> Unit raise Error {
  if fs.is_file(path) {
    let content = @utf8.decode_lossy(fs.read_file(path)[:])
    matcher.add_rules("", content)
  }
}

///|
fn ls_files_add_cli_exclude_rules(
  matcher : @ignore.Matcher,
  patterns : Array[String],
) -> Unit {
  for pattern in patterns {
    matcher.add_rules("", pattern + "\n")
    if pattern.has_prefix("**/") {
      let alt = String::unsafe_substring(pattern, start=3, end=pattern.length())
      matcher.add_rules("", alt + "\n")
    }
  }
}

///|
fn ls_files_add_per_directory_rules(
  fs : &@bitcore.RepoFileSystem,
  root : String,
  rel : String,
  entry_map : Map[String, @bitlib.IndexEntry],
  matcher : @ignore.Matcher,
  db : @bitlib.ObjectDb,
  per_directory_files : Array[String],
) -> Unit raise Error {
  let dir = if rel == "" { root } else { root + "/" + rel }
  for name in per_directory_files {
    let file_rel = if rel == "" { name } else { rel + "/" + name }
    let path = if rel == "" { root + "/" + name } else { dir + "/" + name }
    if fs.is_file(path) {
      let content = @utf8.decode_lossy(fs.read_file(path)[:])
      matcher.add_rules(rel, content)
    } else {
      match entry_map.get(file_rel) {
        Some(entry) =>
          match db.get(fs, entry.id) {
            Some(obj) if obj.obj_type == @bitcore.ObjectType::Blob => {
              let content = @utf8.decode_lossy(obj.data[:])
              matcher.add_rules(rel, content)
            }
            _ => ()
          }
        None => ()
      }
    }
  }
}

///|
fn ls_files_cached_entry_is_ignored(
  fs : &@bitcore.RepoFileSystem,
  root : String,
  git_dir : String,
  entry_map : Map[String, @bitlib.IndexEntry],
  path : String,
  exclude_standard : Bool,
  exclude_patterns : Array[String],
  exclude_from_files : Array[String],
  exclude_per_directory : String?,
) -> Bool raise Error {
  let matcher = @ignore.Matcher::new()
  let db = @bitlib.ObjectDb::load_lazy(fs, git_dir)
  ls_files_add_global_exclude_rules(
    fs, root, git_dir, matcher, exclude_standard, exclude_from_files,
  )
  let per_directory_files : Array[String] = []
  if exclude_standard {
    per_directory_files.push(".gitignore")
  }
  match exclude_per_directory {
    Some(name) =>
      if !per_directory_files.contains(name) {
        per_directory_files.push(name)
      }
    None => ()
  }
  ls_files_add_per_directory_rules(
    fs, root, "", entry_map, matcher, db, per_directory_files,
  )
  let mut current = ""
  let segments : Array[String] = []
  for segment_view in path.split("/") {
    let segment = segment_view.to_owned()
    if segment.length() > 0 {
      segments.push(segment)
    }
  }
  let last = segments.length()
  let mut idx = 0
  for segment in segments {
    if idx >= last - 1 {
      break
    }
    current = if current == "" { segment } else { current + "/" + segment }
    ls_files_add_per_directory_rules(
      fs, root, current, entry_map, matcher, db, per_directory_files,
    )
    idx += 1
  }
  ls_files_add_cli_exclude_rules(matcher, exclude_patterns)
  matcher.is_ignored(path, false)
}

///|
fn ls_files_resolve_exclude_file_path(
  root : String,
  git_dir : String,
  raw : String,
) -> String {
  if raw.has_prefix("/") {
    return raw
  }
  if raw.has_prefix(".git/") {
    let suffix = String::unsafe_substring(raw, start=5, end=raw.length())
    return git_dir + "/" + suffix
  }
  root + "/" + raw
}

///|
fn ls_files_walk_other_files(
  fs : &@bitcore.RepoFileSystem,
  root : String,
  rel : String,
  tracked : Map[String, Bool],
  entry_map : Map[String, @bitlib.IndexEntry],
  matcher : @ignore.Matcher,
  db : @bitlib.ObjectDb,
  per_directory_files : Array[String],
  exclude_patterns : Array[String],
  files_out : Array[String],
  dirs_out : Array[String],
  show_ignored : Bool,
) -> Unit raise Error {
  let dir = if rel == "" { root } else { root + "/" + rel }
  if rel != "" {
    let dot_git_marker = dir + "/.git"
    let bit_marker = dir + "/.bit"
    if fs.is_file(dot_git_marker) ||
      fs.is_dir(dot_git_marker) ||
      fs.is_file(bit_marker) ||
      fs.is_dir(bit_marker) {
      return
    }
  }
  let prev_len = matcher.len()
  ls_files_add_per_directory_rules(
    fs, root, rel, entry_map, matcher, db, per_directory_files,
  )
  ls_files_add_cli_exclude_rules(matcher, exclude_patterns)
  for name in fs.readdir(dir) {
    if name == "." ||
      name == ".." ||
      name == ".git" ||
      name == ".bit" ||
      name == ".jj" {
      continue
    }
    let child_rel = if rel == "" { name } else { rel + "/" + name }
    let child_path = root + "/" + child_rel
    let is_dir = fs.is_dir(child_path)
    let ignored = matcher.is_ignored(child_rel, is_dir)
    if is_dir {
      if !dirs_out.contains(child_rel) {
        dirs_out.push(child_rel)
      }
      if ignored {
        if show_ignored {
          ls_files_walk_other_files(
            fs, root, child_rel, tracked, entry_map, matcher, db, per_directory_files,
            exclude_patterns, files_out, dirs_out, show_ignored,
          )
        }
      } else {
        ls_files_walk_other_files(
          fs, root, child_rel, tracked, entry_map, matcher, db, per_directory_files,
          exclude_patterns, files_out, dirs_out, show_ignored,
        )
      }
      continue
    }
    if tracked.contains(child_rel) {
      continue
    }
    if show_ignored {
      if ignored {
        files_out.push(child_rel)
      }
    } else if !ignored {
      files_out.push(child_rel)
    }
  }
  matcher.truncate(prev_len)
}

///|
fn ls_files_collect_candidate_dirs(
  files : Array[String],
  explicit_dirs : Array[String],
  tracked_dirs : Map[String, Bool],
) -> Array[String] {
  let seen : Map[String, Bool] = Map([])
  for file in files {
    let mut current = file
    while true {
      match current.rev_find("/") {
        Some(idx) => {
          let dir = String::unsafe_substring(current, start=0, end=idx)
          if tracked_dirs.contains(dir) {
            break
          }
          seen[dir] = true
          current = dir
        }
        None => break
      }
    }
  }
  for dir in explicit_dirs {
    if !tracked_dirs.contains(dir) {
      seen[dir] = true
    }
  }
  let out = seen.keys().to_array()
  out.sort_by(fn(a, b) { ls_files_compare_paths(a, b) })
  out
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
fn detect_eol_type(content : Bytes) -> String {
  if content.length() == 0 {
    return ""
  }
  // Binary detection (git gather_stats compatible)
  let limit = if content.length() > 8000 { 8000 } else { content.length() }
  let mut i = 0
  let mut has_lf = false
  let mut has_crlf = false
  while i < limit {
    let b = content[i]
    // NUL byte → binary
    if b == b'\x00' {
      return "-text"
    }
    // lone CR (CR not followed by LF) → binary
    if b == b'\r' {
      if i + 1 < limit && content[i + 1] == b'\n' {
        has_crlf = true
        i += 2
        continue
      } else {
        return "-text"
      }
    }
    // SOH (\x01) at position < 128 → binary
    if b == 0x01 && i < 128 {
      return "-text"
    }
    // EOF/^Z (\x1a) at position < 128 → binary
    if b == 0x1a && i < 128 {
      return "-text"
    }
    if b == b'\n' {
      has_lf = true
    }
    i += 1
  }
  if has_crlf && has_lf {
    "mixed"
  } else if has_crlf {
    "crlf"
  } else if has_lf {
    "lf"
  } else {
    "none"
  }
}

///|
fn format_eol_attr(attrs : @bitlib.FileEolAttrs) -> String {
  match (attrs.text, attrs.eol) {
    (@bitlib.TextAttr::Unspecified, @bitlib.EolAttr::Unspecified) => ""
    (@bitlib.TextAttr::Auto, @bitlib.EolAttr::Unspecified) => "text=auto"
    (@bitlib.TextAttr::Auto, @bitlib.EolAttr::Lf) => "text=auto eol=lf"
    (@bitlib.TextAttr::Auto, @bitlib.EolAttr::Crlf) => "text=auto eol=crlf"
    (@bitlib.TextAttr::Set, @bitlib.EolAttr::Unspecified) => "text"
    (@bitlib.TextAttr::Set, @bitlib.EolAttr::Lf) => "text eol=lf"
    (@bitlib.TextAttr::Set, @bitlib.EolAttr::Crlf) => "text eol=crlf"
    (@bitlib.TextAttr::Unset, _) => "-text"
    (@bitlib.TextAttr::Unspecified, @bitlib.EolAttr::Lf) => "eol=lf"
    (@bitlib.TextAttr::Unspecified, @bitlib.EolAttr::Crlf) => "eol=crlf"
  }
}

///|

///|

///|
async fn show_add_command_help() -> Unit {
  show_simple_command_help(
    "git add [<options>] [--] <pathspec>...",
    summary="Add file contents to the index.",
  )
}

///|
fn add_abs_path(path : String) -> String {
  if path.has_prefix("/") {
    return path
  }
  let cwd = match @env.current_dir() {
    Some(dir) => dir
    None => "."
  }
  normalize_path(cwd + "/" + path)
}

///|
async fn run_add_hook(
  fs : OsFs,
  root : String,
  git_dir : String,
  hook_name : String,
) -> Int {
  let hook_git_dir = add_abs_path(git_dir)
  let work_root = add_abs_path(root)
  run_hook(fs, work_root, hook_git_dir, hook_name, work_root)
}

///|
fn add_need_real_git() -> Bool {
  false
}

///|
fn add_storage_runtime_delegate_args(
  args : Array[String],
) -> @runtime.StorageAddArgs? {
  if add_need_real_git() {
    return None
  }
  let parsed = storage_runtime_parse_command("add", args) catch {
    _ => return None
  }
  match parsed {
    @runtime.StorageCommand::Add(add_args) =>
      if add_args.add_all && add_args.paths.length() == 0 {
        Some(add_args)
      } else {
        None
      }
    _ => None
  }
}

///|
fn add_should_use_storage_runtime(args : Array[String]) -> Bool {
  add_storage_runtime_delegate_args(args) is Some(_)
}

///|
async fn handle_add(args : Array[String]) -> Unit raise Error {
  if has_interactive_add_flag(args) {
    run_add_interactive(args)
    return
  }
  let root = get_work_root()
  let fs = OsFs::new()
  let rfs : &@bitcore.RepoFileSystem = fs
  let git_dir = resolve_git_dir(rfs, root)

  if add_should_use_storage_runtime(args) {
    match add_storage_runtime_delegate_args(args) {
      Some(add_args) => {
        @runtime.run_storage_command(
          fs,
          rfs,
          root,
          @runtime.StorageCommand::Add(add_args),
        )
        return
      }
      None => ()
    }
  }
  let mut add_all = false
  let mut update_only = false
  let mut ignore_removal = false
  let mut force = false
  let mut refresh = false
  let mut dry_run = false
  let mut intent_to_add = false
  let mut ignore_missing = false
  let mut ignore_errors = false
  let mut ignore_errors_explicit = false
  let mut verbose = false
  let mut interactive = false
  let mut chmod_mode : String? = None // "+x" or "-x"
  let mut end_of_options = false
  let paths : Array[String] = []
  for raw_arg in args {
    let arg = raw_arg
    if !end_of_options && arg == "--" {
      end_of_options = true
      continue
    }
    match arg {
      "-A" | "--all" if !end_of_options => add_all = true
      "-u" | "--update" if !end_of_options => update_only = true
      "--no-all" | "--ignore-removal" if !end_of_options =>
        ignore_removal = true
      "-f" | "--force" if !end_of_options => force = true
      "--refresh" if !end_of_options => refresh = true
      "-N" | "--intent-to-add" if !end_of_options => intent_to_add = true
      "-n" | "--dry-run" if !end_of_options => dry_run = true
      "--ignore-missing" if !end_of_options => ignore_missing = true
      "--ignore-errors" if !end_of_options => {
        ignore_errors = true
        ignore_errors_explicit = true
      }
      "--no-ignore-errors" if !end_of_options => {
        ignore_errors = false
        ignore_errors_explicit = true
      }
      "-v" | "--verbose" if !end_of_options => verbose = true
      "--interactive" if !end_of_options => interactive = true
      "--chmod=+x" if !end_of_options => chmod_mode = Some("+x")
      "--chmod=-x" if !end_of_options => chmod_mode = Some("-x")
      _ if end_of_options || !arg.has_prefix("-") => paths.push(arg)
      _ if arg.has_prefix("-") => warn_unimplemented_arg("add", arg)
      _ => ()
    }
  }
  // Read add.ignore-errors config (only if not explicitly set via CLI flag)
  if !ignore_errors_explicit {
    let rfs2 : &@bitcore.RepoFileSystem = fs
    let config_path2 = git_dir + "/config"
    if fs.is_file(config_path2) {
      let ie_val = @bitlib.read_config_bool(
        rfs2, config_path2, "add", "ignore-errors",
      ).unwrap_or(false)
      if ie_val {
        ignore_errors = true
      }
    }
  }
  if dry_run {
    if chmod_mode is Some(cm) {
      handle_add_chmod_dry_run(fs, root, git_dir, paths, cm)
      return
    }
    if update_only {
      handle_add_update_dry_run(fs, root, paths)
      return
    }
    handle_add_dry_run(fs, root, paths, force~, ignore_missing~, interactive~)
    return
  }
  if paths.iter().any(p => p.length() == 0) {
    @sys.exit(1)
  }
  if refresh {
    add_refresh_index_entries(fs, root, paths)
    return
  }
  // Handle --chmod=[+-]x
  if chmod_mode is Some(mode) {
    handle_add_chmod(fs, root, git_dir, paths, mode, verbose)
    return
  }
  if add_all {
    // Stage all: untracked, modified, and deleted
    let status = @bitlib.status(fs, root)
    let all_paths : Array[String] = []
    for p in status.untracked {
      all_paths.push(p)
    }
    for p in status.unstaged_modified {
      all_paths.push(p)
    }
    for p in status.unstaged_deleted {
      all_paths.push(p)
    }
    if all_paths.length() > 0 {
      let pre_code = run_add_hook(fs, root, git_dir, "pre-add")
      if pre_code != 0 {
        raise @bitcore.GitError::InvalidObject("pre-add hook failed")
      }
      let filter_cmd = @bitlib.FilterCmd::{
        run: @bitlibnative.run_filter_command,
      }
      let crlf_warnings : Array[String] = []
      @bitlib.add_paths_async(
        fs,
        fs,
        root,
        all_paths,
        run_filter_cmd=filter_cmd,
        warnings=crlf_warnings,
      )
      for msg in crlf_warnings {
        eprint_line(msg)
      }
      stage_submodule_gitlinks(fs, root, all_paths)

      let post_code = run_add_hook(fs, root, git_dir, "post-add")
      if post_code != 0 {
        raise @bitcore.GitError::InvalidObject("post-add hook failed")
      }
    }
    return
  }
  if paths.length() == 0 && !update_only {
    eprint_line("Nothing specified, nothing added.")
    if add_should_show_empty_pathspec_hint(fs, root) {
      eprint_line("hint: Maybe you wanted to say 'git add .'?")
      eprint_line(
        "hint: Disable this message with \"git config set advice.addEmptyPathspec false\"",
      )
    }
    return
  }
  let requested_paths = if update_only {
    add_collect_update_requested_paths(fs, root, paths)
  } else {
    expand_add_stage_paths(fs, root, paths, force)
  }
  let requested_stage_paths = requested_paths
  let stage_paths = if ignore_removal && !update_only {
    let unmerged_paths = @bitlib.read_unmerged_paths(fs, git_dir)
    match
      add_filter_stage_paths_for_no_all(
        fs, root, requested_stage_paths, unmerged_paths,
      ) {
      Ok(filtered) => filtered
      Err(path) => {
        eprint_line(
          "fatal: unable to stat '\{path}': No such file or directory",
        )
        @sys.exit(1)
        []
      }
    }
  } else {
    requested_stage_paths
  }
  let mut had_error = false
  if stage_paths.length() > 0 {
    let pre_code = run_add_hook(fs, root, git_dir, "pre-add")
    if pre_code != 0 {
      raise @bitcore.GitError::InvalidObject("pre-add hook failed")
    }
    if intent_to_add {
      let intent_paths = add_apply_intent_to_add(
        fs, fs, root, git_dir, stage_paths,
      )
      if verbose {
        for p in intent_paths {
          eprint_line("add '\{p}'")
        }
      }
    } else {
      let filter_cmd = @bitlib.FilterCmd::{
        run: @bitlibnative.run_filter_command,
      }
      if ignore_errors {
        // When --ignore-errors or add.ignore-errors is set, add files one by one
        // so that failures on individual files don't prevent other files from being added
        let succeeded : Array[String] = []
        for p in stage_paths {
          let crlf_warnings : Array[String] = []
          try {
            @bitlib.add_paths_async(
              fs,
              fs,
              root,
              [p],
              run_filter_cmd=filter_cmd,
              warnings=crlf_warnings,
            )
            succeeded.push(p)
            if verbose {
              eprint_line("add '\{p}'")
            }
          } catch {
            _ => had_error = true
          }
          for msg in crlf_warnings {
            eprint_line(msg)
          }
        }
        stage_submodule_gitlinks(fs, root, succeeded)
      } else {
        let crlf_warnings : Array[String] = []
        @bitlib.add_paths_async(
          fs,
          fs,
          root,
          stage_paths,
          run_filter_cmd=filter_cmd,
          warnings=crlf_warnings,
        )
        for msg in crlf_warnings {
          eprint_line(msg)
        }
        if verbose {
          for p in stage_paths {
            eprint_line("add '\{p}'")
          }
        }
        stage_submodule_gitlinks(fs, root, stage_paths)
      }
    }
  }
  if !force && add_has_explicit_ignored_path(fs, root, paths) {
    eprint_line(
      "The following paths are ignored by one of your .gitignore files.",
    )
    eprint_line("hint: Use -f if you really want to add them.")
    @sys.exit(1)
  }
  if requested_paths.length() == 0 && !(update_only && paths.length() == 0) {
    let first = add_first_non_empty_pathspec(paths)
    if first is Some(spec) {
      eprint_line("fatal: pathspec '\{spec}' did not match any files")
      @sys.exit(1)
    }
  }
  if had_error {
    eprint_line("fatal: adding files failed")
    @sys.exit(1)
  }
  if stage_paths.length() > 0 {
    let post_code = run_add_hook(fs, root, git_dir, "post-add")
    if post_code != 0 {
      raise @bitcore.GitError::InvalidObject("post-add hook failed")
    }
  }
}

///|
fn add_filter_stage_paths_for_no_all(
  fs : &@bitcore.RepoFileSystem,
  root : String,
  stage_paths : Array[String],
  unmerged_paths : Map[String, Bool],
) -> Result[Array[String], String] {
  let out : Array[String] = []
  for path in stage_paths {
    let abs = root + "/" + path
    if fs.is_file(abs) || fs.is_dir(abs) {
      out.push(path)
      continue
    }
    if unmerged_paths.contains(path) {
      return Err(path)
    }
  }
  Ok(out)
}

///|
fn add_apply_intent_to_add(
  fs : &@bitcore.FileSystem,
  rfs : &@bitcore.RepoFileSystem,
  root : String,
  git_dir : String,
  stage_paths : Array[String],
) -> Array[String] raise Error {
  let algo = @bitlib.repo_hash_algorithm(rfs, git_dir)
  let entries = @bitlib.read_index_entries(rfs, git_dir)
  let map : Map[String, @bitlib.IndexEntry] = Map([])
  for entry in entries {
    map[entry.path] = entry
  }
  let mut empty_id : @bitcore.ObjectId? = None
  let staged : Array[String] = []
  for path in stage_paths {
    if map.contains(path) {
      continue
    }
    let abs = root + "/" + path
    if !rfs.is_file(abs) {
      continue
    }
    let id = match empty_id {
      Some(existing) => existing
      None => {
        let created = @bitlib.write_loose_object(
          fs,
          git_dir,
          @bitcore.ObjectType::Blob,
          Default::default(),
          algo~,
        )
        @bitlib.compat_record_blob_mapping(
          fs,
          rfs,
          git_dir,
          created,
          Default::default(),
        )
        empty_id = Some(created)
        created
      }
    }
    map[path] = @bitlib.IndexEntry::new(
      path,
      id,
      0o100644,
      0,
      intent_to_add=true,
    )
    staged.push(path)
  }
  if staged.length() == 0 {
    return staged
  }
  let updated = map.values().to_array()
  @bitlib.write_index_entries_preserving_cache_tree(fs, rfs, git_dir, updated)
  staged
}

///|
async fn add_collect_update_requested_paths(
  fs : &@bitcore.RepoFileSystem,
  root : String,
  raw_paths : Array[String],
) -> Array[String] raise Error {
  let git_dir = resolve_git_dir(fs, root)
  let entries = @bitlib.read_index_entries(fs, git_dir)
  let tracked_paths : Array[String] = []
  for entry in entries {
    tracked_paths.push(entry.path)
  }
  if raw_paths.length() == 0 {
    return tracked_paths
  }
  let selected : Map[String, Bool] = Map([])
  for raw in raw_paths {
    let (pattern_raw, icase) = add_parse_refresh_pathspec(raw)
    let pattern = add_normalize_input_path(root, pattern_raw)
    if pattern.length() == 0 {
      continue
    }
    let mut matched = false
    for path in tracked_paths {
      if add_refresh_pathspec_matches(pattern, icase, path) {
        matched = true
        selected[path] = true
      }
    }
    if !matched {
      eprint_line(
        "error: pathspec '\{raw}' did not match any file(s) known to git",
      )
      @sys.exit(1)
    }
  }
  selected.keys().to_array()
}

///|
async fn add_collect_update_stage_paths(
  fs : &@bitcore.RepoFileSystem,
  root : String,
  requested_paths : Array[String],
) -> Array[String] raise Error {
  let status = @bitlib.status(fs, root)
  if requested_paths.length() == 0 {
    let out : Array[String] = []
    out.append(status.unstaged_modified)
    out.append(status.unstaged_deleted)
    return out
  }
  let requested : Map[String, Bool] = Map([])
  for path in requested_paths {
    requested[path] = true
  }
  let out : Array[String] = []
  for path in status.unstaged_modified {
    if requested.contains(path) {
      out.push(path)
    }
  }
  for path in status.unstaged_deleted {
    if requested.contains(path) {
      out.push(path)
    }
  }
  out
}

///|
async fn handle_add_update_dry_run(
  fs : OsFs,
  root : String,
  raw_paths : Array[String],
) -> Unit raise Error {
  let requested_paths = add_collect_update_requested_paths(fs, root, raw_paths)
  let stage_paths = add_collect_update_stage_paths(fs, root, requested_paths)
  for path in stage_paths {
    let abs = root + "/" + path
    if fs.is_file(abs) {
      print_line("add '\{path}'")
    } else {
      print_line("remove '\{path}'")
    }
  }
}

///|
async fn handle_add_dry_run(
  fs : OsFs,
  root : String,
  paths : Array[String],
  force? : Bool = false,
  ignore_missing? : Bool = false,
  interactive? : Bool = false,
) -> Unit raise Error {
  if interactive {
    @sys.exit(1)
  }
  if paths.iter().any(p => p.length() == 0) {
    @sys.exit(1)
  }
  let stage_paths = expand_add_stage_paths(fs, root, paths, force)
  let unmatched = add_collect_unmatched_pathspecs(fs, root, paths, force)
  if unmatched.length() > 0 && !ignore_missing {
    eprint_line("fatal: pathspec '\{unmatched[0]}' did not match any files")
    @sys.exit(1)
  }
  let printed : Map[String, Bool] = Map([])
  for path in stage_paths {
    if printed.contains(path) {
      continue
    }
    printed[path] = true
    print_line("add '\{path}'")
  }
  if unmatched.length() == 0 {
    return
  }
  if ignore_missing {
    let ignored : Array[String] = []
    for spec in unmatched {
      if @bitlib.is_ignored_path(fs, root, spec, false) {
        ignored.push(spec)
      }
    }
    if ignored.length() > 0 {
      eprint_line(
        "The following paths are ignored by one of your .gitignore files:",
      )
      for path in ignored {
        eprint_line(path)
      }
      eprint_line("hint: Use -f if you really want to add them.")
      eprint_line(
        "hint: Disable this message with \"git config set advice.addIgnoredFile false\"",
      )
    }
    @sys.exit(1)
  }
  @sys.exit(1)
}

///|
async fn add_collect_unmatched_pathspecs(
  fs : &@bitcore.RepoFileSystem,
  root : String,
  paths : Array[String],
  force : Bool,
) -> Array[String] raise Error {
  let out : Array[String] = []
  let git_dir = resolve_git_dir(fs, root)
  let tracked_entries = @bitlib.read_index_entries(fs, git_dir)
  let tracked : Map[String, Bool] = Map([])
  let tracked_folded : Map[String, String] = Map([])
  for entry in tracked_entries {
    let normalized = normalize_add_path(entry.path)
    tracked[normalized] = true
    let folded = normalized.to_lower()
    if !tracked_folded.contains(folded) {
      tracked_folded[folded] = normalized
    }
  }
  let visible_paths = if force {
    []
  } else {
    @bitlib.list_working_files_async(fs, root)
  }
  let visible_map : Map[String, Bool] = Map([])
  let visible_folded : Map[String, String] = Map([])
  for p in visible_paths {
    visible_map[p] = true
    let folded = p.to_lower()
    if !visible_folded.contains(folded) {
      visible_folded[folded] = p
    }
  }
  for raw_path in paths {
    let path = add_normalize_input_path(root, raw_path)
    if path.length() == 0 || path == "." {
      continue
    }
    let abs = root + "/" + path
    let matched = if visible_map.get(path) is Some(_) {
      true
    } else if visible_folded.get(path.to_lower()) is Some(_) {
      true
    } else if tracked.contains(path) {
      true
    } else if tracked_folded.get(path.to_lower()) is Some(_) {
      true
    } else if fs.is_dir(abs) {
      let prefix = path + "/"
      visible_paths.iter().any(p => p.has_prefix(prefix))
    } else {
      false
    }
    if !matched {
      out.push(path)
    }
  }
  out
}

///|
fn add_first_non_empty_pathspec(paths : Array[String]) -> String? {
  for raw in paths {
    let normalized = normalize_add_path(raw)
    if normalized.length() > 0 && normalized != "." {
      return Some(normalized)
    }
  }
  None
}

///|
async fn add_refresh_index_entries(
  fs : OsFs,
  root : String,
  raw_specs : Array[String],
) -> Unit raise Error {
  let git_dir = resolve_git_dir(fs, root)
  let entries = @bitlib.read_index_entries(fs, git_dir)
  if entries.length() == 0 {
    return
  }
  let tracked_paths : Array[String] = []
  for entry in entries {
    tracked_paths.push(entry.path)
  }
  let selected : Map[String, Bool] = Map([])
  if raw_specs.length() == 0 {
    for path in tracked_paths {
      selected[path] = true
    }
  } else {
    for raw in raw_specs {
      let (pattern, icase) = add_parse_refresh_pathspec(raw)
      if pattern.length() == 0 {
        continue
      }
      let mut matched = false
      for path in tracked_paths {
        if add_refresh_pathspec_matches(pattern, icase, path) {
          matched = true
          selected[path] = true
        }
      }
      if !matched {
        eprint_line("fatal: pathspec '\{raw}' did not match any files")
        @sys.exit(1)
      }
    }
  }
  let refreshed : Array[@bitlib.IndexEntry] = []
  for entry in entries {
    if !selected.contains(entry.path) {
      refreshed.push(entry)
      continue
    }
    let abs = root + "/" + entry.path
    if !fs.is_file(abs) {
      refreshed.push(entry)
      continue
    }
    let mut size = entry.size
    try {
      size = fs.read_file(abs).length()
    } catch {
      _ => ()
    }
    let mut mtime_sec = entry.mtime_sec
    let mut mtime_nsec = entry.mtime_nsec
    try {
      let (sec, nsec) = @asyncfs.mtime(abs, follow_symlink=false)
      mtime_sec = sec.to_int()
      mtime_nsec = nsec
    } catch {
      _ => ()
    }
    refreshed.push(
      @bitlib.IndexEntry::new(
        entry.path,
        entry.id,
        entry.mode,
        size,
        mtime_sec~,
        mtime_nsec~,
        intent_to_add=entry.intent_to_add,
        dev=entry.dev,
        ino=entry.ino,
        uid=entry.uid,
        gid=entry.gid,
      ),
    )
  }
  @bitlib.write_index_entries_preserving_cache_tree(fs, fs, git_dir, refreshed)
}

///|
fn add_parse_refresh_pathspec(raw : String) -> (String, Bool) {
  let normalized = normalize_add_path(raw)
  if normalized.has_prefix(":(") {
    match normalized.find(")") {
      Some(idx) => {
        let magic = String::unsafe_substring(normalized, start=2, end=idx)
        let rest = String::unsafe_substring(
          normalized,
          start=idx + 1,
          end=normalized.length(),
        )
        let mut icase = false
        for token_view in magic.split(",") {
          let token = trim_string(token_view.to_owned())
          if token == "icase" {
            icase = true
          }
        }
        (normalize_add_path(rest), icase)
      }
      None => (normalized, false)
    }
  } else {
    (normalized, false)
  }
}

///|
fn add_refresh_pathspec_matches(
  spec : String,
  icase : Bool,
  path : String,
) -> Bool {
  if spec == "." {
    return true
  }
  if icase {
    let folded_spec = spec.to_lower()
    let folded_path = path.to_lower()
    return folded_path == folded_spec ||
      folded_path.has_prefix(folded_spec + "/")
  }
  path == spec || path.has_prefix(spec + "/")
}

///|
fn normalize_add_path(path : String) -> String {
  let mut out = path
  while out.has_prefix("./") {
    out = String::unsafe_substring(out, start=2, end=out.length())
  }
  while out.length() > 1 && out.has_suffix("/") {
    out = String::unsafe_substring(out, start=0, end=out.length() - 1)
  }
  let sb = StringBuilder::new()
  let mut i = 0
  while i < out.length() {
    let c = out[i].unsafe_to_char()
    if c == '\\' && i + 1 < out.length() {
      let next = out[i + 1].unsafe_to_char()
      if next == '[' || next == ']' || next == '\\' {
        sb.write_char(next)
        i += 2
        continue
      }
    }
    sb.write_char(c)
    i += 1
  }
  sb.to_string()
}

///|
fn add_normalize_input_path(root : String, raw_path : String) -> String {
  let path = normalize_add_path(raw_path)
  if path.length() == 0 {
    return path
  }
  let normalized = if !path.has_prefix("/") {
    let cwd_rel = add_repo_relative_cwd(root)
    if cwd_rel.length() > 0 {
      if path == "." {
        normalize_path(cwd_rel)
      } else {
        normalize_path(cwd_rel + "/" + path)
      }
    } else {
      normalize_path(path)
    }
  } else {
    normalize_path(path)
  }
  let root_prefix = if root.has_suffix("/") { root } else { root + "/" }
  if normalized.has_prefix(root_prefix) {
    return String::unsafe_substring(
      normalized,
      start=root_prefix.length(),
      end=normalized.length(),
    )
  }
  let normalized_folded = normalized.to_lower()
  let root_folded = root_prefix.to_lower()
  if normalized_folded.has_prefix(root_folded) {
    return String::unsafe_substring(
      normalized,
      start=root_prefix.length(),
      end=normalized.length(),
    )
  }
  normalized
}

///|
fn add_repo_relative_cwd(root : String) -> String {
  let cwd = match @sys.get_env_var("GIT_SHIM_CWD") {
    Some(dir) => dir
    None =>
      match @sys.get_env_var("GIT_SHIM_PWD") {
        Some(dir) => dir
        None =>
          match @env.current_dir() {
            Some(dir) => dir
            None => return ""
          }
      }
  }
  let root_prefix = if root.has_suffix("/") { root } else { root + "/" }
  if cwd == root {
    return ""
  }
  if cwd.has_prefix(root_prefix) {
    return normalize_add_path(
      String::unsafe_substring(
        cwd,
        start=root_prefix.length(),
        end=cwd.length(),
      ),
    )
  }
  let cwd_folded = cwd.to_lower()
  let root_folded = root_prefix.to_lower()
  if cwd_folded.has_prefix(root_folded) {
    return normalize_add_path(
      String::unsafe_substring(
        cwd,
        start=root_prefix.length(),
        end=cwd.length(),
      ),
    )
  }
  ""
}

///|
fn add_should_show_empty_pathspec_hint(
  fs : &@bitcore.RepoFileSystem,
  root : String,
) -> Bool {
  let git_dir = resolve_git_dir(fs, root)
  match get_config_override("advice.addEmptyPathspec") {
    Some(value) => add_parse_bool(value).unwrap_or(true)
    None =>
      @bitlib.read_config_bool(
        fs,
        git_dir + "/config",
        "advice",
        "addemptypathspec",
      ).unwrap_or(true)
  }
}

///|
fn add_parse_bool(value : String) -> Bool? {
  let lowered = trim_string(value).to_lower()
  if lowered == "true" || lowered == "yes" || lowered == "on" || lowered == "1" {
    Some(true)
  } else if lowered == "false" ||
    lowered == "no" ||
    lowered == "off" ||
    lowered == "0" {
    Some(false)
  } else {
    None
  }
}

///|
async fn expand_add_stage_paths(
  fs : &@bitcore.RepoFileSystem,
  root : String,
  paths : Array[String],
  force : Bool,
) -> Array[String] raise Error {
  let out : Array[String] = []
  let seen : Map[String, Bool] = Map([])
  let visible_paths = if force {
    []
  } else {
    @bitlib.list_working_files_async(fs, root)
  }
  let git_dir = resolve_git_dir(fs, root)
  let tracked_entries = @bitlib.read_index_entries(fs, git_dir)
  let tracked_map : Map[String, Bool] = Map([])
  let tracked_folded : Map[String, String] = Map([])
  for entry in tracked_entries {
    let normalized = normalize_add_path(entry.path)
    tracked_map[normalized] = true
    let folded = normalized.to_lower()
    if !tracked_folded.contains(folded) {
      tracked_folded[folded] = normalized
    }
  }
  let visible_map : Map[String, Bool] = Map([])
  let visible_folded : Map[String, String] = Map([])
  for p in visible_paths {
    visible_map[p] = true
    let folded = p.to_lower()
    if !visible_folded.contains(folded) {
      visible_folded[folded] = p
    }
  }
  for raw_path in paths {
    let path = add_normalize_input_path(root, raw_path)
    if path.length() == 0 {
      continue
    }
    if force {
      expand_force_add_path(fs, root, path, seen, out)
      continue
    }
    if path == "." {
      for p in visible_paths {
        add_push_unique_stage_path(seen, out, p)
      }
      add_collect_embedded_repo_paths(fs, root, "", seen, out)
      continue
    }
    let abs = root + "/" + path
    if fs.is_dir(abs) {
      if add_is_embedded_repo_dir(fs, root, path) {
        add_push_unique_stage_path(seen, out, path)
        continue
      }
      let prefix = path + "/"
      for p in visible_paths {
        if p.has_prefix(prefix) {
          add_push_unique_stage_path(seen, out, p)
        }
      }
      add_collect_embedded_repo_paths(fs, root, path, seen, out)
      continue
    }
    if visible_map.get(path) is Some(_) {
      add_push_unique_stage_path(seen, out, path)
      continue
    }
    match visible_folded.get(path.to_lower()) {
      Some(actual) => {
        add_push_unique_stage_path(seen, out, actual)
        continue
      }
      None => ()
    }
    if tracked_map.contains(path) {
      add_push_unique_stage_path(seen, out, path)
      continue
    }
    match tracked_folded.get(path.to_lower()) {
      Some(actual) => add_push_unique_stage_path(seen, out, actual)
      None => ()
    }
  }
  out
}

///|
fn add_push_unique_stage_path(
  seen : Map[String, Bool],
  out : Array[String],
  path : String,
) -> Unit {
  if path.length() == 0 || seen.contains(path) {
    return
  }
  seen[path] = true
  out.push(path)
}

///|
fn add_is_embedded_repo_dir(
  fs : &@bitcore.RepoFileSystem,
  root : String,
  rel : String,
) -> Bool {
  if rel.length() == 0 {
    return false
  }
  let abs = root + "/" + rel
  if !fs.is_dir(abs) {
    return false
  }
  let dot_git = abs + "/.git"
  let bit_dir = abs + "/.bit"
  fs.is_file(dot_git) ||
  fs.is_dir(dot_git) ||
  fs.is_file(bit_dir) ||
  fs.is_dir(bit_dir)
}

///|
fn add_collect_embedded_repo_paths(
  fs : &@bitcore.RepoFileSystem,
  root : String,
  rel : String,
  seen : Map[String, Bool],
  out : Array[String],
) -> Unit raise Error {
  let dir = if rel.length() == 0 { root } else { root + "/" + rel }
  if !fs.is_dir(dir) {
    return
  }
  for name in fs.readdir(dir) {
    if name == "." ||
      name == ".." ||
      name == ".git" ||
      name == ".bit" ||
      name == ".jj" {
      continue
    }
    let child_rel = if rel.length() == 0 { name } else { rel + "/" + name }
    let child_abs = root + "/" + child_rel
    if !fs.is_dir(child_abs) {
      continue
    }
    if @bitlib.is_ignored_path(fs, root, child_rel, true) {
      continue
    }
    if add_is_embedded_repo_dir(fs, root, child_rel) {
      add_push_unique_stage_path(seen, out, child_rel)
    } else {
      add_collect_embedded_repo_paths(fs, root, child_rel, seen, out)
    }
  }
}

///|
fn expand_force_add_path(
  fs : &@bitcore.RepoFileSystem,
  root : String,
  path : String,
  seen : Map[String, Bool],
  out : Array[String],
) -> Unit raise Error {
  if path == "." {
    collect_all_addable_paths(fs, root, "", out)
    return
  }
  let abs = root + "/" + path
  if fs.is_dir(abs) {
    if add_is_embedded_repo_dir(fs, root, path) {
      add_push_unique_stage_path(seen, out, path)
      return
    }
    collect_all_addable_paths(fs, root, path, out)
  } else {
    add_push_unique_stage_path(seen, out, path)
  }
}

///|
fn collect_all_addable_paths(
  fs : &@bitcore.RepoFileSystem,
  root : String,
  rel : String,
  out : Array[String],
) -> Unit raise Error {
  let dir = if rel.length() == 0 { root } else { root + "/" + rel }
  if !fs.is_dir(dir) {
    return
  }
  for name in fs.readdir(dir) {
    if name == "." ||
      name == ".." ||
      name == ".git" ||
      name == ".bit" ||
      name == ".jj" {
      continue
    }
    let child_rel = if rel.length() == 0 { name } else { rel + "/" + name }
    let child_abs = root + "/" + child_rel
    if fs.is_dir(child_abs) {
      if add_is_embedded_repo_dir(fs, root, child_rel) {
        out.push(child_rel)
      } else {
        collect_all_addable_paths(fs, root, child_rel, out)
      }
    } else {
      out.push(child_rel)
    }
  }
}

///|
fn add_has_explicit_ignored_path(
  fs : &@bitcore.RepoFileSystem,
  root : String,
  paths : Array[String],
) -> Bool raise Error {
  let git_dir = resolve_git_dir(fs, root)
  let tracked_entries = @bitlib.read_index_entries(fs, git_dir)
  let tracked : Map[String, Bool] = Map([])
  for entry in tracked_entries {
    tracked[normalize_add_path(entry.path)] = true
  }
  for raw_path in paths {
    let rel = add_normalize_input_path(root, raw_path)
    if rel.length() == 0 {
      continue
    }
    if rel == "." {
      continue
    }
    if tracked.contains(rel) {
      continue
    }
    let abs = root + "/" + rel
    if fs.is_dir(abs) {
      if add_has_ignored_under(fs, root, rel) {
        return true
      }
    } else if @bitlib.is_ignored_path(fs, root, rel, false) {
      return true
    }
  }
  false
}

///|
fn add_has_ignored_under(
  fs : &@bitcore.RepoFileSystem,
  root : String,
  rel : String,
) -> Bool raise Error {
  let dir = if rel.length() == 0 { root } else { root + "/" + rel }
  if !fs.is_dir(dir) {
    return false
  }
  for name in fs.readdir(dir) {
    if name == "." ||
      name == ".." ||
      name == ".git" ||
      name == ".bit" ||
      name == ".jj" {
      continue
    }
    let child_rel = if rel.length() == 0 { name } else { rel + "/" + name }
    let child_abs = root + "/" + child_rel
    let is_dir = fs.is_dir(child_abs)
    if @bitlib.is_ignored_path(fs, root, child_rel, is_dir) {
      return true
    }
    if is_dir && add_has_ignored_under(fs, root, child_rel) {
      return true
    }
  }
  false
}

///|
/// Handle git add --chmod=[+-]x: update the mode of index entries
async fn handle_add_chmod(
  fs : OsFs,
  root : String,
  git_dir : String,
  paths : Array[String],
  mode : String,
  verbose : Bool,
) -> Unit raise Error {
  let target_mode = if mode == "+x" { 0o100755 } else { 0o100644 }
  let rfs : &@bitcore.RepoFileSystem = fs
  // First, add the files normally (stages new files)
  let stage_paths = expand_add_stage_paths(rfs, root, paths, false)
  if stage_paths.length() > 0 {
    let filter_cmd = @bitlib.FilterCmd::{
      run: @bitlibnative.run_filter_command,
    }
    let crlf_warnings : Array[String] = []
    @bitlib.add_paths_async(
      fs,
      fs,
      root,
      stage_paths,
      run_filter_cmd=filter_cmd,
      warnings=crlf_warnings,
    )
    for msg in crlf_warnings {
      eprint_line(msg)
    }
  }
  // Now read index and update modes
  let entries = @bitlib.read_index_entries(rfs, git_dir)
  let matched_paths = add_resolve_chmod_paths(rfs, root, paths, entries)
  let mut had_error = false
  let updated : Array[@bitlib.IndexEntry] = []
  for entry in entries {
    if matched_paths.contains(entry.path) {
      // Check if it's a regular file (not symlink/gitlink)
      if add_is_regular_file_mode(entry.mode) {
        updated.push(
          @bitlib.IndexEntry::new(
            entry.path,
            entry.id,
            target_mode,
            entry.size,
            mtime_sec=entry.mtime_sec,
            mtime_nsec=entry.mtime_nsec,
            intent_to_add=entry.intent_to_add,
            dev=entry.dev,
            ino=entry.ino,
            uid=entry.uid,
            gid=entry.gid,
          ),
        )
        if verbose {
          eprint_line("add '\{entry.path}'")
        }
      } else {
        // Cannot chmod non-regular files (symlinks, submodules)
        eprint_line("cannot chmod \{mode} '\{entry.path}'")
        had_error = true
        updated.push(entry)
      }
    } else {
      updated.push(entry)
    }
  }
  @bitlib.write_index_entries_preserving_cache_tree(fs, fs, git_dir, updated)
  if had_error {
    @sys.exit(1)
  }
}

///|
/// Handle git add --chmod=[+-]x --dry-run
async fn handle_add_chmod_dry_run(
  fs : OsFs,
  root : String,
  git_dir : String,
  paths : Array[String],
  mode : String,
) -> Unit raise Error {
  let rfs : &@bitcore.RepoFileSystem = fs
  let entries = @bitlib.read_index_entries(rfs, git_dir)
  let stage_paths = expand_add_stage_paths(rfs, root, paths, false)
  let matched_paths = add_resolve_chmod_paths(rfs, root, paths, entries)
  let mut had_error = false
  for p in stage_paths {
    print_line("add '\{p}'")
  }
  // Check for unmatched pathspecs
  for raw_path in paths {
    let path = add_normalize_input_path(root, raw_path)
    if path == "." || path.length() == 0 {
      continue
    }
    let in_index = matched_paths.contains(path)
    let in_stage = stage_paths.iter().any(fn(p) { p == path })
    let abs = root + "/" + path
    let is_dir_match = if rfs.is_dir(abs) {
      entries.iter().any(fn(e) { e.path.has_prefix(path + "/") }) ||
      stage_paths.iter().any(fn(p) { p.has_prefix(path + "/") })
    } else {
      false
    }
    if !in_index && !in_stage && !is_dir_match {
      eprint_line("fatal: pathspec '\{path}' did not match any files")
      @sys.exit(128)
    }
  }
  for entry in entries {
    if matched_paths.contains(entry.path) {
      if !add_is_regular_file_mode(entry.mode) {
        eprint_line("cannot chmod \{mode} '\{entry.path}'")
        had_error = true
      }
    }
  }
  if had_error {
    @sys.exit(1)
  }
}

///|
/// Resolve paths for chmod: expand "." and directory paths to matching index entries
fn add_resolve_chmod_paths(
  fs : &@bitcore.RepoFileSystem,
  root : String,
  paths : Array[String],
  entries : Array[@bitlib.IndexEntry],
) -> Map[String, Bool] {
  let result : Map[String, Bool] = Map([])
  for raw_path in paths {
    let path = add_normalize_input_path(root, raw_path)
    if path == "." || path.length() == 0 {
      // Match all entries
      for entry in entries {
        result[entry.path] = true
      }
    } else {
      let abs = root + "/" + path
      if fs.is_dir(abs) {
        let prefix = path + "/"
        for entry in entries {
          if entry.path.has_prefix(prefix) || entry.path == path {
            result[entry.path] = true
          }
        }
        // Only add to result if the path exists in the index
      } else if entries.iter().any(fn(e) { e.path == path }) {
        result[path] = true
      }
    }
  }
  result
}

///|
fn add_is_regular_file_mode(mode : Int) -> Bool {
  mode == 0o100644 || mode == 0o100755
}

///|
fn stage_submodule_gitlinks(
  fs : OsFs,
  root : String,
  paths : Array[String],
) -> Unit raise Error {
  let rfs : &@bitcore.RepoFileSystem = fs
  let git_dir = resolve_git_dir(fs, root)
  for raw_path in paths {
    let rel_path = normalize_add_path(raw_path)
    if rel_path == "." || rel_path.length() == 0 {
      continue
    }
    let sub_path = root + "/" + rel_path
    let sub_git = sub_path + "/.git"
    let sub_git_dir = if rfs.is_file(sub_git) {
      @bitlib.resolve_gitdir(rfs, sub_git)
    } else if rfs.is_dir(sub_git) {
      sub_git
    } else {
      continue
    }
    match @bitlib.resolve_head_commit(rfs, sub_git_dir) {
      Some(id) => update_submodule_index_entry(fs, git_dir, rel_path, id)
      None => ()
    }
  }
}

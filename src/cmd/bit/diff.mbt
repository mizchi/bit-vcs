///| Miscellaneous handlers: diff, merge, tag, rm, mv, config, sparse-checkout, rev-parse, cat-file, ls-files, hash-object, ls-tree, write-tree, show-ref, update-ref, symbolic-ref

///|
fn find_git_dir(fs : OsFs) -> String {
  // Check GIT_DIR environment variable first
  if @sys.get_env_var("GIT_DIR") is Some(dir) {
    if fs.is_dir(dir) || fs.is_file(dir) {
      return dir
    }
  }
  // Check if current directory is a .git directory (bare repo or inside .git)
  let cwd = get_work_root()
  if fs.is_file(cwd + "/config") &&
    fs.is_file(cwd + "/HEAD") &&
    fs.is_dir(cwd + "/refs") {
    return cwd
  }
  // Standard case: .git subdirectory
  cwd + "/.git"
}

///|
fn get_config_override(key : String) -> String? {
  let overrides = @sys.get_env_var("GIT_CONFIG_OVERRIDES")
  match overrides {
    Some(data) => {
      for line_view in data.split("\n") {
        let line = line_view.to_string()
        match line.find("=") {
          Some(eq_idx) => {
            let k = String::unsafe_substring(line, start=0, end=eq_idx)
            // Case-insensitive comparison for config keys
            if k.to_lower() == key.to_lower() {
              return Some(
                String::unsafe_substring(
                  line,
                  start=eq_idx + 1,
                  end=line.length(),
                ),
              )
            }
          }
          None => ()
        }
      }
      None
    }
    None => None
  }
}

///|
fn is_gitlink_mode_for_diff(mode : Int) -> Bool {
  mode == 0o160000
}

///|
fn looks_like_cached_diff_revision(token : String) -> Bool {
  token == "HEAD" ||
  token == "@" ||
  token.has_prefix("HEAD^") ||
  token.has_prefix("HEAD~")
}

///|
async fn handle_diff(args : Array[String]) -> Unit raise Error {
  let root = get_work_root()
  let fs = OsFs::new()
  let rfs : &@bitcore.RepoFileSystem = fs
  let git_dir = resolve_git_dir(rfs, root)
  let repo_git_dir = resolve_submodule_common_git_dir(rfs, git_dir)
  let mut submodule_mode = false
  let mut range_spec : String? = None
  let mut cached = false
  let mut stat_mode = false
  let mut name_only = false
  let mut name_status = false
  let mut quiet = false
  let mut exit_code = false
  let mut parse_options = true
  let mut ref_target : String? = None
  let paths : Array[String] = []
  for arg in args {
    if parse_options && arg == "--" {
      parse_options = false
      continue
    }
    if arg == "--submodule" || arg.has_prefix("--submodule=") {
      submodule_mode = true
    }
    if parse_options {
      match arg {
        "--cached" | "--staged" => cached = true
        "--stat" => stat_mode = true
        "--name-only" => name_only = true
        "--name-status" => name_status = true
        "--quiet" => {
          quiet = true
          exit_code = true
        }
        "--exit-code" => exit_code = true
        "--submodule" => ()
        _ if arg.has_prefix("--submodule=") => ()
        _ if not(arg.has_prefix("-")) =>
          if arg.contains("^!") || arg.contains("..") {
            if range_spec is None {
              range_spec = Some(arg)
            }
          } else if cached &&
            ref_target is None &&
            looks_like_cached_diff_revision(arg) {
            ref_target = Some(arg)
          } else if arg.contains("/") && ref_target is None {
            // Check if it's a ref (contains / like origin/main)
            ref_target = Some(arg)
          } else {
            paths.push(arg)
          }
        _ if arg.has_prefix("-") => warn_unimplemented_arg("diff", arg)
        _ => ()
      }
    } else if arg.contains("^!") || arg.contains("..") {
      if range_spec is None {
        range_spec = Some(arg)
      }
    } else if cached &&
      ref_target is None &&
      looks_like_cached_diff_revision(arg) {
      ref_target = Some(arg)
    } else if arg.contains("/") && ref_target is None {
      ref_target = Some(arg)
    } else {
      paths.push(arg)
    }
  }
  // Handle subdir-clone diff with upstream ref
  match (ref_target, get_subdir_info(fs, git_dir)) {
    (Some(refspec), Some((_, subdir_path, _))) => {
      handle_subdir_diff(
        fs, root, git_dir, refspec, subdir_path, stat_mode, name_only, name_status,
      ) catch {
        err => raise err
      }
      if exit_code {
        // `handle_subdir_diff` writes output directly; use diff result as conservative signal.
        let files = if cached {
          @bitdiff.diff_index(fs, root)
        } else {
          @bitdiff.diff_worktree(fs, root)
        }
        if files.length() > 0 {
          @sys.exit(1)
        }
      }
      return
    }
    _ => ()
  }
  let all_files = match range_spec {
    Some(spec) => {
      if submodule_mode {
        let handled = try_handle_submodule_range_diff(
          fs, root, git_dir, repo_git_dir, spec,
        )
        if handled {
          return
        }
      }
      let db = @bitlib.ObjectDb::load(rfs, repo_git_dir)
      match resolve_submodule_diff_range(db, rfs, repo_git_dir, spec) {
        Some((old_id, new_id)) => {
          let old_tree = resolve_diff_tree_id(db, rfs, old_id)
          let new_tree = resolve_diff_tree_id(db, rfs, new_id)
          match (old_tree, new_tree) {
            (Some(ot), Some(nt)) =>
              @bitdiff.diff_trees(rfs, repo_git_dir, Some(ot), nt)
            _ =>
              raise @bitcore.GitError::InvalidObject(
                "unsupported diff range: " + spec,
              )
          }
        }
        None =>
          raise @bitcore.GitError::InvalidObject(
            "unsupported diff range: " + spec,
          )
      }
    }
    None =>
      if cached {
        match ref_target {
          Some(spec) => diff_cached_against_ref(fs, rfs, root, git_dir, spec)
          None => @bitdiff.diff_index(fs, root)
        }
      } else {
        @bitdiff.diff_worktree(fs, root)
      }
  }
  // Filter by paths if specified
  let files = if paths.length() > 0 {
    all_files
    .iter()
    .filter(fn(f) {
      paths.iter().any(p => f.path == p || f.path.has_prefix(p + "/"))
    })
    .collect()
  } else {
    all_files
  }
  if not(quiet) {
    // Output based on mode
    if name_only {
      for f in files {
        print_line(f.path)
      }
    } else if name_status {
      for f in files {
        let status = match f.kind {
          @bitdiff.DiffKind::Added => "A"
          @bitdiff.DiffKind::Modified => "M"
          @bitdiff.DiffKind::Deleted => "D"
        }
        print_line("\{status}\t\{f.path}")
      }
    } else if stat_mode {
      let lines = @bitdiff.diff_stat(files)
      for line in lines {
        print_line(line)
      }
    } else {
      let lines = @bitdiff.diff_text(files)
      for line in lines {
        print_line(line)
      }
    }
  }
  if exit_code && files.length() > 0 {
    @sys.exit(1)
  }
}

///|
async fn handle_diff_files(args : Array[String]) -> Unit raise Error {
  let mut exit_code = false
  let mut quiet = false
  let mut name_only = false
  let mut name_status = false
  let mut parse_options = true
  let filters : Array[String] = []
  for arg in args {
    if parse_options && arg == "--" {
      parse_options = false
      continue
    }
    if parse_options {
      match arg {
        "--exit-code" => exit_code = true
        "--quiet" => {
          quiet = true
          exit_code = true
        }
        "--name-only" => name_only = true
        "--name-status" => name_status = true
        _ if not(arg.has_prefix("-")) => filters.push(arg)
        _ => ()
      }
    } else {
      filters.push(arg)
    }
  }
  let root = get_work_root()
  let fs = OsFs::new()
  let stale_entries = collect_diff_index_stale_entries(fs, root, filters)
  if stale_entries.length() > 0 {
    if exit_code {
      @sys.exit(1)
    }
    if not(quiet) {
      if name_only {
        for entry in stale_entries {
          print_line(entry.path)
        }
      } else if name_status {
        for entry in stale_entries {
          print_line("M\t" + entry.path)
        }
      } else {
        for entry in stale_entries {
          print_line(format_diff_index_line_from_entry(entry))
        }
      }
    }
    return
  }
  handle_diff(args)
}

///|
async fn handle_diff_index(args : Array[String]) -> Unit raise Error {
  let mut exit_code = false
  let mut quiet = false
  let mut name_only = false
  let mut cached = false
  let mut parse_options = true
  let mut treeish : String? = None
  let filters : Array[String] = []
  for arg in args {
    if parse_options && arg == "--" {
      parse_options = false
      continue
    }
    if parse_options {
      match arg {
        "--exit-code" => exit_code = true
        "--quiet" => {
          quiet = true
          exit_code = true
        }
        "--name-only" => name_only = true
        "--cached" => cached = true
        _ if arg.has_prefix("-") => warn_unimplemented_arg("diff-index", arg)
        _ =>
          if treeish is None {
            treeish = Some(arg)
          } else {
            filters.push(arg)
          }
      }
    } else {
      filters.push(arg)
    }
  }
  let root = get_work_root()
  let fs = OsFs::new()
  let rfs : &@bitcore.RepoFileSystem = fs
  let git_dir = resolve_git_dir(rfs, root)
  let target = treeish.unwrap_or("HEAD")
  let staged_all = diff_cached_against_ref(fs, rfs, root, git_dir, target)
  let staged : Array[@bitdiff.DiffFile] = []
  let staged_paths : Map[String, Bool] = {}
  for file in staged_all {
    if diff_path_matches_filters(file.path, filters) {
      staged.push(file)
      staged_paths[file.path] = true
    }
  }
  let stale_all = if cached {
    []
  } else {
    collect_diff_index_stale_entries(fs, root, filters)
  }
  let stale : Array[@bitlib.IndexEntry] = []
  for entry in stale_all {
    if not(staged_paths.contains(entry.path)) {
      stale.push(entry)
    }
  }
  let has_changes = staged.length() > 0 || stale.length() > 0
  if not(quiet) {
    if name_only {
      for file in staged {
        print_line(file.path)
      }
      for entry in stale {
        print_line(entry.path)
      }
    } else {
      for file in staged {
        print_line(format_diff_index_line_from_diff_file(file))
      }
      for entry in stale {
        print_line(format_diff_index_line_from_entry(entry))
      }
    }
  }
  if exit_code && has_changes {
    @sys.exit(1)
  }
}

///|
async fn collect_diff_index_stale_entries(
  fs : OsFs,
  root : String,
  filters : Array[String],
) -> Array[@bitlib.IndexEntry] raise Error {
  let git_dir = resolve_git_dir(fs, root)
  let entries = @bitlib.read_index_entries(fs, git_dir)
  let stale : Array[@bitlib.IndexEntry] = []
  for entry in entries {
    if not(diff_path_matches_filters(entry.path, filters)) {
      continue
    }
    let mut is_stale = entry.mtime_sec == 0 && entry.mtime_nsec == 0
    if not(is_stale) {
      let abs = root + "/" + entry.path
      let mtime_result : Result[(Int64, Int), Error] = try? @asyncfs.mtime(
        abs,
        follow_symlink=false,
      )
      match mtime_result {
        Ok((sec, nsec)) =>
          if sec.to_int() != entry.mtime_sec || nsec != entry.mtime_nsec {
            is_stale = true
          }
        Err(_) => is_stale = true
      }
      if not(is_stale) && entry.mode != 0o120000 {
        let size_result : Result[Bytes, Error] = try? fs.read_file(abs)
        match size_result {
          Ok(content) => if content.length() != entry.size { is_stale = true }
          Err(_) => ()
        }
      }
    }
    if is_stale {
      stale.push(entry)
    }
  }
  stale
}

///|
fn diff_path_matches_filters(path : String, filters : Array[String]) -> Bool {
  if filters.length() == 0 {
    return true
  }
  filters.iter().any(p => path == p || path.has_prefix(p + "/"))
}

///|
fn format_diff_index_line_from_diff_file(file : @bitdiff.DiffFile) -> String {
  let status = match file.kind {
    @bitdiff.DiffKind::Added => "A"
    @bitdiff.DiffKind::Modified => "M"
    @bitdiff.DiffKind::Deleted => "D"
  }
  let old_mode = diff_index_mode_string(file.old_mode)
  let new_mode = diff_index_mode_string(file.new_mode)
  let old_oid = diff_index_content_oid_string(file.old_content)
  let new_oid = diff_index_content_oid_string(file.new_content)
  ":\{old_mode} \{new_mode} \{old_oid} \{new_oid} \{status}\t\{file.path}"
}

///|
fn format_diff_index_line_from_entry(entry : @bitlib.IndexEntry) -> String {
  let mode = diff_index_mode_string(Some(entry.mode))
  let old_oid = entry.id.to_hex()
  let new_oid = diff_index_zero_oid_hex()
  ":\{mode} \{mode} \{old_oid} \{new_oid} M\t\{entry.path}"
}

///|
fn diff_index_content_oid_string(content : Bytes?) -> String {
  match content {
    Some(bytes) => @bitcore.sha1(bytes).to_hex()
    None => diff_index_zero_oid_hex()
  }
}

///|
fn diff_index_zero_oid_hex() -> String {
  "0000000000000000000000000000000000000000"
}

///|
fn diff_index_mode_string(mode : Int?) -> String {
  match mode {
    Some(value) => {
      let octal = diff_index_to_octal(value)
      if octal.length() >= 6 {
        octal
      } else {
        "0".repeat(6 - octal.length()) + octal
      }
    }
    None => "000000"
  }
}

///|
fn diff_index_to_octal(value : Int) -> String {
  if value == 0 {
    return "0"
  }
  let digits : Array[Char] = []
  let mut v = if value < 0 { -value } else { value }
  while v > 0 {
    let d = v % 8
    digits.push((d + '0'.to_int()).unsafe_to_char())
    v = v / 8
  }
  let rev = digits.rev()
  let sb = StringBuilder::new()
  if value < 0 {
    sb.write_char('-')
  }
  for digit in rev {
    sb.write_char(digit)
  }
  sb.to_string()
}

///|
fn diff_cached_against_ref(
  fs : OsFs,
  rfs : &@bitcore.RepoFileSystem,
  root : String,
  git_dir : String,
  spec : String,
) -> Array[@bitdiff.DiffFile] raise Error {
  ignore(root)
  let target = @bitrepo.rev_parse(rfs, git_dir, spec)
  guard target is Some(target_id) else {
    raise @bitcore.GitError::InvalidObject(
      "unknown revision or path not in the working tree: " + spec,
    )
  }
  let db = @bitlib.ObjectDb::load(rfs, git_dir)
  let old_tree = resolve_diff_tree_id(db, rfs, target_id)
  guard old_tree is Some(old_tree_id) else {
    raise @bitcore.GitError::InvalidObject("object is not a tree-ish: " + spec)
  }
  let index_entries = @bitlib.read_index_entries(rfs, git_dir)
  let index_tree = @bitlib.write_tree_from_index(
    fs, rfs, git_dir, index_entries,
  )
  @bitdiff.diff_trees(rfs, git_dir, Some(old_tree_id), index_tree)
}

///|
fn resolve_diff_tree_id(
  db : @bitlib.ObjectDb,
  rfs : &@bitcore.RepoFileSystem,
  id : @bitcore.ObjectId,
) -> @bitcore.ObjectId? {
  let mut current = id
  for _ in 0..<8 {
    let obj = db.get(rfs, current) catch { _ => return None }
    guard obj is Some(o) else { return None }
    match o.obj_type {
      @bitcore.ObjectType::Tree => return Some(current)
      @bitcore.ObjectType::Commit => {
        let commit = @bitcore.parse_commit(o.data) catch { _ => return None }
        return Some(commit.tree)
      }
      @bitcore.ObjectType::Tag => {
        let parsed = parse_tag_object(decode_bytes(o.data)) catch { _ => None }
        guard parsed is Some(target) else { return None }
        current = target
      }
      _ => return None
    }
  }
  None
}

///|
async fn try_handle_submodule_range_diff(
  fs : OsFs,
  root : String,
  git_dir : String,
  repo_git_dir : String,
  spec : String,
) -> Bool raise Error {
  let rfs : &@bitcore.RepoFileSystem = fs
  let db = @bitlib.ObjectDb::load(rfs, repo_git_dir)
  guard resolve_submodule_diff_range(db, rfs, repo_git_dir, spec)
    is Some((old_commit, new_commit)) else {
    return false
  }
  let old_entries = @bitlib.collect_tree_files_from_commit(db, rfs, old_commit)
  let new_entries = @bitlib.collect_tree_files_from_commit(db, rfs, new_commit)
  let changes : Array[(String, @bitcore.ObjectId, @bitcore.ObjectId)] = []
  for item in new_entries.to_array() {
    let (path, new_entry) = item
    if not(is_gitlink_mode_for_diff(new_entry.mode)) {
      continue
    }
    match old_entries.get(path) {
      Some(old_entry) =>
        if is_gitlink_mode_for_diff(old_entry.mode) &&
          old_entry.id != new_entry.id {
          changes.push((path, old_entry.id, new_entry.id))
        }
      None => ()
    }
  }
  if changes.length() == 0 {
    return false
  }
  let submodules = parse_gitmodules(rfs, root)
  let mut handled = false
  for item in changes {
    let (path, old_id, new_id) = item
    let submodule_name = resolve_submodule_name_for_path(submodules, path)
    let subjects = collect_submodule_diff_subjects(
      fs, root, git_dir, repo_git_dir, path, submodule_name, old_id, new_id,
    )
    if subjects.length() == 0 {
      continue
    }
    print_line("Submodule \{path} \{old_id.to_hex()}..\{new_id.to_hex()}:")
    for subject in subjects {
      print_line("  > \{subject}")
    }
    handled = true
  }
  handled
}

///|
fn resolve_submodule_diff_range(
  db : @bitlib.ObjectDb,
  rfs : &@bitcore.RepoFileSystem,
  git_dir : String,
  spec : String,
) -> (@bitcore.ObjectId, @bitcore.ObjectId)? raise Error {
  if spec.has_suffix("^!") && spec.length() > 2 {
    let target_ref = String::unsafe_substring(
      spec,
      start=0,
      end=spec.length() - 2,
    )
    let end_id = @bitrepo.rev_parse(rfs, git_dir, target_ref)
    guard end_id is Some(new_id) else { return None }
    guard db.get(rfs, new_id) is Some(obj) else { return None }
    if obj.obj_type != @bitcore.ObjectType::Commit {
      return None
    }
    let info = @bitcore.parse_commit(obj.data)
    if info.parents.length() == 0 {
      return None
    }
    return Some((info.parents[0], new_id))
  }
  match spec.find("..") {
    Some(idx) => {
      let start_ref = String::unsafe_substring(spec, start=0, end=idx)
      let end_ref = String::unsafe_substring(
        spec,
        start=idx + 2,
        end=spec.length(),
      )
      if start_ref.length() == 0 {
        return None
      }
      let start_id = @bitrepo.rev_parse(rfs, git_dir, start_ref)
      let end_id = @bitrepo.rev_parse(
        rfs,
        git_dir,
        if end_ref.length() == 0 {
          "HEAD"
        } else {
          end_ref
        },
      )
      guard start_id is Some(old_id) && end_id is Some(new_id) else {
        return None
      }
      Some((old_id, new_id))
    }
    None => None
  }
}

///|
fn resolve_submodule_name_for_path(
  submodules : Array[SubmoduleInfo],
  path : String,
) -> String {
  for sub in submodules {
    if sub.path == path {
      return sub.name
    }
  }
  path
}

///|
fn collect_submodule_diff_subjects(
  fs : OsFs,
  root : String,
  git_dir : String,
  repo_git_dir : String,
  path : String,
  submodule_name : String,
  old_id : @bitcore.ObjectId,
  new_id : @bitcore.ObjectId,
) -> Array[String] raise Error {
  let rfs : &@bitcore.RepoFileSystem = fs
  let candidates = resolve_submodule_git_dir_candidates(
    rfs, root, git_dir, repo_git_dir, path, submodule_name,
  )
  for sub_git_dir in candidates {
    let commits = collect_commits_in_range(rfs, sub_git_dir, old_id, new_id) catch {
      _ => []
    }
    if commits.length() == 0 {
      continue
    }
    let db = @bitlib.ObjectDb::load(rfs, sub_git_dir) catch { _ => continue }
    let subjects : Array[String] = []
    for commit_id in commits {
      match db.get(rfs, commit_id) {
        Some(obj) =>
          if obj.obj_type == @bitcore.ObjectType::Commit {
            let message = extract_commit_message(obj.data)
            let subject = get_first_line(message)
            if subject.length() > 0 {
              subjects.push(subject)
            }
          }
        None => ()
      }
    }
    if subjects.length() > 0 {
      return subjects
    }
  }
  []
}

///|
fn resolve_submodule_git_dir_candidates(
  rfs : &@bitcore.RepoFileSystem,
  root : String,
  git_dir : String,
  repo_git_dir : String,
  path : String,
  submodule_name : String,
) -> Array[String] {
  let candidates : Array[String] = []
  let worktree_git = root + "/" + path + "/.git"
  if rfs.is_file(worktree_git) {
    let resolved = @bitlib.resolve_gitdir(rfs, worktree_git)
    candidates.push(resolved)
  } else if rfs.is_dir(worktree_git) {
    candidates.push(worktree_git)
  }
  let linked_modules = git_dir + "/modules/" + submodule_name
  if rfs.is_dir(linked_modules) && not(candidates.contains(linked_modules)) {
    candidates.push(linked_modules)
  }
  let common_modules = repo_git_dir + "/modules/" + submodule_name
  if rfs.is_dir(common_modules) && not(candidates.contains(common_modules)) {
    candidates.push(common_modules)
  }
  candidates
}

///|

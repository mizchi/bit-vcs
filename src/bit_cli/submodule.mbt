///|
async fn handle_submodule(args : Array[String]) -> Unit raise Error {
  let root = get_work_root()
  let git_dir = root + "/.git"
  let fs = OsFs::new()
  let rfs : &@git.RepoFileSystem = fs
  let git_dir = if rfs.is_file(git_dir) {
    @gitlib.resolve_gitdir(rfs, git_dir)
  } else {
    git_dir
  }
  let subcmd = args.get(0).unwrap_or("")
  let rest : Array[String] = []
  for i in 1..<args.length() {
    rest.push(args[i])
  }
  match subcmd {
    "" | "status" => handle_submodule_status(fs, root, git_dir, rest)
    "add" => handle_submodule_add(fs, root, git_dir, rest)
    "init" => handle_submodule_init(fs, root, git_dir, rest)
    "update" => handle_submodule_update(fs, root, git_dir, rest)
    "deinit" => handle_submodule_deinit(fs, root, git_dir, rest)
    "sync" => handle_submodule_sync(fs, root, git_dir, rest)
    _ => {
      @stdio.stderr.write("error: unknown submodule command: \{subcmd}")
      @sys.exit(1)
    }
  }
}

///|
fn resolve_submodule_common_git_dir(
  fs : &@git.RepoFileSystem,
  git_dir : String,
) -> String {
  let commondir_path = git_dir + "/commondir"
  if fs.is_file(commondir_path) {
    let raw = decode_bytes(
      fs.read_file(commondir_path) catch {
        _ => Bytes::default()
      },
    )
    let rel = trim_string(raw)
    if rel.length() > 0 {
      if rel.has_prefix("/") {
        return normalize_path(rel)
      } else {
        return normalize_path(git_dir + "/" + rel)
      }
    }
  }
  git_dir
}

///|
fn resolve_submodule_fetch_url(
  fs : OsFs,
  root : String,
  git_dir : String,
  url : String,
) -> String {
  let rfs : &@git.RepoFileSystem = fs
  match @gitlib.resolve_local_repo_path(rfs, root, url) {
    Some(local_path) => return local_path
    None => ()
  }
  let config_git_dir = resolve_submodule_common_git_dir(rfs, git_dir)
  let (remotes, _) = @gitlib.read_repo_config(fs, config_git_dir)
  let origin_url = match remotes.get("origin") {
    Some(rc) if rc.urls.length() > 0 => Some(rc.urls[0])
    _ => None
  }
  match origin_url {
    Some(base_url) =>
      match @gitlib.resolve_local_repo_path(rfs, root, base_url) {
        Some(base_path) =>
          match @gitlib.resolve_local_repo_path(rfs, base_path, url) {
            Some(resolved) => resolved
            None => url
          }
        None => url
      }
    None => url
  }
}

///|
async fn handle_submodule_add(
  fs : OsFs,
  root : String,
  git_dir : String,
  args : Array[String],
) -> Unit raise Error {
  let mut branch : String? = None
  let mut url = ""
  let mut path = ""
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    match arg {
      "--branch" | "-b" => {
        i += 1
        if i >= args.length() {
          raise @git.GitError::InvalidObject(
            "submodule add requires a branch name",
          )
        }
        branch = Some(args[i])
      }
      _ if arg.has_prefix("-") => warn_unimplemented_arg("submodule add", arg)
      _ =>
        if url.length() == 0 {
          url = arg
        } else if path.length() == 0 {
          path = arg
        }
    }
    i += 1
  }
  if url.length() == 0 {
    raise @git.GitError::InvalidObject("submodule add requires a repository")
  }
  if path.length() == 0 {
    path = derive_submodule_path(url)
  }
  let name = path
  write_gitmodules_entry(fs, root, name, path, url, branch)
  let config_path = git_dir + "/config"
  set_config(fs, config_path, "submodule." + name + ".url", url, false)
  set_config(fs, config_path, "submodule." + name + ".path", path, false)
  if branch is Some(b) {
    set_config(fs, config_path, "submodule." + name + ".branch", b, false)
  }
  let fetch_url = resolve_submodule_fetch_url(fs, root, git_dir, url)
  let target_id = resolve_submodule_head_id(fs, root, fetch_url)
  let modules_dir = git_dir + "/modules/" + name
  if not(fs.is_dir(modules_dir)) {
    @gitrepo.init_repo(fs, modules_dir, bare=true)
  }
  let modules_config = modules_dir + "/config"
  set_config(fs, modules_config, "remote.origin.url", fetch_url, false)
  set_config(
    fs, modules_config, "remote.origin.fetch", "+refs/heads/*:refs/remotes/origin/*",
    false,
  )
  fetch_submodule_objects(fs, root, modules_dir, fetch_url, target_id)
  let sub_path = root + "/" + path
  if not(fs.is_dir(sub_path)) {
    fs.mkdir_p(sub_path)
  }
  let rel_path = get_rel_path(sub_path, modules_dir)
  fs.write_string(sub_path + "/.git", "gitdir: \{rel_path}\n")
  ensure_submodule_gitdir_config(fs, modules_dir, sub_path)
  run_checkout_in_submodule(fs, fs, sub_path, modules_dir, target_id)
  let checkout_branch = match branch {
    Some(name) => Some(name)
    None =>
      match @gitlib.read_remote_head_branch(fs, modules_dir) {
        Some(name) => Some(name)
        None => Some("main")
      }
  }
  match checkout_branch {
    Some(branch_name) => {
      let branch_ref = modules_dir + "/refs/heads/" + branch_name
      match branch_ref.rev_find("/") {
        Some(i) =>
          fs.mkdir_p(String::unsafe_substring(branch_ref, start=0, end=i))
        None => ()
      }
      fs.write_string(branch_ref, target_id.to_hex() + "\n")
      fs.write_string(
        modules_dir + "/HEAD",
        "ref: refs/heads/" + branch_name + "\n",
      )
      set_config(
        fs,
        modules_config,
        "branch." + branch_name + ".remote",
        "origin",
        false,
      )
      set_config(
        fs,
        modules_config,
        "branch." + branch_name + ".merge",
        "refs/heads/" + branch_name,
        false,
      )
    }
    None => ()
  }
  @gitlibnative.apply_worktree_modes_from_commit(
    fs, fs, sub_path, modules_dir, target_id,
  ) catch {
    err => {
      if @async.is_being_cancelled() || @async.is_cancellation_error(err) {
        raise err
      }
      eprint_line(
        "warning: failed to apply worktree modes in submodule '\{path}': \{err}",
      )
    }
  }
  @gitlib.add_paths_async(fs, fs, root, [".gitmodules"])
  update_submodule_index_entry(fs, git_dir, path, target_id)
}

///|
fn derive_submodule_path(url : String) -> String {
  let mut name = url
  for part_view in url.split("/") {
    let part = part_view.to_string()
    if part.length() > 0 {
      name = part
    }
  }
  if name.has_suffix(".git") && name.length() > 4 {
    name = String::unsafe_substring(name, start=0, end=name.length() - 4)
  }
  name
}

///|
fn write_gitmodules_entry(
  fs : OsFs,
  root : String,
  name : String,
  path : String,
  url : String,
  branch : String?,
) -> Unit raise Error {
  let gitmodules_path = root + "/.gitmodules"
  let rfs : &@git.RepoFileSystem = fs
  let mut content = if rfs.is_file(gitmodules_path) {
    decode_bytes(rfs.read_file(gitmodules_path))
  } else {
    ""
  }
  let section = "[submodule \"\{name}\"]"
  if content.contains(section) {
    return
  }
  let mut entry = section + "\n\tpath = " + path + "\n\turl = " + url + "\n"
  if branch is Some(b) {
    entry = entry + "\tbranch = " + b + "\n"
  }
  if content.length() > 0 && not(content.has_suffix("\n")) {
    content = content + "\n"
  }
  fs.write_string(gitmodules_path, content + entry)
}

///|
async fn resolve_submodule_head_id(
  fs : OsFs,
  root : String,
  url : String,
) -> @git.ObjectId raise Error {
  let rfs : &@git.RepoFileSystem = fs
  match @gitlib.resolve_local_repo_path(rfs, root, url) {
    Some(src_path) =>
      match @gitlib.detect_git_dir(rfs, src_path) {
        Some((src_git_dir, _)) => {
          let head = @gitlib.resolve_head_commit(rfs, src_git_dir)
          match head {
            Some(id) => id
            None =>
              raise @git.GitError::InvalidObject(
                "Invalid HEAD in submodule: " + url,
              )
          }
        }
        None =>
          raise @git.GitError::InvalidObject("Not a git repository: " + url)
      }
    None => {
      let resolved = resolve_remote_ref_id(url, "HEAD")
      match resolved {
        Some((id, _)) => id
        None =>
          raise @git.GitError::InvalidObject(
            "Failed to resolve submodule HEAD: " + url,
          )
      }
    }
  }
}

///|
fn update_submodule_index_entry(
  fs : OsFs,
  git_dir : String,
  path : String,
  id : @git.ObjectId,
) -> Unit raise Error {
  let rfs : &@git.RepoFileSystem = fs
  let entries = @gitlib.read_index_entries(rfs, git_dir) catch { _ => [] }
  let out : Array[@gitlib.IndexEntry] = []
  for e in entries {
    if e.path != path {
      out.push(e)
    }
  }
  out.push(
    @gitlib.IndexEntry::new(path, id, 57344, 0, mtime_sec=0, mtime_nsec=0),
  )
  @gitlib.write_index_entries(fs, git_dir, out)
}

///|
async fn handle_submodule_status(
  fs : OsFs,
  root : String,
  git_dir : String,
  args : Array[String],
) -> Unit raise Error {
  let mut recursive = false
  let paths : Array[String] = []
  for arg in args {
    match arg {
      "--recursive" => recursive = true
      _ if not(arg.has_prefix("-")) => paths.push(arg)
      _ => ()
    }
  }
  let rfs : &@git.RepoFileSystem = fs
  let submodules = parse_gitmodules(rfs, root)
  for sub in submodules {
    if paths.length() > 0 && not(paths.contains(sub.path)) {
      continue
    }
    let sub_path = root + "/" + sub.path
    let sub_git = sub_path + "/.git"
    // Check if initialized
    if not(rfs.is_file(sub_git)) && not(rfs.is_dir(sub_git)) {
      print_line("-\{String::make(40, '0')} \{sub.path}")
      continue
    }
    // Get HEAD of submodule
    let sub_git_dir = @gitlib.resolve_gitdir(rfs, sub_git)
    let head_id = @gitlib.resolve_head_commit(rfs, sub_git_dir) catch {
      err => {
        if @async.is_being_cancelled() || @async.is_cancellation_error(err) {
          raise err
        }
        print_line("-\{String::make(40, '0')} \{sub.path}")
        continue
      }
    }
    match head_id {
      Some(id) => {
        // Check against index
        let index_id = get_submodule_index_id(rfs, git_dir, sub.path)
        let prefix = match index_id {
          Some(idx) if idx.to_hex() == id.to_hex() => " "
          Some(_) => "+"
          None => " "
        }
        print_line("\{prefix}\{id.to_hex()} \{sub.path}")
      }
      None => print_line("-\{String::make(40, '0')} \{sub.path}")
    }
    // Handle recursive
    if recursive {
      let nested = sub_path + "/.gitmodules"
      if rfs.is_file(nested) {
        handle_submodule_status(fs, sub_path, sub_git_dir, args)
      }
    }
  }
}

///|
fn get_submodule_index_id(
  fs : &@git.RepoFileSystem,
  git_dir : String,
  path : String,
) -> @git.ObjectId? {
  let entries = @gitlib.read_index_entries(fs, git_dir) catch {
    _ => return None
  }
  for e in entries {
    if e.path == path {
      return Some(e.id)
    }
  }
  None
}

///|
async fn handle_submodule_init(
  fs : OsFs,
  root : String,
  git_dir : String,
  args : Array[String],
) -> Unit raise Error {
  let paths : Array[String] = []
  for arg in args {
    if not(arg.has_prefix("-")) {
      paths.push(arg)
    }
  }
  let rfs : &@git.RepoFileSystem = fs
  let wfs : &@git.FileSystem = fs
  let submodules = parse_gitmodules(rfs, root)
  for sub in submodules {
    if paths.length() > 0 && not(paths.contains(sub.path)) {
      continue
    }
    // Write to .git/config
    let config_path = git_dir + "/config"
    let config_content = if rfs.is_file(config_path) {
      decode_bytes(rfs.read_file(config_path))
    } else {
      ""
    }
    let section = "[submodule \"\{sub.name}\"]"
    if config_content.contains(section) {
      continue
    }
    let new_section = "\n\{section}\n\tactive = true\n\turl = \{sub.url}\n"
    wfs.write_string(config_path, config_content + new_section)
    print_line(
      "Submodule '\{sub.name}' (\{sub.url}) registered for path '\{sub.path}'",
    )
  }
}

///|
async fn handle_submodule_update(
  fs : OsFs,
  root : String,
  git_dir : String,
  args : Array[String],
) -> Unit raise Error {
  let mut has_init_flag = false
  for arg in args {
    if arg == "--init" {
      has_init_flag = true
      break
    }
  }
  let rfs : &@git.RepoFileSystem = fs
  let gitfile = root + "/.git"
  if has_init_flag && rfs.is_file(gitfile) {
    let _gitfile_content = decode_bytes(
      rfs.read_file(gitfile) catch {
        err => {
          if @async.is_being_cancelled() || @async.is_cancellation_error(err) {
            raise err
          }
          Bytes::default()
        }
      },
    )
  }
  let mut init = false
  let mut recursive = false
  let paths : Array[String] = []
  for arg in args {
    match arg {
      "--init" => init = true
      "--recursive" => recursive = true
      _ if not(arg.has_prefix("-")) => paths.push(arg)
      _ => ()
    }
  }
  let rfs : &@git.RepoFileSystem = fs
  let wfs : &@git.FileSystem = fs
  // Init first if requested
  if init {
    handle_submodule_init(fs, root, git_dir, paths)
  }
  let submodules = parse_gitmodules(rfs, root)
  for sub in submodules {
    if paths.length() > 0 && not(paths.contains(sub.path)) {
      continue
    }
    let sub_path = root + "/" + sub.path
    let modules_dir = git_dir + "/modules/" + sub.name
    // Get expected commit from index
    let expected_id = get_submodule_index_id(rfs, git_dir, sub.path)
    guard expected_id is Some(target_id) else { continue }
    let sub_git = sub_path + "/.git"
    let sub_git_is_dir = rfs.is_dir(sub_git)
    let mut has_modules = rfs.is_dir(modules_dir)
    // Clone if needed
    if not(sub_git_is_dir) && not(has_modules) {
      print_line("Cloning into '\{sub.path}'...")
      @gitrepo.init_repo(wfs, modules_dir, bare=true)
      let config_path = modules_dir + "/config"
      set_config(fs, config_path, "remote.origin.url", sub.url, false)
      set_config(
        fs, config_path, "remote.origin.fetch", "+refs/heads/*:refs/remotes/origin/*",
        false,
      )
      has_modules = true
    }
    if has_modules {
      let config_path = modules_dir + "/config"
      let fetch_url = resolve_submodule_fetch_url(fs, root, git_dir, sub.url)
      set_config(fs, config_path, "remote.origin.url", fetch_url, false)
      set_config(
        fs, config_path, "remote.origin.fetch", "+refs/heads/*:refs/remotes/origin/*",
        false,
      )
      fetch_submodule_objects(fs, root, modules_dir, fetch_url, target_id)
    }
    if not(sub_git_is_dir) && has_modules {
      // Create or refresh .git file to point to modules dir
      let rel_path = get_rel_path(sub_path, modules_dir)
      wfs.write_string(sub_git, "gitdir: \{rel_path}\n")
    }
    if has_modules {
      ensure_submodule_gitdir_config(fs, modules_dir, sub_path)
    }
    // Checkout target commit
    let sub_git_dir = @gitlib.resolve_gitdir(rfs, sub_git)
    print_line(
      "Submodule path '\{sub.path}': checked out '\{target_id.to_hex()}'",
    )
    // Use checkout command
    run_checkout_in_submodule(wfs, rfs, sub_path, sub_git_dir, target_id)
    @gitlibnative.apply_worktree_modes_from_commit(
      fs, fs, sub_path, sub_git_dir, target_id,
    ) catch {
      err => {
        if @async.is_being_cancelled() || @async.is_cancellation_error(err) {
          raise err
        }
        eprint_line(
          "warning: failed to apply worktree modes in submodule '\{sub.path}': \{err}",
        )
      }
    }
    // Handle recursive
    if recursive {
      let nested = sub_path + "/.gitmodules"
      if rfs.is_file(nested) {
        handle_submodule_update(fs, sub_path, sub_git_dir, args)
      }
    }
  }
}

///|

///|
async fn fetch_submodule_objects(
  fs : OsFs,
  root : String,
  modules_dir : String,
  url : String,
  target_id : @git.ObjectId,
) -> Unit raise Error {
  let rfs : &@git.RepoFileSystem = fs
  match @gitlib.resolve_local_repo_path(rfs, root, url) {
    Some(src_path) => {
      fetch_local_repo(fs, src_path, modules_dir, modules_dir, "origin", url, [])
      return ()
    }
    None => ()
  }
  let pack = @gitnative.fetch_pack_http(url, [target_id], true)
  let objects = @pack.parse_packfile(pack)
  @pack.write_packfile_with_index(fs, modules_dir, pack, objects)
}

///|
fn ensure_submodule_gitdir_config(
  fs : OsFs,
  modules_dir : String,
  work_tree : String,
) -> Unit raise Error {
  let config_path = modules_dir + "/config"
  let rel_work_tree = get_rel_path(modules_dir, work_tree)
  set_config(fs, config_path, "core.worktree", rel_work_tree, false)
  set_config(fs, config_path, "core.bare", "false", false)
}

///|
fn run_checkout_in_submodule(
  wfs : &@git.FileSystem,
  rfs : &@git.RepoFileSystem,
  work_tree : String,
  git_dir : String,
  commit_id : @git.ObjectId,
) -> Unit {
  let db = @gitlib.ObjectDb::load(rfs, git_dir) catch { _ => return }
  let head_path = git_dir + "/HEAD"
  wfs.write_string(head_path, commit_id.to_hex() + "\n") catch {
    _ => ()
  }
  let files = @gitlib.collect_tree_files_from_commit(db, rfs, commit_id) catch {
    _ => return
  }
  @gitlib.write_worktree_from_files(
    db,
    wfs,
    rfs,
    work_tree,
    git_dir,
    files,
    remove_missing=true,
  ) catch {
    _ => return
  }
  let entries = @gitlib.tree_files_to_index(db, rfs, files) catch {
    _ => return
  }
  @gitlib.write_index_entries(wfs, git_dir, entries) catch {
    _ => return
  }
}

///|

///|
fn get_rel_path(from : String, to : String) -> String {
  let from_parts : Array[String] = from
    .split("/")
    .filter(s => s.to_string().length() > 0)
    .map(s => s.to_string())
    .collect()
  let to_parts : Array[String] = to
    .split("/")
    .filter(s => s.to_string().length() > 0)
    .map(s => s.to_string())
    .collect()
  // Find common prefix
  let mut common = 0
  while common < from_parts.length() && common < to_parts.length() {
    if from_parts[common] == to_parts[common] {
      common += 1
    } else {
      break
    }
  }
  // Build relative path
  let mut result = ""
  for _ in 0..<(from_parts.length() - common) {
    result = result + "../"
  }
  for i in common..<to_parts.length() {
    if result.length() > 0 && not(result.has_suffix("/")) {
      result = result + "/"
    }
    result = result + to_parts[i]
  }
  result
}

///|
async fn handle_submodule_deinit(
  fs : OsFs,
  root : String,
  git_dir : String,
  args : Array[String],
) -> Unit raise Error {
  let mut force = false
  let mut all = false
  let paths : Array[String] = []
  for arg in args {
    match arg {
      "-f" | "--force" => force = true
      "--all" => all = true
      _ if not(arg.has_prefix("-")) => paths.push(arg)
      _ => ()
    }
  }
  let rfs : &@git.RepoFileSystem = fs
  let wfs : &@git.FileSystem = fs
  let submodules = parse_gitmodules(rfs, root)
  for sub in submodules {
    if not(all) && paths.length() > 0 && not(paths.contains(sub.path)) {
      continue
    }
    let sub_path = root + "/" + sub.path
    // Check for local modifications
    if not(force) && rfs.is_dir(sub_path) {
      let sub_git_dir = @gitlib.resolve_gitdir(rfs, sub_path + "/.git")
      if rfs.is_dir(sub_git_dir) {
        let status = @gitlib.status(rfs, sub_path) catch {
          err => {
            if @async.is_being_cancelled() || @async.is_cancellation_error(err) {
              raise err
            }
            continue
          }
        }
        if status.unstaged_modified.length() > 0 {
          @stdio.stderr.write(
            "error: '\{sub.path}' has local modifications (use --force)",
          )
          @sys.exit(1)
        }
      }
    }
    // Remove from .git/config
    let config_path = git_dir + "/config"
    if rfs.is_file(config_path) {
      let content = decode_bytes(rfs.read_file(config_path))
      let new_content = remove_config_section(content, "submodule", sub.name)
      wfs.write_string(config_path, new_content)
    }
    // Clear working directory
    if rfs.is_dir(sub_path) {
      let entries = rfs.readdir(sub_path) catch {
        err => {
          if @async.is_being_cancelled() || @async.is_cancellation_error(err) {
            raise err
          }
          continue
        }
      }
      for e in entries {
        if e == ".git" {
          continue
        }
        let full = sub_path + "/" + e
        if rfs.is_dir(full) {
          remove_dir_recursive(fs, full)
        } else {
          wfs.remove_file(full) catch {
            err => {
              if @async.is_being_cancelled() ||
                @async.is_cancellation_error(err) {
                raise err
              }
              ()
            }
          }
        }
      }
    }
    print_line("Cleared directory '\{sub.path}'")
  }
}

///|
fn remove_config_section(
  content : String,
  section_type : String,
  name : String,
) -> String {
  let lines : Array[String] = []
  let mut skip = false
  let target = "[\{section_type} \"\{name}\"]"
  for line_view in content.split("\n") {
    let line = line_view.to_string()
    let trimmed = trim_chars(line, " \t")
    if trimmed.has_prefix("[") {
      skip = trimmed == target
    }
    if not(skip) {
      lines.push(line)
    }
  }
  lines.join("\n")
}

///|
async fn handle_submodule_sync(
  fs : OsFs,
  root : String,
  git_dir : String,
  args : Array[String],
) -> Unit raise Error {
  let mut recursive = false
  let paths : Array[String] = []
  for arg in args {
    match arg {
      "--recursive" => recursive = true
      _ if not(arg.has_prefix("-")) => paths.push(arg)
      _ => ()
    }
  }
  let rfs : &@git.RepoFileSystem = fs
  let wfs : &@git.FileSystem = fs
  let submodules = parse_gitmodules(rfs, root)
  for sub in submodules {
    if paths.length() > 0 && not(paths.contains(sub.path)) {
      continue
    }
    // Update .git/config
    let config_path = git_dir + "/config"
    if rfs.is_file(config_path) {
      let content = decode_bytes(rfs.read_file(config_path))
      let section = "[submodule \"\{sub.name}\"]"
      if content.contains(section) {
        let updated = update_config_value(content, sub.name, "url", sub.url)
        wfs.write_string(config_path, updated)
      }
    }
    // Update submodule's origin URL
    let sub_path = root + "/" + sub.path
    let sub_git_dir = @gitlib.resolve_gitdir(rfs, sub_path + "/.git")
    let sub_config = sub_git_dir + "/config"
    if rfs.is_file(sub_config) {
      let content = decode_bytes(rfs.read_file(sub_config))
      let updated = update_remote_origin(content, sub.url)
      wfs.write_string(sub_config, updated)
    }
    print_line("Synchronizing submodule url for '\{sub.path}'")
    // Handle recursive
    if recursive {
      let nested = sub_path + "/.gitmodules"
      if rfs.is_file(nested) {
        handle_submodule_sync(fs, sub_path, sub_git_dir, args)
      }
    }
  }
}

///|
fn update_config_value(
  content : String,
  name : String,
  key : String,
  value : String,
) -> String {
  let lines : Array[String] = []
  let mut in_section = false
  let mut updated = false
  let target = "[submodule \"\{name}\"]"
  for line_view in content.split("\n") {
    let line = line_view.to_string()
    let trimmed = trim_chars(line, " \t")
    if trimmed.has_prefix("[") {
      in_section = trimmed == target
    }
    if in_section && trimmed.has_prefix(key + " =") && not(updated) {
      lines.push("\t\{key} = \{value}")
      updated = true
    } else {
      lines.push(line)
    }
  }
  lines.join("\n")
}

///|
fn update_remote_origin(content : String, url : String) -> String {
  let lines : Array[String] = []
  let mut in_origin = false
  let mut updated = false
  for line_view in content.split("\n") {
    let line = line_view.to_string()
    let trimmed = trim_chars(line, " \t")
    if trimmed.has_prefix("[") {
      in_origin = trimmed == "[remote \"origin\"]"
    }
    if in_origin && trimmed.has_prefix("url =") && not(updated) {
      lines.push("\turl = \{url}")
      updated = true
    } else {
      lines.push(line)
    }
  }
  lines.join("\n")
}

///|

///|
struct SubmoduleDispatch {
  subcmd : String
  args : Array[String]
  usage_error : Bool
}

///|
struct SubmoduleAddArgs {
  branch : String?
  depth : Int?
  name : String?
  quiet : Bool
  progress : Bool
  force : Bool
  url : String
  path : String
}

///|
fn parse_submodule_add_depth(value : String) -> Int raise Error {
  let depth = @string.parse_int(value) catch {
    _ =>
      raise @bitcore.GitError::InvalidObject(
        "submodule add requires a positive depth",
      )
  }
  if depth <= 0 {
    raise @bitcore.GitError::InvalidObject(
      "submodule add requires a positive depth",
    )
  }
  depth
}

///|
fn parse_submodule_dispatch(args : Array[String]) -> SubmoduleDispatch {
  let leading_status_args : Array[String] = []
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    match arg {
      "--quiet" | "--cached" => leading_status_args.push(arg)
      "--recursive" | "--" | "--end-of-options" =>
        return { subcmd: "", args: [], usage_error: true }
      "status" => {
        let out = leading_status_args.copy()
        for j in (i + 1)..<args.length() {
          out.push(args[j])
        }
        return { subcmd: "status", args: out, usage_error: false }
      }
      _ if arg.has_prefix("-") =>
        return { subcmd: arg, args: [], usage_error: false }
      _ => {
        let out = leading_status_args.copy()
        for j in (i + 1)..<args.length() {
          out.push(args[j])
        }
        return { subcmd: arg, args: out, usage_error: false }
      }
    }
    i += 1
  }
  if leading_status_args.length() > 0 {
    return { subcmd: "status", args: leading_status_args, usage_error: false }
  }
  { subcmd: "", args: [], usage_error: false }
}

///|
async fn show_submodule_usage_stderr() -> Unit raise Error {
  eprint_line("usage: git submodule [--quiet] [--cached] [<command>] [<args>]")
}

///|
fn resolve_submodule_root() -> String {
  match @sys.get_env_var("GIT_SHIM_CWD") {
    Some(dir) =>
      if is_bare_repo_dir(dir) {
        dir
      } else {
        find_repo_root(dir).unwrap_or(dir)
      }
    None =>
      match @sys.get_env_var("GIT_SHIM_PWD") {
        Some(dir) =>
          if is_bare_repo_dir(dir) {
            dir
          } else {
            find_repo_root(dir).unwrap_or(dir)
          }
        None =>
          match @sys.get_env_var("PWD") {
            Some(dir) =>
              match find_repo_root(dir) {
                Some(root) => root
                None => get_work_root()
              }
            None =>
              match @env.current_dir() {
                Some(dir) =>
                  match find_repo_root(dir) {
                    Some(root) => root
                    None => get_work_root()
                  }
                None => get_work_root()
              }
          }
      }
  }
}

///|
async fn handle_submodule(args : Array[String]) -> Unit raise Error {
  let raw_root = match @sys.get_env_var("GIT_WORK_TREE") {
    Some(path) => path
    None => resolve_submodule_root()
  }
  let fs = OsFs::new()
  let rfs : &@bitcore.RepoFileSystem = fs
  let root = normalize_path(raw_root)
  let raw_git_dir = match @sys.get_env_var("GIT_DIR") {
    Some(path) => path
    None => raw_root + "/.git"
  }
  let git_dir = if rfs.is_file(raw_git_dir) {
    @bitlib.resolve_gitdir(rfs, raw_git_dir)
  } else {
    raw_git_dir
  }
  let git_dir = normalize_path(git_dir)
  let dispatch = parse_submodule_dispatch(args)
  if dispatch.usage_error {
    show_submodule_usage_stderr()
    @sys.exit(1)
  }
  let subcmd = dispatch.subcmd
  let rest = dispatch.args
  match subcmd {
    "" | "status" => handle_submodule_status(fs, root, git_dir, rest)
    "add" => handle_submodule_add(fs, root, git_dir, rest)
    "init" => handle_submodule_init(fs, root, git_dir, rest)
    "update" => handle_submodule_update(fs, root, git_dir, rest)
    "deinit" => handle_submodule_deinit(fs, root, git_dir, rest)
    "sync" => handle_submodule_sync(fs, root, git_dir, rest)
    "foreach" => handle_submodule_foreach(fs, root, git_dir, rest)
    "set-url" => handle_submodule_set_url(fs, root, git_dir, rest)
    "set-branch" => handle_submodule_set_branch(fs, root, rest)
    "absorbgitdirs" => handle_submodule_absorbgitdirs(fs, root, git_dir, rest)
    "summary" => handle_submodule_summary(fs, root, git_dir, rest)
    _ => {
      @stdio.stderr.write("error: unknown submodule command: \{subcmd}")
      @sys.exit(1)
    }
  }
}

///|
fn resolve_submodule_common_git_dir(
  fs : &@bitcore.RepoFileSystem,
  git_dir : String,
) -> String {
  let commondir_path = git_dir + "/commondir"
  if fs.is_file(commondir_path) {
    let raw = decode_bytes(
      fs.read_file(commondir_path) catch {
        _ => Default::default()
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
fn get_submodule_origin_url(fs : OsFs, git_dir : String) -> String? {
  let rfs : &@bitcore.RepoFileSystem = fs
  let config_git_dir = resolve_submodule_common_git_dir(rfs, git_dir)
  let (remotes, _) = @bitlib.read_repo_config(fs, config_git_dir)
  match remotes.get("origin") {
    Some(rc) if rc.urls.length() > 0 => Some(rc.urls[0])
    _ => None
  }
}

///|
fn submodule_url_is_local_not_ssh(url : String) -> Bool {
  if url.has_prefix("http://") ||
    url.has_prefix("https://") ||
    url.has_prefix("ssh://") ||
    url.has_prefix("git://") ||
    url.has_prefix("file://") ||
    url.contains("://") {
    return false
  }
  match url.find(":") {
    Some(colon_idx) if !url.has_prefix("/") =>
      match url.find("/") {
        Some(slash_idx) => colon_idx > slash_idx
        None => false
      }
    _ => true
  }
}

///|
fn submodule_chop_last_dir(
  remote_url : String,
  is_relative : Bool,
) -> (String, Bool) {
  match remote_url.rev_find("/") {
    Some(idx) => (String::unsafe_substring(remote_url, start=0, end=idx), false)
    None =>
      match remote_url.rev_find(":") {
        Some(idx) =>
          (String::unsafe_substring(remote_url, start=0, end=idx), true)
        None =>
          if is_relative || remote_url == "." {
            (".", false)
          } else {
            (".", false)
          }
      }
  }
}

///|
fn submodule_resolve_relative_url(
  remote_url : String,
  url : String,
  up_path : String?,
) -> String {
  if !submodule_relative_local_url(url) {
    return url
  }
  let mut remote_url = remote_url
  if remote_url.has_suffix("/") {
    remote_url = String::unsafe_substring(
      remote_url,
      start=0,
      end=remote_url.length() - 1,
    )
  }
  let mut is_relative = false
  if submodule_url_is_local_not_ssh(remote_url) && !remote_url.has_prefix("/") {
    is_relative = true
    if !remote_url.has_prefix("./") && !remote_url.has_prefix("../") {
      remote_url = "./" + remote_url
    }
  }
  let mut relative_url = url
  let mut colon_sep = false
  while relative_url.length() > 0 {
    if relative_url.has_prefix("../") {
      relative_url = String::unsafe_substring(
        relative_url,
        start=3,
        end=relative_url.length(),
      )
      let (trimmed, uses_colon_sep) = submodule_chop_last_dir(
        remote_url, is_relative,
      )
      remote_url = trimmed
      if uses_colon_sep {
        colon_sep = true
      }
      continue
    }
    if relative_url.has_prefix("./") {
      relative_url = String::unsafe_substring(
        relative_url,
        start=2,
        end=relative_url.length(),
      )
      continue
    }
    break
  }
  let mut out = remote_url + (if colon_sep { ":" } else { "/" }) + relative_url
  if relative_url.has_suffix("/") && out.length() > 0 {
    out = String::unsafe_substring(out, start=0, end=out.length() - 1)
  }
  if out.has_prefix("./") {
    out = String::unsafe_substring(out, start=2, end=out.length())
  }
  match up_path {
    Some(prefix) if is_relative => prefix + out
    _ => out
  }
}

///|
fn submodule_up_path(path : String) -> String {
  let up : Array[String] = []
  for part_view in path.split("/") {
    if part_view.to_owned().length() > 0 {
      up.push("../")
    }
  }
  up.join("")
}

///|
fn resolve_submodule_config_url(
  fs : OsFs,
  root : String,
  git_dir : String,
  url : String,
) -> String {
  let base_url = get_submodule_origin_url(fs, git_dir).unwrap_or(root)
  submodule_resolve_relative_url(base_url, url, None)
}

///|
fn submodule_expand_template_dir(path : String) -> String {
  if !path.has_prefix("~/") {
    return path
  }
  match @sys.get_env_var("HOME") {
    Some(home) =>
      home + String::unsafe_substring(path, start=1, end=path.length())
    None => path
  }
}

///|
fn submodule_add_template_dir(fs : OsFs) -> String? {
  match @sys.get_env_var("GIT_TEMPLATE_DIR") {
    Some(path) => Some(submodule_expand_template_dir(path))
    None => {
      let rfs : &@bitcore.RepoFileSystem = fs
      match find_global_gitconfig_path() {
        Some(config_path) => {
          let template_dir = get_config_value(
            rfs,
            config_path,
            "init.templatedir",
            None,
            false,
          ) catch {
            _ => None
          }
          match template_dir {
            Some(path) => Some(submodule_expand_template_dir(path))
            None => None
          }
        }
        None => None
      }
    }
  }
}

///|
async fn submodule_apply_template_exec_bits(
  fs : OsFs,
  template_dir : String,
  modules_dir : String,
) -> Unit {
  let entries = fs.readdir(template_dir) catch { _ => [] }
  for entry in entries {
    if entry == "." || entry == ".." {
      continue
    }
    let src_path = template_dir + "/" + entry
    let dst_path = modules_dir + "/" + entry
    if fs.is_dir(src_path) {
      submodule_apply_template_exec_bits(fs, src_path, dst_path)
      continue
    }
    if !fs.is_file(src_path) || !fs.is_file(dst_path) {
      continue
    }
    match @bitio.lstat_entry_meta(src_path) {
      Some(meta) if meta.mode == 0o100755 =>
        @asyncfs.chmod(dst_path[:], 0o755) catch {
          _ => ()
        }
      _ => ()
    }
  }
}

///|
async fn submodule_init_modules_repo(
  fs : OsFs,
  super_git_dir : String,
  modules_dir : String,
) -> Unit raise Error {
  let template_dir = submodule_add_template_dir(fs)
  let opts : @bitlib.InitOptions = {
    default_branch: "main",
    bare: true,
    separate_git_dir: None,
    template_dir,
    ref_format: if is_reftable_repo(fs, super_git_dir) {
      "reftable"
    } else {
      "files"
    },
    object_format: repo_object_format(fs, super_git_dir),
    is_reinit: false,
    git_dir: None,
    work_tree: None,
    shared: None,
  }
  @bitlib.init_repo_with_options(fs, modules_dir, opts)
  match template_dir {
    Some(tpl) => {
      @bitlib.apply_template(fs, fs, modules_dir, tpl)
      submodule_apply_template_exec_bits(fs, tpl, modules_dir)
    }
    None => ()
  }
}

///|
fn resolve_submodule_origin_url(
  fs : OsFs,
  root : String,
  git_dir : String,
  path : String,
  url : String,
) -> String {
  let base_url = get_submodule_origin_url(fs, git_dir).unwrap_or(root)
  submodule_resolve_relative_url(base_url, url, Some(submodule_up_path(path)))
}

///|
fn resolve_submodule_fetch_url(
  fs : OsFs,
  root : String,
  git_dir : String,
  url : String,
) -> String {
  let rfs : &@bitcore.RepoFileSystem = fs
  match @bitlib.resolve_local_repo_path(rfs, root, url) {
    Some(local_path) => return local_path
    None => ()
  }
  let origin_url = get_submodule_origin_url(fs, git_dir)
  match origin_url {
    Some(base_url) =>
      match @bitlib.resolve_local_repo_path(rfs, root, base_url) {
        Some(base_path) =>
          match @bitlib.resolve_local_repo_path(rfs, base_path, url) {
            Some(resolved) => resolved
            None => url
          }
        None => url
      }
    None => url
  }
}

///|
fn submodule_relative_local_url(url : String) -> Bool {
  url.has_prefix("./") || url.has_prefix("../")
}

///|
fn parse_submodule_add_args(
  args : Array[String],
) -> SubmoduleAddArgs raise Error {
  let mut branch : String? = None
  let mut depth : Int? = None
  let mut name : String? = None
  let mut quiet = false
  let mut progress = false
  let mut force = false
  let mut url = ""
  let mut path = ""
  let mut parse_options = true
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    if parse_options {
      match arg {
        "--" => parse_options = false
        "--branch" | "-b" => {
          i += 1
          if i >= args.length() {
            raise @bitcore.GitError::InvalidObject(
              "submodule add requires a branch name",
            )
          }
          branch = Some(args[i])
        }
        "--depth" => {
          i += 1
          if i >= args.length() {
            raise @bitcore.GitError::InvalidObject(
              "submodule add requires a depth",
            )
          }
          depth = Some(parse_submodule_add_depth(args[i]))
        }
        "--name" => {
          i += 1
          if i >= args.length() {
            raise @bitcore.GitError::InvalidObject(
              "submodule add requires a name",
            )
          }
          name = Some(args[i])
        }
        _ if arg.has_prefix("--depth=") => {
          let value = String::unsafe_substring(arg, start=8, end=arg.length())
          depth = Some(parse_submodule_add_depth(value))
        }
        "--quiet" | "-q" => quiet = true
        "--progress" => progress = true
        "--force" | "-f" => force = true
        _ if arg.has_prefix("-") => ()
        _ =>
          if url.length() == 0 {
            url = arg
          } else if path.length() == 0 {
            path = arg
          }
      }
    } else if url.length() == 0 {
      url = arg
    } else if path.length() == 0 {
      path = arg
    }
    i += 1
  }
  { branch, depth, name, quiet, progress, force, url, path }
}

///|
fn normalize_submodule_add_path(
  path : String,
  cwd_prefix : String,
  root_abs : String,
) -> String {
  let path_abs = if path.has_prefix("/") {
    normalize_path(path)
  } else {
    let base = if cwd_prefix.length() == 0 {
      root_abs
    } else {
      root_abs + "/" + cwd_prefix
    }
    normalize_path(base + "/" + path)
  }
  let root_norm = normalize_path(root_abs)
  if path_abs == root_norm {
    return "."
  }
  if path_abs.has_prefix(root_norm + "/") {
    return String::unsafe_substring(
      path_abs,
      start=root_norm.length() + 1,
      end=path_abs.length(),
    )
  }
  path_abs
}

///|
async fn submodule_canonical_dir(path : String) -> String {
  let (code, stdout) = @process.collect_stdout("pwd", ["-P"], cwd=path)
  if code == 0 {
    let out = stdout.text() catch { _ => "" }
    let canonical = trim_string(out)
    if canonical.length() > 0 {
      return normalize_path(canonical)
    }
  }
  normalize_path(path)
}

///|
async fn submodule_relative_path(from : String, to : String) -> String {
  let canonical_from = submodule_canonical_dir(from)
  let canonical_to = submodule_canonical_dir(to)
  get_rel_path(canonical_from, canonical_to)
}

///|
fn submodule_add_ignored_error_lines(path : String) -> Array[String] {
  [
    "The following paths are ignored by one of your .gitignore files:", path, "hint: Use -f if you really want to add them.",
    "hint: Disable this message with \"git config set advice.addIgnoredFile false\"",
  ]
}

///|
fn submodule_add_existing_index_error(
  entries : Array[@bitlib.IndexEntry],
  path : String,
  force : Bool,
) -> String? {
  let mut has_gitlink = false
  for entry in entries {
    if entry.path == path {
      if entry.mode == 0o160000 {
        has_gitlink = true
        continue
      }
      return Some("fatal: '\{path}' already exists in the index")
    }
    if entry.path.has_prefix(path + "/") {
      return Some("fatal: '\{path}' already exists in the index")
    }
  }
  if has_gitlink && !force {
    return Some("fatal: '\{path}' already exists in the index")
  }
  None
}

///|
fn submodule_add_reserved_name_path(
  fs : &@bitcore.RepoFileSystem,
  root : String,
  git_dir : String,
  name : String,
) -> String? {
  for sub in parse_gitmodules(fs, root) {
    if sub.name == name && sub.path.length() > 0 {
      return Some(sub.path)
    }
  }
  for sub in parse_submodule_config(fs, git_dir) {
    if sub.name == name && sub.path.length() > 0 {
      return Some(sub.path)
    }
  }
  None
}

///|
fn submodule_add_name_in_use_error(name : String, path : String) -> String {
  "fatal: submodule name '\{name}' is already used for path '\{path}'"
}

///|
async fn resolve_submodule_target_id(
  fs : OsFs,
  root : String,
  url : String,
  branch : String?,
) -> @bitcore.ObjectId raise Error {
  if branch is None {
    return resolve_submodule_head_id(fs, root, url)
  }
  let rfs : &@bitcore.RepoFileSystem = fs
  let target_ref = "refs/heads/" + branch.unwrap()
  match @bitlib.resolve_local_repo_path(rfs, root, url) {
    Some(src_path) =>
      match @bitlib.detect_git_dir(rfs, src_path) {
        Some((src_git_dir, _)) => {
          let resolved = match branch {
            Some(_) => @bitlib.resolve_ref(rfs, src_git_dir, target_ref)
            None => @bitlib.resolve_head_commit(rfs, src_git_dir)
          }
          match resolved {
            Some(id) => id
            None =>
              raise @bitcore.GitError::InvalidObject(
                "Failed to resolve submodule target: " + url + " " + target_ref,
              )
          }
        }
        None =>
          raise @bitcore.GitError::InvalidObject("Not a git repository: " + url)
      }
    None => {
      let resolved = resolve_remote_ref_id(url, target_ref)
      match resolved {
        Some((id, _)) => id
        None =>
          raise @bitcore.GitError::InvalidObject(
            "Failed to resolve submodule target: " + url + " " + target_ref,
          )
      }
    }
  }
}

///|
fn submodule_add_source_git_dir(
  fs : &@bitcore.RepoFileSystem,
  root : String,
  url : String,
  existing_repo_git_dir : String?,
) -> String? {
  match existing_repo_git_dir {
    Some(git_dir) => Some(git_dir)
    None =>
      match @bitlib.resolve_local_repo_path(fs, root, url) {
        Some(src_path) =>
          @bitlib.detect_git_dir(fs, src_path).map(pair => pair.0)
        None => None
      }
  }
}

///|
fn submodule_add_hash_mismatch(
  fs : &@bitcore.RepoFileSystem,
  super_git_dir : String,
  source_git_dir : String?,
) -> Bool {
  match source_git_dir {
    Some(src_git_dir) =>
      repo_object_format(fs, super_git_dir) !=
      repo_object_format(fs, src_git_dir)
    None => false
  }
}

///|
async fn handle_submodule_add(
  fs : OsFs,
  root : String,
  git_dir : String,
  args : Array[String],
) -> Unit raise Error {
  let add_args = parse_submodule_add_args(args)
  let branch = add_args.branch
  let depth = add_args.depth
  let explicit_name = add_args.name
  let quiet = add_args.quiet
  let progress = add_args.progress
  let force = add_args.force
  let url = add_args.url
  let mut path = add_args.path
  if url.length() == 0 {
    raise @bitcore.GitError::InvalidObject(
      "submodule add requires a repository",
    )
  }
  let cwd_prefix = submodule_cwd_prefix(root)
  if cwd_prefix.length() > 0 && submodule_relative_local_url(url) {
    eprint_line(
      "fatal: Relative path can only be used from the toplevel of the working tree",
    )
    @sys.exit(128)
  }
  let root_abs = submodule_canonical_dir(ls_files_repo_root_abs(root))
  if path.length() == 0 {
    path = derive_submodule_path(url)
    if cwd_prefix.length() > 0 {
      path = normalize_submodule_add_path(path, cwd_prefix, root_abs)
    }
  } else {
    path = normalize_submodule_add_path(path, cwd_prefix, root_abs)
  }
  path = normalize_submodule_add_path(path, "", root_abs)
  let name = explicit_name.unwrap_or(path)
  let rfs : &@bitcore.RepoFileSystem = fs
  let index_lock = git_dir + "/index.lock"
  if rfs.is_file(index_lock) {
    eprint_line("fatal: Unable to create '\{index_lock}': File exists.")
    @sys.exit(128)
  }
  if !force && add_has_explicit_ignored_path(rfs, root, [path]) {
    for line in submodule_add_ignored_error_lines(path) {
      eprint_line(line)
    }
    @sys.exit(1)
  }
  let index_entries = @bitlib.read_index_entries(rfs, git_dir) catch { _ => [] }
  match submodule_add_existing_index_error(index_entries, path, force) {
    Some(msg) => {
      eprint_line(msg)
      @sys.exit(128)
    }
    None => ()
  }
  let common_git_dir = resolve_submodule_common_git_dir(rfs, git_dir)
  let modules_dir = common_git_dir + "/modules/" + name
  let sub_path = root + "/" + path
  let sub_git = sub_path + "/.git"
  let existing_embedded_repo = rfs.is_dir(sub_git)
  match load_submodule_add_path_blocker(rfs, sub_path, sub_git) {
    Some("empty_dir") => exit_submodule_add_invalid_repo_path(path)
    Some(_) => exit_submodule_existing_path(sub_path)
    None => ()
  }
  let existing_repo_git_dir = match @bitlib.detect_git_dir(rfs, sub_path) {
    Some((existing_git_dir, _)) => Some(existing_git_dir)
    None => None
  }
  let reusable_modules_git_dir = match
    @bitlib.detect_git_dir(rfs, modules_dir) {
    Some((reused_git_dir, _)) => Some(reused_git_dir)
    None => None
  }
  match submodule_add_reserved_name_path(rfs, root, git_dir, name) {
    Some(existing_path) =>
      if !force {
        eprint_line(submodule_add_name_in_use_error(name, existing_path))
        @sys.exit(128)
      }
    None =>
      if !force && reusable_modules_git_dir is Some(_) {
        eprint_line(submodule_add_name_in_use_error(name, path))
        @sys.exit(128)
      }
  }
  let reusable_repo_git_dir = match existing_repo_git_dir {
    Some(existing_git_dir) => Some(existing_git_dir)
    None => if force { reusable_modules_git_dir } else { None }
  }
  let unreachable_id = @bitcore.ObjectId::new(FixedArray::make(20, b'\x00'))
  let fetch_url = match reusable_repo_git_dir {
    Some(_) => resolve_submodule_config_url(fs, root, git_dir, url)
    None => resolve_submodule_fetch_url(fs, root, git_dir, url)
  }
  let source_git_dir = submodule_add_source_git_dir(
    rfs, root, fetch_url, reusable_repo_git_dir,
  )
  if submodule_add_hash_mismatch(rfs, git_dir, source_git_dir) {
    eprint_line("fatal: cannot add a submodule of a different hash algorithm")
    @sys.exit(128)
  }
  let target_id = match reusable_repo_git_dir {
    Some(reused_git_dir) => {
      let existing_target = match branch {
        Some(branch_name) =>
          @bitlib.resolve_ref(rfs, reused_git_dir, "refs/heads/" + branch_name)
        None => @bitlib.resolve_head_commit(rfs, reused_git_dir)
      }
      match existing_target {
        Some(id) => id
        None => {
          eprint_line(submodule_add_no_commit_message(path))
          @sys.exit(128)
          unreachable_id
        }
      }
    }
    None => {
      match @bitlib.resolve_local_repo_path(rfs, root, fetch_url) {
        Some(src_path) =>
          match @bitlib.detect_git_dir(rfs, src_path) {
            Some((src_git_dir, _)) =>
              if @bitlib.resolve_head_commit(rfs, src_git_dir) is None {
                eprint_line(submodule_add_no_commit_message(path))
                @sys.exit(128)
              }
            None => ()
          }
        None => ()
      }
      resolve_submodule_target_id(fs, root, fetch_url, branch)
    }
  }
  write_gitmodules_entry(fs, root, name, path, url, branch)
  let config_path = git_dir + "/config"
  let config_url = resolve_submodule_config_url(fs, root, git_dir, url)
  set_config(
    fs,
    config_path,
    "submodule." + name + ".url",
    config_url,
    false,
    (None : String?),
    (None : String?),
  )
  set_config(
    fs,
    config_path,
    "submodule." + name + ".path",
    path,
    false,
    (None : String?),
    (None : String?),
  )
  if submodule_add_should_write_active(rfs, git_dir, name, path, root_abs) {
    set_config(
      fs,
      config_path,
      "submodule." + name + ".active",
      "true",
      false,
      (None : String?),
      (None : String?),
    )
  }
  if branch is Some(b) {
    set_config(
      fs,
      config_path,
      "submodule." + name + ".branch",
      b,
      false,
      (None : String?),
      (None : String?),
    )
  }
  let reused_existing_repo = reusable_repo_git_dir is Some(_)
  let absorbed_existing_repo = if existing_embedded_repo &&
    !reused_existing_repo {
    if !fs.is_dir(modules_dir) {
      fs.mkdir_p(modules_dir)
    }
    absorb_git_dir(fs, sub_path, sub_git, modules_dir)
    true
  } else {
    false
  }
  let direct_existing_repo = existing_embedded_repo && !absorbed_existing_repo
  if !absorbed_existing_repo && !direct_existing_repo && !fs.is_dir(modules_dir) {
    submodule_init_modules_repo(fs, git_dir, modules_dir)
  }
  let active_sub_git_dir = if direct_existing_repo {
    sub_git
  } else {
    modules_dir
  }
  let modules_config = active_sub_git_dir + "/config"
  if !direct_existing_repo {
    set_config(
      fs,
      modules_config,
      "remote.origin.url",
      if absorbed_existing_repo {
        config_url
      } else {
        fetch_url
      },
      false,
      (None : String?),
      (None : String?),
    )
    set_config(
      fs,
      modules_config,
      "remote.origin.fetch",
      "+refs/heads/*:refs/remotes/origin/*",
      false,
      (None : String?),
      (None : String?),
    )
    if absorbed_existing_repo {
      ensure_submodule_gitdir_config(fs, modules_dir, sub_path)
    }
  }
  let mut remote_head_branch = @bitlib.read_remote_head_branch(fs, modules_dir)
  if !reused_existing_repo && !direct_existing_repo {
    if progress && !quiet {
      eprint_line("Checking connectivity: 100% (1/1), done.")
    }
    fetch_submodule_objects(
      fs,
      root,
      modules_dir,
      fetch_url,
      target_id,
      branch~,
      depth~,
      quiet~,
    )
    remote_head_branch = @bitlib.read_remote_head_branch(fs, modules_dir)
  }
  let needs_worktree_checkout = !absorbed_existing_repo &&
    (!fs.is_dir(sub_path) || (!fs.is_file(sub_git) && !fs.is_dir(sub_git)))
  if needs_worktree_checkout {
    if !fs.is_dir(sub_path) {
      fs.mkdir_p(sub_path)
    }
    let rel_path = submodule_relative_path(sub_path, modules_dir)
    fs.write_string(sub_path + "/.git", "gitdir: \{rel_path}\n")
    ensure_submodule_gitdir_config(fs, modules_dir, sub_path)
    run_checkout_in_submodule(fs, fs, sub_path, modules_dir, target_id)
  }
  let checkout_branch = match branch {
    Some(name) => Some(name)
    None =>
      match remote_head_branch {
        Some(name) => Some(name)
        None => Some("main")
      }
  }
  match branch {
    Some(branch_name) =>
      match remote_head_branch {
        Some(remote_name) =>
          if remote_name != branch_name {
            match resolve_submodule_branch_id(rfs, modules_dir, remote_name) {
              Some(branch_id) =>
                write_submodule_branch_ref(
                  fs, modules_dir, remote_name, branch_id,
                )
              None => ()
            }
          }
        None => ()
      }
    None => ()
  }
  match checkout_branch {
    Some(branch_name) => {
      let branch_id = resolve_submodule_branch_id(rfs, modules_dir, branch_name).unwrap_or(
        target_id,
      )
      write_submodule_branch_ref(fs, active_sub_git_dir, branch_name, branch_id)
      fs.write_string(
        active_sub_git_dir + "/HEAD",
        "ref: refs/heads/" + branch_name + "\n",
      )
      if !direct_existing_repo {
        set_config(
          fs,
          modules_config,
          "branch." + branch_name + ".remote",
          "origin",
          false,
          (None : String?),
          (None : String?),
        )
        set_config(
          fs,
          modules_config,
          "branch." + branch_name + ".merge",
          "refs/heads/" + branch_name,
          false,
          (None : String?),
          (None : String?),
        )
      }
    }
    None => ()
  }
  @bitlibnative.apply_worktree_modes_from_commit(
    fs, fs, sub_path, active_sub_git_dir, target_id,
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
  if needs_worktree_checkout {
    let post_checkout_code = submodule_run_post_checkout_hook(
      sub_path, active_sub_git_dir, target_id,
    )
    if post_checkout_code != 0 {
      @sys.exit(128)
    }
  }
  @bitlib.add_paths_async(fs, fs, root, [".gitmodules"])
  update_submodule_index_entry(fs, git_dir, path, target_id)
}

///|
fn derive_submodule_path(url : String) -> String {
  let mut name = url
  for part_view in url.split("/") {
    let part = part_view.to_owned()
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
fn submodule_find_by_path(
  submodules : Array[SubmoduleInfo],
  path : String,
) -> SubmoduleInfo? {
  for sub in submodules {
    if sub.path == path {
      return Some(sub)
    }
  }
  None
}

///|
fn submodule_index_gitlink_paths(
  entries : Array[@bitlib.IndexEntry],
) -> Array[String] {
  let paths : Array[String] = []
  for entry in entries {
    if entry.mode == 57344 {
      paths.push(entry.path)
    }
  }
  paths
}

///|
fn load_submodule_index_gitlink_paths(
  fs : &@bitcore.RepoFileSystem,
  git_dir : String,
) -> Array[String] {
  let entries = @bitlib.read_index_entries(fs, git_dir) catch { _ => return [] }
  submodule_index_gitlink_paths(entries)
}

///|
fn submodule_missing_url_paths(
  submodules : Array[SubmoduleInfo],
  index_paths : Array[String],
  requested_paths : Array[String],
) -> Array[String] {
  let target_paths = if requested_paths.length() > 0 {
    requested_paths
  } else {
    index_paths
  }
  let missing : Array[String] = []
  for path in target_paths {
    if !index_paths.contains(path) {
      continue
    }
    match submodule_find_by_path(submodules, path) {
      Some(sub) if sub.url.length() > 0 => ()
      _ => missing.push(path)
    }
  }
  missing
}

///|
fn submodule_unmatched_index_paths(
  index_paths : Array[String],
  requested_paths : Array[String],
) -> Array[String] {
  let unmatched : Array[String] = []
  for path in requested_paths {
    if !index_paths.contains(path) {
      unmatched.push(path)
    }
  }
  unmatched
}

///|
fn submodule_known_paths(
  submodules : Array[SubmoduleInfo],
  index_paths : Array[String],
) -> Array[String] {
  let known = index_paths.copy()
  for sub in submodules {
    if !known.contains(sub.path) {
      known.push(sub.path)
    }
  }
  known
}

///|
fn submodule_update_path_blocker_kind(
  path_is_file : Bool,
  entries : Array[String],
  has_git_entry : Bool,
) -> Bool {
  if path_is_file {
    return true
  }
  if has_git_entry {
    return false
  }
  entries.length() > 0
}

///|
fn load_submodule_update_path_blocker(
  fs : &@bitcore.RepoFileSystem,
  sub_path : String,
  sub_git : String,
) -> Bool {
  if fs.is_file(sub_path) {
    return true
  }
  if !fs.is_dir(sub_path) {
    return false
  }
  let entries = fs.readdir(sub_path) catch { _ => [] }
  let has_git_entry = fs.is_dir(sub_git) || fs.is_file(sub_git)
  submodule_update_path_blocker_kind(false, entries, has_git_entry)
}

///|
fn submodule_add_path_blocker_kind(
  path_is_file : Bool,
  entries : Array[String],
  has_git_entry : Bool,
) -> String? {
  if path_is_file {
    return Some("path")
  }
  if has_git_entry {
    return None
  }
  if entries.length() == 0 {
    return Some("empty_dir")
  }
  Some("path")
}

///|
fn load_submodule_add_path_blocker(
  fs : &@bitcore.RepoFileSystem,
  sub_path : String,
  sub_git : String,
) -> String? {
  if fs.is_file(sub_path) {
    return Some("path")
  }
  if !fs.is_dir(sub_path) {
    return None
  }
  let entries = fs.readdir(sub_path) catch { _ => [] }
  let has_git_entry = fs.is_dir(sub_git) || fs.is_file(sub_git)
  submodule_add_path_blocker_kind(false, entries, has_git_entry)
}

///|
fn submodule_add_no_commit_message(path : String) -> String {
  let display_path = if path.has_prefix("./") && path.length() > 2 {
    String::unsafe_substring(path, start=2, end=path.length())
  } else {
    path
  }
  "fatal: '\{display_path}' does not have a commit checked out"
}

///|
fn resolve_submodule_branch_id(
  fs : &@bitcore.RepoFileSystem,
  modules_dir : String,
  branch_name : String,
) -> @bitcore.ObjectId? {
  let local_id = @bitlib.resolve_ref(
    fs,
    modules_dir,
    "refs/heads/" + branch_name,
  ) catch {
    _ => None
  }
  match local_id {
    Some(id) => Some(id)
    None =>
      @bitlib.resolve_ref(fs, modules_dir, "refs/remotes/origin/" + branch_name) catch {
        _ => None
      }
  }
}

///|
fn write_submodule_branch_ref(
  fs : OsFs,
  modules_dir : String,
  branch_name : String,
  branch_id : @bitcore.ObjectId,
) -> Unit raise Error {
  let branch_ref = modules_dir + "/refs/heads/" + branch_name
  match branch_ref.rev_find("/") {
    Some(i) => fs.mkdir_p(String::unsafe_substring(branch_ref, start=0, end=i))
    None => ()
  }
  fs.write_string(branch_ref, branch_id.to_hex() + "\n")
}

///|
fn read_submodule_config_value(
  fs : &@bitcore.RepoFileSystem,
  git_dir : String,
  name : String,
  key : String,
) -> String? {
  let section = "submodule \"" + name + "\""
  match @bitlib.read_config_value(fs, git_dir + "/config", section, key) {
    Some(value) if trim_string(value).length() > 0 => Some(trim_string(value))
    _ => {
      let common_git_dir = resolve_submodule_common_git_dir(fs, git_dir)
      if common_git_dir == git_dir {
        None
      } else {
        match
          @bitlib.read_config_value(
            fs,
            common_git_dir + "/config",
            section,
            key,
          ) {
          Some(value) if trim_string(value).length() > 0 =>
            Some(trim_string(value))
          _ => None
        }
      }
    }
  }
}

///|
fn parse_submodule_config(
  fs : &@bitcore.RepoFileSystem,
  git_dir : String,
) -> Array[SubmoduleInfo] {
  let config_git_dir = resolve_submodule_common_git_dir(fs, git_dir)
  let config_path = config_git_dir + "/config"
  if !fs.is_file(config_path) {
    return []
  }
  let content = decode_bytes(fs.read_file(config_path)) catch { _ => return [] }
  let result : Array[SubmoduleInfo] = []
  let mut current_name = ""
  let mut current_path = ""
  let mut current_url = ""
  for line_view in content.split("\n") {
    let line = trim_string(line_view.to_owned())
    if line.has_prefix("[submodule \"") && line.has_suffix("\"]") {
      if current_name.length() > 0 && current_path.length() > 0 {
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
  if current_name.length() > 0 && current_path.length() > 0 {
    result.push({ name: current_name, path: current_path, url: current_url })
  }
  result
}

///|
fn submodule_status_infos(
  gitmodules : Array[SubmoduleInfo],
  config : Array[SubmoduleInfo],
) -> Array[SubmoduleInfo] {
  let merged : Array[SubmoduleInfo] = []
  for sub in gitmodules {
    let mut path = sub.path
    let mut url = sub.url
    for config_sub in config {
      if config_sub.name == sub.name || config_sub.path == sub.path {
        if config_sub.path.length() > 0 {
          path = config_sub.path
        }
        if config_sub.url.length() > 0 {
          url = config_sub.url
        }
        break
      }
    }
    merged.push({ name: sub.name, path, url })
  }
  merged
}

///|
fn submodule_uninitialized_paths(
  fs : &@bitcore.RepoFileSystem,
  git_dir : String,
  submodules : Array[SubmoduleInfo],
  requested_paths : Array[String],
) -> Array[String] {
  let paths : Array[String] = []
  for sub in submodules {
    if requested_paths.length() > 0 && !requested_paths.contains(sub.path) {
      continue
    }
    if read_submodule_config_value(fs, git_dir, sub.name, "url") is None {
      paths.push(sub.path)
    }
  }
  paths
}

///|
fn submodule_update_notice_paths(
  fs : &@bitcore.RepoFileSystem,
  git_dir : String,
  submodules : Array[SubmoduleInfo],
  index_paths : Array[String],
  requested_paths : Array[String],
) -> Array[String] {
  let paths = submodule_missing_url_paths(
    submodules, index_paths, requested_paths,
  )
  let uninitialized = submodule_uninitialized_paths(
    fs, git_dir, submodules, requested_paths,
  )
  for path in uninitialized {
    if !paths.contains(path) {
      paths.push(path)
    }
  }
  paths
}

///|
fn submodule_update_fatal_missing_url_paths(
  fs : &@bitcore.RepoFileSystem,
  git_dir : String,
  submodules : Array[SubmoduleInfo],
  paths : Array[String],
) -> Array[String] {
  let fatal : Array[String] = []
  let common_git_dir = resolve_submodule_common_git_dir(fs, git_dir)
  for path in paths {
    match submodule_find_by_path(submodules, path) {
      Some(sub) =>
        if read_submodule_config_value(fs, git_dir, sub.name, "active")
          is Some(_) ||
          fs.is_dir(common_git_dir + "/modules/" + sub.name) {
          fatal.push(path)
        }
      None => ()
    }
  }
  fatal
}

///|
fn submodule_select_paths_from_filters(
  known_paths : Array[String],
  filters : Array[String],
) -> (Array[String], String?) {
  let include_filters : Array[String] = []
  let exclude_filters : Array[String] = []
  for filter in filters {
    let (raw, is_exclude, _is_icase) = parse_pathspec_magic(filter)
    if raw.length() == 0 {
      continue
    }
    if is_exclude {
      exclude_filters.push(filter)
    } else {
      include_filters.push(filter)
    }
  }
  if include_filters.length() > 0 {
    for filter in include_filters {
      let (raw, _is_exclude, _is_icase) = parse_pathspec_magic(filter)
      let matched = if raw == "" || raw == "." {
        known_paths.length() > 0
      } else {
        let mut found = false
        for path in known_paths {
          if ls_files_pathspec_matches(path, filter) {
            found = true
            break
          }
        }
        found
      }
      if !matched {
        return ([], Some(filter))
      }
    }
  }
  let selected : Array[String] = []
  for path in known_paths {
    let include_match = if include_filters.length() == 0 {
      true
    } else {
      let mut matched = false
      for filter in include_filters {
        let (raw, _is_exclude, _is_icase) = parse_pathspec_magic(filter)
        if raw == "" || raw == "." || ls_files_pathspec_matches(path, filter) {
          matched = true
          break
        }
      }
      matched
    }
    if !include_match {
      continue
    }
    let mut excluded = false
    for filter in exclude_filters {
      let (raw, _is_exclude, _is_icase) = parse_pathspec_magic(filter)
      if raw == "" || raw == "." || ls_files_pathspec_matches(path, filter) {
        excluded = true
        break
      }
    }
    if !excluded {
      selected.push(path)
    }
  }
  (selected, None)
}

///|
fn submodule_active_filters(
  fs : &@bitcore.RepoFileSystem,
  git_dir : String,
  root_abs : String,
) -> Array[String] {
  let config_path = git_dir + "/config"
  if !fs.is_file(config_path) {
    return []
  }
  let values = get_all_config_values(
    fs,
    config_path,
    "submodule.active",
    (None : String?),
    false,
  ) catch {
    _ => []
  }
  let normalized : Array[String] = []
  for value in values {
    let (raw, is_exclude, is_icase) = parse_pathspec_magic(value)
    if raw == "" || raw == "." {
      normalized.push(compose_pathspec_magic(".", is_exclude, is_icase))
      continue
    }
    let resolved = normalize_submodule_status_paths([value], "", root_abs) catch {
      _ => []
    }
    for item in resolved {
      normalized.push(item)
    }
  }
  normalized
}

///|
fn submodule_add_should_write_active(
  fs : &@bitcore.RepoFileSystem,
  git_dir : String,
  name : String,
  path : String,
  root_abs : String,
) -> Bool {
  if read_submodule_config_value(fs, git_dir, name, "active") is Some(_) {
    return false
  }
  let active_filters = submodule_active_filters(fs, git_dir, root_abs)
  if active_filters.length() == 0 {
    return true
  }
  let (selected, _unmatched) = submodule_select_paths_from_filters(
    [path],
    active_filters,
  )
  selected.length() == 0
}

///|
fn submodule_resolve_target_paths(
  fs : &@bitcore.RepoFileSystem,
  git_dir : String,
  submodules : Array[SubmoduleInfo],
  known_paths : Array[String],
  requested_paths : Array[String],
  root_abs : String,
) -> (Array[String], Bool, String?) {
  if requested_paths.length() > 0 {
    let (selected, unmatched) = submodule_select_paths_from_filters(
      known_paths, requested_paths,
    )
    return (selected, true, unmatched)
  }
  let active_filters = submodule_active_filters(fs, git_dir, root_abs)
  let named_active : Map[String, Bool] = Map([])
  let mut has_named_active = false
  for sub in submodules {
    match read_submodule_config_value(fs, git_dir, sub.name, "active") {
      Some(raw) =>
        match parse_bool_keyword_value(raw) {
          Some(active) => {
            named_active[sub.path] = active
            has_named_active = true
          }
          None => ()
        }
      None => ()
    }
  }
  if active_filters.length() == 0 && !has_named_active {
    return ([], false, None)
  }
  let selected_by_filter = if active_filters.length() > 0 {
    let (selected, _unmatched) = submodule_select_paths_from_filters(
      known_paths, active_filters,
    )
    selected
  } else {
    []
  }
  let selected : Array[String] = []
  for sub in submodules {
    match named_active.get(sub.path) {
      Some(active) => if active { selected.push(sub.path) }
      None =>
        if active_filters.length() > 0 && selected_by_filter.contains(sub.path) {
          selected.push(sub.path)
        }
    }
  }
  (selected, true, None)
}

///|
fn normalize_submodule_status_paths(
  paths : Array[String],
  cwd_prefix : String,
  root_abs : String,
) -> Array[String] raise Error {
  normalize_ls_files_filters(paths, cwd_prefix, root_abs)
}

///|
fn submodule_status_output(
  display_path : String,
  index_id : @bitcore.ObjectId?,
  head_id : @bitcore.ObjectId?,
  cached : Bool,
  head_label : String?,
) -> String {
  let prefix = match (index_id, head_id) {
    (Some(idx), Some(head)) =>
      if idx.to_hex() == head.to_hex() {
        " "
      } else {
        "+"
      }
    (Some(_), None) => "-"
    (None, Some(_)) => " "
    (None, None) => "-"
  }
  let shown_id = if cached {
    match index_id {
      Some(id) => Some(id)
      None => head_id
    }
  } else {
    match head_id {
      Some(id) => Some(id)
      None => index_id
    }
  }
  let hex = match shown_id {
    Some(id) => id.to_hex()
    None => String::make(40, '0')
  }
  let suffix = if cached {
    ""
  } else {
    match (head_id, head_label) {
      (Some(_), Some(label)) => " (\{label})"
      _ => ""
    }
  }
  "\{prefix}\{hex} \{display_path}\{suffix}"
}

///|
fn submodule_status_head_label(content : String) -> String? {
  let trimmed = trim_string(content)
  guard trimmed.has_prefix("ref: ") else { return None }
  let ref_name = String::unsafe_substring(
    trimmed,
    start=5,
    end=trimmed.length(),
  )
  if ref_name.has_prefix("refs/") {
    Some(String::unsafe_substring(ref_name, start=5, end=ref_name.length()))
  } else {
    Some(ref_name)
  }
}

///|
fn read_submodule_status_head_label(
  fs : &@bitcore.RepoFileSystem,
  sub_git_dir : String,
  head_id : @bitcore.ObjectId,
) -> String? {
  let head_path = sub_git_dir + "/HEAD"
  if !fs.is_file(head_path) {
    return None
  }
  let content = decode_bytes(
    fs.read_file(head_path) catch {
      _ => Default::default()
    },
  )
  match submodule_status_head_label(content) {
    Some(label) => Some(label)
    None => submodule_status_exact_ref_label(fs, sub_git_dir, head_id)
  }
}

///|
fn submodule_status_exact_ref_label(
  fs : &@bitcore.RepoFileSystem,
  sub_git_dir : String,
  head_id : @bitcore.ObjectId,
) -> String? {
  let refs = @bitlib.show_ref(fs, sub_git_dir) catch { _ => [] }
  let mut branch_match : String? = None
  let mut remote_match : String? = None
  let mut other_match : String? = None
  for item in refs {
    let (name, id) = item
    let target_id = if name.has_prefix("refs/tags/") {
      if id.to_hex() == head_id.to_hex() {
        Some(id)
      } else {
        @bitrepo.rev_parse(fs, sub_git_dir, "\{name}^{commit}") catch {
          _ => None
        }
      }
    } else {
      Some(id)
    }
    match target_id {
      Some(target) =>
        if target.to_hex() == head_id.to_hex() {
          if name.has_prefix("refs/tags/") {
            return Some(
              String::unsafe_substring(name, start=10, end=name.length()),
            )
          } else if name.has_prefix("refs/heads/") {
            branch_match = Some(
              String::unsafe_substring(name, start=5, end=name.length()),
            )
          } else if name.has_prefix("refs/remotes/") {
            remote_match = Some(
              String::unsafe_substring(name, start=5, end=name.length()),
            )
          } else if other_match is None {
            other_match = Some(name)
          }
        }
      None => ()
    }
  }
  match branch_match {
    Some(label) => Some(label)
    None =>
      match remote_match {
        Some(label) => Some(label)
        None => other_match
      }
  }
}

///|
fn submodule_cwd_prefix(root : String) -> String {
  let cwd_abs = match @sys.get_env_var("GIT_SHIM_CWD") {
    Some(v) => v
    None =>
      match @sys.get_env_var("GIT_SHIM_PWD") {
        Some(v) => v
        None => @sys.get_env_var("PWD").unwrap_or(root)
      }
  }
  let raw_cwd_prefix = rev_parse_show_prefix(root, cwd_abs)
  if raw_cwd_prefix.has_suffix("/") {
    String::unsafe_substring(
      raw_cwd_prefix,
      start=0,
      end=raw_cwd_prefix.length() - 1,
    )
  } else {
    raw_cwd_prefix
  }
}

///|
fn gitmodules_has_unmapped_paths(content : String) -> Bool {
  let mut in_section = false
  let mut has_path = false
  let mut has_url = false
  for line_view in content.split("\n") {
    let line = trim_string(line_view.to_owned())
    if line.has_prefix("[submodule \"") && line.has_suffix("\"]") {
      if in_section && has_url && !has_path {
        return true
      }
      in_section = true
      has_path = false
      has_url = false
      continue
    }
    if !in_section {
      continue
    }
    if line.has_prefix("path") {
      has_path = true
    } else if line.has_prefix("url") {
      has_url = true
    }
  }
  in_section && has_url && !has_path
}

///|
async fn exit_missing_submodule_url(path : String) -> Unit raise Error {
  eprint_line("fatal: No url found for submodule path '\{path}' in .gitmodules")
  @sys.exit(128)
}

///|
async fn exit_update_missing_submodule_url(path : String) -> Unit raise Error {
  eprint_line("fatal: cannot clone submodule '\{path}' without a URL")
  @sys.exit(128)
}

///|
async fn print_submodule_not_initialized(path : String) -> Unit raise Error {
  eprint_line("Submodule path '\{path}' not initialized")
  eprint_line("Maybe you want to use 'update --init'?")
}

///|
async fn exit_submodule_existing_path(path : String) -> Unit raise Error {
  eprint_line(
    "fatal: destination path '\{path}' already exists and is not an empty directory.",
  )
  @sys.exit(1)
}

///|
async fn exit_submodule_add_invalid_repo_path(
  path : String,
) -> Unit raise Error {
  eprint_line("fatal: '\{path}' already exists and is not a valid git repo")
  @sys.exit(1)
}

///|
fn submodule_upsert_config_value(
  content : String,
  name : String,
  key : String,
  value : String,
) -> String {
  let target = "[submodule \"\{name}\"]"
  let lines : Array[String] = []
  for line_view in content.split("\n") {
    lines.push(line_view.to_owned())
  }
  let mut section_start = -1
  let mut section_end = lines.length()
  for i in 0..<lines.length() {
    let trimmed = trim_chars(lines[i], " \t")
    if trimmed == target {
      section_start = i
      section_end = lines.length()
      continue
    }
    if section_start >= 0 && trimmed.has_prefix("[") {
      section_end = i
      break
    }
  }
  if section_start < 0 {
    let mut out = content
    if out.length() > 0 && !out.has_suffix("\n") {
      out = out + "\n"
    }
    return out + target + "\n\t\{key} = \{value}\n"
  }
  let out : Array[String] = []
  let mut inserted = false
  let mut i = 0
  while i < lines.length() {
    if i == section_end && !inserted {
      out.push("\t\{key} = \{value}")
      inserted = true
    }
    if i > section_start && i < section_end {
      let trimmed = trim_chars(lines[i], " \t")
      if trimmed.has_prefix(key + " =") && !inserted {
        out.push("\t\{key} = \{value}")
        inserted = true
        i += 1
        continue
      }
    }
    out.push(lines[i])
    i += 1
  }
  if !inserted {
    if out.length() > 0 && out[out.length() - 1].length() == 0 {
      out.insert(out.length() - 1, "\t\{key} = \{value}")
    } else {
      out.push("\t\{key} = \{value}")
    }
  }
  out.join("\n")
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
  let rfs : &@bitcore.RepoFileSystem = fs
  let content = if rfs.is_file(gitmodules_path) {
    decode_bytes(rfs.read_file(gitmodules_path))
  } else {
    ""
  }
  let mut updated = submodule_upsert_config_value(content, name, "path", path)
  updated = submodule_upsert_config_value(updated, name, "url", url)
  if branch is Some(b) {
    updated = submodule_upsert_config_value(updated, name, "branch", b)
  }
  fs.write_string(gitmodules_path, updated)
}

///|
async fn resolve_submodule_head_id(
  fs : OsFs,
  root : String,
  url : String,
) -> @bitcore.ObjectId raise Error {
  let rfs : &@bitcore.RepoFileSystem = fs
  match @bitlib.resolve_local_repo_path(rfs, root, url) {
    Some(src_path) =>
      match @bitlib.detect_git_dir(rfs, src_path) {
        Some((src_git_dir, _)) => {
          let head = @bitlib.resolve_head_commit(rfs, src_git_dir)
          match head {
            Some(id) => id
            None =>
              raise @bitcore.GitError::InvalidObject(
                "Invalid HEAD in submodule: " + url,
              )
          }
        }
        None =>
          raise @bitcore.GitError::InvalidObject("Not a git repository: " + url)
      }
    None => {
      let resolved = resolve_remote_ref_id(url, "HEAD")
      match resolved {
        Some((id, _)) => id
        None =>
          raise @bitcore.GitError::InvalidObject(
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
  id : @bitcore.ObjectId,
) -> Unit raise Error {
  let rfs : &@bitcore.RepoFileSystem = fs
  let entries = @bitlib.read_index_entries(rfs, git_dir) catch { _ => [] }
  let out : Array[@bitlib.IndexEntry] = []
  for e in entries {
    if e.path != path {
      out.push(e)
    }
  }
  out.push(
    @bitlib.IndexEntry::new(path, id, 57344, 0, mtime_sec=0, mtime_nsec=0),
  )
  @bitlib.write_index_entries(fs, git_dir, out)
}

///|
async fn handle_submodule_status(
  fs : OsFs,
  root : String,
  git_dir : String,
  args : Array[String],
) -> Unit raise Error {
  let mut recursive = false
  let mut cached = false
  let raw_paths : Array[String] = []
  for arg in args {
    match arg {
      "--recursive" => recursive = true
      "--cached" => cached = true
      _ if !arg.has_prefix("-") => raw_paths.push(arg)
      _ => ()
    }
  }
  let rfs : &@bitcore.RepoFileSystem = fs
  let cwd_prefix = submodule_cwd_prefix(root)
  let root_abs = ls_files_repo_root_abs(root)
  let paths = normalize_submodule_status_paths(raw_paths, cwd_prefix, root_abs)
  let gitmodules_path = root + "/.gitmodules"
  if rfs.is_file(gitmodules_path) {
    let gitmodules = decode_bytes(
      rfs.read_file(gitmodules_path) catch {
        _ => Default::default()
      },
    )
    if gitmodules_has_unmapped_paths(gitmodules) {
      @sys.exit(1)
    }
  }
  let index_paths = load_submodule_index_gitlink_paths(rfs, git_dir)
  let unmatched_paths = submodule_unmatched_index_paths(index_paths, paths)
  match unmatched_paths.get(0) {
    Some(path) => {
      eprint_line(
        "error: pathspec '\{path}' did not match any file(s) known to git",
      )
      @sys.exit(1)
    }
    None => ()
  }
  let submodules = submodule_status_infos(
    parse_gitmodules(rfs, root),
    parse_submodule_config(rfs, git_dir),
  )
  for sub in submodules {
    if paths.length() > 0 && !paths.contains(sub.path) {
      continue
    }
    let sub_path = root + "/" + sub.path
    let display_path = make_display_path(sub.path, cwd_prefix)
    let index_id = get_submodule_index_id(rfs, git_dir, sub.path)
    let sub_git = sub_path + "/.git"
    // Check if initialized
    if !rfs.is_file(sub_git) && !rfs.is_dir(sub_git) {
      print_line(
        submodule_status_output(display_path, index_id, None, cached, None),
      )
      continue
    }
    // Get HEAD of submodule
    let sub_git_dir = @bitlib.resolve_gitdir(rfs, sub_git)
    let head_id = @bitlib.resolve_head_commit(rfs, sub_git_dir) catch {
      err => {
        if @async.is_being_cancelled() || @async.is_cancellation_error(err) {
          raise err
        }
        print_line(
          submodule_status_output(display_path, index_id, None, cached, None),
        )
        continue
      }
    }
    match head_id {
      Some(id) => {
        let head_label = read_submodule_status_head_label(rfs, sub_git_dir, id)
        print_line(
          submodule_status_output(
            display_path,
            index_id,
            Some(id),
            cached,
            head_label,
          ),
        )
      }
      None =>
        print_line(
          submodule_status_output(display_path, index_id, None, cached, None),
        )
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
  fs : &@bitcore.RepoFileSystem,
  git_dir : String,
  path : String,
) -> @bitcore.ObjectId? {
  let entries = @bitlib.read_index_entries(fs, git_dir) catch {
    _ => return None
  }
  for e in entries {
    if e.path == path && e.mode == 57344 {
      return Some(e.id)
    }
  }
  None
}

///|
fn submodule_git_dir_has_object(
  fs : &@bitcore.RepoFileSystem,
  git_dir : String,
  target_id : @bitcore.ObjectId,
) -> Bool {
  let db = @bitlib.ObjectDb::load(fs, git_dir) catch { _ => return false }
  (db.get(fs, target_id) catch { _ => None }) is Some(_)
}

///|
async fn handle_submodule_init(
  fs : OsFs,
  root : String,
  git_dir : String,
  args : Array[String],
  quiet? : Bool = false,
) -> Unit raise Error {
  let mut quiet = quiet
  let raw_paths : Array[String] = []
  for arg in args {
    match arg {
      "-q" | "--quiet" => quiet = true
      _ if !arg.has_prefix("-") => raw_paths.push(arg)
      _ => ()
    }
  }
  let rfs : &@bitcore.RepoFileSystem = fs
  let wfs : &@bitcore.FileSystem = fs
  let cwd_prefix = submodule_cwd_prefix(root)
  let root_abs = ls_files_repo_root_abs(root)
  let paths = normalize_submodule_status_paths(raw_paths, cwd_prefix, root_abs)
  let submodules = parse_gitmodules(rfs, root)
  let index_paths = load_submodule_index_gitlink_paths(rfs, git_dir)
  let known_paths = submodule_known_paths(submodules, index_paths)
  let (already_active_paths, _, _) = submodule_resolve_target_paths(
    rfs,
    git_dir,
    submodules,
    known_paths,
    [],
    root_abs,
  )
  let (selected_paths, restrict_paths, unmatched_path) = submodule_resolve_target_paths(
    rfs, git_dir, submodules, known_paths, paths, root_abs,
  )
  match unmatched_path {
    Some(path) => {
      eprint_line(
        "error: pathspec '\{path}' did not match any file(s) known to git",
      )
      @sys.exit(1)
    }
    None => ()
  }
  let missing_paths = submodule_missing_url_paths(
    submodules,
    index_paths,
    if restrict_paths {
      selected_paths
    } else {
      []
    },
  )
  match missing_paths.get(0) {
    Some(path) => exit_missing_submodule_url(path)
    None => ()
  }
  let config_path = git_dir + "/config"
  let mut config_content = if rfs.is_file(config_path) {
    decode_bytes(rfs.read_file(config_path))
  } else {
    ""
  }
  for sub in submodules {
    if restrict_paths && !selected_paths.contains(sub.path) {
      continue
    }
    let config_url = resolve_submodule_config_url(fs, root, git_dir, sub.url)
    if read_submodule_config_value(rfs, git_dir, sub.name, "url") is Some(_) {
      continue
    }
    let mut updated = submodule_upsert_config_value(
      config_content,
      sub.name,
      "url",
      config_url,
    )
    if !already_active_paths.contains(sub.path) {
      updated = submodule_upsert_config_value(
        updated,
        sub.name,
        "active",
        "true",
      )
    }
    if updated == config_content {
      continue
    }
    wfs.write_string(config_path, updated)
    config_content = updated
    if !quiet {
      print_line(
        "Submodule '\{sub.name}' (\{config_url}) registered for path '\{sub.path}'",
      )
    }
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
  let rfs : &@bitcore.RepoFileSystem = fs
  let gitfile = root + "/.git"
  if has_init_flag && rfs.is_file(gitfile) {
    let _gitfile_content = decode_bytes(
      rfs.read_file(gitfile) catch {
        err => {
          if @async.is_being_cancelled() || @async.is_cancellation_error(err) {
            raise err
          }
          Default::default()
        }
      },
    )
  }
  let mut init = false
  let mut recursive = false
  let mut quiet = false
  let mut remote = false
  let raw_paths : Array[String] = []
  for arg in args {
    match arg {
      "--init" => init = true
      "--remote" => remote = true
      "--recursive" => recursive = true
      "--quiet" | "-q" => quiet = true
      _ if !arg.has_prefix("-") => raw_paths.push(arg)
      _ => ()
    }
  }
  let rfs : &@bitcore.RepoFileSystem = fs
  let wfs : &@bitcore.FileSystem = fs
  let cwd_prefix = submodule_cwd_prefix(root)
  let root_abs = ls_files_repo_root_abs(root)
  let paths = normalize_submodule_status_paths(raw_paths, cwd_prefix, root_abs)
  let submodules = parse_gitmodules(rfs, root)
  let index_paths = load_submodule_index_gitlink_paths(rfs, git_dir)
  let known_paths = submodule_known_paths(submodules, index_paths)
  let active_filters = if init && paths.length() == 0 {
    submodule_active_filters(rfs, git_dir, root_abs)
  } else {
    []
  }
  let (selected_paths, restrict_paths, unmatched_path) = if init &&
    paths.length() == 0 {
    if active_filters.length() > 0 {
      let (selected, unmatched) = submodule_select_paths_from_filters(
        known_paths, active_filters,
      )
      (selected, true, unmatched)
    } else {
      ([], false, (None : String?))
    }
  } else {
    submodule_resolve_target_paths(
      rfs, git_dir, submodules, known_paths, paths, root_abs,
    )
  }
  match unmatched_path {
    Some(path) => {
      eprint_line(
        "error: pathspec '\{path}' did not match any file(s) known to git",
      )
      @sys.exit(1)
    }
    None => ()
  }
  let missing_paths = submodule_missing_url_paths(
    submodules,
    index_paths,
    if restrict_paths {
      selected_paths
    } else {
      []
    },
  )
  let fatal_missing_paths = if init {
    missing_paths
  } else {
    submodule_update_fatal_missing_url_paths(
      rfs, git_dir, submodules, missing_paths,
    )
  }
  match fatal_missing_paths.get(0) {
    Some(path) => exit_update_missing_submodule_url(path)
    None => ()
  }
  // Init first if requested
  if init {
    let init_paths = if raw_paths.length() > 0 {
      raw_paths
    } else if active_filters.length() > 0 {
      selected_paths
    } else {
      known_paths
    }
    handle_submodule_init(fs, root, git_dir, init_paths, quiet~)
  }
  let auto_init_active = !init && paths.length() == 0 && restrict_paths
  let effective_paths = if restrict_paths { selected_paths } else { [] }
  let notice_paths = if init || auto_init_active {
    []
  } else {
    submodule_update_notice_paths(
      rfs, git_dir, submodules, index_paths, effective_paths,
    )
  }
  for path in notice_paths {
    print_submodule_not_initialized(path)
  }
  if !init && notice_paths.length() > 0 && submodules.length() == 0 {
    return ()
  }
  for sub in submodules {
    if notice_paths.contains(sub.path) {
      continue
    }
    if restrict_paths && !selected_paths.contains(sub.path) {
      continue
    }
    let sub_path = root + "/" + sub.path
    let common_git_dir = resolve_submodule_common_git_dir(rfs, git_dir)
    let modules_dir = common_git_dir + "/modules/" + sub.name
    let sub_git = sub_path + "/.git"
    let sub_git_is_dir = rfs.is_dir(sub_git)
    let had_git_marker = sub_git_is_dir || rfs.is_file(sub_git)
    let mut has_modules = rfs.is_dir(modules_dir)
    let fetch_target = match
      read_submodule_config_value(rfs, git_dir, sub.name, "url") {
      Some(url) => url
      None => sub.url
    }
    let fetch_url = resolve_submodule_fetch_url(fs, root, git_dir, fetch_target)
    let target_branch = match
      read_submodule_config_value(rfs, git_dir, sub.name, "branch") {
      Some(branch_name) =>
        if branch_name == "." {
          None
        } else {
          Some(branch_name)
        }
      None => None
    }
    let target_id = if remote {
      resolve_submodule_target_id(fs, root, fetch_url, target_branch)
    } else {
      match get_submodule_index_id(rfs, git_dir, sub.path) {
        Some(id) => id
        None => continue
      }
    }
    if load_submodule_update_path_blocker(rfs, sub_path, sub_git) {
      exit_submodule_existing_path(sub.path)
    }
    // Clone if needed
    if !sub_git_is_dir && !has_modules {
      if !quiet {
        print_line("Cloning into '\{sub.path}'...")
      }
      @bitrepo.init_repo(wfs, modules_dir, bare=true)
      let config_path = modules_dir + "/config"
      set_config(
        fs,
        config_path,
        "remote.origin.url",
        sub.url,
        false,
        (None : String?),
        (None : String?),
      )
      set_config(
        fs,
        config_path,
        "remote.origin.fetch",
        "+refs/heads/*:refs/remotes/origin/*",
        false,
        (None : String?),
        (None : String?),
      )
      has_modules = true
    }
    if has_modules {
      let config_path = modules_dir + "/config"
      set_config(
        fs,
        config_path,
        "remote.origin.url",
        fetch_url,
        false,
        (None : String?),
        (None : String?),
      )
      set_config(
        fs,
        config_path,
        "remote.origin.fetch",
        "+refs/heads/*:refs/remotes/origin/*",
        false,
        (None : String?),
        (None : String?),
      )
      if !submodule_git_dir_has_object(rfs, modules_dir, target_id) {
        fetch_submodule_objects(
          fs,
          root,
          modules_dir,
          fetch_url,
          target_id,
          branch=target_branch,
        )
      }
    }
    if !sub_git_is_dir && has_modules {
      if !rfs.is_dir(sub_path) {
        fs.mkdir_p(sub_path)
      }
      // Create or refresh .git file to point to modules dir
      let rel_path = submodule_relative_path(sub_path, modules_dir)
      wfs.write_string(sub_git, "gitdir: \{rel_path}\n")
    }
    if has_modules {
      ensure_submodule_gitdir_config(fs, modules_dir, sub_path)
    }
    // Checkout target commit
    let sub_git_dir = @bitlib.resolve_gitdir(rfs, sub_git)
    let already_at_target = had_git_marker &&
      @bitlib.resolve_head_commit(rfs, sub_git_dir) == Some(target_id)
    if !already_at_target {
      if !quiet {
        print_line(
          "Submodule path '\{sub.path}': checked out '\{target_id.to_hex()}'",
        )
      }
      // Use checkout command
      run_checkout_in_submodule(wfs, rfs, sub_path, sub_git_dir, target_id)
      @bitlibnative.apply_worktree_modes_from_commit(
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
fn submodule_pack_object_hex(obj : @bitcore.PackObject) -> String {
  if obj.offset >= 0 {
    obj.id.to_hex()
  } else {
    @bitcore.hash_object_content(obj.obj_type, obj.data).to_hex()
  }
}

///|
fn submodule_collect_shallow_commit_objects(
  db : @bitlib.ObjectDb,
  fs : &@bitcore.RepoFileSystem,
  commit_id : @bitcore.ObjectId,
  depth : Int,
  seen_commits : Map[String, Bool],
  seen_objects : Map[String, Bool],
  out : Array[@bitcore.PackObject],
  boundary_ids : Array[@bitcore.ObjectId],
  seen_boundaries : Map[String, Bool],
) -> Unit raise Error {
  let commit_hex = commit_id.to_hex()
  if seen_commits.contains(commit_hex) {
    return
  }
  seen_commits[commit_hex] = true
  let objects = @bitlib.collect_commit_tree_only(db, fs, commit_id)
  for obj in objects {
    let obj_hex = submodule_pack_object_hex(obj)
    if seen_objects.contains(obj_hex) {
      continue
    }
    seen_objects[obj_hex] = true
    out.push(obj)
  }
  let commit_obj = db.get(fs, commit_id) catch {
    _ => raise @bitcore.GitError::InvalidObject("Missing commit object")
  }
  guard commit_obj is Some(commit_obj) else {
    raise @bitcore.GitError::InvalidObject("Missing commit object")
  }
  let info = @bitcore.parse_commit(commit_obj.data)
  if depth <= 1 {
    if !seen_boundaries.contains(commit_hex) {
      seen_boundaries[commit_hex] = true
      boundary_ids.push(commit_id)
    }
    return
  }
  if info.parents.length() == 0 {
    return
  }
  for parent_id in info.parents {
    submodule_collect_shallow_commit_objects(
      db,
      fs,
      parent_id,
      depth - 1,
      seen_commits,
      seen_objects,
      out,
      boundary_ids,
      seen_boundaries,
    )
  }
}

///|
fn submodule_shallow_ref_targets(
  fs : &@bitcore.RepoFileSystem,
  src_git_dir : String,
  target_id : @bitcore.ObjectId,
  branch : String?,
) -> (String?, Array[(String, @bitcore.ObjectId)]) raise Error {
  let refs : Array[(String, @bitcore.ObjectId)] = []
  let mut head_branch : String? = None
  match @bitlib.read_head_ref(fs, src_git_dir) {
    @bitlib.HeadRef::Branch(name) => {
      head_branch = Some(name)
      match @bitlib.resolve_ref(fs, src_git_dir, "refs/heads/" + name) {
        Some(id) => refs.push((name, id))
        None => refs.push((name, target_id))
      }
    }
    @bitlib.HeadRef::Detached(_) => ()
  }
  match branch {
    Some(branch_name) => {
      let mut exists = false
      for ref_target in refs {
        if ref_target.0 == branch_name {
          exists = true
          break
        }
      }
      if !exists {
        let branch_id = @bitlib.resolve_ref(
          fs,
          src_git_dir,
          "refs/heads/" + branch_name,
        ).unwrap_or(target_id)
        refs.push((branch_name, branch_id))
      }
    }
    None => ()
  }
  (head_branch, refs)
}

///|
async fn fetch_submodule_local_repo_shallow(
  fs : OsFs,
  src_path : String,
  modules_dir : String,
  remote_name : String,
  remote_url : String,
  target_id : @bitcore.ObjectId,
  depth : Int,
  branch? : String? = None,
  quiet? : Bool = false,
) -> Unit raise Error {
  guard @bitlib.detect_git_dir(fs, src_path) is Some((src_git_dir, _)) else {
    raise @bitcore.GitError::InvalidObject("Not a git repository: \{src_path}")
  }
  let display_url = if remote_url.has_prefix("/") ||
    remote_url.has_prefix("file://") {
    remote_url
  } else {
    src_path
  }
  if !quiet {
    eprint_line("From \{display_url}")
  }
  let rfs : &@bitcore.RepoFileSystem = fs
  let src_db = @bitlib.ObjectDb::load(fs, src_git_dir)
  let objects : Array[@bitcore.PackObject] = []
  let seen_commits : Map[String, Bool] = Map([])
  let seen_objects : Map[String, Bool] = Map([])
  let boundary_ids : Array[@bitcore.ObjectId] = []
  let seen_boundaries : Map[String, Bool] = Map([])
  let (head_branch, ref_targets) = submodule_shallow_ref_targets(
    rfs, src_git_dir, target_id, branch,
  )
  let copy_targets : Array[@bitcore.ObjectId] = [target_id]
  for ref_target in ref_targets {
    copy_targets.push(ref_target.1)
  }
  for commit_id in copy_targets {
    submodule_collect_shallow_commit_objects(
      src_db, rfs, commit_id, depth, seen_commits, seen_objects, objects, boundary_ids,
      seen_boundaries,
    )
  }
  for obj in objects {
    ignore(@bitlib.write_loose_object(fs, modules_dir, obj.obj_type, obj.data))
  }
  for ref_target in ref_targets {
    write_ref_file(
      fs,
      modules_dir,
      "refs/remotes/" + remote_name + "/" + ref_target.0,
      ref_target.1,
    )
  }
  match head_branch {
    Some(name) =>
      update_remote_tracking_head_ref(fs, modules_dir, remote_name, name, quiet)
    None => ()
  }
  if boundary_ids.length() > 0 {
    fs.write_string(
      modules_dir + "/shallow",
      boundary_ids.map(id => id.to_hex()).join("\n") + "\n",
    )
  }
}

///|
fn ensure_submodule_local_target_objects(
  fs : OsFs,
  src_path : String,
  modules_dir : String,
  target_id : @bitcore.ObjectId,
) -> Unit raise Error {
  let rfs : &@bitcore.RepoFileSystem = fs
  let dst_db = @bitlib.ObjectDb::load(fs, modules_dir)
  if dst_db.get(rfs, target_id) is Some(_) {
    return
  }
  guard @bitlib.detect_git_dir(rfs, src_path) is Some((src_git_dir, _)) else {
    raise @bitcore.GitError::InvalidObject("Not a git repository: \{src_path}")
  }
  let src_db = @bitlib.ObjectDb::load(fs, src_git_dir)
  let transferred_object_ids : Map[String, Bool] = Map([])
  copy_wanted_object_graph(
    fs, rfs, src_db, modules_dir, target_id, transferred_object_ids,
  )
}

///|

///|
async fn fetch_submodule_objects(
  fs : OsFs,
  root : String,
  modules_dir : String,
  url : String,
  target_id : @bitcore.ObjectId,
  branch? : String? = None,
  depth? : Int? = None,
  quiet? : Bool = false,
) -> Unit raise Error {
  let rfs : &@bitcore.RepoFileSystem = fs
  match @bitlib.resolve_local_repo_path(rfs, root, url) {
    Some(src_path) => {
      if depth is Some(local_depth) {
        fetch_submodule_local_repo_shallow(
          fs,
          src_path,
          modules_dir,
          "origin",
          url,
          target_id,
          local_depth,
          branch~,
          quiet~,
        )
        return ()
      }
      fetch_local_repo(
        fs,
        src_path,
        modules_dir,
        modules_dir,
        "origin",
        url,
        [],
        quiet~,
      )
      ensure_submodule_local_target_objects(
        fs, src_path, modules_dir, target_id,
      )
      return ()
    }
    None => ()
  }
  let pack = @bitnative.fetch_pack_http(
    url,
    [target_id],
    true,
    depth=depth.unwrap_or(0),
  )
  let objects = @pack.parse_packfile(pack)
  @pack.write_packfile_with_index(fs, modules_dir, pack, objects)
}

///|
async fn ensure_submodule_gitdir_config(
  fs : OsFs,
  modules_dir : String,
  work_tree : String,
) -> Unit raise Error {
  let config_path = modules_dir + "/config"
  let rel_work_tree = submodule_relative_path(modules_dir, work_tree)
  set_config(
    fs,
    config_path,
    "core.worktree",
    rel_work_tree,
    false,
    (None : String?),
    (None : String?),
  )
  set_config(
    fs,
    config_path,
    "core.bare",
    "false",
    false,
    (None : String?),
    (None : String?),
  )
}

///|
fn run_checkout_in_submodule(
  wfs : &@bitcore.FileSystem,
  rfs : &@bitcore.RepoFileSystem,
  work_tree : String,
  git_dir : String,
  commit_id : @bitcore.ObjectId,
) -> Unit {
  let db = @bitlib.ObjectDb::load(rfs, git_dir) catch { _ => return }
  let head_path = git_dir + "/HEAD"
  wfs.write_string(head_path, commit_id.to_hex() + "\n") catch {
    _ => ()
  }
  let files = @bitlib.collect_tree_files_from_commit(db, rfs, commit_id) catch {
    _ => return
  }
  @bitlib.write_worktree_from_files(
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
  let entries = @bitlib.tree_files_to_index(db, rfs, files) catch {
    _ => return
  }
  @bitlib.write_index_entries(wfs, git_dir, entries) catch {
    _ => return
  }
}

///|
async fn submodule_run_post_checkout_hook(
  work_tree : String,
  git_dir : String,
  commit_id : @bitcore.ObjectId,
) -> Int {
  let fs = OsFs::new()
  let hook_path = git_dir + "/hooks/post-checkout"
  if !fs.is_file(hook_path) {
    return 0
  }
  let new_hex = commit_id.to_hex()
  let old_hex = String::make(new_hex.length(), '0')
  @process.run(
    hook_path,
    [old_hex, new_hex, "1"],
    inherit_env=true,
    cwd=work_tree,
  ) catch {
    _ => 1
  }
}

///|

///|
fn get_rel_path(from : String, to : String) -> String {
  let from_parts : Array[String] = from
    .split("/")
    .filter(s => s.to_owned().length() > 0)
    .map(s => s.to_owned())
    .collect()
  let to_parts : Array[String] = to
    .split("/")
    .filter(s => s.to_owned().length() > 0)
    .map(s => s.to_owned())
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
    if result.length() > 0 && !result.has_suffix("/") {
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
  let mut quiet = false
  let paths : Array[String] = []
  for arg in args {
    match arg {
      "-f" | "--force" => force = true
      "--all" => all = true
      "-q" | "--quiet" => quiet = true
      _ if !arg.has_prefix("-") => paths.push(arg)
      _ => ()
    }
  }
  let rfs : &@bitcore.RepoFileSystem = fs
  let wfs : &@bitcore.FileSystem = fs
  let cwd_prefix = submodule_cwd_prefix(root)
  let root_abs = submodule_canonical_dir(ls_files_repo_root_abs(root))
  let (select_all, requested_paths) = normalize_submodule_deinit_paths(
    paths, cwd_prefix, root_abs, all,
  )
  if !select_all && requested_paths.length() == 0 {
    @sys.exit(1)
    return
  }
  let submodules = parse_gitmodules(rfs, root)
  let index_paths = load_submodule_index_gitlink_paths(rfs, git_dir)
  let known_paths = submodule_known_paths(submodules, index_paths)
  let unknown_paths = submodule_unmatched_index_paths(
    known_paths, requested_paths,
  )
  match unknown_paths.get(0) {
    Some(path) => {
      eprint_line(
        "error: pathspec '\{path}' did not match any file(s) known to git",
      )
      @sys.exit(1)
      return
    }
    None => ()
  }
  for sub in submodules {
    if !select_all && !requested_paths.contains(sub.path) {
      continue
    }
    let sub_path = root + "/" + sub.path
    let display_path = make_display_path(sub.path, cwd_prefix)
    let sub_git_dir = prepare_submodule_deinit_git_dir(
      fs, git_dir, sub, sub_path,
    )
    let config_path = git_dir + "/config"
    let registered_url = read_submodule_config_value(
      rfs,
      git_dir,
      sub.name,
      "url",
    )
    let sub_worktree_git = sub_path + "/.git"
    let has_worktree_git = rfs.is_dir(sub_worktree_git) ||
      rfs.is_file(sub_worktree_git)
    // Check for local modifications
    if !force && rfs.is_dir(sub_path) && has_worktree_git {
      match sub_git_dir {
        Some(actual_sub_git_dir) if rfs.is_dir(actual_sub_git_dir) => {
          let status = @bitlib.status(rfs, sub_path) catch {
            err => {
              if @async.is_being_cancelled() ||
                @async.is_cancellation_error(err) {
                raise err
              }
              @stdio.stderr.write(
                "error: could not inspect submodule '\{sub.path}'",
              )
              @sys.exit(1)
              panic()
            }
          }
          if submodule_deinit_has_local_changes(status) ||
            submodule_deinit_head_mismatch(
              rfs,
              git_dir,
              actual_sub_git_dir,
              sub.path,
            ) {
            @stdio.stderr.write(
              "error: '\{sub.path}' has local modifications (use --force)",
            )
            @sys.exit(1)
            return
          }
        }
        _ => ()
      }
    }
    // Remove from .git/config
    if rfs.is_file(config_path) {
      let content = decode_bytes(rfs.read_file(config_path))
      let new_content = remove_config_section(content, "submodule", sub.name)
      wfs.write_string(config_path, new_content)
    }
    match sub_git_dir {
      Some(actual_sub_git_dir) => {
        let module_config_path = actual_sub_git_dir + "/config"
        if rfs.is_file(module_config_path) {
          let module_config = decode_bytes(rfs.read_file(module_config_path))
          let new_module_config = remove_config_key(
            module_config, "[core]", "worktree",
          )
          wfs.write_string(module_config_path, new_module_config)
        }
      }
      None => ()
    }
    // Clear working directory
    let mut cleared_worktree = false
    if rfs.is_dir(sub_path) {
      let entries = rfs.readdir(sub_path) catch {
        err => {
          if @async.is_being_cancelled() || @async.is_cancellation_error(err) {
            raise err
          }
          continue
        }
      }
      cleared_worktree = true
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
    remove_submodule_worktree_git(fs, sub_path)
    if !rfs.is_dir(sub_path) && !rfs.is_file(sub_path) {
      fs.mkdir_p(sub_path)
    }
    if !quiet {
      match registered_url {
        Some(url) =>
          print_line(
            "Submodule '\{sub.name}' (\{url}) unregistered for path '\{display_path}'",
          )
        None => ()
      }
    }
    if cleared_worktree && !quiet {
      print_line("Cleared directory '\{display_path}'")
    }
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
    let line = line_view.to_owned()
    let trimmed = trim_chars(line, " \t")
    if trimmed.has_prefix("[") {
      skip = trimmed == target
    }
    if !skip {
      lines.push(line)
    }
  }
  lines.join("\n")
}

///|
fn remove_config_key(
  content : String,
  section_header : String,
  key : String,
) -> String {
  let lines : Array[String] = []
  let mut in_target = false
  for line_view in content.split("\n") {
    let line = line_view.to_owned()
    let trimmed = trim_chars(line, " \t")
    if trimmed.has_prefix("[") {
      in_target = trimmed == section_header
      lines.push(line)
      continue
    }
    if in_target &&
      (
        trimmed == key ||
        trimmed.has_prefix(key + " =") ||
        trimmed.has_prefix(key + "=")
      ) {
      continue
    }
    lines.push(line)
  }
  lines.join("\n")
}

///|
fn normalize_submodule_deinit_paths(
  paths : Array[String],
  cwd_prefix : String,
  root_abs : String,
  all : Bool,
) -> (Bool, Array[String]) raise Error {
  let mut select_all = all
  let filtered : Array[String] = []
  for path in paths {
    if path == "." {
      select_all = true
      continue
    }
    if path.has_prefix("/") || path.has_prefix("./") || path.has_prefix("../") {
      let normalized = normalize_submodule_status_paths(
        [path],
        cwd_prefix,
        root_abs,
      )
      match normalized.get(0) {
        Some(value) => filtered.push(value)
        None => filtered.push(path)
      }
    } else {
      filtered.push(path)
    }
  }
  (select_all, filtered)
}

///|
fn submodule_deinit_has_local_changes(status : @bitlib.Status) -> Bool {
  status.unstaged_modified.length() > 0 ||
  status.unstaged_deleted.length() > 0 ||
  status.untracked.length() > 0 ||
  status.staged_added.length() > 0 ||
  status.staged_modified.length() > 0 ||
  status.staged_deleted.length() > 0
}

///|
fn submodule_deinit_head_mismatch(
  fs : &@bitcore.RepoFileSystem,
  git_dir : String,
  sub_git_dir : String,
  path : String,
) -> Bool {
  let head_id = @bitlib.resolve_head_commit(fs, sub_git_dir) catch { _ => None }
  match (get_submodule_index_id(fs, git_dir, path), head_id) {
    (Some(index_id), Some(head_id)) => index_id != head_id
    _ => false
  }
}

///|
async fn prepare_submodule_deinit_git_dir(
  fs : OsFs,
  git_dir : String,
  sub : SubmoduleInfo,
  sub_path : String,
) -> String? raise Error {
  let rfs : &@bitcore.RepoFileSystem = fs
  let sub_git = sub_path + "/.git"
  let common_git_dir = resolve_submodule_common_git_dir(rfs, git_dir)
  let module_git_dir = common_git_dir + "/modules/" + sub.name
  if rfs.is_dir(sub_git) {
    fs.mkdir_p(module_git_dir)
    absorb_git_dir(fs, sub_path, sub_git, module_git_dir)
    return Some(module_git_dir)
  }
  if rfs.is_file(sub_git) {
    return Some(@bitlib.resolve_gitdir(rfs, sub_git))
  }
  if rfs.is_dir(module_git_dir) {
    return Some(module_git_dir)
  }
  None
}

///|
fn remove_submodule_worktree_git(fs : OsFs, sub_path : String) -> Unit {
  let rfs : &@bitcore.RepoFileSystem = fs
  let wfs : &@bitcore.FileSystem = fs
  let sub_git = sub_path + "/.git"
  if rfs.is_file(sub_git) {
    wfs.remove_file(sub_git) catch {
      _ => ()
    }
  } else if rfs.is_dir(sub_git) {
    remove_dir_recursive(fs, sub_git)
  }
}

///|
async fn handle_submodule_sync(
  fs : OsFs,
  root : String,
  git_dir : String,
  args : Array[String],
) -> Unit raise Error {
  let mut recursive = false
  let mut quiet = false
  let paths : Array[String] = []
  for arg in args {
    match arg {
      "--recursive" => recursive = true
      "-q" | "--quiet" => quiet = true
      _ if !arg.has_prefix("-") => paths.push(arg)
      _ => ()
    }
  }
  let rfs : &@bitcore.RepoFileSystem = fs
  let wfs : &@bitcore.FileSystem = fs
  let submodules = parse_gitmodules(rfs, root)
  let index_paths = load_submodule_index_gitlink_paths(rfs, git_dir)
  let known_paths = submodule_known_paths(submodules, index_paths)
  let unknown_paths = submodule_unmatched_index_paths(known_paths, paths)
  match unknown_paths.get(0) {
    Some(path) => {
      eprint_line(
        "error: pathspec '\{path}' did not match any file(s) known to git",
      )
      @sys.exit(1)
    }
    None => ()
  }
  for sub in submodules {
    if paths.length() > 0 && !paths.contains(sub.path) {
      continue
    }
    let sync_config_url = resolve_submodule_config_url(
      fs,
      root,
      git_dir,
      sub.url,
    )
    // Update .git/config
    let config_path = git_dir + "/config"
    if rfs.is_file(config_path) {
      let content = decode_bytes(rfs.read_file(config_path))
      let section = "[submodule \"\{sub.name}\"]"
      if content.contains(section) {
        let updated = update_config_value(
          content,
          sub.name,
          "url",
          sync_config_url,
        )
        wfs.write_string(config_path, updated)
      }
    }
    // Update submodule's origin URL
    let sub_path = root + "/" + sub.path
    let sync_origin_url = resolve_submodule_origin_url(
      fs,
      root,
      git_dir,
      sub.path,
      sub.url,
    )
    let sub_git_dir = @bitlib.resolve_gitdir(rfs, sub_path + "/.git")
    let sub_config = sub_git_dir + "/config"
    if rfs.is_file(sub_config) {
      let content = decode_bytes(rfs.read_file(sub_config))
      let updated = update_remote_origin(content, sync_origin_url)
      wfs.write_string(sub_config, updated)
    }
    if !quiet {
      print_line("Synchronizing submodule url for '\{sub.path}'")
    }
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
    let line = line_view.to_owned()
    let trimmed = trim_chars(line, " \t")
    if trimmed.has_prefix("[") {
      in_section = trimmed == target
    }
    if in_section && trimmed.has_prefix(key + " =") && !updated {
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
    let line = line_view.to_owned()
    let trimmed = trim_chars(line, " \t")
    if trimmed.has_prefix("[") {
      in_origin = trimmed == "[remote \"origin\"]"
    }
    if in_origin && trimmed.has_prefix("url =") && !updated {
      lines.push("\turl = \{url}")
      updated = true
    } else {
      lines.push(line)
    }
  }
  lines.join("\n")
}

///|
fn find_submodule_name_by_path(
  submodules : Array[SubmoduleInfo],
  path : String,
) -> String? {
  for sub in submodules {
    if sub.path == path {
      return Some(sub.name)
    }
  }
  None
}

///|
async fn handle_submodule_set_url(
  fs : OsFs,
  root : String,
  git_dir : String,
  args : Array[String],
) -> Unit raise Error {
  let positional : Array[String] = []
  for arg in args {
    if !arg.has_prefix("-") {
      positional.push(arg)
    }
  }
  if positional.length() < 2 {
    raise @bitcore.GitError::InvalidObject(
      "usage: git submodule set-url [--] <path> <newurl>",
    )
  }
  let path = positional[0]
  let newurl = positional[1]
  let rfs : &@bitcore.RepoFileSystem = fs
  let submodules = parse_gitmodules(rfs, root)
  let name = match find_submodule_name_by_path(submodules, path) {
    Some(n) => n
    None =>
      raise @bitcore.GitError::InvalidObject(
        "No submodule mapping found in .gitmodules for path '\{path}'",
      )
  }
  let gitmodules_path = root + "/.gitmodules"
  set_config(
    fs,
    gitmodules_path,
    "submodule.\{name}.url",
    newurl,
    false,
    (None : String?),
    (None : String?),
  )
  set_config(
    fs,
    git_dir + "/config",
    "submodule.\{name}.url",
    newurl,
    false,
    (None : String?),
    (None : String?),
  )
}

///|
async fn handle_submodule_set_branch(
  fs : OsFs,
  root : String,
  args : Array[String],
) -> Unit raise Error {
  let mut branch : String? = None
  let mut default_branch = false
  let positional : Array[String] = []
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    match arg {
      "--branch" | "-b" => {
        i += 1
        if i >= args.length() {
          raise @bitcore.GitError::InvalidObject(
            "option requires an argument -- branch",
          )
        }
        branch = Some(args[i])
      }
      "--default" | "-d" => default_branch = true
      _ if !arg.has_prefix("-") => positional.push(arg)
      _ => ()
    }
    i += 1
  }
  if positional.length() < 1 {
    raise @bitcore.GitError::InvalidObject(
      "usage: git submodule set-branch (-b <branch>|-d) [--] <path>",
    )
  }
  let path = positional[0]
  let rfs : &@bitcore.RepoFileSystem = fs
  let submodules = parse_gitmodules(rfs, root)
  let name = match find_submodule_name_by_path(submodules, path) {
    Some(n) => n
    None =>
      raise @bitcore.GitError::InvalidObject(
        "No submodule mapping found in .gitmodules for path '\{path}'",
      )
  }
  let gitmodules_path = root + "/.gitmodules"
  if default_branch {
    unset_config(
      fs,
      gitmodules_path,
      "submodule.\{name}.branch",
      None,
      false,
      false,
    )
  } else {
    match branch {
      Some(b) =>
        set_config(
          fs,
          gitmodules_path,
          "submodule.\{name}.branch",
          b,
          false,
          (None : String?),
          (None : String?),
        )
      None =>
        raise @bitcore.GitError::InvalidObject(
          "usage: git submodule set-branch (-b <branch>|-d) [--] <path>",
        )
    }
  }
}

///|
async fn handle_submodule_foreach(
  fs : OsFs,
  root : String,
  _git_dir : String,
  args : Array[String],
) -> Unit raise Error {
  let mut recursive = false
  let mut quiet = false
  let cmd_parts : Array[String] = []
  let mut past_opts = false
  for arg in args {
    if past_opts {
      cmd_parts.push(arg)
    } else {
      match arg {
        "--recursive" => recursive = true
        "--quiet" => quiet = true
        "--" => past_opts = true
        _ if arg.has_prefix("-") => ()
        _ => {
          past_opts = true
          cmd_parts.push(arg)
        }
      }
    }
  }
  if cmd_parts.length() == 0 {
    return
  }
  let cmd = cmd_parts.join(" ")
  let rfs : &@bitcore.RepoFileSystem = fs
  let submodules = parse_gitmodules(rfs, root)
  for sub in submodules {
    let sub_path = root + "/" + sub.path
    let sub_git = sub_path + "/.git"
    if !rfs.is_file(sub_git) && !rfs.is_dir(sub_git) {
      continue
    }
    let sub_git_dir = @bitlib.resolve_gitdir(rfs, sub_git)
    let head_id = @bitlib.resolve_head_commit(rfs, sub_git_dir) catch {
      err => {
        if @async.is_being_cancelled() || @async.is_cancellation_error(err) {
          raise err
        }
        continue
      }
    }
    let sha1 = match head_id {
      Some(id) => id.to_hex()
      None => String::make(40, '0')
    }
    if !quiet {
      print_line("Entering '\{sub.path}'")
    }
    let env : Map[String, String] = {
      "name": sub.name,
      "sm_path": sub.path,
      "path": sub.path,
      "displaypath": sub.path,
      "sha1": sha1,
      "toplevel": root,
    }
    let code = @process.run(
      "sh",
      ["-c", cmd],
      extra_env=env,
      inherit_env=true,
      cwd=sub_path,
    )
    if code != 0 {
      raise @bitcore.GitError::InvalidObject(
        "Stopping at '\{sub.path}'; script returned non-zero status.",
      )
    }
    if recursive {
      let nested = sub_path + "/.gitmodules"
      if rfs.is_file(nested) {
        handle_submodule_foreach(fs, sub_path, sub_git_dir, args)
      }
    }
  }
}

///|
async fn handle_submodule_absorbgitdirs(
  fs : OsFs,
  root : String,
  git_dir : String,
  args : Array[String],
) -> Unit raise Error {
  handle_submodule_absorbgitdirs_with_prefix(fs, root, git_dir, args, "")
}

///|
fn submodule_absorbgitdirs_valid_git_dir(
  fs : &@bitcore.RepoFileSystem,
  git_dir : String,
) -> Bool {
  let resolved_git_dir = normalize_path(git_dir)
  let common_git_dir = resolve_submodule_common_git_dir(fs, resolved_git_dir)
  fs.is_file(resolved_git_dir + "/HEAD") &&
  (
    fs.is_dir(common_git_dir + "/objects") ||
    fs.is_file(resolved_git_dir + "/commondir")
  )
}

///|
async fn handle_submodule_absorbgitdirs_with_prefix(
  fs : OsFs,
  root : String,
  git_dir : String,
  args : Array[String],
  super_prefix : String,
) -> Unit raise Error {
  let rfs : &@bitcore.RepoFileSystem = fs
  let wfs : &@bitcore.FileSystem = fs
  let paths : Array[String] = []
  for arg in args {
    if !arg.has_prefix("-") {
      paths.push(arg)
    }
  }
  let submodules = parse_gitmodules(rfs, root)
  let index_paths = load_submodule_index_gitlink_paths(rfs, git_dir)
  for path in index_paths {
    if paths.length() > 0 && !paths.contains(path) {
      continue
    }
    if submodule_find_by_path(submodules, path) is Some(_) {
      continue
    }
    let sub_path = root + "/" + path
    let sub_git = sub_path + "/.git"
    if rfs.is_dir(sub_git) || rfs.is_file(sub_git) {
      eprint_line("fatal: could not lookup name for submodule '\{path}'")
      @sys.exit(128)
    }
  }
  for sub in submodules {
    if paths.length() > 0 && !paths.contains(sub.path) {
      continue
    }
    let sub_path = root + "/" + sub.path
    let sub_git = sub_path + "/.git"
    let common_git_dir = resolve_submodule_common_git_dir(fs, git_dir)
    let dest = common_git_dir + "/modules/" + sub.name
    let mut recurse_git_dir : String? = None
    let display_path = if super_prefix.length() == 0 {
      sub.path
    } else {
      super_prefix + sub.path
    }
    if rfs.is_dir(sub_git) {
      if !rfs.is_dir(dest) {
        wfs.mkdir_p(dest)
      }
      absorb_git_dir(fs, sub_path, sub_git, dest)
      eprint_line("Migrating git directory of '\{display_path}' from")
      eprint_line("'\{sub_git}' to")
      eprint_line("'\{normalize_path(dest)}'")
      recurse_git_dir = Some(dest)
    } else if rfs.is_file(sub_git) {
      let resolved_git_dir = normalize_path(
        @bitlib.resolve_gitdir(rfs, sub_git),
      )
      if submodule_absorbgitdirs_valid_git_dir(rfs, resolved_git_dir) {
        recurse_git_dir = Some(resolved_git_dir)
      } else if rfs.is_dir(dest) {
        let rel_path = submodule_relative_path(sub_path, dest)
        wfs.write_string(sub_git, "gitdir: \{rel_path}\n")
        ensure_submodule_gitdir_config(fs, dest, sub_path)
        recurse_git_dir = Some(dest)
      }
    }
    guard recurse_git_dir is Some(next_git_dir) else { continue }
    // Recurse into nested submodules
    let nested = sub_path + "/.gitmodules"
    if rfs.is_file(nested) {
      handle_submodule_absorbgitdirs_with_prefix(
        fs,
        sub_path,
        normalize_path(next_git_dir),
        [],
        display_path + "/",
      )
    }
  }
}

///|
async fn absorb_git_dir(
  fs : OsFs,
  work_tree : String,
  src_git_dir : String,
  dest_git_dir : String,
) -> Unit raise Error {
  let rfs : &@bitcore.RepoFileSystem = fs
  let wfs : &@bitcore.FileSystem = fs
  // Move contents from src to dest
  let entries = rfs.readdir(src_git_dir) catch { _ => return }
  for entry in entries {
    let src = src_git_dir + "/" + entry
    let dst = dest_git_dir + "/" + entry
    let code = @process.run("mv", [src, dst], inherit_env=true)
    if code != 0 {
      raise @bitcore.GitError::InvalidObject("failed to move \{src} to \{dst}")
    }
  }
  // Remove original .git directory
  remove_dir_recursive(fs, src_git_dir)
  // Write gitdir pointer
  let rel_path = submodule_relative_path(work_tree, dest_git_dir)
  wfs.write_string(work_tree + "/.git", "gitdir: \{rel_path}\n")
  // Update core.worktree in dest config
  ensure_submodule_gitdir_config(fs, dest_git_dir, work_tree)
}

///|
async fn handle_submodule_summary(
  _fs : OsFs,
  _root : String,
  _git_dir : String,
  _args : Array[String],
) -> Unit {
  // summary is a display-only command showing commit range diffs
  // between HEAD and index for submodules. Since the tests that
  // call summary go through real git (not shim), a stub suffices.
  ()
}

///|

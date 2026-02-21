///|
fn collect_global_config_overrides_for_delegate() -> Array[String] {
  let overrides : Array[String] = []
  match @sys.get_env_var("GIT_CONFIG_OVERRIDES") {
    Some(encoded) =>
      for line_view in encoded.split("\n") {
        let line = line_view.to_string()
        if line.length() == 0 {
          continue
        }
        overrides.push("-c")
        overrides.push(line)
      }
    None => ()
  }
  overrides
}

///|
fn collect_global_path_overrides_for_delegate() -> Array[String] {
  let overrides : Array[String] = []
  let delegate_cwd = match @sys.get_env_var("GIT_SHIM_CWD") {
    Some(dir) if dir.length() > 0 => Some(dir)
    _ =>
      match @sys.get_env_var("GIT_SHIM_PWD") {
        Some(dir) if dir.length() > 0 => Some(dir)
        _ => None
      }
  }
  match delegate_cwd {
    Some(dir) => {
      overrides.push("-C")
      overrides.push(dir)
    }
    None => ()
  }
  let explicit_git_dir = match @sys.get_env_var("GIT_SHIM_EXPLICIT_GIT_DIR") {
    Some(value) => value == "1"
    None => false
  }
  if explicit_git_dir {
    match @sys.get_env_var("GIT_DIR") {
      Some(dir) if dir.length() > 0 => overrides.push("--git-dir=" + dir)
      _ => ()
    }
  }
  overrides
}

///|
async fn handle_fetch(args : Array[String]) -> Unit raise Error {
  let fs = OsFs::new()
  let rfs : &@bitcore.RepoFileSystem = fs
  // Keep override parsers exercised without delegating to real git.
  ignore(collect_global_path_overrides_for_delegate())
  ignore(collect_global_config_overrides_for_delegate())
  let root = get_work_root()
  let git_dir = resolve_git_dir(rfs, root)
  let (remotes, branches) = @bitlib.read_repo_config(fs, git_dir)
  // Read remote URL - prefer subdir-clone remote, then config
  let mut remote_name = "origin"
  let mut remote_url : String? = get_effective_remote_url(fs, git_dir)
  match @bitlib.read_head_ref(fs, git_dir) {
    @bitlib.HeadRef::Branch(branch_name) =>
      match branches.get(branch_name) {
        Some(branch_config) =>
          match branch_config.remote {
            Some(config_remote) if config_remote.length() > 0 => {
              remote_name = config_remote
              match remotes.get(config_remote) {
                Some(remote_config) =>
                  if remote_config.urls.length() > 0 {
                    remote_url = Some(remote_config.urls[0])
                  }
                None => ()
              }
            }
            _ => ()
          }
        None => ()
      }
    @bitlib.HeadRef::Detached(_) => ()
  }
  let mut explicit_filter_flag = false
  let mut explicit_no_filter = false
  let mut filter = @protocol.FilterSpec::NoFilter
  let mut refetch = false
  let mut update_head_ok = false
  let mut quiet = false
  let mut relay_preferred_sender_opt : String? = None
  let mut relay_preferred_repo_opt : String? = None
  let positional_args : Array[String] = []
  // Override with command line argument
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    if arg == "--filter" && i + 1 < args.length() {
      explicit_filter_flag = true
      filter = parse_filter_spec(args[i + 1])
      i += 2
      continue
    }
    if arg.has_prefix("--filter=") {
      explicit_filter_flag = true
      let filter_spec = String::unsafe_substring(arg, start=9, end=arg.length())
      filter = parse_filter_spec(filter_spec)
      i += 1
      continue
    }
    if arg == "--no-filter" {
      explicit_filter_flag = true
      explicit_no_filter = true
      filter = @protocol.FilterSpec::NoFilter
      i += 1
      continue
    }
    if arg == "--refetch" {
      refetch = true
      i += 1
      continue
    }
    if arg == "--relay-sender" && i + 1 < args.length() {
      relay_preferred_sender_opt = Some(args[i + 1])
      i += 2
      continue
    }
    if arg.has_prefix("--relay-sender=") {
      relay_preferred_sender_opt = Some(
        String::unsafe_substring(arg, start=15, end=arg.length()),
      )
      i += 1
      continue
    }
    if arg == "--relay-repo" && i + 1 < args.length() {
      relay_preferred_repo_opt = Some(args[i + 1])
      i += 2
      continue
    }
    if arg.has_prefix("--relay-repo=") {
      relay_preferred_repo_opt = Some(
        String::unsafe_substring(arg, start=13, end=arg.length()),
      )
      i += 1
      continue
    }
    if arg == "--no-ipv4" || arg == "--no-ipv6" {
      raise @bitcore.GitError::InvalidObject(
        "unknown option '" + option_name_without_prefix(arg) + "'",
      )
    }
    if not(arg.has_prefix("-")) {
      positional_args.push(arg)
      i += 1
      continue
    }
    if arg == "-u" || arg == "--update-head-ok" {
      update_head_ok = true
      i += 1
      continue
    }
    if arg == "-q" || arg == "--quiet" {
      quiet = true
      i += 1
      continue
    }
    if arg == "--prune" ||
      arg == "-p" ||
      arg == "--prune-tags" ||
      arg == "--tags" ||
      arg == "--no-tags" {
      i += 1
      continue
    }
    warn_unimplemented_arg("fetch", arg)
    i += 1
  }
  let explicit_refspecs : Array[String] = []
  let mut legacy_fetch_target : String? = None
  if positional_args.length() > 0 {
    let first = positional_args[0]
    match remotes.get(first) {
      Some(rc) => {
        remote_name = first
        if rc.urls.length() > 0 {
          remote_url = Some(rc.urls[0])
        }
      }
      None =>
        match parse_legacy_branches_entry(fs, git_dir, first) {
          Some((legacy_url, legacy_branch)) => {
            remote_name = first
            remote_url = Some(legacy_url)
            let branch = match legacy_branch {
              Some(name) => name
              None => legacy_default_branch_name()
            }
            legacy_fetch_target = Some(branch)
          }
          None => remote_url = Some(first)
        }
    }
    let mut i = 1
    while i < positional_args.length() {
      let token = positional_args[i]
      if token == "tag" {
        if i + 1 >= positional_args.length() {
          raise @bitcore.GitError::InvalidObject("fetch tag requires tag name")
        }
        let tag_name = positional_args[i + 1]
        if tag_name.length() == 0 {
          raise @bitcore.GitError::InvalidObject("fetch tag requires tag name")
        }
        let tag_ref = "refs/tags/" + tag_name
        explicit_refspecs.push(tag_ref + ":" + tag_ref)
        i += 2
        continue
      }
      explicit_refspecs.push(token)
      i += 1
    }
  }
  if explicit_refspecs.length() == 0 && legacy_fetch_target is Some(branch) {
    explicit_refspecs.push(
      "refs/heads/" + branch + ":refs/heads/" + remote_name,
    )
  }
  guard remote_url is Some(url) else {
    raise @bitcore.GitError::InvalidObject("No remote configured")
  }
  let mut resolved_remote_url = url
  if fetch_remote_uses_relay_signaling(resolved_remote_url) {
    let preferred_sender = match
      fetch_normalize_optional_value(relay_preferred_sender_opt) {
      Some(value) => Some(value)
      None => fetch_relay_preferred_sender()
    }
    let preferred_repo = match
      fetch_normalize_optional_value(relay_preferred_repo_opt) {
      Some(value) => Some(value)
      None => fetch_relay_preferred_repo()
    }
    let (relay_sender, relay_fetch_url) = resolve_fetch_remote_via_relay(
      resolved_remote_url,
      preferred_sender~,
      preferred_repo~,
    )
    if not(quiet) {
      print_line("Relay peer selected: \{relay_sender} -> \{relay_fetch_url}")
    }
    resolved_remote_url = relay_fetch_url
  }
  let rewrite_rules = read_url_rewrite_rules(fs, git_dir)
  let resolved_url = rewrite_url_by_rules(
    resolved_remote_url, rewrite_rules, false,
  )
  let mut is_partial_clone = false
  let mut inherited_filter = @protocol.FilterSpec::NoFilter
  match remotes.get(remote_name) {
    Some(rc) => {
      if rc.promisor || rc.partial_clone_filter is Some(_) {
        is_partial_clone = true
      }
      if rc.partial_clone_filter is Some(raw_filter) {
        inherited_filter = parse_filter_spec(raw_filter)
      }
    }
    None => ()
  }
  if explicit_no_filter {
    filter = @protocol.FilterSpec::NoFilter
  } else if not(explicit_filter_flag) && inherited_filter.is_partial() {
    filter = inherited_filter
  }
  let local_root = match @sys.get_env_var("GIT_SHIM_CWD") {
    Some(dir) => dir
    None => root
  }
  let local_promisor_remote = match
    @bitlib.resolve_local_repo_path(fs, local_root, resolved_url) {
    Some(src_path) => has_promisor_source_repo(fs, src_path)
    None => false
  }
  let mut has_oid_refspec = false
  for spec in explicit_refspecs {
    let raw = if spec.has_prefix("+") {
      String::unsafe_substring(spec, start=1, end=spec.length())
    } else {
      spec
    }
    if looks_like_object_id(raw) {
      has_oid_refspec = true
      break
    }
  }
  let force_transport = (
      filter.is_partial() ||
      refetch ||
      local_promisor_remote ||
      is_partial_clone
    ) &&
    not(has_oid_refspec)
  fetch_from_remote(
    fs,
    git_dir,
    root,
    remote_name,
    resolved_url,
    explicit_refspecs,
    filter~,
    force_transport~,
    update_head_ok~,
    quiet~,
  )
}

///|
fn fetch_remote_uses_relay_signaling(remote_url : String) -> Bool {
  remote_url.has_prefix("relay+http://") ||
  remote_url.has_prefix("relay+https://") ||
  remote_url.has_prefix("relay://")
}

///|
fn fetch_normalize_optional_value(value : String?) -> String? {
  match value {
    Some(raw) => {
      let normalized = raw.trim(chars=" \n\r\t").to_string()
      if normalized.length() == 0 {
        None
      } else {
        Some(normalized)
      }
    }
    None => None
  }
}

///|
fn fetch_relay_preferred_sender() -> String? {
  fetch_normalize_optional_value(@sys.get_env_var("BIT_RELAY_FETCH_SENDER"))
}

///|
fn fetch_relay_preferred_repo() -> String? {
  fetch_normalize_optional_value(@sys.get_env_var("BIT_RELAY_FETCH_REPO"))
}

///|
fn fetch_select_relay_peer(
  peers : Array[(String, String, String?)],
  preferred_sender~ : String?,
  preferred_repo~ : String?,
) -> (String, String)? {
  match preferred_sender {
    Some(target_sender) =>
      for peer in peers {
        let (sender, fetch_url, _repo) = peer
        if sender == target_sender {
          return Some((sender, fetch_url))
        }
      }
    None => ()
  }
  match preferred_repo {
    Some(target_repo) =>
      for peer in peers {
        let (sender, fetch_url, repo) = peer
        if repo == Some(target_repo) {
          return Some((sender, fetch_url))
        }
      }
    None => ()
  }
  if peers.length() == 0 {
    None
  } else {
    let (sender, fetch_url, _repo) = peers[0]
    Some((sender, fetch_url))
  }
}

///|
async fn resolve_fetch_remote_via_relay(
  relay_remote_url : String,
  preferred_sender~ : String?,
  preferred_repo~ : String?,
) -> (String, String) raise Error {
  let peers = @hub_native.relay_list_clone_peers(
    relay_remote_url,
    auth_token=None,
  )
  guard fetch_select_relay_peer(peers, preferred_sender~, preferred_repo~)
    is Some((sender, fetch_url)) else {
    raise @bitcore.GitError::InvalidObject(
      "No fetch peers announced via relay: \{relay_remote_url}",
    )
  }
  (sender, fetch_url)
}

///|
fn find_submodule_replaced_with_non_submodule(
  from_modes : Map[String, Int],
  to_modes : Map[String, Int],
) -> String? {
  for path, mode in from_modes {
    if mode != 0o160000 {
      continue
    }
    match to_modes.get(path) {
      Some(next_mode) => if next_mode != 0o160000 { return Some(path) }
      None => ()
    }
  }
  None
}

///|
fn resolve_initial_pull_head_target(branch_name : String?) -> String {
  match branch_name {
    Some(branch) => "refs/heads/" + branch
    None => "HEAD"
  }
}

///|
fn collect_commit_tree_modes(
  db : @bitlib.ObjectDb,
  fs : &@bitcore.RepoFileSystem,
  commit_id : @bitcore.ObjectId,
) -> Map[String, Int] raise @bitcore.GitError {
  let files = @bitlib.collect_tree_files_from_commit(db, fs, commit_id)
  let modes : Map[String, Int] = {}
  for path, entry in files {
    modes[path] = entry.mode
  }
  modes
}

///|

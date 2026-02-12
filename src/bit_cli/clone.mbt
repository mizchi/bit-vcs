///|
async fn handle_clone(args : Array[String]) -> Unit raise Error {
  let root = get_work_root()
  let mut url : String? = None
  let mut dest : String? = None
  let mut depth = 0
  let mut filter = @protocol.FilterSpec::NoFilter
  let mut has_filter_flag = false
  let mut recursive = false
  let mut bare = false
  let mut ref_spec : String? = None
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    if arg == "--depth" && i + 1 < args.length() {
      // Parse depth value
      let depth_str = args[i + 1]
      depth = @strconv.parse_int(depth_str) catch {
        err => {
          if @async.is_being_cancelled() || @async.is_cancellation_error(err) {
            raise err
          }
          0
        }
      }
      i += 2
      continue
    }
    if arg.has_prefix("--depth=") {
      let depth_str = String::unsafe_substring(arg, start=8, end=arg.length())
      depth = @strconv.parse_int(depth_str) catch {
        err => {
          if @async.is_being_cancelled() || @async.is_cancellation_error(err) {
            raise err
          }
          0
        }
      }
      i += 1
      continue
    }
    if arg == "--bare" {
      bare = true
      i += 1
      continue
    }
    if arg == "--recursive" {
      recursive = true
      i += 1
      continue
    }
    // Parse --filter option
    if arg == "--filter" && i + 1 < args.length() {
      has_filter_flag = true
      filter = parse_filter_spec(args[i + 1])
      i += 2
      continue
    }
    if arg.has_prefix("--filter=") {
      has_filter_flag = true
      let filter_str = String::unsafe_substring(arg, start=9, end=arg.length())
      filter = parse_filter_spec(filter_str)
      i += 1
      continue
    }
    if arg.has_prefix("-") {
      warn_unimplemented_arg("clone", arg)
      i += 1
      continue
    }
    if url is None {
      url = Some(arg)
    } else if dest is None {
      dest = Some(arg)
    }
    i += 1
  }
  guard url is Some(remote_url) else {
    raise @git.GitError::InvalidObject("repository URL required")
  }
  ignore(has_filter_flag)
  if recursive {
    @stdio.stderr.write("fatal: --recursive is not supported yet\n")
    @sys.exit(1)
  }
  // Check for ambiguity with local directories
  let fs = OsFs::new()
  match check_shorthand_ambiguity(remote_url, p => fs.is_dir(p)) {
    Some(conflict_path) =>
      raise @git.GitError::InvalidObject(
        "Ambiguous: '\{conflict_path}' exists locally. Use full URL or ./\{remote_url} for local path.",
      )
    None => ()
  }
  // Check for shorthand (user/repo, user/repo:path, or browser URL)
  match parse_github_shorthand(remote_url) {
    Some(Repo(github_url, refname)) => {
      // user/repo → normal clone from GitHub
      print_line("Shorthand: \{github_url}")
      url = Some(github_url)
      ref_spec = refname
    }
    Some(Subdir(github_url, subdir, refname)) => {
      // user/repo:path or /tree/ URL → subdir clone
      print_line("Subdir clone: \{github_url} → \{subdir}")
      return subdir_clone(github_url, subdir, dest, refname)
    }
    Some(File(raw_url, filename)) => {
      // /blob/ URL → single file fetch
      let target_file = match dest {
        Some(d) => d
        None => filename
      }
      print_line("Fetching file: \{raw_url}")
      return fetch_raw_file(raw_url, target_file)
    }
    None => ()
  }
  // Re-extract remote_url after potential shorthand expansion
  guard url is Some(remote_url) else {
    raise @git.GitError::InvalidObject("repository URL required")
  }
  // Derive destination from URL if not specified
  let relative_target = match dest {
    Some(d) => d
    None => {
      let name = if remote_url.has_suffix(".git") {
        String::unsafe_substring(
          remote_url,
          start=0,
          end=remote_url.length() - 4,
        )
      } else {
        remote_url
      }
      match name.rev_find("/") {
        Some(i) =>
          String::unsafe_substring(name, start=i + 1, end=name.length())
        None => name
      }
    }
  }
  let target = if relative_target.has_prefix("/") {
    relative_target
  } else {
    root + "/" + relative_target
  }
  // Show what kind of clone we're doing
  let clone_type = if filter.is_partial() {
    "partial clone (\{filter.to_string()})"
  } else if depth > 0 {
    "shallow clone (depth=\{depth})"
  } else {
    "full clone"
  }
  print_line("Cloning into '\{relative_target}'... (\{clone_type})")
  let fs = OsFs::new()
  let local_root = match @sys.get_env_var("GIT_SHIM_CWD") {
    Some(dir) => dir
    None => root
  }
  match @gitlib.resolve_local_repo_path(fs, local_root, remote_url) {
    Some(src_path) => {
      if has_promisor_source_repo(fs, src_path) {
        ()
      }
      let remote_display = if remote_url.has_prefix("file://") {
        remote_url
      } else if remote_url.has_prefix("/") {
        remote_url
      } else {
        normalize_path(local_root + "/" + remote_url)
      }
      clone_local_repo(fs, src_path, target, remote_display, bare, filter)
      if not(bare) && not(filter.is_partial()) {
        let git_dir = target + "/.git"
        match @gitlib.resolve_head_commit(fs, git_dir) {
          Some(commit_id) =>
            @gitlibnative.apply_worktree_modes_from_commit(
              fs, fs, target, git_dir, commit_id,
            )
          None => ()
        }
        pack_remote_tracking_refs(fs, git_dir, "origin")
      }
      if ref_spec is Some(refname) && not(bare) && not(filter.is_partial()) {
        let _ = @gitlib.checkout(fs, fs, target, refname)
      }
      print_line("done.")
    }
    None => {
      let refs = @gitnative.clone_http_to_fs(
        remote_url,
        true,
        fs,
        target,
        depth~,
        filter~,
      )
      if not(bare) && not(filter.is_partial()) {
        let git_dir = target + "/.git"
        match @gitlib.resolve_head_commit(fs, git_dir) {
          Some(commit_id) =>
            @gitlibnative.apply_worktree_modes_from_commit(
              fs, fs, target, git_dir, commit_id,
            )
          None => ()
        }
        pack_remote_tracking_refs(fs, git_dir, "origin")
      }
      if refs.length() > 0 {
        if ref_spec is Some(refname) && not(bare) && not(filter.is_partial()) {
          match resolve_remote_ref_id(remote_url, refname) {
            Some((commit_id, branch)) => {
              let git_dir = target + "/.git"
              let mut db = @gitlib.ObjectDb::load_lazy(fs, git_dir)
              if db.get(fs, commit_id) is None {
                let pack = @gitnative.fetch_pack_http(
                  remote_url,
                  [commit_id],
                  true,
                )
                let objects = @pack.parse_packfile(pack)
                @pack.write_packfile_with_index(fs, git_dir, pack, objects)
                db = @gitlib.ObjectDb::load_lazy(fs, git_dir)
              }
              match branch {
                Some(name) => {
                  fs.mkdir_p(git_dir + "/refs/heads") catch {
                    err => {
                      if @async.is_being_cancelled() ||
                        @async.is_cancellation_error(err) {
                        raise err
                      }
                      ()
                    }
                  }
                  fs.write_string(
                    git_dir + "/refs/heads/" + name,
                    commit_id.to_hex() + "\n",
                  ) catch {
                    err => {
                      if @async.is_being_cancelled() ||
                        @async.is_cancellation_error(err) {
                        raise err
                      }
                      ()
                    }
                  }
                  let _ = @gitlib.checkout(fs, fs, target, name)
                }
                None => {
                  let _ = @gitlib.checkout(fs, fs, target, commit_id.to_hex())
                }
              }
            }
            None =>
              raise @git.GitError::InvalidObject("Unknown ref: " + refname)
          }
        }
        print_line("done.")
      } else {
        raise @git.GitError::InvalidObject("Clone failed: no refs found")
      }
    }
  }
}

///|

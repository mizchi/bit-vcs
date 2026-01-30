///| Remote operation handlers: upload-pack, receive-pack, fetch, pull, clone

///|
fn parse_pack_args(args : Array[String]) -> (Bool, String)? {
  let mut advertise = false
  let mut repo : String? = None
  for arg in args {
    match arg {
      "--advertise-refs" => advertise = true
      "--stateless-rpc" => continue
      _ if arg.has_prefix("--") => continue
      _ =>
        if repo is None {
          repo = Some(arg)
        }
    }
  }
  match repo {
    Some(path) => Some((advertise, path))
    None => None
  }
}

///|
async fn handle_upload_pack(args : Array[String]) -> Unit {
  guard parse_pack_args(args) is Some((advertise, repo_path)) else {
    raise @git.GitError::ProtocolError("missing repository path")
  }
  if repo_path.has_suffix(".git") && !repo_path.has_suffix("/.git") {
    run_system_git(prepend_arg("upload-pack", args))
    return ()
  }
  let root = normalize_repo_root(repo_path)
  let fs = OsFs::new()
  if advertise {
    let out = @gitlib.build_upload_pack_advertisement(fs, root)
    @stdio.stdout.write(out)
  } else {
    let input = read_all_stdin()
    let req = @gitlib.parse_upload_pack_request(input)
    let out = @gitlib.upload_pack(fs, root, req)
    @stdio.stdout.write(out)
  }
}

///|
async fn handle_receive_pack(args : Array[String]) -> Unit {
  guard parse_pack_args(args) is Some((advertise, repo_path)) else {
    raise @git.GitError::ProtocolError("missing repository path")
  }
  if repo_path.has_suffix(".git") && !repo_path.has_suffix("/.git") {
    run_system_git(prepend_arg("receive-pack", args))
    return ()
  }
  let root = normalize_repo_root(repo_path)
  let fs = OsFs::new()
  if advertise {
    let out = @gitlib.build_receive_pack_advertisement(fs, root)
    @stdio.stdout.write(out)
  } else {
    let input = read_all_stdin()
    let out = @gitlib.receive_pack(fs, fs, root, input)
    @stdio.stdout.write(out)
  }
}

///|
async fn handle_clone(args : Array[String]) -> Unit raise Error {
  let root = get_work_root()
  let mut url : String? = None
  let mut dest : String? = None
  for arg in args {
    if arg.has_prefix("-") {
      continue
    }
    if url is None {
      url = Some(arg)
    } else if dest is None {
      dest = Some(arg)
    }
  }
  guard url is Some(remote_url) else {
    raise @git.GitError::InvalidObject("repository URL required")
  }
  // Derive destination from URL if not specified
  let relative_target = match dest {
    Some(d) => d
    None => {
      let name = if remote_url.has_suffix(".git") {
        String::unsafe_substring(remote_url, start=0, end=remote_url.length() - 4)
      } else {
        remote_url
      }
      match name.rev_find("/") {
        Some(i) => String::unsafe_substring(name, start=i + 1, end=name.length())
        None => name
      }
    }
  }
  let target = if relative_target.has_prefix("/") {
    relative_target
  } else {
    root + "/" + relative_target
  }
  print_line("Cloning into '\{relative_target}'...")
  let fs = OsFs::new()
  let refs = @git.clone_http_to_fs(remote_url, true, fs, target)
  if refs.length() > 0 {
    print_line("done.")
  } else {
    raise @git.GitError::InvalidObject("Clone failed: no refs found")
  }
}

///|
async fn handle_fetch(args : Array[String]) -> Unit raise Error {
  let root = get_work_root()
  let git_dir = root + "/.git"
  let fs = OsFs::new()
  // Read remote URL from config
  let mut remote_url : String? = read_remote_url_from_config(fs, git_dir)
  // Override with command line argument
  for arg in args {
    if not(arg.has_prefix("-")) {
      remote_url = Some(arg)
      break
    }
  }
  guard remote_url is Some(url) else {
    raise @git.GitError::InvalidObject("No remote configured")
  }
  print_line("Fetching from \{url}...")
  let (refs, _caps, _version, symrefs) = @git.discover_upload_refs_http(
    url, true,
  )
  let default_ref = @git.select_default_ref(refs, symrefs)
  match default_ref {
    None => {
      print_line("No refs to fetch")
      return ()
    }
    Some((refname, commit_id)) => {
      let pack = @git.fetch_pack_http(url, [commit_id], true)
      let objects = @git.parse_packfile(pack)
      @git.write_packfile_with_index(fs, git_dir, pack, objects)
      // Update remote tracking ref
      let remote_ref = if refname.has_prefix("refs/heads/") {
        let name = String::unsafe_substring(
          refname,
          start=11,
          end=refname.length(),
        )
        "refs/remotes/origin/" + name
      } else {
        "refs/remotes/origin/HEAD"
      }
      let remote_path = git_dir + "/" + remote_ref
      let dir = match remote_path.rev_find("/") {
        None => ""
        Some(i) => String::unsafe_substring(remote_path, start=0, end=i)
      }
      if dir.length() > 0 {
        fs.mkdir_p(dir)
      }
      fs.write_string(remote_path, commit_id.to_hex() + "\n")
      print_line("From \{url}")
      print_line(" * [new branch] \{refname} -> \{remote_ref}")
    }
  }
}

///|
async fn handle_pull(args : Array[String]) -> Unit raise Error {
  let root = get_work_root()
  let git_dir = root + "/.git"
  let fs = OsFs::new()
  let mut remote_url : String? = read_remote_url_from_config(fs, git_dir)
  let mut rebase = false
  for arg in args {
    match arg {
      "--rebase" | "-r" => rebase = true
      _ if arg.has_prefix("-") => continue
      _ => {
        remote_url = Some(arg)
        break
      }
    }
  }
  guard remote_url is Some(url) else {
    raise @git.GitError::InvalidObject("No remote configured")
  }
  print_line("Pulling from \{url}...")
  let result = @gitlib.pull_http(fs, fs, root, url, true, rebase~)
  match result {
    None => print_line("Already up to date.")
    Some(id) => print_line("Updated to \{id.to_hex()}")
  }
}

///|
fn read_remote_url_from_config(
  fs : &@git.RepoFileSystem,
  git_dir : String,
) -> String? {
  let config_path = git_dir + "/config"
  if not(fs.is_file(config_path)) {
    return None
  }
  let config_content = decode_bytes(
    fs.read_file(config_path) catch { _ => return None },
  )
  let mut in_remote_section = false
  for line_view in config_content.split("\n") {
    let line = trim_string(line_view.to_string())
    if line.has_prefix("[remote ") {
      in_remote_section = true
      continue
    }
    if line.has_prefix("[") {
      in_remote_section = false
      continue
    }
    if in_remote_section && line.has_prefix("url = ") {
      return Some(String::unsafe_substring(line, start=6, end=line.length()))
    }
  }
  None
}

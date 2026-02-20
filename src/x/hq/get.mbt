///|
/// Execute hq get command
///
/// Clone a repository to the bhq root directory.
/// If subdir is specified, use sparse checkout.
pub fn hq_get(
  repo : RepoPath,
  config : HqConfig,
  options : HqGetOptions,
  /// Execute shell command and return (exit_code, stdout, stderr)
  exec : (String) -> (Int, String, String),
  /// Check if path exists
  path_exists : (String) -> Bool,
) -> HqGetResult {
  let local_path = repo.local_path(config.root)
  // Check if already exists
  if path_exists(local_path) {
    if options.update {
      if options.unshallow {
        let (unshallow_code, _unshallow_stdout, unshallow_stderr) = exec(
          "cd \{local_path} && git fetch --unshallow",
        )
        if unshallow_code != 0 {
          return HqGetResult::Error("Failed to unshallow: \{unshallow_stderr}")
        }
      }
      // Update existing repository
      let cmd = "cd \{local_path} && git pull --ff-only"
      let (code, _stdout, stderr) = exec(cmd)
      if code == 0 {
        HqGetResult::Updated(local_path)
      } else {
        HqGetResult::Error("Failed to update: \{stderr}")
      }
    } else {
      HqGetResult::Skipped(local_path)
    }
  } else {
    // Clone new repository
    let clone_result = if repo.needs_sparse() {
      clone_sparse(repo, local_path, options, exec)
    } else {
      clone_normal(repo, local_path, options, exec)
    }
    match clone_result {
      Ok(_) => HqGetResult::Cloned(local_path)
      Err(msg) => HqGetResult::Error(msg)
    }
  }
}

///|
fn resolve_hq_clone_depth(options : HqGetOptions) -> Int {
  if options.depth > 0 {
    options.depth
  } else if options.shallow {
    1
  } else {
    0
  }
}

///|
fn clone_normal(
  repo : RepoPath,
  local_path : String,
  options : HqGetOptions,
  exec : (String) -> (Int, String, String),
) -> Result[Unit, String] {
  let url = repo.clone_url(ssh=options.ssh)
  let depth = resolve_hq_clone_depth(options)
  let args : Array[String] = ["git", "clone"]
  if depth > 0 {
    args.push("--depth=" + depth.to_string())
  }
  match options.branch {
    Some(branch) => {
      args.push("--branch")
      args.push(branch)
    }
    None => ()
  }
  args.push(url)
  args.push(local_path)
  let cmd = args.iter().map(s => s).join(" ")
  let (code, _stdout, stderr) = exec(cmd)
  if code == 0 {
    Ok(())
  } else {
    Err("Clone failed: \{stderr}")
  }
}

///|
fn clone_sparse(
  repo : RepoPath,
  local_path : String,
  options : HqGetOptions,
  exec : (String) -> (Int, String, String),
) -> Result[Unit, String] {
  let url = repo.clone_url(ssh=options.ssh)
  let depth = resolve_hq_clone_depth(options)
  let subdir = repo.subdir.unwrap_or("")
  // Step 1: Clone with filter and no checkout
  let clone_args : Array[String] = ["git", "clone", "--no-checkout"]
  if depth > 0 {
    clone_args.push("--depth=" + depth.to_string())
  }
  match options.branch {
    Some(branch) => {
      clone_args.push("--branch")
      clone_args.push(branch)
    }
    None => ()
  }
  clone_args.push(url)
  clone_args.push(local_path)
  let clone_cmd = clone_args.iter().map(s => s).join(" ")
  let (code1, _stdout1, stderr1) = exec(clone_cmd)
  if code1 != 0 {
    return Err("Clone failed: \{stderr1}")
  }
  // Step 2: Initialize sparse checkout
  let sparse_init_cmd = "cd \{local_path} && git sparse-checkout init --cone"
  let (code2, _stdout2, stderr2) = exec(sparse_init_cmd)
  if code2 != 0 {
    return Err("Sparse checkout init failed: \{stderr2}")
  }
  // Step 3: Set sparse checkout paths
  let sparse_dir = if subdir.has_prefix("/") { subdir } else { "/" + subdir }
  let sparse_dir_with_sep = if sparse_dir.has_suffix("/") {
    sparse_dir
  } else {
    sparse_dir + "/"
  }
  let sparse_set_cmd = "cd \{local_path} && git sparse-checkout set \{sparse_dir_with_sep}"
  let (code3, _stdout3, stderr3) = exec(sparse_set_cmd)
  if code3 != 0 {
    return Err("Sparse checkout set failed: \{stderr3}")
  }
  Ok(())
}

///|
/// Build the git clone command string (for display/logging)
pub fn build_clone_command(
  repo : RepoPath,
  local_path : String,
  options : HqGetOptions,
) -> String {
  let url = repo.clone_url(ssh=options.ssh)
  let depth = resolve_hq_clone_depth(options)
  if repo.needs_sparse() {
    let subdir = repo.subdir.unwrap_or("")
    let sparse_dir = if subdir.has_prefix("/") { subdir } else { "/" + subdir }
    let sparse_dir_with_sep = if sparse_dir.has_suffix("/") {
      sparse_dir
    } else {
      sparse_dir + "/"
    }
    let sparse_args : Array[String] = ["git", "clone", "--no-checkout"]
    if depth > 0 {
      sparse_args.push("--depth=" + depth.to_string())
    }
    match options.branch {
      Some(branch) => {
        sparse_args.push("--branch")
        sparse_args.push(branch)
      }
      None => ()
    }
    sparse_args.push(url)
    sparse_args.push(local_path)
    let clone_cmd = sparse_args.iter().map(s => s).join(" ")
    "\{clone_cmd} && cd \{local_path} && git sparse-checkout init --cone && git sparse-checkout set \{sparse_dir_with_sep}"
  } else {
    let args : Array[String] = ["git", "clone"]
    if depth > 0 {
      args.push("--depth=" + depth.to_string())
    }
    match options.branch {
      Some(branch) => {
        args.push("--branch")
        args.push(branch)
      }
      None => ()
    }
    args.push(url)
    args.push(local_path)
    args.iter().map(s => s).join(" ")
  }
}

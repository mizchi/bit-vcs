///|

///|
async fn show_add_command_help() -> Unit {
  show_simple_command_help(
    "git add [<options>] [--] <pathspec>...",
    summary="Add file contents to the index.",
  )
}

///|
async fn handle_add(args : Array[String]) -> Unit raise Error {
  if has_interactive_add_flag(args) {
    run_add_interactive(args)
    return
  }
  let root = get_work_root()
  let fs = OsFs::new()
  let mut add_all = false
  let paths : Array[String] = []
  for arg in args {
    match arg {
      "-A" | "--all" => add_all = true
      "-f" | "--force" => () // TODO: skip gitignore check
      _ if not(arg.has_prefix("-")) => paths.push(arg)
      _ if arg.has_prefix("-") => warn_unimplemented_arg("add", arg)
      _ => ()
    }
  }
  if add_all {
    // Stage all: untracked, modified, and deleted
    let status = @gitlib.status(fs, root)
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
      @gitlib.add_paths_async(fs, fs, root, all_paths)
      stage_submodule_gitlinks(fs, root, all_paths)
    }
    return
  }
  if paths.length() == 0 {
    raise @git.GitError::InvalidObject("Nothing specified, nothing added.")
  }
  @gitlib.add_paths_async(fs, fs, root, paths)
  stage_submodule_gitlinks(fs, root, paths)
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
  out
}

///|
fn stage_submodule_gitlinks(
  fs : OsFs,
  root : String,
  paths : Array[String],
) -> Unit raise Error {
  let rfs : &@git.RepoFileSystem = fs
  let git_dir = resolve_git_dir(fs, root)
  for raw_path in paths {
    let rel_path = normalize_add_path(raw_path)
    if rel_path == "." || rel_path.length() == 0 {
      continue
    }
    let sub_path = root + "/" + rel_path
    let sub_git = sub_path + "/.git"
    let sub_git_dir = if rfs.is_file(sub_git) {
      @gitlib.resolve_gitdir(rfs, sub_git)
    } else if rfs.is_dir(sub_git) {
      sub_git
    } else {
      continue
    }
    match @gitlib.resolve_head_commit(rfs, sub_git_dir) {
      Some(id) => update_submodule_index_entry(fs, git_dir, rel_path, id)
      None => ()
    }
  }
}

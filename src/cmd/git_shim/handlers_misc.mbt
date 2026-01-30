///| Miscellaneous handlers: diff, merge, tag, rm, mv, config, sparse-checkout, rev-parse

///|
async fn handle_diff(args : Array[String]) -> Unit raise Error {
  let root = get_work_root()
  let fs = OsFs::new()
  let mut cached = false
  let mut stat_mode = false
  let mut name_only = false
  let mut name_status = false
  let paths : Array[String] = []
  for arg in args {
    match arg {
      "--cached" | "--staged" => cached = true
      "--stat" => stat_mode = true
      "--name-only" => name_only = true
      "--name-status" => name_status = true
      _ if not(arg.has_prefix("-")) => paths.push(arg)
      _ => ()
    }
  }
  let all_files = if cached {
    @gitlib.diff_index(fs, root)
  } else {
    @gitlib.diff_worktree(fs, root)
  }
  // Filter by paths if specified
  let files = if paths.length() > 0 {
    all_files.iter().filter(fn(f) {
      paths.iter().any(fn(p) { f.path == p || f.path.has_prefix(p + "/") })
    }).collect()
  } else {
    all_files
  }
  // Output based on mode
  if name_only {
    for f in files {
      print_line(f.path)
    }
  } else if name_status {
    for f in files {
      let status = match f.kind {
        @gitlib.DiffKind::Added => "A"
        @gitlib.DiffKind::Modified => "M"
        @gitlib.DiffKind::Deleted => "D"
      }
      print_line("\{status}\t\{f.path}")
    }
  } else if stat_mode {
    let lines = @gitlib.diff_stat(files)
    for line in lines {
      print_line(line)
    }
  } else {
    let lines = @gitlib.diff_text(files)
    for line in lines {
      print_line(line)
    }
  }
}

///|
async fn handle_merge(args : Array[String]) -> Unit raise Error {
  let root = get_work_root()
  let git_dir = root + "/.git"
  let fs = OsFs::new()
  let mut target_ref : String? = None
  let mut message : String? = None
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    match arg {
      "-m" if i + 1 < args.length() => {
        message = Some(args[i + 1])
        i += 2
        continue
      }
      _ if arg.has_prefix("-m") => {
        message = Some((try! arg[2:]).to_string())
        i += 1
        continue
      }
      _ if not(arg.has_prefix("-")) => target_ref = Some(arg)
      _ => ()
    }
    i += 1
  }
  guard target_ref is Some(refspec) else {
    raise @git.GitError::InvalidObject("No commit to merge specified")
  }
  // Resolve target
  let target_id = @gitlib.rev_parse(fs, git_dir, refspec)
  guard target_id is Some(tid) else {
    raise @git.GitError::InvalidObject("unknown revision: \{refspec}")
  }
  let author = get_author_string()
  let timestamp = get_commit_timestamp()
  let msg = message.unwrap_or("Merge \{refspec}")
  let result = @gitlib.merge(fs, fs, root, tid, msg, author, timestamp)
  match result.status {
    @gitlib.MergeStatus::AlreadyUpToDate => print_line("Already up to date.")
    @gitlib.MergeStatus::FastForward =>
      match result.commit_id {
        Some(id) => {
          let short = String::unsafe_substring(id.to_hex(), start=0, end=7)
          print_line("Fast-forward to \{short}")
        }
        None => print_line("Fast-forward")
      }
    @gitlib.MergeStatus::Merged =>
      match result.commit_id {
        Some(id) => {
          let short = String::unsafe_substring(id.to_hex(), start=0, end=7)
          print_line("Merge made by the 'ort' strategy. [\{short}]")
        }
        None => print_line("Merged")
      }
    @gitlib.MergeStatus::Conflicted => {
      print_line("CONFLICT (content): Merge conflict in the following files:")
      for path in result.conflicts {
        print_line("  \{path}")
      }
      print_line("Automatic merge failed; fix conflicts and then commit.")
    }
  }
}

///|
async fn handle_tag(args : Array[String]) -> Unit raise Error {
  let root = get_work_root()
  let git_dir = root + "/.git"
  let fs = OsFs::new()
  let mut list_mode = true
  let mut delete_mode = false
  let mut annotated = false
  let mut message : String? = None
  let mut tag_name : String? = None
  let mut target : String? = None
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    match arg {
      "-l" | "--list" => list_mode = true
      "-d" | "--delete" => {
        delete_mode = true
        list_mode = false
      }
      "-a" | "--annotate" => {
        annotated = true
        list_mode = false
      }
      "-m" if i + 1 < args.length() => {
        message = Some(args[i + 1])
        annotated = true
        list_mode = false
        i += 2
        continue
      }
      _ if arg.has_prefix("-m") => {
        message = Some((try! arg[2:]).to_string())
        annotated = true
        list_mode = false
        i += 1
        continue
      }
      _ if arg.has_prefix("--message=") => {
        message = Some((try! arg[10:]).to_string())
        annotated = true
        list_mode = false
        i += 1
        continue
      }
      _ if not(arg.has_prefix("-")) =>
        if tag_name is None {
          tag_name = Some(arg)
          list_mode = false
        } else if target is None {
          target = Some(arg)
        }
      _ => ()
    }
    i += 1
  }
  if delete_mode {
    guard tag_name is Some(name) else {
      raise @git.GitError::InvalidObject("tag name required for delete")
    }
    @gitlib.delete_tag(fs, git_dir, name)
    print_line("Deleted tag '\{name}'")
    return ()
  }
  if list_mode {
    let tags = @gitlib.list_tags(fs, git_dir)
    for tag in tags {
      print_line(tag)
    }
    return ()
  }
  guard tag_name is Some(name) else {
    raise @git.GitError::InvalidObject("tag name required")
  }
  // Resolve target (default to HEAD)
  let target_ref = target.unwrap_or("HEAD")
  let commit_id = @gitlib.rev_parse(fs, git_dir, target_ref)
  guard commit_id is Some(id) else {
    raise @git.GitError::InvalidObject("unknown revision: \{target_ref}")
  }
  if annotated {
    let msg = message.unwrap_or("")
    let author = get_author_string()
    let timestamp = get_commit_timestamp()
    @gitlib.create_annotated_tag(
      fs, fs, git_dir, name, id, msg, author, timestamp,
    )
  } else {
    @gitlib.create_lightweight_tag(fs, git_dir, name, id)
  }
}

///|
fn handle_rm(args : Array[String]) -> Unit raise Error {
  let root = get_work_root()
  let fs = OsFs::new()
  let mut cached = false
  let mut force = false
  let mut recursive = false
  let paths : Array[String] = []
  for arg in args {
    match arg {
      "--cached" => cached = true
      "-f" | "--force" => force = true
      "-r" => recursive = true
      _ if not(arg.has_prefix("-")) => paths.push(arg)
      _ => ()
    }
  }
  if paths.length() == 0 {
    raise @git.GitError::InvalidObject("No pathspec given")
  }
  @gitlib.rm_paths(fs, fs, root, paths, cached~, force~, recursive~)
}

///|
fn handle_mv(args : Array[String]) -> Unit raise Error {
  let root = get_work_root()
  let fs = OsFs::new()
  let mut force = false
  let paths : Array[String] = []
  for arg in args {
    match arg {
      "-f" | "--force" => force = true
      _ if not(arg.has_prefix("-")) => paths.push(arg)
      _ => ()
    }
  }
  if paths.length() < 2 {
    raise @git.GitError::InvalidObject("usage: git mv <source> <destination>")
  }
  let source = paths[0]
  let dest = paths[1]
  @gitlib.mv_path(fs, fs, root, source, dest, force~)
}

///|
async fn handle_config(args : Array[String]) -> Unit raise Error {
  let root = get_work_root()
  let git_dir = root + "/.git"
  let fs = OsFs::new()
  let config_path = git_dir + "/config"
  // Parse arguments
  let mut get_mode = false
  let mut get_bool = false
  let mut key : String? = None
  let mut value : String? = None
  for arg in args {
    match arg {
      "--get" => get_mode = true
      "--bool" => get_bool = true
      _ if arg.has_prefix("-") => ()
      _ =>
        if key is None {
          key = Some(arg)
        } else if value is None {
          value = Some(arg)
        }
    }
  }
  guard key is Some(k) else {
    raise @git.GitError::InvalidObject("key required")
  }
  if get_mode || value is None {
    // Read config
    if not(fs.is_file(config_path)) {
      raise @git.GitError::InvalidObject("config not found")
    }
    let content = decode_bytes(fs.read_file(config_path))
    let parts = k.split(".").map(fn(v) { v.to_string() }).collect()
    if parts.length() != 2 {
      raise @git.GitError::InvalidObject("invalid key format")
    }
    let section = parts[0]
    let name = parts[1]
    let mut in_section = false
    for line_view in content.split("\n") {
      let line = trim_string(line_view.to_string())
      if line.has_prefix("[") && line.has_suffix("]") {
        let sec_name = String::unsafe_substring(
          line,
          start=1,
          end=line.length() - 1,
        )
        in_section = sec_name == section ||
          sec_name.has_prefix(section + " ") ||
          sec_name.has_prefix(section + "\t")
        continue
      }
      if in_section && line.has_prefix(name + " = ") {
        let val = String::unsafe_substring(
          line,
          start=name.length() + 3,
          end=line.length(),
        )
        if get_bool {
          print_line(if val == "true" || val == "1" { "true" } else { "false" })
        } else {
          print_line(val)
        }
        return
      }
      if in_section && line.has_prefix(name + "=") {
        let val = String::unsafe_substring(
          line,
          start=name.length() + 1,
          end=line.length(),
        )
        if get_bool {
          print_line(if val == "true" || val == "1" { "true" } else { "false" })
        } else {
          print_line(val)
        }
        return
      }
    }
    // Key not found
    raise @git.GitError::InvalidObject("key not found: " + k)
  } else {
    // Write config - fallback to system git for now
    raise @git.GitError::InvalidObject("config write not implemented")
  }
}

///|
async fn handle_sparse_checkout(args : Array[String]) -> Unit raise Error {
  let root = get_work_root()
  let git_dir = root + "/.git"
  let fs = OsFs::new()
  if args.length() == 0 {
    raise @git.GitError::InvalidObject(
      "usage: git sparse-checkout <init|set|add|list|disable>",
    )
  }
  let subcmd = args[0]
  let rest : Array[String] = []
  for i in 1..<args.length() {
    rest.push(args[i])
  }
  match subcmd {
    "init" => {
      let cone = rest.contains("--cone")
      @gitlib.sparse_checkout_init(fs, fs, root, cone~)
      print_line("Sparse checkout initialized")
    }
    "set" => {
      let patterns = rest.iter().filter(fn(arg) {
        not(arg.has_prefix("-"))
      }).collect()
      if patterns.length() == 0 {
        raise @git.GitError::InvalidObject("patterns required for set")
      }
      @gitlib.sparse_checkout_set(fs, fs, root, patterns)
      print_line("Sparse checkout patterns set")
    }
    "add" => {
      let patterns = rest.iter().filter(fn(arg) {
        not(arg.has_prefix("-"))
      }).collect()
      if patterns.length() == 0 {
        raise @git.GitError::InvalidObject("patterns required for add")
      }
      @gitlib.sparse_checkout_add(fs, fs, root, patterns)
      print_line("Sparse checkout patterns added")
    }
    "list" => {
      let patterns = @gitlib.read_sparse_patterns(fs, git_dir)
      for p in patterns {
        print_line(p)
      }
    }
    "disable" => {
      @gitlib.sparse_checkout_disable(fs, fs, root)
      print_line("Sparse checkout disabled")
    }
    _ =>
      raise @git.GitError::InvalidObject(
        "unknown sparse-checkout subcommand: \{subcmd}",
      )
  }
}

///|
async fn handle_rev_parse(args : Array[String]) -> Unit raise Error {
  let root = get_work_root()
  let git_dir = root + "/.git"
  let fs = OsFs::new()
  for arg in args {
    match arg {
      "--git-dir" => print_line(git_dir)
      "--show-toplevel" => {
        let abs = if root == "." {
          @sys.get_env_var("PWD").unwrap_or(root)
        } else {
          root
        }
        print_line(abs)
      }
      _ if arg.has_prefix("-") => ()
      _ => {
        let id = @gitlib.rev_parse(fs, git_dir, arg)
        match id {
          Some(oid) => print_line(oid.to_hex())
          None => raise @git.GitError::InvalidObject("unknown revision: " + arg)
        }
      }
    }
  }
}

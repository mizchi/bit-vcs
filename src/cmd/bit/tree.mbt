///| Tree/cat handlers for remote repository browsing (porcelain)

///|
fn print_tree_usage() -> Unit {
  println("usage: bit tree [<options>] <repo>[:<path>] [<pathspec>...]")
  println("")
  println("List tree entries from a remote repository in porcelain format.")
  println("")
  println("Options:")
  println("  --blob                Show porcelain details (mode/type/oid)")
  println("  -r, --recursive       Recurse into subdirectories (default)")
  println("  --no-recursive        Do not recurse")
  println("  --name-only           Show only names")
  println("  -t                    Show tree entries when recursing")
  println("  -d                    Show only tree entries")
  println("")
  println("Examples:")
  println("  bit tree mizchi/bit")
  println("  bit tree mizchi/bit:src/x")
  println("  bit tree mizchi/bit@<rev>:src/x")
  println("  bit tree mizchi/bit src/x --name-only")
}

///|
fn print_cat_usage() -> Unit {
  println("usage: bit cat <repo>:<path>")
  println("")
  println("Show file contents from a remote repository.")
  println("")
  println("Examples:")
  println("  bit cat mizchi/bit:README.md")
  println("  bit cat mizchi/bit@<rev>:README.md")
}

///|
fn temp_root_dir() -> String {
  match @sys.get_env_var("TMPDIR") {
    Some(dir) =>
      if dir.has_suffix("/") && dir.length() > 1 {
        (try! dir[:dir.length() - 1]).to_string()
      } else {
        dir
      }
    None => @sys.get_env_var("TMP").unwrap_or("/tmp")
  }
}

///|
fn make_temp_dir(fs : OsFs, prefix : String) -> String raise @bitcore.GitError {
  let base = temp_root_dir() + "/" + prefix + "-" + "\{get_current_timestamp()}"
  let mut candidate = base
  let mut i = 0
  while fs.is_dir(candidate) || fs.is_file(candidate) {
    i += 1
    candidate = base + "-" + "\{i}"
  }
  fs.mkdir_p(candidate) catch {
    _ =>
      raise @bitcore.GitError::IoError(
        "Failed to create temp dir: " + candidate,
      )
  }
  candidate
}

///|
async fn handle_tree(args : Array[String]) -> Unit raise Error {
  let mut recursive = true
  let mut show_trees = false
  let mut only_trees = false
  let mut name_only = true
  let positional : Array[String] = []
  for arg in args {
    match arg {
      "--blob" => name_only = false
      "-r" | "--recursive" => recursive = true
      "--no-recursive" => recursive = false
      "-t" => show_trees = true
      "-d" => only_trees = true
      "--name-only" | "--name-status" => name_only = true
      _ if arg.has_prefix("-") => warn_unimplemented_arg("tree", arg)
      _ => positional.push(arg)
    }
  }
  guard positional.length() > 0 else {
    print_tree_usage()
    return ()
  }
  let spec = positional[0]
  let fs = OsFs::new()
  match check_shorthand_ambiguity(spec, p => fs.is_dir(p)) {
    Some(conflict_path) =>
      raise @bitcore.GitError::InvalidObject(
        "Ambiguous: '\{conflict_path}' exists locally. Use full URL or ./\{spec} for local path.",
      )
    None => ()
  }
  let (remote_url, path_from_spec, ref_spec) = match
    parse_github_shorthand(spec) {
    Some(Repo(url, refname)) => (url, None, refname)
    Some(Subdir(url, subpath, refname)) => (url, Some(subpath), refname)
    Some(File(_url, _)) =>
      raise @bitcore.GitError::InvalidObject(
        "tree does not accept file URLs; use 'bit cat' instead",
      )
    None =>
      if spec.has_prefix("https://") || spec.has_prefix("http://") {
        (spec, None, None)
      } else if spec.has_prefix("git@") {
        raise @bitcore.GitError::InvalidObject(
          "SSH URLs are not supported; use https://",
        )
      } else {
        // Fallback to local ls-tree behavior
        let local_args : Array[String] = []
        if recursive {
          local_args.push("-r")
        }
        if show_trees {
          local_args.push("-t")
        }
        if only_trees {
          local_args.push("-d")
        }
        if name_only {
          local_args.push("--name-only")
        }
        local_args.append(positional)
        return handle_ls_tree(local_args)
      }
  }
  let path_filters : Array[String] = []
  if path_from_spec is Some(path) {
    path_filters.push(path)
  }
  if positional.length() > 1 {
    for i in 1..<positional.length() {
      path_filters.push(positional[i])
    }
  }
  let normalized_filters = normalize_ls_tree_filters(path_filters, "")
  let temp_dir = make_temp_dir(fs, "bit-tree")
  try {
    let _ = @bitnative.clone_http_to_fs(
      remote_url,
      true,
      fs,
      temp_dir,
      depth=1,
      filter=@protocol.FilterSpec::BlobNone,
    )
    let git_dir = temp_dir + "/.git"
    let commit_id = match ref_spec {
      Some(refname) => {
        let resolved = resolve_remote_ref_id(remote_url, refname)
        guard resolved is Some((id, _)) else {
          raise @bitcore.GitError::InvalidObject("Unknown ref: " + refname)
        }
        id
      }
      None => {
        let head_id = @bitrepo.rev_parse(fs, git_dir, "HEAD")
        guard head_id is Some(id) else {
          raise @bitcore.GitError::InvalidObject("HEAD not found")
        }
        id
      }
    }
    let mut db = @bitlib.ObjectDb::load_lazy(fs, git_dir)
    if db.get(fs, commit_id) is None {
      let pack = @bitnative.fetch_pack_http(remote_url, [commit_id], true)
      let objects = @pack.parse_packfile(pack)
      @pack.write_packfile_with_index(fs, git_dir, pack, objects)
      db = @bitlib.ObjectDb::load_lazy(fs, git_dir)
    }
    let tree_id = resolve_to_tree(db, fs, commit_id)
    print_tree_entries(
      db,
      fs,
      tree_id,
      "",
      recursive,
      show_trees,
      only_trees,
      name_only,
      false,
      "",
      [],
      "",
      normalized_filters,
    )
  } catch {
    err => {
      remove_dir_recursive(fs, temp_dir)
      raise err
    }
  }
  remove_dir_recursive(fs, temp_dir)
}

///|

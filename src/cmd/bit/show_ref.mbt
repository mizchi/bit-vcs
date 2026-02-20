///|
async fn handle_show_ref(args : Array[String]) -> Unit raise Error {
  let root = get_work_root()
  let fs = OsFs::new()
  let git_dir = resolve_git_dir(fs, root)
  let mut heads_only = false
  let mut tags_only = false
  let mut hash_only = false
  let mut verify = false
  let mut exists = false
  let mut quiet = false
  let patterns : Array[String] = []
  for arg in args {
    match arg {
      "--heads" => heads_only = true
      "--tags" => tags_only = true
      "-s" | "--hash" => hash_only = true
      "--verify" => verify = true
      "--exists" => exists = true
      "-q" | "--quiet" => quiet = true
      "--" => ()
      _ if arg.has_prefix("-") => warn_unimplemented_arg("show-ref", arg)
      _ => patterns.push(arg)
    }
  }
  if exists {
    if patterns.length() != 1 {
      @sys.exit(1)
    }
    let refname = patterns[0]
    if show_ref_exists_without_resolution(fs, git_dir, refname) {
      @sys.exit(0)
    } else {
      @sys.exit(2)
    }
  }
  if verify {
    if patterns.length() == 0 {
      @sys.exit(1)
    }
    let mut has_missing = false
    for refname in patterns {
      match @bitlib.resolve_ref(fs, git_dir, refname) {
        Some(id) =>
          if not(quiet) {
            if hash_only {
              print_line(id.to_hex())
            } else {
              print_line("\{id.to_hex()} \{refname}")
            }
          }
        None => has_missing = true
      }
    }
    if has_missing {
      @sys.exit(1)
    }
    return
  }
  let refs = @bitrepo.show_ref(fs, git_dir)
  let mut matched_count = 0
  for item in refs {
    let (refname, id) = item
    if heads_only && not(refname.has_prefix("refs/heads/")) {
      continue
    }
    if tags_only && not(refname.has_prefix("refs/tags/")) {
      continue
    }
    if patterns.length() > 0 {
      let mut matched = false
      for pattern in patterns {
        if refname == pattern || refname.has_suffix("/" + pattern) {
          matched = true
          break
        }
      }
      if not(matched) {
        continue
      }
    }
    matched_count += 1
    if not(quiet) {
      if hash_only {
        print_line(id.to_hex())
      } else {
        print_line("\{id.to_hex()} \{refname}")
      }
    }
  }
  if matched_count == 0 {
    @sys.exit(1)
  }
}

///|
fn show_ref_exists_without_resolution(
  fs : &@bitcore.RepoFileSystem,
  git_dir : String,
  refname : String,
) -> Bool {
  let normalized = if refname == "HEAD" {
    "HEAD"
  } else {
    let normalized = @bitlib.normalize_repo_path(refname) catch {
      _ => return false
    }
    if not(normalized.has_prefix("refs/")) {
      return false
    }
    normalized
  }
  let loose_path = git_dir + "/" + normalized
  if fs.is_file(loose_path) {
    return true
  }
  let packed_refs_path = git_dir + "/packed-refs"
  if not(fs.is_file(packed_refs_path)) {
    return false
  }
  let content = decode_bytes(
    fs.read_file(packed_refs_path) catch {
      _ => return false
    },
  )
  for line_view in content.split("\n") {
    let line = trim_string(line_view.to_string())
    if line.length() == 0 || line.has_prefix("#") || line.has_prefix("^") {
      continue
    }
    match line.find(" ") {
      Some(idx) => {
        let packed_ref = String::unsafe_substring(
          line,
          start=idx + 1,
          end=line.length(),
        )
        if packed_ref == normalized {
          return true
        }
      }
      None => ()
    }
  }
  false
}

///|

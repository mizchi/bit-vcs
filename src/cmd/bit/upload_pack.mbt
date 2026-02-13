///|
async fn handle_upload_pack(args : Array[String]) -> Unit raise Error {
  // Handle -h/--help/--help-all option
  for arg in args {
    if arg == "-h" || arg == "--help" || arg == "--help-all" {
      print_line(
        "usage: git upload-pack [--[no-]strict] [--timeout=<n>] [--stateless-rpc]",
      )
      print_line("                       [--advertise-refs] <dir>")
      @sys.exit(129)
    }
  }
  match find_malformed_uploadpackfilter_override() {
    Some(key) => {
      @stdio.stderr.write(
        "unable to parse '" + key + "' from command-line config\n",
      )
      @sys.exit(129)
    }
    None => ()
  }
  let mut advertise = false
  let mut protocol_version = 1
  try {
    // Parse config overrides from environment variable
    let cmdline_config = @gitlib.parse_config_overrides()
    guard parse_pack_args(args) is Some((advertise_flag, repo_path)) else {
      raise @git.GitError::ProtocolError("missing repository path")
    }
    advertise = advertise_flag
    let root = if repo_path.has_suffix(".git") && !repo_path.has_suffix("/.git") {
      // Bare repository with .git suffix
      repo_path
    } else {
      normalize_repo_root(repo_path)
    }
    let fs = OsFs::new()
    let git_dir = if root.has_suffix(".git") && !root.has_suffix("/.git") {
      root
    } else {
      root + "/.git"
    }
    let config_git_dir = if fs.is_file(root + "/config") {
      root
    } else {
      git_dir
    }
    if is_sha256_repo(config_git_dir) {
      @stdio.stderr.write("bit: SHA256 repositories are not supported\n")
      @sys.exit(1)
    }
    let mut has_uploadpackfilter = false
    for entry in cmdline_config {
      let (key, value) = entry
      if key.has_prefix("uploadpackfilter.") {
        if value.length() == 0 {
          @stdio.stderr.write(
            "unable to parse '" + key + "' from command-line config\n",
          )
          @sys.exit(129)
        }
        has_uploadpackfilter = true
        break
      }
    }
    let allow_filter = match
      git_config_get(config_git_dir, "uploadpack", "allowfilter") {
      Some(value) => parse_bool_value(value).unwrap_or(false)
      None => false
    }
    let allow_any_want = match
      git_config_get(config_git_dir, "uploadpack", "allowanysha1inwant") {
      Some(value) => parse_bool_value(value).unwrap_or(false)
      None => false
    }
    if has_uploadpackfilter || allow_filter || allow_any_want {
      @stdio.stderr.write("bit: upload-pack filter options are not supported\n")
      @sys.exit(1)
    }
    if advertise {
      let out = @gitlib.build_upload_pack_advertisement(fs, root)
      @stdio.stdout.write(out)
    } else {
      let input = read_all_stdin()
      // Check protocol version from GIT_PROTOCOL environment variable
      protocol_version = @gitlib.get_protocol_version()
      if protocol_version == 2 {
        // Protocol v2: parse and handle v2 request
        let req = @gitlib.parse_upload_pack_request_v2(input)
        let config = @gitlib.build_upload_pack_config_with_overrides(
          fs, root, cmdline_config,
        )
        let out = @gitlib.upload_pack_v2(fs, root, req, config)
        @stdio.stdout.write(out)
      } else {
        // Protocol v1: use existing handler
        let req = @gitlib.parse_upload_pack_request(input)
        let out = @gitlib.upload_pack(fs, root, req)
        @stdio.stdout.write(out)
      }
    }
  } catch {
    err if @async.is_cancellation_error(err) => raise err
    err => upload_pack_fail(err, protocol_version, advertise)
  }
}

///|
fn find_malformed_uploadpackfilter_override() -> String? {
  let cli_args = @sys.get_cli_args()
  if cli_args.length() < 2 {
    return None
  }
  let mut i = 1
  let mut in_opts = true
  while i < cli_args.length() {
    let arg = cli_args[i]
    if in_opts && arg == "--" {
      in_opts = false
      i += 1
      continue
    }
    if in_opts && arg == "-c" && i + 1 < cli_args.length() {
      let kv = cli_args[i + 1]
      if kv.has_prefix("uploadpackfilter.") && kv.find("=") is None {
        return Some(kv.to_lower())
      }
      i += 2
      continue
    }
    if in_opts && !arg.has_prefix("-") {
      break
    }
    i += 1
  }
  None
}

///|
async fn upload_pack_fail(
  err : Error,
  protocol_version : Int,
  advertise : Bool,
) -> Unit {
  let _ : Int = protocol_version
  let msg = upload_pack_error_text(err)
  if not(advertise) {
    let line = upload_pack_first_line(msg)
    let pkt = @protocol.pktline_encode("ERR " + line + "\n")
    @stdio.stdout.write(pkt)
  }
  @stdio.stderr.write(msg + "\n")
  @sys.exit(1)
}

///|
fn upload_pack_error_text(err : Error) -> String {
  match err {
    @git.GitError::ProtocolError(msg) => msg
    @git.GitError::InvalidObject(msg) => msg
    @git.GitError::PackfileError(msg) => msg
    @git.GitError::HashMismatch(_, _) => "hash mismatch"
    @git.GitError::IoError(msg) => msg
    _ => err.to_string()
  }
}

///|
fn upload_pack_first_line(msg : String) -> String {
  match msg.find("\n") {
    Some(idx) => String::unsafe_substring(msg, start=0, end=idx)
    None => msg
  }
}

///|

///|
/// Subdir-clone command handler - clone subdirectory as independent repository

///|
fn subdir_clone_usage_lines() -> Array[String] {
  [
    "Usage: bit subdir-clone <url> <path> [<dest>]", "", "Clone a subdirectory from a remote repository as an independent git repo.",
    "", "Arguments:", "  <url>         Remote repository URL", "  <path>        Path within the remote repo (e.g., src/lib)",
    "  <dest>        Local directory name (default: last component of path)", "",
    "Examples:", "  bit subdir-clone https://github.com/user/repo src", "    → Creates src/ with contents of repo's src/",
    "", "  bit subdir-clone https://github.com/user/repo src/lib mylib", "    → Creates mylib/ with contents of repo's src/lib/",
    "", "After cloning, standard git/bit commands work from the directory:", "  cd mylib",
    "  bit status     # detects subdir-clone automatically", "  bit rebase origin/main  # rebases only subdir changes",
  ]
}

///|
fn print_subdir_clone_usage() -> Unit {
  for line in subdir_clone_usage_lines() {
    println(line)
  }
}

///|
/// Clone a subdirectory from remote repository
async fn handle_subdir_clone(args : Array[String]) -> Unit raise Error {
  let mut url : String? = None
  let mut subdir : String? = None
  let mut dest : String? = None
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    if arg.has_prefix("-") {
      warn_unimplemented_arg("subdir-clone", arg)
      i += 1
      continue
    }
    if url is None {
      url = Some(arg)
    } else if subdir is None {
      subdir = Some(arg)
    } else if dest is None {
      dest = Some(arg)
    }
    i += 1
  }
  guard url is Some(remote_url) else {
    print_subdir_clone_usage()
    return
  }
  guard subdir is Some(subdir_path) else {
    raise @bitcore.GitError::InvalidObject("subdirectory path required")
  }
  subdir_clone(remote_url, subdir_path, dest, None)
}

///|
async fn subdir_clone(
  remote_url : String,
  subdir_path : String,
  dest : String?,
  ref_spec : String?,
) -> Unit raise Error {
  // Derive destination from subdir or explicit dest
  let relative_target = match dest {
    Some(d) => d
    None =>
      match subdir_path.rev_find("/") {
        Some(idx) =>
          String::unsafe_substring(
            subdir_path,
            start=idx + 1,
            end=subdir_path.length(),
          )
        None => subdir_path
      }
  }
  let root = get_work_root()
  let target = if relative_target.has_prefix("/") {
    relative_target
  } else {
    root + "/" + relative_target
  }
  let git_dir = target + "/.git"
  print_line(
    "Cloning '\{subdir_path}' from '\{remote_url}' into '\{relative_target}'...",
  )
  let fs = OsFs::new()
  let target_existed = fs.is_dir(target)
  let local_root = match @sys.get_env_var("GIT_SHIM_CWD") {
    Some(dir) => dir
    None => root
  }
  let local_repo_path = @bitlib.resolve_local_repo_path(
    fs, local_root, remote_url,
  )
  // Step 1: Create target directory
  fs.mkdir_p(target) catch {
    _ =>
      raise @bitcore.GitError::IoError("Failed to create directory: " + target)
  }
  // Step 2: Clone with blob:none filter to a temp location
  print_line("  Fetching repository metadata...")
  let temp_clone = target + "/.git-temp"
  let from_local_repo = match local_repo_path {
    Some(src_path) => {
      let remote_display = if remote_url.has_prefix("file://") {
        remote_url
      } else if remote_url.has_prefix("/") {
        remote_url
      } else {
        normalize_path(local_root + "/" + remote_url)
      }
      clone_local_repo(
        fs,
        src_path,
        temp_clone,
        remote_display,
        false,
        @protocol.FilterSpec::BlobNone,
      )
      true
    }
    None => {
      let refs = @bitnative.clone_http_to_fs(
        remote_url,
        true,
        fs,
        temp_clone,
        filter=@protocol.FilterSpec::BlobNone,
      )
      if refs.length() == 0 {
        raise @bitcore.GitError::InvalidObject("Clone failed: no refs found")
      }
      false
    }
  }
  // Step 3: Read HEAD commit from temp
  let temp_git_dir = temp_clone + "/.git"
  let commit_id = match ref_spec {
    Some(refname) =>
      if from_local_repo {
        let resolved = @bitrepo.rev_parse(fs, temp_git_dir, refname)
        guard resolved is Some(id) else {
          raise @bitcore.GitError::InvalidObject("Unknown ref: " + refname)
        }
        id
      } else {
        let resolved = resolve_remote_ref_id(remote_url, refname)
        guard resolved is Some((id, _)) else {
          raise @bitcore.GitError::InvalidObject("Unknown ref: " + refname)
        }
        id
      }
    None => {
      let head_ref = fs.read_file(temp_git_dir + "/HEAD") catch {
        _ => raise @bitcore.GitError::IoError("Failed to read HEAD")
      }
      let head_text = @utf8.decode_lossy(head_ref[:])
        .trim(chars=" \n\r\t")
        .to_string()
      if head_text.has_prefix("ref: ") {
        let ref_name = String::unsafe_substring(
          head_text,
          start=5,
          end=head_text.length(),
        )
        let ref_path = temp_git_dir + "/" + ref_name
        let ref_content = fs.read_file(ref_path) catch {
          _ =>
            raise @bitcore.GitError::IoError("Failed to read ref: " + ref_name)
        }
        let ref_text = @utf8.decode_lossy(ref_content[:])
          .trim(chars=" \n\r\t")
          .to_string()
        @bitcore.ObjectId::from_hex(ref_text) catch {
          _ =>
            raise @bitcore.GitError::InvalidObject("Invalid commit ID in ref")
        }
      } else {
        @bitcore.ObjectId::from_hex(head_text) catch {
          _ => raise @bitcore.GitError::InvalidObject("Invalid HEAD")
        }
      }
    }
  }
  // Load object database and get tree
  let mut db = @bitlib.ObjectDb::load_lazy(fs, temp_git_dir)
  if not(from_local_repo) && db.get(fs, commit_id) is None {
    let pack = @bitnative.fetch_pack_http(remote_url, [commit_id], true)
    let objects = @pack.parse_packfile(pack)
    @pack.write_packfile_with_index(fs, temp_git_dir, pack, objects)
    db = @bitlib.ObjectDb::load_lazy(fs, temp_git_dir)
  }
  let commit_obj = db.get(fs, commit_id)
  guard commit_obj is Some(_) else {
    raise @bitcore.GitError::InvalidObject("Commit not found")
  }
  // Navigate to subdirectory tree
  print_line("  Finding subdirectory '\{subdir_path}'...")
  let subdir_tree_id = @bitlib.get_subdir_tree_from_commit(
    db, fs, commit_id, subdir_path,
  )
  guard subdir_tree_id is Some(tree_id) else {
    @bitlib.subdir_remove_dir(fs, fs, temp_clone)
    if not(target_existed) {
      @bitlib.subdir_remove_dir(fs, fs, target)
    }
    raise @bitcore.GitError::InvalidObject(
      "Subdirectory not found: " + subdir_path,
    )
  }
  // Fetch blobs for the subdirectory
  print_line("  Fetching files...")
  let needed_blobs = @bitlib.collect_tree_blobs(db, fs, tree_id)
  if needed_blobs.length() > 0 {
    let missing : Array[@bitcore.ObjectId] = []
    for blob_id in needed_blobs {
      let exists = db.get(fs, blob_id)
      if exists is None {
        missing.push(blob_id)
      }
    }
    if missing.length() > 0 {
      if from_local_repo {
        raise @bitcore.GitError::InvalidObject(
          "missing local objects for subdir clone",
        )
      }
      let pack = @bitnative.fetch_pack_http(remote_url, missing, true)
      let objects = @pack.parse_packfile(pack)
      @pack.write_packfile_with_index(fs, temp_git_dir, pack, objects)
    }
  }
  // Reload object database
  let db2 = @bitlib.ObjectDb::load_lazy(fs, temp_git_dir)
  // Step 4: Write files directly to target
  print_line("  Writing files...")
  @bitlib.write_tree_to_worktree(db2, fs, fs, tree_id, target)
  // Step 5: Move .git to target
  print_line("  Setting up git repository...")
  @bitlib.move_directory(fs, fs, temp_git_dir, git_dir)
  @bitlib.subdir_remove_dir(fs, fs, temp_clone)
  // Step 6: Create orphan commit with subdirectory as root
  print_line("  Creating initial commit...")
  let timestamp = get_current_timestamp()
  let author = "subdir-clone <subdir-clone@bitcore>"
  let message = "Initial commit (cloned from " + subdir_path + ")\n"
  let parents : Array[@bitcore.ObjectId] = []
  let commit = @bitcore.Commit::new(
    tree_id, parents, author, timestamp, "+0000", author, timestamp, "+0000", message,
  )
  let (new_commit_id, commit_bytes) = @bitcore.create_commit(commit)
  @bitlib.write_object_bytes(fs, git_dir, new_commit_id, commit_bytes) catch {
    _ => raise @bitcore.GitError::IoError("Failed to write commit object")
  }
  // Update HEAD
  let head_path = git_dir + "/HEAD"
  fs.write_file(head_path, string_to_bytes("ref: refs/heads/main\n")) catch {
    err => {
      if @async.is_being_cancelled() || @async.is_cancellation_error(err) {
        raise err
      }
      ()
    }
  }
  let ref_path = git_dir + "/refs/heads/main"
  fs.mkdir_p(git_dir + "/refs/heads") catch {
    err => {
      if @async.is_being_cancelled() || @async.is_cancellation_error(err) {
        raise err
      }
      ()
    }
  }
  fs.write_file(ref_path, string_to_bytes(new_commit_id.to_hex() + "\n")) catch {
    err => {
      if @async.is_being_cancelled() || @async.is_cancellation_error(err) {
        raise err
      }
      ()
    }
  }
  // Step 7: Write subdir-clone metadata to .git/info/attributes
  write_subdir_attributes(fs, git_dir, remote_url, subdir_path, commit_id)
  // Step 8: Reset index
  let _ = run_git_command(["-C", target, "reset", "HEAD"], cwd=None)
  print_line("done.")
  print_line("")
  print_line("Cloned '\{subdir_path}' to '\{relative_target}/'")
  print_line("")
  print_line("Standard git/bit commands work from this directory:")
  print_line("  cd \{relative_target}")
  print_line("  bit status")
  print_line("  bit rebase origin/main  # rebases only subdir changes")
}

///|
/// Write subdir-clone metadata to .git/info/attributes
fn write_subdir_attributes(
  fs : OsFs,
  git_dir : String,
  remote_url : String,
  subdir_path : String,
  base_commit : @bitcore.ObjectId,
) -> Unit {
  @bitlib.write_subdir_attributes(
    fs, git_dir, remote_url, subdir_path, base_commit,
  )
}

///|
/// Read subdir-clone metadata from .git/info/attributes
pub fn read_subdir_attributes(
  fs : OsFs,
  git_dir : String,
) -> (String, String, String)? {
  @bitlib.read_subdir_attributes(fs, git_dir)
}

///|
/// Update subdir-base in .git/info/attributes
pub fn update_subdir_base(
  fs : OsFs,
  git_dir : String,
  new_base : String,
) -> Unit {
  @bitlib.update_subdir_base(fs, fs, git_dir, new_base)
}

///|
/// Check if current directory is a subdir-clone
pub fn is_subdir_clone(fs : OsFs, git_dir : String) -> Bool {
  @bitlib.is_subdir_clone(fs, git_dir)
}

///|
/// Get effective remote URL - prefers subdir remote over config
pub fn get_effective_remote_url(fs : OsFs, git_dir : String) -> String? {
  @bitlib.get_effective_remote_url(fs, git_dir)
}

///|
/// Get subdir info for display (remote, path, base)
pub fn get_subdir_info(
  fs : OsFs,
  git_dir : String,
) -> (String, String, String)? {
  @bitlib.get_subdir_info(fs, git_dir)
}

///|
/// Get the subdir tree from a commit (for subdir-clone operations)
pub fn get_subdir_tree_from_commit(
  db : @bitlib.ObjectDb,
  fs : OsFs,
  commit_id : @bitcore.ObjectId,
  subdir_path : String,
) -> @bitcore.ObjectId? raise @bitcore.GitError {
  @bitlib.get_subdir_tree_from_commit(db, fs, commit_id, subdir_path)
}

///|
/// Resolve a ref to commit ID, handling both local and remote refs
pub fn resolve_ref_for_subdir(
  fs : OsFs,
  git_dir : String,
  refspec : String,
) -> @bitcore.ObjectId? raise Error {
  @bitlib.resolve_ref_for_subdir(fs, git_dir, refspec)
}

///|
fn string_to_bytes(s : String) -> Bytes {
  let bytes : Array[Byte] = []
  for c in s {
    bytes.push(c.to_int().to_byte())
  }
  Bytes::from_array(bytes)
}

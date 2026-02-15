///|
fn storage_runtime_wbtest_decode_bytes(data : Bytes) -> String {
  @utf8.decode_lossy(data[:])
}

///|
fn storage_runtime_wbtest_trim(s : String) -> String {
  let mut start = 0
  let mut end = s.length()
  while start < end {
    let c = s.unsafe_get(start)
    if c == ' ' || c == '\t' || c == '\n' || c == '\r' {
      start += 1
    } else {
      break
    }
  }
  while end > start {
    let c = s.unsafe_get(end - 1)
    if c == ' ' || c == '\t' || c == '\n' || c == '\r' {
      end -= 1
    } else {
      break
    }
  }
  if start == 0 && end == s.length() {
    s
  } else {
    String::unsafe_substring(s, start~, end~)
  }
}

///|
fn storage_runtime_wbtest_has_line(
  lines : Array[String],
  expected : String,
) -> Bool {
  for line in lines {
    if line == expected {
      return true
    }
  }
  false
}

///|
fn restore_env_var_for_storage_runtime_wbtest(
  name : String,
  prev : String?,
) -> Unit {
  match prev {
    Some(value) => @sys.set_env_var(name, value)
    None => @sys.unset_env_var(name)
  }
}

///|
fn setup_storage_runtime_quiet_for_wbtest() -> String? {
  let prev = @sys.get_env_var("BIT_STORAGE_RUNTIME_QUIET")
  @sys.set_env_var("BIT_STORAGE_RUNTIME_QUIET", "1")
  prev
}

///|
fn setup_identity_for_storage_runtime_wbtest() -> (
  String?,
  String?,
  String?,
  String?,
) {
  let prev_author_name = @sys.get_env_var("GIT_AUTHOR_NAME")
  let prev_author_email = @sys.get_env_var("GIT_AUTHOR_EMAIL")
  let prev_committer_name = @sys.get_env_var("GIT_COMMITTER_NAME")
  let prev_committer_email = @sys.get_env_var("GIT_COMMITTER_EMAIL")
  @sys.set_env_var("GIT_AUTHOR_NAME", "Storage Test")
  @sys.set_env_var("GIT_AUTHOR_EMAIL", "storage@example.com")
  @sys.set_env_var("GIT_COMMITTER_NAME", "Storage Test")
  @sys.set_env_var("GIT_COMMITTER_EMAIL", "storage@example.com")
  (
    prev_author_name, prev_author_email, prev_committer_name, prev_committer_email,
  )
}

///|
fn restore_identity_for_storage_runtime_wbtest(
  prev_author_name : String?,
  prev_author_email : String?,
  prev_committer_name : String?,
  prev_committer_email : String?,
) -> Unit {
  restore_env_var_for_storage_runtime_wbtest(
    "GIT_AUTHOR_NAME", prev_author_name,
  )
  restore_env_var_for_storage_runtime_wbtest(
    "GIT_AUTHOR_EMAIL", prev_author_email,
  )
  restore_env_var_for_storage_runtime_wbtest(
    "GIT_COMMITTER_NAME", prev_committer_name,
  )
  restore_env_var_for_storage_runtime_wbtest(
    "GIT_COMMITTER_EMAIL", prev_committer_email,
  )
}

///|
fn storage_runtime_wbtest_init_command(quiet? : Bool = true) -> StorageCommand {
  StorageCommand::Init({
    quiet,
    default_branch: "main",
    ref_format: "files",
    object_format: "sha1",
  })
}

///|
fn storage_runtime_wbtest_add_command(
  paths : Array[String],
  add_all? : Bool = false,
) -> StorageCommand {
  StorageCommand::Add({ add_all, paths })
}

///|
fn storage_runtime_wbtest_commit_command(
  message : String,
  all_modified? : Bool = false,
  allow_empty? : Bool = false,
  quiet? : Bool = true,
) -> StorageCommand {
  StorageCommand::Commit({ message, all_modified, allow_empty, quiet })
}

///|
fn storage_runtime_wbtest_status_command(
  porcelain? : Bool = false,
  short? : Bool = false,
  show_branch? : Bool = false,
) -> StorageCommand {
  StorageCommand::Status({ porcelain, short, show_branch })
}

///|
fn storage_runtime_wbtest_log_command(
  oneline? : Bool = false,
  max_count? : Int = 10,
) -> StorageCommand {
  StorageCommand::Log({ oneline, max_count })
}

///|
fn storage_runtime_wbtest_hash_object_command(
  paths : Array[String],
  write_object? : Bool = false,
  stdin_mode? : Bool = false,
  obj_type? : @git.ObjectType = @git.ObjectType::Blob,
) -> StorageCommand {
  StorageCommand::HashObject({ write_object, stdin_mode, obj_type, paths })
}

///|
fn storage_runtime_wbtest_write_tree_command(
  prefix? : String? = None,
) -> StorageCommand {
  StorageCommand::WriteTree({ prefix, })
}

///|
fn storage_runtime_wbtest_update_ref_command(
  delete_mode : Bool,
  refname : String,
  new_value : String?,
  old_value : String?,
) -> StorageCommand {
  StorageCommand::UpdateRef({ delete_mode, refname, new_value, old_value })
}

///|
test "storage runtime: init/add/commit/status/log on TestFs" {
  let fs = @git.TestFs::new()
  let root = "/repo-storage-runtime-basic"
  let prev_quiet = setup_storage_runtime_quiet_for_wbtest()
  let (
    prev_author_name,
    prev_author_email,
    prev_committer_name,
    prev_committer_email,
  ) = setup_identity_for_storage_runtime_wbtest()
  run_storage_command(fs, fs, root, storage_runtime_wbtest_init_command()) catch {
    err => fail("init failed: \{err}")
  }
  fs.write_string(root + "/a.txt", "hello\n")
  run_storage_command(
    fs,
    fs,
    root,
    storage_runtime_wbtest_add_command(["a.txt"]),
  ) catch {
    err => fail("add failed: \{err}")
  }
  run_storage_command(
    fs,
    fs,
    root,
    storage_runtime_wbtest_commit_command("first commit"),
  ) catch {
    err => fail("commit failed: \{err}")
  }
  let git_dir = root + "/.git"
  assert_true(fs.is_file(git_dir + "/refs/heads/main"))
  run_storage_command(
    fs,
    fs,
    root,
    storage_runtime_wbtest_status_command(porcelain=true),
  ) catch {
    err => fail("status failed: \{err}")
  }
  run_storage_command(
    fs,
    fs,
    root,
    storage_runtime_wbtest_log_command(oneline=true, max_count=1),
  ) catch {
    err => fail("log failed: \{err}")
  }
  restore_identity_for_storage_runtime_wbtest(
    prev_author_name, prev_author_email, prev_committer_name, prev_committer_email,
  )
  restore_env_var_for_storage_runtime_wbtest(
    "BIT_STORAGE_RUNTIME_QUIET", prev_quiet,
  )
}

///|
test "storage runtime: hash-object -w and write-tree work on TestFs" {
  let fs = @git.TestFs::new()
  let root = "/repo-storage-runtime-objects"
  let prev_quiet = setup_storage_runtime_quiet_for_wbtest()
  run_storage_command(fs, fs, root, storage_runtime_wbtest_init_command()) catch {
    err => fail("init failed: \{err}")
  }
  fs.write_string(root + "/blob.txt", "blob-data\n")
  run_storage_command(
    fs,
    fs,
    root,
    storage_runtime_wbtest_add_command(["blob.txt"]),
  ) catch {
    err => fail("add failed: \{err}")
  }
  run_storage_command(
    fs,
    fs,
    root,
    storage_runtime_wbtest_hash_object_command(["blob.txt"], write_object=true),
  ) catch {
    err => fail("hash-object failed: \{err}")
  }
  let blob_id = @git.hash_object_content(
    @git.ObjectType::Blob,
    fs.read_file(root + "/blob.txt"),
  )
  let blob_hex = blob_id.to_hex()
  let dir = (try! blob_hex[:2]).to_string()
  let rest = (try! blob_hex[2:]).to_string()
  let object_path = root + "/.git/objects/" + dir + "/" + rest
  assert_true(fs.is_file(object_path))
  run_storage_command(fs, fs, root, storage_runtime_wbtest_write_tree_command()) catch {
    err => fail("write-tree failed: \{err}")
  }
  restore_env_var_for_storage_runtime_wbtest(
    "BIT_STORAGE_RUNTIME_QUIET", prev_quiet,
  )
}

///|
test "storage runtime: update-ref create and delete on TestFs" {
  let fs = @git.TestFs::new()
  let root = "/repo-storage-runtime-update-ref"
  let prev_quiet = setup_storage_runtime_quiet_for_wbtest()
  let (
    prev_author_name,
    prev_author_email,
    prev_committer_name,
    prev_committer_email,
  ) = setup_identity_for_storage_runtime_wbtest()
  run_storage_command(fs, fs, root, storage_runtime_wbtest_init_command()) catch {
    err => fail("init failed: \{err}")
  }
  fs.write_string(root + "/a.txt", "hello\n")
  run_storage_command(
    fs,
    fs,
    root,
    storage_runtime_wbtest_add_command(["a.txt"]),
  ) catch {
    err => fail("add failed: \{err}")
  }
  run_storage_command(
    fs,
    fs,
    root,
    storage_runtime_wbtest_commit_command("base"),
  ) catch {
    err => fail("commit failed: \{err}")
  }
  let git_dir = root + "/.git"
  let head_id = match @gitrepo.rev_parse(fs, git_dir, "HEAD") {
    Some(id) => id
    None => {
      fail("HEAD not found")
      @git.ObjectId::zero()
    }
  }
  run_storage_command(
    fs,
    fs,
    root,
    storage_runtime_wbtest_update_ref_command(
      false,
      "refs/heads/storage",
      Some(head_id.to_hex()),
      None,
    ),
  ) catch {
    err => fail("update-ref create failed: \{err}")
  }
  let created = storage_runtime_wbtest_trim(
    storage_runtime_wbtest_decode_bytes(
      fs.read_file(git_dir + "/refs/heads/storage"),
    ),
  )
  assert_eq(created, head_id.to_hex())
  run_storage_command(
    fs,
    fs,
    root,
    storage_runtime_wbtest_update_ref_command(
      true,
      "refs/heads/storage",
      None,
      Some(head_id.to_hex()),
    ),
  ) catch {
    err => fail("update-ref delete failed: \{err}")
  }
  assert_false(fs.is_file(git_dir + "/refs/heads/storage"))
  restore_identity_for_storage_runtime_wbtest(
    prev_author_name, prev_author_email, prev_committer_name, prev_committer_email,
  )
  restore_env_var_for_storage_runtime_wbtest(
    "BIT_STORAGE_RUNTIME_QUIET", prev_quiet,
  )
}

///|
test "storage runtime: add without pathspec is rejected" {
  let fs = @git.TestFs::new()
  let root = "/repo-storage-runtime-add-no-pathspec"
  let prev_quiet = setup_storage_runtime_quiet_for_wbtest()
  run_storage_command(fs, fs, root, storage_runtime_wbtest_init_command()) catch {
    err => fail("init failed: \{err}")
  }
  let mut failed = false
  run_storage_command(fs, fs, root, storage_runtime_wbtest_add_command([])) catch {
    _ => failed = true
  }
  assert_true(failed)
  restore_env_var_for_storage_runtime_wbtest(
    "BIT_STORAGE_RUNTIME_QUIET", prev_quiet,
  )
}

///|
test "storage runtime: commit without message is rejected" {
  let fs = @git.TestFs::new()
  let root = "/repo-storage-runtime-no-message"
  let prev_quiet = setup_storage_runtime_quiet_for_wbtest()
  run_storage_command(fs, fs, root, storage_runtime_wbtest_init_command()) catch {
    err => fail("init failed: \{err}")
  }
  fs.write_string(root + "/a.txt", "hello\n")
  run_storage_command(
    fs,
    fs,
    root,
    storage_runtime_wbtest_add_command(["a.txt"]),
  ) catch {
    err => fail("add failed: \{err}")
  }
  let mut failed = false
  run_storage_command(
    fs,
    fs,
    root,
    storage_runtime_wbtest_commit_command("", quiet=false),
  ) catch {
    _ => failed = true
  }
  assert_true(failed)
  restore_env_var_for_storage_runtime_wbtest(
    "BIT_STORAGE_RUNTIME_QUIET", prev_quiet,
  )
}

///|
test "storage runtime: status porcelain lines report unstaged and untracked" {
  let fs = @git.TestFs::new()
  let root = "/repo-storage-runtime-status-lines"
  let prev_quiet = setup_storage_runtime_quiet_for_wbtest()
  let (
    prev_author_name,
    prev_author_email,
    prev_committer_name,
    prev_committer_email,
  ) = setup_identity_for_storage_runtime_wbtest()
  run_storage_command(fs, fs, root, storage_runtime_wbtest_init_command()) catch {
    err => fail("init failed: \{err}")
  }
  fs.write_string(root + "/a.txt", "base\n")
  run_storage_command(
    fs,
    fs,
    root,
    storage_runtime_wbtest_add_command(["a.txt"]),
  ) catch {
    err => fail("add failed: \{err}")
  }
  run_storage_command(
    fs,
    fs,
    root,
    storage_runtime_wbtest_commit_command("base"),
  ) catch {
    err => fail("commit failed: \{err}")
  }
  fs.write_string(root + "/a.txt", "changed\n")
  fs.write_string(root + "/b.txt", "new\n")
  let lines = storage_status_porcelain_lines(fs, root, false) catch {
    err => {
      fail("status lines failed: \{err}")
      []
    }
  }
  assert_true(storage_runtime_wbtest_has_line(lines, " M a.txt"))
  assert_true(storage_runtime_wbtest_has_line(lines, "?? b.txt"))
  restore_identity_for_storage_runtime_wbtest(
    prev_author_name, prev_author_email, prev_committer_name, prev_committer_email,
  )
  restore_env_var_for_storage_runtime_wbtest(
    "BIT_STORAGE_RUNTIME_QUIET", prev_quiet,
  )
}

///|
test "storage runtime: status porcelain branch line" {
  let fs = @git.TestFs::new()
  let root = "/repo-storage-runtime-status-branch"
  let prev_quiet = setup_storage_runtime_quiet_for_wbtest()
  let (
    prev_author_name,
    prev_author_email,
    prev_committer_name,
    prev_committer_email,
  ) = setup_identity_for_storage_runtime_wbtest()
  run_storage_command(fs, fs, root, storage_runtime_wbtest_init_command()) catch {
    err => fail("init failed: \{err}")
  }
  fs.write_string(root + "/a.txt", "base\n")
  run_storage_command(
    fs,
    fs,
    root,
    storage_runtime_wbtest_add_command(["a.txt"]),
  ) catch {
    err => fail("add failed: \{err}")
  }
  run_storage_command(
    fs,
    fs,
    root,
    storage_runtime_wbtest_commit_command("base"),
  ) catch {
    err => fail("commit failed: \{err}")
  }
  let lines = storage_status_porcelain_lines(fs, root, true) catch {
    err => {
      fail("status lines failed: \{err}")
      []
    }
  }
  assert_eq(lines.length(), 1)
  assert_eq(lines[0], "## main")
  restore_identity_for_storage_runtime_wbtest(
    prev_author_name, prev_author_email, prev_committer_name, prev_committer_email,
  )
  restore_env_var_for_storage_runtime_wbtest(
    "BIT_STORAGE_RUNTIME_QUIET", prev_quiet,
  )
}

///|
test "storage runtime: status porcelain branch mode includes branch and changes" {
  let fs = @git.TestFs::new()
  let root = "/repo-storage-runtime-status-branch-change"
  let prev_quiet = setup_storage_runtime_quiet_for_wbtest()
  let (
    prev_author_name,
    prev_author_email,
    prev_committer_name,
    prev_committer_email,
  ) = setup_identity_for_storage_runtime_wbtest()
  run_storage_command(fs, fs, root, storage_runtime_wbtest_init_command()) catch {
    err => fail("init failed: \{err}")
  }
  fs.write_string(root + "/a.txt", "base\n")
  run_storage_command(
    fs,
    fs,
    root,
    storage_runtime_wbtest_add_command(["a.txt"]),
  ) catch {
    err => fail("add failed: \{err}")
  }
  run_storage_command(
    fs,
    fs,
    root,
    storage_runtime_wbtest_commit_command("base"),
  ) catch {
    err => fail("commit failed: \{err}")
  }
  fs.write_string(root + "/a.txt", "changed\n")
  let lines = storage_status_porcelain_lines(fs, root, true) catch {
    err => {
      fail("status lines failed: \{err}")
      []
    }
  }
  assert_true(lines.length() >= 2)
  assert_eq(lines[0], "## main")
  assert_true(storage_runtime_wbtest_has_line(lines, " M a.txt"))
  restore_identity_for_storage_runtime_wbtest(
    prev_author_name, prev_author_email, prev_committer_name, prev_committer_email,
  )
  restore_env_var_for_storage_runtime_wbtest(
    "BIT_STORAGE_RUNTIME_QUIET", prev_quiet,
  )
}

///|
test "storage runtime: status porcelain detached head branch line" {
  let fs = @git.TestFs::new()
  let root = "/repo-storage-runtime-status-detached"
  let prev_quiet = setup_storage_runtime_quiet_for_wbtest()
  let (
    prev_author_name,
    prev_author_email,
    prev_committer_name,
    prev_committer_email,
  ) = setup_identity_for_storage_runtime_wbtest()
  run_storage_command(fs, fs, root, storage_runtime_wbtest_init_command()) catch {
    err => fail("init failed: \{err}")
  }
  fs.write_string(root + "/a.txt", "base\n")
  run_storage_command(
    fs,
    fs,
    root,
    storage_runtime_wbtest_add_command(["a.txt"]),
  ) catch {
    err => fail("add failed: \{err}")
  }
  run_storage_command(
    fs,
    fs,
    root,
    storage_runtime_wbtest_commit_command("base"),
  ) catch {
    err => fail("commit failed: \{err}")
  }
  let head_full = storage_runtime_wbtest_trim(
    storage_runtime_wbtest_decode_bytes(
      fs.read_file(root + "/.git/refs/heads/main"),
    ),
  )
  fs.write_string(root + "/.git/HEAD", head_full + "\n")
  let short = (try! head_full[:7]).to_string()
  let lines = storage_status_porcelain_lines(fs, root, true) catch {
    err => {
      fail("status lines failed: \{err}")
      []
    }
  }
  assert_eq(lines.length(), 1)
  assert_eq(lines[0], "## HEAD (detached at " + short + ")")
  restore_identity_for_storage_runtime_wbtest(
    prev_author_name, prev_author_email, prev_committer_name, prev_committer_email,
  )
  restore_env_var_for_storage_runtime_wbtest(
    "BIT_STORAGE_RUNTIME_QUIET", prev_quiet,
  )
}

///|
test "storage runtime: status porcelain reports MM for staged and unstaged change" {
  let fs = @git.TestFs::new()
  let root = "/repo-storage-runtime-status-mm"
  let prev_quiet = setup_storage_runtime_quiet_for_wbtest()
  let (
    prev_author_name,
    prev_author_email,
    prev_committer_name,
    prev_committer_email,
  ) = setup_identity_for_storage_runtime_wbtest()
  run_storage_command(fs, fs, root, storage_runtime_wbtest_init_command()) catch {
    err => fail("init failed: \{err}")
  }
  fs.write_string(root + "/a.txt", "base\n")
  run_storage_command(
    fs,
    fs,
    root,
    storage_runtime_wbtest_add_command(["a.txt"]),
  ) catch {
    err => fail("add failed: \{err}")
  }
  run_storage_command(
    fs,
    fs,
    root,
    storage_runtime_wbtest_commit_command("base"),
  ) catch {
    err => fail("commit failed: \{err}")
  }
  fs.write_string(root + "/a.txt", "stage-1\n")
  run_storage_command(
    fs,
    fs,
    root,
    storage_runtime_wbtest_add_command(["a.txt"]),
  ) catch {
    err => fail("stage modified failed: \{err}")
  }
  fs.write_string(root + "/a.txt", "stage-2\n")
  let lines = storage_status_porcelain_lines(fs, root, false) catch {
    err => {
      fail("status lines failed: \{err}")
      []
    }
  }
  assert_true(storage_runtime_wbtest_has_line(lines, "MM a.txt"))
  restore_identity_for_storage_runtime_wbtest(
    prev_author_name, prev_author_email, prev_committer_name, prev_committer_email,
  )
  restore_env_var_for_storage_runtime_wbtest(
    "BIT_STORAGE_RUNTIME_QUIET", prev_quiet,
  )
}

///|
test "storage runtime: status porcelain lines report staged add modify delete" {
  let fs = @git.TestFs::new()
  let root = "/repo-storage-runtime-status-staged"
  let prev_quiet = setup_storage_runtime_quiet_for_wbtest()
  let (
    prev_author_name,
    prev_author_email,
    prev_committer_name,
    prev_committer_email,
  ) = setup_identity_for_storage_runtime_wbtest()
  run_storage_command(fs, fs, root, storage_runtime_wbtest_init_command()) catch {
    err => fail("init failed: \{err}")
  }
  fs.write_string(root + "/a.txt", "base\n")
  fs.write_string(root + "/c.txt", "remove\n")
  run_storage_command(
    fs,
    fs,
    root,
    storage_runtime_wbtest_add_command(["a.txt", "c.txt"]),
  ) catch {
    err => fail("add failed: \{err}")
  }
  run_storage_command(
    fs,
    fs,
    root,
    storage_runtime_wbtest_commit_command("base"),
  ) catch {
    err => fail("commit failed: \{err}")
  }

  fs.write_string(root + "/a.txt", "changed\n")
  run_storage_command(
    fs,
    fs,
    root,
    storage_runtime_wbtest_add_command(["a.txt"]),
  ) catch {
    err => fail("stage modified failed: \{err}")
  }
  fs.write_string(root + "/b.txt", "new\n")
  run_storage_command(
    fs,
    fs,
    root,
    storage_runtime_wbtest_add_command(["b.txt"]),
  ) catch {
    err => fail("stage added failed: \{err}")
  }
  fs.remove_file(root + "/c.txt") catch {
    err => fail("remove file failed: \{err}")
  }
  run_storage_command(
    fs,
    fs,
    root,
    storage_runtime_wbtest_add_command(["c.txt"]),
  ) catch {
    err => fail("stage deleted failed: \{err}")
  }

  let lines = storage_status_porcelain_lines(fs, root, false) catch {
    err => {
      fail("status lines failed: \{err}")
      []
    }
  }
  assert_true(storage_runtime_wbtest_has_line(lines, "M  a.txt"))
  assert_true(storage_runtime_wbtest_has_line(lines, "A  b.txt"))
  assert_true(storage_runtime_wbtest_has_line(lines, "D  c.txt"))

  restore_identity_for_storage_runtime_wbtest(
    prev_author_name, prev_author_email, prev_committer_name, prev_committer_email,
  )
  restore_env_var_for_storage_runtime_wbtest(
    "BIT_STORAGE_RUNTIME_QUIET", prev_quiet,
  )
}

///|
test "storage runtime: add -A stages untracked modified deleted" {
  let fs = @git.TestFs::new()
  let root = "/repo-storage-runtime-add-all"
  let prev_quiet = setup_storage_runtime_quiet_for_wbtest()
  let (
    prev_author_name,
    prev_author_email,
    prev_committer_name,
    prev_committer_email,
  ) = setup_identity_for_storage_runtime_wbtest()
  run_storage_command(fs, fs, root, storage_runtime_wbtest_init_command()) catch {
    err => fail("init failed: \{err}")
  }
  fs.write_string(root + "/keep.txt", "keep\n")
  fs.write_string(root + "/delete.txt", "delete\n")
  run_storage_command(
    fs,
    fs,
    root,
    storage_runtime_wbtest_add_command(["keep.txt", "delete.txt"]),
  ) catch {
    err => fail("add initial failed: \{err}")
  }
  run_storage_command(
    fs,
    fs,
    root,
    storage_runtime_wbtest_commit_command("initial"),
  ) catch {
    err => fail("commit initial failed: \{err}")
  }
  fs.write_string(root + "/keep.txt", "modified\n")
  fs.remove_file(root + "/delete.txt") catch {
    err => fail("remove tracked file failed: \{err}")
  }
  fs.write_string(root + "/new.txt", "new\n")
  run_storage_command(
    fs,
    fs,
    root,
    storage_runtime_wbtest_add_command([], add_all=true),
  ) catch {
    err => fail("add -A failed: \{err}")
  }
  let lines = storage_status_porcelain_lines(fs, root, false) catch {
    err => {
      fail("status lines failed: \{err}")
      []
    }
  }
  assert_true(storage_runtime_wbtest_has_line(lines, "M  keep.txt"))
  assert_true(storage_runtime_wbtest_has_line(lines, "D  delete.txt"))
  assert_true(storage_runtime_wbtest_has_line(lines, "A  new.txt"))
  restore_identity_for_storage_runtime_wbtest(
    prev_author_name, prev_author_email, prev_committer_name, prev_committer_email,
  )
  restore_env_var_for_storage_runtime_wbtest(
    "BIT_STORAGE_RUNTIME_QUIET", prev_quiet,
  )
}

///|
test "storage runtime: commit -a stages tracked only" {
  let fs = @git.TestFs::new()
  let root = "/repo-storage-runtime-commit-all-modified"
  let prev_quiet = setup_storage_runtime_quiet_for_wbtest()
  let (
    prev_author_name,
    prev_author_email,
    prev_committer_name,
    prev_committer_email,
  ) = setup_identity_for_storage_runtime_wbtest()
  run_storage_command(fs, fs, root, storage_runtime_wbtest_init_command()) catch {
    err => fail("init failed: \{err}")
  }
  fs.write_string(root + "/tracked.txt", "base\n")
  run_storage_command(
    fs,
    fs,
    root,
    storage_runtime_wbtest_add_command(["tracked.txt"]),
  ) catch {
    err => fail("add initial failed: \{err}")
  }
  run_storage_command(
    fs,
    fs,
    root,
    storage_runtime_wbtest_commit_command("initial"),
  ) catch {
    err => fail("commit initial failed: \{err}")
  }
  fs.write_string(root + "/tracked.txt", "updated\n")
  fs.write_string(root + "/untracked.txt", "new\n")
  run_storage_command(
    fs,
    fs,
    root,
    storage_runtime_wbtest_commit_command("auto stage", all_modified=true),
  ) catch {
    err => fail("commit -a failed: \{err}")
  }
  let lines = storage_status_porcelain_lines(fs, root, false) catch {
    err => {
      fail("status lines failed: \{err}")
      []
    }
  }
  assert_true(storage_runtime_wbtest_has_line(lines, "?? untracked.txt"))
  assert_false(storage_runtime_wbtest_has_line(lines, " M tracked.txt"))
  let log_lines = @gitlib.log_head_oneline(fs, root + "/.git", max_count=1)
  assert_true(log_lines[0].contains("auto stage"))
  restore_identity_for_storage_runtime_wbtest(
    prev_author_name, prev_author_email, prev_committer_name, prev_committer_email,
  )
  restore_env_var_for_storage_runtime_wbtest(
    "BIT_STORAGE_RUNTIME_QUIET", prev_quiet,
  )
}

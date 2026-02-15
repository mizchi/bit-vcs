///|
fn cmd_storage_decode_bytes(data : Bytes) -> String {
  @utf8.decode_lossy(data[:])
}

///|
fn cmd_storage_trim(s : String) -> String {
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
fn cmd_storage_restore_env(name : String, prev : String?) -> Unit {
  match prev {
    Some(value) => @sys.set_env_var(name, value)
    None => @sys.unset_env_var(name)
  }
}

///|
fn cmd_storage_setup_test_env() -> (
  String?,
  String?,
  String?,
  String?,
  String?,
  String?,
) {
  let prev_author_name = @sys.get_env_var("GIT_AUTHOR_NAME")
  let prev_author_email = @sys.get_env_var("GIT_AUTHOR_EMAIL")
  let prev_committer_name = @sys.get_env_var("GIT_COMMITTER_NAME")
  let prev_committer_email = @sys.get_env_var("GIT_COMMITTER_EMAIL")
  let prev_committer_date = @sys.get_env_var("GIT_COMMITTER_DATE")
  let prev_quiet = @sys.get_env_var("BIT_STORAGE_RUNTIME_QUIET")
  @sys.set_env_var("GIT_AUTHOR_NAME", "Storage Delegate Test")
  @sys.set_env_var("GIT_AUTHOR_EMAIL", "storage-delegate@example.com")
  @sys.set_env_var("GIT_COMMITTER_NAME", "Storage Delegate Test")
  @sys.set_env_var("GIT_COMMITTER_EMAIL", "storage-delegate@example.com")
  @sys.set_env_var("GIT_COMMITTER_DATE", "1700000000")
  @sys.set_env_var("BIT_STORAGE_RUNTIME_QUIET", "1")
  (
    prev_author_name, prev_author_email, prev_committer_name, prev_committer_email,
    prev_committer_date, prev_quiet,
  )
}

///|
fn cmd_storage_restore_test_env(
  prev_author_name : String?,
  prev_author_email : String?,
  prev_committer_name : String?,
  prev_committer_email : String?,
  prev_committer_date : String?,
  prev_quiet : String?,
) -> Unit {
  cmd_storage_restore_env("GIT_AUTHOR_NAME", prev_author_name)
  cmd_storage_restore_env("GIT_AUTHOR_EMAIL", prev_author_email)
  cmd_storage_restore_env("GIT_COMMITTER_NAME", prev_committer_name)
  cmd_storage_restore_env("GIT_COMMITTER_EMAIL", prev_committer_email)
  cmd_storage_restore_env("GIT_COMMITTER_DATE", prev_committer_date)
  cmd_storage_restore_env("BIT_STORAGE_RUNTIME_QUIET", prev_quiet)
}

///|
fn cmd_storage_init_command() -> @runtime.StorageCommand {
  @runtime.StorageCommand::Init({
    quiet: true,
    default_branch: "main",
    ref_format: "files",
    object_format: "sha1",
  })
}

///|
fn cmd_storage_add_command(path : String) -> @runtime.StorageCommand {
  @runtime.StorageCommand::Add({ add_all: false, paths: [path] })
}

///|
fn cmd_storage_commit_command(message : String) -> @runtime.StorageCommand {
  @runtime.StorageCommand::Commit({
    message,
    all_modified: false,
    allow_empty: false,
    quiet: true,
  })
}

///|
async test "storage runtime cmd wrapper: delegates successful flow" {
  let fs = @git.TestFs::new()
  let root_cmd = "/repo-storage-runtime-cmd-wrapper"
  let root_runtime = "/repo-storage-runtime-runtime-direct"
  let (
    prev_author_name,
    prev_author_email,
    prev_committer_name,
    prev_committer_email,
    prev_committer_date,
    prev_quiet,
  ) = cmd_storage_setup_test_env()

  run_storage_command(fs, fs, root_cmd, cmd_storage_init_command()) catch {
    err => fail("cmd init failed: \{err}")
  }
  fs.write_string(root_cmd + "/a.txt", "hello\n")
  run_storage_command(fs, fs, root_cmd, cmd_storage_add_command("a.txt")) catch {
    err => fail("cmd add failed: \{err}")
  }
  run_storage_command(fs, fs, root_cmd, cmd_storage_commit_command("base")) catch {
    err => fail("cmd commit failed: \{err}")
  }

  @runtime.run_storage_command(fs, fs, root_runtime, cmd_storage_init_command()) catch {
    err => fail("runtime init failed: \{err}")
  }
  fs.write_string(root_runtime + "/a.txt", "hello\n")
  @runtime.run_storage_command(
    fs,
    fs,
    root_runtime,
    cmd_storage_add_command("a.txt"),
  ) catch {
    err => fail("runtime add failed: \{err}")
  }
  @runtime.run_storage_command(
    fs,
    fs,
    root_runtime,
    cmd_storage_commit_command("base"),
  ) catch {
    err => fail("runtime commit failed: \{err}")
  }

  let cmd_head = cmd_storage_trim(
    cmd_storage_decode_bytes(fs.read_file(root_cmd + "/.git/refs/heads/main")),
  )
  let runtime_head = cmd_storage_trim(
    cmd_storage_decode_bytes(
      fs.read_file(root_runtime + "/.git/refs/heads/main"),
    ),
  )
  assert_eq(cmd_head, runtime_head)

  cmd_storage_restore_test_env(
    prev_author_name, prev_author_email, prev_committer_name, prev_committer_email,
    prev_committer_date, prev_quiet,
  )
}

///|
async test "storage runtime cmd wrapper: delegates error path" {
  let fs = @git.TestFs::new()
  let mut cmd_error = ""
  run_storage_command_by_name(fs, fs, "/repo-cmd-error", "clone", []) catch {
    err => cmd_error = "\{err}"
  }
  assert_true(cmd_error.length() > 0)
  assert_eq(cmd_error, "InvalidObject(\"unsupported storage command: clone\")")
}

///|
fn cmd_storage_parse_should_fail(
  cmd : String,
  args : Array[String],
) -> Unit raise Error {
  let mut failed = false
  let _ = storage_runtime_parse_command(cmd, args) catch {
    _ => {
      failed = true
      @runtime.StorageCommand::Init({
        quiet: false,
        default_branch: "",
        ref_format: "",
        object_format: "",
      })
    }
  }
  assert_true(failed)
}

///|
test "storage runtime parser: init normal and invalid ref-format" {
  let parsed = storage_runtime_parse_command("init", [
    "-q", "--initial-branch", "dev", "--ref-format=files", "--object-format=sha1",
  ]) catch {
    err => {
      fail("parse init failed: \{err}")
      @runtime.StorageCommand::Init({
        quiet: false,
        default_branch: "",
        ref_format: "",
        object_format: "",
      })
    }
  }
  match parsed {
    @runtime.StorageCommand::Init(args) => {
      assert_true(args.quiet)
      assert_eq(args.default_branch, "dev")
      assert_eq(args.ref_format, "files")
      assert_eq(args.object_format, "sha1")
    }
    _ => fail("expected init command")
  }
  cmd_storage_parse_should_fail("init", ["--ref-format=reftable"])
}

///|
test "storage runtime parser: add normal and no pathspec" {
  let parsed = storage_runtime_parse_command("add", ["--", "-file"]) catch {
    err => {
      fail("parse add failed: \{err}")
      @runtime.StorageCommand::Add({ add_all: false, paths: [] })
    }
  }
  match parsed {
    @runtime.StorageCommand::Add(args) => {
      assert_false(args.add_all)
      assert_eq(args.paths, ["-file"])
    }
    _ => fail("expected add command")
  }
  cmd_storage_parse_should_fail("add", [])
}

///|
test "storage runtime parser: commit normal and missing message" {
  let parsed = storage_runtime_parse_command("commit", [
    "-am", "msg", "--allow-empty", "-q",
  ]) catch {
    err => {
      fail("parse commit failed: \{err}")
      @runtime.StorageCommand::Commit({
        message: "",
        all_modified: false,
        allow_empty: false,
        quiet: false,
      })
    }
  }
  match parsed {
    @runtime.StorageCommand::Commit(args) => {
      assert_eq(args.message, "msg")
      assert_true(args.all_modified)
      assert_true(args.allow_empty)
      assert_true(args.quiet)
    }
    _ => fail("expected commit command")
  }
  cmd_storage_parse_should_fail("commit", [])
}

///|
test "storage runtime parser: status normal and pathspec invalid" {
  let parsed = storage_runtime_parse_command("status", ["-sb"]) catch {
    err => {
      fail("parse status failed: \{err}")
      @runtime.StorageCommand::Status({
        porcelain: false,
        short: false,
        show_branch: false,
      })
    }
  }
  match parsed {
    @runtime.StorageCommand::Status(args) => {
      assert_false(args.porcelain)
      assert_true(args.short)
      assert_true(args.show_branch)
    }
    _ => fail("expected status command")
  }
  cmd_storage_parse_should_fail("status", ["a.txt"])
}

///|
test "storage runtime parser: log normal and revision invalid" {
  let parsed = storage_runtime_parse_command("log", [
    "--oneline", "--max-count=3",
  ]) catch {
    err => {
      fail("parse log failed: \{err}")
      @runtime.StorageCommand::Log({ oneline: false, max_count: 0 })
    }
  }
  match parsed {
    @runtime.StorageCommand::Log(args) => {
      assert_true(args.oneline)
      assert_eq(args.max_count, 3)
    }
    _ => fail("expected log command")
  }
  cmd_storage_parse_should_fail("log", ["HEAD"])
}

///|
test "storage runtime parser: hash-object normal and invalid type" {
  let parsed = storage_runtime_parse_command("hash-object", [
    "-w", "-t", "tree", "x.txt",
  ]) catch {
    err => {
      fail("parse hash-object failed: \{err}")
      @runtime.StorageCommand::HashObject({
        write_object: false,
        stdin_mode: false,
        obj_type: @git.ObjectType::Blob,
        paths: [],
      })
    }
  }
  match parsed {
    @runtime.StorageCommand::HashObject(args) => {
      assert_true(args.write_object)
      assert_false(args.stdin_mode)
      assert_eq(args.obj_type, @git.ObjectType::Tree)
      assert_eq(args.paths, ["x.txt"])
    }
    _ => fail("expected hash-object command")
  }
  cmd_storage_parse_should_fail("hash-object", ["-t", "unknown", "x.txt"])
}

///|
test "storage runtime parser: write-tree normal and invalid option" {
  let parsed = storage_runtime_parse_command("write-tree", ["--prefix=sub/"]) catch {
    err => {
      fail("parse write-tree failed: \{err}")
      @runtime.StorageCommand::WriteTree({ prefix: None })
    }
  }
  match parsed {
    @runtime.StorageCommand::WriteTree(args) =>
      assert_eq(args.prefix, Some("sub/"))
    _ => fail("expected write-tree command")
  }
  cmd_storage_parse_should_fail("write-tree", ["--unknown"])
}

///|
test "storage runtime parser: update-ref normal and missing value" {
  let parsed = storage_runtime_parse_command("update-ref", [
    "refs/heads/dev", "@",
  ]) catch {
    err => {
      fail("parse update-ref failed: \{err}")
      @runtime.StorageCommand::UpdateRef({
        delete_mode: false,
        refname: "",
        new_value: None,
        old_value: None,
      })
    }
  }
  match parsed {
    @runtime.StorageCommand::UpdateRef(args) => {
      assert_false(args.delete_mode)
      assert_eq(args.refname, "refs/heads/dev")
      assert_eq(args.new_value, Some("@"))
      assert_eq(args.old_value, None)
    }
    _ => fail("expected update-ref command")
  }
  let parsed_delete = storage_runtime_parse_command("update-ref", [
    "-d", "refs/heads/dev", "oldhash",
  ]) catch {
    err => {
      fail("parse update-ref delete failed: \{err}")
      @runtime.StorageCommand::UpdateRef({
        delete_mode: false,
        refname: "",
        new_value: None,
        old_value: None,
      })
    }
  }
  match parsed_delete {
    @runtime.StorageCommand::UpdateRef(args) => {
      assert_true(args.delete_mode)
      assert_eq(args.refname, "refs/heads/dev")
      assert_eq(args.new_value, None)
      assert_eq(args.old_value, Some("oldhash"))
    }
    _ => fail("expected update-ref command")
  }
  cmd_storage_parse_should_fail("update-ref", ["refs/heads/dev"])
}

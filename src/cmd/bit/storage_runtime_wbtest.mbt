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

///|
let checkout_wbtest_shim_lock : @async.Semaphore = @async.Semaphore(
  1,
  initial_value=1,
)

///|
async fn checkout_wbtest_collect_shim_git_output(
  cwd : String,
  args : Array[String],
) -> (Int, String, String) raise Error {
  checkout_wbtest_shim_lock.acquire()
  defer checkout_wbtest_shim_lock.release()
  let repo_root = wbtest_resolve_repo_root()
  let shim_git = repo_root + "/tools/git-shim/bin/git"
  let shim_moon = "/tmp/bit-checkout-shim-moon.sh"
  let fs = OsFs::new()
  // Build the native binary first so exit codes propagate correctly
  // (moon run swallows non-zero exit codes)
  let bit_exe = wbtest_resolve_bit_exe(repo_root)
  if !fs.is_file(bit_exe) {
    fail(
      "bit.exe not found at \{bit_exe}; build it with `moon build --target native modules/bit/cmd/bit` first",
    )
  }
  fs.write_string(shim_moon, "#!/bin/sh\nset -eu\nexec '\{bit_exe}' \"$@\"\n")
  let chmod_code = @process.run("chmod", ["+x", shim_moon], inherit_env=true)
  @test.assert_eq(chmod_code, 0)
  let env : Map[String, String] = {
    "SHIM_REAL_GIT": wbtest_resolve_real_git(repo_root),
    "SHIM_EXEC_PATH": repo_root + "/third_party/git",
    "SHIM_MOON": shim_moon,
    "SHIM_CMDS": "checkout",
    "SHIM_STRICT": "1",
  }
  let git_args : Array[String] = ["-C", cwd]
  for arg in args {
    git_args.push(arg)
  }
  let (code, stdout, stderr) = @process.collect_output(
    shim_git,
    git_args[:],
    extra_env=env,
    inherit_env=true,
  )
  let stdout_text = stdout.text() catch { _ => "" }
  let stderr_text = stderr.text() catch { _ => "" }
  (code, stdout_text, stderr_text)
}

///|
async fn checkout_wbtest_run_shim_git(
  cwd : String,
  args : Array[String],
) -> Unit raise Error {
  let (code, stdout, stderr) = checkout_wbtest_collect_shim_git_output(
    cwd, args,
  )
  @test.assert_eq(code, 0)
  @test.assert_eq(stdout, "")
  @test.assert_eq(stderr, "")
}

///|
test "checkout: tracked path detection sees deleted gitmodules in index" {
  let fs = @bitcore.TestFs::new()
  @bitlib.init_repo(fs, "/repo")
  fs.write_string(
    "/repo/.gitmodules", "[submodule \"example\"]\n\tpath = example\n\turl = ../example\n",
  )
  @bitlib.add_paths(fs, fs, "/repo", [".gitmodules"])
  fs.remove_file("/repo/.gitmodules")

  assert_true(checkout_target_is_tracked_path(fs, "/repo/.git", ".gitmodules"))
  assert_false(checkout_target_is_tracked_path(fs, "/repo/.git", "missing"))
}

///|
async fn checkout_wbtest_case_treeish_restore() -> Unit raise Error {
  @bitnative.init_native_io()
  let fs = OsFs::new()
  let root = "/tmp/bit-test-checkout-treeish-path-" +
    get_current_timestamp().to_string()
  cleanup_tree(fs, root)
  fs.mkdir_p(root)
  let repo_dir = root + "/repo"
  let linked_dir = root + "/linked"

  let prev_shim_cwd = @sys.get_env_var("GIT_SHIM_CWD")
  let prev_shim_pwd = @sys.get_env_var("GIT_SHIM_PWD")
  let prev_git_dir = @sys.get_env_var("GIT_DIR")
  let prev_work_tree = @sys.get_env_var("GIT_WORK_TREE")

  add_test_run_git(root, ["init", "--initial-branch=main", "-q", "repo"])
  add_test_run_git(repo_dir, ["config", "user.name", "Test User"])
  add_test_run_git(repo_dir, ["config", "user.email", "test@example.com"])
  fs.write_string(repo_dir + "/init.t", "main\n")
  add_test_run_git(repo_dir, ["add", "init.t"])
  add_test_run_git(repo_dir, ["commit", "-q", "-m", "main"])
  add_test_run_git(repo_dir, ["checkout", "-q", "-b", "newmain"])
  fs.write_string(repo_dir + "/init.t", "newmain\n")
  add_test_run_git(repo_dir, ["commit", "-qam", "newmain"])
  add_test_run_git(repo_dir, ["checkout", "-q", "main"])

  @bitlib.create_worktree(
    fs,
    fs,
    repo_dir,
    linked_dir,
    Some("newmain"),
    new_branch=None,
  )
  fs.write_string(repo_dir + "/init.t", "dirty\n")

  @sys.set_env_var("GIT_SHIM_CWD", repo_dir)
  @sys.set_env_var("GIT_SHIM_PWD", repo_dir)
  @sys.unset_env_var("GIT_DIR")
  @sys.unset_env_var("GIT_WORK_TREE")
  checkout_wbtest_run_shim_git(repo_dir, [
    "checkout", "-q", "newmain", "--", "init.t",
  ])

  @test.assert_eq(decode_bytes(fs.read_file(repo_dir + "/init.t")), "newmain\n")
  @test.assert_eq(
    add_test_git_stdout(repo_dir, ["symbolic-ref", "--short", "HEAD"]),
    "main\n",
  )

  add_test_restore_env("GIT_SHIM_CWD", prev_shim_cwd)
  add_test_restore_env("GIT_SHIM_PWD", prev_shim_pwd)
  add_test_restore_env("GIT_DIR", prev_git_dir)
  add_test_restore_env("GIT_WORK_TREE", prev_work_tree)
  cleanup_tree(fs, root)
}

///|
async fn checkout_wbtest_case_switch_back_to_main() -> Unit raise Error {
  @bitnative.init_native_io()
  let fs = OsFs::new()
  let root = "/tmp/bit-test-checkout-switch-main-" +
    get_current_timestamp().to_string()
  cleanup_tree(fs, root)
  fs.mkdir_p(root)
  let repo_dir = root + "/repo"

  let prev_shim_cwd = @sys.get_env_var("GIT_SHIM_CWD")
  let prev_shim_pwd = @sys.get_env_var("GIT_SHIM_PWD")
  let prev_git_dir = @sys.get_env_var("GIT_DIR")
  let prev_work_tree = @sys.get_env_var("GIT_WORK_TREE")

  add_test_run_git(root, ["init", "--initial-branch=main", "-q", "repo"])
  add_test_run_git(repo_dir, ["config", "user.name", "Test User"])
  add_test_run_git(repo_dir, ["config", "user.email", "test@example.com"])
  fs.write_string(repo_dir + "/init.t", "main\n")
  add_test_run_git(repo_dir, ["add", "init.t"])
  add_test_run_git(repo_dir, ["commit", "-q", "-m", "main"])

  @sys.set_env_var("GIT_SHIM_CWD", repo_dir)
  @sys.set_env_var("GIT_SHIM_PWD", repo_dir)
  @sys.unset_env_var("GIT_DIR")
  @sys.unset_env_var("GIT_WORK_TREE")

  checkout_wbtest_run_shim_git(repo_dir, ["checkout", "-q", "-b", "newbranch"])
  fs.write_string(repo_dir + "/myworld", "hello\n")
  add_test_run_git(repo_dir, ["add", "myworld"])
  add_test_run_git(repo_dir, ["commit", "-q", "-m", "myworld"])

  checkout_wbtest_run_shim_git(repo_dir, ["checkout", "-q", "main"])

  @test.assert_eq(
    add_test_git_stdout(repo_dir, ["symbolic-ref", "--short", "HEAD"]),
    "main\n",
  )

  add_test_restore_env("GIT_SHIM_CWD", prev_shim_cwd)
  add_test_restore_env("GIT_SHIM_PWD", prev_shim_pwd)
  add_test_restore_env("GIT_DIR", prev_git_dir)
  add_test_restore_env("GIT_WORK_TREE", prev_work_tree)
  cleanup_tree(fs, root)
}

///|
async fn checkout_wbtest_case_switch_back_with_detached_worktree() -> Unit raise Error {
  @bitnative.init_native_io()
  let fs = OsFs::new()
  let root = "/tmp/bit-test-checkout-switch-main-linked-" +
    get_current_timestamp().to_string()
  cleanup_tree(fs, root)
  fs.mkdir_p(root)
  let repo_dir = root + "/repo"
  let detached_dir = root + "/existing_empty"

  let prev_shim_cwd = @sys.get_env_var("GIT_SHIM_CWD")
  let prev_shim_pwd = @sys.get_env_var("GIT_SHIM_PWD")
  let prev_git_dir = @sys.get_env_var("GIT_DIR")
  let prev_work_tree = @sys.get_env_var("GIT_WORK_TREE")

  add_test_run_git(root, ["init", "--initial-branch=main", "-q", "repo"])
  add_test_run_git(repo_dir, ["config", "user.name", "Test User"])
  add_test_run_git(repo_dir, ["config", "user.email", "test@example.com"])
  fs.write_string(repo_dir + "/init.t", "main\n")
  add_test_run_git(repo_dir, ["add", "init.t"])
  add_test_run_git(repo_dir, ["commit", "-q", "-m", "main"])

  @bitlib.create_worktree(
    fs,
    fs,
    repo_dir,
    detached_dir,
    Some("main"),
    detach=true,
    new_branch=None,
  )

  @sys.set_env_var("GIT_SHIM_CWD", repo_dir)
  @sys.set_env_var("GIT_SHIM_PWD", repo_dir)
  @sys.unset_env_var("GIT_DIR")
  @sys.unset_env_var("GIT_WORK_TREE")

  checkout_wbtest_run_shim_git(repo_dir, ["checkout", "-q", "-b", "newbranch"])
  fs.write_string(repo_dir + "/myworld", "hello\n")
  add_test_run_git(repo_dir, ["add", "myworld"])
  add_test_run_git(repo_dir, ["commit", "-q", "-m", "myworld"])

  checkout_wbtest_run_shim_git(repo_dir, ["checkout", "-q", "main"])

  @test.assert_eq(
    add_test_git_stdout(repo_dir, ["symbolic-ref", "--short", "HEAD"]),
    "main\n",
  )

  add_test_restore_env("GIT_SHIM_CWD", prev_shim_cwd)
  add_test_restore_env("GIT_SHIM_PWD", prev_shim_pwd)
  add_test_restore_env("GIT_DIR", prev_git_dir)
  add_test_restore_env("GIT_WORK_TREE", prev_work_tree)
  cleanup_tree(fs, root)
}

///|
async fn checkout_wbtest_case_switch_back_after_shim_commit() -> Unit raise Error {
  @bitnative.init_native_io()
  let fs = OsFs::new()
  let root = "/tmp/bit-test-checkout-switch-main-shim-commit-" +
    get_current_timestamp().to_string()
  cleanup_tree(fs, root)
  fs.mkdir_p(root)
  let repo_dir = root + "/repo"

  let prev_shim_cwd = @sys.get_env_var("GIT_SHIM_CWD")
  let prev_shim_pwd = @sys.get_env_var("GIT_SHIM_PWD")
  let prev_git_dir = @sys.get_env_var("GIT_DIR")
  let prev_work_tree = @sys.get_env_var("GIT_WORK_TREE")

  add_test_run_git(root, ["init", "--initial-branch=main", "-q", "repo"])
  add_test_run_git(repo_dir, ["config", "user.name", "Test User"])
  add_test_run_git(repo_dir, ["config", "user.email", "test@example.com"])
  fs.write_string(repo_dir + "/init.t", "main\n")
  add_test_run_git(repo_dir, ["add", "init.t"])
  add_test_run_git(repo_dir, ["commit", "-q", "-m", "main"])

  @sys.set_env_var("GIT_SHIM_CWD", repo_dir)
  @sys.set_env_var("GIT_SHIM_PWD", repo_dir)
  @sys.unset_env_var("GIT_DIR")
  @sys.unset_env_var("GIT_WORK_TREE")

  checkout_wbtest_run_shim_git(repo_dir, ["checkout", "-q", "-b", "newbranch"])
  fs.write_string(repo_dir + "/myworld", "hello\n")
  handle_add(["myworld"])
  handle_commit(["-q", "-m", "myworld"])

  checkout_wbtest_run_shim_git(repo_dir, ["checkout", "-q", "main"])

  @test.assert_eq(
    add_test_git_stdout(repo_dir, ["symbolic-ref", "--short", "HEAD"]),
    "main\n",
  )

  add_test_restore_env("GIT_SHIM_CWD", prev_shim_cwd)
  add_test_restore_env("GIT_SHIM_PWD", prev_shim_pwd)
  add_test_restore_env("GIT_DIR", prev_git_dir)
  add_test_restore_env("GIT_WORK_TREE", prev_work_tree)
  cleanup_tree(fs, root)
}

///|
async fn checkout_wbtest_case_branch_in_use() -> Unit raise Error {
  @bitnative.init_native_io()
  let fs = OsFs::new()
  let root = "/tmp/bit-test-checkout-branch-in-use-" +
    get_current_timestamp().to_string()
  cleanup_tree(fs, root)
  fs.mkdir_p(root)
  let repo_dir = root + "/repo"
  let linked_dir = root + "/linked"

  let prev_shim_cwd = @sys.get_env_var("GIT_SHIM_CWD")
  let prev_shim_pwd = @sys.get_env_var("GIT_SHIM_PWD")
  let prev_git_dir = @sys.get_env_var("GIT_DIR")
  let prev_work_tree = @sys.get_env_var("GIT_WORK_TREE")

  add_test_run_git(root, ["init", "--initial-branch=main", "-q", "repo"])
  add_test_run_git(repo_dir, ["config", "user.name", "Test User"])
  add_test_run_git(repo_dir, ["config", "user.email", "test@example.com"])
  fs.write_string(repo_dir + "/init.t", "main\n")
  add_test_run_git(repo_dir, ["add", "init.t"])
  add_test_run_git(repo_dir, ["commit", "-q", "-m", "main"])

  @bitlib.create_worktree(
    fs,
    fs,
    repo_dir,
    linked_dir,
    Some("main"),
    new_branch=Some("newmain"),
  )

  @sys.set_env_var("GIT_SHIM_CWD", repo_dir)
  @sys.set_env_var("GIT_SHIM_PWD", repo_dir)
  @sys.unset_env_var("GIT_DIR")
  @sys.unset_env_var("GIT_WORK_TREE")

  let (_, stdout, stderr) = checkout_wbtest_collect_shim_git_output(repo_dir, [
    "checkout", "-q", "newmain",
  ])
  @test.assert_eq(stdout, "")
  assert_true(stderr.contains("already used by worktree at"))
  @test.assert_eq(
    add_test_git_stdout(repo_dir, ["symbolic-ref", "--short", "HEAD"]),
    "main\n",
  )

  add_test_restore_env("GIT_SHIM_CWD", prev_shim_cwd)
  add_test_restore_env("GIT_SHIM_PWD", prev_shim_pwd)
  add_test_restore_env("GIT_DIR", prev_git_dir)
  add_test_restore_env("GIT_WORK_TREE", prev_work_tree)
  cleanup_tree(fs, root)
}

///|
async fn checkout_wbtest_case_force_branch_in_use() -> Unit raise Error {
  @bitnative.init_native_io()
  let fs = OsFs::new()
  let root = "/tmp/bit-test-checkout-force-branch-in-use-" +
    get_current_timestamp().to_string()
  cleanup_tree(fs, root)
  fs.mkdir_p(root)
  let repo_dir = root + "/repo"
  let linked_dir = root + "/linked"

  let prev_shim_cwd = @sys.get_env_var("GIT_SHIM_CWD")
  let prev_shim_pwd = @sys.get_env_var("GIT_SHIM_PWD")
  let prev_git_dir = @sys.get_env_var("GIT_DIR")
  let prev_work_tree = @sys.get_env_var("GIT_WORK_TREE")

  add_test_run_git(root, ["init", "--initial-branch=main", "-q", "repo"])
  add_test_run_git(repo_dir, ["config", "user.name", "Test User"])
  add_test_run_git(repo_dir, ["config", "user.email", "test@example.com"])
  fs.write_string(repo_dir + "/init.t", "main\n")
  add_test_run_git(repo_dir, ["add", "init.t"])
  add_test_run_git(repo_dir, ["commit", "-q", "-m", "main"])

  @bitlib.create_worktree(
    fs,
    fs,
    repo_dir,
    linked_dir,
    Some("main"),
    new_branch=Some("newmain"),
  )
  add_test_run_git(repo_dir, ["checkout", "--detach", "-q", "HEAD"])

  @sys.set_env_var("GIT_SHIM_CWD", repo_dir)
  @sys.set_env_var("GIT_SHIM_PWD", repo_dir)
  @sys.unset_env_var("GIT_DIR")
  @sys.unset_env_var("GIT_WORK_TREE")

  @test.assert_eq(
    checkout_branch_in_use_path(fs, repo_dir, "newmain"),
    Some(linked_dir),
  )
  let before_head = add_test_git_stdout(repo_dir, [
    "rev-parse", "--verify", "HEAD",
  ])
  let before_branch = add_test_git_stdout(repo_dir, [
    "rev-parse", "--verify", "refs/heads/newmain",
  ])
  let (_, stdout, stderr) = checkout_wbtest_collect_shim_git_output(repo_dir, [
    "checkout", "-q", "-B", "newmain",
  ])
  @test.assert_eq(stdout, "")
  assert_true(stderr.contains("already used by worktree at"))
  @test.assert_eq(
    add_test_git_stdout(repo_dir, [
      "rev-parse", "--verify", "refs/heads/newmain",
    ]),
    before_branch,
  )
  @test.assert_eq(
    add_test_git_stdout(repo_dir, ["rev-parse", "--verify", "HEAD"]),
    before_head,
  )

  add_test_restore_env("GIT_SHIM_CWD", prev_shim_cwd)
  add_test_restore_env("GIT_SHIM_PWD", prev_shim_pwd)
  add_test_restore_env("GIT_DIR", prev_git_dir)
  add_test_restore_env("GIT_WORK_TREE", prev_work_tree)
  cleanup_tree(fs, root)
}

///|
async fn checkout_wbtest_case_symlinked_branch_in_use() -> Unit raise Error {
  @bitnative.init_native_io()
  let fs = OsFs::new()
  let root = "/tmp/bit-test-checkout-symlink-branch-in-use-" +
    get_current_timestamp().to_string()
  cleanup_tree(fs, root)
  fs.mkdir_p(root)
  let repo_dir = root + "/repo"
  let linked_dir = root + "/there"
  let linked_head = repo_dir + "/.git/worktrees/there/HEAD"

  let prev_shim_cwd = @sys.get_env_var("GIT_SHIM_CWD")
  let prev_shim_pwd = @sys.get_env_var("GIT_SHIM_PWD")
  let prev_git_dir = @sys.get_env_var("GIT_DIR")
  let prev_work_tree = @sys.get_env_var("GIT_WORK_TREE")

  add_test_run_git(root, ["init", "--initial-branch=main", "-q", "repo"])
  add_test_run_git(repo_dir, ["config", "user.name", "Test User"])
  add_test_run_git(repo_dir, ["config", "user.email", "test@example.com"])
  fs.write_string(repo_dir + "/init.t", "main\n")
  add_test_run_git(repo_dir, ["add", "init.t"])
  add_test_run_git(repo_dir, ["commit", "-q", "-m", "main"])

  @bitlib.create_worktree(
    fs,
    fs,
    repo_dir,
    linked_dir,
    Some("main"),
    new_branch=Some("newmain"),
  )
  fs.remove_file(linked_head)
  let link_code = @process.run(
    "ln",
    ["-s", "refs/heads/newmain", linked_head],
    inherit_env=true,
    cwd=root,
  )
  @test.assert_eq(link_code, 0)

  @sys.set_env_var("GIT_SHIM_CWD", repo_dir)
  @sys.set_env_var("GIT_SHIM_PWD", repo_dir)
  @sys.unset_env_var("GIT_DIR")
  @sys.unset_env_var("GIT_WORK_TREE")

  @test.assert_eq(
    checkout_branch_in_use_path(fs, repo_dir, "newmain"),
    Some(linked_dir),
  )
  let (_, stdout, stderr) = checkout_wbtest_collect_shim_git_output(repo_dir, [
    "checkout", "-q", "newmain",
  ])
  @test.assert_eq(stdout, "")
  assert_true(stderr.contains("already used by worktree at"))

  add_test_restore_env("GIT_SHIM_CWD", prev_shim_cwd)
  add_test_restore_env("GIT_SHIM_PWD", prev_shim_pwd)
  add_test_restore_env("GIT_DIR", prev_git_dir)
  add_test_restore_env("GIT_WORK_TREE", prev_work_tree)
  cleanup_tree(fs, root)
}

///|
async fn checkout_wbtest_case_recheckout_current_branch_with_symlink_head() -> Unit raise Error {
  @bitnative.init_native_io()
  let fs = OsFs::new()
  let root = "/tmp/bit-test-checkout-current-branch-symlink-head-" +
    get_current_timestamp().to_string()
  cleanup_tree(fs, root)
  fs.mkdir_p(root)
  let repo_dir = root + "/repo"
  let linked_dir = root + "/there"
  let linked_head = repo_dir + "/.git/worktrees/there/HEAD"

  let prev_shim_cwd = @sys.get_env_var("GIT_SHIM_CWD")
  let prev_shim_pwd = @sys.get_env_var("GIT_SHIM_PWD")
  let prev_git_dir = @sys.get_env_var("GIT_DIR")
  let prev_work_tree = @sys.get_env_var("GIT_WORK_TREE")

  add_test_run_git(root, ["init", "--initial-branch=main", "-q", "repo"])
  add_test_run_git(repo_dir, ["config", "user.name", "Test User"])
  add_test_run_git(repo_dir, ["config", "user.email", "test@example.com"])
  fs.write_string(repo_dir + "/init.t", "main\n")
  add_test_run_git(repo_dir, ["add", "init.t"])
  add_test_run_git(repo_dir, ["commit", "-q", "-m", "main"])

  @bitlib.create_worktree(
    fs,
    fs,
    repo_dir,
    linked_dir,
    Some("main"),
    new_branch=Some("newmain"),
  )
  fs.remove_file(linked_head)
  let link_code = @process.run(
    "ln",
    ["-s", "refs/heads/newmain", linked_head],
    inherit_env=true,
    cwd=root,
  )
  @test.assert_eq(link_code, 0)

  @sys.set_env_var("GIT_SHIM_CWD", linked_dir)
  @sys.set_env_var("GIT_SHIM_PWD", linked_dir)
  @sys.unset_env_var("GIT_DIR")
  @sys.unset_env_var("GIT_WORK_TREE")

  checkout_wbtest_run_shim_git(linked_dir, ["checkout", "-q", "newmain"])

  @test.assert_eq(
    add_test_git_stdout(linked_dir, ["symbolic-ref", "HEAD"]),
    "refs/heads/newmain\n",
  )

  add_test_restore_env("GIT_SHIM_CWD", prev_shim_cwd)
  add_test_restore_env("GIT_SHIM_PWD", prev_shim_pwd)
  add_test_restore_env("GIT_DIR", prev_git_dir)
  add_test_restore_env("GIT_WORK_TREE", prev_work_tree)
  cleanup_tree(fs, root)
}

///|
async fn checkout_wbtest_case_bare_repo_checkout_fails() -> Unit raise Error {
  @bitnative.init_native_io()
  let fs = OsFs::new()
  let root = "/tmp/bit-test-checkout-bare-repo-" +
    get_current_timestamp().to_string()
  cleanup_tree(fs, root)
  fs.mkdir_p(root)
  let repo_dir = root + "/repo"
  let bare_dir = root + "/bare.git"

  let prev_shim_cwd = @sys.get_env_var("GIT_SHIM_CWD")
  let prev_shim_pwd = @sys.get_env_var("GIT_SHIM_PWD")
  let prev_git_dir = @sys.get_env_var("GIT_DIR")
  let prev_work_tree = @sys.get_env_var("GIT_WORK_TREE")

  add_test_run_git(root, ["init", "--initial-branch=main", "-q", "repo"])
  add_test_run_git(repo_dir, ["config", "user.name", "Test User"])
  add_test_run_git(repo_dir, ["config", "user.email", "test@example.com"])
  fs.write_string(repo_dir + "/init.t", "main\n")
  add_test_run_git(repo_dir, ["add", "init.t"])
  add_test_run_git(repo_dir, ["commit", "-q", "-m", "main"])
  add_test_run_git(root, ["clone", "--bare", "repo", "bare.git"])

  @sys.set_env_var("GIT_SHIM_CWD", bare_dir)
  @sys.set_env_var("GIT_SHIM_PWD", bare_dir)
  @sys.unset_env_var("GIT_DIR")
  @sys.unset_env_var("GIT_WORK_TREE")

  let (_, stdout, stderr) = checkout_wbtest_collect_shim_git_output(bare_dir, [
    "checkout", "-q", "main",
  ])
  @test.assert_eq(stdout, "")
  assert_true(stderr.length() > 0)

  add_test_restore_env("GIT_SHIM_CWD", prev_shim_cwd)
  add_test_restore_env("GIT_SHIM_PWD", prev_shim_pwd)
  add_test_restore_env("GIT_DIR", prev_git_dir)
  add_test_restore_env("GIT_WORK_TREE", prev_work_tree)
  cleanup_tree(fs, root)
}

///|
async fn checkout_wbtest_case_orphan_branch() -> Unit raise Error {
  @bitnative.init_native_io()
  let fs = OsFs::new()
  let root = "/tmp/bit-test-checkout-orphan-" +
    get_current_timestamp().to_string()
  cleanup_tree(fs, root)
  fs.mkdir_p(root)
  let repo_dir = root + "/repo"

  let prev_shim_cwd = @sys.get_env_var("GIT_SHIM_CWD")
  let prev_shim_pwd = @sys.get_env_var("GIT_SHIM_PWD")
  let prev_git_dir = @sys.get_env_var("GIT_DIR")
  let prev_work_tree = @sys.get_env_var("GIT_WORK_TREE")

  add_test_run_git(root, ["init", "--initial-branch=main", "-q", "repo"])
  add_test_run_git(repo_dir, ["config", "user.name", "Test User"])
  add_test_run_git(repo_dir, ["config", "user.email", "test@example.com"])
  fs.write_string(repo_dir + "/init.t", "main\n")
  add_test_run_git(repo_dir, ["add", "init.t"])
  add_test_run_git(repo_dir, ["commit", "-q", "-m", "main"])

  @sys.set_env_var("GIT_SHIM_CWD", repo_dir)
  @sys.set_env_var("GIT_SHIM_PWD", repo_dir)
  @sys.unset_env_var("GIT_DIR")
  @sys.unset_env_var("GIT_WORK_TREE")

  checkout_wbtest_run_shim_git(repo_dir, [
    "checkout", "-q", "--orphan", "orphan1",
  ])

  @test.assert_eq(
    add_test_git_stdout(repo_dir, ["symbolic-ref", "--short", "HEAD"]),
    "orphan1\n",
  )
  assert_false(fs.is_file(repo_dir + "/.git/refs/heads/orphan1"))
  @test.assert_eq(
    @bitlib.read_index_entries(fs, repo_dir + "/.git").length(),
    1,
  )
  @test.assert_eq(add_test_git_stdout(repo_dir, ["ls-files"]), "init.t\n")
  @test.assert_eq(@fs.read_file_to_string(repo_dir + "/init.t"), "main\n")

  add_test_restore_env("GIT_SHIM_CWD", prev_shim_cwd)
  add_test_restore_env("GIT_SHIM_PWD", prev_shim_pwd)
  add_test_restore_env("GIT_DIR", prev_git_dir)
  add_test_restore_env("GIT_WORK_TREE", prev_work_tree)
  cleanup_tree(fs, root)
}

///|
async fn checkout_wbtest_case_checkout_updates_head_reflog() -> Unit raise Error {
  @bitnative.init_native_io()
  let fs = OsFs::new()
  let root = "/tmp/bit-test-checkout-reflog-" +
    get_current_timestamp().to_string()
  cleanup_tree(fs, root)
  fs.mkdir_p(root)
  let repo_dir = root + "/repo"

  let prev_shim_cwd = @sys.get_env_var("GIT_SHIM_CWD")
  let prev_shim_pwd = @sys.get_env_var("GIT_SHIM_PWD")
  let prev_git_dir = @sys.get_env_var("GIT_DIR")
  let prev_work_tree = @sys.get_env_var("GIT_WORK_TREE")

  add_test_run_git(root, ["init", "--initial-branch=main", "-q", "repo"])
  add_test_run_git(repo_dir, ["config", "user.name", "Test User"])
  add_test_run_git(repo_dir, ["config", "user.email", "test@example.com"])
  fs.write_string(repo_dir + "/init.t", "initial\n")
  add_test_run_git(repo_dir, ["add", "init.t"])
  add_test_run_git(repo_dir, ["commit", "-q", "-m", "initial"])
  add_test_run_git(repo_dir, ["branch", "side"])
  fs.write_string(repo_dir + "/init.t", "second\n")
  add_test_run_git(repo_dir, ["commit", "-am", "second", "-q"])

  @sys.set_env_var("GIT_SHIM_CWD", repo_dir)
  @sys.set_env_var("GIT_SHIM_PWD", repo_dir)
  @sys.unset_env_var("GIT_DIR")
  @sys.unset_env_var("GIT_WORK_TREE")

  let before = @bitrepo.read_reflog(fs, repo_dir + "/.git", "HEAD")
  @test.assert_eq(before.length(), 2)

  checkout_wbtest_run_shim_git(repo_dir, ["checkout", "-q", "side"])

  let side_id = @bitcore.ObjectId::from_hex(
    trim_string(add_test_git_stdout(repo_dir, ["rev-parse", "side"])),
  )
  let after_branch = @bitrepo.read_reflog(fs, repo_dir + "/.git", "HEAD")
  @test.assert_eq(after_branch.length(), 3)
  @test.assert_eq(after_branch[after_branch.length() - 1].new_id, side_id)

  checkout_wbtest_run_shim_git(repo_dir, ["checkout", "-q", "main^0"])

  let main_id = @bitcore.ObjectId::from_hex(
    trim_string(add_test_git_stdout(repo_dir, ["rev-parse", "main"])),
  )
  let after_detach = @bitrepo.read_reflog(fs, repo_dir + "/.git", "HEAD")
  @test.assert_eq(after_detach.length(), 4)
  @test.assert_eq(after_detach[after_detach.length() - 1].new_id, main_id)

  add_test_restore_env("GIT_SHIM_CWD", prev_shim_cwd)
  add_test_restore_env("GIT_SHIM_PWD", prev_shim_pwd)
  add_test_restore_env("GIT_DIR", prev_git_dir)
  add_test_restore_env("GIT_WORK_TREE", prev_work_tree)
  cleanup_tree(fs, root)
}

///|
async fn checkout_wbtest_case_force_checkout_clears_merge_state() -> Unit raise Error {
  @bitnative.init_native_io()
  let fs = OsFs::new()
  let root = "/tmp/bit-test-checkout-force-clears-merge-state-" +
    get_current_timestamp().to_string()
  cleanup_tree(fs, root)
  fs.mkdir_p(root)
  let repo_dir = root + "/repo"

  let prev_shim_cwd = @sys.get_env_var("GIT_SHIM_CWD")
  let prev_shim_pwd = @sys.get_env_var("GIT_SHIM_PWD")
  let prev_git_dir = @sys.get_env_var("GIT_DIR")
  let prev_work_tree = @sys.get_env_var("GIT_WORK_TREE")

  add_test_run_git(root, ["init", "--initial-branch=main", "-q", "repo"])
  add_test_run_git(repo_dir, ["config", "user.name", "Test User"])
  add_test_run_git(repo_dir, ["config", "user.email", "test@example.com"])
  fs.write_string(repo_dir + "/file", "main\n")
  add_test_run_git(repo_dir, ["add", "file"])
  add_test_run_git(repo_dir, ["commit", "-q", "-m", "main"])
  add_test_run_git(repo_dir, ["checkout", "-q", "-b", "side"])
  fs.write_string(repo_dir + "/file", "side\n")
  add_test_run_git(repo_dir, ["commit", "-q", "-a", "-m", "side"])
  add_test_run_git(repo_dir, ["checkout", "-q", "main"])
  let side_id = trim_string(
    add_test_git_stdout(repo_dir, ["rev-parse", "side"]),
  )
  fs.write_string(repo_dir + "/.git/MERGE_HEAD", side_id + "\n")
  fs.write_string(repo_dir + "/.git/MERGE_MSG", "merge side\n")

  @sys.set_env_var("GIT_SHIM_CWD", repo_dir)
  @sys.set_env_var("GIT_SHIM_PWD", repo_dir)
  @sys.unset_env_var("GIT_DIR")
  @sys.unset_env_var("GIT_WORK_TREE")

  checkout_wbtest_run_shim_git(repo_dir, ["checkout", "-q", "-f", "side"])

  assert_false(fs.is_file(repo_dir + "/.git/MERGE_HEAD"))
  assert_false(fs.is_file(repo_dir + "/.git/MERGE_MSG"))
  @test.assert_eq(
    decode_bytes(
      fs.read_file(repo_dir + "/file") catch {
        _ => Default::default()
      },
    ),
    "side\n",
  )

  add_test_restore_env("GIT_SHIM_CWD", prev_shim_cwd)
  add_test_restore_env("GIT_SHIM_PWD", prev_shim_pwd)
  add_test_restore_env("GIT_DIR", prev_git_dir)
  add_test_restore_env("GIT_WORK_TREE", prev_work_tree)
  cleanup_tree(fs, root)
}

///|
async fn checkout_wbtest_case_treeish_restore_updates_index() -> Unit raise Error {
  @bitnative.init_native_io()
  let fs = OsFs::new()
  let root = "/tmp/bit-test-checkout-treeish-index-" +
    get_current_timestamp().to_string()
  cleanup_tree(fs, root)
  fs.mkdir_p(root)
  let repo_dir = root + "/repo"

  let prev_shim_cwd = @sys.get_env_var("GIT_SHIM_CWD")
  let prev_shim_pwd = @sys.get_env_var("GIT_SHIM_PWD")
  let prev_git_dir = @sys.get_env_var("GIT_DIR")
  let prev_work_tree = @sys.get_env_var("GIT_WORK_TREE")

  add_test_run_git(root, ["init", "--initial-branch=main", "-q", "repo"])
  add_test_run_git(repo_dir, ["config", "user.name", "Test User"])
  add_test_run_git(repo_dir, ["config", "user.email", "test@example.com"])
  fs.write_string(repo_dir + "/file", "base\n")
  add_test_run_git(repo_dir, ["add", "file"])
  add_test_run_git(repo_dir, ["commit", "-q", "-m", "base"])
  fs.write_string(repo_dir + "/file", "dirty\n")
  add_test_run_git(repo_dir, ["add", "file"])

  @sys.set_env_var("GIT_SHIM_CWD", repo_dir)
  @sys.set_env_var("GIT_SHIM_PWD", repo_dir)
  @sys.unset_env_var("GIT_DIR")
  @sys.unset_env_var("GIT_WORK_TREE")
  checkout_wbtest_run_shim_git(repo_dir, [
    "checkout", "-q", "HEAD", "--", "file",
  ])

  @test.assert_eq(decode_bytes(fs.read_file(repo_dir + "/file")), "base\n")
  @test.assert_eq(
    add_test_git_stdout(repo_dir, ["diff", "--cached", "--name-only"]),
    "",
  )

  add_test_restore_env("GIT_SHIM_CWD", prev_shim_cwd)
  add_test_restore_env("GIT_SHIM_PWD", prev_shim_pwd)
  add_test_restore_env("GIT_DIR", prev_git_dir)
  add_test_restore_env("GIT_WORK_TREE", prev_work_tree)
  cleanup_tree(fs, root)
}

///|
async fn checkout_wbtest_case_treeish_restore_without_separator() -> Unit raise Error {
  @bitnative.init_native_io()
  let fs = OsFs::new()
  let root = "/tmp/bit-test-checkout-treeish-no-sep-" +
    get_current_timestamp().to_string()
  cleanup_tree(fs, root)
  fs.mkdir_p(root)
  let repo_dir = root + "/repo"

  let prev_shim_cwd = @sys.get_env_var("GIT_SHIM_CWD")
  let prev_shim_pwd = @sys.get_env_var("GIT_SHIM_PWD")
  let prev_git_dir = @sys.get_env_var("GIT_DIR")
  let prev_work_tree = @sys.get_env_var("GIT_WORK_TREE")

  add_test_run_git(root, ["init", "--initial-branch=main", "-q", "repo"])
  add_test_run_git(repo_dir, ["config", "user.name", "Test User"])
  add_test_run_git(repo_dir, ["config", "user.email", "test@example.com"])
  fs.write_string(repo_dir + "/file", "main\n")
  add_test_run_git(repo_dir, ["add", "file"])
  add_test_run_git(repo_dir, ["commit", "-q", "-m", "main"])
  add_test_run_git(repo_dir, ["checkout", "-q", "-b", "side"])
  fs.write_string(repo_dir + "/file", "side\n")
  add_test_run_git(repo_dir, ["commit", "-qam", "side"])
  add_test_run_git(repo_dir, ["checkout", "-q", "main"])
  fs.write_string(repo_dir + "/file", "dirty\n")

  @sys.set_env_var("GIT_SHIM_CWD", repo_dir)
  @sys.set_env_var("GIT_SHIM_PWD", repo_dir)
  @sys.unset_env_var("GIT_DIR")
  @sys.unset_env_var("GIT_WORK_TREE")
  checkout_wbtest_run_shim_git(repo_dir, ["checkout", "-q", "side", "file"])

  @test.assert_eq(decode_bytes(fs.read_file(repo_dir + "/file")), "side\n")
  @test.assert_eq(
    add_test_git_stdout(repo_dir, ["symbolic-ref", "--short", "HEAD"]),
    "main\n",
  )

  add_test_restore_env("GIT_SHIM_CWD", prev_shim_cwd)
  add_test_restore_env("GIT_SHIM_PWD", prev_shim_pwd)
  add_test_restore_env("GIT_DIR", prev_git_dir)
  add_test_restore_env("GIT_WORK_TREE", prev_work_tree)
  cleanup_tree(fs, root)
}

///|
async fn checkout_wbtest_case_track_sets_branch_config() -> Unit raise Error {
  @bitnative.init_native_io()
  let fs = OsFs::new()
  let root = "/tmp/bit-test-checkout-track-config-" +
    get_current_timestamp().to_string()
  cleanup_tree(fs, root)
  fs.mkdir_p(root)
  let repo_dir = root + "/repo"

  let prev_shim_cwd = @sys.get_env_var("GIT_SHIM_CWD")
  let prev_shim_pwd = @sys.get_env_var("GIT_SHIM_PWD")
  let prev_git_dir = @sys.get_env_var("GIT_DIR")
  let prev_work_tree = @sys.get_env_var("GIT_WORK_TREE")

  add_test_run_git(root, ["init", "--initial-branch=main", "-q", "repo"])
  add_test_run_git(repo_dir, ["config", "user.name", "Test User"])
  add_test_run_git(repo_dir, ["config", "user.email", "test@example.com"])
  fs.write_string(repo_dir + "/file", "base\n")
  add_test_run_git(repo_dir, ["add", "file"])
  add_test_run_git(repo_dir, ["commit", "-q", "-m", "base"])
  add_test_run_git(repo_dir, ["remote", "add", "me", "."])
  add_test_run_git(repo_dir, ["update-ref", "refs/remotes/me/main", "HEAD"])

  @sys.set_env_var("GIT_SHIM_CWD", repo_dir)
  @sys.set_env_var("GIT_SHIM_PWD", repo_dir)
  @sys.unset_env_var("GIT_DIR")
  @sys.unset_env_var("GIT_WORK_TREE")
  checkout_wbtest_run_shim_git(repo_dir, [
    "checkout", "-q", "--track", "-b", "topic", "me/main",
  ])

  @test.assert_eq(
    add_test_git_stdout(repo_dir, ["config", "--get", "branch.topic.remote"]),
    "me\n",
  )
  @test.assert_eq(
    add_test_git_stdout(repo_dir, ["config", "--get", "branch.topic.merge"]),
    "refs/heads/main\n",
  )

  add_test_restore_env("GIT_SHIM_CWD", prev_shim_cwd)
  add_test_restore_env("GIT_SHIM_PWD", prev_shim_pwd)
  add_test_restore_env("GIT_DIR", prev_git_dir)
  add_test_restore_env("GIT_WORK_TREE", prev_work_tree)
  cleanup_tree(fs, root)
}

///|
async fn checkout_wbtest_case_detach_head_without_target() -> Unit raise Error {
  @bitnative.init_native_io()
  let fs = OsFs::new()
  let root = "/tmp/bit-test-checkout-detach-head-" +
    get_current_timestamp().to_string()
  cleanup_tree(fs, root)
  fs.mkdir_p(root)
  let repo_dir = root + "/repo"

  let prev_shim_cwd = @sys.get_env_var("GIT_SHIM_CWD")
  let prev_shim_pwd = @sys.get_env_var("GIT_SHIM_PWD")
  let prev_git_dir = @sys.get_env_var("GIT_DIR")
  let prev_work_tree = @sys.get_env_var("GIT_WORK_TREE")

  add_test_run_git(root, ["init", "--initial-branch=main", "-q", "repo"])
  add_test_run_git(repo_dir, ["config", "user.name", "Test User"])
  add_test_run_git(repo_dir, ["config", "user.email", "test@example.com"])
  fs.write_string(repo_dir + "/file", "base\n")
  add_test_run_git(repo_dir, ["add", "file"])
  add_test_run_git(repo_dir, ["commit", "-q", "-m", "base"])
  let head_before = trim_string(
    add_test_git_stdout(repo_dir, ["rev-parse", "HEAD"]),
  )

  @sys.set_env_var("GIT_SHIM_CWD", repo_dir)
  @sys.set_env_var("GIT_SHIM_PWD", repo_dir)
  @sys.unset_env_var("GIT_DIR")
  @sys.unset_env_var("GIT_WORK_TREE")
  checkout_wbtest_run_shim_git(repo_dir, ["checkout", "-q", "--detach"])

  @test.assert_eq(
    trim_string(decode_bytes(fs.read_file(repo_dir + "/.git/HEAD"))),
    head_before,
  )

  add_test_restore_env("GIT_SHIM_CWD", prev_shim_cwd)
  add_test_restore_env("GIT_SHIM_PWD", prev_shim_pwd)
  add_test_restore_env("GIT_DIR", prev_git_dir)
  add_test_restore_env("GIT_WORK_TREE", prev_work_tree)
  cleanup_tree(fs, root)
}

///|
async fn checkout_wbtest_case_previous_checkout_syntax() -> Unit raise Error {
  @bitnative.init_native_io()
  let fs = OsFs::new()
  let root = "/tmp/bit-test-checkout-prev-syntax-" +
    get_current_timestamp().to_string()
  cleanup_tree(fs, root)
  fs.mkdir_p(root)
  let repo_dir = root + "/repo"

  let prev_shim_cwd = @sys.get_env_var("GIT_SHIM_CWD")
  let prev_shim_pwd = @sys.get_env_var("GIT_SHIM_PWD")
  let prev_git_dir = @sys.get_env_var("GIT_DIR")
  let prev_work_tree = @sys.get_env_var("GIT_WORK_TREE")

  add_test_run_git(root, ["init", "--initial-branch=main", "-q", "repo"])
  add_test_run_git(repo_dir, ["config", "user.name", "Test User"])
  add_test_run_git(repo_dir, ["config", "user.email", "test@example.com"])
  fs.write_string(repo_dir + "/file", "base\n")
  add_test_run_git(repo_dir, ["add", "file"])
  add_test_run_git(repo_dir, ["commit", "-q", "-m", "base"])

  @sys.set_env_var("GIT_SHIM_CWD", repo_dir)
  @sys.set_env_var("GIT_SHIM_PWD", repo_dir)
  @sys.unset_env_var("GIT_DIR")
  @sys.unset_env_var("GIT_WORK_TREE")

  checkout_wbtest_run_shim_git(repo_dir, ["checkout", "-q", "-b", "topic"])
  checkout_wbtest_run_shim_git(repo_dir, ["checkout", "-q", "main"])
  checkout_wbtest_run_shim_git(repo_dir, ["checkout", "-q", "@{-1}"])

  @test.assert_eq(
    add_test_git_stdout(repo_dir, ["symbolic-ref", "--short", "HEAD"]),
    "topic\n",
  )

  add_test_restore_env("GIT_SHIM_CWD", prev_shim_cwd)
  add_test_restore_env("GIT_SHIM_PWD", prev_shim_pwd)
  add_test_restore_env("GIT_DIR", prev_git_dir)
  add_test_restore_env("GIT_WORK_TREE", prev_work_tree)
  cleanup_tree(fs, root)
}

///|
async test "checkout: command path cases stay compatible" {
  cmd_bit_wbtest_env_lock.acquire()
  defer cmd_bit_wbtest_env_lock.release()
  checkout_wbtest_case_treeish_restore()
  checkout_wbtest_case_treeish_restore_updates_index()
  checkout_wbtest_case_treeish_restore_without_separator()
  checkout_wbtest_case_switch_back_to_main()
  checkout_wbtest_case_switch_back_with_detached_worktree()
  checkout_wbtest_case_switch_back_after_shim_commit()
  checkout_wbtest_case_branch_in_use()
  checkout_wbtest_case_force_branch_in_use()
  checkout_wbtest_case_symlinked_branch_in_use()
  checkout_wbtest_case_recheckout_current_branch_with_symlink_head()
  checkout_wbtest_case_bare_repo_checkout_fails()
  checkout_wbtest_case_orphan_branch()
  checkout_wbtest_case_checkout_updates_head_reflog()
  checkout_wbtest_case_force_checkout_clears_merge_state()
  checkout_wbtest_case_track_sets_branch_config()
  checkout_wbtest_case_detach_head_without_target()
  checkout_wbtest_case_previous_checkout_syntax()
}

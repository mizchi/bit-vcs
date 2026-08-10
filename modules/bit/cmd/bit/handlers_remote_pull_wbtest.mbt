///|
test "pull: detect submodule replaced by file" {
  let from_modes : Map[String, Int] = Map([])
  from_modes["sub1"] = 0o160000
  let to_modes : Map[String, Int] = Map([])
  to_modes["sub1"] = 0o100644
  let replaced = find_submodule_replaced_with_non_submodule(
    from_modes, to_modes,
  )
  @test.assert_eq(replaced, Some("sub1"))
}

///|
test "pull: do not flag submodule removal" {
  let from_modes : Map[String, Int] = Map([])
  from_modes["sub1"] = 0o160000
  let to_modes : Map[String, Int] = Map([])
  let replaced = find_submodule_replaced_with_non_submodule(
    from_modes, to_modes,
  )
  @test.assert_eq(replaced, None)
}

///|
test "pull: initial head target uses current branch ref" {
  let target = resolve_initial_pull_head_target(Some("main"))
  @test.assert_eq(target, "refs/heads/main")
}

///|
test "pull: initial head target uses detached HEAD" {
  let target = resolve_initial_pull_head_target(None)
  @test.assert_eq(target, "HEAD")
}

///|
test "pull: explicit refspec keeps fetch and merge target aligned" {
  let parsed = pull_parse_explicit_refspec(Some("main:main"))
  @test.assert_eq(parsed.fetch_refspecs, ["main:main"])
  @test.assert_eq(parsed.merge_ref, Some("refs/heads/main"))
  @test.assert_eq(parsed.target_ref, Some("refs/heads/main"))
  @test.assert_eq(parsed.upstream_ref, Some("refs/heads/main"))
}

///|
test "pull: validation rejects detached HEAD without refspec" {
  let message = pull_pre_fetch_validation_error(
    true,
    None,
    None,
    None,
    false,
    None,
    true,
  )
  @test.assert_eq(message, Some("You are not currently on a branch."))
}

///|
test "pull: validation rejects remote without branch when HEAD exists" {
  let message = pull_pre_fetch_validation_error(
    false,
    Some("test_remote"),
    None,
    None,
    false,
    None,
    true,
  )
  @test.assert_eq(message, Some("Please specify a branch on the command line."))
}

///|
test "pull: validation allows unborn branch without explicit merge ref" {
  let message = pull_pre_fetch_validation_error(
    false,
    Some(".."),
    None,
    None,
    false,
    None,
    false,
  )
  @test.assert_eq(message, None)
}

///|
test "pull: validation reports missing tracking information" {
  let message = pull_pre_fetch_validation_error(
    false,
    None,
    None,
    Some("origin"),
    false,
    None,
    true,
  )
  @test.assert_eq(
    message,
    Some("There is no tracking information for the current branch."),
  )
}

///|
test "pull: missing target error prefers wildcard message" {
  let message = pull_missing_target_error_message(
    Some("refs/nonexisting1/*:refs/nonexisting2/*"),
    None,
    ["refs/nonexisting1/*:refs/nonexisting2/*"],
    "refs/nonexisting2/*",
  )
  assert_true(message.contains("no candidates for merging"))
}

///|
test "pull: missing target error prefers tracking ref message" {
  let message = pull_missing_target_error_message(
    None,
    Some("refs/heads/nonexisting"),
    [],
    "refs/remotes/origin/nonexisting",
  )
  assert_true(message.contains("no such ref was fetched"))
}

///|
test "pull: merge ref becomes implicit fetch refspec" {
  let target_ref = pull_target_ref(
    "origin",
    Some("refs/heads/not-in-refspec"),
    None,
  )
  @test.assert_eq(
    pull_fetch_refspecs([], Some("refs/heads/not-in-refspec"), target_ref),
    ["refs/heads/not-in-refspec:refs/remotes/origin/not-in-refspec"],
  )
}

///|
test "pull: in-progress merge error prefers unmerged files" {
  @test.assert_eq(
    pull_in_progress_error(true, true),
    Some("Pulling is not possible because you have unmerged files."),
  )
  @test.assert_eq(
    pull_in_progress_error(false, true),
    Some("You have not concluded your merge (MERGE_HEAD exists)."),
  )
  @test.assert_eq(pull_in_progress_error(false, false), None)
}

///|
test "pull: pull.autostash overrides mode-specific config" {
  let fs = @bitcore.TestFs::new()
  let git_dir = "/repo/.git"
  fs.mkdir_p(git_dir)
  fs.write_string(
    git_dir + "/config",
    (
      #|[pull]
      #|  autostash = false
      #|[rebase]
      #|  autostash = true
      #|[merge]
      #|  autostash = true
      #|
    ),
  )
  assert_false(pull_autostash_enabled(fs, git_dir, true, None))
  assert_false(pull_autostash_enabled(fs, git_dir, false, None))
  assert_true(pull_autostash_enabled(fs, git_dir, true, Some(true)))
  assert_false(pull_autostash_enabled(fs, git_dir, false, Some(false)))
}

///|
test "pull: rebase mode prefers branch config over pull.rebase" {
  let fs = @bitcore.TestFs::new()
  let git_dir = "/repo/.git"
  fs.mkdir_p(git_dir)
  fs.write_string(
    git_dir + "/config",
    (
      #|[pull]
      #|  rebase = true
      #|
    ),
  )
  @test.assert_eq(
    pull_resolve_rebase_behavior(fs, git_dir, Some(false), None),
    (false, false),
  )
  @test.assert_eq(
    pull_resolve_rebase_behavior(fs, git_dir, Some(true), None),
    (true, false),
  )
}

///|
test "pull: rebase mode parses interactive and rejects invalid config" {
  let fs = @bitcore.TestFs::new()
  let git_dir = "/repo/.git"
  fs.mkdir_p(git_dir)
  fs.write_string(
    git_dir + "/config",
    (
      #|[pull]
      #|  rebase = interactive
      #|
    ),
  )
  @test.assert_eq(
    pull_resolve_rebase_behavior(fs, git_dir, None, None),
    (true, true),
  )
  @test.assert_eq(
    pull_parse_rebase_behavior_value("i", "--rebase"),
    (true, true),
  )
  fs.write_string(
    git_dir + "/config",
    (
      #|[pull]
      #|  rebase = invalid
      #|
    ),
  )
  let rejected = try {
    ignore(pull_resolve_rebase_behavior(fs, git_dir, None, None))
    false
  } catch {
    @bitcore.GitError::InvalidObject(msg) =>
      msg == "Invalid value for pull.rebase: invalid"
    _ => false
  }
  assert_true(rejected)
}

///|
let handlers_remote_pull_wbtest_shim_lock : @async.Semaphore = @async.Semaphore(
  1,
  initial_value=1,
)

///|
async fn handlers_remote_pull_wbtest_collect_shim_git(
  cwd : String,
  args : Array[String],
) -> (Int, String, String) raise Error {
  handlers_remote_pull_wbtest_shim_lock.acquire()
  defer handlers_remote_pull_wbtest_shim_lock.release()
  // Derive repo root from the executable path to avoid CWD pollution
  let repo_root = match @sys.get_env_var("CARGO_MANIFEST_DIR") {
    Some(d) => d
    None => {
      let exe = @sys.get_cli_args()[0]
      // exe is like /path/to/bit/_build/native/release/build/mizchi/bit/bit.exe
      // or the test binary — fallback to current_dir
      let idx = exe.find("/_build/")
      match idx {
        Some(i) => String::unsafe_substring(exe, start=0, end=i)
        None => @env.current_dir().unwrap_or(".")
      }
    }
  }
  let shim_git = repo_root + "/tools/git-shim/bin/git"
  let shim_moon = "/tmp/bit-pull-shim-moon.sh"
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
    "SHIM_REAL_GIT_FALLBACK": "",
    "SHIM_EXEC_PATH": repo_root + "/third_party/git",
    "SHIM_MOON": shim_moon,
    "SHIM_CMDS": "init status add commit log show branch checkout switch reset rebase stash cherry-pick diff diff-files diff-index merge tag rm mv config sparse-checkout restore rev-parse cat-file ls-files hash-object ls-tree write-tree show-ref update-ref update-index symbolic-ref reflog worktree gc clean grep submodule revert notes bisect describe blame format-patch shortlog remote clone fetch pull push receive-pack upload-pack pack-objects index-pack shell",
    "SHIM_STRICT": "1",
    "GIT_SHIM_CWD": "",
    "GIT_SHIM_PWD": "",
    "GIT_DIR": "",
    "GIT_WORK_TREE": "",
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
  (code, stdout.text() catch { _ => "" }, stderr.text() catch { _ => "" })
}

///|
async fn handlers_remote_pull_wbtest_run_shim_git(
  cwd : String,
  args : Array[String],
) -> Unit raise Error {
  let (code, stdout, stderr) = handlers_remote_pull_wbtest_collect_shim_git(
    cwd, args,
  )
  @test.assert_eq(code, 0)
  @test.assert_eq(stdout, "")
  @test.assert_eq(stderr, "")
}

///|
async test "pull: local fetch with main:main writes target ref and FETCH_HEAD" {
  @bitnative.init_native_io()
  cmd_bit_wbtest_env_lock.acquire()
  defer cmd_bit_wbtest_env_lock.release()
  let fs = OsFs::new()
  let root = "/tmp/bit-test pull fetch explicit trash directory-" +
    get_current_timestamp().to_string()
  cleanup_tree(fs, root)
  fs.mkdir_p(root)
  let dst_dir = root + "/dst"

  // Protect against env pollution from other tests
  let prev_shim_cwd = @sys.get_env_var("GIT_SHIM_CWD")
  let prev_git_dir = @sys.get_env_var("GIT_DIR")
  let prev_git_work_tree = @sys.get_env_var("GIT_WORK_TREE")
  let prev_shim_pwd = @sys.get_env_var("GIT_SHIM_PWD")
  @sys.unset_env_var("GIT_SHIM_CWD")
  @sys.unset_env_var("GIT_DIR")
  @sys.unset_env_var("GIT_WORK_TREE")
  @sys.unset_env_var("GIT_SHIM_PWD")
  defer add_test_restore_env("GIT_SHIM_CWD", prev_shim_cwd)
  defer add_test_restore_env("GIT_DIR", prev_git_dir)
  defer add_test_restore_env("GIT_WORK_TREE", prev_git_work_tree)
  defer add_test_restore_env("GIT_SHIM_PWD", prev_shim_pwd)

  commit_wbtest_run_git(root, ["init", "--initial-branch=main", "-q"])
  commit_wbtest_run_git(root, ["config", "user.name", "Test User"])
  commit_wbtest_run_git(root, ["config", "user.email", "test@example.com"])
  fs.write_string(root + "/file", "file\n")
  commit_wbtest_run_git(root, ["add", "file"])
  commit_wbtest_run_git(root, ["commit", "-q", "-m", "initial"])

  commit_wbtest_run_git(root, ["init", "--initial-branch=main", "-q", "dst"])

  fetch_from_remote(
    fs,
    dst_dir + "/.git",
    dst_dir,
    "__pull_tmp__",
    "..",
    ["main:main"],
    update_head_ok=true,
    quiet=true,
  )

  assert_true(
    @bitlib.resolve_ref(fs, dst_dir + "/.git", "refs/heads/main") is Some(_),
  )
  assert_true(resolve_fetch_head_oid(fs, dst_dir + "/.git") is Some(_))

  cleanup_tree(fs, root)
}

///|
async test "pull: local fetch for main writes remote-tracking ref and FETCH_HEAD" {
  @bitnative.init_native_io()
  cmd_bit_wbtest_env_lock.acquire()
  defer cmd_bit_wbtest_env_lock.release()
  let fs = OsFs::new()
  let root = "/tmp/bit-test pull fetch merge-ref trash directory-" +
    get_current_timestamp().to_string()
  cleanup_tree(fs, root)
  fs.mkdir_p(root)
  let dst_dir = root + "/dst"

  // Protect against env pollution from other tests
  let prev_shim_cwd = @sys.get_env_var("GIT_SHIM_CWD")
  let prev_git_dir = @sys.get_env_var("GIT_DIR")
  let prev_git_work_tree = @sys.get_env_var("GIT_WORK_TREE")
  let prev_shim_pwd = @sys.get_env_var("GIT_SHIM_PWD")
  @sys.unset_env_var("GIT_SHIM_CWD")
  @sys.unset_env_var("GIT_DIR")
  @sys.unset_env_var("GIT_WORK_TREE")
  @sys.unset_env_var("GIT_SHIM_PWD")
  defer add_test_restore_env("GIT_SHIM_CWD", prev_shim_cwd)
  defer add_test_restore_env("GIT_DIR", prev_git_dir)
  defer add_test_restore_env("GIT_WORK_TREE", prev_git_work_tree)
  defer add_test_restore_env("GIT_SHIM_PWD", prev_shim_pwd)

  commit_wbtest_run_git(root, ["init", "--initial-branch=main", "-q"])
  commit_wbtest_run_git(root, ["config", "user.name", "Test User"])
  commit_wbtest_run_git(root, ["config", "user.email", "test@example.com"])
  fs.write_string(root + "/file", "file\n")
  commit_wbtest_run_git(root, ["add", "file"])
  commit_wbtest_run_git(root, ["commit", "-q", "-m", "initial"])

  commit_wbtest_run_git(root, ["init", "--initial-branch=main", "-q", "dst"])

  fetch_from_remote(
    fs,
    dst_dir + "/.git",
    dst_dir,
    "__pull_tmp__",
    "..",
    [],
    quiet=true,
  )

  assert_true(
    @bitlib.resolve_ref(fs, dst_dir + "/.git", "refs/remotes/__pull_tmp__/main")
    is Some(_),
  )
  assert_true(resolve_fetch_head_oid(fs, dst_dir + "/.git") is Some(_))

  cleanup_tree(fs, root)
}

///|
async test "pull: branch remote dot pulls from current repo config" {
  @bitnative.init_native_io()
  cmd_bit_wbtest_env_lock.acquire()
  defer cmd_bit_wbtest_env_lock.release()
  let fs = OsFs::new()
  let root = "/tmp/bit-test pull branch-remote-dot trash directory-" +
    get_current_timestamp().to_string()
  cleanup_tree(fs, root)
  fs.mkdir_p(root)

  commit_wbtest_run_git(root, ["init", "--initial-branch=main", "-q"])
  commit_wbtest_run_git(root, ["config", "user.name", "Test User"])
  commit_wbtest_run_git(root, ["config", "user.email", "test@example.com"])
  fs.write_string(root + "/file", "file\n")
  commit_wbtest_run_git(root, ["add", "file"])
  commit_wbtest_run_git(root, ["commit", "-q", "-m", "original"])
  commit_wbtest_run_git(root, ["branch", "copy", "main"])
  commit_wbtest_run_git(root, ["config", "branch.copy.remote", "."])
  commit_wbtest_run_git(root, ["config", "branch.copy.merge", "refs/heads/main"])
  fs.write_string(root + "/file", "updated\n")
  commit_wbtest_run_git(root, ["commit", "-q", "-a", "-m", "updated"])
  commit_wbtest_run_git(root, ["checkout", "-q", "copy"])

  handlers_remote_pull_wbtest_run_shim_git(root, ["pull", "-q"])

  @test.assert_eq(
    decode_bytes(fs.read_file(root + "/file") catch { _ => Default::default() }),
    "updated\n",
  )
  assert_true(
    decode_bytes(
      fs.read_file(root + "/.git/logs/HEAD") catch {
        _ => Default::default()
      },
    ).contains("Fast-forward"),
  )
  cleanup_tree(fs, root)
}

///|
async test "pull: command path pulls into unborn branch from parent repo" {
  @bitnative.init_native_io()
  cmd_bit_wbtest_env_lock.acquire()
  defer cmd_bit_wbtest_env_lock.release()
  let fs = OsFs::new()
  let root = "/tmp/bit-test pull command unborn trash directory-" +
    get_current_timestamp().to_string()
  cleanup_tree(fs, root)
  fs.mkdir_p(root)
  let dst_dir = root + "/dst"

  commit_wbtest_run_git(root, ["init", "--initial-branch=main", "-q"])
  commit_wbtest_run_git(root, ["config", "user.name", "Test User"])
  commit_wbtest_run_git(root, ["config", "user.email", "test@example.com"])
  fs.write_string(root + "/file", "file\n")
  commit_wbtest_run_git(root, ["add", "file"])
  commit_wbtest_run_git(root, ["commit", "-q", "-m", "initial"])

  commit_wbtest_run_git(root, ["init", "--initial-branch=main", "-q", "dst"])

  handlers_remote_pull_wbtest_run_shim_git(dst_dir, [
    "pull", "-q", "..", "main:main",
  ])

  @test.assert_eq(
    decode_bytes(
      fs.read_file(dst_dir + "/file") catch {
        _ => Default::default()
      },
    ),
    "file\n",
  )
  assert_true(@bitlib.resolve_head_commit(fs, dst_dir + "/.git") is Some(_))
  cleanup_tree(fs, root)
}

///|
async test "pull: command path keeps staged new file on unborn branch" {
  @bitnative.init_native_io()
  cmd_bit_wbtest_env_lock.acquire()
  defer cmd_bit_wbtest_env_lock.release()
  let fs = OsFs::new()
  let root = "/tmp/bit-test pull command preserve-index trash directory-" +
    get_current_timestamp().to_string()
  cleanup_tree(fs, root)
  fs.mkdir_p(root)
  let dst_dir = root + "/dst"

  commit_wbtest_run_git(root, ["init", "--initial-branch=main", "-q"])
  commit_wbtest_run_git(root, ["config", "user.name", "Test User"])
  commit_wbtest_run_git(root, ["config", "user.email", "test@example.com"])
  fs.write_string(root + "/file", "file\n")
  commit_wbtest_run_git(root, ["add", "file"])
  commit_wbtest_run_git(root, ["commit", "-q", "-m", "initial"])

  commit_wbtest_run_git(root, ["init", "--initial-branch=main", "-q", "dst"])
  fs.write_string(dst_dir + "/newfile", "new tracked file\n")
  commit_wbtest_run_git(dst_dir, ["add", "newfile"])

  handlers_remote_pull_wbtest_run_shim_git(dst_dir, ["pull", "-q", "..", "main"])

  @test.assert_eq(
    decode_bytes(
      fs.read_file(dst_dir + "/newfile") catch {
        _ => Default::default()
      },
    ),
    "new tracked file\n",
  )
  let entries = @bitlib.read_index_entries(fs, dst_dir + "/.git")
  let mut found_newfile = false
  for entry in entries {
    if entry.path == "newfile" {
      found_newfile = true
      break
    }
  }
  assert_true(found_newfile)
  cleanup_tree(fs, root)
}

///|
async test "pull: command path rejects octopus into unborn branch" {
  @bitnative.init_native_io()
  cmd_bit_wbtest_env_lock.acquire()
  defer cmd_bit_wbtest_env_lock.release()
  let fs = OsFs::new()
  let root = "/tmp/bit-test pull command octopus trash directory-" +
    get_current_timestamp().to_string()
  cleanup_tree(fs, root)
  fs.mkdir_p(root)
  let dst_dir = root + "/dst"

  commit_wbtest_run_git(root, ["init", "--initial-branch=main", "-q"])
  commit_wbtest_run_git(root, ["config", "user.name", "Test User"])
  commit_wbtest_run_git(root, ["config", "user.email", "test@example.com"])
  fs.write_string(root + "/file", "file\n")
  commit_wbtest_run_git(root, ["add", "file"])
  commit_wbtest_run_git(root, ["commit", "-q", "-m", "initial"])

  commit_wbtest_run_git(root, ["init", "--initial-branch=main", "-q", "dst"])

  let (code, _stdout, stderr) = handlers_remote_pull_wbtest_collect_shim_git(
    dst_dir,
    ["pull", "..", "main", "main"],
  )

  assert_true(code != 0)
  assert_true(stderr.contains("Cannot merge multiple branches into empty"))
  assert_false(fs.is_file(dst_dir + "/file"))

  cleanup_tree(fs, root)
}

///|
async test "pull: rebase rejects staged changes on unborn branch" {
  @bitnative.init_native_io()
  cmd_bit_wbtest_env_lock.acquire()
  defer cmd_bit_wbtest_env_lock.release()
  let fs = OsFs::new()
  let root = "/tmp/bit-test pull unborn-rebase-index trash directory-" +
    get_current_timestamp().to_string()
  cleanup_tree(fs, root)
  fs.mkdir_p(root)
  let dst_dir = root + "/dst"

  commit_wbtest_run_git(root, ["init", "--initial-branch=main", "-q"])
  commit_wbtest_run_git(root, ["config", "user.name", "Test User"])
  commit_wbtest_run_git(root, ["config", "user.email", "test@example.com"])
  fs.write_string(root + "/file", "file\n")
  commit_wbtest_run_git(root, ["add", "file"])
  commit_wbtest_run_git(root, ["commit", "-q", "-m", "initial"])

  commit_wbtest_run_git(root, ["init", "--initial-branch=main", "-q", "dst"])
  fs.write_string(dst_dir + "/staged-file", "staged-file\n")
  commit_wbtest_run_git(dst_dir, ["add", "staged-file"])

  let (code, _stdout, stderr) = handlers_remote_pull_wbtest_collect_shim_git(
    dst_dir,
    ["pull", "--rebase", "..", "main"],
  )

  assert_true(code != 0)
  assert_true(stderr.contains("unborn branch with changes added to the index"))
  let entries = @bitlib.read_index_entries(fs, dst_dir + "/.git")
  let mut found_staged_file = false
  for entry in entries {
    if entry.path == "staged-file" {
      found_staged_file = true
      break
    }
  }
  assert_true(found_staged_file)
  @test.assert_eq(
    decode_bytes(
      fs.read_file(dst_dir + "/staged-file") catch {
        _ => Default::default()
      },
    ),
    "staged-file\n",
  )
  cleanup_tree(fs, root)
}

///|
async test "pull: rebase uses previous target as fork point for rebased upstream" {
  @bitnative.init_native_io()
  cmd_bit_wbtest_env_lock.acquire()
  defer cmd_bit_wbtest_env_lock.release()
  let fs = OsFs::new()
  let root = "/tmp/bit-test pull rebased-upstream trash directory-" +
    get_current_timestamp().to_string()
  cleanup_tree(fs, root)
  fs.mkdir_p(root)

  commit_wbtest_run_git(root, ["init", "--initial-branch=main", "-q"])
  commit_wbtest_run_git(root, ["config", "user.name", "Test User"])
  commit_wbtest_run_git(root, ["config", "user.email", "test@example.com"])
  fs.write_string(root + "/file", "file\n")
  commit_wbtest_run_git(root, ["add", "file"])
  commit_wbtest_run_git(root, ["commit", "-q", "-m", "original"])

  commit_wbtest_run_git(root, ["branch", "copy", "main"])
  commit_wbtest_run_git(root, ["checkout", "-q", "copy"])
  fs.write_string(root + "/file", "modified again\n")
  commit_wbtest_run_git(root, ["commit", "-q", "-a", "-m", "file"])

  commit_wbtest_run_git(root, ["checkout", "-q", "-b", "to-rebase"])
  fs.write_string(root + "/file2", "new\n")
  commit_wbtest_run_git(root, ["add", "file2"])
  commit_wbtest_run_git(root, ["commit", "-q", "-m", "new file"])

  commit_wbtest_run_git(root, ["remote", "add", "me", "."])
  commit_wbtest_run_git(root, ["fetch", "-q", "me"])

  commit_wbtest_run_git(root, ["checkout", "-q", "copy"])
  commit_wbtest_run_git(root, ["reset", "--hard", "HEAD^"])
  fs.write_string(root + "/file", "conflicting modification\n")
  commit_wbtest_run_git(root, ["commit", "-q", "-a", "-m", "conflict"])

  commit_wbtest_run_git(root, ["checkout", "-q", "to-rebase"])
  handlers_remote_pull_wbtest_run_shim_git(root, [
    "pull", "--rebase", "-q", "me", "copy",
  ])

  @test.assert_eq(
    decode_bytes(fs.read_file(root + "/file") catch { _ => Default::default() }),
    "conflicting modification\n",
  )
  @test.assert_eq(
    decode_bytes(fs.read_file(root + "/file2") catch { _ => Default::default() }),
    "new\n",
  )
  @test.assert_eq(@bitlib.read_unmerged_paths(fs, root + "/.git").length(), 0)
  cleanup_tree(fs, root)
}

///|
async test "pull: updates checked-out branch worktree when fetch advances it" {
  @bitnative.init_native_io()
  cmd_bit_wbtest_env_lock.acquire()
  defer cmd_bit_wbtest_env_lock.release()
  let fs = OsFs::new()
  let root = "/tmp/bit-test pull fetch-updates-head trash directory-" +
    get_current_timestamp().to_string()
  cleanup_tree(fs, root)
  fs.mkdir_p(root)

  commit_wbtest_run_git(root, ["init", "--initial-branch=main", "-q"])
  commit_wbtest_run_git(root, ["config", "user.name", "Test User"])
  commit_wbtest_run_git(root, ["config", "user.email", "test@example.com"])
  fs.write_string(root + "/file", "base\n")
  commit_wbtest_run_git(root, ["add", "file"])
  commit_wbtest_run_git(root, ["commit", "-q", "-m", "base"])
  fs.write_string(root + "/file", "file\n")
  commit_wbtest_run_git(root, ["commit", "-q", "-a", "-m", "original"])
  commit_wbtest_run_git(root, ["checkout", "-q", "-b", "second", "main"])
  fs.write_string(root + "/file", "modified\n")
  commit_wbtest_run_git(root, ["commit", "-q", "-a", "-m", "modified"])
  let second_id = @bitlib.resolve_ref(fs, root + "/.git", "refs/heads/second")
  commit_wbtest_run_git(root, ["checkout", "-q", "-b", "third", "second^"])
  fs.write_string(root + "/expect", "file\n")

  handlers_remote_pull_wbtest_run_shim_git(root, [
    "pull", "-q", ".", "second:third",
  ])

  @test.assert_eq(
    decode_bytes(fs.read_file(root + "/file") catch { _ => Default::default() }),
    "modified\n",
  )
  @test.assert_eq(
    @bitlib.resolve_ref(fs, root + "/.git", "refs/heads/third"),
    second_id,
  )
  assert_true(
    decode_bytes(
      fs.read_file(root + "/.git/logs/HEAD") catch {
        _ => Default::default()
      },
    ).contains("Fast-forward"),
  )
  cleanup_tree(fs, root)
}

///|
async test "pull: refuses dirty worktree when fetch advances current branch" {
  @bitnative.init_native_io()
  cmd_bit_wbtest_env_lock.acquire()
  defer cmd_bit_wbtest_env_lock.release()
  let fs = OsFs::new()
  let root = "/tmp/bit-test pull fetch-updates-head-dirty trash directory-" +
    get_current_timestamp().to_string()
  cleanup_tree(fs, root)
  fs.mkdir_p(root)

  commit_wbtest_run_git(root, ["init", "--initial-branch=main", "-q"])
  commit_wbtest_run_git(root, ["config", "user.name", "Test User"])
  commit_wbtest_run_git(root, ["config", "user.email", "test@example.com"])
  fs.write_string(root + "/file", "base\n")
  commit_wbtest_run_git(root, ["add", "file"])
  commit_wbtest_run_git(root, ["commit", "-q", "-m", "base"])
  fs.write_string(root + "/file", "file\n")
  commit_wbtest_run_git(root, ["commit", "-q", "-a", "-m", "original"])
  commit_wbtest_run_git(root, ["checkout", "-q", "-b", "second", "main"])
  fs.write_string(root + "/file", "modified\n")
  commit_wbtest_run_git(root, ["commit", "-q", "-a", "-m", "modified"])
  let second_id = @bitlib.resolve_ref(fs, root + "/.git", "refs/heads/second")
  commit_wbtest_run_git(root, ["checkout", "-q", "-b", "third", "second^"])
  fs.write_string(root + "/file", "conflict\n")

  let (code, _stdout, stderr) = handlers_remote_pull_wbtest_collect_shim_git(
    root,
    ["pull", ".", "second:third"],
  )

  assert_true(code != 0)
  assert_true(stderr.contains("Cannot fast-forward your working tree"))
  @test.assert_eq(
    decode_bytes(fs.read_file(root + "/file") catch { _ => Default::default() }),
    "conflict\n",
  )
  @test.assert_eq(
    @bitlib.resolve_ref(fs, root + "/.git", "refs/heads/third"),
    second_id,
  )
  cleanup_tree(fs, root)
}

///|
async test "pull: rebase rejects multiple explicit refspecs" {
  @bitnative.init_native_io()
  cmd_bit_wbtest_env_lock.acquire()
  defer cmd_bit_wbtest_env_lock.release()
  let fs = OsFs::new()
  let root = "/tmp/bit-test pull rebase-multi trash directory-" +
    get_current_timestamp().to_string()
  cleanup_tree(fs, root)
  fs.mkdir_p(root)

  commit_wbtest_run_git(root, ["init", "--initial-branch=main", "-q"])
  commit_wbtest_run_git(root, ["config", "user.name", "Test User"])
  commit_wbtest_run_git(root, ["config", "user.email", "test@example.com"])
  fs.write_string(root + "/file", "base\n")
  commit_wbtest_run_git(root, ["add", "file"])
  commit_wbtest_run_git(root, ["commit", "-q", "-m", "base"])
  commit_wbtest_run_git(root, ["branch", "copy", "main"])
  fs.write_string(root + "/file", "modified\n")
  commit_wbtest_run_git(root, ["commit", "-q", "-a", "-m", "modified"])

  let (code, _stdout, stderr) = handlers_remote_pull_wbtest_collect_shim_git(
    root,
    ["pull", "--rebase", ".", "copy", "main"],
  )

  assert_true(code != 0)
  assert_true(stderr.contains("Cannot rebase onto multiple branches"))
  cleanup_tree(fs, root)
}

///|
async test "pull: rebase autostash preserves staged file on fast-forward" {
  @bitnative.init_native_io()
  cmd_bit_wbtest_env_lock.acquire()
  defer cmd_bit_wbtest_env_lock.release()
  let fs = OsFs::new()
  let root = "/tmp/bit-test pull rebase-autostash trash directory-" +
    get_current_timestamp().to_string()
  cleanup_tree(fs, root)
  fs.mkdir_p(root)

  commit_wbtest_run_git(root, ["init", "--initial-branch=main", "-q"])
  commit_wbtest_run_git(root, ["config", "user.name", "Test User"])
  commit_wbtest_run_git(root, ["config", "user.email", "test@example.com"])
  fs.write_string(root + "/file", "file\n")
  commit_wbtest_run_git(root, ["add", "file"])
  commit_wbtest_run_git(root, ["commit", "-q", "-m", "original"])
  commit_wbtest_run_git(root, ["branch", "copy", "main"])
  fs.write_string(root + "/file", "modified again\n")
  commit_wbtest_run_git(root, ["commit", "-q", "-a", "-m", "file"])
  commit_wbtest_run_git(root, ["checkout", "-q", "-b", "to-rebase", "copy"])
  fs.write_string(root + "/new_file", "dirty\n")
  commit_wbtest_run_git(root, ["add", "new_file"])
  commit_wbtest_run_git(root, ["config", "rebase.autostash", "true"])

  handlers_remote_pull_wbtest_run_shim_git(root, [
    "pull", "--rebase", "-q", ".", "main",
  ])

  @test.assert_eq(
    decode_bytes(
      fs.read_file(root + "/new_file") catch {
        _ => Default::default()
      },
    ),
    "dirty\n",
  )
  @test.assert_eq(
    decode_bytes(fs.read_file(root + "/file") catch { _ => Default::default() }),
    "modified again\n",
  )
  @test.assert_eq(@bitlib.stash_list(fs, root + "/.git").length(), 0)
  cleanup_tree(fs, root)
}

///|
async test "pull: unborn conflict detection only keeps colliding paths" {
  let fs = @bitcore.TestFs::new()
  fs.mkdir_p("/repo/.git")
  fs.write_string("/repo/.git/HEAD", "ref: refs/heads/main\n")
  fs.write_string("/repo/file", "file\n")
  fs.write_string("/repo/extra", "extra\n")
  let file_id = @bitcore.ObjectId::from_hex(
    "1111111111111111111111111111111111111111",
  )
  let newfile_id = @bitcore.ObjectId::from_hex(
    "2222222222222222222222222222222222222222",
  )
  @bitlib.write_index_entries(fs, "/repo/.git", [
    @bitlib.IndexEntry::new("file", file_id, 0o100644, 5),
    @bitlib.IndexEntry::new("newfile", newfile_id, 0o100644, 8),
  ])
  let status = @bitlib.status(fs, "/repo")
  let target_modes : Map[String, Int] = Map([])
  target_modes["file"] = 0o100644
  target_modes["extra"] = 0o100644
  let conflicts = pull_collect_initial_conflicting_paths(status, target_modes)
  @test.assert_eq(conflicts.length(), 2)
  assert_true(conflicts.contains("file"))
  assert_true(conflicts.contains("extra"))
}

///|
test "pull: unborn preserve index entries outside target tree" {
  let keep_id = @bitcore.ObjectId::from_hex(
    "0123456789abcdef0123456789abcdef01234567",
  )
  let drop_id = @bitcore.ObjectId::from_hex(
    "89abcdef0123456789abcdef0123456789abcdef",
  )
  let entries = [
    @bitlib.IndexEntry::new("keep", keep_id, 0o100644, 1),
    @bitlib.IndexEntry::new("drop", drop_id, 0o100644, 1),
  ]
  let target_modes : Map[String, Int] = Map([])
  target_modes["drop"] = 0o100644
  let preserved = pull_collect_initial_preserved_index_entries(
    entries, target_modes,
  )
  @test.assert_eq(preserved.length(), 1)
  @test.assert_eq(preserved[0].path, "keep")
}

///|
test "fetch transport: http url uses http transport" {
  let transport = resolve_upload_pack_transport(
    "https://github.com/mizchi/bit-vcs.git",
  )
  assert_true(
    match transport {
      UploadPackTransport::Http => true
      _ => false
    },
  )
}

///|
test "fetch transport: scp style ssh url uses process transport" {
  let transport = resolve_upload_pack_transport(
    "git@github.com:mizchi/bit-vcs.git",
  )
  assert_true(
    match transport {
      UploadPackTransport::Process => true
      _ => false
    },
  )
}

///|
test "fetch transport: file path uses process transport" {
  let transport = resolve_upload_pack_transport("/tmp/example-repo")
  assert_true(
    match transport {
      UploadPackTransport::Process => true
      _ => false
    },
  )
}

///|
test "pull relay: remote detection handles explicit relay schemes" {
  assert_true(pull_remote_uses_relay_signaling("relay+http://127.0.0.1:8788"))
  assert_true(
    pull_remote_uses_relay_signaling("relay+https://relay.example.com"),
  )
  assert_true(pull_remote_uses_relay_signaling("relay://relay.example.com"))
  assert_false(
    pull_remote_uses_relay_signaling("https://relay.example.com/repo.git"),
  )
  assert_false(
    pull_remote_uses_relay_signaling("git@github.com:mizchi/bit.git"),
  )
}

///|
test "pull relay: preferred sender/repo env is trimmed and optional" {
  let prev_sender = @sys.get_env_var("BIT_RELAY_PULL_SENDER")
  let prev_repo = @sys.get_env_var("BIT_RELAY_PULL_REPO")
  @sys.set_env_var("BIT_RELAY_PULL_SENDER", " node-a ")
  @sys.set_env_var("BIT_RELAY_PULL_REPO", " repo-b ")
  @test.assert_eq(pull_relay_preferred_sender(), Some("node-a"))
  @test.assert_eq(pull_relay_preferred_repo(), Some("repo-b"))
  @sys.set_env_var("BIT_RELAY_PULL_SENDER", "   ")
  @sys.set_env_var("BIT_RELAY_PULL_REPO", "   ")
  @test.assert_eq(pull_relay_preferred_sender(), None)
  @test.assert_eq(pull_relay_preferred_repo(), None)
  restore_env_var_for_fetch_wbtest("BIT_RELAY_PULL_SENDER", prev_sender)
  restore_env_var_for_fetch_wbtest("BIT_RELAY_PULL_REPO", prev_repo)
}

///|
test "pull relay: sender filter is preferred over repo filter" {
  let peers : Array[(String, String, String?)] = [
    ("node-a", "http://node-a:9418/repo-a.git", Some("repo-a")),
    ("node-b", "http://node-b:9418/repo-b.git", Some("repo-b")),
  ]
  let selected = pull_select_relay_peer(
    peers,
    preferred_sender=Some("node-a"),
    preferred_repo=Some("repo-b"),
  )
  @test.assert_eq(selected, Some(("node-a", "http://node-a:9418/repo-a.git")))
}

///|
test "pull relay: falls back to repo and then first peer" {
  let peers : Array[(String, String, String?)] = [
    ("node-a", "http://node-a:9418/repo-a.git", Some("repo-a")),
    ("node-b", "http://node-b:9418/repo-b.git", Some("repo-b")),
  ]
  let by_repo = pull_select_relay_peer(
    peers,
    preferred_sender=Some("node-z"),
    preferred_repo=Some("repo-b"),
  )
  @test.assert_eq(by_repo, Some(("node-b", "http://node-b:9418/repo-b.git")))
  let first = pull_select_relay_peer(
    peers,
    preferred_sender=None,
    preferred_repo=Some("repo-z"),
  )
  @test.assert_eq(first, Some(("node-a", "http://node-a:9418/repo-a.git")))
}

///|
fn cleanup_tree(fs : OsFs, path : String) -> Unit {
  if fs.is_file(path) {
    fs.remove_file(path) catch {
      _ => ()
    }
    return
  }
  if not(fs.is_dir(path)) {
    return
  }
  let entries = fs.readdir(path) catch { _ => [] }
  for entry in entries {
    if entry == "." || entry == ".." {
      continue
    }
    cleanup_tree(fs, path + "/" + entry)
  }
  fs.remove_dir(path) catch {
    _ => ()
  }
}

///|
async test "core: init --bit creates .bit repository metadata directory" {
  let fs = OsFs::new()
  let path = "/tmp/bit-test-init-bit-" + get_current_timestamp().to_string()
  cleanup_tree(fs, path)
  let prev_git_dir = @sys.get_env_var("GIT_DIR")
  let prev_work_tree = @sys.get_env_var("GIT_WORK_TREE")
  let prev_shim_cwd = @sys.get_env_var("GIT_SHIM_CWD")
  let prev_shim_pwd = @sys.get_env_var("GIT_SHIM_PWD")
  @sys.unset_env_var("GIT_DIR")
  @sys.unset_env_var("GIT_WORK_TREE")
  @sys.unset_env_var("GIT_SHIM_CWD")
  @sys.set_env_var("GIT_SHIM_PWD", ".")
  handle_init(["-q", "--bit", path])
  assert_true(fs.is_dir(path + "/.bit"))
  assert_true(fs.is_file(path + "/.bit/HEAD"))
  let resolved = resolve_git_dir(fs, path)
  assert_eq(resolved, path + "/.bit")
  let status = @gitlib.status(fs, path)
  assert_eq(status.untracked.length(), 0)
  @sys.set_env_var("GIT_SHIM_CWD", path)
  @sys.set_env_var("GIT_SHIM_PWD", path)
  @sys.unset_env_var("GIT_DIR")
  @sys.unset_env_var("GIT_WORK_TREE")
  handle_status(["--porcelain"])
  match prev_git_dir {
    Some(value) => @sys.set_env_var("GIT_DIR", value)
    None => @sys.unset_env_var("GIT_DIR")
  }
  match prev_work_tree {
    Some(value) => @sys.set_env_var("GIT_WORK_TREE", value)
    None => @sys.unset_env_var("GIT_WORK_TREE")
  }
  match prev_shim_cwd {
    Some(value) => @sys.set_env_var("GIT_SHIM_CWD", value)
    None => @sys.unset_env_var("GIT_SHIM_CWD")
  }
  match prev_shim_pwd {
    Some(value) => @sys.set_env_var("GIT_SHIM_PWD", value)
    None => @sys.unset_env_var("GIT_SHIM_PWD")
  }
  cleanup_tree(fs, path)
}

///|
async test "core: init --template= does not precreate hooks directory" {
  let fs = OsFs::new()
  let path = "/tmp/bit-test-init-template-empty-" +
    get_current_timestamp().to_string()
  cleanup_tree(fs, path)
  let prev_git_dir = @sys.get_env_var("GIT_DIR")
  let prev_work_tree = @sys.get_env_var("GIT_WORK_TREE")
  let prev_shim_cwd = @sys.get_env_var("GIT_SHIM_CWD")
  let prev_shim_pwd = @sys.get_env_var("GIT_SHIM_PWD")
  @sys.unset_env_var("GIT_DIR")
  @sys.unset_env_var("GIT_WORK_TREE")
  @sys.unset_env_var("GIT_SHIM_CWD")
  @sys.set_env_var("GIT_SHIM_PWD", ".")
  handle_init(["-q", "--template=", path])
  assert_true(fs.is_dir(path + "/.git"))
  assert_false(fs.is_dir(path + "/.git/hooks"))
  fs.mkdir_p(path + "/.git/hooks")
  assert_true(fs.is_dir(path + "/.git/hooks"))
  match prev_git_dir {
    Some(value) => @sys.set_env_var("GIT_DIR", value)
    None => @sys.unset_env_var("GIT_DIR")
  }
  match prev_work_tree {
    Some(value) => @sys.set_env_var("GIT_WORK_TREE", value)
    None => @sys.unset_env_var("GIT_WORK_TREE")
  }
  match prev_shim_cwd {
    Some(value) => @sys.set_env_var("GIT_SHIM_CWD", value)
    None => @sys.unset_env_var("GIT_SHIM_CWD")
  }
  match prev_shim_pwd {
    Some(value) => @sys.set_env_var("GIT_SHIM_PWD", value)
    None => @sys.unset_env_var("GIT_SHIM_PWD")
  }
  cleanup_tree(fs, path)
}

///|
async test "core: commit --allow-empty creates initial commit" {
  let fs = OsFs::new()
  let path = "/tmp/bit-test-commit-allow-empty-" +
    get_current_timestamp().to_string()
  cleanup_tree(fs, path)
  let prev_git_dir = @sys.get_env_var("GIT_DIR")
  let prev_work_tree = @sys.get_env_var("GIT_WORK_TREE")
  let prev_shim_cwd = @sys.get_env_var("GIT_SHIM_CWD")
  let prev_shim_pwd = @sys.get_env_var("GIT_SHIM_PWD")
  let prev_author_name = @sys.get_env_var("GIT_AUTHOR_NAME")
  let prev_author_email = @sys.get_env_var("GIT_AUTHOR_EMAIL")
  let prev_committer_name = @sys.get_env_var("GIT_COMMITTER_NAME")
  let prev_committer_email = @sys.get_env_var("GIT_COMMITTER_EMAIL")
  @sys.unset_env_var("GIT_DIR")
  @sys.unset_env_var("GIT_WORK_TREE")
  @sys.unset_env_var("GIT_SHIM_CWD")
  @sys.set_env_var("GIT_SHIM_PWD", ".")
  @sys.set_env_var("GIT_AUTHOR_NAME", "Test User")
  @sys.set_env_var("GIT_AUTHOR_EMAIL", "test@example.com")
  @sys.set_env_var("GIT_COMMITTER_NAME", "Test User")
  @sys.set_env_var("GIT_COMMITTER_EMAIL", "test@example.com")
  handle_init(["-q", path])
  @sys.set_env_var("GIT_SHIM_CWD", path)
  @sys.set_env_var("GIT_SHIM_PWD", path)
  handle_commit(["-q", "--allow-empty", "-m", "empty commit"])
  assert_true(fs.is_file(path + "/.git/refs/heads/main"))
  let head_ref = fs.read_file(path + "/.git/refs/heads/main")
  assert_true(head_ref.length() > 0)
  match prev_git_dir {
    Some(value) => @sys.set_env_var("GIT_DIR", value)
    None => @sys.unset_env_var("GIT_DIR")
  }
  match prev_work_tree {
    Some(value) => @sys.set_env_var("GIT_WORK_TREE", value)
    None => @sys.unset_env_var("GIT_WORK_TREE")
  }
  match prev_shim_cwd {
    Some(value) => @sys.set_env_var("GIT_SHIM_CWD", value)
    None => @sys.unset_env_var("GIT_SHIM_CWD")
  }
  match prev_shim_pwd {
    Some(value) => @sys.set_env_var("GIT_SHIM_PWD", value)
    None => @sys.unset_env_var("GIT_SHIM_PWD")
  }
  match prev_author_name {
    Some(value) => @sys.set_env_var("GIT_AUTHOR_NAME", value)
    None => @sys.unset_env_var("GIT_AUTHOR_NAME")
  }
  match prev_author_email {
    Some(value) => @sys.set_env_var("GIT_AUTHOR_EMAIL", value)
    None => @sys.unset_env_var("GIT_AUTHOR_EMAIL")
  }
  match prev_committer_name {
    Some(value) => @sys.set_env_var("GIT_COMMITTER_NAME", value)
    None => @sys.unset_env_var("GIT_COMMITTER_NAME")
  }
  match prev_committer_email {
    Some(value) => @sys.set_env_var("GIT_COMMITTER_EMAIL", value)
    None => @sys.unset_env_var("GIT_COMMITTER_EMAIL")
  }
  cleanup_tree(fs, path)
}

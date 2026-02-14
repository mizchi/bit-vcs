///|
fn restore_env_var_for_add_wbtest(name : String, prev : String?) -> Unit {
  match prev {
    Some(value) => @sys.set_env_var(name, value)
    None => @sys.unset_env_var(name)
  }
}

///|
test "add: sha256 repository requires real-git delegation when available" {
  let prev_shim_real_git = @sys.get_env_var("SHIM_REAL_GIT")
  let prev_legacy_real_git = @sys.get_env_var("GIT_SHIM_REAL_GIT")
  @sys.set_env_var("SHIM_REAL_GIT", "git")
  @sys.unset_env_var("GIT_SHIM_REAL_GIT")

  let fs = @git.TestFs::new()
  fs.mkdir_p("/repo/.git")
  fs.write_string(
    "/repo/.git/config", "[extensions]\n\tobjectformat = sha256\n",
  )
  assert_true(add_repo_requires_real_git_delegate(fs, "/repo/.git"))

  fs.write_string(
    "/repo/.git/config",
    "[core]\n\trepositoryformatversion = 0\n",
  )
  assert_false(add_repo_requires_real_git_delegate(fs, "/repo/.git"))

  restore_env_var_for_add_wbtest("SHIM_REAL_GIT", prev_shim_real_git)
  restore_env_var_for_add_wbtest("GIT_SHIM_REAL_GIT", prev_legacy_real_git)
}

///|
test "add: compatobjectformat=sha256 requires real-git delegation when available" {
  let prev_shim_real_git = @sys.get_env_var("SHIM_REAL_GIT")
  let prev_legacy_real_git = @sys.get_env_var("GIT_SHIM_REAL_GIT")
  @sys.set_env_var("SHIM_REAL_GIT", "git")
  @sys.unset_env_var("GIT_SHIM_REAL_GIT")

  let fs = @git.TestFs::new()
  fs.mkdir_p("/repo/.git")
  fs.write_string(
    "/repo/.git/config", "[extensions]\n\tcompatobjectformat = sha256\n",
  )
  assert_true(add_repo_requires_real_git_delegate(fs, "/repo/.git"))

  fs.write_string(
    "/repo/.git/config", "[extensions]\n\tcompatobjectformat = sha1\n",
  )
  assert_false(add_repo_requires_real_git_delegate(fs, "/repo/.git"))

  restore_env_var_for_add_wbtest("SHIM_REAL_GIT", prev_shim_real_git)
  restore_env_var_for_add_wbtest("GIT_SHIM_REAL_GIT", prev_legacy_real_git)
}

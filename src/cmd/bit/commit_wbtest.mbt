///|
test "commit: signing options trigger real-git delegation when enabled" {
  let prev_shim_real_git = @sys.get_env_var("SHIM_REAL_GIT")
  let prev_legacy_real_git = @sys.get_env_var("GIT_SHIM_REAL_GIT")
  @sys.set_env_var("SHIM_REAL_GIT", "/usr/bin/git")
  @sys.unset_env_var("GIT_SHIM_REAL_GIT")
  assert_true(commit_should_delegate_to_real_git(["-S", "-m", "msg"]))
  assert_true(
    commit_should_delegate_to_real_git(["-S/path/to/key", "-m", "msg"]),
  )
  assert_true(commit_should_delegate_to_real_git(["--gpg-sign", "-m", "msg"]))
  assert_true(
    commit_should_delegate_to_real_git(["--gpg-sign=KEY", "-m", "msg"]),
  )
  match prev_shim_real_git {
    Some(value) => @sys.set_env_var("SHIM_REAL_GIT", value)
    None => @sys.unset_env_var("SHIM_REAL_GIT")
  }
  match prev_legacy_real_git {
    Some(value) => @sys.set_env_var("GIT_SHIM_REAL_GIT", value)
    None => @sys.unset_env_var("GIT_SHIM_REAL_GIT")
  }
}

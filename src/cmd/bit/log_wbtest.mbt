///|
test "log delegate gate: oneline + count stays in pure path" {
  assert_false(log_args_require_real_git(["--oneline", "-1"]))
  assert_false(log_args_require_real_git(["-n", "2", "--oneline"]))
  assert_false(log_args_require_real_git(["--oneline", "--max-count=2"]))
}

///|
test "log delegate gate: no-count or positional forms are delegated" {
  assert_true(log_args_require_real_git([]))
  assert_true(log_args_require_real_git(["--oneline"]))
  assert_true(log_args_require_real_git(["--oneline", "HEAD~1"]))
}

///|
test "log delegate gate: unsupported forms are delegated" {
  assert_true(log_args_require_real_git(["--pretty=%s"]))
  assert_true(log_args_require_real_git(["--author=alice"]))
  assert_true(log_args_require_real_git(["--", "a.txt"]))
}

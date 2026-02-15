///|
test "update-ref stdin token split trims repeated spaces" {
  let tokens = update_ref_split_stdin_tokens(
    "  create   refs/tags/v1   deadbeef  ",
  )
  assert_eq(tokens.length(), 3)
  assert_eq(tokens[0], "create")
  assert_eq(tokens[1], "refs/tags/v1")
  assert_eq(tokens[2], "deadbeef")
}

///|
test "update-ref stdin base args keep flags and message" {
  let args = update_ref_stdin_base_args(true, true, Some("from-stdin"))
  assert_eq(args.length(), 4)
  assert_eq(args[0], "--no-deref")
  assert_eq(args[1], "--create-reflog")
  assert_eq(args[2], "-m")
  assert_eq(args[3], "from-stdin")
}

///|
test "update-ref: storage runtime routing follows simple parser support" {
  assert_true(
    update_ref_should_use_storage_runtime_args([
      "refs/heads/main", "0123456789012345678901234567890123456789",
    ]),
  )
  assert_true(
    update_ref_should_use_storage_runtime_args([
      "-d", "refs/heads/main", "0123456789012345678901234567890123456789",
    ]),
  )

  assert_false(update_ref_should_use_storage_runtime_args(["--stdin"]))
  assert_false(
    update_ref_should_use_storage_runtime_args([
      "--create-reflog", "refs/heads/main", "0123456789012345678901234567890123456789",
    ]),
  )
}

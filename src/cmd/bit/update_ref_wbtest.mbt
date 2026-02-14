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

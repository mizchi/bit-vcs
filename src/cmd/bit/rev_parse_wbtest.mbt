///|
test "rev-parse: output-object-format uses loose-object-idx mapping" {
  let fs = @bitcore.TestFs::new()
  fs.mkdir_p("/repo/.git/objects")
  fs.write_string(
    "/repo/.git/config", "[extensions]\n\tobjectformat = sha1\n\tcompatobjectformat = sha256\n",
  )
  fs.write_string(
    "/repo/.git/objects/loose-object-idx", "# loose-object-idx\n1111111111111111111111111111111111111111 2222222222222222222222222222222222222222222222222222222222222222\n",
  )
  let oid = @bitcore.ObjectId::from_hex(
    "1111111111111111111111111111111111111111",
  )
  assert_eq(
    rev_parse_resolve_output_oid_hex(fs, "/repo/.git", oid, Some("sha256")),
    "2222222222222222222222222222222222222222222222222222222222222222",
  )
}

///|
test "rev-parse: output-object-format falls back to storage oid when mapping is absent" {
  let fs = @bitcore.TestFs::new()
  fs.mkdir_p("/repo/.git")
  fs.write_string(
    "/repo/.git/config", "[extensions]\n\tobjectformat = sha1\n\tcompatobjectformat = sha256\n",
  )
  let oid = @bitcore.ObjectId::from_hex(
    "3333333333333333333333333333333333333333",
  )
  assert_eq(
    rev_parse_resolve_output_oid_hex(fs, "/repo/.git", oid, Some("sha256")),
    "3333333333333333333333333333333333333333",
  )
}

///|
test "rev-parse: --git-path resolves relative paths from git dir" {
  assert_eq(
    rev_parse_resolve_git_path("/repo", ".git", "objects/aa/bb"),
    ".git/objects/aa/bb",
  )
  assert_eq(
    rev_parse_resolve_git_path("/repo", ".", "objects/aa/bb"),
    "objects/aa/bb",
  )
}

///|
test "rev-parse: --git-path keeps absolute path argument" {
  assert_eq(
    rev_parse_resolve_git_path("/repo", ".git", "/tmp/custom-path"),
    "/tmp/custom-path",
  )
}

///|
test "rev-parse: --git-path prefers cwd-relative path for absolute git dir" {
  assert_eq(
    rev_parse_resolve_git_path("/repo", "/repo/.git", "objects/aa/bb"),
    ".git/objects/aa/bb",
  )
  assert_eq(
    rev_parse_resolve_git_path(
      "/repo/corrupt-loose.git", "/repo/corrupt-loose.git", "objects/aa/bb",
    ),
    "objects/aa/bb",
  )
}

///|
test "write-tree: compatobjectformat=sha256 requires standalone error" {
  let fs = @git.TestFs::new()
  fs.mkdir_p("/repo/.git")
  fs.write_string(
    "/repo/.git/config", "[extensions]\n\tcompatobjectformat = sha256\n",
  )
  assert_true(write_tree_repo_requires_standalone_error(fs, "/repo/.git"))

  fs.write_string(
    "/repo/.git/config", "[extensions]\n\tcompatobjectformat = sha1\n",
  )
  assert_false(write_tree_repo_requires_standalone_error(fs, "/repo/.git"))
}

///|
test "write-tree: storage runtime routing follows parser support" {
  assert_true(write_tree_should_use_storage_runtime([]))
  assert_true(write_tree_should_use_storage_runtime(["--prefix=sub/"]))

  assert_false(write_tree_should_use_storage_runtime(["sub/path"]))
  assert_false(write_tree_should_use_storage_runtime(["--dry-run"]))
}

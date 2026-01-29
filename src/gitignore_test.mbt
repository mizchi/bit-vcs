///| Tests for gitignore and ls-files behavior

///|
fn setup_repo_fs() -> TestFs {
  let fs = TestFs::new()
  fs.mkdir_p("/repo")
  fs
}

///|
test "gitignore: basic ignore and .git skip" {
  let fs = setup_repo_fs()
  fs.write_string("/repo/.gitignore", "*.log\n")
  fs.write_string("/repo/keep.txt", "ok")
  fs.write_string("/repo/debug.log", "ng")
  fs.mkdir_p("/repo/sub")
  fs.write_string("/repo/sub/info.log", "ng")
  fs.mkdir_p("/repo/.git")
  fs.write_string("/repo/.git/config", "[core]\n")
  let files = list_working_files(fs, "/repo")
  assert_true(files.contains("keep.txt"))
  assert_true(not(files.contains("debug.log")))
  assert_true(not(files.contains("sub/info.log")))
  assert_true(not(files.contains(".git/config")))
}

///|
test "gitignore: negation and dir ignore" {
  let fs = setup_repo_fs()
  fs.write_string("/repo/.gitignore", "build/\n*.log\n!important.log\n")
  fs.mkdir_p("/repo/build")
  fs.write_string("/repo/build/out.txt", "ng")
  fs.write_string("/repo/important.log", "ok")
  fs.write_string("/repo/other.log", "ng")
  let files = list_working_files(fs, "/repo")
  assert_true(files.contains("important.log"))
  assert_true(not(files.contains("other.log")))
  assert_true(not(files.contains("build/out.txt")))
}

///|
test "gitignore: nested gitignore" {
  let fs = setup_repo_fs()
  fs.write_string("/repo/.gitignore", "*.tmp\n")
  fs.mkdir_p("/repo/src")
  fs.write_string("/repo/src/.gitignore", "!keep.tmp\n")
  fs.write_string("/repo/src/keep.tmp", "ok")
  fs.write_string("/repo/src/drop.tmp", "ng")
  let files = list_working_files(fs, "/repo")
  assert_true(files.contains("src/keep.tmp"))
  assert_true(not(files.contains("src/drop.tmp")))
}

///|
test "gitignore: is_ignored_path" {
  let fs = setup_repo_fs()
  fs.write_string("/repo/.gitignore", "*.log\n")
  assert_true(is_ignored_path(fs, "/repo", "a.log", false))
  assert_true(not(is_ignored_path(fs, "/repo", "a.txt", false)))
}

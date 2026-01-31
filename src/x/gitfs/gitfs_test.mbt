///|
/// GitFs blackbox tests
test "gitfs: empty filesystem" {
  let gitfs = GitFs::empty("/repo/.git")
  assert_eq(gitfs.is_dirty(), false)
  assert_eq(gitfs.base_tree(), @git.ObjectId::zero())
  assert_eq(gitfs.base_commit(), None)
}

///|
test "gitfs: write and read file in working layer" {
  let gitfs = GitFs::empty("/repo/.git")
  gitfs.write_string("/file.txt", "hello\n")
  assert_eq(gitfs.is_dirty(), true)
  let files = gitfs.get_working_files()
  assert_eq(files, ["file.txt"])
}

///|
test "gitfs: mkdir_p creates directory hierarchy" {
  let gitfs = GitFs::empty("/repo/.git")
  gitfs.mkdir_p("a/b/c")
  assert_eq(gitfs.is_dirty(), true)
}

///|
test "gitfs: remove_file marks file as deleted" {
  let gitfs = GitFs::empty("/repo/.git")
  gitfs.write_string("file.txt", "content")
  gitfs.remove_file("file.txt")
  let files = gitfs.get_working_files()
  assert_eq(files, [])
  let deleted = gitfs.get_deleted_files()
  assert_eq(deleted, ["file.txt"])
}

///|
test "gitfs: rollback clears working layer" {
  let gitfs = GitFs::empty("/repo/.git")
  gitfs.write_string("file.txt", "content")
  assert_eq(gitfs.is_dirty(), true)
  gitfs.rollback()
  assert_eq(gitfs.is_dirty(), false)
  assert_eq(gitfs.get_working_files(), [])
}

///|
test "gitfs: config defaults" {
  let config = GitFsConfig::default()
  assert_eq(config.max_cache_bytes, 64 * 1024 * 1024)
  assert_eq(config.max_cache_entries, 1000)
}

///|
test "gitfs: full workflow with backing fs" {
  let fs = @git.TestFs::new()
  @lib.init_repo(fs, "/repo")
  fs.write_string("/repo/file.txt", "initial\n")
  @lib.add_paths(fs, fs, "/repo", ["file.txt"])
  let commit1 = @lib.commit(
    fs, fs, "/repo", "Initial commit", "Author <a@b.com>", 1700000000L,
  )
  let gitfs = GitFs::from_commit(fs, "/repo/.git", commit1)
  let content = gitfs.read_file(fs, "file.txt")
  assert_eq(@utf8.decode_lossy(content[:]), "initial\n")
  gitfs.write_string("file.txt", "modified\n")
  assert_eq(gitfs.is_dirty(), true)
  let snap = gitfs.snapshot(
    fs, fs, "Snapshot 1", "Author <a@b.com>", 1700001000L,
  )
  assert_eq(gitfs.is_dirty(), false)
  assert_true(snap.commit_id != commit1)
  gitfs.write_string("file.txt", "changed again\n")
  gitfs.rollback()
  let content2 = gitfs.read_file(fs, "file.txt")
  assert_eq(@utf8.decode_lossy(content2[:]), "modified\n")
}

///|
test "gitfs: readdir from base tree" {
  let fs = @git.TestFs::new()
  @lib.init_repo(fs, "/repo")
  fs.write_string("/repo/a/b.txt", "content\n")
  fs.write_string("/repo/a/c.txt", "content\n")
  fs.write_string("/repo/d.txt", "content\n")
  @lib.add_paths(fs, fs, "/repo", ["a/b.txt", "a/c.txt", "d.txt"])
  let commit = @lib.commit(
    fs, fs, "/repo", "Add files", "Author <a@b.com>", 1700000000L,
  )
  let gitfs = GitFs::from_commit(fs, "/repo/.git", commit)
  let root_entries = gitfs.readdir(fs, "")
  assert_true(root_entries.contains("a"))
  assert_true(root_entries.contains("d.txt"))
  let a_entries = gitfs.readdir(fs, "a")
  assert_true(a_entries.contains("b.txt"))
  assert_true(a_entries.contains("c.txt"))
}

///|
test "gitfs: is_dir and is_file" {
  let fs = @git.TestFs::new()
  @lib.init_repo(fs, "/repo")
  fs.write_string("/repo/dir/file.txt", "content\n")
  @lib.add_paths(fs, fs, "/repo", ["dir/file.txt"])
  let commit = @lib.commit(
    fs, fs, "/repo", "Add file", "Author <a@b.com>", 1700000000L,
  )
  let gitfs = GitFs::from_commit(fs, "/repo/.git", commit)
  assert_true(gitfs.is_dir(fs, ""))
  assert_true(gitfs.is_dir(fs, "dir"))
  assert_false(gitfs.is_dir(fs, "dir/file.txt"))
  assert_true(gitfs.is_file(fs, "dir/file.txt"))
  assert_false(gitfs.is_file(fs, "dir"))
  assert_false(gitfs.is_file(fs, "nonexistent"))
}

///|
test "gitfs: layers" {
  let fs = @git.TestFs::new()
  @lib.init_repo(fs, "/repo")
  fs.write_string("/repo/base.txt", "base\n")
  @lib.add_paths(fs, fs, "/repo", ["base.txt"])
  let commit1 = @lib.commit(
    fs, fs, "/repo", "Base", "Author <a@b.com>", 1700000000L,
  )
  fs.write_string("/repo/layer.txt", "layer\n")
  @lib.add_paths(fs, fs, "/repo", ["layer.txt"])
  let commit2 = @lib.commit(
    fs, fs, "/repo", "Layer", "Author <a@b.com>", 1700001000L,
  )
  let gitfs = GitFs::from_commit(fs, "/repo/.git", commit1)
  assert_true(gitfs.is_file(fs, "base.txt"))
  assert_false(gitfs.is_file(fs, "layer.txt"))
  gitfs.add_layer_from_commit(fs, commit2, "overlay")
  assert_true(gitfs.is_file(fs, "layer.txt"))
  assert_true(gitfs.has_layer("overlay"))
  let removed = gitfs.remove_layer("overlay")
  assert_true(removed)
  assert_false(gitfs.has_layer("overlay"))
  assert_false(gitfs.is_file(fs, "layer.txt"))
}

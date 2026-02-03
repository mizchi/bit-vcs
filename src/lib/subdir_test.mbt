///| Tests for subdir path resolution

///|
test "subdir: get_subdir_tree_from_commit rejects missing or file path" {
  let fs = @git.TestFs::new()
  init_repo(fs, "/repo") catch {
    _ => return ()
  }
  fs.mkdir_p("/repo/src")
  fs.write_file("/repo/src/fs.mbt", b"data")
  let commit_id = commit(fs, fs, "/repo", "init", "test <test@test.com>", 1000L) catch {
    _ => return ()
  }
  let db = ObjectDb::load(fs, "/repo/.git") catch { _ => return () }
  let missing = get_subdir_tree_from_commit(db, fs, commit_id, "src/missing")
  assert_true(missing is None)
  let file_path = get_subdir_tree_from_commit(db, fs, commit_id, "src/fs.mbt")
  assert_true(file_path is None)
}

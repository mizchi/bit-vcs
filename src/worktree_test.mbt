///| Tests for worktree status/add/commit

///|
fn setup_repo() -> TestFs {
  let fs = TestFs::new()
  ignore(try? init_repo(fs, "/repo"))
  fs
}

///|
test "worktree: status/add/commit" {
  let fs = setup_repo()
  fs.write_string("/repo/a.txt", "hello\n")
  let st1 = status(fs, "/repo")
  assert_true(st1.untracked.contains("a.txt"))
  add_paths(fs, fs, "/repo", ["a.txt"])
  let st2 = status(fs, "/repo")
  assert_true(st2.staged_added.contains("a.txt"))
  assert_true(st2.untracked.length() == 0)
  let commit_id = commit(
    fs, fs, "/repo", "msg\n", "Test <test@example.com>", 1700000000L,
  )
  let ref_text = fs.read_string("/repo/.git/refs/heads/main")
  assert_true(ref_text.contains(commit_id.to_hex()))
  let st3 = status(fs, "/repo")
  assert_true(st3.untracked.length() == 0)
  assert_true(st3.unstaged_modified.length() == 0)
  assert_true(st3.staged_added.length() == 0)
}

///|
test "worktree: modified after commit" {
  let fs = setup_repo()
  fs.write_string("/repo/a.txt", "hello\n")
  add_paths(fs, fs, "/repo", ["a.txt"])
  ignore(
    commit(fs, fs, "/repo", "msg\n", "Test <test@example.com>", 1700000000L),
  )
  fs.write_string("/repo/a.txt", "changed\n")
  let st = status(fs, "/repo")
  assert_true(st.unstaged_modified.contains("a.txt"))
}

///|
test "worktree: status text" {
  let fs = setup_repo()
  let text1 = status_text(fs, "/repo")
  assert_true(text1.contains("On branch main"))
  assert_true(text1.contains("No commits yet"))
  assert_true(text1.contains("nothing to commit"))
  fs.write_string("/repo/a.txt", "hello\n")
  add_paths(fs, fs, "/repo", ["a.txt"])
  let text2 = status_text(fs, "/repo")
  assert_true(text2.contains("Changes to be committed"))
  assert_true(text2.contains("staged: a.txt"))
}

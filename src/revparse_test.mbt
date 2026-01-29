///| Tests for rev-parse/show-ref/log/diff/status porcelain

///|
fn setup_rev_repo() -> TestFs {
  let fs = TestFs::new()
  fs.mkdir_p("/repo/.git/refs/heads")
  fs.write_string("/repo/.git/HEAD", "ref: refs/heads/main\n")
  fs
}

///|
test "rev-parse: HEAD and show-ref" {
  let fs = setup_rev_repo()
  fs.write_string("/repo/a.txt", "hello\n")
  add_paths(fs, fs, "/repo", ["a.txt"])
  let id = commit(
    fs, fs, "/repo", "msg\n", "Test <test@example.com>", 1700000000L,
  )
  let head = rev_parse(fs, "/repo/.git", "HEAD")
  assert_true(head is Some(_))
  assert_true(head.unwrap().to_hex() == id.to_hex())
  let refs = show_ref_text(fs, "/repo/.git")
  assert_true(refs.length() == 1)
  assert_true(refs[0].contains("refs/heads/main"))
}

///|
test "log: oneline" {
  let fs = setup_rev_repo()
  fs.write_string("/repo/a.txt", "hello\n")
  add_paths(fs, fs, "/repo", ["a.txt"])
  ignore(
    commit(fs, fs, "/repo", "first\n", "Test <test@example.com>", 1700000000L),
  )
  let lines = log_head_oneline(fs, "/repo/.git", max_count=10)
  assert_true(lines.length() == 1)
  assert_true(lines[0].contains("first"))
}

///|
test "status porcelain + diff" {
  let fs = setup_rev_repo()
  fs.write_string("/repo/a.txt", "hello\n")
  let st1 = status_porcelain(fs, "/repo")
  assert_true(st1.contains("?? a.txt"))
  add_paths(fs, fs, "/repo", ["a.txt"])
  let st2 = status_porcelain(fs, "/repo")
  assert_true(st2.contains("A  a.txt"))
  ignore(
    commit(fs, fs, "/repo", "first\n", "Test <test@example.com>", 1700000000L),
  )
  fs.write_string("/repo/a.txt", "changed\n")
  let diffs = diff_worktree(fs, "/repo")
  let text = diff_text(diffs)
  assert_true(text.contains("diff --git a/a.txt b/a.txt"))
}

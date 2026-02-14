///| Tests for rev-parse/show-ref/log/diff/status porcelain

///|
fn setup_rev_repo() -> @git.TestFs {
  let fs = @git.TestFs::new()
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
test "rev-parse: HEAD^ parent reference" {
  let fs = setup_rev_repo()
  // First commit
  fs.write_string("/repo/a.txt", "first\n")
  add_paths(fs, fs, "/repo", ["a.txt"])
  let first = commit(
    fs, fs, "/repo", "first\n", "Test <test@example.com>", 1700000000L,
  )
  // Second commit
  fs.write_string("/repo/a.txt", "second\n")
  add_paths(fs, fs, "/repo", ["a.txt"])
  let second = commit(
    fs, fs, "/repo", "second\n", "Test <test@example.com>", 1700000001L,
  )
  // HEAD should be second commit
  let head = rev_parse(fs, "/repo/.git", "HEAD")
  assert_eq(head.unwrap().to_hex(), second.to_hex())
  // HEAD^ should be first commit
  let parent = rev_parse(fs, "/repo/.git", "HEAD^")
  assert_eq(parent.unwrap().to_hex(), first.to_hex())
}

///|
test "rev-parse: @ and @^ aliases HEAD" {
  let fs = setup_rev_repo()
  fs.write_string("/repo/a.txt", "first\n")
  add_paths(fs, fs, "/repo", ["a.txt"])
  let first = commit(
    fs, fs, "/repo", "first\n", "Test <test@example.com>", 1700000000L,
  )
  fs.write_string("/repo/a.txt", "second\n")
  add_paths(fs, fs, "/repo", ["a.txt"])
  let second = commit(
    fs, fs, "/repo", "second\n", "Test <test@example.com>", 1700000001L,
  )
  let at = rev_parse(fs, "/repo/.git", "@")
  let at_parent = rev_parse(fs, "/repo/.git", "@^")
  assert_eq(at.unwrap().to_hex(), second.to_hex())
  assert_eq(at_parent.unwrap().to_hex(), first.to_hex())
}

///|
test "rev-parse: HEAD^^ and HEAD~2 are equivalent" {
  let fs = setup_rev_repo()
  // Three commits
  fs.write_string("/repo/a.txt", "first\n")
  add_paths(fs, fs, "/repo", ["a.txt"])
  let first = commit(
    fs, fs, "/repo", "first\n", "Test <test@example.com>", 1700000000L,
  )
  fs.write_string("/repo/a.txt", "second\n")
  add_paths(fs, fs, "/repo", ["a.txt"])
  ignore(
    commit(fs, fs, "/repo", "second\n", "Test <test@example.com>", 1700000001L),
  )
  fs.write_string("/repo/a.txt", "third\n")
  add_paths(fs, fs, "/repo", ["a.txt"])
  ignore(
    commit(fs, fs, "/repo", "third\n", "Test <test@example.com>", 1700000002L),
  )
  // HEAD^^ should be first commit
  let caret_caret = rev_parse(fs, "/repo/.git", "HEAD^^")
  assert_eq(caret_caret.unwrap().to_hex(), first.to_hex())
  // HEAD~2 should also be first commit
  let tilde_2 = rev_parse(fs, "/repo/.git", "HEAD~2")
  assert_eq(tilde_2.unwrap().to_hex(), first.to_hex())
}

///|
test "rev-parse: 40-char hex without suffix" {
  let fs = setup_rev_repo()
  fs.write_string("/repo/a.txt", "hello\n")
  add_paths(fs, fs, "/repo", ["a.txt"])
  let id = commit(
    fs, fs, "/repo", "msg\n", "Test <test@example.com>", 1700000000L,
  )
  // Parse by full hex should work
  let parsed = rev_parse(fs, "/repo/.git", id.to_hex())
  assert_eq(parsed.unwrap().to_hex(), id.to_hex())
}

///|
test "rev-parse: HEAD~1 equals HEAD^" {
  let fs = setup_rev_repo()
  fs.write_string("/repo/a.txt", "first\n")
  add_paths(fs, fs, "/repo", ["a.txt"])
  let first = commit(
    fs, fs, "/repo", "first\n", "Test <test@example.com>", 1700000000L,
  )
  fs.write_string("/repo/a.txt", "second\n")
  add_paths(fs, fs, "/repo", ["a.txt"])
  ignore(
    commit(fs, fs, "/repo", "second\n", "Test <test@example.com>", 1700000001L),
  )
  let caret = rev_parse(fs, "/repo/.git", "HEAD^")
  let tilde_1 = rev_parse(fs, "/repo/.git", "HEAD~1")
  assert_eq(caret.unwrap().to_hex(), first.to_hex())
  assert_eq(tilde_1.unwrap().to_hex(), first.to_hex())
}

///|
test "rev-parse: tag^{commit} peels annotated tag" {
  let fs = setup_rev_repo()
  fs.write_string("/repo/a.txt", "hello\n")
  add_paths(fs, fs, "/repo", ["a.txt"])
  let id = commit(
    fs, fs, "/repo", "msg\n", "Test <test@example.com>", 1700000000L,
  )
  create_annotated_tag(
    fs, fs, "/repo/.git", "v1", id, "annotated", "Test <test@example.com>", 1700000001L,
  )
  let parsed = rev_parse(fs, "/repo/.git", "v1^{commit}")
  assert_eq(parsed.unwrap().to_hex(), id.to_hex())
}

///|
test "rev-parse: :/message finds commit from HEAD history" {
  let fs = setup_rev_repo()
  fs.write_string("/repo/a.txt", "first\n")
  add_paths(fs, fs, "/repo", ["a.txt"])
  ignore(
    commit(fs, fs, "/repo", "initial\n", "Test <test@example.com>", 1700000000L),
  )
  fs.write_string("/repo/a.txt", "second\n")
  add_paths(fs, fs, "/repo", ["a.txt"])
  let target = commit(
    fs, fs, "/repo", "needle message\n", "Test <test@example.com>", 1700000001L,
  )
  let parsed = rev_parse(fs, "/repo/.git", ":/needle")
  assert_eq(parsed.unwrap().to_hex(), target.to_hex())
}

///|
test "rev-parse: base^{/message} finds reachable commit" {
  let fs = setup_rev_repo()
  fs.write_string("/repo/a.txt", "first\n")
  add_paths(fs, fs, "/repo", ["a.txt"])
  let first = commit(
    fs, fs, "/repo", "first target\n", "Test <test@example.com>", 1700000000L,
  )
  fs.write_string("/repo/a.txt", "second\n")
  add_paths(fs, fs, "/repo", ["a.txt"])
  ignore(
    commit(fs, fs, "/repo", "second\n", "Test <test@example.com>", 1700000001L),
  )
  let parsed = rev_parse(fs, "/repo/.git", "HEAD^{/first target}")
  assert_eq(parsed.unwrap().to_hex(), first.to_hex())
}

///|
async test "status porcelain + diff" {
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

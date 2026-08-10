///| Tests for merge

///|
fn setup_repo_merge() -> @bit.TestFs {
  let fs = @bit.TestFs::new()
  ignore(init_repo(fs, "/repo")) catch {
    _ => ()
  }
  fs
}

///|
test "merge: content-level merge non-overlapping changes" {
  let fs = setup_repo_merge()
  // Create base with multi-line file
  fs.write_string("/repo/file.txt", "line1\nline2\nline3\nline4\nline5\n")
  add_paths(fs, fs, "/repo", ["file.txt"])
  ignore(commit(fs, fs, "/repo", "base", "Test <t@example.com>", 1700000000L))
  // Feature branch: change line2
  switch_branch(fs, fs, "/repo", "feature", create=true, checkout_files=true)
  fs.write_string("/repo/file.txt", "line1\nchanged2\nline3\nline4\nline5\n")
  add_paths(fs, fs, "/repo", ["file.txt"])
  let feature_commit = commit(
    fs, fs, "/repo", "feature", "Test <t@example.com>", 1700000001L,
  )
  // Main branch: change line4
  switch_branch(fs, fs, "/repo", "main", checkout_files=true)
  fs.write_string("/repo/file.txt", "line1\nline2\nline3\nchanged4\nline5\n")
  add_paths(fs, fs, "/repo", ["file.txt"])
  ignore(commit(fs, fs, "/repo", "main", "Test <t@example.com>", 1700000002L))
  // Merge should succeed with content merge
  let result = merge(
    fs, fs, "/repo", feature_commit, "merge", "Test <t@example.com>", 1700000003L,
  )
  match result.status {
    Merged => ()
    _ => {
      println("Expected Merged, got conflicts: \{Repr(result.conflicts)}")
      assert_true(false)
    }
  }
  let content = fs.read_string("/repo/file.txt")
  @test.assert_eq(content, "line1\nchanged2\nline3\nchanged4\nline5\n")
}

///|
test "merge: content-level merge with conflict" {
  let fs = setup_repo_merge()
  fs.write_string("/repo/file.txt", "line1\nline2\nline3\n")
  add_paths(fs, fs, "/repo", ["file.txt"])
  ignore(commit(fs, fs, "/repo", "base", "Test <t@example.com>", 1700000000L))
  // Feature branch: change line2 to X
  switch_branch(fs, fs, "/repo", "feature", create=true, checkout_files=true)
  fs.write_string("/repo/file.txt", "line1\nfeature_change\nline3\n")
  add_paths(fs, fs, "/repo", ["file.txt"])
  let feature_commit = commit(
    fs, fs, "/repo", "feature", "Test <t@example.com>", 1700000001L,
  )
  // Main branch: change line2 to Y
  switch_branch(fs, fs, "/repo", "main", checkout_files=true)
  fs.write_string("/repo/file.txt", "line1\nmain_change\nline3\n")
  add_paths(fs, fs, "/repo", ["file.txt"])
  ignore(commit(fs, fs, "/repo", "main", "Test <t@example.com>", 1700000002L))
  // Merge should produce conflict
  let result = merge(
    fs, fs, "/repo", feature_commit, "merge", "Test <t@example.com>", 1700000003L,
  )
  match result.status {
    Conflicted => ()
    _ => {
      println("Expected Conflicted")
      assert_true(false)
    }
  }
  assert_true(result.conflicts.contains("file.txt"))
  // Conflict markers should be written to worktree
  let content = fs.read_string("/repo/file.txt")
  assert_true(content.contains("<<<<<<< HEAD"))
  assert_true(content.contains(">>>>>>> incoming"))
  let staged = read_index_stage_entries(fs, "/repo/.git")
  @test.assert_eq(staged.length(), 3)
  @test.assert_eq(staged[0].entry.path, "file.txt")
  @test.assert_eq(staged[0].stage, 1)
  @test.assert_eq(staged[1].stage, 2)
  @test.assert_eq(staged[2].stage, 3)
  assert_true(
    fs.read_string("/repo/.git/MERGE_HEAD").contains(feature_commit.to_hex()),
  )
}

///|
test "merge: file-level merge without conflicts" {
  let fs = setup_repo_merge()
  fs.write_string("/repo/a.txt", "base\n")
  add_paths(fs, fs, "/repo", ["a.txt"])
  ignore(commit(fs, fs, "/repo", "base\n", "Test <t@example.com>", 1700000000L))
  switch_branch(fs, fs, "/repo", "feature", create=true, checkout_files=true)
  fs.write_string("/repo/b.txt", "feature\n")
  add_paths(fs, fs, "/repo", ["b.txt"])
  let feature_commit = commit(
    fs, fs, "/repo", "feature\n", "Test <t@example.com>", 1700000001L,
  )
  switch_branch(fs, fs, "/repo", "main", checkout_files=true)
  fs.write_string("/repo/a.txt", "main\n")
  add_paths(fs, fs, "/repo", ["a.txt"])
  let main_commit = commit(
    fs, fs, "/repo", "main\n", "Test <t@example.com>", 1700000002L,
  )
  let result = merge(
    fs, fs, "/repo", feature_commit, "merge\n", "Test <t@example.com>", 1700000003L,
  )
  match result.status {
    Merged => ()
    Conflicted => {
      println("CONFLICT: \{Repr(result.conflicts)}")
      assert_true(false)
    }
    AlreadyUpToDate => {
      println("AlreadyUpToDate merge")
      assert_true(false)
    }
    FastForward => {
      println("FastForward merge")
      assert_true(false)
    }
  }
  let head = fs.read_string("/repo/.git/refs/heads/main")
  match result.commit_id {
    None => assert_true(false)
    Some(id) => assert_true(head.contains(id.to_hex()))
  }
  let content_a = fs.read_string("/repo/a.txt")
  let content_b = fs.read_string("/repo/b.txt")
  assert_true(content_a == "main\n")
  assert_true(content_b == "feature\n")
  let db = ObjectDb::load(fs, "/repo/.git")
  match result.commit_id {
    None => ()
    Some(id) => {
      let obj = db.get(fs, id)
      match obj {
        None => assert_true(false)
        Some(o) => {
          let info = @bit.parse_commit(o.data)
          assert_true(info.parents.length() == 2)
          assert_true(info.parents.contains(main_commit))
          assert_true(info.parents.contains(feature_commit))
        }
      }
    }
  }
}

///|
test "merge: unborn branch fast-forwards to target" {
  let fs = setup_repo_merge()
  fs.write_string("/repo/file.txt", "base\n")
  add_paths(fs, fs, "/repo", ["file.txt"])
  let target = commit(
    fs, fs, "/repo", "base", "Test <t@example.com>", 1700000000L,
  )
  fs.remove_file("/repo/.git/refs/heads/main") catch {
    _ => ()
  }
  fs.remove_file("/repo/.git/index") catch {
    _ => ()
  }
  fs.remove_file("/repo/file.txt") catch {
    _ => ()
  }
  let result = merge(
    fs, fs, "/repo", target, "merge", "Test <t@example.com>", 1700000001L,
  )
  match result.status {
    FastForward => ()
    _ => fail("expected fast-forward merge")
  }
  @test.assert_eq(result.commit_id, Some(target))
  let head_ref = fs.read_string("/repo/.git/refs/heads/main")
  assert_true(head_ref.contains(target.to_hex()))
  @test.assert_eq(fs.read_string("/repo/file.txt"), "base\n")
}

///|
test "merge: fast-forward preserves initialized submodule on removal" {
  let fs = setup_repo_merge()
  fs.write_string("/repo/a.txt", "one\n")
  add_paths(fs, fs, "/repo", ["a.txt"])
  ignore(
    commit(fs, fs, "/repo", "initial", "Test <t@example.com>", 1700000100L),
  )

  init_repo_with_options(fs, "/repo/vendor/sub", {
    default_branch: "main",
    bare: false,
    separate_git_dir: Some("/repo/.git/modules/example"),
    template_dir: None,
    ref_format: "files",
    object_format: "sha1",
    is_reinit: false,
    git_dir: None,
    work_tree: Some("/repo/vendor/sub"),
    shared: None,
  })
  fs.write_string("/repo/vendor/sub/a", "sub\n")
  add_paths(fs, fs, "/repo/vendor/sub", ["a"])
  let submodule_commit = commit(
    fs, fs, "/repo/vendor/sub", "submodule", "Test <t@example.com>", 1700000101L,
  )
  fs.write_string(
    "/repo/.gitmodules", "[submodule \"example\"]\n\tpath = vendor/sub\n\turl = ../example\n",
  )
  add_paths(fs, fs, "/repo", [".gitmodules"])
  let entries = read_index_entries(fs, "/repo/.git")
  entries.push(IndexEntry::new("vendor/sub", submodule_commit, 0o160000, 0))
  write_index_entries(fs, "/repo/.git", entries)
  ignore(
    commit(
      fs, fs, "/repo", "with-submodule", "Test <t@example.com>", 1700000102L,
    ),
  )

  switch_branch(fs, fs, "/repo", "feature", create=true, checkout_files=false)
  let remove_entries = read_index_entries(fs, "/repo/.git")
  let remaining : Array[IndexEntry] = []
  for entry in remove_entries {
    if entry.path != ".gitmodules" && entry.path != "vendor/sub" {
      remaining.push(entry)
    }
  }
  write_index_entries(fs, "/repo/.git", remaining)
  let remove_commit = commit(
    fs, fs, "/repo", "remove-submodule", "Test <t@example.com>", 1700000103L,
  )

  switch_branch(fs, fs, "/repo", "main", checkout_files=false)
  let result = merge(
    fs, fs, "/repo", remove_commit, "merge", "Test <t@example.com>", 1700000104L,
  )

  match result.status {
    FastForward => ()
    _ => fail("expected fast-forward merge")
  }
  assert_true(fs.is_dir("/repo/vendor/sub"))
  assert_true(fs.is_file("/repo/vendor/sub/.git"))
  @test.assert_eq(fs.read_string("/repo/vendor/sub/a"), "sub\n")
}

///|
test "merge: rename on one side, no conflict" {
  // Feature renames a.txt -> b.txt (same content), main doesn't touch a.txt
  // Expected: merge succeeds, file at b.txt
  let fs = setup_repo_merge()
  fs.write_string("/repo/a.txt", "content\n")
  add_paths(fs, fs, "/repo", ["a.txt"])
  ignore(commit(fs, fs, "/repo", "base", "Test <t@example.com>", 1700000000L))
  // Feature branch: rename a.txt -> b.txt
  switch_branch(fs, fs, "/repo", "feature", create=true, checkout_files=true)
  let entries = read_index_entries(fs, "/repo/.git")
  let new_entries : Array[IndexEntry] = []
  let mut a_entry : IndexEntry? = None
  for entry in entries {
    if entry.path == "a.txt" {
      a_entry = Some(entry)
    } else {
      new_entries.push(entry)
    }
  }
  match a_entry {
    Some(e) => new_entries.push(IndexEntry::new("b.txt", e.id, e.mode, 0))
    None => fail("a.txt not found in index")
  }
  write_index_entries(fs, "/repo/.git", new_entries)
  fs.remove_file("/repo/a.txt") catch {
    _ => ()
  }
  fs.write_string("/repo/b.txt", "content\n")
  let feature_commit = commit(
    fs, fs, "/repo", "rename a->b", "Test <t@example.com>", 1700000001L,
  )
  // Main branch: no changes to a.txt (add another file)
  switch_branch(fs, fs, "/repo", "main", checkout_files=true)
  fs.write_string("/repo/c.txt", "other\n")
  add_paths(fs, fs, "/repo", ["c.txt"])
  ignore(commit(fs, fs, "/repo", "add c", "Test <t@example.com>", 1700000002L))
  // Merge
  let result = merge(
    fs, fs, "/repo", feature_commit, "merge rename", "Test <t@example.com>", 1700000003L,
  )
  match result.status {
    Merged => ()
    _ => {
      println("Expected Merged, got conflicts: \{Repr(result.conflicts)}")
      fail("expected merged")
    }
  }
  // b.txt should exist, a.txt should be gone
  @test.assert_eq(fs.read_string("/repo/b.txt"), "content\n")
  @test.assert_eq(fs.read_string("/repo/c.txt"), "other\n")
}

///|
test "merge: rename on one side, modify on other (rename/modify)" {
  // Feature renames a.txt -> b.txt, main modifies a.txt content
  // Expected: merge succeeds with content merge at b.txt
  let fs = setup_repo_merge()
  fs.write_string("/repo/a.txt", "line1\nline2\nline3\n")
  add_paths(fs, fs, "/repo", ["a.txt"])
  ignore(commit(fs, fs, "/repo", "base", "Test <t@example.com>", 1700000000L))
  // Feature branch: rename a.txt -> b.txt (same content)
  switch_branch(fs, fs, "/repo", "feature", create=true, checkout_files=true)
  let entries = read_index_entries(fs, "/repo/.git")
  let new_entries : Array[IndexEntry] = []
  let mut a_id : @bit.ObjectId? = None
  for entry in entries {
    if entry.path == "a.txt" {
      a_id = Some(entry.id)
    } else {
      new_entries.push(entry)
    }
  }
  match a_id {
    Some(id) => new_entries.push(IndexEntry::new("b.txt", id, 0o100644, 0))
    None => fail("a.txt not found")
  }
  write_index_entries(fs, "/repo/.git", new_entries)
  fs.remove_file("/repo/a.txt") catch {
    _ => ()
  }
  fs.write_string("/repo/b.txt", "line1\nline2\nline3\n")
  let feature_commit = commit(
    fs, fs, "/repo", "rename a->b", "Test <t@example.com>", 1700000001L,
  )
  // Main branch: modify a.txt (change line2)
  switch_branch(fs, fs, "/repo", "main", checkout_files=true)
  fs.write_string("/repo/a.txt", "line1\nmodified\nline3\n")
  add_paths(fs, fs, "/repo", ["a.txt"])
  ignore(
    commit(fs, fs, "/repo", "modify a", "Test <t@example.com>", 1700000002L),
  )
  // Merge
  let result = merge(
    fs, fs, "/repo", feature_commit, "merge", "Test <t@example.com>", 1700000003L,
  )
  // Should succeed - rename + modify = content merge at new path
  match result.status {
    Merged => ()
    Conflicted => {
      println("Conflicts: \{Repr(result.conflicts)}")
      fail("expected merged, got conflicted")
    }
    _ => fail("expected merged")
  }
  // File should be at b.txt with modified content
  @test.assert_eq(fs.read_string("/repo/b.txt"), "line1\nmodified\nline3\n")
}

///|
test "merge: rename on both sides to same target" {
  // Both sides rename a.txt -> b.txt
  // Expected: merge succeeds
  let fs = setup_repo_merge()
  fs.write_string("/repo/a.txt", "content\n")
  add_paths(fs, fs, "/repo", ["a.txt"])
  ignore(commit(fs, fs, "/repo", "base", "Test <t@example.com>", 1700000000L))
  // Feature: rename a->b
  switch_branch(fs, fs, "/repo", "feature", create=true, checkout_files=true)
  let entries = read_index_entries(fs, "/repo/.git")
  let new_entries : Array[IndexEntry] = []
  let mut a_entry : IndexEntry? = None
  for entry in entries {
    if entry.path == "a.txt" {
      a_entry = Some(entry)
    } else {
      new_entries.push(entry)
    }
  }
  match a_entry {
    Some(e) => new_entries.push(IndexEntry::new("b.txt", e.id, e.mode, 0))
    None => fail("a.txt not found")
  }
  write_index_entries(fs, "/repo/.git", new_entries)
  fs.remove_file("/repo/a.txt") catch {
    _ => ()
  }
  fs.write_string("/repo/b.txt", "content\n")
  let feature_commit = commit(
    fs, fs, "/repo", "rename a->b", "Test <t@example.com>", 1700000001L,
  )
  // Main: also rename a->b
  switch_branch(fs, fs, "/repo", "main", checkout_files=true)
  let entries2 = read_index_entries(fs, "/repo/.git")
  let new_entries2 : Array[IndexEntry] = []
  let mut a_entry2 : IndexEntry? = None
  for entry in entries2 {
    if entry.path == "a.txt" {
      a_entry2 = Some(entry)
    } else {
      new_entries2.push(entry)
    }
  }
  match a_entry2 {
    Some(e) => new_entries2.push(IndexEntry::new("b.txt", e.id, e.mode, 0))
    None => fail("a.txt not found")
  }
  write_index_entries(fs, "/repo/.git", new_entries2)
  fs.remove_file("/repo/a.txt") catch {
    _ => ()
  }
  fs.write_string("/repo/b.txt", "content\n")
  ignore(
    commit(fs, fs, "/repo", "rename a->b", "Test <t@example.com>", 1700000002L),
  )
  // Merge
  let result = merge(
    fs, fs, "/repo", feature_commit, "merge", "Test <t@example.com>", 1700000003L,
  )
  match result.status {
    Merged => ()
    AlreadyUpToDate => () // Also acceptable since trees are identical
    _ => fail("expected merged or up-to-date")
  }
  @test.assert_eq(fs.read_string("/repo/b.txt"), "content\n")
}

///|
test "merge: rename/add-source - rename a->b with new file at a" {
  // Feature renames a.txt -> b.txt AND creates new a.txt with different content
  // Main modifies a.txt (original content)
  // Expected: b.txt has merged content, a.txt has new content from feature
  let fs = setup_repo_merge()
  fs.write_string("/repo/a.txt", "line1\nline2\nline3\n")
  add_paths(fs, fs, "/repo", ["a.txt"])
  ignore(commit(fs, fs, "/repo", "base", "Test <t@example.com>", 1700000000L))
  // Feature: rename a.txt -> b.txt, create new a.txt
  switch_branch(fs, fs, "/repo", "feature", create=true, checkout_files=true)
  let entries = read_index_entries(fs, "/repo/.git")
  let new_entries : Array[IndexEntry] = []
  let mut a_id : @bit.ObjectId? = None
  for entry in entries {
    if entry.path == "a.txt" {
      a_id = Some(entry.id)
    } else {
      new_entries.push(entry)
    }
  }
  // b.txt gets the original content (same OID as base a.txt)
  match a_id {
    Some(id) => new_entries.push(IndexEntry::new("b.txt", id, 0o100644, 0))
    None => fail("a.txt not found")
  }
  // New a.txt with completely different content
  fs.write_string("/repo/a.txt", "something completely different\n")
  fs.write_string("/repo/b.txt", "line1\nline2\nline3\n")
  add_paths(fs, fs, "/repo", ["a.txt"])
  // Re-read to get new a.txt's OID
  let updated = read_index_entries(fs, "/repo/.git")
  for entry in updated {
    if entry.path == "a.txt" {
      new_entries.push(entry)
    }
  }
  write_index_entries(fs, "/repo/.git", new_entries)
  let feature_commit = commit(
    fs, fs, "/repo", "rename+add-source", "Test <t@example.com>", 1700000001L,
  )
  // Main: don't touch a.txt
  switch_branch(fs, fs, "/repo", "main", checkout_files=true)
  fs.write_string("/repo/c.txt", "other\n")
  add_paths(fs, fs, "/repo", ["c.txt"])
  ignore(commit(fs, fs, "/repo", "add c", "Test <t@example.com>", 1700000002L))
  // Merge
  let result = merge(
    fs, fs, "/repo", feature_commit, "merge", "Test <t@example.com>", 1700000003L,
  )
  match result.status {
    Merged => ()
    _ => {
      println("Expected Merged, got conflicts: \{Repr(result.conflicts)}")
      fail("expected merged")
    }
  }
  // b.txt should have original content, a.txt should have new content
  @test.assert_eq(fs.read_string("/repo/b.txt"), "line1\nline2\nline3\n")
  @test.assert_eq(
    fs.read_string("/repo/a.txt"),
    "something completely different\n",
  )
  @test.assert_eq(fs.read_string("/repo/c.txt"), "other\n")
}

///| Tests for pack collection functions including diff collection

///|
test "collect_diff_objects: collects only new objects" {
  let fs = @bit.TestFs::new()
  init_repo(fs, "/repo") catch {
    _ => ()
  }
  // Create initial content
  fs.mkdir_p("/repo/src")
  fs.write_file("/repo/src/foo.mbt", b"original foo")
  fs.write_file("/repo/README.md", b"readme")
  let commit1 = commit(
    fs, fs, "/repo", "Initial", "test <test@test.com>", 1000L,
  ) catch {
    _ => return ()
  }
  // Modify one file and add another
  fs.write_file("/repo/src/foo.mbt", b"modified foo")
  fs.write_file("/repo/src/bar.mbt", b"new bar")
  let commit2 = commit(fs, fs, "/repo", "Update", "test <test@test.com>", 2000L) catch {
    _ => return ()
  }
  // Collect diff objects
  let db = ObjectDb::load(fs, "/repo/.git") catch { _ => return () }
  let diff_objects = collect_diff_objects(db, fs, commit1, commit2) catch {
    _ => return ()
  }
  // Should have: commit2, new root tree, new src tree, modified foo blob, new bar blob
  // Should NOT have: README.md blob, original foo blob
  assert_true(diff_objects.length() > 0)
  // Verify the new commit is included
  let mut has_new_commit = false
  for obj in diff_objects {
    if obj.obj_type == @bit.ObjectType::Commit {
      let info = @bit.parse_commit(obj.data) catch { _ => continue }
      if info.parents.length() > 0 && info.parents[0] == commit1 {
        has_new_commit = true
      }
    }
  }
  assert_true(has_new_commit)
}

///|
test "collect_diff_objects: empty diff when no changes" {
  let fs = @bit.TestFs::new()
  init_repo(fs, "/repo") catch {
    _ => ()
  }
  fs.write_file("/repo/file.txt", b"content")
  let commit1 = commit(
    fs, fs, "/repo", "Initial", "test <test@test.com>", 1000L,
  ) catch {
    _ => return ()
  }
  // Collect diff with same commit as base and new
  let db = ObjectDb::load(fs, "/repo/.git") catch { _ => return () }
  let diff_objects = collect_diff_objects(db, fs, commit1, commit1) catch {
    _ => return ()
  }
  // Should be empty - same commit
  assert_eq(diff_objects.length(), 0)
}

///|
test "collect_diff_objects: preserves unchanged nested trees" {
  let fs = @bit.TestFs::new()
  init_repo(fs, "/repo") catch {
    _ => ()
  }
  // Create nested structure
  fs.mkdir_p("/repo/a/b/c")
  fs.write_file("/repo/a/b/c/deep.mbt", b"deep content")
  fs.write_file("/repo/a/sibling.mbt", b"sibling")
  fs.write_file("/repo/root.mbt", b"root")
  let commit1 = commit(
    fs, fs, "/repo", "Initial", "test <test@test.com>", 1000L,
  ) catch {
    _ => return ()
  }
  // Only modify root file
  fs.write_file("/repo/root.mbt", b"root modified")
  let commit2 = commit(fs, fs, "/repo", "Update", "test <test@test.com>", 2000L) catch {
    _ => return ()
  }
  let db = ObjectDb::load(fs, "/repo/.git") catch { _ => return () }
  let diff_objects = collect_diff_objects(db, fs, commit1, commit2) catch {
    _ => return ()
  }
  // Should NOT include the nested unchanged trees/blobs
  let mut deep_blob_count = 0
  for obj in diff_objects {
    if obj.obj_type == @bit.ObjectType::Blob {
      // Check if it's the deep.mbt blob
      let content = @utf8.decode_lossy(obj.data[:])
      if content.contains("deep content") {
        deep_blob_count += 1
      }
    }
  }
  assert_eq(deep_blob_count, 0)
}

///|
test "collect_commit_tree_only: includes all tree objects" {
  let fs = @bit.TestFs::new()
  init_repo(fs, "/repo") catch {
    _ => ()
  }
  fs.mkdir_p("/repo/src/lib")
  fs.write_file("/repo/src/lib/foo.mbt", b"content")
  fs.write_file("/repo/README.md", b"readme")
  let commit1 = commit(
    fs, fs, "/repo", "Initial", "test <test@test.com>", 1000L,
  ) catch {
    _ => return ()
  }
  let db = ObjectDb::load(fs, "/repo/.git") catch { _ => return () }
  let objects = collect_commit_tree_only(db, fs, commit1) catch {
    _ => return ()
  }
  // Should include: commit, root tree, src tree, lib tree, 2 blobs
  let mut commit_count = 0
  let mut tree_count = 0
  let mut blob_count = 0
  for obj in objects {
    match obj.obj_type {
      @bit.ObjectType::Commit => commit_count += 1
      @bit.ObjectType::Tree => tree_count += 1
      @bit.ObjectType::Blob => blob_count += 1
      _ => ()
    }
  }
  assert_eq(commit_count, 1)
  assert_true(tree_count >= 3) // root, src, lib
  assert_eq(blob_count, 2)
}

///|
test "collect_commit_tree_only: does not walk parent commits" {
  let fs = @bit.TestFs::new()
  init_repo(fs, "/repo") catch {
    _ => ()
  }
  fs.write_file("/repo/v1.txt", b"version 1")
  let _ = commit(fs, fs, "/repo", "v1", "test <test@test.com>", 1000L) catch {
    _ => return ()
  }
  fs.write_file("/repo/v2.txt", b"version 2")
  let tip = commit(fs, fs, "/repo", "v2", "test <test@test.com>", 2000L) catch {
    _ => return ()
  }
  let db = ObjectDb::load(fs, "/repo/.git") catch { _ => return () }
  let objects = collect_commit_tree_only(db, fs, tip) catch { _ => return () }
  // Should only have 1 commit (commit2), not 2
  let mut commit_count = 0
  for obj in objects {
    if obj.obj_type == @bit.ObjectType::Commit {
      commit_count += 1
    }
  }
  assert_eq(commit_count, 1)
}

///|
test "collect_reachable_objects: walks parent commits" {
  let fs = @bit.TestFs::new()
  init_repo(fs, "/repo") catch {
    _ => ()
  }
  fs.write_file("/repo/v1.txt", b"version 1")
  let _ = commit(fs, fs, "/repo", "v1", "test <test@test.com>", 1000L) catch {
    _ => return ()
  }
  fs.write_file("/repo/v2.txt", b"version 2")
  let commit2 = commit(fs, fs, "/repo", "v2", "test <test@test.com>", 2000L) catch {
    _ => return ()
  }
  let db = ObjectDb::load(fs, "/repo/.git") catch { _ => return () }
  let objects = collect_reachable_objects(db, fs, commit2) catch {
    _ => return ()
  }
  // Should have 2 commits
  let mut commit_count = 0
  for obj in objects {
    if obj.obj_type == @bit.ObjectType::Commit {
      commit_count += 1
    }
  }
  assert_eq(commit_count, 2)
}

///|
test "collect_diff_objects: handles subdirectory changes" {
  let fs = @bit.TestFs::new()
  init_repo(fs, "/repo") catch {
    _ => ()
  }
  // Create structure similar to subdir-clone scenario
  fs.mkdir_p("/repo/src/x/fs")
  fs.mkdir_p("/repo/src/x/kv")
  fs.write_file("/repo/src/x/fs/fs.mbt", b"fs content")
  fs.write_file("/repo/src/x/kv/kv.mbt", b"kv content")
  fs.write_file("/repo/README.md", b"readme")
  let commit1 = commit(
    fs, fs, "/repo", "Initial", "test <test@test.com>", 1000L,
  ) catch {
    _ => return ()
  }
  // Only modify fs subdirectory
  fs.write_file("/repo/src/x/fs/fs.mbt", b"fs modified")
  fs.write_file("/repo/src/x/fs/new.mbt", b"new file")
  let commit2 = commit(
    fs, fs, "/repo", "Update fs", "test <test@test.com>", 2000L,
  ) catch {
    _ => return ()
  }
  let db = ObjectDb::load(fs, "/repo/.git") catch { _ => return () }
  let diff_objects = collect_diff_objects(db, fs, commit1, commit2) catch {
    _ => return ()
  }
  // Should include: new commit, changed trees (root, src, x, fs), changed/new blobs
  // Should NOT include: kv tree, kv.mbt blob, README.md blob
  let mut kv_content_found = false
  let mut readme_found = false
  for obj in diff_objects {
    if obj.obj_type == @bit.ObjectType::Blob {
      let content = @utf8.decode_lossy(obj.data[:])
      if content.contains("kv content") {
        kv_content_found = true
      }
      if content.contains("readme") {
        readme_found = true
      }
    }
  }
  assert_false(kv_content_found)
  assert_false(readme_found)
}

///|
test "collect_diff_objects: handles file deletion" {
  let fs = @bit.TestFs::new()
  init_repo(fs, "/repo") catch {
    _ => ()
  }
  fs.write_file("/repo/keep.txt", b"keep")
  fs.write_file("/repo/delete.txt", b"to delete")
  let commit1 = commit(
    fs, fs, "/repo", "Initial", "test <test@test.com>", 1000L,
  ) catch {
    _ => return ()
  }
  // Delete a file
  fs.remove_file("/repo/delete.txt")
  let commit2 = commit(fs, fs, "/repo", "Delete", "test <test@test.com>", 2000L) catch {
    _ => return ()
  }
  let db = ObjectDb::load(fs, "/repo/.git") catch { _ => return () }
  let diff_objects = collect_diff_objects(db, fs, commit1, commit2) catch {
    _ => return ()
  }
  // Should include the new commit and the new root tree
  // Should NOT include the deleted blob or the unchanged keep.txt blob
  let mut keep_found = false
  let mut delete_found = false
  for obj in diff_objects {
    if obj.obj_type == @bit.ObjectType::Blob {
      let content = @utf8.decode_lossy(obj.data[:])
      if content.contains("keep") {
        keep_found = true
      }
      if content.contains("to delete") {
        delete_found = true
      }
    }
  }
  assert_false(keep_found)
  assert_false(delete_found)
}

///|
test "collect_diff_objects: handles new directory" {
  let fs = @bit.TestFs::new()
  init_repo(fs, "/repo") catch {
    _ => ()
  }
  fs.write_file("/repo/root.txt", b"root")
  let commit1 = commit(
    fs, fs, "/repo", "Initial", "test <test@test.com>", 1000L,
  ) catch {
    _ => return ()
  }
  // Add new directory
  fs.mkdir_p("/repo/newdir")
  fs.write_file("/repo/newdir/file.txt", b"new dir file")
  let commit2 = commit(
    fs, fs, "/repo", "Add dir", "test <test@test.com>", 2000L,
  ) catch {
    _ => return ()
  }
  let db = ObjectDb::load(fs, "/repo/.git") catch { _ => return () }
  let diff_objects = collect_diff_objects(db, fs, commit1, commit2) catch {
    _ => return ()
  }
  // Should include the new dir tree and its blob
  let mut new_dir_file_found = false
  for obj in diff_objects {
    if obj.obj_type == @bit.ObjectType::Blob {
      let content = @utf8.decode_lossy(obj.data[:])
      if content.contains("new dir file") {
        new_dir_file_found = true
      }
    }
  }
  assert_true(new_dir_file_found)
}

///|
test "collect_reachable_objects_from_commits: deduplicates" {
  let fs = @bit.TestFs::new()
  init_repo(fs, "/repo") catch {
    _ => ()
  }
  fs.write_file("/repo/shared.txt", b"shared")
  let commit1 = commit(fs, fs, "/repo", "v1", "test <test@test.com>", 1000L) catch {
    _ => return ()
  }
  fs.write_file("/repo/v2.txt", b"v2 only")
  let commit2 = commit(fs, fs, "/repo", "v2", "test <test@test.com>", 2000L) catch {
    _ => return ()
  }
  let db = ObjectDb::load(fs, "/repo/.git") catch { _ => return () }
  // Collect from both commits
  let objects = collect_reachable_objects_from_commits(db, fs, [
    commit1, commit2,
  ]) catch {
    _ => return ()
  }
  // Shared blob should only appear once
  let mut shared_count = 0
  for obj in objects {
    if obj.obj_type == @bit.ObjectType::Blob {
      let content = @utf8.decode_lossy(obj.data[:])
      if content.contains("shared") {
        shared_count += 1
      }
    }
  }
  assert_eq(shared_count, 1)
}

///|
test "collect_reachable_objects_excluding_commits: stops at have commits" {
  let fs = @bit.TestFs::new()
  init_repo(fs, "/repo") catch {
    _ => ()
  }
  fs.write_file("/repo/shared.txt", b"shared")
  fs.mkdir_p("/repo/nested")
  fs.write_file("/repo/nested/shared.txt", b"nested shared")
  add_paths(fs, fs, "/repo", ["."])
  let base = commit(fs, fs, "/repo", "base", "test <test@test.com>", 1000L)
  fs.write_file("/repo/new.txt", b"new")
  add_paths(fs, fs, "/repo", ["new.txt"])
  let tip = commit(fs, fs, "/repo", "tip", "test <test@test.com>", 2000L)
  let db = ObjectDb::load(fs, "/repo/.git")

  let objects = collect_reachable_objects_excluding_commits(db, fs, [tip], [
    base,
  ])
  let ids : Map[String, Bool] = Map([])
  let mut shared_blob_count = 0
  let mut nested_shared_blob_count = 0
  let mut new_blob_count = 0
  for obj in objects {
    ids[obj.id.to_hex()] = true
    if obj.obj_type == @bit.ObjectType::Blob {
      let content = @utf8.decode_lossy(obj.data[:])
      if content == "shared" {
        shared_blob_count += 1
      }
      if content == "nested shared" {
        nested_shared_blob_count += 1
      }
      if content == "new" {
        new_blob_count += 1
      }
    }
  }
  assert_true(ids.contains(tip.to_hex()))
  assert_true(!ids.contains(base.to_hex()))
  // Objects reachable from a remote "have" must not be sent again, even
  // when the wanted commit's tree still references them.
  assert_eq(shared_blob_count, 0)
  assert_eq(nested_shared_blob_count, 0)
  assert_eq(new_blob_count, 1)
}

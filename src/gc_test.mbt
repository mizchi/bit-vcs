///| Tests for gc/repack

///|
fn build_simple_repo(
  fs : TestFs,
  root : String,
) -> (ObjectId, ObjectId, ObjectId) raise GitError {
  init_repo(fs, root)
  let git_dir = root + "/.git"
  let (blob_id, blob_bytes) = create_blob_string("hello\n")
  write_object_bytes(fs, git_dir, blob_id, blob_bytes)
  let entry = TreeEntry::new("100644", "hello.txt", blob_id)
  let (tree_id, tree_bytes) = create_tree([entry])
  write_object_bytes(fs, git_dir, tree_id, tree_bytes)
  let commit = Commit::new(
    tree_id,
    [],
    "Test <test@example.com>",
    0L,
    "+0000",
    "Test <test@example.com>",
    0L,
    "+0000",
    "test commit\n",
  )
  let (commit_id, commit_bytes) = create_commit(commit)
  write_object_bytes(fs, git_dir, commit_id, commit_bytes)
  update_head_ref(fs, fs, git_dir, commit_id)
  (commit_id, tree_id, blob_id)
}

///|
test "repack_repo writes pack with reachable objects" {
  let fs = TestFs::new()
  let root = "/repo"
  let git_dir = root + "/.git"
  let _ = build_simple_repo(fs, root)
  let (orphan_id, orphan_bytes) = create_blob_string("orphan\n")
  write_object_bytes(fs, git_dir, orphan_id, orphan_bytes)
  let result = repack_repo(fs, fs, root)
  match result {
    None => fail("expected pack")
    Some(r) => {
      assert_true(r.object_count == 3)
      let pack_path = git_dir +
        "/objects/pack/pack-" +
        r.pack_id.to_hex() +
        ".pack"
      assert_true(fs.is_file(pack_path))
      let pack = fs.read_file(pack_path)
      let objects = parse_packfile(pack)
      assert_true(objects.length() == 3)
    }
  }
}

///|
test "gc_repo reports unreachable objects" {
  let fs = TestFs::new()
  let root = "/repo"
  let git_dir = root + "/.git"
  let _ = build_simple_repo(fs, root)
  let (orphan_id, orphan_bytes) = create_blob_string("orphan\n")
  write_object_bytes(fs, git_dir, orphan_id, orphan_bytes)
  let result = gc_repo(fs, fs, root)
  assert_true(result.dangling.length() == 1)
  assert_true(result.dangling[0].to_hex() == orphan_id.to_hex())
  let hex = orphan_id.to_hex()
  let orphan_path = git_dir +
    "/objects/" +
    String::unsafe_substring(hex, start=0, end=2) +
    "/" +
    String::unsafe_substring(hex, start=2, end=hex.length())
  assert_true(not(fs.is_file(orphan_path)))
  match result.pack {
    None => fail("expected pack")
    Some(r) => assert_true(r.object_count == 3)
  }
}

///|
test "gc_repo keeps tag and remote refs" {
  let fs = TestFs::new()
  let root = "/repo"
  let git_dir = root + "/.git"
  let (_, tree_id, _) = build_simple_repo(fs, root)
  let tag_commit = Commit::new(
    tree_id,
    [],
    "Tagger <tag@example.com>",
    1L,
    "+0000",
    "Tagger <tag@example.com>",
    1L,
    "+0000",
    "tagged commit\n",
  )
  let (tag_commit_id, tag_commit_bytes) = create_commit(tag_commit)
  write_object_bytes(fs, git_dir, tag_commit_id, tag_commit_bytes)
  fs.mkdir_p(git_dir + "/refs/tags")
  fs.write_string(git_dir + "/refs/tags/v1", tag_commit_id.to_hex() + "\n")
  fs.mkdir_p(git_dir + "/refs/remotes/origin")
  fs.write_string(
    git_dir + "/refs/remotes/origin/main",
    tag_commit_id.to_hex() + "\n",
  )
  let result = gc_repo(fs, fs, root)
  for id in result.dangling {
    assert_true(id.to_hex() != tag_commit_id.to_hex())
  }
}

///|
test "gc_repo skips prune when no refs" {
  let fs = TestFs::new()
  let root = "/repo"
  let git_dir = root + "/.git"
  let _ = build_simple_repo(fs, root)
  fs.remove_file(git_dir + "/refs/heads/main")
  let (orphan_id, orphan_bytes) = create_blob_string("orphan\n")
  write_object_bytes(fs, git_dir, orphan_id, orphan_bytes)
  let result = gc_repo(fs, fs, root)
  match result.pack {
    None => ()
    Some(_) => fail("expected no pack")
  }
  let hex = orphan_id.to_hex()
  let orphan_path = git_dir +
    "/objects/" +
    String::unsafe_substring(hex, start=0, end=2) +
    "/" +
    String::unsafe_substring(hex, start=2, end=hex.length())
  assert_true(fs.is_file(orphan_path))
}

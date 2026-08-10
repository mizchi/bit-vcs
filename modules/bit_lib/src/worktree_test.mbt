///| Tests for worktree status/add/commit

///|
fn setup_repo() -> @bit.TestFs {
  let fs = @bit.TestFs::new()
  ignore(init_repo(fs, "/repo")) catch {
    _ => ()
  }
  fs
}

///|
fn setup_sha256_compat_repo() -> @bit.TestFs {
  let fs = @bit.TestFs::new()
  ignore(
    init_repo_with_options(fs, "/repo", {
      default_branch: "main",
      bare: false,
      separate_git_dir: None,
      template_dir: None,
      ref_format: "files",
      object_format: "sha256",
      is_reinit: false,
      git_dir: None,
      work_tree: None,
      shared: None,
    }),
  ) catch {
    _ => ()
  }
  fs.write_string(
    "/repo/.git/config", "[core]\n\trepositoryformatversion = 1\n\tfilemode = true\n\tbare = false\n\tlogallrefupdates = true\n[extensions]\n\tobjectFormat = sha256\n\tcompatObjectFormat = sha1\n",
  )
  fs
}

///|
fn worktree_test_object_path(git_dir : String, id : @bit.ObjectId) -> String {
  let hex = id.to_hex()
  git_dir +
  "/objects/" +
  String::unsafe_substring(hex, start=0, end=2) +
  "/" +
  String::unsafe_substring(hex, start=2, end=hex.length())
}

///|
fn worktree_test_bytes_contains_ascii(bytes : Bytes, text : String) -> Bool {
  let needle = @utf8.encode(text)
  if needle.length() == 0 {
    return true
  }
  if bytes.length() < needle.length() {
    return false
  }
  for start in 0..<=(bytes.length() - needle.length()) {
    let mut matched = true
    for i in 0..<needle.length() {
      if bytes[start + i] != needle[i] {
        matched = false
        break
      }
    }
    if matched {
      return true
    }
  }
  false
}

///|
async test "worktree: status/add/commit" {
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
async test "worktree: linked commit stores shared objects and updates common branch" {
  let fs = setup_repo()
  fs.write_string("/repo/a.txt", "base\n")
  add_paths(fs, fs, "/repo", ["a.txt"])
  let base = commit(
    fs, fs, "/repo", "base\n", "Test <test@example.com>", 1700000000L,
  )
  create_worktree(
    fs,
    fs,
    "/repo",
    "/worker",
    Some(base.to_hex()),
    new_branch=Some("feature"),
  )

  fs.write_string("/worker/a.txt", "base\nworker\n")
  add_paths(fs, fs, "/worker", ["a.txt"])
  let worker_commit = commit(
    fs, fs, "/worker", "worker\n", "Test <test@example.com>", 1700000001L,
  )

  assert_true(
    ObjectDb::load(fs, "/repo/.git").get(fs, worker_commit) is Some(_),
  )
  assert_false(fs.is_dir("/repo/.git/worktrees/worker/objects"))
  @test.assert_eq(
    fs.read_string("/repo/.git/refs/heads/feature"),
    worker_commit.to_hex() + "\n",
  )
  let linked_status = status(fs, "/worker")
  @test.assert_eq(linked_status.staged_added.length(), 0)
  @test.assert_eq(linked_status.staged_modified.length(), 0)
  @test.assert_eq(linked_status.unstaged_modified.length(), 0)
  let worktrees = list_worktrees(fs, "/repo")
  @test.assert_eq(worktrees.length(), 2)
  @test.assert_eq(worktrees[1].head_id, Some(worker_commit))
}

///|
test "worktree: cherry-pick into linked worktree uses shared objects and refs" {
  let fs = setup_repo()
  fs.write_string("/repo/a.txt", "base\n")
  add_paths(fs, fs, "/repo", ["a.txt"])
  let base = commit(
    fs, fs, "/repo", "base\n", "Test <test@example.com>", 1700000000L,
  )
  fs.write_string("/repo/a.txt", "base\nsource\n")
  add_paths(fs, fs, "/repo", ["a.txt"])
  let source = commit(
    fs, fs, "/repo", "source\n", "Test <test@example.com>", 1700000001L,
  )
  create_worktree(
    fs,
    fs,
    "/repo",
    "/worker",
    Some(base.to_hex()),
    new_branch=Some("feature"),
  )

  let result = cherry_pick(
    fs, fs, "/worker", source, "Test <test@example.com>", 1700000002L,
  )
  guard result.commit_id is Some(picked) else {
    fail("expected linked worktree cherry-pick to create a commit")
  }
  assert_true(ObjectDb::load(fs, "/repo/.git").get(fs, picked) is Some(_))
  @test.assert_eq(
    fs.read_string("/repo/.git/refs/heads/feature"),
    picked.to_hex() + "\n",
  )
  @test.assert_eq(fs.read_string("/worker/a.txt"), "base\nsource\n")
}

///|
async test "worktree: add_paths writes cache-tree extension" {
  let fs = setup_repo()
  fs.write_string("/repo/one", "frotz\n")
  fs.mkdir_p("/repo/two")
  fs.write_string("/repo/two/three", "frotz\n")
  add_paths(fs, fs, "/repo", ["one", "two/three"])
  let after_add = worktree_test_bytes_contains_ascii(
    fs.read_file("/repo/.git/index"),
    "TREE",
  )
  let entries = read_index_entries(fs, "/repo/.git")
  write_index_entries_preserving_cache_tree(fs, fs, "/repo/.git", entries)
  let after_rewrite = worktree_test_bytes_contains_ascii(
    fs.read_file("/repo/.git/index"),
    "TREE",
  )
  assert_true(after_add || after_rewrite)
}

///|
async test "worktree: status skips a matching HEAD cache-tree root" {
  let fs = setup_repo()
  fs.write_string("/repo/tracked.txt", "tracked\n")
  add_paths(fs, fs, "/repo", ["tracked.txt"])
  let commit_id = commit(
    fs, fs, "/repo", "initial\n", "Test <test@example.com>", 1700000000L,
  )
  let db = ObjectDb::load(fs, "/repo/.git")
  let commit_obj = db.get(fs, commit_id).unwrap()
  let tree_id = @bit.parse_commit(commit_obj.data).tree

  // A clean index has the same root OID in its TREE extension as HEAD. If
  // status consults it first, it need not load this tree object at all.
  fs.remove_file(worktree_test_object_path("/repo/.git", tree_id))

  let st = status(fs, "/repo")
  assert_true(st.staged_added.length() == 0)
  assert_true(st.staged_modified.length() == 0)
  assert_true(st.staged_deleted.length() == 0)
}

///|
async test "worktree: status skips unchanged cache-tree subtrees" {
  let fs = setup_repo()
  fs.mkdir_p("/repo/clean")
  fs.mkdir_p("/repo/changed")
  fs.write_string("/repo/clean/file.txt", "clean\n")
  fs.write_string("/repo/changed/file.txt", "before\n")
  add_paths(fs, fs, "/repo", ["clean/file.txt", "changed/file.txt"])
  let commit_id = commit(
    fs, fs, "/repo", "initial\n", "Test <test@example.com>", 1700000000L,
  )
  let db = ObjectDb::load(fs, "/repo/.git")
  let commit_obj = db.get(fs, commit_id).unwrap()
  let root_tree = db.get(fs, @bit.parse_commit(commit_obj.data).tree).unwrap()
  let mut clean_tree_id = None
  for entry in @bit.parse_tree(root_tree.data) {
    if entry.name == "clean" {
      clean_tree_id = Some(entry.id)
    }
  }
  guard clean_tree_id is Some(clean_tree_id) else {
    fail("expected clean subtree in HEAD")
  }

  // Updating the sibling invalidates the root and only that sibling in the
  // index TREE extension. The clean subtree remains reusable.
  fs.write_string("/repo/changed/file.txt", "after\n")
  add_paths(fs, fs, "/repo", ["changed/file.txt"])
  fs.remove_file(worktree_test_object_path("/repo/.git", clean_tree_id))

  let st = status(fs, "/repo")
  assert_true(st.staged_modified.contains("changed/file.txt"))
  assert_true(st.staged_added.length() == 0)
  assert_true(st.staged_deleted.length() == 0)
}

///|
async test "worktree: commit writes HEAD and branch reflogs" {
  let fs = setup_repo()
  fs.write_string("/repo/a.txt", "hello\n")
  add_paths(fs, fs, "/repo", ["a.txt"])
  ignore(
    commit(
      fs, fs, "/repo", "msg\nbody\n", "Test <test@example.com>", 1700000000L,
    ),
  )
  let head_log = read_reflog(fs, "/repo/.git", "HEAD")
  let branch_log = read_reflog(fs, "/repo/.git", "refs/heads/main")
  @test.assert_eq(head_log.length(), 1)
  @test.assert_eq(branch_log.length(), 1)
  @test.assert_eq(head_log[0].message, "commit (initial): msg")
  @test.assert_eq(branch_log[0].message, "commit (initial): msg")
}

///|
async test "worktree: sha256 compat repo records loose-object-idx mappings" {
  let fs = setup_sha256_compat_repo()
  let git_dir = "/repo/.git"
  let content = @utf8.encode("Hello World!\n")
  fs.write_string("/repo/hello", "Hello World!\n")
  add_paths(fs, fs, "/repo", ["hello"])
  let commit_id = commit(
    fs,
    fs,
    "/repo",
    "Initial commit\n",
    "A U Thor <author@example.com>",
    1112354055L,
    committer="C O Mitter <committer@example.com>",
    committer_timestamp=1112354055L,
    timezone="+0200",
  )
  let blob_storage = @object.hash_object_content_with_algo(
    @object.HashAlgorithm::Sha256,
    @bit.ObjectType::Blob,
    content,
  )
  let blob_compat = @object.hash_object_content_with_algo(
    @object.HashAlgorithm::Sha1,
    @bit.ObjectType::Blob,
    content,
  )
  let (expected_tree_compat, _) = @object.create_tree_with_algo(
    @object.HashAlgorithm::Sha1,
    [@bit.TreeEntry::new("100644", "hello", blob_compat)],
  )
  assert_true(fs.is_file(worktree_test_object_path(git_dir, blob_storage)))
  @test.assert_eq(
    compat_lookup_loose_object_idx(fs, git_dir, blob_storage.to_hex()),
    Some(blob_compat.to_hex()),
  )
  let commit_obj = ObjectDb::load(fs, git_dir).get(fs, commit_id).unwrap()
  let tree_id = @bit.parse_commit(commit_obj.data).tree
  let tree_obj = ObjectDb::load(fs, git_dir).get(fs, tree_id).unwrap()
  let tree_entries = @bit.parse_tree(tree_obj.data)
  @test.assert_eq(tree_entries.length(), 1)
  @test.assert_eq(tree_entries[0].name, "hello")
  @test.assert_eq(tree_entries[0].mode, "100644")
  @test.assert_eq(tree_entries[0].id.to_hex(), blob_storage.to_hex())
  let tree_compat = compat_lookup_loose_object_idx(
    fs,
    git_dir,
    tree_id.to_hex(),
  )
  let commit_compat = compat_lookup_loose_object_idx(
    fs,
    git_dir,
    commit_id.to_hex(),
  )
  assert_true(tree_compat is Some(_))
  assert_true(commit_compat is Some(_))
  @test.assert_eq(tree_compat.unwrap(), expected_tree_compat.to_hex())
  let (expected_commit_compat, _) = @object.create_commit_with_algo(
    @object.HashAlgorithm::Sha1,
    @bit.Commit::new(
      expected_tree_compat,
      [],
      "A U Thor <author@example.com>",
      1112354055L,
      "+0200",
      "C O Mitter <committer@example.com>",
      1112354055L,
      "+0200",
      "Initial commit\n",
    ),
  )
  @test.assert_eq(commit_compat.unwrap(), expected_commit_compat.to_hex())
}

///|
async test "worktree: modified after commit" {
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
async test "worktree: staged modified after add" {
  let fs = setup_repo()
  fs.write_string("/repo/a.txt", "hello\n")
  add_paths(fs, fs, "/repo", ["a.txt"])
  ignore(
    commit(fs, fs, "/repo", "msg\n", "Test <test@example.com>", 1700000000L),
  )
  fs.write_string("/repo/a.txt", "changed\n")
  add_paths(fs, fs, "/repo", ["a.txt"])
  let st = status(fs, "/repo")
  assert_true(st.staged_modified.contains("a.txt"))
  assert_true(st.unstaged_modified.length() == 0)
}

///|
async test "worktree: staged deleted after remove and add" {
  let fs = setup_repo()
  fs.write_string("/repo/a.txt", "hello\n")
  add_paths(fs, fs, "/repo", ["a.txt"])
  ignore(
    commit(fs, fs, "/repo", "msg\n", "Test <test@example.com>", 1700000000L),
  )
  fs.remove_file("/repo/a.txt")
  add_paths(fs, fs, "/repo", ["a.txt"])
  let st = status(fs, "/repo")
  assert_true(st.staged_deleted.contains("a.txt"))
  assert_true(st.unstaged_deleted.length() == 0)
}

///|
async test "worktree: status text" {
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

///|
async test "worktree: status text tolerates sha256 ref" {
  let fs = setup_repo()
  fs.write_string(
    "/repo/.git/refs/heads/main", "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\n",
  )
  let text = status_text(fs, "/repo")
  assert_true(text.contains("On branch main"))
}

///|
async test "worktree: empty commit requires allow_empty" {
  let fs = setup_repo()
  let _ = commit(
    fs, fs, "/repo", "msg\n", "Test <test@example.com>", 1700000000L,
  ) catch {
    _ => return ()
  }
  fail("expected empty-index commit to fail without allow_empty")
}

///|
async test "worktree: allow_empty creates initial commit" {
  let fs = setup_repo()
  let allow_empty = true
  let commit_id = commit(
    fs,
    fs,
    "/repo",
    "empty\n",
    "Test <test@example.com>",
    1700000000L,
    allow_empty~,
  )
  let ref_text = fs.read_string("/repo/.git/refs/heads/main")
  assert_true(ref_text.contains(commit_id.to_hex()))
}

///|
async test "worktree: amend preserves gitlink entries without local object" {
  let fs = setup_repo()
  fs.write_string("/repo/a.txt", "hello\n")
  add_paths(fs, fs, "/repo", ["a.txt"])
  ignore(
    commit(fs, fs, "/repo", "base\n", "Test <test@example.com>", 1700000000L),
  )
  let entries = read_index_entries(fs, "/repo/.git")
  entries.push(
    IndexEntry::new(
      "submodule",
      @bit.ObjectId::from_hex("e598ccc29ff366687aa04587483454a7925521ae"),
      0o160000,
      0,
    ),
  )
  write_index_entries(fs, "/repo/.git", entries)
  let amended = commit_amend(
    fs, fs, "/repo", "amended\n", "Test <test@example.com>", 1700000001L,
  )
  let db = ObjectDb::load_lazy(fs, "/repo/.git")
  let commit_obj = db.get(fs, amended).unwrap()
  let commit_info = @bit.parse_commit(commit_obj.data)
  let tree_obj = db.get(fs, commit_info.tree).unwrap()
  let tree_entries = @bit.parse_tree(tree_obj.data)
  @test.assert_eq(tree_entries.length(), 2)
  @test.assert_eq(tree_entries[1].mode, "160000")
  @test.assert_eq(tree_entries[1].name, "submodule")
  @test.assert_eq(
    tree_entries[1].id.to_hex(),
    "e598ccc29ff366687aa04587483454a7925521ae",
  )
}

///|
async test "worktree: mv_path moves gitlink directory" {
  let fs = setup_repo()
  let gitlink_id = @bit.ObjectId::from_hex(
    "e598ccc29ff366687aa04587483454a7925521ae",
  )
  write_index_entries(fs, "/repo/.git", [
    IndexEntry::new("child", gitlink_id, 0o160000, 0),
  ])
  fs.mkdir_p("/repo/child")
  fs.write_string("/repo/child/.git", "gitdir: ../.git/modules/child\n")

  mv_path(fs, fs, "/repo", "child", "child_old")

  let entries = read_index_entries(fs, "/repo/.git")
  @test.assert_eq(entries.length(), 1)
  @test.assert_eq(entries[0].path, "child_old")
  assert_false(fs.is_dir("/repo/child"))
  assert_true(fs.is_dir("/repo/child_old"))
  @test.assert_eq(
    fs.read_string("/repo/child_old/.git"),
    "gitdir: ../.git/modules/child\n",
  )
}

///|
async test "worktree: mv_path updates gitmodules path for gitlink rename" {
  let fs = setup_repo()
  let gitlink_id = @bit.ObjectId::from_hex(
    "e598ccc29ff366687aa04587483454a7925521ae",
  )
  fs.write_string(
    "/repo/.gitmodules", "[submodule \"a\"]\n\tpath = a\n\turl = ../submodule\n",
  )
  add_paths(fs, fs, "/repo", [".gitmodules"])
  let entries = read_index_entries(fs, "/repo/.git")
  entries.push(IndexEntry::new("a", gitlink_id, 0o160000, 0))
  write_index_entries(fs, "/repo/.git", entries)
  fs.mkdir_p("/repo/a")
  fs.write_string("/repo/a/.git", "gitdir: ../.git/modules/a\n")

  mv_path(fs, fs, "/repo", "a", "b")

  @test.assert_eq(
    fs.read_string("/repo/.gitmodules"),
    "[submodule \"a\"]\n\tpath = b\n\turl = ../submodule\n",
  )
  let updated_entries = read_index_entries(fs, "/repo/.git")
  let mut gitmodules_entry : IndexEntry? = None
  for entry in updated_entries {
    if entry.path == ".gitmodules" {
      gitmodules_entry = Some(entry)
      break
    }
  }
  guard gitmodules_entry is Some(entry) else {
    fail("expected .gitmodules entry in index after move")
  }
  let db = ObjectDb::load_lazy(fs, "/repo/.git")
  let gitmodules_obj = db.get(fs, entry.id).unwrap()
  @test.assert_eq(
    @utf8.decode_lossy(gitmodules_obj.data),
    "[submodule \"a\"]\n\tpath = b\n\turl = ../submodule\n",
  )
}

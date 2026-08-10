///|
fn index_wbtest_init_sha256_repo(fs : @bit.TestFs) -> Unit {
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
}

///|
test "index: read_index_entries accepts version 3 headers" {
  let fs = @bit.TestFs::new()
  init_repo(fs, "/repo")
  fs.write_string("/repo/a.txt", "hello\n")
  add_paths(fs, fs, "/repo", ["a.txt"])

  let index_path = "/repo/.git/index"
  let data = fs.read_file(index_path)
  let patched = Bytes::from_array(
    FixedArray::makei(data.length(), fn(i) {
      if i == 7 {
        b'\x03'
      } else {
        data[i]
      }
    }),
  )
  fs.write_file(index_path, patched)

  let entries = read_index_entries(fs, "/repo/.git")
  assert_eq(entries.length(), 1)
  assert_eq(entries[0].path, "a.txt")
}

///|
test "index: read_skip_worktree_paths reads extended skip-worktree flag" {
  let fs = @bit.TestFs::new()
  init_repo(fs, "/repo")
  fs.write_string("/repo/a.txt", "hello\n")
  add_paths(fs, fs, "/repo", ["a.txt"])
  index_test_mark_single_entry_skip_worktree(fs, "/repo/.git/index")

  let skip = read_skip_worktree_paths(fs, "/repo/.git")
  assert_true(skip.contains("a.txt"))

  let entries = read_index_entries(fs, "/repo/.git")
  assert_eq(entries.length(), 1)
  assert_eq(entries[0].path, "a.txt")
}

///|
test "index: write_skip_worktree_paths marks extended flag entries" {
  let fs = @bit.TestFs::new()
  init_repo(fs, "/repo")
  fs.write_string("/repo/a.txt", "hello\n")
  add_paths(fs, fs, "/repo", ["a.txt"])
  let entries = read_index_entries(fs, "/repo/.git")
  let skip_set : Map[String, Bool] = { "a.txt": true }
  write_skip_worktree_paths(fs, "/repo/.git", ["a.txt"])
  write_index_entries_with_skip_worktree(fs, "/repo/.git", entries, skip_set)
  let skip = read_skip_worktree_paths(fs, "/repo/.git")
  assert_true(skip.contains("a.txt"))
}

///|
test "index: write_index_entries_with_flags preserves sha256 paths" {
  let fs = @bit.TestFs::new()
  index_wbtest_init_sha256_repo(fs)
  let content = @utf8.encode("hello\n")
  let blob_id = write_loose_object(
    fs,
    "/repo/.git",
    @bit.ObjectType::Blob,
    content,
    algo=@bit.HashAlgorithm::Sha256,
  )
  let entries = [IndexEntry::new("hello", blob_id, 0o100644, content.length())]

  write_index_entries_with_flags(fs, "/repo/.git", entries, Map([]), Map([]))

  let actual = read_index_entries(fs, "/repo/.git")
  assert_eq(actual.length(), 1)
  assert_eq(actual[0].path, "hello")
  assert_eq(actual[0].id.to_hex(), blob_id.to_hex())
}

///|
test "index: write_index_entries supports empty sha256 index" {
  let fs = @bit.TestFs::new()
  index_wbtest_init_sha256_repo(fs)

  write_index_entries(fs, "/repo/.git", [], hash_size=32)

  let actual = read_index_entries(fs, "/repo/.git")
  assert_eq(actual.length(), 0)
  assert_eq(fs.read_file("/repo/.git/index").length(), 44)
}

///|
test "index: read_index_entries preserves intent-to-add entries" {
  let fs = @bit.TestFs::new()
  init_repo(fs, "/repo")
  let empty = @bit.ObjectId::from_hex(
    "e69de29bb2d1d6434b8b29ae775ad8c2e48c5391",
  )
  let entries = [
    IndexEntry::new("file", empty, 0o100644, 0, intent_to_add=true),
  ]
  write_index_entries(fs, "/repo/.git", entries)

  let actual = read_index_entries(fs, "/repo/.git")
  assert_eq(actual.length(), 1)
  assert_eq(actual[0].path, "file")
  assert_true(actual[0].intent_to_add)
  assert_eq(actual[0].id.to_hex(), empty.to_hex())
}

///|
test "index: read_index_stage_entries preserves unmerged stages" {
  let fs = @bit.TestFs::new()
  init_repo(fs, "/repo")
  fs.write_string("/repo/a.txt", "hello\n")
  add_paths(fs, fs, "/repo", ["a.txt"])
  index_test_replace_single_entry_with_stages(fs, "/repo/.git/index", [1, 2, 3])

  let actual = read_index_stage_entries(fs, "/repo/.git")
  assert_eq(actual.length(), 3)
  assert_eq(actual[0].entry.path, "a.txt")
  assert_eq(actual[0].stage, 1)
  assert_eq(actual[1].stage, 2)
  assert_eq(actual[2].stage, 3)
}

///|
test "index: read_resolve_undo_entries reads REUC extension" {
  let fs = @bit.TestFs::new()
  init_repo(fs, "/repo")
  fs.write_string("/repo/a.txt", "hello\n")
  add_paths(fs, fs, "/repo", ["a.txt"])

  let base_hex = "1111111111111111111111111111111111111111"
  let ours_hex = "2222222222222222222222222222222222222222"
  let theirs_hex = "3333333333333333333333333333333333333333"
  index_test_write_resolve_undo_extension(
    fs, "/repo/.git/index", "a.txt", "100644", "100755", "100644", base_hex, ours_hex,
    theirs_hex,
  )

  let actual = read_resolve_undo_entries(fs, "/repo/.git")
  assert_eq(actual.length(), 1)
  assert_eq(actual[0].path, "a.txt")
  match actual[0].base {
    Some(stage) => {
      assert_eq(stage.mode, 0o100644)
      assert_eq(stage.id.to_hex(), base_hex)
    }
    None => assert_true(false)
  }
  match actual[0].ours {
    Some(stage) => {
      assert_eq(stage.mode, 0o100755)
      assert_eq(stage.id.to_hex(), ours_hex)
    }
    None => assert_true(false)
  }
  match actual[0].theirs {
    Some(stage) => {
      assert_eq(stage.mode, 0o100644)
      assert_eq(stage.id.to_hex(), theirs_hex)
    }
    None => assert_true(false)
  }
}

///|
test "index: write_index_entries_with_tree writes valid TREE extension" {
  let fs = @bit.TestFs::new()
  init_repo(fs, "/repo")
  fs.write_string("/repo/one", "frotz\n")
  fs.mkdir_p("/repo/two")
  fs.write_string("/repo/two/three", "frotz\n")
  add_paths(fs, fs, "/repo", ["one", "two/three"])

  let entries = read_index_entries(fs, "/repo/.git")
  let tree_id = write_tree_from_index(fs, fs, "/repo/.git", entries)
  write_index_entries_with_tree(fs, fs, "/repo/.git", entries, tree_id)

  let cache_tree = index_read_cache_tree_from_bytes(
    fs.read_file("/repo/.git/index"),
  )
  guard cache_tree is Some(root) else { fail("expected TREE extension") }
  let db = ObjectDb::load(fs, "/repo/.git")
  let tree_obj = db.get(fs, tree_id)
  guard tree_obj is Some(root_obj) else { fail("expected root tree object") }
  let root_entries = @bit.parse_tree(root_obj.data)
  let mut two_tree_id : @bit.ObjectId? = None
  for entry in root_entries {
    if entry.name == "two" {
      two_tree_id = Some(entry.id)
    }
  }
  guard two_tree_id is Some(expected_two_tree) else {
    fail("expected two subtree id")
  }
  assert_eq(root.name, "")
  assert_eq(root.entry_count, 2)
  match root.oid {
    Some(actual_root_tree) =>
      assert_eq(actual_root_tree.to_hex(), tree_id.to_hex())
    None => fail("expected valid root cache-tree")
  }
  let two_tree = index_test_cache_tree_subtree(root, "two")
  guard two_tree is Some(subtree) else { fail("expected subtree cache-tree") }
  assert_eq(subtree.entry_count, 1)
  match subtree.oid {
    Some(actual_two_tree) =>
      assert_eq(actual_two_tree.to_hex(), expected_two_tree.to_hex())
    None => fail("expected valid subtree cache-tree")
  }
}

///|
test "index: write_index_entries invalidates root and keeps unaffected subtree" {
  let fs = @bit.TestFs::new()
  init_repo(fs, "/repo")
  fs.write_string("/repo/one", "frotz\n")
  fs.mkdir_p("/repo/two")
  fs.write_string("/repo/two/three", "frotz\n")
  add_paths(fs, fs, "/repo", ["one", "two/three"])

  let entries = read_index_entries(fs, "/repo/.git")
  let tree_id = write_tree_from_index(fs, fs, "/repo/.git", entries)
  write_index_entries_with_tree(fs, fs, "/repo/.git", entries, tree_id)

  let db = ObjectDb::load(fs, "/repo/.git")
  let tree_obj = db.get(fs, tree_id)
  guard tree_obj is Some(root_obj) else { fail("expected root tree object") }
  let root_entries = @bit.parse_tree(root_obj.data)
  let mut two_tree_id : @bit.ObjectId? = None
  for entry in root_entries {
    if entry.name == "two" {
      two_tree_id = Some(entry.id)
    }
  }
  guard two_tree_id is Some(expected_two_tree) else {
    fail("expected two subtree id")
  }

  fs.write_string("/repo/only-in-index", "only-in-index\n")
  add_paths(fs, fs, "/repo", ["only-in-index"])

  let cache_tree = index_read_cache_tree_from_bytes(
    fs.read_file("/repo/.git/index"),
  )
  guard cache_tree is Some(root) else {
    fail("expected TREE extension after add")
  }
  assert_eq(root.entry_count, -1)
  assert_true(root.oid is None)
  let two_tree = index_test_cache_tree_subtree(root, "two")
  guard two_tree is Some(subtree) else {
    fail("expected preserved subtree cache-tree")
  }
  assert_eq(subtree.entry_count, 1)
  match subtree.oid {
    Some(actual_two_tree) =>
      assert_eq(actual_two_tree.to_hex(), expected_two_tree.to_hex())
    None => fail("expected valid preserved subtree cache-tree")
  }
}

///|
test "index: write_index_entries_preserving_cache_tree builds fresh TREE extension" {
  let fs = @bit.TestFs::new()
  init_repo(fs, "/repo")
  let content = @utf8.encode("frotz\n")
  let blob_id = write_loose_object(
    fs,
    "/repo/.git",
    @bit.ObjectType::Blob,
    content,
  )
  let entries = [
    IndexEntry::new("one", blob_id, 0o100644, content.length()),
    IndexEntry::new("two/three", blob_id, 0o100644, content.length()),
  ]

  write_index_entries_preserving_cache_tree(fs, fs, "/repo/.git", entries)

  let cache_tree = index_read_cache_tree_from_bytes(
    fs.read_file("/repo/.git/index"),
  )
  guard cache_tree is Some(root) else { fail("expected TREE extension") }
  assert_eq(root.entry_count, 2)
  let two_tree = index_test_cache_tree_subtree(root, "two")
  guard two_tree is Some(subtree) else { fail("expected subtree cache-tree") }
  assert_eq(subtree.entry_count, 1)
}

///|
test "index: write_index_entries_preserving_cache_tree preserves skip and assume flags" {
  let fs = @bit.TestFs::new()
  init_repo(fs, "/repo")
  fs.write_string("/repo/a.txt", "hello\n")
  fs.write_string("/repo/b.txt", "world\n")
  add_paths(fs, fs, "/repo", ["a.txt", "b.txt"])

  let entries = read_index_entries(fs, "/repo/.git")
  let skip_paths : Map[String, Bool] = { "a.txt": true }
  let assume_paths : Map[String, Bool] = { "b.txt": true }
  write_index_entries_with_flags(
    fs, "/repo/.git", entries, skip_paths, assume_paths,
  )

  let rewritten = read_index_entries(fs, "/repo/.git")
  write_index_entries_preserving_cache_tree(fs, fs, "/repo/.git", rewritten)

  let actual_skip = read_skip_worktree_paths(fs, "/repo/.git")
  let actual_assume = read_assume_unchanged_paths(fs, "/repo/.git")
  assert_true(actual_skip.contains("a.txt"))
  assert_true(actual_assume.contains("b.txt"))
}

///|
test "index: sparse directory entries expand to file entries and skip paths" {
  let fs = @bit.TestFs::new()
  init_repo(fs, "/repo")
  fs.write_string("/repo/root.txt", "root\n")
  fs.mkdir_p("/repo/dir")
  fs.write_string("/repo/dir/file.txt", "nested\n")
  add_paths(fs, fs, "/repo", ["root.txt", "dir/file.txt"])

  let full_entries = read_index_entries(fs, "/repo/.git")
  let tree_id = write_tree_from_index(fs, fs, "/repo/.git", full_entries)
  let db = ObjectDb::load(fs, "/repo/.git")
  let tree_obj = db.get(fs, tree_id)
  guard tree_obj is Some(root_obj) else { fail("expected root tree") }
  let root_entries = @bit.parse_tree(root_obj.data)
  let mut dir_tree_id : @bit.ObjectId? = None
  let mut root_entry : IndexEntry? = None
  for entry in full_entries {
    if entry.path == "root.txt" {
      root_entry = Some(entry)
    }
  }
  guard root_entry is Some(existing_root_entry) else {
    fail("expected root entry")
  }
  for entry in root_entries {
    if entry.name == "dir" {
      dir_tree_id = Some(entry.id)
    }
  }
  guard dir_tree_id is Some(actual_dir_tree_id) else {
    fail("expected dir tree id")
  }

  let sparse_entries = [
    existing_root_entry,
    IndexEntry::new("dir/", actual_dir_tree_id, 0o040000, 0),
  ]
  let expanded = expand_sparse_index_entries(fs, "/repo/.git", sparse_entries)
  assert_true(expanded.any(fn(entry) { entry.path == "root.txt" }))
  assert_true(expanded.any(fn(entry) { entry.path == "dir/file.txt" }))
  assert_false(expanded.any(fn(entry) { entry.path == "dir/" }))

  let expanded_skip = expand_sparse_skip_worktree_paths(
    fs,
    "/repo/.git",
    sparse_entries,
    { "dir/": true },
  )
  assert_true(expanded_skip.contains("dir/"))
  assert_true(expanded_skip.contains("dir/file.txt"))
}

///|
fn index_test_mark_single_entry_skip_worktree(
  fs : @bit.TestFs,
  index_path : String,
) -> Unit {
  let data = fs.read_file(index_path) catch { _ => Default::default() }
  let arr : Array[Byte] = []
  for b in data {
    arr.push(b)
  }
  // entry_start = 12, flags offset = entry_start + 60
  let flags_offset = 72
  arr[flags_offset] = (arr[flags_offset].to_int() | 0x40).to_byte()

  // Rewrite [ext_flags][path...NUL][padding] in-place.
  // For a.txt (len=5), old/new entry sizes are both 72 bytes.
  let path_start = 74
  let path_with_nul : Array[Byte] = []
  let mut i = path_start
  while i < arr.length() && arr[i] != b'\x00' {
    path_with_nul.push(arr[i])
    i += 1
  }
  path_with_nul.push(b'\x00')

  arr[path_start] = b'\x40'
  arr[path_start + 1] = b'\x00'
  for j in 0..<path_with_nul.length() {
    arr[path_start + 2 + j] = path_with_nul[j]
  }
  let entry_end = 84
  let mut k = path_start + 2 + path_with_nul.length()
  while k < entry_end {
    arr[k] = b'\x00'
    k += 1
  }

  let patched = Bytes::from_array(
    FixedArray::makei(arr.length(), fn(i) { arr[i] }),
  )
  fs.write_file(index_path, patched)
}

///|
fn index_test_replace_single_entry_with_stages(
  fs : @bit.TestFs,
  index_path : String,
  stages : Array[Int],
) -> Unit {
  let data = fs.read_file(index_path) catch { _ => Default::default() }
  if data.length() < 12 + 20 {
    panic()
  }
  let arr : Array[Byte] = []
  for b in data {
    arr.push(b)
  }
  let checksum_start = arr.length() - 20
  let entry_start = 12
  let flags_offset = entry_start + 60
  let flags = (arr[flags_offset].to_int() << 8) | arr[flags_offset + 1].to_int()
  let has_extended = (flags & 0x4000) != 0
  let fixed_size = if has_extended { 64 } else { 62 }
  let path_start = entry_start + fixed_size
  let mut path_end = path_start
  while path_end < checksum_start && arr[path_end] != b'\x00' {
    path_end += 1
  }
  if path_end >= checksum_start {
    panic()
  }
  let path_len = path_end - path_start
  let entry_size = (fixed_size + path_len + 1 + 7) / 8 * 8
  let base_entry : Array[Byte] = []
  for i in entry_start..<(entry_start + entry_size) {
    base_entry.push(arr[i])
  }
  let trailing : Array[Byte] = []
  for i in (entry_start + entry_size)..<checksum_start {
    trailing.push(arr[i])
  }

  let patched : Array[Byte] = []
  for i in 0..<12 {
    patched.push(arr[i])
  }
  let count = stages.length()
  patched[8] = ((count >> 24) & 0xFF).to_byte()
  patched[9] = ((count >> 16) & 0xFF).to_byte()
  patched[10] = ((count >> 8) & 0xFF).to_byte()
  patched[11] = (count & 0xFF).to_byte()
  for stage in stages {
    let entry_copy = base_entry.copy()
    let stage_flags = (flags & 0xCFFF) | ((stage & 0x3) << 12)
    entry_copy[60] = ((stage_flags >> 8) & 0xFF).to_byte()
    entry_copy[61] = (stage_flags & 0xFF).to_byte()
    patched.append(entry_copy)
  }
  patched.append(trailing)
  let content = Bytes::from_array(
    FixedArray::makei(patched.length(), fn(i) { patched[i] }),
  )
  let checksum = @bit.sha1(content)
  for i in 0..<20 {
    patched.push(checksum.bytes[i])
  }
  fs.write_file(
    index_path,
    Bytes::from_array(FixedArray::makei(patched.length(), fn(i) { patched[i] })),
  )
}

///|
fn index_test_write_resolve_undo_extension(
  fs : @bit.TestFs,
  index_path : String,
  path : String,
  base_mode : String,
  ours_mode : String,
  theirs_mode : String,
  base_hex : String,
  ours_hex : String,
  theirs_hex : String,
) -> Unit {
  let data = fs.read_file(index_path) catch { _ => Default::default() }
  let arr : Array[Byte] = []
  for b in data {
    arr.push(b)
  }
  let checksum_start = arr.length() - 20
  let body : Array[Byte] = []
  index_test_append_nul_terminated_ascii(body, path)
  index_test_append_nul_terminated_ascii(body, base_mode)
  index_test_append_nul_terminated_ascii(body, ours_mode)
  index_test_append_nul_terminated_ascii(body, theirs_mode)
  index_test_append_hex_bytes(body, base_hex)
  index_test_append_hex_bytes(body, ours_hex)
  index_test_append_hex_bytes(body, theirs_hex)

  let extension : Array[Byte] = [b'R', b'E', b'U', b'C']
  index_test_append_u32_be(extension, body.length())
  extension.append(body)

  let patched : Array[Byte] = []
  for i in 0..<checksum_start {
    patched.push(arr[i])
  }
  patched.append(extension)
  for i in checksum_start..<arr.length() {
    patched.push(arr[i])
  }
  fs.write_file(
    index_path,
    Bytes::from_array(FixedArray::makei(patched.length(), fn(i) { patched[i] })),
  )
}

///|
fn index_test_append_nul_terminated_ascii(
  target : Array[Byte],
  text : String,
) -> Unit {
  for c in text.to_array() {
    target.push(c.to_int().to_byte())
  }
  target.push(b'\x00')
}

///|
fn index_test_append_hex_bytes(target : Array[Byte], hex : String) -> Unit {
  let chars = hex.to_array()
  for i in 0..<20 {
    let hi = index_test_hex_char_to_int(chars[i * 2])
    let lo = index_test_hex_char_to_int(chars[i * 2 + 1])
    target.push(((hi << 4) | lo).to_byte())
  }
}

///|
fn index_test_append_u32_be(target : Array[Byte], value : Int) -> Unit {
  target.push(((value >> 24) & 0xFF).to_byte())
  target.push(((value >> 16) & 0xFF).to_byte())
  target.push(((value >> 8) & 0xFF).to_byte())
  target.push((value & 0xFF).to_byte())
}

///|
fn index_test_cache_tree_subtree(
  tree : IndexCacheTree,
  name : String,
) -> IndexCacheTree? {
  for subtree in tree.subtrees {
    if subtree.name == name {
      return Some(subtree)
    }
  }
  None
}

///|
fn index_test_hex_char_to_int(c : Char) -> Int {
  if c >= '0' && c <= '9' {
    c.to_int() - '0'.to_int()
  } else if c >= 'a' && c <= 'f' {
    c.to_int() - 'a'.to_int() + 10
  } else if c >= 'A' && c <= 'F' {
    c.to_int() - 'A'.to_int() + 10
  } else {
    0
  }
}

///| Tests verifying compatibility with real Git

///|
/// All expected values were generated using git command-line tools

// =============================================================================
// Blob Hash Tests
// =============================================================================

test "git compat: blob hash 'hello' (no newline)" {
  // echo -n "hello" | git hash-object --stdin
  let id = @git.hash_blob_string("hello")
  inspect(id.to_hex(), content="b6fc4c620b67d95f953a5c1c1230aaab5db5a1b0")
}

///|
test "git compat: blob hash 'hello\\n'" {
  // echo "hello" | git hash-object --stdin
  let id = @git.hash_blob_string("hello\n")
  inspect(id.to_hex(), content="ce013625030ba8dba906f756967f9e9ca394464a")
}

///|
test "git compat: blob hash 'world\\n'" {
  // echo "world" | git hash-object --stdin
  let id = @git.hash_blob_string("world\n")
  inspect(id.to_hex(), content="cc628ccd10742baea8241c5924df992b5c019f71")
}

///|
test "git compat: blob hash single newline" {
  // echo "" | git hash-object --stdin
  let id = @git.hash_blob_string("\n")
  inspect(id.to_hex(), content="8b137891791fe96927ad78e64b0aad7bded08bdc")
}

///|
test "git compat: blob hash multiline" {
  // printf "line1\nline2\nline3\n" | git hash-object --stdin
  let id = @git.hash_blob_string("line1\nline2\nline3\n")
  inspect(id.to_hex(), content="83db48f84ec878fbfb30b46d16630e944e34f205")
}

///|
test "git compat: blob hash empty" {
  // git hash-object -t blob /dev/null
  let id = @git.hash_blob_string("")
  inspect(id.to_hex(), content="e69de29bb2d1d6434b8b29ae775ad8c2e48c5391")
}

// =============================================================================
// Tree Hash Tests
// =============================================================================

///|
test "git compat: tree with single file" {
  // Tree containing: hello.txt -> "hello\n"
  // git write-tree after: echo "hello" > hello.txt && git add hello.txt
  let blob_id = @git.ObjectId::from_hex(
    "ce013625030ba8dba906f756967f9e9ca394464a",
  )
  let entry = @git.TreeEntry::new("100644", "hello.txt", blob_id)
  let (tree_id, _) = @git.create_tree([entry])
  inspect(tree_id.to_hex(), content="aaa96ced2d9a1c8e72c56b253a0e2fe78393feb7")
}

///|
test "git compat: tree with two files" {
  // Tree containing:
  //   hello.txt -> "hello\n"
  //   world.txt -> "world\n"
  // Entries must be sorted by name
  let hello_id = @git.ObjectId::from_hex(
    "ce013625030ba8dba906f756967f9e9ca394464a",
  )
  let world_id = @git.ObjectId::from_hex(
    "cc628ccd10742baea8241c5924df992b5c019f71",
  )
  let entries = [
    @git.TreeEntry::new("100644", "hello.txt", hello_id),
    @git.TreeEntry::new("100644", "world.txt", world_id),
  ]
  let (tree_id, _) = @git.create_tree(entries)
  inspect(tree_id.to_hex(), content="88e38705fdbd3608cddbe904b67c731f3234c45b")
}

// =============================================================================
// Commit Hash Tests
// =============================================================================

///|
test "git compat: initial commit" {
  // Commit with:
  //   tree: 88e38705fdbd3608cddbe904b67c731f3234c45b
  //   author: Test <test@example.com> 1700000000 +0000
  //   committer: Test <test@example.com> 1700000000 +0000
  //   message: Initial commit
  let tree_id = @git.ObjectId::from_hex(
    "88e38705fdbd3608cddbe904b67c731f3234c45b",
  )
  let commit = @git.Commit::new(
    tree_id,
    [], // no parents
    "Test <test@example.com>",
    1700000000L,
    "+0000",
    "Test <test@example.com>",
    1700000000L,
    "+0000",
    "Initial commit\n",
  )
  let (commit_id, _) = @git.create_commit(commit)
  inspect(
    commit_id.to_hex(),
    content="681226a87c4a64f59b7b47bd497af25e16ac4635",
  )
}

// =============================================================================
// Zlib Tests
// =============================================================================

///|
test "git compat: zlib roundtrip" {
  let original = "Hello, Git!\n"
  let data : Array[Byte] = []
  for c in original {
    data.push(c.to_int().to_byte())
  }
  let bytes = Bytes::from_array(
    FixedArray::makei(data.length(), fn(i) { data[i] }),
  )
  let compressed = @zlib.zlib_compress_stored(bytes)
  let decompressed = @zlib.zlib_decompress(compressed)
  assert_true(decompressed.length() == bytes.length())
  for i = 0; i < bytes.length(); i = i + 1 {
    assert_true(decompressed[i] == bytes[i])
  }
}

///|
test "git compat: zlib header" {
  let data = Bytes::from_array([b'x'])
  let compressed = @zlib.zlib_compress_stored(data)

  // Zlib header: 0x78 0x01 (deflate, fastest)
  inspect(compressed[0], content="b'\\x78'")
  inspect(compressed[1], content="b'\\x01'")
}

// =============================================================================
// Packfile Tests
// =============================================================================

///|
test "git compat: packfile header" {
  let content = Bytes::from_array([b'h', b'e', b'l', b'l', b'o'])
  let packfile = @pack.create_blob_packfile(content)

  // Magic: "PACK"
  inspect(packfile[0], content="b'\\x50'") // 'P'
  inspect(packfile[1], content="b'\\x41'") // 'A'
  inspect(packfile[2], content="b'\\x43'") // 'C'
  inspect(packfile[3], content="b'\\x4B'") // 'K'

  // Version: 2 (big-endian)
  inspect(packfile[4], content="b'\\x00'")
  inspect(packfile[5], content="b'\\x00'")
  inspect(packfile[6], content="b'\\x00'")
  inspect(packfile[7], content="b'\\x02'")

  // Object count: 1 (big-endian)
  inspect(packfile[8], content="b'\\x00'")
  inspect(packfile[9], content="b'\\x00'")
  inspect(packfile[10], content="b'\\x00'")
  inspect(packfile[11], content="b'\\x01'")
}

///|
test "git compat: packfile with 3 objects" {
  let blob_content = Bytes::from_array([b'h', b'e', b'l', b'l', b'o', b'\n'])
  let commit = @git.Commit::new(
    @git.ObjectId::zero(),
    [],
    "Test <test@example.com>",
    1700000000L,
    "+0000",
    "Test <test@example.com>",
    1700000000L,
    "+0000",
    "Test\n",
  )
  let (_, packfile) = @pack.create_commit_packfile(
    blob_content, "hello.txt", commit,
  )

  // Object count should be 3 (blob, tree, commit)
  inspect(packfile[8], content="b'\\x00'")
  inspect(packfile[9], content="b'\\x00'")
  inspect(packfile[10], content="b'\\x00'")
  inspect(packfile[11], content="b'\\x03'")
}

// =============================================================================
// pkt-line Tests
// =============================================================================

///|
test "git compat: pktline encode" {
  // "hello\n" with 4-byte length prefix
  // Length = 6 + 4 = 10 = 0x000a
  let encoded = @protocol.pktline_encode("hello\n")
  inspect(encoded[0], content="b'\\x30'") // '0'
  inspect(encoded[1], content="b'\\x30'") // '0'
  inspect(encoded[2], content="b'\\x30'") // '0'
  inspect(encoded[3], content="b'\\x61'") // 'a'
  inspect(encoded[4], content="b'\\x68'") // 'h'
}

///|
test "git compat: pktline flush" {
  // Flush packet: 0000
  let flush = @protocol.pktline_flush()
  inspect(flush.length(), content="4")
  inspect(flush[0], content="b'\\x30'")
  inspect(flush[1], content="b'\\x30'")
  inspect(flush[2], content="b'\\x30'")
  inspect(flush[3], content="b'\\x30'")
}

///|
test "git compat: pktline delim" {
  // Delimiter packet: 0001
  let delim = @protocol.pktline_delim()
  inspect(delim.length(), content="4")
  inspect(delim[0], content="b'\\x30'")
  inspect(delim[1], content="b'\\x30'")
  inspect(delim[2], content="b'\\x30'")
  inspect(delim[3], content="b'\\x31'")
}

// =============================================================================
// ObjectId Tests
// =============================================================================

///|
test "git compat: ObjectId zero" {
  let id = @git.ObjectId::zero()
  inspect(id.to_hex(), content="0000000000000000000000000000000000000000")
}

///|
test "git compat: ObjectId from_hex roundtrip" {
  let hex = "ce013625030ba8dba906f756967f9e9ca394464a"
  let id = @git.ObjectId::from_hex(hex)
  inspect(id.to_hex(), content="ce013625030ba8dba906f756967f9e9ca394464a")
}

// =============================================================================
// SHA-1 Known Values Tests
// =============================================================================

///|
test "git compat: SHA-1 empty string" {
  // SHA-1("") = da39a3ee5e6b4b0d3255bfef95601890afd80709
  let hash = @git.sha1(Bytes::from_array([]))
  inspect(hash.to_hex(), content="da39a3ee5e6b4b0d3255bfef95601890afd80709")
}

///|
test "git compat: SHA-1 'abc'" {
  // SHA-1("abc") = a9993e364706816aba3e25717850c26c9cd0d89d
  let hash = @git.sha1(Bytes::from_array([b'a', b'b', b'c']))
  inspect(hash.to_hex(), content="a9993e364706816aba3e25717850c26c9cd0d89d")
}

///|
test "git compat: SHA-1 quick brown fox" {
  // SHA-1("The quick brown fox jumps over the lazy dog")
  // = 2fd4e1c67a2d28fced849ee1bb76e7391b93eb12
  let msg = "The quick brown fox jumps over the lazy dog"
  let data : Array[Byte] = []
  for c in msg {
    data.push(c.to_int().to_byte())
  }
  let hash = @git.sha1(
    Bytes::from_array(FixedArray::makei(data.length(), fn(i) { data[i] })),
  )
  inspect(hash.to_hex(), content="2fd4e1c67a2d28fced849ee1bb76e7391b93eb12")
}

// =============================================================================
// Nested Tree Tests
// =============================================================================

///|
test "git compat: subtree with single file" {
  // Tree containing: world.txt -> "world\n"
  // This is the "subdir" tree in a nested structure
  let world_id = @git.ObjectId::from_hex(
    "cc628ccd10742baea8241c5924df992b5c019f71",
  )
  let entry = @git.TreeEntry::new("100644", "world.txt", world_id)
  let (tree_id, _) = @git.create_tree([entry])
  inspect(tree_id.to_hex(), content="b032d4b998c65562e088abaa88fdd859476c089e")
}

///|
test "git compat: nested tree with subdirectory" {
  // Tree containing:
  //   hello.txt -> "hello\n"
  //   subdir/   -> tree(world.txt -> "world\n")
  // Structure:
  //   .
  //   ├── hello.txt
  //   └── subdir/
  //       └── world.txt
  let hello_id = @git.ObjectId::from_hex(
    "ce013625030ba8dba906f756967f9e9ca394464a",
  )
  let subdir_id = @git.ObjectId::from_hex(
    "b032d4b998c65562e088abaa88fdd859476c089e",
  )
  let entries = [
    @git.TreeEntry::new("100644", "hello.txt", hello_id),
    @git.TreeEntry::new("40000", "subdir", subdir_id),
  ]
  let (tree_id, _) = @git.create_tree(entries)
  inspect(tree_id.to_hex(), content="117040856e0066e76d38c559f9d2127fd6a10858")
}

// =============================================================================
// Commit with Parent Tests
// =============================================================================

///|
test "git compat: commit with parent" {
  // Second commit with parent
  // tree: 88e38705fdbd3608cddbe904b67c731f3234c45b (hello.txt + world.txt)
  // parent: 681226a87c4a64f59b7b47bd497af25e16ac4635 (initial commit)
  // author/committer: Test <test@example.com> 1700000100 +0000
  // message: Second commit
  let tree_id = @git.ObjectId::from_hex(
    "88e38705fdbd3608cddbe904b67c731f3234c45b",
  )
  let parent_id = @git.ObjectId::from_hex(
    "681226a87c4a64f59b7b47bd497af25e16ac4635",
  )
  let commit = @git.Commit::new(
    tree_id,
    [parent_id],
    "Test <test@example.com>",
    1700000100L,
    "+0000",
    "Test <test@example.com>",
    1700000100L,
    "+0000",
    "Second commit\n",
  )
  let (commit_id, _) = @git.create_commit(commit)
  // Verified against git hash-object -t commit
  inspect(
    commit_id.to_hex(),
    content="2fe96b04b8c1f081765898435f0d2497cfef21ea",
  )
}

// =============================================================================
// Blob Integrity Tests (Binary Data)
// =============================================================================

///|
test "blob integrity: null bytes preserved" {
  // Verify null bytes are not truncated or corrupted
  let data = Bytes::from_array([b'\x00', b'a', b'\x00', b'b', b'\x00'])
  let (id, compressed) = @git.create_blob(data)
  let decompressed = @zlib.zlib_decompress(compressed)
  // Skip header "blob 5\0" (7 bytes)
  let header_len = 7
  assert_true(decompressed.length() == header_len + data.length())
  for i = 0; i < data.length(); i = i + 1 {
    assert_true(decompressed[header_len + i] == data[i])
  }
  // Verify hash is consistent
  let id2 = @git.hash_blob(data)
  assert_true(id == id2)
}

///|
test "blob integrity: high bytes (0x80-0xFF)" {
  // Verify bytes > 127 are handled correctly
  let data = Bytes::from_array([b'\x80', b'\xFF', b'\xFE', b'\xAB', b'\xCD'])
  let (id, compressed) = @git.create_blob(data)
  let decompressed = @zlib.zlib_decompress(compressed)
  let header_len = 7 // "blob 5\0"
  assert_true(decompressed.length() == header_len + data.length())
  for i = 0; i < data.length(); i = i + 1 {
    assert_true(decompressed[header_len + i] == data[i])
  }
  let id2 = @git.hash_blob(data)
  assert_true(id == id2)
}

///|
test "blob integrity: all byte values roundtrip" {
  // Create blob with all 256 possible byte values
  let data : Array[Byte] = []
  for i = 0; i < 256; i = i + 1 {
    data.push(i.to_byte())
  }
  let bytes = Bytes::from_array(FixedArray::makei(256, fn(i) { data[i] }))
  let (id, compressed) = @git.create_blob(bytes)
  let decompressed = @zlib.zlib_decompress(compressed)
  let header_len = 9 // "blob 256\0"
  assert_true(decompressed.length() == header_len + 256)
  for i = 0; i < 256; i = i + 1 {
    assert_true(decompressed[header_len + i] == i.to_byte())
  }
  // Verify hash consistency
  let id2 = @git.hash_blob(bytes)
  assert_true(id == id2)
}

///|
test "blob integrity: single byte" {
  let data = Bytes::from_array([b'X'])
  let (id, compressed) = @git.create_blob(data)
  let decompressed = @zlib.zlib_decompress(compressed)
  let header_len = 7 // "blob 1\0"
  assert_true(decompressed.length() == header_len + 1)
  assert_true(decompressed[header_len] == b'X')
  let id2 = @git.hash_blob(data)
  assert_true(id == id2)
}

///|
test "blob integrity: 1KB binary data" {
  // Test with larger binary data
  let size = 1024
  let data : Array[Byte] = []
  for i = 0; i < size; i = i + 1 {
    data.push((i % 256).to_byte())
  }
  let bytes = Bytes::from_array(FixedArray::makei(size, fn(i) { data[i] }))
  let (id, compressed) = @git.create_blob(bytes)
  let decompressed = @zlib.zlib_decompress(compressed)
  // header: "blob 1024\0" = 10 bytes
  let header_len = 10
  assert_true(decompressed.length() == header_len + size)
  for i = 0; i < size; i = i + 1 {
    assert_true(decompressed[header_len + i] == (i % 256).to_byte())
  }
  let id2 = @git.hash_blob(bytes)
  assert_true(id == id2)
}

///|
test "blob integrity: 100KB binary data" {
  // Test with data larger than single zlib block
  let size = 100 * 1024
  let data : Array[Byte] = []
  for i = 0; i < size; i = i + 1 {
    data.push((i % 256).to_byte())
  }
  let bytes = Bytes::from_array(FixedArray::makei(size, fn(i) { data[i] }))
  let (id, compressed) = @git.create_blob(bytes)
  let decompressed = @zlib.zlib_decompress(compressed)
  // header: "blob 102400\0" = 12 bytes
  let header_len = 12
  assert_true(decompressed.length() == header_len + size)
  // Check first and last bytes
  assert_true(decompressed[header_len] == b'\x00')
  assert_true(decompressed[header_len + 255] == b'\xFF')
  assert_true(
    decompressed[header_len + size - 1] == ((size - 1) % 256).to_byte(),
  )
  let id2 = @git.hash_blob(bytes)
  assert_true(id == id2)
}

///|
test "blob integrity: zlib compress/decompress roundtrip" {
  // Test zlib roundtrip independently
  let original = Bytes::from_array([
    b'\x00', b'\x01', b'\x7F', b'\x80', b'\xFF', b'a', b'b', b'c',
  ])
  let compressed = @zlib.zlib_compress(original)
  let decompressed = @zlib.zlib_decompress(compressed)
  assert_true(decompressed.length() == original.length())
  for i = 0; i < original.length(); i = i + 1 {
    assert_true(decompressed[i] == original[i])
  }
}

///|
test "blob integrity: create_object and hash_object_content consistent" {
  // Verify create_object and hash_object_content produce same ID
  let data = Bytes::from_array([b'h', b'e', b'l', b'l', b'o'])
  let (id1, _) = @git.create_object(@git.ObjectType::Blob, data)
  let id2 = @git.hash_object_content(@git.ObjectType::Blob, data)
  assert_true(id1 == id2)
}

///|
test "blob integrity: repeated creation yields same ID" {
  // Verify idempotency
  let data = Bytes::from_array([b't', b'e', b's', b't'])
  let (id1, _) = @git.create_blob(data)
  let (id2, _) = @git.create_blob(data)
  let (id3, _) = @git.create_blob(data)
  assert_true(id1 == id2)
  assert_true(id2 == id3)
}

// =============================================================================
// ObjectId Tests (Additional)
// =============================================================================

///|
test "ObjectId: equality for same hex" {
  let hex = "ce013625030ba8dba906f756967f9e9ca394464a"
  let id1 = @git.ObjectId::from_hex(hex)
  let id2 = @git.ObjectId::from_hex(hex)
  assert_true(id1 == id2)
}

///|
test "ObjectId: inequality for different hex" {
  let id1 = @git.ObjectId::from_hex("ce013625030ba8dba906f756967f9e9ca394464a")
  let id2 = @git.ObjectId::from_hex("cc628ccd10742baea8241c5924df992b5c019f71")
  assert_true(id1 != id2)
}

// =============================================================================
// Git-Verified Binary Blob Hash Tests
// =============================================================================

///|
test "git compat: blob hash binary 0x00 0x01 0x7f 0x80 0xff" {
  // printf '\x00\x01\x7f\x80\xff' | git hash-object --stdin
  let data = Bytes::from_array([b'\x00', b'\x01', b'\x7F', b'\x80', b'\xFF'])
  let id = @git.hash_blob(data)
  inspect(id.to_hex(), content="3f841d7e56eef5a4d10f557d3db2228bb9948b2b")
}

///|
test "git compat: blob hash all 256 byte values" {
  // python3 -c 'import sys; sys.stdout.buffer.write(bytes(range(256)))' | git hash-object --stdin
  let data : Array[Byte] = []
  for i = 0; i < 256; i = i + 1 {
    data.push(i.to_byte())
  }
  let bytes = Bytes::from_array(FixedArray::makei(256, fn(i) { data[i] }))
  let id = @git.hash_blob(bytes)
  inspect(id.to_hex(), content="c86626638e0bc8cf47ca49bb1525b40e9737ee64")
}

// =============================================================================
// Object Roundtrip Tests (create -> compress -> decompress -> parse -> verify)
// =============================================================================

///|
/// Helper: parse header from raw loose object format "type size\0content"
/// Returns (type_str, content_start_index)
fn parse_loose_header(raw : Bytes) -> (String, Int) {
  let type_buf = StringBuilder::new()
  let mut i = 0
  // Read type until space
  while i < raw.length() && raw[i] != b' ' {
    type_buf.write_char(raw[i].to_int().unsafe_to_char())
    i += 1
  }
  i += 1 // skip space
  // Skip size digits until null byte
  while i < raw.length() && raw[i] != b'\x00' {
    i += 1
  }
  i += 1 // skip null byte
  (type_buf.to_string(), i)
}

///|
test "roundtrip: binary blob create -> compress -> decompress" {
  // Create blob with binary data including null bytes and high bytes
  let original = Bytes::from_array([
    b'\x00', b'\x01', b'\x7F', b'\x80', b'\xFE', b'\xFF',
  ])
  let (expected_id, compressed) = @git.create_blob(original)

  // Decompress
  let raw = @zlib.zlib_decompress(compressed)

  // Parse header
  let (type_str, content_start) = parse_loose_header(raw)

  // Verify type
  assert_true(type_str == "blob")

  // Extract content
  let content_len = raw.length() - content_start
  assert_true(content_len == original.length())

  // Verify every byte matches original
  for i = 0; i < original.length(); i = i + 1 {
    assert_true(raw[content_start + i] == original[i])
  }

  // Verify re-hashing gives same ID
  let computed_id = @git.hash_blob(original)
  assert_true(computed_id == expected_id)
}

///|
test "roundtrip: tree create -> compress -> decompress" {
  // Create tree
  let blob_id = @git.ObjectId::from_hex(
    "ce013625030ba8dba906f756967f9e9ca394464a",
  )
  let entries = [@git.TreeEntry::new("100644", "test.txt", blob_id)]
  let (expected_id, compressed) = @git.create_tree(entries)

  // Decompress
  let raw = @zlib.zlib_decompress(compressed)

  // Parse header
  let (type_str, content_start) = parse_loose_header(raw)
  assert_true(type_str == "tree")

  // Extract content
  let content_len = raw.length() - content_start
  let content = Bytes::from_array(
    FixedArray::makei(content_len, fn(i) { raw[content_start + i] }),
  )

  // Verify tree can be parsed
  let parsed_entries = @git.parse_tree(content)
  assert_true(parsed_entries.length() == 1)
  assert_true(parsed_entries[0].name == "test.txt")
  assert_true(parsed_entries[0].mode == "100644")
  assert_true(parsed_entries[0].id == blob_id)

  // Verify re-hashing gives same ID
  let computed_id = @git.hash_object_content(@git.ObjectType::Tree, content)
  assert_true(computed_id == expected_id)
}

///|
test "roundtrip: commit create -> compress -> decompress" {
  let tree_id = @git.ObjectId::from_hex(
    "88e38705fdbd3608cddbe904b67c731f3234c45b",
  )
  let commit = @git.Commit::new(
    tree_id,
    [],
    "Test <test@example.com>",
    1700000000L,
    "+0000",
    "Test <test@example.com>",
    1700000000L,
    "+0000",
    "Test commit\n",
  )
  let (expected_id, compressed) = @git.create_commit(commit)

  // Decompress
  let raw = @zlib.zlib_decompress(compressed)

  // Parse header
  let (type_str, content_start) = parse_loose_header(raw)
  assert_true(type_str == "commit")

  // Extract content
  let content_len = raw.length() - content_start
  let content = Bytes::from_array(
    FixedArray::makei(content_len, fn(i) { raw[content_start + i] }),
  )

  // Verify commit can be parsed
  let parsed = @git.parse_commit(content)
  assert_true(parsed.tree == tree_id)
  assert_true(parsed.parents.length() == 0)

  // Verify re-hashing gives same ID
  let computed_id = @git.hash_object_content(@git.ObjectType::Commit, content)
  assert_true(computed_id == expected_id)
}

// =============================================================================
// Tree Parsing Tests
// =============================================================================

///|
test "git compat: parse_tree single entry" {
  // Create tree and extract content
  let blob_id = @git.ObjectId::from_hex(
    "ce013625030ba8dba906f756967f9e9ca394464a",
  )
  let entries = [@git.TreeEntry::new("100644", "hello.txt", blob_id)]
  let (_, compressed) = @git.create_tree(entries)
  let raw = @zlib.zlib_decompress(compressed)
  let (_, content_start) = parse_loose_header(raw)
  let content = Bytes::from_array(
    FixedArray::makei(raw.length() - content_start, fn(i) {
      raw[content_start + i]
    }),
  )

  // Parse and verify
  let parsed = @git.parse_tree(content)
  assert_true(parsed.length() == 1)
  assert_true(parsed[0].mode == "100644")
  assert_true(parsed[0].name == "hello.txt")
  assert_true(parsed[0].id == blob_id)
}

///|
test "git compat: parse_tree multiple entries sorted" {
  // Create tree with multiple files
  let hello_id = @git.ObjectId::from_hex(
    "ce013625030ba8dba906f756967f9e9ca394464a",
  )
  let world_id = @git.ObjectId::from_hex(
    "cc628ccd10742baea8241c5924df992b5c019f71",
  )
  let entries = [
    @git.TreeEntry::new("100644", "hello.txt", hello_id),
    @git.TreeEntry::new("100644", "world.txt", world_id),
  ]
  let (_, compressed) = @git.create_tree(entries)
  let raw = @zlib.zlib_decompress(compressed)
  let (_, content_start) = parse_loose_header(raw)
  let content = Bytes::from_array(
    FixedArray::makei(raw.length() - content_start, fn(i) {
      raw[content_start + i]
    }),
  )

  // Parse and verify order is preserved
  let parsed = @git.parse_tree(content)
  assert_true(parsed.length() == 2)
  assert_true(parsed[0].name == "hello.txt")
  assert_true(parsed[1].name == "world.txt")
}

///|
test "git compat: parse_tree with directory entry" {
  // Tree with file and subdirectory
  let blob_id = @git.ObjectId::from_hex(
    "ce013625030ba8dba906f756967f9e9ca394464a",
  )
  let tree_id = @git.ObjectId::from_hex(
    "b032d4b998c65562e088abaa88fdd859476c089e",
  )
  let entries = [
    @git.TreeEntry::new("100644", "hello.txt", blob_id),
    @git.TreeEntry::new("40000", "subdir", tree_id),
  ]
  let (_, compressed) = @git.create_tree(entries)
  let raw = @zlib.zlib_decompress(compressed)
  let (_, content_start) = parse_loose_header(raw)
  let content = Bytes::from_array(
    FixedArray::makei(raw.length() - content_start, fn(i) {
      raw[content_start + i]
    }),
  )

  // Parse and verify
  let parsed = @git.parse_tree(content)
  assert_true(parsed.length() == 2)
  // Files and dirs should be in sorted order
  assert_true(parsed[0].name == "hello.txt")
  assert_true(parsed[0].mode == "100644")
  assert_true(parsed[1].name == "subdir")
  assert_true(parsed[1].mode == "40000")
}

///|
test "git compat: parse_tree with executable file" {
  // Tree with executable file (mode 100755)
  let blob_id = @git.ObjectId::from_hex(
    "ce013625030ba8dba906f756967f9e9ca394464a",
  )
  let entries = [@git.TreeEntry::new("100755", "script.sh", blob_id)]
  let (_, compressed) = @git.create_tree(entries)
  let raw = @zlib.zlib_decompress(compressed)
  let (_, content_start) = parse_loose_header(raw)
  let content = Bytes::from_array(
    FixedArray::makei(raw.length() - content_start, fn(i) {
      raw[content_start + i]
    }),
  )
  let parsed = @git.parse_tree(content)
  assert_true(parsed.length() == 1)
  assert_true(parsed[0].mode == "100755")
  assert_true(parsed[0].name == "script.sh")
}

// =============================================================================
// Commit Parsing Tests
// =============================================================================

///|
test "git compat: parse_commit initial commit" {
  // Create initial commit (no parents)
  let tree_id = @git.ObjectId::from_hex(
    "88e38705fdbd3608cddbe904b67c731f3234c45b",
  )
  let commit = @git.Commit::new(
    tree_id,
    [],
    "Author <author@example.com>",
    1700000000L,
    "+0000",
    "Committer <committer@example.com>",
    1700000100L,
    "+0900",
    "Initial commit\n",
  )
  let (_, compressed) = @git.create_commit(commit)
  let raw = @zlib.zlib_decompress(compressed)
  let (_, content_start) = parse_loose_header(raw)
  let content = Bytes::from_array(
    FixedArray::makei(raw.length() - content_start, fn(i) {
      raw[content_start + i]
    }),
  )
  let parsed = @git.parse_commit(content)
  assert_true(parsed.tree == tree_id)
  assert_true(parsed.parents.length() == 0)
}

///|
test "git compat: parse_commit with one parent" {
  let tree_id = @git.ObjectId::from_hex(
    "88e38705fdbd3608cddbe904b67c731f3234c45b",
  )
  let parent_id = @git.ObjectId::from_hex(
    "681226a87c4a64f59b7b47bd497af25e16ac4635",
  )
  let commit = @git.Commit::new(
    tree_id,
    [parent_id],
    "Test <test@example.com>",
    1700000100L,
    "+0000",
    "Test <test@example.com>",
    1700000100L,
    "+0000",
    "Second commit\n",
  )
  let (_, compressed) = @git.create_commit(commit)
  let raw = @zlib.zlib_decompress(compressed)
  let (_, content_start) = parse_loose_header(raw)
  let content = Bytes::from_array(
    FixedArray::makei(raw.length() - content_start, fn(i) {
      raw[content_start + i]
    }),
  )
  let parsed = @git.parse_commit(content)
  assert_true(parsed.tree == tree_id)
  assert_true(parsed.parents.length() == 1)
  assert_true(parsed.parents[0] == parent_id)
}

///|
test "git compat: parse_commit with merge (two parents)" {
  let tree_id = @git.ObjectId::from_hex(
    "88e38705fdbd3608cddbe904b67c731f3234c45b",
  )
  let parent1 = @git.ObjectId::from_hex(
    "681226a87c4a64f59b7b47bd497af25e16ac4635",
  )
  let parent2 = @git.ObjectId::from_hex(
    "2fe96b04b8c1f081765898435f0d2497cfef21ea",
  )
  let commit = @git.Commit::new(
    tree_id,
    [parent1, parent2],
    "Test <test@example.com>",
    1700000200L,
    "+0000",
    "Test <test@example.com>",
    1700000200L,
    "+0000",
    "Merge branch 'feature'\n",
  )
  let (_, compressed) = @git.create_commit(commit)
  let raw = @zlib.zlib_decompress(compressed)
  let (_, content_start) = parse_loose_header(raw)
  let content = Bytes::from_array(
    FixedArray::makei(raw.length() - content_start, fn(i) {
      raw[content_start + i]
    }),
  )
  let parsed = @git.parse_commit(content)
  assert_true(parsed.tree == tree_id)
  assert_true(parsed.parents.length() == 2)
  assert_true(parsed.parents[0] == parent1)
  assert_true(parsed.parents[1] == parent2)
}

// =============================================================================
// Delta Application Tests
// =============================================================================
// Git delta format:
// - source size (varint)
// - target size (varint)
// - instructions:
//   - Copy (bit 7 set): opcode byte has bitmask for which offset/size bytes follow
//     - bits 0-3: offset bytes present (0-4 bytes)
//     - bits 4-6: size bytes present (0-3 bytes)
//     - if size is 0 after reading, it means 0x10000
//   - Insert (bit 7 clear): opcode is length (1-127), followed by that many literal bytes

///|
test "git compat: delta copy instruction" {
  // Test delta that copies from base
  // Base: "hello world" (11 bytes)
  // Delta: copy all of base
  let base = Bytes::from_array([
    b'h', b'e', b'l', b'l', b'o', b' ', b'w', b'o', b'r', b'l', b'd',
  ])

  // Delta format for copying 11 bytes from offset 0:
  // opcode = 0x80 | 0x10 = 0x90 (copy, size byte 0 present)
  // Since offset is 0, no offset bytes needed
  // size byte 0 = 0x0b (11)
  let delta = Bytes::from_array([
      b'\x0b', // source size: 11
       b'\x0b', // target size: 11
       b'\x90', // copy: bit7=1 (copy), bit4=1 (size byte 0 present)
       b'\x0b',
    ], // size: 11
  )
  let result = @pack.apply_delta(base, delta)
  assert_true(result.length() == 11)
  for i = 0; i < base.length(); i = i + 1 {
    assert_true(result[i] == base[i])
  }
}

///|
test "git compat: delta insert instruction" {
  // Test delta that inserts new data
  // Base: "old" (3 bytes)
  // Delta: insert "new data" (ignore base completely)
  let base = Bytes::from_array([b'o', b'l', b'd'])

  // Delta format:
  // - source size: 3
  // - target size: 8 (length of "new data")
  // - insert instruction: 0x08 (insert 8 bytes), followed by "new data"
  let delta = Bytes::from_array([
    b'\x03', // source size: 3
     b'\x08', // target size: 8
     b'\x08', // insert 8 bytes (bit 7 clear, lower 7 bits = length)
     b'n', b'e', b'w', b' ', b'd', b'a', b't', b'a',
  ])
  let result = @pack.apply_delta(base, delta)
  assert_true(result.length() == 8)
  // Verify "new data"
  assert_true(result[0] == b'n')
  assert_true(result[1] == b'e')
  assert_true(result[2] == b'w')
  assert_true(result[3] == b' ')
  assert_true(result[4] == b'd')
  assert_true(result[5] == b'a')
  assert_true(result[6] == b't')
  assert_true(result[7] == b'a')
}

///|
test "git compat: delta mixed copy and insert" {
  // Base: "hello" (5 bytes)
  // Target: "hello world" (copy "hello", insert " world")
  let base = Bytes::from_array([b'h', b'e', b'l', b'l', b'o'])

  // Delta:
  // - source size: 5
  // - target size: 11
  // - copy 5 bytes from offset 0: opcode=0x90, size=5
  // - insert 6 bytes " world": opcode=0x06, then literal bytes
  let delta = Bytes::from_array([
    b'\x05', // source size: 5
     b'\x0b', // target size: 11
     b'\x90', // copy: bit7=1, bit4=1 (size byte 0 present)
     b'\x05', // size: 5
     b'\x06', // insert 6 bytes
     b' ', b'w', b'o', b'r', b'l', b'd',
  ])
  let result = @pack.apply_delta(base, delta)
  assert_true(result.length() == 11)
  // Check "hello world"
  assert_true(result[0] == b'h')
  assert_true(result[4] == b'o')
  assert_true(result[5] == b' ')
  assert_true(result[10] == b'd')
}

///|
test "git compat: delta copy with offset" {
  // Base: "hello world" (11 bytes)
  // Target: "world" (copy 5 bytes from offset 6)
  let base = Bytes::from_array([
    b'h', b'e', b'l', b'l', b'o', b' ', b'w', b'o', b'r', b'l', b'd',
  ])

  // Delta:
  // - source size: 11
  // - target size: 5
  // - copy 5 bytes from offset 6: opcode=0x91, offset=6, size=5
  //   (bit0=1: offset byte 0 present, bit4=1: size byte 0 present)
  let delta = Bytes::from_array([
      b'\x0b', // source size: 11
       b'\x05', // target size: 5
       b'\x91', // copy: bit7=1, bit0=1 (offset byte 0), bit4=1 (size byte 0)
       b'\x06', // offset: 6
       b'\x05',
    ], // size: 5
  )
  let result = @pack.apply_delta(base, delta)
  assert_true(result.length() == 5)
  // Check "world"
  assert_true(result[0] == b'w')
  assert_true(result[1] == b'o')
  assert_true(result[2] == b'r')
  assert_true(result[3] == b'l')
  assert_true(result[4] == b'd')
}

// =============================================================================
// Packfile Parsing Tests (git-generated)
// =============================================================================

///|
/// Helper: convert hex string to bytes
fn compat_hex_to_bytes(hex : String) -> Bytes {
  let result : Array[Byte] = []
  let mut i = 0
  while i < hex.length() {
    let high = compat_hex_digit_to_int(hex[i])
    let low = compat_hex_digit_to_int(hex[i + 1])
    result.push(((high << 4) | low).to_byte())
    i += 2
  }
  Bytes::from_array(FixedArray::makei(result.length(), fn(j) { result[j] }))
}

///|
fn compat_hex_digit_to_int(code : UInt16) -> Int {
  let c = code.to_int()
  if c >= '0'.to_int() && c <= '9'.to_int() {
    c - '0'.to_int()
  } else if c >= 'a'.to_int() && c <= 'f'.to_int() {
    c - 'a'.to_int() + 10
  } else if c >= 'A'.to_int() && c <= 'F'.to_int() {
    c - 'A'.to_int() + 10
  } else {
    0
  }
}

///|
test "git compat: parse git-generated packfile (single blob)" {
  // Packfile generated by: echo "hello" | git hash-object -w --stdin && git pack-objects --stdout
  // Contains blob "hello\n" (ce013625030ba8dba906f756967f9e9ca394464a)
  let packfile_hex = "5041434b000000020000000136789ccb48cdc9c9e70200084b021fde0412401f4a9e5f05411f44eaf9c86d46096746"
  let packfile = compat_hex_to_bytes(packfile_hex)

  // Verify header
  assert_true(packfile[0] == b'P')
  assert_true(packfile[1] == b'A')
  assert_true(packfile[2] == b'C')
  assert_true(packfile[3] == b'K')

  // Parse packfile
  let objects = @pack.parse_packfile(packfile)
  assert_true(objects.length() == 1)
  assert_true(objects[0].obj_type == @git.ObjectType::Blob)

  // Verify content
  let content = objects[0].data
  assert_true(content.length() == 6) // "hello\n"
  assert_true(content[0] == b'h')
  assert_true(content[1] == b'e')
  assert_true(content[2] == b'l')
  assert_true(content[3] == b'l')
  assert_true(content[4] == b'o')
  assert_true(content[5] == b'\n')

  // Verify hash matches expected
  let id = @git.hash_blob(content)
  inspect(id.to_hex(), content="ce013625030ba8dba906f756967f9e9ca394464a")
}

///|
test "git compat: packfile create and parse roundtrip" {
  // Create a blob object
  let content = Bytes::from_array([b't', b'e', b's', b't', b'\n'])
  let (blob_id, _) = @git.create_blob(content)
  let obj = @git.PackObject::new(@git.ObjectType::Blob, content)

  // Create packfile
  let packfile = @pack.create_packfile([obj])

  // Verify header
  assert_true(packfile[0] == b'P')
  assert_true(packfile[1] == b'A')
  assert_true(packfile[2] == b'C')
  assert_true(packfile[3] == b'K')

  // Parse back
  let parsed = @pack.parse_packfile(packfile)
  assert_true(parsed.length() == 1)
  assert_true(parsed[0].obj_type == @git.ObjectType::Blob)

  // Verify content preserved
  assert_true(parsed[0].data.length() == content.length())
  for i = 0; i < content.length(); i = i + 1 {
    assert_true(parsed[0].data[i] == content[i])
  }

  // Verify hash matches
  let parsed_id = @git.hash_blob(parsed[0].data)
  assert_true(parsed_id == blob_id)
}

///|
test "git compat: packfile with multiple objects roundtrip" {
  // Create multiple objects
  let blob1 = Bytes::from_array([b'a', b'\n'])
  let blob2 = Bytes::from_array([b'b', b'\n'])
  let obj1 = @git.PackObject::new(@git.ObjectType::Blob, blob1)
  let obj2 = @git.PackObject::new(@git.ObjectType::Blob, blob2)

  // Create packfile
  let packfile = @pack.create_packfile([obj1, obj2])

  // Verify object count in header
  assert_true(packfile[8] == b'\x00')
  assert_true(packfile[9] == b'\x00')
  assert_true(packfile[10] == b'\x00')
  assert_true(packfile[11] == b'\x02') // 2 objects

  // Parse back
  let parsed = @pack.parse_packfile(packfile)
  assert_true(parsed.length() == 2)
}

// =============================================================================
// Tree Sorting Edge Cases
// =============================================================================

///|
test "git compat: tree entry order preserved" {
  // create_tree preserves entry order (caller must sort)
  // Verify entries are written and read back in given order
  let blob_id = @git.ObjectId::from_hex(
    "ce013625030ba8dba906f756967f9e9ca394464a",
  )
  let tree_id = @git.ObjectId::from_hex(
    "b032d4b998c65562e088abaa88fdd859476c089e",
  )

  // Create tree with entries in specific order
  let entries = [
    @git.TreeEntry::new("100644", "aaa", blob_id),
    @git.TreeEntry::new("40000", "bbb", tree_id),
    @git.TreeEntry::new("100644", "ccc", blob_id),
  ]
  let (_, compressed) = @git.create_tree(entries)
  let raw = @zlib.zlib_decompress(compressed)
  let (_, content_start) = parse_loose_header(raw)
  let content = Bytes::from_array(
    FixedArray::makei(raw.length() - content_start, fn(i) {
      raw[content_start + i]
    }),
  )

  // Parse and verify order is preserved
  let parsed = @git.parse_tree(content)
  assert_true(parsed.length() == 3)
  assert_true(parsed[0].name == "aaa")
  assert_true(parsed[1].name == "bbb")
  assert_true(parsed[2].name == "ccc")
}

///|
test "git compat: tree special characters in filename" {
  // Test filenames with special characters
  let blob_id = @git.ObjectId::from_hex(
    "ce013625030ba8dba906f756967f9e9ca394464a",
  )

  // Files with special characters (but no null bytes or slashes)
  let entries = [
    @git.TreeEntry::new("100644", "file with spaces.txt", blob_id),
    @git.TreeEntry::new("100644", "file-with-dashes.txt", blob_id),
    @git.TreeEntry::new("100644", "file_with_underscores.txt", blob_id),
  ]

  // Should create tree without error
  let (_, compressed) = @git.create_tree(entries)
  let raw = @zlib.zlib_decompress(compressed)

  // Should parse back correctly
  let (_, content_start) = parse_loose_header(raw)
  let content = Bytes::from_array(
    FixedArray::makei(raw.length() - content_start, fn(i) {
      raw[content_start + i]
    }),
  )
  let parsed = @git.parse_tree(content)
  assert_true(parsed.length() == 3)
}

// =============================================================================
// Varint Encoding Tests
// =============================================================================

///|
test "git compat: varint encoding small values" {
  // Test encode_type_and_size for small values
  let out : Array[Byte] = []
  @pack.encode_type_and_size(3, 5, out) // type=blob, size=5

  // For size 5:
  // First byte: (type << 4) | (size & 0x0F) = (3 << 4) | 5 = 0x35
  // Since size fits in 4 bits, no continuation
  assert_true(out.length() == 1)
  assert_true(out[0] == b'\x35')
}

///|
test "git compat: varint encoding larger values" {
  // Test encode_type_and_size for values requiring continuation
  let out : Array[Byte] = []
  @pack.encode_type_and_size(3, 100, out) // type=blob, size=100

  // size=100 in binary: 0110 0100
  // First 4 bits of size: 0100 = 4
  // Remaining: 0110 = 6
  // First byte: 0x80 | (3 << 4) | 4 = 0x80 | 0x30 | 0x04 = 0xB4
  // Second byte: 6 (no continuation)
  assert_true(out.length() == 2)
  assert_true(out[0] == b'\xB4')
  assert_true(out[1] == b'\x06')
}

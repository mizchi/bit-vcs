///| Tests for upload-pack server implementation

///|
fn test_concat_bytes(chunks : Array[Bytes]) -> Bytes {
  let out : Array[Byte] = []
  for chunk in chunks {
    for b in chunk {
      out.push(b)
    }
  }
  Bytes::from_array(FixedArray::makei(out.length(), fn(i) { out[i] }))
}

///|
test "build_upload_pack_advertisement: empty repo" {
  let fs = @git.TestFs::new()
  ignore(try? init_repo(fs, "/repo"))
  let adv = build_upload_pack_advertisement(fs, "/repo")
  // Should have capabilities^{} line for empty repo
  let text = @utf8.decode_lossy(adv[:])
  assert_true(text.contains("capabilities^{}"))
  assert_true(text.contains("agent=git/moonbit"))
}

///|
test "build_upload_pack_advertisement: with refs" {
  let fs = @git.TestFs::new()
  ignore(try? init_repo(fs, "/repo"))
  // Create a commit to get a real ref
  fs.write_string("/repo/a.txt", "hello\n")
  add_paths(fs, fs, "/repo", ["a.txt"])
  let commit_id = commit(
    fs, fs, "/repo", "initial\n", "Test <t@example.com>", 1700000000L,
  )
  let adv = build_upload_pack_advertisement(fs, "/repo")
  let text = @utf8.decode_lossy(adv[:])
  assert_true(text.contains(commit_id.to_hex()))
  assert_true(text.contains("refs/heads/main"))
}

///|
test "parse_upload_pack_request: simple want" {
  // Build a simple want request
  let want_line = "want ce013625030ba8dba906f756967f9e9ca394464a\n"
  let req_bytes = test_concat_bytes([
    @git.pktline_encode(want_line),
    @git.pktline_flush(),
    @git.pktline_encode("done\n"),
  ])
  let req = parse_upload_pack_request(req_bytes)
  assert_true(req.wants.length() == 1)
  assert_true(
    req.wants[0].to_hex() == "ce013625030ba8dba906f756967f9e9ca394464a",
  )
  assert_true(req.done)
}

///|
test "parse_upload_pack_request: want with capabilities" {
  // Build a want request with capabilities
  let want_line = "want ce013625030ba8dba906f756967f9e9ca394464a\u0000ofs-delta side-band-64k\n"
  let req_bytes = test_concat_bytes([
    @git.pktline_encode(want_line),
    @git.pktline_flush(),
    @git.pktline_encode("done\n"),
  ])
  let req = parse_upload_pack_request(req_bytes)
  assert_true(req.wants.length() == 1)
  assert_true(req.capabilities.length() == 2)
  assert_true(req.capabilities[0] == "ofs-delta")
  assert_true(req.capabilities[1] == "side-band-64k")
}

///|
test "parse_upload_pack_request: multiple wants and haves" {
  let want1 = "want ce013625030ba8dba906f756967f9e9ca394464a\n"
  let want2 = "want cc628ccd10742baea8241c5924df992b5c019f71\n"
  let have1 = "have 88e38705fdbd3608cddbe904b67c731f3234c45b\n"
  let req_bytes = test_concat_bytes([
    @git.pktline_encode(want1),
    @git.pktline_encode(want2),
    @git.pktline_flush(),
    @git.pktline_encode(have1),
    @git.pktline_encode("done\n"),
  ])
  let req = parse_upload_pack_request(req_bytes)
  assert_true(req.wants.length() == 2)
  assert_true(req.haves.length() == 1)
  assert_true(req.done)
}

// Note: Oracle tests for upload-pack are in src/git_oracle_pack_test.mbt
// (main package) which has access to native-only features (@process, @fs).

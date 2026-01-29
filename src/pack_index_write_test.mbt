///| Pack index fixture tests (git index-pack output)

///|
fn read_fixture_bytes(path : String) -> Bytes raise {
  @fs.read_file_to_bytes(path) catch {
    e => fail("failed to read fixture: \{path} (\{e})")
  }
}

///|
fn assert_bytes_equal(actual : Bytes, expected : Bytes) -> Unit raise {
  if not(Bytes::equal(actual, expected)) {
    fail(
      "bytes mismatch: actual=\{actual.length()} expected=\{expected.length()}",
    )
  }
}

///|
fn assert_pack_idx_matches(pack_path : String, idx_path : String) -> Unit raise {
  let pack = read_fixture_bytes(pack_path)
  let expected = read_fixture_bytes(idx_path)
  let actual = build_pack_index(pack)
  assert_bytes_equal(actual, expected)
}

///|
test "pack index fixture: hello.pack" {
  assert_pack_idx_matches("src/fixtures/hello.pack", "src/fixtures/hello.idx")
}

///|
test "pack index fixture: oracle.pack" {
  assert_pack_idx_matches("src/fixtures/oracle.pack", "src/fixtures/oracle.idx")
}

///|
test "pack index fixture: oracle_deflate.pack" {
  assert_pack_idx_matches(
    "src/fixtures/oracle_deflate.pack", "src/fixtures/oracle_deflate.idx",
  )
}

///|
test "pack index fixture: oracle_delta.pack" {
  assert_pack_idx_matches(
    "src/fixtures/oracle_delta.pack", "src/fixtures/oracle_delta.idx",
  )
}

///|
test "pack index fixture: oracle_after_delta.pack" {
  assert_pack_idx_matches(
    "src/fixtures/oracle_after_delta.pack", "src/fixtures/oracle_after_delta.idx",
  )
}

///|
test "pack index fixture: oracle_thin_base.pack" {
  assert_pack_idx_matches(
    "src/fixtures/oracle_thin_base.pack", "src/fixtures/oracle_thin_base.idx",
  )
}

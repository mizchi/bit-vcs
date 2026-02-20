///|
test "update-index: normalize_update_index_path rejects traversal paths" {
  let bad_paths : Array[String] = ["..", "../a.txt", "/a.txt", "a/../../b.txt"]
  for p in bad_paths {
    assert_true(update_index_path_is_rejected(p))
  }
}

///|
fn update_index_path_is_rejected(path : String) -> Bool {
  let _ = normalize_update_index_path(path) catch { _ => return true }
  false
}

///|
test "update-index: parse_update_index_cacheinfo rejects bad paths" {
  let (blob_id, _) = @bitcore.create_blob_string("cacheinfo")
  assert_true(
    parse_update_index_cacheinfo("100644", blob_id.to_hex(), "../a.txt") is None,
  )
}

///|
test "update-index: parse_update_index_info_line rejects bad paths" {
  let (blob_id, _) = @bitcore.create_blob_string("info line")
  let line = "100644 " + blob_id.to_hex() + "\t../a.txt"
  assert_true(parse_update_index_info_line(line) is None)
}

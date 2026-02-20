///|
test "checkout: restore_paths rejects traversal pathspecs" {
  let fs = @bit.TestFs::new()
  init_repo(fs, "/repo")
  fs.write_string("/repo/a.txt", "hello\n")
  add_paths(fs, fs, "/repo", ["a.txt"])
  assert_true(restore_paths_is_rejected(fs, "/repo", ["../a.txt"]))
  assert_false(fs.is_file("/a.txt"))
  assert_true(fs.is_file("/repo/a.txt"))
}

///|
test "checkout: restore_paths rejects index paths outside repository" {
  let fs = @bit.TestFs::new()
  init_repo(fs, "/repo")
  let (blob_id, blob) = @bit.create_blob_string("outside.txt")
  let entries : Array[IndexEntry] = [
    IndexEntry::new("../outside.txt", blob_id, 33188, blob.length()),
  ]
  write_object_bytes(fs, "/repo/.git", blob_id, blob)
  write_index_entries(fs, "/repo/.git", entries)
  assert_true(restore_paths_is_rejected(fs, "/repo", ["a.txt"]))
}

///|
fn restore_paths_is_rejected(
  fs : @bit.TestFs,
  root : String,
  paths : Array[String],
) -> Bool {
  restore_paths(fs, fs, root, paths) catch {
    _ => return true
  }
  false
}

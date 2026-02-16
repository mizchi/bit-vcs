///|
test "ls-files: no wildcard filter matches exact path" {
  assert_true(ls_files_matches_filters("a.txt", ["a.txt"]))
  assert_true(not(ls_files_matches_filters("dir/b.txt", ["a.txt"])))
}

///|
test "ls-files: directory prefix filter works" {
  assert_true(ls_files_matches_filters("dir/a.txt", ["dir"]))
  assert_true(not(ls_files_matches_filters("other.txt", ["dir"])))
}

///|
test "ls-files: wildcard prefix filter" {
  let long_name = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  assert_true(ls_files_matches_filters(long_name, ["a*"]))
  assert_true(not(ls_files_matches_filters("b.txt", ["a*"])))
}

///|
test "ls-files: normalize keeps wildcard filter as-is" {
  assert_eq(normalize_ls_tree_filters(["a*"], ""), ["a*"])
}

///|
test "ls-files: wildcard filter matches index scan" {
  let entries = [ls_files_entry("a_long_path.txt"), ls_files_entry("other.txt")]
  assert_true(ls_files_filter_has_match("a*", entries))
  assert_true(not(ls_files_filter_has_match("b*", entries)))
}

///|
test "ls-files: compare directory and file suffix order" {
  assert_true(ls_files_compare_paths("path2-junk", "path2/") < 0)
  assert_true(ls_files_compare_paths("path2/", "path4/") < 0)
}

///|
test "ls-files: untracked directory compression" {
  assert_true(
    ls_files_is_within_untracked_dir("partially_tracked/untracked/file.txt", [
      "partially_tracked/untracked",
    ]),
  )
  assert_true(
    not(
      ls_files_is_within_untracked_dir("partially_tracked/tracked.txt", [
        "partially_tracked/untracked",
      ]),
    ),
  )
}

///|
test "ls-files: has matching file under directory" {
  let files = ["src/main.rs", "src/lib/main.rs", "readme.md"]
  let untracked : Map[String, Bool] = { "src/main.rs": true, "readme.md": true }
  assert_true(ls_files_has_matching_file("src", files, untracked))
  assert_true(not(ls_files_has_matching_file("tests", files, untracked)))
}

///|
fn ls_files_entry(path : String) -> @gitlib.IndexEntry {
  @gitlib.IndexEntry::new(
    path,
    @git.ObjectId::new(FixedArray::make(20, b'\x00')),
    0,
    0,
  )
}

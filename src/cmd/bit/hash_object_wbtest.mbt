///|

///|
test "hash-object: storage runtime routing follows parser support" {
  assert_false(hash_object_should_use_storage_runtime(["--stdin"]))
  assert_true(hash_object_should_use_storage_runtime(["-t", "blob", "a.txt"]))
  assert_false(hash_object_should_use_storage_runtime(["-t", "tree", "a.txt"]))

  assert_false(hash_object_should_use_storage_runtime(["--stdin-paths"]))
}

test "hash-object: fallback condition checks for autocrlf and gitattributes" {
  let fs = OsFs::new()
  let root =
    "/tmp/bit-test-hash-object-fallback-" + get_current_timestamp().to_string()
  fs.mkdir_p(root + "/.git")
  let cleanup = fn() {
    fs.remove_file(root + "/.gitattributes") catch {
      _ => ()
    }
    fs.remove_file(root + "/.git/config") catch {
      _ => ()
    }
    fs.remove_dir(root + "/.git") catch {
      _ => ()
    }
    fs.remove_dir(root) catch {
      _ => ()
    }
  }

  fs.write_file(
    root + "/.git/config",
    string_to_bytes("[core]\nautocrlf = true\n"),
  )
  assert_true(hash_object_need_real_git_for_autocrlf(root))

  fs.write_file(
    root + "/.git/config",
    string_to_bytes("[core]\nautocrlf = input\n"),
  )
  assert_true(hash_object_need_real_git_for_autocrlf(root))

  fs.write_file(
    root + "/.git/config",
    string_to_bytes("[core]\nautocrlf = false\n"),
  )
  assert_false(hash_object_need_real_git_for_autocrlf(root))

  fs.write_file(
    root + "/.git/config",
    string_to_bytes("[core]\nautocrlf = mixed\n"),
  )
  assert_true(hash_object_need_real_git_for_autocrlf(root))

  fs.write_file(root + "/.gitattributes", string_to_bytes("*.txt -text\n"))
  assert_true(hash_object_need_real_git_for_gitattributes(root))

  fs.write_file(root + "/.gitattributes", string_to_bytes("*.txt text\n"))
  assert_true(hash_object_need_real_git_for_gitattributes(root))

  fs.write_file(root + "/.gitattributes", string_to_bytes("*.txt eol=crlf\n"))
  assert_true(hash_object_need_real_git_for_gitattributes(root))

  fs.write_file(root + "/.gitattributes", string_to_bytes("*.txt filter=foo diff=bar\n"))
  assert_true(hash_object_need_real_git_for_gitattributes(root))

  fs.write_file(root + "/.gitattributes", string_to_bytes("# comment only\n   \n"))
  assert_false(hash_object_need_real_git_for_gitattributes(root))
  cleanup()
}

///|
test "doc: put_page validates nested names and rejects traversal" {
  let fs = @osfs.OsFs::new()
  let root = "/tmp/bit-test-doc-validate"
  cleanup_doc_test_root(fs, root)

  match put_page(fs, root, "wiki/setup", "ok") {
    Ok(page) => assert_eq(page, "wiki/setup")
    Err(_) => fail("expected nested page name to be valid")
  }
  match read_page(fs, root, "wiki/setup") {
    Ok(body) => assert_eq(body, "ok\n")
    Err(_) => fail("expected valid page to be readable")
  }
  for
    invalid in [
      "", ".", "..", "/abs", "a//b", "../x", "a/../b", "a\\b", "a\nb", "a\tb",
    ] {
    match put_page(fs, root, invalid, "x") {
      Ok(_) => fail("expected invalid page name to be rejected")
      Err(InvalidPageName(name)) => assert_eq(name, invalid)
      Err(_) => fail("expected InvalidPageName")
    }
  }

  cleanup_doc_test_root(fs, root)
}

///|
test "doc: list_pages reads recursive markdown pages with prefix filter" {
  let fs = @osfs.OsFs::new()
  let root = "/tmp/bit-test-doc-list"
  cleanup_doc_test_root(fs, root)
  fs.mkdir_p(root + "/.bit/docs/wiki")
  fs.mkdir_p(root + "/.bit/docs/daily")
  fs.write_string(root + "/.bit/docs/home.md", "# home\n")
  fs.write_string(root + "/.bit/docs/wiki/setup.md", "# setup\n")
  fs.write_string(root + "/.bit/docs/daily/2026-02-19.md", "# day\n")
  fs.write_string(root + "/.bit/docs/ignore.txt", "ignore\n")

  let pages = list_pages(fs, root, None)
  assert_eq(pages, ["daily/2026-02-19", "home", "wiki/setup"])

  let filtered = list_pages(fs, root, Some("wiki"))
  assert_eq(filtered, ["wiki/setup"])

  fs.remove_file(root + "/.bit/docs/home.md") catch {
    _ => ()
  }
  fs.remove_file(root + "/.bit/docs/wiki/setup.md") catch {
    _ => ()
  }
  fs.remove_file(root + "/.bit/docs/daily/2026-02-19.md") catch {
    _ => ()
  }
  fs.remove_file(root + "/.bit/docs/ignore.txt") catch {
    _ => ()
  }
  fs.remove_dir(root + "/.bit/docs/wiki") catch {
    _ => ()
  }
  fs.remove_dir(root + "/.bit/docs/daily") catch {
    _ => ()
  }
  fs.remove_dir(root + "/.bit/docs") catch {
    _ => ()
  }
  fs.remove_dir(root + "/.bit") catch {
    _ => ()
  }
  fs.remove_dir(root) catch {
    _ => ()
  }
}

///|
test "doc: put append remove updates docs storage" {
  let fs = @osfs.OsFs::new()
  let root = "/tmp/bit-test-doc-flow"
  cleanup_doc_test_root(fs, root)
  let page_path = root + "/.bit/docs/home.md"
  match put_page(fs, root, "home", "initial memo") {
    Ok(page) => assert_eq(page, "home")
    Err(_) => fail("expected put_page to succeed")
  }
  let initial = read_page(fs, root, "home")
  match initial {
    Ok(body) => assert_eq(body, "initial memo\n")
    Err(_) => fail("expected read_page to succeed")
  }

  match append_page(fs, fs, root, "home", "next line", 12345) {
    Ok(page) => assert_eq(page, "home")
    Err(_) => fail("expected append_page to succeed")
  }
  let appended = read_page(fs, root, "home")
  match appended {
    Ok(body) => {
      assert_true(body.contains("initial memo\n"))
      assert_true(body.contains("- [12345] next line\n"))
    }
    Err(_) => fail("expected appended page to exist")
  }

  match remove_page(fs, fs, root, "home") {
    Ok(page) => assert_eq(page, "home")
    Err(_) => fail("expected remove_page to succeed")
  }
  assert_false(fs.is_file(page_path))

  fs.remove_dir(root + "/.bit/docs") catch {
    _ => ()
  }
  fs.remove_dir(root + "/.bit") catch {
    _ => ()
  }
  fs.remove_dir(root) catch {
    _ => ()
  }
}

///|
fn cleanup_doc_test_root(fs : @osfs.OsFs, root : String) -> Unit {
  fs.remove_file(root + "/.bit/docs/home.md") catch {
    _ => ()
  }
  fs.remove_file(root + "/.bit/docs/wiki/setup.md") catch {
    _ => ()
  }
  fs.remove_file(root + "/.bit/docs/daily/2026-02-19.md") catch {
    _ => ()
  }
  fs.remove_file(root + "/.bit/docs/ignore.txt") catch {
    _ => ()
  }
  fs.remove_dir(root + "/.bit/docs/wiki") catch {
    _ => ()
  }
  fs.remove_dir(root + "/.bit/docs/daily") catch {
    _ => ()
  }
  fs.remove_dir(root + "/.bit/docs") catch {
    _ => ()
  }
  fs.remove_dir(root + "/.bit") catch {
    _ => ()
  }
  fs.remove_dir(root) catch {
    _ => ()
  }
}

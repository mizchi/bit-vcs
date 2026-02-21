///|
test "clone caps contain token: direct token word" {
  let caps = ["multi_ack thin-pack filter side-band-64k"]
  assert_true(clone_caps_contain_token(caps, "filter"))
}

///|
test "clone caps contain token: token with value" {
  let caps = ["filter=blob:none"]
  assert_true(clone_caps_contain_token(caps, "filter"))
}

///|
test "clone caps contain token: fetch equals token" {
  let caps = ["fetch=filter", "agent=git/2.45.0"]
  assert_true(clone_caps_contain_token(caps, "filter"))
}

///|
test "clone caps contain token: fetch embedded token list" {
  let caps = ["fetch=shallow deepen-since filter", "agent=git/2.45.0"]
  assert_true(clone_caps_contain_token(caps, "filter"))
}

///|
test "clone caps contain token: missing token" {
  let caps = ["multi_ack thin-pack", "fetch=shallow deepen-since"]
  assert_false(clone_caps_contain_token(caps, "filter"))
}

///|
test "clone local source file resolver: existing relative bundle path" {
  let fs = @bitcore.TestFs::new()
  fs.write_string("/work/repo/repo.bundle", "bundle")
  let resolved = resolve_local_clone_source_file(
    fs, "/work/repo", "repo.bundle",
  )
  assert_eq(resolved, Some("/work/repo/repo.bundle"))
}

///|
test "clone local source file resolver: file URL path" {
  let fs = @bitcore.TestFs::new()
  fs.write_string("/tmp/repo.bundle", "bundle")
  let resolved = resolve_local_clone_source_file(
    fs, "/work/repo", "file:///tmp/repo.bundle",
  )
  assert_eq(resolved, Some("/tmp/repo.bundle"))
}

///|
test "clone local source file resolver: remote URL is ignored" {
  let fs = @bitcore.TestFs::new()
  let resolved = resolve_local_clone_source_file(
    fs, "/work/repo", "https://example.com/repo.bundle",
  )
  assert_eq(resolved, None)
}

///|
test "clone bundle advanced compat requires local bundle path" {
  assert_true(
    clone_bundle_requires_advanced_compat(Some("/work/repo/repo.bundle")),
  )
  assert_false(
    clone_bundle_requires_advanced_compat(Some("/work/repo/not-bundle.git")),
  )
  assert_false(clone_bundle_requires_advanced_compat(None))
}

///|
test "clone reftable advanced compat depends on ref-format only" {
  assert_true(clone_ref_format_requires_advanced_compat("reftable"))
  assert_false(clone_ref_format_requires_advanced_compat("files"))
}

///|
test "clone relay: remote detection handles explicit relay schemes" {
  assert_true(clone_remote_uses_relay_signaling("relay+http://127.0.0.1:8788"))
  assert_true(
    clone_remote_uses_relay_signaling("relay+https://relay.example.com"),
  )
  assert_true(clone_remote_uses_relay_signaling("relay://relay.example.com"))
  assert_false(clone_remote_uses_relay_signaling("https://relay.example.com"))
  assert_false(
    clone_remote_uses_relay_signaling("git@github.com:mizchi/bit.git"),
  )
}

///|
test "clone relay: select preferred sender when available" {
  let peers : Array[(String, String, String?)] = [
    ("node-a", "http://node-a:9418/repo.git", Some("repo-a")),
    ("node-b", "http://node-b:9418/repo.git", Some("repo-b")),
  ]
  let selected = clone_select_relay_peer(
    peers,
    preferred_sender=Some("node-b"),
    preferred_repo=None,
  )
  assert_eq(selected, Some(("node-b", "http://node-b:9418/repo.git")))
}

///|
test "clone relay: fallback to first sender when preferred missing" {
  let peers : Array[(String, String, String?)] = [
    ("node-a", "http://node-a:9418/repo.git", Some("repo-a")),
    ("node-b", "http://node-b:9418/repo.git", Some("repo-b")),
  ]
  let selected = clone_select_relay_peer(
    peers,
    preferred_sender=Some("node-z"),
    preferred_repo=None,
  )
  assert_eq(selected, Some(("node-a", "http://node-a:9418/repo.git")))
}

///|
test "clone relay: no peers returns none" {
  let peers : Array[(String, String, String?)] = []
  let selected = clone_select_relay_peer(
    peers,
    preferred_sender=None,
    preferred_repo=None,
  )
  assert_eq(selected, None)
}

///|
test "clone relay: preferred sender env is trimmed and optional" {
  @sys.set_env_var("BIT_RELAY_CLONE_SENDER", " node-preferred ")
  assert_eq(clone_relay_preferred_sender(), Some("node-preferred"))
  @sys.set_env_var("BIT_RELAY_CLONE_SENDER", "   ")
  assert_eq(clone_relay_preferred_sender(), None)
  @sys.unset_env_var("BIT_RELAY_CLONE_SENDER")
  assert_eq(clone_relay_preferred_sender(), None)
}

///|
test "clone relay: preferred repo env is trimmed and optional" {
  @sys.set_env_var("BIT_RELAY_CLONE_REPO", " repo-b ")
  assert_eq(clone_relay_preferred_repo(), Some("repo-b"))
  @sys.set_env_var("BIT_RELAY_CLONE_REPO", "   ")
  assert_eq(clone_relay_preferred_repo(), None)
  @sys.unset_env_var("BIT_RELAY_CLONE_REPO")
  assert_eq(clone_relay_preferred_repo(), None)
}

///|
test "clone relay: preferred repo selects matching peer" {
  let peers : Array[(String, String, String?)] = [
    ("node-a", "http://node-a:9418/repo-a.git", Some("repo-a")),
    ("node-b", "http://node-b:9418/repo-b.git", Some("repo-b")),
  ]
  let selected = clone_select_relay_peer(
    peers,
    preferred_sender=None,
    preferred_repo=Some("repo-b"),
  )
  assert_eq(selected, Some(("node-b", "http://node-b:9418/repo-b.git")))
}

///|
test "clone relay: sender filter is applied before repo filter" {
  let peers : Array[(String, String, String?)] = [
    ("node-a", "http://node-a:9418/repo-a.git", Some("repo-a")),
    ("node-b", "http://node-b:9418/repo-b.git", Some("repo-b")),
  ]
  let selected = clone_select_relay_peer(
    peers,
    preferred_sender=Some("node-a"),
    preferred_repo=Some("repo-b"),
  )
  assert_eq(selected, Some(("node-a", "http://node-a:9418/repo-a.git")))
}

///|
fn cleanup_clone_wbtest_tree(fs : OsFs, path : String) -> Unit {
  if fs.is_file(path) {
    fs.remove_file(path) catch {
      _ => ()
    }
    return
  }
  if not(fs.is_dir(path)) {
    return
  }
  let entries = fs.readdir(path) catch { _ => [] }
  for entry in entries {
    if entry == "." || entry == ".." {
      continue
    }
    cleanup_clone_wbtest_tree(fs, path + "/" + entry)
  }
  fs.remove_dir(path) catch {
    _ => ()
  }
}

///|
test "clone: configure_reftable_ref_storage writes reftable metadata" {
  let fs = OsFs::new()
  let root = "/tmp/bit-clone-reftable-" + get_current_timestamp().to_string()
  cleanup_clone_wbtest_tree(fs, root)
  fs.mkdir_p(root)
  fs.write_string(root + "/config", "[core]\n\trepositoryformatversion = 0\n")
  configure_reftable_ref_storage(fs, root) catch {
    err => fail("unexpected error: \{err}")
  }
  assert_true(fs.is_dir(root + "/reftable"))
  assert_true(fs.is_file(root + "/reftable/tables.list"))
  let config = decode_bytes(fs.read_file(root + "/config"))
  assert_true(config.contains("[extensions]"))
  assert_true(config.contains("refStorage = reftable"))
  cleanup_clone_wbtest_tree(fs, root)
}

///|
async test "clone: run_postclone_hook is no-op when hook is absent" {
  let fs = OsFs::new()
  let root = "/tmp/bit-test-postclone-noop-" +
    get_current_timestamp().to_string()
  cleanup_clone_wbtest_tree(fs, root)
  let git_dir = root + "/.git"
  fs.mkdir_p(git_dir + "/hooks")
  run_postclone_hook(fs, fs, root, git_dir, false) catch {
    err => fail("unexpected error: \{err}")
  }
  cleanup_clone_wbtest_tree(fs, root)
}

///|
async test "clone: run_postclone_hook remains skipped without hook file even with approval cache" {
  let fs = OsFs::new()
  let root = "/tmp/bit-test-postclone-skip-with-cache-" +
    get_current_timestamp().to_string()
  let git_dir = root + "/.git"
  cleanup_clone_wbtest_tree(fs, root)
  fs.mkdir_p(git_dir + "/hooks")
  fs.write_string(git_dir + "/hooks/postclone", "#!/bin/sh\necho executed\n")
  let checksum = hooks_active_checksum(fs, root, "postclone").unwrap_or("")
  hooks_write_approved_checksum(fs, fs, root, "postclone", checksum)
  fs.remove_file(git_dir + "/hooks/postclone") catch {
    _ => ()
  }
  run_postclone_hook(fs, fs, root, git_dir, false) catch {
    err => fail("unexpected error: \{err}")
  }
  assert_false(fs.is_file(root + "/postclone-marker"))
  cleanup_clone_wbtest_tree(fs, root)
}

///|
async test "clone: run_postclone_hook skips execution when skip-hooks is enabled" {
  let fs = OsFs::new()
  let root = "/tmp/bit-test-postclone-skip-hook-" +
    get_current_timestamp().to_string()
  let git_dir = root + "/.git"
  cleanup_clone_wbtest_tree(fs, root)
  fs.mkdir_p(git_dir + "/hooks")
  fs.write_string(
    git_dir + "/hooks/postclone",
    "#!/bin/sh\necho should_not_run > \"" + root + "/postclone-marker\"\n",
  )
  let checksum = hooks_active_checksum(fs, root, "postclone").unwrap_or("")
  hooks_write_approved_checksum(fs, fs, root, "postclone", checksum)
  run_postclone_hook(fs, fs, root, git_dir, true) catch {
    err => fail("unexpected error: \{err}")
  }
  assert_false(fs.is_file(root + "/postclone-marker"))
  cleanup_clone_wbtest_tree(fs, root)
}

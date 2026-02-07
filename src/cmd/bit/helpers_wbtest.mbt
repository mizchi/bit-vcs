///|
test "helpers: resolve_git_dir falls back to bare repo when GIT_DIR points missing .git" {
  let fs = OsFs::new()
  let root = "/tmp/bit-test-resolve-git-dir-bare-" +
    get_current_timestamp().to_string()
  fs.mkdir_p(root + "/objects")
  fs.write_string(root + "/HEAD", "ref: refs/heads/main\n")
  let prev_git_dir = @sys.get_env_var("GIT_DIR")
  @sys.set_env_var("GIT_DIR", root + "/.git")
  let resolved = resolve_git_dir(fs, root)
  assert_eq(resolved, root)
  match prev_git_dir {
    Some(value) => @sys.set_env_var("GIT_DIR", value)
    None => @sys.unset_env_var("GIT_DIR")
  }
  fs.remove_file(root + "/HEAD") catch {
    _ => ()
  }
  fs.remove_dir(root + "/objects") catch {
    _ => ()
  }
  fs.remove_dir(root) catch {
    _ => ()
  }
}

///|
test "helpers: find_repo_root detects .bit repository marker" {
  let fs = OsFs::new()
  let root = "/tmp/bit-test-find-repo-root-bit-" +
    get_current_timestamp().to_string()
  let nested = root + "/a/b/c"
  fs.mkdir_p(root + "/.bit/objects")
  fs.write_string(root + "/.bit/HEAD", "ref: refs/heads/main\n")
  fs.mkdir_p(nested)
  let found = find_repo_root(nested)
  match found {
    Some(path) => assert_eq(path, root)
    None => fail("expected .bit repo root")
  }
  fs.remove_file(root + "/.bit/HEAD") catch {
    _ => ()
  }
  fs.remove_dir(root + "/.bit/objects") catch {
    _ => ()
  }
  fs.remove_dir(root + "/.bit") catch {
    _ => ()
  }
  fs.remove_dir(root + "/a/b/c") catch {
    _ => ()
  }
  fs.remove_dir(root + "/a/b") catch {
    _ => ()
  }
  fs.remove_dir(root + "/a") catch {
    _ => ()
  }
  fs.remove_dir(root) catch {
    _ => ()
  }
}

///|
test "helpers: resolve_git_dir prefers .bit when present" {
  let fs = OsFs::new()
  let root = "/tmp/bit-test-resolve-git-dir-bit-" +
    get_current_timestamp().to_string()
  fs.mkdir_p(root + "/.bit")
  let prev_git_dir = @sys.get_env_var("GIT_DIR")
  @sys.unset_env_var("GIT_DIR")
  let resolved = resolve_git_dir(fs, root)
  assert_eq(resolved, root + "/.bit")
  match prev_git_dir {
    Some(value) => @sys.set_env_var("GIT_DIR", value)
    None => @sys.unset_env_var("GIT_DIR")
  }
  fs.remove_dir(root + "/.bit") catch {
    _ => ()
  }
  fs.remove_dir(root) catch {
    _ => ()
  }
}

///|
test "helpers: resolve_git_dir keeps explicit GIT_DIR even if .bit exists" {
  let fs = OsFs::new()
  let root = "/tmp/bit-test-resolve-git-dir-explicit-" +
    get_current_timestamp().to_string()
  fs.mkdir_p(root + "/.bit")
  fs.mkdir_p(root + "/custom-meta")
  let prev_git_dir = @sys.get_env_var("GIT_DIR")
  @sys.set_env_var("GIT_DIR", root + "/custom-meta")
  let resolved = resolve_git_dir(fs, root)
  assert_eq(resolved, root + "/custom-meta")
  match prev_git_dir {
    Some(value) => @sys.set_env_var("GIT_DIR", value)
    None => @sys.unset_env_var("GIT_DIR")
  }
  fs.remove_dir(root + "/custom-meta") catch {
    _ => ()
  }
  fs.remove_dir(root + "/.bit") catch {
    _ => ()
  }
  fs.remove_dir(root) catch {
    _ => ()
  }
}

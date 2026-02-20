///|
test "hooks: is_valid_hook_name validates simple names" {
  assert_true(is_valid_hook_name("pre-add"))
  assert_true(is_valid_hook_name("post-add"))
  assert_true(is_valid_hook_name("hook_name"))
  assert_true(is_valid_hook_name("postclone"))
  assert_false(is_valid_hook_name(""))
  assert_false(is_valid_hook_name("."))
  assert_false(is_valid_hook_name(".."))
  assert_false(is_valid_hook_name("path/to/name"))
  assert_false(is_valid_hook_name("path\\to\\name"))
  assert_false(is_valid_hook_name("with space"))
}

///|
test "hooks: list_hooks sorts and filters installed hooks" {
  let fs = OsFs::new()
  let root = "/tmp/bit-test-hooks-list-" + get_current_timestamp().to_string()
  let git_dir = root + "/.git"
  fs.mkdir_p(git_dir + "/hooks")
  fs.write_string(git_dir + "/hooks/pre-add", "#!/bin/sh\n")
  fs.write_string(git_dir + "/hooks/post-add", "#!/bin/sh\n")
  fs.write_string(git_dir + "/hooks/pre-commit", "#!/bin/sh\n")
  let all = list_hooks(fs, git_dir, None)
  assert_eq(all, ["pre-add", "post-add", "pre-commit"])
  let filtered = list_hooks(fs, git_dir, Some("pre"))
  assert_eq(filtered, ["pre-add", "pre-commit"])

  fs.remove_file(git_dir + "/hooks/pre-add") catch {
    _ => ()
  }
  fs.remove_file(git_dir + "/hooks/post-add") catch {
    _ => ()
  }
  fs.remove_file(git_dir + "/hooks/pre-commit") catch {
    _ => ()
  }
  fs.remove_dir(git_dir + "/hooks") catch {
    _ => ()
  }
  fs.remove_dir(git_dir) catch {
    _ => ()
  }
  fs.remove_dir(root) catch {
    _ => ()
  }
}

///|
test "hooks: list_hooks_with_status merges .git/hooks and .bit/hooks" {
  let fs = OsFs::new()
  let root = "/tmp/bit-test-hooks-list-status-" +
    get_current_timestamp().to_string()
  let git_dir = root + "/.git"
  fs.mkdir_p(git_dir + "/hooks")
  fs.mkdir_p(root + "/.bit/hooks")
  fs.write_string(root + "/.bit/hooks/pre-add", "#!/bin/sh\n")
  fs.write_string(git_dir + "/hooks/post-applypatch", "#!/bin/sh\n")
  fs.write_string(git_dir + "/hooks/pre-add", "#!/bin/sh\n")
  let status = list_hooks_with_status(fs, root, git_dir, None)
  assert_eq(status, [
    "pre-add (available, enabled)", "post-applypatch (enabled)",
  ])
  let filtered = list_hooks_with_status(fs, root, git_dir, Some("pre"))
  assert_eq(filtered, ["pre-add (available, enabled)"])

  fs.remove_file(root + "/.bit/hooks/pre-add") catch {
    _ => ()
  }
  fs.remove_file(git_dir + "/hooks/post-applypatch") catch {
    _ => ()
  }
  fs.remove_file(git_dir + "/hooks/pre-add") catch {
    _ => ()
  }
  fs.remove_dir(git_dir + "/hooks") catch {
    _ => ()
  }
  fs.remove_dir(git_dir) catch {
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
async test "hooks: set registers available hook and approve/unapprove operate independently" {
  let fs = OsFs::new()
  let root = "/tmp/bit-test-hooks-flow-" + get_current_timestamp().to_string()
  let git_dir = root + "/.git"
  fs.mkdir_p(root)
  fs.mkdir_p(git_dir)
  let source = root + "/source-hook"
  fs.write_string(source, "#!/bin/sh\necho test\n")
  handle_x_hooks_set(fs, root, ["pre-commit", source])
  assert_true(fs.is_file(root + "/.bit/hooks/pre-commit"))
  handle_x_hooks_approve(fs, root, git_dir, ["pre-commit"])
  assert_true(fs.is_file(git_dir + "/hooks/pre-commit"))
  handle_x_hooks_unapprove(fs, git_dir, ["pre-commit"])
  assert_false(fs.is_file(git_dir + "/hooks/pre-commit"))
  handle_x_hooks_remove(fs, root, ["pre-commit"])
  assert_false(fs.is_file(root + "/.bit/hooks/pre-commit"))

  fs.remove_file(source) catch {
    _ => ()
  }
  fs.remove_dir(git_dir) catch {
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
test "hooks: hooks_is_current_checksum_approved monitors sensitive hook modifications" {
  let fs = OsFs::new()
  let root = "/tmp/bit-test-hooks-sensitive-check-" +
    get_current_timestamp().to_string()
  let git_dir = root + "/.git"
  fs.mkdir_p(git_dir + "/hooks")
  fs.mkdir_p(root + "/.bit")
  fs.write_string(git_dir + "/hooks/post-checkout", "#!/bin/sh\necho pre\n")
  let rfs : &@bitcore.RepoFileSystem = fs
  assert_false(hooks_is_current_checksum_approved(rfs, root, "post-checkout"))
  let checksum = hooks_active_checksum(rfs, root, "post-checkout").unwrap_or("")
  hooks_write_approved_checksum(fs, fs, root, "post-checkout", checksum)
  assert_true(hooks_is_current_checksum_approved(rfs, root, "post-checkout"))
  fs.write_string(git_dir + "/hooks/post-checkout", "#!/bin/sh\necho updated\n")
  assert_false(hooks_is_current_checksum_approved(rfs, root, "post-checkout"))
  fs.write_string(git_dir + "/hooks/post-commit", "#!/bin/sh\necho always\n")
  assert_true(hooks_is_current_checksum_approved(rfs, root, "post-commit"))

  fs.remove_file(git_dir + "/hooks/post-checkout") catch {
    _ => ()
  }
  fs.remove_file(git_dir + "/hooks/post-commit") catch {
    _ => ()
  }
  fs.remove_dir(git_dir + "/hooks") catch {
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
async test "hooks: approving sensitive hook writes approved checksum metadata" {
  let fs = OsFs::new()
  let root = "/tmp/bit-test-hooks-sensitive-approve-" +
    get_current_timestamp().to_string()
  let git_dir = root + "/.git"
  fs.mkdir_p(root)
  fs.mkdir_p(git_dir)
  let source = root + "/source-hook"
  fs.write_string(source, "#!/bin/sh\necho approved\n")
  handle_x_hooks_set(fs, root, ["post-merge", source])
  handle_x_hooks_approve(fs, root, git_dir, ["post-merge"])
  let approved = hooks_read_approved_checksum(fs, root, "post-merge").unwrap_or(
    "",
  )
  let rfs : &@bitcore.RepoFileSystem = fs
  let active = hooks_active_checksum(rfs, root, "post-merge").unwrap_or("")
  assert_eq(approved, active)
  assert_true(hooks_is_current_checksum_approved(rfs, root, "post-merge"))

  fs.write_string(git_dir + "/hooks/post-merge", "#!/bin/sh\necho modified\n")
  assert_false(hooks_is_current_checksum_approved(rfs, root, "post-merge"))

  handle_x_hooks_unapprove(fs, git_dir, ["post-merge"])
  handle_x_hooks_remove(fs, root, ["post-merge"])
  fs.remove_file(source) catch {
    _ => ()
  }
  fs.remove_dir(git_dir) catch {
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
test "hooks: always requiring user approval works for postclone" {
  let fs = OsFs::new()
  let root = "/tmp/bit-test-hooks-postclone-approve-" +
    get_current_timestamp().to_string()
  let git_dir = root + "/.git"
  fs.mkdir_p(git_dir + "/hooks")
  fs.mkdir_p(root + "/.bit")
  fs.write_string(git_dir + "/hooks/postclone", "#!/bin/sh\necho hi\n")
  let rfs : &@bitcore.RepoFileSystem = fs
  let checksum = hooks_active_checksum(rfs, root, "postclone").unwrap_or("")
  hooks_write_approved_checksum(fs, fs, root, "postclone", checksum)
  assert_false(hooks_is_current_checksum_approved(rfs, root, "postclone"))

  fs.remove_file(git_dir + "/hooks/postclone") catch {
    _ => ()
  }
  fs.remove_dir(git_dir + "/hooks") catch {
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
test "hooks: postclone is considered sensitive and always prompt" {
  assert_true(is_sensitive_hook("postclone"))
  assert_true(is_always_prompt_hook("postclone"))
}

///|
test "hooks: postinstall is considered sensitive and always prompt" {
  assert_true(is_sensitive_hook("postinstall"))
  assert_true(is_always_prompt_hook("postinstall"))
}

///|
async test "hooks: approving postinstall still requires approval on every run" {
  let fs = OsFs::new()
  let root = "/tmp/bit-test-hooks-postinstall-approve-no-persist-" +
    get_current_timestamp().to_string()
  let git_dir = root + "/.git"
  fs.mkdir_p(root)
  fs.mkdir_p(git_dir)
  let source = root + "/source-hook"
  fs.write_string(source, "#!/bin/sh\necho hi\n")
  handle_x_hooks_set(fs, root, ["postinstall", source])
  handle_x_hooks_approve(fs, root, git_dir, ["postinstall"])
  assert_true(fs.is_file(git_dir + "/hooks/postinstall"))
  let rfs : &@bitcore.RepoFileSystem = fs
  assert_false(hooks_is_current_checksum_approved(rfs, root, "postinstall"))
  match hooks_read_approved_checksum(fs, root, "postinstall") {
    Some(_) => ()
    None =>
      fail(
        "expected approval checksum to be recorded for enabled sensitive hook",
      )
  }

  handle_x_hooks_unapprove(fs, git_dir, ["postinstall"])
  handle_x_hooks_remove(fs, root, ["postinstall"])
  fs.remove_file(source) catch {
    _ => ()
  }
  fs.remove_dir(git_dir) catch {
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
test "hooks: postinstall never becomes auto-approved by checksum" {
  let fs = OsFs::new()
  let root = "/tmp/bit-test-hooks-postinstall-approve-" +
    get_current_timestamp().to_string()
  let git_dir = root + "/.git"
  fs.mkdir_p(git_dir + "/hooks")
  fs.mkdir_p(root + "/.bit")
  fs.write_string(git_dir + "/hooks/postinstall", "#!/bin/sh\necho hi\n")
  let rfs : &@bitcore.RepoFileSystem = fs
  let checksum = hooks_active_checksum(rfs, root, "postinstall").unwrap_or("")
  hooks_write_approved_checksum(fs, fs, root, "postinstall", checksum)
  assert_false(hooks_is_current_checksum_approved(rfs, root, "postinstall"))

  fs.remove_file(git_dir + "/hooks/postinstall") catch {
    _ => ()
  }
  fs.remove_dir(git_dir + "/hooks") catch {
    _ => ()
  }
  fs.remove_dir(root + "/.bit") catch {
    _ => ()
  }
  fs.remove_dir(root) catch {
    _ => ()
  }
}

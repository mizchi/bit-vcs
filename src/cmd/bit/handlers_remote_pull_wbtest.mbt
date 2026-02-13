///|
test "pull: detect submodule replaced by file" {
  let from_modes : Map[String, Int] = {}
  from_modes["sub1"] = 0o160000
  let to_modes : Map[String, Int] = {}
  to_modes["sub1"] = 0o100644
  let replaced = find_submodule_replaced_with_non_submodule(
    from_modes, to_modes,
  )
  assert_eq(replaced, Some("sub1"))
}

///|
test "pull: do not flag submodule removal" {
  let from_modes : Map[String, Int] = {}
  from_modes["sub1"] = 0o160000
  let to_modes : Map[String, Int] = {}
  let replaced = find_submodule_replaced_with_non_submodule(
    from_modes, to_modes,
  )
  assert_eq(replaced, None)
}

///|
test "pull: initial head target uses current branch ref" {
  let target = resolve_initial_pull_head_target(Some("main"))
  assert_eq(target, "refs/heads/main")
}

///|
test "pull: initial head target uses detached HEAD" {
  let target = resolve_initial_pull_head_target(None)
  assert_eq(target, "HEAD")
}

///|
test "fetch transport: http url uses http transport" {
  let transport = resolve_upload_pack_transport(
    "https://github.com/mizchi/bit-vcs.git",
  )
  assert_true(
    match transport {
      UploadPackTransport::Http => true
      _ => false
    },
  )
}

///|
test "fetch transport: scp style ssh url uses process transport" {
  let transport = resolve_upload_pack_transport(
    "git@github.com:mizchi/bit-vcs.git",
  )
  assert_true(
    match transport {
      UploadPackTransport::Process => true
      _ => false
    },
  )
}

///|
test "fetch transport: file path uses process transport" {
  let transport = resolve_upload_pack_transport("/tmp/example-repo")
  assert_true(
    match transport {
      UploadPackTransport::Process => true
      _ => false
    },
  )
}

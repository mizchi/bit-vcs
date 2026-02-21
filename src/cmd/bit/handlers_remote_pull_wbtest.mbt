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

///|
test "pull relay: remote detection handles explicit relay schemes" {
  assert_true(pull_remote_uses_relay_signaling("relay+http://127.0.0.1:8788"))
  assert_true(
    pull_remote_uses_relay_signaling("relay+https://relay.example.com"),
  )
  assert_true(pull_remote_uses_relay_signaling("relay://relay.example.com"))
  assert_false(
    pull_remote_uses_relay_signaling("https://relay.example.com/repo.git"),
  )
  assert_false(
    pull_remote_uses_relay_signaling("git@github.com:mizchi/bit.git"),
  )
}

///|
test "pull relay: preferred sender/repo env is trimmed and optional" {
  let prev_sender = @sys.get_env_var("BIT_RELAY_PULL_SENDER")
  let prev_repo = @sys.get_env_var("BIT_RELAY_PULL_REPO")
  @sys.set_env_var("BIT_RELAY_PULL_SENDER", " node-a ")
  @sys.set_env_var("BIT_RELAY_PULL_REPO", " repo-b ")
  assert_eq(pull_relay_preferred_sender(), Some("node-a"))
  assert_eq(pull_relay_preferred_repo(), Some("repo-b"))
  @sys.set_env_var("BIT_RELAY_PULL_SENDER", "   ")
  @sys.set_env_var("BIT_RELAY_PULL_REPO", "   ")
  assert_eq(pull_relay_preferred_sender(), None)
  assert_eq(pull_relay_preferred_repo(), None)
  restore_env_var_for_fetch_wbtest("BIT_RELAY_PULL_SENDER", prev_sender)
  restore_env_var_for_fetch_wbtest("BIT_RELAY_PULL_REPO", prev_repo)
}

///|
test "pull relay: sender filter is preferred over repo filter" {
  let peers : Array[(String, String, String?)] = [
    ("node-a", "http://node-a:9418/repo-a.git", Some("repo-a")),
    ("node-b", "http://node-b:9418/repo-b.git", Some("repo-b")),
  ]
  let selected = pull_select_relay_peer(
    peers,
    preferred_sender=Some("node-a"),
    preferred_repo=Some("repo-b"),
  )
  assert_eq(selected, Some(("node-a", "http://node-a:9418/repo-a.git")))
}

///|
test "pull relay: falls back to repo and then first peer" {
  let peers : Array[(String, String, String?)] = [
    ("node-a", "http://node-a:9418/repo-a.git", Some("repo-a")),
    ("node-b", "http://node-b:9418/repo-b.git", Some("repo-b")),
  ]
  let by_repo = pull_select_relay_peer(
    peers,
    preferred_sender=Some("node-z"),
    preferred_repo=Some("repo-b"),
  )
  assert_eq(by_repo, Some(("node-b", "http://node-b:9418/repo-b.git")))
  let first = pull_select_relay_peer(
    peers,
    preferred_sender=None,
    preferred_repo=Some("repo-z"),
  )
  assert_eq(first, Some(("node-a", "http://node-a:9418/repo-a.git")))
}

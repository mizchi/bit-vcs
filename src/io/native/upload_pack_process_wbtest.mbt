///|
fn restore_env_var_for_upload_pack_process_wbtest(
  name : String,
  prev : String?,
) -> Unit {
  match prev {
    Some(value) => @sys.set_env_var(name, value)
    None => @sys.unset_env_var(name)
  }
}

///|
test "upload-pack process: info-refs over ssh keeps ssh command" {
  let prev_ssh_command = @sys.get_env_var("GIT_SSH_COMMAND")
  let prev_ssh = @sys.get_env_var("GIT_SSH")
  @sys.unset_env_var("GIT_SSH_COMMAND")
  @sys.unset_env_var("GIT_SSH")
  let spec = build_upload_pack_info_refs_process_spec(
    "git@github.com:mizchi/bit-vcs.git", true,
  )
  assert_eq(spec.cmd, "ssh")
  assert_true(spec.args.length() >= 2)
  let remote_cmd = spec.args[spec.args.length() - 1]
  assert_true(remote_cmd.contains("git-upload-pack 'mizchi/bit-vcs.git'"))
  match spec.extra_env {
    Some(extra) => assert_eq(extra.get("GIT_PROTOCOL"), Some("version=2"))
    None => fail("expected GIT_PROTOCOL for prefer_v2")
  }
  restore_env_var_for_upload_pack_process_wbtest(
    "GIT_SSH_COMMAND", prev_ssh_command,
  )
  restore_env_var_for_upload_pack_process_wbtest("GIT_SSH", prev_ssh)
}

///|
test "upload-pack process: request over ssh keeps ssh command" {
  let prev_ssh_command = @sys.get_env_var("GIT_SSH_COMMAND")
  let prev_ssh = @sys.get_env_var("GIT_SSH")
  @sys.unset_env_var("GIT_SSH_COMMAND")
  @sys.unset_env_var("GIT_SSH")
  let spec = build_upload_pack_request_process_spec(
    "git@github.com:mizchi/bit-vcs.git", true,
  )
  assert_eq(spec.cmd, "ssh")
  assert_true(spec.args.length() >= 2)
  let remote_cmd = spec.args[spec.args.length() - 1]
  assert_true(remote_cmd.contains("git-upload-pack 'mizchi/bit-vcs.git'"))
  assert_false(remote_cmd.contains("--advertise-refs"))
  match spec.extra_env {
    Some(extra) => assert_eq(extra.get("GIT_PROTOCOL"), Some("version=2"))
    None => fail("expected GIT_PROTOCOL for prefer_v2")
  }
  restore_env_var_for_upload_pack_process_wbtest(
    "GIT_SSH_COMMAND", prev_ssh_command,
  )
  restore_env_var_for_upload_pack_process_wbtest("GIT_SSH", prev_ssh)
}

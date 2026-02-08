///|
test "shell: parse upload-pack command with quoted path" {
  match shell_parse_service_command("git-upload-pack '.'") {
    Some((service, path)) => {
      assert_eq(service, "git-upload-pack")
      assert_eq(path, ".")
    }
    None => assert_true(false)
  }
}

///|
test "shell: parse service command defaults to current dir" {
  match shell_parse_service_command("git-receive-pack") {
    Some((service, path)) => {
      assert_eq(service, "git-receive-pack")
      assert_eq(path, ".")
    }
    None => assert_true(false)
  }
}

///|
test "shell: reject unsupported command line" {
  let parsed = shell_parse_service_command("git config foo.bar baz")
  assert_eq(parsed, None)
}

///|
test "shell: interactive command parser splits name and args" {
  let (name, args) = shell_parse_interactive_command("ping arg1 arg2")
  assert_eq(name, "ping")
  assert_eq(args.length(), 2)
  assert_eq(args[0], "arg1")
  assert_eq(args[1], "arg2")
}

///|
test "shell: interactive command name safety" {
  assert_true(shell_is_safe_interactive_name("ping"))
  assert_false(shell_is_safe_interactive_name("../ping"))
  assert_false(shell_is_safe_interactive_name("foo/bar"))
}

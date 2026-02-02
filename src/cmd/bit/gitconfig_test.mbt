///| Tests for gitconfig alias parsing and expansion

///|
test "parse alias section from gitconfig" {
  let content =
    #|[core]
    #|  editor = vim
    #|[alias]
    #|  co = checkout
    #|  st = status -sb
    #|  lg = "log --oneline"
    #|  shell = "!echo hello"
    #|
  let aliases = parse_gitconfig_aliases(content)
  assert_eq(aliases["co"], "checkout")
  assert_eq(aliases["st"], "status -sb")
  assert_eq(aliases["lg"], "log --oneline")
  assert_eq(aliases["shell"], "!echo hello")
  assert_eq(aliases.get("editor"), None)
}

///|
test "resolve alias expands args" {
  let aliases : Map[String, String] = {}
  aliases.set("st", "status -sb")
  match resolve_alias(aliases, "st", ["-u"]) {
    Resolved(cmd, rest) => {
      assert_eq(cmd, "status")
      assert_eq(rest.length(), 2)
      assert_eq(rest[0], "-sb")
      assert_eq(rest[1], "-u")
    }
    Shell(_) => fail("unexpected shell alias")
  }
}

///|
test "resolve alias keeps quoted args together" {
  let aliases : Map[String, String] = {}
  aliases.set("pretty", "log --pretty=\"%h %s\"")
  match resolve_alias(aliases, "pretty", []) {
    Resolved(cmd, rest) => {
      assert_eq(cmd, "log")
      assert_eq(rest.length(), 1)
      assert_eq(rest[0], "--pretty=%h %s")
    }
    Shell(_) => fail("unexpected shell alias")
  }
}

///|
test "resolve alias reports shell alias" {
  let aliases : Map[String, String] = {}
  aliases.set("sh", "!echo hi")
  match resolve_alias(aliases, "sh", []) {
    Resolved(_, _) => fail("expected shell alias")
    Shell(cmdline) => assert_eq(cmdline, "echo hi")
  }
}

///|
/// Tests for gitignore pattern matching
test "parse simple patterns" {
  let rules = @ignore.parse("*.txt\nnode_modules/\n", "")
  assert_eq(rules.length(), 2)
  assert_eq(rules[0].pattern, "*.txt")
  assert_eq(rules[0].dir_only, false)
  assert_eq(rules[1].pattern, "node_modules")
  assert_eq(rules[1].dir_only, true)
}

///|
test "parse negation" {
  let rules = @ignore.parse("*.log\n!important.log\n", "")
  assert_eq(rules.length(), 2)
  assert_eq(rules[0].negated, false)
  assert_eq(rules[1].negated, true)
  assert_eq(rules[1].pattern, "important.log")
}

///|
test "parse anchored patterns" {
  let rules = @ignore.parse("/build\n*.o\n", "")
  assert_eq(rules.length(), 2)
  assert_eq(rules[0].anchored, true)
  assert_eq(rules[0].pattern, "build")
  assert_eq(rules[1].anchored, false)
}

///|
test "parse comments and empty lines" {
  let rules = @ignore.parse("# comment\n\n*.txt\n  \n", "")
  assert_eq(rules.length(), 1)
  assert_eq(rules[0].pattern, "*.txt")
}

///|
test "parse escaped characters" {
  let rules = @ignore.parse("\\!important\n\\#hash\n", "")
  assert_eq(rules.length(), 2)
  assert_eq(rules[0].pattern, "!important")
  assert_eq(rules[0].negated, false)
  assert_eq(rules[1].pattern, "#hash")
}

///|
test "match_glob simple" {
  assert_true(@ignore.match_glob("*.txt", "file.txt"))
  assert_true(@ignore.match_glob("*.txt", "a.txt"))
  assert_false(@ignore.match_glob("*.txt", "file.log"))
  assert_false(@ignore.match_glob("*.txt", "txt"))
}

///|
test "match_glob question mark" {
  assert_true(@ignore.match_glob("file?.txt", "file1.txt"))
  assert_true(@ignore.match_glob("file?.txt", "fileA.txt"))
  assert_false(@ignore.match_glob("file?.txt", "file10.txt"))
  assert_false(@ignore.match_glob("file?.txt", "file.txt"))
}

///|
test "match_glob multiple wildcards" {
  assert_true(@ignore.match_glob("*.min.*", "app.min.js"))
  assert_true(@ignore.match_glob("*.min.*", "lib.min.css"))
  assert_false(@ignore.match_glob("*.min.*", "app.js"))
}

///|
test "matcher basic" {
  let m = @ignore.Matcher::new()
  m.add_rules("", "*.log\nnode_modules/\n")
  assert_true(m.is_ignored("debug.log", false))
  assert_true(m.is_ignored("logs/error.log", false))
  assert_true(m.is_ignored("node_modules", true))
  assert_true(m.is_ignored("node_modules/pkg/index.js", false))
  assert_false(m.is_ignored("src/main.js", false))
}

///|
test "matcher negation" {
  let m = @ignore.Matcher::new()
  m.add_rules("", "*.log\n!important.log\n")
  assert_true(m.is_ignored("debug.log", false))
  assert_false(m.is_ignored("important.log", false))
}

///|
test "matcher anchored pattern" {
  let m = @ignore.Matcher::new()
  m.add_rules("", "/build\n")
  assert_true(m.is_ignored("build", true))
  assert_false(m.is_ignored("src/build", true))
}

///|
test "matcher with base" {
  let m = @ignore.Matcher::new()
  m.add_rules("src", "*.bak\n")
  assert_true(m.is_ignored("src/file.bak", false))
  assert_false(m.is_ignored("file.bak", false))
  assert_false(m.is_ignored("other/file.bak", false))
}

///|
test "matcher double star" {
  let m = @ignore.Matcher::new()
  m.add_rules("", "**/test\n")
  assert_true(m.is_ignored("test", true))
  assert_true(m.is_ignored("src/test", true))
  assert_true(m.is_ignored("src/pkg/test", true))
}

///|
test "matcher truncate" {
  let m = @ignore.Matcher::new()
  m.add_rules("", "*.txt\n")
  let len = m.len()
  m.add_rules("src", "*.bak\n")
  assert_true(m.is_ignored("src/file.bak", false))
  m.truncate(len)
  assert_false(m.is_ignored("src/file.bak", false))
  assert_true(m.is_ignored("file.txt", false))
}

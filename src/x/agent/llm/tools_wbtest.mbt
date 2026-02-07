///| Tests for tool registry

///|
test "tool registry has 7 tools" {
  let env = TestToolEnvironment::new()
  let registry = create_tool_registry(env)
  let defs = registry.get_defs()
  assert_eq(defs.length(), 7)
}

///|
test "read_file tool returns content" {
  let env = TestToolEnvironment::new()
  env.files["hello.txt"] = "hello"
  let registry = create_tool_registry(env)
  let (result, is_error) = registry.execute("read_file", { "path": "hello.txt" })
  assert_false(is_error)
  assert_eq(result, "hello")
}

///|
test "write_file tool creates file" {
  let env = TestToolEnvironment::new()
  let registry = create_tool_registry(env)
  let (result, is_error) = registry.execute("write_file", {
    "path": "new.txt",
    "content": "world",
  })
  assert_false(is_error)
  assert_eq(result, "ok")
  assert_eq(env.files.get("new.txt"), Some("world"))
}

///|
test "remove_file tool removes file" {
  let env = TestToolEnvironment::new()
  env.files["old.txt"] = "data"
  let registry = create_tool_registry(env)
  let (result, is_error) = registry.execute("remove_file", { "path": "old.txt" })
  assert_false(is_error)
  assert_eq(result, "ok")
  assert_true(env.removed.contains("old.txt"))
  assert_true(env.files.get("old.txt") is None)
}

///|
test "list_directory tool" {
  let env = TestToolEnvironment::new()
  env.files["src/a.mbt"] = "a"
  env.files["src/b.mbt"] = "b"
  let registry = create_tool_registry(env)
  let (result, is_error) = registry.execute("list_directory", { "path": "src" })
  assert_false(is_error)
  assert_true(result.contains("a.mbt"))
  assert_true(result.contains("b.mbt"))
}

///|
test "search_text tool" {
  let env = TestToolEnvironment::new()
  env.files["main.mbt"] = "fn main() { println(\"hello\") }"
  env.files["lib.mbt"] = "fn helper() { 42 }"
  let registry = create_tool_registry(env)
  let (result, is_error) = registry.execute("search_text", {
    "pattern": "println",
  })
  assert_false(is_error)
  assert_true(result.contains("main.mbt"))
}

///|
test "run_command tool" {
  let env = TestToolEnvironment::new()
  env.commands["echo hello"] = "hello"
  let registry = create_tool_registry(env)
  let (result, is_error) = registry.execute("run_command", {
    "command": "echo hello",
  })
  assert_false(is_error)
  assert_eq(result, "hello")
}

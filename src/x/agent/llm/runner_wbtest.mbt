///| Tests for runner utility functions

///|
test "extract_json_array valid" {
  let result = extract_json_array("[\"a\",\"b\"]")
  assert_eq(result.length(), 2)
  assert_eq(result[0], "a")
  assert_eq(result[1], "b")
}

///|
test "extract_json_array from text" {
  let result = extract_json_array("Here: [\"x\"] end")
  assert_eq(result.length(), 1)
  assert_eq(result[0], "x")
}

///|
test "extract_json_array invalid" {
  let result = extract_json_array("no json")
  assert_eq(result.length(), 0)
}

///|
test "build_system_prompt" {
  let prompt = build_system_prompt("/tmp/work", "fix the bug")
  assert_true(prompt.contains("/tmp/work"))
  assert_true(prompt.contains("fix the bug"))
}

///|
test "strip_trailing_whitespace" {
  assert_eq(strip_trailing_whitespace("hello  \n"), "hello")
  assert_eq(strip_trailing_whitespace("abc"), "abc")
  assert_eq(strip_trailing_whitespace("  "), "")
}

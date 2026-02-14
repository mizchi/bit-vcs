///|
test "grep filter: fixed treats dot literally" {
  assert_false(
    grep_patterns_match_message(
      "(1|2)",
      ["..."],
      GrepPatternType::Fixed,
      false,
    ),
  )
}

///|
test "grep filter: basic treats dot as wildcard" {
  assert_true(
    grep_patterns_match_message(
      "(1|2)",
      ["..."],
      GrepPatternType::Basic,
      false,
    ),
  )
}

///|
test "grep filter: ignore-case works for fixed mode" {
  assert_true(
    grep_patterns_match_message(
      "Second",
      ["sec"],
      GrepPatternType::Fixed,
      true,
    ),
  )
}

///|

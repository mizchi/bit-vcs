///| Tests for runner utility functions

///|
test "extract_subtask_plans with object format" {
  let text =
    #|[{"task": "Add tests for A", "files": ["a_test.mbt"]}, {"task": "Add tests for B", "files": ["b_test.mbt"]}]
  let plans = extract_subtask_plans(text)
  assert_eq(plans.length(), 2)
  assert_eq(plans[0].task, "Add tests for A")
  assert_eq(plans[0].files.length(), 1)
  assert_eq(plans[0].files[0], "a_test.mbt")
  assert_eq(plans[1].task, "Add tests for B")
}

///|
test "extract_subtask_plans with legacy string format" {
  let text =
    #|["task A", "task B"]
  let plans = extract_subtask_plans(text)
  assert_eq(plans.length(), 2)
  assert_eq(plans[0].task, "task A")
  assert_eq(plans[0].files.length(), 0)
}

///|
test "extract_subtask_plans from text with surrounding content" {
  let plans = extract_subtask_plans(
    "Here is the plan: [{\"task\": \"fix\", \"files\": []}] done",
  )
  assert_eq(plans.length(), 1)
  assert_eq(plans[0].task, "fix")
}

///|
test "extract_subtask_plans invalid" {
  let plans = extract_subtask_plans("no json here")
  assert_eq(plans.length(), 0)
}

///|
test "validate_file_overlap detects conflict" {
  let plans : Array[SubtaskPlan] = [
    { task: "A", files: ["shared.mbt", "a.mbt"] },
    { task: "B", files: ["shared.mbt", "b.mbt"] },
  ]
  let conflicts = validate_file_overlap(plans)
  assert_eq(conflicts.length(), 1)
  assert_true(conflicts[0].contains("shared.mbt"))
}

///|
test "validate_file_overlap no conflict" {
  let plans : Array[SubtaskPlan] = [
    { task: "A", files: ["a.mbt"] },
    { task: "B", files: ["b.mbt"] },
  ]
  let conflicts = validate_file_overlap(plans)
  assert_eq(conflicts.length(), 0)
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

///|
test "build_system_prompt contains workflow phases" {
  let prompt = build_system_prompt("/tmp/work", "test task")
  assert_true(prompt.contains("Phase 1"))
  assert_true(prompt.contains("Phase 2"))
  assert_true(prompt.contains("Phase 3"))
  assert_true(prompt.contains("Phase 4"))
  assert_true(prompt.contains("Phase 5"))
  assert_true(prompt.contains("Implement"))
  assert_true(prompt.contains("Verify"))
}

///|
test "build_system_prompt contains anti-patterns" {
  let prompt = build_system_prompt("/tmp/work", "test task")
  assert_true(prompt.contains("Do NOT"))
  assert_true(prompt.contains("Anti-patterns"))
}

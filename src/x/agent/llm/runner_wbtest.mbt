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

///|
test "run_auto_commit_steps stops on checkout failure" {
  let calls : Array[String] = []
  let logs = StringBuilder::new()
  let ok = run_auto_commit_steps(
    "/repo",
    "agent/test",
    "msg",
    fn(cmd) {
      calls.push(cmd)
      if calls.length() == 1 {
        "ERROR: exit code 1: checkout failed"
      } else {
        ""
      }
    },
    fn(s) { logs.write_string(s + "\n") },
  )
  assert_false(ok)
  assert_eq(calls.length(), 1)
  assert_true(logs.to_string().contains("git checkout -b"))
}

///|
test "run_auto_commit_steps stops on git add failure" {
  let calls : Array[String] = []
  let ok = run_auto_commit_steps(
    "/repo",
    "agent/test",
    "msg",
    fn(cmd) {
      calls.push(cmd)
      if calls.length() == 2 {
        "ERROR: exit code 1: add failed"
      } else {
        ""
      }
    },
    fn(_s) {  },
  )
  assert_false(ok)
  assert_eq(calls.length(), 2)
}

///|
test "run_auto_commit_steps succeeds when all commands succeed" {
  let calls : Array[String] = []
  let ok = run_auto_commit_steps(
    "/repo",
    "agent/test",
    "msg",
    fn(cmd) {
      calls.push(cmd)
      ""
    },
    fn(_s) {  },
  )
  assert_true(ok)
  assert_eq(calls.length(), 3)
}

///|
test "evaluate_agent_stop_reason handles external cancellation" {
  let reason = evaluate_agent_stop_reason(true, 100, 101, 900, 0, 60, false)
  assert_eq(reason, Some("cancel:requested"))
}

///|
test "evaluate_agent_stop_reason stops on runtime budget exceeded" {
  let reason = evaluate_agent_stop_reason(false, 100, 201, 100, 0, 60, false)
  assert_eq(reason, Some("budget:max_runtime_sec"))
}

///|
test "evaluate_agent_stop_reason stops on tool call budget exceeded" {
  let reason = evaluate_agent_stop_reason(false, 100, 120, 900, 61, 60, false)
  assert_eq(reason, Some("budget:max_tool_calls"))
}

///|
test "evaluate_agent_stop_reason stops on stop file trigger" {
  let reason = evaluate_agent_stop_reason(false, 100, 120, 900, 10, 60, true)
  assert_eq(reason, Some("cancel:stop_file"))
}

///|
test "evaluate_agent_stop_reason keeps running within budget" {
  let reason = evaluate_agent_stop_reason(false, 100, 120, 900, 10, 60, false)
  assert_eq(reason, None)
}

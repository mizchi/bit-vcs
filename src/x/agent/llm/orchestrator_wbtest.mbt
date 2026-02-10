///| Tests for orchestrator command failure handling

///|
test "exec_checked returns none and logs on command error" {
  let logs = StringBuilder::new()
  let result = exec_checked(
    "dummy",
    "worktree add",
    fn(_cmd) { "ERROR: exit code 1: boom" },
    fn(s) { logs.write_string(s + "\n") },
  )
  assert_true(result is None)
  let out = logs.to_string()
  assert_true(out.contains("worktree add"))
  assert_true(out.contains("ERROR: exit code 1"))
}

///|
test "exec_checked returns output on success" {
  let result = exec_checked("dummy", "status", fn(_cmd) { "ok\n" }, fn(_s) {  })
  assert_eq(result, Some("ok\n"))
}

///|
test "normalize_planned_file_path converts absolute path under work_dir" {
  let got = normalize_planned_file_path(
    "/tmp/bit-orch-debug/src/a.txt", "/tmp/bit-orch-debug",
  )
  assert_eq(got, Some("src/a.txt"))
}

///|
test "normalize_planned_file_path rejects absolute path outside work_dir" {
  let got = normalize_planned_file_path("/etc/passwd", "/tmp/bit-orch-debug")
  assert_eq(got, None)
}

///|
test "normalize_subtask_plans unifies absolute/relative path for overlap check" {
  let plans : Array[SubtaskPlan] = [
    { task: "edit a", files: ["/tmp/bit-orch-debug/src/a.txt"] },
    { task: "edit a again", files: ["src/a.txt"] },
  ]
  let normalized = normalize_subtask_plans(plans, "/tmp/bit-orch-debug", fn(
    _s,
  ) {

  })
  let conflicts = validate_file_overlap(normalized)
  assert_eq(conflicts, ["src/a.txt (subtask 0 and 1)"])
}

///|
test "select_bit_binary prefers BIT_PATH env" {
  let got = select_bit_binary(
    "/custom/bit", "/tmp/_build/bit_cli.exe", "/usr/local/bin/bit",
  )
  assert_eq(got, "/custom/bit")
}

///|
test "select_bit_binary prefers argv0 when it is a bit binary" {
  let got = select_bit_binary(
    "", "/tmp/_build/native/release/build/bit_cli/bit_cli.exe", "/usr/local/bin/bit",
  )
  assert_eq(got, "/tmp/_build/native/release/build/bit_cli/bit_cli.exe")
}

///|
test "select_bit_binary falls back to which bit for non-bit argv0" {
  let got = select_bit_binary("", "moon", "/usr/local/bin/bit")
  assert_eq(got, "/usr/local/bin/bit")
}

///|
test "parse_orchestrator_exec_mode parses known aliases" {
  assert_true(parse_orchestrator_exec_mode("process") == ProcessMode)
  assert_true(parse_orchestrator_exec_mode("local") == ProcessMode)
  assert_true(parse_orchestrator_exec_mode("in-process") == InProcessMode)
  assert_true(parse_orchestrator_exec_mode("self") == InProcessMode)
  assert_true(parse_orchestrator_exec_mode("cloudflare") == CloudflareMode)
  assert_true(
    parse_orchestrator_exec_mode("cloudflare-static") == CloudflareMode,
  )
  assert_true(
    parse_orchestrator_exec_mode("cloudflare-static-deno") == CloudflareMode,
  )
  assert_true(parse_orchestrator_exec_mode("deno-remote") == CloudflareMode)
  assert_true(parse_orchestrator_exec_mode("remote") == CloudflareMode)
}

///|
test "parse_orchestrator_exec_mode falls back to process for unknown values" {
  assert_true(parse_orchestrator_exec_mode("") == ProcessMode)
  assert_true(parse_orchestrator_exec_mode("weird") == ProcessMode)
}

///|
test "normalize_orchestrator_submit_url accepts endpoint and base url" {
  assert_eq(
    normalize_orchestrator_submit_url(
      "https://cluster.example.com/api/v1/jobs/submit",
    ),
    Some("https://cluster.example.com/api/v1/jobs/submit"),
  )
  assert_eq(
    normalize_orchestrator_submit_url("https://cluster.example.com"),
    Some("https://cluster.example.com/api/v1/jobs/submit"),
  )
  assert_eq(
    normalize_orchestrator_submit_url("https://cluster.example.com/"),
    Some("https://cluster.example.com/api/v1/jobs/submit"),
  )
}

///|
test "normalize_orchestrator_submit_url rejects empty value" {
  assert_eq(normalize_orchestrator_submit_url(""), None)
  assert_eq(normalize_orchestrator_submit_url("   "), None)
}

///|
test "cloudflare_job_status_url rewrites submit endpoint to job endpoint" {
  assert_eq(
    cloudflare_job_status_url(
      "https://cluster.example.com/api/v1/jobs/submit", "job-123",
    ),
    "https://cluster.example.com/api/v1/jobs/job-123",
  )
}

///|
test "subtask_task_for_agent appends file scope" {
  let plain : SubtaskPlan = { task: "implement feature", files: [] }
  assert_eq(subtask_task_for_agent(plain), "implement feature")
  let scoped : SubtaskPlan = {
    task: "refactor parser",
    files: ["src/parser.mbt", "src/parser_test.mbt"],
  }
  assert_eq(
    subtask_task_for_agent(scoped),
    "refactor parser (files: src/parser.mbt, src/parser_test.mbt)",
  )
  assert_eq(
    subtask_display(scoped),
    "refactor parser [files: src/parser.mbt, src/parser_test.mbt]",
  )
}

///|
test "create_cloudflare_payload includes files and static-check policy" {
  let config : OrchestratorConfig = {
    work_dir: "/tmp/repo",
    task: "top-level task",
    provider_name: "openrouter",
    model: "moonshot/kimi-k2.5",
    max_workers: 4,
    max_runtime_sec: 600,
    max_tool_calls: 200,
    stop_file: ".bit-stop",
    target_branch: "main",
    auto_pr: true,
    verbose: false,
    exec_mode: CloudflareMode,
    orchestrator_url: "https://cluster.example.com",
    orchestrator_token: "token",
  }
  let payload = create_cloudflare_payload(
    config,
    "session-1",
    "agent-0",
    "agent/session-1-0",
    "update tests",
    ["src/a.mbt", "src/a_test.mbt"],
  )
  match payload {
    Object(obj) => {
      assert_eq(obj.get("objective_id"), Some("session-1/agent-0".to_json()))
      assert_eq(obj.get("task"), Some("update tests".to_json()))
      assert_eq(
        obj.get("files"),
        Some(Json::array(["src/a.mbt".to_json(), "src/a_test.mbt".to_json()])),
      )
      assert_eq(obj.get("branch"), Some("agent/session-1-0".to_json()))
      assert_eq(obj.get("static_check_only"), Some(Json::boolean(true)))
      assert_eq(obj.get("execution_backend"), Some("deno-worker".to_json()))
      assert_eq(obj.get("execution_runtime"), Some("deno".to_json()))
    }
    _ => assert_true(false)
  }
}

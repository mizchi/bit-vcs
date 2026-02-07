///| Tests for coordination utility functions

///|
test "AgentStatus round-trip" {
  let statuses : Array[AgentStatus] = [
    Pending,
    Running,
    Done,
    Failed,
    Cancelled,
  ]
  for status in statuses {
    let s = status.to_string()
    let parsed = AgentStatus::parse(s)
    assert_true(status == parsed)
  }
}

///|
test "coord_event_to_json StepCompleted" {
  let json = coord_event_to_json(StepCompleted(step=3, tools_called=5))
  assert_true(json.contains("\"type\":\"step_completed\""))
  assert_true(json.contains("\"step\":3"))
  assert_true(json.contains("\"tools_called\":5"))
}

///|
test "coord_event_to_json Error" {
  let json = coord_event_to_json(Error(message="test \"error\""))
  assert_true(json.contains("\"type\":\"error\""))
  assert_true(json.contains("test \\\"error\\\""))
}

///|
test "evaluate_progress AllDone" {
  let snapshots : Array[AgentSnapshot] = [
    {
      agent_id: "a-0",
      status: Done,
      pid: 100,
      step: 5,
      branch: "b0",
      last_step_time: 100L,
    },
    {
      agent_id: "a-1",
      status: Done,
      pid: 101,
      step: 3,
      branch: "b1",
      last_step_time: 100L,
    },
  ]
  let decision = evaluate_progress(snapshots, "/tmp/fake", 200L, fn(_s) {  })
  assert_true(decision is AllDone)
}

///|
test "evaluate_progress Continue" {
  let snapshots : Array[AgentSnapshot] = [
    {
      agent_id: "a-0",
      status: Running,
      pid: 100,
      step: 2,
      branch: "b0",
      last_step_time: 190L,
    },
  ]
  let decision = evaluate_progress(snapshots, "/tmp/fake", 200L, fn(_s) {  })
  assert_true(decision is Continue)
}

///|
test "pad_int" {
  assert_eq(pad_int(5, 6), "000005")
  assert_eq(pad_int(123, 6), "000123")
  assert_eq(pad_int(0, 3), "000")
}

///|
test "split_lines" {
  let lines = split_lines("a\nb\nc")
  assert_eq(lines.length(), 3)
  assert_eq(lines[0], "a")
  assert_eq(lines[1], "b")
  assert_eq(lines[2], "c")
}

///|
test "take_chars" {
  assert_eq(take_chars("hello world", 5), "hello")
  assert_eq(take_chars("ab", 5), "ab")
  assert_eq(take_chars("", 3), "")
}

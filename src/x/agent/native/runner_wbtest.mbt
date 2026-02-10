///| Tests for native runner prefetch preparation

///|
test "collect_prefetch_paths picks unique edited files in order" {
  let task = @agent.AgentTask::new(
    "task-1",
    "update files",
    [
      @agent.FileEdit::Write("src/a.mbt", b"1"),
      @agent.FileEdit::Delete("src/b.mbt"),
      @agent.FileEdit::Write("src/a.mbt", b"2"),
      @agent.FileEdit::Delete("src/b.mbt"),
      @agent.FileEdit::Write("src/c.mbt", b"3"),
    ],
    "title",
    "body",
    "agent/task-1",
  )
  let paths = collect_prefetch_paths(task)
  assert_eq(paths, ["src/a.mbt", "src/b.mbt", "src/c.mbt"])
}

///|
test "collect_prefetch_paths ignores blank paths" {
  let task = @agent.AgentTask::new(
    "task-2",
    "update files",
    [
      @agent.FileEdit::Write("  ", b""),
      @agent.FileEdit::Delete(""),
      @agent.FileEdit::Write(" src/a.mbt ", b"x"),
    ],
    "title",
    "body",
    "agent/task-2",
  )
  let paths = collect_prefetch_paths(task)
  assert_eq(paths, ["src/a.mbt"])
}

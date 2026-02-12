///|
test "rebase-ai parser: basic flags and upstream" {
  let parsed = parse_rebase_ai_args(["--continue", "--skip", "origin/main"])
  assert_true(parsed.do_continue)
  assert_true(parsed.do_skip)
  assert_false(parsed.do_abort)
  assert_eq(parsed.upstream, Some("origin/main"))
}

///|
test "rebase-ai parser: model and round options" {
  let parsed = parse_rebase_ai_args([
    "--model=moonshotai/kimi-k2", "--max-ai-rounds", "5",
  ])
  assert_eq(parsed.model, "moonshotai/kimi-k2")
  assert_eq(parsed.max_auto_rounds, 5)
}

///|
test "rebase-ai parser: invalid max-ai-rounds rejects non-positive value" {
  ignore(
    parse_rebase_ai_args(["--max-ai-rounds", "0"]) catch {
      @git.GitError::InvalidObject(message) => {
        assert_true(message.contains("greater than 0"))
        return ()
      }
      err => fail("unexpected error: \{err.to_string()}")
    },
  )
  fail("expected invalid object error")
}

///|
test "rebase-ai parser: agent-loop options" {
  let parsed = parse_rebase_ai_args([
    "--agent-loop", "--agent-max-steps", "9", "origin/main",
  ])
  assert_true(parsed.use_agent_loop)
  assert_eq(parsed.agent_max_steps, 9)
  assert_eq(parsed.upstream, Some("origin/main"))
}

///|
test "rebase-ai parser: invalid --agent-max-steps rejects non-positive value" {
  ignore(
    parse_rebase_ai_args(["--agent-max-steps", "0"]) catch {
      @git.GitError::InvalidObject(message) => {
        assert_true(message.contains("greater than 0"))
        return ()
      }
      err => fail("unexpected error: \{err.to_string()}")
    },
  )
  fail("expected invalid object error")
}

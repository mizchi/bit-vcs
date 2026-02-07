///|
test "push-default: upstream uses configured tracking" {
  let plan = resolve_push_target_plan(
    None,
    None,
    "main",
    ["parent1", "parent2"],
    Some("parent1"),
    Some("refs/heads/foo"),
    Some("upstream"),
    None,
    false,
  )
  assert_eq(plan.remote_name, "parent1")
  assert_eq(plan.source_ref, "refs/heads/main")
  assert_eq(plan.dest_ref, "refs/heads/foo")
  assert_false(plan.auto_set_upstream)
}

///|
test "push-default: upstream rejects explicit non-upstream remote" {
  let _ = resolve_push_target_plan(
    Some("parent2"),
    None,
    "main",
    ["parent1", "parent2"],
    Some("parent1"),
    Some("refs/heads/foo"),
    Some("upstream"),
    None,
    false,
  ) catch {
    _ => return ()
  }
  fail("expected upstream mismatch error")
}

///|
test "push-default: current chooses origin when multiple remotes" {
  let plan = resolve_push_target_plan(
    None,
    None,
    "main",
    ["origin", "parent1"],
    None,
    None,
    Some("current"),
    None,
    false,
  )
  assert_eq(plan.remote_name, "origin")
  assert_eq(plan.dest_ref, "refs/heads/main")
}

///|
test "push-default: current chooses sole remote" {
  let plan = resolve_push_target_plan(
    None,
    None,
    "main",
    ["parent2"],
    None,
    None,
    Some("current"),
    None,
    false,
  )
  assert_eq(plan.remote_name, "parent2")
  assert_eq(plan.dest_ref, "refs/heads/main")
}

///|
test "push-default: simple requires same-name upstream" {
  let _ = resolve_push_target_plan(
    None,
    None,
    "main",
    ["parent1"],
    Some("parent1"),
    Some("refs/heads/foo"),
    Some("simple"),
    Some("parent1"),
    false,
  ) catch {
    _ => return ()
  }
  fail("expected simple mismatch error")
}

///|
test "push-default: simple triangular falls back to current" {
  let plan = resolve_push_target_plan(
    None,
    None,
    "main",
    ["parent1", "parent2"],
    Some("parent1"),
    Some("refs/heads/foo"),
    Some("simple"),
    Some("parent2"),
    false,
  )
  assert_eq(plan.remote_name, "parent2")
  assert_eq(plan.dest_ref, "refs/heads/main")
}

///|
test "push-default: autosetup enables new branch push" {
  let plan = resolve_push_target_plan(
    None,
    None,
    "new-branch",
    ["parent1"],
    Some("parent1"),
    None,
    Some("upstream"),
    None,
    true,
  )
  assert_eq(plan.remote_name, "parent1")
  assert_eq(plan.dest_ref, "refs/heads/new-branch")
  assert_true(plan.auto_set_upstream)
}

///|
test "push-default: upstream fails in triangular workflow" {
  let _ = resolve_push_target_plan(
    None,
    None,
    "main",
    ["parent1", "parent2"],
    Some("parent1"),
    Some("refs/heads/foo"),
    Some("upstream"),
    Some("parent2"),
    false,
  ) catch {
    _ => return ()
  }
  fail("expected triangular upstream failure")
}

///|
test "push-default: matching without upstream merge fails" {
  let _ = resolve_push_target_plan(
    None,
    None,
    "new-branch",
    ["parent1"],
    Some("parent1"),
    None,
    Some("matching"),
    None,
    false,
  ) catch {
    _ => return ()
  }
  fail("expected matching failure")
}

///|
test "push-default: colon refspec reports branch hint" {
  let _ = resolve_push_target_plan(
    Some("origin"),
    Some(":"),
    "main",
    ["origin"],
    Some("origin"),
    Some("refs/heads/main"),
    Some("matching"),
    None,
    false,
  ) catch {
    err =>
      match err {
        @git.GitError::InvalidObject(msg) => {
          assert_true(msg.contains("Perhaps you should specify a branch"))
          return ()
        }
        _ => return ()
      }
  }
  fail("expected colon refspec error")
}

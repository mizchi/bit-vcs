///|
fn test_now_ms() -> Int64 {
  @env.now().to_int().to_int64()
}

///|
fn test_tmp_root(prefix : String) -> String {
  "/tmp/bit-rebase-ai-test-" + prefix + "-" + test_now_ms().to_string()
}

///|
async fn test_cleanup(path : String) -> Unit {
  ignore(@process.run("rm", ["-rf", path], inherit_env=true)) catch {
    _ => ()
  }
}

///|
async fn test_exec_code(
  cmd : String,
  args : Array[String],
  cwd : String,
) -> Int {
  @process.run(cmd, args, inherit_env=true, cwd~) catch {
    _ => -1
  }
}

///|
async fn test_exec_text(
  cmd : String,
  args : Array[String],
  cwd : String,
) -> String? {
  let (code, out, _) = @process.collect_output(
    cmd,
    args,
    inherit_env=true,
    cwd~,
  ) catch {
    _ => return None
  }
  if code != 0 {
    return None
  }
  let text = out.text() catch { _ => return None }
  Some(text.trim_end().to_string())
}

///|
test "rebase-ai: normalize_model_output extracts fenced content" {
  let raw =
    #|```diff
    #|line-1
    #|line-2
    #|```
  let normalized = normalize_model_output(raw)
  assert_eq(normalized, "line-1\nline-2")
}

///|
test "rebase-ai: normalize_repo_relative_path rejects escape path" {
  assert_eq(
    normalize_repo_relative_path("conflicted.txt"),
    Some("conflicted.txt"),
  )
  assert_eq(normalize_repo_relative_path("./nested/../x.txt"), None)
  assert_eq(normalize_repo_relative_path("../outside.txt"), None)
  assert_eq(normalize_repo_relative_path(".git/config"), None)
}

///|
async test "rebase-ai: find_conflict_marker_paths finds files with markers" {
  let fs : @osfs.OsFs = @osfs.OsFs::new()
  let root = test_tmp_root("scan")
  test_cleanup(root)
  fs.mkdir_p(root + "/nested")
  fs.mkdir_p(root + "/.git")
  let conflicted =
    #|<<<<<<< HEAD
    #|ours
    #|=======
    #|theirs
    #|>>>>>>> incoming
  fs.write_string(root + "/nested/conflict.txt", conflicted)
  fs.write_string(root + "/plain.txt", "ok")
  fs.write_string(root + "/.git/HEAD", conflicted)
  let paths = find_conflict_marker_paths(fs, root)
  assert_eq(paths.length(), 1)
  assert_eq(paths[0], "nested/conflict.txt")
  test_cleanup(root)
}

///|
async test "rebase-ai: resolve_conflict_paths applies model output and stages file" {
  let fs : @osfs.OsFs = @osfs.OsFs::new()
  let root = test_tmp_root("resolve")
  test_cleanup(root)
  fs.mkdir_p(root)
  if test_exec_code("git", ["init", "-b", "main"], root) != 0 {
    test_cleanup(root)
    return
  }
  let conflict_text =
    #|<<<<<<< HEAD
    #|left
    #|=======
    #|right
    #|>>>>>>> incoming
  fs.write_string(root + "/conflicted.txt", conflict_text)
  let mock = @llmlib.MockProvider::new([
    [
      @llmlib.StreamEvent::TextDelta("merged-line\n"),
      @llmlib.StreamEvent::MessageEnd(
        finish_reason=@llmlib.FinishReason::Stop,
        usage=None,
      ),
    ],
  ])
  let options = AiRebaseOptions::new(
    max_auto_rounds=4,
    verbose=false,
    provider=Some(mock.boxed()),
  )
  let provider_ref : Ref[@llmlib.BoxedProvider?] = { val: options.provider }
  let resolved = resolve_conflict_paths(
    fs,
    fs,
    root,
    ["conflicted.txt"],
    options,
    provider_ref,
  )
  assert_eq(resolved.failed.length(), 0)
  assert_eq(resolved.resolved.length(), 1)
  let data = fs.read_file(root + "/conflicted.txt")
  let text = decode_bytes(data)
  assert_eq(has_conflict_markers(text), false)
  assert_true(text.contains("merged-line"))
  guard test_exec_text("git", ["diff", "--cached", "--name-only"], root)
    is Some(staged_names) else {
    test_cleanup(root)
    fail("expected staged output")
  }
  assert_true(staged_names.contains("conflicted.txt"))
  test_cleanup(root)
}

///|
async test "rebase-ai: agent-loop mode resolves conflict with repo-scoped read/write tools" {
  let fs : @osfs.OsFs = @osfs.OsFs::new()
  let root = test_tmp_root("agent-loop")
  test_cleanup(root)
  fs.mkdir_p(root)
  if test_exec_code("git", ["init", "-b", "main"], root) != 0 {
    test_cleanup(root)
    return
  }
  let conflict_text =
    #|<<<<<<< HEAD
    #|left
    #|=======
    #|right
    #|>>>>>>> incoming
  fs.write_string(root + "/conflicted.txt", conflict_text)
  let mock = @llmlib.MockProvider::new([
    [
      @llmlib.MessageStart,
      @llmlib.ToolCallStart(id="call_1", name="read_file"),
      @llmlib.ToolCallEnd(id="call_1", name="read_file", input={
        "path": "conflicted.txt".to_json(),
      }),
      @llmlib.MessageEnd(
        finish_reason=@llmlib.FinishReason::ToolUse,
        usage=None,
      ),
    ],
    [
      @llmlib.MessageStart,
      @llmlib.ToolCallStart(id="call_2", name="write_file"),
      @llmlib.ToolCallEnd(id="call_2", name="write_file", input={
        "path": "conflicted.txt".to_json(),
        "content": "merged-line\n".to_json(),
      }),
      @llmlib.MessageEnd(
        finish_reason=@llmlib.FinishReason::ToolUse,
        usage=None,
      ),
    ],
    [
      @llmlib.MessageStart,
      @llmlib.TextDelta("resolved"),
      @llmlib.MessageEnd(finish_reason=@llmlib.FinishReason::Stop, usage=None),
    ],
  ])
  let options = AiRebaseOptions::new(
    max_auto_rounds=4,
    verbose=false,
    provider=Some(mock.boxed()),
    use_agent_loop=true,
    agent_max_steps=8,
  )
  let provider_ref : Ref[@llmlib.BoxedProvider?] = { val: options.provider }
  let resolved = resolve_conflict_paths(
    fs,
    fs,
    root,
    ["conflicted.txt"],
    options,
    provider_ref,
  )
  assert_eq(resolved.failed.length(), 0)
  assert_eq(resolved.resolved.length(), 1)
  let data = fs.read_file(root + "/conflicted.txt")
  let text = decode_bytes(data)
  assert_eq(has_conflict_markers(text), false)
  assert_true(text.contains("merged-line"))
  guard test_exec_text("git", ["diff", "--cached", "--name-only"], root)
    is Some(staged_names) else {
    test_cleanup(root)
    fail("expected staged output")
  }
  assert_true(staged_names.contains("conflicted.txt"))
  test_cleanup(root)
}

///|
pub(all) struct LlmAgentConfig {
  work_dir : String
  task : String
  branch_name : String
  target_branch : String
  provider_name : String
  model : String
  max_steps : Int
  max_runtime_sec : Int // hard stop by wall clock seconds; <=0 disables
  max_tool_calls : Int // hard stop by tool call count; <=0 disables
  stop_file : String // optional stop file path; exists => cancel
  auto_commit : Bool
  auto_pr : Bool
  pr_title : String
  verbose : Bool
  coord_dir : String // empty = no coordination
  agent_id : String // empty = no coordination
  env : &ToolEnvironment? // None = use NativeToolEnvironment
  coord : &CoordinationBackend? // None = use FileCoordinationBackend
  provider : @llmlib.BoxedProvider? // None = create_provider(provider_name, model, ...)
}

///|
fn detect_project_hints(work_dir : String) -> String {
  let has_moon = strip_trailing_whitespace(
    exec(
      "test -f " +
      shell_escape(work_dir + "/moon.mod.json") +
      " && echo yes || echo no",
    ),
  )
  if has_moon == "yes" {
    return "## Project: MoonBit\n- Type check: `moon check --deny-warn`\n- Test: `moon test`\n- Format: `moon fmt`\n- Always run `moon check --deny-warn` after writing code to catch errors early.\n"
  }
  ""
}

///|
fn build_system_prompt(work_dir : String, task : String) -> String {
  let buf = StringBuilder::new()
  buf.write_string("You are a coding agent working in: ")
  buf.write_string(work_dir)
  buf.write_string("\n\nTask: ")
  buf.write_string(task)
  let workflow =
    #|
    #|
    #|## Workflow (follow these phases in order)
    #|
    #|Phase 1 - Explore: Understand the codebase structure.
    #|  - Call `list_files_recursive` ONCE to get an overview.
    #|  - Use `search_text` to find relevant code by pattern.
    #|  - Use `read_file` to read specific files you need to understand.
    #|
    #|Phase 2 - Plan: Decide what changes to make.
    #|  - Identify which files to create or modify.
    #|  - Read each file you plan to modify BEFORE writing.
    #|
    #|Phase 3 - Implement: Make changes using `write_file`.
    #|  - You MUST call `write_file` to make progress. Exploring alone is not progress.
    #|  - Write complete file contents. Do NOT leave placeholders.
    #|
    #|Phase 4 - Verify: Run checks and tests.
    #|  - Use `run_command` to run the project's type checker and tests.
    #|  - If errors occur, read the error output, fix with `write_file`, and re-verify.
    #|
    #|Phase 5 - Complete: Stop calling tools and summarize what you did.
    #|
    #|## Anti-patterns (Do NOT do these)
    #|
    #|- Do NOT call `list_directory` on the same path more than once.
    #|- Do NOT call `list_files_recursive` on the same path more than once.
    #|- Do NOT keep exploring without writing code. If you have read enough, start writing.
    #|- Do NOT call `read_file` on the same file repeatedly. Read once, then modify.
    #|- Do NOT run the same failing command without changing code first.
    #|
    #|## Tool selection guide
    #|
    #|- To find code by content: use `search_text` (regex, fast).
    #|- To understand project structure: use `list_files_recursive` once.
    #|- To read a specific file: use `read_file`.
    #|- To make changes: use `write_file` (REQUIRED for progress).
    #|- To verify: use `run_command`.
  buf.write_string(workflow)
  let hints = detect_project_hints(work_dir)
  if not(hints.is_empty()) {
    buf.write_string("\n")
    buf.write_string(hints)
  }
  buf.to_string()
}

///|
pub fn create_provider(
  name : String,
  model : String,
  system_prompt : String,
) -> @llmlib.BoxedProvider {
  match name {
    "anthropic" => {
      let api_key = @ffi.get_env("ANTHROPIC_API_KEY")
      let m = if model.is_empty() {
        @llmlib.default_anthropic_model
      } else {
        model
      }
      let provider = @anthropic.AnthropicProvider::new(
        api_key,
        model=m,
        system_prompt~,
        max_tokens=8192,
      )
      @llmlib.BoxedProvider::new(provider)
    }
    "openai" => {
      let api_key = @ffi.get_env("OPENAI_API_KEY")
      let m = if model.is_empty() {
        @llmlib.default_openai_model
      } else {
        model
      }
      let provider = @openai.OpenAIProvider::new(
        api_key,
        model=m,
        system_prompt~,
        max_tokens=8192,
      )
      @llmlib.BoxedProvider::new(provider)
    }
    "openrouter" => {
      let api_key = @ffi.get_env("OPENROUTER_API_KEY")
      let m = if model.is_empty() {
        @llmlib.default_openrouter_model
      } else {
        model
      }
      let provider = @openai.OpenAIProvider::new(
        api_key,
        endpoint=OpenRouter,
        model=m,
        system_prompt~,
        max_tokens=8192,
      )
      @llmlib.BoxedProvider::new(provider)
    }
    "claude_code" => {
      let m = if model.is_empty() { "" } else { model }
      let provider = @claude_code.ClaudeCodeProvider::new(
        model=m,
        system_prompt~,
      )
      @llmlib.BoxedProvider::new(provider)
    }
    _ => create_provider("anthropic", model, system_prompt)
  }
}

///|
fn is_exec_error(output : String) -> Bool {
  output.has_prefix("ERROR:")
}

///|
fn now_unix_seconds(exec_cmd : (String) -> String) -> Int {
  let out = strip_trailing_whitespace(exec_cmd("date +%s"))
  @strconv.parse_int(out) catch {
    _ => 0
  }
}

///|
fn is_stop_file_triggered(
  stop_file : String,
  exec_cmd : (String) -> String,
) -> Bool {
  let path = stop_file.trim().to_string()
  if path.is_empty() {
    return false
  }
  let cmd = "test -f " + shell_escape(path) + " && echo 1 || echo 0"
  strip_trailing_whitespace(exec_cmd(cmd)) == "1"
}

///|
fn evaluate_agent_stop_reason(
  cancel_requested : Bool,
  start_sec : Int,
  now_sec : Int,
  max_runtime_sec : Int,
  tool_calls : Int,
  max_tool_calls : Int,
  stop_file_triggered : Bool,
) -> String? {
  if cancel_requested {
    return Some("cancel:requested")
  }
  if stop_file_triggered {
    return Some("cancel:stop_file")
  }
  if max_runtime_sec > 0 &&
    start_sec > 0 &&
    now_sec - start_sec >= max_runtime_sec {
    return Some("budget:max_runtime_sec")
  }
  if max_tool_calls > 0 && tool_calls >= max_tool_calls {
    return Some("budget:max_tool_calls")
  }
  None
}

///|
fn run_auto_commit_steps(
  work_dir : String,
  branch : String,
  message : String,
  exec_cmd : (String) -> String,
  log : (String) -> Unit,
) -> Bool {
  let checkout_cmd = "cd " +
    shell_escape(work_dir) +
    " && git checkout -b " +
    shell_escape(branch)
  let checkout_out = exec_cmd(checkout_cmd)
  if is_exec_error(checkout_out) {
    log("[git] ERROR: git checkout -b failed: " + checkout_out)
    return false
  }
  let add_cmd = "cd " + shell_escape(work_dir) + " && git add -A"
  let add_out = exec_cmd(add_cmd)
  if is_exec_error(add_out) {
    log("[git] ERROR: git add failed: " + add_out)
    return false
  }
  let commit_cmd = "cd " +
    shell_escape(work_dir) +
    " && git commit -m " +
    shell_escape(message)
  let commit_out = exec_cmd(commit_cmd)
  if is_exec_error(commit_out) {
    log("[git] ERROR: git commit failed: " + commit_out)
    return false
  }
  true
}

///|
pub fn run_llm_agent(
  config : LlmAgentConfig,
  on_output~ : (String) -> Unit,
  should_cancel? : () -> Bool = fn() { false },
) -> Unit {
  let log = fn(s : String) { on_output(s + "\n") }
  let system_prompt = build_system_prompt(config.work_dir, config.task)
  let provider = match config.provider {
    Some(p) => p
    None => create_provider(config.provider_name, config.model, system_prompt)
  }
  let env : &ToolEnvironment = match config.env {
    Some(e) => e
    None => native_tool_env(config.work_dir)
  }
  let registry = create_tool_registry(env)
  let messages : Array[@llmlib.Message] = [@llmlib.Message::user(config.task)]
  let verbose = config.verbose
  let has_coord = not(config.coord_dir.is_empty()) &&
    not(config.agent_id.is_empty())
  let coord : &CoordinationBackend? = if has_coord {
    match config.coord {
      Some(c) => Some(c)
      None => Some(file_coordination_backend(""))
    }
  } else {
    None
  }
  if has_coord {
    guard coord is Some(c) else { () }
    c.write_status(config.coord_dir, config.agent_id, Running)
  }
  if verbose {
    log("[agent] provider=" + config.provider_name + " model=" + config.model)
    log("[agent] work_dir=" + config.work_dir)
    log("[agent] task=" + config.task)
    log("")
  }
  if should_cancel() {
    if has_coord {
      guard coord is Some(c) else { () }
      c.write_status(config.coord_dir, config.agent_id, Cancelled)
      c.append_event(
        config.coord_dir,
        config.agent_id,
        Finished(summary="cancelled before start"),
      )
    }
    log("[cancelled]")
    return
  }
  let start_sec = now_unix_seconds(exec)
  let stop_file = if config.stop_file.trim().to_string().is_empty() {
    @ffi.get_env("BIT_AGENT_STOP_FILE")
  } else {
    config.stop_file
  }
  let text_buf = StringBuilder::new()
  let mut tools_in_step = 0
  let total_tool_calls : Ref[Int] = Ref::new(0)
  let cancel_reason : Ref[String?] = Ref::new(None)
  let final_reason : Ref[String] = Ref::new("")
  let was_cancelled : Ref[Bool] = Ref::new(false)
  let should_stop = fn() {
    let reason = evaluate_agent_stop_reason(
      should_cancel(),
      start_sec,
      now_unix_seconds(exec),
      config.max_runtime_sec,
      total_tool_calls.val,
      config.max_tool_calls,
      is_stop_file_triggered(stop_file, exec),
    )
    match reason {
      Some(r) => {
        cancel_reason.val = Some(r)
        true
      }
      None => false
    }
  }
  @llmlib.run_agent_cancellable(
    provider,
    registry,
    messages,
    @llmlib.StopCondition::MaxSteps(config.max_steps),
    should_stop,
    fn(event) {
      match event {
        Stream(stream_event) =>
          match stream_event {
            TextDelta(s) => text_buf.write_string(s)
            _ => ()
          }
        ToolExecute(name~, input~) =>
          if verbose {
            let text = text_buf.to_string()
            if not(text.is_empty()) {
              on_output(text)
              text_buf.reset()
            }
            log("\n[tool] " + name + " " + input.stringify())
          }
        ToolResult(name~, result~, is_error~) => {
          total_tool_calls.val += 1
          tools_in_step += 1
          if has_coord {
            guard coord is Some(c) else { () }
            if name == "write_file" {
              c.append_event(
                config.coord_dir,
                config.agent_id,
                FileChanged(path=result),
              )
            }
            if is_error {
              c.append_event(
                config.coord_dir,
                config.agent_id,
                Error(message=name + ": " + result),
              )
            }
          }
          if verbose {
            let status = if is_error { " ERROR" } else { " ok" }
            let preview = if result.length() > 200 {
              let buf = StringBuilder::new()
              let rchars : Array[Char] = []
              for ch in result {
                rchars.push(ch)
              }
              for j = 0; j < 200; j = j + 1 {
                buf.write_char(rchars[j])
              }
              buf.write_string("...")
              buf.to_string()
            } else {
              result
            }
            log("[result] " + name + status + ": " + preview)
          }
        }
        StepComplete(step~) => {
          if has_coord {
            guard coord is Some(c) else { () }
            c.write_step(config.coord_dir, config.agent_id, step)
            c.append_event(
              config.coord_dir,
              config.agent_id,
              StepCompleted(step~, tools_called=tools_in_step),
            )
          }
          tools_in_step = 0
          let text = text_buf.to_string()
          if not(text.is_empty()) {
            on_output(text)
            text_buf.reset()
          }
          if verbose {
            log("[step " + step.to_string() + " complete]")
          }
        }
        Done(reason~) => {
          let effective_reason = if reason == "cancelled" {
            match cancel_reason.val {
              Some(r) => r
              None => "cancelled"
            }
          } else {
            reason
          }
          final_reason.val = effective_reason
          was_cancelled.val = reason == "cancelled"
          if has_coord {
            guard coord is Some(c) else { () }
            c.write_status(
              config.coord_dir,
              config.agent_id,
              if was_cancelled.val {
                Cancelled
              } else {
                Done
              },
            )
            c.append_event(
              config.coord_dir,
              config.agent_id,
              Finished(summary=effective_reason),
            )
          }
          let text = text_buf.to_string()
          if not(text.is_empty()) {
            on_output(text)
          }
          if was_cancelled.val {
            log("\n[cancelled] " + effective_reason)
          } else {
            log("\n[done] " + effective_reason)
          }
        }
      }
    },
  )
  if was_cancelled.val {
    if verbose && not(final_reason.val.is_empty()) {
      log("[agent] stop reason: " + final_reason.val)
    }
    return
  }
  // Auto-commit
  if config.auto_commit {
    let branch = config.branch_name
    let wd = config.work_dir
    if verbose {
      log("[git] creating branch: " + branch)
    }
    let msg = "agent: " + config.task
    let ok = run_auto_commit_steps(wd, branch, msg, exec, log)
    if not(ok) {
      if verbose {
        log("[git] auto-commit aborted")
      }
      return
    }
    if verbose {
      log("[git] committed on branch: " + branch)
    }
  }
  // Auto-PR
  if config.auto_pr {
    let wd = config.work_dir
    let branch = config.branch_name
    let title = if config.pr_title.is_empty() {
      "agent: " + config.task
    } else {
      config.pr_title
    }
    ignore(
      exec_with_timeout(
        "cd " +
        shell_escape(wd) +
        " && git push -u origin " +
        shell_escape(branch),
        60000,
      ),
    )
    let result = exec_with_timeout(
      "cd " +
      shell_escape(wd) +
      " && gh pr create --title " +
      shell_escape(title) +
      " --body 'Created by bit agent' --base " +
      shell_escape(config.target_branch),
      60000,
    )
    log("[pr] " + result)
  }
}

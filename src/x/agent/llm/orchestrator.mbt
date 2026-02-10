///|
priv struct WorkerTask {
  task : String
  files : Array[String]
  work_dir : String
  branch : String
  agent_id : String
}

///|
priv struct SubtaskPlan {
  task : String
  files : Array[String] // file scope for this subtask
}

///|
priv struct SubmittedRemoteJob {
  job_id : String
  agent_id : String
}

///|
pub(all) enum OrchestratorExecMode {
  ProcessMode
  InProcessMode
  CloudflareMode
} derive(Eq)

///|
pub(all) struct OrchestratorConfig {
  work_dir : String
  task : String
  provider_name : String
  model : String
  max_workers : Int
  max_runtime_sec : Int
  max_tool_calls : Int
  stop_file : String
  target_branch : String
  auto_pr : Bool
  verbose : Bool
  exec_mode : OrchestratorExecMode // process|in-process|cloudflare
  orchestrator_url : String // cloudflare mode: base URL or /api/v1/jobs/submit endpoint
  orchestrator_token : String // cloudflare mode: optional bearer token
}

///|
pub fn parse_orchestrator_exec_mode(raw : String) -> OrchestratorExecMode {
  let normalized = raw.trim().to_string_view().to_lower().to_string()
  match normalized {
    "in-process" | "inprocess" | "self" | "self-agent" => InProcessMode
    "cloudflare"
    | "remote"
    | "remote-cloudflare"
    | "cloudflare-static"
    | "cloudflare-static-deno"
    | "deno-remote" => CloudflareMode
    "process" | "local" => ProcessMode
    _ => ProcessMode
  }
}

///|
fn normalize_orchestrator_submit_url(base_url : String) -> String? {
  let trimmed = base_url.trim().to_string()
  if trimmed.is_empty() {
    return None
  }
  if trimmed.has_suffix("/api/v1/jobs/submit") {
    return Some(trimmed)
  }
  if trimmed.has_suffix("/") {
    return Some(trimmed + "api/v1/jobs/submit")
  }
  Some(trimmed + "/api/v1/jobs/submit")
}

///|
fn cloudflare_job_status_url(submit_url : String, job_id : String) -> String {
  let suffix = "/submit"
  if submit_url.has_suffix(suffix) {
    let end = submit_url.length() - suffix.length()
    String::unsafe_substring(submit_url, start=0, end~) + "/" + job_id
  } else {
    submit_url + "/" + job_id
  }
}

///|
/// Abstraction for how agents are executed
pub(open) trait AgentRunner {
  /// Spawn an agent. Returns a handle identifier (e.g., PID string or agent_id).
  spawn_agent(Self, config : LlmAgentConfig, log_file : String) -> String
  /// Wait for all spawned agents to complete. Polls/blocks until done or timeout.
  wait_all(
    Self,
    session_dir : String,
    timeout_seconds : Int,
    log : (String) -> Unit,
  ) -> Unit
  /// Cancel a specific agent by its handle/id.
  cancel_agent(Self, handle : String) -> Unit
}

///|
/// Runs agents as separate OS processes via nohup
priv struct ProcessAgentRunner {
  bit_binary : String
  provider_name : String
  model : String
  verbose : Bool
}

///|
fn ProcessAgentRunner::new(
  provider_name : String,
  model : String,
  verbose : Bool,
) -> ProcessAgentRunner {
  { bit_binary: find_bit_binary(), provider_name, model, verbose }
}

///|
impl AgentRunner for ProcessAgentRunner with spawn_agent(self, config, log_file) {
  let cmd = "nohup " +
    shell_escape(self.bit_binary) +
    " agent llm" +
    " --task " +
    shell_escape(config.task) +
    " --work-dir " +
    shell_escape(config.work_dir) +
    " --branch " +
    shell_escape(config.branch_name) +
    " --provider " +
    shell_escape(self.provider_name) +
    (if self.model.is_empty() {
      ""
    } else {
      " --model " + shell_escape(self.model)
    }) +
    " --coord-dir " +
    shell_escape(config.coord_dir) +
    " --agent-id " +
    shell_escape(config.agent_id) +
    " --no-commit" +
    " > " +
    shell_escape(log_file) +
    " 2>&1 & echo $!"
  strip_trailing_whitespace(exec(cmd))
}

///|
impl AgentRunner for ProcessAgentRunner with wait_all(
  self,
  session_dir,
  timeout_seconds,
  log,
) {
  let max_iterations = timeout_seconds / 2
  let mut iteration = 0
  while iteration < max_iterations {
    ignore(exec("sleep 2"))
    iteration += 1
    let snapshots = coord_read_all_agents(session_dir)
    let now_str = strip_trailing_whitespace(exec("date +%s"))
    let now = (@strconv.parse_int(now_str) catch { _ => 0 }).to_int64()
    let decision = evaluate_progress(snapshots, session_dir, now, log)
    match decision {
      AllDone => {
        if self.verbose {
          log("[orchestrator] All agents completed.")
        }
        break
      }
      CancelAgent(id~, reason~) => {
        if self.verbose {
          log("[orchestrator] Cancelling " + id + ": " + reason)
        }
        for s in snapshots {
          if s.agent_id == id && s.pid > 0 {
            ignore(exec("kill " + s.pid.to_string() + " 2>/dev/null"))
            coord_write_status(session_dir, id, Cancelled)
          }
        }
      }
      Continue =>
        if self.verbose && iteration % 5 == 0 {
          for s in snapshots {
            let elapsed = if s.last_step_time > 0L && now > s.last_step_time {
              " elapsed=" + (now - s.last_step_time).to_string() + "s"
            } else {
              ""
            }
            log(
              "  " +
              s.agent_id +
              ": " +
              s.status.to_string() +
              " step=" +
              s.step.to_string() +
              elapsed,
            )
          }
        }
    }
  }
  if iteration >= max_iterations {
    log("[orchestrator] Timeout reached, killing remaining agents...")
    let snapshots = coord_read_all_agents(session_dir)
    for s in snapshots {
      if s.status == Running && s.pid > 0 {
        ignore(exec("kill " + s.pid.to_string() + " 2>/dev/null"))
        coord_write_status(session_dir, s.agent_id, Cancelled)
      }
    }
  }
}

///|
impl AgentRunner for ProcessAgentRunner with cancel_agent(_self, handle) {
  ignore(exec("kill " + handle + " 2>/dev/null"))
}

///|
/// Runs agents in-process sequentially (no OS process spawn)
priv struct InProcessAgentRunner {
  verbose : Bool
  results : Map[String, Bool] // agent_id -> completed
  cancelled : Map[String, Bool]
}

///|
fn InProcessAgentRunner::new(
  _provider_name : String,
  _model : String,
  verbose : Bool,
) -> InProcessAgentRunner {
  { verbose, results: {}, cancelled: {} }
}

///|
impl AgentRunner for InProcessAgentRunner with spawn_agent(
  self,
  config,
  _log_file,
) {
  let agent_id = config.agent_id
  // Run the agent immediately (blocking) with cancellation support
  run_llm_agent(config, on_output=fn(s) { if self.verbose { ignore(s) } }, should_cancel=fn() {
    self.cancelled.get(agent_id) == Some(true)
  })
  self.results[agent_id] = true
  agent_id
}

///|
impl AgentRunner for InProcessAgentRunner with wait_all(
  _self,
  _session_dir,
  _timeout_seconds,
  _log,
) {
  // All agents already completed in spawn_agent (synchronous)
}

///|
impl AgentRunner for InProcessAgentRunner with cancel_agent(self, handle) {
  self.cancelled[handle] = true
}

///|
fn exec_checked(
  command : String,
  action : String,
  exec_cmd : (String) -> String,
  log : (String) -> Unit,
) -> String? {
  let output = exec_cmd(command)
  if is_exec_error(output) {
    log("[orchestrator] ERROR " + action + ": " + output)
    return None
  }
  Some(output)
}

///|
fn extract_subtask_plans(text : String) -> Array[SubtaskPlan] {
  // Try to find JSON array in the text
  let chars : Array[Char] = []
  for ch in text {
    chars.push(ch)
  }
  let mut start = -1
  let mut end_ = -1
  for i = 0; i < chars.length(); i = i + 1 {
    if chars[i] == '[' && start < 0 {
      start = i
    }
    if chars[i] == ']' {
      end_ = i
    }
  }
  if start < 0 || end_ < 0 {
    return []
  }
  let buf = StringBuilder::new()
  for i = start; i <= end_; i = i + 1 {
    buf.write_char(chars[i])
  }
  let json = @json.parse(buf.to_string()) catch { _ => return [] }
  let plans : Array[SubtaskPlan] = []
  match json {
    Array(items) =>
      for item in items {
        match item {
          // New format: {"task": "...", "files": ["..."]}
          Object(m) => {
            let task = match m.get("task") {
              Some(String(s)) => s
              _ => continue
            }
            let files : Array[String] = []
            match m.get("files") {
              Some(Array(arr)) =>
                for f in arr {
                  match f {
                    String(s) => files.push(s)
                    _ => ()
                  }
                }
              _ => ()
            }
            plans.push({ task, files })
          }
          // Legacy format: plain string
          String(s) => plans.push({ task: s, files: [] })
          _ => ()
        }
      }
    _ => ()
  }
  plans
}

///|
fn normalize_planned_file_path(
  file_path : String,
  work_dir : String,
) -> String? {
  let raw = file_path.trim().to_string()
  if raw.is_empty() {
    return None
  }
  let wd = work_dir.trim().to_string()
  let wd_prefix = if wd.has_suffix("/") { wd } else { wd + "/" }
  let relative = if raw == wd {
    ""
  } else if raw.has_prefix(wd_prefix) {
    String::unsafe_substring(raw, start=wd_prefix.length(), end=raw.length())
  } else if raw.has_prefix("/") {
    return None
  } else if raw.has_prefix("./") {
    String::unsafe_substring(raw, start=2, end=raw.length())
  } else {
    raw
  }
  if relative.is_empty() {
    return None
  }
  if relative == "." ||
    relative == ".." ||
    relative.has_prefix("../") ||
    relative.contains("/../") {
    return None
  }
  Some(relative)
}

///|
fn normalize_subtask_plans(
  plans : Array[SubtaskPlan],
  work_dir : String,
  log : (String) -> Unit,
) -> Array[SubtaskPlan] {
  let normalized : Array[SubtaskPlan] = []
  for plan in plans {
    let files : Array[String] = []
    let seen : Map[String, Bool] = {}
    for file in plan.files {
      match normalize_planned_file_path(file, work_dir) {
        Some(relative) =>
          if seen.get(relative) is None {
            files.push(relative)
            seen[relative] = true
          }
        None =>
          if not(file.trim().to_string().is_empty()) {
            log("[planner] Ignore invalid file scope: " + file)
          }
      }
    }
    normalized.push({ task: plan.task, files })
  }
  normalized
}

///|
fn validate_file_overlap(plans : Array[SubtaskPlan]) -> Array[String] {
  let seen : Map[String, Int] = {}
  let conflicts : Array[String] = []
  for i, plan in plans {
    for file in plan.files {
      match seen.get(file) {
        Some(prev) =>
          conflicts.push(
            file +
            " (subtask " +
            prev.to_string() +
            " and " +
            i.to_string() +
            ")",
          )
        None => seen[file] = i
      }
    }
  }
  conflicts
}

///|
fn subtask_task_for_agent(plan : SubtaskPlan) -> String {
  if plan.files.is_empty() {
    plan.task
  } else {
    plan.task + " (files: " + plan.files.join(", ") + ")"
  }
}

///|
fn subtask_display(plan : SubtaskPlan) -> String {
  if plan.files.is_empty() {
    plan.task
  } else {
    plan.task + " [files: " + plan.files.join(", ") + "]"
  }
}

///|
fn plan_subtasks(
  config : OrchestratorConfig,
  log : (String) -> Unit,
) -> Array[SubtaskPlan] {
  let file_listing = exec(
    "cd " +
    shell_escape(config.work_dir) +
    " && find . -maxdepth 3 -not -path './.*' -type f | sed 's#^./##' | head -200",
  )
  let system_prompt =
    #|You are a task planner for a coding project.
    #|Break down the given task into independent subtasks that can be executed in parallel by coding agents.
    #|Each subtask MUST be independent — no file overlap between subtasks.
    #|
    #|Respond with ONLY a JSON array of objects. Each object has:
    #|- "task": description of the subtask
    #|- "files": array of repository-relative file paths this subtask will modify (write-scope)
    #|
    #|Example:
    #|[
    #|  {"task": "Add tests for math module", "files": ["src/math_test.mbt"]},
    #|  {"task": "Add tests for string module", "files": ["src/string_test.mbt"]}
    #|]
    #|
    #|CRITICAL: Use repository-relative paths only (e.g. src/a.mbt, not /abs/path/src/a.mbt).
    #|CRITICAL: No two subtasks may list the same file. If tasks share dependencies, combine them into one subtask.
  let provider = create_provider(
    config.provider_name,
    config.model,
    system_prompt,
  )
  let user_msg = "Project files:\n" +
    file_listing +
    "\n\nTask: " +
    config.task +
    "\n\nPlan " +
    config.max_workers.to_string() +
    " or fewer subtasks."
  let messages : Array[@llmlib.Message] = [@llmlib.Message::user(user_msg)]
  let response = @llmlib.collect_text(provider.inner, messages)
  if config.verbose {
    log("[planner] LLM response:\n" + response)
  }
  let plans = extract_subtask_plans(response)
  if plans.is_empty() {
    return [{ task: config.task, files: [] }]
  }
  let normalized_plans = normalize_subtask_plans(plans, config.work_dir, log)
  // Validate file overlap
  let conflicts = validate_file_overlap(normalized_plans)
  if not(conflicts.is_empty()) {
    if config.verbose {
      log(
        "[planner] File overlap detected, falling back to single task: " +
        conflicts.iter().map(fn(s) { s }).collect().join(", "),
      )
    }
    return [{ task: config.task, files: [] }]
  }
  normalized_plans
}

///|
/// Find the bit binary path for spawning sub-agents
fn is_likely_bit_binary(path : String) -> Bool {
  let p = path.trim().to_string()
  if p.is_empty() {
    return false
  }
  p == "bit" ||
  p.has_suffix("/bit") ||
  p.has_suffix("/bit_cli.exe") ||
  p.contains("/bit_cli.")
}

///|
fn select_bit_binary(
  bit_path_env : String,
  argv0 : String,
  which_bit : String,
) -> String {
  let env = bit_path_env.trim().to_string()
  if not(env.is_empty()) {
    return env
  }
  let a0 = argv0.trim().to_string()
  if is_likely_bit_binary(a0) {
    return a0
  }
  let which = which_bit.trim().to_string()
  if not(which.is_empty()) {
    return which
  }
  "bit"
}

///|
fn find_bit_binary() -> String {
  let bit_path_env = @ffi.get_env("BIT_PATH")
  let argv = @sys.get_cli_args()
  let argv0 = if argv.length() > 0 { argv[0] } else { "" }
  let which = strip_trailing_whitespace(exec("which bit 2>/dev/null"))
  select_bit_binary(bit_path_env, argv0, which)
}

///|
fn create_cloudflare_payload(
  config : OrchestratorConfig,
  session_id : String,
  agent_id : String,
  branch : String,
  task : String,
  files : Array[String],
) -> Json {
  let payload : Map[String, Json] = {}
  let files_json : Array[Json] = []
  for file in files {
    files_json.push(file.to_json())
  }
  payload["objective_id"] = (session_id + "/" + agent_id).to_json()
  payload["task"] = task.to_json()
  payload["files"] = Json::array(files_json)
  payload["agent_id"] = agent_id.to_json()
  payload["branch"] = branch.to_json()
  payload["target_branch"] = config.target_branch.to_json()
  payload["provider"] = config.provider_name.to_json()
  payload["model"] = config.model.to_json()
  payload["max_steps"] = (20).to_json()
  payload["max_runtime_sec"] = config.max_runtime_sec.to_json()
  payload["max_tool_calls"] = config.max_tool_calls.to_json()
  payload["stop_file"] = config.stop_file.to_json()
  payload["work_dir"] = config.work_dir.to_json()
  payload["static_check_only"] = Json::boolean(true)
  payload["execution_backend"] = "deno-worker".to_json()
  payload["execution_runtime"] = "deno".to_json()
  payload["source"] = "bit-orchestrator".to_json()
  Json::object(payload)
}

///|
fn submit_cloudflare_job(
  submit_url : String,
  token : String,
  payload : Json,
  log : (String) -> Unit,
) -> String? {
  let auth_token = token.trim().to_string()
  let auth_header = if auth_token.is_empty() {
    ""
  } else {
    " -H " + shell_escape("authorization: Bearer " + auth_token)
  }
  let cmd = "curl -sS -X POST" +
    " -H " +
    shell_escape("content-type: application/json") +
    auth_header +
    " --data " +
    shell_escape(payload.stringify()) +
    " " +
    shell_escape(submit_url)
  let output = exec(cmd)
  if is_exec_error(output) {
    log("[orchestrator] ERROR cloudflare submit failed: " + output)
    return None
  }
  let parsed = @json.parse(output) catch {
    _ => {
      log("[orchestrator] ERROR cloudflare submit invalid response: " + output)
      return None
    }
  }
  match parsed {
    Object(m) => {
      let ok = match m.get("ok") {
        Some(True) => true
        _ => false
      }
      if not(ok) {
        let err = match m.get("error") {
          Some(String(s)) => s
          _ => output
        }
        log("[orchestrator] ERROR cloudflare submit rejected: " + err)
        return None
      }
      match m.get("job_id") {
        Some(String(job_id)) => Some(job_id)
        _ => {
          log("[orchestrator] ERROR cloudflare submit missing job_id")
          None
        }
      }
    }
    _ => {
      log("[orchestrator] ERROR cloudflare submit invalid json object")
      None
    }
  }
}

///|
fn is_terminal_cloudflare_status(status : String) -> Bool {
  status == "done" || status == "failed" || status == "cancelled"
}

///|
fn fetch_cloudflare_job_status(
  submit_url : String,
  token : String,
  job_id : String,
  log : (String) -> Unit,
) -> String? {
  let status_url = cloudflare_job_status_url(submit_url, job_id)
  let auth_token = token.trim().to_string()
  let auth_header = if auth_token.is_empty() {
    ""
  } else {
    " -H " + shell_escape("authorization: Bearer " + auth_token)
  }
  let cmd = "curl -sS" + auth_header + " " + shell_escape(status_url)
  let output = exec(cmd)
  if is_exec_error(output) {
    log(
      "[orchestrator] ERROR cloudflare status request failed for " +
      job_id +
      ": " +
      output,
    )
    return None
  }
  let parsed = @json.parse(output) catch {
    _ => {
      log(
        "[orchestrator] ERROR cloudflare status invalid response for " +
        job_id +
        ": " +
        output,
      )
      return None
    }
  }
  match parsed {
    Object(root) => {
      let ok = match root.get("ok") {
        Some(True) => true
        _ => false
      }
      if not(ok) {
        let err = match root.get("error") {
          Some(String(s)) => s
          _ => "unknown error"
        }
        log(
          "[orchestrator] cloudflare status rejected for " + job_id + ": " + err,
        )
        return None
      }
      match root.get("job") {
        Some(Object(job)) =>
          match job.get("status") {
            Some(String(status)) => Some(status)
            _ => {
              log(
                "[orchestrator] ERROR cloudflare status missing `job.status` for " +
                job_id,
              )
              None
            }
          }
        _ => {
          log(
            "[orchestrator] ERROR cloudflare status missing `job` for " + job_id,
          )
          None
        }
      }
    }
    _ => {
      log(
        "[orchestrator] ERROR cloudflare status expected object for " + job_id,
      )
      None
    }
  }
}

///|
fn poll_cloudflare_jobs(
  submit_url : String,
  token : String,
  jobs : Array[SubmittedRemoteJob],
  log : (String) -> Unit,
  verbose : Bool,
) -> Unit {
  if jobs.is_empty() {
    return
  }
  let statuses : Map[String, String] = {}
  for job in jobs {
    statuses[job.job_id] = "queued"
  }
  let max_iterations = 600
  let mut iteration = 0
  let mut stale_iterations = 0
  while iteration < max_iterations {
    let mut pending = 0
    let mut any_change = false
    for job in jobs {
      match fetch_cloudflare_job_status(submit_url, token, job.job_id, log) {
        Some(status) => {
          let previous = statuses.get(job.job_id).unwrap_or("")
          if previous != status {
            any_change = true
            statuses[job.job_id] = status
            if verbose {
              log(
                "[orchestrator] remote status " +
                job.agent_id +
                " job_id=" +
                job.job_id +
                " -> " +
                status,
              )
            }
          }
        }
        None => ()
      }
      let current = statuses.get(job.job_id).unwrap_or("queued")
      if not(is_terminal_cloudflare_status(current)) {
        pending += 1
      }
    }
    if pending == 0 {
      break
    }
    if any_change {
      stale_iterations = 0
    } else {
      stale_iterations += 1
      if stale_iterations >= 30 {
        log(
          "[orchestrator] WARN no remote status change; stop polling early (jobs may still be running)",
        )
        break
      }
    }
    iteration += 1
    ignore(exec("sleep 2"))
  }
  if iteration >= max_iterations {
    log("[orchestrator] WARN cloudflare polling timeout reached")
  }
  let mut done_count = 0
  let mut failed_count = 0
  let mut cancelled_count = 0
  let mut queued_count = 0
  let mut running_count = 0
  for job in jobs {
    match statuses.get(job.job_id).unwrap_or("queued") {
      "done" => done_count += 1
      "failed" => failed_count += 1
      "cancelled" => cancelled_count += 1
      "running" => running_count += 1
      _ => queued_count += 1
    }
  }
  log(
    "[orchestrator] remote summary done=" +
    done_count.to_string() +
    " failed=" +
    failed_count.to_string() +
    " cancelled=" +
    cancelled_count.to_string() +
    " running=" +
    running_count.to_string() +
    " queued=" +
    queued_count.to_string(),
  )
}

///|
fn run_cloudflare_orchestration(
  config : OrchestratorConfig,
  subtasks : Array[SubtaskPlan],
  log : (String) -> Unit,
) -> Unit {
  let submit_url = match
    normalize_orchestrator_submit_url(config.orchestrator_url) {
    Some(url) => url
    None => {
      log(
        "[orchestrator] ERROR cloudflare mode requires --orchestrator-url (base URL or /api/v1/jobs/submit)",
      )
      return
    }
  }
  let ts = strip_trailing_whitespace(exec("date +%s"))
  let session_id = "bit-orch-" + ts
  log(
    "[orchestrator] Submitting " +
    subtasks.length().to_string() +
    " subtasks to cloudflare orchestrator: " +
    submit_url,
  )
  log(
    "[orchestrator] Remote policy: cloudflare=static-check only, execution=deno-worker",
  )
  let mut accepted = 0
  let jobs : Array[SubmittedRemoteJob] = []
  for i, subtask in subtasks {
    let agent_id = "agent-" + i.to_string()
    let branch = "agent/" + ts + "-" + i.to_string()
    let payload = create_cloudflare_payload(
      config,
      session_id,
      agent_id,
      branch,
      subtask.task,
      subtask.files,
    )
    match
      submit_cloudflare_job(submit_url, config.orchestrator_token, payload, log) {
      Some(job_id) => {
        accepted += 1
        jobs.push({ job_id, agent_id })
        log(
          "[orchestrator] queued " +
          agent_id +
          " -> job_id=" +
          job_id +
          " branch=" +
          branch,
        )
      }
      None =>
        log(
          "[orchestrator] failed to queue " +
          agent_id +
          " (task: " +
          subtask.task +
          ")",
        )
    }
  }
  log(
    "[orchestrator] cloudflare queue accepted " +
    accepted.to_string() +
    "/" +
    subtasks.length().to_string() +
    " jobs",
  )
  if accepted == subtasks.length() {
    log("[orchestrator] Remote orchestration submit completed.")
  } else {
    log("[orchestrator] Remote orchestration submit completed with errors.")
  }
  if not(jobs.is_empty()) {
    log("[orchestrator] Polling cloudflare job statuses...")
    poll_cloudflare_jobs(
      submit_url,
      config.orchestrator_token,
      jobs,
      log,
      config.verbose,
    )
  }
}

///|
/// Monitor decision
priv enum MonitorDecision {
  Continue
  CancelAgent(id~ : String, reason~ : String)
  AllDone
}

///|
/// Evaluate progress of all agents and decide next action
fn evaluate_progress(
  snapshots : Array[AgentSnapshot],
  session_dir : String,
  now : Int64,
  _log : (String) -> Unit,
) -> MonitorDecision {
  let mut all_done = true
  for s in snapshots {
    match s.status {
      Running | Pending => {
        all_done = false
        // Check for excessive errors (3+ consecutive error events)
        let events = coord_read_events_since(session_dir, s.agent_id, 0)
        let mut consecutive_errors = 0
        for ev in events {
          if ev.contains("\"type\":\"error\"") {
            consecutive_errors += 1
          } else {
            consecutive_errors = 0
          }
        }
        if consecutive_errors >= 3 {
          return CancelAgent(
            id=s.agent_id,
            reason="3+ consecutive errors detected",
          )
        }
        // Check for stall: no progress for 5 minutes
        if s.step > 0 && s.last_step_time > 0L && now - s.last_step_time > 300L {
          return CancelAgent(
            id=s.agent_id,
            reason="stalled: no progress for 5 minutes",
          )
        }
      }
      _ => ()
    }
  }
  if all_done {
    return AllDone
  }
  Continue
}

///|
fn cleanup_worktrees(
  wd : String,
  workers : Array[WorkerTask],
  log : (String) -> Unit,
) -> Unit {
  for w in workers {
    ignore(
      exec_checked(
        "git -C " +
        shell_escape(wd) +
        " worktree remove --force " +
        shell_escape(w.work_dir) +
        " 2>/dev/null",
        "worktree remove " + w.work_dir,
        exec,
        log,
      ),
    )
    ignore(
      exec_checked(
        "git -C " +
        shell_escape(wd) +
        " branch -d " +
        shell_escape(w.branch) +
        " 2>/dev/null",
        "branch delete " + w.branch,
        exec,
        log,
      ),
    )
  }
}

///|
pub fn run_orchestrator(
  config : OrchestratorConfig,
  on_output~ : (String) -> Unit,
) -> Unit {
  let verbose = config.verbose
  let wd = config.work_dir
  let log = fn(s : String) { on_output(s + "\n") }
  // Step 1: Plan subtasks
  if verbose {
    log("[orchestrator] Planning subtasks...")
  }
  let subtasks = plan_subtasks(config, log)
  if verbose {
    log(
      "[orchestrator] Planned " + subtasks.length().to_string() + " subtasks:",
    )
    for i, subtask in subtasks {
      log("  " + (i + 1).to_string() + ". " + subtask_display(subtask))
    }
  }
  if config.exec_mode == CloudflareMode {
    run_cloudflare_orchestration(config, subtasks, log)
    return
  }
  // If only 1 subtask, run directly (no need for parallel overhead)
  if subtasks.length() == 1 {
    if verbose {
      log("[orchestrator] Single subtask, running directly...")
    }
    let agent_config : LlmAgentConfig = {
      work_dir: wd,
      task: subtask_task_for_agent(subtasks[0]),
      branch_name: "agent/" + strip_trailing_whitespace(exec("date +%s")),
      target_branch: config.target_branch,
      provider_name: config.provider_name,
      model: config.model,
      max_steps: 20,
      max_runtime_sec: config.max_runtime_sec,
      max_tool_calls: config.max_tool_calls,
      stop_file: config.stop_file,
      auto_commit: true,
      auto_pr: config.auto_pr,
      pr_title: "",
      verbose: config.verbose,
      coord_dir: "",
      agent_id: "",
      env: None,
      coord: None,
      provider: None,
    }
    run_llm_agent(agent_config, on_output~)
    return
  }
  // Step 2: Setup coordination directory + worktrees
  let ts = strip_trailing_whitespace(exec("date +%s"))
  let session_dir = coord_init("/tmp", ts)
  if verbose {
    log("[orchestrator] Coordination dir: " + session_dir)
  }
  let workers : Array[WorkerTask] = []
  for i, subtask in subtasks {
    let agent_id = "agent-" + i.to_string()
    let branch = "agent/" + ts + "-" + i.to_string()
    let wt_dir = "/tmp/bit-agent-" + ts + "-" + i.to_string()
    coord_init_agent(session_dir, agent_id)
    coord_write_status(session_dir, agent_id, Pending)
    coord_write_branch(session_dir, agent_id, branch)
    let worktree_cmd = "git -C " +
      shell_escape(wd) +
      " worktree add " +
      shell_escape(wt_dir) +
      " -b " +
      shell_escape(branch) +
      " 2>&1"
    if exec_checked(worktree_cmd, "worktree add " + wt_dir, exec, log) is None {
      coord_write_status(session_dir, agent_id, Cancelled)
      cleanup_worktrees(wd, workers, log)
      coord_cleanup(session_dir)
      return
    }
    workers.push({
      task: subtask_task_for_agent(subtask),
      files: subtask.files,
      work_dir: wt_dir,
      branch,
      agent_id,
    })
    if verbose {
      log("[orchestrator] Worktree: " + wt_dir + " -> " + branch)
    }
  }
  // Step 3: Select runner and spawn agents
  let in_process = config.exec_mode == InProcessMode
  let runner : &AgentRunner = if in_process {
    let r = InProcessAgentRunner::new(
      config.provider_name,
      config.model,
      config.verbose,
    )
    let tr : &AgentRunner = r
    tr
  } else {
    let r = ProcessAgentRunner::new(
      config.provider_name,
      config.model,
      config.verbose,
    )
    if config.verbose {
      log("[orchestrator] agent binary: " + r.bit_binary)
    }
    let tr : &AgentRunner = r
    tr
  }
  let mode = if in_process { "in-process" } else { "process" }
  if verbose {
    log(
      "\n[orchestrator] Spawning " +
      workers.length().to_string() +
      " agents (" +
      mode +
      ")...",
    )
  }
  for w in workers {
    let log_file = session_dir + "/agents/" + w.agent_id + "/log.txt"
    let agent_config : LlmAgentConfig = {
      work_dir: w.work_dir,
      task: w.task,
      branch_name: w.branch,
      target_branch: config.target_branch,
      provider_name: config.provider_name,
      model: config.model,
      max_steps: 20,
      max_runtime_sec: config.max_runtime_sec,
      max_tool_calls: config.max_tool_calls,
      stop_file: config.stop_file,
      auto_commit: false,
      auto_pr: false,
      pr_title: "",
      verbose: config.verbose,
      coord_dir: session_dir,
      agent_id: w.agent_id,
      env: None,
      coord: None,
      provider: None,
    }
    let handle = runner.spawn_agent(agent_config, log_file)
    if not(in_process) {
      let pid = @strconv.parse_int(handle) catch { _ => 0 }
      coord_write_pid(session_dir, w.agent_id, pid)
    }
    if verbose {
      let scoped_task = if w.files.is_empty() {
        w.task
      } else {
        w.task + " [files: " + w.files.join(", ") + "]"
      }
      log("[orchestrator] Spawned " + w.agent_id + ": " + scoped_task)
    }
  }
  // Step 4: Wait for all agents
  if verbose {
    log("\n[orchestrator] Monitoring agents...")
  }
  runner.wait_all(session_dir, 1200, log)
  // Step 5: Commit changes in each completed worktree
  for w in workers {
    let status = coord_read_status(session_dir, w.agent_id)
    if status != Done && status != Running {
      if verbose {
        log(
          "[orchestrator] Skipping " +
          w.agent_id +
          " (status: " +
          status.to_string() +
          ")",
        )
      }
      continue
    }
    let changes = exec(
      "cd " +
      shell_escape(w.work_dir) +
      " && git status --porcelain 2>/dev/null",
    )
    if is_exec_error(changes) {
      coord_write_status(session_dir, w.agent_id, Cancelled)
      log(
        "[orchestrator] ERROR git status failed for " +
        w.agent_id +
        ": " +
        changes,
      )
      continue
    }
    if not(changes.is_empty()) {
      let add_cmd = "cd " + shell_escape(w.work_dir) + " && git add -A"
      if exec_checked(add_cmd, "git add " + w.agent_id, exec, log) is None {
        coord_write_status(session_dir, w.agent_id, Cancelled)
        continue
      }
      let commit_cmd = "cd " +
        shell_escape(w.work_dir) +
        " && git commit -m " +
        shell_escape("agent: " + w.task)
      if exec_checked(commit_cmd, "git commit " + w.agent_id, exec, log) is None {
        coord_write_status(session_dir, w.agent_id, Cancelled)
        continue
      }
      if verbose {
        log("[orchestrator] Committed on " + w.branch)
      }
    } else if verbose {
      log("[orchestrator] No changes on " + w.branch)
    }
  }
  // Step 6: Merge all branches
  let merge_branch = "agent/combined-" + ts
  let create_merge_branch_cmd = "cd " +
    shell_escape(wd) +
    " && git checkout -b " +
    shell_escape(merge_branch)
  if exec_checked(
      create_merge_branch_cmd,
      "git checkout -b " + merge_branch,
      exec,
      log,
    )
    is None {
    cleanup_worktrees(wd, workers, log)
    coord_cleanup(session_dir)
    return
  }
  let mut merge_failed = false
  for w in workers {
    let status = coord_read_status(session_dir, w.agent_id)
    if status != Done && status != Running {
      continue
    }
    let result = exec(
      "cd " +
      shell_escape(wd) +
      " && git merge --no-edit " +
      shell_escape(w.branch) +
      " 2>&1",
    )
    if is_exec_error(result) {
      merge_failed = true
      log("[orchestrator] ERROR merge failed for " + w.branch + ": " + result)
      continue
    }
    if verbose {
      log("[orchestrator] Merge " + w.branch + ": " + result)
    }
  }
  if merge_failed {
    cleanup_worktrees(wd, workers, log)
    coord_cleanup(session_dir)
    return
  }
  // Step 7: Cleanup worktrees + coordination dir
  cleanup_worktrees(wd, workers, log)
  coord_cleanup(session_dir)
  if verbose {
    log("[orchestrator] Cleaned up worktrees and coordination dir")
  }
  // Step 8: PR
  if config.auto_pr {
    let push_result = exec_with_timeout(
      "cd " +
      shell_escape(wd) +
      " && git push -u origin " +
      shell_escape(merge_branch),
      60000,
    )
    if is_exec_error(push_result) {
      log("[orchestrator] ERROR git push failed: " + push_result)
      return
    }
    let result = exec_with_timeout(
      "cd " +
      shell_escape(wd) +
      " && gh pr create --title " +
      shell_escape("agent: " + config.task) +
      " --body 'Created by bit orchestrator' --base " +
      shell_escape(config.target_branch),
      60000,
    )
    if is_exec_error(result) {
      log("[orchestrator] ERROR gh pr create failed: " + result)
      return
    }
    log("[pr] " + result)
  }
  log("\n[orchestrator] Done. Branch: " + merge_branch)
}

///|
/// Agent lifecycle status
pub(all) enum AgentStatus {
  Pending
  Running
  Done
  Failed
  Cancelled
}

///|
pub fn AgentStatus::to_string(self : AgentStatus) -> String {
  match self {
    Pending => "pending"
    Running => "running"
    Done => "done"
    Failed => "failed"
    Cancelled => "cancelled"
  }
}

///|
pub fn AgentStatus::parse(s : String) -> AgentStatus {
  match s {
    "running" => Running
    "done" => Done
    "failed" => Failed
    "cancelled" => Cancelled
    _ => Pending
  }
}

///|
pub impl Eq for AgentStatus with equal(self, other) -> Bool {
  self.to_string() == other.to_string()
}

///|
/// Event written by agent to coordination directory
pub(all) enum CoordEvent {
  StepCompleted(step~ : Int, tools_called~ : Int)
  FileChanged(path~ : String)
  TestResult(passed~ : Bool, output~ : String)
  Error(message~ : String)
  Finished(summary~ : String)
}

///|
fn coord_event_to_json(event : CoordEvent) -> String {
  match event {
    StepCompleted(step~, tools_called~) =>
      "{\"type\":\"step_completed\",\"step\":" +
      step.to_string() +
      ",\"tools_called\":" +
      tools_called.to_string() +
      "}"
    FileChanged(path~) =>
      "{\"type\":\"file_changed\",\"path\":" + json_escape(path) + "}"
    TestResult(passed~, output~) =>
      "{\"type\":\"test_result\",\"passed\":" +
      passed.to_string() +
      ",\"output\":" +
      json_escape(output) +
      "}"
    Error(message~) =>
      "{\"type\":\"error\",\"message\":" + json_escape(message) + "}"
    Finished(summary~) =>
      "{\"type\":\"finished\",\"summary\":" + json_escape(summary) + "}"
  }
}

///|
fn json_escape(s : String) -> String {
  let buf = StringBuilder::new()
  buf.write_char('"')
  for ch in s {
    match ch {
      '"' => buf.write_string("\\\"")
      '\\' => buf.write_string("\\\\")
      '\n' => buf.write_string("\\n")
      '\r' => buf.write_string("\\r")
      '\t' => buf.write_string("\\t")
      _ => buf.write_char(ch)
    }
  }
  buf.write_char('"')
  buf.to_string()
}

///|
/// Snapshot of one agent's state
pub(all) struct AgentSnapshot {
  agent_id : String
  status : AgentStatus
  pid : Int
  step : Int
  branch : String
  last_step_time : Int64
}

///|
/// Coordination backend trait for agent lifecycle management
pub(open) trait CoordinationBackend {
  init_session(Self, session_id : String) -> String
  init_agent(Self, dir : String, agent_id : String) -> Unit
  write_status(Self, dir : String, agent_id : String, status : AgentStatus) -> Unit
  write_step(Self, dir : String, agent_id : String, step : Int) -> Unit
  write_pid(Self, dir : String, agent_id : String, pid : Int) -> Unit
  write_branch(Self, dir : String, agent_id : String, branch : String) -> Unit
  append_event(Self, dir : String, agent_id : String, event : CoordEvent) -> Unit
  read_status(Self, dir : String, agent_id : String) -> AgentStatus
  read_all_agents(Self, dir : String) -> Array[AgentSnapshot]
  read_events_since(Self, dir : String, agent_id : String, since : Int) -> Array[
    String,
  ]
  cleanup(Self, dir : String) -> Unit
}

///|
/// File-system based coordination backend
pub(all) struct FileCoordinationBackend {
  base_dir : String
}

///|
pub fn FileCoordinationBackend::new(
  base_dir : String,
) -> FileCoordinationBackend {
  { base_dir, }
}

///|
pub fn file_coordination_backend(base_dir : String) -> &CoordinationBackend {
  FileCoordinationBackend::new(base_dir)
}

///|
impl CoordinationBackend for FileCoordinationBackend with init_session(
  self,
  session_id,
) {
  let dir = self.base_dir + "/bit-orch-" + session_id
  ignore(exec("mkdir -p " + shell_escape(dir + "/agents")))
  ignore(exec("mkdir -p " + shell_escape(dir + "/events")))
  dir
}

///|
impl CoordinationBackend for FileCoordinationBackend with init_agent(
  _self,
  dir,
  agent_id,
) {
  ignore(exec("mkdir -p " + shell_escape(dir + "/agents/" + agent_id)))
}

///|
impl CoordinationBackend for FileCoordinationBackend with write_status(
  _self,
  dir,
  agent_id,
  status,
) {
  let path = dir + "/agents/" + agent_id + "/status"
  ignore(
    exec(
      "printf '%s' " +
      shell_escape(status.to_string()) +
      " > " +
      shell_escape(path),
    ),
  )
}

///|
impl CoordinationBackend for FileCoordinationBackend with write_step(
  _self,
  dir,
  agent_id,
  step,
) {
  let path = dir + "/agents/" + agent_id + "/step"
  ignore(
    exec(
      "printf '%s' " +
      shell_escape(step.to_string()) +
      " > " +
      shell_escape(path),
    ),
  )
  let time_path = dir + "/agents/" + agent_id + "/step_time"
  let now = strip_trailing_whitespace(exec("date +%s"))
  ignore(
    exec("printf '%s' " + shell_escape(now) + " > " + shell_escape(time_path)),
  )
}

///|
impl CoordinationBackend for FileCoordinationBackend with write_pid(
  _self,
  dir,
  agent_id,
  pid,
) {
  let path = dir + "/agents/" + agent_id + "/pid"
  ignore(
    exec(
      "printf '%s' " +
      shell_escape(pid.to_string()) +
      " > " +
      shell_escape(path),
    ),
  )
}

///|
impl CoordinationBackend for FileCoordinationBackend with write_branch(
  _self,
  dir,
  agent_id,
  branch,
) {
  let path = dir + "/agents/" + agent_id + "/branch"
  ignore(
    exec("printf '%s' " + shell_escape(branch) + " > " + shell_escape(path)),
  )
}

///|
impl CoordinationBackend for FileCoordinationBackend with append_event(
  _self,
  dir,
  agent_id,
  event,
) {
  let seq = strip_trailing_whitespace(
    exec("ls " + shell_escape(dir + "/events") + " 2>/dev/null | wc -l"),
  )
  let seq_num = @strconv.parse_int(seq.trim().to_string()) catch { _ => 0 }
  let padded = pad_int(seq_num, 6)
  let filename = padded + "_" + agent_id + ".json"
  let path = dir + "/events/" + filename
  let json = coord_event_to_json(event)
  ignore(exec("printf '%s' " + shell_escape(json) + " > " + shell_escape(path)))
}

///|
impl CoordinationBackend for FileCoordinationBackend with read_status(
  _self,
  dir,
  agent_id,
) {
  let path = dir + "/agents/" + agent_id + "/status"
  let raw = strip_trailing_whitespace(
    exec("cat " + shell_escape(path) + " 2>/dev/null"),
  )
  AgentStatus::parse(raw)
}

///|
fn file_coord_read_pid(dir : String, agent_id : String) -> Int {
  let path = dir + "/agents/" + agent_id + "/pid"
  let raw = strip_trailing_whitespace(
    exec("cat " + shell_escape(path) + " 2>/dev/null"),
  )
  @strconv.parse_int(raw) catch {
    _ => 0
  }
}

///|
fn file_coord_read_step(dir : String, agent_id : String) -> Int {
  let path = dir + "/agents/" + agent_id + "/step"
  let raw = strip_trailing_whitespace(
    exec("cat " + shell_escape(path) + " 2>/dev/null"),
  )
  @strconv.parse_int(raw) catch {
    _ => 0
  }
}

///|
fn file_coord_read_branch(dir : String, agent_id : String) -> String {
  let path = dir + "/agents/" + agent_id + "/branch"
  strip_trailing_whitespace(exec("cat " + shell_escape(path) + " 2>/dev/null"))
}

///|
fn file_coord_read_step_time(dir : String, agent_id : String) -> Int64 {
  let path = dir + "/agents/" + agent_id + "/step_time"
  let raw = strip_trailing_whitespace(
    exec("cat " + shell_escape(path) + " 2>/dev/null"),
  )
  if raw.is_empty() {
    return 0L
  }
  let n = @strconv.parse_int(raw) catch { _ => 0 }
  n.to_int64()
}

///|
impl CoordinationBackend for FileCoordinationBackend with read_all_agents(
  _self,
  dir,
) {
  let raw = strip_trailing_whitespace(
    exec("ls " + shell_escape(dir + "/agents") + " 2>/dev/null"),
  )
  if raw.is_empty() {
    return []
  }
  let result : Array[AgentSnapshot] = []
  let lines = split_lines(raw)
  for line in lines {
    let id = strip_trailing_whitespace(line)
    if id.is_empty() {
      continue
    }
    let path = dir + "/agents/" + id + "/status"
    let status_raw = strip_trailing_whitespace(
      exec("cat " + shell_escape(path) + " 2>/dev/null"),
    )
    let snapshot : AgentSnapshot = {
      agent_id: id,
      status: AgentStatus::parse(status_raw),
      pid: file_coord_read_pid(dir, id),
      step: file_coord_read_step(dir, id),
      branch: file_coord_read_branch(dir, id),
      last_step_time: file_coord_read_step_time(dir, id),
    }
    result.push(snapshot)
  }
  result
}

///|
impl CoordinationBackend for FileCoordinationBackend with read_events_since(
  _self,
  dir,
  agent_id,
  since,
) {
  let raw = strip_trailing_whitespace(
    exec("ls " + shell_escape(dir + "/events") + " 2>/dev/null"),
  )
  if raw.is_empty() {
    return []
  }
  let result : Array[String] = []
  let files = split_lines(raw)
  for file in files {
    let fname = strip_trailing_whitespace(file)
    if fname.is_empty() {
      continue
    }
    if not(fname.contains("_" + agent_id + ".json")) {
      continue
    }
    let seq_str = take_chars(fname, 6)
    let seq = @strconv.parse_int(seq_str) catch { _ => 0 }
    if seq < since {
      continue
    }
    let content = strip_trailing_whitespace(
      exec("cat " + shell_escape(dir + "/events/" + fname) + " 2>/dev/null"),
    )
    if not(content.is_empty()) {
      result.push(content)
    }
  }
  result
}

///|
impl CoordinationBackend for FileCoordinationBackend with cleanup(_self, dir) {
  ignore(exec("rm -rf " + shell_escape(dir)))
}

// --- Thin wrappers for backward compatibility ---

///|
/// Initialize coordination directory structure
pub fn coord_init(base_dir : String, session_id : String) -> String {
  let backend = FileCoordinationBackend::new(base_dir)
  (backend : &CoordinationBackend).init_session(session_id)
}

///|
/// Initialize agent subdirectory in coordination dir
pub fn coord_init_agent(dir : String, agent_id : String) -> Unit {
  let backend = FileCoordinationBackend::new("")
  (backend : &CoordinationBackend).init_agent(dir, agent_id)
}

///|
/// Write agent status
pub fn coord_write_status(
  dir : String,
  agent_id : String,
  status : AgentStatus,
) -> Unit {
  let backend = FileCoordinationBackend::new("")
  (backend : &CoordinationBackend).write_status(dir, agent_id, status)
}

///|
/// Write agent PID
pub fn coord_write_pid(dir : String, agent_id : String, pid : Int) -> Unit {
  let backend = FileCoordinationBackend::new("")
  (backend : &CoordinationBackend).write_pid(dir, agent_id, pid)
}

///|
/// Write agent step number
pub fn coord_write_step(dir : String, agent_id : String, step : Int) -> Unit {
  let backend = FileCoordinationBackend::new("")
  (backend : &CoordinationBackend).write_step(dir, agent_id, step)
}

///|
/// Write agent branch name
pub fn coord_write_branch(
  dir : String,
  agent_id : String,
  branch : String,
) -> Unit {
  let backend = FileCoordinationBackend::new("")
  (backend : &CoordinationBackend).write_branch(dir, agent_id, branch)
}

///|
/// Append event to coordination directory
pub fn coord_append_event(
  dir : String,
  agent_id : String,
  event : CoordEvent,
) -> Unit {
  let backend = FileCoordinationBackend::new("")
  (backend : &CoordinationBackend).append_event(dir, agent_id, event)
}

///|
/// Read agent status
pub fn coord_read_status(dir : String, agent_id : String) -> AgentStatus {
  let backend = FileCoordinationBackend::new("")
  (backend : &CoordinationBackend).read_status(dir, agent_id)
}

///|
/// Read all agent snapshots from coordination directory
pub fn coord_read_all_agents(dir : String) -> Array[AgentSnapshot] {
  let backend = FileCoordinationBackend::new("")
  (backend : &CoordinationBackend).read_all_agents(dir)
}

///|
/// Read events since sequence number for an agent
pub fn coord_read_events_since(
  dir : String,
  agent_id : String,
  since : Int,
) -> Array[String] {
  let backend = FileCoordinationBackend::new("")
  (backend : &CoordinationBackend).read_events_since(dir, agent_id, since)
}

///|
/// Cleanup coordination directory
pub fn coord_cleanup(dir : String) -> Unit {
  let backend = FileCoordinationBackend::new("")
  (backend : &CoordinationBackend).cleanup(dir)
}

// --- Helper functions ---

///|
fn take_chars(s : String, n : Int) -> String {
  let buf = StringBuilder::new()
  let mut count = 0
  for ch in s {
    if count >= n {
      break
    }
    buf.write_char(ch)
    count += 1
  }
  buf.to_string()
}

///|
fn pad_int(n : Int, width : Int) -> String {
  let s = n.to_string()
  let buf = StringBuilder::new()
  for i = 0; i < width - s.length(); i = i + 1 {
    buf.write_char('0')
  }
  buf.write_string(s)
  buf.to_string()
}

///|
fn split_lines(s : String) -> Array[String] {
  let result : Array[String] = []
  let buf = StringBuilder::new()
  for ch in s {
    if ch == '\n' {
      result.push(buf.to_string())
      buf.reset()
    } else {
      buf.write_char(ch)
    }
  }
  let last = buf.to_string()
  if not(last.is_empty()) {
    result.push(last)
  }
  result
}

///|
fn json_get_str(j : Json, field : String) -> String {
  match j {
    Object(m) =>
      match m.get(field) {
        Some(String(s)) => s
        _ => ""
      }
    _ => ""
  }
}

///|
fn json_get_int(j : Json, field : String, default_ : Int) -> Int {
  match j {
    Object(m) =>
      match m.get(field) {
        Some(Number(n, ..)) => n.to_int()
        _ => default_
      }
    _ => default_
  }
}

///|
fn json_get_bool(j : Json, field : String, default_ : Bool) -> Bool {
  match j {
    Object(m) =>
      match m.get(field) {
        Some(True) => true
        Some(False) => false
        _ => default_
      }
    _ => default_
  }
}

///|
fn jsonrpc_response(id : Json, result : Json) -> String {
  let resp : Map[String, Json] = {}
  resp["jsonrpc"] = "2.0".to_json()
  resp["id"] = id
  resp["result"] = result
  Json::object(resp).stringify()
}

///|
fn jsonrpc_error(id : Json, code : Int, message : String) -> String {
  let err : Map[String, Json] = {}
  err["code"] = Json::number(code.to_double())
  err["message"] = message.to_json()
  let resp : Map[String, Json] = {}
  resp["jsonrpc"] = "2.0".to_json()
  resp["id"] = id
  resp["error"] = Json::object(err)
  Json::object(resp).stringify()
}

///|
fn jsonrpc_notification(meth : String, params : Json) -> String {
  let msg : Map[String, Json] = {}
  msg["jsonrpc"] = "2.0".to_json()
  msg["method"] = meth.to_json()
  msg["params"] = params
  Json::object(msg).stringify()
}

///|
fn tool_output_notification(id : Json, tool : String, delta : String) -> String {
  let payload : Map[String, Json] = {}
  payload["type"] = "tool_output".to_json()
  payload["requestId"] = id
  payload["tool"] = tool.to_json()
  payload["delta"] = delta.to_json()
  let params : Map[String, Json] = {}
  params["level"] = "info".to_json()
  params["logger"] = "bit-agent".to_json()
  params["data"] = Json::object(payload)
  jsonrpc_notification("notifications/message", Json::object(params))
}

///|
fn maybe_stream_tool_output(
  stream : Bool,
  id : Json,
  tool : String,
  delta : String,
) -> Unit {
  if stream && not(delta.is_empty()) {
    write_message(tool_output_notification(id, tool, delta))
  }
}

///|
fn tool_result_text(text : String) -> Json {
  let content : Map[String, Json] = {}
  content["type"] = "text".to_json()
  content["text"] = text.to_json()
  let result : Map[String, Json] = {}
  result["content"] = Json::array([Json::object(content)])
  Json::object(result)
}

///|
fn tool_result_error(text : String) -> Json {
  let content : Map[String, Json] = {}
  content["type"] = "text".to_json()
  content["text"] = text.to_json()
  let result : Map[String, Json] = {}
  result["content"] = Json::array([Json::object(content)])
  result["isError"] = Json::boolean(true)
  Json::object(result)
}

///|
fn handle_initialize(id : Json) -> String {
  let caps : Map[String, Json] = {}
  caps["tools"] = Json::object({})
  let info : Map[String, Json] = {}
  info["name"] = "bit-agent".to_json()
  info["version"] = "0.1.0".to_json()
  let result : Map[String, Json] = {}
  result["protocolVersion"] = "2024-11-05".to_json()
  result["capabilities"] = Json::object(caps)
  result["serverInfo"] = Json::object(info)
  jsonrpc_response(id, Json::object(result))
}

///|
fn build_tool_defs() -> Json {
  let run_agent_schema : Map[String, Json] = {}
  run_agent_schema["type"] = "object".to_json()
  let ra_props : Map[String, Json] = {}
  ra_props["task"] = Json::object({
    "type": "string".to_json(),
    "description": "Task description for the agent".to_json(),
  })
  ra_props["work_dir"] = Json::object({
    "type": "string".to_json(),
    "description": "Working directory (default: cwd)".to_json(),
  })
  ra_props["provider"] = Json::object({
    "type": "string".to_json(),
    "description": "LLM provider: openrouter|anthropic|openai|claude_code".to_json(),
  })
  ra_props["model"] = Json::object({
    "type": "string".to_json(),
    "description": "Model name".to_json(),
  })
  ra_props["max_steps"] = Json::object({
    "type": "integer".to_json(),
    "description": "Max agent steps (default: 20)".to_json(),
  })
  ra_props["max_runtime_sec"] = Json::object({
    "type": "integer".to_json(),
    "description": "Max runtime seconds before forced stop (default: 900)".to_json(),
  })
  ra_props["max_tool_calls"] = Json::object({
    "type": "integer".to_json(),
    "description": "Max tool calls before forced stop (default: 60)".to_json(),
  })
  ra_props["stop_file"] = Json::object({
    "type": "string".to_json(),
    "description": "Stop when this file appears (or BIT_AGENT_STOP_FILE if empty)".to_json(),
  })
  ra_props["no_commit"] = Json::object({
    "type": "boolean".to_json(),
    "description": "Skip auto-commit (default: false)".to_json(),
  })
  ra_props["stream"] = Json::object({
    "type": "boolean".to_json(),
    "description": "Stream progress via notifications/message (default: true)".to_json(),
  })
  run_agent_schema["properties"] = Json::object(ra_props)
  run_agent_schema["required"] = Json::array(["task".to_json()])
  let run_agent_tool : Map[String, Json] = {}
  run_agent_tool["name"] = "run_agent".to_json()
  run_agent_tool["description"] = "Run a coding agent that reads/writes files to complete a task".to_json()
  run_agent_tool["inputSchema"] = Json::object(run_agent_schema)
  // orchestrate tool
  let orch_schema : Map[String, Json] = {}
  orch_schema["type"] = "object".to_json()
  let o_props : Map[String, Json] = {}
  o_props["task"] = Json::object({
    "type": "string".to_json(),
    "description": "High-level task to split into parallel subtasks".to_json(),
  })
  o_props["work_dir"] = Json::object({
    "type": "string".to_json(),
    "description": "Working directory (default: cwd)".to_json(),
  })
  o_props["provider"] = Json::object({
    "type": "string".to_json(),
    "description": "LLM provider".to_json(),
  })
  o_props["model"] = Json::object({
    "type": "string".to_json(),
    "description": "Model name".to_json(),
  })
  o_props["max_workers"] = Json::object({
    "type": "integer".to_json(),
    "description": "Max parallel workers (default: 3)".to_json(),
  })
  o_props["max_runtime_sec"] = Json::object({
    "type": "integer".to_json(),
    "description": "Max runtime seconds per worker before forced stop (default: 900)".to_json(),
  })
  o_props["max_tool_calls"] = Json::object({
    "type": "integer".to_json(),
    "description": "Max tool calls per worker before forced stop (default: 60)".to_json(),
  })
  o_props["stop_file"] = Json::object({
    "type": "string".to_json(),
    "description": "Stop when this file appears (or BIT_AGENT_STOP_FILE if empty)".to_json(),
  })
  o_props["exec_mode"] = Json::object({
    "type": "string".to_json(),
    "description": "Execution mode: process|in-process|cloudflare (cloudflare-static, deno-remote aliases)".to_json(),
  })
  o_props["orchestrator_url"] = Json::object({
    "type": "string".to_json(),
    "description": "Cloudflare orchestrator URL (base or /api/v1/jobs/submit, static-check on cloudflare + execution on deno-worker)".to_json(),
  })
  o_props["orchestrator_token"] = Json::object({
    "type": "string".to_json(),
    "description": "Optional bearer token for cloudflare mode".to_json(),
  })
  o_props["stream"] = Json::object({
    "type": "boolean".to_json(),
    "description": "Stream progress via notifications/message (default: true)".to_json(),
  })
  orch_schema["properties"] = Json::object(o_props)
  orch_schema["required"] = Json::array(["task".to_json()])
  let orch_tool : Map[String, Json] = {}
  orch_tool["name"] = "run_orchestrator".to_json()
  orch_tool["description"] = "Run parallel coding agents on subtasks with automatic planning and merging".to_json()
  orch_tool["inputSchema"] = Json::object(orch_schema)
  let result : Map[String, Json] = {}
  result["tools"] = Json::array([
    Json::object(run_agent_tool),
    Json::object(orch_tool),
  ])
  Json::object(result)
}

///|
fn handle_tools_list(id : Json) -> String {
  jsonrpc_response(id, build_tool_defs())
}

///|
fn get_work_dir(args : Json) -> String {
  let wd = json_get_str(args, "work_dir")
  if wd.is_empty() {
    @agent_llm.strip_trailing_whitespace(@llm_ffi.exec_sync("pwd", 5000))
  } else {
    wd
  }
}

///|
fn handle_tools_call(id : Json, params : Json) -> String {
  let name = json_get_str(params, "name")
  let arguments = match params {
    Object(m) =>
      match m.get("arguments") {
        Some(obj) => obj
        _ => Json::object({})
      }
    _ => Json::object({})
  }
  match name {
    "run_agent" => handle_run_agent(id, arguments)
    "run_orchestrator" => handle_run_orchestrator(id, arguments)
    _ => jsonrpc_error(id, -32601, "Unknown tool: " + name)
  }
}

///|
fn handle_run_agent(id : Json, args : Json) -> String {
  let task = json_get_str(args, "task")
  if task.is_empty() {
    return jsonrpc_response(id, tool_result_error("task is required"))
  }
  let work_dir = get_work_dir(args)
  let provider = json_get_str(args, "provider")
  let model = json_get_str(args, "model")
  let max_steps = json_get_int(args, "max_steps", 20)
  let max_runtime_sec = json_get_int(args, "max_runtime_sec", 900)
  let max_tool_calls = json_get_int(args, "max_tool_calls", 60)
  let stop_file = json_get_str(args, "stop_file")
  let no_commit = json_get_bool(args, "no_commit", false)
  let stream = json_get_bool(args, "stream", true)
  let ts = @agent_llm.strip_trailing_whitespace(
    @llm_ffi.exec_sync("date +%s", 5000),
  )
  let config : @agent_llm.LlmAgentConfig = {
    work_dir,
    task,
    branch_name: "agent/" + ts,
    target_branch: "main",
    provider_name: if provider.is_empty() {
      "openrouter"
    } else {
      provider
    },
    model,
    max_steps,
    max_runtime_sec,
    max_tool_calls,
    stop_file,
    auto_commit: not(no_commit),
    auto_pr: false,
    pr_title: "",
    verbose: true,
    coord_dir: "",
    agent_id: "",
    env: None,
    coord: None,
    provider: None,
  }
  let buf = StringBuilder::new()
  log("[mcp] Running agent: task=" + task)
  @agent_llm.run_llm_agent(config, on_output=fn(s) {
    buf.write_string(s)
    maybe_stream_tool_output(stream, id, "run_agent", s)
    log("[agent] " + s)
  })
  jsonrpc_response(id, tool_result_text(buf.to_string()))
}

///|
fn handle_run_orchestrator(id : Json, args : Json) -> String {
  let task = json_get_str(args, "task")
  if task.is_empty() {
    return jsonrpc_response(id, tool_result_error("task is required"))
  }
  let work_dir = get_work_dir(args)
  let provider = json_get_str(args, "provider")
  let model = json_get_str(args, "model")
  let max_workers = json_get_int(args, "max_workers", 3)
  let max_runtime_sec = json_get_int(args, "max_runtime_sec", 900)
  let max_tool_calls = json_get_int(args, "max_tool_calls", 60)
  let stop_file = json_get_str(args, "stop_file")
  let exec_mode = @agent_llm.parse_orchestrator_exec_mode(
    json_get_str(args, "exec_mode"),
  )
  let orchestrator_url = json_get_str(args, "orchestrator_url")
  let orchestrator_token = json_get_str(args, "orchestrator_token")
  let stream = json_get_bool(args, "stream", true)
  let config : @agent_llm.OrchestratorConfig = {
    work_dir,
    task,
    provider_name: if provider.is_empty() {
      "openrouter"
    } else {
      provider
    },
    model,
    max_workers,
    max_runtime_sec,
    max_tool_calls,
    stop_file,
    target_branch: "main",
    auto_pr: false,
    verbose: true,
    exec_mode,
    orchestrator_url,
    orchestrator_token,
  }
  let buf = StringBuilder::new()
  log("[mcp] Orchestrating: task=" + task)
  @agent_llm.run_orchestrator(config, on_output=fn(s) {
    buf.write_string(s)
    maybe_stream_tool_output(stream, id, "run_orchestrator", s)
    log("[orch] " + s)
  })
  jsonrpc_response(id, tool_result_text(buf.to_string()))
}

///|
fn extract_request_id(json : Json) -> Json {
  match json {
    Object(m) =>
      match m.get("id") {
        Some(v) => v
        _ => Json::null()
      }
    _ => Json::null()
  }
}

///|
fn extract_request_params(json : Json) -> Json {
  match json {
    Object(m) =>
      match m.get("params") {
        Some(v) => v
        _ => Json::object({})
      }
    _ => Json::object({})
  }
}

///|
fn dispatch_request(meth : String, id : Json, params : Json) -> String {
  match meth {
    "initialize" => handle_initialize(id)
    "tools/list" => handle_tools_list(id)
    "tools/call" => handle_tools_call(id, params)
    _ => jsonrpc_error(id, -32601, "Method not found: " + meth)
  }
}

///|
fn process_message(msg : String) -> String? {
  let json = @json.parse(msg) catch {
    _ => {
      log("[mcp] Failed to parse JSON: " + msg)
      return Some(jsonrpc_error(Json::null(), -32700, "Parse error"))
    }
  }
  let meth = json_get_str(json, "method")
  let id = extract_request_id(json)
  let params = extract_request_params(json)
  if meth.is_empty() {
    return Some(jsonrpc_error(id, -32600, "Invalid Request"))
  }
  log("[mcp] method=" + meth)
  if meth == "notifications/initialized" || meth == "initialized" {
    return None
  }
  Some(dispatch_request(meth, id, params))
}

///|
pub fn run_mcp_server() -> Unit {
  log("[mcp] bit-agent MCP server started")
  while true {
    let msg = read_message()
    if msg.is_empty() {
      break
    }
    match process_message(msg) {
      Some(response) => write_message(response)
      None => ()
    }
  }
  log("[mcp] Server stopped")
}

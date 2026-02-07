///|
fn shell_escape(s : String) -> String {
  let buf = StringBuilder::new()
  buf.write_char('\'')
  for ch in s {
    if ch == '\'' {
      buf.write_string("'\\''")
    } else {
      buf.write_char(ch)
    }
  }
  buf.write_char('\'')
  buf.to_string()
}

///|
fn resolve_path(work_dir : String, path : String) -> String {
  if path.has_prefix("/") {
    path
  } else {
    work_dir + "/" + path
  }
}

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
fn json_get_int_opt(j : Json, field : String) -> Int? {
  match j {
    Object(m) =>
      match m.get(field) {
        Some(Number(n, ..)) => Some(n.to_int())
        _ => None
      }
    _ => None
  }
}

///|
pub fn strip_trailing_whitespace(s : String) -> String {
  let chars : Array[Char] = []
  for ch in s {
    chars.push(ch)
  }
  let mut end = chars.length()
  while end > 0 {
    let ch = chars[end - 1]
    if ch == '\n' || ch == '\r' || ch == ' ' || ch == '\t' {
      end = end - 1
    } else {
      break
    }
  }
  if end == chars.length() {
    s
  } else {
    let buf = StringBuilder::new()
    for j = 0; j < end; j = j + 1 {
      buf.write_char(chars[j])
    }
    buf.to_string()
  }
}

///|
fn exec(command : String) -> String {
  @ffi.exec_sync(command, 30000)
}

///|
fn exec_with_timeout(command : String, timeout_ms : Int) -> String {
  @ffi.exec_sync(command, timeout_ms)
}

///|
pub fn create_tool_registry(env : &ToolEnvironment) -> @llmlib.ToolRegistry {
  let registry = @llmlib.ToolRegistry::new()
  let tracker = LoopTracker::new()

  // read_file
  registry.register(
    "read_file",
    "Read file contents. Always read before modifying. Do NOT guess file contents.",
    @llmlib.SchemaBuilder::new()
    .string(
      "path",
      "File path (relative to work_dir or absolute)",
      required=true,
    )
    .build(),
    tracked_handler(tracker, "read_file", fn(input) {
      env.read_file(json_get_str(input, "path")) catch {
        e => "error: " + e.to_string()
      }
    }),
  )

  // write_file
  registry.register(
    "write_file",
    "Write complete content to a file (creates or overwrites). Read the file first. You MUST call this tool to make progress.",
    @llmlib.SchemaBuilder::new()
    .string(
      "path",
      "File path (relative to work_dir or absolute)",
      required=true,
    )
    .string("content", "Content to write to the file", required=true)
    .build(),
    tracked_handler(tracker, "write_file", fn(input) {
      env.write_file(
        json_get_str(input, "path"),
        json_get_str(input, "content"),
      ) catch {
        e => return "error: " + e.to_string()
      }
      "ok"
    }),
  )

  // list_directory
  registry.register(
    "list_directory",
    "List directory entries (shallow). Use sparingly — prefer search_text or list_files_recursive for exploration.",
    @llmlib.SchemaBuilder::new()
    .string("path", "Directory path (default: work_dir)")
    .build(),
    tracked_handler(tracker, "list_directory", fn(input) {
      env.list_directory(json_get_str(input, "path")) catch {
        e => "error: " + e.to_string()
      }
    }),
  )

  // list_files_recursive
  registry.register(
    "list_files_recursive",
    "Recursive file listing (excludes hidden dirs). Call once at start for overview. Do not repeat on the same path.",
    @llmlib.SchemaBuilder::new()
    .string("path", "Base directory (default: work_dir)")
    .integer("max_depth", "Max directory depth (default: 3)")
    .build(),
    tracked_handler(tracker, "list_files_recursive", fn(input) {
      let depth = match json_get_int_opt(input, "max_depth") {
        Some(d) => d
        None => 3
      }
      env.list_files_recursive(json_get_str(input, "path"), depth) catch {
        e => "error: " + e.to_string()
      }
    }),
  )

  // search_text
  registry.register(
    "search_text",
    "Regex search across files (ripgrep). Preferred way to find code. Use instead of list_directory for discovery.",
    @llmlib.SchemaBuilder::new()
    .string("pattern", "Search pattern (regex)", required=true)
    .string("path", "Directory to search (default: work_dir)")
    .string("glob", "File glob pattern (e.g. '*.mbt')")
    .build(),
    tracked_handler(tracker, "search_text", fn(input) {
      let pattern = json_get_str(input, "pattern")
      let path = json_get_str(input, "path")
      let glob = json_get_str(input, "glob")
      env.search_text(pattern, path, glob, 100) catch {
        e => "error: " + e.to_string()
      }
    }),
  )

  // run_command
  registry.register(
    "run_command",
    "Execute a shell command for verification (tests, type-check). Use after writing code to confirm correctness.",
    @llmlib.SchemaBuilder::new()
    .string("command", "Shell command to execute", required=true)
    .integer("timeout_ms", "Timeout in milliseconds (default: 30000)")
    .build(),
    tracked_handler(tracker, "run_command", fn(input) {
      let command = json_get_str(input, "command")
      let t = match json_get_int_opt(input, "timeout_ms") {
        Some(ms) => ms
        None => 30000
      }
      env.run_command(command, "", t) catch {
        e => "error: " + e.to_string()
      }
    }),
  )

  // remove_file
  registry.register(
    "remove_file",
    "Delete a file. Use only when the task requires file removal.",
    @llmlib.SchemaBuilder::new()
    .string("path", "File path to remove", required=true)
    .build(),
    tracked_handler(tracker, "remove_file", fn(input) {
      env.remove_file(json_get_str(input, "path")) catch {
        e => return "error: " + e.to_string()
      }
      "ok"
    }),
  )
  registry
}

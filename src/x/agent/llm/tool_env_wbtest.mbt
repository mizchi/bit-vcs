///| Test mock for ToolEnvironment trait

///|
priv struct TestToolEnvironment {
  files : Map[String, String]
  commands : Map[String, String]
  removed : Array[String]
}

///|
fn TestToolEnvironment::new() -> TestToolEnvironment {
  { files: {}, commands: {}, removed: [] }
}

///|
impl ToolEnvironment for TestToolEnvironment with read_file(self, path) {
  match self.files.get(path) {
    Some(content) => content
    None => raise Failure::Failure("file not found: " + path)
  }
}

///|
impl ToolEnvironment for TestToolEnvironment with write_file(
  self,
  path,
  content,
) {
  self.files[path] = content
}

///|
impl ToolEnvironment for TestToolEnvironment with remove_file(self, path) {
  match self.files.get(path) {
    Some(_) => {
      self.files.remove(path)
      self.removed.push(path)
    }
    None => raise Failure::Failure("file not found: " + path)
  }
}

///|
impl ToolEnvironment for TestToolEnvironment with list_directory(self, path) {
  let result : Array[String] = []
  let prefix = if path.is_empty() { "" } else { path + "/" }
  for item in self.files.to_array() {
    let (key, _) = item
    if prefix.is_empty() || key.has_prefix(prefix) {
      let rest = if prefix.is_empty() {
        key
      } else {
        String::unsafe_substring(key, start=prefix.length(), end=key.length())
      }
      // Only include direct children (no further slashes)
      if not(rest.contains("/")) {
        result.push(rest)
      }
    }
  }
  result.join("\n")
}

///|
impl ToolEnvironment for TestToolEnvironment with list_files_recursive(
  self,
  path,
  _max_depth,
) {
  let result : Array[String] = []
  let prefix = if path.is_empty() { "" } else { path + "/" }
  for item in self.files.to_array() {
    let (key, _) = item
    if prefix.is_empty() || key.has_prefix(prefix) {
      result.push(key)
    }
  }
  result.join("\n")
}

///|
impl ToolEnvironment for TestToolEnvironment with search_text(
  self,
  pattern,
  _path,
  _glob,
  _max_results,
) {
  let result : Array[String] = []
  for item in self.files.to_array() {
    let (key, value) = item
    if value.contains(pattern) {
      result.push(key + ":1:" + pattern)
    }
  }
  result.join("\n")
}

///|
impl ToolEnvironment for TestToolEnvironment with run_command(
  self,
  command,
  _work_dir,
  _timeout_ms,
) {
  match self.commands.get(command) {
    Some(output) => output
    None => raise Failure::Failure("command not found: " + command)
  }
}

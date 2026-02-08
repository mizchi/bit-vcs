///|
let shell_max_command_length = 4096

///|
fn shell_unquote_arg(raw : String) -> String {
  let text = trim_string(raw)
  if text.length() >= 2 &&
    ((text.has_prefix("'") && text.has_suffix("'")) ||
      (text.has_prefix("\"") && text.has_suffix("\""))) {
    String::unsafe_substring(text, start=1, end=text.length() - 1)
  } else {
    text
  }
}

///|
fn shell_parse_service_command(raw : String) -> (String, String)? {
  let line = trim_string(raw)
  let services : Array[String] = [
    "git-upload-pack",
    "git-receive-pack",
    "git-upload-archive",
  ]
  for service in services {
    if line == service {
      return Some((service, "."))
    }
    let prefix = service + " "
    if line.has_prefix(prefix) {
      let start = prefix.length()
      let end = line.length()
      let rest = String::unsafe_substring(line, start~, end~)
      let path = shell_unquote_arg(rest)
      if path.length() == 0 {
        return None
      }
      return Some((service, path))
    }
  }
  None
}

///|
fn shell_real_git_path() -> String? {
  match @sys.get_env_var("SHIM_REAL_GIT") {
    Some(path) => Some(path)
    None => @sys.get_env_var("GIT_SHIM_REAL_GIT")
  }
}

///|
fn shell_is_safe_interactive_name(name : String) -> Bool {
  if name.length() == 0 {
    return false
  }
  if name.contains("/") || name.contains("\\") || name.contains("..") {
    return false
  }
  true
}

///|
fn shell_parse_interactive_command(line : String) -> (String, Array[String]) {
  let mut name : String? = None
  let args : Array[String] = []
  for token_view in line.split(" ") {
    let token = trim_string(token_view.to_string())
    if token.length() == 0 {
      continue
    }
    match name {
      None => name = Some(token)
      Some(_) => args.push(token)
    }
  }
  match name {
    Some(cmd) => (cmd, args)
    None => ("", [])
  }
}

///|
async fn shell_read_interactive_command_line() -> String {
  let line_bytes : Array[Byte] = []
  let mut done = false
  while not(done) {
    match @stdio.stdin.read_some(max_len=256) {
      None => break
      Some(chunk) =>
        for b in chunk {
          if b == 10 {
            done = true
            break
          }
          line_bytes.push(b)
          if line_bytes.length() > shell_max_command_length {
            eprint_line("fatal: command too long")
            @sys.exit(1)
          }
        }
    }
  }
  trim_string(decode_bytes(bytes_from_array(line_bytes)))
}

///|
async fn shell_run_service_command(command_line : String) -> Unit raise Error {
  match shell_parse_service_command(command_line) {
    Some((service, path)) =>
      match service {
        "git-upload-pack" =>
          handle_upload_pack([path]) catch {
            err if @async.is_cancellation_error(err) => raise err
            err => exit_with_error("upload-pack", err)
          }
        "git-receive-pack" =>
          handle_receive_pack([path]) catch {
            err if @async.is_cancellation_error(err) => raise err
            err => exit_with_error("receive-pack", err)
          }
        _ =>
          match shell_real_git_path() {
            Some(real_git) => {
              let code = @process.run(
                real_git,
                ["upload-archive", path],
                inherit_env=true,
              )
              if code != 0 {
                @sys.exit(code)
              }
            }
            None => {
              eprint_line("fatal: 'git-upload-archive' is not supported")
              @sys.exit(1)
            }
          }
      }
    None => {
      eprint_line("fatal: unrecognized command")
      @sys.exit(1)
    }
  }
}

///|
async fn shell_run_interactive(fs : OsFs) -> Unit {
  let command_line = shell_read_interactive_command_line()
  if not(fs.is_dir("git-shell-commands")) {
    eprint_line("fatal: interactive git shell is not enabled")
    @sys.exit(1)
  }
  if command_line.length() == 0 {
    @sys.exit(0)
  }
  let (command_name, command_args) = shell_parse_interactive_command(command_line)
  if not(shell_is_safe_interactive_name(command_name)) {
    eprint_line("fatal: unrecognized command")
    @sys.exit(1)
  }
  let script_path = "git-shell-commands/" + command_name
  if not(fs.is_file(script_path)) {
    eprint_line("fatal: unrecognized command")
    @sys.exit(1)
  }
  let code = @process.run(script_path, command_args, inherit_env=true)
  if code != 0 {
    @sys.exit(code)
  }
}

///|
async fn handle_shell(args : Array[String]) -> Unit raise Error {
  if args.length() == 0 {
    shell_run_interactive(OsFs::new())
    return
  }
  if args.length() >= 2 && args[0] == "-c" {
    shell_run_service_command(args[1])
    return
  }
  eprint_line("fatal: bad arguments for git shell")
  @sys.exit(1)
}

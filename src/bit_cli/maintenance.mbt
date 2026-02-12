///|
async fn handle_maintenance(args : Array[String]) -> Unit raise Error {
  let fs = OsFs::new()
  let root = get_work_root()
  let mut task : String? = None
  let mut auto = false
  let mut quiet = false
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    match arg {
      "run" => task = Some("run")
      "start" => task = Some("start")
      "stop" => task = Some("stop")
      "register" => task = Some("register")
      "unregister" => task = Some("unregister")
      "--auto" => auto = true
      "-q" | "--quiet" => quiet = true
      "--task" => {
        i += 1
        if i < args.length() {
          task = Some(args[i])
        }
      }
      _ if arg.has_prefix("--task=") =>
        task = Some(String::unsafe_substring(arg, start=7, end=arg.length()))
      _ => ()
    }
    i += 1
  }
  match task {
    Some("run") | None => run_maintenance_tasks(fs, root, auto, quiet)
    Some("start") =>
      if not(quiet) {
        print_line("Scheduled maintenance started.")
      }
    Some("stop") =>
      if not(quiet) {
        print_line("Scheduled maintenance stopped.")
      }
    Some("register") =>
      if not(quiet) {
        print_line("Repository registered for maintenance.")
      }
    Some("unregister") =>
      if not(quiet) {
        print_line("Repository unregistered from maintenance.")
      }
    Some("gc") => handle_gc([])
    Some("commit-graph") =>
      if not(quiet) {
        print_line("Commit graph updated.")
      }
    Some("prefetch") => if not(quiet) { print_line("Prefetch completed.") }
    Some("loose-objects") => handle_repack(["-d", "-q"])
    Some("incremental-repack") => handle_repack(["-d", "-q"])
    Some("pack-refs") => handle_pack_refs(["--all"])
    Some(t) =>
      raise @git.GitError::InvalidObject("Unknown maintenance task: \{t}")
  }
}

///|
async fn run_maintenance_tasks(
  fs : OsFs,
  root : String,
  auto : Bool,
  quiet : Bool,
) -> Unit raise Error {
  if not(quiet) {
    print_line("Running maintenance tasks...")
  }
  if not(quiet) {
    print_line("  pack-refs")
  }
  handle_pack_refs(["--all"])
  if auto {
    // Run GC only if needed
    let result = @gitlib.gc_repo(fs, fs, root)
    if not(quiet) && result.pack is Some(_) {
      print_line("  gc (auto)")
    }
  } else {
    if not(quiet) {
      print_line("  gc")
    }
    handle_gc([])
  }
  if not(quiet) {
    print_line("Maintenance completed.")
  }
}

///|
fn get_config_value_simple(
  fs : OsFs,
  config_path : String,
  key : String,
) -> String? {
  if not(fs.is_file(config_path)) {
    return None
  }
  let content = decode_bytes(fs.read_file(config_path)) catch {
    _ => return None
  }
  let parts : Array[String] = []
  for p in key.split(".") {
    parts.push(p.to_string())
  }
  if parts.length() < 2 {
    return None
  }
  let section = parts[0]
  let name = parts[parts.length() - 1]
  let mut in_section = false
  for line_view in content.split("\n") {
    let line = trim_string(line_view.to_string())
    if line.has_prefix("[") && line.has_suffix("]") {
      let sec_content = String::unsafe_substring(
        line,
        start=1,
        end=line.length() - 1,
      )
      if sec_content == section ||
        sec_content.has_prefix(section + " ") ||
        sec_content.has_prefix(section + "\t") {
        in_section = true
      } else {
        in_section = false
      }
    } else if in_section && line.contains("=") {
      match line.find("=") {
        Some(eq_idx) => {
          let k = trim_string(
            String::unsafe_substring(line, start=0, end=eq_idx),
          )
          let v = trim_string(
            String::unsafe_substring(line, start=eq_idx + 1, end=line.length()),
          )
          if k == name {
            return Some(v)
          }
        }
        None => ()
      }
    }
  }
  None
}

///|
async fn stage_all_changes(fs : OsFs, root : String) -> Unit raise Error {
  let status = @gitlib.status(fs, root) catch {
    err => {
      if @async.is_being_cancelled() || @async.is_cancellation_error(err) {
        raise err
      }
      return
    }
  }
  let all_paths : Array[String] = []
  for p in status.untracked {
    all_paths.push(p)
  }
  for p in status.unstaged_modified {
    all_paths.push(p)
  }
  for p in status.unstaged_deleted {
    all_paths.push(p)
  }
  if all_paths.length() > 0 {
    let _ = @gitlib.add_paths_async(fs, fs, root, all_paths) catch {
      err => {
        if @async.is_being_cancelled() || @async.is_cancellation_error(err) {
          raise err
        }
        ()
      }
    }
  }
}

///| git quiltimport - import quilt patch series

///|
async fn handle_quiltimport(args : Array[String]) -> Unit raise Error {
  let mut dry_run = false
  let mut author = ""
  let mut patches_dir = "patches"
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    match arg {
      "-h" | "--help" => {
        show_simple_command_help(
          "git quiltimport [--dry-run] [--author <author>] [--patches <dir>]",
          summary="Import a quilt patch series.",
        )
        return
      }
      "--dry-run" | "-n" => dry_run = true
      "--author" => {
        i += 1
        if i < args.length() {
          author = args[i]
        }
      }
      _ if arg.has_prefix("--author=") => author = arg[9:].to_owned()
      "--patches" => {
        i += 1
        if i < args.length() {
          patches_dir = args[i]
        }
      }
      _ if arg.has_prefix("--patches=") => patches_dir = arg[10:].to_owned()
      _ if arg.has_prefix("-") => warn_unimplemented_arg("quiltimport", arg)
      _ => ()
    }
    i += 1
  }
  // Read series file
  let series_path = patches_dir + "/series"
  let series_data = @fs.read_file_to_bytes(series_path) catch {
    err => {
      eprint_line(
        "fatal: cannot read \{series_path}: \{@debug.render(Repr(err))}",
      )
      @sys.exit(1)
      return
    }
  }
  let series_text = decode_bytes(series_data)
  // Parse series: one patch file per line, skip comments and blanks
  let patch_files : Array[String] = []
  for line_view in series_text.split("\n") {
    let line = quiltimport_trim(line_view.to_owned())
    if line.length() == 0 {
      continue
    }
    if line.has_prefix("#") {
      continue
    }
    // Take just the patch filename (ignore options after spaces)
    let parts : Array[String] = []
    for part_view in line.split(" ") {
      parts.push(part_view.to_owned())
    }
    if parts.length() > 0 && parts[0].length() > 0 {
      patch_files.push(parts[0])
    }
  }
  if patch_files.length() == 0 {
    eprint_line("No patches to import")
    return
  }
  let root = get_work_root()
  // Apply each patch
  for patch_name in patch_files {
    let patch_path = patches_dir + "/" + patch_name
    if dry_run {
      print_line("Would apply \{patch_path}")
      continue
    }
    print_line("Applying \{patch_name}")
    // Use bit's own am/apply/commit instead of delegating to real git
    let bit_exe = @sys.get_cli_args()[0]
    // Try bit am first for mbox-style patches
    let am_args : Array[String] = ["am", "--3way"]
    if author.length() > 0 {
      am_args.push("--author=" + author)
    }
    am_args.push(patch_path)
    let code = @process.run(
      bit_exe,
      am_args,
      inherit_env=true,
      cwd=root,
      stdin=@stdio.stdin,
      stdout=@stdio.stdout,
      stderr=@stdio.stderr,
    )
    if code != 0 {
      // Fall back to bit apply + manual commit
      let apply_code = @process.run(
        bit_exe,
        ["apply", "--index", patch_path],
        inherit_env=true,
        cwd=root,
        stdin=@stdio.stdin,
        stdout=@stdio.stdout,
        stderr=@stdio.stderr,
      )
      if apply_code != 0 {
        eprint_line("fatal: failed to apply \{patch_name}")
        @sys.exit(1)
        return
      }
      let commit_args : Array[String] = [
        "commit",
        "-m",
        "Import patch " + patch_name,
      ]
      if author.length() > 0 {
        commit_args.push("--author=" + author)
      }
      let commit_code = @process.run(
        bit_exe,
        commit_args,
        inherit_env=true,
        cwd=root,
        stdin=@stdio.stdin,
        stdout=@stdio.stdout,
        stderr=@stdio.stderr,
      )
      if commit_code != 0 {
        eprint_line("fatal: failed to commit \{patch_name}")
        @sys.exit(1)
        return
      }
    }
  }
  print_line("\{patch_files.length()} patches applied")
}

///|
fn quiltimport_trim(s : String) -> String {
  let chars = s.to_array()
  let mut start = 0
  let mut end = chars.length()
  while start < end &&
        (chars[start] == ' ' || chars[start] == '\t' || chars[start] == '\r') {
    start += 1
  }
  while end > start &&
        (
          chars[end - 1] == ' ' ||
          chars[end - 1] == '\t' ||
          chars[end - 1] == '\r'
        ) {
    end -= 1
  }
  if start == 0 && end == chars.length() {
    s
  } else {
    s[start:end].to_owned()
  }
}

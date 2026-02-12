///|
async fn handle_unpack_objects(args : Array[String]) -> Unit raise Error {
  let fs = OsFs::new()
  let git_dir = find_git_dir(fs)
  let mut quiet = false
  let mut dry_run = false
  for arg in args {
    match arg {
      "-q" => quiet = true
      "-n" => dry_run = true
      "-r" => () // Recover - ignored for now
      "--strict" => () // Strict - ignored for now
      _ if arg.has_prefix("-") => warn_unimplemented_arg("unpack-objects", arg)
      _ => ()
    }
  }
  // Read packfile from stdin
  let data = read_all_stdin()
  if data.length() < 32 {
    raise @git.GitError::PackfileError("Packfile too short")
  }
  // Parse the packfile
  let objects = @pack.parse_packfile(data)
  if not(quiet) {
    print_line(
      "Unpacking objects: 100% (\{objects.length()}/\{objects.length()}), done.",
    )
  }
  if dry_run {
    return
  }
  // Write objects to the repository
  for obj in objects {
    let _ = @gitlib.write_loose_object(fs, git_dir, obj.obj_type, obj.data)
  }
}

///|

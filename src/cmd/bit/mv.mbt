///|
async fn handle_mv(args : Array[String]) -> Unit raise Error {
  let root = get_work_root()
  let fs = OsFs::new()
  let mut force = false
  let paths : Array[String] = []
  for arg in args {
    match arg {
      "-f" | "--force" => force = true
      _ if not(arg.has_prefix("-")) => paths.push(arg)
      _ if arg.has_prefix("-") => warn_unimplemented_arg("mv", arg)
      _ => ()
    }
  }
  if paths.length() < 2 {
    raise @bitcore.GitError::InvalidObject(
      "usage: git mv <source> <destination>",
    )
  }
  let source = paths[0]
  let dest = paths[1]
  @bitlib.mv_path(fs, fs, root, source, dest, force~)
}

///|

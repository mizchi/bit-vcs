///|
async fn handle_reset(args : Array[String]) -> Unit raise Error {
  let root = get_work_root()
  let fs = OsFs::new()
  let mut mode : @gitlib.ResetMode = @gitlib.ResetMode::Mixed
  let mut rev = "HEAD"
  for arg in args {
    match arg {
      "--soft" => mode = @gitlib.ResetMode::Soft
      "--mixed" => mode = @gitlib.ResetMode::Mixed
      "--hard" => mode = @gitlib.ResetMode::Hard
      _ if not(arg.has_prefix("-")) => rev = arg
      _ if arg.has_prefix("-") => warn_unimplemented_arg("reset", arg)
      _ => ()
    }
  }
  let commit_id = @gitlib.reset(fs, fs, root, rev, mode)
  let short_id = String::unsafe_substring(commit_id.to_hex(), start=0, end=7)
  println("HEAD is now at \{short_id}")
}

///|

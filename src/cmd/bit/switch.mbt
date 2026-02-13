///|
async fn handle_switch(args : Array[String]) -> Unit raise Error {
  if is_real_git_delegate_enabled() {
    delegate_to_real_git("switch", args)
  }
  let root = get_work_root()
  let fs = OsFs::new()
  let mut branch : String? = None
  let mut create = false
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    match arg {
      "-c" | "--create" => {
        create = true
        if i + 1 < args.length() && not(args[i + 1].has_prefix("-")) {
          branch = Some(args[i + 1])
          i += 2
          continue
        }
      }
      _ if not(arg.has_prefix("-")) => branch = Some(arg)
      _ if arg.has_prefix("-") => warn_unimplemented_arg("switch", arg)
      _ => ()
    }
    i += 1
  }
  guard branch is Some(name) else {
    raise @git.GitError::InvalidObject("No branch specified")
  }
  @gitlib.switch_branch(fs, fs, root, name, create~)
  if create {
    println("Switched to a new branch '\{name}'")
  } else {
    println("Switched to branch '\{name}'")
  }
}

///|

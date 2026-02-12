///|
struct RebaseAiArgs {
  do_continue : Bool
  do_abort : Bool
  do_skip : Bool
  interactive : Bool
  onto : String?
  upstream : String?
  model : String
  max_auto_rounds : Int
  use_agent_loop : Bool
  agent_max_steps : Int
}

///|
fn parse_rebase_ai_rounds(raw : String) -> Int raise @git.GitError {
  let parsed = @strconv.parse_int(raw) catch {
    _ =>
      raise @git.GitError::InvalidObject(
        "rebase-ai: --max-ai-rounds expects a positive integer",
      )
  }
  if parsed <= 0 {
    raise @git.GitError::InvalidObject(
      "rebase-ai: --max-ai-rounds must be greater than 0",
    )
  }
  parsed
}

///|
fn parse_rebase_ai_agent_steps(raw : String) -> Int raise @git.GitError {
  let parsed = @strconv.parse_int(raw) catch {
    _ =>
      raise @git.GitError::InvalidObject(
        "rebase-ai: --agent-max-steps expects a positive integer",
      )
  }
  if parsed <= 0 {
    raise @git.GitError::InvalidObject(
      "rebase-ai: --agent-max-steps must be greater than 0",
    )
  }
  parsed
}

///|
fn parse_rebase_ai_args(
  args : Array[String],
) -> RebaseAiArgs raise @git.GitError {
  let mut do_continue = false
  let mut do_abort = false
  let mut do_skip = false
  let mut interactive = false
  let mut onto : String? = None
  let mut upstream : String? = None
  let mut model = ""
  let mut max_auto_rounds = 32
  let mut use_agent_loop = false
  let mut agent_max_steps = 16
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    match arg {
      "--continue" => {
        do_continue = true
        i += 1
        continue
      }
      "--abort" => {
        do_abort = true
        i += 1
        continue
      }
      "--skip" => {
        do_skip = true
        i += 1
        continue
      }
      "-i" | "--interactive" => {
        interactive = true
        i += 1
        continue
      }
      "--onto" if i + 1 < args.length() => {
        onto = Some(args[i + 1])
        i += 2
        continue
      }
      "--onto" =>
        raise @git.GitError::InvalidObject("rebase-ai: --onto requires a value")
      "--model" if i + 1 < args.length() => {
        model = args[i + 1]
        i += 2
        continue
      }
      "--model" =>
        raise @git.GitError::InvalidObject(
          "rebase-ai: --model requires a value",
        )
      "--max-ai-rounds" if i + 1 < args.length() => {
        max_auto_rounds = parse_rebase_ai_rounds(args[i + 1])
        i += 2
        continue
      }
      "--max-ai-rounds" =>
        raise @git.GitError::InvalidObject(
          "rebase-ai: --max-ai-rounds requires a value",
        )
      "--agent-loop" => {
        use_agent_loop = true
        i += 1
        continue
      }
      "--agent-max-steps" if i + 1 < args.length() => {
        agent_max_steps = parse_rebase_ai_agent_steps(args[i + 1])
        i += 2
        continue
      }
      "--agent-max-steps" =>
        raise @git.GitError::InvalidObject(
          "rebase-ai: --agent-max-steps requires a value",
        )
      _ if arg.has_prefix("--model=") => {
        model = String::unsafe_substring(arg, start=8, end=arg.length())
        i += 1
        continue
      }
      _ if arg.has_prefix("--max-ai-rounds=") => {
        let raw = String::unsafe_substring(arg, start=16, end=arg.length())
        max_auto_rounds = parse_rebase_ai_rounds(raw)
        i += 1
        continue
      }
      _ if arg.has_prefix("--agent-max-steps=") => {
        let raw = String::unsafe_substring(arg, start=18, end=arg.length())
        agent_max_steps = parse_rebase_ai_agent_steps(raw)
        i += 1
        continue
      }
      _ if not(arg.has_prefix("-")) => {
        upstream = Some(arg)
        i += 1
        continue
      }
      _ if arg.has_prefix("-") => {
        i += 1
        continue
      }
      _ => {
        i += 1
        continue
      }
    }
  }
  {
    do_continue,
    do_abort,
    do_skip,
    interactive,
    onto,
    upstream,
    model,
    max_auto_rounds,
    use_agent_loop,
    agent_max_steps,
  }
}

///|
fn rebase_ai_options(parsed : RebaseAiArgs) -> @rebase_ai.AiRebaseOptions {
  @rebase_ai.AiRebaseOptions::new(
    model=parsed.model,
    max_auto_rounds=parsed.max_auto_rounds,
    use_agent_loop=parsed.use_agent_loop,
    agent_max_steps=parsed.agent_max_steps,
    verbose=true,
    provider=None,
  )
}

///|
async fn handle_rebase_ai(args : Array[String]) -> Unit raise Error {
  let root = get_work_root()
  let git_dir = root + "/.git"
  let fs = OsFs::new()
  let wfs : &@git.FileSystem = fs
  let rfs : &@git.RepoFileSystem = fs
  let parsed = parse_rebase_ai_args(args)
  if is_subdir_clone(fs, git_dir) {
    handle_subdir_rebase(fs, root, git_dir, parsed.upstream)
    return
  }
  if parsed.interactive {
    eprint_line(
      "rebase-ai: --interactive is not supported yet, falling back to regular rebase",
    )
    handle_rebase(args)
    return
  }
  if parsed.do_abort {
    @rebase_ai.ai_rebase_abort(fs, fs, root)
    print_line("Rebase aborted")
    return
  }
  let options = rebase_ai_options(parsed)
  let result = if parsed.do_continue {
    @rebase_ai.ai_rebase_continue(wfs, rfs, root, options~)
  } else if parsed.do_skip {
    @rebase_ai.ai_rebase_skip(wfs, rfs, root, options~)
  } else {
    guard parsed.upstream is Some(ref_name) else {
      raise @git.GitError::InvalidObject(
        "usage: git rebase-ai [<options>] <upstream>",
      )
    }
    let upstream_id = @gitrepo.rev_parse(fs, git_dir, ref_name)
    guard upstream_id is Some(id) else {
      raise @git.GitError::InvalidObject("unknown revision: \{ref_name}")
    }
    let _ = parsed.onto
    @rebase_ai.ai_rebase_start(wfs, rfs, root, id, options~)
  }
  print_rebase_result(result)
  match result.status {
    @gitlib.RebaseStatus::Conflict => {
      print_line("")
      print_line(
        "rebase-ai: auto resolution stopped. resolve manually, then run \"git rebase-ai --continue\".",
      )
    }
    _ => ()
  }
}

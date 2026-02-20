///|
async fn show_ai_command_help() -> Unit {
  show_simple_command_help(
    "bit ai <command> [<args>]",
    summary="AI helpers.\n\nSubcommands:\n  rebase   AI-assisted rebase conflict resolution\n  merge    AI-assisted merge conflict resolution\n  cherry-pick AI-assisted cherry-pick conflict resolution\n  revert   AI-assisted revert conflict resolution\n  commit   AI-assisted commit message workflow",
  )
}

///|
fn read_file_text(
  fs : &@bitcore.RepoFileSystem,
  root : String,
  rel_path : String,
) -> String? {
  let path = root + "/" + rel_path
  if not(fs.is_file(path)) {
    return None
  }
  let content = fs.read_file(path) catch { _ => return None }
  Some(@utf8.decode_lossy(content[:]))
}

///|
fn collect_ai_context(
  fs : &@bitcore.RepoFileSystem,
  root : String,
  user_instructions : Array[String],
) -> String {
  let blocks : Array[String] = []
  match read_file_text(fs, root, "CLAUDE.md") {
    Some(content) => blocks.push("CLAUDE.md\n\n" + content)
    None => ()
  }
  match read_file_text(fs, root, "AGENTS.md") {
    Some(content) => blocks.push("AGENTS.md\n\n" + content)
    None => ()
  }
  if user_instructions.length() > 0 {
    blocks.push("Custom instructions:\n" + user_instructions.join("\n"))
  }
  blocks.join("\n\n")
}

///|
struct AiDiffUnit {
  name : String
  diffs : Array[@bitdiff.DiffFile]
}

///|
fn diff_unit_name(path : String) -> String {
  match path.find("/") {
    Some(idx) => String::unsafe_substring(path, start=0, end=idx)
    None => path
  }
}

///|
fn merge_index_and_worktree_diffs(
  index_diffs : Array[@bitdiff.DiffFile],
  worktree_diffs : Array[@bitdiff.DiffFile],
) -> Array[@bitdiff.DiffFile] {
  let merged : Map[String, @bitdiff.DiffFile] = {}
  for item in worktree_diffs {
    merged[item.path] = item
  }
  for item in index_diffs {
    if not(merged.contains(item.path)) {
      merged[item.path] = item
    }
  }
  let out : Array[@bitdiff.DiffFile] = []
  for pair in merged.to_array() {
    let (_, file) = pair
    out.push(file)
  }
  out.sort_by((a, b) => String::compare(a.path, b.path))
  out
}

///|
fn build_diff_units_for_ai(diffs : Array[@bitdiff.DiffFile]) -> String {
  if diffs.length() == 0 {
    return ""
  }
  let out = StringBuilder::new()
  for unit in split_diff_units(diffs) {
    out.write_string("## Logical unit: " + unit.name + "\n")
    for item in unit.diffs {
      out.write_string("### " + item.path + "\n")
      let segment = @bitdiff.diff_text([item]).join("\n")
      out.write_string(segment)
      out.write_string("\n")
    }
  }
  out.to_string()
}

///|
fn split_diff_units(diffs : Array[@bitdiff.DiffFile]) -> Array[AiDiffUnit] {
  let grouped : Map[String, Array[@bitdiff.DiffFile]] = {}
  for item in diffs {
    let unit = diff_unit_name(item.path)
    match grouped.get(unit) {
      Some(values) => values.push(item)
      None => grouped[unit] = [item]
    }
  }
  let units : Array[AiDiffUnit] = []
  for pair in grouped.to_array() {
    let (name, files) = pair
    files.sort_by((a, b) => String::compare(a.path, b.path))
    units.push({ name, diffs: files })
  }
  units.sort_by((a, b) => String::compare(a.name, b.name))
  units
}

///|
fn build_single_diff_unit_for_ai(unit : AiDiffUnit) -> String {
  let out = StringBuilder::new()
  out.write_string("## Logical unit: " + unit.name + "\n")
  for item in unit.diffs {
    out.write_string("### " + item.path + "\n")
    let segment = @bitdiff.diff_text([item]).join("\n")
    out.write_string(segment)
    out.write_string("\n")
  }
  out.to_string()
}

///|
fn extract_commit_message_for_ai(data : Bytes) -> String {
  let content = @utf8.decode_lossy(data[:])
  let mut in_message = false
  let message_lines : Array[String] = []
  for line_view in content.split("\n") {
    let line = line_view.to_string()
    if in_message {
      message_lines.push(line)
      continue
    }
    if line.length() == 0 {
      in_message = true
    }
  }
  message_lines.join("\n")
}

///|
struct AiCommitCommandOptions {
  model : String
  max_auto_rounds : Int
  use_agent_loop : Bool
  agent_max_steps : Int
}

///|
struct AiMergeCommandOptions {
  model : String
  max_auto_rounds : Int
  use_agent_loop : Bool
  agent_max_steps : Int
}

///|
fn parse_ai_commit_options(
  args : Array[String],
) -> (AiCommitCommandOptions, Array[String], Bool, Bool, Bool, Array[String]) raise @bitcore.GitError {
  let mut model = ""
  let mut max_auto_rounds = 32
  let mut use_agent_loop = false
  let mut agent_max_steps = 16
  let mut split = false
  let commit_args : Array[String] = []
  let user_instructions : Array[String] = []
  let mut i = 0
  let mut should_generate_message = true
  let mut all_modified = false
  while i < args.length() {
    let arg = args[i]
    match arg {
      "--model" if i + 1 < args.length() => {
        model = args[i + 1]
        i += 2
        continue
      }
      "--model" =>
        raise @bitcore.GitError::InvalidObject(
          "rebase-ai: --model requires a value",
        )
      "--max-ai-rounds" if i + 1 < args.length() => {
        max_auto_rounds = parse_rebase_ai_rounds(args[i + 1])
        i += 2
        continue
      }
      "--max-ai-rounds" =>
        raise @bitcore.GitError::InvalidObject(
          "rebase-ai: --max-ai-rounds requires a value",
        )
      "--agent-loop" => {
        use_agent_loop = true
        i += 1
        continue
      }
      "--split" => {
        split = true
        i += 1
        continue
      }
      "--agent-max-steps" if i + 1 < args.length() => {
        agent_max_steps = parse_rebase_ai_agent_steps(args[i + 1])
        i += 2
        continue
      }
      "--agent-max-steps" =>
        raise @bitcore.GitError::InvalidObject(
          "rebase-ai: --agent-max-steps requires a value",
        )
      "--" => {
        let mut j = i + 1
        while j < args.length() {
          user_instructions.push(args[j])
          j += 1
        }
        break
      }
      "--all" | "-a" => {
        all_modified = true
        commit_args.push(arg)
        i += 1
      }
      "--no-edit" => {
        should_generate_message = false
        commit_args.push(arg)
        i += 1
      }
      "-m" if i + 1 < args.length() => {
        should_generate_message = false
        commit_args.push(arg)
        commit_args.push(args[i + 1])
        i += 2
      }
      "--message" if i + 1 < args.length() => {
        should_generate_message = false
        commit_args.push(arg)
        commit_args.push(args[i + 1])
        i += 2
      }
      "--file" if i + 1 < args.length() => {
        should_generate_message = false
        commit_args.push(arg)
        commit_args.push(args[i + 1])
        i += 2
      }
      "-F" if i + 1 < args.length() => {
        should_generate_message = false
        commit_args.push(arg)
        commit_args.push(args[i + 1])
        i += 2
      }
      "-C" if i + 1 < args.length() => {
        should_generate_message = false
        commit_args.push(arg)
        commit_args.push(args[i + 1])
        i += 2
      }
      "-c" if i + 1 < args.length() => {
        should_generate_message = false
        commit_args.push(arg)
        commit_args.push(args[i + 1])
        i += 2
      }
      "--reuse-message" if i + 1 < args.length() => {
        should_generate_message = false
        commit_args.push(arg)
        commit_args.push(args[i + 1])
        i += 2
      }
      "--reedit-message" if i + 1 < args.length() => {
        should_generate_message = false
        commit_args.push(arg)
        commit_args.push(args[i + 1])
        i += 2
      }
      "-am" if i + 1 < args.length() => {
        all_modified = true
        should_generate_message = false
        commit_args.push(arg)
        commit_args.push(args[i + 1])
        i += 2
      }
      "-ma" if i + 1 < args.length() => {
        all_modified = true
        should_generate_message = false
        commit_args.push(arg)
        commit_args.push(args[i + 1])
        i += 2
      }
      _ if arg.has_prefix("-m") => {
        should_generate_message = false
        commit_args.push(arg)
        i += 1
      }
      _ if arg.has_prefix("--message=") => {
        should_generate_message = false
        commit_args.push(arg)
        i += 1
      }
      _ if arg.has_prefix("--file=") => {
        should_generate_message = false
        commit_args.push(arg)
        i += 1
      }
      _ if arg.has_prefix("-F") => {
        should_generate_message = false
        commit_args.push(arg)
        i += 1
      }
      _ if arg.has_prefix("-C") => {
        should_generate_message = false
        commit_args.push(arg)
        i += 1
      }
      _ if arg.has_prefix("-c") => {
        should_generate_message = false
        commit_args.push(arg)
        i += 1
      }
      _ if arg.has_prefix("--reuse-message=") => {
        should_generate_message = false
        commit_args.push(arg)
        i += 1
      }
      _ if arg.has_prefix("--reedit-message=") => {
        should_generate_message = false
        commit_args.push(arg)
        i += 1
      }
      _ if arg.has_prefix("-ma") => {
        all_modified = true
        should_generate_message = false
        commit_args.push(arg)
        i += 1
      }
      _ if arg.has_prefix("-am") => {
        all_modified = true
        should_generate_message = false
        commit_args.push(arg)
        i += 1
      }
      _ if arg.has_prefix("--model=") => {
        model = String::unsafe_substring(arg, start=8, end=arg.length())
        i += 1
      }
      _ if arg.has_prefix("--max-ai-rounds=") => {
        let raw = String::unsafe_substring(arg, start=16, end=arg.length())
        max_auto_rounds = parse_rebase_ai_rounds(raw)
        i += 1
      }
      _ if arg.has_prefix("--agent-max-steps=") => {
        let raw = String::unsafe_substring(arg, start=18, end=arg.length())
        agent_max_steps = parse_rebase_ai_agent_steps(raw)
        i += 1
      }
      _ => {
        commit_args.push(arg)
        i += 1
      }
    }
  }
  (
    { model, max_auto_rounds, use_agent_loop, agent_max_steps },
    commit_args,
    should_generate_message,
    all_modified,
    split,
    user_instructions,
  )
}

///|
fn parse_ai_merge_options(
  args : Array[String],
) -> (AiMergeCommandOptions, Array[String], Array[String]) raise @bitcore.GitError {
  let mut model = ""
  let mut max_auto_rounds = 32
  let mut use_agent_loop = false
  let mut agent_max_steps = 16
  let merge_args : Array[String] = []
  let user_instructions : Array[String] = []
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    match arg {
      "--model" if i + 1 < args.length() => {
        model = args[i + 1]
        i += 2
        continue
      }
      "--model" =>
        raise @bitcore.GitError::InvalidObject(
          "rebase-ai: --model requires a value",
        )
      "--max-ai-rounds" if i + 1 < args.length() => {
        max_auto_rounds = parse_rebase_ai_rounds(args[i + 1])
        i += 2
        continue
      }
      "--max-ai-rounds" =>
        raise @bitcore.GitError::InvalidObject(
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
        raise @bitcore.GitError::InvalidObject(
          "rebase-ai: --agent-max-steps requires a value",
        )
      "--" => {
        let mut j = i + 1
        while j < args.length() {
          user_instructions.push(args[j])
          j += 1
        }
        break
      }
      _ if arg.has_prefix("--model=") => {
        model = String::unsafe_substring(arg, start=8, end=arg.length())
        i += 1
      }
      _ if arg.has_prefix("--max-ai-rounds=") => {
        let raw = String::unsafe_substring(arg, start=16, end=arg.length())
        max_auto_rounds = parse_rebase_ai_rounds(raw)
        i += 1
      }
      _ if arg.has_prefix("--agent-max-steps=") => {
        let raw = String::unsafe_substring(arg, start=18, end=arg.length())
        agent_max_steps = parse_rebase_ai_agent_steps(raw)
        i += 1
      }
      _ => {
        merge_args.push(arg)
        i += 1
      }
    }
  }
  (
    { model, max_auto_rounds, use_agent_loop, agent_max_steps },
    merge_args,
    user_instructions,
  )
}

///|
struct AiCherryPickCommandOptions {
  model : String
  max_auto_rounds : Int
  use_agent_loop : Bool
  agent_max_steps : Int
}

///|
fn parse_ai_cherry_pick_options(
  args : Array[String],
) -> (AiCherryPickCommandOptions, Array[String], Array[String]) raise @bitcore.GitError {
  let mut model = ""
  let mut max_auto_rounds = 32
  let mut use_agent_loop = false
  let mut agent_max_steps = 16
  let cherry_pick_args : Array[String] = []
  let user_instructions : Array[String] = []
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    match arg {
      "--model" if i + 1 < args.length() => {
        model = args[i + 1]
        i += 2
        continue
      }
      "--model" =>
        raise @bitcore.GitError::InvalidObject(
          "rebase-ai: --model requires a value",
        )
      "--max-ai-rounds" if i + 1 < args.length() => {
        max_auto_rounds = parse_rebase_ai_rounds(args[i + 1])
        i += 2
        continue
      }
      "--max-ai-rounds" =>
        raise @bitcore.GitError::InvalidObject(
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
        raise @bitcore.GitError::InvalidObject(
          "rebase-ai: --agent-max-steps requires a value",
        )
      "--" => {
        let mut j = i + 1
        while j < args.length() {
          user_instructions.push(args[j])
          j += 1
        }
        break
      }
      _ if arg.has_prefix("--model=") => {
        model = String::unsafe_substring(arg, start=8, end=arg.length())
        i += 1
      }
      _ if arg.has_prefix("--max-ai-rounds=") => {
        let raw = String::unsafe_substring(arg, start=16, end=arg.length())
        max_auto_rounds = parse_rebase_ai_rounds(raw)
        i += 1
      }
      _ if arg.has_prefix("--agent-max-steps=") => {
        let raw = String::unsafe_substring(arg, start=18, end=arg.length())
        agent_max_steps = parse_rebase_ai_agent_steps(raw)
        i += 1
      }
      _ => {
        cherry_pick_args.push(arg)
        i += 1
      }
    }
  }
  (
    { model, max_auto_rounds, use_agent_loop, agent_max_steps },
    cherry_pick_args,
    user_instructions,
  )
}

///|
struct AiRevertCommandOptions {
  model : String
  max_auto_rounds : Int
  use_agent_loop : Bool
  agent_max_steps : Int
}

///|
fn parse_ai_revert_options(
  args : Array[String],
) -> (AiRevertCommandOptions, Array[String], Array[String]) raise @bitcore.GitError {
  let mut model = ""
  let mut max_auto_rounds = 32
  let mut use_agent_loop = false
  let mut agent_max_steps = 16
  let revert_args : Array[String] = []
  let user_instructions : Array[String] = []
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    match arg {
      "--model" if i + 1 < args.length() => {
        model = args[i + 1]
        i += 2
        continue
      }
      "--model" =>
        raise @bitcore.GitError::InvalidObject(
          "rebase-ai: --model requires a value",
        )
      "--max-ai-rounds" if i + 1 < args.length() => {
        max_auto_rounds = parse_rebase_ai_rounds(args[i + 1])
        i += 2
        continue
      }
      "--max-ai-rounds" =>
        raise @bitcore.GitError::InvalidObject(
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
        raise @bitcore.GitError::InvalidObject(
          "rebase-ai: --agent-max-steps requires a value",
        )
      "--" => {
        let mut j = i + 1
        while j < args.length() {
          user_instructions.push(args[j])
          j += 1
        }
        break
      }
      _ if arg.has_prefix("--model=") => {
        model = String::unsafe_substring(arg, start=8, end=arg.length())
        i += 1
      }
      _ if arg.has_prefix("--max-ai-rounds=") => {
        let raw = String::unsafe_substring(arg, start=16, end=arg.length())
        max_auto_rounds = parse_rebase_ai_rounds(raw)
        i += 1
      }
      _ if arg.has_prefix("--agent-max-steps=") => {
        let raw = String::unsafe_substring(arg, start=18, end=arg.length())
        agent_max_steps = parse_rebase_ai_agent_steps(raw)
        i += 1
      }
      _ => {
        revert_args.push(arg)
        i += 1
      }
    }
  }
  (
    { model, max_auto_rounds, use_agent_loop, agent_max_steps },
    revert_args,
    user_instructions,
  )
}

///|
async fn handle_ai_commit(args : Array[String]) -> Unit raise Error {
  if args.length() == 0 {
    handle_commit([])
    return
  }
  match args[0] {
    "-h" | "--help" | "help" => {
      show_ai_commit_help()
      return
    }
    _ => ()
  }
  let (
    parsed,
    commit_args,
    generate_message,
    all_modified,
    split_commits,
    user_instructions,
  ) = parse_ai_commit_options(args)
  if not(generate_message) {
    handle_commit(commit_args)
    return
  }
  let root = get_work_root()
  let fs = OsFs::new()
  let rfs : &@bitcore.RepoFileSystem = fs
  let diff_index = @bitdiff.diff_index(rfs, root)
  let diff_files = if all_modified {
    merge_index_and_worktree_diffs(
      diff_index,
      @bitdiff.diff_worktree(rfs, root),
    )
  } else {
    diff_index
  }
  if diff_files.length() == 0 {
    handle_commit(commit_args)
    return
  }
  let context = collect_ai_context(rfs, root, user_instructions)
  let ai_options = @rebase_ai.AiRebaseOptions::new(
    model=parsed.model,
    max_auto_rounds=parsed.max_auto_rounds,
    use_agent_loop=parsed.use_agent_loop,
    agent_max_steps=parsed.agent_max_steps,
    provider=None,
  )
  let units = split_diff_units(diff_files)
  if not(split_commits) || units.length() == 1 {
    let message = @rebase_ai.ai_generate_commit_message(
      rfs,
      root,
      build_diff_units_for_ai(diff_files),
      context,
      options=ai_options,
    )
    let generated_commit_args : Array[String] = []
    for arg in commit_args {
      generated_commit_args.push(arg)
    }
    generated_commit_args.push("-m")
    generated_commit_args.push(message)
    handle_commit(generated_commit_args)
    return
  }
  let split_commit_args : Array[String] = []
  for arg in commit_args {
    match arg {
      "-a" | "--all" => ()
      _ => split_commit_args.push(arg)
    }
  }
  for unit in units {
    ignore(@bitlib.reset(fs, rfs, root, "HEAD", @bitlib.ResetMode::Mixed))
    let path_map : Map[String, Bool] = {}
    let unit_paths : Array[String] = []
    for file in unit.diffs {
      if not(path_map.contains(file.path)) {
        path_map[file.path] = true
        unit_paths.push(file.path)
      }
    }
    if unit_paths.length() == 0 {
      continue
    }
    @bitlib.add_paths_async(fs, fs, root, unit_paths)
    let message = @rebase_ai.ai_generate_commit_message(
      rfs,
      root,
      build_single_diff_unit_for_ai(unit),
      context,
      options=ai_options,
    )
    let generated_commit_args : Array[String] = []
    for arg in split_commit_args {
      generated_commit_args.push(arg)
    }
    generated_commit_args.push("-m")
    generated_commit_args.push(message)
    handle_commit(generated_commit_args)
  }
}

///|
fn merge_args_has(args : Array[String], target : String) -> Bool {
  for arg in args {
    if arg == target {
      return true
    }
  }
  false
}

///|
async fn handle_ai_merge(args : Array[String]) -> Unit raise Error {
  if args.length() == 0 {
    show_ai_merge_help()
    return
  }
  match args[0] {
    "-h" | "--help" | "help" => {
      show_ai_merge_help()
      return
    }
    _ => ()
  }
  let (parsed, merge_args, user_instructions) = parse_ai_merge_options(args)
  if merge_args.length() == 0 {
    raise @bitcore.GitError::InvalidObject(
      "bit ai merge: commit target is required",
    )
  }
  let root = get_work_root()
  let fs = OsFs::new()
  let rfs : &@bitcore.RepoFileSystem = fs
  let context = collect_ai_context(rfs, root, user_instructions)
  let ai_options = @rebase_ai.AiRebaseOptions::new(
    model=parsed.model,
    max_auto_rounds=parsed.max_auto_rounds,
    use_agent_loop=parsed.use_agent_loop,
    agent_max_steps=parsed.agent_max_steps,
    provider=None,
  )
  if merge_args_has(merge_args, "--continue") ||
    merge_args_has(merge_args, "--abort") {
    let conflict_paths = @rebase_ai.find_conflict_marker_paths(rfs, root)
    if conflict_paths.length() > 0 {
      let resolved = @rebase_ai.ai_resolve_conflict_paths(
        fs, rfs, root, conflict_paths, ai_options, context,
      )
      if resolved.failed.length() > 0 {
        let failed_paths = resolved.failed.join(", ")
        raise @bitcore.GitError::InvalidObject(
          "bit ai merge: failed to resolve conflicts: \{failed_paths}",
        )
      }
    }
  }
  handle_merge(merge_args)
  if not(merge_args_has(merge_args, "--continue")) &&
    not(merge_args_has(merge_args, "--abort")) {
    let conflict_paths = @rebase_ai.find_conflict_marker_paths(rfs, root)
    if conflict_paths.length() > 0 {
      let resolved = @rebase_ai.ai_resolve_conflict_paths(
        fs, rfs, root, conflict_paths, ai_options, context,
      )
      if resolved.failed.length() > 0 {
        let failed_paths = resolved.failed.join(", ")
        raise @bitcore.GitError::InvalidObject(
          "bit ai merge: failed to resolve conflicts: \{failed_paths}",
        )
      }
      if resolved.resolved.length() > 0 {
        print_line(
          "bit ai merge: conflicts were auto-resolved. run \"bit ai merge --continue\".",
        )
      }
    }
  }
}

///|
async fn resolve_cherry_pick_conflict_and_commit(
  fs : &@bitcore.FileSystem,
  rfs : &@bitcore.RepoFileSystem,
  root : String,
  commit_id : String,
  message : String,
  options : AiCherryPickCommandOptions,
  context : String,
) -> Unit raise @bitcore.GitError {
  let conflict_paths = @rebase_ai.find_conflict_marker_paths(rfs, root)
  if conflict_paths.length() == 0 {
    raise @bitcore.GitError::InvalidObject(
      "bit ai cherry-pick: expected conflict markers after cherry-pick conflict",
    )
  }
  let ai_options = @rebase_ai.AiRebaseOptions::new(
    model=options.model,
    max_auto_rounds=options.max_auto_rounds,
    use_agent_loop=options.use_agent_loop,
    agent_max_steps=options.agent_max_steps,
    provider=None,
  )
  let resolved = @rebase_ai.ai_resolve_conflict_paths(
    fs, rfs, root, conflict_paths, ai_options, context,
  )
  if resolved.failed.length() > 0 {
    let failed_paths = resolved.failed.join(", ")
    raise @bitcore.GitError::InvalidObject(
      "bit ai cherry-pick: failed to resolve conflicts: \{failed_paths}",
    )
  }
  let commit_id_obj = @bitcore.ObjectId::from_hex(commit_id) catch {
    _ =>
      raise @bitcore.GitError::InvalidObject("invalid commit id: \{commit_id}")
  }
  let db = @bitlib.ObjectDb::load(rfs, root + "/.git")
  let commit_obj = db.get(rfs, commit_id_obj)
  guard commit_obj is Some(source_commit) else {
    raise @bitcore.GitError::InvalidObject(
      "bit ai cherry-pick: cannot read source commit: \{commit_id}",
    )
  }
  let source_message = extract_commit_message_for_ai(source_commit.data)
  let full_message = if message.length() > 0 { message } else { source_message }
  let new_id = @bitlib.commit(
    fs,
    rfs,
    root,
    full_message,
    get_author_string(),
    get_commit_timestamp(),
  )
  let short_id = String::unsafe_substring(new_id.to_hex(), start=0, end=7)
  print_line(
    "bit ai cherry-pick: auto-resolved conflicts and committed \{short_id}",
  ) catch {
    _ => ()
  }
}

///|
async fn handle_ai_cherry_pick(args : Array[String]) -> Unit raise Error {
  if args.length() == 0 {
    show_ai_cherry_pick_help()
    return
  }
  match args[0] {
    "-h" | "--help" | "help" => {
      show_ai_cherry_pick_help()
      return
    }
    _ => ()
  }
  let (parsed, cherry_pick_args, user_instructions) = parse_ai_cherry_pick_options(
    args,
  )
  if cherry_pick_args.length() == 0 {
    raise @bitcore.GitError::InvalidObject(
      "bit ai cherry-pick: commit target is required",
    )
  }
  if merge_args_has(cherry_pick_args, "--abort") ||
    merge_args_has(cherry_pick_args, "--skip") ||
    merge_args_has(cherry_pick_args, "--continue") {
    handle_cherry_pick(cherry_pick_args)
    return
  }
  let root = get_work_root()
  let fs = OsFs::new()
  let rfs : &@bitcore.RepoFileSystem = fs
  if get_subdir_info(fs, root + "/.git") is Some(_) {
    handle_cherry_pick(cherry_pick_args)
    return
  }
  let mut commit_ref : String? = None
  for arg in cherry_pick_args {
    if not(arg.has_prefix("-")) {
      commit_ref = Some(arg)
      break
    }
  }
  if commit_ref is None {
    handle_cherry_pick(cherry_pick_args)
    return
  }
  let mut has_option = false
  for arg in cherry_pick_args {
    if arg.has_prefix("-") {
      has_option = true
      break
    }
  }
  if has_option {
    handle_cherry_pick(cherry_pick_args)
    return
  }
  let git_dir = root + "/.git"
  let context = collect_ai_context(rfs, root, user_instructions)
  let commit_oid = @bitrepo.rev_parse(rfs, git_dir, commit_ref.unwrap()) catch {
    _ => None
  }
  if commit_oid is None {
    raise @bitcore.GitError::InvalidObject(
      "unknown revision: \{commit_ref.unwrap()}",
    )
  }
  let author = get_author_string()
  let timestamp = get_commit_timestamp()
  let result = @bitlib.cherry_pick(
    fs,
    fs,
    root,
    commit_oid.unwrap(),
    author,
    timestamp,
  )
  match result.status {
    @bitlib.CherryPickStatus::Success =>
      match result.commit_id {
        Some(cid) => {
          let short = String::unsafe_substring(cid.to_hex(), start=0, end=7)
          print_line("[\{short}] Cherry-picked from \{commit_ref.unwrap()}")
        }
        None => print_line("Cherry-pick successful")
      }
    @bitlib.CherryPickStatus::Conflict =>
      resolve_cherry_pick_conflict_and_commit(
        fs,
        rfs,
        root,
        commit_oid.unwrap().to_hex(),
        "Cherry-picked from \{commit_ref.unwrap()}",
        parsed,
        context,
      )
  }
}

///|
async fn handle_ai_revert(args : Array[String]) -> Unit raise Error {
  if args.length() == 0 {
    show_ai_revert_help()
    return
  }
  match args[0] {
    "-h" | "--help" | "help" => {
      show_ai_revert_help()
      return
    }
    _ => ()
  }
  let (parsed, revert_args, user_instructions) = parse_ai_revert_options(args)
  if revert_args.length() == 0 {
    raise @bitcore.GitError::InvalidObject(
      "bit ai revert: commit target is required",
    )
  }
  if merge_args_has(revert_args, "--continue") {
    let root = get_work_root()
    let fs = OsFs::new()
    let rfs : &@bitcore.RepoFileSystem = fs
    let context = collect_ai_context(rfs, root, user_instructions)
    let conflict_paths = @rebase_ai.find_conflict_marker_paths(rfs, root)
    if conflict_paths.length() > 0 {
      let ai_options = @rebase_ai.AiRebaseOptions::new(
        model=parsed.model,
        max_auto_rounds=parsed.max_auto_rounds,
        use_agent_loop=parsed.use_agent_loop,
        agent_max_steps=parsed.agent_max_steps,
        provider=None,
      )
      let resolved = @rebase_ai.ai_resolve_conflict_paths(
        fs, rfs, root, conflict_paths, ai_options, context,
      )
      if resolved.failed.length() > 0 {
        let failed_paths = resolved.failed.join(", ")
        raise @bitcore.GitError::InvalidObject(
          "bit ai revert: failed to resolve conflicts: \{failed_paths}",
        )
      }
    }
  }
  handle_revert(revert_args)
}

///|
async fn show_ai_merge_help() -> Unit {
  show_simple_command_help(
    "bit ai merge [<args>]",
    summary="AI merge with conflict resolution.\nAccepted AI options: --model, --max-ai-rounds, --agent-loop, --agent-max-steps.\nRemaining arguments are passed to `bit merge`.\nCustom instructions can be appended after `--`.\nWhen merge conflicts are detected, the AI tries to resolve and then\ncontinues with `bit ai merge --continue`.",
  )
}

///|
async fn show_ai_revert_help() -> Unit {
  show_simple_command_help(
    "bit ai revert [<args>]",
    summary="AI revert with conflict-resolution on continue.\nAccepted AI options: --model, --max-ai-rounds, --agent-loop, --agent-max-steps.\nRemaining arguments are passed to `bit revert`.\nCustom instructions can be appended after `--`.\nWhen conflicts exist on `--continue`, the AI tries to resolve markers and continue.",
  )
}

///|
async fn show_ai_cherry_pick_help() -> Unit {
  show_simple_command_help(
    "bit ai cherry-pick [<args>]",
    summary="AI cherry-pick with conflict-resolution.\nAccepted AI options: --model, --max-ai-rounds, --agent-loop, --agent-max-steps.\nRemaining arguments are passed to `bit cherry-pick`.\nCustom instructions can be appended after `--`.\nWhen conflicts are detected, AI tries to resolve and commits the result.",
  )
}

///|
async fn show_ai_commit_help() -> Unit {
  show_simple_command_help(
    "bit ai commit [<args>]",
    summary="AI commit message workflow.\nAccepted AI options: --model, --max-ai-rounds, --agent-loop, --agent-max-steps.\nUse --split to generate commit messages per logical unit and commit each one.\nWhen no explicit commit-message option is provided, Bit auto-generates a\nConventional Commit message and passes it to `bit commit`.\nUse commit options like -m, --no-edit, --file, --reuse-message, etc.\nto use existing messages instead.",
  )
}

///|
async fn handle_ai(args : Array[String]) -> Unit raise Error {
  if args.length() == 0 {
    show_ai_command_help()
    return
  }
  let subcmd = args[0]
  if subcmd == "-h" || subcmd == "--help" || subcmd == "help" {
    show_ai_command_help()
    return
  }
  let subargs = collect_args(args, 1)
  match subcmd {
    "rebase" => handle_rebase_ai(subargs)
    "merge" => handle_ai_merge(subargs)
    "commit" => handle_ai_commit(subargs)
    "cherry-pick" => handle_ai_cherry_pick(subargs)
    "revert" => handle_ai_revert(subargs)
    _ =>
      raise @bitcore.GitError::InvalidObject(
        "bit ai supports `rebase`, `merge`, `commit`, `cherry-pick`, and `revert` subcommands",
      )
  }
}

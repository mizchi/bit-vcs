///| AI-assisted rebase helpers.

///|
pub let default_provider : String = "openrouter"

///|
pub let default_model : String = "moonshotai/kimi-k2"

///|
pub struct AiRebaseOptions {
  model : String
  max_auto_rounds : Int
  agent_max_steps : Int
  use_agent_loop : Bool
  verbose : Bool
  provider : @llmlib.BoxedProvider?
}

///|
pub struct AiConflictResolution {
  resolved : Array[String]
  failed : Array[String]
}

///|
pub fn AiRebaseOptions::default() -> AiRebaseOptions {
  {
    model: "",
    max_auto_rounds: 32,
    agent_max_steps: 16,
    use_agent_loop: false,
    verbose: false,
    provider: None,
  }
}

///|
pub fn AiRebaseOptions::new(
  model? : String = "",
  max_auto_rounds? : Int = 32,
  agent_max_steps? : Int = 16,
  use_agent_loop? : Bool = false,
  verbose? : Bool = false,
  provider~ : @llmlib.BoxedProvider?,
) -> AiRebaseOptions {
  { model, max_auto_rounds, agent_max_steps, use_agent_loop, verbose, provider }
}

///|
fn trim_text(s : String) -> String {
  s.trim(chars=" \n\r\t").to_owned()
}

///|
fn effective_model(options : AiRebaseOptions) -> String {
  let explicit = trim_text(options.model)
  if explicit.length() > 0 {
    return explicit
  }
  let env_model = trim_text(@llm_ffi.get_env("BIT_REBASE_AI_MODEL"))
  if env_model.length() > 0 {
    return env_model
  }
  default_model
}

///|
fn env_truthy(name : String) -> Bool {
  let raw = trim_text(@llm_ffi.get_env(name))
  if raw.length() == 0 {
    return false
  }
  match raw.to_string_view().to_lower().to_owned() {
    "1" | "true" | "yes" | "on" => true
    _ => false
  }
}

///|
fn use_agent_loop_mode(options : AiRebaseOptions) -> Bool {
  options.use_agent_loop || env_truthy("BIT_REBASE_AI_AGENT_LOOP")
}

///|
fn normalized_agent_step_limit(options : AiRebaseOptions) -> Int {
  if options.agent_max_steps <= 0 {
    1
  } else {
    options.agent_max_steps
  }
}

///|
fn openrouter_system_prompt(agent_loop_mode : Bool) -> String {
  if agent_loop_mode {
    let prompt =
      #|You are an expert merge conflict resolver.
      #|Use tools to resolve git conflict markers in repository files.
      #|You can only use read_file and write_file.
      #|
      #|Rules:
      #|- Keep all edits inside repository paths.
      #|- Never access or modify `.git` paths.
      #|- Remove all conflict markers.
      #|- After writing final content, stop with a short confirmation.
    return prompt
  }
  let prompt =
    #|You are an expert merge conflict resolver.
    #|You receive one conflicted file content that contains Git conflict markers.
    #|Return ONLY the final resolved file content.
    #|
    #|Rules:
    #|- Do not output Markdown fences.
    #|- Do not explain your reasoning.
    #|- Remove all conflict markers.
    #|- Keep the code/text valid and coherent.
  prompt
}

///|
fn commit_system_prompt(_agent_loop_mode : Bool) -> String {
  (
    #|You are an expert commit message writer.
    #|Write commit messages that follow Conventional Commits.
    #|Return only the commit message text, never explanations or JSON wrappers.
  )
}

///|
fn build_commit_message_prompt(diff_units : String, context : String) -> String {
  let buf = StringBuilder::new()
  buf.write_string(
    "Write one commit message that follows Conventional Commits.\n",
  )
  buf.write_string(
    "Allowed types: feat, fix, chore, docs, style, refactor, perf, test, build, ci, revert, deps.\n",
  )
  buf.write_string(
    "Treat each file block as a logical unit and summarize all units in one message.\n",
  )
  buf.write_string("Output format must be:\n")
  buf.write_string("<type>(<scope>): <summary>\n\n")
  buf.write_string("- <scope>: <change summary>\n")
  buf.write_string("- ...\n\n")
  if context.length() > 0 {
    buf.write_string("Project/User instructions:\n")
    buf.write_string(context)
    buf.write_string("\n\n")
  }
  buf.write_string("Diff units:\n")
  buf.write_string(diff_units)
  buf.to_string()
}

///|
fn build_resolve_prompt(path : String, conflicted_content : String) -> String {
  let buf = StringBuilder::new()
  buf.write_string("Resolve this conflicted file:\n")
  buf.write_string("path: ")
  buf.write_string(path)
  buf.write_string("\n\n")
  buf.write_string("Return only the resolved file content.\n\n")
  buf.write_string("----- BEGIN CONFLICTED FILE -----\n")
  buf.write_string(conflicted_content)
  buf.write_string("\n----- END CONFLICTED FILE -----\n")
  buf.to_string()
}

///|
fn build_resolve_prompt_with_context(
  path : String,
  conflicted_content : String,
  context : String,
) -> String {
  let trimmed_context = trim_text(context)
  if trimmed_context.length() == 0 {
    return build_resolve_prompt(path, conflicted_content)
  }
  let buf = StringBuilder::new()
  buf.write_string("Project/User constraints:\n")
  buf.write_string(trimmed_context)
  buf.write_string("\n\n")
  buf.write_string(build_resolve_prompt(path, conflicted_content))
  buf.to_string()
}

///|
fn has_conflict_markers(content : String) -> Bool {
  content.contains("<<<<<<<") ||
  content.contains(">>>>>>>") ||
  content.contains("|||||||")
}

///|
fn decode_bytes(data : Bytes) -> String {
  @string_utils.decode_bytes(data)
}

///|
fn collect_text_with_provider(
  provider : @llmlib.BoxedProvider,
  prompt : String,
) -> String {
  let buf = StringBuilder::new()
  let handler : @llmlib.StreamHandler = {
    on_event: fn(event) {
      match event {
        @llmlib.StreamEvent::TextDelta(delta) => buf.write_string(delta)
        _ => ()
      }
    },
  }
  provider.stream([@llmlib.Message::user(prompt)], [], handler)
  buf.to_string()
}

///|
fn extract_fenced_code_block(text : String) -> String? {
  let lines : Array[String] = []
  for line_view in text.split("\n") {
    lines.push(line_view.to_owned())
  }
  let captured : Array[String] = []
  let mut started = false
  let mut in_fence = false
  for line in lines {
    if line.has_prefix("```") {
      if !started {
        started = true
        in_fence = true
        continue
      } else if in_fence {
        return Some(captured.join("\n"))
      }
    }
    if in_fence {
      captured.push(line)
    }
  }
  if started && captured.length() > 0 {
    Some(captured.join("\n"))
  } else {
    None
  }
}

///|
fn normalize_model_output(raw : String) -> String {
  match extract_fenced_code_block(raw) {
    Some(code) => code
    None => trim_text(raw)
  }
}

///|
fn json_get_str(j : Json, field : String) -> String {
  match j {
    Object(m) =>
      match m.get(field) {
        Some(String(s)) => s
        _ => ""
      }
    _ => ""
  }
}

///|
fn normalize_repo_relative_path(path : String) -> String? {
  let trimmed = trim_text(path)
  if trimmed.length() == 0 {
    return None
  }
  let normalized_parts : Array[String] = []
  for part_view in trimmed.split("/") {
    let part = part_view.to_owned()
    if part == "" || part == "." {
      continue
    }
    if part == ".." || part == ".git" {
      return None
    }
    normalized_parts.push(part)
  }
  if normalized_parts.length() == 0 {
    return None
  }
  Some(normalized_parts.join("/"))
}

///|
fn resolve_repo_scoped_path(root : String, path : String) -> String? {
  let trimmed = trim_text(path)
  if trimmed.length() == 0 {
    return None
  }
  if trimmed.has_prefix("/") {
    let prefix = root + "/"
    if trimmed.has_prefix(prefix) {
      let rel = String::unsafe_substring(
        trimmed,
        start=prefix.length(),
        end=trimmed.length(),
      )
      return normalize_repo_relative_path(rel)
    }
    return None
  }
  normalize_repo_relative_path(trimmed)
}

///|
fn push_unique_path(paths : Array[String], path : String) -> Unit {
  for current in paths {
    if current == path {
      return
    }
  }
  paths.push(path)
}

///|
fn build_agent_loop_prompt(rel_path : String) -> String {
  let buf = StringBuilder::new()
  buf.write_string("Resolve git conflict markers using tools.\n")
  buf.write_string("Target path: ")
  buf.write_string(rel_path)
  buf.write_string("\n\n")
  buf.write_string("Requirements:\n")
  buf.write_string("- Use read_file before writing.\n")
  buf.write_string("- Write final merged content with write_file.\n")
  buf.write_string("- Remove all conflict markers.\n")
  buf.write_string("- Keep edits coherent and valid.\n")
  buf.write_string("- Prefer minimal, safe change.\n")
  buf.to_string()
}

///|
fn build_repo_scoped_rw_registry(
  fs : &@bit.FileSystem,
  rfs : &@bit.RepoFileSystem,
  root : String,
) -> (@llmlib.ToolRegistry, Ref[Array[String]]) {
  let registry = @llmlib.ToolRegistry::new()
  let touched_paths : Ref[Array[String]] = { val: [] }
  registry.register(
    "read_file",
    "Read file contents from repository scope. Path must stay inside repository.",
    @llmlib.SchemaBuilder::new()
    .string("path", "Repository-relative file path", required=true)
    .build(),
    fn(input) {
      let raw_path = json_get_str(input, "path")
      guard resolve_repo_scoped_path(root, raw_path) is Some(rel_path) else {
        return "error: invalid path (repository scope only)"
      }
      let abs_path = root + "/" + rel_path
      if !rfs.is_file(abs_path) {
        return "error: file not found"
      }
      let bytes = rfs.read_file(abs_path) catch {
        _ => return "error: read failed"
      }
      decode_bytes(bytes)
    },
  )
  registry.register(
    "write_file",
    "Write complete file content to repository scope. Path must stay inside repository.",
    @llmlib.SchemaBuilder::new()
    .string("path", "Repository-relative file path", required=true)
    .string("content", "Complete file content", required=true)
    .build(),
    fn(input) {
      let raw_path = json_get_str(input, "path")
      guard resolve_repo_scoped_path(root, raw_path) is Some(rel_path) else {
        return "error: invalid path (repository scope only)"
      }
      let content = json_get_str(input, "content")
      let abs_path = root + "/" + rel_path
      fs.write_string(abs_path, content) catch {
        _ => return "error: write failed"
      }
      push_unique_path(touched_paths.val, rel_path)
      "ok"
    },
  )
  (registry, touched_paths)
}

///|
fn build_repo_scoped_read_tools(
  rfs : &@bit.RepoFileSystem,
  root : String,
) -> @llmlib.ToolRegistry {
  let registry = @llmlib.ToolRegistry::new()
  registry.register(
    "read_file",
    "Read file content from repository scope.",
    @llmlib.SchemaBuilder::new()
    .string("path", "Repository-relative file path", required=true)
    .build(),
    fn(input) {
      let raw_path = json_get_str(input, "path")
      guard resolve_repo_scoped_path(root, raw_path) is Some(path) else {
        return "error: invalid path"
      }
      if !rfs.is_file(root + "/" + path) {
        return "error: file not found"
      }
      let abs_path = root + "/" + path
      let bytes = rfs.read_file(abs_path) catch {
        _ => return "error: read failed"
      }
      decode_bytes(bytes)
    },
  )
  registry.register(
    "readdir",
    "List repository-relative directory entries (non-recursive).",
    @llmlib.SchemaBuilder::new()
    .string("path", "Repository-relative directory path", required=false)
    .build(),
    fn(input) {
      let raw_path = json_get_str(input, "path")
      let rel_path = trim_text(raw_path)
      let mut target_path = ""
      if rel_path.length() > 0 {
        guard resolve_repo_scoped_path(root, rel_path) is Some(path) else {
          return "error: invalid path"
        }
        target_path = path
      }
      let abs_path = if target_path.length() == 0 {
        root
      } else {
        root + "/" + target_path
      }
      if !rfs.is_dir(abs_path) {
        return "error: invalid path"
      }
      let entries = rfs.readdir(abs_path) catch {
        _ => return "error: readdir failed"
      }
      entries.sort_by((a, b) => String::lexical_compare(a, b))
      let out : Array[String] = []
      for entry in entries {
        if entry == "." || entry == ".." || entry == ".git" {
          continue
        }
        let rel_entry = if target_path.length() == 0 {
          entry
        } else {
          target_path + "/" + entry
        }
        if rfs.is_dir(root + "/" + rel_entry) {
          out.push(rel_entry + "/")
        } else {
          out.push(rel_entry)
        }
      }
      if out.length() == 0 {
        "(empty)"
      } else {
        out.join("\n")
      }
    },
  )
  registry
}

///|
fn stage_paths_with_storage_runtime(
  fs : &@bit.FileSystem,
  rfs : &@bit.RepoFileSystem,
  root : String,
  paths : Array[String],
) -> Unit raise @bit.GitError {
  @runtime.run_storage_command(
    fs,
    rfs,
    root,
    @runtime.StorageCommand::Add({ add_all: false, paths }),
  ) catch {
    err =>
      raise @bit.GitError::InvalidObject(
        "rebase-ai: storage runtime add failed: \{err}",
      )
  }
}

///|
fn resolve_conflict_file_with_agent_loop(
  fs : &@bit.FileSystem,
  rfs : &@bit.RepoFileSystem,
  root : String,
  rel_path : String,
  provider : @llmlib.BoxedProvider,
  options : AiRebaseOptions,
  context : String,
) -> Bool raise @bit.GitError {
  let abs_path = root + "/" + rel_path
  let bytes = rfs.read_file(abs_path) catch { _ => return false }
  let conflicted = decode_bytes(bytes)
  if !has_conflict_markers(conflicted) {
    return false
  }
  let (registry, touched_paths) = build_repo_scoped_rw_registry(fs, rfs, root)
  let user_prompt = if context.length() == 0 {
    build_agent_loop_prompt(rel_path)
  } else {
    build_agent_loop_prompt(rel_path) +
    "\n\n" +
    build_resolve_prompt_with_context(rel_path, conflicted, context)
  }
  let messages : Array[@llmlib.Message] = [@llmlib.Message::user(user_prompt)]
  @llmlib.run_agent_cancellable(
    provider,
    registry,
    messages,
    @llmlib.StopCondition::MaxSteps(normalized_agent_step_limit(options)),
    fn() { false },
    fn(_event) {  },
  )
  let after_bytes = rfs.read_file(abs_path) catch { _ => return false }
  let resolved = decode_bytes(after_bytes)
  if trim_text(resolved).length() == 0 {
    return false
  }
  if has_conflict_markers(resolved) {
    return false
  }
  let stage_paths = if touched_paths.val.length() > 0 {
    touched_paths.val
  } else {
    [rel_path]
  }
  stage_paths_with_storage_runtime(fs, rfs, root, stage_paths)
  true
}

///|
fn resolve_conflict_file_with_provider(
  fs : &@bit.FileSystem,
  rfs : &@bit.RepoFileSystem,
  root : String,
  rel_path : String,
  provider : @llmlib.BoxedProvider,
  context : String,
) -> Bool raise @bit.GitError {
  let abs_path = root + "/" + rel_path
  let bytes = rfs.read_file(abs_path) catch { _ => return false }
  let conflicted = decode_bytes(bytes)
  if !has_conflict_markers(conflicted) {
    return false
  }
  let prompt = build_resolve_prompt_with_context(rel_path, conflicted, context)
  let raw = collect_text_with_provider(provider, prompt)
  let resolved = normalize_model_output(raw)
  if trim_text(resolved).length() == 0 {
    return false
  }
  if has_conflict_markers(resolved) {
    return false
  }
  fs.write_string(abs_path, resolved)
  stage_paths_with_storage_runtime(fs, rfs, root, [rel_path])
  true
}

///|
fn collect_conflict_marker_paths_recursive(
  rfs : &@bit.RepoFileSystem,
  root : String,
  rel : String,
  out : Array[String],
) -> Unit {
  let dir_path = if rel.length() == 0 { root } else { root + "/" + rel }
  let entries = rfs.readdir(dir_path) catch { _ => [] }
  entries.sort_by((a, b) => String::lexical_compare(a, b))
  for entry in entries {
    if entry == "." || entry == ".." || entry == ".git" {
      continue
    }
    let child_rel = if rel.length() == 0 { entry } else { rel + "/" + entry }
    let child_path = root + "/" + child_rel
    if rfs.is_dir(child_path) {
      collect_conflict_marker_paths_recursive(rfs, root, child_rel, out)
    } else if rfs.is_file(child_path) {
      let data = rfs.read_file(child_path) catch { _ => Default::default() }
      let text = decode_bytes(data)
      if has_conflict_markers(text) {
        out.push(child_rel)
      }
    }
  }
}

///|
pub fn find_conflict_marker_paths(
  rfs : &@bit.RepoFileSystem,
  root : String,
) -> Array[String] {
  let out : Array[String] = []
  collect_conflict_marker_paths_recursive(rfs, root, "", out)
  out
}

///|
fn ensure_openrouter_api_key() -> Unit raise @bit.GitError {
  let api_key = trim_text(@llm_ffi.get_env("OPENROUTER_API_KEY"))
  if api_key.length() == 0 {
    raise @bit.GitError::InvalidObject("rebase-ai requires OPENROUTER_API_KEY")
  }
}

///|
fn build_provider(
  options : AiRebaseOptions,
  provider_ref : Ref[@llmlib.BoxedProvider?],
) -> @llmlib.BoxedProvider raise @bit.GitError {
  build_provider_with_system_prompt(
    options,
    provider_ref,
    openrouter_system_prompt(use_agent_loop_mode(options)),
  )
}

///|
fn build_provider_with_system_prompt(
  options : AiRebaseOptions,
  provider_ref : Ref[@llmlib.BoxedProvider?],
  system_prompt : String,
) -> @llmlib.BoxedProvider raise @bit.GitError {
  match provider_ref.val {
    Some(provider) => provider
    None => {
      ensure_openrouter_api_key()
      let api_key = trim_text(@llm_ffi.get_env("OPENROUTER_API_KEY"))
      let model = effective_model(options)
      let provider = @llmlib.BoxedProvider::new(
        @openai.OpenAIProvider::new(
          api_key,
          endpoint=OpenRouter,
          model~,
          system_prompt~,
          max_tokens=8192,
        ),
      )
      match system_prompt {
        _ => {
          provider_ref.val = Some(provider)
          provider
        }
      }
    }
  }
}

///|
pub fn ai_generate_commit_message(
  fs : &@bit.RepoFileSystem,
  root : String,
  diff_units : String,
  context : String,
  options? : AiRebaseOptions = AiRebaseOptions::default(),
) -> String raise @bit.GitError {
  let trimmed_diff = trim_text(diff_units)
  if trimmed_diff.length() == 0 {
    raise @bit.GitError::InvalidObject("ai: no diff content provided")
  }
  let mut prompt = build_commit_message_prompt(trimmed_diff, trim_text(context))
  if use_agent_loop_mode(options) {
    prompt += "\n\nYou can call the provided read_file and readdir tools if context is insufficient."
  }
  let provider_ref : Ref[@llmlib.BoxedProvider?] = { val: options.provider }
  let provider = build_provider_with_system_prompt(
    options,
    provider_ref,
    commit_system_prompt(use_agent_loop_mode(options)),
  )
  if use_agent_loop_mode(options) {
    let registry = build_repo_scoped_read_tools(fs, root)
    let out = StringBuilder::new()
    @llmlib.run_agent_cancellable(
      provider,
      registry,
      [@llmlib.Message::user(prompt)],
      @llmlib.StopCondition::MaxSteps(normalized_agent_step_limit(options)),
      fn() { false },
      fn(event) {
        match event {
          Stream(stream_event) =>
            match stream_event {
              TextDelta(delta) => out.write_string(delta)
              _ => ()
            }
          _ => ()
        }
      },
    )
    normalize_model_output(out.to_string())
  } else {
    normalize_model_output(collect_text_with_provider(provider, prompt))
  }
}

///|
fn raise_unresolved_conflicts(
  conflicts : Array[String],
) -> Unit raise @bit.GitError {
  if conflicts.length() == 0 {
    raise @bit.GitError::InvalidObject("rebase-ai: unresolved conflicts remain")
  }
  raise @bit.GitError::InvalidObject(
    "rebase-ai failed to resolve conflicts: " + conflicts.join(", "),
  )
}

///|
fn resolve_conflict_paths(
  fs : &@bit.FileSystem,
  rfs : &@bit.RepoFileSystem,
  root : String,
  paths : Array[String],
  options : AiRebaseOptions,
  provider_ref : Ref[@llmlib.BoxedProvider?],
  context : String,
) -> AiConflictResolution raise @bit.GitError {
  if paths.length() == 0 {
    return { resolved: [], failed: [] }
  }
  let provider = build_provider(options, provider_ref)
  let agent_loop_mode = use_agent_loop_mode(options)
  let resolved : Array[String] = []
  let failed : Array[String] = []
  for path in paths {
    let ok = if agent_loop_mode {
      resolve_conflict_file_with_agent_loop(
        fs, rfs, root, path, provider, options, context,
      ) catch {
        _ => false
      }
    } else {
      resolve_conflict_file_with_provider(
        fs, rfs, root, path, provider, context,
      ) catch {
        _ => false
      }
    }
    if ok {
      resolved.push(path)
    } else {
      failed.push(path)
    }
  }
  { resolved, failed }
}

///|
pub fn ai_resolve_conflict_paths(
  fs : &@bit.FileSystem,
  rfs : &@bit.RepoFileSystem,
  root : String,
  paths : Array[String],
  options : AiRebaseOptions,
  context : String,
) -> AiConflictResolution raise @bit.GitError {
  let provider_ref : Ref[@llmlib.BoxedProvider?] = { val: options.provider }
  resolve_conflict_paths(fs, rfs, root, paths, options, provider_ref, context)
}

///|
fn normalized_round_limit(options : AiRebaseOptions) -> Int {
  if options.max_auto_rounds <= 0 {
    1
  } else {
    options.max_auto_rounds
  }
}

///|
async fn continue_until_non_conflict(
  fs : &@bit.FileSystem,
  rfs : &@bit.RepoFileSystem,
  root : String,
  initial : @bitlib.RebaseResult,
  options : AiRebaseOptions,
  provider_ref : Ref[@llmlib.BoxedProvider?],
) -> @bitlib.RebaseResult raise @bit.GitError {
  let mut current = initial
  let mut rounds = 0
  let round_limit = normalized_round_limit(options)
  while rounds <= round_limit {
    match current.status {
      @bitlib.RebaseStatus::Conflict => ()
      _ => return current
    }
    if rounds >= round_limit {
      return current
    }
    let conflict_paths = if current.conflicts.length() > 0 {
      current.conflicts
    } else {
      find_conflict_marker_paths(rfs, root)
    }
    if conflict_paths.length() == 0 {
      return current
    }
    let resolved = resolve_conflict_paths(
      fs, rfs, root, conflict_paths, options, provider_ref, "",
    )
    if resolved.failed.length() > 0 {
      raise_unresolved_conflicts(resolved.failed)
    }
    current = @bitlib.rebase_continue(fs, rfs, root)
    rounds += 1
  }
  current
}

///|
pub async fn ai_rebase_start(
  fs : &@bit.FileSystem,
  rfs : &@bit.RepoFileSystem,
  root : String,
  upstream : @bit.ObjectId,
  options? : AiRebaseOptions = AiRebaseOptions::default(),
) -> @bitlib.RebaseResult raise @bit.GitError {
  let provider_ref : Ref[@llmlib.BoxedProvider?] = { val: options.provider }
  let start_result = @bitlib.rebase_start(fs, rfs, root, upstream)
  continue_until_non_conflict(
    fs, rfs, root, start_result, options, provider_ref,
  )
}

///|
pub async fn ai_rebase_continue(
  fs : &@bit.FileSystem,
  rfs : &@bit.RepoFileSystem,
  root : String,
  options? : AiRebaseOptions = AiRebaseOptions::default(),
) -> @bitlib.RebaseResult raise @bit.GitError {
  let provider_ref : Ref[@llmlib.BoxedProvider?] = { val: options.provider }
  let marker_paths = find_conflict_marker_paths(rfs, root)
  if marker_paths.length() > 0 {
    let resolved = resolve_conflict_paths(
      fs, rfs, root, marker_paths, options, provider_ref, "",
    )
    if resolved.failed.length() > 0 {
      raise_unresolved_conflicts(resolved.failed)
    }
  }
  let continue_result = @bitlib.rebase_continue(fs, rfs, root)
  continue_until_non_conflict(
    fs, rfs, root, continue_result, options, provider_ref,
  )
}

///|
pub async fn ai_rebase_skip(
  fs : &@bit.FileSystem,
  rfs : &@bit.RepoFileSystem,
  root : String,
  options? : AiRebaseOptions = AiRebaseOptions::default(),
) -> @bitlib.RebaseResult raise @bit.GitError {
  let provider_ref : Ref[@llmlib.BoxedProvider?] = { val: options.provider }
  let skip_result = @bitlib.rebase_skip(fs, rfs, root)
  continue_until_non_conflict(fs, rfs, root, skip_result, options, provider_ref)
}

///|
pub async fn ai_rebase_abort(
  fs : &@bit.FileSystem,
  rfs : &@bit.RepoFileSystem,
  root : String,
) -> Unit raise @bit.GitError {
  @bitlib.rebase_abort(fs, rfs, root)
}

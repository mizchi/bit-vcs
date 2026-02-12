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
  s.trim(chars=" \n\r\t").to_string()
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
  match raw.to_string_view().to_lower().to_string() {
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
fn has_conflict_markers(content : String) -> Bool {
  content.contains("<<<<<<<") ||
  content.contains(">>>>>>>") ||
  content.contains("|||||||")
}

///|
fn decode_bytes(data : Bytes) -> String {
  @utf8.decode_lossy(data[:])
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
    lines.push(line_view.to_string())
  }
  let captured : Array[String] = []
  let mut started = false
  let mut in_fence = false
  for line in lines {
    if line.has_prefix("```") {
      if not(started) {
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
    let part = part_view.to_string()
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
  fs : &@git.FileSystem,
  rfs : &@git.RepoFileSystem,
  root : String,
) -> (@llmlib.ToolRegistry, Ref[Array[String]]) {
  let registry = @llmlib.ToolRegistry::new()
  let touched_paths : Ref[Array[String]] = Ref::new([])
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
      if not(rfs.is_file(abs_path)) {
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
fn resolve_conflict_file_with_agent_loop(
  fs : &@git.FileSystem,
  rfs : &@git.RepoFileSystem,
  root : String,
  rel_path : String,
  provider : @llmlib.BoxedProvider,
  options : AiRebaseOptions,
) -> Bool raise @git.GitError {
  let abs_path = root + "/" + rel_path
  let bytes = rfs.read_file(abs_path) catch { _ => return false }
  let conflicted = decode_bytes(bytes)
  if not(has_conflict_markers(conflicted)) {
    return false
  }
  let (registry, touched_paths) = build_repo_scoped_rw_registry(fs, rfs, root)
  let messages : Array[@llmlib.Message] = [
    @llmlib.Message::user(build_agent_loop_prompt(rel_path)),
  ]
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
  @gitlib.add_paths(fs, rfs, root, stage_paths)
  true
}

///|
fn resolve_conflict_file_with_provider(
  fs : &@git.FileSystem,
  rfs : &@git.RepoFileSystem,
  root : String,
  rel_path : String,
  provider : @llmlib.BoxedProvider,
) -> Bool raise @git.GitError {
  let abs_path = root + "/" + rel_path
  let bytes = rfs.read_file(abs_path) catch { _ => return false }
  let conflicted = decode_bytes(bytes)
  if not(has_conflict_markers(conflicted)) {
    return false
  }
  let prompt = build_resolve_prompt(rel_path, conflicted)
  let raw = collect_text_with_provider(provider, prompt)
  let resolved = normalize_model_output(raw)
  if trim_text(resolved).length() == 0 {
    return false
  }
  if has_conflict_markers(resolved) {
    return false
  }
  fs.write_string(abs_path, resolved)
  @gitlib.add_paths(fs, rfs, root, [rel_path])
  true
}

///|
fn collect_conflict_marker_paths_recursive(
  rfs : &@git.RepoFileSystem,
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
      let data = rfs.read_file(child_path) catch { _ => Bytes::default() }
      let text = decode_bytes(data)
      if has_conflict_markers(text) {
        out.push(child_rel)
      }
    }
  }
}

///|
pub fn find_conflict_marker_paths(
  rfs : &@git.RepoFileSystem,
  root : String,
) -> Array[String] {
  let out : Array[String] = []
  collect_conflict_marker_paths_recursive(rfs, root, "", out)
  out
}

///|
fn ensure_openrouter_api_key() -> Unit raise @git.GitError {
  let api_key = trim_text(@llm_ffi.get_env("OPENROUTER_API_KEY"))
  if api_key.length() == 0 {
    raise @git.GitError::InvalidObject("rebase-ai requires OPENROUTER_API_KEY")
  }
}

///|
fn build_provider(
  options : AiRebaseOptions,
  provider_ref : Ref[@llmlib.BoxedProvider?],
) -> @llmlib.BoxedProvider raise @git.GitError {
  let agent_loop_mode = use_agent_loop_mode(options)
  match provider_ref.val {
    Some(provider) => provider
    None => {
      ensure_openrouter_api_key()
      let provider = @agent_llm.create_provider(
        default_provider,
        effective_model(options),
        openrouter_system_prompt(agent_loop_mode),
      )
      provider_ref.val = Some(provider)
      provider
    }
  }
}

///|
fn raise_unresolved_conflicts(
  conflicts : Array[String],
) -> Unit raise @git.GitError {
  if conflicts.length() == 0 {
    raise @git.GitError::InvalidObject("rebase-ai: unresolved conflicts remain")
  }
  raise @git.GitError::InvalidObject(
    "rebase-ai failed to resolve conflicts: " + conflicts.join(", "),
  )
}

///|
fn resolve_conflict_paths(
  fs : &@git.FileSystem,
  rfs : &@git.RepoFileSystem,
  root : String,
  paths : Array[String],
  options : AiRebaseOptions,
  provider_ref : Ref[@llmlib.BoxedProvider?],
) -> AiConflictResolution raise @git.GitError {
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
        fs, rfs, root, path, provider, options,
      ) catch {
        _ => false
      }
    } else {
      resolve_conflict_file_with_provider(fs, rfs, root, path, provider) catch {
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
fn normalized_round_limit(options : AiRebaseOptions) -> Int {
  if options.max_auto_rounds <= 0 {
    1
  } else {
    options.max_auto_rounds
  }
}

///|
fn continue_until_non_conflict(
  fs : &@git.FileSystem,
  rfs : &@git.RepoFileSystem,
  root : String,
  initial : @gitlib.RebaseResult,
  options : AiRebaseOptions,
  provider_ref : Ref[@llmlib.BoxedProvider?],
) -> @gitlib.RebaseResult raise @git.GitError {
  let mut current = initial
  let mut rounds = 0
  let round_limit = normalized_round_limit(options)
  while rounds <= round_limit {
    match current.status {
      @gitlib.RebaseStatus::Conflict => ()
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
      fs, rfs, root, conflict_paths, options, provider_ref,
    )
    if resolved.failed.length() > 0 {
      raise_unresolved_conflicts(resolved.failed)
    }
    current = @gitlib.rebase_continue(fs, rfs, root)
    rounds += 1
  }
  current
}

///|
pub fn ai_rebase_start(
  fs : &@git.FileSystem,
  rfs : &@git.RepoFileSystem,
  root : String,
  upstream : @git.ObjectId,
  options? : AiRebaseOptions = AiRebaseOptions::default(),
) -> @gitlib.RebaseResult raise @git.GitError {
  let provider_ref : Ref[@llmlib.BoxedProvider?] = { val: options.provider }
  let start_result = @gitlib.rebase_start(fs, rfs, root, upstream)
  continue_until_non_conflict(
    fs, rfs, root, start_result, options, provider_ref,
  )
}

///|
pub fn ai_rebase_continue(
  fs : &@git.FileSystem,
  rfs : &@git.RepoFileSystem,
  root : String,
  options? : AiRebaseOptions = AiRebaseOptions::default(),
) -> @gitlib.RebaseResult raise @git.GitError {
  let provider_ref : Ref[@llmlib.BoxedProvider?] = { val: options.provider }
  let marker_paths = find_conflict_marker_paths(rfs, root)
  if marker_paths.length() > 0 {
    let resolved = resolve_conflict_paths(
      fs, rfs, root, marker_paths, options, provider_ref,
    )
    if resolved.failed.length() > 0 {
      raise_unresolved_conflicts(resolved.failed)
    }
  }
  let continue_result = @gitlib.rebase_continue(fs, rfs, root)
  continue_until_non_conflict(
    fs, rfs, root, continue_result, options, provider_ref,
  )
}

///|
pub fn ai_rebase_skip(
  fs : &@git.FileSystem,
  rfs : &@git.RepoFileSystem,
  root : String,
  options? : AiRebaseOptions = AiRebaseOptions::default(),
) -> @gitlib.RebaseResult raise @git.GitError {
  let provider_ref : Ref[@llmlib.BoxedProvider?] = { val: options.provider }
  let skip_result = @gitlib.rebase_skip(fs, rfs, root)
  continue_until_non_conflict(fs, rfs, root, skip_result, options, provider_ref)
}

///|
pub fn ai_rebase_abort(
  fs : &@git.FileSystem,
  rfs : &@git.RepoFileSystem,
  root : String,
) -> Unit raise @git.GitError {
  @gitlib.rebase_abort(fs, rfs, root)
}

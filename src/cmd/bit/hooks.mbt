///|
/// Hooks command for bit.

///|
async fn print_x_hooks_usage() -> Unit {
  let usage =
    #|Usage: bit/x/hooks <subcommand> [<args>]
    #|
    #|Experimental: Hooks are designed for carefully controlled local workflows.
    #|Avoid overusing them as automation primitives.
    #|
    #|bit/x/hooks list [<prefix>]
    #|  List hooks under .git/hooks (enabled) and .bit/hooks (available).
    #|  Optional <prefix> filters hook names.
    #|
    #|bit/x/hooks set <name> <source_file>
    #|  Save hook source as an available hook under .bit/hooks.
    #|
    #|bit/x/hooks approve <name>
    #|  Enable a hook by copying from .bit/hooks to .git/hooks.
    #|
    #|bit/x/hooks unapprove <name>
    #|  Disable a hook by removing it from .git/hooks.
    #|
    #|bit/x/hooks remove <name>
    #|  Remove an available hook from .bit/hooks.
    #|
    #|Examples:
    #|  bit/x/hooks list
    #|  bit/x/hooks set pre-add /tmp/pre-add
    #|  bit/x/hooks set postclone /tmp/postclone
    #|  bit/x/hooks approve pre-add
    #|  bit/x/hooks approve postclone
    #|  bit/x/hooks unapprove pre-add
    #|  bit/x/hooks unapprove postclone
    #|  bit/x/hooks remove pre-add
    #|  bit/x/hooks remove postclone
  print_line(usage)
}

///|
fn hooks_dir(git_dir : String) -> String {
  git_dir + "/hooks"
}

///|
fn bit_hooks_dir(root : String) -> String {
  join_repo_marker(root, ".bit/hooks")
}

///|
fn hooks_file_path(git_dir : String, name : String) -> String {
  hooks_dir(git_dir) + "/" + name
}

///|
fn bit_hooks_file_path(root : String, name : String) -> String {
  bit_hooks_dir(root) + "/" + name
}

///|
fn is_valid_hook_name(name : String) -> Bool {
  if name.length() == 0 {
    return false
  }
  if name == "." || name == ".." {
    return false
  }
  match name.find(" ") {
    Some(_) => return false
    None => ()
  }
  match name.find("/") {
    Some(_) => return false
    None => ()
  }
  match name.find("\\") {
    Some(_) => return false
    None => ()
  }
  match name.find("\n") {
    Some(_) => return false
    None => ()
  }
  match name.find("\r") {
    Some(_) => return false
    None => ()
  }
  match name.find("\t") {
    Some(_) => return false
    None => ()
  }
  true
}

///|
fn list_hooks_in_dir(
  fs : OsFs,
  dir : String,
  prefix : String?,
) -> Array[String] {
  if not(fs.is_dir(dir)) {
    return []
  }
  let names : Array[String] = []
  let entries = fs.readdir(dir) catch { _ => [] }
  for entry in entries {
    if entry == "." || entry == ".." {
      continue
    }
    let path = dir + "/" + entry
    if fs.is_dir(path) {
      continue
    }
    match prefix {
      Some(p) if not(entry.has_prefix(p)) => continue
      _ => ()
    }
    names.push(entry)
  }
  names.sort_by((a, b) => a.compare(b))
  names
}

///|
fn list_hooks(fs : OsFs, git_dir : String, prefix : String?) -> Array[String] {
  list_hooks_in_dir(fs, hooks_dir(git_dir), prefix)
}

///|
fn list_available_hooks(
  fs : OsFs,
  root : String,
  prefix : String?,
) -> Array[String] {
  list_hooks_in_dir(fs, bit_hooks_dir(root), prefix)
}

///|
fn list_hooks_with_status(
  fs : OsFs,
  root : String,
  git_dir : String,
  prefix : String?,
) -> Array[String] {
  let active = list_hooks(fs, git_dir, prefix)
  let available = list_available_hooks(fs, root, prefix)
  let names = []
  for name in active {
    if not(names.contains(name)) {
      names.push(name)
    }
  }
  for name in available {
    if not(names.contains(name)) {
      names.push(name)
    }
  }
  names.sort_by((a, b) => a.compare(b))
  let out : Array[String] = []
  for name in names {
    if available.contains(name) {
      if active.contains(name) {
        out.push("\{name} (available, enabled)")
      } else {
        out.push("\{name} (available)")
      }
    } else {
      out.push("\{name} (enabled)")
    }
  }
  out
}

///|
fn hooks_sensitive_names() -> Array[String] {
  ["post-checkout", "post-merge", "postclone", "postinstall"]
}

///|
fn hooks_always_prompt_names() -> Array[String] {
  ["postclone", "postinstall"]
}

///|
fn is_always_prompt_hook(name : String) -> Bool {
  for candidate in hooks_always_prompt_names() {
    if name == candidate {
      return true
    }
  }
  false
}

///|
fn is_sensitive_hook(name : String) -> Bool {
  for candidate in hooks_sensitive_names() {
    if name == candidate {
      return true
    }
  }
  false
}

///|
fn hooks_approved_checksum_path(root : String, hook_name : String) -> String {
  join_repo_marker(root, ".bit/hooks/.approved/" + hook_name + ".sha1")
}

///|
fn hooks_active_hook_path(
  rfs : &@bitcore.RepoFileSystem,
  root : String,
  hook_name : String,
) -> String {
  let git_dir = resolve_git_dir(rfs, root)
  git_dir + "/hooks/" + hook_name
}

///|
fn hooks_file_checksum(
  rfs : &@bitcore.RepoFileSystem,
  path : String,
) -> String? {
  if not(rfs.is_file(path)) {
    return None
  }
  let content = rfs.read_file(path) catch { _ => return None }
  Some(@bitcore.sha1(content).to_hex())
}

///|
fn hooks_read_approved_checksum(
  rfs : &@bitcore.RepoFileSystem,
  root : String,
  hook_name : String,
) -> String? {
  let path = hooks_approved_checksum_path(root, hook_name)
  if not(rfs.is_file(path)) {
    return None
  }
  let raw = decode_bytes(rfs.read_file(path) catch { _ => return None })
  let trimmed = trim_string(raw)
  if trimmed.length() == 0 {
    return None
  }
  Some(trimmed)
}

///|
fn hooks_write_approved_checksum(
  wfs : &@bitcore.FileSystem,
  rfs : &@bitcore.RepoFileSystem,
  root : String,
  hook_name : String,
  checksum : String,
) -> Unit {
  let dir = join_repo_marker(root, ".bit/hooks/.approved")
  if not(rfs.is_dir(dir)) {
    wfs.mkdir_p(dir) catch {
      _ => ()
    }
  }
  wfs.write_string(
    hooks_approved_checksum_path(root, hook_name),
    checksum + "\n",
  ) catch {
    _ => ()
  }
}

///|
fn hooks_active_checksum(
  rfs : &@bitcore.RepoFileSystem,
  root : String,
  hook_name : String,
) -> String? {
  hooks_file_checksum(rfs, hooks_active_hook_path(rfs, root, hook_name))
}

///|
fn hooks_is_current_checksum_approved(
  rfs : &@bitcore.RepoFileSystem,
  root : String,
  hook_name : String,
) -> Bool {
  if is_always_prompt_hook(hook_name) {
    return false
  }
  if not(is_sensitive_hook(hook_name)) {
    return true
  }
  match hooks_active_checksum(rfs, root, hook_name) {
    None => true
    Some(current) =>
      match hooks_read_approved_checksum(rfs, root, hook_name) {
        Some(approved) => approved == current
        None => false
      }
  }
}

///|
async fn hooks_prompt_approve_checksum(
  wfs : &@bitcore.FileSystem,
  rfs : &@bitcore.RepoFileSystem,
  root : String,
  hook_name : String,
  current_checksum : String,
) -> Unit {
  let hook_path = hooks_active_hook_path(rfs, root, hook_name)
  let approved = match hooks_read_approved_checksum(rfs, root, hook_name) {
    Some(v) => v
    None => "<not approved yet>"
  }
  if is_always_prompt_hook(hook_name) {
    eprint_line(
      "warning: this hook always requires explicit execution approval: '" +
      hook_name +
      "'",
    )
    eprint_line(
      "warning: this hook is experimental, so avoid overusing it as an automation",
    )
  } else {
    eprint_line(
      "warning: sensitive hook changed since last approval: '" + hook_name + "'",
    )
  }
  eprint_line("  path: " + hook_path)
  eprint_line("  approved checksum: " + approved)
  eprint_line("  current checksum:  " + current_checksum)
  eprint_line(
    "Approve and continue now? [y/N] (or run `bit/x/hooks unapprove " +
    hook_name +
    "` to disable this hook)",
  )
  let bytes : Array[Byte] = []
  let mut finished = false
  while not(finished) {
    match @stdio.stdin.read_some(max_len=64) {
      None => finished = true
      Some(chunk) =>
        for b in chunk {
          if b == 10 {
            finished = true
            break
          }
          if b == 13 {
            continue
          }
          if bytes.length() <= 64 {
            bytes.push(b)
          }
          if bytes.length() >= 64 {
            finished = true
            break
          }
        }
    }
  }
  let answer = trim_string(decode_bytes(bytes_from_array(bytes))).to_lower()
  if answer != "y" && answer != "yes" {
    eprint_line("fatal: rejected unapproved sensitive hook")
    @sys.exit(1)
  }
  hooks_write_approved_checksum(wfs, rfs, root, hook_name, current_checksum)
}

///|
async fn hooks_ensure_sensitive_hook_approval(
  wfs : &@bitcore.FileSystem,
  fs : &@bitcore.RepoFileSystem,
  root : String,
  hook_name : String,
) -> Unit {
  if not(is_sensitive_hook(hook_name)) {
    return
  }
  if not(hooks_is_current_checksum_approved(fs, root, hook_name)) {
    match hooks_active_checksum(fs, root, hook_name) {
      Some(current) =>
        hooks_prompt_approve_checksum(wfs, fs, root, hook_name, current)
      None => ()
    }
  }
}

///|
async fn handle_x_hooks_list(
  root : String,
  git_dir : String,
  args : Array[String],
) -> Unit {
  if args.length() > 0 && (args[0] == "-h" || args[0] == "--help") {
    print_x_hooks_usage()
    return
  }
  if args.length() > 1 {
    eprint_line("usage: bit/x/hooks list [<prefix>]")
    @sys.exit(1)
  }
  let filter = if args.length() > 0 { Some(args[0]) } else { None }
  let fs = OsFs::new()
  let hooks = list_hooks_with_status(fs, root, git_dir, filter)
  if hooks.length() == 0 {
    print_line("No hooks configured.")
    return
  }
  for hook in hooks {
    print_line(hook)
  }
}

///|
async fn handle_x_hooks_set(
  fs : OsFs,
  root : String,
  args : Array[String],
) -> Unit raise Error {
  if args.length() == 1 && (args[0] == "-h" || args[0] == "--help") {
    print_x_hooks_usage()
    return
  }
  if args.length() != 2 {
    eprint_line("usage: bit/x/hooks set <name> <source_file>")
    @sys.exit(1)
  }
  let name = args[0]
  let source = args[1]
  if not(is_valid_hook_name(name)) {
    eprint_line("fatal: invalid hook name '\{name}'")
    @sys.exit(1)
  }
  let source_path = abs_path(source)
  if not(fs.is_file(source_path)) {
    eprint_line("fatal: cannot read hook source '\{source_path}'")
    @sys.exit(1)
  }
  let dir = bit_hooks_dir(root)
  if not(fs.is_dir(dir)) {
    fs.mkdir_p(dir)
  }
  let target = bit_hooks_file_path(root, name)
  let content = fs.read_file(source_path)
  fs.write_file(target, content)
  @asyncfs.chmod(target[:], 0o755) catch {
    _ => ()
  }
}

///|
async fn handle_x_hooks_approve(
  fs : OsFs,
  root : String,
  git_dir : String,
  args : Array[String],
) -> Unit raise Error {
  if args.length() == 1 && (args[0] == "-h" || args[0] == "--help") {
    print_x_hooks_usage()
    return
  }
  if args.length() != 1 {
    eprint_line("usage: bit/x/hooks approve <name>")
    @sys.exit(1)
  }
  let name = args[0]
  if not(is_valid_hook_name(name)) {
    eprint_line("fatal: invalid hook name '\{name}'")
    @sys.exit(1)
  }
  let source = bit_hooks_file_path(root, name)
  if not(fs.is_file(source)) {
    eprint_line("fatal: hook '\{name}' is not available")
    @sys.exit(1)
  }
  let target_dir = hooks_dir(git_dir)
  if not(fs.is_dir(target_dir)) {
    fs.mkdir_p(target_dir)
  }
  let target = hooks_file_path(git_dir, name)
  let content = fs.read_file(source)
  fs.write_file(target, content)
  @asyncfs.chmod(target[:], 0o755) catch {
    _ => ()
  }
  if is_sensitive_hook(name) {
    match hooks_active_checksum(fs, root, name) {
      Some(checksum) =>
        hooks_write_approved_checksum(fs, fs, root, name, checksum)
      None => ()
    }
  }
}

///|
async fn handle_x_hooks_unapprove(
  fs : OsFs,
  git_dir : String,
  args : Array[String],
) -> Unit raise Error {
  if args.length() == 1 && (args[0] == "-h" || args[0] == "--help") {
    print_x_hooks_usage()
    return
  }
  if args.length() != 1 {
    eprint_line("usage: bit/x/hooks unapprove <name>")
    @sys.exit(1)
  }
  let name = args[0]
  if not(is_valid_hook_name(name)) {
    eprint_line("fatal: invalid hook name '\{name}'")
    @sys.exit(1)
  }
  let path = hooks_file_path(git_dir, name)
  if fs.is_file(path) {
    fs.remove_file(path)
    return
  }
  if fs.is_dir(path) {
    fs.remove_dir(path)
    return
  }
  eprint_line("fatal: hook '\{name}' is not enabled")
  @sys.exit(1)
}

///|
async fn handle_x_hooks_remove(
  fs : OsFs,
  root : String,
  args : Array[String],
) -> Unit raise Error {
  if args.length() == 1 && (args[0] == "-h" || args[0] == "--help") {
    print_x_hooks_usage()
    return
  }
  if args.length() != 1 {
    eprint_line("usage: bit/x/hooks remove <name>")
    @sys.exit(1)
  }
  let name = args[0]
  if not(is_valid_hook_name(name)) {
    eprint_line("fatal: invalid hook name '\{name}'")
    @sys.exit(1)
  }
  let path = bit_hooks_file_path(root, name)
  if fs.is_file(path) {
    fs.remove_file(path)
    return
  }
  if fs.is_dir(path) {
    fs.remove_dir(path)
    return
  }
  eprint_line("fatal: hook '\{name}' is not available")
  @sys.exit(1)
}

///|
async fn handle_x_hooks(args : Array[String]) -> Unit raise Error {
  let root = get_work_root()
  let fs = OsFs::new()
  let rfs : &@bitcore.RepoFileSystem = fs
  let git_dir = resolve_git_dir(rfs, root)
  if not(fs.is_dir(git_dir)) {
    eprint_line("fatal: not a git repository")
    @sys.exit(1)
  }
  if args.length() == 0 {
    print_x_hooks_usage()
    return
  }
  let subcmd = args[0]
  let rest = collect_args(args, 1)
  match subcmd {
    "list" => handle_x_hooks_list(root, git_dir, rest)
    "set" => handle_x_hooks_set(fs, root, rest)
    "approve" => handle_x_hooks_approve(fs, root, git_dir, rest)
    "unapprove" => handle_x_hooks_unapprove(fs, git_dir, rest)
    "remove" => handle_x_hooks_remove(fs, root, rest)
    "-h" | "--help" | "help" => print_x_hooks_usage()
    _ => {
      eprint_line("fatal: unknown subcommand '\{subcmd}'")
      print_x_hooks_usage()
      @sys.exit(1)
    }
  }
}

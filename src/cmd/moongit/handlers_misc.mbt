///| Miscellaneous handlers: diff, merge, tag, rm, mv, config, sparse-checkout, rev-parse, cat-file, ls-files, hash-object, ls-tree, write-tree, show-ref, update-ref, symbolic-ref

///|
async fn handle_diff(args : Array[String]) -> Unit raise Error {
  let root = get_work_root()
  let fs = OsFs::new()
  let mut cached = false
  let mut stat_mode = false
  let mut name_only = false
  let mut name_status = false
  let paths : Array[String] = []
  for arg in args {
    match arg {
      "--cached" | "--staged" => cached = true
      "--stat" => stat_mode = true
      "--name-only" => name_only = true
      "--name-status" => name_status = true
      _ if not(arg.has_prefix("-")) => paths.push(arg)
      _ => ()
    }
  }
  let all_files = if cached {
    @gitlib.diff_index(fs, root)
  } else {
    @gitlib.diff_worktree(fs, root)
  }
  // Filter by paths if specified
  let files = if paths.length() > 0 {
    all_files
    .iter()
    .filter(fn(f) {
      paths.iter().any(fn(p) { f.path == p || f.path.has_prefix(p + "/") })
    })
    .collect()
  } else {
    all_files
  }
  // Output based on mode
  if name_only {
    for f in files {
      print_line(f.path)
    }
  } else if name_status {
    for f in files {
      let status = match f.kind {
        @gitlib.DiffKind::Added => "A"
        @gitlib.DiffKind::Modified => "M"
        @gitlib.DiffKind::Deleted => "D"
      }
      print_line("\{status}\t\{f.path}")
    }
  } else if stat_mode {
    let lines = @gitlib.diff_stat(files)
    for line in lines {
      print_line(line)
    }
  } else {
    let lines = @gitlib.diff_text(files)
    for line in lines {
      print_line(line)
    }
  }
}

///|
async fn handle_merge(args : Array[String]) -> Unit raise Error {
  let root = get_work_root()
  let git_dir = root + "/.git"
  let fs = OsFs::new()
  let mut target_ref : String? = None
  let mut message : String? = None
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    match arg {
      "-m" if i + 1 < args.length() => {
        message = Some(args[i + 1])
        i += 2
        continue
      }
      _ if arg.has_prefix("-m") => {
        message = Some((try! arg[2:]).to_string())
        i += 1
        continue
      }
      _ if not(arg.has_prefix("-")) => target_ref = Some(arg)
      _ => ()
    }
    i += 1
  }
  guard target_ref is Some(refspec) else {
    raise @git.GitError::InvalidObject("No commit to merge specified")
  }
  // Resolve target
  let target_id = @gitlib.rev_parse(fs, git_dir, refspec)
  guard target_id is Some(tid) else {
    raise @git.GitError::InvalidObject("unknown revision: \{refspec}")
  }
  let author = get_author_string()
  let timestamp = get_commit_timestamp()
  let msg = message.unwrap_or("Merge \{refspec}")
  let result = @gitlib.merge(fs, fs, root, tid, msg, author, timestamp)
  match result.status {
    @gitlib.MergeStatus::AlreadyUpToDate => print_line("Already up to date.")
    @gitlib.MergeStatus::FastForward =>
      match result.commit_id {
        Some(id) => {
          let short = String::unsafe_substring(id.to_hex(), start=0, end=7)
          print_line("Fast-forward to \{short}")
        }
        None => print_line("Fast-forward")
      }
    @gitlib.MergeStatus::Merged =>
      match result.commit_id {
        Some(id) => {
          let short = String::unsafe_substring(id.to_hex(), start=0, end=7)
          print_line("Merge made by the 'ort' strategy. [\{short}]")
        }
        None => print_line("Merged")
      }
    @gitlib.MergeStatus::Conflicted => {
      print_line("CONFLICT (content): Merge conflict in the following files:")
      for path in result.conflicts {
        print_line("  \{path}")
      }
      print_line("Automatic merge failed; fix conflicts and then commit.")
    }
  }
}

///|
async fn handle_tag(args : Array[String]) -> Unit raise Error {
  let root = get_work_root()
  let git_dir = root + "/.git"
  let fs = OsFs::new()
  let mut list_mode = true
  let mut delete_mode = false
  let mut annotated = false
  let mut message : String? = None
  let mut tag_name : String? = None
  let mut target : String? = None
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    match arg {
      "-l" | "--list" => list_mode = true
      "-d" | "--delete" => {
        delete_mode = true
        list_mode = false
      }
      "-a" | "--annotate" => {
        annotated = true
        list_mode = false
      }
      "-m" if i + 1 < args.length() => {
        message = Some(args[i + 1])
        annotated = true
        list_mode = false
        i += 2
        continue
      }
      _ if arg.has_prefix("-m") => {
        message = Some((try! arg[2:]).to_string())
        annotated = true
        list_mode = false
        i += 1
        continue
      }
      _ if arg.has_prefix("--message=") => {
        message = Some((try! arg[10:]).to_string())
        annotated = true
        list_mode = false
        i += 1
        continue
      }
      _ if not(arg.has_prefix("-")) =>
        if tag_name is None {
          tag_name = Some(arg)
          list_mode = false
        } else if target is None {
          target = Some(arg)
        }
      _ => ()
    }
    i += 1
  }
  if delete_mode {
    guard tag_name is Some(name) else {
      raise @git.GitError::InvalidObject("tag name required for delete")
    }
    @gitlib.delete_tag(fs, git_dir, name)
    print_line("Deleted tag '\{name}'")
    return ()
  }
  if list_mode {
    let tags = @gitlib.list_tags(fs, git_dir)
    for tag in tags {
      print_line(tag)
    }
    return ()
  }
  guard tag_name is Some(name) else {
    raise @git.GitError::InvalidObject("tag name required")
  }
  // Resolve target (default to HEAD)
  let target_ref = target.unwrap_or("HEAD")
  let commit_id = @gitlib.rev_parse(fs, git_dir, target_ref)
  guard commit_id is Some(id) else {
    raise @git.GitError::InvalidObject("unknown revision: \{target_ref}")
  }
  if annotated {
    let msg = message.unwrap_or("")
    let author = get_author_string()
    let timestamp = get_commit_timestamp()
    @gitlib.create_annotated_tag(
      fs, fs, git_dir, name, id, msg, author, timestamp,
    )
  } else {
    @gitlib.create_lightweight_tag(fs, git_dir, name, id)
  }
}

///|
fn handle_rm(args : Array[String]) -> Unit raise Error {
  let root = get_work_root()
  let fs = OsFs::new()
  let mut cached = false
  let mut force = false
  let mut recursive = false
  let paths : Array[String] = []
  for arg in args {
    match arg {
      "--cached" => cached = true
      "-f" | "--force" => force = true
      "-r" => recursive = true
      _ if not(arg.has_prefix("-")) => paths.push(arg)
      _ => ()
    }
  }
  if paths.length() == 0 {
    raise @git.GitError::InvalidObject("No pathspec given")
  }
  @gitlib.rm_paths(fs, fs, root, paths, cached~, force~, recursive~)
}

///|
fn handle_mv(args : Array[String]) -> Unit raise Error {
  let root = get_work_root()
  let fs = OsFs::new()
  let mut force = false
  let paths : Array[String] = []
  for arg in args {
    match arg {
      "-f" | "--force" => force = true
      _ if not(arg.has_prefix("-")) => paths.push(arg)
      _ => ()
    }
  }
  if paths.length() < 2 {
    raise @git.GitError::InvalidObject("usage: git mv <source> <destination>")
  }
  let source = paths[0]
  let dest = paths[1]
  @gitlib.mv_path(fs, fs, root, source, dest, force~)
}

///|
async fn handle_config(args : Array[String]) -> Unit raise Error {
  let root = get_work_root()
  let git_dir = root + "/.git"
  let fs = OsFs::new()
  let config_path = git_dir + "/config"
  // Parse arguments
  let mut get_mode = false
  let mut get_bool = false
  let mut key : String? = None
  let mut value : String? = None
  for arg in args {
    match arg {
      "--get" => get_mode = true
      "--bool" => get_bool = true
      _ if arg.has_prefix("-") => ()
      _ =>
        if key is None {
          key = Some(arg)
        } else if value is None {
          value = Some(arg)
        }
    }
  }
  guard key is Some(k) else {
    raise @git.GitError::InvalidObject("key required")
  }
  if get_mode || value is None {
    // Read config
    if not(fs.is_file(config_path)) {
      raise @git.GitError::InvalidObject("config not found")
    }
    let content = decode_bytes(fs.read_file(config_path))
    let parts = k.split(".").map(fn(v) { v.to_string() }).collect()
    if parts.length() != 2 {
      raise @git.GitError::InvalidObject("invalid key format")
    }
    let section = parts[0]
    let name = parts[1]
    let mut in_section = false
    for line_view in content.split("\n") {
      let line = trim_string(line_view.to_string())
      if line.has_prefix("[") && line.has_suffix("]") {
        let sec_name = String::unsafe_substring(
          line,
          start=1,
          end=line.length() - 1,
        )
        in_section = sec_name == section ||
          sec_name.has_prefix(section + " ") ||
          sec_name.has_prefix(section + "\t")
        continue
      }
      if in_section && line.has_prefix(name + " = ") {
        let val = String::unsafe_substring(
          line,
          start=name.length() + 3,
          end=line.length(),
        )
        if get_bool {
          print_line(if val == "true" || val == "1" { "true" } else { "false" })
        } else {
          print_line(val)
        }
        return
      }
      if in_section && line.has_prefix(name + "=") {
        let val = String::unsafe_substring(
          line,
          start=name.length() + 1,
          end=line.length(),
        )
        if get_bool {
          print_line(if val == "true" || val == "1" { "true" } else { "false" })
        } else {
          print_line(val)
        }
        return
      }
    }
    // Key not found
    raise @git.GitError::InvalidObject("key not found: " + k)
  } else {
    // Write config - fallback to system git for now
    raise @git.GitError::InvalidObject("config write not implemented")
  }
}

///|
async fn handle_sparse_checkout(args : Array[String]) -> Unit raise Error {
  let root = get_work_root()
  let git_dir = root + "/.git"
  let fs = OsFs::new()
  if args.length() == 0 {
    raise @git.GitError::InvalidObject(
      "usage: git sparse-checkout <init|set|add|list|disable>",
    )
  }
  let subcmd = args[0]
  let rest : Array[String] = []
  for i in 1..<args.length() {
    rest.push(args[i])
  }
  match subcmd {
    "init" => {
      let cone = rest.contains("--cone")
      @gitlib.sparse_checkout_init(fs, fs, root, cone~)
      print_line("Sparse checkout initialized")
    }
    "set" => {
      let patterns = rest
        .iter()
        .filter(fn(arg) { not(arg.has_prefix("-")) })
        .collect()
      if patterns.length() == 0 {
        raise @git.GitError::InvalidObject("patterns required for set")
      }
      @gitlib.sparse_checkout_set(fs, fs, root, patterns)
      print_line("Sparse checkout patterns set")
    }
    "add" => {
      let patterns = rest
        .iter()
        .filter(fn(arg) { not(arg.has_prefix("-")) })
        .collect()
      if patterns.length() == 0 {
        raise @git.GitError::InvalidObject("patterns required for add")
      }
      @gitlib.sparse_checkout_add(fs, fs, root, patterns)
      print_line("Sparse checkout patterns added")
    }
    "list" => {
      let patterns = @gitlib.read_sparse_patterns(fs, git_dir)
      for p in patterns {
        print_line(p)
      }
    }
    "disable" => {
      @gitlib.sparse_checkout_disable(fs, fs, root)
      print_line("Sparse checkout disabled")
    }
    _ =>
      raise @git.GitError::InvalidObject(
        "unknown sparse-checkout subcommand: \{subcmd}",
      )
  }
}

///|
async fn handle_rev_parse(args : Array[String]) -> Unit raise Error {
  let root = get_work_root()
  let git_dir = root + "/.git"
  let fs = OsFs::new()
  for arg in args {
    match arg {
      "--git-dir" => print_line(git_dir)
      "--show-toplevel" => {
        let abs = if root == "." {
          @sys.get_env_var("PWD").unwrap_or(root)
        } else {
          root
        }
        print_line(abs)
      }
      _ if arg.has_prefix("-") => ()
      _ => {
        let id = @gitlib.rev_parse(fs, git_dir, arg)
        match id {
          Some(oid) => print_line(oid.to_hex())
          None => raise @git.GitError::InvalidObject("unknown revision: " + arg)
        }
      }
    }
  }
}

///|
async fn handle_cat_file(args : Array[String]) -> Unit raise Error {
  let root = get_work_root()
  let git_dir = root + "/.git"
  let fs = OsFs::new()
  let mut show_type = false
  let mut show_size = false
  let mut pretty_print = false
  let mut obj_spec : String? = None
  for arg in args {
    match arg {
      "-t" => show_type = true
      "-s" => show_size = true
      "-p" => pretty_print = true
      _ if arg.has_prefix("-") => ()
      _ => obj_spec = Some(arg)
    }
  }
  guard obj_spec is Some(spec) else {
    raise @git.GitError::InvalidObject("object name required")
  }
  let obj_id = @gitlib.rev_parse(fs, git_dir, spec)
  guard obj_id is Some(oid) else {
    raise @git.GitError::InvalidObject("Not a valid object name: \{spec}")
  }
  let db = @gitlib.ObjectDb::load(fs, git_dir)
  let obj = db.get(fs, oid)
  guard obj is Some(o) else {
    raise @git.GitError::InvalidObject("Object not found: \{spec}")
  }
  if show_type {
    print_line(o.obj_type.to_string())
    return ()
  }
  if show_size {
    print_line(o.data.length().to_string())
    return ()
  }
  if pretty_print {
    match o.obj_type {
      @git.ObjectType::Blob => @stdio.stdout.write(o.data)
      @git.ObjectType::Tree => {
        let entries = @git.parse_tree(o.data)
        for entry in entries {
          let mode_str = if entry.mode == "40000" {
            "040000"
          } else {
            entry.mode
          }
          let type_str = if entry.mode == "40000" { "tree" } else { "blob" }
          print_line("\{mode_str} \{type_str} \{entry.id.to_hex()}\t\{entry.name}")
        }
      }
      @git.ObjectType::Commit => {
        let text = decode_bytes(o.data)
        print_line(text)
      }
      @git.ObjectType::Tag => {
        let text = decode_bytes(o.data)
        print_line(text)
      }
    }
    return ()
  }
  // Default: output raw content
  @stdio.stdout.write(o.data)
}

///|
async fn handle_ls_files(args : Array[String]) -> Unit raise Error {
  let root = get_work_root()
  let git_dir = root + "/.git"
  let fs = OsFs::new()
  let mut show_stage = false
  let mut show_others = false
  let mut show_deleted = false
  for arg in args {
    match arg {
      "-s" | "--stage" => show_stage = true
      "-c" | "--cached" => () // default mode, no-op
      "-o" | "--others" => show_others = true
      "-d" | "--deleted" => show_deleted = true
      _ => ()
    }
  }
  let entries = @gitlib.read_index_entries(fs, git_dir)
  if show_others {
    // Show untracked files
    let tracked : Map[String, Bool] = {}
    for e in entries {
      tracked[e.path] = true
    }
    let all_files = @gitlib.list_working_files(fs, root)
    for path in all_files {
      if not(tracked.contains(path)) {
        print_line(path)
      }
    }
    return ()
  }
  if show_deleted {
    // Show deleted files (in index but not in worktree)
    for e in entries {
      let abs = root + "/" + e.path
      if not(fs.is_file(abs)) {
        print_line(e.path)
      }
    }
    return ()
  }
  // Default: show cached (indexed) files
  if show_stage {
    for e in entries {
      let mode = format_mode(e.mode)
      // Stage is always 0 for normal entries (no merge conflict)
      print_line("\{mode} \{e.id.to_hex()} 0\t\{e.path}")
    }
  } else {
    for e in entries {
      print_line(e.path)
    }
  }
}

///|
fn format_mode(mode : Int) -> String {
  // Convert mode to octal string (6 digits)
  let mut n = mode
  let digits : Array[String] = []
  while n > 0 {
    digits.push((n % 8).to_string())
    n = n / 8
  }
  while digits.length() < 6 {
    digits.push("0")
  }
  digits.rev_in_place()
  digits.iter().fold(init="", fn(acc, d) { acc + d })
}

///|
async fn handle_hash_object(args : Array[String]) -> Unit raise Error {
  let root = get_work_root()
  let git_dir = root + "/.git"
  let fs = OsFs::new()
  let mut write_object = false
  let mut stdin_mode = false
  let mut obj_type = "blob"
  let paths : Array[String] = []
  for arg in args {
    match arg {
      "-w" => write_object = true
      "--stdin" => stdin_mode = true
      "-t" => () // next arg is type, handled below
      _ if arg.has_prefix("-t") =>
        obj_type = String::unsafe_substring(arg, start=2, end=arg.length())
      _ if not(arg.has_prefix("-")) => paths.push(arg)
      _ => ()
    }
  }
  // Handle -t <type> pattern
  let mut i = 0
  while i < args.length() {
    if args[i] == "-t" && i + 1 < args.length() {
      obj_type = args[i + 1]
    }
    i += 1
  }
  if stdin_mode {
    let content = read_all_stdin()
    let id = @git.hash_object_content(parse_object_type(obj_type), content)
    if write_object {
      let _ = @gitlib.write_loose_object(fs, git_dir, parse_object_type(obj_type), content)

    }
    print_line(id.to_hex())
    return ()
  }
  for path in paths {
    let abs = if path.has_prefix("/") { path } else { root + "/" + path }
    let content = fs.read_file(abs)
    let id = @git.hash_object_content(parse_object_type(obj_type), content)
    if write_object {
      let _ = @gitlib.write_loose_object(fs, git_dir, parse_object_type(obj_type), content)

    }
    print_line(id.to_hex())
  }
}

///|
fn parse_object_type(s : String) -> @git.ObjectType {
  match s {
    "blob" => @git.ObjectType::Blob
    "tree" => @git.ObjectType::Tree
    "commit" => @git.ObjectType::Commit
    "tag" => @git.ObjectType::Tag
    _ => @git.ObjectType::Blob
  }
}

///|
async fn handle_ls_tree(args : Array[String]) -> Unit raise Error {
  let root = get_work_root()
  let git_dir = root + "/.git"
  let fs = OsFs::new()
  let mut recursive = false
  let mut name_only = false
  let mut tree_spec : String? = None
  for arg in args {
    match arg {
      "-r" | "--recursive" => recursive = true
      "--name-only" | "--name-status" => name_only = true
      _ if not(arg.has_prefix("-")) => tree_spec = Some(arg)
      _ => ()
    }
  }
  guard tree_spec is Some(spec) else {
    raise @git.GitError::InvalidObject("tree-ish required")
  }
  let tree_id = @gitlib.rev_parse(fs, git_dir, spec)
  guard tree_id is Some(tid) else {
    raise @git.GitError::InvalidObject("Not a valid object name: \{spec}")
  }
  let db = @gitlib.ObjectDb::load(fs, git_dir)
  // Resolve to tree if it's a commit
  let actual_tree_id = resolve_to_tree(db, fs, tid)
  print_tree_entries(db, fs, actual_tree_id, "", recursive, name_only)
}

///|
fn resolve_to_tree(
  db : @gitlib.ObjectDb,
  fs : &@git.RepoFileSystem,
  id : @git.ObjectId,
) -> @git.ObjectId raise @git.GitError {
  let obj = db.get(fs, id)
  guard obj is Some(o) else {
    raise @git.GitError::InvalidObject("Object not found")
  }
  match o.obj_type {
    @git.ObjectType::Tree => id
    @git.ObjectType::Commit => {
      let info = @git.parse_commit(o.data)
      info.tree
    }
    _ => raise @git.GitError::InvalidObject("Not a tree or commit")
  }
}

///|
async fn print_tree_entries(
  db : @gitlib.ObjectDb,
  fs : &@git.RepoFileSystem,
  tree_id : @git.ObjectId,
  prefix : String,
  recursive : Bool,
  name_only : Bool,
) -> Unit raise Error {
  let obj = db.get(fs, tree_id)
  guard obj is Some(o) else {
    raise @git.GitError::InvalidObject("Tree not found")
  }
  let entries = @git.parse_tree(o.data)
  for entry in entries {
    let path = if prefix.length() == 0 {
      entry.name
    } else {
      prefix + "/" + entry.name
    }
    let is_tree = entry.mode == "40000" || entry.mode == "040000"
    if name_only {
      if not(is_tree) || not(recursive) {
        print_line(path)
      }
    } else {
      let mode_str = if entry.mode == "40000" { "040000" } else { entry.mode }
      let type_str = if is_tree { "tree" } else { "blob" }
      print_line("\{mode_str} \{type_str} \{entry.id.to_hex()}\t\{path}")
    }
    if recursive && is_tree {
      print_tree_entries(db, fs, entry.id, path, recursive, name_only)
    }
  }
}

///|
async fn handle_write_tree(args : Array[String]) -> Unit raise Error {
  let root = get_work_root()
  let git_dir = root + "/.git"
  let fs = OsFs::new()
  // Parse --prefix option
  let mut prefix : String? = None
  for arg in args {
    if arg.has_prefix("--prefix=") {
      prefix = Some((try! arg[9:]).to_string())
    }
  }
  let entries = @gitlib.read_index_entries(fs, git_dir)
  let tree_id = @gitlib.write_tree_from_index(fs, git_dir, entries, prefix=prefix)
  print_line(tree_id.to_hex())
}

///|
async fn handle_show_ref(args : Array[String]) -> Unit raise Error {
  let root = get_work_root()
  let git_dir = root + "/.git"
  let fs = OsFs::new()
  let mut heads_only = false
  let mut tags_only = false
  for arg in args {
    match arg {
      "--heads" => heads_only = true
      "--tags" => tags_only = true
      _ => ()
    }
  }
  let refs = @gitlib.show_ref(fs, git_dir)
  for item in refs {
    let (refname, id) = item
    if heads_only && not(refname.has_prefix("refs/heads/")) {
      continue
    }
    if tags_only && not(refname.has_prefix("refs/tags/")) {
      continue
    }
    print_line("\{id.to_hex()} \{refname}")
  }
}

///|
fn handle_update_ref(args : Array[String]) -> Unit raise Error {
  let root = get_work_root()
  let git_dir = root + "/.git"
  let fs = OsFs::new()
  let mut delete_mode = false
  let positional : Array[String] = []
  for arg in args {
    match arg {
      "-d" | "--delete" => delete_mode = true
      _ if not(arg.has_prefix("-")) => positional.push(arg)
      _ => ()
    }
  }
  if delete_mode {
    if positional.length() < 1 {
      raise @git.GitError::InvalidObject("usage: git update-ref -d <refname>")
    }
    let refname = positional[0]
    let ref_path = git_dir + "/" + refname
    if fs.is_file(ref_path) {
      fs.remove_file(ref_path)
    }
    return ()
  }
  if positional.length() < 2 {
    raise @git.GitError::InvalidObject(
      "usage: git update-ref <refname> <newvalue>",
    )
  }
  let refname = positional[0]
  let new_value = positional[1]
  let new_id = @git.ObjectId::from_hex(new_value)
  let ref_path = git_dir + "/" + refname
  // Ensure parent directory exists
  let dir = match ref_path.rev_find("/") {
    None => ""
    Some(i) => String::unsafe_substring(ref_path, start=0, end=i)
  }
  if dir.length() > 0 {
    fs.mkdir_p(dir)
  }
  fs.write_string(ref_path, new_id.to_hex() + "\n")
}

///|
async fn handle_symbolic_ref(args : Array[String]) -> Unit raise Error {
  let root = get_work_root()
  let git_dir = root + "/.git"
  let fs = OsFs::new()
  let mut delete_mode = false
  let mut short_mode = false
  let positional : Array[String] = []
  for arg in args {
    match arg {
      "-d" | "--delete" => delete_mode = true
      "--short" => short_mode = true
      _ if not(arg.has_prefix("-")) => positional.push(arg)
      _ => ()
    }
  }
  if positional.length() == 0 {
    raise @git.GitError::InvalidObject("usage: git symbolic-ref <name> [<ref>]")
  }
  let name = positional[0]
  let ref_path = if name == "HEAD" { git_dir + "/HEAD" } else { git_dir + "/" + name }
  if delete_mode {
    if fs.is_file(ref_path) {
      fs.remove_file(ref_path)
    }
    return ()
  }
  if positional.length() == 1 {
    // Read mode
    if not(fs.is_file(ref_path)) {
      raise @git.GitError::InvalidObject("ref \{name} not found")
    }
    let content = decode_bytes(fs.read_file(ref_path))
    let trimmed = content.trim_end(chars="\n\r ").to_string()
    if trimmed.has_prefix("ref: ") {
      let target = String::unsafe_substring(
        trimmed,
        start=5,
        end=trimmed.length(),
      )
      if short_mode && target.has_prefix("refs/heads/") {
        print_line(
          String::unsafe_substring(target, start=11, end=target.length()),
        )
      } else {
        print_line(target)
      }
    } else {
      raise @git.GitError::InvalidObject("ref \{name} is not a symbolic ref")
    }
  } else {
    // Write mode
    let target = positional[1]
    fs.write_string(ref_path, "ref: \{target}\n")
  }
}

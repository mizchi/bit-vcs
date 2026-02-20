///|
async fn handle_rev_parse(args : Array[String]) -> Unit raise Error {
  let mut sq_quote_mode = false
  let sq_quote_values : Array[String] = []
  for arg in args {
    if sq_quote_mode {
      sq_quote_values.push(arg)
      continue
    }
    if arg == "--sq-quote" {
      sq_quote_mode = true
    }
  }
  if sq_quote_mode {
    let quoted : Array[String] = []
    for value in sq_quote_values {
      quoted.push(shell_single_quote(value))
    }
    if quoted.length() > 0 {
      print_line(" " + quoted.join(" "))
    }
    return
  }
  let root = get_work_root()
  let fs = OsFs::new()
  let rfs : &@bitcore.RepoFileSystem = fs
  let git_dir = resolve_git_dir(rfs, root)
  let cwd_abs = @sys.get_env_var("PWD").unwrap_or(root)
  let abs_git_dir = if git_dir.has_prefix("/") {
    git_dir
  } else if git_dir == "." {
    cwd_abs
  } else {
    cwd_abs + "/" + git_dir
  }
  let mut revs_only = false
  let mut verify = false
  let mut quiet = false
  let mut show_ref_format = false
  let mut show_object_format = false
  let mut short_length : Int? = None
  let mut abbrev_ref = false
  let mut symbolic_full_name = false
  let mut output_object_format : String? = None
  let output_object_format_arg_indices : Map[Int, Bool] = {}
  let mut arg_index = 0
  while arg_index < args.length() {
    let arg = args[arg_index]
    match arg {
      "--revs-only" => revs_only = true
      "--verify" => verify = true
      "--quiet" => quiet = true
      "--show-ref-format" => show_ref_format = true
      "--show-object-format" => show_object_format = true
      "--short" => short_length = Some(7)
      "--abbrev-ref" => abbrev_ref = true
      "--symbolic-full-name" => symbolic_full_name = true
      "--output-object-format" => {
        output_object_format_arg_indices[arg_index] = true
        if arg_index + 1 >= args.length() {
          eprint_line("fatal: option '--output-object-format' requires a value")
          @sys.exit(128)
        }
        output_object_format = Some(args[arg_index + 1])
        output_object_format_arg_indices[arg_index + 1] = true
        arg_index += 2
        continue
      }
      _ if arg.has_prefix("--short=") =>
        match
          parse_rev_parse_short_length(
            String::unsafe_substring(arg, start=8, end=arg.length()),
          ) {
          Some(value) => short_length = Some(value)
          None => short_length = Some(7)
        }
      _ if arg.has_prefix("--abbrev-ref=") => abbrev_ref = true
      _ if arg.has_prefix("--show-object-format=") => show_object_format = true
      _ if arg.has_prefix("--output-object-format=") => {
        output_object_format_arg_indices[arg_index] = true
        output_object_format = Some(
          String::unsafe_substring(arg, start=23, end=arg.length()),
        )
      }
      _ => ()
    }
    arg_index += 1
  }
  if output_object_format is Some(raw_output_format) {
    let requested_format = @bitlib.config_strip_quotes(raw_output_format).to_lower()
    if !rev_parse_output_object_format_supported(fs, git_dir, requested_format) {
      eprint_line("fatal: unsupported object format: \{requested_format}")
      @sys.exit(128)
    }
  }
  ignore(verify)
  ignore(quiet)
  let mut process_index = 0
  while process_index < args.length() {
    if output_object_format_arg_indices.contains(process_index) {
      process_index += 1
      continue
    }
    let arg = args[process_index]
    if arg == "--git-path" {
      if process_index + 1 >= args.length() {
        eprint_line("fatal: option '--git-path' requires a value")
        @sys.exit(128)
      }
      let requested = args[process_index + 1]
      print_line(rev_parse_resolve_git_path(cwd_abs, git_dir, requested))
      process_index += 2
      continue
    }
    if arg.has_prefix("--git-path=") {
      let requested = String::unsafe_substring(arg, start=11, end=arg.length())
      print_line(rev_parse_resolve_git_path(cwd_abs, git_dir, requested))
      process_index += 1
      continue
    }
    match arg {
      "--git-dir" => print_line(git_dir)
      "--absolute-git-dir" => print_line(abs_git_dir)
      "--show-toplevel" => {
        let abs = if root == "." {
          @sys.get_env_var("PWD").unwrap_or(root)
        } else {
          root
        }
        print_line(abs)
      }
      "--show-ref-format" =>
        print_line(
          if is_reftable_repo(fs, git_dir) {
            "reftable"
          } else {
            "files"
          },
        )
      "--show-object-format" => print_line(repo_object_format(fs, git_dir))
      _ if arg.has_prefix("--show-object-format=") => {
        let mode = String::unsafe_substring(arg, start=21, end=arg.length())
        if mode == "storage" || mode == "input" || mode == "output" {
          print_line(repo_object_format(fs, git_dir))
        } else {
          eprint_line("fatal: unknown mode for --show-object-format: \{mode}")
          @sys.exit(128)
        }
      }
      "--revs-only" => ()
      "--verify" => ()
      "--quiet" => ()
      "--short" => ()
      _ if arg.has_prefix("--short=") => ()
      "--abbrev-ref" => ()
      _ if arg.has_prefix("--abbrev-ref=") => ()
      "--symbolic-full-name" => ()
      "--output-object-format" => ()
      _ if arg.has_prefix("--output-object-format=") => ()
      _ if arg.has_prefix("-") => warn_unimplemented_arg("rev-parse", arg)
      _ =>
        if abbrev_ref {
          let name = resolve_abbrev_ref_name(fs, git_dir, arg)
          match name {
            Some(value) => print_line(value)
            None =>
              if not(revs_only) {
                raise @bitcore.GitError::InvalidObject(
                  "unknown revision: " + arg,
                )
              }
          }
        } else if symbolic_full_name {
          let name = resolve_symbolic_full_name(fs, git_dir, arg)
          match name {
            Some(value) => print_line(value)
            None =>
              if not(revs_only) {
                raise @bitcore.GitError::InvalidObject(
                  "unknown revision: " + arg,
                )
              }
          }
        } else {
          let id = if arg == "FETCH_HEAD" {
            resolve_fetch_head_oid(fs, git_dir)
          } else if arg.has_prefix(":") &&
            arg.length() > 1 &&
            not(arg.has_prefix(":/")) {
            resolve_index_path_oid(fs, git_dir, arg)
          } else if arg.find("@{") is Some(_) {
            resolve_reflog_selector(fs, git_dir, arg)
          } else {
            @bitrepo.rev_parse(fs, git_dir, arg)
          }
          match id {
            Some(oid) => {
              let output_oid_hex = rev_parse_resolve_output_oid_hex(
                fs, git_dir, oid, output_object_format,
              )
              match short_length {
                Some(length) =>
                  print_line(shorten_oid_hex(output_oid_hex, length))
                None => print_line(output_oid_hex)
              }
            }
            None =>
              if not(revs_only) {
                raise @bitcore.GitError::InvalidObject(
                  "unknown revision: " + arg,
                )
              }
          }
        }
    }
    process_index += 1
  }
  ignore(show_ref_format)
  ignore(show_object_format)
}

///|
fn rev_parse_resolve_git_path(
  cwd_abs : String,
  git_dir : String,
  requested_path : String,
) -> String {
  if requested_path.length() == 0 {
    if git_dir == "." {
      return "."
    }
    return git_dir
  }
  if requested_path.has_prefix("/") {
    return requested_path
  }
  let abs_git_dir = if git_dir.has_prefix("/") {
    git_dir
  } else if git_dir == "." {
    cwd_abs
  } else {
    cwd_abs + "/" + git_dir
  }
  let abs_target = if abs_git_dir.has_suffix("/") {
    abs_git_dir + requested_path
  } else {
    abs_git_dir + "/" + requested_path
  }
  let cwd_prefix = if cwd_abs.has_suffix("/") { cwd_abs } else { cwd_abs + "/" }
  if abs_target == cwd_abs {
    return "."
  }
  if abs_target.has_prefix(cwd_prefix) {
    return String::unsafe_substring(
      abs_target,
      start=cwd_prefix.length(),
      end=abs_target.length(),
    )
  }
  if git_dir == "." {
    return requested_path
  }
  if git_dir.has_prefix("/") {
    return abs_target
  }
  if git_dir.has_suffix("/") {
    return git_dir + requested_path
  }
  git_dir + "/" + requested_path
}

///|
fn rev_parse_resolve_output_oid_hex(
  fs : &@bitcore.RepoFileSystem,
  git_dir : String,
  oid : @bitcore.ObjectId,
  output_object_format : String?,
) -> String {
  let oid_hex = oid.to_hex()
  guard output_object_format is Some(raw_requested_format) else {
    return oid_hex
  }
  let requested_format = @bitlib.config_strip_quotes(raw_requested_format).to_lower()
  let storage_format = repo_object_format(fs, git_dir)
  if requested_format == storage_format {
    return oid_hex
  }
  match repo_compat_object_format(fs, git_dir) {
    Some(compat_format) if compat_format == requested_format =>
      match rev_parse_lookup_loose_object_idx(fs, git_dir, oid_hex) {
        Some(mapped) => mapped
        None => oid_hex
      }
    _ => oid_hex
  }
}

///|
fn rev_parse_output_object_format_supported(
  fs : &@bitcore.RepoFileSystem,
  git_dir : String,
  requested_format : String,
) -> Bool {
  if requested_format.length() == 0 {
    return false
  }
  let storage_format = repo_object_format(fs, git_dir)
  if requested_format == storage_format {
    return true
  }
  match repo_compat_object_format(fs, git_dir) {
    Some(compat_format) => compat_format == requested_format
    None => false
  }
}

///|
fn resolve_index_path_oid(
  fs : &@bitcore.RepoFileSystem,
  git_dir : String,
  spec : String,
) -> @bitcore.ObjectId? raise Error {
  let (stage, path_opt) = parse_index_pathspec(spec)
  guard path_opt is Some(path) else { return None }
  // Current index reader keeps one entry per path; stage lookup is supported for :0:path only.
  if stage != 0 {
    return None
  }
  let normalized = normalize_index_pathspec_path(path)
  let entries = @bitlib.read_index_entries(fs, git_dir)
  for entry in entries {
    if normalize_index_pathspec_path(entry.path) == normalized {
      return Some(entry.id)
    }
  }
  None
}

///|
fn parse_index_pathspec(spec : String) -> (Int, String?) {
  if not(spec.has_prefix(":")) || spec.length() <= 1 {
    return (0, None)
  }
  let rest = String::unsafe_substring(spec, start=1, end=spec.length())
  let mut stage = 0
  let mut path = rest
  if rest.length() >= 3 && rest[0] >= '0' && rest[0] <= '3' && rest[1] == ':' {
    stage = rest[0].to_int() - '0'.to_int()
    path = String::unsafe_substring(rest, start=2, end=rest.length())
  }
  if path.length() == 0 {
    (stage, None)
  } else {
    (stage, Some(path))
  }
}

///|
fn normalize_index_pathspec_path(path : String) -> String {
  let mut out = path
  while out.has_prefix("./") {
    out = String::unsafe_substring(out, start=2, end=out.length())
  }
  while out.length() > 1 && out.has_suffix("/") {
    out = String::unsafe_substring(out, start=0, end=out.length() - 1)
  }
  out
}

///|
fn parse_rev_parse_short_length(value : String) -> Int? {
  if value.length() == 0 {
    return None
  }
  let mut result = 0
  for c in value {
    if c < '0' || c > '9' {
      return None
    }
    result = result * 10 + (c.to_int() - '0'.to_int())
  }
  Some(result)
}

///|
fn parse_reflog_selector(spec : String) -> (String, Int)? {
  guard spec.has_suffix("}") else { return None }
  match spec.find("@{") {
    Some(idx) => {
      let number_start = idx + 2
      guard number_start < spec.length() - 1 else { return None }
      let number_text = String::unsafe_substring(
        spec,
        start=number_start,
        end=spec.length() - 1,
      )
      let mut number = 0
      for c in number_text {
        if c < '0' || c > '9' {
          return None
        }
        number = number * 10 + (c.to_int() - '0'.to_int())
      }
      let raw_ref = String::unsafe_substring(spec, start=0, end=idx)
      let refname = if raw_ref.length() == 0 || raw_ref == "HEAD" {
        "HEAD"
      } else if raw_ref.has_prefix("refs/") {
        raw_ref
      } else {
        "refs/heads/" + raw_ref
      }
      Some((refname, number))
    }
    None => None
  }
}

///|
fn resolve_reflog_selector(
  fs : &@bitcore.RepoFileSystem,
  git_dir : String,
  spec : String,
) -> @bitcore.ObjectId? raise Error {
  match parse_reflog_selector(spec) {
    Some(parsed) => {
      let refname = parsed.0
      let index = parsed.1
      let entries = @bitrepo.read_reflog(fs, git_dir, refname)
      let len = entries.length()
      if index >= len {
        return None
      }
      Some(entries[len - 1 - index].new_id)
    }
    None => None
  }
}

///|
fn resolve_abbrev_ref_name(
  fs : &@bitcore.RepoFileSystem,
  git_dir : String,
  spec : String,
) -> String? raise Error {
  if spec == "HEAD" {
    return match @bitlib.read_head_ref(fs, git_dir) {
      @bitlib.HeadRef::Branch(name) => Some(name)
      @bitlib.HeadRef::Detached(_) => Some("HEAD")
    }
  }
  if spec.has_prefix("refs/heads/") {
    return Some(String::unsafe_substring(spec, start=11, end=spec.length()))
  }
  if @bitlib.resolve_ref(fs, git_dir, "refs/heads/" + spec) is Some(_) {
    return Some(spec)
  }
  None
}

///|
fn resolve_symbolic_full_name(
  fs : &@bitcore.RepoFileSystem,
  git_dir : String,
  spec : String,
) -> String? raise Error {
  if spec == "HEAD" {
    return match @bitlib.read_head_ref(fs, git_dir) {
      @bitlib.HeadRef::Branch(name) => Some("refs/heads/" + name)
      @bitlib.HeadRef::Detached(_) => Some("HEAD")
    }
  }
  if spec.has_prefix("refs/") {
    return if @bitlib.resolve_ref(fs, git_dir, spec) is Some(_) {
      Some(spec)
    } else {
      None
    }
  }
  let head_ref = "refs/heads/" + spec
  if @bitlib.resolve_ref(fs, git_dir, head_ref) is Some(_) {
    return Some(head_ref)
  }
  let tag_ref = "refs/tags/" + spec
  if @bitlib.resolve_ref(fs, git_dir, tag_ref) is Some(_) {
    return Some(tag_ref)
  }
  let remote_ref = "refs/remotes/" + spec
  if @bitlib.resolve_ref(fs, git_dir, remote_ref) is Some(_) {
    return Some(remote_ref)
  }
  None
}

///|
fn shorten_oid_hex(hex : String, requested : Int) -> String {
  let mut length = requested
  if length < 4 {
    length = 4
  }
  if length > hex.length() {
    length = hex.length()
  }
  String::unsafe_substring(hex, start=0, end=length)
}

///|
fn resolve_fetch_head_oid(
  fs : &@bitcore.RepoFileSystem,
  git_dir : String,
) -> @bitcore.ObjectId? {
  let fetch_head_path = git_dir + "/FETCH_HEAD"
  guard fs.is_file(fetch_head_path) else { return None }
  let content = decode_bytes(
    fs.read_file(fetch_head_path) catch {
      _ => return None
    },
  )
  let mut result : @bitcore.ObjectId? = None
  for line_view in content.split("\n") {
    let line = line_view.to_string().trim().to_string()
    if line.length() == 0 {
      continue
    }
    let oid_hex = match line.find("\t") {
      Some(idx) => String::unsafe_substring(line, start=0, end=idx)
      None =>
        match line.find(" ") {
          Some(space_idx) =>
            String::unsafe_substring(line, start=0, end=space_idx)
          None => line
        }
    }
    if oid_hex.length() == 0 {
      continue
    }
    let oid = @bitcore.ObjectId::from_hex(oid_hex) catch { _ => continue }
    result = Some(oid)
    break
  }
  result
}

///|
fn shell_single_quote(value : String) -> String {
  let out = StringBuilder::new()
  out.write_char('\'')
  for c in value {
    if c == '\'' {
      out.write_char('\'')
      out.write_char('\\')
      out.write_char('\'')
      out.write_char('\'')
    } else {
      out.write_char(c)
    }
  }
  out.write_char('\'')
  out.to_string()
}

///|
fn peel_cat_file_object_to_type(
  db : @bitlib.ObjectDb,
  fs : &@bitcore.RepoFileSystem,
  object_id : @bitcore.ObjectId,
  expected_type : @bitcore.ObjectType,
) -> Bytes raise @bitcore.GitError {
  let mut current_id = object_id
  for _ in 0..<8 {
    let current_obj = db.get(fs, current_id)
    guard current_obj is Some(current) else {
      raise @bitcore.GitError::InvalidObject(
        "Object not found: " + current_id.to_hex(),
      )
    }
    if current.obj_type == expected_type {
      return current.data
    }
    guard current.obj_type == @bitcore.ObjectType::Tag else {
      raise @bitcore.GitError::InvalidObject(
        "object is of type \{current.obj_type.to_string()}, not \{expected_type.to_string()}",
      )
    }
    let tag_text = decode_bytes(current.data)
    let tag_target = rev_parse_parse_tag_target_with_compat(db, fs, tag_text)
    guard tag_target is Some(target_id) else {
      raise @bitcore.GitError::InvalidObject("malformed tag object")
    }
    current_id = target_id
  }
  raise @bitcore.GitError::InvalidObject("tag dereference depth exceeded")
}

///|
fn rev_parse_parse_tag_target_with_compat(
  db : @bitlib.ObjectDb,
  fs : &@bitcore.RepoFileSystem,
  tag_text : String,
) -> @bitcore.ObjectId? {
  let target_name = rev_parse_extract_tag_target_name(tag_text)
  guard target_name is Some(raw_name) else { return None }
  let direct_id : @bitcore.ObjectId? = Some(
    @bitcore.ObjectId::from_hex(raw_name),
  ) catch {
    _ => None
  }
  if direct_id is Some(id) && (db.get(fs, id) catch { _ => None }) is Some(_) {
    return direct_id
  }
  let root = get_work_root()
  let git_dir = resolve_git_dir(fs, root)
  match rev_parse_lookup_loose_object_idx(fs, git_dir, raw_name) {
    Some(mapped_name) => {
      let mapped_id : @bitcore.ObjectId? = Some(
        @bitcore.ObjectId::from_hex(mapped_name),
      ) catch {
        _ => None
      }
      if mapped_id is Some(id) &&
        (db.get(fs, id) catch { _ => None }) is Some(_) {
        return mapped_id
      }
      direct_id
    }
    None => direct_id
  }
}

///|
fn rev_parse_extract_tag_target_name(tag_text : String) -> String? {
  for line_view in tag_text.split("\n") {
    let line = line_view.to_string()
    if line.has_prefix("object ") {
      return Some(
        trim_string(String::unsafe_substring(line, start=7, end=line.length())),
      )
    }
  }
  None
}

///|
fn rev_parse_lookup_loose_object_idx(
  fs : &@bitcore.RepoFileSystem,
  git_dir : String,
  spec : String,
) -> String? {
  let idx_path = git_dir + "/objects/loose-object-idx"
  if !fs.is_file(idx_path) {
    return None
  }
  let text = decode_bytes(fs.read_file(idx_path) catch { _ => return None })
  for line_view in text.split("\n") {
    let line = trim_string(line_view.to_string())
    if line.length() == 0 || line.has_prefix("#") {
      continue
    }
    let cols : Array[String] = []
    for col_view in line.split(" ") {
      let col = trim_string(col_view.to_string())
      if col.length() > 0 {
        cols.push(col)
      }
    }
    if cols.length() < 2 {
      continue
    }
    let a = cols[0]
    let b = cols[1]
    if spec == a {
      return Some(b)
    }
    if spec == b {
      return Some(a)
    }
  }
  None
}

///|

///|
async fn handle_rev_parse(args : Array[String]) -> Unit raise Error {
  if is_real_git_delegate_enabled() {
    delegate_to_real_git("rev-parse", args)
  }
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
  let rfs : &@git.RepoFileSystem = fs
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
  for arg in args {
    match arg {
      "--revs-only" => revs_only = true
      "--verify" => verify = true
      "--quiet" => quiet = true
      "--show-ref-format" => show_ref_format = true
      _ => ()
    }
  }
  ignore(verify)
  ignore(quiet)
  for arg in args {
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
      "--show-ref-format" => {
        print_line("files")
      }
      "--revs-only" => ()
      "--verify" => ()
      "--quiet" => ()
      _ if arg.has_prefix("-") => warn_unimplemented_arg("rev-parse", arg)
      _ => {
        let id = if arg == "FETCH_HEAD" {
          resolve_fetch_head_oid(fs, git_dir)
        } else {
          @gitrepo.rev_parse(fs, git_dir, arg)
        }
        match id {
          Some(oid) => print_line(oid.to_hex())
          None =>
            if not(revs_only) {
              raise @git.GitError::InvalidObject("unknown revision: " + arg)
            }
        }
      }
    }
  }
  ignore(show_ref_format)
}

///|
fn resolve_fetch_head_oid(
  fs : &@git.RepoFileSystem,
  git_dir : String,
) -> @git.ObjectId? {
  let fetch_head_path = git_dir + "/FETCH_HEAD"
  guard fs.is_file(fetch_head_path) else { return None }
  let content = decode_bytes(
    fs.read_file(fetch_head_path) catch {
      _ => return None
    },
  )
  let mut result : @git.ObjectId? = None
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
    let oid = @git.ObjectId::from_hex(oid_hex) catch {
      _ => continue
    }
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
  db : @gitlib.ObjectDb,
  fs : &@git.RepoFileSystem,
  object_id : @git.ObjectId,
  expected_type : @git.ObjectType,
) -> Bytes raise @git.GitError {
  let mut current_id = object_id
  for _ in 0..<8 {
    let current_obj = db.get(fs, current_id)
    guard current_obj is Some(current) else {
      raise @git.GitError::InvalidObject(
        "Object not found: " + current_id.to_hex(),
      )
    }
    if current.obj_type == expected_type {
      return current.data
    }
    guard current.obj_type == @git.ObjectType::Tag else {
      raise @git.GitError::InvalidObject(
        "object is of type \{current.obj_type.to_string()}, not \{expected_type.to_string()}",
      )
    }
    let tag_target = parse_tag_object(decode_bytes(current.data)) catch {
      _ => None
    }
    guard tag_target is Some(target_id) else {
      raise @git.GitError::InvalidObject("malformed tag object")
    }
    current_id = target_id
  }
  raise @git.GitError::InvalidObject("tag dereference depth exceeded")
}

///|

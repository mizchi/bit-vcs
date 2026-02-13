///|
async fn handle_cat_file(args : Array[String]) -> Unit raise Error {
  let root = get_work_root()
  let fs = OsFs::new()
  let git_dir = resolve_git_dir(fs, root)
  let mut show_type = false
  let mut show_size = false
  let mut pretty_print = false
  let mut exists_check = false
  let positionals : Array[String] = []
  for arg in args {
    match arg {
      "-t" => show_type = true
      "-s" => show_size = true
      "-p" => pretty_print = true
      "-e" => exists_check = true
      _ if arg.has_prefix("-") => warn_unimplemented_arg("cat-file", arg)
      _ => positionals.push(arg)
    }
  }
  let mut expected_type : @git.ObjectType? = None
  let mut obj_spec : String? = None
  if not(show_type || show_size || pretty_print) && positionals.length() >= 2 {
    expected_type = Some(parse_object_type(positionals[0])) catch { _ => None }
    if expected_type is Some(_) {
      obj_spec = Some(positionals[1])
    }
  }
  if obj_spec is None && positionals.length() > 0 {
    obj_spec = Some(positionals[positionals.length() - 1])
  }
  guard obj_spec is Some(spec) else {
    raise @git.GitError::InvalidObject("object name required")
  }
  let obj_id = @gitrepo.rev_parse(fs, git_dir, spec)
  if exists_check {
    match obj_id {
      Some(oid) => {
        let db = @gitlib.ObjectDb::load(fs, git_dir)
        if db.get(fs, oid) is Some(_) {
          return ()
        }
      }
      None => ()
    }
    @sys.exit(1)
  }
  guard obj_id is Some(oid) else {
    raise @git.GitError::InvalidObject("Not a valid object name: \{spec}")
  }
  let db = @gitlib.ObjectDb::load(fs, git_dir)
  let obj = db.get(fs, oid)
  guard obj is Some(o) else {
    raise @git.GitError::InvalidObject("Object not found: \{spec}")
  }
  if expected_type is Some(expected) {
    let data = peel_cat_file_object_to_type(db, fs, oid, expected)
    @stdio.stdout.write(data)
    return ()
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
          print_line(
            "\{mode_str} \{type_str} \{entry.id.to_hex()}\t\{entry.name}",
          )
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

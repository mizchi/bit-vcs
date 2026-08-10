///|
async fn handle_merge_file(args : Array[String]) -> Unit raise Error {
  let mut stdout_mode = false
  let mut quiet = false
  let mut diff3_style = false
  let mut favor = "none"
  let labels : Array[String] = []
  let mut marker_size = 7
  let mut object_id_mode = false
  let positional : Array[String] = []
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    match arg {
      "-p" | "--stdout" => stdout_mode = true
      "-q" | "--quiet" => quiet = true
      "--diff3" | "--zdiff3" => diff3_style = true
      "--ours" => favor = "ours"
      "--theirs" => favor = "theirs"
      "--union" => favor = "union"
      "--object-id" => object_id_mode = true
      "-L" => {
        i += 1
        if i < args.length() {
          labels.push(args[i])
        } else {
          eprint_line("fatal: -L requires a value")
          @sys.exit(128)
        }
      }
      _ =>
        if arg.has_prefix("--marker-size=") {
          let val = arg[14:].to_owned()
          marker_size = @string.parse_int(val) catch { _ => 7 }
        } else if arg.has_prefix("-L") {
          labels.push(arg[2:].to_owned())
        } else if arg.has_prefix("-") {
          if !quiet {
            eprint_line("fatal: unknown option '\{arg}'")
          }
          @sys.exit(128)
        } else {
          positional.push(arg)
        }
    }
    i += 1
  }
  if positional.length() != 3 {
    eprint_line(
      "usage: git merge-file [<options>] [-L <name> [-L <orig> [-L <other>]]] <current> <base> <other>",
    )
    @sys.exit(128)
  }
  let current_arg = positional[0]
  let base_arg = positional[1]
  let other_arg = positional[2]
  // Determine labels
  let ours_label = if labels.length() > 0 { labels[0] } else { current_arg }
  let base_label = if labels.length() > 1 { labels[1] } else { base_arg }
  let theirs_label = if labels.length() > 2 { labels[2] } else { other_arg }
  // Build options using builder pattern
  let mut options = match favor {
    "ours" => @diff3.ContentMergeOptions::favor_ours()
    "theirs" => @diff3.ContentMergeOptions::favor_theirs()
    "union" => @diff3.ContentMergeOptions::favor_union()
    _ => @diff3.ContentMergeOptions::default()
  }
  options = options.with_labels(
    ours=ours_label,
    base=base_label,
    theirs=theirs_label,
  )
  if diff3_style {
    options = options.with_diff3()
  }
  if marker_size != 7 {
    options = options.with_marker_size(marker_size)
  }
  // Read inputs and perform merge
  let texts = merge_file_read_inputs(
    object_id_mode, current_arg, base_arg, other_arg,
  )
  let result = @diff3.content_merge(texts.1, texts.0, texts.2, options)
  // Output result
  if object_id_mode {
    let fs = OsFs::new()
    let root = get_work_root()
    let git_dir = resolve_git_dir(fs, root)
    let content_bytes = @utf8.encode(result.content)
    let id = @bitlib.write_loose_object(
      fs,
      git_dir,
      @bitcore.ObjectType::Blob,
      content_bytes,
    )
    print_line(id.to_hex())
  } else if stdout_mode {
    @stdio.stdout.write(@utf8.encode(result.content))
  } else {
    @fs.write_string_to_file(current_arg, result.content) catch {
      e => {
        eprint_line(
          "fatal: could not write '\{current_arg}': \{@debug.render(Repr(e))}",
        )
        @sys.exit(128)
      }
    }
  }
  // Exit code: 0 if clean, conflict_count (capped at 127) if conflicts
  if result.has_conflicts {
    let exit_code = if result.conflict_count > 127 {
      127
    } else {
      result.conflict_count
    }
    @sys.exit(exit_code)
  }
}

///|
async fn merge_file_read_inputs(
  object_id_mode : Bool,
  current_arg : String,
  base_arg : String,
  other_arg : String,
) -> (String, String, String) raise Error {
  if object_id_mode {
    let fs = OsFs::new()
    let root = get_work_root()
    let git_dir = resolve_git_dir(fs, root)
    let dbs = merge_file_load_object_dbs(fs, git_dir)
    let current_text = merge_file_read_blob(dbs, fs, current_arg)
    let base_text = merge_file_read_blob(dbs, fs, base_arg)
    let other_text = merge_file_read_blob(dbs, fs, other_arg)
    (current_text, base_text, other_text)
  } else {
    let fs = OsFs::new()
    let current_text = merge_file_read_file(fs, current_arg)
    let base_text = merge_file_read_file(fs, base_arg)
    let other_text = merge_file_read_file(fs, other_arg)
    (current_text, base_text, other_text)
  }
}

///|
fn merge_file_read_file(fs : OsFs, path : String) -> String raise Error {
  let data = fs.read_file(path)
  decode_bytes(data)
}

///|
fn merge_file_load_object_dbs(
  fs : OsFs,
  git_dir : String,
) -> Array[@bitlib.ObjectDb] {
  let out : Array[@bitlib.ObjectDb] = []
  let objects_dir = git_dir + "/objects"
  let db = @bitlib.ObjectDb::load_lazy_from_objects_dir(fs, objects_dir) catch {
    _ => return out
  }
  db.set_skip_verify(true)
  out.push(db)
  out
}

///|
fn merge_file_read_blob(
  dbs : Array[@bitlib.ObjectDb],
  fs : OsFs,
  oid_str : String,
) -> String raise Error {
  let id = @bitcore.ObjectId::from_hex(oid_str)
  for db in dbs {
    let obj = db.get(fs, id)
    if obj is Some(o) {
      return decode_bytes(o.data)
    }
  }
  raise @bitcore.GitError::InvalidObject(
    "fatal: could not read object '\{oid_str}'",
  )
}

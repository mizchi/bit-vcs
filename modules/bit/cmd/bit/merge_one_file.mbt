///| git merge-one-file - standard helper for merge-index

///|
async fn handle_merge_one_file(args : Array[String]) -> Unit raise Error {
  // Usage: git merge-one-file <base-hash> <base-mode> <our-hash> <our-mode> <their-hash> <their-mode> <path>
  if args.length() > 0 && (args[0] == "-h" || args[0] == "--help") {
    show_simple_command_help(
      "git merge-one-file <base-hash> <base-mode> <our-hash> <our-mode> <their-hash> <their-mode> <path>",
      summary="Standard merge helper for merge-index. Performs 3-way merge.",
    )
    return
  }
  if args.length() < 7 {
    eprint_line(
      "usage: git merge-one-file <base-hash> <base-mode> <our-hash> <our-mode> <their-hash> <their-mode> <path>",
    )
    @sys.exit(1)
    return
  }
  let base_hash = args[0]
  let _base_mode = args[1]
  let our_hash = args[2]
  let _our_mode = args[3]
  let their_hash = args[4]
  let _their_mode = args[5]
  let path = args[6]
  let root = get_work_root()
  let fs = OsFs::new()
  let git_dir = resolve_git_dir(fs, root)
  // Handle deletion cases
  if our_hash.length() == 0 && their_hash.length() == 0 {
    // Both sides deleted
    let full_path = root + "/" + path
    @fs.remove_file(full_path) catch {
      _ => ()
    }
    return
  }
  if our_hash.length() == 0 {
    eprint_line("CONFLICT (modify/delete): \{path}")
    @sys.exit(1)
    return
  }
  if their_hash.length() == 0 {
    eprint_line("CONFLICT (modify/delete): \{path}")
    @sys.exit(1)
    return
  }
  // Load object dbs
  let dbs = merge_one_file_load_dbs(fs, git_dir)
  // Read blob contents
  let base_text = if base_hash.length() > 0 {
    merge_one_file_read_blob(dbs, fs, base_hash)
  } else {
    ""
  }
  let our_text = merge_one_file_read_blob(dbs, fs, our_hash)
  let their_text = merge_one_file_read_blob(dbs, fs, their_hash)
  // Perform 3-way merge
  let opts = @diff3.ContentMergeOptions::default().with_labels(
    ours="ours",
    base="base",
    theirs="theirs",
  )
  let result = @diff3.content_merge(base_text, our_text, their_text, opts)
  // Write result to working tree
  let full_path = root + "/" + path
  let parent = parent_dir(full_path)
  if parent.length() > 0 {
    ensure_dir(parent)
  }
  let content_bytes = @utf8.encode(result.content)
  @fs.write_bytes_to_file(full_path, content_bytes) catch {
    err => {
      eprint_line(
        "error: cannot write \{full_path}: \{@debug.render(Repr(err))}",
      )
      @sys.exit(1)
      return
    }
  }
  if result.has_conflicts {
    eprint_line("CONFLICT (content): Merge conflict in \{path}")
    @sys.exit(1)
  }
}

///|
fn merge_one_file_load_dbs(
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
fn merge_one_file_read_blob(
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

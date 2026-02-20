///|
async fn handle_mktree(args : Array[String]) -> Unit raise Error {
  let fs = OsFs::new()
  let git_dir = find_git_dir(fs)
  let mut batch = false
  let mut nul_term = false
  for arg in args {
    match arg {
      "--batch" => batch = true
      "-z" => nul_term = true
      "--missing" => ()
      _ if arg.has_prefix("-") => warn_unimplemented_arg("mktree", arg)
      _ => ()
    }
  }
  // Read ls-tree format input from stdin
  let input = decode_bytes(read_all_stdin())
  let sep = if nul_term { "\u0000" } else { "\n" }
  if batch {
    // Batch mode: empty line separates trees
    let current_entries : Array[@bitcore.TreeEntry] = []
    for line_view in input.split(sep) {
      let line = trim_string(line_view.to_string())
      if line.length() == 0 {
        // Output tree for current entries
        if current_entries.length() > 0 {
          let tree_id = write_mktree_entries(fs, git_dir, current_entries)
          print_line(tree_id.to_hex())
          current_entries.clear()
        }
        continue
      }
      parse_and_add_tree_entry(line, current_entries)
    }
    // Output final tree if any entries remain
    if current_entries.length() > 0 {
      let tree_id = write_mktree_entries(fs, git_dir, current_entries)
      print_line(tree_id.to_hex())
    }
  } else {
    // Single tree mode
    let entries : Array[@bitcore.TreeEntry] = []
    for line_view in input.split(sep) {
      let line = trim_string(line_view.to_string())
      if line.length() == 0 {
        continue
      }
      parse_and_add_tree_entry(line, entries)
    }
    let tree_id = write_mktree_entries(fs, git_dir, entries)
    print_line(tree_id.to_hex())
  }
}

///|
fn parse_and_add_tree_entry(
  line : String,
  entries : Array[@bitcore.TreeEntry],
) -> Unit {
  // Format: <mode> SP <type> SP <object> TAB <file>
  // Or: <mode> SP <object> TAB <file> (simplified)
  match line.find("\t") {
    None => return ()
    Some(tab_idx) => {
      let meta = String::unsafe_substring(line, start=0, end=tab_idx)
      let name = String::unsafe_substring(
        line,
        start=tab_idx + 1,
        end=line.length(),
      )
      let parts : Array[String] = []
      for part_view in meta.split(" ") {
        let p = part_view.to_string()
        if p.length() > 0 {
          parts.push(p)
        }
      }
      if parts.length() >= 2 {
        let mode = parts[0]
        // Object ID is either parts[1] or parts[2] depending on format
        let object_hex = if parts.length() >= 3 { parts[2] } else { parts[1] }
        let id = @bitcore.ObjectId::from_hex(object_hex) catch {
          _ => return ()
        }
        entries.push(@bitcore.TreeEntry::new(mode, name, id))
      }
    }
  }
}

///|
fn write_mktree_entries(
  fs : OsFs,
  git_dir : String,
  entries : Array[@bitcore.TreeEntry],
) -> @bitcore.ObjectId raise Error {
  // Sort entries by Git's tree sorting rules
  let sorted = entries.copy()
  sorted.sort_by(fn(a, b) {
    let a_key = if a.mode == "40000" { a.name + "/" } else { a.name }
    let b_key = if b.mode == "40000" { b.name + "/" } else { b.name }
    String::compare(a_key, b_key)
  })
  let (tree_id, compressed) = @bitcore.create_tree(sorted)
  @bitlib.write_object_bytes(fs, git_dir, tree_id, compressed)
  tree_id
}

///|

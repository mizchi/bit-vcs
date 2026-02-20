///|
async fn handle_stash(args : Array[String]) -> Unit raise Error {
  let root = get_work_root()
  let git_dir = root + "/.git"
  let fs = OsFs::new()
  // Determine subcommand (default: push if args are empty or start with -)
  let subcmd = if args.length() == 0 {
    "push"
  } else {
    let first = args[0]
    if first.has_prefix("-") {
      "push"
    } else {
      first
    }
  }
  let rest : Array[String] = if args.length() > 0 &&
    not(args[0].has_prefix("-")) {
    args.iter().drop(1).collect()
  } else {
    args.iter().collect()
  }
  match subcmd {
    "push" | "save" => {
      // Parse message option
      let mut message = ""
      let mut i = 0
      while i < rest.length() {
        let arg = rest[i]
        match arg {
          "-m" | "--message" if i + 1 < rest.length() => {
            message = rest[i + 1]
            i += 2
            continue
          }
          _ => ()
        }
        i += 1
      }
      let author = get_author_string()
      let timestamp = get_commit_timestamp()
      let result = @bitlib.stash_push(fs, fs, root, message, author, timestamp)
      match result {
        Some(id) => {
          let short = String::unsafe_substring(id.to_hex(), start=0, end=7)
          print_line("Saved working directory and index state [\{short}]")
        }
        None => print_line("No local changes to save")
      }
    }
    "list" => {
      let entries = @bitlib.stash_list(fs, git_dir)
      for i, entry in entries {
        let short = String::unsafe_substring(entry.id.to_hex(), start=0, end=7)
        print_line("stash@{" + i.to_string() + "}: \{entry.message} [\{short}]")
      }
    }
    "pop" => {
      let index = parse_stash_index(rest)
      @bitlib.stash_apply(fs, fs, root, index, true)
      print_line("Dropped stash@{" + index.to_string() + "}")
    }
    "apply" => {
      let index = parse_stash_index(rest)
      @bitlib.stash_apply(fs, fs, root, index, false)
      print_line("Applied stash@{" + index.to_string() + "}")
    }
    "drop" => {
      let index = parse_stash_index(rest)
      @bitlib.stash_drop(fs, fs, root, index)
      print_line("Dropped stash@{" + index.to_string() + "}")
    }
    "clear" => {
      // Remove all stash entries
      let stash_ref = git_dir + "/refs/stash"
      let reflog_path = git_dir + "/logs/refs/stash"
      if fs.is_file(stash_ref) {
        fs.remove_file(stash_ref)
      }
      if fs.is_file(reflog_path) {
        fs.remove_file(reflog_path)
      }
      print_line("Cleared all stash entries")
    }
    _ =>
      raise @bitcore.GitError::InvalidObject(
        "Unknown stash subcommand: \{subcmd}",
      )
  }
}

///|
fn parse_stash_index(args : Array[String]) -> Int {
  for arg in args {
    // Parse stash@{N} or just a number
    if arg.has_prefix("stash@{") && arg.has_suffix("}") {
      let num_str = String::unsafe_substring(arg, start=7, end=arg.length() - 1)
      let n = @strconv.parse_int(num_str) catch { _ => continue }
      return n
    }
    let n = @strconv.parse_int(arg) catch { _ => continue }
    return n
  }
  0 // Default to first stash entry
}

///|

///|
/// Show branches and their commits (git show-branch)

///|
async fn handle_update_index(args : Array[String]) -> Unit raise Error {
  let fs = OsFs::new()
  let root = get_work_root()
  let git_dir = resolve_git_dir(fs, root)
  let mut add = false
  let mut remove = false
  let mut force_remove = false
  let mut refresh = false
  let mut quiet = false
  let mut ignore_missing = false
  let mut stdin = false
  let mut nul_term = false
  let mut verbose = false
  let mut skip_worktree_mode : Bool? = None
  let cacheinfo : Array[(String, String, String)] = []
  let mut index_info = false
  let paths : Array[String] = []
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    match arg {
      "--add" => add = true
      "--remove" => remove = true
      "--force-remove" => force_remove = true
      "--replace" => ()
      "--refresh" => refresh = true
      "--really-refresh" => refresh = true
      "-q" => quiet = true
      "--ignore-missing" => ignore_missing = true
      "--skip-worktree" => skip_worktree_mode = Some(true)
      "--no-skip-worktree" => skip_worktree_mode = Some(false)
      "--stdin" => stdin = true
      "--index-info" => index_info = true
      "-z" => nul_term = true
      "-v" | "--verbose" => verbose = true
      "--cacheinfo" if i + 3 < args.length() => {
        cacheinfo.push((args[i + 1], args[i + 2], args[i + 3]))
        i += 4
        continue
      }
      _ if arg.has_prefix("--cacheinfo=") => {
        let val = arg[12:].to_string()
        match val.find(",") {
          Some(idx1) => {
            let mode = val[:idx1].to_string()
            let rest = val[idx1 + 1:].to_string()
            match rest.find(",") {
              Some(idx2) => {
                let sha = rest[:idx2].to_string()
                let path = rest[idx2 + 1:].to_string()
                cacheinfo.push((mode, sha, path))
              }
              None => ()
            }
          }
          None => ()
        }
      }
      "--" => {
        for j in (i + 1)..<args.length() {
          paths.push(args[j])
        }
        break
      }
      _ if not(arg.has_prefix("-")) => paths.push(arg)
      _ if arg.has_prefix("-") => warn_unimplemented_arg("update-index", arg)
      _ => ()
    }
    i += 1
  }
  let direct_updates : Array[@bitlib.IndexEntry] = []
  let direct_remove_paths : Array[String] = []
  // Read from stdin if requested
  if stdin {
    let input = decode_bytes(read_all_stdin())
    let sep = if nul_term { "\u0000" } else { "\n" }
    for part_view in input.split(sep) {
      let part = trim_string(part_view.to_string())
      if part.length() == 0 {
        continue
      }
      if index_info {
        match parse_update_index_info_line(part) {
          Some((mode, id, path)) => {
            let normalized_path = normalize_update_index_path(path)
            if mode == 0 {
              direct_remove_paths.push(normalized_path)
            } else {
              direct_updates.push(
                @bitlib.IndexEntry::new(normalized_path, id, mode, 0),
              )
            }
          }
          None => {
            eprint_line("error: bad index-info line: " + part)
            raise @bitcore.GitError::InvalidObject("bad index-info line")
          }
        }
      } else {
        paths.push(part)
      }
    }
  }
  // Handle --cacheinfo (index entries provided directly from command arguments)
  for info in cacheinfo {
    let (mode_str, sha, path) = info
    match parse_update_index_cacheinfo(mode_str, sha, path) {
      Some((mode, id, normalized_path)) => {
        if verbose {
          if mode == 0 {
            print_line("remove '" + normalized_path + "'")
          } else {
            print_line("add '" + normalized_path + "'")
          }
        }
        if mode == 0 {
          direct_remove_paths.push(normalized_path)
        } else {
          direct_updates.push(
            @bitlib.IndexEntry::new(normalized_path, id, mode, 0),
          )
        }
      }
      None => {
        eprint_line(
          "error: bad cacheinfo: " + mode_str + " " + sha + " " + path,
        )
        raise @bitcore.GitError::InvalidObject("bad cacheinfo")
      }
    }
  }
  if direct_updates.length() > 0 || direct_remove_paths.length() > 0 {
    apply_update_index_entries(fs, git_dir, direct_updates, direct_remove_paths)
  }
  // Use the existing add functionality
  if paths.length() > 0 {
    if add || force_remove || remove || refresh {
      // For now, delegate to the git add/rm logic
      let add_paths : Array[String] = []
      let remove_paths : Array[String] = []
      for path in paths {
        let normalized_path = normalize_update_index_path(path)
        let full_path = if normalized_path.has_prefix("/") {
          normalized_path
        } else {
          root + "/" + normalized_path
        }
        if force_remove || (remove && not(fs.is_file(full_path))) {
          remove_paths.push(normalized_path)
        } else if fs.is_file(full_path) {
          add_paths.push(normalized_path)
        } else if not(ignore_missing) && not(quiet) {
          eprint_line("error: " + normalized_path + ": does not exist")
        }
      }
      // Use gitlib functions
      if add_paths.length() > 0 {
        // Ensure replacing existing entries is idempotent for the same path.
        let existing_entries = @bitlib.read_index_entries(fs, git_dir)
        let add_set : Map[String, Bool] = {}
        for p in add_paths {
          add_set[normalize_update_index_path(p)] = true
        }
        let filtered_entries : Array[@bitlib.IndexEntry] = []
        for e in existing_entries {
          if not(add_set.contains(normalize_update_index_path(e.path))) {
            filtered_entries.push(e)
          }
        }
        @bitlib.write_index_entries(fs, git_dir, filtered_entries)
        @bitlib.add_paths_async(fs, fs, root, add_paths)
        let normalized_entries = dedupe_index_entries_by_path(
          @bitlib.read_index_entries(fs, git_dir),
        )
        @bitlib.write_index_entries(fs, git_dir, normalized_entries)
      }
      // For removals, filter out from index
      if remove_paths.length() > 0 {
        let entries = @bitlib.read_index_entries(fs, git_dir)
        let remove_set : Map[String, Bool] = {}
        for p in remove_paths {
          remove_set[normalize_update_index_path(p)] = true
        }
        let filtered : Array[@bitlib.IndexEntry] = []
        for e in entries {
          if not(remove_set.contains(normalize_update_index_path(e.path))) {
            filtered.push(e)
          }
        }
        @bitlib.write_index_entries(fs, git_dir, filtered)
      }
    }
  }
  // Handle --refresh
  if refresh && paths.length() == 0 {
    // Refresh all entries - recompute hashes
    let entries = @bitlib.read_index_entries(fs, git_dir)
    let refreshed : Array[@bitlib.IndexEntry] = []
    for e in entries {
      // Keep existing entries (could recompute hash if needed)
      refreshed.push(e)
    }
    @bitlib.write_index_entries(fs, git_dir, refreshed)
  }
  match skip_worktree_mode {
    Some(enabled) => {
      let normalized : Array[String] = []
      for p in paths {
        let clean = normalize_update_index_path(p)
        if clean.length() > 0 {
          normalized.push(clean)
        }
      }
      if normalized.length() > 0 {
        update_skip_worktree_state(fs, git_dir, normalized, enabled)
      }
    }
    None => ()
  }
}

///|
fn parse_update_index_info_line(
  line : String,
) -> (Int, @bitcore.ObjectId, String)? {
  match line.find("\t") {
    None => None
    Some(tab_idx) => {
      let info = String::unsafe_substring(line, start=0, end=tab_idx)
      let path = String::unsafe_substring(
        line,
        start=tab_idx + 1,
        end=line.length(),
      )
      let normalized_path = normalize_update_index_path(path) catch {
        _ => return None
      }
      let fields = split_update_index_fields(info)
      if fields.length() == 0 {
        return None
      }
      match parse_octal_mode(fields[0]) {
        None => None
        Some(mode) =>
          if mode == 0 {
            if fields.length() < 2 {
              return None
            }
            Some((0, @bitcore.ObjectId::zero(), normalized_path))
          } else {
            match fields.length() {
              2 => {
                let id = match parse_update_index_object_id(fields[1]) {
                  None => return None
                  Some(value) => value
                }
                Some((mode, id, normalized_path))
              }
              3 =>
                if is_update_index_object_type(fields[1]) {
                  let id = match parse_update_index_object_id(fields[2]) {
                    None => return None
                    Some(value) => value
                  }
                  Some((mode, id, normalized_path))
                } else {
                  match parse_update_index_stage(fields[2]) {
                    None => None
                    Some(_) => {
                      let id = match parse_update_index_object_id(fields[1]) {
                        None => return None
                        Some(value) => value
                      }
                      Some((mode, id, normalized_path))
                    }
                  }
                }
              4 =>
                if not(is_update_index_object_type(fields[1])) {
                  None
                } else {
                  match parse_update_index_stage(fields[3]) {
                    None => None
                    Some(_) => {
                      let id = match parse_update_index_object_id(fields[2]) {
                        None => return None
                        Some(value) => value
                      }
                      Some((mode, id, normalized_path))
                    }
                  }
                }
              _ => None
            }
          }
      }
    }
  }
}

///|
fn parse_update_index_cacheinfo(
  mode_str : String,
  sha : String,
  path : String,
) -> (Int, @bitcore.ObjectId, String)? {
  match parse_octal_mode(mode_str) {
    None => None
    Some(mode) => {
      let normalized_path = normalize_update_index_path(path) catch {
        _ => return None
      }
      if mode == 0 {
        None
      } else {
        let id = @bitcore.ObjectId::from_hex(sha) catch { _ => return None }
        if id == @bitcore.ObjectId::zero() {
          None
        } else {
          Some((mode, id, normalized_path))
        }
      }
    }
  }
}

///|
fn parse_update_index_stage(value : String) -> Int? {
  let parsed = @strconv.parse_int(value) catch { _ => return None }
  if parsed >= 0 && parsed <= 3 {
    Some(parsed)
  } else {
    None
  }
}

///|
fn parse_update_index_object_id(hex : String) -> @bitcore.ObjectId? {
  let id = @bitcore.ObjectId::from_hex(hex) catch { _ => return None }
  if id == @bitcore.ObjectId::zero() {
    None
  } else {
    Some(id)
  }
}

///|
fn is_update_index_object_type(value : String) -> Bool {
  value == "blob" || value == "tree" || value == "commit" || value == "tag"
}

///|
fn parse_octal_mode(s : String) -> Int? {
  let mut mode = 0
  if s.length() == 0 {
    return None
  }
  for c in s {
    if c < '0' || c > '7' {
      return None
    }
    mode = mode * 8 + (c.to_int() - '0'.to_int())
  }
  Some(mode)
}

///|
fn split_update_index_fields(s : String) -> Array[String] {
  let out : Array[String] = []
  for item in s.split(" ") {
    let part = trim_string(item.to_string())
    if part.length() > 0 {
      out.push(part)
    }
  }
  out
}

///|
fn apply_update_index_entries(
  fs : OsFs,
  git_dir : String,
  updates : Array[@bitlib.IndexEntry],
  removals : Array[String],
) -> Unit raise Error {
  let existing = @bitlib.read_index_entries(fs, git_dir)
  let update_map : Map[String, @bitlib.IndexEntry] = {}
  for entry in updates {
    update_map[normalize_update_index_path(entry.path)] = entry
  }
  let removal_set : Map[String, Bool] = {}
  for p in removals {
    removal_set[normalize_update_index_path(p)] = true
  }
  let out : Array[@bitlib.IndexEntry] = []
  for entry in existing {
    let path = normalize_update_index_path(entry.path)
    if removal_set.contains(path) {
      continue
    }
    match update_map.get(path) {
      Some(next) => {
        out.push(next)
        update_map.remove(path)
      }
      None => out.push(entry)
    }
  }
  for item in update_map.to_array() {
    let (_, entry) = item
    out.push(entry)
  }
  @bitlib.write_index_entries(fs, git_dir, dedupe_index_entries_by_path(out))
}

///|
fn dedupe_index_entries_by_path(
  entries : Array[@bitlib.IndexEntry],
) -> Array[@bitlib.IndexEntry] raise @bitcore.GitError {
  let by_path : Map[String, @bitlib.IndexEntry] = {}
  for entry in entries {
    by_path[normalize_update_index_path(entry.path)] = entry
  }
  let sorted : Array[(String, @bitlib.IndexEntry)] = by_path.to_array()
  sorted.sort_by((a, b) => String::compare(a.0, b.0))
  let out : Array[@bitlib.IndexEntry] = []
  for item in sorted {
    let (_, entry) = item
    out.push(entry)
  }
  out
}

///|
fn normalize_update_index_path(path : String) -> String raise @bitcore.GitError {
  if path.has_prefix("/") {
    raise @bitcore.GitError::InvalidObject("path must be relative")
  }
  @bitlib.normalize_repo_path(path)
}

///|
fn update_skip_worktree_state(
  fs : OsFs,
  git_dir : String,
  paths : Array[String],
  enabled : Bool,
) -> Unit raise Error {
  let state_path = git_dir + "/bit-skip-worktree"
  let state : Map[String, Bool] = {}
  if fs.is_file(state_path) {
    let text = decode_bytes(fs.read_file(state_path))
    for line_view in text.split("\n") {
      let line = trim_string(line_view.to_string())
      if line.length() > 0 {
        state[line] = true
      }
    }
  }
  for p in paths {
    if enabled {
      state[p] = true
    } else {
      state.remove(p)
    }
  }
  let out : Array[String] = []
  for item in state.to_array() {
    let (path, marked) = item
    if marked {
      out.push(path)
    }
  }
  out.sort_by((a, b) => String::compare(a, b))
  if out.length() == 0 {
    fs.remove_file(state_path) catch {
      _ => ()
    }
  } else {
    fs.write_string(state_path, out.join("\n") + "\n")
  }
}

///|

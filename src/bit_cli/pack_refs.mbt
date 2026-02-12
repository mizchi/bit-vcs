///|
fn handle_pack_refs(args : Array[String]) -> Unit raise Error {
  let fs = OsFs::new()
  let git_dir = find_git_dir(fs)
  let mut all = false
  let mut prune = true
  for arg in args {
    match arg {
      "--all" => all = true
      "--no-prune" => prune = false
      "--prune" => prune = true
      _ => ()
    }
  }
  let refs_dir = git_dir + "/refs"
  let packed_refs_path = git_dir + "/packed-refs"
  // Read existing packed-refs
  let packed : Map[String, String] = {}
  if fs.is_file(packed_refs_path) {
    let content = decode_bytes(fs.read_file(packed_refs_path))
    for line_view in content.split("\n") {
      let line = line_view.to_string()
      if line.length() > 0 &&
        not(line.has_prefix("#")) &&
        not(line.has_prefix("^")) {
        let parts : Array[String] = line
          .split(" ")
          .map(v => v.to_string())
          .collect()
        if parts.length() >= 2 {
          let sha = parts[0]
          let ref_name = parts[1]
          packed[ref_name] = sha
        }
      }
    }
  }
  // Collect refs to pack
  let refs_to_pack : Array[(String, String)] = []
  collect_refs_to_pack(fs, refs_dir, "refs", refs_to_pack, all)
  // Update packed-refs
  for r in refs_to_pack {
    packed[r.0] = r.1
  }
  // Write packed-refs
  let lines : Array[String] = ["# pack-refs with: peeled fully-peeled sorted"]
  let sorted_refs : Array[(String, String)] = packed.iter().collect()
  sorted_refs.sort_by((a, b) => a.0.compare(b.0))
  for entry in sorted_refs {
    lines.push("\{entry.1} \{entry.0}")
  }
  fs.write_string(packed_refs_path, lines.join("\n") + "\n")
  // Prune loose refs if requested
  if prune {
    for r in refs_to_pack {
      let ref_path = git_dir + "/" + r.0
      if fs.is_file(ref_path) {
        fs.remove_file(ref_path)
        cleanup_empty_dirs(fs, git_dir, r.0)
      }
    }
  }
}

///|
fn collect_refs_to_pack(
  fs : OsFs,
  dir : String,
  prefix : String,
  refs : Array[(String, String)],
  all : Bool,
) -> Unit raise Error {
  if not(fs.is_dir(dir)) {
    return
  }
  let entries = fs.readdir(dir)
  for entry in entries {
    let path = dir + "/" + entry
    let ref_name = prefix + "/" + entry
    if fs.is_file(path) {
      if all || ref_name.has_prefix("refs/tags/") {
        let sha = (fs.read_file(path) |> decode_bytes |> trim_string) catch {
          _ => ""
        }
        if sha.length() == 40 {
          refs.push((ref_name, sha))
        }
      }
    } else if fs.is_dir(path) {
      collect_refs_to_pack(fs, path, ref_name, refs, all)
    }
  }
}

///|
fn cleanup_empty_dirs(
  fs : OsFs,
  git_dir : String,
  ref_path : String,
) -> Unit raise Error {
  let parts : Array[String] = ref_path
    .split("/")
    .map(v => v.to_string())
    .collect()
  let mut current = git_dir
  let dirs : Array[String] = []
  for i in 0..<(parts.length() - 1) {
    current = current + "/" + parts[i]
    dirs.push(current)
  }
  let mut i = dirs.length() - 1
  while i >= 0 {
    let dir = dirs[i]
    let entries = fs.readdir(dir)
    if entries.length() == 0 {
      let _ = fs.remove_dir(dir) catch { _ => () }
    } else {
      break
    }
    i -= 1
  }
}

///|

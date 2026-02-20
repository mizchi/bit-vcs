///|
async fn handle_describe(args : Array[String]) -> Unit raise Error {
  let root = get_work_root()
  let git_dir = root + "/.git"
  let fs = OsFs::new()
  let rfs : &@bitcore.RepoFileSystem = fs
  // Parse options
  let mut use_tags = false // --tags: use lightweight tags too
  let mut always = false // --always: show abbreviated commit if no tag
  let mut long_format = false // --long: always use long format
  let mut abbrev = 7 // --abbrev=N: abbreviation length
  let mut commit_ref = "HEAD"
  let mut dirty_mark = ""
  for arg in args {
    match arg {
      "--tags" => use_tags = true
      "--always" => always = true
      "--long" => long_format = true
      "--dirty" => dirty_mark = "-dirty"
      _ if arg.has_prefix("--abbrev=") =>
        abbrev = parse_int(
          String::unsafe_substring(arg, start=9, end=arg.length()),
        )
      _ if arg.has_prefix("--dirty=") =>
        dirty_mark = String::unsafe_substring(arg, start=8, end=arg.length())
      _ if not(arg.has_prefix("-")) => commit_ref = arg
      _ => ()
    }
  }
  // Resolve target commit
  let target_id = @bitrepo.rev_parse(rfs, git_dir, commit_ref)
  guard target_id is Some(tid) else {
    raise @bitcore.GitError::InvalidObject("unknown revision: \{commit_ref}")
  }
  // Get all tags
  let tags = get_all_tags(rfs, git_dir, use_tags)
  if tags.length() == 0 && not(always) {
    @stdio.stderr.write("fatal: No names found, cannot describe anything.")
    @sys.exit(128)
  }
  // Find closest tag using BFS
  let result = find_closest_tag(rfs, git_dir, tid, tags)
  match result {
    Some((tag_name, distance, tag_commit)) => {
      let output = if distance == 0 && not(long_format) {
        tag_name + dirty_mark
      } else {
        let short_sha = String::unsafe_substring(
          tid.to_hex(),
          start=0,
          end=abbrev,
        )
        "\{tag_name}-\{distance}-g\{short_sha}\{dirty_mark}"
      }
      ignore(tag_commit)
      print_line(output)
    }
    None =>
      if always {
        let short_sha = String::unsafe_substring(
          tid.to_hex(),
          start=0,
          end=abbrev,
        )
        print_line(short_sha + dirty_mark)
      } else {
        @stdio.stderr.write(
          "fatal: No tags can describe '\{tid.to_hex()}'.\nTry --always, or create a tag.",
        )
        @sys.exit(128)
      }
  }
}

///|
fn get_all_tags(
  rfs : &@bitcore.RepoFileSystem,
  git_dir : String,
  include_lightweight : Bool,
) -> Map[String, @bitcore.ObjectId] raise Error {
  let tags : Map[String, @bitcore.ObjectId] = {}
  let tags_dir = git_dir + "/refs/tags"
  if not(rfs.is_dir(tags_dir)) {
    return tags
  }
  let entries = rfs.readdir(tags_dir) catch { _ => return tags }
  let db = @bitlib.ObjectDb::load(rfs, git_dir)
  for entry in entries {
    let tag_path = tags_dir + "/" + entry
    if rfs.is_file(tag_path) {
      let ref_hex = rfs.read_file(tag_path) |> decode_bytes |> trim_string
      let ref_id = @bitcore.ObjectId::from_hex(ref_hex)
      // Check if it's an annotated tag (tag object) or lightweight (commit)
      let obj = db.get(rfs, ref_id)
      match obj {
        Some(o) =>
          if o.obj_type == @bitcore.ObjectType::Tag {
            // Annotated tag - dereference to commit
            let tag_data = decode_bytes(o.data)
            let commit_id = parse_tag_object(tag_data)
            match commit_id {
              Some(cid) => tags[entry] = cid
              None => ()
            }
          } else if o.obj_type == @bitcore.ObjectType::Commit &&
            include_lightweight {
            // Lightweight tag
            tags[entry] = ref_id
          }
        None => ()
      }
    }
  }
  tags
}

///|
fn parse_tag_object(data : String) -> @bitcore.ObjectId? raise Error {
  // Tag object format:
  // object <sha>
  // type commit
  // tag <name>
  // ...
  for line_view in data.split("\n") {
    let line = line_view.to_string()
    if line.has_prefix("object ") {
      let hex = String::unsafe_substring(line, start=7, end=line.length())
      return hex |> trim_string |> @bitcore.ObjectId::from_hex |> Some
    }
  }
  None
}

///|
fn find_closest_tag(
  rfs : &@bitcore.RepoFileSystem,
  git_dir : String,
  target : @bitcore.ObjectId,
  tags : Map[String, @bitcore.ObjectId],
) -> (String, Int, @bitcore.ObjectId)? raise Error {
  // BFS from target to find closest tag
  // Queue entries: (commit_id, distance)
  let db = @bitlib.ObjectDb::load(rfs, git_dir)
  let visited : Map[String, Bool] = {}
  let queue : Array[(@bitcore.ObjectId, Int)] = [(target, 0)]
  while queue.length() > 0 {
    // Dequeue from front (FIFO for BFS)
    let (current, distance) = queue[0]
    let new_queue : Array[(@bitcore.ObjectId, Int)] = []
    for i in 1..<queue.length() {
      new_queue.push(queue[i])
    }
    // Clear and refill queue
    while queue.length() > 0 {
      ignore(queue.pop())
    }
    for item in new_queue {
      queue.push(item)
    }
    let hex = current.to_hex()
    if visited.get(hex).unwrap_or(false) {
      continue
    }
    visited[hex] = true
    // Check if this commit has a tag
    for tag_name, tag_commit in tags {
      if tag_commit.to_hex() == hex {
        return Some((tag_name, distance, tag_commit))
      }
    }
    // Add parents to queue
    let obj = db.get(rfs, current)
    match obj {
      Some(o) => {
        let info = @bitcore.parse_commit(o.data)
        for p in info.parents {
          if not(visited.get(p.to_hex()).unwrap_or(false)) {
            queue.push((p, distance + 1))
          }
        }
      }
      None => ()
    }
  }
  None
}

///|
fn parse_int(s : String) -> Int {
  let mut result = 0
  for c in s {
    if c >= '0' && c <= '9' {
      result = result * 10 + (c.to_int() - '0'.to_int())
    }
  }
  result
}

///|
/// Handle git format-patch command

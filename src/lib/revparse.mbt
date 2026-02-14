///| Ref resolution helpers (rev-parse/show-ref)

///|
pub fn rev_parse(
  fs : &@git.RepoFileSystem,
  git_dir : String,
  spec : String,
) -> @git.ObjectId? raise @git.GitError {
  if spec.has_prefix(":/") && spec.length() > 2 {
    let needle = substring_revparse(spec, 2, spec.length())
    return resolve_commit_message_search(fs, git_dir, "HEAD", needle)
  }
  match parse_commit_message_search_spec(spec) {
    Some((base_spec, needle)) =>
      return resolve_commit_message_search(fs, git_dir, base_spec, needle)
    None => ()
  }
  match spec.find(":") {
    Some(idx) =>
      if idx > 0 && idx + 1 < spec.length() {
        let rev_part = substring_revparse(spec, 0, idx)
        let path_part = substring_revparse(spec, idx + 1, spec.length())
        let base = rev_parse(fs, git_dir, rev_part)
        guard base is Some(base_id) else { return None }
        return resolve_path_in_commit(fs, git_dir, base_id, path_part)
      }
    None => ()
  }
  match parse_peel_commit_spec(spec) {
    Some(base_spec) => {
      let base = rev_parse(fs, git_dir, base_spec)
      guard base is Some(base_id) else { return None }
      return peel_object_to_commit(fs, git_dir, base_id)
    }
    None => ()
  }
  match parse_peel_tree_spec(spec) {
    Some(base_spec) => {
      let base = rev_parse(fs, git_dir, base_spec)
      guard base is Some(base_id) else { return None }
      return peel_object_to_tree(fs, git_dir, base_id)
    }
    None => ()
  }
  // Parse suffix (^, ^^, ~n, ^n)
  let (base_spec, ancestor_count) = parse_rev_suffix(spec)
  // Resolve base reference
  let base_id = match resolve_base_ref(fs, git_dir, base_spec) {
    Some(id) => id
    None => return None
  }
  // Walk up parent chain
  if ancestor_count == 0 {
    return Some(base_id)
  }
  walk_ancestors(fs, git_dir, base_id, ancestor_count)
}

///|
fn parse_commit_message_search_spec(spec : String) -> (String, String)? {
  let marker = "^{/"
  match spec.find(marker) {
    Some(idx) if idx > 0 &&
      spec.has_suffix("}") &&
      idx + marker.length() < spec.length() - 1 =>
      Some(
        (
          substring_revparse(spec, 0, idx),
          substring_revparse(spec, idx + marker.length(), spec.length() - 1),
        ),
      )
    _ => None
  }
}

///|
fn resolve_commit_message_search(
  fs : &@git.RepoFileSystem,
  git_dir : String,
  base_spec : String,
  needle : String,
) -> @git.ObjectId? raise @git.GitError {
  if needle.length() == 0 {
    return None
  }
  let base = rev_parse(fs, git_dir, base_spec)
  guard base is Some(base_id) else { return None }
  find_reachable_commit_by_message(fs, git_dir, base_id, needle)
}

///|
fn find_reachable_commit_by_message(
  fs : &@git.RepoFileSystem,
  git_dir : String,
  start : @git.ObjectId,
  needle : String,
) -> @git.ObjectId? raise @git.GitError {
  let db = ObjectDb::load(fs, git_dir)
  let queue : Array[@git.ObjectId] = [start]
  let seen : Map[String, Bool] = {}
  while queue.length() > 0 {
    let current = queue.unsafe_pop()
    let hex = current.to_hex()
    if seen.contains(hex) {
      continue
    }
    seen[hex] = true
    match db.get(fs, current) {
      Some(obj) =>
        if obj.obj_type == @git.ObjectType::Commit {
          if commit_message_contains(obj.data, needle) {
            return Some(current)
          }
          let info = @git.parse_commit(obj.data)
          for parent in info.parents {
            if not(seen.contains(parent.to_hex())) {
              queue.push(parent)
            }
          }
        }
      None => ()
    }
  }
  None
}

///|
fn commit_message_contains(data : Bytes, needle : String) -> Bool {
  let text = @utf8.decode_lossy(data[:])
  match text.find("\n\n") {
    Some(idx) =>
      substring_revparse(text, idx + 2, text.length()).find(needle) is Some(_)
    None => false
  }
}

///|
fn parse_peel_commit_spec(spec : String) -> String? {
  let suffix = "^{commit}"
  if spec.has_suffix(suffix) && spec.length() > suffix.length() {
    return Some(substring_revparse(spec, 0, spec.length() - suffix.length()))
  }
  None
}

///|
fn parse_peel_tree_spec(spec : String) -> String? {
  let suffix = "^{tree}"
  if spec.has_suffix(suffix) && spec.length() > suffix.length() {
    return Some(substring_revparse(spec, 0, spec.length() - suffix.length()))
  }
  None
}

///|
fn peel_object_to_commit(
  fs : &@git.RepoFileSystem,
  git_dir : String,
  id : @git.ObjectId,
) -> @git.ObjectId? raise @git.GitError {
  let db = ObjectDb::load(fs, git_dir)
  let mut current = id
  for _ in 0..<8 {
    let obj = db.get(fs, current)
    guard obj is Some(o) else { return None }
    match o.obj_type {
      @git.ObjectType::Commit => return Some(current)
      @git.ObjectType::Tag =>
        match parse_tag_object_target(o.data) {
          Some(next) => current = next
          None => return None
        }
      _ => return None
    }
  }
  None
}

///|
fn peel_object_to_tree(
  fs : &@git.RepoFileSystem,
  git_dir : String,
  id : @git.ObjectId,
) -> @git.ObjectId? raise @git.GitError {
  let db = ObjectDb::load(fs, git_dir)
  let mut current = id
  for _ in 0..<8 {
    let obj = db.get(fs, current)
    guard obj is Some(o) else { return None }
    match o.obj_type {
      @git.ObjectType::Tree => return Some(current)
      @git.ObjectType::Commit => return Some(@git.parse_commit(o.data).tree)
      @git.ObjectType::Tag =>
        match parse_tag_object_target(o.data) {
          Some(next) => current = next
          None => return None
        }
      _ => return None
    }
  }
  None
}

///|
fn parse_tag_object_target(data : Bytes) -> @git.ObjectId? {
  let text = @utf8.decode_lossy(data[:])
  for line_view in text.split("\n") {
    let line = line_view.to_string()
    if line.length() == 0 {
      break
    }
    if line.has_prefix("object ") {
      let hex = substring_revparse(line, 7, line.length())
      let id = @git.ObjectId::from_hex(hex) catch { _ => return None }
      return Some(id)
    }
  }
  None
}

///|
/// Parse revision suffix like ^, ^^, ~n
fn parse_rev_suffix(spec : String) -> (String, Int) {
  let chars = spec.to_array()
  let len = chars.length()
  if len == 0 {
    return (spec, 0)
  }
  // Find where suffix starts - must start with ^ or ~
  let mut suffix_start = -1
  for i = 0; i < len; i = i + 1 {
    let c = chars[i]
    if c == '^' || c == '~' {
      suffix_start = i
      break
    }
  }
  if suffix_start < 0 {
    return (spec, 0)
  }
  // Validate suffix - only ^, ~, and digits after the first ^ or ~
  for i = suffix_start; i < len; i = i + 1 {
    let c = chars[i]
    if not(c == '^' || c == '~' || (c >= '0' && c <= '9')) {
      // Invalid suffix character - no suffix
      return (spec, 0)
    }
  }
  let base = substring_revparse(spec, 0, suffix_start)
  let suffix = substring_revparse(spec, suffix_start, len)
  // Parse suffix
  let count = parse_ancestor_count(suffix)
  (base, count)
}

///|
/// Parse ancestor count from suffix like ^, ^^, ~3
fn parse_ancestor_count(suffix : String) -> Int {
  let chars = suffix.to_array()
  if chars.length() == 0 {
    return 0
  }
  // Count consecutive ^
  let mut caret_count = 0
  let mut i = 0
  while i < chars.length() && chars[i] == '^' {
    caret_count += 1
    i += 1
  }
  if caret_count > 0 && i == chars.length() {
    return caret_count
  }
  // Handle ~n
  if chars[0] == '~' {
    if chars.length() == 1 {
      return 1
    }
    let num_str = substring_revparse(suffix, 1, chars.length())
    return parse_int_simple(num_str)
  }
  // Handle ^n (first parent n times is same as ~n for our purposes)
  if chars[0] == '^' && chars.length() > 1 {
    let num_str = substring_revparse(suffix, 1, chars.length())
    return parse_int_simple(num_str)
  }
  0
}

///|
fn parse_int_simple(s : String) -> Int {
  let chars = s.to_array()
  let mut result = 0
  for c in chars {
    if c >= '0' && c <= '9' {
      result = result * 10 + (c.to_int() - '0'.to_int())
    }
  }
  result
}

///|
fn substring_revparse(s : String, start : Int, end : Int) -> String {
  let chars = s.to_array()
  let result = StringBuilder::new()
  for i = start; i < end && i < chars.length(); i = i + 1 {
    result.write_char(chars[i])
  }
  result.to_string()
}

///|
fn resolve_abbrev_ref_id(
  fs : &@git.RepoFileSystem,
  git_dir : String,
  spec : String,
) -> @git.ObjectId? raise @git.GitError {
  if spec.length() < 4 ||
    spec.length() >= 40 ||
    not(@githash.is_hex_string(spec)) {
    return None
  }
  let needle = @githash.lower_hex_string(spec)
  let refs = show_ref(fs, git_dir)
  let db = ObjectDb::load(fs, git_dir)
  let queue : Array[@git.ObjectId] = []
  let seen : Map[String, Bool] = {}
  for item in refs {
    let (_, id) = item
    queue.push(id)
  }
  match resolve_head_commit(fs, git_dir) {
    Some(id) => queue.push(id)
    None => ()
  }
  let mut matched : @git.ObjectId? = None
  while queue.length() > 0 {
    let id = match queue.pop() {
      Some(oid) => oid
      None => break
    }
    let hex = id.to_hex()
    if seen.contains(hex) {
      continue
    }
    seen[hex] = true
    if hex.has_prefix(needle) {
      match matched {
        None => matched = Some(id)
        Some(prev) => if prev != id { return None }
      }
    }
    match db.get(fs, id) {
      Some(obj) =>
        if obj.obj_type == @git.ObjectType::Commit {
          let info = @git.parse_commit(obj.data)
          for parent in info.parents {
            queue.push(parent)
          }
        }
      None => ()
    }
  }
  matched
}

///|
/// Resolve base reference (without suffix)
fn resolve_base_ref(
  fs : &@git.RepoFileSystem,
  git_dir : String,
  spec : String,
) -> @git.ObjectId? raise @git.GitError {
  if spec == "HEAD" || spec == "" || spec == "@" {
    return resolve_head_commit(fs, git_dir)
  }
  if resolve_ref(fs, git_dir, spec) is Some(id) {
    return Some(id)
  }
  if spec.has_prefix("refs/") {
    return resolve_ref(fs, git_dir, spec)
  }
  if spec.has_prefix("heads/") ||
    spec.has_prefix("tags/") ||
    spec.has_prefix("remotes/") {
    return resolve_ref(fs, git_dir, "refs/" + spec)
  }
  if spec.length() == 40 && @githash.is_hex_string(spec) {
    match @git.ObjectId::from_hex(spec) {
      id => return Some(id)
    }
  }
  if resolve_abbrev_ref_id(fs, git_dir, spec) is Some(id) {
    return Some(id)
  }
  if resolve_ref(fs, git_dir, "refs/heads/" + spec) is Some(id) {
    return Some(id)
  }
  if resolve_ref(fs, git_dir, "refs/remotes/" + spec) is Some(id) {
    return Some(id)
  }
  if resolve_ref(fs, git_dir, "refs/tags/" + spec) is Some(id) {
    return Some(id)
  }
  None
}

///|
/// Resolve path within a commit/tree
fn resolve_path_in_commit(
  fs : &@git.RepoFileSystem,
  git_dir : String,
  base_id : @git.ObjectId,
  path : String,
) -> @git.ObjectId? raise @git.GitError {
  if path.length() == 0 {
    return None
  }
  let db = ObjectDb::load(fs, git_dir)
  let obj = db.get(fs, base_id)
  match obj {
    None => return None
    Some(o) => {
      let tree_id = match o.obj_type {
        @git.ObjectType::Commit => @git.parse_commit(o.data).tree
        @git.ObjectType::Tree => base_id
        _ => return None
      }
      let entry = find_tree_entry(db, fs, tree_id, path)
      match entry {
        Some(e) => Some(e.id)
        None => None
      }
    }
  }
}

///|
/// Walk up the parent chain n times
fn walk_ancestors(
  fs : &@git.RepoFileSystem,
  git_dir : String,
  start : @git.ObjectId,
  count : Int,
) -> @git.ObjectId? raise @git.GitError {
  let db = ObjectDb::load(fs, git_dir)
  let mut current = start
  for _i = 0; _i < count; _i = _i + 1 {
    let obj = match db.get(fs, current) {
      Some(o) => o
      None => return None
    }
    if obj.obj_type != @git.ObjectType::Commit {
      raise @git.GitError::InvalidObject("Not a commit object")
    }
    let commit_info = @git.parse_commit(obj.data)
    if commit_info.parents.length() == 0 {
      return None // No more parents
    }
    current = commit_info.parents[0]
  }
  Some(current)
}

///|
/// List all refs (loose + packed).
pub fn show_ref(
  fs : &@git.RepoFileSystem,
  git_dir : String,
) -> Array[(String, @git.ObjectId)] raise @git.GitError {
  let out : Map[String, @git.ObjectId] = {}
  let refs_dir = join_path(git_dir, "refs")
  if fs.is_dir(refs_dir) {
    ref_collect_loose(fs, git_dir, refs_dir, "refs", out)
  }
  let packed = join_path(git_dir, "packed-refs")
  if fs.is_file(packed) {
    ref_collect_packed(fs, packed, out)
  }
  let result : Array[(String, @git.ObjectId)] = []
  for item in out.to_array() {
    let (name, id) = item
    result.push((name, id))
  }
  result.sort_by((a, b) => String::compare(a.0, b.0))
  result
}

///|
/// Format like `git show-ref` output.
pub fn show_ref_text(
  fs : &@git.RepoFileSystem,
  git_dir : String,
) -> Array[String] raise @git.GitError {
  let refs = show_ref(fs, git_dir)
  let lines : Array[String] = []
  for item in refs {
    let (name, id) = item
    lines.push("\{id.to_hex()} \{name}")
  }
  lines
}

///|
fn ref_collect_loose(
  fs : &@git.RepoFileSystem,
  git_dir : String,
  dir : String,
  prefix : String,
  out : Map[String, @git.ObjectId],
) -> Unit raise @git.GitError {
  let entries = fs.readdir(dir)
  for name in entries {
    let path = join_path(dir, name)
    let rel = if prefix == "" { name } else { prefix + "/" + name }
    if fs.is_dir(path) {
      ref_collect_loose(fs, git_dir, path, rel, out)
    } else if fs.is_file(path) {
      let line = ref_read_line(fs, path)
      if line.has_prefix("ref: ") {
        let target = String::unsafe_substring(line, start=5, end=line.length())
        let resolved = resolve_ref(fs, git_dir, target) catch { _ => None }
        match resolved {
          Some(id) => out[rel] = id
          None => ()
        }
      } else {
        out[rel] = @git.ObjectId::from_hex(line)
      }
    }
  }
}

///|
fn ref_collect_packed(
  fs : &@git.RepoFileSystem,
  packed_path : String,
  out : Map[String, @git.ObjectId],
) -> Unit raise @git.GitError {
  let text = @utf8.decode_lossy(fs.read_file(packed_path)[:])
  for line_view in text.split("\n") {
    let line = ref_trim_line(line_view.to_string())
    if line.length() == 0 {
      continue
    }
    if line.has_prefix("#") || line.has_prefix("^") {
      continue
    }
    let space = line.find(" ")
    match space {
      None => continue
      Some(idx) => {
        if idx + 1 >= line.length() {
          continue
        }
        let id_hex = String::unsafe_substring(line, start=0, end=idx)
        let name = String::unsafe_substring(
          line,
          start=idx + 1,
          end=line.length(),
        )
        if not(out.contains(name)) {
          out[name] = @git.ObjectId::from_hex(id_hex)
        }
      }
    }
  }
}

///|
fn ref_read_line(
  fs : &@git.RepoFileSystem,
  path : String,
) -> String raise @git.GitError {
  let text = @utf8.decode_lossy(fs.read_file(path)[:])
  for line_view in text.split("\n") {
    let line = ref_trim_line(line_view.to_string())
    if line.length() > 0 {
      return line
    }
  }
  raise @git.GitError::InvalidObject("Empty ref: \{path}")
}

///|
fn ref_trim_line(line : String) -> String {
  let mut s = line
  if s.has_suffix("\r") {
    s = String::unsafe_substring(s, start=0, end=s.length() - 1)
  }
  s
}

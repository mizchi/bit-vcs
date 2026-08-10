///| Git index (v2/v3) reader/writer

///|
pub struct IndexEntry {
  path : String
  id : @bit.ObjectId
  mode : Int
  size : Int
  mtime_sec : Int
  mtime_nsec : Int
  intent_to_add : Bool
  dev : Int
  ino : Int
  uid : Int
  gid : Int
}

///|
pub struct IndexStageEntry {
  entry : IndexEntry
  stage : Int
}

///|
pub struct ResolveUndoStage {
  mode : Int
  id : @bit.ObjectId
}

///|
pub struct ResolveUndoEntry {
  path : String
  base : ResolveUndoStage?
  ours : ResolveUndoStage?
  theirs : ResolveUndoStage?
}

///|
priv struct IndexCacheTree {
  name : String
  entry_count : Int
  oid : @bit.ObjectId?
  subtrees : Array[IndexCacheTree]
}

///|
pub fn IndexEntry::new(
  path : String,
  id : @bit.ObjectId,
  mode : Int,
  size : Int,
  mtime_sec? : Int = 0,
  mtime_nsec? : Int = 0,
  intent_to_add? : Bool = false,
  dev? : Int = 0,
  ino? : Int = 0,
  uid? : Int = 0,
  gid? : Int = 0,
) -> IndexEntry {
  {
    path,
    id,
    mode,
    size,
    mtime_sec,
    mtime_nsec,
    intent_to_add,
    dev,
    ino,
    uid,
    gid,
  }
}

///|
pub fn IndexStageEntry::new(entry : IndexEntry, stage : Int) -> IndexStageEntry {
  { entry, stage }
}

///|
fn index_repo_hash_size(fs : &@bit.RepoFileSystem, git_dir : String) -> Int {
  match
    read_config_value(fs, git_dir + "/config", "extensions", "objectformat") {
    Some(raw) =>
      if config_strip_quotes(raw).to_lower() == "sha256" {
        32
      } else {
        20
      }
    None => 20
  }
}

///|
fn index_hash_size_for_entries(
  entries : Array[IndexEntry],
  hash_size : Int,
) -> Int {
  if entries.length() > 0 {
    entries[0].id.hash_size()
  } else {
    hash_size
  }
}

///|
fn index_hash_size_for_stage_entries(
  entries : Array[IndexStageEntry],
  hash_size : Int,
) -> Int {
  if entries.length() > 0 {
    entries[0].entry.id.hash_size()
  } else {
    hash_size
  }
}

///|
pub fn read_index_entries(
  fs : &@bit.RepoFileSystem,
  git_dir : String,
) -> Array[IndexEntry] raise @bit.GitError {
  index_entries_from_stage_entries(read_index_stage_entries(fs, git_dir))
}

///|
fn index_entries_from_stage_entries(
  staged_entries : Array[IndexStageEntry],
) -> Array[IndexEntry] {
  let mut has_conflicts = false
  for item in staged_entries {
    if item.stage != 0 {
      has_conflicts = true
      break
    }
  }
  if has_conflicts {
    let selected : Map[String, (Int, IndexEntry)] = Map([])
    for item in staged_entries {
      let prio = index_stage_priority(item.stage)
      let entry = item.entry
      match selected.get(entry.path) {
        Some((prev_prio, _)) =>
          if prio > prev_prio {
            selected[entry.path] = (prio, entry)
          }
        None => selected[entry.path] = (prio, entry)
      }
    }
    let deduped : Array[IndexEntry] = Array::new(capacity=selected.length())
    for _, value in selected {
      deduped.push(value.1)
    }
    deduped.sort_by((a, b) => index_path_compare_git_order(a.path, b.path))
    deduped
  } else {
    let entries : Array[IndexEntry] = []
    for item in staged_entries {
      entries.push(item.entry)
    }
    entries
  }
}

///|
/// Read the index entries and optional TREE extension from one index snapshot.
/// A missing or malformed extension falls back to the ordinary staged-tree walk.
fn read_index_entries_with_cache_tree(
  fs : &@bit.RepoFileSystem,
  git_dir : String,
) -> (Array[IndexEntry], IndexCacheTree?) raise @bit.GitError {
  let path = join_path(git_dir, "index")
  if !fs.is_file(path) {
    return ([], None)
  }
  let data = fs.read_file(path)
  let hash_size = index_repo_hash_size(fs, git_dir)
  let staged_entries = index_read_stage_entries_from_bytes(data, hash_size~)
  let index_entries = index_entries_from_stage_entries(staged_entries)
  let cache_tree = if staged_entries.any(fn(item) { item.stage != 0 }) {
    None
  } else {
    index_read_cache_tree_from_bytes(data, hash_size~) catch {
      _ => None
    }
  }
  (index_entries, cache_tree)
}

///|
fn index_entry_is_sparse_dir(entry : IndexEntry) -> Bool {
  entry.mode == 0o040000 && entry.path.has_suffix("/")
}

///|
fn index_collect_tree_entries(
  db : ObjectDb,
  fs : &@bit.RepoFileSystem,
  tree_id : @bit.ObjectId,
  prefix : String,
  out : Array[IndexEntry],
) -> Unit raise @bit.GitError {
  let tree_obj = db.get(fs, tree_id)
  match tree_obj {
    None =>
      raise @bit.GitError::InvalidObject(
        "Missing tree object: " + tree_id.to_hex(),
      )
    Some(obj) => {
      if obj.obj_type != @bit.ObjectType::Tree {
        raise @bit.GitError::InvalidObject("Object is not a tree")
      }
      let entries = @bit.parse_tree(obj.data)
      for entry in entries {
        let path = if prefix == "" {
          entry.name
        } else {
          prefix + "/" + entry.name
        }
        if entry.mode == "40000" {
          index_collect_tree_entries(db, fs, entry.id, path, out)
          continue
        }
        if entry.mode == "160000" {
          out.push(IndexEntry::new(path, entry.id, 0o160000, 0))
          continue
        }
        let blob_obj = db.get(fs, entry.id)
        match blob_obj {
          None =>
            raise @bit.GitError::InvalidObject(
              "Missing blob object: " + entry.id.to_hex(),
            )
          Some(blob) => {
            if blob.obj_type != @bit.ObjectType::Blob {
              raise @bit.GitError::InvalidObject("Object is not a blob")
            }
            out.push(
              IndexEntry::new(
                path,
                entry.id,
                index_parse_octal_value(entry.mode),
                blob.data.length(),
              ),
            )
          }
        }
      }
    }
  }
}

///|
pub fn expand_sparse_index_entries(
  fs : &@bit.RepoFileSystem,
  git_dir : String,
  entries : Array[IndexEntry],
) -> Array[IndexEntry] raise @bit.GitError {
  let has_sparse_dir = entries.any(index_entry_is_sparse_dir)
  if !has_sparse_dir {
    return entries
  }
  let db = ObjectDb::load(fs, git_dir)
  let expanded : Array[IndexEntry] = []
  for entry in entries {
    if index_entry_is_sparse_dir(entry) {
      let prefix = String::unsafe_substring(
        entry.path,
        start=0,
        end=entry.path.length() - 1,
      )
      index_collect_tree_entries(db, fs, entry.id, prefix, expanded)
    } else {
      expanded.push(entry)
    }
  }
  expanded.sort_by((a, b) => index_path_compare_git_order(a.path, b.path))
  expanded
}

///|
pub fn expand_sparse_skip_worktree_paths(
  fs : &@bit.RepoFileSystem,
  git_dir : String,
  entries : Array[IndexEntry],
  skip_worktree_paths : Map[String, Bool],
) -> Map[String, Bool] raise @bit.GitError {
  let has_sparse_dir = entries.any(index_entry_is_sparse_dir)
  if !has_sparse_dir {
    return skip_worktree_paths
  }
  let db = ObjectDb::load(fs, git_dir)
  let expanded : Map[String, Bool] = Map([])
  for path in skip_worktree_paths.keys() {
    expanded[path] = true
  }
  for entry in entries {
    if !skip_worktree_paths.contains(entry.path) {
      continue
    }
    if index_entry_is_sparse_dir(entry) {
      let prefix = String::unsafe_substring(
        entry.path,
        start=0,
        end=entry.path.length() - 1,
      )
      let children : Array[IndexEntry] = []
      index_collect_tree_entries(db, fs, entry.id, prefix, children)
      for child in children {
        expanded[child.path] = true
      }
    } else {
      expanded[entry.path] = true
    }
  }
  expanded
}

///|
pub fn read_index_stage_entries(
  fs : &@bit.RepoFileSystem,
  git_dir : String,
) -> Array[IndexStageEntry] raise @bit.GitError {
  let path = join_path(git_dir, "index")
  if !fs.is_file(path) {
    return []
  }
  let data = fs.read_file(path)
  index_read_stage_entries_from_bytes(
    data,
    hash_size=index_repo_hash_size(fs, git_dir),
  )
}

///|
pub fn read_resolve_undo_entries(
  fs : &@bit.RepoFileSystem,
  git_dir : String,
) -> Array[ResolveUndoEntry] raise @bit.GitError {
  let path = join_path(git_dir, "index")
  if !fs.is_file(path) {
    return []
  }
  let data = fs.read_file(path)
  index_read_resolve_undo_entries_from_bytes(
    data,
    hash_size=index_repo_hash_size(fs, git_dir),
  )
}

///|
fn index_read_stage_entries_from_bytes(
  data : Bytes,
  hash_size? : Int = 20,
) -> Array[IndexStageEntry] raise @bit.GitError {
  if data.length() < 32 {
    raise @bit.GitError::InvalidObject("Index file too short")
  }
  if !(data[0] == b'D' && data[1] == b'I' && data[2] == b'R' && data[3] == b'C') {
    raise @bit.GitError::InvalidObject("Invalid index header")
  }
  let version = index_read_u32_be(data, 4)
  if version != 2 && version != 3 {
    raise @bit.GitError::InvalidObject("Unsupported index version: \{version}")
  }
  let count = index_read_u32_be(data, 8)
  let mut offset = 12
  let entries : Array[IndexStageEntry] = Array::new(capacity=count)
  for _ in 0..<count {
    let entry_start = offset
    if offset + 40 + hash_size + 2 > data.length() {
      raise @bit.GitError::InvalidObject("Index entry truncated")
    }
    // Index entry format (40 bytes stat data):
    // ctime_seconds, ctime_nanoseconds, mtime_seconds, mtime_nanoseconds,
    // dev, ino, mode, uid, gid, file_size
    offset += 8 // skip ctime_sec, ctime_nsec
    let mtime_sec = index_read_u32_be(data, offset)
    offset += 4
    let mtime_nsec = index_read_u32_be(data, offset)
    offset += 4
    let dev = index_read_u32_be(data, offset)
    offset += 4
    let ino = index_read_u32_be(data, offset)
    offset += 4
    let mode = index_read_u32_be(data, offset)
    offset += 4
    let uid = index_read_u32_be(data, offset)
    offset += 4
    let gid = index_read_u32_be(data, offset)
    offset += 4
    let size = index_read_u32_be(data, offset)
    offset += 4
    let id = index_read_object_id(data, offset, hash_size~)
    offset += hash_size
    // flags (u16)
    let flags = index_read_u16_be(data, offset)
    offset += 2
    let stage = (flags >> 12) & 0x3
    let has_extended = (flags & 0x4000) != 0
    let ext_flags = if has_extended {
      index_read_u16_be(data, offset)
    } else {
      0
    }
    if has_extended {
      offset += 2
    }
    // Read path directly from bytes (avoid intermediate Array[Byte] + StringBuilder)
    let fixed_size = 40 + hash_size + 2 + (if has_extended { 2 } else { 0 })
    let path_start = entry_start + fixed_size
    let mut path_end = path_start
    while path_end < data.length() && data[path_end] != b'\x00' {
      path_end += 1
    }
    let path_str = @utf8.decode_lossy(data[path_start:path_end])
    let path_len = path_end - path_start
    let entry_size = (fixed_size + path_len + 1 + 7) / 8 * 8
    offset = entry_start + entry_size
    entries.push({
      entry: {
        path: path_str,
        id,
        mode,
        size,
        mtime_sec,
        mtime_nsec,
        intent_to_add: index_ext_flags_has_intent_to_add(ext_flags),
        dev,
        ino,
        uid,
        gid,
      },
      stage,
    })
  }
  entries
}

///|
fn index_read_resolve_undo_entries_from_bytes(
  data : Bytes,
  hash_size? : Int = 20,
) -> Array[ResolveUndoEntry] raise @bit.GitError {
  if data.length() < 32 {
    return []
  }
  if !(data[0] == b'D' && data[1] == b'I' && data[2] == b'R' && data[3] == b'C') {
    raise @bit.GitError::InvalidObject("Invalid index header")
  }
  let version = index_read_u32_be(data, 4)
  if version != 2 && version != 3 {
    raise @bit.GitError::InvalidObject("Unsupported index version: \{version}")
  }
  let count = index_read_u32_be(data, 8)
  let checksum_start = data.length() - hash_size
  let mut offset = 12
  for _ in 0..<count {
    let entry_start = offset
    if offset + 40 + hash_size + 2 > checksum_start {
      raise @bit.GitError::InvalidObject("Index entry truncated")
    }
    let flags = index_read_u16_be(data, offset + 40 + hash_size)
    let has_extended = (flags & 0x4000) != 0
    let fixed_size = 40 + hash_size + 2 + (if has_extended { 2 } else { 0 })
    let path_start = entry_start + fixed_size
    let mut path_end = path_start
    while path_end < checksum_start && data[path_end] != b'\x00' {
      path_end += 1
    }
    if path_end >= checksum_start {
      raise @bit.GitError::InvalidObject("Index entry truncated")
    }
    let path_len = path_end - path_start
    let entry_size = (fixed_size + path_len + 1 + 7) / 8 * 8
    offset = entry_start + entry_size
  }
  while offset + 8 <= checksum_start {
    let signature = @utf8.decode_lossy(data[offset:offset + 4])
    let chunk_size = index_read_u32_be(data, offset + 4)
    let body_start = offset + 8
    let body_end = body_start + chunk_size
    if body_end > checksum_start {
      raise @bit.GitError::InvalidObject("Index extension truncated")
    }
    if signature == "REUC" {
      let chunk_view = data[body_start:body_end]
      return index_parse_resolve_undo_chunk(
        Bytes::from_array(
          FixedArray::makei(chunk_view.length(), fn(i) { chunk_view[i] }),
        ),
        hash_size~,
      )
    }
    offset = body_end
  }
  []
}

///|
fn index_parse_resolve_undo_chunk(
  data : Bytes,
  hash_size? : Int = 20,
) -> Array[ResolveUndoEntry] raise @bit.GitError {
  let entries : Array[ResolveUndoEntry] = []
  let mut offset = 0
  while offset < data.length() {
    let (path, next_offset) = index_read_nul_terminated_string(data, offset)
    let (base_mode, base_mode_end) = index_read_nul_terminated_octal(
      data, next_offset,
    )
    let (ours_mode, ours_mode_end) = index_read_nul_terminated_octal(
      data, base_mode_end,
    )
    let (theirs_mode, theirs_mode_end) = index_read_nul_terminated_octal(
      data, ours_mode_end,
    )
    let mut cursor = theirs_mode_end
    let base = if base_mode == 0 {
      None
    } else {
      let id = index_read_object_id(data, cursor, hash_size~)
      cursor += hash_size
      let stage : ResolveUndoStage = { mode: base_mode, id }
      Some(stage)
    }
    let ours = if ours_mode == 0 {
      None
    } else {
      let id = index_read_object_id(data, cursor, hash_size~)
      cursor += hash_size
      let stage : ResolveUndoStage = { mode: ours_mode, id }
      Some(stage)
    }
    let theirs = if theirs_mode == 0 {
      None
    } else {
      let id = index_read_object_id(data, cursor, hash_size~)
      cursor += hash_size
      let stage : ResolveUndoStage = { mode: theirs_mode, id }
      Some(stage)
    }
    entries.push({ path, base, ours, theirs })
    offset = cursor
  }
  entries
}

///|
fn index_read_entries_end_offset(
  data : Bytes,
  count : Int,
  hash_size? : Int = 20,
) -> Int raise @bit.GitError {
  let checksum_start = data.length() - hash_size
  let mut offset = 12
  for _ in 0..<count {
    let entry_start = offset
    if offset + 40 + hash_size + 2 > checksum_start {
      raise @bit.GitError::InvalidObject("Index entry truncated")
    }
    let flags = index_read_u16_be(data, offset + 40 + hash_size)
    let has_extended = (flags & 0x4000) != 0
    let fixed_size = 40 + hash_size + 2 + (if has_extended { 2 } else { 0 })
    let path_start = entry_start + fixed_size
    let mut path_end = path_start
    while path_end < checksum_start && data[path_end] != b'\x00' {
      path_end += 1
    }
    if path_end >= checksum_start {
      raise @bit.GitError::InvalidObject("Index entry truncated")
    }
    let path_len = path_end - path_start
    let entry_size = (fixed_size + path_len + 1 + 7) / 8 * 8
    offset = entry_start + entry_size
  }
  offset
}

///|
fn index_find_extension_chunk(
  data : Bytes,
  signature : String,
  hash_size? : Int = 20,
) -> Bytes? raise @bit.GitError {
  if data.length() < 32 {
    return None
  }
  let count = index_read_u32_be(data, 8)
  let checksum_start = data.length() - hash_size
  let mut offset = index_read_entries_end_offset(data, count, hash_size~)
  while offset + 8 <= checksum_start {
    let current_sig = @utf8.decode_lossy(data[offset:offset + 4])
    let chunk_size = index_read_u32_be(data, offset + 4)
    let body_start = offset + 8
    let body_end = body_start + chunk_size
    if body_end > checksum_start {
      raise @bit.GitError::InvalidObject("Index extension truncated")
    }
    if current_sig == signature {
      let chunk_view = data[body_start:body_end]
      return Some(
        Bytes::from_array(
          FixedArray::makei(chunk_view.length(), fn(i) { chunk_view[i] }),
        ),
      )
    }
    offset = body_end
  }
  None
}

///|
fn index_parse_signed_decimal(
  data : Bytes,
  start : Int,
) -> (Int, Int) raise @bit.GitError {
  if start >= data.length() {
    raise @bit.GitError::InvalidObject("Invalid cache-tree extension")
  }
  let mut sign = 1
  let mut cursor = start
  if data[cursor] == b'-' {
    sign = -1
    cursor += 1
  }
  if cursor >= data.length() || data[cursor] < b'0' || data[cursor] > b'9' {
    raise @bit.GitError::InvalidObject("Invalid cache-tree extension")
  }
  let mut value = 0
  while cursor < data.length() && data[cursor] >= b'0' && data[cursor] <= b'9' {
    value = value * 10 + (data[cursor].to_int() - b'0'.to_int())
    cursor += 1
  }
  (sign * value, cursor)
}

///|
fn index_parse_cache_tree_node(
  data : Bytes,
  start : Int,
  hash_size? : Int = 20,
) -> (IndexCacheTree, Int) raise @bit.GitError {
  let (name, after_name) = index_read_nul_terminated_string(data, start)
  let (entry_count, after_entry_count) = index_parse_signed_decimal(
    data, after_name,
  )
  if after_entry_count >= data.length() || data[after_entry_count] != b' ' {
    raise @bit.GitError::InvalidObject("Invalid cache-tree extension")
  }
  let (subtree_nr, after_subtree_nr) = index_parse_signed_decimal(
    data,
    after_entry_count + 1,
  )
  if after_subtree_nr >= data.length() || data[after_subtree_nr] != b'\n' {
    raise @bit.GitError::InvalidObject("Invalid cache-tree extension")
  }
  let mut cursor = after_subtree_nr + 1
  let oid = if entry_count >= 0 {
    let parsed = index_read_object_id(data, cursor, hash_size~)
    cursor += hash_size
    Some(parsed)
  } else {
    None
  }
  let subtrees : Array[IndexCacheTree] = []
  for _ in 0..<subtree_nr {
    let (subtree, next_cursor) = index_parse_cache_tree_node(
      data,
      cursor,
      hash_size~,
    )
    subtrees.push(subtree)
    cursor = next_cursor
  }
  ({ name, entry_count, oid, subtrees }, cursor)
}

///|
fn index_read_cache_tree_from_bytes(
  data : Bytes,
  hash_size? : Int = 20,
) -> IndexCacheTree? raise @bit.GitError {
  match index_find_extension_chunk(data, "TREE", hash_size~) {
    Some(chunk) => {
      let (tree, end_offset) = index_parse_cache_tree_node(chunk, 0, hash_size~)
      if end_offset != chunk.length() {
        raise @bit.GitError::InvalidObject("Invalid cache-tree extension")
      }
      Some(tree)
    }
    None => None
  }
}

///|
fn index_append_ascii_bytes(target : Array[Byte], text : String) -> Unit {
  for c in text {
    target.push(c.to_int().to_byte())
  }
}

///|
fn index_append_u32_be(target : Array[Byte], value : Int) -> Unit {
  target.push(((value >> 24) & 0xFF).to_byte())
  target.push(((value >> 16) & 0xFF).to_byte())
  target.push(((value >> 8) & 0xFF).to_byte())
  target.push((value & 0xFF).to_byte())
}

///|
fn index_append_cache_tree_node(
  target : Array[Byte],
  tree : IndexCacheTree,
) -> Unit {
  index_append_ascii_bytes(target, tree.name)
  target.push(b'\x00')
  index_append_ascii_bytes(target, tree.entry_count.to_string())
  target.push(b' ')
  index_append_ascii_bytes(target, tree.subtrees.length().to_string())
  target.push(b'\n')
  match tree.oid {
    Some(id) if tree.entry_count >= 0 =>
      for b in id.bytes {
        target.push(b)
      }
    _ => ()
  }
  for subtree in tree.subtrees {
    index_append_cache_tree_node(target, subtree)
  }
}

///|
fn index_cache_tree_extension_bytes(tree : IndexCacheTree) -> Array[Byte] {
  let body : Array[Byte] = []
  index_append_cache_tree_node(body, tree)
  let extension : Array[Byte] = [b'T', b'R', b'E', b'E']
  index_append_u32_be(extension, body.length())
  extension.append(body)
  extension
}

///|
fn index_cache_tree_invalidate_path(
  tree : IndexCacheTree,
  path : String,
) -> IndexCacheTree {
  let invalidated_entry_count = -1
  let slash_idx = index_find_first_slash(path)
  match slash_idx {
    None => {
      let kept : Array[IndexCacheTree] = []
      for subtree in tree.subtrees {
        if subtree.name != path {
          kept.push(subtree)
        }
      }
      {
        name: tree.name,
        entry_count: invalidated_entry_count,
        oid: None,
        subtrees: kept,
      }
    }
    Some(idx) => {
      let head = String::unsafe_substring(path, start=0, end=idx)
      let tail = String::unsafe_substring(
        path,
        start=idx + 1,
        end=path.length(),
      )
      let updated : Array[IndexCacheTree] = []
      for subtree in tree.subtrees {
        if subtree.name == head {
          updated.push(index_cache_tree_invalidate_path(subtree, tail))
        } else {
          updated.push(subtree)
        }
      }
      {
        name: tree.name,
        entry_count: invalidated_entry_count,
        oid: None,
        subtrees: updated,
      }
    }
  }
}

///|
fn index_find_first_slash(path : String) -> Int? {
  for i = 0; i < path.length(); i = i + 1 {
    if path[i] == '/' {
      return Some(i)
    }
  }
  None
}

///|
fn index_entry_signature(entry : IndexEntry) -> String {
  entry.id.to_hex() + ":" + entry.mode.to_string()
}

///|
fn index_collect_changed_paths(
  old_entries : Array[IndexEntry],
  new_entries : Array[IndexEntry],
) -> Array[String] {
  let old_by_path : Map[String, String] = Map([])
  for entry in old_entries {
    old_by_path[entry.path] = index_entry_signature(entry)
  }
  let new_by_path : Map[String, String] = Map([])
  for entry in new_entries {
    new_by_path[entry.path] = index_entry_signature(entry)
  }
  let changed : Array[String] = []
  let seen : Map[String, Bool] = Map([])
  for path, old_sig in old_by_path {
    match new_by_path.get(path) {
      Some(new_sig) if new_sig == old_sig => ()
      _ =>
        if !seen.contains(path) {
          seen[path] = true
          changed.push(path)
        }
    }
  }
  for path in new_by_path.keys() {
    if !old_by_path.contains(path) && !seen.contains(path) {
      seen[path] = true
      changed.push(path)
    }
  }
  changed
}

///|
fn index_preserve_cache_tree(
  fs : &@bit.RepoFileSystem,
  git_dir : String,
  sorted : Array[IndexEntry],
) -> IndexCacheTree? {
  let index_path = join_path(git_dir, "index")
  let raw = fs.read_file(index_path) catch { _ => return None }
  let previous_tree = index_read_cache_tree_from_bytes(
    raw,
    hash_size=index_repo_hash_size(fs, git_dir),
  ) catch {
    _ => return None
  }
  guard previous_tree is Some(tree) else { return None }
  let staged = index_read_stage_entries_from_bytes(raw) catch {
    _ => return None
  }
  let old_entries : Array[IndexEntry] = []
  for item in staged {
    if item.stage == 0 {
      old_entries.push(item.entry)
    } else {
      return None
    }
  }
  let changed_paths = index_collect_changed_paths(old_entries, sorted)
  let mut preserved = tree
  for path in changed_paths {
    preserved = index_cache_tree_invalidate_path(preserved, path)
  }
  Some(preserved)
}

///|
fn index_build_cache_tree_from_entries(
  entries : Array[IndexEntry],
  name? : String = "",
) -> IndexCacheTree {
  let file_entries : Array[@bit.TreeEntry] = []
  let dir_map : Map[String, Array[IndexEntry]] = Map([])
  let subtrees : Array[IndexCacheTree] = []
  let mut entry_count = 0
  for entry in entries {
    if worktree_is_zero_object_id(entry.id) {
      continue
    }
    match split_first(entry.path) {
      (entry_name, None) => {
        entry_count += 1
        file_entries.push(
          @bit.TreeEntry::new(
            @string_utils.mode_to_string(entry.mode),
            entry_name,
            entry.id,
          ),
        )
      }
      (entry_name, Some(rest)) =>
        match dir_map.get(entry_name) {
          Some(list) =>
            list.push({
              path: rest,
              id: entry.id,
              mode: entry.mode,
              size: entry.size,
              mtime_sec: entry.mtime_sec,
              mtime_nsec: entry.mtime_nsec,
              intent_to_add: entry.intent_to_add,
              dev: entry.dev,
              ino: entry.ino,
              uid: entry.uid,
              gid: entry.gid,
            })
          None =>
            dir_map[entry_name] = [
              {
                path: rest,
                id: entry.id,
                mode: entry.mode,
                size: entry.size,
                mtime_sec: entry.mtime_sec,
                mtime_nsec: entry.mtime_nsec,
                intent_to_add: entry.intent_to_add,
                dev: entry.dev,
                ino: entry.ino,
                uid: entry.uid,
                gid: entry.gid,
              },
            ]
        }
    }
  }
  for dir_name, list in dir_map {
    let subtree = index_build_cache_tree_from_entries(list, name=dir_name)
    file_entries.push(
      @bit.TreeEntry::new("40000", dir_name, subtree.oid.unwrap()),
    )
    subtrees.push(subtree)
    entry_count += subtree.entry_count
  }
  file_entries.sort_by(fn(a, b) {
    let a_key = if a.mode == "40000" { a.name + "/" } else { a.name }
    let b_key = if b.mode == "40000" { b.name + "/" } else { b.name }
    compare_strings_lexicographic(a_key, b_key)
  })
  subtrees.sort_by(fn(a, b) { compare_strings_lexicographic(a.name, b.name) })
  let (tree_id, _) = @bit.create_tree(file_entries)
  { name, entry_count, oid: Some(tree_id), subtrees }
}

///|
fn index_prepare_cache_tree(
  fs : &@bit.RepoFileSystem,
  git_dir : String,
  sorted : Array[IndexEntry],
) -> IndexCacheTree {
  match index_preserve_cache_tree(fs, git_dir, sorted) {
    Some(tree) => tree
    None => index_build_cache_tree_from_entries(sorted)
  }
}

///|
fn index_read_nul_terminated_string(
  data : Bytes,
  start : Int,
) -> (String, Int) raise @bit.GitError {
  let mut end = start
  while end < data.length() && data[end] != b'\x00' {
    end += 1
  }
  if end >= data.length() {
    raise @bit.GitError::InvalidObject("Unexpected end of resolve-undo data")
  }
  (@utf8.decode_lossy(data[start:end]), end + 1)
}

///|
fn index_read_nul_terminated_octal(
  data : Bytes,
  start : Int,
) -> (Int, Int) raise @bit.GitError {
  let (text, next) = index_read_nul_terminated_string(data, start)
  (index_parse_octal_value(text), next)
}

///|
fn index_parse_octal_value(text : String) -> Int raise @bit.GitError {
  if text.length() == 0 {
    raise @bit.GitError::InvalidObject("Invalid resolve-undo mode")
  }
  let mut value = 0
  for c in text {
    if c < '0' || c > '7' {
      raise @bit.GitError::InvalidObject("Invalid resolve-undo mode")
    }
    value = value * 8 + (c.to_int() - '0'.to_int())
  }
  value
}

///|
/// Read skip-worktree paths from both bit sidecar and index extended flags.
pub fn read_skip_worktree_paths(
  fs : &@bit.RepoFileSystem,
  git_dir : String,
  hash_size? : Int = 20,
) -> Map[String, Bool] {
  let effective_hash_size = if hash_size == 20 {
    index_repo_hash_size(fs, git_dir)
  } else {
    hash_size
  }
  let out : Map[String, Bool] = Map([])
  let sidecar_path = join_path(git_dir, "bit-skip-worktree")
  if fs.is_file(sidecar_path) {
    let text = @utf8.decode_lossy(
      (fs.read_file(sidecar_path) catch { _ => Default::default() })[:],
    )
    for line_view in text.split("\n") {
      let line = line_view.to_owned()
      if line.length() > 0 {
        out[line] = true
      }
    }
  }
  let index_path = join_path(git_dir, "index")
  if !fs.is_file(index_path) {
    return out
  }
  let data = fs.read_file(index_path) catch { _ => return out }
  if data.length() < 32 {
    return out
  }
  if !(data[0] == b'D' && data[1] == b'I' && data[2] == b'R' && data[3] == b'C') {
    return out
  }
  let count = index_read_u32_be(data, 8) catch { _ => return out }
  let mut offset = 12
  for _ in 0..<count {
    if offset + 40 + effective_hash_size + 2 > data.length() {
      return out
    }
    let flags = index_read_u16_be(data, offset + 40 + effective_hash_size) catch {
      _ => return out
    }
    let stage = (flags >> 12) & 0x3
    let has_extended = (flags & 0x4000) != 0
    let ext_flags = if has_extended {
      index_read_u16_be(data, offset + 40 + effective_hash_size + 2) catch {
        _ => return out
      }
    } else {
      0
    }
    let fixed_size = 40 +
      effective_hash_size +
      2 +
      (if has_extended { 2 } else { 0 })
    let path_start = offset + fixed_size
    let mut i = path_start
    while i < data.length() && data[i] != b'\x00' {
      i += 1
    }
    if i >= data.length() {
      return out
    }
    if stage == 0 && has_extended && (ext_flags & 0x4000) != 0 {
      out[@utf8.decode_lossy(data[path_start:i])] = true
    }
    let path_len = i - path_start
    let entry_size = (fixed_size + path_len + 1 + 7) / 8 * 8
    offset += entry_size
  }
  out
}

///|
pub fn read_assume_unchanged_paths(
  fs : &@bit.RepoFileSystem,
  git_dir : String,
  hash_size? : Int = 20,
) -> Map[String, Bool] {
  let effective_hash_size = if hash_size == 20 {
    index_repo_hash_size(fs, git_dir)
  } else {
    hash_size
  }
  let out : Map[String, Bool] = Map([])
  let index_path = join_path(git_dir, "index")
  if !fs.is_file(index_path) {
    return out
  }
  let data = fs.read_file(index_path) catch { _ => return out }
  if data.length() < 32 {
    return out
  }
  if !(data[0] == b'D' && data[1] == b'I' && data[2] == b'R' && data[3] == b'C') {
    return out
  }
  let count = index_read_u32_be(data, 8) catch { _ => return out }
  let mut offset = 12
  for _ in 0..<count {
    if offset + 40 + effective_hash_size + 2 > data.length() {
      return out
    }
    let flags = index_read_u16_be(data, offset + 40 + effective_hash_size) catch {
      _ => return out
    }
    let stage = (flags >> 12) & 0x3
    let has_extended = (flags & 0x4000) != 0
    let fixed_size = 40 +
      effective_hash_size +
      2 +
      (if has_extended { 2 } else { 0 })
    let path_start = offset + fixed_size
    let mut i = path_start
    while i < data.length() && data[i] != b'\x00' {
      i += 1
    }
    if i >= data.length() {
      return out
    }
    if stage == 0 && (flags & 0x8000) != 0 {
      out[@utf8.decode_lossy(data[path_start:i])] = true
    }
    let path_len = i - path_start
    let entry_size = (fixed_size + path_len + 1 + 7) / 8 * 8
    offset += entry_size
  }
  out
}

///|
pub fn read_unmerged_paths(
  fs : &@bit.RepoFileSystem,
  git_dir : String,
) -> Map[String, Bool] {
  let out : Map[String, Bool] = Map([])
  let entries = read_index_stage_entries(fs, git_dir) catch { _ => return out }
  for item in entries {
    if item.stage != 0 {
      out[item.entry.path] = true
    }
  }
  out
}

///|
pub fn write_skip_worktree_paths(
  fs : &@bit.FileSystem,
  git_dir : String,
  paths : Array[String],
) -> Unit raise @bit.GitError {
  let state_path = join_path(git_dir, "bit-skip-worktree")
  let by_path : Map[String, Bool] = Map([])
  for path in paths {
    if path.length() > 0 {
      by_path[path] = true
    }
  }
  let sorted = by_path.keys().to_array()
  sorted.sort_by((a, b) => String::compare(a, b))
  if sorted.length() == 0 {
    fs.remove_file(state_path) catch {
      _ => ()
    }
    return
  }
  fs.write_string(state_path, sorted.join("\n") + "\n")
}

///|
fn index_entry_buf_size(
  path_len : Int,
  has_extended : Bool,
  hash_size? : Int = 20,
) -> Int {
  let fixed_size = 40 + hash_size + 2 + (if has_extended { 2 } else { 0 })
  (fixed_size + path_len + 1 + 7) / 8 * 8
}

///|
fn write_index_entry_to_buf(
  buf : FixedArray[Byte],
  pos : Int,
  e : IndexEntry,
  stage : Int,
  skip_worktree : Bool,
  assume_unchanged : Bool,
  hash_size? : Int = 20,
) -> Int {
  let entry_start = pos
  let mut pos = pos
  fa_set_u32_be(buf, pos, e.mtime_sec) // ctime_sec
  fa_set_u32_be(buf, pos + 4, e.mtime_nsec) // ctime_nsec
  fa_set_u32_be(buf, pos + 8, e.mtime_sec) // mtime_sec
  fa_set_u32_be(buf, pos + 12, e.mtime_nsec) // mtime_nsec
  fa_set_u32_be(buf, pos + 16, e.dev)
  fa_set_u32_be(buf, pos + 20, e.ino)
  fa_set_u32_be(buf, pos + 24, e.mode) // mode
  fa_set_u32_be(buf, pos + 28, e.uid)
  fa_set_u32_be(buf, pos + 32, e.gid)
  fa_set_u32_be(buf, pos + 36, e.size) // file_size
  pos += 40
  // object id
  for i in 0..<e.id.bytes.length() {
    buf[pos + i] = e.id.bytes[i]
  }
  pos += e.id.bytes.length()
  // flags
  let path_bytes = @utf8.encode(e.path)
  let path_byte_len = path_bytes.length()
  let name_len = if path_byte_len < 0x0fff { path_byte_len } else { 0x0fff }
  let mut flags = name_len | ((stage & 0x3) << 12)
  let ext_flags = index_extended_flags(e.intent_to_add, skip_worktree)
  let has_extended = ext_flags != 0
  if stage == 0 && assume_unchanged {
    flags = flags | 0x8000
  }
  if has_extended {
    flags = flags | 0x4000
  }
  fa_set_u16_be(buf, pos, flags)
  pos += 2
  if has_extended {
    fa_set_u16_be(buf, pos, ext_flags)
    pos += 2
  }
  // path bytes
  for i in 0..<path_byte_len {
    buf[pos] = path_bytes[i]
    pos += 1
  }
  // NUL + padding to 8-byte alignment (already zeroed)
  entry_start + index_entry_buf_size(path_byte_len, has_extended, hash_size~)
}

///|
fn write_index_buf(
  sorted : Array[IndexEntry],
  skip_worktree_paths : Map[String, Bool]?,
  assume_unchanged_paths : Map[String, Bool]?,
  cache_tree? : IndexCacheTree? = None,
  hash_size? : Int = 20,
) -> FixedArray[Byte] {
  // Pre-calculate total buffer size
  let mut total_size = 12 // header: "DIRC" + version + count
  let mut version = 2
  for e in sorted {
    let is_skip = match skip_worktree_paths {
      Some(m) => m.contains(e.path)
      None => false
    }
    let has_extended = index_extended_flags(e.intent_to_add, is_skip) != 0
    if has_extended {
      version = 3
    }
    total_size += index_entry_buf_size(
      @utf8.encode(e.path).length(),
      has_extended,
      hash_size~,
    )
  }
  let cache_tree_extension = match cache_tree {
    Some(tree) => index_cache_tree_extension_bytes(tree)
    None => []
  }
  total_size += cache_tree_extension.length()
  total_size += hash_size // hash checksum
  let buf : FixedArray[Byte] = FixedArray::make(total_size, b'\x00')
  // Header
  buf[0] = b'D'
  buf[1] = b'I'
  buf[2] = b'R'
  buf[3] = b'C'
  fa_set_u32_be(buf, 4, version)
  fa_set_u32_be(buf, 8, sorted.length()) // count
  let mut pos = 12
  for e in sorted {
    let is_skip = match skip_worktree_paths {
      Some(m) => m.contains(e.path)
      None => false
    }
    let is_assume = match assume_unchanged_paths {
      Some(m) => m.contains(e.path)
      None => false
    }
    pos = write_index_entry_to_buf(
      buf,
      pos,
      e,
      0,
      is_skip,
      is_assume,
      hash_size~,
    )
  }
  for i in 0..<cache_tree_extension.length() {
    buf[pos + i] = cache_tree_extension[i]
  }
  pos += cache_tree_extension.length()
  // Hash checksum over header + entries
  let content_bytes = Bytes::from_array(buf[:pos])
  let checksum = @bit.hash_prefix(content_bytes, pos, hash_size~)
  for i in 0..<hash_size {
    buf[pos + i] = checksum.bytes[i]
  }
  buf
}

///|
fn index_preserved_flag_paths(
  fs : &@bit.RepoFileSystem,
  git_dir : String,
  entries : Array[IndexEntry],
  hash_size? : Int = 20,
) -> (Map[String, Bool], Map[String, Bool]) {
  let existing_skip = read_skip_worktree_paths(fs, git_dir, hash_size~)
  let existing_assume = read_assume_unchanged_paths(fs, git_dir, hash_size~)
  let skip_worktree_paths : Map[String, Bool] = Map([])
  let assume_unchanged_paths : Map[String, Bool] = Map([])
  for entry in entries {
    if existing_skip.contains(entry.path) {
      skip_worktree_paths[entry.path] = true
    }
    if existing_assume.contains(entry.path) {
      assume_unchanged_paths[entry.path] = true
    }
  }
  (skip_worktree_paths, assume_unchanged_paths)
}

///|
pub fn write_index_entries(
  fs : &@bit.FileSystem,
  git_dir : String,
  entries : Array[IndexEntry],
  hash_size? : Int = 20,
) -> Unit raise @bit.GitError {
  let sorted = entries.copy()
  sorted.sort_by((a, b) => index_path_compare_git_order(a.path, b.path))
  let effective_hash_size = index_hash_size_for_entries(sorted, hash_size)
  let buf = write_index_buf(sorted, None, None, hash_size=effective_hash_size)
  let index_path = join_path(git_dir, "index")
  fs.write_file(index_path, Bytes::from_array(buf[:]))
}

///|
pub fn write_index_entries_preserving_cache_tree(
  fs : &@bit.FileSystem,
  rfs : &@bit.RepoFileSystem,
  git_dir : String,
  entries : Array[IndexEntry],
) -> Unit raise @bit.GitError {
  let hash_size = index_repo_hash_size(rfs, git_dir)
  let sorted = entries.copy()
  sorted.sort_by((a, b) => index_path_compare_git_order(a.path, b.path))
  let cache_tree = index_prepare_cache_tree(rfs, git_dir, sorted)
  let (skip_worktree_paths, assume_unchanged_paths) = index_preserved_flag_paths(
    rfs,
    git_dir,
    sorted,
    hash_size~,
  )
  let buf = write_index_buf(
    sorted,
    Some(skip_worktree_paths),
    Some(assume_unchanged_paths),
    cache_tree=Some(cache_tree),
    hash_size~,
  )
  let index_path = join_path(git_dir, "index")
  fs.write_file(index_path, Bytes::from_array(buf[:]))
}

///|
pub fn write_index_entries_with_tree(
  fs : &@bit.FileSystem,
  rfs : &@bit.RepoFileSystem,
  git_dir : String,
  entries : Array[IndexEntry],
  tree_id : @bit.ObjectId,
) -> Unit raise @bit.GitError {
  let hash_size = index_repo_hash_size(rfs, git_dir)
  let sorted = entries.copy()
  sorted.sort_by((a, b) => index_path_compare_git_order(a.path, b.path))
  let cache_tree = index_build_cache_tree_from_entries(sorted)
  match cache_tree.oid {
    Some(id) if id == tree_id => ()
    _ => ()
  }
  let (skip_worktree_paths, assume_unchanged_paths) = index_preserved_flag_paths(
    rfs,
    git_dir,
    sorted,
    hash_size~,
  )
  let buf = write_index_buf(
    sorted,
    Some(skip_worktree_paths),
    Some(assume_unchanged_paths),
    cache_tree=Some(cache_tree),
    hash_size~,
  )
  let index_path = join_path(git_dir, "index")
  fs.write_file(index_path, Bytes::from_array(buf[:]))
}

///|
fn index_read_u32_be(data : Bytes, start : Int) -> Int raise @bit.GitError {
  if start < 0 || start + 4 > data.length() {
    raise @bit.GitError::InvalidObject("Unexpected end of index data")
  }
  (data[start].to_int() << 24) |
  (data[start + 1].to_int() << 16) |
  (data[start + 2].to_int() << 8) |
  data[start + 3].to_int()
}

///|
fn index_read_u16_be(data : Bytes, start : Int) -> Int raise @bit.GitError {
  if start < 0 || start + 2 > data.length() {
    raise @bit.GitError::InvalidObject("Unexpected end of index data")
  }
  (data[start].to_int() << 8) | data[start + 1].to_int()
}

///|
pub fn write_index_entries_with_skip_worktree(
  fs : &@bit.FileSystem,
  git_dir : String,
  entries : Array[IndexEntry],
  skip_worktree_paths : Map[String, Bool],
  hash_size? : Int = 20,
) -> Unit raise @bit.GitError {
  let sorted = entries.copy()
  sorted.sort_by((a, b) => index_path_compare_git_order(a.path, b.path))
  let effective_hash_size = index_hash_size_for_entries(sorted, hash_size)
  let buf = write_index_buf(
    sorted,
    Some(skip_worktree_paths),
    None,
    hash_size=effective_hash_size,
  )
  let index_path = join_path(git_dir, "index")
  fs.write_file(index_path, Bytes::from_array(buf[:]))
}

///|
pub fn write_index_entries_with_flags(
  fs : &@bit.FileSystem,
  git_dir : String,
  entries : Array[IndexEntry],
  skip_worktree_paths : Map[String, Bool],
  assume_unchanged_paths : Map[String, Bool],
  hash_size? : Int = 20,
) -> Unit raise @bit.GitError {
  let sorted = entries.copy()
  sorted.sort_by((a, b) => index_path_compare_git_order(a.path, b.path))
  let effective_hash_size = index_hash_size_for_entries(sorted, hash_size)
  let buf = write_index_buf(
    sorted,
    Some(skip_worktree_paths),
    Some(assume_unchanged_paths),
    hash_size=effective_hash_size,
  )
  let index_path = join_path(git_dir, "index")
  fs.write_file(index_path, Bytes::from_array(buf[:]))
}

///|
fn write_index_stage_buf(
  entries : Array[IndexStageEntry],
  hash_size? : Int = 20,
) -> FixedArray[Byte] {
  let mut total_size = 12
  let mut version = 2
  for item in entries {
    let has_extended = index_extended_flags(item.entry.intent_to_add, false) !=
      0
    if has_extended {
      version = 3
    }
    total_size += index_entry_buf_size(
      @utf8.encode(item.entry.path).length(),
      has_extended,
      hash_size~,
    )
  }
  total_size += hash_size
  let buf : FixedArray[Byte] = FixedArray::make(total_size, b'\x00')
  buf[0] = b'D'
  buf[1] = b'I'
  buf[2] = b'R'
  buf[3] = b'C'
  fa_set_u32_be(buf, 4, version)
  fa_set_u32_be(buf, 8, entries.length())
  let mut pos = 12
  for item in entries {
    pos = write_index_entry_to_buf(
      buf,
      pos,
      item.entry,
      item.stage,
      false,
      false,
      hash_size~,
    )
  }
  let content_bytes = Bytes::from_array(buf[:pos])
  let checksum = @bit.hash_prefix(content_bytes, pos, hash_size~)
  for i in 0..<hash_size {
    buf[pos + i] = checksum.bytes[i]
  }
  buf
}

///|
pub fn write_index_stage_entries(
  fs : &@bit.FileSystem,
  git_dir : String,
  entries : Array[IndexStageEntry],
  hash_size? : Int = 20,
) -> Unit raise @bit.GitError {
  let sorted = entries.copy()
  sorted.sort_by(fn(a, b) {
    let path_cmp = index_path_compare_git_order(a.entry.path, b.entry.path)
    if path_cmp != 0 {
      path_cmp
    } else {
      Int::compare(a.stage, b.stage)
    }
  })
  let effective_hash_size = index_hash_size_for_stage_entries(sorted, hash_size)
  let buf = write_index_stage_buf(sorted, hash_size=effective_hash_size)
  let index_path = join_path(git_dir, "index")
  fs.write_file(index_path, Bytes::from_array(buf[:]))
}

///|
fn index_read_object_id(
  data : Bytes,
  start : Int,
  hash_size? : Int = 20,
) -> @bit.ObjectId raise @bit.GitError {
  if start + hash_size > data.length() {
    raise @bit.GitError::InvalidObject("Unexpected end of index data")
  }
  let bytes : FixedArray[Byte] = FixedArray::make(hash_size, b'\x00')
  for i in 0..<hash_size {
    bytes[i] = data[start + i]
  }
  @bit.ObjectId::new(bytes)
}

///|
fn index_extended_flags(intent_to_add : Bool, skip_worktree : Bool) -> Int {
  let mut flags = 0
  if intent_to_add {
    flags = flags | 0x2000
  }
  if skip_worktree {
    flags = flags | 0x4000
  }
  flags
}

///|
fn index_ext_flags_has_intent_to_add(ext_flags : Int) -> Bool {
  (ext_flags & 0x2000) != 0
}

///|
fn fa_set_u32_be(buf : FixedArray[Byte], offset : Int, v : Int) -> Unit {
  buf[offset] = ((v >> 24) & 0xff).to_byte()
  buf[offset + 1] = ((v >> 16) & 0xff).to_byte()
  buf[offset + 2] = ((v >> 8) & 0xff).to_byte()
  buf[offset + 3] = (v & 0xff).to_byte()
}

///|
fn fa_set_u16_be(buf : FixedArray[Byte], offset : Int, v : Int) -> Unit {
  buf[offset] = ((v >> 8) & 0xff).to_byte()
  buf[offset + 1] = (v & 0xff).to_byte()
}

///|
fn index_path_compare_git_order(a : String, b : String) -> Int {
  let a_len = a.length()
  let b_len = b.length()
  let min_len = if a_len < b_len { a_len } else { b_len }
  for i in 0..<min_len {
    let av = a.unsafe_get(i)
    let bv = b.unsafe_get(i)
    if av < bv {
      return -1
    }
    if av > bv {
      return 1
    }
  }
  if a_len < b_len {
    -1
  } else if a_len > b_len {
    1
  } else {
    0
  }
}

///|
fn index_stage_priority(stage : Int) -> Int {
  if stage == 0 {
    4
  } else if stage == 2 {
    3
  } else if stage == 1 {
    2
  } else {
    1
  }
}

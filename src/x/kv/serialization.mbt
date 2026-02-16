///| Serialization for hot/cold storage transfer

///|

///| Hot layer: In-memory or Durable Objects (fast, limited capacity)

///| Cold layer: R2 or NativeFS (slow, unlimited capacity)

///|
/// Serialized snapshot for cold storage
pub(all) struct SerializedSnapshot {
  version : Int // format version
  node_id : String
  head : Bytes // 20 bytes SHA1
  clock : Array[(String, Int64)] // vector clock entries
  objects : Array[SerializedObject]
}

///|
/// Serialized git object
pub(all) struct SerializedObject {
  id : Bytes // 20 bytes SHA1
  obj_type : Int // 1=commit, 2=tree, 3=blob, 4=tag
  data : Bytes
}

///|
/// Controls how many git objects are included in a snapshot.
pub(all) enum SnapshotMode {
  /// Include full reachable history from HEAD (commit parents included).
  FullHistory
  /// Include HEAD commit and current tree/blob state only.
  HeadState
  /// Include tree/blob objects for current state only (no commit objects).
  TreeAndBlobOnly
}

///|
/// Serialize ObjectId to bytes - now uses direct byte access
fn object_id_to_bytes(id : @git.ObjectId) -> Bytes {
  id.to_bytes()
}

///|
/// Deserialize bytes to ObjectId - now uses direct byte access
fn _bytes_to_object_id(bytes : Bytes, offset : Int) -> @git.ObjectId {
  @git.ObjectId::from_bytes_at(bytes, offset)
}

///|
fn object_type_to_int(t : @git.ObjectType) -> Int {
  match t {
    Commit => 1
    Tree => 2
    Blob => 3
    Tag => 4
  }
}

///|
fn _int_to_object_type(n : Int) -> @git.ObjectType {
  match n {
    1 => @git.ObjectType::Commit
    2 => @git.ObjectType::Tree
    4 => @git.ObjectType::Tag
    _ => @git.ObjectType::Blob
  }
}

///|
fn snapshot_mode_to_int(mode : SnapshotMode) -> Int {
  match mode {
    FullHistory => 1
    HeadState => 2
    TreeAndBlobOnly => 3
  }
}

///|
fn snapshot_matches_state(db : Kv, snapshot : SerializedSnapshot) -> Bool {
  if snapshot.head != object_id_to_bytes(db.head) {
    return false
  }
  if snapshot.clock.length() != db.clock.clocks.length() {
    return false
  }
  for entry in snapshot.clock {
    let key = entry.0
    let value = entry.1
    if db.clock.clocks.get(key) != Some(value) {
      return false
    }
  }
  true
}

///|
fn Kv::serialize_snapshot_uncached(
  self : Kv,
  mode : SnapshotMode,
) -> SerializedSnapshot {
  // Collect clock entries
  let clock_entries : Array[(String, Int64)] = []
  for entry in self.clock.clocks {
    clock_entries.push((entry.0, entry.1))
  }
  // Collect reachable objects
  let objects : Array[SerializedObject] = []
  if self.head != @git.ObjectId::zero() {
    let store : &@lib.ObjectStore = self.store
    match mode {
      FullHistory =>
        collect_objects_for_serialization(
          store,
          self.head,
          objects,
          Set::new(),
          true,
        )
      HeadState =>
        collect_objects_for_serialization(
          store,
          self.head,
          objects,
          Set::new(),
          false,
        )
      TreeAndBlobOnly =>
        collect_tree_and_blob_objects_from_head(store, self.head, objects)
    }
  }
  {
    version: 1,
    node_id: self.node_id.id,
    head: object_id_to_bytes(self.head),
    clock: clock_entries,
    objects,
  }
}

///|
/// Create a serialized snapshot from Kv state.
/// Reuses cached value while the tree is clean and head/clock are unchanged.
pub fn Kv::serialize_snapshot(
  self : Kv,
  mode? : SnapshotMode = FullHistory,
) -> SerializedSnapshot {
  if self.is_dirty() {
    return self.serialize_snapshot_uncached(mode)
  }
  let mode_key = snapshot_mode_to_int(mode)
  match self.snapshot_cache.get(mode_key) {
    Some(cached) => if snapshot_matches_state(self, cached) { return cached }
    None => ()
  }
  let snapshot = self.serialize_snapshot_uncached(mode)
  self.snapshot_cache[mode_key] = snapshot
  if self.snapshot_bytes_cache.contains(mode_key) {
    self.snapshot_bytes_cache.remove(mode_key)
  }
  snapshot
}

///|
/// Serialize snapshot directly to bytes.
/// Reuses cached bytes while the tree is clean and head/clock are unchanged.
pub fn Kv::serialize_snapshot_bytes(
  self : Kv,
  mode? : SnapshotMode = FullHistory,
) -> Bytes {
  if self.is_dirty() {
    return self.serialize_snapshot_uncached(mode).to_bytes()
  }
  let mode_key = snapshot_mode_to_int(mode)
  let snapshot = self.serialize_snapshot(mode~)
  match self.snapshot_bytes_cache.get(mode_key) {
    Some(cached) => cached
    None => {
      let bytes = snapshot.to_bytes()
      self.snapshot_bytes_cache[mode_key] = bytes
      bytes
    }
  }
}

///|
fn collect_objects_for_serialization(
  store : &@lib.ObjectStore,
  id : @git.ObjectId,
  objects : Array[SerializedObject],
  visited : Set[@git.ObjectId],
  include_parents : Bool,
) -> Unit {
  if id == @git.ObjectId::zero() {
    return
  }
  if visited.contains(id) {
    return
  }
  visited.add(id)
  let obj = store.get(id) catch { _ => return }
  guard obj is Some(o) else { return }
  // Add this object
  objects.push({
    id: object_id_to_bytes(id),
    obj_type: object_type_to_int(o.obj_type),
    data: o.data,
  })
  // Recurse into children
  match o.obj_type {
    Commit => {
      let commit = @git.parse_commit(o.data) catch { _ => return }
      collect_objects_for_serialization(
        store,
        commit.tree,
        objects,
        visited,
        include_parents,
      )
      if include_parents {
        for parent in commit.parents {
          collect_objects_for_serialization(
            store, parent, objects, visited, include_parents,
          )
        }
      }
    }
    Tree => {
      let entries = @git.parse_tree(o.data) catch { _ => return }
      for entry in entries {
        collect_objects_for_serialization(
          store,
          entry.id,
          objects,
          visited,
          include_parents,
        )
      }
    }
    Blob | Tag => ()
  }
}

///|
fn collect_tree_and_blob_objects_from_head(
  store : &@lib.ObjectStore,
  head : @git.ObjectId,
  objects : Array[SerializedObject],
) -> Unit {
  let head_obj = store.get(head) catch { _ => return }
  guard head_obj is Some(obj) else { return }
  match obj.obj_type {
    Commit => {
      let commit = @git.parse_commit(obj.data) catch { _ => return }
      collect_tree_and_blob_objects(store, commit.tree, objects, Set::new())
    }
    Tree => collect_tree_and_blob_objects(store, head, objects, Set::new())
    Blob =>
      objects.push({
        id: object_id_to_bytes(head),
        obj_type: object_type_to_int(Blob),
        data: obj.data,
      })
    Tag => ()
  }
}

///|
fn collect_tree_and_blob_objects(
  store : &@lib.ObjectStore,
  id : @git.ObjectId,
  objects : Array[SerializedObject],
  visited : Set[@git.ObjectId],
) -> Unit {
  if id == @git.ObjectId::zero() {
    return
  }
  if visited.contains(id) {
    return
  }
  visited.add(id)
  let obj = store.get(id) catch { _ => return }
  guard obj is Some(o) else { return }
  match o.obj_type {
    Tree => {
      objects.push({
        id: object_id_to_bytes(id),
        obj_type: object_type_to_int(Tree),
        data: o.data,
      })
      let entries = @git.parse_tree(o.data) catch { _ => return }
      for entry in entries {
        collect_tree_and_blob_objects(store, entry.id, objects, visited)
      }
    }
    Blob =>
      objects.push({
        id: object_id_to_bytes(id),
        obj_type: object_type_to_int(Blob),
        data: o.data,
      })
    Commit | Tag => ()
  }
}

///|
/// Serialize snapshot to bytes (simple binary format)
/// Format:
///   4 bytes: version (little-endian)
///   4 bytes: node_id length
///   N bytes: node_id
///   20 bytes: head
///   4 bytes: clock entry count
///   For each clock entry:
///     4 bytes: key length
///     N bytes: key
///     8 bytes: value (little-endian)
///   4 bytes: object count
///   For each object:
///     20 bytes: id
///     1 byte: type
///     4 bytes: data length
///     N bytes: data
pub fn SerializedSnapshot::to_bytes(self : SerializedSnapshot) -> Bytes {
  let buf = @buffer.new(size_hint=self.byte_size())
  // Version
  buf.write_int_le(self.version)
  // Node ID
  buf_write_ascii_string(buf, self.node_id)
  // Head
  buf.write_bytes(self.head)
  // Clock entries
  buf.write_int_le(self.clock.length())
  for entry in self.clock {
    buf_write_ascii_string(buf, entry.0)
    buf.write_int64_le(entry.1)
  }
  // Objects
  buf.write_int_le(self.objects.length())
  for obj in self.objects {
    buf.write_bytes(obj.id)
    buf.write_byte(obj.obj_type.to_byte())
    buf.write_int_le(obj.data.length())
    buf.write_bytes(obj.data)
  }
  buf.to_bytes()
}

///|
/// Write UTF-8 string as length-prefixed bytes.
fn buf_write_ascii_string(buf : @buffer.Buffer, s : String) -> Unit {
  let bytes = @utf8.encode(s)
  buf.write_int_le(bytes.length())
  buf.write_bytes(bytes)
}

///|
/// Deserialize snapshot from bytes - optimized with slice operations
pub fn SerializedSnapshot::from_bytes(data : Bytes) -> SerializedSnapshot {
  let mut pos = 0
  // Version
  let version = read_u32_le(data, pos)
  pos += 4
  // Node ID
  let (node_id, new_pos) = read_string(data, pos)
  pos = new_pos
  // Head - use slice instead of loop copy
  let head = data[pos:pos + 20].to_bytes()
  pos += 20
  // Clock entries
  let clock_count = read_u32_le(data, pos)
  pos += 4
  let clock : Array[(String, Int64)] = []
  for _ in 0..<clock_count {
    let (key, new_pos2) = read_string(data, pos)
    pos = new_pos2
    let value = read_i64_le(data, pos)
    pos += 8
    clock.push((key, value))
  }
  // Objects
  let object_count = read_u32_le(data, pos)
  pos += 4
  let objects : Array[SerializedObject] = []
  for _ in 0..<object_count {
    // Use slice for id bytes
    let id = data[pos:pos + 20].to_bytes()
    pos += 20
    let obj_type = data[pos].to_int()
    pos += 1
    let data_len = read_u32_le(data, pos)
    pos += 4
    // Use slice for object data
    let obj_data = data[pos:pos + data_len].to_bytes()
    pos += data_len
    objects.push({ id, obj_type, data: obj_data })
  }
  { version, node_id, head, clock, objects }
}

///|
fn read_u32_le(data : Bytes, pos : Int) -> Int {
  data[pos].to_int() |
  (data[pos + 1].to_int() << 8) |
  (data[pos + 2].to_int() << 16) |
  (data[pos + 3].to_int() << 24)
}

///|
fn read_i64_le(data : Bytes, pos : Int) -> Int64 {
  let mut result = 0L
  for i in 0..<8 {
    result = result | (data[pos + i].to_int64() << (i * 8))
  }
  result
}

///|
fn read_string(data : Bytes, pos : Int) -> (String, Int) {
  let len = read_u32_le(data, pos)
  let view = data[pos + 4:pos + 4 + len]
  (@utf8.decode_lossy(view), pos + 4 + len)
}

///|
/// Calculate total serialized size
pub fn SerializedSnapshot::byte_size(self : SerializedSnapshot) -> Int {
  let mut size = 0
  size += 4 // version
  size += 4 + self.node_id.length() // node_id
  size += 20 // head
  size += 4 // clock count
  for entry in self.clock {
    size += 4 + entry.0.length() + 8 // key + value
  }
  size += 4 // object count
  for obj in self.objects {
    size += 20 + 1 + 4 + obj.data.length() // id + type + len + data
  }
  size
}

///|
/// Statistics about serialized data
pub(all) struct SerializationStats {
  total_bytes : Int
  object_count : Int
  commit_count : Int
  tree_count : Int
  blob_count : Int
  blob_bytes : Int
}

///|
pub fn SerializedSnapshot::stats(
  self : SerializedSnapshot,
) -> SerializationStats {
  let mut commits = 0
  let mut trees = 0
  let mut blobs = 0
  let mut blob_bytes = 0
  for obj in self.objects {
    match obj.obj_type {
      1 => commits += 1
      2 => trees += 1
      3 => {
        blobs += 1
        blob_bytes += obj.data.length()
      }
      _ => ()
    }
  }
  {
    total_bytes: self.byte_size(),
    object_count: self.objects.length(),
    commit_count: commits,
    tree_count: trees,
    blob_count: blobs,
    blob_bytes,
  }
}

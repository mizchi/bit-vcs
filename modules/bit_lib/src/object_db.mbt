///| Git object database loader (loose + pack + idx)

///|
#warnings("-deprecated")
fn object_db_parse_int(value : StringView) -> Int raise {
  @strconv.parse_int(value)
}

///|
pub struct PackIndex {
  pack_path : String
  // Raw, sorted object ids: exactly `id_count * hash_size` bytes, copied
  // verbatim from the pack `.idx`. Kept raw (not hex) so lookups binary-search
  // on bytes and parsing never hex-encodes every entry. Hex is materialized
  // lazily via `hex_ids`/`id_hex_at` only for the object-enumeration paths.
  id_bytes : Bytes
  hash_size : Int
  offsets : Array[Int64]
  version : Int
  mut hex_ids_cache : Array[String]?
  // Lazily-built offset -> entry-index map, so `find_id_by_offset` is O(1)
  // instead of scanning every offset on each delta-base resolution.
  mut offset_index_cache : Map[Int64, Int]?
  // Lazily-built ascending copy of `offsets`, so locating the next-higher
  // offset (an object's on-disk end) is a binary search instead of a full
  // linear scan of every entry.
  mut sorted_offsets_cache : Array[Int64]?
}

///|
/// Lazy pack index - loads index data on first access
pub struct LazyPackIndex {
  idx_path : String
  pack_path : String
  mut loaded : PackIndex?
}

///|
pub fn LazyPackIndex::new(
  idx_path : String,
  pack_path : String,
) -> LazyPackIndex {
  { idx_path, pack_path, loaded: None }
}

///|
pub fn LazyPackIndex::get(
  self : LazyPackIndex,
  fs : &@bit.RepoFileSystem,
) -> PackIndex raise @bit.GitError {
  match self.loaded {
    Some(idx) => idx
    None => {
      let data = fs.read_file(self.idx_path)
      let idx = parse_pack_index(data, self.pack_path)
      self.loaded = Some(idx)
      idx
    }
  }
}

///|
pub fn LazyPackIndex::find_offset(
  self : LazyPackIndex,
  fs : &@bit.RepoFileSystem,
  id : @bit.ObjectId,
) -> Int64? raise @bit.GitError {
  let idx = self.get(fs)
  idx.find_offset(id)
}

///|
pub fn LazyPackIndex::find_offset_hex(
  self : LazyPackIndex,
  fs : &@bit.RepoFileSystem,
  hex : String,
) -> Int64? raise @bit.GitError {
  let idx = self.get(fs)
  idx.find_offset_hex(hex)
}

///|
/// Number of objects indexed.
pub fn PackIndex::id_count(self : PackIndex) -> Int {
  self.offsets.length()
}

///|
/// Object id at position `i` (raw bytes → ObjectId, no hex roundtrip).
pub fn PackIndex::id_at(self : PackIndex, i : Int) -> @bit.ObjectId {
  @bit.ObjectId::from_bytes_at(
    self.id_bytes,
    i * self.hash_size,
    hash_size=self.hash_size,
  )
}

///|
/// Hex of the object id at position `i`.
pub fn PackIndex::id_hex_at(self : PackIndex, i : Int) -> String {
  self.id_at(i).to_hex()
}

///|
/// All object ids as hex, materialized lazily and cached. Only the object
/// enumeration paths (fsck, cat-file --batch-all-objects, pack-redundant,
/// commit-graph) need this; normal lookups binary-search on raw bytes and
/// never allocate hex.
pub fn PackIndex::hex_ids(self : PackIndex) -> Array[String] {
  match self.hex_ids_cache {
    Some(ids) => ids
    None => {
      let ids : Array[String] = []
      for i in 0..<self.id_count() {
        ids.push(self.id_hex_at(i))
      }
      self.hex_ids_cache = Some(ids)
      ids
    }
  }
}

///|
/// Compare the id at position `mid` against `target` (exactly `hash_size`
/// bytes), unsigned byte order — identical ordering to hex lexicographic
/// comparison, since hex is a monotonic per-byte encoding.
fn PackIndex::compare_id_at(self : PackIndex, mid : Int, target : Bytes) -> Int {
  let base = mid * self.hash_size
  for j in 0..<self.hash_size {
    let a = self.id_bytes[base + j].to_int()
    let b = target[j].to_int()
    if a != b {
      return a - b
    }
  }
  0
}

///|
fn PackIndex::find_offset_bytes(self : PackIndex, target : Bytes) -> Int64? {
  if target.length() != self.hash_size {
    return None
  }
  let mut lo = 0
  let mut hi = self.id_count()
  while lo < hi {
    let mid = (lo + hi) / 2
    let cmp = self.compare_id_at(mid, target)
    if cmp == 0 {
      return Some(self.offsets[mid])
    } else if cmp < 0 {
      lo = mid + 1
    } else {
      hi = mid
    }
  }
  None
}

///|
pub fn PackIndex::find_offset(self : PackIndex, id : @bit.ObjectId) -> Int64? {
  self.find_offset_bytes(id.to_bytes())
}

///|
pub fn PackIndex::find_offset_hex(self : PackIndex, hex : String) -> Int64? {
  if hex.length() != self.hash_size * 2 {
    return None
  }
  let id = @bit.ObjectId::from_hex(hex) catch { _ => return None }
  self.find_offset_bytes(id.to_bytes())
}

///|
/// Return (building lazily on first use) a map from pack offset to the
/// entry index at that offset. Pack offsets are unique, so the map is exact.
fn PackIndex::offset_index(self : PackIndex) -> Map[Int64, Int] {
  match self.offset_index_cache {
    Some(m) => m
    None => {
      let m : Map[Int64, Int] = Map([])
      for i in 0..<self.offsets.length() {
        m[self.offsets[i]] = i
      }
      self.offset_index_cache = Some(m)
      m
    }
  }
}

///|
/// Return (building lazily on first use) an ascending copy of the pack
/// offsets, for binary-searching the next-higher offset.
fn PackIndex::sorted_offsets(self : PackIndex) -> Array[Int64] {
  match self.sorted_offsets_cache {
    Some(a) => a
    None => {
      let a = self.offsets.copy()
      a.sort()
      self.sorted_offsets_cache = Some(a)
      a
    }
  }
}

///|
/// Smallest offset strictly greater than `offset`, or None if `offset` is
/// the last object in the pack. Binary search over the sorted offsets.
fn PackIndex::next_offset_after(self : PackIndex, offset : Int64) -> Int64? {
  let sorted = self.sorted_offsets()
  let mut lo = 0
  let mut hi = sorted.length()
  while lo < hi {
    let mid = lo + (hi - lo) / 2
    if sorted[mid] <= offset {
      lo = mid + 1
    } else {
      hi = mid
    }
  }
  if lo < sorted.length() {
    Some(sorted[lo])
  } else {
    None
  }
}

///|
/// Find object id (hex) by offset, via the lazily-built offset->index map.
pub fn PackIndex::find_id_by_offset(
  self : PackIndex,
  offset : Int64,
) -> String? {
  match self.offset_index().get(offset) {
    Some(i) => Some(self.id_hex_at(i))
    None => None
  }
}

///|
pub struct ObjectDb {
  objects_dir : String // base path for objects
  loose_paths : Map[String, String] // hex -> path (cache)
  packs : Array[PackIndex]
  lazy_packs : Array[LazyPackIndex] // lazily loaded pack indexes
  pack_cache : Map[String, Bytes]
  pack_cache_order : Array[String]
  pack_cache_limit : Int
  decoded_cache : Map[String, @bit.PackObject]
  decoded_cache_order : Array[String]
  mut decoded_cache_bytes : Int
  decoded_cache_limit : Int
  mut prefer_packed : Bool
  mut saw_corrupt_pack : Bool
  mut skip_verify : Bool
  mut commit_graph : CommitGraphFile?
}

///|
fn pack_cache_limit_from_env() -> Int {
  match @bitio.env_get("BIT_PACK_CACHE_LIMIT") {
    Some(v) =>
      try object_db_parse_int(v) catch {
        _ => 2
      } noraise {
        n => if n < 0 { 0 } else { n }
      }
    None => 2
  }
}

///|
/// Limit decoded packed-object cache memory. The cache is bounded by decoded
/// object bytes rather than entry count because a single large blob should not
/// crowd out many small delta bases.
fn decoded_cache_limit_from_env() -> Int {
  match @bitio.env_get("BIT_DECODED_OBJECT_CACHE_LIMIT") {
    Some(v) =>
      try object_db_parse_int(v) catch {
        _ => 4 * 1024 * 1024
      } noraise {
        n => if n < 0 { 0 } else { n }
      }
    None => 4 * 1024 * 1024
  }
}

///|
/// Hard cap on the inflated size of a single loose object. Mirrors
/// `pack.MAX_PACK_OBJECT_SIZE`. Unlike pack entries, loose objects
/// expose their size only *inside* the deflate stream, so the check
/// runs after `zlib_decompress` — this still bounds the downstream
/// damage even if the initial allocation completed.
const MAX_LOOSE_OBJECT_SIZE : Int = 0x7fff_ffff

///|
fn check_loose_object_size(bytes : Bytes) -> Unit raise @bit.GitError {
  if bytes.length() > MAX_LOOSE_OBJECT_SIZE {
    raise @bit.GitError::InvalidObject(
      "Loose object too large: \{bytes.length()} (max \{MAX_LOOSE_OBJECT_SIZE})",
    )
  }
}

///|
fn touch_pack_cache(db : ObjectDb, pack_path : String) -> Unit {
  if db.pack_cache_order.search(pack_path) is Some(idx) {
    ignore(db.pack_cache_order.remove(idx))
  }
  db.pack_cache_order.push(pack_path)
}

///|
fn evict_pack_cache(db : ObjectDb) -> Unit {
  if db.pack_cache_limit <= 0 {
    return
  }
  while db.pack_cache_order.length() > db.pack_cache_limit {
    let evict = db.pack_cache_order.remove(0)
    db.pack_cache.remove(evict)
  }
}

///|
/// Key an object by its immutable pack location, rather than object ID. This
/// lets OFS_DELTA bases be shared directly by all children that reference them.
fn decoded_cache_key(pack_path : String, offset : Int64) -> String {
  pack_path + "\u0000" + offset.to_string()
}

///|
fn decoded_cache_entry_size(obj : @bit.PackObject) -> Int {
  obj.data.length() + 128
}

///|
fn touch_decoded_cache(db : ObjectDb, key : String) -> Unit {
  if db.decoded_cache_order.search(key) is Some(idx) {
    ignore(db.decoded_cache_order.remove(idx))
  }
  db.decoded_cache_order.push(key)
}

///|
fn evict_decoded_cache(db : ObjectDb) -> Unit {
  while db.decoded_cache_bytes > db.decoded_cache_limit &&
        db.decoded_cache_order.length() > 0 {
    let evict = db.decoded_cache_order.remove(0)
    match db.decoded_cache.get(evict) {
      Some(obj) => {
        db.decoded_cache_bytes -= decoded_cache_entry_size(obj)
        db.decoded_cache.remove(evict)
      }
      None => ()
    }
  }
}

///|
fn get_decoded_cache(
  db : ObjectDb,
  pack_path : String,
  offset : Int64,
) -> @bit.PackObject? {
  let key = decoded_cache_key(pack_path, offset)
  match db.decoded_cache.get(key) {
    Some(obj) => {
      touch_decoded_cache(db, key)
      Some(obj)
    }
    None => None
  }
}

///|
fn put_decoded_cache(
  db : ObjectDb,
  pack_path : String,
  offset : Int64,
  obj : @bit.PackObject,
) -> Unit {
  if db.decoded_cache_limit <= 0 {
    return
  }
  let key = decoded_cache_key(pack_path, offset)
  match db.decoded_cache.get(key) {
    Some(previous) =>
      db.decoded_cache_bytes -= decoded_cache_entry_size(previous)
    None => ()
  }
  db.decoded_cache[key] = obj
  db.decoded_cache_bytes += decoded_cache_entry_size(obj)
  touch_decoded_cache(db, key)
  evict_decoded_cache(db)
}

///|
/// Resolve the git dir that owns object storage. A linked worktree's git dir
/// has no objects/ of its own; its "commondir" file points at the main
/// repository's git dir, which owns objects and the commit graph.
fn object_storage_git_dir(
  fs : &@bit.RepoFileSystem,
  git_dir : String,
) -> String {
  resolve_common_git_dir(fs, git_dir)
}

///|
/// Load ObjectDb with full loose object scan (slower but complete)
pub fn ObjectDb::load(
  fs : &@bit.RepoFileSystem,
  git_dir : String,
) -> ObjectDb raise @bit.GitError {
  let git_dir = object_storage_git_dir(fs, git_dir)
  let db = ObjectDb::load_from_objects_dir(fs, join_path(git_dir, "objects"))
  db.commit_graph = CommitGraphFile::load(fs, git_dir) catch { _ => None }
  db
}

///|
pub fn ObjectDb::load_from_objects_dir(
  fs : &@bit.RepoFileSystem,
  objects_dir : String,
) -> ObjectDb raise @bit.GitError {
  let loose_paths = if fs.is_dir(objects_dir) {
    collect_loose_paths(fs, objects_dir)
  } else {
    Map([])
  }
  let packs = if fs.is_dir(objects_dir) {
    let pack_dir = join_path(objects_dir, "pack")
    if fs.is_dir(pack_dir) {
      load_pack_indexes(fs, pack_dir)
    } else {
      []
    }
  } else {
    []
  }
  let pack_cache_limit = pack_cache_limit_from_env()
  let decoded_cache_limit = decoded_cache_limit_from_env()
  {
    objects_dir,
    loose_paths,
    packs,
    lazy_packs: [],
    pack_cache: Map([]),
    pack_cache_order: [],
    pack_cache_limit,
    decoded_cache: Map([]),
    decoded_cache_order: [],
    decoded_cache_bytes: 0,
    decoded_cache_limit,
    prefer_packed: false,
    saw_corrupt_pack: false,
    skip_verify: false,
    commit_graph: None,
  }
}

///|
/// Load ObjectDb lazily - don't scan loose objects or load pack indexes upfront
pub fn ObjectDb::load_lazy(
  fs : &@bit.RepoFileSystem,
  git_dir : String,
) -> ObjectDb raise @bit.GitError {
  let git_dir = object_storage_git_dir(fs, git_dir)
  let db = ObjectDb::load_lazy_from_objects_dir(
    fs,
    join_path(git_dir, "objects"),
  )
  db.commit_graph = CommitGraphFile::load(fs, git_dir) catch { _ => None }
  db
}

///|
pub fn ObjectDb::load_lazy_from_objects_dir(
  fs : &@bit.RepoFileSystem,
  objects_dir : String,
) -> ObjectDb raise @bit.GitError {
  let lazy_packs = if fs.is_dir(objects_dir) {
    let pack_dir = join_path(objects_dir, "pack")
    if fs.is_dir(pack_dir) {
      collect_lazy_pack_indexes(fs, pack_dir)
    } else {
      []
    }
  } else {
    []
  }
  let pack_cache_limit = pack_cache_limit_from_env()
  let decoded_cache_limit = decoded_cache_limit_from_env()
  {
    objects_dir,
    loose_paths: Map([]),
    packs: [],
    lazy_packs,
    pack_cache: Map([]),
    pack_cache_order: [],
    pack_cache_limit,
    decoded_cache: Map([]),
    decoded_cache_order: [],
    decoded_cache_bytes: 0,
    decoded_cache_limit,
    prefer_packed: false,
    saw_corrupt_pack: false,
    skip_verify: false,
    commit_graph: None,
  }
}

///|

///|
pub fn ObjectDb::set_prefer_packed(self : ObjectDb, value : Bool) -> Unit {
  self.prefer_packed = value
}

///|
pub fn ObjectDb::set_skip_verify(self : ObjectDb, value : Bool) -> Unit {
  self.skip_verify = value
}

///|
pub fn ObjectDb::disable_commit_graph(self : ObjectDb) -> Unit {
  self.commit_graph = None
}

///|
pub fn ObjectDb::enable_commit_graph(
  self : ObjectDb,
  rfs : &@bit.RepoFileSystem,
  git_dir : String,
) -> Unit {
  if self.commit_graph is Some(_) {
    return
  }
  self.commit_graph = CommitGraphFile::load(rfs, git_dir) catch { _ => None }
}

///|
pub fn ObjectDb::get(
  self : ObjectDb,
  fs : &@bit.RepoFileSystem,
  id : @bit.ObjectId,
) -> @bit.PackObject? raise @bit.GitError {
  let hex = id.to_hex()
  // Fast path: try loose object first without allocating seen set
  if !self.prefer_packed {
    match get_loose_by_hex(self, fs, hex) {
      Some(obj) => return Some(obj)
      None => ()
    }
  }
  let seen : Map[String, Bool] = Map([])
  seen[hex] = true
  // prefer_packed: try packs first, then loose (already tried above if !prefer_packed)
  if self.prefer_packed {
    match get_from_packs(self, fs, hex, seen) {
      Some(obj) => return Some(obj)
      None => ()
    }
    match get_loose_by_hex(self, fs, hex) {
      Some(obj) => return Some(obj)
      None => ()
    }
  } else {
    // !prefer_packed: loose already tried, now try packs
    match get_from_packs(self, fs, hex, seen) {
      Some(obj) => return Some(obj)
      None => ()
    }
  }
  // Fallback: try commit-graph for missing commit objects
  get_from_commit_graph(self, id)
}

///|
pub fn ObjectDb::get_commit_graph_commit(
  self : ObjectDb,
  id : @bit.ObjectId,
) -> CommitGraphCommitInfo? {
  match self.commit_graph {
    Some(graph) => {
      let pos = graph.find_commit(id)
      if pos >= 0 {
        Some(graph.read_commit_info(pos))
      } else {
        None
      }
    }
    None => None
  }
}

///|
fn get_from_commit_graph(db : ObjectDb, id : @bit.ObjectId) -> @bit.PackObject? {
  match db.commit_graph {
    Some(graph) => {
      let pos = graph.find_commit(id)
      if pos >= 0 {
        Some(graph.synthesize_commit_object(pos, id))
      } else {
        None
      }
    }
    None => None
  }
}

///|
/// Return delta base object id if the selected packed object is DELTA.
/// Returns None for loose objects or non-delta packed objects.
pub fn ObjectDb::find_delta_base(
  self : ObjectDb,
  fs : &@bit.RepoFileSystem,
  id : @bit.ObjectId,
) -> @bit.ObjectId? raise @bit.GitError {
  let hex = id.to_hex()
  if !self.prefer_packed {
    if get_loose_by_hex(self, fs, hex) is Some(_) {
      return None
    }
  }
  find_delta_base_from_packs(self, fs, hex)
}

///|
/// Return object size on disk.
/// - loose object: compressed loose file size
/// - packed object: packed entry byte length
pub fn ObjectDb::find_object_disk_size(
  self : ObjectDb,
  fs : &@bit.RepoFileSystem,
  id : @bit.ObjectId,
) -> Int? raise @bit.GitError {
  let hex = id.to_hex()
  match find_loose_path_by_hex(self, fs, hex) {
    Some(path) => Some(fs.read_file(path).length())
    None => find_pack_object_disk_size_by_hex(self, fs, hex)
  }
}

///|
fn find_loose_path_by_hex(
  db : ObjectDb,
  fs : &@bit.RepoFileSystem,
  hex : String,
) -> String? {
  match db.loose_paths.get(hex) {
    Some(path) => Some(path)
    None =>
      if hex.length() == 40 || hex.length() == 64 {
        let prefix = String::unsafe_substring(hex, start=0, end=2)
        let suffix = String::unsafe_substring(hex, start=2, end=hex.length())
        let path = db.objects_dir + "/" + prefix + "/" + suffix
        if fs.is_file(path) {
          db.loose_paths[hex] = path
          Some(path)
        } else {
          None
        }
      } else {
        None
      }
  }
}

///|
fn find_pack_object_disk_size_by_hex(
  db : ObjectDb,
  fs : &@bit.RepoFileSystem,
  hex : String,
) -> Int? raise @bit.GitError {
  for pack in db.packs {
    let offset = PackIndex::find_offset_hex(pack, hex)
    if offset is Some(found) {
      return pack_object_disk_size_at(db, fs, pack, found)
    }
  }
  for lazy_pack in db.lazy_packs {
    let pack = lazy_pack.get(fs)
    let offset = PackIndex::find_offset_hex(pack, hex)
    if offset is Some(found) {
      return pack_object_disk_size_at(db, fs, pack, found)
    }
  }
  None
}

///|
fn pack_object_disk_size_at(
  db : ObjectDb,
  fs : &@bit.RepoFileSystem,
  pack : PackIndex,
  offset : Int64,
) -> Int? raise @bit.GitError {
  let data = get_pack_bytes(db, fs, pack.pack_path)
  if data.length() <= 32 {
    return None
  }
  let next_offset = pack.next_offset_after(offset)
  let end_offset = match next_offset {
    Some(found) => found
    None => (data.length() - 20).to_int64() // TODO: use hash_size for SHA-256 packs
  }
  if end_offset < offset {
    return None
  }
  let size64 = end_offset - offset
  if size64 < 0L || size64 > 2147483647L {
    return None
  }
  Some(size64.to_int())
}

///|
/// Fast loose-object lookup without seen set allocation.
fn get_loose_by_hex(
  db : ObjectDb,
  fs : &@bit.RepoFileSystem,
  hex : String,
) -> @bit.PackObject? raise @bit.GitError {
  let loose_path = match db.loose_paths.get(hex) {
    Some(path) => Some(path)
    None =>
      if hex.length() == 40 || hex.length() == 64 {
        let prefix = String::unsafe_substring(hex, start=0, end=2)
        let suffix = String::unsafe_substring(hex, start=2, end=hex.length())
        let path = db.objects_dir + "/" + prefix + "/" + suffix
        if fs.is_file(path) {
          db.loose_paths[hex] = path
          Some(path)
        } else {
          None
        }
      } else {
        None
      }
  }
  match loose_path {
    Some(path) => {
      let compressed = fs.read_file(path)
      let raw = @zlib.zlib_decompress(
        compressed,
        max_size=MAX_LOOSE_OBJECT_SIZE,
      ) catch {
        e => raise @bit.GitError::InvalidObject("Zlib error: \{e}")
      }
      check_loose_object_size(raw)
      let obj = parse_loose_object(raw)
      if !db.skip_verify {
        let verify_algo : @object.HashAlgorithm = if hex.length() == 64 {
          @object.HashAlgorithm::Sha256
        } else {
          @object.HashAlgorithm::Sha1
        }
        let computed = @object.hash_object_content_with_algo(
          verify_algo,
          obj.obj_type,
          obj.data,
        ).to_hex()
        if computed != hex {
          raise @bit.GitError::HashMismatch(computed, hex)
        }
      }
      Some(obj)
    }
    None => None
  }
}

///|
fn get_pack_bytes(
  db : ObjectDb,
  fs : &@bit.RepoFileSystem,
  pack_path : String,
) -> Bytes raise @bit.GitError {
  if db.pack_cache_limit == 0 {
    return fs.read_file(pack_path)
  }
  match db.pack_cache.get(pack_path) {
    Some(data) => {
      touch_pack_cache(db, pack_path)
      data
    }
    None => {
      let data = fs.read_file(pack_path)
      db.pack_cache[pack_path] = data
      touch_pack_cache(db, pack_path)
      evict_pack_cache(db)
      data
    }
  }
}

///|
/// Return a decoded packed object from the location cache when possible.
/// Looking here, before reading the pack bytes, also makes repeated top-level
/// ObjectDb::get calls avoid the pack-file cache entirely.
fn get_cached_or_read_pack_object(
  db : ObjectDb,
  fs : &@bit.RepoFileSystem,
  pack : PackIndex,
  offset : Int64,
  seen : Map[String, Bool],
) -> @bit.PackObject raise @bit.GitError {
  match get_decoded_cache(db, pack.pack_path, offset) {
    Some(obj) => obj
    None => {
      let data = get_pack_bytes(db, fs, pack.pack_path)
      read_pack_object_at(data, pack, offset, db, fs, seen)
    }
  }
}

///|
fn get_from_packs(
  db : ObjectDb,
  fs : &@bit.RepoFileSystem,
  hex : String,
  seen : Map[String, Bool],
) -> @bit.PackObject? raise @bit.GitError {
  let mut last_error : @bit.GitError? = None
  // Try pack files (eagerly loaded)
  for pack in db.packs {
    match PackIndex::find_offset_hex(pack, hex) {
      None => ()
      Some(offset) =>
        try {
          let obj = get_cached_or_read_pack_object(db, fs, pack, offset, seen)
          if !db.skip_verify {
            let computed = obj.id.to_hex()
            if computed != hex {
              if pack.version == 1 {
                db.saw_corrupt_pack = true
                return Some(obj)
              }
              raise @bit.GitError::HashMismatch(computed, hex)
            }
          }
          return Some(obj)
        } catch {
          e => last_error = Some(e)
        }
    }
  }
  // Try lazy pack files (loaded on first access)
  for lazy_pack in db.lazy_packs {
    try {
      match lazy_pack.find_offset_hex(fs, hex) {
        None => ()
        Some(offset) => {
          let pack = lazy_pack.get(fs) // ensure loaded
          let obj = get_cached_or_read_pack_object(db, fs, pack, offset, seen)
          if !db.skip_verify {
            let computed = obj.id.to_hex()
            if computed != hex {
              if pack.version == 1 {
                db.saw_corrupt_pack = true
                return Some(obj)
              }
              raise @bit.GitError::HashMismatch(computed, hex)
            }
          }
          return Some(obj)
        }
      }
    } catch {
      e => last_error = Some(e)
    }
  }
  match last_error {
    Some(e) => raise e
    None => None
  }
}

///|
fn find_delta_base_from_packs(
  db : ObjectDb,
  fs : &@bit.RepoFileSystem,
  hex : String,
) -> @bit.ObjectId? {
  for pack in db.packs {
    match PackIndex::find_offset_hex(pack, hex) {
      Some(offset) =>
        try {
          let data = get_pack_bytes(db, fs, pack.pack_path)
          return read_pack_delta_base_at(data, pack, offset)
        } catch {
          _ => ()
        }
      None => ()
    }
  }
  for lazy_pack in db.lazy_packs {
    try {
      match lazy_pack.find_offset_hex(fs, hex) {
        Some(offset) => {
          let pack = lazy_pack.get(fs)
          let data = get_pack_bytes(db, fs, pack.pack_path)
          return read_pack_delta_base_at(data, pack, offset)
        }
        None => ()
      }
    } catch {
      _ => ()
    }
  }
  None
}

///|
fn read_pack_delta_base_at(
  data : Bytes,
  pack : PackIndex,
  offset : Int64,
) -> @bit.ObjectId? raise @bit.GitError {
  let offset_i = offset_to_int(offset)
  let (type_id, _, next_offset) = @pack.decode_type_and_size_at(data, offset_i)
  match type_id {
    6 => {
      let (back_offset, _) = @pack.read_ofs_delta_offset(data, next_offset)
      let base_offset = offset_i - back_offset
      if base_offset < 0 {
        return None
      }
      match PackIndex::find_id_by_offset(pack, base_offset.to_int64()) {
        Some(base_hex) => Some(@bit.ObjectId::from_hex(base_hex))
        None => None
      }
    }
    7 => {
      let (base_hex, _) = @pack.read_ref_delta_id(data, next_offset)
      Some(@bit.ObjectId::from_hex(base_hex))
    }
    _ => None
  }
}

///|
fn get_by_hex(
  db : ObjectDb,
  fs : &@bit.RepoFileSystem,
  hex : String,
  seen : Map[String, Bool],
) -> @bit.PackObject? raise @bit.GitError {
  if seen.contains(hex) {
    raise @bit.GitError::InvalidObject("Delta cycle detected: \{hex}")
  }
  seen[hex] = true
  if db.prefer_packed {
    match get_from_packs(db, fs, hex, seen) {
      Some(obj) => return Some(obj)
      None => ()
    }
  }
  // Try to load from loose objects - first check cache, then try direct path
  let loose_path = match db.loose_paths.get(hex) {
    Some(path) => Some(path)
    None =>
      // Try constructing path directly (lazy loading)
      if hex.length() == 40 || hex.length() == 64 {
        let prefix = String::unsafe_substring(hex, start=0, end=2)
        let suffix = String::unsafe_substring(hex, start=2, end=hex.length())
        let path = db.objects_dir + "/" + prefix + "/" + suffix
        if fs.is_file(path) {
          db.loose_paths[hex] = path // cache for future lookups
          Some(path)
        } else {
          None
        }
      } else {
        None
      }
  }
  match loose_path {
    Some(path) => {
      let compressed = fs.read_file(path)
      let raw = @zlib.zlib_decompress(
        compressed,
        max_size=MAX_LOOSE_OBJECT_SIZE,
      ) catch {
        e => raise @bit.GitError::InvalidObject("Zlib error: \{e}")
      }
      check_loose_object_size(raw)
      let obj = parse_loose_object(raw)
      if !db.skip_verify {
        let verify_algo : @object.HashAlgorithm = if hex.length() == 64 {
          @object.HashAlgorithm::Sha256
        } else {
          @object.HashAlgorithm::Sha1
        }
        let computed = @object.hash_object_content_with_algo(
          verify_algo,
          obj.obj_type,
          obj.data,
        ).to_hex()
        if computed != hex {
          raise @bit.GitError::HashMismatch(computed, hex)
        }
      }
      return Some(obj)
    }
    None => ()
  }
  if !db.prefer_packed {
    return get_from_packs(db, fs, hex, seen)
  }
  None
}

///|
pub fn load_object_store_from_fs(
  fs : &@bit.RepoFileSystem,
  git_dir : String,
) -> @bit.ObjectStore raise @bit.GitError {
  let store = @bit.ObjectStore::new()
  let objects_dir = join_path(git_dir, "objects")
  if fs.is_dir(objects_dir) {
    let loose = load_loose_objects(fs, objects_dir)
    if loose.length() > 0 {
      store.add_objects(loose)
    }
    let pack_dir = join_path(objects_dir, "pack")
    if fs.is_dir(pack_dir) {
      let packed = load_pack_objects(fs, pack_dir)
      if packed.length() > 0 {
        store.add_objects(packed)
      }
    }
  }
  store
}

///|
pub fn load_all_objects_from_fs(
  fs : &@bit.RepoFileSystem,
  git_dir : String,
) -> Array[@bit.PackObject] raise @bit.GitError {
  load_all_objects_from_object_dir(fs, join_path(git_dir, "objects"))
}

///|
pub fn load_all_objects_from_object_dir(
  fs : &@bit.RepoFileSystem,
  objects_dir : String,
) -> Array[@bit.PackObject] raise @bit.GitError {
  let result : Array[@bit.PackObject] = []
  if fs.is_dir(objects_dir) {
    let loose = load_loose_objects(fs, objects_dir)
    for obj in loose {
      result.push(obj)
    }
    let pack_dir = join_path(objects_dir, "pack")
    if fs.is_dir(pack_dir) {
      let packed = load_pack_objects(fs, pack_dir)
      for obj in packed {
        result.push(obj)
      }
    }
  }
  result
}

///|
/// Collect paths to loose objects without loading content (lazy loading)
fn collect_loose_paths(
  fs : &@bit.RepoFileSystem,
  objects_dir : String,
) -> Map[String, String] raise @bit.GitError {
  let result : Map[String, String] = Map([])
  let entries = fs.readdir(objects_dir)
  for entry in entries {
    if entry.length() != 2 {
      continue
    }
    let dir = join_path(objects_dir, entry)
    if !fs.is_dir(dir) {
      continue
    }
    let files = fs.readdir(dir)
    for name in files {
      if name.length() != 38 {
        continue
      }
      let path = join_path(dir, name)
      if !fs.is_file(path) {
        continue
      }
      let hex = entry + name
      result[hex] = path
    }
  }
  result
}

///|
fn load_loose_objects(
  fs : &@bit.RepoFileSystem,
  objects_dir : String,
) -> Array[@bit.PackObject] raise @bit.GitError {
  let result : Array[@bit.PackObject] = []
  let paths = collect_loose_paths(fs, objects_dir)
  for path in paths.values() {
    let compressed = fs.read_file(path)
    let raw = @zlib.zlib_decompress(compressed, max_size=MAX_LOOSE_OBJECT_SIZE) catch {
      e => raise @bit.GitError::InvalidObject("Zlib error: \{e}")
    }
    let obj = parse_loose_object(raw)
    result.push(obj)
  }
  result
}

///|
fn load_pack_indexes(
  fs : &@bit.RepoFileSystem,
  pack_dir : String,
) -> Array[PackIndex] raise @bit.GitError {
  let result : Array[PackIndex] = []
  let entries = fs.readdir(pack_dir)
  for entry in entries {
    if !entry.has_suffix(".idx") {
      continue
    }
    let idx_path = join_path(pack_dir, entry)
    if !fs.is_file(idx_path) {
      continue
    }
    let base = String::unsafe_substring(entry, start=0, end=entry.length() - 4)
    let pack_path = join_path(pack_dir, base + ".pack")
    if !fs.is_file(pack_path) {
      continue
    }
    let data = fs.read_file(idx_path)
    let idx = parse_pack_index(data, pack_path)
    result.push(idx)
  }
  result
}

///|
/// Collect pack index paths without loading them (for lazy loading)
fn collect_lazy_pack_indexes(
  fs : &@bit.RepoFileSystem,
  pack_dir : String,
) -> Array[LazyPackIndex] raise @bit.GitError {
  let result : Array[LazyPackIndex] = []
  let entries = fs.readdir(pack_dir)
  for entry in entries {
    if !entry.has_suffix(".idx") {
      continue
    }
    let idx_path = join_path(pack_dir, entry)
    if !fs.is_file(idx_path) {
      continue
    }
    let base = String::unsafe_substring(entry, start=0, end=entry.length() - 4)
    let pack_path = join_path(pack_dir, base + ".pack")
    if !fs.is_file(pack_path) {
      continue
    }
    result.push(LazyPackIndex::new(idx_path, pack_path))
  }
  result
}

///|
fn load_pack_objects(
  fs : &@bit.RepoFileSystem,
  pack_dir : String,
) -> Array[@bit.PackObject] raise @bit.GitError {
  let result : Array[@bit.PackObject] = []
  let entries = fs.readdir(pack_dir)
  for entry in entries {
    if !entry.has_suffix(".pack") {
      continue
    }
    let path = join_path(pack_dir, entry)
    if !fs.is_file(path) {
      continue
    }
    let data = fs.read_file(path)
    let objects = @pack.parse_packfile(data)
    for obj in objects {
      result.push(obj)
    }
  }
  result
}

///|

///|
/// Parse v1 pack index (no magic header).
fn parse_pack_index_v1(
  data : Bytes,
  pack_path : String,
  hash_size? : Int = 20,
) -> PackIndex raise @bit.GitError {
  if data.length() < 256 * 4 {
    raise @bit.GitError::InvalidObject("Index file too short")
  }
  let mut offset = 0
  let fanout : Array[Int64] = []
  for _ in 0..<256 {
    fanout.push(read_u32_be_at64(data, offset))
    offset += 4
  }
  let count64 = fanout[255]
  if count64 > 2147483647L {
    raise @bit.GitError::InvalidObject("Too many objects in index")
  }
  let count = count64.to_int()
  let entries_start = offset
  let entry_size = 4 + hash_size
  let expected_len = entries_start + count * entry_size + hash_size
  if data.length() < expected_len {
    raise @bit.GitError::InvalidObject("Index file truncated (v1)")
  }
  let offsets : Array[Int64] = []
  // Gather the interleaved (offset, id) entries: raw ids into one contiguous
  // buffer, no per-entry hex encoding.
  let id_arr : FixedArray[Byte] = FixedArray::make(count * hash_size, b'\x00')
  for i in 0..<count {
    let base = entries_start + i * entry_size
    offsets.push(read_u32_be_at64(data, base))
    let id_base = i * hash_size
    for j in 0..<hash_size {
      id_arr[id_base + j] = data[base + 4 + j]
    }
  }
  {
    pack_path,
    id_bytes: Bytes::from_array(id_arr),
    hash_size,
    offsets,
    version: 1,
    hex_ids_cache: None,
    offset_index_cache: None,
    sorted_offsets_cache: None,
  }
}

///|
fn parse_pack_index(
  data : Bytes,
  pack_path : String,
  hash_size? : Int = 20,
) -> PackIndex raise @bit.GitError {
  if data.length() < 8 {
    raise @bit.GitError::InvalidObject("Index file too short")
  }
  let magic = read_u32_be_at64(data, 0)
  if magic != 0xff744f63L {
    return parse_pack_index_v1(data, pack_path, hash_size~)
  }
  let version = read_u32_be_at64(data, 4)
  if version != 2L {
    raise @bit.GitError::InvalidObject(
      "Unsupported pack index version: \{version}",
    )
  }
  let mut offset = 8
  let fanout : Array[Int64] = []
  for _ in 0..<256 {
    fanout.push(read_u32_be_at64(data, offset))
    offset += 4
  }
  let count64 = fanout[255]
  if count64 > 2147483647L {
    raise @bit.GitError::InvalidObject("Too many objects in index")
  }
  let count = count64.to_int()
  // The v2 id table is `count * hash_size` contiguous bytes; copy it whole
  // instead of hex-encoding each entry.
  let id_byte_len = count * hash_size
  if offset + id_byte_len > data.length() {
    raise @bit.GitError::InvalidObject("Index file truncated (ids)")
  }
  let ids_start = offset
  let id_bytes = Bytes::from_array(
    FixedArray::makei(id_byte_len, j => data[ids_start + j]),
  )
  offset += id_byte_len
  // Skip CRC32 table
  offset += count * 4
  if offset + count * 4 > data.length() {
    raise @bit.GitError::InvalidObject("Index file truncated (offsets)")
  }
  let offsets : Array[Int64] = []
  let large_indices : Array[Int] = []
  for i in 0..<count {
    let v = read_u32_be_at64(data, offset)
    offset += 4
    if (v & 0x80000000L) != 0L {
      offsets.push(v & 0x7fffffffL)
      large_indices.push(i)
    } else {
      offsets.push(v)
    }
  }
  if large_indices.length() > 0 {
    let mut large_idx = 0
    while large_idx < large_indices.length() {
      if offset + 8 > data.length() {
        raise @bit.GitError::InvalidObject(
          "Index file truncated (large offsets)",
        )
      }
      let v = read_u64_be_at64(data, offset)
      offset += 8
      let pos = large_indices[large_idx]
      offsets[pos] = v
      large_idx += 1
    }
  }
  {
    pack_path,
    id_bytes,
    hash_size,
    offsets,
    version: 2,
    hex_ids_cache: None,
    offset_index_cache: None,
    sorted_offsets_cache: None,
  }
}

///|
fn read_pack_object_at(
  data : Bytes,
  pack : PackIndex,
  offset : Int64,
  db : ObjectDb,
  fs : &@bit.RepoFileSystem,
  seen : Map[String, Bool],
) -> @bit.PackObject raise @bit.GitError {
  match get_decoded_cache(db, pack.pack_path, offset) {
    Some(obj) => return obj
    None => ()
  }
  let offset_i = offset_to_int(offset)
  let (type_id, size, next_offset) = @pack.decode_type_and_size_at(
    data, offset_i,
  )
  if size < 0 || size > MAX_LOOSE_OBJECT_SIZE {
    raise @bit.GitError::PackfileError("Pack object size out of range: \{size}")
  }
  let obj = match type_id {
    1 | 2 | 3 | 4 => {
      let obj_type = @pack.packfile_type_to_object_type(type_id)
      let (content, _after) = @zlib.zlib_decompress_at(
        data,
        next_offset,
        max_size=size,
      ) catch {
        e => raise @bit.GitError::PackfileError("Zlib error: \{e}")
      }
      if content.length() != size {
        raise @bit.GitError::PackfileError(
          "Object size mismatch: expected=\{size}, got=\{content.length()}",
        )
      }
      let id = @bit.hash_object_content(obj_type, content)
      @bit.PackObject::with_metadata(obj_type, content, id, offset_i, 0U)
    }
    6 => {
      let (back_offset, after_ref) = @pack.read_ofs_delta_offset(
        data, next_offset,
      )
      let base_offset = offset_i - back_offset
      if base_offset < 0 {
        raise @bit.GitError::PackfileError("Invalid OFS_DELTA base offset")
      }
      let (delta, _after) = @zlib.zlib_decompress_at(
        data,
        after_ref,
        max_size=size,
      ) catch {
        e => raise @bit.GitError::PackfileError("Zlib error: \{e}")
      }
      if delta.length() != size {
        raise @bit.GitError::PackfileError(
          "Delta size mismatch: expected=\{size}, got=\{delta.length()}",
        )
      }
      let base = read_pack_object_at(
        data,
        pack,
        base_offset.to_int64(),
        db,
        fs,
        seen,
      ) catch {
        e =>
          match PackIndex::find_id_by_offset(pack, base_offset.to_int64()) {
            Some(base_hex) =>
              match get_by_hex(db, fs, base_hex, seen) {
                Some(obj) => obj
                None => raise e
              }
            None => raise e
          }
      }
      let content = @pack.apply_delta(base.data, delta)
      let id = @bit.hash_object_content(base.obj_type, content)
      @bit.PackObject::with_metadata(base.obj_type, content, id, offset_i, 0U)
    }
    7 => {
      let (base_hex, after_ref) = @pack.read_ref_delta_id(data, next_offset)
      let (delta, _after) = @zlib.zlib_decompress_at(
        data,
        after_ref,
        max_size=size,
      ) catch {
        e => raise @bit.GitError::PackfileError("Zlib error: \{e}")
      }
      if delta.length() != size {
        raise @bit.GitError::PackfileError(
          "Delta size mismatch: expected=\{size}, got=\{delta.length()}",
        )
      }
      let base = match PackIndex::find_offset_hex(pack, base_hex) {
        Some(base_offset) =>
          read_pack_object_at(data, pack, base_offset, db, fs, seen) catch {
            _ =>
              match get_by_hex(db, fs, base_hex, seen) {
                Some(obj) => obj
                None =>
                  raise @bit.GitError::PackfileError(
                    "Missing base object for REF_DELTA",
                  )
              }
          }
        None =>
          match get_by_hex(db, fs, base_hex, seen) {
            Some(obj) => obj
            None =>
              raise @bit.GitError::PackfileError(
                "Missing base object for REF_DELTA",
              )
          }
      }
      let content = @pack.apply_delta(base.data, delta)
      let id = @bit.hash_object_content(base.obj_type, content)
      @bit.PackObject::with_metadata(base.obj_type, content, id, offset_i, 0U)
    }
    _ =>
      raise @bit.GitError::PackfileError(
        "Unknown packfile object type: \{type_id}",
      )
  }
  put_decoded_cache(db, pack.pack_path, offset, obj)
  obj
}

///|
fn parse_loose_object(data : Bytes) -> @bit.PackObject raise @bit.GitError {
  let len = data.length()
  if len == 0 {
    raise @bit.GitError::InvalidObject("Empty loose object")
  }
  let type_buf = StringBuilder::new()
  let mut i = 0
  while i < len && data[i] != b' ' {
    type_buf.write_char(data[i].to_int().unsafe_to_char())
    i += 1
  }
  if i >= len || data[i] != b' ' {
    raise @bit.GitError::InvalidObject("Invalid loose object header")
  }
  i += 1
  let mut size = 0
  while i < len && data[i] != b'\x00' {
    let b = data[i]
    if b < b'0' || b > b'9' {
      raise @bit.GitError::InvalidObject("Invalid loose object size")
    }
    size = size * 10 + (b.to_int() - b'0'.to_int())
    i += 1
  }
  if i >= len || data[i] != b'\x00' {
    raise @bit.GitError::InvalidObject("Invalid loose object header")
  }
  i += 1
  let content_len = len - i
  if content_len != size {
    raise @bit.GitError::InvalidObject(
      "Loose object size mismatch: expected=\{size}, got=\{content_len}",
    )
  }
  let content = Bytes::from_array(
    FixedArray::makei(content_len, j => data[i + j]),
  )
  let obj_type = object_type_from_string(type_buf.to_string())
  @bit.PackObject::new(obj_type, content)
}

///|
fn object_type_from_string(s : String) -> @bit.ObjectType raise @bit.GitError {
  if s == "blob" {
    @bit.ObjectType::Blob
  } else if s == "tree" {
    @bit.ObjectType::Tree
  } else if s == "commit" {
    @bit.ObjectType::Commit
  } else if s == "tag" {
    @bit.ObjectType::Tag
  } else {
    raise @bit.GitError::InvalidObject("Unknown object type: \{s}")
  }
}

///|
fn read_u32_be_at64(data : Bytes, start : Int) -> Int64 raise @bit.GitError {
  if start + 4 > data.length() {
    raise @bit.GitError::InvalidObject("Unexpected end of index data")
  }
  let b0 = data[start].to_int64()
  let b1 = data[start + 1].to_int64()
  let b2 = data[start + 2].to_int64()
  let b3 = data[start + 3].to_int64()
  (b0 << 24) | (b1 << 16) | (b2 << 8) | b3
}

///|
fn read_u64_be_at64(data : Bytes, start : Int) -> Int64 raise @bit.GitError {
  if start + 8 > data.length() {
    raise @bit.GitError::InvalidObject("Unexpected end of index data")
  }
  let hi = read_u32_be_at64(data, start)
  let lo = read_u32_be_at64(data, start + 4)
  (hi << 32) | lo
}

///|
fn offset_to_int(offset : Int64) -> Int raise @bit.GitError {
  if offset < 0L || offset > 2147483647L {
    raise @bit.GitError::InvalidObject("Pack offset exceeds Int range")
  }
  offset.to_int()
}

///| Git object database loader (loose + pack + idx)

///|
pub struct PackIndex {
  pack_path : String
  ids : Array[String]
  offsets : Array[Int64]
}

///|
pub fn PackIndex::find_offset(self : PackIndex, id : ObjectId) -> Int64? {
  let target = id.to_hex()
  PackIndex::find_offset_hex(self, target)
}

///|
pub fn PackIndex::find_offset_hex(self : PackIndex, hex : String) -> Int64? {
  let mut lo = 0
  let mut hi = self.ids.length()
  while lo < hi {
    let mid = (lo + hi) / 2
    let cmp = String::compare(self.ids[mid], hex)
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
pub struct ObjectDb {
  loose : Map[String, PackObject]
  packs : Array[PackIndex]
}

///|
pub fn ObjectDb::load(
  fs : &RepoFileSystem,
  git_dir : String,
) -> ObjectDb raise GitError {
  let objects_dir = join_path(git_dir, "objects")
  let loose = if fs.is_dir(objects_dir) {
    load_loose_map(fs, objects_dir)
  } else {
    {}
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
  { loose, packs }
}

///|
pub fn ObjectDb::get(
  self : ObjectDb,
  fs : &RepoFileSystem,
  id : ObjectId,
) -> PackObject? raise GitError {
  let seen : Map[String, Bool] = {}
  get_by_hex(self, fs, id.to_hex(), seen)
}

///|
fn get_by_hex(
  db : ObjectDb,
  fs : &RepoFileSystem,
  hex : String,
  seen : Map[String, Bool],
) -> PackObject? raise GitError {
  if seen.contains(hex) {
    raise GitError::InvalidObject("Delta cycle detected: \{hex}")
  }
  seen[hex] = true
  match db.loose.get(hex) {
    Some(obj) => return Some(obj)
    None => ()
  }
  for pack in db.packs {
    match PackIndex::find_offset_hex(pack, hex) {
      None => ()
      Some(offset) => {
        let data = fs.read_file(pack.pack_path)
        let obj = read_pack_object_at(data, pack, offset, db, fs, seen)
        return Some(obj)
      }
    }
  }
  None
}

///|
pub fn load_object_store_from_fs(
  fs : &RepoFileSystem,
  git_dir : String,
) -> ObjectStore raise GitError {
  let store = ObjectStore::new()
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
fn load_loose_map(
  fs : &RepoFileSystem,
  objects_dir : String,
) -> Map[String, PackObject] raise GitError {
  let result : Map[String, PackObject] = {}
  let entries = fs.readdir(objects_dir)
  for entry in entries {
    if entry.length() != 2 {
      continue
    }
    let dir = join_path(objects_dir, entry)
    if not(fs.is_dir(dir)) {
      continue
    }
    let files = fs.readdir(dir)
    for name in files {
      if name.length() != 38 {
        continue
      }
      let path = join_path(dir, name)
      if not(fs.is_file(path)) {
        continue
      }
      let hex = entry + name
      let compressed = fs.read_file(path)
      let raw = @zlib.zlib_decompress(compressed) catch {
        e => raise GitError::InvalidObject("Zlib error: \{e}")
      }
      let obj = parse_loose_object(raw)
      let computed = hash_object_content(obj.obj_type, obj.data).to_hex()
      if computed != hex {
        raise GitError::HashMismatch(computed, hex)
      }
      result[hex] = obj
    }
  }
  result
}

///|
fn load_loose_objects(
  fs : &RepoFileSystem,
  objects_dir : String,
) -> Array[PackObject] raise GitError {
  let result : Array[PackObject] = []
  let map = load_loose_map(fs, objects_dir)
  for item in map.to_array() {
    let (_, obj) = item
    result.push(obj)
  }
  result
}

///|
fn load_pack_indexes(
  fs : &RepoFileSystem,
  pack_dir : String,
) -> Array[PackIndex] raise GitError {
  let result : Array[PackIndex] = []
  let entries = fs.readdir(pack_dir)
  for entry in entries {
    if not(entry.has_suffix(".idx")) {
      continue
    }
    let idx_path = join_path(pack_dir, entry)
    if not(fs.is_file(idx_path)) {
      continue
    }
    let base = String::unsafe_substring(entry, start=0, end=entry.length() - 4)
    let pack_path = join_path(pack_dir, base + ".pack")
    if not(fs.is_file(pack_path)) {
      continue
    }
    let data = fs.read_file(idx_path)
    let idx = parse_pack_index(data, pack_path)
    result.push(idx)
  }
  result
}

///|
fn load_pack_objects(
  fs : &RepoFileSystem,
  pack_dir : String,
) -> Array[PackObject] raise GitError {
  let result : Array[PackObject] = []
  let entries = fs.readdir(pack_dir)
  for entry in entries {
    if not(entry.has_suffix(".pack")) {
      continue
    }
    let path = join_path(pack_dir, entry)
    if not(fs.is_file(path)) {
      continue
    }
    let data = fs.read_file(path)
    let objects = parse_packfile(data)
    for obj in objects {
      result.push(obj)
    }
  }
  result
}

///|
fn parse_pack_index(
  data : Bytes,
  pack_path : String,
) -> PackIndex raise GitError {
  if data.length() < 8 {
    raise GitError::InvalidObject("Index file too short")
  }
  let magic = read_u32_be_at64(data, 0)
  if magic != 0xff744f63L {
    raise GitError::InvalidObject("Unsupported pack index version")
  }
  let version = read_u32_be_at64(data, 4)
  if version != 2L {
    raise GitError::InvalidObject("Unsupported pack index version: \{version}")
  }
  let mut offset = 8
  let fanout : Array[Int64] = []
  for _ in 0..<256 {
    fanout.push(read_u32_be_at64(data, offset))
    offset += 4
  }
  let count64 = fanout[255]
  if count64 > 2147483647L {
    raise GitError::InvalidObject("Too many objects in index")
  }
  let count = count64.to_int()
  let ids : Array[String] = []
  for _ in 0..<count {
    if offset + 20 > data.length() {
      raise GitError::InvalidObject("Index file truncated (ids)")
    }
    let bytes : FixedArray[Byte] = FixedArray::make(20, b'\x00')
    for i = 0; i < 20; i = i + 1 {
      bytes[i] = data[offset + i]
    }
    offset += 20
    ids.push(ObjectId::new(bytes).to_hex())
  }
  // Skip CRC32 table
  offset += count * 4
  if offset + count * 4 > data.length() {
    raise GitError::InvalidObject("Index file truncated (offsets)")
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
        raise GitError::InvalidObject("Index file truncated (large offsets)")
      }
      let v = read_u64_be_at64(data, offset)
      offset += 8
      let pos = large_indices[large_idx]
      offsets[pos] = v
      large_idx += 1
    }
  }
  { pack_path, ids, offsets }
}

///|
fn read_pack_object_at(
  data : Bytes,
  pack : PackIndex,
  offset : Int64,
  db : ObjectDb,
  fs : &RepoFileSystem,
  seen : Map[String, Bool],
) -> PackObject raise GitError {
  let offset_i = offset_to_int(offset)
  let (type_id, size, next_offset) = decode_type_and_size_at(data, offset_i)
  match type_id {
    1 | 2 | 3 | 4 => {
      let obj_type = packfile_type_to_object_type(type_id)
      let (content, _after) = @zlib.zlib_decompress_at(data, next_offset) catch {
        e => raise GitError::PackfileError("Zlib error: \{e}")
      }
      if content.length() != size {
        raise GitError::PackfileError(
          "Object size mismatch: expected=\{size}, got=\{content.length()}",
        )
      }
      PackObject::new(obj_type, content)
    }
    6 => {
      let (back_offset, after_ref) = read_ofs_delta_offset(data, next_offset)
      let base_offset = offset_i - back_offset
      if base_offset < 0 {
        raise GitError::PackfileError("Invalid OFS_DELTA base offset")
      }
      let (delta, _after) = @zlib.zlib_decompress_at(data, after_ref) catch {
        e => raise GitError::PackfileError("Zlib error: \{e}")
      }
      if delta.length() != size {
        raise GitError::PackfileError(
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
      )
      let content = apply_delta(base.data, delta)
      PackObject::new(base.obj_type, content)
    }
    7 => {
      let (base_hex, after_ref) = read_ref_delta_id(data, next_offset)
      let (delta, _after) = @zlib.zlib_decompress_at(data, after_ref) catch {
        e => raise GitError::PackfileError("Zlib error: \{e}")
      }
      if delta.length() != size {
        raise GitError::PackfileError(
          "Delta size mismatch: expected=\{size}, got=\{delta.length()}",
        )
      }
      let base = match PackIndex::find_offset_hex(pack, base_hex) {
        Some(base_offset) =>
          read_pack_object_at(data, pack, base_offset, db, fs, seen)
        None =>
          match get_by_hex(db, fs, base_hex, seen) {
            Some(obj) => obj
            None =>
              raise GitError::PackfileError("Missing base object for REF_DELTA")
          }
      }
      let content = apply_delta(base.data, delta)
      PackObject::new(base.obj_type, content)
    }
    _ =>
      raise GitError::PackfileError("Unknown packfile object type: \{type_id}")
  }
}

///|
fn parse_loose_object(data : Bytes) -> PackObject raise GitError {
  let len = data.length()
  if len == 0 {
    raise GitError::InvalidObject("Empty loose object")
  }
  let type_buf = StringBuilder::new()
  let mut i = 0
  while i < len && data[i] != b' ' {
    type_buf.write_char(data[i].to_int().unsafe_to_char())
    i += 1
  }
  if i >= len || data[i] != b' ' {
    raise GitError::InvalidObject("Invalid loose object header")
  }
  i += 1
  let mut size = 0
  while i < len && data[i] != b'\x00' {
    let b = data[i]
    if b < b'0' || b > b'9' {
      raise GitError::InvalidObject("Invalid loose object size")
    }
    size = size * 10 + (b.to_int() - b'0'.to_int())
    i += 1
  }
  if i >= len || data[i] != b'\x00' {
    raise GitError::InvalidObject("Invalid loose object header")
  }
  i += 1
  let content_len = len - i
  if content_len != size {
    raise GitError::InvalidObject(
      "Loose object size mismatch: expected=\{size}, got=\{content_len}",
    )
  }
  let content = Bytes::from_array(
    FixedArray::makei(content_len, fn(j) { data[i + j] }),
  )
  let obj_type = object_type_from_string(type_buf.to_string())
  PackObject::new(obj_type, content)
}

///|
fn object_type_from_string(s : String) -> ObjectType raise GitError {
  if s == "blob" {
    ObjectType::Blob
  } else if s == "tree" {
    ObjectType::Tree
  } else if s == "commit" {
    ObjectType::Commit
  } else if s == "tag" {
    ObjectType::Tag
  } else {
    raise GitError::InvalidObject("Unknown object type: \{s}")
  }
}

///|
fn read_u32_be_at64(data : Bytes, start : Int) -> Int64 raise GitError {
  if start + 4 > data.length() {
    raise GitError::InvalidObject("Unexpected end of index data")
  }
  let b0 = data[start].to_int64()
  let b1 = data[start + 1].to_int64()
  let b2 = data[start + 2].to_int64()
  let b3 = data[start + 3].to_int64()
  (b0 << 24) | (b1 << 16) | (b2 << 8) | b3
}

///|
fn read_u64_be_at64(data : Bytes, start : Int) -> Int64 raise GitError {
  if start + 8 > data.length() {
    raise GitError::InvalidObject("Unexpected end of index data")
  }
  let hi = read_u32_be_at64(data, start)
  let lo = read_u32_be_at64(data, start + 4)
  (hi << 32) | lo
}

///|
fn offset_to_int(offset : Int64) -> Int raise GitError {
  if offset < 0L || offset > 2147483647L {
    raise GitError::InvalidObject("Pack offset exceeds Int range")
  }
  offset.to_int()
}

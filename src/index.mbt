///| Git index (v2) reader/writer

///|
pub struct IndexEntry {
  path : String
  id : ObjectId
  mode : Int
  size : Int
}

///|
pub fn read_index_entries(
  fs : &RepoFileSystem,
  git_dir : String,
) -> Array[IndexEntry] raise GitError {
  let path = join_path(git_dir, "index")
  if not(fs.is_file(path)) {
    return []
  }
  let data = fs.read_file(path)
  if data.length() < 12 + 20 {
    raise GitError::InvalidObject("Index file too short")
  }
  if not(
      data[0] == b'D' && data[1] == b'I' && data[2] == b'R' && data[3] == b'C',
    ) {
    raise GitError::InvalidObject("Invalid index header")
  }
  let version = index_read_u32_be(data, 4)
  if version != 2 {
    raise GitError::InvalidObject("Unsupported index version: \{version}")
  }
  let count = index_read_u32_be(data, 8)
  let mut offset = 12
  let entries : Array[IndexEntry] = []
  for _ in 0..<count {
    if offset + 62 > data.length() {
      raise GitError::InvalidObject("Index entry truncated")
    }
    // skip ctime/mtime/dev/ino/uid/gid (8 u32)
    offset += 32
    let mode = index_read_u32_be(data, offset)
    offset += 4
    let size = index_read_u32_be(data, offset)
    offset += 4
    let id = index_read_object_id(data, offset)
    offset += 20
    // flags (u16)
    offset += 2
    let (path_str, next) = index_read_cstring(data, offset)
    offset = next
    while offset % 8 != 0 {
      if offset >= data.length() {
        raise GitError::InvalidObject("Index padding out of range")
      }
      offset += 1
    }
    entries.push({ path: path_str, id, mode, size })
  }
  entries
}

///|
pub fn write_index_entries(
  fs : &FileSystem,
  git_dir : String,
  entries : Array[IndexEntry],
) -> Unit raise GitError {
  let sorted = entries.copy()
  sorted.sort_by(fn(a, b) { String::compare(a.path, b.path) })
  let out : Array[Byte] = []
  // Header: "DIRC" + version(2) + count
  out.push(b'D')
  out.push(b'I')
  out.push(b'R')
  out.push(b'C')
  index_push_u32_be(out, 2)
  index_push_u32_be(out, sorted.length())
  for e in sorted {
    // ctime/mtime/dev/ino/uid/gid all zeros
    index_push_u32_be(out, 0)
    index_push_u32_be(out, 0)
    index_push_u32_be(out, 0)
    index_push_u32_be(out, 0)
    index_push_u32_be(out, 0)
    index_push_u32_be(out, 0)
    index_push_u32_be(out, 0)
    index_push_u32_be(out, 0)
    // mode + size
    index_push_u32_be(out, e.mode)
    index_push_u32_be(out, e.size)
    // object id
    for b in e.id.bytes {
      out.push(b)
    }
    let name_len = if e.path.length() < 0x0fff {
      e.path.length()
    } else {
      0x0fff
    }
    index_push_u16_be(out, name_len)
    for c in e.path {
      out.push(c.to_int().to_byte())
    }
    out.push(b'\x00')
    while out.length() % 8 != 0 {
      out.push(b'\x00')
    }
  }
  let content = index_bytes_from_array(out)
  let checksum = sha1(content)
  for b in checksum.bytes {
    out.push(b)
  }
  let index_bytes = index_bytes_from_array(out)
  let index_path = join_path(git_dir, "index")
  fs.write_file(index_path, index_bytes)
}

///|
fn index_read_u32_be(data : Bytes, start : Int) -> Int raise GitError {
  if start < 0 || start + 4 > data.length() {
    raise GitError::InvalidObject("Unexpected end of index data")
  }
  (data[start].to_int() << 24) |
  (data[start + 1].to_int() << 16) |
  (data[start + 2].to_int() << 8) |
  data[start + 3].to_int()
}

///|
fn index_read_object_id(data : Bytes, start : Int) -> ObjectId raise GitError {
  if start + 20 > data.length() {
    raise GitError::InvalidObject("Unexpected end of index data")
  }
  let bytes : FixedArray[Byte] = FixedArray::make(20, b'\x00')
  for i = 0; i < 20; i = i + 1 {
    bytes[i] = data[start + i]
  }
  ObjectId::new(bytes)
}

///|
fn index_read_cstring(
  data : Bytes,
  start : Int,
) -> (String, Int) raise GitError {
  let mut i = start
  while i < data.length() && data[i] != b'\x00' {
    i += 1
  }
  if i >= data.length() {
    raise GitError::InvalidObject("Missing NUL in index entry")
  }
  let bytes : Array[Byte] = []
  for j = start; j < i; j = j + 1 {
    bytes.push(data[j])
  }
  let s = index_bytes_to_string(bytes)
  (s, i + 1)
}

///|
fn index_bytes_to_string(bytes : Array[Byte]) -> String {
  let sb = StringBuilder::new()
  for b in bytes {
    sb.write_char(b.to_int().unsafe_to_char())
  }
  sb.to_string()
}

///|
fn index_bytes_from_array(arr : Array[Byte]) -> Bytes {
  Bytes::from_array(FixedArray::makei(arr.length(), fn(i) { arr[i] }))
}

///|
fn index_push_u32_be(out : Array[Byte], v : Int) -> Unit {
  out.push(((v >> 24) & 0xff).to_byte())
  out.push(((v >> 16) & 0xff).to_byte())
  out.push(((v >> 8) & 0xff).to_byte())
  out.push((v & 0xff).to_byte())
}

///|
fn index_push_u16_be(out : Array[Byte], v : Int) -> Unit {
  out.push(((v >> 8) & 0xff).to_byte())
  out.push((v & 0xff).to_byte())
}

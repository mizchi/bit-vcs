///| Git object types and common errors

///|
/// Object identifier (20 bytes for SHA-1, 32 bytes for SHA-256)
pub struct ObjectId {
  bytes : FixedArray[Byte]
}

///|
pub fn ObjectId::new(bytes : FixedArray[Byte]) -> ObjectId {
  { bytes, }
}

///|
pub fn ObjectId::zero(algo? : HashAlgorithm = Sha1) -> ObjectId {
  { bytes: FixedArray::make(algo.hash_size(), b'\x00') }
}

///|
/// Check if this ObjectId is the zero (null) object id.
pub fn ObjectId::is_zero(self : ObjectId) -> Bool {
  for b in self.bytes {
    if b != b'\x00' {
      return false
    }
  }
  true
}

///|
/// Return the byte length of this ObjectId (20 for SHA-1, 32 for SHA-256).
pub fn ObjectId::hash_size(self : ObjectId) -> Int {
  self.bytes.length()
}

///|
/// Convert ObjectId to Bytes - zero-copy when possible
pub fn ObjectId::to_bytes(self : ObjectId) -> Bytes {
  Bytes::from_array(self.bytes.iter().collect())
}

///|
/// Create ObjectId from Bytes (must be exactly 20 or 32 bytes)
pub fn ObjectId::from_bytes(data : Bytes) -> ObjectId raise GitError {
  if data.length() != 20 && data.length() != 32 {
    raise GitError::InvalidObject("Invalid ObjectId length: \{data.length()}")
  }
  let len = data.length()
  let bytes = FixedArray::make(len, b'\x00')
  for i in 0..<len {
    bytes[i] = data[i]
  }
  { bytes, }
}

///|
/// Create ObjectId from Bytes at offset (for parsing packed data).
/// Reads `hash_size` bytes (default 20 for SHA-1).
pub fn ObjectId::from_bytes_at(
  data : Bytes,
  offset : Int,
  hash_size? : Int = 20,
) -> ObjectId {
  let bytes = FixedArray::make(hash_size, b'\x00')
  for i in 0..<hash_size {
    bytes[i] = data[offset + i]
  }
  { bytes, }
}

///|
pub fn ObjectId::from_hex(hex : String) -> ObjectId raise GitError {
  if hex.length() != 40 && hex.length() != 64 {
    raise GitError::InvalidObject("Invalid hex length: \{hex.length()}")
  }
  let byte_len = hex.length() / 2
  let bytes = FixedArray::make(byte_len, b'\x00')
  let chars = hex.to_array()
  for i = 0; i < byte_len; i = i + 1 {
    let hi = hex_char_to_int(chars[i * 2])
    let lo = hex_char_to_int(chars[i * 2 + 1])
    bytes[i] = ((hi << 4) | lo).to_byte()
  }
  { bytes, }
}

///|
fn hex_char_to_int(c : Char) -> Int raise GitError {
  if c >= '0' && c <= '9' {
    c.to_int() - '0'.to_int()
  } else if c >= 'a' && c <= 'f' {
    c.to_int() - 'a'.to_int() + 10
  } else if c >= 'A' && c <= 'F' {
    c.to_int() - 'A'.to_int() + 10
  } else {
    raise GitError::InvalidObject("Invalid hex char: \{c}")
  }
}

///|
pub fn ObjectId::to_hex(self : ObjectId) -> String {
  let result = StringBuilder::new()
  for b in self.bytes {
    let hi = (b.to_int() >> 4) & 0x0f
    let lo = b.to_int() & 0x0f
    result.write_char(int_to_hex_char(hi))
    result.write_char(int_to_hex_char(lo))
  }
  result.to_string()
}

///|
fn int_to_hex_char(i : Int) -> Char {
  if i < 10 {
    (i + '0'.to_int()).unsafe_to_char()
  } else {
    (i - 10 + 'a'.to_int()).unsafe_to_char()
  }
}

///|
pub impl Show for ObjectId with fn output(self, logger) {
  logger.write_string(self.to_hex())
}

///|
pub impl @debug.Debug for ObjectId with fn to_repr(self) {
  @debug.Repr::string(self.to_hex())
}

///|
pub impl Eq for ObjectId with fn equal(self, other) {
  if self.bytes.length() != other.bytes.length() {
    return false
  }
  for i = 0; i < self.bytes.length(); i = i + 1 {
    if self.bytes[i] != other.bytes[i] {
      return false
    }
  }
  true
}

///|
/// Check if a hex string represents the zero (null) object id.
pub fn ObjectId::is_zero_hex(hex : String) -> Bool {
  hex == "0000000000000000000000000000000000000000" ||
  hex == "0000000000000000000000000000000000000000000000000000000000000000"
}

///|
/// Hash implementation for using ObjectId as Map key
pub impl Hash for ObjectId with fn hash_combine(self, hasher) {
  // Use first 8 bytes as hash (sufficient for distribution)
  for i in 0..<8 {
    Hash::hash_combine(self.bytes[i], hasher)
  }
}

///|
/// Git object types
pub(all) enum ObjectType {
  Blob
  Tree
  Commit
  Tag
} derive(Eq, Debug)

///|
pub fn ObjectType::to_string(self : ObjectType) -> String {
  match self {
    Blob => "blob"
    Tree => "tree"
    Commit => "commit"
    Tag => "tag"
  }
}

///|
pub fn ObjectType::to_packfile_type(self : ObjectType) -> Int {
  match self {
    Commit => 1
    Tree => 2
    Blob => 3
    Tag => 4
  }
}

///|
pub impl Show for ObjectType with fn output(self, logger) {
  logger.write_string(self.to_string())
}

///|
/// Git operation errors
pub(all) suberror GitError {
  InvalidObject(String)
  HashMismatch(String, String)
  PackfileError(String)
  ProtocolError(String)
  IoError(String)
} derive(Debug, Eq)

///|
fn git_error_show_string(value : String) -> String {
  let buf = StringBuilder::new()
  buf.write_char('"')
  for c in value {
    if c == '"' {
      buf.write_string("\\\"")
    } else if c == '\\' {
      buf.write_string("\\\\")
    } else if c == '\n' {
      buf.write_string("\\n")
    } else if c == '\r' {
      buf.write_string("\\r")
    } else if c == '\t' {
      buf.write_string("\\t")
    } else {
      buf.write_char(c)
    }
  }
  buf.write_char('"')
  buf.to_string()
}

///|
pub impl Show for GitError with fn output(self, logger) {
  match self {
    InvalidObject(message) =>
      logger.write_string(
        "InvalidObject(" + git_error_show_string(message) + ")",
      )
    HashMismatch(expected, actual) =>
      logger.write_string(
        "HashMismatch(" +
        git_error_show_string(expected) +
        ", " +
        git_error_show_string(actual) +
        ")",
      )
    PackfileError(message) =>
      logger.write_string(
        "PackfileError(" + git_error_show_string(message) + ")",
      )
    ProtocolError(message) =>
      logger.write_string(
        "ProtocolError(" + git_error_show_string(message) + ")",
      )
    IoError(message) =>
      logger.write_string("IoError(" + git_error_show_string(message) + ")")
  }
}

///|
/// Tree entry in a Git tree object
pub struct TreeEntry {
  mode : String // "100644", "040000", etc.
  name : String
  id : ObjectId
}

///|
pub fn TreeEntry::new(mode : String, name : String, id : ObjectId) -> TreeEntry {
  { mode, name, id }
}

///|
/// Git commit object
pub struct Commit {
  tree : ObjectId
  parents : Array[ObjectId]
  author : String
  author_time : Int64
  author_tz : String
  committer : String
  commit_time : Int64
  committer_tz : String
  message : String
  encoding : String
  verbatim_message : Bool
}

///|
pub fn Commit::new(
  tree : ObjectId,
  parents : Array[ObjectId],
  author : String,
  author_time : Int64,
  author_tz : String,
  committer : String,
  commit_time : Int64,
  committer_tz : String,
  message : String,
  encoding? : String = "UTF-8",
  verbatim_message? : Bool = false,
) -> Commit {
  {
    tree,
    parents,
    author,
    author_time,
    author_tz,
    committer,
    commit_time,
    committer_tz,
    message,
    encoding,
    verbatim_message,
  }
}

///|
/// A Git object ready for packing
pub struct PackObject {
  obj_type : ObjectType
  data : Bytes // Uncompressed object content (without header)
  // Cached metadata for performance (computed during pack parsing)
  id : ObjectId // Object hash (cached)
  offset : Int // Offset in packfile (-1 if not from pack)
  crc32 : UInt // CRC32 of compressed data (0 if not computed)
}

///|
/// Delta encoding mode for packfile generation
pub(all) enum PackDeltaMode {
  NoDelta
  RefDelta
  OfsDelta
}

///|
/// Compression mode for packfile entries
pub(all) enum PackCompression {
  Default
  Stored
}

///|
pub fn PackObject::new(obj_type : ObjectType, data : Bytes) -> PackObject {
  let id = hash_object_content(obj_type, data)
  { obj_type, data, id, offset: -1, crc32: 0U }
}

///|
pub fn PackObject::with_metadata(
  obj_type : ObjectType,
  data : Bytes,
  id : ObjectId,
  offset : Int,
  crc32 : UInt,
) -> PackObject {
  { obj_type, data, id, offset, crc32 }
}

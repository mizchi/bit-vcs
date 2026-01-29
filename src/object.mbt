///| Git object creation and hashing

///|
/// Helper to convert Array[Byte] to Bytes
fn array_to_bytes(arr : Array[Byte]) -> Bytes {
  Bytes::from_array(FixedArray::makei(arr.length(), fn(i) { arr[i] }))
}

///|
/// Create a Git object and return its ID and compressed data
/// Format: {type} {size}\0{content} -> SHA-1 -> zlib compress
pub fn create_object(
  obj_type : ObjectType,
  content : Bytes,
) -> (ObjectId, Bytes) {
  let raw = format_object(obj_type, content)
  let id = sha1(raw)
  let compressed = @zlib.zlib_compress(raw)
  (id, compressed)
}

///|
/// Hash object content (without compression)
pub fn hash_object_content(obj_type : ObjectType, content : Bytes) -> ObjectId {
  let raw = format_object(obj_type, content)
  sha1(raw)
}

///|
/// Format a Git object (without compression)
fn format_object(obj_type : ObjectType, content : Bytes) -> Bytes {
  let header = "\{obj_type.to_string()} \{content.length()}\u0000"
  let result : Array[Byte] = []
  for c in header {
    result.push(c.to_int().to_byte())
  }
  for b in content {
    result.push(b)
  }
  array_to_bytes(result)
}

///|
/// Create a blob object from content
pub fn create_blob(content : Bytes) -> (ObjectId, Bytes) {
  create_object(ObjectType::Blob, content)
}

///|
/// Create a blob from string content
pub fn create_blob_string(content : String) -> (ObjectId, Bytes) {
  let bytes : Array[Byte] = []
  for c in content {
    bytes.push(c.to_int().to_byte())
  }
  create_blob(array_to_bytes(bytes))
}

///|
/// Create a tree object from entries
/// Entries must be sorted by name
pub fn create_tree(entries : Array[TreeEntry]) -> (ObjectId, Bytes) {
  let content : Array[Byte] = []
  for entry in entries {
    // mode (as ASCII)
    for c in entry.mode {
      content.push(c.to_int().to_byte())
    }
    // space
    content.push(b' ')
    // name (as bytes)
    for c in entry.name {
      content.push(c.to_int().to_byte())
    }
    // null byte
    content.push(b'\x00')
    // 20-byte SHA
    for b in entry.id.bytes {
      content.push(b)
    }
  }
  create_object(ObjectType::Tree, array_to_bytes(content))
}

///|
/// Create a commit object
pub fn create_commit(commit : Commit) -> (ObjectId, Bytes) {
  let content = StringBuilder::new()

  // tree
  content.write_string("tree ")
  content.write_string(commit.tree.to_hex())
  content.write_char('\n')

  // parents
  for parent in commit.parents {
    content.write_string("parent ")
    content.write_string(parent.to_hex())
    content.write_char('\n')
  }

  // author
  content.write_string("author ")
  content.write_string(commit.author)
  content.write_string(" ")
  content.write_string(commit.author_time.to_string())
  content.write_string(" ")
  content.write_string(commit.author_tz)
  content.write_char('\n')

  // committer
  content.write_string("committer ")
  content.write_string(commit.committer)
  content.write_string(" ")
  content.write_string(commit.commit_time.to_string())
  content.write_string(" ")
  content.write_string(commit.committer_tz)
  content.write_char('\n')

  // blank line
  content.write_char('\n')

  // message
  content.write_string(commit.message)
  let content_str = content.to_string()
  let bytes : Array[Byte] = []
  for c in content_str {
    bytes.push(c.to_int().to_byte())
  }
  create_object(ObjectType::Commit, array_to_bytes(bytes))
}

///|
/// Hash a blob without creating the compressed object
pub fn hash_blob(content : Bytes) -> ObjectId {
  let raw = format_object(ObjectType::Blob, content)
  sha1(raw)
}

///|
/// Hash a blob from string
pub fn hash_blob_string(content : String) -> ObjectId {
  let bytes : Array[Byte] = []
  for c in content {
    bytes.push(c.to_int().to_byte())
  }
  hash_blob(array_to_bytes(bytes))
}

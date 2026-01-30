///| Upload-pack dispatcher (wasm targets)

///| For wasm, use *_with_http functions from upload_pack_http_common.mbt

///| with your own HTTP client implementation.

///|
fn[T] wasm_http_not_available() -> T raise GitError {
  raise GitError::ProtocolError(
    "HTTP client not available on wasm target. Use *_with_http functions with your own HTTP implementation.",
  )
}

///|
pub async fn upload_pack_info_refs(
  _remote : String,
  _prefer_v2 : Bool,
) -> Bytes raise GitError {
  wasm_http_not_available()
}

///|
pub async fn upload_pack_request(
  _remote : String,
  _body : Bytes,
  _prefer_v2 : Bool,
) -> Bytes raise GitError {
  wasm_http_not_available()
}

///|
pub async fn discover_upload_refs(
  _remote : String,
  _prefer_v2 : Bool,
) -> (
  Array[(ObjectId, String)],
  Array[String],
  ProtocolVersion,
  Map[String, String],
) raise GitError {
  wasm_http_not_available()
}

///|
pub async fn fetch_pack(
  _remote : String,
  _wants : Array[ObjectId],
  _prefer_v2 : Bool,
) -> Bytes raise GitError {
  wasm_http_not_available()
}

///|
pub async fn fetch_objects(
  _remote : String,
  _wants : Array[ObjectId],
  _prefer_v2 : Bool,
) -> Array[PackObject] raise GitError {
  wasm_http_not_available()
}

///|
pub async fn clone_remote(
  _remote : String,
  _prefer_v2 : Bool,
) -> (Array[(ObjectId, String)], Array[PackObject]) raise GitError {
  wasm_http_not_available()
}

///|
pub async fn clone_remote_to_fs(
  _remote : String,
  _prefer_v2 : Bool,
  _fs : &FileSystem,
  _root : String,
) -> Array[(ObjectId, String)] raise GitError {
  wasm_http_not_available()
}

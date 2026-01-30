///| Upload-pack over HTTP - native implementation

///| This file is only compiled for native target

///|
pub async fn upload_pack_info_refs_http(
  remote : String,
  prefer_v2 : Bool,
) -> Bytes raise GitError {
  upload_pack_info_refs_with_http(remote, prefer_v2, native_http_get)
}

///|
pub async fn upload_pack_request_http(
  remote : String,
  body : Bytes,
  prefer_v2 : Bool,
) -> Bytes raise GitError {
  upload_pack_request_with_http(remote, body, prefer_v2, native_http_post)
}

///|
pub async fn discover_upload_refs_http(
  remote : String,
  prefer_v2 : Bool,
) -> (
  Array[(ObjectId, String)],
  Array[String],
  ProtocolVersion,
  Map[String, String],
) raise GitError {
  discover_upload_refs_with_http(
    remote, prefer_v2, native_http_get, native_http_post,
  )
}

///|
pub async fn fetch_pack_http(
  remote : String,
  wants : Array[ObjectId],
  prefer_v2 : Bool,
) -> Bytes raise GitError {
  fetch_pack_with_http(
    remote, wants, prefer_v2, native_http_get, native_http_post,
  )
}

///|
pub async fn fetch_objects_http(
  remote : String,
  wants : Array[ObjectId],
  prefer_v2 : Bool,
) -> Array[PackObject] raise GitError {
  fetch_objects_with_http(
    remote, wants, prefer_v2, native_http_get, native_http_post,
  )
}

///|
pub async fn clone_http(
  remote : String,
  prefer_v2 : Bool,
) -> (Array[(ObjectId, String)], Array[PackObject]) raise GitError {
  clone_with_http(remote, prefer_v2, native_http_get, native_http_post)
}

///|
/// Clone and checkout into filesystem under `root`.
pub async fn clone_http_to_fs(
  remote : String,
  prefer_v2 : Bool,
  fs : &FileSystem,
  root : String,
) -> Array[(ObjectId, String)] raise GitError {
  clone_to_fs_with_http(
    remote, prefer_v2, fs, root, native_http_get, native_http_post,
  )
}

///| Upload-pack over HTTP (smart HTTP, wasm targets)

///|
pub async fn upload_pack_info_refs_http(
  remote : String,
  prefer_v2 : Bool,
) -> Bytes raise GitError {
  let spec = parse_remote(remote)
  if spec.kind != RemoteKind::Http {
    raise GitError::ProtocolError("HTTP transport required")
  }
  let base = spec.base_url.unwrap_or(remote)
  let url = "\{base}/info/refs?service=git-upload-pack"
  let headers : Map[String, String] = {
    "User-Agent": "git/moonbit",
    "Accept": "application/x-git-upload-pack-advertisement",
  }
  if prefer_v2 {
    headers.set("Git-Protocol", "version=2")
  }
  let (response, data) = @http.get(url, headers~) catch {
    e => raise GitError::IoError("HTTP request failed: \{e}")
  }
  if response.code != 200 {
    raise GitError::ProtocolError(
      "Failed to fetch info/refs: HTTP \{response.code}",
    )
  }
  data
}

///|
pub async fn upload_pack_request_http(
  remote : String,
  body : Bytes,
  prefer_v2 : Bool,
) -> Bytes raise GitError {
  let spec = parse_remote(remote)
  if spec.kind != RemoteKind::Http {
    raise GitError::ProtocolError("HTTP transport required")
  }
  let base = spec.base_url.unwrap_or(remote)
  let url = "\{base}/git-upload-pack"
  let headers : Map[String, String] = {
    "User-Agent": "git/moonbit",
    "Content-Type": "application/x-git-upload-pack-request",
    "Accept": "application/x-git-upload-pack-result",
  }
  if prefer_v2 {
    headers.set("Git-Protocol", "version=2")
  }
  let (response, data) = @http.post(url, body, headers~) catch {
    e => raise GitError::IoError("HTTP request failed: \{e}")
  }
  if response.code != 200 {
    raise GitError::ProtocolError(
      "Failed to upload-pack: HTTP \{response.code}",
    )
  }
  data
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
  let adv = upload_pack_info_refs_http(remote, prefer_v2)
  let version = detect_protocol_version(adv)
  if version == ProtocolVersion::V2 {
    let caps = parse_v2_advertised_caps(adv)
    let req = build_ls_refs_request("git/moonbit", [
      "refs/heads/", "refs/tags/", "HEAD",
    ])
    let resp = upload_pack_request_http(remote, req, true)
    let parsed = parse_ls_refs_response(resp)
    return (parsed.refs, caps, version, parsed.symrefs)
  }
  let refs = parse_refs(adv)
  let caps = extract_capabilities(adv)
  (refs, caps, ProtocolVersion::V0, {})
}

///|
pub async fn fetch_pack_http(
  remote : String,
  wants : Array[ObjectId],
  prefer_v2 : Bool,
) -> Bytes raise GitError {
  let (refs, caps, version, _symrefs) = discover_upload_refs_http(
    remote, prefer_v2,
  )
  let wants = if wants.length() == 0 {
    let ids : Array[ObjectId] = []
    for item in refs {
      let (id, _) = item
      ids.push(id)
    }
    ids
  } else {
    wants
  }
  if version == ProtocolVersion::V2 {
    let req = build_fetch_request_v2("git/moonbit", wants)
    let resp = upload_pack_request_http(remote, req, true)
    return extract_pack_from_v2_response(resp)
  }
  let req = build_fetch_request_v0("git/moonbit", wants, caps)
  let resp = upload_pack_request_http(remote, req, false)
  extract_pack_from_v0_response(resp)
}

///|
pub async fn fetch_objects_http(
  remote : String,
  wants : Array[ObjectId],
  prefer_v2 : Bool,
) -> Array[PackObject] raise GitError {
  let pack = fetch_pack_http(remote, wants, prefer_v2)
  parse_packfile(pack)
}

///|
pub async fn clone_http(
  remote : String,
  prefer_v2 : Bool,
) -> (Array[(ObjectId, String)], Array[PackObject]) raise GitError {
  let (refs, _caps, _version, symrefs) = discover_upload_refs_http(
    remote, prefer_v2,
  )
  let wants = select_default_wants(refs, symrefs)
  let pack = fetch_pack_http(remote, wants, prefer_v2)
  let objects = parse_packfile(pack)
  (refs, objects)
}

///|
/// Clone and checkout into filesystem under `root`.
pub async fn clone_http_to_fs(
  remote : String,
  prefer_v2 : Bool,
  fs : &FileSystem,
  root : String,
) -> Array[(ObjectId, String)] raise GitError {
  let (refs, _caps, _version, symrefs) = discover_upload_refs_http(
    remote, prefer_v2,
  )
  let wants = select_default_wants(refs, symrefs)
  let default_ref = select_default_ref(refs, symrefs)
  match default_ref {
    None => return refs
    Some(_) => ()
  }
  if wants.length() == 0 {
    return refs
  }
  let pack = fetch_pack_http(remote, wants, prefer_v2)
  let objects = parse_packfile(pack)
  let store = ObjectStore::from_pack(objects)
  match default_ref {
    None => ()
    Some((refname, commit_id)) => {
      materialize_clone_to_fs(store, commit_id, refname, remote, fs, root)
      let git_dir = join_path(root, ".git")
      write_packfile_with_index(fs, git_dir, pack, objects)
    }
  }
  refs
}

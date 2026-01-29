///| Git HTTP push protocol implementation (WASM target only)

///| This file is only compiled for wasm-gc and wasm targets

// Note: This module requires the x-async HTTP client
// Import will be added when moon.pkg.json is updated for wasm targets

///|
/// Helper to convert Array[Byte] to Bytes
fn remote_array_to_bytes(arr : Array[Byte]) -> Bytes {
  Bytes::from_array(FixedArray::makei(arr.length(), fn(i) { arr[i] }))
}

///|
/// Remote repository URL
pub struct Remote {
  url : String // e.g., "https://github.com/user/repo.git"
}

///|
pub fn Remote::new(url : String) -> Remote {
  { url, }
}

///|
/// Normalize URL (remove trailing .git if present)
fn normalize_url(url : String) -> String {
  if url.has_suffix(".git") {
    let chars = url.to_array()
    let result = StringBuilder::new()
    for i = 0; i < chars.length() - 4; i = i + 1 {
      result.write_char(chars[i])
    }
    result.to_string()
  } else {
    url
  }
}

///|
/// Build URL for git-receive-pack info/refs
pub fn Remote::info_refs_url(self : Remote) -> String {
  let base = normalize_url(self.url)
  "\{base}/info/refs?service=git-receive-pack"
}

///|
/// Build URL for git-receive-pack
pub fn Remote::receive_pack_url(self : Remote) -> String {
  let base = normalize_url(self.url)
  "\{base}/git-receive-pack"
}

///|
/// Fetch receive-pack refs via smart HTTP
pub async fn discover_receive_refs_http(
  remote : Remote,
) -> Array[(ObjectId, String)] raise GitError {
  let url = remote.info_refs_url()
  let headers : Map[String, String] = {
    "User-Agent": "git/moonbit",
    "Accept": "application/x-git-receive-pack-advertisement",
  }
  let (response, data) = @http.get(url, headers~) catch {
    e => raise GitError::IoError("HTTP request failed: \{e}")
  }
  if response.code != 200 {
    raise GitError::ProtocolError(
      "Failed to fetch info/refs: HTTP \{response.code}",
    )
  }
  parse_refs(data)
}

///|
/// Git push request data
pub struct PushRequest {
  old_id : ObjectId
  new_id : ObjectId
  refname : String
  packfile : Bytes
}

///|
pub fn PushRequest::new(
  old_id : ObjectId,
  new_id : ObjectId,
  refname : String,
  packfile : Bytes,
) -> PushRequest {
  { old_id, new_id, refname, packfile }
}

///|
/// Build the request body for git-receive-pack
/// Format:
///   {pkt-line: old new ref\0capabilities\n}
///   {flush: 0000}
///   {packfile binary}
pub fn build_receive_pack_body(req : PushRequest) -> Bytes {
  let result : Array[Byte] = []

  // Ref update command with capabilities
  let cmd = build_ref_update(
    req.old_id,
    req.new_id,
    req.refname,
    "report-status side-band-64k",
  )
  let cmd_pkt = pktline_encode(cmd)
  for b in cmd_pkt {
    result.push(b)
  }

  // Flush
  let flush = pktline_flush()
  for b in flush {
    result.push(b)
  }

  // Packfile
  for b in req.packfile {
    result.push(b)
  }
  remote_array_to_bytes(result)
}

///|
/// Parse receive-pack response
pub fn parse_receive_pack_response(data : Bytes) -> Result[String, GitError] {
  // Response format:
  // {pkt-line: unpack ok\n} or {pkt-line: unpack error\n}
  // {pkt-line: ok refs/heads/main\n} or {pkt-line: ng refs/heads/main message\n}
  // {flush: 0000}

  let decoded = pktline_decode(data) catch { e => return Err(e) }
  let mut unpack_ok = false
  let mut ref_ok = false
  let mut error_msg = ""
  for item in decoded {
    let (line_bytes, is_flush) = item
    if is_flush || line_bytes.length() == 0 {
      continue
    }
    let line = remote_bytes_to_string(line_bytes)
    if line.has_prefix("unpack ok") {
      unpack_ok = true
    } else if line.has_prefix("unpack ") {
      error_msg = line
    } else if line.has_prefix("ok ") {
      ref_ok = true
    } else if line.has_prefix("ng ") {
      error_msg = line
    }
  }
  if unpack_ok && ref_ok {
    Ok("Push successful")
  } else if error_msg.length() > 0 {
    Err(GitError::ProtocolError(error_msg))
  } else {
    Err(GitError::ProtocolError("Unknown response"))
  }
}

///|
/// Parse side-band data (used by some servers)
/// Side-band format: {channel byte}{data}
/// Channel 1 = pack data, Channel 2 = progress, Channel 3 = error
pub fn parse_sideband(data : Bytes) -> (Int, Bytes) {
  if data.length() == 0 {
    return (0, Bytes::from_array([]))
  }
  let channel = data[0].to_int()
  let content : Array[Byte] = []
  for i = 1; i < data.length(); i = i + 1 {
    content.push(data[i])
  }
  (channel, remote_array_to_bytes(content))
}

///|
/// Extract capabilities from refs response
pub fn extract_capabilities(data : Bytes) -> Array[String] {
  let result : Array[String] = []
  let decoded = pktline_decode(data) catch { _ => return result }
  for item in decoded {
    let (line_bytes, _) = item
    if line_bytes.length() == 0 {
      continue
    }
    let line = remote_bytes_to_string(line_bytes)

    // Look for null byte separator
    match line.find("\u0000") {
      None => continue
      Some(idx) => {
        let caps_str = substring_from_index(line, idx + 1)
        // Split by space
        let mut current : Array[Char] = []
        for c in caps_str {
          if c == ' ' || c == '\n' {
            if current.length() > 0 {
              let sb = StringBuilder::new()
              for ch in current {
                sb.write_char(ch)
              }
              result.push(sb.to_string())
              current = []
            }
          } else {
            current.push(c)
          }
        }
        if current.length() > 0 {
          let sb = StringBuilder::new()
          for ch in current {
            sb.write_char(ch)
          }
          result.push(sb.to_string())
        }
        break // Only first line has capabilities
      }
    }
  }
  result
}

///|
fn substring_from_index(s : String, start : Int) -> String {
  let chars = s.to_array()
  if start >= chars.length() {
    return ""
  }
  let result = StringBuilder::new()
  for i = start; i < chars.length(); i = i + 1 {
    result.write_char(chars[i])
  }
  result.to_string()
}

///|
fn remote_bytes_to_string(data : Bytes) -> String {
  let result = StringBuilder::new()
  for b in data {
    result.write_char(b.to_int().unsafe_to_char())
  }
  result.to_string()
}

///|
/// Discover refs and capabilities from remote
pub async fn discover_refs(
  remote : Remote,
) -> (Array[(ObjectId, String)], Array[String]) raise GitError {
  let url = remote.info_refs_url()
  let headers : Map[String, String] = {
    "User-Agent": "git/moonbit",
    "Accept": "application/x-git-receive-pack-advertisement",
  }
  let (response, data) = @http.get(url, headers~) catch {
    e => raise GitError::IoError("HTTP request failed: \{e}")
  }
  if response.code != 200 {
    raise GitError::ProtocolError(
      "Failed to discover refs: HTTP \{response.code}",
    )
  }

  // Skip service announcement line if present
  // Format: "# service=git-receive-pack\n" followed by flush
  let refs = parse_refs(data)
  let caps = extract_capabilities(data)
  (refs, caps)
}

///|
/// Push a packfile to remote repository
pub async fn push(remote : Remote, req : PushRequest) -> String raise GitError {
  // Step 1: Discover refs to get capabilities
  let (_, caps) = discover_refs(remote)

  // Check for required capabilities
  let has_report_status = caps.contains("report-status")
  if not(has_report_status) {
    raise GitError::ProtocolError("Server does not support report-status")
  }

  // Step 2: Send receive-pack request
  let url = remote.receive_pack_url()
  let body = build_receive_pack_body(req)
  let headers : Map[String, String] = {
    "User-Agent": "git/moonbit",
    "Content-Type": "application/x-git-receive-pack-request",
    "Accept": "application/x-git-receive-pack-result",
  }
  let (response, response_data) = @http.post(url, body, headers~) catch {
    e => raise GitError::IoError("HTTP request failed: \{e}")
  }
  if response.code != 200 {
    raise GitError::ProtocolError("Failed to push: HTTP \{response.code}")
  }

  // Step 3: Parse response
  match parse_receive_pack_response(response_data) {
    Ok(msg) => msg
    Err(e) => raise e
  }
}

///|
/// Push a single file as a new commit
pub async fn push_file(
  remote : Remote,
  content : Bytes,
  filename : String,
  message : String,
  author : String,
  timestamp : Int64,
  parent : ObjectId?,
) -> ObjectId raise GitError {
  // Create commit
  let parents = match parent {
    Some(p) => [p]
    None => []
  }
  let commit = Commit::new(
    ObjectId::zero(), // placeholder, will be replaced
    parents,
    author,
    timestamp,
    "+0000",
    author,
    timestamp,
    "+0000",
    message,
  )
  let (commit_id, packfile) = create_commit_packfile(content, filename, commit)

  // Determine old_id
  let old_id = match parent {
    Some(p) => p
    None => ObjectId::zero()
  }

  // Push
  let req = PushRequest::new(old_id, commit_id, "refs/heads/main", packfile)
  let _ = push(remote, req)
  commit_id
}

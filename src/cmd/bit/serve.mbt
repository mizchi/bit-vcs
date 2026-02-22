///|
fn print_hub_serve_usage() -> Unit {
  println(
    "Usage: bit hub serve [<relay-url>] [--repo <name>] [--allow-push] [--broadcast] [--auto-fetch] [--room <name>]",
  )
  println("")
  println("Serve the current repository via relay for remote cloning.")
  println("The relay URL should use relay+https:// or relay+http:// prefix.")
  println("")
  println("Options:")
  println("  --repo <name>    Repository name to advertise")
  println("  --allow-push     Accept incoming push (receive-pack)")
  println("  --broadcast      Broadcast feature notifications on push")
  println(
    "  --auto-fetch     Auto-fetch when feature-broadcast is detected in room",
  )
  println(
    "  --room <name>    Room name for broadcast/auto-fetch (default: serve-{session_id})",
  )
  println("  -h, --help       Show this help")
}

///|
struct HubServeOptions {
  relay_url : String
  _repo : String?
  allow_push : Bool
  broadcast : Bool
  auto_fetch : Bool
  room : String?
}

///|
fn parse_hub_serve_options(args : Array[String]) -> HubServeOptions? {
  let mut relay_url : String? = None
  let mut repo : String? = None
  let mut allow_push = false
  let mut broadcast = false
  let mut auto_fetch = false
  let mut room : String? = None
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    if arg == "-h" || arg == "--help" {
      print_hub_serve_usage()
      return None
    }
    if arg == "--allow-push" {
      allow_push = true
      i += 1
      continue
    }
    if arg == "--broadcast" {
      broadcast = true
      i += 1
      continue
    }
    if arg == "--auto-fetch" {
      auto_fetch = true
      i += 1
      continue
    }
    if arg == "--room" && i + 1 < args.length() {
      room = Some(args[i + 1])
      i += 2
      continue
    }
    if arg.has_prefix("--room=") {
      room = Some(String::unsafe_substring(arg, start=7, end=arg.length()))
      i += 1
      continue
    }
    if arg == "--repo" && i + 1 < args.length() {
      repo = Some(args[i + 1])
      i += 2
      continue
    }
    if arg.has_prefix("--repo=") {
      repo = Some(String::unsafe_substring(arg, start=7, end=arg.length()))
      i += 1
      continue
    }
    if not(arg.has_prefix("-")) && relay_url is None {
      relay_url = Some(arg)
      i += 1
      continue
    }
    i += 1
  }
  let url = match relay_url {
    Some(u) => u
    None =>
      match @sys.get_env_var("BIT_RELAY_URL") {
        Some(u) => u
        None => {
          println("Error: relay URL required")
          print_hub_serve_usage()
          return None
        }
      }
  }
  Some({ relay_url: url, _repo: repo, allow_push, broadcast, auto_fetch, room })
}

///|
fn serve_parse_relay_base_url(remote_url : String) -> String? {
  if remote_url.has_prefix("relay+http://") ||
    remote_url.has_prefix("relay+https://") {
    let raw = String::unsafe_substring(
      remote_url,
      start=6,
      end=remote_url.length(),
    )
    Some(serve_trim_trailing_slash(raw))
  } else if remote_url.has_prefix("relay://") {
    let suffix = String::unsafe_substring(
      remote_url,
      start=8,
      end=remote_url.length(),
    )
    Some(serve_trim_trailing_slash("http://" + suffix))
  } else if remote_url.has_prefix("http://") ||
    remote_url.has_prefix("https://") {
    Some(serve_trim_trailing_slash(remote_url))
  } else {
    None
  }
}

///|
fn serve_trim_trailing_slash(s : String) -> String {
  if s.has_suffix("/") {
    String::unsafe_substring(s, start=0, end=s.length() - 1)
  } else {
    s
  }
}

///|
fn serve_decode_bytes(data : Bytes) -> String {
  @encoding.decoder(@encoding.Encoding::UTF8).decode_lossy(data[:])
}

///|
fn serve_json_get_string(obj : Map[String, Json], key : String) -> String? {
  match obj.get(key) {
    Some(Json::String(value)) => Some(value)
    _ => None
  }
}

///|
fn serve_b64_char(idx : Int) -> Char {
  let table = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
  let mut pos = 0
  for c in table {
    if pos == idx {
      return c
    }
    pos += 1
  }
  'A'
}

///|
fn serve_base64_encode(data : Bytes) -> String {
  let out = StringBuilder::new()
  let len = data.length()
  let mut i = 0
  while i < len {
    let b0 = data[i].to_int()
    let b1 = if i + 1 < len { data[i + 1].to_int() } else { 0 }
    let b2 = if i + 2 < len { data[i + 2].to_int() } else { 0 }
    let n = (b0 << 16) | (b1 << 8) | b2
    out.write_char(serve_b64_char((n >> 18) & 0x3f))
    out.write_char(serve_b64_char((n >> 12) & 0x3f))
    if i + 1 < len {
      out.write_char(serve_b64_char((n >> 6) & 0x3f))
    } else {
      out.write_char('=')
    }
    if i + 2 < len {
      out.write_char(serve_b64_char(n & 0x3f))
    } else {
      out.write_char('=')
    }
    i += 3
  }
  out.to_string()
}

///|
fn serve_b64_decode_char(c : Char) -> Int {
  if c >= 'A' && c <= 'Z' {
    c.to_int() - 'A'.to_int()
  } else if c >= 'a' && c <= 'z' {
    c.to_int() - 'a'.to_int() + 26
  } else if c >= '0' && c <= '9' {
    c.to_int() - '0'.to_int() + 52
  } else if c == '+' {
    62
  } else if c == '/' {
    63
  } else {
    -1
  }
}

///|
fn serve_base64_decode(b64 : String) -> Bytes {
  let out : Array[Byte] = []
  let chars : Array[Int] = []
  for c in b64 {
    if c == '=' {
      break
    }
    let v = serve_b64_decode_char(c)
    if v >= 0 {
      chars.push(v)
    }
  }
  let mut i = 0
  while i + 1 < chars.length() {
    if i + 3 < chars.length() {
      let n = (chars[i] << 18) |
        (chars[i + 1] << 12) |
        (chars[i + 2] << 6) |
        chars[i + 3]
      out.push(((n >> 16) & 0xff).to_byte())
      out.push(((n >> 8) & 0xff).to_byte())
      out.push((n & 0xff).to_byte())
      i += 4
    } else if i + 2 < chars.length() {
      let n = (chars[i] << 18) | (chars[i + 1] << 12) | (chars[i + 2] << 6)
      out.push(((n >> 16) & 0xff).to_byte())
      out.push(((n >> 8) & 0xff).to_byte())
      i += 3
    } else {
      let n = (chars[i] << 18) | (chars[i + 1] << 12)
      out.push(((n >> 16) & 0xff).to_byte())
      i += 2
    }
  }
  Bytes::from_array(FixedArray::makei(out.length(), fn(idx) { out[idx] }))
}

///|
struct ServeSession {
  session_id : String
  session_token : String
}

///|
async fn serve_register_session(base_url : String) -> ServeSession raise Error {
  let url = base_url + "/api/v1/serve/register"
  let headers : Map[String, String] = { "Content-Type": "application/json" }
  let (response, body) = @bitnative.native_http_post(
    url,
    Bytes::new(0),
    headers,
  )
  if response.code != 200 {
    raise @bitcore.GitError::ProtocolError(
      "Failed to register session: HTTP \{response.code}",
    )
  }
  let text = serve_decode_bytes(body)
  let parsed = @json.parse(text) catch {
    _ =>
      raise @bitcore.GitError::ProtocolError(
        "Failed to parse register response",
      )
  }
  guard parsed is Json::Object(obj) else {
    raise @bitcore.GitError::ProtocolError("Invalid register response format")
  }
  guard serve_json_get_string(obj, "session_id") is Some(session_id) else {
    raise @bitcore.GitError::ProtocolError(
      "Missing session_id in register response",
    )
  }
  guard serve_json_get_string(obj, "session_token") is Some(session_token) else {
    raise @bitcore.GitError::ProtocolError(
      "Missing session_token in register response",
    )
  }
  { session_id, session_token }
}

///|
struct ServePollRequest {
  request_id : String
  req_method : String
  path : String
  _headers : Map[String, String]
  body_base64 : String?
}

///|
fn serve_parse_poll_response(body : Bytes) -> Array[ServePollRequest]? {
  let text = serve_decode_bytes(body)
  let parsed = @json.parse(text) catch { _ => return None }
  guard parsed is Json::Object(root) else { return None }
  match root.get("ok") {
    Some(Json::True) => ()
    _ => return None
  }
  let requests : Array[ServePollRequest] = []
  guard root.get("requests") is Some(Json::Array(arr)) else {
    return Some(requests)
  }
  for item in arr {
    guard item is Json::Object(obj) else { continue }
    let request_id = match serve_json_get_string(obj, "request_id") {
      Some(s) => s
      None => continue
    }
    let req_method = match serve_json_get_string(obj, "method") {
      Some(s) => s
      None => "GET"
    }
    let path = match serve_json_get_string(obj, "path") {
      Some(s) => s
      None => continue
    }
    let headers : Map[String, String] = {}
    match obj.get("headers") {
      Some(Json::Object(hobj)) =>
        for key, value in hobj {
          match value {
            Json::String(v) => headers[key] = v
            _ => ()
          }
        }
      _ => ()
    }
    let body_base64 : String? = serve_json_get_string(obj, "body_base64")
    requests.push({
      request_id,
      req_method,
      path,
      _headers: headers,
      body_base64,
    })
  }
  Some(requests)
}

///|
async fn serve_poll(
  base_url : String,
  session_id : String,
  timeout : Int,
  session_token? : String = "",
) -> Array[ServePollRequest] raise Error {
  let url = if session_token.length() > 0 {
    "\{base_url}/api/v1/serve/poll?session=\{session_id}&timeout=\{timeout}&session_token=\{session_token}"
  } else {
    "\{base_url}/api/v1/serve/poll?session=\{session_id}&timeout=\{timeout}"
  }
  let headers : Map[String, String] = {}
  let (response, body) = @bitnative.native_http_get(url, headers)
  if response.code != 200 {
    raise @bitcore.GitError::ProtocolError("Poll failed: HTTP \{response.code}")
  }
  match serve_parse_poll_response(body) {
    Some(requests) => requests
    None =>
      raise @bitcore.GitError::ProtocolError("Failed to parse poll response")
  }
}

///|
fn serve_concat_bytes(chunks : Array[Bytes]) -> Bytes {
  let result : Array[Byte] = []
  for chunk in chunks {
    for b in chunk {
      result.push(b)
    }
  }
  Bytes::from_array(FixedArray::makei(result.length(), fn(i) { result[i] }))
}

///|
async fn serve_respond(
  base_url : String,
  session_id : String,
  request_id : String,
  status : Int,
  response_headers : Map[String, String],
  body_base64 : String,
  session_token? : String = "",
) -> Unit raise Error {
  let url = if session_token.length() > 0 {
    "\{base_url}/api/v1/serve/respond?session=\{session_id}&session_token=\{session_token}"
  } else {
    "\{base_url}/api/v1/serve/respond?session=\{session_id}"
  }
  let headers_obj : Map[String, Json] = {}
  for entry in response_headers.to_array() {
    let (key, value) = entry
    headers_obj[key] = Json::string(value)
  }
  let payload_obj : Map[String, Json] = {}
  payload_obj["request_id"] = Json::string(request_id)
  payload_obj["status"] = Json::number(status.to_double())
  payload_obj["headers"] = Json::object(headers_obj)
  payload_obj["body_base64"] = Json::string(body_base64)
  let payload = Json::object(payload_obj)
  let payload_text = payload.stringify()
  let payload_bytes = @encoding.encode(@encoding.Encoding::UTF8, payload_text)
  let headers : Map[String, String] = { "Content-Type": "application/json" }
  let (response, _body) = @bitnative.native_http_post(
    url, payload_bytes, headers,
  )
  if response.code != 200 {
    eprint_line(
      "Warning: respond failed for request \{request_id}: HTTP \{response.code}",
    )
  }
}

///|

///|
fn serve_extract_query_param(path : String, param : String) -> String? {
  let query_start = path.find("?")
  guard query_start is Some(idx) else { return None }
  let query = String::unsafe_substring(path, start=idx + 1, end=path.length())
  let prefix = param + "="
  for part_view in query.split("&") {
    let part = part_view.to_string()
    if part.has_prefix(prefix) {
      return Some(
        String::unsafe_substring(part, start=prefix.length(), end=part.length()),
      )
    }
  }
  None
}

///|
/// Rewrite ref names for incoming push: refs/heads/X -> refs/relay/incoming/heads/X
fn serve_rewrite_ref_incoming(refname : String) -> String {
  if refname.has_prefix("refs/") {
    let suffix = String::unsafe_substring(
      refname,
      start=5,
      end=refname.length(),
    )
    "refs/relay/incoming/" + suffix
  } else {
    "refs/relay/incoming/" + refname
  }
}

///|
async fn serve_handle_git_request(
  repo_root : String,
  req : ServePollRequest,
  allow_push? : Bool = false,
) -> (Int, Map[String, String], Bytes) raise Error {
  let path = req.path
  if path.has_prefix("/info/refs") {
    let service = serve_extract_query_param(path, "service")
    match service {
      Some("git-receive-pack") => {
        if not(allow_push) {
          let error_body = @encoding.encode(
            @encoding.Encoding::UTF8,
            "receive-pack not enabled",
          )
          return (403, {}, error_body)
        }
        let fs = OsFs::new()
        let root = normalize_repo_root(repo_root)
        let out = @bitlib.build_receive_pack_advertisement(fs, root)
        let service_line = "# service=git-receive-pack\n"
        let pkt_service = @protocol.pktline_encode(service_line)
        let flush_bytes = @encoding.encode(@encoding.Encoding::UTF8, "0000")
        let full_body = serve_concat_bytes([pkt_service, flush_bytes, out])
        let headers : Map[String, String] = {
          "Content-Type": "application/x-git-receive-pack-advertisement",
        }
        (200, headers, full_body)
      }
      _ => {
        // Default: git-upload-pack
        let fs = OsFs::new()
        let root = normalize_repo_root(repo_root)
        let out = @bitlib.build_upload_pack_advertisement(fs, root)
        let service_line = "# service=git-upload-pack\n"
        let pkt_service = @protocol.pktline_encode(service_line)
        let flush_bytes = @encoding.encode(@encoding.Encoding::UTF8, "0000")
        let full_body = serve_concat_bytes([pkt_service, flush_bytes, out])
        let headers : Map[String, String] = {
          "Content-Type": "application/x-git-upload-pack-advertisement",
        }
        (200, headers, full_body)
      }
    }
  } else if path.has_prefix("/git-receive-pack") {
    if not(allow_push) {
      let error_body = @encoding.encode(
        @encoding.Encoding::UTF8,
        "receive-pack not enabled",
      )
      return (403, {}, error_body)
    }
    let input_bytes = match req.body_base64 {
      Some(b64) => serve_base64_decode(b64)
      None => Bytes::new(0)
    }
    let fs = OsFs::new()
    let root = normalize_repo_root(repo_root)
    // Rewrite ref names in the raw protocol data to refs/relay/incoming/ namespace
    let (rewritten_bytes, original_refnames) = serve_rewrite_receive_pack_refs(
      input_bytes,
    )
    let out = @bitlib.receive_pack(fs, fs, root, rewritten_bytes)
    // Rewrite status response: translate rewritten refs back to original names
    let final_out = serve_rewrite_status_response(out, original_refnames)
    let headers : Map[String, String] = {
      "Content-Type": "application/x-git-receive-pack-result",
    }
    (200, headers, final_out)
  } else if path.has_prefix("/git-upload-pack") {
    let input_bytes = match req.body_base64 {
      Some(b64) => serve_base64_decode(b64)
      None => Bytes::new(0)
    }
    let fs = OsFs::new()
    let root = normalize_repo_root(repo_root)
    let protocol_version = @bitlib.get_protocol_version()
    let cmdline_config = @bitlib.parse_config_overrides()
    let out = if protocol_version == 2 {
      let pack_req = @bitlib.parse_upload_pack_request_v2(input_bytes)
      let config = @bitlib.build_upload_pack_config_with_overrides(
        fs, root, cmdline_config,
      )
      @bitlib.upload_pack_v2(fs, root, pack_req, config)
    } else {
      let pack_req = @bitlib.parse_upload_pack_request(input_bytes)
      @bitlib.upload_pack(fs, root, pack_req)
    }
    let headers : Map[String, String] = {
      "Content-Type": "application/x-git-upload-pack-result",
    }
    (200, headers, out)
  } else {
    let error_body = @encoding.encode(@encoding.Encoding::UTF8, "not found")
    (404, {}, error_body)
  }
}

///|
/// Rewrite ref names in raw receive-pack protocol data.
/// Returns (rewritten_bytes, mapping from rewritten -> original ref names)
fn serve_rewrite_receive_pack_refs(
  data : Bytes,
) -> (Bytes, Map[String, String]) {
  let rewrite_map : Map[String, String] = {}
  // Parse pkt-lines up to the flush, rewrite ref names, then append remaining pack data
  let out : Array[Byte] = []
  let mut i = 0
  let mut first = true
  // Parse command lines
  while i + 4 <= data.length() {
    let len = serve_parse_pkt_len(data, i)
    if len == 0 {
      // flush packet
      out.push(b'0')
      out.push(b'0')
      out.push(b'0')
      out.push(b'0')
      i += 4
      break
    }
    if len < 4 || i + len > data.length() {
      break
    }
    let line_start = i + 4
    let line_end = i + len
    let line = serve_bytes_to_string(data, line_start, line_end)
    let trimmed = if line.has_suffix("\n") {
      String::unsafe_substring(line, start=0, end=line.length() - 1)
    } else {
      line
    }
    // Split capabilities on first line
    let (command_part, caps_part) = if first {
      first = false
      match trimmed.find("\u0000") {
        Some(idx) => {
          let cmd = String::unsafe_substring(trimmed, start=0, end=idx)
          let caps = String::unsafe_substring(
            trimmed,
            start=idx,
            end=trimmed.length(),
          )
          (cmd, caps)
        }
        None => (trimmed, "")
      }
    } else {
      (trimmed, "")
    }
    // Parse: old_id new_id refname
    let parts = serve_split_spaces(command_part)
    let rewritten_line = if parts.length() >= 3 {
      let original_ref = parts[2]
      let rewritten_ref = serve_rewrite_ref_incoming(original_ref)
      rewrite_map[rewritten_ref] = original_ref
      parts[0] + " " + parts[1] + " " + rewritten_ref + caps_part + "\n"
    } else {
      line
    }
    // Encode as pkt-line
    let pkt = @protocol.pktline_encode(rewritten_line)
    for b in pkt {
      out.push(b)
    }
    i += len
  }
  // Copy remaining pack data verbatim
  while i < data.length() {
    out.push(data[i])
    i += 1
  }
  let result = Bytes::from_array(
    FixedArray::makei(out.length(), fn(idx) { out[idx] }),
  )
  (result, rewrite_map)
}

///|
/// Rewrite status response bytes: replace rewritten ref names with originals
fn serve_rewrite_status_response(
  data : Bytes,
  rewrite_map : Map[String, String],
) -> Bytes {
  if rewrite_map.length() == 0 {
    return data
  }
  let out : Array[Byte] = []
  let mut i = 0
  while i + 4 <= data.length() {
    let len = serve_parse_pkt_len(data, i)
    if len == 0 {
      // flush packet
      out.push(b'0')
      out.push(b'0')
      out.push(b'0')
      out.push(b'0')
      i += 4
      continue
    }
    if len < 4 || i + len > data.length() {
      break
    }
    let line = serve_bytes_to_string(data, i + 4, i + len)
    // Check for "ok refname\n" or "ng refname msg\n"
    let rewritten_line = if line.has_prefix("ok ") {
      let refname = if line.has_suffix("\n") {
        String::unsafe_substring(line, start=3, end=line.length() - 1)
      } else {
        String::unsafe_substring(line, start=3, end=line.length())
      }
      match rewrite_map.get(refname) {
        Some(orig) => "ok \{orig}\n"
        None => line
      }
    } else if line.has_prefix("ng ") {
      let rest = String::unsafe_substring(line, start=3, end=line.length())
      let trimmed_rest = if rest.has_suffix("\n") {
        String::unsafe_substring(rest, start=0, end=rest.length() - 1)
      } else {
        rest
      }
      match trimmed_rest.find(" ") {
        Some(sp) => {
          let refname = String::unsafe_substring(trimmed_rest, start=0, end=sp)
          let msg = String::unsafe_substring(
            trimmed_rest,
            start=sp + 1,
            end=trimmed_rest.length(),
          )
          match rewrite_map.get(refname) {
            Some(orig) => "ng \{orig} \{msg}\n"
            None => line
          }
        }
        None => line
      }
    } else {
      line
    }
    let pkt = @protocol.pktline_encode(rewritten_line)
    for b in pkt {
      out.push(b)
    }
    i += len
  }
  Bytes::from_array(FixedArray::makei(out.length(), fn(idx) { out[idx] }))
}

///|
fn serve_parse_pkt_len(data : Bytes, start : Int) -> Int {
  if start + 4 > data.length() {
    return 0
  }
  let mut v = 0
  for j in 0..<4 {
    let c = data[start + j].to_int()
    let digit = if c >= 0x30 && c <= 0x39 {
      c - 0x30
    } else if c >= 0x61 && c <= 0x66 {
      c - 0x61 + 10
    } else if c >= 0x41 && c <= 0x46 {
      c - 0x41 + 10
    } else {
      return 0
    }
    v = v * 16 + digit
  }
  v
}

///|
fn serve_bytes_to_string(data : Bytes, start : Int, end : Int) -> String {
  let buf = StringBuilder::new()
  let mut i = start
  while i < end {
    buf.write_char(data[i].to_int().unsafe_to_char())
    i += 1
  }
  buf.to_string()
}

///|
fn serve_split_spaces(s : String) -> Array[String] {
  let out : Array[String] = []
  let buf = StringBuilder::new()
  for c in s {
    if c == ' ' {
      out.push(buf.to_string())
      buf.reset()
    } else {
      buf.write_char(c)
    }
  }
  out.push(buf.to_string())
  out
}

///|
async fn handle_hub_serve(args : Array[String]) -> Unit raise Error {
  guard parse_hub_serve_options(args) is Some(options) else { return }
  guard serve_parse_relay_base_url(options.relay_url) is Some(base_url) else {
    eprint_line(
      "Error: invalid relay URL '\{options.relay_url}'. Use relay+https://... or relay+http://...",
    )
    @sys.exit(1)
    return
  }
  let repo_root = get_work_root()
  let session = serve_register_session(base_url)
  let session_id = session.session_id
  let session_token = session.session_token
  print_line("Session registered: \{session_id}")
  print_line("Clone URL: \{options.relay_url}/\{session_id}")
  if options.allow_push {
    print_line(
      "Push enabled: incoming pushes will be stored in refs/relay/incoming/",
    )
  }
  if options.broadcast {
    print_line("Broadcast enabled: feature notifications will be sent on push")
  }
  let effective_room = match options.room {
    Some(r) => r
    None => "serve-\{session_id}"
  }
  if options.auto_fetch {
    print_line(
      "Auto-fetch enabled: watching room '\{effective_room}' for feature broadcasts",
    )
  }
  print_line("Waiting for requests... (Ctrl-C to stop)")
  let poll_timeout = if options.auto_fetch { 5 } else { 30 }
  let mut room_cursor = 0
  while true {
    let requests = serve_poll(
      base_url,
      session_id,
      poll_timeout,
      session_token~,
    ) catch {
      err => {
        if @async.is_cancellation_error(err) {
          break
        }
        eprint_line("Poll error: \{err}, retrying...")
        continue
      }
    }
    for req in requests {
      print_line("[\{session_id}] \{req.req_method} \{req.path}")
      let (status, response_headers, body) = serve_handle_git_request(
        repo_root,
        req,
        allow_push=options.allow_push,
      ) catch {
        err => {
          eprint_line("Error handling request \{req.request_id}: \{err}")
          let error_body = @encoding.encode(
            @encoding.Encoding::UTF8,
            "internal server error",
          )
          (500, {}, error_body)
        }
      }
      // Broadcast feature notification on successful receive-pack
      if options.broadcast &&
        req.path.has_prefix("/git-receive-pack") &&
        status == 200 {
        let broadcast_room = match options.room {
          Some(r) => r
          None => ""
        }
        serve_broadcast_push_notification(
          base_url,
          session_id,
          repo_root,
          req.path,
          room=broadcast_room,
        ) catch {
          err => eprint_line("Broadcast error: \{err}")
        }
      }
      let body_b64 = serve_base64_encode(body)
      serve_respond(
        base_url,
        session_id,
        req.request_id,
        status,
        response_headers,
        body_b64,
        session_token~,
      ) catch {
        err => {
          if @async.is_cancellation_error(err) {
            break
          }
          eprint_line("Respond error: \{err}")
        }
      }
    }
    // Auto-fetch: poll room for feature-broadcast messages
    if options.auto_fetch {
      room_cursor = serve_auto_fetch_from_room(
        base_url, effective_room, session_id, repo_root, room_cursor,
      ) catch {
        err => {
          eprint_line("Auto-fetch poll error: \{err}")
          room_cursor
        }
      }
    }
  }
}

///|
/// Broadcast a push notification to the relay room
async fn serve_broadcast_push_notification(
  base_url : String,
  session_id : String,
  repo_root : String,
  _path : String,
  room? : String = "",
) -> Unit raise Error {
  // Collect incoming refs that were just updated
  let fs = OsFs::new()
  let root = normalize_repo_root(repo_root)
  let git_dir = root + "/.git"
  let incoming_dir = git_dir + "/refs/relay/incoming/heads"
  if not(fs.is_dir(incoming_dir)) {
    return
  }
  // Build broadcast payload with incoming refs
  let refs = @bitrepo.show_ref(fs, git_dir)
  let incoming_refs : Array[(String, String)] = []
  for item in refs {
    let (refname, id) = item
    if refname.has_prefix("refs/relay/incoming/") {
      incoming_refs.push((refname, id.to_hex()))
    }
  }
  if incoming_refs.length() == 0 {
    return
  }
  // Publish broadcast to relay
  let payload_obj : Map[String, Json] = {}
  payload_obj["type"] = Json::string("feature-broadcast")
  payload_obj["session_id"] = Json::string(session_id)
  let refs_arr : Array[Json] = []
  for item in incoming_refs {
    let (refname, hex) = item
    let ref_obj : Map[String, Json] = {}
    ref_obj["ref"] = Json::string(refname)
    ref_obj["commit"] = Json::string(hex)
    refs_arr.push(Json::object(ref_obj))
  }
  payload_obj["refs"] = Json::array(refs_arr)
  let payload = Json::object(payload_obj)
  let payload_text = payload.stringify()
  let payload_bytes = @encoding.encode(@encoding.Encoding::UTF8, payload_text)
  let room = if room.length() > 0 { room } else { "serve-\{session_id}" }
  let event_id = session_id + "-push-" + @bitcore.sha1(payload_bytes).to_hex()
  let url = "\{base_url}/api/v1/publish?room=\{room}&sender=\{session_id}&topic=notify&id=\{event_id}"
  let headers : Map[String, String] = {
    "Content-Type": "application/octet-stream",
  }
  let (response, _body) = @bitnative.native_http_post(
    url, payload_bytes, headers,
  )
  if response.code == 200 {
    print_line("[\{session_id}] Broadcast: feature push notification sent")
  } else {
    eprint_line("[\{session_id}] Broadcast warning: HTTP \{response.code}")
  }
}

///|
struct ServeFeatureBroadcast {
  sender_session_id : String
  refs : Array[(String, String)] // (refname, commit_hex)
}

///|
fn serve_parse_room_poll_response(
  body : Bytes,
) -> (Int, Array[ServeFeatureBroadcast])? {
  let text = serve_decode_bytes(body)
  let parsed = @json.parse(text) catch { _ => return None }
  guard parsed is Json::Object(root) else { return None }
  let next_cursor = match root.get("next_cursor") {
    Some(Json::Number(n, ..)) => n.to_int()
    _ => 0
  }
  let broadcasts : Array[ServeFeatureBroadcast] = []
  guard root.get("envelopes") is Some(Json::Array(items)) else {
    return Some((next_cursor, broadcasts))
  }
  for item in items {
    guard item is Json::Object(envelope_obj) else { continue }
    let sender = match serve_json_get_string(envelope_obj, "sender") {
      Some(s) => s
      None => ""
    }
    guard envelope_obj.get("payload") is Some(payload_json) else { continue }
    // payload may be a JSON string or object
    let payload_obj : Map[String, Json] = match payload_json {
      Json::Object(obj) => obj
      Json::String(s) => {
        let inner = @json.parse(s) catch { _ => continue }
        guard inner is Json::Object(obj) else { continue }
        obj
      }
      _ => continue
    }
    guard serve_json_get_string(payload_obj, "type") is Some(t) else {
      continue
    }
    if t != "feature-broadcast" {
      continue
    }
    let session_id = match serve_json_get_string(payload_obj, "session_id") {
      Some(s) => s
      None => sender
    }
    let refs : Array[(String, String)] = []
    match payload_obj.get("refs") {
      Some(Json::Array(ref_items)) =>
        for ref_item in ref_items {
          guard ref_item is Json::Object(ref_obj) else { continue }
          let refname = match serve_json_get_string(ref_obj, "ref") {
            Some(s) => s
            None => continue
          }
          let commit = match serve_json_get_string(ref_obj, "commit") {
            Some(s) => s
            None => continue
          }
          refs.push((refname, commit))
        }
      _ => ()
    }
    broadcasts.push({ sender_session_id: session_id, refs })
  }
  Some((next_cursor, broadcasts))
}

///|
async fn serve_auto_fetch_from_room(
  base_url : String,
  room : String,
  own_session_id : String,
  repo_root : String,
  cursor : Int,
) -> Int raise Error {
  let url = "\{base_url}/api/v1/poll?room=\{room}&after=\{cursor}&limit=50"
  let headers : Map[String, String] = {}
  let (response, body) = @bitnative.native_http_get(url, headers)
  if response.code != 200 {
    return cursor
  }
  guard serve_parse_room_poll_response(body) is Some((next_cursor, broadcasts)) else {
    return cursor
  }
  for broadcast in broadcasts {
    if broadcast.sender_session_id == own_session_id {
      continue
    }
    print_line(
      "[\{own_session_id}] Auto-fetch: detected broadcast from \{broadcast.sender_session_id}",
    )
    serve_fetch_from_session(
      base_url,
      broadcast.sender_session_id,
      broadcast.refs,
      repo_root,
    ) catch {
      err =>
        eprint_line(
          "Auto-fetch error from \{broadcast.sender_session_id}: \{err}",
        )
    }
  }
  next_cursor
}

///|
async fn serve_fetch_from_session(
  base_url : String,
  sender_session_id : String,
  refs_info : Array[(String, String)],
  repo_root : String,
) -> Unit raise Error {
  let proxied_url = base_url + "/git/" + sender_session_id
  let (remote_refs, _, _, _) = @bitnative.discover_upload_refs_http(
    proxied_url, true,
  )
  // Build wants from refs_info commit OIDs that exist on the remote
  let wants : Array[@bitcore.ObjectId] = []
  let ref_map : Map[String, String] = {} // commit_hex -> refname
  for item in refs_info {
    let (refname, commit_hex) = item
    ref_map[commit_hex] = refname
    for remote_item in remote_refs {
      let (remote_oid, _) = remote_item
      if remote_oid.to_hex() == commit_hex {
        wants.push(remote_oid)
        break
      }
    }
  }
  // If no matching wants, try all commit OIDs from refs_info
  if wants.length() == 0 {
    for item in refs_info {
      let (_, commit_hex) = item
      wants.push(@bitcore.ObjectId::from_hex(commit_hex))
    }
  }
  if wants.length() == 0 {
    return
  }
  let pack = @bitnative.fetch_pack_http(proxied_url, wants, true)
  if pack.length() == 0 {
    return
  }
  let objects = @pack.parse_packfile(pack)
  let fs = OsFs::new()
  let root = normalize_repo_root(repo_root)
  let git_dir = root + "/.git"
  @pack.write_packfile_with_index(fs, git_dir, pack, objects)
  // Write refs under refs/relay/remote/{session_id}/heads/{branch}
  for item in refs_info {
    let (refname, commit_hex) = item
    // Extract branch name: strip refs/relay/incoming/heads/ or refs/heads/ prefix
    let branch = if refname.has_prefix("refs/relay/incoming/heads/") {
      String::unsafe_substring(refname, start=25, end=refname.length())
    } else if refname.has_prefix("refs/heads/") {
      String::unsafe_substring(refname, start=11, end=refname.length())
    } else if refname.has_prefix("refs/") {
      String::unsafe_substring(refname, start=5, end=refname.length())
    } else {
      refname
    }
    let ref_path = git_dir +
      "/refs/relay/remote/" +
      sender_session_id +
      "/heads/" +
      branch
    let dir = serve_parent_path(ref_path)
    fs.mkdir_p(dir)
    fs.write_string(ref_path, commit_hex + "\n")
    print_line(
      "  Fetched: refs/relay/remote/\{sender_session_id}/heads/\{branch} -> \{commit_hex}",
    )
  }
}

///|
fn serve_parent_path(path : String) -> String {
  let mut last_slash = -1
  let mut i = 0
  for c in path {
    if c == '/' {
      last_slash = i
    }
    i += 1
  }
  if last_slash > 0 {
    String::unsafe_substring(path, start=0, end=last_slash)
  } else {
    path
  }
}

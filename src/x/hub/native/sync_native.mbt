///| Native hub sync operations (push/fetch requiring network access)

///|
/// Native adapter: ObjectDb + RepoFileSystem -> ObjectStore
priv struct NativeObjectStore {
  db : @lib.ObjectDb
  rfs : &@bit.RepoFileSystem
  fs : &@bit.FileSystem
  git_dir : String
}

///|
impl @lib.ObjectStore for NativeObjectStore with get(self, id) {
  self.db.get(self.rfs, id)
}

///|
impl @lib.ObjectStore for NativeObjectStore with put(self, obj_type, content) {
  let (id, compressed) = @bit.create_object(obj_type, content)
  @hub.write_object_bytes(self.fs, self.git_dir, id, compressed)
  id
}

///|
impl @lib.ObjectStore for NativeObjectStore with has(self, id) {
  let obj = self.db.get(self.rfs, id)
  obj is Some(_)
}

///|
/// Native read-only adapter for relay push.
priv struct NativeReadObjectStore {
  db : @lib.ObjectDb
  rfs : &@bit.RepoFileSystem
}

///|
impl @lib.ObjectStore for NativeReadObjectStore with get(self, id) {
  self.db.get(self.rfs, id)
}

///|
impl @lib.ObjectStore for NativeReadObjectStore with put(
  _self,
  _obj_type,
  _content,
) {
  raise @bit.GitError::InvalidObject("NativeReadObjectStore is read-only")
}

///|
impl @lib.ObjectStore for NativeReadObjectStore with has(self, id) {
  let obj = self.db.get(self.rfs, id)
  obj is Some(_)
}

///|
/// Native adapter: FileSystem + git_dir -> RefStore
priv struct NativeRefStore {
  fs : &@bit.FileSystem
  rfs : &@bit.RepoFileSystem
  git_dir : String
}

///|
impl @lib.RefStore for NativeRefStore with resolve(self, ref_name) {
  @lib.resolve_ref(self.rfs, self.git_dir, ref_name)
}

///|
impl @lib.RefStore for NativeRefStore with update(self, ref_name, id) {
  match id {
    Some(commit_id) => {
      let ref_path = join_path(self.git_dir, ref_name)
      let dir = parent_path(ref_path)
      self.fs.mkdir_p(dir)
      self.fs.write_string(ref_path, commit_id.to_hex() + "\n")
    }
    None => ()
  }
}

///|
impl @lib.RefStore for NativeRefStore with list(self, _prefix) {
  ignore(self)
  []
}

///|
/// Native read-only ref adapter for relay push.
priv struct NativeReadRefStore {
  rfs : &@bit.RepoFileSystem
  git_dir : String
}

///|
impl @lib.RefStore for NativeReadRefStore with resolve(self, ref_name) {
  @lib.resolve_ref(self.rfs, self.git_dir, ref_name)
}

///|
impl @lib.RefStore for NativeReadRefStore with update(_self, _ref_name, _id) {
  ()
}

///|
impl @lib.RefStore for NativeReadRefStore with list(self, _prefix) {
  ignore(self)
  []
}

///|
fn join_path(a : String, b : String) -> String {
  if a.has_suffix("/") {
    a + b
  } else {
    a + "/" + b
  }
}

///|
fn parent_path(path : String) -> String {
  let chars = path.to_array()
  let mut i = chars.length()
  while i > 0 {
    let idx = i - 1
    if chars[idx] == '/' {
      if idx == 0 {
        return "."
      }
      return String::unsafe_substring(path, start=0, end=idx)
    }
    i = i - 1
  }
  "."
}

///|
fn trim_trailing_slash(url : String) -> String {
  if url.length() > 1 && url.has_suffix("/") {
    String::unsafe_substring(url, start=0, end=url.length() - 1)
  } else {
    url
  }
}

///|
fn is_http_url(url : String) -> Bool {
  url.has_prefix("http://") || url.has_prefix("https://")
}

///|
fn relay_signing_key() -> String? {
  match @sys.get_env_var("BIT_COLLAB_SIGN_KEY") {
    Some(value) => if value.length() > 0 { Some(value) } else { None }
    None => None
  }
}

///|
fn relay_require_signed() -> Bool {
  match @sys.get_env_var("BIT_COLLAB_REQUIRE_SIGNED") {
    Some(value) => {
      let normalized = value.to_lower()
      normalized == "1" || normalized == "true" || normalized == "yes"
    }
    None => false
  }
}

///|
fn relay_auth_token() -> String? {
  match @sys.get_env_var("BIT_RELAY_AUTH_TOKEN") {
    Some(value) => if value.length() > 0 { Some(value) } else { None }
    None => None
  }
}

///|
fn relay_sender_safe_char(c : Char) -> Bool {
  (c >= 'a' && c <= 'z') ||
  (c >= 'A' && c <= 'Z') ||
  (c >= '0' && c <= '9') ||
  c == '.' ||
  c == '_' ||
  c == '-'
}

///|
fn relay_room_leading_char(c : Char) -> Bool {
  (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')
}

///|
fn relay_room_safe_char(c : Char) -> Bool {
  relay_room_leading_char(c) || c == '.' || c == '_' || c == '-'
}

///|
fn relay_is_valid_room_name(room : String) -> Bool {
  if room.length() == 0 || room.length() > 64 {
    return false
  }
  let mut first = true
  for c in room {
    if first {
      if not(relay_room_leading_char(c)) {
        return false
      }
      first = false
    } else if not(relay_room_safe_char(c)) {
      return false
    }
  }
  true
}

///|
fn normalize_relay_sender(raw : String) -> String {
  let trimmed = raw.trim(chars=" \n\r\t").to_string()
  let out = StringBuilder::new()
  for c in trimmed {
    if relay_sender_safe_char(c) {
      out.write_char(c)
    } else {
      out.write_char('-')
    }
  }
  let normalized = out.to_string()
  if normalized.length() == 0 {
    "bit"
  } else {
    normalized
  }
}

///|
fn relay_sender() -> String {
  match @sys.get_env_var("BIT_RELAY_SENDER") {
    Some(value) => normalize_relay_sender(value)
    None => "bit"
  }
}

///|
fn relay_conflict_policy() -> @hub.RecordMergePolicy {
  match @sys.get_env_var("BIT_HUB_CONFLICT_POLICY") {
    Some(value) =>
      match @hub.parse_record_merge_policy(value) {
        Some(policy) => policy
        None => @hub.default_record_merge_policy()
      }
    None => @hub.default_record_merge_policy()
  }
}

///|
extern "C" fn relay_native_time(ptr : Int) -> Int64 = "time"

///|
fn relay_unix_timestamp_sec() -> Int64 {
  relay_native_time(0)
}

///|
priv struct RelayHttpSigningConfig {
  private_key_file : String
  public_key : String
}

///|
priv struct RelayPublishHttpSignature {
  public_key : String
  signature : String
  timestamp_sec : Int64
  nonce : String
}

///|
fn relay_sign_private_key_file() -> String? {
  match @sys.get_env_var("BIT_RELAY_SIGN_PRIVATE_KEY_FILE") {
    Some(value) => {
      let normalized = value.trim(chars=" \n\r\t").to_string()
      if normalized.length() > 0 {
        Some(normalized)
      } else {
        None
      }
    }
    None => None
  }
}

///|
fn relay_sign_public_key() -> String? {
  match @sys.get_env_var("BIT_RELAY_SIGN_PUBLIC_KEY") {
    Some(value) => {
      let normalized = value.trim(chars=" \n\r\t").to_string()
      if normalized.length() > 0 {
        Some(normalized)
      } else {
        None
      }
    }
    None => None
  }
}

///|
fn relay_base64_to_base64url(base64 : String) -> String {
  let out = StringBuilder::new()
  for c in base64 {
    if c == '+' {
      out.write_char('-')
    } else if c == '/' {
      out.write_char('_')
    } else if c == '=' {
      ()
    } else {
      out.write_char(c)
    }
  }
  out.to_string()
}

///|
fn relay_extract_ed25519_public_key_from_der(der : Bytes) -> String? {
  if der.length() != 44 {
    return None
  }
  let prefix : Array[Byte] = [
    0x30, 0x2a, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x70, 0x03, 0x21, 0x00,
  ]
  for i = 0; i < prefix.length(); i = i + 1 {
    if der[i] != prefix[i] {
      return None
    }
  }
  let raw_key = der[12:44]
  let base64 = @base64.encode(raw_key, padding=false)
  Some(relay_base64_to_base64url(base64))
}

///|
fn relay_is_hex_char(c : Char) -> Bool {
  (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F')
}

///|
fn relay_extract_sha256_hex(output : String) -> String? {
  for line_view in output.split("\n") {
    let line = line_view.trim(chars=" \n\r\t").to_string()
    if line.length() == 0 {
      continue
    }
    let candidate_with_label = match line.find("=") {
      Some(eq_idx) =>
        String::unsafe_substring(line, start=eq_idx + 1, end=line.length())
      None => line
    }
    let candidate_trimmed = candidate_with_label
      .trim(chars=" \n\r\t")
      .to_string()
    let token = match candidate_trimmed.find(" ") {
      Some(space_idx) =>
        String::unsafe_substring(candidate_trimmed, start=0, end=space_idx)
      None => candidate_trimmed
    }
    if token.length() == 64 {
      let mut ok = true
      for c in token.to_array() {
        if not(relay_is_hex_char(c)) {
          ok = false
          break
        }
      }
      if ok {
        return Some(token.to_lower())
      }
    }
  }
  None
}

///|
async fn relay_prepare_process_stdin(
  text : String,
) -> &@process.ProcessInput raise @bit.GitError {
  let (stdin, writer) = @process.write_to_process() catch {
    err => raise @bit.GitError::IoError("relay sign: pipe failed: \{err}")
  }
  writer.write(text) catch {
    err => raise @bit.GitError::IoError("relay sign: pipe write failed: \{err}")
  }
  writer.close()
  stdin
}

///|
async fn relay_sha256_hex(text : String) -> String raise @bit.GitError {
  let stdin = relay_prepare_process_stdin(text)
  let (code, stdout, stderr) = @process.collect_output(
    "openssl",
    ["dgst", "-sha256", "-hex", "-r"],
    inherit_env=true,
    stdin~,
  ) catch {
    err =>
      raise @bit.GitError::IoError("relay sign: openssl dgst failed: \{err}")
  }
  if code != 0 {
    let err_text = stderr.text() catch { _ => "" }
    let normalized = err_text.trim(chars=" \n\r\t").to_string()
    raise @bit.GitError::IoError(
      "relay sign: openssl dgst error: \{normalized}",
    )
  }
  let out_text = stdout.text() catch { _ => "" }
  match relay_extract_sha256_hex(out_text) {
    Some(hex) => hex
    None =>
      raise @bit.GitError::IoError(
        "relay sign: openssl dgst returned unexpected output",
      )
  }
}

///|
async fn relay_sign_ed25519(
  private_key_file : String,
  message : String,
) -> String raise @bit.GitError {
  // Ed25519 is a oneshot signature scheme — openssl pkeyutl cannot read
  // from a pipe because it needs to know the input size upfront.  Write to
  // a temporary file so -in works reliably on both macOS and Linux.
  let tmp_in = "/tmp/bit-relay-sign-in-" +
    @env.now().to_int().to_string() +
    ".bin"
  let write_code = @process.run(
    "sh",
    ["-c", "cat > \"$BIT_SIGN_TMP\""],
    inherit_env=true,
    stdin=relay_prepare_process_stdin(message),
    extra_env={ "BIT_SIGN_TMP": tmp_in },
  ) catch {
    err =>
      raise @bit.GitError::IoError(
        "relay sign: failed to write temp file: \{err}",
      )
  }
  if write_code != 0 {
    raise @bit.GitError::IoError("relay sign: failed to write temp file")
  }
  let (code, stdout, stderr) = @process.collect_output(
    "sh",
    [
      "-c",
      "openssl pkeyutl -sign -rawin -inkey \"$BIT_RELAY_SIGN_PRIVATE_KEY_FILE\" -in \"$BIT_SIGN_TMP\" | openssl base64 -A; rm -f \"$BIT_SIGN_TMP\"",
    ],
    inherit_env=true,
    extra_env={
      "BIT_RELAY_SIGN_PRIVATE_KEY_FILE": private_key_file,
      "BIT_SIGN_TMP": tmp_in,
    },
  ) catch {
    err => {
      ignore(
        @process.run("rm", ["-f", tmp_in], inherit_env=true) catch { _ => -1 },
      )
      raise @bit.GitError::IoError(
        "relay sign: openssl pkeyutl failed: \{err}",
      )
    }
  }
  if code != 0 {
    let err_text = stderr.text() catch { _ => "" }
    let normalized = err_text.trim(chars=" \n\r\t").to_string()
    raise @bit.GitError::IoError(
      "relay sign: openssl pkeyutl error: \{normalized}",
    )
  }
  let base64_sig = stdout.text() catch { _ => "" }
  let normalized = base64_sig.trim(chars=" \n\r\t").to_string()
  if normalized.length() == 0 {
    raise @bit.GitError::IoError("relay sign: openssl produced empty signature")
  }
  relay_base64_to_base64url(normalized)
}

///|
async fn relay_resolve_public_key(
  private_key_file : String,
) -> String raise @bit.GitError {
  match relay_sign_public_key() {
    Some(explicit) => explicit
    None => {
      let (code, stdout, stderr) = @process.collect_output(
        "sh",
        [
          "-c", "openssl pkey -in \"$BIT_RELAY_SIGN_PRIVATE_KEY_FILE\" -pubout -outform DER | openssl base64 -A",
        ],
        inherit_env=true,
        extra_env={ "BIT_RELAY_SIGN_PRIVATE_KEY_FILE": private_key_file },
      ) catch {
        err =>
          raise @bit.GitError::IoError(
            "relay sign: openssl pkey failed: \{err}",
          )
      }
      if code != 0 {
        let err_text = stderr.text() catch { _ => "" }
        let normalized = err_text.trim(chars=" \n\r\t").to_string()
        raise @bit.GitError::IoError(
          "relay sign: openssl pkey error: \{normalized}",
        )
      }
      let der_base64 = stdout.text() catch { _ => "" }
      let normalized = der_base64.trim(chars=" \n\r\t").to_string()
      if normalized.length() == 0 {
        raise @bit.GitError::IoError(
          "relay sign: openssl returned empty public key",
        )
      }
      let der = @base64.decode(normalized) catch {
        _ =>
          raise @bit.GitError::IoError(
            "relay sign: invalid base64 from openssl public key",
          )
      }
      match relay_extract_ed25519_public_key_from_der(der) {
        Some(key) => key
        None =>
          raise @bit.GitError::IoError(
            "relay sign: unsupported public key format (expected Ed25519)",
          )
      }
    }
  }
}

///|
async fn relay_http_signing_config() -> RelayHttpSigningConfig? raise @bit.GitError {
  match relay_sign_private_key_file() {
    None => None
    Some(private_key_file) => {
      let public_key = relay_resolve_public_key(private_key_file)
      Some({ private_key_file, public_key })
    }
  }
}

///|
fn relay_canonicalize_json(value : Json) -> String {
  match value {
    Json::Null => "null"
    Json::True => "true"
    Json::False => "false"
    Json::String(text) => Json::string(text).stringify()
    Json::Number(number, ..) => Json::number(number).stringify()
    Json::Array(items) => {
      let parts : Array[String] = []
      for item in items {
        parts.push(relay_canonicalize_json(item))
      }
      "[" + parts.join(",") + "]"
    }
    Json::Object(obj) => {
      let entries = obj.to_array()
      entries.sort_by((a, b) => String::compare(a.0, b.0))
      let parts : Array[String] = []
      for entry in entries {
        let (key, item) = entry
        let quoted_key = Json::string(key).stringify()
        parts.push(quoted_key + ":" + relay_canonicalize_json(item))
      }
      "{" + parts.join(",") + "}"
    }
  }
}

///|
fn relay_build_publish_signing_message(
  sender : String,
  room : String,
  id : String,
  topic : String,
  timestamp_sec : Int64,
  nonce : String,
  payload_sha256 : String,
) -> String {
  [
    "v1",
    "sender=" + sender,
    "room=" + room,
    "id=" + id,
    "topic=" + topic,
    "ts=" + timestamp_sec.to_string(),
    "nonce=" + nonce,
    "payload_sha256=" + payload_sha256,
  ].join("\n")
}

///|
async fn relay_sign_publish_payload(
  config : RelayHttpSigningConfig?,
  sender : String,
  room : String,
  topic : String,
  id : String,
  payload : Json,
) -> RelayPublishHttpSignature? raise @bit.GitError {
  match config {
    None => None
    Some(signing) => {
      let timestamp_sec = relay_unix_timestamp_sec()
      let nonce_now = @env.now().to_int().to_int64()
      let nonce = "\{timestamp_sec}-\{nonce_now}-\{id}"
      let payload_sha256 = relay_sha256_hex(relay_canonicalize_json(payload))
      let message = relay_build_publish_signing_message(
        sender, room, id, topic, timestamp_sec, nonce, payload_sha256,
      )
      let signature = relay_sign_ed25519(signing.private_key_file, message)
      Some({ public_key: signing.public_key, signature, timestamp_sec, nonce })
    }
  }
}

///|
fn relay_headers_with_publish_signature(
  headers : Map[String, String],
  signature : RelayPublishHttpSignature?,
) -> Map[String, String] {
  let out = headers
  match signature {
    Some(auth) => {
      out["x-relay-public-key"] = auth.public_key
      out["x-relay-signature"] = auth.signature
      out["x-relay-timestamp"] = auth.timestamp_sec.to_string()
      out["x-relay-nonce"] = auth.nonce
    }
    None => ()
  }
  out
}

///|
fn relay_copy_headers(headers : Map[String, String]) -> Map[String, String] {
  let out : Map[String, String] = {}
  for entry in headers.to_array() {
    let (key, value) = entry
    out[key] = value
  }
  out
}

///|
fn relay_headers_with_auth(
  headers : Map[String, String],
  auth_token : String?,
) -> Map[String, String] {
  let out = headers
  match auth_token {
    Some(token) =>
      if token.has_prefix("Bearer ") || token.has_prefix("bearer ") {
        out["Authorization"] = token
      } else {
        out["Authorization"] = "Bearer " + token
      }
    None => ()
  }
  out
}

///|
fn parse_relay_base_url(remote_url : String) -> String? {
  if remote_url.has_prefix("relay+http://") ||
    remote_url.has_prefix("relay+https://") {
    let raw = String::unsafe_substring(
      remote_url,
      start=6,
      end=remote_url.length(),
    )
    Some(trim_trailing_slash(raw))
  } else if remote_url.has_prefix("relay://") {
    let suffix = String::unsafe_substring(
      remote_url,
      start=8,
      end=remote_url.length(),
    )
    Some(trim_trailing_slash("http://" + suffix))
  } else {
    None
  }
}

///|
priv struct RelayControlEndpoint {
  base_url : String
  room : String
  room_token : String?
}

///|
fn relay_query_get(raw_query : String?, key : String) -> String? {
  match raw_query {
    None => None
    Some(query) => {
      for part_view in query.split("&") {
        let part = part_view.to_string()
        if part.length() == 0 {
          continue
        }
        match part.find("=") {
          Some(eq_idx) => {
            let part_key = String::unsafe_substring(part, start=0, end=eq_idx)
            if part_key == key {
              return Some(
                String::unsafe_substring(
                  part,
                  start=eq_idx + 1,
                  end=part.length(),
                ),
              )
            }
          }
          None => if part == key { return Some("") }
        }
      }
      None
    }
  }
}

///|
fn relay_split_url_query(raw_url : String) -> (String, String?) {
  match raw_url.find("?") {
    Some(idx) =>
      (
        String::unsafe_substring(raw_url, start=0, end=idx),
        Some(
          String::unsafe_substring(raw_url, start=idx + 1, end=raw_url.length()),
        ),
      )
    None => (raw_url, None)
  }
}

///|
fn relay_resolve_control_endpoint(
  remote_url : String,
) -> RelayControlEndpoint raise @bit.GitError {
  let raw = match parse_relay_base_url(remote_url) {
    Some(base_url) => base_url
    None =>
      if is_http_url(remote_url) {
        trim_trailing_slash(remote_url)
      } else {
        raise @bit.GitError::InvalidObject(
          "relay url must be relay+http(s)://, relay://, or http(s)://",
        )
      }
  }
  let (raw_base_url, raw_query) = relay_split_url_query(raw)
  let base_url = trim_trailing_slash(raw_base_url)
  let room = match relay_query_get(raw_query, "room") {
    Some(value) => {
      let normalized = value.trim(chars=" \n\r\t").to_string()
      if normalized.length() == 0 {
        "main"
      } else {
        normalized
      }
    }
    None => "main"
  }
  if not(relay_is_valid_room_name(room)) {
    raise @bit.GitError::InvalidObject("invalid relay room: \{room}")
  }
  let room_token = relay_normalize_optional_text(
    relay_query_get(raw_query, "room_token"),
  )
  { base_url, room, room_token }
}

///|
fn should_fallback_to_relay(err : @bit.GitError, remote_url : String) -> Bool {
  if not(is_http_url(remote_url)) {
    return false
  }
  match err {
    @bit.GitError::ProtocolError(msg) => msg.contains("HTTP 404")
    _ => false
  }
}

///|
fn json_get_string(
  obj : Map[String, Json],
  key : String,
  fallback : String,
) -> String {
  match obj.get(key) {
    Some(Json::String(value)) => value
    Some(Json::Number(value, ..)) => value.to_string()
    Some(Json::True) => "true"
    Some(Json::False) => "false"
    _ => fallback
  }
}

///|
fn json_get_int(obj : Map[String, Json], key : String, fallback : Int) -> Int {
  match obj.get(key) {
    Some(Json::Number(value, ..)) => value.to_int()
    Some(Json::String(value)) =>
      @strconv.parse_int(value) catch {
        _ => fallback
      }
    _ => fallback
  }
}

///|
fn parse_relay_publish_accepted(text : String) -> Bool {
  let parsed = @json.parse(text) catch { _ => Json::object({}) }
  match parsed {
    Json::Object(obj) =>
      match obj.get("accepted") {
        Some(Json::True) => true
        _ => false
      }
    _ => false
  }
}

///|
fn parse_relay_poll_body(
  text : String,
) -> (Int, Array[@hub.HubRecord]) raise @bit.GitError {
  let parsed = @json.parse(text) catch {
    err =>
      raise @bit.GitError::InvalidObject(
        "invalid relay poll response: \{err.to_string()}",
      )
  }
  guard parsed is Json::Object(root) else {
    raise @bit.GitError::InvalidObject(
      "invalid relay poll response: expected object",
    )
  }
  let next_cursor = json_get_int(root, "next_cursor", 0)
  let records : Array[@hub.HubRecord] = []
  match root.get("envelopes") {
    Some(Json::Array(items)) =>
      for item in items {
        guard item is Json::Object(envelope_obj) else { continue }
        guard envelope_obj.get("payload") is Some(Json::Object(payload_obj)) else {
          continue
        }
        if json_get_string(payload_obj, "kind", "") != "hub.record" {
          continue
        }
        let record_text = json_get_string(payload_obj, "record", "")
        if record_text.length() == 0 {
          continue
        }
        records.push(@hub.parse_hub_record(record_text))
      }
    _ => ()
  }
  (next_cursor, records)
}

///|
fn relay_clone_announce_kind() -> String {
  "bit.clone.announce.v1"
}

///|
fn parse_relay_poll_clone_peers(
  text : String,
  include_self? : Bool = false,
  self_sender? : String = "",
) -> (Int, Array[(String, String, String?)]) raise @bit.GitError {
  let parsed = @json.parse(text) catch {
    err =>
      raise @bit.GitError::InvalidObject(
        "invalid relay poll response: \{err.to_string()}",
      )
  }
  guard parsed is Json::Object(root) else {
    raise @bit.GitError::InvalidObject(
      "invalid relay poll response: expected object",
    )
  }
  let next_cursor = json_get_int(root, "next_cursor", 0)
  let peers_by_sender : Map[String, (String, String, String?)] = {}
  match root.get("envelopes") {
    Some(Json::Array(items)) =>
      for item in items {
        guard item is Json::Object(envelope_obj) else { continue }
        let sender = json_get_string(envelope_obj, "sender", "")
          .trim(chars=" \n\r\t")
          .to_string()
        if sender.length() == 0 {
          continue
        }
        if not(include_self) && sender == self_sender {
          continue
        }
        guard envelope_obj.get("payload") is Some(Json::Object(payload_obj)) else {
          continue
        }
        if json_get_string(payload_obj, "kind", "") !=
          relay_clone_announce_kind() {
          continue
        }
        let clone_url = json_get_string(payload_obj, "clone_url", "")
          .trim(chars=" \n\r\t")
          .to_string()
        if clone_url.length() == 0 {
          continue
        }
        let repo = match payload_obj.get("repo") {
          Some(Json::String(raw_repo)) => {
            let normalized = raw_repo.trim(chars=" \n\r\t").to_string()
            if normalized.length() == 0 {
              None
            } else {
              Some(normalized)
            }
          }
          _ => None
        }
        peers_by_sender[sender] = (sender, clone_url, repo)
      }
    _ => ()
  }
  let entries = peers_by_sender.to_array()
  entries.sort_by((a, b) => String::compare(a.0, b.0))
  let peers : Array[(String, String, String?)] = []
  for entry in entries {
    let (_sender, peer) = entry
    peers.push(peer)
  }
  (next_cursor, peers)
}

///|
fn hub_record_entry_name(key : String) -> String {
  let (target_id, _) = @bit.create_blob_string(key)
  target_id.to_hex()
}

///|
fn relay_clock_to_string(clock : Map[String, Int64]) -> String {
  if clock.length() == 0 {
    return ""
  }
  let items = clock.to_array()
  items.sort_by((a, b) => String::compare(a.0, b.0))
  let parts : Array[String] = []
  for item in items {
    let (key, value) = item
    parts.push(key + "=" + value.to_string())
  }
  parts.join(",")
}

///|
fn relay_serialize_record_unsigned(record : @hub.HubRecord) -> String {
  let sb = StringBuilder::new()
  sb.write_string("version ")
  sb.write_string(record.version.to_string())
  sb.write_char('\n')
  sb.write_string("key ")
  sb.write_string(record.key)
  sb.write_char('\n')
  sb.write_string("kind ")
  sb.write_string(record.kind)
  sb.write_char('\n')
  sb.write_string("clock ")
  sb.write_string(relay_clock_to_string(record.clock))
  sb.write_char('\n')
  sb.write_string("timestamp ")
  sb.write_string(record.timestamp.to_string())
  sb.write_char('\n')
  sb.write_string("node ")
  sb.write_string(record.node)
  sb.write_char('\n')
  sb.write_string("deleted ")
  sb.write_string(if record.deleted { "1" } else { "0" })
  sb.write_char('\n')
  sb.write_char('\n')
  sb.write_string(record.payload)
  sb.to_string()
}

///|
fn relay_compute_record_signature(
  record : @hub.HubRecord,
  signing_key : String,
) -> String {
  let state = @bit.Sha1State::new()
  state.update_string(relay_serialize_record_unsigned(record))
  state.update_string("\n--signing-key--\n")
  state.update_string(signing_key)
  state.finish().to_hex()
}

///|
fn relay_record_matches_signing_policy(
  record : @hub.HubRecord,
  signing_key : String?,
  require_signed : Bool,
) -> Bool {
  match signing_key {
    Some(key) =>
      match record.signature {
        Some(signature) =>
          signature == relay_compute_record_signature(record, key)
        None => not(require_signed)
      }
    None => not(require_signed)
  }
}

///|
fn commit_relay_notes(
  store : @hub.HubStore,
  objects : &@lib.ObjectStore,
  refs : &@lib.RefStore,
  message : String,
  timestamp : Int64,
) -> @bit.ObjectId raise @bit.GitError {
  let tree_entries : Array[@bit.TreeEntry] = []
  for item in store.entries.to_array() {
    let (name, blob_id) = item
    tree_entries.push(@bit.TreeEntry::new("100644", name, blob_id))
  }
  tree_entries.sort_by((a, b) => String::compare(a.name, b.name))
  let tree_bytes = @bit.serialize_tree(tree_entries)
  let tree_id = objects.put(@bit.ObjectType::Tree, tree_bytes)
  let parents = match store.head {
    Some(p) => [p]
    None => []
  }
  let commit = @bit.Commit::new(
    tree_id,
    parents,
    "Hub <hub@local>",
    timestamp,
    "+0000",
    "Hub <hub@local>",
    timestamp,
    "+0000",
    message + "\n",
  )
  let commit_bytes = @bit.serialize_commit_content(commit)
  let commit_id = objects.put(@bit.ObjectType::Commit, commit_bytes)
  refs.update(@hub.hub_notes_ref_name(), Some(commit_id))
  commit_id
}

///|
fn apply_relay_record(
  store : @hub.HubStore,
  objects : &@lib.ObjectStore,
  record : @hub.HubRecord,
  conflict_policy : @hub.RecordMergePolicy,
) -> Bool raise @bit.GitError {
  if not(
      relay_record_matches_signing_policy(
        record,
        store.signing_key(),
        store.require_signed(),
      ),
    ) {
    return false
  }
  let entry_name = hub_record_entry_name(record.key)
  let incoming_bytes = @utf8.encode(record.serialize())
  let current_blob_id = store.entries.get(entry_name)
  match current_blob_id {
    None => {
      let next_blob_id = objects.put(@bit.ObjectType::Blob, incoming_bytes)
      store.entries[entry_name] = next_blob_id
      true
    }
    Some(existing_blob_id) => {
      let existing_obj = objects.get(existing_blob_id)
      match existing_obj {
        None => {
          let next_blob_id = objects.put(@bit.ObjectType::Blob, incoming_bytes)
          store.entries[entry_name] = next_blob_id
          true
        }
        Some(existing_blob) => {
          let merged = @hub.merge_record_bytes_with_policy(
            existing_blob.data,
            incoming_bytes,
            conflict_policy,
          )
          if merged == existing_blob.data {
            false
          } else {
            let next_blob_id = objects.put(@bit.ObjectType::Blob, merged)
            store.entries[entry_name] = next_blob_id
            true
          }
        }
      }
    }
  }
}

///|
fn apply_relay_records(
  store : @hub.HubStore,
  objects : &@lib.ObjectStore,
  refs : &@lib.RefStore,
  records : Array[@hub.HubRecord],
  commit_timestamp : Int64,
  message : String,
  conflict_policy : @hub.RecordMergePolicy,
) -> Bool raise @bit.GitError {
  let mut changed = false
  for record in records {
    if apply_relay_record(store, objects, record, conflict_policy) {
      changed = true
    }
  }
  if changed {
    let ts = if commit_timestamp <= 0L { 1L } else { commit_timestamp }
    ignore(commit_relay_notes(store, objects, refs, message, ts))
  }
  changed
}

///|
fn relay_cursor_key(remote_url : String) -> String {
  let (id, _) = @bit.create_blob_string(remote_url)
  id.to_hex()
}

///|
fn relay_cursor_path(git_dir : String, remote_url : String) -> String {
  join_path(git_dir, "hub/relay-cursor/" + relay_cursor_key(remote_url))
}

///|
fn read_relay_cursor(
  rfs : &@bit.RepoFileSystem,
  git_dir : String,
  remote_url : String,
) -> Int {
  let path = relay_cursor_path(git_dir, remote_url)
  if not(rfs.is_file(path)) {
    return 0
  }
  let content = rfs.read_file(path) catch { _ => return 0 }
  let text = @utf8.decode_lossy(content[:])
  let first = match text.split("\n").iter().next() {
    Some(line) => line.to_string()
    None => ""
  }
  @strconv.parse_int(first) catch {
    _ => 0
  }
}

///|
fn write_relay_cursor(
  fs : &@bit.FileSystem,
  git_dir : String,
  remote_url : String,
  cursor : Int,
) -> Unit raise @bit.GitError {
  let path = relay_cursor_path(git_dir, remote_url)
  let dir = parent_path(path)
  fs.mkdir_p(dir)
  fs.write_string(path, cursor.to_string() + "\n")
}

///|
fn relay_publish_url(
  base_url : String,
  room : String,
  sender : String,
  event_id : String,
  room_token~ : String?,
) -> String {
  let base_query = "room=\{room}&sender=\{sender}&topic=notify&id=\{event_id}"
  let query = match room_token {
    Some(token) => base_query + "&room_token=" + token
    None => base_query
  }
  "\{base_url}/api/v1/publish?\{query}"
}

///|
fn relay_poll_url(
  base_url : String,
  room : String,
  after : Int,
  limit : Int,
  room_token~ : String?,
) -> String {
  let base_query = "room=\{room}&after=\{after}&limit=\{limit}"
  let query = match room_token {
    Some(token) => base_query + "&room_token=" + token
    None => base_query
  }
  "\{base_url}/api/v1/poll?\{query}"
}

///|
fn relay_normalize_optional_text(value : String?) -> String? {
  match value {
    Some(raw) => {
      let normalized = raw.trim(chars=" \n\r\t").to_string()
      if normalized.length() == 0 {
        None
      } else {
        Some(normalized)
      }
    }
    None => None
  }
}

///|
fn relay_build_clone_announce_payload(
  clone_url : String,
  repo~ : String?,
) -> Json {
  let payload_obj : Map[String, Json] = {}
  payload_obj["kind"] = Json::string(relay_clone_announce_kind())
  payload_obj["clone_url"] = Json::string(clone_url)
  match repo {
    Some(value) => payload_obj["repo"] = Json::string(value)
    None => ()
  }
  Json::object(payload_obj)
}

///|
fn relay_clone_announce_event_id(
  sender : String,
  clone_url : String,
  repo~ : String?,
) -> String {
  let repo_text = match repo {
    Some(value) => value
    None => ""
  }
  let stable_text = sender + "\n" + clone_url + "\n" + repo_text
  let (blob_id, _) = @bit.create_blob_string(stable_text)
  "clone-" + blob_id.to_hex()
}

///|
async fn relay_publish_clone_announce_with_http(
  remote_url : String,
  clone_url : String,
  http_post : async (String, Bytes, Map[String, String]) -> (
    @bit.HttpResponse,
    Bytes,
  ) raise @bit.GitError,
  repo~ : String?,
  auth_token~ : String?,
) -> Bool raise @bit.GitError {
  let endpoint = relay_resolve_control_endpoint(remote_url)
  let normalized_clone_url = clone_url.trim(chars=" \n\r\t").to_string()
  if normalized_clone_url.length() == 0 {
    raise @bit.GitError::InvalidObject(
      "hub sync clone-announce: --url must not be empty",
    )
  }
  let normalized_repo = relay_normalize_optional_text(repo)
  let sender = relay_sender()
  let payload_json = relay_build_clone_announce_payload(
    normalized_clone_url,
    repo=normalized_repo,
  )
  let payload_text = payload_json.stringify()
  let event_id = relay_clone_announce_event_id(
    sender,
    normalized_clone_url,
    repo=normalized_repo,
  )
  let base_headers = relay_headers_with_auth(
    { "Content-Type": "application/json" },
    auth_token,
  )
  let relay_signing = relay_http_signing_config()
  let publish_signature = relay_sign_publish_payload(
    relay_signing,
    sender,
    endpoint.room,
    "notify",
    event_id,
    payload_json,
  )
  let headers = relay_headers_with_publish_signature(
    relay_copy_headers(base_headers),
    publish_signature,
  )
  let url = relay_publish_url(
    endpoint.base_url,
    endpoint.room,
    sender,
    event_id,
    room_token=endpoint.room_token,
  )
  let (response, response_body) = http_post(
    url,
    @utf8.encode(payload_text),
    headers,
  )
  if response.code != 200 {
    let body_text = @utf8.decode_lossy(response_body[:])
    raise @bit.GitError::ProtocolError(
      "Relay clone announce failed: HTTP \{response.code} \{body_text}",
    )
  }
  parse_relay_publish_accepted(@utf8.decode_lossy(response_body[:]))
}

///|
async fn relay_list_clone_peers_with_http(
  remote_url : String,
  http_get : async (String, Map[String, String]) -> (@bit.HttpResponse, Bytes) raise @bit.GitError,
  auth_token~ : String?,
  include_self? : Bool = false,
) -> Array[(String, String, String?)] raise @bit.GitError {
  let endpoint = relay_resolve_control_endpoint(remote_url)
  let headers = relay_headers_with_auth(
    { "Accept": "application/json" },
    auth_token,
  )
  let url = relay_poll_url(
    endpoint.base_url,
    endpoint.room,
    0,
    200,
    room_token=endpoint.room_token,
  )
  let (response, response_body) = http_get(url, headers)
  if response.code != 200 {
    let body_text = @utf8.decode_lossy(response_body[:])
    raise @bit.GitError::ProtocolError(
      "Relay clone peers poll failed: HTTP \{response.code} \{body_text}",
    )
  }
  let poll_text = @utf8.decode_lossy(response_body[:])
  let (_, peers) = parse_relay_poll_clone_peers(
    poll_text,
    include_self~,
    self_sender=relay_sender(),
  )
  peers
}

///|
async fn relay_push_with_http(
  rfs : &@bit.RepoFileSystem,
  git_dir : String,
  remote_url : String,
  http_post : async (String, Bytes, Map[String, String]) -> (
    @bit.HttpResponse,
    Bytes,
  ) raise @bit.GitError,
  signing_key~ : String?,
  require_signed? : Bool = false,
  auth_token~ : String?,
) -> @hub.PrSyncResult raise @bit.GitError {
  let ref_name = @hub.hub_notes_ref_name()
  let local_commit = @lib.resolve_ref(rfs, git_dir, ref_name)
  guard local_commit is Some(local_id) else {
    return @hub.PrSyncResult::new(
      false,
      "No local hub notes ref found",
      None,
      None,
    )
  }
  let endpoint = relay_resolve_control_endpoint(remote_url)
  let sender = relay_sender()
  let db = @lib.ObjectDb::load(rfs, git_dir)
  let ro_objects : NativeReadObjectStore = { db, rfs }
  let ro_refs : NativeReadRefStore = { rfs, git_dir }
  let objects : &@lib.ObjectStore = ro_objects
  let refs : &@lib.RefStore = ro_refs
  let store = @hub.HubStore::load(
    objects,
    refs,
    node_id="relay",
    signing_key~,
    require_signed~,
  )
  let records = store.list_records(objects, "hub/", include_deleted=true)
  let base_headers = relay_headers_with_auth(
    { "Content-Type": "application/json" },
    auth_token,
  )
  let relay_signing = relay_http_signing_config()
  let mut accepted = 0
  for record in records {
    let payload_obj : Map[String, Json] = {}
    payload_obj["kind"] = Json::string("hub.record")
    payload_obj["record"] = Json::string(record.serialize())
    let payload_json = Json::object(payload_obj)
    let payload_text = payload_json.stringify()
    let (record_blob_id, _) = @bit.create_blob_string(record.serialize())
    let event_id = record_blob_id.to_hex()
    let publish_signature = relay_sign_publish_payload(
      relay_signing,
      sender,
      endpoint.room,
      "notify",
      event_id,
      payload_json,
    )
    let headers = relay_headers_with_publish_signature(
      relay_copy_headers(base_headers),
      publish_signature,
    )
    let url = relay_publish_url(
      endpoint.base_url,
      endpoint.room,
      sender,
      event_id,
      room_token=endpoint.room_token,
    )
    let (response, response_body) = http_post(
      url,
      @utf8.encode(payload_text),
      headers,
    )
    if response.code != 200 {
      let body_text = @utf8.decode_lossy(response_body[:])
      return @hub.PrSyncResult::new(
        false,
        "Relay publish failed: HTTP \{response.code} \{body_text}",
        Some(local_id),
        None,
      )
    }
    if parse_relay_publish_accepted(@utf8.decode_lossy(response_body[:])) {
      accepted += 1
    }
  }
  @hub.PrSyncResult::new(
    true,
    "Push successful (relay accepted \{accepted}/\{records.length()})",
    Some(local_id),
    Some(local_id),
  )
}

///|
async fn relay_fetch_with_http(
  hub : @hub.Hub,
  fs : &@bit.FileSystem,
  rfs : &@bit.RepoFileSystem,
  git_dir : String,
  remote_url : String,
  http_get : async (String, Map[String, String]) -> (@bit.HttpResponse, Bytes) raise @bit.GitError,
  signing_key~ : String?,
  require_signed? : Bool = false,
  auth_token~ : String?,
  conflict_policy? : @hub.RecordMergePolicy = @hub.default_record_merge_policy(),
) -> @hub.PrSyncResult raise @bit.GitError {
  let endpoint = relay_resolve_control_endpoint(remote_url)
  let cursor_remote_url = match endpoint.room_token {
    Some(token) =>
      "\{endpoint.base_url}?room=\{endpoint.room}&room_token=\{token}"
    None => "\{endpoint.base_url}?room=\{endpoint.room}"
  }
  let before = @lib.resolve_ref(rfs, git_dir, @hub.hub_notes_ref_name())
  let cursor = read_relay_cursor(rfs, git_dir, cursor_remote_url)
  let url = relay_poll_url(
    endpoint.base_url,
    endpoint.room,
    cursor,
    200,
    room_token=endpoint.room_token,
  )
  let headers = relay_headers_with_auth(
    { "Accept": "application/json" },
    auth_token,
  )
  let (response, data) = http_get(url, headers)
  if response.code != 200 {
    let body_text = @utf8.decode_lossy(data[:])
    return @hub.PrSyncResult::new(
      false,
      "Relay poll failed: HTTP \{response.code} \{body_text}",
      before,
      None,
    )
  }
  let poll_text = @utf8.decode_lossy(data[:])
  let (next_cursor, records) = parse_relay_poll_body(poll_text)
  let db = @lib.ObjectDb::load(rfs, git_dir)
  let native_objects : NativeObjectStore = { db, rfs, fs, git_dir }
  let native_refs : NativeRefStore = { fs, rfs, git_dir }
  let objects : &@lib.ObjectStore = native_objects
  let refs : &@lib.RefStore = native_refs
  let store = @hub.HubStore::load(
    objects,
    refs,
    node_id="relay",
    signing_key~,
    require_signed~,
  )
  let mut max_ts : Int64 = 0
  for record in records {
    if record.timestamp > max_ts {
      max_ts = record.timestamp
    }
  }
  let changed = apply_relay_records(
    store, objects, refs, records, max_ts, "hub relay fetch", conflict_policy,
  )
  write_relay_cursor(fs, git_dir, cursor_remote_url, next_cursor)
  if changed {
    hub.reload_store(objects, refs)
  }
  let after = @lib.resolve_ref(rfs, git_dir, @hub.hub_notes_ref_name())
  if changed {
    @hub.PrSyncResult::new(
      true,
      "Fetched relay records (\{records.length()})",
      after,
      after,
    )
  } else {
    @hub.PrSyncResult::new(
      true,
      "Already up to date (relay cursor=\{next_cursor})",
      before,
      before,
    )
  }
}

///|
/// Push hub notes ref to remote (git smart-http transport)
async fn hub_push_git_http(
  rfs : &@bit.RepoFileSystem,
  git_dir : String,
  remote_url : String,
) -> @hub.PrSyncResult raise @bit.GitError {
  let ref_name = @hub.hub_notes_ref_name()
  let local_commit = @lib.resolve_ref(rfs, git_dir, ref_name)
  guard local_commit is Some(local_id) else {
    return @hub.PrSyncResult::new(
      false,
      "No local hub notes ref found",
      None,
      None,
    )
  }
  let db = @lib.ObjectDb::load(rfs, git_dir)
  let objects = @lib.collect_reachable_objects(db, rfs, local_id)
  let pack = @pack.create_packfile(objects)
  let remote = @protocol.Remote::new(remote_url)
  let refs = @bitnative.discover_receive_refs_http(remote)
  let (old_id, push_ref) = @hub.find_remote_notes_ref(refs)
  let req = @protocol.PushRequest::new(old_id, local_id, push_ref, pack)
  let result = @bitnative.push(remote, req)
  if result.has_prefix("unpack ok") ||
    result.has_prefix("ok ") ||
    result.has_prefix("Push successful") {
    @hub.PrSyncResult::new(
      true,
      "Push successful",
      Some(local_id),
      Some(local_id),
    )
  } else {
    @hub.PrSyncResult::new(
      false,
      "Push failed: \{result}",
      Some(local_id),
      None,
    )
  }
}

///|
/// Fetch hub notes ref from remote and merge (git smart-http transport)
async fn hub_fetch_git_http(
  hub : @hub.Hub,
  fs : &@bit.FileSystem,
  rfs : &@bit.RepoFileSystem,
  git_dir : String,
  remote_url : String,
  conflict_policy? : @hub.RecordMergePolicy = @hub.default_record_merge_policy(),
) -> @hub.PrSyncResult raise @bit.GitError {
  let ref_name = @hub.hub_notes_ref_name()
  let (refs, _, _, _) = @bitnative.discover_upload_refs_http(remote_url, true)
  let remote_id = @hub.find_upload_notes_ref(refs)
  guard remote_id is Some((rid, remote_ref)) else {
    return @hub.PrSyncResult::new(
      false,
      "No remote hub notes ref found",
      @lib.resolve_ref(rfs, git_dir, ref_name),
      None,
    )
  }
  let pack = @bitnative.fetch_pack_http(remote_url, [rid], true)
  let objects = @pack.parse_packfile(pack)
  @pack.write_packfile_with_index(fs, git_dir, pack, objects)
  let remote_short = @hub.short_ref_name(remote_ref)
  let remote_ref_path = join_path(
    git_dir,
    "refs/remotes/origin/" + remote_short,
  )
  let dir = parent_path(remote_ref_path)
  fs.mkdir_p(dir)
  fs.write_string(remote_ref_path, rid.to_hex() + "\n")
  let local_commit = @lib.resolve_ref(rfs, git_dir, ref_name)
  let db = @lib.ObjectDb::load(rfs, git_dir)
  let native_objects : NativeObjectStore = { db, rfs, fs, git_dir }
  let native_refs : NativeRefStore = { fs, rfs, git_dir }
  let obj_store : &@lib.ObjectStore = native_objects
  let ref_store : &@lib.RefStore = native_refs
  match local_commit {
    None => {
      ref_store.update(@hub.hub_notes_ref_name(), Some(rid))
      hub.reload_store(obj_store, ref_store)
      @hub.PrSyncResult::new(
        true,
        "Fetched remote hub notes ref",
        Some(rid),
        Some(rid),
      )
    }
    Some(lid) =>
      if lid == rid {
        @hub.PrSyncResult::new(true, "Already up to date", Some(lid), Some(rid))
      } else {
        @hub.merge_notes_commits(
          hub,
          fs,
          git_dir,
          obj_store,
          ref_store,
          lid,
          rid,
          conflict_policy~,
        )
      }
  }
}

///|
/// Push hub notes ref to remote
pub async fn hub_push(
  _hub : @hub.Hub,
  rfs : &@bit.RepoFileSystem,
  git_dir : String,
  remote_url : String,
  signing_key~ : String?,
  require_signed~ : Bool?,
  auth_token~ : String?,
  conflict_policy~ : @hub.RecordMergePolicy?,
) -> @hub.PrSyncResult raise @bit.GitError {
  let effective_signing_key = match signing_key {
    Some(value) => Some(value)
    None => relay_signing_key()
  }
  let effective_require_signed = match require_signed {
    Some(value) => value
    None => relay_require_signed()
  }
  let effective_auth_token = match auth_token {
    Some(value) => Some(value)
    None => relay_auth_token()
  }
  let _effective_conflict_policy = match conflict_policy {
    Some(value) => value
    None => relay_conflict_policy()
  }
  match parse_relay_base_url(remote_url) {
    Some(_base_url) =>
      relay_push_with_http(
        rfs,
        git_dir,
        remote_url,
        @bitnative.native_http_post,
        signing_key=effective_signing_key,
        require_signed=effective_require_signed,
        auth_token=effective_auth_token,
      )
    None =>
      hub_push_git_http(rfs, git_dir, remote_url) catch {
        err => {
          if @async.is_being_cancelled() || @async.is_cancellation_error(err) {
            raise err
          }
          if should_fallback_to_relay(err, remote_url) {
            relay_push_with_http(
              rfs,
              git_dir,
              remote_url,
              @bitnative.native_http_post,
              signing_key=effective_signing_key,
              require_signed=effective_require_signed,
              auth_token=effective_auth_token,
            )
          } else {
            raise err
          }
        }
      }
  }
}

///|
pub async fn relay_publish_clone_announce(
  remote_url : String,
  clone_url : String,
  repo~ : String?,
  auth_token~ : String?,
) -> Bool raise @bit.GitError {
  let effective_auth_token = match auth_token {
    Some(value) => Some(value)
    None => relay_auth_token()
  }
  relay_publish_clone_announce_with_http(
    remote_url,
    clone_url,
    @bitnative.native_http_post,
    repo~,
    auth_token=effective_auth_token,
  )
}

///|
pub async fn relay_list_clone_peers(
  remote_url : String,
  auth_token~ : String?,
  include_self? : Bool = false,
) -> Array[(String, String, String?)] raise @bit.GitError {
  let effective_auth_token = match auth_token {
    Some(value) => Some(value)
    None => relay_auth_token()
  }
  relay_list_clone_peers_with_http(
    remote_url,
    @bitnative.native_http_get,
    auth_token=effective_auth_token,
    include_self~,
  )
}

///|
/// Fetch hub notes ref from remote and merge
pub async fn hub_fetch(
  hub : @hub.Hub,
  fs : &@bit.FileSystem,
  rfs : &@bit.RepoFileSystem,
  git_dir : String,
  remote_url : String,
  signing_key~ : String?,
  require_signed~ : Bool?,
  auth_token~ : String?,
  conflict_policy~ : @hub.RecordMergePolicy?,
) -> @hub.PrSyncResult raise @bit.GitError {
  let effective_signing_key = match signing_key {
    Some(value) => Some(value)
    None => relay_signing_key()
  }
  let effective_require_signed = match require_signed {
    Some(value) => value
    None => relay_require_signed()
  }
  let effective_auth_token = match auth_token {
    Some(value) => Some(value)
    None => relay_auth_token()
  }
  let effective_conflict_policy = match conflict_policy {
    Some(value) => value
    None => relay_conflict_policy()
  }
  match parse_relay_base_url(remote_url) {
    Some(_base_url) =>
      relay_fetch_with_http(
        hub,
        fs,
        rfs,
        git_dir,
        remote_url,
        @bitnative.native_http_get,
        signing_key=effective_signing_key,
        require_signed=effective_require_signed,
        auth_token=effective_auth_token,
        conflict_policy=effective_conflict_policy,
      )
    None =>
      hub_fetch_git_http(
        hub,
        fs,
        rfs,
        git_dir,
        remote_url,
        conflict_policy=effective_conflict_policy,
      ) catch {
        err => {
          if @async.is_being_cancelled() || @async.is_cancellation_error(err) {
            raise err
          }
          if should_fallback_to_relay(err, remote_url) {
            relay_fetch_with_http(
              hub,
              fs,
              rfs,
              git_dir,
              remote_url,
              @bitnative.native_http_get,
              signing_key=effective_signing_key,
              require_signed=effective_require_signed,
              auth_token=effective_auth_token,
              conflict_policy=effective_conflict_policy,
            )
          } else {
            raise err
          }
        }
      }
  }
}

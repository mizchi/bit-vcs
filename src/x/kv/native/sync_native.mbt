///| Native transport adapters for kv sync (http / websocket)

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
fn json_get_int64(
  obj : Map[String, Json],
  key : String,
  fallback : Int64,
) -> Int64 {
  match obj.get(key) {
    Some(Json::Number(value, ..)) => value.to_int64()
    Some(Json::String(value)) =>
      @strconv.parse_int64(value) catch {
        _ => fallback
      }
    _ => fallback
  }
}

///|
fn object_type_to_string(obj_type : @git.ObjectType) -> String {
  match obj_type {
    @git.ObjectType::Commit => "commit"
    @git.ObjectType::Tree => "tree"
    @git.ObjectType::Blob => "blob"
    @git.ObjectType::Tag => "tag"
  }
}

///|
fn parse_object_type(value : String) -> @git.ObjectType? {
  match value {
    "commit" => Some(@git.ObjectType::Commit)
    "tree" => Some(@git.ObjectType::Tree)
    "blob" => Some(@git.ObjectType::Blob)
    "tag" => Some(@git.ObjectType::Tag)
    _ => None
  }
}

///|
fn vector_clock_to_json(clock : @kv.VectorClock) -> Json {
  let obj : Map[String, Json] = {}
  for entry in clock.clocks {
    obj[entry.0] = Json::number(entry.1.to_double())
  }
  Json::object(obj)
}

///|
fn parse_vector_clock(value : Json) -> Result[@kv.VectorClock, String] {
  guard value is Json::Object(obj) else {
    return Err("clock must be an object")
  }
  let clocks : Map[String, Int64] = {}
  for entry in obj {
    let key = entry.0
    match entry.1 {
      Json::Number(number, ..) => clocks[key] = number.to_int64()
      Json::String(text) => {
        let parsed = @strconv.parse_int64(text) catch {
          _ => return Err("invalid clock value: \{text}")
        }
        clocks[key] = parsed
      }
      _ => return Err("invalid clock value for node: \{key}")
    }
  }
  Ok({ clocks, })
}

///|
fn object_ids_to_json(ids : Array[@git.ObjectId]) -> Json {
  Json::array(ids.map(fn(id) { Json::string(id.to_hex()) }))
}

///|
fn parse_object_id(
  value : Json,
  field : String,
) -> Result[@git.ObjectId, String] {
  guard value is Json::String(hex) else {
    return Err("\{field} must be string")
  }
  let id = @git.ObjectId::from_hex(hex) catch {
    _ => return Err("invalid object id for \{field}: \{hex}")
  }
  Ok(id)
}

///|
fn parse_object_id_array(
  value : Json,
  field : String,
) -> Result[Array[@git.ObjectId], String] {
  guard value is Json::Array(items) else {
    return Err("\{field} must be array")
  }
  let result : Array[@git.ObjectId] = []
  for item in items {
    let parsed = parse_object_id(item, field)
    match parsed {
      Ok(id) => result.push(id)
      Err(err) => return Err(err)
    }
  }
  Ok(result)
}

///|
fn git_object_to_json(obj : @kv.GitObject) -> Json {
  let json_obj : Map[String, Json] = {}
  json_obj["id"] = Json::string(obj.id.to_hex())
  json_obj["obj_type"] = Json::string(object_type_to_string(obj.obj_type))
  json_obj["data"] = Json::string(@base64.encode(obj.data, padding=true))
  Json::object(json_obj)
}

///|
fn parse_git_object(value : Json) -> Result[@kv.GitObject, String] {
  guard value is Json::Object(obj) else {
    return Err("git object must be object")
  }
  let id = match obj.get("id") {
    Some(id_json) => {
      let parsed = parse_object_id(id_json, "id")
      match parsed {
        Ok(v) => v
        Err(err) => return Err(err)
      }
    }
    None => return Err("git object missing id")
  }
  let obj_type_text = json_get_string(obj, "obj_type", "")
  let obj_type = parse_object_type(obj_type_text)
  guard obj_type is Some(obj_type_value) else {
    return Err("invalid object type: \{obj_type_text}")
  }
  let encoded = json_get_string(obj, "data", "")
  let data = @base64.decode(encoded) catch {
    _ => return Err("invalid object data (base64)")
  }
  Ok({ id, obj_type: obj_type_value, data })
}

///|
fn gossip_state_to_json(state : @kv.GossipState) -> Json {
  let obj : Map[String, Json] = {}
  obj["node_id"] = Json::string(state.node_id.id)
  obj["head"] = Json::string(state.head.to_hex())
  obj["clock"] = vector_clock_to_json(state.clock)
  obj["timestamp"] = Json::number(state.timestamp.to_double())
  Json::object(obj)
}

///|
fn parse_gossip_state(value : Json) -> Result[@kv.GossipState, String] {
  guard value is Json::Object(obj) else { return Err("state must be object") }
  let node_id = @kv.NodeId::new(json_get_string(obj, "node_id", ""))
  if node_id.id.length() == 0 {
    return Err("state.node_id is required")
  }
  let head = match obj.get("head") {
    Some(v) => {
      let parsed = parse_object_id(v, "state.head")
      match parsed {
        Ok(id) => id
        Err(err) => return Err(err)
      }
    }
    None => return Err("state.head is required")
  }
  let clock = match obj.get("clock") {
    Some(v) => {
      let parsed = parse_vector_clock(v)
      match parsed {
        Ok(clock) => clock
        Err(err) => return Err(err)
      }
    }
    None => @kv.VectorClock::new()
  }
  let timestamp = json_get_int64(obj, "timestamp", 0L)
  Ok({ node_id, head, clock, timestamp })
}

///|
fn gossip_message_to_json(msg : @kv.GossipMessage) -> Json {
  let obj : Map[String, Json] = {}
  match msg {
    @kv.GossipMessage::Announce(state) => {
      obj["type"] = Json::string("announce")
      obj["state"] = gossip_state_to_json(state)
    }
    @kv.GossipMessage::WantObjects(ids) => {
      obj["type"] = Json::string("want_objects")
      obj["ids"] = object_ids_to_json(ids)
    }
    @kv.GossipMessage::HaveObjects(objects) => {
      obj["type"] = Json::string("have_objects")
      obj["objects"] = Json::array(objects.map(fn(o) { git_object_to_json(o) }))
    }
    @kv.GossipMessage::SyncRequest(from, their_head) => {
      obj["type"] = Json::string("sync_request")
      obj["from"] = Json::string(from.id)
      obj["their_head"] = Json::string(their_head.to_hex())
    }
    @kv.GossipMessage::SyncResponse(objects, new_head) => {
      obj["type"] = Json::string("sync_response")
      obj["objects"] = Json::array(objects.map(fn(o) { git_object_to_json(o) }))
      obj["new_head"] = Json::string(new_head.to_hex())
    }
  }
  Json::object(obj)
}

///|
fn parse_gossip_message_json(
  json_value : Json,
) -> Result[@kv.GossipMessage, String] {
  guard json_value is Json::Object(obj) else {
    return Err("message must be object")
  }
  let msg_type = json_get_string(obj, "type", "")
  match msg_type {
    "announce" =>
      match obj.get("state") {
        Some(state_json) => {
          let parsed = parse_gossip_state(state_json)
          match parsed {
            Ok(state) => Ok(@kv.GossipMessage::Announce(state))
            Err(err) => Err(err)
          }
        }
        None => Err("announce.state is required")
      }
    "want_objects" =>
      match obj.get("ids") {
        Some(ids_json) => {
          let parsed = parse_object_id_array(ids_json, "ids")
          match parsed {
            Ok(ids) => Ok(@kv.GossipMessage::WantObjects(ids))
            Err(err) => Err(err)
          }
        }
        None => Err("want_objects.ids is required")
      }
    "have_objects" =>
      match obj.get("objects") {
        Some(Json::Array(items)) => {
          let objects : Array[@kv.GitObject] = []
          for item in items {
            let parsed = parse_git_object(item)
            match parsed {
              Ok(obj) => objects.push(obj)
              Err(err) => return Err(err)
            }
          }
          Ok(@kv.GossipMessage::HaveObjects(objects))
        }
        _ => Err("have_objects.objects must be array")
      }
    "sync_request" => {
      let from = @kv.NodeId::new(json_get_string(obj, "from", ""))
      if from.id.length() == 0 {
        return Err("sync_request.from is required")
      }
      let their_head = match obj.get("their_head") {
        Some(v) => {
          let parsed = parse_object_id(v, "their_head")
          match parsed {
            Ok(id) => id
            Err(err) => return Err(err)
          }
        }
        None => return Err("sync_request.their_head is required")
      }
      Ok(@kv.GossipMessage::SyncRequest(from, their_head))
    }
    "sync_response" => {
      let new_head = match obj.get("new_head") {
        Some(v) => {
          let parsed = parse_object_id(v, "new_head")
          match parsed {
            Ok(id) => id
            Err(err) => return Err(err)
          }
        }
        None => return Err("sync_response.new_head is required")
      }
      let objects : Array[@kv.GitObject] = []
      match obj.get("objects") {
        Some(Json::Array(items)) =>
          for item in items {
            let parsed = parse_git_object(item)
            match parsed {
              Ok(obj) => objects.push(obj)
              Err(err) => return Err(err)
            }
          }
        _ => return Err("sync_response.objects must be array")
      }
      Ok(@kv.GossipMessage::SyncResponse(objects, new_head))
    }
    _ => Err("unknown message type: \{msg_type}")
  }
}

///|
pub fn encode_gossip_message(msg : @kv.GossipMessage) -> String {
  gossip_message_to_json(msg).stringify()
}

///|
pub fn decode_gossip_message(
  text : String,
) -> Result[@kv.GossipMessage?, String] {
  let trimmed = text.trim().to_string()
  if trimmed.length() == 0 || trimmed == "null" {
    return Ok(None)
  }
  let parsed = @json.parse(trimmed) catch {
    err => return Err("invalid gossip json: \{err.to_string()}")
  }
  if parsed is Json::Object(obj) {
    match obj.get("message") {
      Some(message_json) => {
        let parsed_message = parse_gossip_message_json(message_json)
        match parsed_message {
          Ok(message) => Ok(Some(message))
          Err(err) => Err(err)
        }
      }
      None => {
        let parsed_message = parse_gossip_message_json(parsed)
        match parsed_message {
          Ok(message) => Ok(Some(message))
          Err(err) => Err(err)
        }
      }
    }
  } else {
    let parsed_message = parse_gossip_message_json(parsed)
    match parsed_message {
      Ok(message) => Ok(Some(message))
      Err(err) => Err(err)
    }
  }
}

///|
fn is_http_endpoint(endpoint : String) -> Bool {
  endpoint.has_prefix("http://") || endpoint.has_prefix("https://")
}

///|
fn is_websocket_endpoint(endpoint : String) -> Bool {
  endpoint.has_prefix("ws://") || endpoint.has_prefix("wss://")
}

///|
async fn exchange_http_peer(
  peer : @kv.PeerInfo,
  msg : @kv.GossipMessage,
  headers : Map[String, String],
) -> Result[@kv.GossipMessage?, String] {
  if not(is_http_endpoint(peer.endpoint)) {
    return Err("peer endpoint is not http(s): \{peer.endpoint}")
  }
  let request_headers = headers.copy()
  if not(request_headers.contains("Content-Type")) {
    request_headers["Content-Type"] = "application/json"
  }
  let payload = encode_gossip_message(msg)
  let (response, body) = @xhttp.post(
    peer.endpoint,
    payload,
    headers=request_headers,
  ) catch {
    err => return Err("http exchange failed: \{err.to_string()}")
  }
  if response.code < 200 || response.code >= 300 {
    return Err("http exchange failed: status=\{response.code}")
  }
  let text = body.text() catch { _ => @utf8.decode_lossy(body.binary()[:]) }
  decode_gossip_message(text)
}

///|
async fn exchange_websocket_peer(
  peer : @kv.PeerInfo,
  msg : @kv.GossipMessage,
  headers : Map[String, String],
) -> Result[@kv.GossipMessage?, String] {
  if not(is_websocket_endpoint(peer.endpoint)) {
    return Err("peer endpoint is not ws(s): \{peer.endpoint}")
  }
  let conn = @xws.Conn::connect(peer.endpoint, headers~) catch {
    err => return Err("websocket connect failed: \{err.to_string()}")
  }
  defer conn.close()
  conn.send_text(encode_gossip_message(msg)) catch {
    err => return Err("websocket send failed: \{err.to_string()}")
  }
  let incoming = conn.recv() catch {
    err => return Err("websocket recv failed: \{err.to_string()}")
  }
  let text = match incoming {
    @xws.Message::Text(value) => value
    @xws.Message::Binary(bytes) => @utf8.decode_lossy(bytes[:])
  }
  decode_gossip_message(text)
}

///|
pub async fn sync_round_with_exchange(
  kv : @kv.Kv,
  count : Int,
  seed : Int64,
  timestamp : Int64,
  exchange : async (@kv.PeerInfo, @kv.GossipMessage) -> Result[
    @kv.GossipMessage?,
    String,
  ],
) -> @kv.SyncRoundResult {
  let peers = kv.select_gossip_peers(count, seed, timestamp~)
  let mut attempted = 0
  let mut succeeded = 0
  let mut failed = 0
  let mut messages_sent = 0
  let mut messages_received = 0
  for peer in peers {
    attempted += 1
    let mut ok = true
    let mut did_send = false
    let mut steps = 0
    let mut outbound : @kv.GossipMessage? = Some(
      @kv.GossipMessage::Announce(kv.get_gossip_state(timestamp)),
    )
    while outbound is Some(msg) {
      steps += 1
      if steps > 8 {
        ok = false
        break
      }
      did_send = true
      messages_sent += 1
      let response = exchange(peer, msg) catch { err => Err(err.to_string()) }
      match response {
        Err(_) => {
          ok = false
          break
        }
        Ok(None) => outbound = None
        Ok(Some(inbound)) => {
          messages_received += 1
          outbound = kv.handle_gossip(inbound, timestamp)
        }
      }
    }
    if ok && did_send {
      succeeded += 1
      kv.record_peer_sync_result(peer.node_id, true, timestamp)
      let cursor = kv.get_peer_cursor(peer.node_id).unwrap_or(0L) + 1L
      kv.set_peer_cursor(peer.node_id, cursor)
    } else {
      failed += 1
      kv.record_peer_sync_result(peer.node_id, false, timestamp)
    }
  }
  {
    selected: peers.length(),
    attempted,
    succeeded,
    failed,
    messages_sent,
    messages_received,
  }
}

///|
pub async fn sync_round_http(
  kv : @kv.Kv,
  count : Int,
  seed : Int64,
  timestamp : Int64,
  headers? : Map[String, String] = {},
) -> @kv.SyncRoundResult {
  sync_round_with_exchange(kv, count, seed, timestamp, async fn(peer, msg) {
    exchange_http_peer(peer, msg, headers)
  })
}

///|
pub async fn sync_round_websocket(
  kv : @kv.Kv,
  count : Int,
  seed : Int64,
  timestamp : Int64,
  headers? : Map[String, String] = {},
) -> @kv.SyncRoundResult {
  sync_round_with_exchange(kv, count, seed, timestamp, async fn(peer, msg) {
    exchange_websocket_peer(peer, msg, headers)
  })
}

///|
pub async fn sync_round_native(
  kv : @kv.Kv,
  count : Int,
  seed : Int64,
  timestamp : Int64,
  headers? : Map[String, String] = {},
) -> @kv.SyncRoundResult {
  sync_round_with_exchange(kv, count, seed, timestamp, async fn(peer, msg) {
    if is_http_endpoint(peer.endpoint) {
      exchange_http_peer(peer, msg, headers)
    } else if is_websocket_endpoint(peer.endpoint) {
      exchange_websocket_peer(peer, msg, headers)
    } else {
      Err("unsupported peer endpoint: \{peer.endpoint}")
    }
  })
}

///| Gossip protocol implementation

///|

///| Gossip protocol flow:

///| 1. Each node periodically broadcasts its state (Announce)

///| 2. When receiving an Announce, compare HEADs

///| 3. If different, initiate sync (SyncRequest/SyncResponse)

///| 4. Merge received objects and update local state

///|
/// Get current gossip state
pub fn Kv::get_gossip_state(self : Kv, timestamp : Int64) -> GossipState {
  { node_id: self.node_id, head: self.head, clock: self.clock, timestamp }
}

///|
/// Add or update a peer
pub fn Kv::add_peer(self : Kv, peer : PeerInfo) -> Unit {
  self.sync_engine.upsert_peer(peer)
}

///|
/// Remove a peer
pub fn Kv::remove_peer(self : Kv, node_id : NodeId) -> Bool {
  self.sync_engine.remove_peer(node_id)
}

///|
/// Get all peers
pub fn Kv::get_peers(self : Kv) -> Array[PeerInfo] {
  self.sync_engine.get_peers()
}

///|
/// Select random peers for gossip (anti-entropy)
pub fn Kv::select_gossip_peers(
  self : Kv,
  count : Int,
  seed : Int64,
  timestamp? : Int64 = seed,
) -> Array[PeerInfo] {
  self.sync_engine.select_peers(count, seed, timestamp)
}

///|
/// Set per-peer sync cursor
pub fn Kv::set_peer_cursor(self : Kv, node_id : NodeId, cursor : Int64) -> Unit {
  self.sync_engine.set_cursor(node_id, cursor)
}

///|
/// Get per-peer sync cursor
pub fn Kv::get_peer_cursor(self : Kv, node_id : NodeId) -> Int64? {
  self.sync_engine.get_cursor(node_id)
}

///|
/// Record sync result to update retry state
pub fn Kv::record_peer_sync_result(
  self : Kv,
  node_id : NodeId,
  success : Bool,
  timestamp : Int64,
) -> Unit {
  self.sync_engine.record_sync_result(node_id, success, timestamp)
}

///|
/// Run one anti-entropy round against selected peers via injected transport.
/// The exchange callback sends one message to a peer and returns an optional response.
pub fn Kv::sync_round(
  self : Kv,
  count : Int,
  seed : Int64,
  timestamp : Int64,
  exchange : (PeerInfo, GossipMessage) -> Result[GossipMessage?, String],
) -> SyncRoundResult {
  let peers = self.select_gossip_peers(count, seed, timestamp~)
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
    let mut outbound : GossipMessage? = Some(
      Announce(self.get_gossip_state(timestamp)),
    )
    while outbound is Some(msg) {
      steps += 1
      if steps > 8 {
        ok = false
        break
      }
      did_send = true
      messages_sent += 1
      let response = exchange(peer, msg)
      match response {
        Err(_) => {
          ok = false
          break
        }
        Ok(None) => outbound = None
        Ok(Some(inbound)) => {
          messages_received += 1
          outbound = self.handle_gossip(inbound, timestamp)
        }
      }
    }
    if ok && did_send {
      succeeded += 1
      self.record_peer_sync_result(peer.node_id, true, timestamp)
      let cursor = self.get_peer_cursor(peer.node_id).unwrap_or(0L) + 1L
      self.set_peer_cursor(peer.node_id, cursor)
    } else {
      failed += 1
      self.record_peer_sync_result(peer.node_id, false, timestamp)
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
/// Handle incoming gossip message
/// Returns optional response message
pub fn Kv::handle_gossip(
  self : Kv,
  msg : GossipMessage,
  timestamp : Int64,
) -> GossipMessage? {
  match msg {
    Announce(state) => self.handle_announce(state, timestamp)
    WantObjects(ids) => self.handle_want_objects(ids)
    HaveObjects(objects) => {
      self.handle_have_objects(objects)
      None
    }
    SyncRequest(from, their_head) => self.handle_sync_request(from, their_head)
    SyncResponse(objects, new_head) => {
      self.handle_sync_response(objects, new_head)
      None
    }
  }
}

///|
fn Kv::handle_announce(
  self : Kv,
  state : GossipState,
  timestamp : Int64,
) -> GossipMessage? {
  // Update peer info
  let peer : PeerInfo = {
    node_id: state.node_id,
    last_seen: timestamp,
    head: state.head,
    endpoint: "", // Will be set by transport layer
  }
  self.add_peer(peer)
  // If their head is different, request sync
  if state.head != self.head && state.head != @git.ObjectId::zero() {
    // Compare vector clocks
    let cmp = self.clock.compare(state.clock)
    if cmp < 0 {
      // We're behind, request sync
      Some(SyncRequest(self.node_id, self.head))
    } else if cmp == 0 && state.head.to_hex() > self.head.to_hex() {
      // Concurrent, use hash as tie-breaker
      Some(SyncRequest(self.node_id, self.head))
    } else {
      None
    }
  } else {
    None
  }
}

///|
fn Kv::handle_want_objects(
  self : Kv,
  ids : Array[@git.ObjectId],
) -> GossipMessage? {
  let objects : Array[GitObject] = []
  let store : &@lib.ObjectStore = self.store
  for id in ids {
    let obj = store.get(id) catch { _ => continue }
    guard obj is Some(o) else { continue }
    objects.push({ id, obj_type: o.obj_type, data: o.data })
  }
  if objects.length() > 0 {
    objects |> HaveObjects |> Some
  } else {
    None
  }
}

///|
fn Kv::handle_have_objects(self : Kv, objects : Array[GitObject]) -> Unit {
  for obj in objects {
    self.pending_objects[obj.id.to_hex()] = obj
  }
}

///|
fn Kv::handle_sync_request(
  self : Kv,
  _from : NodeId,
  their_head : @git.ObjectId,
) -> GossipMessage? {
  // Find objects they don't have
  let missing = self.find_missing_objects(their_head)
  if missing.length() > 0 || self.head != their_head {
    Some(SyncResponse(missing, self.head))
  } else {
    None
  }
}

///|
fn Kv::handle_sync_response(
  self : Kv,
  objects : Array[GitObject],
  _new_head : @git.ObjectId,
) -> Unit {
  // Store received objects for later processing
  for obj in objects {
    self.pending_objects[obj.id.to_hex()] = obj
  }
  // Note: actual merge is done by apply_pending_sync
}

///|
/// Find objects that the peer is missing
/// This does a simple walk from our HEAD to their HEAD
fn Kv::find_missing_objects(
  self : Kv,
  their_head : @git.ObjectId,
) -> Array[GitObject] {
  let result : Array[GitObject] = []
  if self.head == their_head || self.head == @git.ObjectId::zero() {
    return result
  }
  let store : &@lib.ObjectStore = self.store
  // Collect objects reachable from our HEAD
  let our_objects : Map[String, Bool] = {}
  collect_reachable_objects(store, self.head, our_objects)
  // Collect objects reachable from their HEAD
  let their_objects : Map[String, Bool] = {}
  if their_head != @git.ObjectId::zero() {
    collect_reachable_objects(store, their_head, their_objects)
  }
  // Find objects we have that they don't
  for entry in our_objects {
    if not(their_objects.contains(entry.0)) {
      let id = @git.ObjectId::from_hex(entry.0) catch { _ => continue }
      let obj = store.get(id) catch { _ => continue }
      guard obj is Some(o) else { continue }
      result.push({ id, obj_type: o.obj_type, data: o.data })
    }
  }
  result
}

///|
fn collect_reachable_objects(
  store : &@lib.ObjectStore,
  start : @git.ObjectId,
  result : Map[String, Bool],
) -> Unit {
  if start == @git.ObjectId::zero() {
    return
  }
  let hex = start.to_hex()
  if result.contains(hex) {
    return
  }
  result[hex] = true
  let obj = store.get(start) catch { _ => return }
  guard obj is Some(o) else { return }
  match o.obj_type {
    Commit => {
      let commit = @git.parse_commit(o.data) catch { _ => return }
      collect_reachable_objects(store, commit.tree, result)
      for parent in commit.parents {
        collect_reachable_objects(store, parent, result)
      }
    }
    Tree => {
      let entries = @git.parse_tree(o.data) catch { _ => return }
      for entry in entries {
        collect_reachable_objects(store, entry.id, result)
      }
    }
    Blob | Tag => ()
  }
}

///|
/// Apply pending objects from sync
/// Returns number of objects applied
pub fn Kv::apply_pending_objects(self : Kv) -> Int raise @git.GitError {
  let mut count = 0
  let store : &@lib.ObjectStore = self.store
  for entry in self.pending_objects {
    let obj = entry.1
    let _ = store.put(obj.obj_type, obj.data)
    count = count + 1
  }
  self.pending_objects.clear()
  count
}

///|
/// Check if we have pending objects to apply
pub fn Kv::has_pending_objects(self : Kv) -> Bool {
  self.pending_objects.length() > 0
}

///|
/// Get count of pending objects
pub fn Kv::pending_object_count(self : Kv) -> Int {
  self.pending_objects.length()
}

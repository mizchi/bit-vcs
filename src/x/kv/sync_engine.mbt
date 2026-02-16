///| Sync engine for peer discovery, anti-entropy scheduling, cursor, and retry

///|
pub fn SyncEngine::new(
  config? : SyncEngineConfig = SyncEngineConfig::default(),
) -> SyncEngine {
  { config, peers: {} }
}

///|
fn new_peer_sync_state(peer : PeerInfo) -> PeerSyncState {
  {
    peer,
    cursor: None,
    last_sync_at: None,
    last_attempt_at: None,
    retry_count: 0,
    next_retry_at: 0L,
  }
}

///|
pub fn SyncEngine::upsert_peer(self : SyncEngine, peer : PeerInfo) -> Unit {
  match self.peers.get(peer.node_id.id) {
    None => self.peers[peer.node_id.id] = new_peer_sync_state(peer)
    Some(state) =>
      self.peers[peer.node_id.id] = {
        peer,
        cursor: state.cursor,
        last_sync_at: state.last_sync_at,
        last_attempt_at: state.last_attempt_at,
        retry_count: state.retry_count,
        next_retry_at: state.next_retry_at,
      }
  }
}

///|
pub fn SyncEngine::remove_peer(self : SyncEngine, node_id : NodeId) -> Bool {
  if self.peers.contains(node_id.id) {
    self.peers.remove(node_id.id)
    true
  } else {
    false
  }
}

///|
fn compare_peer_node_id(a : PeerInfo, b : PeerInfo) -> Int {
  if a.node_id.id < b.node_id.id {
    -1
  } else if a.node_id.id > b.node_id.id {
    1
  } else {
    0
  }
}

///|
pub fn SyncEngine::get_peers(self : SyncEngine) -> Array[PeerInfo] {
  let result : Array[PeerInfo] = []
  for entry in self.peers {
    result.push(entry.1.peer)
  }
  result.sort_by(compare_peer_node_id)
  result
}

///|
pub fn SyncEngine::set_cursor(
  self : SyncEngine,
  node_id : NodeId,
  cursor : Int64,
) -> Unit {
  let state = self.peers.get(node_id.id)
  guard state is Some(current) else { return }
  self.peers[node_id.id] = {
    peer: current.peer,
    cursor: Some(cursor),
    last_sync_at: current.last_sync_at,
    last_attempt_at: current.last_attempt_at,
    retry_count: current.retry_count,
    next_retry_at: current.next_retry_at,
  }
}

///|
pub fn SyncEngine::get_cursor(self : SyncEngine, node_id : NodeId) -> Int64? {
  let state = self.peers.get(node_id.id)
  match state {
    None => None
    Some(current) => current.cursor
  }
}

///|
fn retry_backoff_ms(config : SyncEngineConfig, retry_count : Int) -> Int64 {
  let mut value = config.retry_base_ms
  let mut i = 1
  while i < retry_count {
    value = value * 2L
    if value >= config.retry_max_ms {
      return config.retry_max_ms
    }
    i += 1
  }
  if value > config.retry_max_ms {
    config.retry_max_ms
  } else {
    value
  }
}

///|
pub fn SyncEngine::record_sync_result(
  self : SyncEngine,
  node_id : NodeId,
  success : Bool,
  timestamp : Int64,
) -> Unit {
  let state = self.peers.get(node_id.id)
  guard state is Some(current) else { return }
  if success {
    self.peers[node_id.id] = {
      peer: current.peer,
      cursor: current.cursor,
      last_sync_at: Some(timestamp),
      last_attempt_at: Some(timestamp),
      retry_count: 0,
      next_retry_at: timestamp,
    }
  } else {
    let retry_count = current.retry_count + 1
    let backoff = retry_backoff_ms(self.config, retry_count)
    self.peers[node_id.id] = {
      peer: current.peer,
      cursor: current.cursor,
      last_sync_at: current.last_sync_at,
      last_attempt_at: Some(timestamp),
      retry_count,
      next_retry_at: timestamp + backoff,
    }
  }
}

///|
fn is_due_for_sync(
  state : PeerSyncState,
  timestamp : Int64,
  anti_entropy_interval_ms : Int64,
) -> Bool {
  if timestamp < state.next_retry_at {
    return false
  }
  if state.retry_count > 0 {
    return true
  }
  match state.last_sync_at {
    None => true
    Some(last_sync_at) => timestamp - last_sync_at >= anti_entropy_interval_ms
  }
}

///|
fn select_random_unique(
  peers : Array[PeerInfo],
  count : Int,
  seed : Int64,
) -> Array[PeerInfo] {
  if count <= 0 || peers.length() == 0 {
    return []
  }
  if peers.length() <= count {
    return peers
  }
  let selected : Array[PeerInfo] = []
  let mut current_seed = seed
  let used : Map[Int, Bool] = {}
  while selected.length() < count && used.length() < peers.length() {
    current_seed = (current_seed * 1103515245L + 12345L) % 2147483648L
    let idx = (current_seed % peers.length().to_int64()).to_int()
    if not(used.contains(idx)) {
      used[idx] = true
      selected.push(peers[idx])
    }
  }
  selected
}

///|
pub fn SyncEngine::select_peers(
  self : SyncEngine,
  count : Int,
  seed : Int64,
  timestamp : Int64,
) -> Array[PeerInfo] {
  if count <= 0 {
    return []
  }
  let due_peers : Array[PeerInfo] = []
  for entry in self.peers {
    let state = entry.1
    if is_due_for_sync(state, timestamp, self.config.anti_entropy_interval_ms) {
      due_peers.push(state.peer)
    }
  }
  due_peers.sort_by(compare_peer_node_id)
  select_random_unique(due_peers, count, seed)
}

///| Tests for native kv sync transport

///|
priv struct TestWorkingTree {
  fs : @fs.Fs
  backing_fs : &@git.RepoFileSystem
  write_fs : &@git.FileSystem
}

///|
impl @lib.WorkingTree for TestWorkingTree with read_file(self, path) {
  self.fs.read_file(self.backing_fs, path)
}

///|
impl @lib.WorkingTree for TestWorkingTree with write_file(self, path, data) {
  self.fs.write_file(path, data)
}

///|
impl @lib.WorkingTree for TestWorkingTree with remove_file(self, path) {
  self.fs.remove_file(path)
}

///|
impl @lib.WorkingTree for TestWorkingTree with is_file(self, path) {
  self.fs.is_file(self.backing_fs, path)
}

///|
impl @lib.WorkingTree for TestWorkingTree with is_dir(self, path) {
  self.fs.is_dir(self.backing_fs, path)
}

///|
impl @lib.WorkingTree for TestWorkingTree with readdir(self, path) {
  self.fs.readdir(self.backing_fs, path)
}

///|
impl @lib.WorkingTree for TestWorkingTree with is_dirty(self) {
  self.fs.is_dirty()
}

///|
impl @lib.WorkingTree for TestWorkingTree with rollback(self) {
  self.fs.rollback()
}

///|
impl @lib.WorkingTree for TestWorkingTree with get_working_files(self) {
  self.fs.get_working_files()
}

///|
impl @lib.WorkingTree for TestWorkingTree with snapshot(
  self,
  message,
  author,
  timestamp,
) {
  let snapshot = self.fs.snapshot(
    self.write_fs,
    self.backing_fs,
    message,
    author,
    timestamp,
  )
  snapshot.commit_id
}

///|
impl @lib.WorkingTree for TestWorkingTree with checkout(self, commit_id) {
  self.fs.checkout_snapshot(self.backing_fs, commit_id)
}

///|
priv struct TestObjectStore {
  backing_fs : &@git.RepoFileSystem
  write_fs : &@git.FileSystem
  git_dir : String
}

///|
impl @lib.ObjectStore for TestObjectStore with get(self, id) {
  let db = @lib.ObjectDb::load(self.backing_fs, self.git_dir)
  db.get(self.backing_fs, id)
}

///|
impl @lib.ObjectStore for TestObjectStore with put(self, obj_type, data) {
  @lib.write_loose_object(self.write_fs, self.git_dir, obj_type, data)
}

///|
impl @lib.ObjectStore for TestObjectStore with has(self, id) {
  let db = @lib.ObjectDb::load(self.backing_fs, self.git_dir) catch {
    _ => return false
  }
  let obj = db.get(self.backing_fs, id) catch { _ => return false }
  obj is Some(_)
}

///|
fn make_test_kv_simple(node_id : String) -> @kv.Kv {
  let fs = @git.TestFs::new()
  @lib.init_repo(fs, "/repo") catch {
    _ => ()
  }
  let bitfs = @fs.Fs::empty("/repo/.git")
  let tree : TestWorkingTree = { fs: bitfs, backing_fs: fs, write_fs: fs }
  let store : TestObjectStore = {
    backing_fs: fs,
    write_fs: fs,
    git_dir: "/repo/.git",
  }
  @kv.Kv::new(@kv.NodeId::new(node_id), tree, store, @git.ObjectId::zero())
}

///|
fn peer(node_id : String, endpoint : String) -> @kv.PeerInfo {
  {
    node_id: @kv.NodeId::new(node_id),
    last_seen: 0L,
    head: @git.ObjectId::zero(),
    endpoint,
  }
}

///|
test "kv native: encode/decode announce message roundtrip" {
  let state : @kv.GossipState = {
    node_id: @kv.NodeId::new("node-a"),
    head: @git.ObjectId::zero(),
    clock: @kv.VectorClock::new().increment(@kv.NodeId::new("node-a")),
    timestamp: 1234L,
  }
  let msg = @kv.GossipMessage::Announce(state)
  let encoded = encode_gossip_message(msg)
  let decoded = decode_gossip_message(encoded)
  guard decoded is Ok(Some(@kv.GossipMessage::Announce(decoded_state))) else {
    fail("failed to decode announce")
  }
  assert_eq(decoded_state.node_id.id, "node-a")
  assert_eq(decoded_state.timestamp, 1234L)
}

///|
async test "kv native: sync_round_with_exchange updates cursor on success" {
  let kv = make_test_kv_simple("node-local")
  kv.add_peer(peer("peer1", "http://localhost:1111/kv/sync"))
  let result = sync_round_with_exchange(kv, 1, 11L, 1000L, fn(_peer, _msg) {
    Ok(None)
  })
  assert_eq(result.selected, 1)
  assert_eq(result.succeeded, 1)
  assert_eq(result.failed, 0)
  assert_eq(kv.get_peer_cursor(@kv.NodeId::new("peer1")), Some(1L))
}

///|
async test "kv native: sync_round_with_exchange applies retry on failure" {
  let kv = make_test_kv_simple("node-local")
  kv.add_peer(peer("peer1", "ws://localhost:2222/kv/sync"))
  let result = sync_round_with_exchange(kv, 1, 22L, 1000L, fn(_peer, _msg) {
    Err("boom")
  })
  assert_eq(result.succeeded, 0)
  assert_eq(result.failed, 1)
  let early = kv.select_gossip_peers(1, 22L, timestamp=1500L)
  assert_eq(early.length(), 0)
  let late = kv.select_gossip_peers(1, 22L, timestamp=2500L)
  assert_eq(late.length(), 1)
}

///| Benchmarks for hot/cold serialization

///|
/// Cached ObjectStore that loads ObjectDb once (for benchmarks)
priv struct CachedTestObjectStore {
  db : @lib.ObjectDb
  backing_fs : &@git.RepoFileSystem
  write_fs : &@git.FileSystem
  git_dir : String
}

///|
priv enum KvBenchBackend {
  InMemory
  NativeFs
}

///|
priv enum KvBenchFixture {
  MemFixture(Kv, @git.TestFs)
  FsFixture(Kv, @osfs.OsFs)
}

///|
let bench_native_root_base : String = "/tmp/bit_bench_kv_backend_v1"

///|
fn KvBenchFixture::kv(self : KvBenchFixture) -> Kv {
  match self {
    MemFixture(db, _fs) => db
    FsFixture(db, _fs) => db
  }
}

///|
fn bench_join_path(root : String, path : String) -> String {
  if root.length() == 0 || root == "/" {
    if path.has_prefix("/") {
      path
    } else {
      "/" + path
    }
  } else if root.has_suffix("/") {
    root + path
  } else {
    root + "/" + path
  }
}

///|
fn bench_ensure_dir(path : String) -> Unit {
  if not(@nfs.path_exists(path)) {
    @nfs.create_dir(path) catch {
      _ => ()
    }
  }
}

///|
fn bench_seed_files(
  db : Kv,
  file_count : Int,
  file_size : Int,
) -> Unit raise @git.GitError {
  // Create files with different content to avoid dedup.
  for i = 0; i < file_count; i = i + 1 {
    let path = "dir" +
      (i / 10).to_string() +
      "/file" +
      (i % 10).to_string() +
      ".txt"
    let content = Bytes::make(file_size, (i % 256).to_byte())
    db.set(path, content)
  }
  ignore(db.commit("Initial commit", 1000L))
}

///|
fn bench_resolve_head(
  fs : &@git.RepoFileSystem,
  git_dir : String,
) -> @git.ObjectId {
  let resolved = @lib.resolve_ref(fs, git_dir, "HEAD") catch { _ => None }
  resolved.unwrap_or(@git.ObjectId::zero())
}

///|
fn create_cached_bench_db(
  backing_fs : &@git.RepoFileSystem,
  write_fs : &@git.FileSystem,
  git_dir : String,
  head : @git.ObjectId,
) -> Kv raise @git.GitError {
  let bitfs = @fs.Fs::empty(git_dir)
  let tree : TestWorkingTree = { fs: bitfs, backing_fs, write_fs }
  let obj_db = @lib.ObjectDb::load(backing_fs, git_dir)
  let cached_store : CachedTestObjectStore = {
    db: obj_db,
    backing_fs,
    write_fs,
    git_dir,
  }
  Kv::new(NodeId::new("bench-node"), tree, cached_store, head)
}

///|
impl @lib.ObjectStore for CachedTestObjectStore with get(self, id) {
  self.db.get(self.backing_fs, id)
}

///|
impl @lib.ObjectStore for CachedTestObjectStore with put(self, obj_type, data) {
  @lib.write_loose_object(self.write_fs, self.git_dir, obj_type, data)
}

///|
impl @lib.ObjectStore for CachedTestObjectStore with has(self, id) {
  let obj = self.db.get(self.backing_fs, id) catch { _ => return false }
  obj is Some(_)
}

///|
/// Create bench Kv with CachedTestObjectStore (ObjectDb loaded once)
fn create_bench_db(
  file_count : Int,
  file_size : Int,
) -> (Kv, @git.TestFs) raise @git.GitError {
  let fs = @git.TestFs::new()
  @lib.init_repo(fs, "/repo")
  let git_dir = "/repo/.git"
  let bitfs = @fs.Fs::empty(git_dir)
  let tree : TestWorkingTree = { fs: bitfs, backing_fs: fs, write_fs: fs }
  let store : TestObjectStore = { backing_fs: fs, write_fs: fs, git_dir }
  let db = Kv::new(
    NodeId::new("bench-node"),
    tree,
    store,
    @git.ObjectId::zero(),
  )
  bench_seed_files(db, file_count, file_size)
  let cached_kv = create_cached_bench_db(fs, fs, git_dir, db.head())
  (cached_kv, fs)
}

///|
fn native_bench_repo_root(file_count : Int, file_size : Int) -> String {
  bench_join_path(bench_native_root_base, "f\{file_count}_s\{file_size}")
}

///|
fn read_marker_head(marker : String) -> @git.ObjectId? {
  let raw = @nfs.read_file_to_string(marker) catch { _ => return None }
  let line = raw.trim().to_string()
  if line.length() == 0 {
    return None
  }
  let parsed = @git.ObjectId::from_hex(line) catch { _ => return None }
  Some(parsed)
}

///|
fn ensure_native_bench_repo(
  root : String,
  file_count : Int,
  file_size : Int,
) -> Unit raise @git.GitError {
  let marker = bench_join_path(root, ".bench_ready")
  if @nfs.path_exists(marker) {
    return
  }
  bench_ensure_dir(bench_native_root_base)
  bench_ensure_dir(root)
  let fs = @osfs.OsFs::new()
  ignore(try? @lib.init_repo(fs, root))
  let git_dir = bench_join_path(root, ".git")
  let bitfs = @fs.Fs::empty(git_dir)
  let tree : TestWorkingTree = { fs: bitfs, backing_fs: fs, write_fs: fs }
  let store : TestObjectStore = { backing_fs: fs, write_fs: fs, git_dir }
  let db = Kv::new(
    NodeId::new("bench-node"),
    tree,
    store,
    @git.ObjectId::zero(),
  )
  bench_seed_files(db, file_count, file_size)
  @nfs.write_string_to_file(marker, db.head().to_hex()) catch {
    _ => ()
  }
}

///|
fn create_bench_db_native(
  file_count : Int,
  file_size : Int,
) -> (Kv, @osfs.OsFs) raise @git.GitError {
  let root = native_bench_repo_root(file_count, file_size)
  ensure_native_bench_repo(root, file_count, file_size)
  let fs = @osfs.OsFs::new()
  let git_dir = bench_join_path(root, ".git")
  let marker = bench_join_path(root, ".bench_ready")
  let head = match read_marker_head(marker) {
    Some(id) => id
    None => bench_resolve_head(fs, git_dir)
  }
  let db = create_cached_bench_db(fs, fs, git_dir, head)
  (db, fs)
}

///|
fn create_bench_fixture(
  backend : KvBenchBackend,
  file_count : Int,
  file_size : Int,
) -> KvBenchFixture raise @git.GitError {
  match backend {
    InMemory => {
      let (db, fs) = create_bench_db(file_count, file_size)
      MemFixture(db, fs)
    }
    NativeFs => {
      let (db, fs) = create_bench_db_native(file_count, file_size)
      FsFixture(db, fs)
    }
  }
}

///|
fn bench_serialize_snapshot_backend(
  b : @bench.T,
  backend : KvBenchBackend,
  file_count : Int,
  file_size : Int,
) -> Unit {
  let fixture = try! create_bench_fixture(backend, file_count, file_size)
  let db = fixture.kv()
  b.bench(fn() { b.keep(db.serialize_snapshot(mode=TreeAndBlobOnly)) })
}

///|
fn bench_roundtrip_backend(
  b : @bench.T,
  backend : KvBenchBackend,
  file_count : Int,
  file_size : Int,
) -> Unit {
  let fixture = try! create_bench_fixture(backend, file_count, file_size)
  let db = fixture.kv()
  b.bench(fn() {
    let snapshot = db.serialize_snapshot(mode=TreeAndBlobOnly)
    let bytes = snapshot.to_bytes()
    b.keep(SerializedSnapshot::from_bytes(bytes))
  })
}

///|
/// Benchmark: Serialize small snapshot (10 files, 1KB each)
test "bench: serialize small snapshot (10 files x 1KB)" (b : @bench.T) {
  let (db, _fs) = try! create_bench_db(10, 1024)
  b.bench(fn() { b.keep(db.serialize_snapshot()) })
}

///|
/// Benchmark: Serialize medium snapshot (100 files, 1KB each)
test "bench: serialize medium snapshot (100 files x 1KB)" (b : @bench.T) {
  let (db, _fs) = try! create_bench_db(100, 1024)
  b.bench(fn() { b.keep(db.serialize_snapshot()) })
}

///|
/// Benchmark: Serialize large snapshot (100 files, 10KB each)
test "bench: serialize large snapshot (100 files x 10KB)" (b : @bench.T) {
  let (db, _fs) = try! create_bench_db(100, 10240)
  b.bench(fn() { b.keep(db.serialize_snapshot()) })
}

///|
/// Benchmark: Snapshot to bytes (full pipeline)
test "bench: snapshot to bytes (10 files x 1KB)" (b : @bench.T) {
  let (db, _fs) = try! create_bench_db(10, 1024)
  b.bench(fn() {
    let snapshot = db.serialize_snapshot()
    b.keep(snapshot.to_bytes())
  })
}

///|
/// Benchmark: Snapshot to bytes (100 files)
test "bench: snapshot to bytes (100 files x 1KB)" (b : @bench.T) {
  let (db, _fs) = try! create_bench_db(100, 1024)
  b.bench(fn() {
    let snapshot = db.serialize_snapshot()
    b.keep(snapshot.to_bytes())
  })
}

///|
/// Benchmark: to_bytes only (100 files)
test "bench: to_bytes only (100 files x 1KB)" (b : @bench.T) {
  let (db, _fs) = try! create_bench_db(100, 1024)
  let snapshot = db.serialize_snapshot()
  b.bench(fn() { b.keep(snapshot.to_bytes()) })
}

///|
/// Benchmark: Bytes to snapshot (deserialization)
test "bench: bytes to snapshot (10 files x 1KB)" (b : @bench.T) {
  let (db, _fs) = try! create_bench_db(10, 1024)
  let snapshot = db.serialize_snapshot()
  let bytes = snapshot.to_bytes()
  b.bench(fn() { b.keep(SerializedSnapshot::from_bytes(bytes)) })
}

///|
/// Benchmark: Bytes to snapshot (100 files)
test "bench: bytes to snapshot (100 files x 1KB)" (b : @bench.T) {
  let (db, _fs) = try! create_bench_db(100, 1024)
  let snapshot = db.serialize_snapshot()
  let bytes = snapshot.to_bytes()
  b.bench(fn() { b.keep(SerializedSnapshot::from_bytes(bytes)) })
}

///|
/// Benchmark: Round-trip (serialize + deserialize)
test "bench: round-trip (10 files x 1KB)" (b : @bench.T) {
  let (db, _fs) = try! create_bench_db(10, 1024)
  b.bench(fn() {
    let snapshot = db.serialize_snapshot()
    let bytes = snapshot.to_bytes()
    b.keep(SerializedSnapshot::from_bytes(bytes))
  })
}

///|
/// Benchmark: Round-trip (100 files)
test "bench: round-trip (100 files x 1KB)" (b : @bench.T) {
  let (db, _fs) = try! create_bench_db(100, 1024)
  b.bench(fn() {
    let snapshot = db.serialize_snapshot()
    let bytes = snapshot.to_bytes()
    b.keep(SerializedSnapshot::from_bytes(bytes))
  })
}

///|
test "bench backend: serialize snapshot in-memory (100 files x 1KB)" (
  b : @bench.T,
) {
  bench_serialize_snapshot_backend(b, InMemory, 100, 1024)
}

///|
test "bench backend: serialize snapshot native-fs (100 files x 1KB)" (
  b : @bench.T,
) {
  bench_serialize_snapshot_backend(b, NativeFs, 100, 1024)
}

///|
test "bench backend: round-trip in-memory (100 files x 1KB)" (b : @bench.T) {
  bench_roundtrip_backend(b, InMemory, 100, 1024)
}

///|
test "bench backend: round-trip native-fs (100 files x 1KB)" (b : @bench.T) {
  bench_roundtrip_backend(b, NativeFs, 100, 1024)
}

///|
test "bench backend fixture: in-memory smoke" {
  let fixture = try! create_bench_fixture(InMemory, 10, 128)
  let db = fixture.kv()
  let snapshot = db.serialize_snapshot()
  assert_true(snapshot.objects.length() > 0)
}

///|
test "bench backend fixture: native-fs smoke" {
  let fixture = try! create_bench_fixture(NativeFs, 10, 128)
  let db = fixture.kv()
  let snapshot = db.serialize_snapshot()
  assert_true(snapshot.objects.length() > 0)
}

///|
/// Test: Verify serialization correctness
test "serialization: round-trip preserves data" {
  let (db, _fs) = make_test_kv("test-node", "/repo/.git")
  // Add some data
  db.set("users/alice", b"Alice")
  db.set("users/bob", b"Bob")
  db.set("config/version", b"1.0.0")
  let _ = db.commit("Test commit", 12345L)
  // Serialize
  let snapshot = db.serialize_snapshot()
  let bytes = snapshot.to_bytes()
  // Deserialize
  let restored = SerializedSnapshot::from_bytes(bytes)
  // Verify
  assert_eq(restored.version, 1)
  assert_eq(restored.node_id, "test-node")
  assert_eq(restored.objects.length(), snapshot.objects.length())
  // Verify clock
  assert_eq(restored.clock.length(), snapshot.clock.length())
}

///|
/// Test: Statistics calculation
test "serialization: stats" {
  let (db, _fs) = make_test_kv("test-node", "/repo/.git")
  db.set("file1.txt", Bytes::make(100, b'a'))
  db.set("file2.txt", Bytes::make(200, b'b'))
  let _ = db.commit("Test", 1000L)
  let snapshot = db.serialize_snapshot()
  let stats = snapshot.stats()
  assert_eq(stats.commit_count, 1)
  assert_true(stats.tree_count >= 1)
  assert_eq(stats.blob_count, 2)
  assert_eq(stats.blob_bytes, 300)
  println("Stats: \{stats.total_bytes} bytes, \{stats.object_count} objects")
}

///|
test "serialization: tree+blob mode excludes commit history" {
  let (db, _fs) = make_test_kv("test-node", "/repo/.git")
  db.set("a.txt", b"a")
  let _ = db.commit("c1", 1000L)
  db.set("b.txt", b"b")
  let _ = db.commit("c2", 1001L)
  let full = db.serialize_snapshot()
  let tree_blob = db.serialize_snapshot(mode=TreeAndBlobOnly)
  let full_stats = full.stats()
  let tree_blob_stats = tree_blob.stats()
  assert_true(full_stats.commit_count >= 2)
  assert_eq(tree_blob_stats.commit_count, 0)
  assert_true(tree_blob.objects.length() < full.objects.length())
}

///|
/// Demo: Show serialization overhead
test "demo: serialization overhead" {
  let (db, _fs) = make_test_kv("demo-node", "/repo/.git")
  // Create 50 files of 2KB each = 100KB raw data
  for i = 0; i < 50; i = i + 1 {
    // Use different content for each file to avoid dedup
    let file_content = Bytes::make(2048, (i % 256).to_byte())
    db.set("file\{i}.txt", file_content)
  }
  let _ = db.commit("50 files", 1000L)
  let snapshot = db.serialize_snapshot()
  let bytes = snapshot.to_bytes()
  let stats = snapshot.stats()
  let raw_size = 50 * 2048
  let overhead = (bytes.length() - raw_size) * 100 / raw_size
  println("Raw data: \{raw_size} bytes")
  println("Serialized: \{bytes.length()} bytes")
  println("Overhead: \{overhead}%")
  println(
    "Objects: \{stats.object_count} (commits: \{stats.commit_count}, trees: \{stats.tree_count}, blobs: \{stats.blob_count})",
  )
}

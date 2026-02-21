///| Benchmarks for relay push path.

///|
/// Run with:
/// - moon bench -p mizchi/bit/x/hub/native --target native -f sync_native_bench_wbtest.mbt

///|
priv struct BenchClock {
  now_ts : Int64
}

///|
impl @lib.Clock for BenchClock with now(self) {
  self.now_ts
}

///|
priv struct PushBenchFixture {
  fs : @bit.TestFs
  git_dir : String
}

///|
fn build_push_bench_fixture(
  record_count : Int,
) -> PushBenchFixture raise @bit.GitError {
  let fs = @bit.TestFs::new()
  let git_dir = "/bench-relay/.git"
  fs.mkdir_p(git_dir)
  let db = @lib.ObjectDb::load_lazy(fs, git_dir)
  let native_objects : NativeObjectStore = { db, rfs: fs, fs, git_dir }
  let native_refs : NativeRefStore = { fs, rfs: fs, git_dir }
  let objects : &@lib.ObjectStore = native_objects
  let refs : &@lib.RefStore = native_refs
  let store = @hub.HubStore::load(objects, refs, node_id="node-bench")
  let clock : BenchClock = { now_ts: 1700000000L }
  let clock_ref : &@lib.Clock = clock
  for i in 0..<record_count {
    ignore(
      store.put_record(
        objects,
        refs,
        clock_ref,
        "hub/pr/\{i}/meta",
        "hub.pr",
        "payload-\{i}",
        "node-bench",
      ),
    )
  }
  { fs, git_dir }
}

///|
let relay_push_fixture_200 : PushBenchFixture = try! build_push_bench_fixture(
  200,
)

///|
async fn relay_bench_http_post_ok(
  _url : String,
  _body : Bytes,
  _headers : Map[String, String],
) -> (@bit.HttpResponse, Bytes) raise @bit.GitError {
  let no_ops : Array[async () -> Unit] = []
  ignore(
    @async.all(no_ops) catch {
      err => raise @bit.GitError::IoError(err.to_string())
    },
  )
  (
    @bit.HttpResponse::new(200),
    @utf8.encode("{\"ok\":true,\"accepted\":true,\"cursor\":1}"),
  )
}

///|
test "bench relay push 200 records default sender" (b : @bench.T) {
  @sys.unset_env_var("BIT_RELAY_SENDER")
  @sys.unset_env_var("BIT_RELAY_SIGN_PRIVATE_KEY_FILE")
  @sys.unset_env_var("BIT_RELAY_SIGN_PUBLIC_KEY")
  b.bench(fn() {
    let mut ok = false
    @async.run_async_main(async fn() {
      let result = relay_push_with_http(
        relay_push_fixture_200.fs,
        relay_push_fixture_200.git_dir,
        "http://relay.test",
        relay_bench_http_post_ok,
        signing_key=None,
        auth_token=None,
      )
      ok = result.success()
    })
    b.keep(ok)
  })
}

///|
test "bench relay push 200 records BIT_RELAY_SENDER set" (b : @bench.T) {
  @sys.set_env_var("BIT_RELAY_SENDER", "node-a")
  @sys.unset_env_var("BIT_RELAY_SIGN_PRIVATE_KEY_FILE")
  @sys.unset_env_var("BIT_RELAY_SIGN_PUBLIC_KEY")
  b.bench(fn() {
    let mut ok = false
    @async.run_async_main(async fn() {
      let result = relay_push_with_http(
        relay_push_fixture_200.fs,
        relay_push_fixture_200.git_dir,
        "http://relay.test",
        relay_bench_http_post_ok,
        signing_key=None,
        auth_token=None,
      )
      ok = result.success()
    })
    b.keep(ok)
  })
  @sys.unset_env_var("BIT_RELAY_SENDER")
}

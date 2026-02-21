///| Whitebox tests for relay transport helpers in hub sync.

///|
priv struct FixedClock {
  now_ts : Int64
}

///|
impl @lib.Clock for FixedClock with now(self) {
  self.now_ts
}

///|
async fn relay_test_http_get_ok(
  _url : String,
  _headers : Map[String, String],
) -> (@bit.HttpResponse, Bytes) raise @bit.GitError {
  let no_ops : Array[async () -> Unit] = []
  ignore(
    @async.all(no_ops) catch {
      err => raise @bit.GitError::IoError(err.to_string())
    },
  )
  let body = "{\"ok\":true,\"room\":\"main\",\"next_cursor\":1,\"envelopes\":[{\"room\":\"main\",\"id\":\"msg-1\",\"sender\":\"node-a\",\"topic\":\"notify\",\"payload\":{\"kind\":\"hub.record\",\"record\":\"version 1\\nkey hub/pr/1/meta\\nkind hub.pr\\nclock node-a=1\\ntimestamp 1\\nnode node-a\\ndeleted 0\\n\\npayload\"},\"signature\":null}]}"
  (@bit.HttpResponse::new(200), @utf8.encode(body))
}

///|
async fn relay_test_http_post_ok(
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
test "relay: parse_relay_base_url handles explicit prefixes" {
  assert_eq(
    parse_relay_base_url("relay+http://127.0.0.1:8787"),
    Some("http://127.0.0.1:8787"),
  )
  assert_eq(
    parse_relay_base_url("relay+https://relay.example.com"),
    Some("https://relay.example.com"),
  )
  assert_eq(
    parse_relay_base_url("relay://127.0.0.1:8787"),
    Some("http://127.0.0.1:8787"),
  )
  assert_eq(parse_relay_base_url("http://127.0.0.1:8787"), None)
}

///|
test "relay: relay_resolve_control_endpoint parses room and token query" {
  let endpoint = relay_resolve_control_endpoint(
    "relay+https://relay.example.com/base/?room=team-a&room_token=token-1",
  )
  assert_eq(endpoint.base_url, "https://relay.example.com/base")
  assert_eq(endpoint.room, "team-a")
  assert_eq(endpoint.room_token, Some("token-1"))
}

///|
test "relay: relay_resolve_control_endpoint rejects invalid room name" {
  ignore(
    relay_resolve_control_endpoint(
      "relay+https://relay.example.com?room=invalid/room",
    ) catch {
      @bit.GitError::InvalidObject(message) => {
        assert_true(message.contains("invalid relay room"))
        return ()
      }
      err => fail("unexpected error: \{err.to_string()}")
    },
  )
  fail("expected invalid room error")
}

///|
test "relay: publish and poll urls include room token query when provided" {
  let publish_url = relay_publish_url(
    "https://relay.example.com",
    "team-a",
    "node-a",
    "event-1",
    room_token=Some("token-1"),
  )
  assert_true(publish_url.contains("room=team-a"))
  assert_true(publish_url.contains("room_token=token-1"))
  let poll_url = relay_poll_url(
    "https://relay.example.com",
    "team-a",
    3,
    50,
    room_token=Some("token-1"),
  )
  assert_true(poll_url.contains("room=team-a"))
  assert_true(poll_url.contains("room_token=token-1"))
  assert_true(poll_url.contains("after=3"))
  assert_true(poll_url.contains("limit=50"))
}

///|
test "relay: should_fallback_to_relay only for http 404 smart-http errors" {
  assert_true(
    should_fallback_to_relay(
      @bit.GitError::ProtocolError("Failed to fetch info/refs: HTTP 404"),
      "http://127.0.0.1:8787",
    ),
  )
  assert_true(
    should_fallback_to_relay(
      @bit.GitError::ProtocolError("Failed to discover refs: HTTP 404"),
      "https://relay.example.com",
    ),
  )
  assert_false(
    should_fallback_to_relay(
      @bit.GitError::ProtocolError("Failed to fetch info/refs: HTTP 500"),
      "http://127.0.0.1:8787",
    ),
  )
  assert_false(
    should_fallback_to_relay(
      @bit.GitError::IoError("connection refused"),
      "http://127.0.0.1:8787",
    ),
  )
}

///|
test "relay: parse_relay_poll_body extracts hub records and cursor" {
  let body = "{\"ok\":true,\"room\":\"main\",\"next_cursor\":1,\"envelopes\":[{\"room\":\"main\",\"id\":\"msg-1\",\"sender\":\"node-a\",\"topic\":\"notify\",\"payload\":{\"kind\":\"hub.record\",\"record\":\"version 1\\nkey hub/pr/1/meta\\nkind hub.pr\\nclock node-a=1\\ntimestamp 1\\nnode node-a\\ndeleted 0\\n\\npayload\"},\"signature\":null}]}"
  let (cursor, records) = parse_relay_poll_body(body)
  assert_eq(cursor, 1)
  assert_eq(records.length(), 1)
  assert_eq(records[0].key, "hub/pr/1/meta")
  assert_eq(records[0].payload, "payload")
}

///|
test "relay: apply_relay_records stores imported record into notes" {
  let fs = @bit.TestFs::new()
  let git_dir = "/repo/.git"
  fs.mkdir_p(git_dir)
  let db = @lib.ObjectDb::load_lazy(fs, git_dir)
  let native_objects : NativeObjectStore = { db, rfs: fs, fs, git_dir }
  let native_refs : NativeRefStore = { fs, rfs: fs, git_dir }
  let objects : &@lib.ObjectStore = native_objects
  let refs : &@lib.RefStore = native_refs
  let store = @hub.HubStore::load(objects, refs, node_id="node-local")
  let incoming = @hub.HubRecord::new(
    "hub/pr/1/meta",
    "hub.pr",
    "payload",
    "node-a",
    1L,
    clock={ "node-a": 1 },
  )
  let changed = apply_relay_records(
    store,
    objects,
    refs,
    [incoming],
    1L,
    "relay import",
    @hub.default_record_merge_policy(),
  )
  assert_true(changed)
  let reloaded = @hub.HubStore::load(objects, refs, node_id="node-local")
  let loaded = reloaded.get_record(objects, "hub/pr/1/meta")
  assert_true(loaded is Some(_))
  guard loaded is Some(record) else { panic() }
  assert_eq(record.payload, "payload")
}

///|
async test "relay: relay_fetch_with_http imports records and stores cursor" {
  let fs = @bit.TestFs::new()
  let git_dir = "/repo/.git"
  fs.mkdir_p(git_dir)
  let db = @lib.ObjectDb::load_lazy(fs, git_dir)
  let native_objects : NativeObjectStore = { db, rfs: fs, fs, git_dir }
  let native_refs : NativeRefStore = { fs, rfs: fs, git_dir }
  let objects : &@lib.ObjectStore = native_objects
  let refs : &@lib.RefStore = native_refs
  let hub = @hub.Hub::load(objects, refs, node_id="node-local")
  let result = relay_fetch_with_http(
    hub,
    fs,
    fs,
    git_dir,
    "http://relay.test",
    relay_test_http_get_ok,
    signing_key=None,
    auth_token=None,
  )
  assert_true(result.success())
  let reloaded = @hub.HubStore::load(objects, refs, node_id="node-local")
  let loaded = reloaded.get_record(objects, "hub/pr/1/meta")
  assert_true(loaded is Some(_))
  let cursor_path = relay_cursor_path(git_dir, "http://relay.test?room=main")
  assert_true(fs.is_file(cursor_path))
}

///|
async test "relay: relay_push_with_http sends local hub records" {
  let fs = @bit.TestFs::new()
  let git_dir = "/repo/.git"
  fs.mkdir_p(git_dir)
  let db = @lib.ObjectDb::load_lazy(fs, git_dir)
  let native_objects : NativeObjectStore = { db, rfs: fs, fs, git_dir }
  let native_refs : NativeRefStore = { fs, rfs: fs, git_dir }
  let objects : &@lib.ObjectStore = native_objects
  let refs : &@lib.RefStore = native_refs
  let store = @hub.HubStore::load(objects, refs, node_id="node-local")
  let clock : FixedClock = { now_ts: 1L }
  let clock_ref : &@lib.Clock = clock
  ignore(
    store.put_record(
      objects, refs, clock_ref, "hub/pr/1/meta", "hub.pr", "payload", "node-local",
    ),
  )
  let hub = @hub.Hub::load(objects, refs, node_id="node-local")
  let result = relay_push_with_http(
    fs,
    git_dir,
    "http://relay.test",
    relay_test_http_post_ok,
    signing_key=None,
    auth_token=None,
  )
  ignore(hub)
  assert_true(result.success())
  assert_true(result.message().contains("relay accepted 1/1"))
}

///|
async test "relay: relay push forwards auth token header" {
  let fs = @bit.TestFs::new()
  let git_dir = "/repo/.git"
  fs.mkdir_p(git_dir)
  let db = @lib.ObjectDb::load_lazy(fs, git_dir)
  let native_objects : NativeObjectStore = { db, rfs: fs, fs, git_dir }
  let native_refs : NativeRefStore = { fs, rfs: fs, git_dir }
  let objects : &@lib.ObjectStore = native_objects
  let refs : &@lib.RefStore = native_refs
  let store = @hub.HubStore::load(objects, refs, node_id="node-local")
  let clock : FixedClock = { now_ts: 1L }
  let clock_ref : &@lib.Clock = clock
  ignore(
    store.put_record(
      objects, refs, clock_ref, "hub/pr/1/meta", "hub.pr", "payload", "node-local",
    ),
  )
  let seen_auth : Array[String] = []
  let post = async fn(
    _url : String,
    _body : Bytes,
    headers : Map[String, String],
  ) -> (@bit.HttpResponse, Bytes) raise @bit.GitError {
    let no_ops : Array[async () -> Unit] = []
    ignore(
      @async.all(no_ops) catch {
        err => raise @bit.GitError::IoError(err.to_string())
      },
    )
    match headers.get("Authorization") {
      Some(value) => seen_auth.push(value)
      None => ()
    }
    (
      @bit.HttpResponse::new(200),
      @utf8.encode("{\"ok\":true,\"accepted\":true,\"cursor\":1}"),
    )
  }
  let result = relay_push_with_http(
    fs,
    git_dir,
    "http://relay.test",
    post,
    signing_key=None,
    auth_token=Some("token-1"),
  )
  assert_true(result.success())
  assert_eq(seen_auth.length(), 1)
  assert_eq(seen_auth[0], "Bearer token-1")
}

///|
async test "relay: relay push adds relay signature headers when key env is set" {
  let fs = @bit.TestFs::new()
  let git_dir = "/repo/.git"
  fs.mkdir_p(git_dir)
  let db = @lib.ObjectDb::load_lazy(fs, git_dir)
  let native_objects : NativeObjectStore = { db, rfs: fs, fs, git_dir }
  let native_refs : NativeRefStore = { fs, rfs: fs, git_dir }
  let objects : &@lib.ObjectStore = native_objects
  let refs : &@lib.RefStore = native_refs
  let store = @hub.HubStore::load(objects, refs, node_id="node-local")
  let clock : FixedClock = { now_ts: 1L }
  let clock_ref : &@lib.Clock = clock
  ignore(
    store.put_record(
      objects, refs, clock_ref, "hub/pr/1/meta", "hub.pr", "payload", "node-local",
    ),
  )

  let key_path = "/tmp/bit-relay-sign-" +
    @env.now().to_int().to_string() +
    ".pem"
  let keygen_code = @process.run(
    "openssl",
    ["genpkey", "-algorithm", "Ed25519", "-out", key_path],
    inherit_env=true,
  ) catch {
    _ => -1
  }
  if keygen_code != 0 {
    // Skip this test when openssl is unavailable in the runtime.
    return
  }

  @sys.set_env_var("BIT_RELAY_SIGN_PRIVATE_KEY_FILE", key_path)
  @sys.set_env_var("BIT_RELAY_SIGN_PUBLIC_KEY", "test-public-key")

  let seen_public_keys : Array[String] = []
  let seen_signatures : Array[String] = []
  let seen_timestamps : Array[String] = []
  let seen_nonces : Array[String] = []
  let post = async fn(
    _url : String,
    _body : Bytes,
    headers : Map[String, String],
  ) -> (@bit.HttpResponse, Bytes) raise @bit.GitError {
    let no_ops : Array[async () -> Unit] = []
    ignore(
      @async.all(no_ops) catch {
        err => raise @bit.GitError::IoError(err.to_string())
      },
    )
    match headers.get("x-relay-public-key") {
      Some(value) => seen_public_keys.push(value)
      None => ()
    }
    match headers.get("x-relay-signature") {
      Some(value) => seen_signatures.push(value)
      None => ()
    }
    match headers.get("x-relay-timestamp") {
      Some(value) => seen_timestamps.push(value)
      None => ()
    }
    match headers.get("x-relay-nonce") {
      Some(value) => seen_nonces.push(value)
      None => ()
    }
    (
      @bit.HttpResponse::new(200),
      @utf8.encode("{\"ok\":true,\"accepted\":true,\"cursor\":1}"),
    )
  }

  let result = relay_push_with_http(
    fs,
    git_dir,
    "http://relay.test",
    post,
    signing_key=None,
    auth_token=None,
  )

  @sys.unset_env_var("BIT_RELAY_SIGN_PRIVATE_KEY_FILE")
  @sys.unset_env_var("BIT_RELAY_SIGN_PUBLIC_KEY")
  ignore(
    @process.run("rm", ["-f", key_path], inherit_env=true) catch {
      _ => -1
    },
  )

  assert_true(result.success())
  assert_eq(seen_public_keys.length(), 1)
  assert_eq(seen_public_keys[0], "test-public-key")
  assert_eq(seen_signatures.length(), 1)
  assert_true(seen_signatures[0].length() > 0)
  assert_eq(seen_timestamps.length(), 1)
  assert_true(seen_timestamps[0].length() > 0)
  assert_eq(seen_nonces.length(), 1)
  assert_true(seen_nonces[0].length() > 0)
}

///|
async test "relay: relay push uses BIT_RELAY_SENDER for publish sender query" {
  let fs = @bit.TestFs::new()
  let git_dir = "/repo/.git"
  fs.mkdir_p(git_dir)
  let db = @lib.ObjectDb::load_lazy(fs, git_dir)
  let native_objects : NativeObjectStore = { db, rfs: fs, fs, git_dir }
  let native_refs : NativeRefStore = { fs, rfs: fs, git_dir }
  let objects : &@lib.ObjectStore = native_objects
  let refs : &@lib.RefStore = native_refs
  let store = @hub.HubStore::load(objects, refs, node_id="node-local")
  let clock : FixedClock = { now_ts: 1L }
  let clock_ref : &@lib.Clock = clock
  ignore(
    store.put_record(
      objects, refs, clock_ref, "hub/pr/1/meta", "hub.pr", "payload", "node-local",
    ),
  )
  @sys.set_env_var("BIT_RELAY_SENDER", "node-a")
  let seen_urls : Array[String] = []
  let post = async fn(
    url : String,
    _body : Bytes,
    _headers : Map[String, String],
  ) -> (@bit.HttpResponse, Bytes) raise @bit.GitError {
    let no_ops : Array[async () -> Unit] = []
    ignore(
      @async.all(no_ops) catch {
        err => raise @bit.GitError::IoError(err.to_string())
      },
    )
    seen_urls.push(url)
    (
      @bit.HttpResponse::new(200),
      @utf8.encode("{\"ok\":true,\"accepted\":true,\"cursor\":1}"),
    )
  }
  let result = relay_push_with_http(
    fs,
    git_dir,
    "relay+http://relay.test?room=team-a&room_token=token-1",
    post,
    signing_key=None,
    auth_token=None,
  )
  @sys.unset_env_var("BIT_RELAY_SENDER")
  assert_true(result.success())
  assert_eq(seen_urls.length(), 1)
  assert_true(seen_urls[0].contains("sender=node-a"))
  assert_true(seen_urls[0].contains("room=team-a"))
  assert_true(seen_urls[0].contains("room_token=token-1"))
}

///|
async test "relay: relay fetch forwards auth token header" {
  let fs = @bit.TestFs::new()
  let git_dir = "/repo/.git"
  fs.mkdir_p(git_dir)
  let db = @lib.ObjectDb::load_lazy(fs, git_dir)
  let native_objects : NativeObjectStore = { db, rfs: fs, fs, git_dir }
  let native_refs : NativeRefStore = { fs, rfs: fs, git_dir }
  let objects : &@lib.ObjectStore = native_objects
  let refs : &@lib.RefStore = native_refs
  let hub = @hub.Hub::load(objects, refs, node_id="node-local")
  let seen_auth : Array[String] = []
  let seen_urls : Array[String] = []
  let get = async fn(
    url : String,
    headers : Map[String, String],
  ) -> (@bit.HttpResponse, Bytes) raise @bit.GitError {
    let no_ops : Array[async () -> Unit] = []
    ignore(
      @async.all(no_ops) catch {
        err => raise @bit.GitError::IoError(err.to_string())
      },
    )
    seen_urls.push(url)
    match headers.get("Authorization") {
      Some(value) => seen_auth.push(value)
      None => ()
    }
    let body = "{\"ok\":true,\"room\":\"main\",\"next_cursor\":1,\"envelopes\":[]}"
    (@bit.HttpResponse::new(200), @utf8.encode(body))
  }
  let result = relay_fetch_with_http(
    hub,
    fs,
    fs,
    git_dir,
    "relay+http://relay.test?room=team-a&room_token=token-2",
    get,
    signing_key=None,
    auth_token=Some("token-2"),
  )
  assert_true(result.success())
  assert_eq(seen_auth.length(), 1)
  assert_eq(seen_auth[0], "Bearer token-2")
  assert_eq(seen_urls.length(), 1)
  assert_true(seen_urls[0].contains("room=team-a"))
  assert_true(seen_urls[0].contains("room_token=token-2"))
}

///|
async test "relay: strict signed policy rejects unsigned records during fetch" {
  let fs = @bit.TestFs::new()
  let git_dir = "/repo/.git"
  fs.mkdir_p(git_dir)
  let db = @lib.ObjectDb::load_lazy(fs, git_dir)
  let native_objects : NativeObjectStore = { db, rfs: fs, fs, git_dir }
  let native_refs : NativeRefStore = { fs, rfs: fs, git_dir }
  let objects : &@lib.ObjectStore = native_objects
  let refs : &@lib.RefStore = native_refs
  let hub = @hub.Hub::load(
    objects,
    refs,
    node_id="node-local",
    signing_key=Some("k1"),
    require_signed=true,
  )
  let result = relay_fetch_with_http(
    hub,
    fs,
    fs,
    git_dir,
    "http://relay.test",
    relay_test_http_get_ok,
    signing_key=Some("k1"),
    require_signed=true,
    auth_token=None,
  )
  assert_true(result.success())
  let notes_ref = @lib.resolve_ref(fs, git_dir, @hub.hub_notes_ref_name())
  assert_true(notes_ref is None)
  let strict_store = @hub.HubStore::load(
    objects,
    refs,
    node_id="node-local",
    signing_key=Some("k1"),
    require_signed=true,
  )
  let record = strict_store.get_record(objects, "hub/pr/1/meta")
  assert_true(record is None)
}

///|
test "relay: parse_relay_poll_clone_peers extracts latest announce per sender" {
  let body = "{\"ok\":true,\"room\":\"main\",\"next_cursor\":4,\"envelopes\":[{\"room\":\"main\",\"id\":\"h1\",\"sender\":\"node-a\",\"topic\":\"notify\",\"payload\":{\"kind\":\"hub.record\",\"record\":\"ignored\"},\"signature\":null},{\"room\":\"main\",\"id\":\"c1\",\"sender\":\"node-a\",\"topic\":\"notify\",\"payload\":{\"kind\":\"bit.clone.announce.v1\",\"clone_url\":\"http://node-a:9418/repo.git\",\"repo\":\"repo-a\"},\"signature\":null},{\"room\":\"main\",\"id\":\"c2\",\"sender\":\"node-self\",\"topic\":\"notify\",\"payload\":{\"kind\":\"bit.clone.announce.v1\",\"clone_url\":\"http://self:9418/repo.git\"},\"signature\":null},{\"room\":\"main\",\"id\":\"c3\",\"sender\":\"node-a\",\"topic\":\"notify\",\"payload\":{\"kind\":\"bit.clone.announce.v1\",\"clone_url\":\"http://node-a-new:9418/repo.git\",\"repo\":\"repo-a\"},\"signature\":null}]}"
  let (cursor, peers) = parse_relay_poll_clone_peers(
    body,
    include_self=false,
    self_sender="node-self",
  )
  assert_eq(cursor, 4)
  assert_eq(peers.length(), 1)
  let (sender, clone_url, repo) = peers[0]
  assert_eq(sender, "node-a")
  assert_eq(clone_url, "http://node-a-new:9418/repo.git")
  assert_eq(repo, Some("repo-a"))
}

///|
async test "relay: relay_publish_clone_announce_with_http publishes notify payload" {
  @sys.set_env_var("BIT_RELAY_SENDER", "node-self")
  let seen_urls : Array[String] = []
  let seen_bodies : Array[String] = []
  let seen_auth : Array[String] = []
  let post = async fn(
    url : String,
    body : Bytes,
    headers : Map[String, String],
  ) -> (@bit.HttpResponse, Bytes) raise @bit.GitError {
    let no_ops : Array[async () -> Unit] = []
    ignore(
      @async.all(no_ops) catch {
        err => raise @bit.GitError::IoError(err.to_string())
      },
    )
    seen_urls.push(url)
    seen_bodies.push(@utf8.decode_lossy(body[:]))
    match headers.get("Authorization") {
      Some(value) => seen_auth.push(value)
      None => ()
    }
    (
      @bit.HttpResponse::new(200),
      @utf8.encode("{\"ok\":true,\"accepted\":true,\"cursor\":1}"),
    )
  }
  let accepted = relay_publish_clone_announce_with_http(
    "relay+http://relay.test?room=team-a&room_token=token-3",
    "http://node-self:9418/repo.git",
    post,
    repo=Some("repo-self"),
    auth_token=Some("token-3"),
  )
  @sys.unset_env_var("BIT_RELAY_SENDER")
  assert_true(accepted)
  assert_eq(seen_urls.length(), 1)
  assert_true(seen_urls[0].contains("sender=node-self"))
  assert_true(seen_urls[0].contains("topic=notify"))
  assert_true(seen_urls[0].contains("room=team-a"))
  assert_true(seen_urls[0].contains("room_token=token-3"))
  assert_eq(seen_auth.length(), 1)
  assert_eq(seen_auth[0], "Bearer token-3")
  assert_eq(seen_bodies.length(), 1)
  assert_true(seen_bodies[0].contains("\"kind\":\"bit.clone.announce.v1\""))
  assert_true(
    seen_bodies[0].contains("\"clone_url\":\"http://node-self:9418/repo.git\""),
  )
}

///|
async test "relay: relay_list_clone_peers_with_http filters self sender by default" {
  let seen_auth : Array[String] = []
  let seen_urls : Array[String] = []
  let get = async fn(
    url : String,
    headers : Map[String, String],
  ) -> (@bit.HttpResponse, Bytes) raise @bit.GitError {
    let no_ops : Array[async () -> Unit] = []
    ignore(
      @async.all(no_ops) catch {
        err => raise @bit.GitError::IoError(err.to_string())
      },
    )
    seen_urls.push(url)
    match headers.get("Authorization") {
      Some(value) => seen_auth.push(value)
      None => ()
    }
    let body = "{\"ok\":true,\"room\":\"main\",\"next_cursor\":2,\"envelopes\":[{\"room\":\"main\",\"id\":\"c1\",\"sender\":\"bit\",\"topic\":\"notify\",\"payload\":{\"kind\":\"bit.clone.announce.v1\",\"clone_url\":\"http://self:9418/repo.git\"},\"signature\":null},{\"room\":\"main\",\"id\":\"c2\",\"sender\":\"node-peer\",\"topic\":\"notify\",\"payload\":{\"kind\":\"bit.clone.announce.v1\",\"clone_url\":\"http://peer:9418/repo.git\",\"repo\":\"repo-peer\"},\"signature\":null}]}"
    (@bit.HttpResponse::new(200), @utf8.encode(body))
  }
  let peers = relay_list_clone_peers_with_http(
    "relay+http://relay.test?room=team-a&room_token=token-4",
    get,
    auth_token=Some("token-4"),
    include_self=false,
  )
  let peers_including_self = relay_list_clone_peers_with_http(
    "relay+http://relay.test?room=team-a&room_token=token-4",
    get,
    auth_token=Some("token-4"),
    include_self=true,
  )
  assert_eq(seen_auth.length(), 2)
  assert_eq(seen_urls.length(), 2)
  assert_true(seen_urls[0].contains("room=team-a"))
  assert_true(seen_urls[0].contains("room_token=token-4"))
  assert_true(seen_urls[1].contains("room=team-a"))
  assert_true(seen_urls[1].contains("room_token=token-4"))
  assert_eq(seen_auth[0], "Bearer token-4")
  assert_eq(seen_auth[1], "Bearer token-4")
  assert_eq(peers.length(), 1)
  let (sender, clone_url, repo) = peers[0]
  assert_eq(sender, "node-peer")
  assert_eq(clone_url, "http://peer:9418/repo.git")
  assert_eq(repo, Some("repo-peer"))
  assert_eq(peers_including_self.length(), 2)
}

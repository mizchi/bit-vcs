///| Upload-pack fixture tests (git oracle)

///|
fn hex_char_val(c : Char) -> Int {
  if c >= '0' && c <= '9' {
    c.to_int() - '0'.to_int()
  } else if c >= 'a' && c <= 'f' {
    c.to_int() - 'a'.to_int() + 10
  } else if c >= 'A' && c <= 'F' {
    c.to_int() - 'A'.to_int() + 10
  } else {
    0
  }
}

///|
fn hex_to_bytes(hex : String) -> Bytes {
  let chars = hex.to_array()
  let len = hex.length()
  if len % 2 != 0 {
    return Bytes::from_array([])
  }
  let out : Array[Byte] = []
  for i in 0..<(len / 2) {
    let hi = hex_char_val(chars[i * 2])
    let lo = hex_char_val(chars[i * 2 + 1])
    out.push(((hi << 4) | lo).to_byte())
  }
  Bytes::from_array(FixedArray::makei(out.length(), fn(i) { out[i] }))
}

///|
fn append_bytes(buf : Array[Byte], text : String) -> Unit {
  for c in text {
    buf.push(c.to_int().to_byte())
  }
}

///|
fn bytes_to_string(buf : Array[Byte]) -> String {
  let sb = StringBuilder::new()
  for b in buf {
    sb.write_char(b.to_int().unsafe_to_char())
  }
  sb.to_string()
}

///|
let adv_v2_hex : String = "3030306576657273696f6e20320a303031636167656e743d6769742f322e35302e312d44617277696e0a303031336c732d726566733d756e626f726e0a3030323066657463683d7368616c6c6f7720776169742d666f722d646f6e650a303031327365727665722d6f7074696f6e0a303031376f626a6563742d666f726d61743d736861310a30303030"

///|
let lsrefs_hex : String = "303035303330633966323038616363373630313737336132396165663339343135376164663936306431303420484541442073796d7265662d7461726765743a726566732f68656164732f6d61696e0a303033643330633966323038616363373630313737336132396165663339343135376164663936306431303420726566732f68656164732f6d61696e0a30303030"

///|
let fetch_hex : String = "303030647061636b66696c650a30306435015041434b00000002000000039b09789c95cb310ac3300c40d1dda7f05e28b21ccb319492ab288ad208ea0682baf4f4cd15327d78f0fd508dccdc4874c1a57192512b4aa1194b66505cb58eb9e555e71af8ebdb7ec46e3fd92c3ece0e304cafcef6becbde9f31556a2513258c376800e1d46eee7a690af6310f7f8ae52e13a502789c33343030333151c848cdc9c9d72ba9286138c768a6caccbde2f64ab6ef61d3eae7cd593cc5cd0b00df740dbf36789ccb48cdc9c9e70200084b021f62c7bf336ea966f094470f354a76a0f737e13d30303036017a30303030"

///|
let fixture_commit : String = "30c9f208acc7601773a29aef394157adf960d104"

///|
let fixture_tree : String = "aaa96ced2d9a1c8e72c56b253a0e2fe78393feb7"

///|
let fixture_blob : String = "ce013625030ba8dba906f756967f9e9ca394464a"

///|
test "upload-pack v2: advertised capabilities" {
  let adv = hex_to_bytes(adv_v2_hex)
  assert_true(
    @protocol.detect_protocol_version(adv) == @protocol.ProtocolVersion::V2,
  )
  let caps = @protocol.parse_v2_advertised_caps(adv)
  assert_true(caps.contains("ls-refs=unborn"))
  assert_true(caps.contains("fetch=shallow wait-for-done"))
  assert_true(caps.contains("object-format=sha1"))
}

///|
test "upload-pack v2: ls-refs response" {
  let resp = hex_to_bytes(lsrefs_hex)
  let result = @protocol.parse_ls_refs_response(resp)
  assert_true(result.refs.length() == 2)
  match result.symrefs.get("HEAD") {
    Some(target) => assert_true(target == "refs/heads/main")
    None => assert_true(false)
  }
  let mut found = false
  for item in result.refs {
    let (id, name) = item
    if name == "refs/heads/main" {
      assert_true(id.to_hex() == fixture_commit)
      found = true
    }
  }
  assert_true(found)
}

///|
test "upload-pack v2: fetch response packfile" {
  let resp = hex_to_bytes(fetch_hex)
  let pack = @protocol.extract_pack_from_v2_response(resp)
  let objects = @pack.parse_packfile(pack)
  let store = @bit.ObjectStore::from_pack(objects)
  let commit_id = @bit.ObjectId::from_hex(fixture_commit)
  let tree_id = @bit.ObjectId::from_hex(fixture_tree)
  let blob_id = @bit.ObjectId::from_hex(fixture_blob)
  assert_true(store.contains(commit_id))
  assert_true(store.contains(tree_id))
  assert_true(store.contains(blob_id))
  let files = @bit.checkout_commit(store, commit_id)
  match files.get("hello.txt") {
    Some(data) => {
      let text = @utf8.decode_lossy(data[:])
      inspect(text, content="hello\n")
    }
    None => assert_true(false)
  }
}

///|
test "upload-pack v2: materialize clone to fs" {
  let resp = hex_to_bytes(fetch_hex)
  let pack = @protocol.extract_pack_from_v2_response(resp)
  let objects = @pack.parse_packfile(pack)
  let store = @bit.ObjectStore::from_pack(objects)
  let commit_id = @bit.ObjectId::from_hex(fixture_commit)
  let fs = @bit.TestFs::new()
  @bit.materialize_clone_to_fs(
    store, commit_id, "refs/heads/main", "https://example.com/repo.git", fs, "/repo",
  )
  let data = fs.read_file("/repo/hello.txt")
  let text = @utf8.decode_lossy(data[:])
  inspect(text, content="hello\n")
  let head = fs.read_string("/repo/.git/HEAD")
  inspect(head, content="ref: refs/heads/main\n")
  let ref_text = fs.read_string("/repo/.git/refs/heads/main")
  inspect(ref_text, content="\{fixture_commit}\n")
  let config = fs.read_string("/repo/.git/config")
  assert_true(config.contains("https://example.com/repo.git"))
  assert_true(fs.exists("/repo/.git/index"))
}

///|
test "upload-pack v0: advertised symref is used as HEAD target" {
  let refs_line : Array[Byte] = []
  append_bytes(refs_line, fixture_commit)
  append_bytes(refs_line, " HEAD")
  refs_line.push(b'\x00')
  append_bytes(refs_line, "symref=HEAD:refs/heads/main agent=git/2.53.0\n")
  let branch_line : Array[Byte] = []
  append_bytes(branch_line, fixture_commit)
  append_bytes(branch_line, " refs/heads/main\n")
  let adv = @protocol.pktline_encode(bytes_to_string(refs_line)) +
    @protocol.pktline_encode(bytes_to_string(branch_line)) +
    @protocol.pktline_flush()
  let refs = @protocol.parse_refs(adv)
  assert_true(refs.length() == 2)

  let symrefs : Map[String, String] = { "HEAD": "refs/heads/main" }
  match symrefs.get("HEAD") {
    Some(target) => assert_true(target == "refs/heads/main")
    None => assert_true(false)
  }
  match @protocol.select_default_ref(refs, symrefs) {
    Some((name, commit_id)) => {
      assert_true(name == "refs/heads/main")
      assert_true(commit_id.to_hex() == fixture_commit)
    }
    None => assert_true(false)
  }
  let wants = @protocol.select_default_wants(refs, symrefs)
  assert_true(wants.length() == 1)
  assert_true(wants[0].to_hex() == fixture_commit)
}

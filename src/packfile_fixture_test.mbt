///|
/// Packfile fixture tests (git oracle)

///|
let oracle_pack_hex : String = "5041434b00000002000000049a097801019a0065ff7472656520383865333837303566646264333630386364646265393034623637633733316633323334633435620a617574686f722054657374203c74657374406578616d706c652e636f6d3e2031373030303030303030202b303030300a636f6d6d69747465722054657374203c74657374406578616d706c652e636f6d3e2031373030303030303030202b303030300a0a696e697469616c0a17112dd9aa047801014a00b5ff3130303634342068656c6c6f2e74787400ce013625030ba8dba906f756967f9e9ca394464a31303036343420776f726c642e74787400cc628ccd10742baea8241c5924df992b5c019f71c79c1b1d367801010600f9ff68656c6c6f0a084b021f367801010600f9ff776f726c640a08d90233ab151860f56db826bbcde3a97379bc7545b1a7d2"

///|
let oracle_deflate_hex : String = "5041434b00000002000000049a097801958bcb0980301005efa962ef8244379a0822166103f9ac18302aba82e5ab6003bec3300c3cde89c01842a365350617b096c687e0a891cad5da6b2c462c51795539614f9ed61d063a185a7ed8d365d33653eed7d441a1e537c85e114f4d91997e5c445c22473b8b1b17112dd9aa04780133343030333151c848cdc9c9d72ba9286138c768a6caccbde2f64ab6ef61d3eae7cd593cc5cdcb10a2a83cbf282705ace84c52cf598112ed752b54642255eecfd48e619c5f0800c79c1b1d367801cb48cdc9c9e70200084b021f3678012bcf2fca49e1020008d90233be0f16caf0da4cf166bd0c1248380f642dd35bf8"

///|
let oracle_delta_hex : String = "5041434b00000002000000049a097801958b410a84301004ef79c5dc172491814490c547ec0762d2c180594547f0f946f003f6a129ba68d9004a2307d66cdbc8513b40b7ce1a708a694c0ed51a84683a56fe9069d9e8875da897da034e5fd6194d58ca978cd54fe87383aa6bc922787151f99f25fb595d6f1e2e95a70478013334303033315148ca4cd72ba9286150b351176bc80d99b5c04e7b6ffbccd9af2576069a1bc2951881d584e545c6395c9e96befdb1f1ed6deb2bf676446ab8010056aa1aacb1800178014b4c1c05a321301a02a321301a02a321301a02232d04b8004a3608387e263c2716806d549aa03e2bbd87999beb18b9513778016b14681458c0c298b491f13f332317001ffe03e92dec04ec6a876ccd940e20792662b371fcb9551a"

///|
let oracle_thin_hex : String = "5041434b0000000200000003950c7801958b410ac2301045f73945f68264326d2605110fe10592c90c0ac69676048f6fc513f8169fc78767ab886f9a22eb3845aa238756884118a3002644a541ebc4ca53734b59e5699e10b968a89c43952494221566a80459920e2d2a64dc5b575e769b577f95cdfcc9f6bdc8bbf4e521479efbd903851fe00f5f71fbdbef66f247e238ba0f18973a19a30278013334303033315148ca4cd72ba9286108cb8b8c73b83c2d7dfb63e3dbdbd657eced88d4700300d8780e2c7e263c2716806d549aa03e2bbd87999beb18b9513778016b14681458c0c298b491f13f332317001ffe03e9ab192291c3d38617a830e6d2a928eb304cc3f3ff"

///|
let oracle_thin_base_hex : String = "5041434b0000000200000003950978012b294a4d55304d363534333633b64c4e4a4b49b1b048b330b0b048344f363130b6343732354f3632364c353137e44a2c2dc9c82f5208492d2e51b02901920ea91589b90539a97ac9f9b9760a86e60650a0a00d6270014573334b4a5249d0c2956cc80500df652acea30278013334303033315148ca4cd72ba9286150b351176bc80d99b5c04e7b6ffbccd9af2576069a0300bb770c4fb1800178014b4c1c05a321301a02a321301a02a321301a02232d04b8004a3608382570814282dac5a49081c350d0575bdd9f254c64"

///|
let oracle_after_delta_hex : String = "5041434b00000002000000067f566e595e40d39667b7e333dbb6af78bd8859284678016b14681458c0b251e003f3440101462e00277f0437950c7801958b410ac2301045f73945f68264326d2605110fe10592c90c0ac69676048f6fc513f8169fc78767ab886f9a22eb3845aa238756884118a3002644a541ebc4ca53734b59e5699e10b968a89c43952494221566a80459920e2d2a64dc5b575e769b577f95cdfcc9f6bdc8bbf4e521479efbd903851fe00f5f71fbdbef66f247e238ba0f18973a19950978012b294a4d55304d363534333633b64c4e4a4b49b1b048b330b0b048344f363130b6343732354f3632364c353137e44a2c2dc9c82f5208492d2e51b02901920ea91589b90539a97ac9f9b9760a86e60650a0a00d6270014573334b4a5249d0c2956cc80500df652acea30278013334303033315148ca4cd72ba9286108cb8b8c73b83c2d7dfb63e3dbdbd657eced88d4700300d8780e2cb1800178014b4c1c05a321301a022335049246aac747fd3d1a02a32190c805004e370839a30278013334303033315148ca4cd72ba9286150b351176bc80d99b5c04e7b6ffbccd9af2576069a0300bb770c4fc1a821f0b71cc0b44ca33a69d3511760b91cfa52"

///|
test "packfile fixture: oracle.pack" {
  let packfile = load_fixture("oracle.pack", oracle_pack_hex)
  let objects = parse_packfile(packfile)
  assert_true(objects.length() == 4)
  assert_true(count_type(objects, ObjectType::Commit) == 1)
  assert_true(count_type(objects, ObjectType::Tree) == 1)
  assert_true(count_type(objects, ObjectType::Blob) == 2)
  let ids = collect_object_ids(objects)
  assert_true(ids.contains("4332a3d7c17f1ce072e6691f6856d1c9bf9d2f9d"))
  assert_true(ids.contains("88e38705fdbd3608cddbe904b67c731f3234c45b"))
  assert_true(ids.contains("ce013625030ba8dba906f756967f9e9ca394464a"))
  assert_true(ids.contains("cc628ccd10742baea8241c5924df992b5c019f71"))
}

///|
test "packfile fixture: oracle_deflate.pack" {
  let packfile = load_fixture("oracle_deflate.pack", oracle_deflate_hex)
  let objects = parse_packfile(packfile)
  assert_true(objects.length() == 4)
  assert_true(count_type(objects, ObjectType::Commit) == 1)
  assert_true(count_type(objects, ObjectType::Tree) == 1)
  assert_true(count_type(objects, ObjectType::Blob) == 2)
  let ids = collect_object_ids(objects)
  assert_true(ids.contains("4332a3d7c17f1ce072e6691f6856d1c9bf9d2f9d"))
  assert_true(ids.contains("88e38705fdbd3608cddbe904b67c731f3234c45b"))
  assert_true(ids.contains("ce013625030ba8dba906f756967f9e9ca394464a"))
  assert_true(ids.contains("cc628ccd10742baea8241c5924df992b5c019f71"))
}

///|
test "packfile fixture: oracle_delta.pack" {
  let packfile = load_fixture("oracle_delta.pack", oracle_delta_hex)
  let objects = parse_packfile(packfile)
  assert_true(objects.length() == 4)
  assert_true(count_type(objects, ObjectType::Commit) == 1)
  assert_true(count_type(objects, ObjectType::Tree) == 1)
  assert_true(count_type(objects, ObjectType::Blob) == 2)
  let ids = collect_object_ids(objects)
  assert_true(ids.contains("8fddbcdcd14623cc3b31587df65e562f53cf5554"))
  assert_true(ids.contains("fb4c40472d4d08ee02871e4fdfbf8efb41ecd194"))
  assert_true(ids.contains("263c2716806d549aa03e2bbd87999beb18b95137"))
  assert_true(ids.contains("566e595e40d39667b7e333dbb6af78bd88592846"))
  let sizes = collect_blob_sizes(objects)
  assert_true(sizes.contains(2049))
  assert_true(sizes.length() == 1)
}

///|
test "packfile fixture: oracle_thin.pack (missing base)" {
  let packfile = load_fixture("oracle_thin.pack", oracle_thin_hex)
  let result : Result[Array[PackObject], GitError] = try? parse_packfile(
    packfile,
  )
  match result {
    Err(GitError::PackfileError(_)) => ()
    _ => assert_true(false)
  }
}

///|
test "packfile fixture: oracle_thin.pack (with base)" {
  let base_pack = load_fixture("oracle_thin_base.pack", oracle_thin_base_hex)
  let base_objects = parse_packfile(base_pack)
  let packfile = load_fixture("oracle_thin.pack", oracle_thin_hex)
  let objects = parse_packfile_with_bases(packfile, base_objects)
  assert_true(objects.length() == 3)
  let ids = collect_object_ids(objects)
  assert_true(ids.contains("3a76cfa1c53d259541847fc7f35de3d6a673ef1d"))
  assert_true(ids.contains("df62cf5927b5c0da7c1ec32e13633f74fb9cfc9d"))
  assert_true(ids.contains("566e595e40d39667b7e333dbb6af78bd88592846"))
}

///|
test "packfile fixture: oracle_after_delta.pack (base after delta)" {
  let packfile = load_fixture("oracle_after_delta.pack", oracle_after_delta_hex)
  let objects = parse_packfile(packfile)
  assert_true(objects.length() == 6)
  assert_true(count_type(objects, ObjectType::Commit) == 2)
  assert_true(count_type(objects, ObjectType::Tree) == 2)
  assert_true(count_type(objects, ObjectType::Blob) == 2)
  let ids = collect_object_ids(objects)
  assert_true(ids.contains("3a76cfa1c53d259541847fc7f35de3d6a673ef1d"))
  assert_true(ids.contains("733caf0bc80be6e7627acc1b718e6f4d2f183363"))
  assert_true(ids.contains("df62cf5927b5c0da7c1ec32e13633f74fb9cfc9d"))
  assert_true(ids.contains("5c5163639cbfdd88f8088a7c40397257c231e471"))
  assert_true(ids.contains("566e595e40d39667b7e333dbb6af78bd88592846"))
  assert_true(ids.contains("263c2716806d549aa03e2bbd87999beb18b95137"))
}

///|
fn collect_object_ids(objects : Array[PackObject]) -> Map[String, Bool] {
  let ids : Map[String, Bool] = {}
  for obj in objects {
    let id = hash_object_content(obj.obj_type, obj.data)
    ids[id.to_hex()] = true
  }
  ids
}

///|
fn collect_blob_sizes(objects : Array[PackObject]) -> Map[Int, Bool] {
  let sizes : Map[Int, Bool] = {}
  for obj in objects {
    if obj.obj_type == ObjectType::Blob {
      sizes[obj.data.length()] = true
    }
  }
  sizes
}

///|
fn count_type(objects : Array[PackObject], t : ObjectType) -> Int {
  let mut count = 0
  for obj in objects {
    if obj.obj_type == t {
      count = count + 1
    }
  }
  count
}

///|
fn load_fixture(_name : String, hex : String) -> Bytes {
  hex_to_bytes(hex)
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
    let hi = hex_char_to_int(chars[i * 2])
    let lo = hex_char_to_int(chars[i * 2 + 1])
    out.push(((hi << 4) | lo).to_byte())
  }
  Bytes::from_array(FixedArray::makei(out.length(), fn(i) { out[i] }))
}

///|
fn hex_char_to_int(c : Char) -> Int {
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
fn hash_object_content(obj_type : ObjectType, content : Bytes) -> ObjectId {
  let header = "\{obj_type.to_string()} \{content.length()}\u0000"
  let bytes : Array[Byte] = []
  for c in header {
    bytes.push(c.to_int().to_byte())
  }
  for b in content {
    bytes.push(b)
  }
  sha1(Bytes::from_array(FixedArray::makei(bytes.length(), fn(i) { bytes[i] })))
}

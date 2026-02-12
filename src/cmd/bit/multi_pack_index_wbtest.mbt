///|
fn make_test_oid(byte : Byte) -> @git.ObjectId {
  @git.ObjectId::new(FixedArray::make(20, byte))
}

///|
test "midx stdin pack normalize supports idx and pack paths" {
  assert_eq(
    midx_normalize_stdin_pack_name(
      "pack-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.idx",
    ),
    Some("pack-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.pack"),
  )
  assert_eq(
    midx_normalize_stdin_pack_name(
      "/tmp/pack-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb.pack",
    ),
    Some("pack-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb.pack"),
  )
  assert_eq(midx_normalize_stdin_pack_name("foo.txt"), None)
}

///|
test "midx stdin pack selection keeps include order and applies excludes" {
  let selected = midx_select_pack_files_from_stdin(
    [
      "pack-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.pack", "pack-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb.pack",
      "pack-cccccccccccccccccccccccccccccccccccccccc.pack",
    ],
    [
      "pack-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb.idx", "pack-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.pack",
      "pack-unknown.idx",
    ],
    ["pack-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.idx"],
  )
  assert_eq(selected.length(), 1)
  assert_eq(selected[0], "pack-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb.pack")
}

///|
test "midx stdin pack selection with empty stdin keeps no packs" {
  let selected = midx_select_pack_files_from_stdin(
    [
      "pack-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.pack", "pack-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb.pack",
    ],
    [],
    [],
  )
  assert_eq(selected.length(), 0)
}

///|
test "midx build writes BTMP chunk only when --bitmap is requested" {
  let pack_files = [
    "pack-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.pack", "pack-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb.pack",
    "pack-cccccccccccccccccccccccccccccccccccccccc.pack",
  ]
  let entries : Array[MidxEntry] = [
    {
      id: make_test_oid(b'\x01'),
      pack_idx: 0,
      pack_mtime: 0,
      offset_hi: 0,
      offset: 1,
    },
    {
      id: make_test_oid(b'\x02'),
      pack_idx: 0,
      pack_mtime: 0,
      offset_hi: 0,
      offset: 2,
    },
    {
      id: make_test_oid(b'\x03'),
      pack_idx: 2,
      pack_mtime: 0,
      offset_hi: 0,
      offset: 3,
    },
  ]
  let with_bitmap = midx_build(pack_files, entries, true, 1)
  let chunk_count = with_bitmap[6].to_int()
  let btmp_offset = midx_find_chunk(with_bitmap, chunk_count, "BTMP")
  assert_true(btmp_offset > 0)
  let btmp_end = midx_find_chunk_end(with_bitmap, chunk_count, "BTMP")
  assert_eq(btmp_end - btmp_offset, pack_files.length() * 8)
  assert_eq(midx_read_u32(with_bitmap, btmp_offset), 0)
  assert_eq(midx_read_u32(with_bitmap, btmp_offset + 4), 2)
  assert_eq(midx_read_u32(with_bitmap, btmp_offset + 8), 2)
  assert_eq(midx_read_u32(with_bitmap, btmp_offset + 12), 0)
  assert_eq(midx_read_u32(with_bitmap, btmp_offset + 16), 2)
  assert_eq(midx_read_u32(with_bitmap, btmp_offset + 20), 1)
  let without_bitmap = midx_build(pack_files, entries, false, 1)
  let without_chunk_count = without_bitmap[6].to_int()
  assert_eq(midx_find_chunk(without_bitmap, without_chunk_count, "BTMP"), 0)
}

///|
test "midx build writes LOFF chunk for large offsets" {
  let pack_files = ["pack-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.pack"]
  let entries : Array[MidxEntry] = [
    {
      id: make_test_oid(b'\x01'),
      pack_idx: 0,
      pack_mtime: 0,
      offset_hi: 0,
      offset: 1,
    },
    {
      id: make_test_oid(b'\x02'),
      pack_idx: 0,
      pack_mtime: 0,
      offset_hi: 1,
      offset: 2,
    },
    {
      id: make_test_oid(b'\x03'),
      pack_idx: 0,
      pack_mtime: 0,
      offset_hi: 0,
      offset: -1,
    },
  ]
  let data = midx_build(pack_files, entries, false, 1)
  let chunk_count = data[6].to_int()
  let ooff_offset = midx_find_chunk(data, chunk_count, "OOFF")
  let loff_offset = midx_find_chunk(data, chunk_count, "LOFF")
  assert_true(ooff_offset > 0)
  assert_true(loff_offset > 0)
  assert_eq(midx_read_u32(data, ooff_offset + 4), 1)
  let marker0 = midx_read_u32(data, ooff_offset + 12)
  assert_true(marker0 < 0)
  assert_eq(marker0 & 2147483647, 0)
  let marker1 = midx_read_u32(data, ooff_offset + 20)
  assert_true(marker1 < 0)
  assert_eq(marker1 & 2147483647, 1)
  assert_eq(midx_read_u32(data, loff_offset), 1)
  assert_eq(midx_read_u32(data, loff_offset + 4), 2)
  assert_eq(midx_read_u32(data, loff_offset + 8), 0)
  assert_eq(midx_read_u32(data, loff_offset + 12), -1)
}

///|
test "midx build writes oid version byte from argument" {
  let pack_files = ["pack-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.pack"]
  let entries : Array[MidxEntry] = [
    {
      id: make_test_oid(b'\x01'),
      pack_idx: 0,
      pack_mtime: 0,
      offset_hi: 0,
      offset: 1,
    },
  ]
  let sha1 = midx_build(pack_files, entries, false, 1)
  let sha256 = midx_build(pack_files, entries, false, 2)
  assert_eq(sha1[5].to_int(), 1)
  assert_eq(sha256[5].to_int(), 2)
}

///|
test "midx read pack usage returns referenced object counts per pack" {
  let pack_files = [
    "pack-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.pack", "pack-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb.pack",
  ]
  let entries : Array[MidxEntry] = [
    {
      id: make_test_oid(b'\x01'),
      pack_idx: 0,
      pack_mtime: 0,
      offset_hi: 0,
      offset: 1,
    },
    {
      id: make_test_oid(b'\x02'),
      pack_idx: 0,
      pack_mtime: 0,
      offset_hi: 0,
      offset: 2,
    },
    {
      id: make_test_oid(b'\x03'),
      pack_idx: 1,
      pack_mtime: 0,
      offset_hi: 0,
      offset: 3,
    },
  ]
  let data = midx_build(pack_files, entries, false, 1)
  let usage = midx_read_pack_usage_from_data(data)
  guard usage is Some((names, counts)) else { fail("expected pack usage") }
  assert_eq(names.length(), 2)
  assert_eq(names[0], pack_files[0])
  assert_eq(names[1], pack_files[1])
  assert_eq(counts.length(), 2)
  assert_eq(counts[0], 2)
  assert_eq(counts[1], 1)
}

///|
test "midx expected repack size scales by referenced ratio" {
  assert_eq(midx_expected_repack_size(0, 4, 1000), 0)
  assert_eq(midx_expected_repack_size(1, 4, 1000), 250)
  assert_eq(midx_expected_repack_size(3, 4, 1000), 750)
}

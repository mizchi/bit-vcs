///| Benchmarks for recent midx and fetch/clone hot paths

///|
/// Run with:
/// - moon bench -p mizchi/bit/cmd/bit --target native -f bench_midx_clone_wbtest.mbt

///|
let bench_pack_count : Int = 1500

///|
let bench_include_repeat : Int = 3

///|
let bench_clone_cap_count : Int = 240

///|
fn make_bench_all_pack_files() -> Array[String] {
  let out : Array[String] = []
  for i in 0..<bench_pack_count {
    out.push("pack-\{i}.pack")
  }
  out
}

///|
fn make_bench_include_names() -> Array[String] {
  let out : Array[String] = []
  for i in 0..<bench_pack_count {
    for r in 0..<bench_include_repeat {
      if r % 2 == 0 {
        out.push("/tmp/objects/pack/pack-\{i}.idx")
      } else {
        out.push("pack-\{i}.pack")
      }
    }
  }
  out
}

///|
fn make_bench_exclude_names() -> Array[String] {
  let out : Array[String] = []
  for i in 0..<bench_pack_count {
    if i % 3 == 0 {
      out.push("pack-\{i}.idx")
      out.push("pack-\{i}.idx")
    }
  }
  out
}

///|
fn make_bench_clone_caps() -> Array[String] {
  let out : Array[String] = []
  for i in 0..<bench_clone_cap_count {
    if i % 4 == 0 {
      out.push(
        "multi_ack thin-pack side-band-64k ofs-delta no-progress include-tag agent=git/2.\{i}",
      )
    } else if i % 4 == 1 {
      out.push("fetch=shallow deepen-since deepen-not filter")
    } else if i % 4 == 2 {
      out.push("fetch=shallow deepen-since deepen-not")
    } else {
      out.push("symref=HEAD:refs/heads/main object-format=sha1")
    }
  }
  out
}

///|
let bench_all_pack_files : Array[String] = make_bench_all_pack_files()

///|
let bench_include_names : Array[String] = make_bench_include_names()

///|
let bench_exclude_names : Array[String] = make_bench_exclude_names()

///|
let bench_clone_caps : Array[String] = make_bench_clone_caps()

///|
test "bench midx_select_pack_files_from_stdin large include/exclude" (
  b : @bench.T,
) {
  b.bench(fn() {
    let selected = midx_select_pack_files_from_stdin(
      bench_all_pack_files, bench_include_names, bench_exclude_names,
    )
    b.keep(selected.length())
  })
}

///|
test "bench clone_caps_contain_token filter present" (b : @bench.T) {
  b.bench(fn() { b.keep(clone_caps_contain_token(bench_clone_caps, "filter")) })
}

///|
test "bench clone_caps_contain_token filter missing" (b : @bench.T) {
  b.bench(fn() {
    b.keep(clone_caps_contain_token(bench_clone_caps, "bundle-uri"))
  })
}

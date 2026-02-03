///| Benchmarks for index and diff operations

///|
/// Run with:
/// - moon bench -p mizchi/bit/lib --target native

///|
let bench_index_root_base : String = "/tmp/bit_bench_index_diff"

///|
fn bench_index_join_path(root : String, path : String) -> String {
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
fn bench_index_ensure_dir(path : String) -> Unit {
  if not(@fs.path_exists(path)) {
    @fs.create_dir(path) catch {
      _ => ()
    }
  }
}

///|
fn bench_index_ensure_repo(root : String, file_count : Int) -> Unit {
  let marker = bench_index_join_path(root, ".bench_ready")
  if @fs.path_exists(marker) {
    return
  }
  bench_index_ensure_dir(bench_index_root_base)
  bench_index_ensure_dir(root)
  let fs = @osfs.OsFs::new()
  init_repo(fs, root) catch {
    _ => ()
  }
  let paths : Array[String] = []
  for i in 0..<file_count {
    let path = bench_index_join_path(root, "file_\{i}.txt")
    @fs.write_string_to_file(path, "content\n") catch {
      _ => ()
    }
    paths.push("file_\{i}.txt")
  }
  add_paths(fs, fs, root, paths) catch {
    _ => ()
  }
  ignore(try? commit(fs, fs, root, "init", "Author <a@b.com>", 1700000000L))
  @fs.write_string_to_file(marker, "ok\n") catch {
    _ => ()
  }
}

///|
let bench_index_small_root : String = bench_index_join_path(
  bench_index_root_base, "small",
)

///|
let bench_index_large_root : String = bench_index_join_path(
  bench_index_root_base, "large",
)

///|
test "bench read_index_entries small" (b : @bench.T) {
  bench_index_ensure_repo(bench_index_small_root, 200)
  let fs = @osfs.OsFs::new()
  let git_dir = bench_index_join_path(bench_index_small_root, ".git")
  b.bench(fn() {
    let entries = try! read_index_entries(fs, git_dir)
    b.keep(entries.length())
  })
}

///|
test "bench read_index_entries large" (b : @bench.T) {
  bench_index_ensure_repo(bench_index_large_root, 2000)
  let fs = @osfs.OsFs::new()
  let git_dir = bench_index_join_path(bench_index_large_root, ".git")
  b.bench(fn() {
    let entries = try! read_index_entries(fs, git_dir)
    b.keep(entries.length())
  })
}

///|
test "bench diff_index small" (b : @bench.T) {
  bench_index_ensure_repo(bench_index_small_root, 200)
  let fs = @osfs.OsFs::new()
  b.bench(fn() {
    let diffs = try! diff_index(fs, bench_index_small_root)
    b.keep(diffs.length())
  })
}

///|
test "bench diff_index large" (b : @bench.T) {
  bench_index_ensure_repo(bench_index_large_root, 2000)
  let fs = @osfs.OsFs::new()
  b.bench(fn() {
    let diffs = try! diff_index(fs, bench_index_large_root)
    b.keep(diffs.length())
  })
}

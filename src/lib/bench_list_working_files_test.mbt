///| Benchmarks for worktree file walking

///|
/// Run with:
/// - moon bench -p mizchi/bit/lib --target native

///|
let bench_root_base : String = "/tmp/bit_bench_list_working_files"

///|
fn join_path(root : String, path : String) -> String {
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
let bench_small_root : String = join_path(bench_root_base, "small")

///|
let bench_large_root : String = join_path(bench_root_base, "large")

///|
fn ensure_dir(path : String) -> Unit {
  if not(@fs.path_exists(path)) {
    @fs.create_dir(path) catch {
      _ => ()
    }
  }
}

///|
fn ensure_bench_repo(root : String, file_count : Int, dir_count : Int) -> Unit {
  let marker = join_path(root, ".bench_ready")
  if @fs.path_exists(marker) {
    return
  }
  ensure_dir(bench_root_base)
  ensure_dir(root)
  ensure_dir(join_path(root, ".git"))
  let ignore_path = join_path(root, ".gitignore")
  if not(@fs.path_exists(ignore_path)) {
    @fs.write_string_to_file(ignore_path, "ignore*\n") catch {
      _ => ()
    }
  }
  for i in 0..<file_count {
    let path = join_path(root, "file_\{i}.txt")
    @fs.write_string_to_file(path, "content\n") catch {
      _ => ()
    }
  }
  let ignored = if file_count / 10 > 0 { file_count / 10 } else { 1 }
  for i in 0..<ignored {
    let path = join_path(root, "ignore_\{i}.txt")
    @fs.write_string_to_file(path, "ignore\n") catch {
      _ => ()
    }
  }
  let per_dir = if dir_count > 0 { file_count / dir_count } else { 0 }
  for d in 0..<dir_count {
    let dir = join_path(root, "dir_\{d}")
    ensure_dir(dir)
    for i in 0..<per_dir {
      let path = join_path(dir, "file_\{i}.txt")
      @fs.write_string_to_file(path, "content\n") catch {
        _ => ()
      }
    }
  }
  @fs.write_string_to_file(marker, "ok\n") catch {
    _ => ()
  }
}

///|
fn bench_list_walk_plain(
  fs : &@git.RepoFileSystem,
  root : String,
  rel : String,
  out : Array[String],
) -> Unit raise @git.GitError {
  let dir = if rel == "" { root } else { join_path(root, rel) }
  if rel != "" {
    let git_marker = join_path(dir, ".git")
    if fs.is_file(git_marker) || fs.is_dir(git_marker) {
      return ()
    }
  }
  let entries = fs.readdir(dir)
  for name in entries {
    if name == "." || name == ".." || name == ".git" || name == ".jj" {
      continue
    }
    let child_rel = if rel == "" { name } else { rel + "/" + name }
    let child_path = join_path(root, child_rel)
    let is_dir = fs.is_dir(child_path)
    let is_file = fs.is_file(child_path)
    if is_dir {
      bench_list_walk_plain(fs, root, child_rel, out)
    } else if is_file {
      out.push(child_rel)
    }
  }
}

///|
test "bench list_working_files small" (b : @bench.T) {
  ensure_bench_repo(bench_small_root, 200, 4)
  let fs = @osfs.OsFs::new()
  b.bench(fn() {
    let files = try! list_working_files(fs, bench_small_root)
    b.keep(files.length())
  })
}

///|
test "bench list_working_files large" (b : @bench.T) {
  ensure_bench_repo(bench_large_root, 2000, 20)
  let fs = @osfs.OsFs::new()
  b.bench(fn() {
    let files = try! list_working_files(fs, bench_large_root)
    b.keep(files.length())
  })
}

///|
test "bench walk_plain small" (b : @bench.T) {
  ensure_bench_repo(bench_small_root, 200, 4)
  let fs = @osfs.OsFs::new()
  b.bench(fn() {
    let out : Array[String] = []
    try! bench_list_walk_plain(fs, bench_small_root, "", out)
    b.keep(out.length())
  })
}

///|
test "bench walk_plain large" (b : @bench.T) {
  ensure_bench_repo(bench_large_root, 2000, 20)
  let fs = @osfs.OsFs::new()
  b.bench(fn() {
    let out : Array[String] = []
    try! bench_list_walk_plain(fs, bench_large_root, "", out)
    b.keep(out.length())
  })
}

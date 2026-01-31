///| GitFs benchmarks

///|
/// Run with:
/// - moon bench -p mizchi/git/x/gitfs --target native

///|
let bench_1kb : Bytes = Bytes::make(1024, b'x')

///|
let bench_64kb : Bytes = Bytes::make(65536, b'x')

///|
let bench_1mb : Bytes = Bytes::make(1024 * 1024, b'x')

///|
test "bench sha1 1KB" (b : @bench.T) {
  b.bench(fn() { b.keep(@git.sha1(bench_1kb)) })
}

///|
test "bench sha1 64KB" (b : @bench.T) {
  b.bench(fn() { b.keep(@git.sha1(bench_64kb)) })
}

///|
test "bench sha1 1MB" (b : @bench.T) {
  b.bench(fn() { b.keep(@git.sha1(bench_1mb)) })
}

///|
test "bench hash_blob 1KB" (b : @bench.T) {
  b.bench(fn() { b.keep(@git.hash_blob(bench_1kb)) })
}

///|
test "bench hash_blob 64KB" (b : @bench.T) {
  b.bench(fn() { b.keep(@git.hash_blob(bench_64kb)) })
}

///|
test "bench zlib compress 64KB" (b : @bench.T) {
  b.bench(fn() { b.keep(@mizchi/zlib.zlib_compress(bench_64kb)) })
}

///|
let bench_compressed_64kb : Bytes = @mizchi/zlib.zlib_compress(bench_64kb)

///|
test "bench zlib decompress 64KB" (b : @bench.T) {
  b.bench(fn() {
    b.keep(try! @mizchi/zlib.zlib_decompress(bench_compressed_64kb))
  })
}

///|
test "bench create_object blob 1KB" (b : @bench.T) {
  b.bench(fn() { b.keep(@git.create_object(@git.ObjectType::Blob, bench_1kb)) })
}

///|
test "bench ObjectId to_hex" (b : @bench.T) {
  let id = @git.ObjectId::zero()
  b.bench(fn() { b.keep(id.to_hex()) })
}

///|
test "bench ObjectId from_hex" (b : @bench.T) {
  let hex = "0000000000000000000000000000000000000000"
  b.bench(fn() { b.keep(try! @git.ObjectId::from_hex(hex)) })
}

///|
test "bench gitfs write 100 files" (b : @bench.T) {
  let content = Bytes::make(100, b'a')
  b.bench(fn() {
    let gitfs = GitFs::empty("/repo/.git")
    for i in 0..<100 {
      gitfs.write_file("file\{i}.txt", content)
    }
    b.keep(gitfs)
  })
}

///|
test "bench gitfs write 1000 files" (b : @bench.T) {
  let content = Bytes::make(100, b'a')
  b.bench(fn() {
    let gitfs = GitFs::empty("/repo/.git")
    for i in 0..<1000 {
      gitfs.write_file("file\{i}.txt", content)
    }
    b.keep(gitfs)
  })
}

///|
fn setup_repo_with_files(
  count : Int,
) -> (@git.TestFs, @git.ObjectId) raise @git.GitError {
  let fs = @git.TestFs::new()
  @lib.init_repo(fs, "/repo")
  let paths : Array[String] = []
  for i in 0..<count {
    fs.write_string("/repo/file\{i}.txt", "content\{i}\n")
    paths.push("file\{i}.txt")
  }
  @lib.add_paths(fs, fs, "/repo", paths)
  let commit = @lib.commit(
    fs, fs, "/repo", "Add files", "Author <a@b.com>", 1700000000L,
  )
  (fs, commit)
}

///|
let bench_repo_100 : (@git.TestFs, @git.ObjectId) = try! setup_repo_with_files(
  100,
)

///|
test "bench gitfs read 100 files (cold)" (b : @bench.T) {
  let (fs, commit) = bench_repo_100
  b.bench(fn() {
    let gitfs = try! GitFs::from_commit(fs, "/repo/.git", commit)
    for i in 0..<100 {
      b.keep(try! gitfs.read_file(fs, "file\{i}.txt"))
    }
  })
}

///|
test "bench gitfs read 100 files (cached)" (b : @bench.T) {
  let (fs, commit) = bench_repo_100
  let gitfs = try! GitFs::from_commit(fs, "/repo/.git", commit)
  for i in 0..<100 {
    let _ = try! gitfs.read_file(fs, "file\{i}.txt")

  }
  b.bench(fn() {
    for i in 0..<100 {
      b.keep(try! gitfs.read_file(fs, "file\{i}.txt"))
    }
  })
}

///|
test "bench gitfs snapshot 100 files" (b : @bench.T) {
  let content = Bytes::make(100, b'a')
  b.bench(fn() {
    let fs = @git.TestFs::new()
    try! @lib.init_repo(fs, "/repo")
    let gitfs = GitFs::empty("/repo/.git")
    for i in 0..<100 {
      gitfs.write_file("file\{i}.txt", content)
    }
    b.keep(try! gitfs.snapshot(fs, fs, "test", "Author <a@b.com>", 1700000000L))
  })
}

///|
test "bench gitfs snapshot 500 files" (b : @bench.T) {
  let content = Bytes::make(100, b'a')
  b.bench(fn() {
    let fs = @git.TestFs::new()
    try! @lib.init_repo(fs, "/repo")
    let gitfs = GitFs::empty("/repo/.git")
    for i in 0..<500 {
      gitfs.write_file("file\{i}.txt", content)
    }
    b.keep(try! gitfs.snapshot(fs, fs, "test", "Author <a@b.com>", 1700000000L))
  })
}

///|
test "bench gitfs from_commit only" (b : @bench.T) {
  let (fs, commit) = bench_repo_100
  b.bench(fn() { b.keep(try! GitFs::from_commit(fs, "/repo/.git", commit)) })
}

///|
test "bench gitfs read_single_file" (b : @bench.T) {
  let (fs, commit) = bench_repo_100
  let gitfs = try! GitFs::from_commit(fs, "/repo/.git", commit)
  b.bench(fn() { b.keep(try! gitfs.read_file(fs, "file50.txt")) })
}

///| E2E benchmarks for status command
///  Profiles each phase: index read, file listing, worktree scan, head diff

///|
/// Run with:
/// - moon bench -p mizchi/bit/cmd/bit --target native -f bench_status_wbtest.mbt

///|
let bench_status_e2e_root : String = "/tmp/bit_bench_status_e2e_v1"

///|
let bench_status_e2e_small : String = bench_status_e2e_root + "/small"

///|
let bench_status_e2e_medium : String = bench_status_e2e_root + "/medium"

///|
let bench_status_e2e_large : String = bench_status_e2e_root + "/large"

///|
fn bench_status_ensure_dir(path : String) -> Unit {
  if not(@fs.path_exists(path)) {
    @fs.create_dir(path) catch {
      _ => ()
    }
  }
}

///|
fn bench_status_cleanup_tree(fs : OsFs, path : String) -> Unit {
  if fs.is_file(path) {
    fs.remove_file(path) catch {
      _ => ()
    }
    return
  }
  if not(fs.is_dir(path)) {
    return
  }
  let entries = fs.readdir(path) catch { _ => [] }
  for entry in entries {
    if entry == "." || entry == ".." {
      continue
    }
    bench_status_cleanup_tree(fs, path + "/" + entry)
  }
  fs.remove_dir(path) catch {
    _ => ()
  }
}

///|
fn bench_status_reset_env() -> Unit {
  @sys.unset_env_var("GIT_DIR")
  @sys.unset_env_var("GIT_WORK_TREE")
  @sys.unset_env_var("GIT_SHIM_CWD")
  @sys.unset_env_var("GIT_SHIM_PWD")
  @sys.unset_env_var("GIT_SHIM_EXPLICIT_GIT_DIR")
  @sys.unset_env_var("GIT_CONFIG_OVERRIDES")
  @sys.unset_env_var("BIT_PROFILE")
}

///|
fn bench_status_init_probe() -> Unit {
  @bitnative.init_native_io()
}

///|
fn bench_status_ensure_repo(
  repo_root : String,
  dir_count : Int,
  files_per_dir : Int,
) -> Unit {
  let marker = repo_root + "/.bench_ready"
  if @fs.path_exists(marker) {
    return
  }
  bench_status_init_probe()
  let fs = OsFs::new()
  bench_status_ensure_dir(bench_status_e2e_root)
  bench_status_cleanup_tree(fs, repo_root)
  bench_status_ensure_dir(repo_root)
  ignore(try? @bitrepo.init_repo(fs, repo_root))
  for d in 0..<dir_count {
    let dir = repo_root + "/dir_\{d}"
    bench_status_ensure_dir(dir)
    for i in 0..<files_per_dir {
      @fs.write_string_to_file(
        dir + "/file_\{i}.txt",
        "bench data d=\{d} i=\{i} padding for realistic file size\n",
      ) catch {
        _ => ()
      }
    }
  }
  @async.run_async_main(async fn() {
    ignore(try? @bitlib.add_paths_async(fs, fs, repo_root, ["."]))
  })
  ignore(
    try? @bitlib.commit(
      fs, fs, repo_root, "bench status seed\n", "Bench <bench@example.com>", 1700000000L,
    ),
  )
  @fs.write_string_to_file(marker, "ok\n") catch {
    _ => ()
  }
}

///|
fn bench_status_dirty(repo_root : String, count : Int) -> Unit {
  for i in 0..<count {
    let dir_idx = i / 25
    let file_idx = i % 25
    let path = repo_root + "/dir_\{dir_idx}/file_\{file_idx}.txt"
    @fs.write_string_to_file(path, "modified \{i}\n") catch {
      _ => ()
    }
  }
}

///|
fn bench_status_run(repo_root : String) -> Int {
  bench_status_init_probe()
  let fs = OsFs::new()
  let mut count = 0
  @async.run_async_main(async fn() {
    let st = @bitlib.status(fs, repo_root)
    count = st.staged_added.length() +
      st.staged_modified.length() +
      st.unstaged_modified.length() +
      st.untracked.length()
  })
  count
}

///|
test "bench status e2e clean 100 files" (b : @bench.T) {
  // 5 dirs x 20 files = 100 files
  bench_status_ensure_repo(bench_status_e2e_small, 5, 20)
  bench_status_reset_env()
  b.bench(fn() { b.keep(bench_status_run(bench_status_e2e_small)) })
}

///|
test "bench status e2e clean 1000 files" (b : @bench.T) {
  // 20 dirs x 50 files = 1000 files
  bench_status_ensure_repo(bench_status_e2e_medium, 20, 50)
  bench_status_reset_env()
  b.bench(fn() { b.keep(bench_status_run(bench_status_e2e_medium)) })
}

///|
test "bench status e2e clean 5000 files" (b : @bench.T) {
  // 50 dirs x 100 files = 5000 files
  bench_status_ensure_repo(bench_status_e2e_large, 50, 100)
  bench_status_reset_env()
  b.bench(fn() { b.keep(bench_status_run(bench_status_e2e_large)) })
}

///|
test "bench status e2e dirty 100/100 files" (b : @bench.T) {
  bench_status_ensure_repo(bench_status_e2e_small, 5, 20)
  bench_status_dirty(bench_status_e2e_small, 100)
  bench_status_reset_env()
  b.bench(fn() { b.keep(bench_status_run(bench_status_e2e_small)) })
}

///|
test "bench status e2e dirty 500/1000 files" (b : @bench.T) {
  bench_status_ensure_repo(bench_status_e2e_medium, 20, 50)
  bench_status_dirty(bench_status_e2e_medium, 500)
  bench_status_reset_env()
  b.bench(fn() { b.keep(bench_status_run(bench_status_e2e_medium)) })
}

///|
test "bench status e2e dirty 2500/5000 files" (b : @bench.T) {
  bench_status_ensure_repo(bench_status_e2e_large, 50, 100)
  bench_status_dirty(bench_status_e2e_large, 2500)
  bench_status_reset_env()
  b.bench(fn() { b.keep(bench_status_run(bench_status_e2e_large)) })
}

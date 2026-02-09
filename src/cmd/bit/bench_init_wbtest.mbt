///| Benchmarks for bit startup/init path

///|
/// Run with:
/// - moon bench -p mizchi/bit/cmd/bit --target native

///|
let bench_config_path : String = "/tmp/bit_bench_gitconfig"

///|
let bench_status_root_base : String = "/tmp/bit_bench_startup_status_v2"

///|
let bench_status_repo_root : String = bench_status_root_base + "/repo"

///|
let bench_startup_repeat : Int = 3

///|
fn ensure_bench_dir(path : String) -> Unit {
  if not(@fs.path_exists(path)) {
    @fs.create_dir(path) catch {
      _ => ()
    }
  }
}

///|
fn ensure_status_bench_repo() -> Unit {
  let marker = bench_status_root_base + "/.bench_ready"
  if @fs.path_exists(marker) {
    @fs.remove_file(bench_status_repo_root + "/.bench_ready") catch {
      _ => ()
    }
    return
  }
  ensure_bench_dir(bench_status_root_base)
  ensure_bench_dir(bench_status_repo_root)
  let fs = OsFs::new()
  ignore(try? @gitlib.init_repo(fs, bench_status_repo_root))
  for d in 0..<40 {
    let dir = bench_status_repo_root + "/dir_\{d}"
    ensure_bench_dir(dir)
    for i in 0..<25 {
      @fs.write_string_to_file(dir + "/file_\{i}.txt", "bench \{d} \{i}\n") catch {
        _ => ()
      }
    }
  }
  for i in 0..<200 {
    @fs.write_string_to_file(
      bench_status_repo_root + "/root_\{i}.txt",
      "bench root \{i}\n",
    ) catch {
      _ => ()
    }
  }
  @async.run_async_main(async fn() {
    ignore(try? @gitlib.add_paths_async(fs, fs, bench_status_repo_root, ["."]))
  })
  ignore(
    try? @gitlib.commit(
      fs, fs, bench_status_repo_root, "bench init\n", "Bench <bench@example.com>",
      1700000000L,
    ),
  )
  @fs.write_string_to_file(marker, "ok\n") catch {
    _ => ()
  }
}

///|
fn ensure_bench_config() -> Unit {
  let content =
    #|[alias]
    #|  st = status
    #|  co = checkout
    #|
  @fs.write_string_to_file(bench_config_path, content) catch {
    _ => ()
  }
  @sys.set_env_var("GIT_CONFIG_GLOBAL", bench_config_path)
}

///|
fn init_path_for_bench(args : Array[String]) -> (String, Array[String]) {
  let opts = parse_global_options(args)
  let cmd = opts.subcmd.unwrap_or("status")
  let fs = OsFs::new()
  let aliases = load_global_aliases(fs)
  apply_alias_overrides(aliases, opts.config_overrides)
  let (alias_cmd, alias_rest) = match resolve_alias(aliases, cmd, opts.rest) {
    Resolved(resolved_cmd, resolved_rest) => (resolved_cmd, resolved_rest)
    Shell(_cmdline) => (cmd, opts.rest)
  }
  let effective_rest = if opts.bare && alias_cmd == "init" {
    prepend_arg("--bare", alias_rest)
  } else {
    alias_rest
  }
  (alias_cmd, effective_rest)
}

///|
test "bench init parse_global_options (status)" (b : @bench.T) {
  let args = ["bit", "status"]
  b.bench(fn() { b.keep(parse_global_options(args)) })
}

///|
test "bench init parse+alias (status)" (b : @bench.T) {
  ensure_bench_config()
  let args = ["bit", "status"]
  b.bench(fn() {
    let (cmd, rest) = init_path_for_bench(args)
    b.keep(cmd)
    b.keep(rest.length())
  })
}

///|
test "bench init parse+alias (-c override)" (b : @bench.T) {
  ensure_bench_config()
  let args = ["bit", "-c", "alias.st=show", "st"]
  b.bench(fn() {
    let (cmd, rest) = init_path_for_bench(args)
    b.keep(cmd)
    b.keep(rest.length())
  })
}

///|
test "bench init first status startup (-C)" (b : @bench.T) {
  ensure_bench_config()
  ensure_status_bench_repo()
  @fs.remove_file(bench_status_repo_root + "/.bench_ready") catch {
    _ => ()
  }
  let args = ["bit", "-C", bench_status_repo_root, "status", "--porcelain"]
  @sys.unset_env_var("GIT_DIR")
  @sys.unset_env_var("GIT_WORK_TREE")
  @sys.unset_env_var("GIT_SHIM_CWD")
  @sys.unset_env_var("GIT_CONFIG_OVERRIDES")
  b.bench(fn() {
    for _ in 0..<bench_startup_repeat {
      @async.run_async_main(async fn() { run_main_for_args(args) })
    }
    b.keep(bench_startup_repeat)
  })
}

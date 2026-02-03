///| Benchmarks for bit startup/init path

///|
/// Run with:
/// - moon bench -p mizchi/bit/cmd/bit --target native

///|
let bench_config_path : String = "/tmp/bit_bench_gitconfig"

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

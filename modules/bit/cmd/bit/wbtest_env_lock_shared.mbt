///|
let cmd_bit_wbtest_env_lock : @async.Semaphore = @async.Semaphore(
  1,
  initial_value=1,
)

///|
fn init {
  ignore(cmd_bit_wbtest_env_lock)
  ignore(wbtest_resolve_real_git)
  ignore(wbtest_resolve_bit_exe)
  ignore(wbtest_resolve_repo_root)
}

///|
/// Resolve the git repo root for wbtests independently of the current working
/// directory. `moon test` sets CWD to the module dir (`modules/bit`), so
/// `@env.current_dir()` cannot locate repo-root-relative assets such as the
/// git shim (`tools/git-shim/bin/git`). Derive the root from the running test
/// executable's `/_build/` path instead, falling back to CWD when that fails.
fn wbtest_resolve_repo_root() -> String {
  let exe = @env.args()[0]
  match exe.find("/_build/") {
    Some(i) => String::unsafe_substring(exe, start=0, end=i)
    None => @env.current_dir().unwrap_or(".")
  }
}

///|
/// Resolve real git path for wbtests. Uses third_party/git/git if available,
/// otherwise falls back to system git.
fn wbtest_resolve_real_git(repo_root : String) -> String {
  let third_party = repo_root + "/third_party/git/git"
  let fs : &@bitcore.RepoFileSystem = OsFs::new()
  if fs.is_file(third_party) {
    third_party
  } else {
    "git"
  }
}

///|
/// Resolve the freshly built `bit.exe` for wbtests. The native binary lives
/// under a debug or release build directory depending on how it was compiled.
/// Prefer the variant matching the running test binary so a stale build of the
/// other variant cannot affect a whitebox test.
fn wbtest_resolve_bit_exe(repo_root : String) -> String {
  let fs : &@bitcore.RepoFileSystem = OsFs::new()
  let debug_rel = "/_build/native/debug/build/mizchi/bit/bit.exe"
  let release_rel = "/_build/native/release/build/mizchi/bit/bit.exe"
  // Candidate repo roots, most reliable first: a root derived from the running
  // test executable path (independent of CWD, which `moon test` may set to the
  // module dir), then the caller-supplied repo_root.
  let roots : Array[String] = []
  let exe = @env.args()[0]
  let running_release = exe.contains("/_build/native/release/")
  match exe.find("/_build/") {
    Some(i) => roots.push(String::unsafe_substring(exe, start=0, end=i))
    None => ()
  }
  roots.push(repo_root)
  for root in roots {
    let debug_path = root + debug_rel
    let release_path = root + release_rel
    if running_release {
      if fs.is_file(release_path) {
        return release_path
      }
      if fs.is_file(debug_path) {
        return debug_path
      }
    } else {
      if fs.is_file(debug_path) {
        return debug_path
      }
      if fs.is_file(release_path) {
        return release_path
      }
    }
  }
  // Not found anywhere: return the matching primary candidate so the caller's
  // existence check fails with a clear, actionable path.
  roots[0] + (if running_release { release_rel } else { debug_rel })
}

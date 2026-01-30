///| Git-shim main entry point and command dispatcher

///|
async fn main_async() -> Unit {
  let args = @sys.get_cli_args()
  if args.length() < 2 {
    eprint_line("git-shim: missing subcommand")
    @sys.exit(2)
  }
  // Handle --version early
  match args {
    [_, "--version" | "version", ..] => {
      print_line("git version 2.47.0 (git-shim)")
      return ()
    }
    _ => ()
  }
  let full_args = collect_args(args, 1)
  let (subcmd, rest, cwd, unsupported_global) = parse_global_options(args)
  guard subcmd is Some(cmd) else {
    eprint_line("git-shim: missing subcommand")
    @sys.exit(2)
  }
  if unsupported_global {
    run_system_git(full_args)
  }
  // Set working directory if -C was used
  match cwd {
    Some(dir) => {
      @sys.set_env_var("GIT_SHIM_CWD", dir)
      if @sys.get_env_var("GIT_DIR") is None {
        @sys.set_env_var("GIT_DIR", dir + "/.git")
      }
      if @sys.get_env_var("GIT_WORK_TREE") is None {
        @sys.set_env_var("GIT_WORK_TREE", dir)
      }
    }
    None => ()
  }
  dispatch_command(cmd, rest, full_args)
}

///|
fn parse_global_options(
  args : Array[String],
) -> (String?, Array[String], String?, Bool) {
  let mut i = 1
  let mut in_opts = true
  let mut cwd : String? = None
  let mut unsupported_global = false
  let mut subcmd : String? = None
  let mut rest : Array[String] = []
  while i < args.length() {
    let arg = args[i]
    if in_opts && arg == "--" {
      in_opts = false
      i += 1
      continue
    }
    if in_opts && arg == "-C" && i + 1 < args.length() {
      let raw = args[i + 1]
      cwd = Some(
        if raw.has_prefix("/") {
          raw
        } else {
          @sys.get_env_var("GIT_SHIM_PWD").map(fn(base) { base + "/" + raw }).unwrap_or(
            raw,
          )
        },
      )
      i += 2
      continue
    }
    if in_opts && arg == "-c" && i + 1 < args.length() {
      unsupported_global = true
      i += 2
      continue
    }
    if in_opts && is_unsupported_global_flag(arg) {
      unsupported_global = true
      if not(arg.contains("=")) && i + 1 < args.length() {
        i += 2
      } else {
        i += 1
      }
      continue
    }
    if in_opts && arg.has_prefix("-") {
      i += 1
      continue
    }
    subcmd = Some(arg)
    rest = collect_args(args, i + 1)
    break
  }
  (subcmd, rest, cwd, unsupported_global)
}

///|
fn is_unsupported_global_flag(arg : String) -> Bool {
  arg == "--git-dir" ||
  arg == "--work-tree" ||
  arg == "--namespace" ||
  arg == "--super-prefix" ||
  arg == "--git-path" ||
  arg.has_prefix("--git-dir=") ||
  arg.has_prefix("--work-tree=") ||
  arg.has_prefix("--namespace=") ||
  arg.has_prefix("--super-prefix=") ||
  arg.has_prefix("--git-path=")
}

///|
async fn dispatch_command(
  cmd : String,
  rest : Array[String],
  full_args : Array[String],
) -> Unit {
  match cmd {
    // Pack operations
    "receive-pack" | "git-receive-pack" =>
      handle_receive_pack(rest) catch {
        err => exit_with_error("receive-pack", err)
      }
    "upload-pack" | "git-upload-pack" =>
      handle_upload_pack(rest) catch {
        err => exit_with_error("upload-pack", err)
      }
    "pack-objects" =>
      handle_pack_objects(rest) catch {
        err => exit_with_error("pack-objects", err)
      }
    "index-pack" =>
      handle_index_pack(rest) catch { err => exit_with_error("index-pack", err) }
    // Remote operations
    "clone" =>
      handle_clone(rest) catch { err => exit_with_error("clone", err) }
    "fetch" =>
      handle_fetch(rest) catch { err => exit_with_error("fetch", err) }
    "pull" => handle_pull(rest) catch { err => exit_with_error("pull", err) }
    // Core operations
    "init" => handle_init(rest) catch { err => exit_with_error("init", err) }
    "status" =>
      handle_status(rest) catch { err => exit_with_error("status", err) }
    "add" => handle_add(rest) catch { err => exit_with_error("add", err) }
    "commit" =>
      handle_commit(rest) catch { err => exit_with_error("commit", err) }
    "log" => handle_log(rest) catch { err => exit_with_error("log", err) }
    "show" => handle_show(rest) catch { err => exit_with_error("show", err) }
    // Branch operations
    "branch" =>
      handle_branch(rest) catch { _ => run_system_git(prepend_arg("branch", rest))
      }
    "checkout" => {
      // For -b/-B options, don't fallback to system git
      let has_create_branch = rest.iter().any(fn(arg) {
        arg == "-b" || arg == "-B"
      })
      if has_create_branch {
        handle_checkout(rest) catch { err => exit_with_error("checkout", err) }
      } else {
        handle_checkout(rest) catch {
          _ => run_system_git(prepend_arg("checkout", rest))
        }
      }
    }
    "switch" =>
      handle_switch(rest) catch { _ => run_system_git(prepend_arg("switch", rest))
      }
    "reset" =>
      handle_reset(rest) catch { err => exit_with_error("reset", err) }
    // Misc operations
    "diff" => handle_diff(rest) catch { err => exit_with_error("diff", err) }
    "merge" =>
      handle_merge(rest) catch { _ => run_system_git(prepend_arg("merge", rest))
      }
    "tag" => handle_tag(rest) catch { err => exit_with_error("tag", err) }
    "rm" => handle_rm(rest) catch { err => exit_with_error("rm", err) }
    "mv" => handle_mv(rest) catch { err => exit_with_error("mv", err) }
    "config" =>
      handle_config(rest) catch { _ => run_system_git(prepend_arg("config", rest))
      }
    "sparse-checkout" =>
      handle_sparse_checkout(rest) catch {
        err => exit_with_error("sparse-checkout", err)
      }
    "rev-parse" =>
      handle_rev_parse(rest) catch {
        _ => run_system_git(prepend_arg("rev-parse", rest))
      }
    "version" | "--version" => print_line("git version 2.47.0 (git-shim)")
    // Fallback to system git
    _ => run_system_git(prepend_arg(cmd, rest))
  }
  ignore(full_args)
}

///|
async fn exit_with_error(cmd : String, err : Error) -> Unit {
  eprint_line("\{cmd} failed: \{err}")
  @sys.exit(1)
}

///|
fn main {
  @async.run_async_main(main_async)
}

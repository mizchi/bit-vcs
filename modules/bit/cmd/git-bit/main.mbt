///| git-bit main entry point

///|
let git_bit_version_tag : String = "0.2.0"

///|
fn git_bit_help_text() -> String {
  let text =
    #|usage: git-bit [-v | --version] [-h | --help] [-C <path>]
    #|               <command> [<args>]
    #|
    #|git-bit provides Git-hosted collaboration commands without depending on bit CLI.
    #|
    #|commands
    #|   pr           Manage pull requests
    #|   issue        Manage issues
    #|   work-item    Manage combined issue / pull-request views
    #|   search       Search pull requests and issues
    #|   init         Initialize collaboration metadata
    #|   debug        Debug and inspect collaboration internals
  text
}

///|
async fn show_git_bit_help() -> Unit {
  print_line(git_bit_help_text())
}

///|
fn git_bit_apply_cwd(raw_dir : String) -> Unit {
  let resolved = if raw_dir.has_prefix("/") {
    raw_dir
  } else {
    let base = @sys.get_env_var("PWD").unwrap_or(".")
    normalize_path(base + "/" + raw_dir)
  }
  @sys.set_env_var("GIT_SHIM_CWD", resolved)
  @sys.set_env_var("GIT_SHIM_PWD", resolved)
}

///|
async fn run_git_bit_for_args(args : Array[String]) -> Unit {
  if args.length() < 2 {
    show_git_bit_help()
    return ()
  }
  let mut i = 1
  while i < args.length() {
    match args[i] {
      "-v" | "--version" | "version" => {
        print_line("git-bit version \{git_bit_version_tag}")
        return ()
      }
      "-h" | "--help" => {
        show_git_bit_help()
        return ()
      }
      "-C" if i + 1 < args.length() => {
        git_bit_apply_cwd(args[i + 1])
        i += 2
      }
      _ if args[i].has_prefix("-") => {
        eprint_line("git-bit: unsupported global option '\{args[i]}'")
        @sys.exit(2)
      }
      _ => break
    }
  }
  if i >= args.length() {
    eprint_line("git-bit: missing subcommand")
    @sys.exit(2)
  }
  let cmd = args[i]
  let rest = collect_args(args, i + 1)
  match cmd {
    "pr" => handle_hub_pr(rest)
    "issue" => handle_hub_issue(rest)
    "work-item" => handle_hub_work_item(rest)
    "search" => handle_hub_search(rest)
    "init" => handle_hub_init(rest)
    "debug" =>
      if rest.length() > 0 && rest[0] == "dump" {
        handle_hub_dump(collect_args(rest, 1))
      } else {
        eprint_line("git-bit debug: supported subcommands: dump")
        @sys.exit(1)
      }
    "help" => show_git_bit_help()
    _ => {
      eprint_line("git-bit: unknown subcommand '\{cmd}'")
      show_git_bit_help()
      @sys.exit(1)
    }
  }
}

///|
async fn main_async() -> Unit {
  let args = @env.args()
  run_git_bit_for_args(args)
}

///|
fn main {
  @async.run_async_main(main_async)
}

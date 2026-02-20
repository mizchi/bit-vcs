///|
async fn print_x_doc_usage() -> Unit {
  let usage =
    #|Usage: bit x/doc <subcommand> [<args>]
    #|
    #|Experimental wiki-like docs and memo storage for this repository.
    #|
    #|Subcommands:
    #|  list [prefix]           List document pages
    #|  show <page>             Show page body
    #|  put <page> <text...>    Replace page body
    #|  append <page> <text...> Append memo line with timestamp
    #|  rm <page>               Remove page
    #|
    #|Examples:
    #|  bit x/doc list
    #|  bit x/doc show home
    #|  bit x/doc put home "Project wiki home"
    #|  bit x/doc append home "sync done"
    #|  bit x/doc rm home
  print_line(usage)
}

///|
fn doc_message_from_args(args : Array[String], start : Int) -> String? {
  let message = collect_args(args, start).join(" ")
  if message.length() == 0 {
    None
  } else {
    Some(message)
  }
}

///|
async fn report_doc_error(err : @xdoc.DocError, empty_message : String) -> Unit {
  match err {
    @xdoc.DocError::InvalidPageName(name) =>
      eprint_line("fatal: invalid page name '\{name}'")
    @xdoc.DocError::PageNotFound(name) =>
      eprint_line("fatal: document '\{name}' does not exist")
    @xdoc.DocError::EmptyBody => eprint_line("fatal: \{empty_message}")
  }
}

///|
async fn handle_x_doc_list(
  rfs : &@bitcore.RepoFileSystem,
  root : String,
  args : Array[String],
) -> Unit {
  if args.length() > 1 {
    eprint_line("fatal: too many arguments for x/doc list")
    print_x_doc_usage()
    @sys.exit(1)
  }
  let prefix = if args.length() == 1 { Some(args[0]) } else { None }
  for page in @xdoc.list_pages(rfs, root, prefix) {
    print_line(page)
  }
}

///|
async fn handle_x_doc_show(
  rfs : &@bitcore.RepoFileSystem,
  root : String,
  args : Array[String],
) -> Unit raise Error {
  if args.length() != 1 {
    eprint_line("fatal: x/doc show requires <page>")
    print_x_doc_usage()
    @sys.exit(1)
  }
  match @xdoc.read_page(rfs, root, args[0]) {
    Ok(content) => {
      print_str(content)
      if content.length() == 0 || not(content.has_suffix("\n")) {
        print_line("")
      }
    }
    Err(err) => {
      report_doc_error(err, "empty document body is not allowed")
      @sys.exit(1)
    }
  }
}

///|
async fn handle_x_doc_put(
  wfs : &@bitcore.FileSystem,
  root : String,
  args : Array[String],
) -> Unit raise Error {
  if args.length() < 2 {
    eprint_line("fatal: x/doc put requires <page> <text...>")
    print_x_doc_usage()
    @sys.exit(1)
  }
  let page_name = args[0]
  let message = match doc_message_from_args(args, 1) {
    Some(msg) => msg
    None => {
      eprint_line("fatal: empty document body is not allowed")
      @sys.exit(1)
      return
    }
  }
  match @xdoc.put_page(wfs, root, page_name, message) {
    Ok(page) => print_line("updated \{page}")
    Err(err) => {
      report_doc_error(err, "empty document body is not allowed")
      @sys.exit(1)
    }
  }
}

///|
async fn handle_x_doc_append(
  wfs : &@bitcore.FileSystem,
  rfs : &@bitcore.RepoFileSystem,
  root : String,
  args : Array[String],
) -> Unit raise Error {
  if args.length() < 2 {
    eprint_line("fatal: x/doc append requires <page> <text...>")
    print_x_doc_usage()
    @sys.exit(1)
  }
  let page_name = args[0]
  let message = match doc_message_from_args(args, 1) {
    Some(msg) => msg
    None => {
      eprint_line("fatal: empty memo is not allowed")
      @sys.exit(1)
      return
    }
  }
  match
    @xdoc.append_page(
      wfs,
      rfs,
      root,
      page_name,
      message,
      get_current_timestamp(),
    ) {
    Ok(page) => print_line("appended \{page}")
    Err(err) => {
      report_doc_error(err, "empty memo is not allowed")
      @sys.exit(1)
    }
  }
}

///|
async fn handle_x_doc_remove(
  wfs : &@bitcore.FileSystem,
  rfs : &@bitcore.RepoFileSystem,
  root : String,
  args : Array[String],
) -> Unit raise Error {
  if args.length() != 1 {
    eprint_line("fatal: x/doc rm requires <page>")
    print_x_doc_usage()
    @sys.exit(1)
  }
  match @xdoc.remove_page(wfs, rfs, root, args[0]) {
    Ok(page) => print_line("removed \{page}")
    Err(err) => {
      report_doc_error(err, "empty document body is not allowed")
      @sys.exit(1)
    }
  }
}

///|
async fn handle_x_doc(args : Array[String]) -> Unit raise Error {
  let root = get_work_root()
  let fs = OsFs::new()
  let wfs : &@bitcore.FileSystem = fs
  let rfs : &@bitcore.RepoFileSystem = fs
  let git_dir = resolve_git_dir(rfs, root)
  if not(rfs.is_dir(git_dir)) {
    eprint_line("fatal: not a git repository")
    @sys.exit(1)
  }
  if args.length() == 0 {
    print_x_doc_usage()
    return
  }
  let subcmd = args[0]
  let rest = collect_args(args, 1)
  match subcmd {
    "list" | "ls" => handle_x_doc_list(rfs, root, rest)
    "show" | "cat" => handle_x_doc_show(rfs, root, rest)
    "put" | "set" => handle_x_doc_put(wfs, root, rest)
    "append" | "add" => handle_x_doc_append(wfs, rfs, root, rest)
    "rm" | "remove" => handle_x_doc_remove(wfs, rfs, root, rest)
    "-h" | "--help" | "help" => print_x_doc_usage()
    _ => {
      eprint_line("fatal: unknown subcommand '\{subcmd}'")
      print_x_doc_usage()
      @sys.exit(1)
    }
  }
}

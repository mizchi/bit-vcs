///|
pub async fn run_storage_command(
  fs : &@bitcore.FileSystem,
  rfs : &@bitcore.RepoFileSystem,
  root : String,
  command : @runtime.StorageCommand,
) -> Unit raise Error {
  @runtime.run_storage_command(fs, rfs, root, command)
}

///|
fn storage_runtime_fail_unsupported_option(
  cmd : String,
  arg : String,
) -> Unit raise Error {
  raise @bitcore.GitError::InvalidObject(
    cmd + ": option is not supported in storage runtime: " + arg,
  )
}

///|
fn storage_runtime_fail_unsupported_mode(
  cmd : String,
  detail : String,
) -> Unit raise Error {
  raise @bitcore.GitError::InvalidObject(
    cmd + ": mode is not supported in storage runtime: " + detail,
  )
}

///|
fn storage_runtime_is_short_count_flag(arg : String) -> Bool {
  if not(arg.has_prefix("-")) || arg.length() <= 1 {
    return false
  }
  let raw = String::unsafe_substring(arg, start=1, end=arg.length())
  for c in raw {
    if c < '0' || c > '9' {
      return false
    }
  }
  true
}

///|
fn storage_runtime_parse_object_type(
  s : String,
) -> @bitcore.ObjectType raise Error {
  match s {
    "blob" => @bitcore.ObjectType::Blob
    "tree" => @bitcore.ObjectType::Tree
    "commit" => @bitcore.ObjectType::Commit
    "tag" => @bitcore.ObjectType::Tag
    _ =>
      raise @bitcore.GitError::InvalidObject(
        "invalid object type \"" + s + "\"",
      )
  }
}

///|
fn storage_runtime_parse_init_args(
  args : Array[String],
) -> @runtime.StorageInitArgs raise Error {
  let mut quiet = false
  let mut default_branch = "main"
  let mut ref_format = "files"
  let mut object_format = "sha1"
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    match arg {
      "-q" | "--quiet" => quiet = true
      "-b" if i + 1 < args.length() => {
        default_branch = args[i + 1]
        i += 2
        continue
      }
      "--initial-branch" if i + 1 < args.length() => {
        default_branch = args[i + 1]
        i += 2
        continue
      }
      "--ref-format" if i + 1 < args.length() => {
        let value = args[i + 1].to_lower()
        if value != "files" {
          storage_runtime_fail_unsupported_mode("init", "--ref-format=" + value)
        }
        ref_format = value
        i += 2
        continue
      }
      "--object-format" if i + 1 < args.length() => {
        let value = args[i + 1].to_lower()
        if value != "sha1" {
          storage_runtime_fail_unsupported_mode(
            "init",
            "--object-format=" + value,
          )
        }
        object_format = value
        i += 2
        continue
      }
      _ if arg.has_prefix("--initial-branch=") =>
        default_branch = (try! arg[17:]).to_string()
      _ if arg.has_prefix("--ref-format=") => {
        let value = (try! arg[13:]).to_string().to_lower()
        if value != "files" {
          storage_runtime_fail_unsupported_mode("init", "--ref-format=" + value)
        }
        ref_format = value
      }
      _ if arg.has_prefix("--object-format=") => {
        let value = (try! arg[16:]).to_string().to_lower()
        if value != "sha1" {
          storage_runtime_fail_unsupported_mode(
            "init",
            "--object-format=" + value,
          )
        }
        object_format = value
      }
      _ if arg.has_prefix("-") =>
        storage_runtime_fail_unsupported_option("init", arg)
      _ => storage_runtime_fail_unsupported_mode("init", "directory argument")
    }
    i += 1
  }
  { quiet, default_branch, ref_format, object_format }
}

///|
fn storage_runtime_parse_add_args(
  args : Array[String],
) -> @runtime.StorageAddArgs raise Error {
  let mut add_all = false
  let mut end_of_options = false
  let paths : Array[String] = []
  for arg in args {
    if not(end_of_options) && arg == "--" {
      end_of_options = true
      continue
    }
    match arg {
      "-A" | "--all" if not(end_of_options) => add_all = true
      _ if end_of_options || not(arg.has_prefix("-")) => paths.push(arg)
      _ if arg.has_prefix("-") =>
        storage_runtime_fail_unsupported_option("add", arg)
      _ => ()
    }
  }
  if not(add_all) && paths.length() == 0 {
    raise @bitcore.GitError::InvalidObject("add requires pathspec")
  }
  { add_all, paths }
}

///|
fn storage_runtime_parse_commit_args(
  args : Array[String],
) -> @runtime.StorageCommitArgs raise Error {
  let mut message : String? = None
  let mut all_modified = false
  let mut allow_empty = false
  let mut quiet = false
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    match arg {
      "-m" if i + 1 < args.length() => {
        message = Some(args[i + 1])
        i += 2
        continue
      }
      "--message" if i + 1 < args.length() => {
        message = Some(args[i + 1])
        i += 2
        continue
      }
      "-am" | "-ma" if i + 1 < args.length() => {
        all_modified = true
        message = Some(args[i + 1])
        i += 2
        continue
      }
      _ if arg.has_prefix("-m") && arg.length() > 2 => {
        message = Some((try! arg[2:]).to_string())
        i += 1
        continue
      }
      _ if arg.has_prefix("-am") || arg.has_prefix("-ma") => {
        all_modified = true
        message = Some((try! arg[3:]).to_string())
        i += 1
        continue
      }
      _ if arg.has_prefix("--message=") => {
        message = Some((try! arg[10:]).to_string())
        i += 1
        continue
      }
      "-a" | "--all" => all_modified = true
      "--allow-empty" => allow_empty = true
      "-q" | "--quiet" => quiet = true
      "--no-verify" => ()
      _ if arg.has_prefix("-") =>
        storage_runtime_fail_unsupported_option("commit", arg)
      _ =>
        storage_runtime_fail_unsupported_mode("commit", "positional arguments")
    }
    i += 1
  }
  guard message is Some(msg) else {
    raise @bitcore.GitError::InvalidObject(
      "storage runtime commit requires -m/--message",
    )
  }
  { message: msg, all_modified, allow_empty, quiet }
}

///|
fn storage_runtime_parse_status_args(
  args : Array[String],
) -> @runtime.StorageStatusArgs raise Error {
  let mut porcelain = false
  let mut short = false
  let mut show_branch = false
  for arg in args {
    match arg {
      "--porcelain" | "--porcelain=v1" => porcelain = true
      "-s" | "--short" => short = true
      "-b" | "--branch" => show_branch = true
      "-sb" => {
        short = true
        show_branch = true
      }
      _ if arg.has_prefix("-") =>
        storage_runtime_fail_unsupported_option("status", arg)
      _ => storage_runtime_fail_unsupported_mode("status", "pathspec")
    }
  }
  { porcelain, short, show_branch }
}

///|
fn storage_runtime_parse_log_args(
  args : Array[String],
) -> @runtime.StorageLogArgs raise Error {
  let mut oneline = false
  let mut max_count = 10
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    match arg {
      "--oneline" => oneline = true
      "-n" if i + 1 < args.length() => {
        max_count = @strconv.parse_int(args[i + 1])
        i += 2
        continue
      }
      "--max-count" if i + 1 < args.length() => {
        max_count = @strconv.parse_int(args[i + 1])
        i += 2
        continue
      }
      _ if arg.has_prefix("-n") && arg.length() > 2 =>
        max_count = @strconv.parse_int((try! arg[2:]).to_string())
      _ if storage_runtime_is_short_count_flag(arg) => {
        let num_str = String::unsafe_substring(arg, start=1, end=arg.length())
        max_count = @strconv.parse_int(num_str)
      }
      _ if arg.has_prefix("--max-count=") =>
        max_count = @strconv.parse_int((try! arg[12:]).to_string())
      _ if arg.has_prefix("-") =>
        storage_runtime_fail_unsupported_option("log", arg)
      _ => storage_runtime_fail_unsupported_mode("log", "revision arguments")
    }
    i += 1
  }
  { oneline, max_count }
}

///|
fn storage_runtime_parse_hash_object_args(
  args : Array[String],
) -> @runtime.StorageHashObjectArgs raise Error {
  let mut write_object = false
  let mut stdin_mode = false
  let mut obj_type = "blob"
  let paths : Array[String] = []
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    match arg {
      "-w" => write_object = true
      "--stdin" => stdin_mode = true
      "--literally" => ()
      "-t" if i + 1 < args.length() => {
        obj_type = args[i + 1]
        i += 2
        continue
      }
      _ if arg.has_prefix("-t") && arg.length() > 2 =>
        obj_type = String::unsafe_substring(arg, start=2, end=arg.length())
      _ if not(arg.has_prefix("-")) => paths.push(arg)
      _ => storage_runtime_fail_unsupported_option("hash-object", arg)
    }
    i += 1
  }
  {
    write_object,
    stdin_mode,
    obj_type: storage_runtime_parse_object_type(obj_type),
    paths,
  }
}

///|
fn storage_runtime_parse_write_tree_args(
  args : Array[String],
) -> @runtime.StorageWriteTreeArgs raise Error {
  let mut prefix : String? = None
  let mut missing_ok = false
  for arg in args {
    if arg.has_prefix("--prefix=") {
      prefix = Some((try! arg[9:]).to_string())
      continue
    }
    if arg == "--missing-ok" {
      missing_ok = true
      continue
    }
    if arg.has_prefix("-") {
      storage_runtime_fail_unsupported_option("write-tree", arg)
    }
    storage_runtime_fail_unsupported_mode("write-tree", "path arguments")
  }
  { prefix, missing_ok }
}

///|
fn storage_runtime_parse_update_ref_args(
  args : Array[String],
) -> @runtime.StorageUpdateRefArgs raise Error {
  let mut delete_mode = false
  let positional : Array[String] = []
  for arg in args {
    match arg {
      "-d" | "--delete" => delete_mode = true
      _ if not(arg.has_prefix("-")) => positional.push(arg)
      _ => storage_runtime_fail_unsupported_option("update-ref", arg)
    }
  }
  if delete_mode {
    guard positional.length() >= 1 else {
      raise @bitcore.GitError::InvalidObject(
        "usage: update-ref -d <refname> [<oldvalue>]",
      )
    }
    let old_value : String? = if positional.length() >= 2 {
      Some(positional[1])
    } else {
      None
    }
    return {
      delete_mode: true,
      refname: positional[0],
      new_value: None,
      old_value,
    }
  }
  guard positional.length() >= 2 else {
    raise @bitcore.GitError::InvalidObject(
      "usage: update-ref <refname> <newvalue> [<oldvalue>]",
    )
  }
  let old_value : String? = if positional.length() >= 3 {
    Some(positional[2])
  } else {
    None
  }
  {
    delete_mode: false,
    refname: positional[0],
    new_value: Some(positional[1]),
    old_value,
  }
}

///|
fn storage_runtime_parse_command(
  cmd : String,
  args : Array[String],
) -> @runtime.StorageCommand raise Error {
  match cmd {
    "init" =>
      @runtime.StorageCommand::Init(storage_runtime_parse_init_args(args))
    "add" => @runtime.StorageCommand::Add(storage_runtime_parse_add_args(args))
    "commit" =>
      @runtime.StorageCommand::Commit(storage_runtime_parse_commit_args(args))
    "status" =>
      @runtime.StorageCommand::Status(storage_runtime_parse_status_args(args))
    "log" => @runtime.StorageCommand::Log(storage_runtime_parse_log_args(args))
    "hash-object" =>
      @runtime.StorageCommand::HashObject(
        storage_runtime_parse_hash_object_args(args),
      )
    "write-tree" =>
      @runtime.StorageCommand::WriteTree(
        storage_runtime_parse_write_tree_args(args),
      )
    "update-ref" =>
      @runtime.StorageCommand::UpdateRef(
        storage_runtime_parse_update_ref_args(args),
      )
    _ =>
      raise @bitcore.GitError::InvalidObject(
        "unsupported storage command: " + cmd,
      )
  }
}

///|
pub async fn run_storage_command_by_name(
  fs : &@bitcore.FileSystem,
  rfs : &@bitcore.RepoFileSystem,
  root : String,
  cmd : String,
  args : Array[String],
) -> Unit raise Error {
  let command = storage_runtime_parse_command(cmd, args)
  @runtime.run_storage_command(fs, rfs, root, command)
}

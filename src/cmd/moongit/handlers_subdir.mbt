///|
/// Subdir command handlers - subdirectory as independent repository

///|
async fn handle_subdir(args : Array[String]) -> Unit raise Error {
  if args.length() == 0 {
    print_subdir_usage()
    return
  }
  let subcommand = args[0]
  let rest = array_view_to_array(args[1:])
  match subcommand {
    "init" => handle_subdir_init(rest) catch { e => raise e }
    "deinit" => handle_subdir_deinit(rest) catch { e => raise e }
    "shell" => handle_subdir_shell(rest) catch { e => raise e }
    "show" => handle_subdir_show(rest) catch { e => raise e }
    "log" => handle_subdir_log(rest) catch { e => raise e }
    "diff" => handle_subdir_diff(rest) catch { e => raise e }
    "extract" => handle_subdir_extract(rest) catch { e => raise e }
    _ => {
      print_line("Unknown subdir subcommand: " + subcommand)
      print_subdir_usage()
    }
  }
}

///|
/// ArrayView を Array に変換
fn array_view_to_array(view : ArrayView[String]) -> Array[String] {
  let arr : Array[String] = []
  for item in view {
    arr.push(item)
  }
  arr
}

///|
async fn print_subdir_usage() -> Unit raise Error {
  print_line("Usage: moongit subdir <command> [options]")
  print_line("")
  print_line("Commands:")
  print_line("  init <path>      Initialize subdirectory for transparent git operations")
  print_line("  deinit <path>    Remove subdirectory initialization")
  print_line("  shell <path>     Start a shell with git scoped to subdirectory")
  print_line("  show <path>      Show subdirectory info")
  print_line("  log <path>       Show commits that affected the subdirectory")
  print_line("  diff <path>      Show working changes in subdirectory")
  print_line("  extract <path> <target>  Extract subdirectory to target directory")
}

///|
async fn handle_subdir_show(args : Array[String]) -> Unit raise Error {
  if args.length() < 1 {
    print_line("Usage: moongit subdir show <path>")
    return
  }
  let subdir_path = args[0]
  let root = get_work_root()
  let git_dir = root + "/.git"
  let fs = OsFs::new()
  // SubdirRepo を作成
  let subdir = @gitsubdir.SubdirRepo::from_head(fs, git_dir, subdir_path) catch {
    err => raise @git.GitError::IoError("Failed to open subdirectory: " + err.to_string())
  }
  print_line("Subdirectory: " + subdir.path())
  match subdir.base_commit() {
    Some(id) => print_line("Base commit: " + id.to_hex())
    None => print_line("Base commit: (none)")
  }
  match subdir.tree_id() {
    Some(id) => print_line("Tree ID: " + id.to_hex())
    None => print_line("Tree ID: (none)")
  }
  print_line("Dirty: " + subdir.is_dirty().to_string())
}

///|
async fn handle_subdir_log(args : Array[String]) -> Unit raise Error {
  if args.length() < 1 {
    print_line("Usage: moongit subdir log <path> [--max-count=N]")
    return
  }
  let subdir_path = args[0]
  let mut max_count = 20
  // オプション解析
  let mut i = 1
  while i < args.length() {
    let arg = args[i]
    if arg.has_prefix("--max-count=") {
      max_count = parse_int_simple(subdir_skip_prefix(arg, 12))
    } else if arg == "-n" && i + 1 < args.length() {
      i += 1
      max_count = parse_int_simple(args[i])
    }
    i += 1
  }
  let root = get_work_root()
  let git_dir = root + "/.git"
  let fs = OsFs::new()
  // SubdirRepo を作成
  let subdir = @gitsubdir.SubdirRepo::from_head(fs, git_dir, subdir_path) catch {
    err => raise @git.GitError::IoError("Failed to open subdirectory: " + err.to_string())
  }
  // 履歴を取得
  let history = subdir.log(fs, max_count~) catch {
    err => raise @git.GitError::IoError("Failed to get log: " + err.to_string())
  }
  if history.length() == 0 {
    print_line("No commits found that affected " + subdir_path)
    return
  }
  print_line("Commits affecting " + subdir_path + ":")
  print_line("")
  for commit in history {
    let _short_id = subdir_short_hex(commit.id.to_hex())
    print_line("commit " + commit.id.to_hex())
    if commit.author != "" {
      print_line("Author: " + commit.author)
    }
    if commit.timestamp > 0L {
      print_line("Date:   " + format_timestamp_simple(commit.timestamp))
    }
    print_line("")
    if commit.message != "" {
      print_line("    " + commit.message)
    }
    print_line("")
  }
}

///|
async fn handle_subdir_diff(args : Array[String]) -> Unit raise Error {
  if args.length() < 1 {
    print_line("Usage: moongit subdir diff <path>")
    return
  }
  let subdir_path = args[0]
  let root = get_work_root()
  let git_dir = root + "/.git"
  let fs = OsFs::new()
  // SubdirRepo を作成
  let subdir = @gitsubdir.SubdirRepo::from_head(fs, git_dir, subdir_path) catch {
    err => raise @git.GitError::IoError("Failed to open subdirectory: " + err.to_string())
  }
  let diff = subdir.diff()
  if diff.length() == 0 {
    print_line("No changes in " + subdir_path)
    return
  }
  print_line("Changes in " + subdir_path + ":")
  for entry in diff {
    print_line(entry.to_string())
  }
}

///|
async fn handle_subdir_extract(args : Array[String]) -> Unit raise Error {
  if args.length() < 2 {
    print_line("Usage: moongit subdir extract <path> <target>")
    return
  }
  let subdir_path = args[0]
  let target_dir = args[1]
  let root = get_work_root()
  let git_dir = root + "/.git"
  let fs = OsFs::new()
  // SubdirRepo を作成
  let subdir = @gitsubdir.SubdirRepo::from_head(fs, git_dir, subdir_path) catch {
    err => raise @git.GitError::IoError("Failed to open subdirectory: " + err.to_string())
  }
  // ターゲットディレクトリを作成
  fs.mkdir_p(target_dir) catch { _ => () }
  // ファイルを展開
  let gitfs = subdir.fs()
  let files = gitfs.readdir(fs, "/") catch {
    _ => raise @git.GitError::IoError("Failed to read subdirectory")
  }
  let mut count = 0
  for file in files {
    extract_file_recursive(fs, gitfs, "/", file, target_dir) catch { e => raise e }
    count += 1
  }
  print_line("Extracted " + count.to_string() + " items to " + target_dir)
}

///|
async fn extract_file_recursive(
  fs : OsFs,
  gitfs : @gitfs.GitFs,
  base_path : String,
  name : String,
  target_dir : String
) -> Unit raise Error {
  let path = if base_path == "/" { "/" + name } else { base_path + "/" + name }
  if gitfs.is_dir(fs, path) {
    // ディレクトリの場合は再帰
    let subdir_target = target_dir + "/" + name
    fs.mkdir_p(subdir_target) catch { _ => () }
    let children = gitfs.readdir(fs, path) catch { _ => return () }
    for child in children {
      extract_file_recursive(fs, gitfs, path, child, subdir_target) catch {
        e => raise e
      }
    }
  } else if gitfs.is_file(fs, path) {
    // ファイルの場合は内容を書き出し
    let content = gitfs.read_file(fs, path) catch { _ => return () }
    let target_path = target_dir + "/" + name
    fs.write_file(target_path, content) catch { _ => () }
  }
}

///|
/// 文字列の先頭 n 文字をスキップ
fn subdir_skip_prefix(s : String, n : Int) -> String {
  let chars = s.to_array()
  if n >= chars.length() {
    return ""
  }
  let result = StringBuilder::new()
  for i = n; i < chars.length(); i = i + 1 {
    result.write_char(chars[i])
  }
  result.to_string()
}

///|
/// 簡易的な整数パース
fn parse_int_simple(s : String) -> Int {
  let mut result = 0
  for c in s {
    if c >= '0' && c <= '9' {
      result = result * 10 + (c.to_int() - 48)
    }
  }
  result
}

///|
/// SHA の短縮表示
fn subdir_short_hex(hex : String) -> String {
  let chars = hex.to_array()
  let result = StringBuilder::new()
  for i = 0; i < 7 && i < chars.length(); i = i + 1 {
    result.write_char(chars[i])
  }
  result.to_string()
}

///|
/// タイムスタンプのフォーマット
fn format_timestamp_simple(timestamp : Int64) -> String {
  // Unix タイムスタンプを簡易的に表示
  timestamp.to_string()
}

///|
async fn handle_subdir_init(args : Array[String]) -> Unit raise Error {
  if args.length() < 1 {
    print_line("Usage: moongit subdir init <path> [--no-wrapper]")
    return
  }
  let subdir_path = args[0]
  let mut create_wrapper = true
  // オプション解析
  let mut i = 1
  while i < args.length() {
    let arg = args[i]
    if arg == "--no-wrapper" {
      create_wrapper = false
    }
    i += 1
  }
  let root = get_work_root()
  let git_dir = root + "/.git"
  let fs = OsFs::new()
  // サブディレクトリが存在するか確認
  let subdir_abs = root + "/" + subdir_path
  if not(fs.is_dir(subdir_abs)) {
    print_line("Error: subdirectory does not exist: " + subdir_path)
    return
  }
  // 初期化
  let config = @gitsubdir.SubdirInitConfig::new(create_wrapper~)
  let info = @gitsubdir.init_subdir(fs, git_dir, root, subdir_path, config) catch {
    err => raise @git.GitError::IoError("Failed to init: " + err.to_string())
  }
  print_line("Initialized subdirectory: " + info.path)
  print_line("Config: " + info.config_path)
  if create_wrapper {
    print_line("Wrapper script: " + subdir_abs + "/git-subdir")
  }
  print_line("")
  print_line("You can now:")
  print_line("  - Run 'moongit subdir shell " + subdir_path + "' to enter scoped shell")
  print_line("  - Use ./git-subdir in the subdirectory for scoped git commands")
}

///|
async fn handle_subdir_deinit(args : Array[String]) -> Unit raise Error {
  if args.length() < 1 {
    print_line("Usage: moongit subdir deinit <path>")
    return
  }
  let subdir_path = args[0]
  let root = get_work_root()
  let git_dir = root + "/.git"
  let fs = OsFs::new()
  // 初期化済みか確認
  if not(@gitsubdir.is_subdir_initialized(fs, git_dir, subdir_path)) {
    print_line("Subdirectory is not initialized: " + subdir_path)
    return
  }
  // 初期化解除
  @gitsubdir.deinit_subdir(fs, fs, git_dir, root, subdir_path) catch {
    err => raise @git.GitError::IoError("Failed to deinit: " + err.to_string())
  }
  print_line("Deinitialized subdirectory: " + subdir_path)
}

///|
async fn handle_subdir_shell(args : Array[String]) -> Unit raise Error {
  if args.length() < 1 {
    print_line("Usage: moongit subdir shell <path>")
    return
  }
  let subdir_path = args[0]
  let root = get_work_root()
  let git_dir = root + "/.git"
  let fs = OsFs::new()
  let subdir_abs = root + "/" + subdir_path
  // サブディレクトリが存在するか確認
  if not(fs.is_dir(subdir_abs)) {
    print_line("Error: subdirectory does not exist: " + subdir_path)
    return
  }
  // 環境変数を取得
  let env_vars = @gitsubdir.generate_shell_env(git_dir, root, subdir_path)
  // RC スクリプトを生成
  let rc_script = @gitsubdir.generate_shell_rc(subdir_path)
  // 一時ファイルに RC を書き込み
  let rc_path = "/tmp/moongit-subdir-rc-" + subdir_path_to_id(subdir_path)
  fs.write_file(rc_path, string_to_bytes_subdir(rc_script)) catch { _ => () }
  // シェルを起動
  print_line("Starting subdir shell for: " + subdir_path)
  print_line("git commands will be scoped to this directory.")
  print_line("")
  // 環境変数を設定してシェルを起動
  let shell = get_user_shell()
  let shell_args = build_shell_args(shell, rc_path)
  // 環境変数を設定
  for pair in env_vars {
    @sys.set_env_var(pair.0, pair.1)
  }
  // シェルプロセスを起動（サブディレクトリで）
  // カレントディレクトリを変更してシェルを起動
  @sys.set_env_var("MOONGIT_SUBDIR_RC", rc_path)
  let exit_code = @process.run(shell, shell_args)
  if exit_code != 0 {
    print_line("Shell exited with code: " + exit_code.to_string())
  }
  // 一時ファイルを削除
  fs.remove_file(rc_path) catch { _ => () }
  print_line("Exited subdir shell.")
}

///|
fn get_user_shell() -> String {
  match @sys.get_env_var("SHELL") {
    Some(s) => s
    None => "/bin/sh"
  }
}

///|
fn build_shell_args(shell : String, rc_path : String) -> Array[String] {
  // bash/zsh の場合は --rcfile を使用
  if shell.has_suffix("bash") {
    ["--rcfile", rc_path]
  } else if shell.has_suffix("zsh") {
    // zsh は ZDOTDIR を使うのが標準だが、簡易的に -i で対応
    ["-i"]
  } else {
    []
  }
}

///|
fn subdir_path_to_id(path : String) -> String {
  let result = StringBuilder::new()
  for c in path {
    if c == '/' {
      result.write_char('-')
    } else if c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' {
      result.write_char(c)
    }
  }
  result.to_string()
}

///|
fn string_to_bytes_subdir(s : String) -> Bytes {
  let bytes : Array[Byte] = []
  for c in s {
    bytes.push(c.to_int().to_byte())
  }
  Bytes::from_array(bytes)
}

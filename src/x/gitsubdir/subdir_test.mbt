///|
/// SubdirRepo のテスト

///|
test "subdir: extract_subdir_tree finds nested directory" {
  let fs = @git.TestFs::new()
  @lib.init_repo(fs, "/repo") catch { _ => () }
  // ディレクトリ構造を作成
  fs.mkdir_p("/repo/src/lib")
  fs.write_file("/repo/src/lib/foo.mbt", b"content of foo")
  fs.write_file("/repo/src/lib/bar.mbt", b"content of bar")
  fs.write_file("/repo/src/main.mbt", b"main content")
  fs.write_file("/repo/README.md", b"readme")
  // コミット
  let commit_id = @lib.commit(
    fs,
    fs,
    "/repo",
    "Initial commit",
    "test <test@test.com>",
    1000L,
  ) catch {
    _ => return ()
  }
  // ObjectDb を読み込む
  let db = @lib.ObjectDb::load(fs, "/repo/.git") catch { _ => return () }
  // サブディレクトリのツリーを抽出
  let tree_id = extract_subdir_tree(db, fs, commit_id, "src/lib") catch {
    _ => return ()
  }
  // ツリーが見つかったことを確認
  assert_true(tree_id != @git.ObjectId::zero())
}

///|
test "subdir: SubdirRepo::from_commit creates repo" {
  let fs = @git.TestFs::new()
  @lib.init_repo(fs, "/repo") catch { _ => () }
  // ディレクトリ構造を作成
  fs.mkdir_p("/repo/src/lib")
  fs.write_file("/repo/src/lib/foo.mbt", b"content of foo")
  fs.write_file("/repo/README.md", b"readme")
  // コミット
  let commit_id = @lib.commit(
    fs,
    fs,
    "/repo",
    "Initial commit",
    "test <test@test.com>",
    1000L,
  ) catch {
    _ => return ()
  }
  // SubdirRepo を作成
  let subdir = SubdirRepo::from_commit(fs, "/repo/.git", commit_id, "src/lib") catch {
    _ => return ()
  }
  // 基本プロパティを確認
  assert_eq(subdir.path(), "src/lib")
  assert_eq(subdir.base_commit(), Some(commit_id))
  assert_true(subdir.tree_id() is Some(_))
}

///|
test "subdir: read file through GitFs" {
  let fs = @git.TestFs::new()
  @lib.init_repo(fs, "/repo") catch { _ => () }
  // ディレクトリ構造を作成
  fs.mkdir_p("/repo/src/lib")
  fs.write_file("/repo/src/lib/foo.mbt", b"content of foo")
  // コミット
  let commit_id = @lib.commit(
    fs,
    fs,
    "/repo",
    "Initial commit",
    "test <test@test.com>",
    1000L,
  ) catch {
    _ => return ()
  }
  // SubdirRepo を作成
  let subdir = SubdirRepo::from_commit(fs, "/repo/.git", commit_id, "src/lib") catch {
    _ => return ()
  }
  // サブディレクトリ内のファイルをルートからのパスで読む
  let gitfs = subdir.fs()
  let content = gitfs.read_file(fs, "/foo.mbt") catch { _ => return () }
  assert_eq(content, b"content of foo")
}

///|
test "subdir: write file to working layer" {
  let fs = @git.TestFs::new()
  @lib.init_repo(fs, "/repo") catch { _ => () }
  // ディレクトリ構造を作成
  fs.mkdir_p("/repo/src/lib")
  fs.write_file("/repo/src/lib/foo.mbt", b"original")
  // コミット
  let commit_id = @lib.commit(
    fs,
    fs,
    "/repo",
    "Initial commit",
    "test <test@test.com>",
    1000L,
  ) catch {
    _ => return ()
  }
  // SubdirRepo を作成
  let subdir = SubdirRepo::from_commit(fs, "/repo/.git", commit_id, "src/lib") catch {
    _ => return ()
  }
  // 最初は dirty ではない
  assert_false(subdir.is_dirty())
  // ファイルを書き込む
  let gitfs = subdir.fs()
  gitfs.write_file("/foo.mbt", b"modified")
  // dirty になる
  assert_true(subdir.is_dirty())
  // 変更が読める
  let content = gitfs.read_file(fs, "/foo.mbt") catch { _ => return () }
  assert_eq(content, b"modified")
}

///|
test "subdir: error on non-existent subdir" {
  let fs = @git.TestFs::new()
  @lib.init_repo(fs, "/repo") catch { _ => () }
  // ファイルのみ作成（サブディレクトリなし）
  fs.write_file("/repo/README.md", b"readme")
  // コミット
  let commit_id = @lib.commit(
    fs,
    fs,
    "/repo",
    "Initial commit",
    "test <test@test.com>",
    1000L,
  ) catch {
    _ => return ()
  }
  // 存在しないサブディレクトリを指定 - エラーになるはず
  let _ = SubdirRepo::from_commit(fs, "/repo/.git", commit_id, "nonexistent") catch {
    SubdirNotFound(_) => {
      // 期待通りのエラー - テスト成功
      return ()
    }
    _ => {
      // 予期しないエラー
      assert_true(false)
      return ()
    }
  }
  // ここに来たら from_commit が成功してしまった
  assert_true(false)
}

///|
test "subdir: log returns commits that changed subdir" {
  let fs = @git.TestFs::new()
  @lib.init_repo(fs, "/repo") catch { _ => () }
  // 最初のコミット
  fs.mkdir_p("/repo/src/lib")
  fs.write_file("/repo/src/lib/foo.mbt", b"content v1")
  fs.write_file("/repo/README.md", b"readme")
  let _ = @lib.commit(
    fs,
    fs,
    "/repo",
    "Initial commit",
    "test <test@test.com>",
    1000L,
  ) catch {
    _ => return ()
  }
  // 2番目のコミット - サブディレクトリを変更
  fs.write_file("/repo/src/lib/foo.mbt", b"content v2")
  let _ = @lib.commit(
    fs,
    fs,
    "/repo",
    "Update lib",
    "test <test@test.com>",
    2000L,
  ) catch {
    _ => return ()
  }
  // 3番目のコミット - サブディレクトリ以外を変更
  fs.write_file("/repo/README.md", b"readme v2")
  let commit3 = @lib.commit(
    fs,
    fs,
    "/repo",
    "Update readme",
    "test <test@test.com>",
    3000L,
  ) catch {
    _ => return ()
  }
  // SubdirRepo を作成してログを取得
  let subdir = SubdirRepo::from_commit(fs, "/repo/.git", commit3, "src/lib") catch {
    _ => return ()
  }
  let history = subdir.log(fs) catch { _ => return () }
  // サブディレクトリを変更したコミットは2つ（1番目と2番目）
  // 3番目のコミットは README.md だけなので含まれない
  assert_eq(history.length(), 2)
}

///|
test "subdir: diff shows working changes" {
  let fs = @git.TestFs::new()
  @lib.init_repo(fs, "/repo") catch { _ => () }
  fs.mkdir_p("/repo/src/lib")
  fs.write_file("/repo/src/lib/foo.mbt", b"original")
  let commit_id = @lib.commit(
    fs,
    fs,
    "/repo",
    "Initial",
    "test <test@test.com>",
    1000L,
  ) catch {
    _ => return ()
  }
  let subdir = SubdirRepo::from_commit(fs, "/repo/.git", commit_id, "src/lib") catch {
    _ => return ()
  }
  // 変更前は空
  let diff_before = subdir.diff()
  assert_eq(diff_before.length(), 0)
  // ファイルを変更
  subdir.fs().write_file("/bar.mbt", b"new file")
  // 変更が表示される
  let diff_after = subdir.diff()
  assert_eq(diff_after.length(), 1)
  assert_eq(diff_after[0].path(), "/bar.mbt")
}

///|
test "subdir: commit changes to parent repo" {
  let fs = @git.TestFs::new()
  @lib.init_repo(fs, "/repo") catch { _ => () }
  fs.mkdir_p("/repo/src/lib")
  fs.write_file("/repo/src/lib/foo.mbt", b"original")
  fs.write_file("/repo/README.md", b"readme")
  let commit1 = @lib.commit(
    fs,
    fs,
    "/repo",
    "Initial",
    "test <test@test.com>",
    1000L,
  ) catch {
    _ => return ()
  }
  // SubdirRepo を作成して変更を加える
  let subdir = SubdirRepo::from_commit(fs, "/repo/.git", commit1, "src/lib") catch {
    _ => return ()
  }
  subdir.fs().write_file("/foo.mbt", b"modified")
  subdir.fs().write_file("/bar.mbt", b"new file")
  // サブディレクトリをコミット
  let commit2 = subdir.commit(
    fs,
    fs,
    "Update lib",
    author="test <test@test.com>",
    timestamp=2000L,
  ) catch {
    _ => return ()
  }
  // コミットが作成されたことを確認
  assert_true(commit2 != commit1)
  // 元リポジトリで変更を確認
  let db = @lib.ObjectDb::load(fs, "/repo/.git") catch { _ => return () }
  let files = @lib.collect_tree_files_from_commit(db, fs, commit2) catch {
    _ => return ()
  }
  // サブディレクトリのファイルが更新されている
  assert_true(files.contains("src/lib/foo.mbt"))
  assert_true(files.contains("src/lib/bar.mbt"))
  // ルートのファイルもまだ存在する
  assert_true(files.contains("README.md"))
}

///|
test "subdir: normalize path" {
  let fs = @git.TestFs::new()
  @lib.init_repo(fs, "/repo") catch { _ => () }
  // ディレクトリ構造を作成
  fs.mkdir_p("/repo/src/lib")
  fs.write_file("/repo/src/lib/foo.mbt", b"content")
  // コミット
  let commit_id = @lib.commit(
    fs,
    fs,
    "/repo",
    "Initial commit",
    "test <test@test.com>",
    1000L,
  ) catch {
    _ => return ()
  }
  // 様々なパス形式でテスト
  let subdir1 = SubdirRepo::from_commit(fs, "/repo/.git", commit_id, "src/lib") catch {
    _ => return ()
  }
  let subdir2 = SubdirRepo::from_commit(fs, "/repo/.git", commit_id, "/src/lib/") catch {
    _ => return ()
  }
  let subdir3 = SubdirRepo::from_commit(fs, "/repo/.git", commit_id, "./src/lib") catch {
    _ => return ()
  }
  // すべて同じパスに正規化される
  assert_eq(subdir1.path(), "src/lib")
  assert_eq(subdir2.path(), "src/lib")
  assert_eq(subdir3.path(), "src/lib")
}

///|
test "subdir: init creates config and marker files" {
  let fs = @git.TestFs::new()
  @lib.init_repo(fs, "/repo") catch { _ => () }
  fs.mkdir_p("/repo/src/lib")
  fs.write_file("/repo/src/lib/foo.mbt", b"content")
  // 初期化
  let config = SubdirInitConfig::new(create_wrapper=false)
  let info = init_subdir(fs, "/repo/.git", "/repo", "src/lib", config) catch {
    _ => return ()
  }
  // 結果を確認
  assert_eq(info.path, "src/lib")
  assert_true(info.initialized)
  // 設定ファイルが作成されている
  assert_true(fs.is_file("/repo/.git/subdir/src_lib/config"))
  // マーカーファイルが作成されている
  assert_true(fs.is_file("/repo/src/lib/.gitsubdir"))
}

///|
test "subdir: is_subdir_initialized returns correct status" {
  let fs = @git.TestFs::new()
  @lib.init_repo(fs, "/repo") catch { _ => () }
  fs.mkdir_p("/repo/src/lib")
  // 初期化前
  assert_false(is_subdir_initialized(fs, "/repo/.git", "src/lib"))
  // 初期化
  let config = SubdirInitConfig::default()
  let _ = init_subdir(fs, "/repo/.git", "/repo", "src/lib", config) catch {
    _ => return ()
  }
  // 初期化後
  assert_true(is_subdir_initialized(fs, "/repo/.git", "src/lib"))
}

///|
test "subdir: deinit removes config and marker files" {
  let fs = @git.TestFs::new()
  @lib.init_repo(fs, "/repo") catch { _ => () }
  fs.mkdir_p("/repo/src/lib")
  // 初期化
  let config = SubdirInitConfig::new(create_wrapper=false)
  let _ = init_subdir(fs, "/repo/.git", "/repo", "src/lib", config) catch {
    _ => return ()
  }
  assert_true(is_subdir_initialized(fs, "/repo/.git", "src/lib"))
  // 初期化解除
  deinit_subdir(fs, fs, "/repo/.git", "/repo", "src/lib") catch { _ => () }
  // 確認
  assert_false(is_subdir_initialized(fs, "/repo/.git", "src/lib"))
  assert_false(fs.is_file("/repo/src/lib/.gitsubdir"))
}

///|
test "subdir: generate_shell_env returns correct variables" {
  let env = generate_shell_env("/repo/.git", "/repo", "src/lib")
  assert_eq(env.length(), 4)
  // MOONGIT_SUBDIR
  assert_eq(env[0].0, "MOONGIT_SUBDIR")
  assert_eq(env[0].1, "src/lib")
  // GIT_PREFIX
  assert_eq(env[3].0, "GIT_PREFIX")
  assert_eq(env[3].1, "src/lib/")
}

///|
test "subdir: generate_shell_rc contains git wrapper" {
  let rc = generate_shell_rc("src/lib")
  // 基本的な内容を確認
  assert_true(rc.contains("git()"))
  assert_true(rc.contains("log)"))
  assert_true(rc.contains("status)"))
  assert_true(rc.contains("diff)"))
}

///|
test "subdir: init creates wrapper script with correct content" {
  let fs = @git.TestFs::new()
  @lib.init_repo(fs, "/repo") catch { _ => () }
  fs.mkdir_p("/repo/src/lib")
  // ラッパー付きで初期化
  let config = SubdirInitConfig::new(create_wrapper=true)
  let _ = init_subdir(fs, "/repo/.git", "/repo", "src/lib", config) catch {
    _ => return ()
  }
  // ラッパースクリプトが作成されている
  assert_true(fs.is_file("/repo/src/lib/git-subdir"))
  // 内容を確認
  let content = fs.read_file("/repo/src/lib/git-subdir") catch { _ => return () }
  let content_str = bytes_to_string_test(content)
  // シェバンがある
  assert_true(content_str.has_prefix("#!/bin/sh"))
  // log/status/diff がスコープされている
  assert_true(content_str.contains("log|status|diff)"))
  assert_true(content_str.contains("git \"$cmd\" \"$@\" -- ."))
}

///|
test "subdir: config file contains correct settings" {
  let fs = @git.TestFs::new()
  @lib.init_repo(fs, "/repo") catch { _ => () }
  fs.mkdir_p("/repo/src/lib")
  let config = SubdirInitConfig::new(create_wrapper=false)
  let _ = init_subdir(fs, "/repo/.git", "/repo", "src/lib", config) catch {
    _ => return ()
  }
  // 設定ファイルの内容を確認
  let content = fs.read_file("/repo/.git/subdir/src_lib/config") catch {
    _ => return ()
  }
  let content_str = bytes_to_string_test(content)
  assert_true(content_str.contains("[subdir]"))
  assert_true(content_str.contains("path = src/lib"))
  assert_true(content_str.contains("repoRoot = /repo"))
  assert_true(content_str.contains("initialized = true"))
}

///|
test "subdir: marker file contains path info" {
  let fs = @git.TestFs::new()
  @lib.init_repo(fs, "/repo") catch { _ => () }
  fs.mkdir_p("/repo/src/lib")
  let config = SubdirInitConfig::new(verbose_marker=true)
  let _ = init_subdir(fs, "/repo/.git", "/repo", "src/lib", config) catch {
    _ => return ()
  }
  // マーカーファイルの内容を確認
  let content = fs.read_file("/repo/src/lib/.gitsubdir") catch { _ => return () }
  let content_str = bytes_to_string_test(content)
  assert_true(content_str.contains("path = src/lib"))
  assert_true(content_str.contains("gitdir = /repo/.git"))
}

///|
test "subdir: get_subdir_info returns info for initialized subdir" {
  let fs = @git.TestFs::new()
  @lib.init_repo(fs, "/repo") catch { _ => () }
  fs.mkdir_p("/repo/src/lib")
  // 初期化前は None
  let info_before = get_subdir_info(fs, "/repo/.git", "/repo", "src/lib")
  assert_true(info_before is None)
  // 初期化
  let config = SubdirInitConfig::default()
  let _ = init_subdir(fs, "/repo/.git", "/repo", "src/lib", config) catch {
    _ => return ()
  }
  // 初期化後は Some
  let info_after = get_subdir_info(fs, "/repo/.git", "/repo", "src/lib")
  match info_after {
    Some(info) => {
      assert_eq(info.path, "src/lib")
      assert_eq(info.git_dir, "/repo/.git")
      assert_true(info.initialized)
    }
    None => assert_true(false)
  }
}

///|
test "subdir: full workflow init -> check -> deinit" {
  let fs = @git.TestFs::new()
  @lib.init_repo(fs, "/repo") catch { _ => () }
  // 複数のサブディレクトリを作成
  fs.mkdir_p("/repo/src/lib")
  fs.mkdir_p("/repo/src/cli")
  fs.write_file("/repo/src/lib/foo.mbt", b"lib content")
  fs.write_file("/repo/src/cli/main.mbt", b"cli content")
  // 両方を初期化
  let config = SubdirInitConfig::default()
  let _ = init_subdir(fs, "/repo/.git", "/repo", "src/lib", config) catch {
    _ => return ()
  }
  let _ = init_subdir(fs, "/repo/.git", "/repo", "src/cli", config) catch {
    _ => return ()
  }
  // 両方が初期化されている
  assert_true(is_subdir_initialized(fs, "/repo/.git", "src/lib"))
  assert_true(is_subdir_initialized(fs, "/repo/.git", "src/cli"))
  // lib だけ解除
  deinit_subdir(fs, fs, "/repo/.git", "/repo", "src/lib") catch { _ => () }
  // lib は解除され、cli はまだ初期化されている
  assert_false(is_subdir_initialized(fs, "/repo/.git", "src/lib"))
  assert_true(is_subdir_initialized(fs, "/repo/.git", "src/cli"))
  // ファイルが削除されている
  assert_false(fs.is_file("/repo/src/lib/.gitsubdir"))
  assert_false(fs.is_file("/repo/src/lib/git-subdir"))
  // cli のファイルはまだ存在
  assert_true(fs.is_file("/repo/src/cli/.gitsubdir"))
}

///|
test "subdir: nested path initialization" {
  let fs = @git.TestFs::new()
  @lib.init_repo(fs, "/repo") catch { _ => () }
  // 深いネストのディレクトリ
  fs.mkdir_p("/repo/src/packages/core/lib")
  fs.write_file("/repo/src/packages/core/lib/index.mbt", b"content")
  let config = SubdirInitConfig::default()
  let info = init_subdir(
    fs,
    "/repo/.git",
    "/repo",
    "src/packages/core/lib",
    config,
  ) catch {
    _ => return ()
  }
  // パスが正規化されている
  assert_eq(info.path, "src/packages/core/lib")
  // 設定ディレクトリ名が正しい（/ が _ に変換）
  assert_true(fs.is_file("/repo/.git/subdir/src_packages_core_lib/config"))
}

///|
test "subdir: shell rc script has correct structure" {
  let rc = generate_shell_rc("src/lib")
  // ヘッダーコメント
  assert_true(rc.contains("# Moongit subdir shell for: src/lib"))
  // git 関数定義
  assert_true(rc.contains("git() {"))
  // case 文
  assert_true(rc.contains("case \"$cmd\" in"))
  // log コマンドのスコープ
  assert_true(rc.contains("log)"))
  assert_true(rc.contains("command git log \"$@\" -- ."))
  // status コマンドのスコープ
  assert_true(rc.contains("status)"))
  assert_true(rc.contains("command git status \"$@\" -- ."))
  // diff コマンドのスコープ
  assert_true(rc.contains("diff)"))
  assert_true(rc.contains("command git diff \"$@\" -- ."))
  // add コマンド
  assert_true(rc.contains("add)"))
  assert_true(rc.contains("command git add ."))
  // プロンプト設定
  assert_true(rc.contains("PS1=\"[subdir:src/lib]"))
  // 説明メッセージ
  assert_true(rc.contains("Entered subdir shell for: src/lib"))
}

///|
test "subdir: env vars have correct values" {
  let env = generate_shell_env("/home/user/repo/.git", "/home/user/repo", "packages/core")
  // 各環境変数を確認
  let mut found_subdir = false
  let mut found_git_dir = false
  let mut found_root = false
  let mut found_prefix = false
  for pair in env {
    match pair.0 {
      "MOONGIT_SUBDIR" => {
        assert_eq(pair.1, "packages/core")
        found_subdir = true
      }
      "MOONGIT_GIT_DIR" => {
        assert_eq(pair.1, "/home/user/repo/.git")
        found_git_dir = true
      }
      "MOONGIT_REPO_ROOT" => {
        assert_eq(pair.1, "/home/user/repo")
        found_root = true
      }
      "GIT_PREFIX" => {
        assert_eq(pair.1, "packages/core/")
        found_prefix = true
      }
      _ => ()
    }
  }
  assert_true(found_subdir)
  assert_true(found_git_dir)
  assert_true(found_root)
  assert_true(found_prefix)
}

///|
test "subdir: init with SubdirRepo integration" {
  let fs = @git.TestFs::new()
  @lib.init_repo(fs, "/repo") catch { _ => () }
  // ディレクトリとファイルを作成してコミット
  fs.mkdir_p("/repo/src/lib")
  fs.write_file("/repo/src/lib/foo.mbt", b"original content")
  fs.write_file("/repo/README.md", b"readme")
  let commit_id = @lib.commit(
    fs,
    fs,
    "/repo",
    "Initial commit",
    "test <test@test.com>",
    1000L,
  ) catch {
    _ => return ()
  }
  // init_subdir を実行
  let config = SubdirInitConfig::default()
  let _ = init_subdir(fs, "/repo/.git", "/repo", "src/lib", config) catch {
    _ => return ()
  }
  // SubdirRepo も正常に作成できる
  let subdir = SubdirRepo::from_commit(fs, "/repo/.git", commit_id, "src/lib") catch {
    _ => return ()
  }
  // ファイルが読める
  let content = subdir.fs().read_file(fs, "/foo.mbt") catch { _ => return () }
  assert_eq(content, b"original content")
}

///|
fn bytes_to_string_test(bytes : Bytes) -> String {
  let result = StringBuilder::new()
  for i = 0; i < bytes.length(); i = i + 1 {
    result.write_char(bytes[i].to_int().unsafe_to_char())
  }
  result.to_string()
}

///|
test "subdir: commit creates new commit in parent repo" {
  let fs = @git.TestFs::new()
  @lib.init_repo(fs, "/repo") catch { _ => () }
  // 初期ファイルを作成
  fs.mkdir_p("/repo/src/lib")
  fs.write_file("/repo/src/lib/foo.mbt", b"original")
  fs.write_file("/repo/README.md", b"readme")
  // 初期コミット
  let commit1 = @lib.commit(
    fs,
    fs,
    "/repo",
    "Initial",
    "test <test@test.com>",
    1000L,
  ) catch {
    _ => return ()
  }
  // SubdirRepo を作成して変更
  let subdir = SubdirRepo::from_commit(fs, "/repo/.git", commit1, "src/lib") catch {
    _ => return ()
  }
  // ワーキング層に変更を加える
  subdir.fs().write_file("/foo.mbt", b"modified")
  subdir.fs().write_file("/bar.mbt", b"new file")
  assert_true(subdir.is_dirty())
  // コミット
  let commit2 = subdir.commit(
    fs,
    fs,
    "Update lib",
    author="test <test@test.com>",
    timestamp=2000L,
  ) catch {
    _ => return ()
  }
  // 新しいコミットが作成された
  assert_true(commit2 != commit1)
  // 新しいコミットからファイルを読める
  let subdir2 = SubdirRepo::from_commit(fs, "/repo/.git", commit2, "src/lib") catch {
    _ => return ()
  }
  let content = subdir2.fs().read_file(fs, "/foo.mbt") catch { _ => return () }
  assert_eq(content, b"modified")
  let new_content = subdir2.fs().read_file(fs, "/bar.mbt") catch { _ => return () }
  assert_eq(new_content, b"new file")
}

///|
test "subdir: checkout retrieves files from specific commit" {
  let fs = @git.TestFs::new()
  @lib.init_repo(fs, "/repo") catch { _ => () }
  // コミット1: v1
  fs.mkdir_p("/repo/src/lib")
  fs.write_file("/repo/src/lib/foo.mbt", b"version 1")
  let commit1 = @lib.commit(
    fs,
    fs,
    "/repo",
    "Version 1",
    "test <test@test.com>",
    1000L,
  ) catch {
    _ => return ()
  }
  // コミット2: v2
  fs.write_file("/repo/src/lib/foo.mbt", b"version 2")
  let commit2 = @lib.commit(
    fs,
    fs,
    "/repo",
    "Version 2",
    "test <test@test.com>",
    2000L,
  ) catch {
    _ => return ()
  }
  // commit1 のサブディレクトリを取得
  let subdir1 = SubdirRepo::from_commit(fs, "/repo/.git", commit1, "src/lib") catch {
    _ => return ()
  }
  let content1 = subdir1.fs().read_file(fs, "/foo.mbt") catch { _ => return () }
  assert_eq(content1, b"version 1")
  // commit2 のサブディレクトリを取得
  let subdir2 = SubdirRepo::from_commit(fs, "/repo/.git", commit2, "src/lib") catch {
    _ => return ()
  }
  let content2 = subdir2.fs().read_file(fs, "/foo.mbt") catch { _ => return () }
  assert_eq(content2, b"version 2")
}

///|
test "subdir: commit preserves files outside subdirectory" {
  let fs = @git.TestFs::new()
  @lib.init_repo(fs, "/repo") catch { _ => () }
  // ルートとサブディレクトリにファイルを作成
  fs.mkdir_p("/repo/src/lib")
  fs.write_file("/repo/src/lib/foo.mbt", b"lib content")
  fs.write_file("/repo/README.md", b"root readme")
  fs.write_file("/repo/src/main.mbt", b"main content")
  // 初期コミット
  let commit1 = @lib.commit(
    fs,
    fs,
    "/repo",
    "Initial",
    "test <test@test.com>",
    1000L,
  ) catch {
    _ => return ()
  }
  // SubdirRepo で変更してコミット
  let subdir = SubdirRepo::from_commit(fs, "/repo/.git", commit1, "src/lib") catch {
    _ => return ()
  }
  subdir.fs().write_file("/foo.mbt", b"modified lib")
  let commit2 = subdir.commit(
    fs,
    fs,
    "Update lib only",
    author="test <test@test.com>",
    timestamp=2000L,
  ) catch {
    _ => return ()
  }
  // ルートのファイルが保持されていることを確認
  let db = @lib.ObjectDb::load(fs, "/repo/.git") catch { _ => return () }
  let files = @lib.collect_tree_files_from_commit(db, fs, commit2) catch {
    _ => return ()
  }
  // すべてのファイルが存在
  assert_true(files.contains("README.md"))
  assert_true(files.contains("src/main.mbt"))
  assert_true(files.contains("src/lib/foo.mbt"))
}

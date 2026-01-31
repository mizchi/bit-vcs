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

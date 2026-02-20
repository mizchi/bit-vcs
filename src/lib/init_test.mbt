///| Tests for init ref storage options

///|
test "init: default options use files ref format" {
  let fs = @bit.TestFs::new()
  let opts = InitOptions::new()
  init_repo_with_options(fs, "/repo", opts)
  let config = fs.read_string("/repo/.git/config")
  assert_false(config.contains("refStorage = reftable"))
  assert_false(fs.is_dir("/repo/.git/reftable"))
}

///|
test "init: reftable ref format writes extensions and metadata directory" {
  let fs = @bit.TestFs::new()
  init_repo_with_options(fs, "/repo", {
    default_branch: "main",
    bare: false,
    separate_git_dir: None,
    template_dir: None,
    ref_format: "reftable",
    object_format: "sha1",
  })
  let config = fs.read_string("/repo/.git/config")
  assert_true(config.contains("repositoryformatversion = 1"))
  assert_true(config.contains("refStorage = reftable"))
  assert_true(fs.is_dir("/repo/.git/reftable"))
  assert_true(fs.is_file("/repo/.git/reftable/tables.list"))
}

///|
test "init: sha256 object format writes objectFormat extension" {
  let fs = @bit.TestFs::new()
  init_repo_with_options(fs, "/repo", {
    default_branch: "main",
    bare: false,
    separate_git_dir: None,
    template_dir: None,
    ref_format: "files",
    object_format: "sha256",
  })
  let config = fs.read_string("/repo/.git/config")
  assert_true(config.contains("repositoryformatversion = 1"))
  assert_true(config.contains("objectFormat = sha256"))
}

///|
test "init: reinit to move existing .git directory to separate gitdir" {
  let fs = @bit.TestFs::new()
  init_repo_with_options(fs, "/repo", {
    default_branch: "main",
    bare: false,
    separate_git_dir: None,
    template_dir: None,
    ref_format: "files",
    object_format: "sha1",
  })
  init_repo_with_options_with_repo_fs(fs, fs, "/repo", {
    default_branch: "main",
    bare: false,
    separate_git_dir: Some("/separate"),
    template_dir: None,
    ref_format: "files",
    object_format: "sha1",
  })
  assert_true(fs.is_file("/repo/.git"))
  assert_eq(fs.read_string("/repo/.git"), "gitdir: /separate\n")
  assert_true(fs.is_dir("/separate"))
  assert_false(fs.is_dir("/repo/.git"))
  assert_false(fs.is_dir("/repo/.git/refs"))
}

///|
test "init: reinit to move existing separate gitdir path from .git file" {
  let fs = @bit.TestFs::new()
  init_repo_with_options_with_repo_fs(fs, fs, "/repo", {
    default_branch: "main",
    bare: false,
    separate_git_dir: Some("/real-git-dir"),
    template_dir: None,
    ref_format: "files",
    object_format: "sha1",
  })
  init_repo_with_options_with_repo_fs(fs, fs, "/repo", {
    default_branch: "main",
    bare: false,
    separate_git_dir: Some("/surreal-git-dir"),
    template_dir: None,
    ref_format: "files",
    object_format: "sha1",
  })
  assert_true(fs.is_file("/repo/.git"))
  assert_eq(fs.read_string("/repo/.git"), "gitdir: /surreal-git-dir\n")
  assert_true(fs.is_dir("/surreal-git-dir"))
  assert_false(fs.is_dir("/real-git-dir/refs"))
}

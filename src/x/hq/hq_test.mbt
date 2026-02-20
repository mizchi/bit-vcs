///|
test "RepoPath::parse: user/repo shorthand" {
  let result = parse_repo_url("mizchi/git")
  let expected =
    #|Some({host: None, user: "mizchi", repo: "git", subdir: None})
  inspect(result, content=expected)
}

///|
test "RepoPath::parse: user/repo:subdir shorthand" {
  let result = parse_repo_url("mizchi/monorepo:packages/core")
  let expected =
    #|Some({host: None, user: "mizchi", repo: "monorepo", subdir: Some("packages/core")})
  inspect(result, content=expected)
}

///|
test "RepoPath::parse: user/repo/path subdir" {
  let result = parse_repo_url("mizchi/monorepo/packages/core")
  let expected =
    #|Some({host: None, user: "mizchi", repo: "monorepo", subdir: Some("packages/core")})
  inspect(result, content=expected)
}

///|
test "RepoPath::parse: github.com/user/repo/path subdir" {
  let result = parse_repo_url("github.com/mizchi/monorepo/packages/core")
  let expected =
    #|Some({host: None, user: "mizchi", repo: "monorepo", subdir: Some("packages/core")})
  inspect(result, content=expected)
}

///|
test "RepoPath::parse: gitlab.com/user/repo/path subdir" {
  let result = parse_repo_url("gitlab.com/user/monorepo/packages/core")
  let expected =
    #|Some({host: Some("gitlab.com"), user: "user", repo: "monorepo", subdir: Some("packages/core")})
  inspect(result, content=expected)
}

///|
test "RepoPath::parse: github.com/user/repo (normalized)" {
  let result = parse_repo_url("github.com/mizchi/git")
  let expected =
    #|Some({host: None, user: "mizchi", repo: "git", subdir: None})
  inspect(result, content=expected)
}

///|
test "RepoPath::parse: gitlab.com/user/repo (other host)" {
  let result = parse_repo_url("gitlab.com/user/project")
  let expected =
    #|Some({host: Some("gitlab.com"), user: "user", repo: "project", subdir: None})
  inspect(result, content=expected)
}

///|
test "RepoPath::parse: https URL" {
  let result = parse_repo_url("https://github.com/mizchi/git")
  let expected =
    #|Some({host: None, user: "mizchi", repo: "git", subdir: None})
  inspect(result, content=expected)
}

///|
test "RepoPath::parse: https URL with .git" {
  let result = parse_repo_url("https://github.com/mizchi/git.git")
  let expected =
    #|Some({host: None, user: "mizchi", repo: "git", subdir: None})
  inspect(result, content=expected)
}

///|
test "RepoPath::parse: https URL with tree path" {
  let result = parse_repo_url(
    "https://github.com/mizchi/monorepo/tree/main/packages/core",
  )
  let expected =
    #|Some({host: None, user: "mizchi", repo: "monorepo", subdir: Some("packages/core")})
  inspect(result, content=expected)
}

///|
test "RepoPath::parse: SSH URL" {
  let result = parse_repo_url("git@github.com:mizchi/git.git")
  let expected =
    #|Some({host: None, user: "mizchi", repo: "git", subdir: None})
  inspect(result, content=expected)
}

///|
test "RepoPath::parse: SSH URL gitlab" {
  let result = parse_repo_url("git@gitlab.com:user/project.git")
  let expected =
    #|Some({host: Some("gitlab.com"), user: "user", repo: "project", subdir: None})
  inspect(result, content=expected)
}

///|
test "RepoPath::clone_url: HTTPS" {
  let repo = RepoPath::new("mizchi", "git")
  inspect(repo.clone_url(), content="https://github.com/mizchi/git.git")
}

///|
test "RepoPath::clone_url: SSH" {
  let repo = RepoPath::new("mizchi", "git")
  inspect(repo.clone_url(ssh=true), content="git@github.com:mizchi/git.git")
}

///|
test "RepoPath::clone_url: other host" {
  let repo = RepoPath::new("user", "project", host=Some("gitlab.com"))
  inspect(repo.clone_url(), content="https://gitlab.com/user/project.git")
}

///|
test "RepoPath::local_path: github.com normalized" {
  let repo = RepoPath::new("mizchi", "git")
  inspect(
    repo.local_path("/home/user/bhq"),
    content="/home/user/bhq/mizchi/git",
  )
}

///|
test "RepoPath::local_path: explicit github.com also normalized" {
  let repo = parse_repo_url("github.com/mizchi/git").unwrap()
  inspect(
    repo.local_path("/home/user/bhq"),
    content="/home/user/bhq/mizchi/git",
  )
}

///|
test "RepoPath::local_path: other host includes host" {
  let repo = RepoPath::new("user", "project", host=Some("gitlab.com"))
  let expected = "/home/user/bhq/gitlab.com/user/project"
  inspect(repo.local_path("/home/user/bhq"), content=expected)
}

///|
test "RepoPath::needs_sparse" {
  let repo1 = RepoPath::new("mizchi", "git")
  let repo2 = RepoPath::new("mizchi", "monorepo", subdir=Some("packages/core"))
  inspect(repo1.needs_sparse(), content="false")
  inspect(repo2.needs_sparse(), content="true")
}

///|
test "load_config: BHQ_ROOT environment variable" {
  fn env_get(key : String) -> String? {
    if key == "BHQ_ROOT" {
      Some("/custom/path")
    } else {
      None
    }
  }

  fn bit_config_get(_key : String) -> String? {
    None
  }

  let config = load_config(env_get, bit_config_get)
  inspect(config.root, content="/custom/path")
}

///|
test "load_config: default bhq root" {
  fn env_get(_key : String) -> String? {
    None
  }

  fn bit_config_get(_key : String) -> String? {
    None
  }

  let config = load_config(env_get, bit_config_get)
  // Default is ~/bhq, but ~ is expanded to /home/user in tests
  inspect(config.root, content="/home/user/bhq")
}

///|
test "expand_home: with tilde" {
  let result = expand_home("~/repos")
  // In tests, home is /home/user
  inspect(result, content="/home/user/repos")
}

///|
test "expand_home: without tilde" {
  let result = expand_home("/absolute/path")
  inspect(result, content="/absolute/path")
}

///|
test "contract_home: with matching home" {
  let result = contract_home("/home/user/repos", "/home/user")
  inspect(result, content="~/repos")
}

///|
test "build_clone_command: simple" {
  let repo = RepoPath::new("mizchi", "git")
  let options = HqGetOptions::default()
  let cmd = build_clone_command(repo, "/home/user/bhq/mizchi/git", options)
  let expected = "git clone https://github.com/mizchi/git.git /home/user/bhq/mizchi/git"
  inspect(cmd, content=expected)
}

///|
test "build_clone_command: shallow" {
  let repo = RepoPath::new("mizchi", "git")
  let options = HqGetOptions::new(shallow=true)
  let cmd = build_clone_command(repo, "/home/user/bhq/mizchi/git", options)
  let expected = "git clone --depth=1 https://github.com/mizchi/git.git /home/user/bhq/mizchi/git"
  inspect(cmd, content=expected)
}

///|
test "build_clone_command: explicit depth" {
  let repo = RepoPath::new("mizchi", "git")
  let options = HqGetOptions::new(depth=3)
  let cmd = build_clone_command(repo, "/home/user/bhq/mizchi/git", options)
  let expected = "git clone --depth=3 https://github.com/mizchi/git.git /home/user/bhq/mizchi/git"
  inspect(cmd, content=expected)
}

///|
test "build_clone_command: sparse checkout" {
  let repo = RepoPath::new("mizchi", "monorepo", subdir=Some("packages/core"))
  let options = HqGetOptions::default()
  let cmd = build_clone_command(repo, "/home/user/bhq/mizchi/monorepo", options)
  let expected = "git clone --no-checkout https://github.com/mizchi/monorepo.git /home/user/bhq/mizchi/monorepo && cd /home/user/bhq/mizchi/monorepo && git sparse-checkout init --cone && git sparse-checkout set /packages/core/"
  inspect(cmd, content=expected)
}

///|
test "build_clone_command: sparse checkout with depth" {
  let repo = RepoPath::new("mizchi", "monorepo", subdir=Some("packages/core"))
  let options = HqGetOptions::new(depth=2)
  let cmd = build_clone_command(repo, "/home/user/bhq/mizchi/monorepo", options)
  let expected = "git clone --no-checkout --depth=2 https://github.com/mizchi/monorepo.git /home/user/bhq/mizchi/monorepo && cd /home/user/bhq/mizchi/monorepo && git sparse-checkout init --cone && git sparse-checkout set /packages/core/"
  inspect(cmd, content=expected)
}

///|
test "hq_get: clone new repository" {
  let repo = RepoPath::new("mizchi", "git")
  let config = HqConfig::new("/tmp/bhq")
  let options = HqGetOptions::default()
  fn exec(_cmd : String) -> (Int, String, String) {
    (0, "", "")
  }

  fn path_exists(_path : String) -> Bool {
    false
  }

  let result = hq_get(repo, config, options, exec, path_exists)
  inspect(result, content="Cloned(\"/tmp/bhq/mizchi/git\")")
}

///|
test "hq_get: clone new repository with explicit depth" {
  let repo = RepoPath::new("mizchi", "git")
  let config = HqConfig::new("/tmp/bhq")
  let options = HqGetOptions::new(depth=2)
  let commands : Array[String] = []
  fn exec(cmd : String) -> (Int, String, String) {
    commands.push(cmd)
    (0, "", "")
  }

  fn path_exists(_path : String) -> Bool {
    false
  }

  let result = hq_get(repo, config, options, exec, path_exists)
  inspect(result, content="Cloned(\"/tmp/bhq/mizchi/git\")")
  assert_eq(commands.length(), 1)
  assert_eq(
    commands[0],
    "git clone --depth=2 https://github.com/mizchi/git.git /tmp/bhq/mizchi/git",
  )
}

///|
test "hq_get: skip existing without update" {
  let repo = RepoPath::new("mizchi", "git")
  let config = HqConfig::new("/tmp/bhq")
  let options = HqGetOptions::default()
  fn exec(_cmd : String) -> (Int, String, String) {
    (0, "", "")
  }

  fn path_exists(_path : String) -> Bool {
    true
  }

  let result = hq_get(repo, config, options, exec, path_exists)
  inspect(result, content="Skipped(\"/tmp/bhq/mizchi/git\")")
}

///|
test "hq_get: unshallow existing repository before update" {
  let repo = RepoPath::new("mizchi", "git")
  let config = HqConfig::new("/tmp/bhq")
  let options = HqGetOptions::new(update=true, unshallow=true)
  let commands : Array[String] = []
  fn exec(cmd : String) -> (Int, String, String) {
    commands.push(cmd)
    (0, "", "")
  }

  fn path_exists(_path : String) -> Bool {
    true
  }

  let result = hq_get(repo, config, options, exec, path_exists)
  inspect(result, content="Updated(\"/tmp/bhq/mizchi/git\")")
  assert_eq(commands.length(), 2)
  assert_eq(commands[0], "cd /tmp/bhq/mizchi/git && git fetch --unshallow")
  assert_eq(commands[1], "cd /tmp/bhq/mizchi/git && git pull --ff-only")
}

///|
test "hq_get: update existing with -u" {
  let repo = RepoPath::new("mizchi", "git")
  let config = HqConfig::new("/tmp/bhq")
  let options = HqGetOptions::new(update=true)
  fn exec(_cmd : String) -> (Int, String, String) {
    (0, "", "")
  }

  fn path_exists(_path : String) -> Bool {
    true
  }

  let result = hq_get(repo, config, options, exec, path_exists)
  inspect(result, content="Updated(\"/tmp/bhq/mizchi/git\")")
}

///|
test "parse_repo_path: user/repo" {
  let result = parse_repo_path("mizchi/git")
  let expected =
    #|Some({host: None, user: "mizchi", repo: "git", subdir: None})
  inspect(result, content=expected)
}

///|
test "parse_repo_path: host/user/repo" {
  let result = parse_repo_path("gitlab.com/user/project")
  let expected =
    #|Some({host: Some("gitlab.com"), user: "user", repo: "project", subdir: None})
  inspect(result, content=expected)
}

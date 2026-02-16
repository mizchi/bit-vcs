///|
test "hub parser: parse_pr_state handles known and unknown values" {
  assert_eq(parse_pr_state("open"), Some(@hub.PrState::Open))
  assert_eq(parse_pr_state("closed"), Some(@hub.PrState::Closed))
  assert_eq(parse_pr_state("merged"), Some(@hub.PrState::Merged))
  assert_eq(parse_pr_state("draft"), None)
}

///|
test "hub parser: parse_issue_state handles known and unknown values" {
  assert_eq(parse_issue_state("open"), Some(@hub.IssueState::Open))
  assert_eq(parse_issue_state("closed"), Some(@hub.IssueState::Closed))
  assert_eq(parse_issue_state("draft"), None)
}

///|
test "hub parser: parse_work_item_state handles known and unknown values" {
  assert_eq(parse_work_item_state("open"), Some(@hub.WorkItemState::Open))
  assert_eq(parse_work_item_state("closed"), Some(@hub.WorkItemState::Closed))
  assert_eq(parse_work_item_state("merged"), Some(@hub.WorkItemState::Merged))
  assert_eq(parse_work_item_state("draft"), None)
}

///|
test "hub parser: parse_work_item_kind handles known and unknown values" {
  assert_eq(parse_work_item_kind("issue"), Some(@hub.WorkItemKind::Issue))
  assert_eq(parse_work_item_kind("pr"), Some(@hub.WorkItemKind::PullRequest))
  assert_eq(
    parse_work_item_kind("pull-request"),
    Some(@hub.WorkItemKind::PullRequest),
  )
  assert_eq(parse_work_item_kind("comment"), None)
}

///|
test "hub parser: parse_review_verdict handles known and unknown values" {
  assert_eq(
    parse_review_verdict("approved"),
    Some(@hub.ReviewVerdict::Approved),
  )
  assert_eq(parse_review_verdict("comment"), Some(@hub.ReviewVerdict::Comment))
  assert_eq(
    parse_review_verdict("request-changes"),
    Some(@hub.ReviewVerdict::RequestChanges),
  )
  assert_eq(parse_review_verdict("reject"), None)
}

///|
test "hub parser: parse_review_verdict_flag handles gh-style flags" {
  assert_eq(
    parse_review_verdict_flag("--approve"),
    Some(@hub.ReviewVerdict::Approved),
  )
  assert_eq(
    parse_review_verdict_flag("--comment"),
    Some(@hub.ReviewVerdict::Comment),
  )
  assert_eq(
    parse_review_verdict_flag("--request-changes"),
    Some(@hub.ReviewVerdict::RequestChanges),
  )
  assert_eq(parse_review_verdict_flag("--unknown"), None)
}

///|
test "hub parser: parse_merge_strategy handles known and unknown values" {
  match parse_merge_strategy("merge") {
    Some(@hub.PrMergeStrategy::Merge) => ()
    _ => fail("expected merge strategy")
  }
  match parse_merge_strategy("squash") {
    Some(@hub.PrMergeStrategy::Squash) => ()
    _ => fail("expected squash strategy")
  }
  match parse_merge_strategy("ff") {
    Some(@hub.PrMergeStrategy::FastForward) => ()
    _ => fail("expected ff strategy")
  }
  match parse_merge_strategy("rebase") {
    None => ()
    _ => fail("unexpected strategy")
  }
}

///|
test "hub parser: parse_merge_strategy_flag handles gh-style flags" {
  match parse_merge_strategy_flag("--merge") {
    Some(@hub.PrMergeStrategy::Merge) => ()
    _ => fail("expected merge strategy")
  }
  match parse_merge_strategy_flag("--squash") {
    Some(@hub.PrMergeStrategy::Squash) => ()
    _ => fail("expected squash strategy")
  }
  match parse_merge_strategy_flag("--ff") {
    Some(@hub.PrMergeStrategy::FastForward) => ()
    _ => fail("expected ff strategy")
  }
  match parse_merge_strategy_flag("--unknown") {
    None => ()
    _ => fail("unexpected strategy")
  }
}

///|
test "hub parser: normalize pr subcommand handles gh aliases" {
  assert_eq(normalize_hub_pr_subcommand("view"), "get")
  assert_eq(normalize_hub_pr_subcommand("edit"), "update")
  assert_eq(normalize_hub_pr_subcommand("proposal"), "proposals")
  assert_eq(normalize_hub_pr_subcommand("list"), "list")
}

///|
test "hub parser: normalize issue subcommand handles gh aliases" {
  assert_eq(normalize_hub_issue_subcommand("view"), "get")
  assert_eq(normalize_hub_issue_subcommand("edit"), "update")
  assert_eq(normalize_hub_issue_subcommand("list"), "list")
}

///|
test "hub parser: normalize work-item subcommand handles aliases" {
  assert_eq(normalize_hub_work_item_subcommand("view"), "get")
  assert_eq(normalize_hub_work_item_subcommand("list"), "list")
}

///|
test "hub parser: resolve comment subcommand defaults to add" {
  assert_eq(resolve_hub_comment_subcommand("add"), "add")
  assert_eq(resolve_hub_comment_subcommand("list"), "list")
  assert_eq(resolve_hub_comment_subcommand("123"), "add")
}

///|
test "hub parser: resolve review subcommand defaults to submit" {
  assert_eq(resolve_hub_review_subcommand("submit"), "submit")
  assert_eq(resolve_hub_review_subcommand("list"), "list")
  assert_eq(resolve_hub_review_subcommand("123"), "submit")
}

///|
test "hub parser: parse_pr_state_flag handles gh-style flags" {
  assert_eq(parse_pr_state_flag("--open"), Some(@hub.PrState::Open))
  assert_eq(parse_pr_state_flag("--closed"), Some(@hub.PrState::Closed))
  assert_eq(parse_pr_state_flag("--merged"), Some(@hub.PrState::Merged))
  assert_eq(parse_pr_state_flag("--all"), None)
}

///|
test "hub parser: parse_issue_state_flag handles gh-style flags" {
  assert_eq(parse_issue_state_flag("--open"), Some(@hub.IssueState::Open))
  assert_eq(parse_issue_state_flag("--closed"), Some(@hub.IssueState::Closed))
  assert_eq(parse_issue_state_flag("--all"), None)
}

///|
test "hub parser: parse_work_item_state_flag handles flags" {
  assert_eq(
    parse_work_item_state_flag("--open"),
    Some(@hub.WorkItemState::Open),
  )
  assert_eq(
    parse_work_item_state_flag("--closed"),
    Some(@hub.WorkItemState::Closed),
  )
  assert_eq(
    parse_work_item_state_flag("--merged"),
    Some(@hub.WorkItemState::Merged),
  )
  assert_eq(parse_work_item_state_flag("--all"), None)
}

///|
test "hub parser: parse_work_item_kind_flag handles flags" {
  assert_eq(
    parse_work_item_kind_flag("--issue"),
    Some(@hub.WorkItemKind::Issue),
  )
  assert_eq(
    parse_work_item_kind_flag("--pr"),
    Some(@hub.WorkItemKind::PullRequest),
  )
  assert_eq(parse_work_item_kind_flag("--all"), None)
}

///|
test "hub parser: parse_head_branch_name handles symbolic and detached head" {
  assert_eq(parse_head_branch_name("ref: refs/heads/main\n"), Some("main"))
  assert_eq(
    parse_head_branch_name("ref: refs/heads/feature/topic\n"),
    Some("feature/topic"),
  )
  assert_eq(
    parse_head_branch_name("9fceb02f5f7a6f5a5be74e5f7d2d9d31b2f9f0f5\n"),
    None,
  )
}

///|
test "hub parser: parse_hub_pr_list_options handles gh-style flags and limit" {
  let opts = parse_hub_pr_list_options(["--closed", "--limit", "5"])
  assert_eq(opts.limit, Some(5))
  match opts.state {
    Some(@hub.PrState::Closed) => ()
    _ => fail("expected closed state")
  }
  let opts2 = parse_hub_pr_list_options(["-L", "3", "--open"])
  assert_eq(opts2.limit, Some(3))
  match opts2.state {
    Some(@hub.PrState::Open) => ()
    _ => fail("expected open state")
  }
}

///|
test "hub parser: parse_hub_issue_list_options handles gh-style flags and limit" {
  let opts = parse_hub_issue_list_options(["--closed", "--limit", "7"])
  assert_eq(opts.limit, Some(7))
  match opts.state {
    Some(@hub.IssueState::Closed) => ()
    _ => fail("expected closed state")
  }
  let opts2 = parse_hub_issue_list_options(["-L", "2", "--open"])
  assert_eq(opts2.limit, Some(2))
  match opts2.state {
    Some(@hub.IssueState::Open) => ()
    _ => fail("expected open state")
  }
}

///|
test "hub parser: parse_hub_work_item_list_options handles filters and limit" {
  let opts = parse_hub_work_item_list_options([
    "--closed", "--kind", "issue", "--limit", "4",
  ])
  assert_eq(opts.limit, Some(4))
  match opts.state {
    Some(@hub.WorkItemState::Closed) => ()
    _ => fail("expected closed state")
  }
  match opts.kind {
    Some(@hub.WorkItemKind::Issue) => ()
    _ => fail("expected issue kind")
  }
  let opts2 = parse_hub_work_item_list_options(["-L", "2", "--pr", "--open"])
  assert_eq(opts2.limit, Some(2))
  match opts2.kind {
    Some(@hub.WorkItemKind::PullRequest) => ()
    _ => fail("expected pull request kind")
  }
  match opts2.state {
    Some(@hub.WorkItemState::Open) => ()
    _ => fail("expected open state")
  }
}

///|
test "hub parser: parse_hub_pr_list_options rejects invalid limit" {
  ignore(
    parse_hub_pr_list_options(["--limit", "0"]) catch {
      @git.GitError::InvalidObject(message) => {
        assert_true(message.contains("Limit must be positive"))
        return ()
      }
      err => fail("unexpected error: \{err.to_string()}")
    },
  )
  fail("expected invalid object error")
}

///|
test "hub parser: parse_hub_issue_list_options rejects missing limit value" {
  ignore(
    parse_hub_issue_list_options(["-L"]) catch {
      @git.GitError::InvalidObject(message) => {
        assert_true(message.contains("--limit requires a value"))
        return ()
      }
      err => fail("unexpected error: \{err.to_string()}")
    },
  )
  fail("expected invalid object error")
}

///|
test "hub parser: parse_hub_work_item_list_options rejects unknown kind" {
  ignore(
    parse_hub_work_item_list_options(["--kind", "review"]) catch {
      @git.GitError::InvalidObject(message) => {
        assert_true(message.contains("Unknown work item kind"))
        return ()
      }
      err => fail("unexpected error: \{err.to_string()}")
    },
  )
  fail("expected invalid object error")
}

///|
async test "hub parser: parse_hub_pr_create_options accepts positional source/target" {
  let options = parse_hub_pr_create_options(
    ["--title", "Add feature", "feature", "main"],
    "hub pr create",
  )
  assert_eq(options.title, "Add feature")
  assert_eq(options.body, "")
  assert_eq(options.source_branch, "feature")
  assert_eq(options.target_branch, "main")
  assert_eq(options.source_repo, None)
  assert_eq(options.source_ref, None)
}

///|
async test "hub parser: parse_hub_pr_create_options rejects missing title value" {
  ignore(
    parse_hub_pr_create_options(["--title"], "hub pr create") catch {
      @git.GitError::InvalidObject(message) => {
        assert_true(message.contains("--title requires a value"))
        return ()
      }
      err => fail("unexpected error: \{err.to_string()}")
    },
  )
  fail("expected invalid object error")
}

///|
async test "hub pr update: --label requires a value" {
  handle_hub_pr_update(["123", "--label"]) catch {
    @git.GitError::InvalidObject(message) => {
      assert_true(message.contains("--label requires a value"))
      return ()
    }
    err => fail("unexpected error: \{err.to_string()}")
  }
  fail("expected invalid object error")
}

///|
async test "hub pr review submit: --verdict requires a value" {
  handle_hub_pr_review_submit(["123", "--verdict"]) catch {
    @git.GitError::InvalidObject(message) => {
      assert_true(message.contains("--verdict requires a value"))
      return ()
    }
    err => fail("unexpected error: \{err.to_string()}")
  }
  fail("expected invalid object error")
}

///|
async test "hub pr review submit: --commit requires a value" {
  handle_hub_pr_review_submit(["123", "--approve", "--commit"]) catch {
    @git.GitError::InvalidObject(message) => {
      assert_true(message.contains("--commit requires a value"))
      return ()
    }
    err => fail("unexpected error: \{err.to_string()}")
  }
  fail("expected invalid object error")
}

///|
test "hub dump parser: defaults" {
  let opts = parse_hub_dump_options([])
  assert_eq(opts.prefix, "hub/")
  assert_false(opts.raw)
  assert_false(opts.include_deleted)
}

///|
test "hub dump parser: options and positional prefix" {
  let opts1 = parse_hub_dump_options([
    "--prefix", "hub/pr/", "--raw", "--include-deleted",
  ])
  assert_eq(opts1.prefix, "hub/pr/")
  assert_true(opts1.raw)
  assert_true(opts1.include_deleted)
  let opts2 = parse_hub_dump_options(["hub/issue/"])
  assert_eq(opts2.prefix, "hub/issue/")
  assert_false(opts2.raw)
  assert_false(opts2.include_deleted)
}

///|
test "hub dump parser: --prefix requires value" {
  ignore(
    parse_hub_dump_options(["--prefix"]) catch {
      @git.GitError::InvalidObject(message) => {
        assert_true(message.contains("--prefix requires a value"))
        return ()
      }
      err => fail("unexpected error: \{err.to_string()}")
    },
  )
  fail("expected invalid object error")
}

///|
test "hub dump parser: unknown option fails" {
  ignore(
    parse_hub_dump_options(["--unknown"]) catch {
      @git.GitError::InvalidObject(message) => {
        assert_true(message.contains("Unknown hub dump option"))
        return ()
      }
      err => fail("unexpected error: \{err.to_string()}")
    },
  )
  fail("expected invalid object error")
}

///|
test "hub dump summary: includes key and kind" {
  let record = @hub.HubRecord::new(
    "hub/pr/1/meta", "pr", "payload", "node-a", 10L,
  )
  let out = format_hub_record_summary(record)
  assert_true(out.contains("kind=pr"))
  assert_true(out.contains("key=hub/pr/1/meta"))
}

///|
test "hub search parser: defaults" {
  let opts = parse_hub_search_options([])
  assert_true(opts.query is None)
  assert_true(hub_search_has_type(opts.types, HubSearchType::Pr))
  assert_true(hub_search_has_type(opts.types, HubSearchType::Issue))
  assert_true(hub_search_has_type(opts.types, HubSearchType::PrComment))
  assert_true(hub_search_has_type(opts.types, HubSearchType::PrReview))
  assert_true(hub_search_has_type(opts.types, HubSearchType::IssueComment))
  assert_true(opts.state is None)
  assert_true(opts.author is None)
  assert_eq(opts.labels.length(), 0)
  assert_true(opts.limit is None)
}

///|
test "hub search parser: parse query and filters" {
  let opts = parse_hub_search_options([
    "--type", "pr,issue", "--state", "open", "--author", "alice", "--label", "bug",
    "--limit", "3", "hello", "world",
  ])
  guard opts.query is Some(q) else { fail("expected query") }
  assert_eq(q, "hello world")
  assert_eq(opts.types.length(), 2)
  assert_true(hub_search_has_type(opts.types, HubSearchType::Pr))
  assert_true(hub_search_has_type(opts.types, HubSearchType::Issue))
  guard opts.state is Some(state) else { fail("expected state") }
  assert_eq(state, "open")
  guard opts.author is Some(author) else { fail("expected author") }
  assert_eq(author, "alice")
  assert_eq(opts.labels.length(), 1)
  assert_eq(opts.labels[0], "bug")
  guard opts.limit is Some(limit) else { fail("expected limit") }
  assert_eq(limit, 3)
}

///|
test "hub search parser: reject unknown type" {
  ignore(
    parse_hub_search_options(["--type", "unknown"]) catch {
      @git.GitError::InvalidObject(message) => {
        assert_true(message.contains("Unknown hub search type"))
        return ()
      }
      err => fail("unexpected error: \{err.to_string()}")
    },
  )
  fail("expected invalid object error")
}

///|
test "hub search parser: reject unknown state" {
  ignore(
    parse_hub_search_options(["--state", "draft"]) catch {
      @git.GitError::InvalidObject(message) => {
        assert_true(message.contains("Unknown hub search state"))
        return ()
      }
      err => fail("unexpected error: \{err.to_string()}")
    },
  )
  fail("expected invalid object error")
}

///|
async test "hub pr list: --state requires a value" {
  handle_hub_pr_list(["--state"]) catch {
    @git.GitError::InvalidObject(message) => {
      assert_true(message.contains("--state requires a value"))
      return ()
    }
    err => fail("unexpected error: \{err.to_string()}")
  }
  fail("expected invalid object error")
}

///|
async test "hub issue list: --state requires a value" {
  handle_hub_issue_list(["--state"]) catch {
    @git.GitError::InvalidObject(message) => {
      assert_true(message.contains("--state requires a value"))
      return ()
    }
    err => fail("unexpected error: \{err.to_string()}")
  }
  fail("expected invalid object error")
}

///|
async test "hub pr import: --limit requires a value" {
  handle_hub_pr_import(["--limit"]) catch {
    @git.GitError::InvalidObject(message) => {
      assert_true(message.contains("--limit requires a value"))
      return ()
    }
    err => fail("unexpected error: \{err.to_string()}")
  }
  fail("expected invalid object error")
}

///|
async test "hub issue import: --limit requires a value" {
  handle_hub_issue_import(["--limit"]) catch {
    @git.GitError::InvalidObject(message) => {
      assert_true(message.contains("--limit requires a value"))
      return ()
    }
    err => fail("unexpected error: \{err.to_string()}")
  }
  fail("expected invalid object error")
}

///|
test "hub import provider parser: gh and json-file aliases" {
  match parse_github_import_provider("gh") {
    Some(GitHubImportProvider::GhCli) => ()
    _ => fail("expected gh provider")
  }
  match parse_github_import_provider("gh-cli") {
    Some(GitHubImportProvider::GhCli) => ()
    _ => fail("expected gh-cli provider")
  }
  match parse_github_import_provider("json-file") {
    Some(GitHubImportProvider::JsonFile) => ()
    _ => fail("expected json-file provider")
  }
  match parse_github_import_provider("file") {
    Some(GitHubImportProvider::JsonFile) => ()
    _ => fail("expected file provider")
  }
  match parse_github_import_provider("unknown") {
    None => ()
    _ => fail("expected unknown provider to be rejected")
  }
}

///|
async test "hub pr import: --provider requires a value" {
  handle_hub_pr_import(["--provider"]) catch {
    @git.GitError::InvalidObject(message) => {
      assert_true(message.contains("--provider requires a value"))
      return ()
    }
    err => fail("unexpected error: \{err.to_string()}")
  }
  fail("expected invalid object error")
}

///|
async test "hub pr import: unknown provider fails" {
  handle_hub_pr_import(["--provider", "unknown"]) catch {
    @git.GitError::InvalidObject(message) => {
      assert_true(message.contains("Unknown GitHub import provider"))
      return ()
    }
    err => fail("unexpected error: \{err.to_string()}")
  }
  fail("expected invalid object error")
}

///|
async test "hub pr import: json-file provider requires --input" {
  handle_hub_pr_import(["--provider", "json-file"]) catch {
    @git.GitError::InvalidObject(message) => {
      assert_true(message.contains("--input requires a file path"))
      return ()
    }
    err => fail("unexpected error: \{err.to_string()}")
  }
  fail("expected invalid object error")
}

///|
async test "hub issue import: --input requires a value" {
  handle_hub_issue_import(["--provider", "json-file", "--input"]) catch {
    @git.GitError::InvalidObject(message) => {
      assert_true(message.contains("--input requires a value"))
      return ()
    }
    err => fail("unexpected error: \{err.to_string()}")
  }
  fail("expected invalid object error")
}

///|
test "hub parser: parse_gh_prs rejects missing branch names" {
  let payload =
    #|[{
    #|  "id": "1",
    #|  "title": "demo",
    #|  "body": "",
    #|  "source_commit": "1111111111111111111111111111111111111111",
    #|  "target_commit": "2222222222222222222222222222222222222222"
    #|}]
  ignore(
    parse_gh_prs(payload) catch {
      @git.GitError::InvalidObject(message) => {
        assert_true(message.contains("Missing branch name"))
        return ()
      }
      err => fail("unexpected error: \{err.to_string()}")
    },
  )
  fail("expected invalid object error")
}

///|
test "hub parser: parse_gh_prs captures source repo/ref" {
  let payload =
    #|[{
    #|  "id": "7",
    #|  "title": "fork pr",
    #|  "body": "body",
    #|  "source_branch": "feature",
    #|  "source_ref": "refs/heads/feature",
    #|  "source_repo": "contrib/bit",
    #|  "source_commit": "1111111111111111111111111111111111111111",
    #|  "target_branch": "main",
    #|  "target_commit": "2222222222222222222222222222222222222222",
    #|  "author": "contrib",
    #|  "created_at": 1,
    #|  "updated_at": 2,
    #|  "state": "open",
    #|  "labels": []
    #|}]
  let prs = parse_gh_prs(payload)
  assert_eq(prs.length(), 1)
  let pr = prs[0]
  guard pr.source_repo() is Some(source_repo) else {
    fail("missing source_repo")
  }
  assert_eq(source_repo, "contrib/bit")
  guard pr.source_ref() is Some(source_ref) else { fail("missing source_ref") }
  assert_eq(source_ref, "refs/heads/feature")
}

///|
test "hub parser: parse_gh_issues rejects non-array JSON" {
  ignore(
    parse_gh_issues("{}") catch {
      @git.GitError::InvalidObject(message) => {
        assert_true(message.contains("Expected JSON array"))
        return ()
      }
      err => fail("unexpected error: \{err.to_string()}")
    },
  )
  fail("expected invalid object error")
}

///|
test "hub merge policy parser: defaults without explicit values" {
  let policy = parse_hub_merge_policy_toml("")
  assert_eq(policy.required_approvals(), 0)
  assert_true(policy.allow_request_changes())
  assert_false(policy.require_signed_records())
}

///|
test "hub merge policy parser: parse merge section values" {
  let policy_text =
    #|[merge]
    #|required_approvals = 2
    #|allow_request_changes = false
    #|require_signed_records = true
    #|required_workflows = ["test", "lint"]
  let policy = parse_hub_merge_policy_toml(policy_text)
  assert_eq(policy.required_approvals(), 2)
  assert_false(policy.allow_request_changes())
  assert_true(policy.require_signed_records())
  assert_eq(policy.required_workflows().length(), 2)
  assert_eq(policy.required_workflows()[0], "test")
  assert_eq(policy.required_workflows()[1], "lint")
}

///|
test "hub merge policy parser: reject negative required approvals" {
  let policy_text =
    #|[merge]
    #|required_approvals = -1
  ignore(
    parse_hub_merge_policy_toml(policy_text) catch {
      @git.GitError::InvalidObject(message) => {
        assert_true(message.contains("required_approvals"))
        return ()
      }
      err => fail("unexpected error: \{err.to_string()}")
    },
  )
  fail("expected invalid object error")
}

///|
test "hub merge policy parser: reject non-array required_workflows" {
  let policy_text =
    #|[merge]
    #|required_workflows = "test"
  ignore(
    parse_hub_merge_policy_toml(policy_text) catch {
      @git.GitError::InvalidObject(message) => {
        assert_true(message.contains("required_workflows"))
        return ()
      }
      err => fail("unexpected error: \{err.to_string()}")
    },
  )
  fail("expected invalid object error")
}

///|
test "hub sync parser: parse remote and auth/signing overrides" {
  let options = parse_hub_sync_runtime_options(
    [
      "--auth-token", "token-1", "--signing-key", "k1", "--require-signed", "relay+http://127.0.0.1:8787",
    ],
    default_remote_url=Some("https://origin.example/repo.git"),
  )
  assert_eq(options.remote_url, Some("relay+http://127.0.0.1:8787"))
  assert_eq(options.auth_token, Some("token-1"))
  assert_eq(options.signing_key, Some("k1"))
  assert_eq(options.require_signed, Some(true))
}

///|
test "hub sync parser: defaults to configured remote and allows unsigned override" {
  let options = parse_hub_sync_runtime_options(
    ["--allow-unsigned"],
    default_remote_url=Some("https://origin.example/repo.git"),
  )
  assert_eq(options.remote_url, Some("https://origin.example/repo.git"))
  assert_eq(options.require_signed, Some(false))
  assert_eq(options.auth_token, None)
  assert_eq(options.signing_key, None)
}

///|
test "hub sync parser: parses conflict policy option" {
  let options = parse_hub_sync_runtime_options(
    ["--conflict-policy", "tombstone-wins"],
    default_remote_url=Some("https://origin.example/repo.git"),
  )
  assert_eq(options.remote_url, Some("https://origin.example/repo.git"))
  match options.conflict_policy {
    Some(@hub.RecordMergePolicy::TombstoneWins) => ()
    _ => fail("expected tombstone-wins policy")
  }
}

///|
test "hub sync parser: invalid conflict policy value fails" {
  ignore(
    parse_hub_sync_runtime_options(["--conflict-policy", "unknown"]) catch {
      @git.GitError::InvalidObject(message) => {
        assert_true(message.contains("Unknown hub conflict policy"))
        return ()
      }
      err => fail("unexpected error: \{err.to_string()}")
    },
  )
  fail("expected invalid object error")
}

///|
test "hub sync parser: --sign-key alias parses inline value" {
  let options = parse_hub_sync_runtime_options([
    "--sign-key=key-1", "relay+http://127.0.0.1:8787",
  ])
  assert_eq(options.signing_key, Some("key-1"))
  assert_eq(options.remote_url, Some("relay+http://127.0.0.1:8787"))
}

///|
test "hub sync parser: rejects unknown option" {
  ignore(
    parse_hub_sync_runtime_options(["--unknown"]) catch {
      @git.GitError::InvalidObject(message) => {
        assert_true(message.contains("Unknown hub sync option"))
        return ()
      }
      err => fail("unexpected error: \{err.to_string()}")
    },
  )
  fail("expected invalid object error")
}

///|
test "hub notify: select_notify_records filters notify-only records" {
  let canonical = @hub.HubRecord::new(
    "hub/pr/1/meta", "pr", "canonical", "node-a", 1L,
  )
  let proposal = @hub.HubRecord::new(
    "hub/proposal/pr/p1/meta", "pr-proposal", "proposal", "node-b", 2L,
  )
  let selected = select_notify_records([canonical, proposal])
  assert_eq(selected.length(), 1)
  assert_true(selected.contains("hub/proposal/pr/p1/meta"))
}

///|
test "hub notify: collect_changed_notify_records detects new and updated" {
  let before : Map[String, @hub.HubRecord] = {}
  before["hub/proposal/pr/p1/meta"] = @hub.HubRecord::new(
    "hub/proposal/pr/p1/meta", "pr-proposal", "old", "node-a", 1L,
  )
  let after : Map[String, @hub.HubRecord] = {}
  after["hub/proposal/pr/p1/meta"] = @hub.HubRecord::new(
    "hub/proposal/pr/p1/meta", "pr-proposal", "new", "node-a", 2L,
  )
  after["hub/proposal/pr/p2/meta"] = @hub.HubRecord::new(
    "hub/proposal/pr/p2/meta", "pr-proposal", "created", "node-b", 3L,
  )
  let changed = collect_changed_notify_records(before, after)
  assert_eq(changed.length(), 2)
  assert_eq(changed[0].key, "hub/proposal/pr/p1/meta")
  assert_eq(changed[1].key, "hub/proposal/pr/p2/meta")
}

///|
test "hub notify: format_hub_notify_message handles hub.pr.proposal" {
  let proposal = @hub.PullRequest::new(
    "p-1",
    "External Proposal",
    "Body",
    "refs/heads/feature",
    @git.ObjectId::zero(),
    "refs/heads/main",
    @git.ObjectId::zero(),
    "peer-user",
    10L,
    10L,
    @hub.PrState::Open,
    [],
  )
  let record = @hub.HubRecord::new(
    @hub.pr_proposal_meta_key("p-1"),
    "pr-proposal",
    proposal.serialize(),
    "peer-node",
    10L,
  )
  let message = format_hub_notify_message("hub.pr.proposal", record)
  assert_true(message.contains("hub.pr.proposal"))
  assert_true(message.contains("#p-1"))
  assert_true(message.contains("External Proposal"))
  assert_eq(
    format_hub_notify_message("hub.other", record),
    "[hub.notify] hub.other key=hub/proposal/pr/p-1/meta",
  )
}

///|
test "hub format: format_work_item_summary includes kind and state" {
  let item = @hub.WorkItem::new(
    "w1",
    "Unified title",
    "body",
    "alice",
    1L,
    2L,
    @hub.WorkItemState::Open,
  )
  let out = format_work_item_summary(item)
  assert_true(out.contains("#w1"))
  assert_true(out.contains("[issue/open]"))
  assert_true(out.contains("Unified title"))
}

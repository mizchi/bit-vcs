///|
test "collab parser: parse_pr_state handles known and unknown values" {
  assert_eq(parse_pr_state("open"), Some(@collab.PrState::Open))
  assert_eq(parse_pr_state("closed"), Some(@collab.PrState::Closed))
  assert_eq(parse_pr_state("merged"), Some(@collab.PrState::Merged))
  assert_eq(parse_pr_state("draft"), None)
}

///|
test "collab parser: parse_issue_state handles known and unknown values" {
  assert_eq(parse_issue_state("open"), Some(@collab.IssueState::Open))
  assert_eq(parse_issue_state("closed"), Some(@collab.IssueState::Closed))
  assert_eq(parse_issue_state("draft"), None)
}

///|
test "collab parser: parse_review_verdict handles known and unknown values" {
  assert_eq(
    parse_review_verdict("approved"),
    Some(@collab.ReviewVerdict::Approved),
  )
  assert_eq(
    parse_review_verdict("comment"),
    Some(@collab.ReviewVerdict::Comment),
  )
  assert_eq(
    parse_review_verdict("request-changes"),
    Some(@collab.ReviewVerdict::RequestChanges),
  )
  assert_eq(parse_review_verdict("reject"), None)
}

///|
test "collab parser: parse_merge_strategy handles known and unknown values" {
  match parse_merge_strategy("merge") {
    Some(@collab.PrMergeStrategy::Merge) => ()
    _ => fail("expected merge strategy")
  }
  match parse_merge_strategy("squash") {
    Some(@collab.PrMergeStrategy::Squash) => ()
    _ => fail("expected squash strategy")
  }
  match parse_merge_strategy("ff") {
    Some(@collab.PrMergeStrategy::FastForward) => ()
    _ => fail("expected ff strategy")
  }
  match parse_merge_strategy("rebase") {
    None => ()
    _ => fail("unexpected strategy")
  }
}

///|
test "collab dump parser: defaults" {
  let opts = parse_collab_dump_options([])
  assert_eq(opts.prefix, "collab/")
  assert_false(opts.raw)
  assert_false(opts.include_deleted)
}

///|
test "collab dump parser: options and positional prefix" {
  let opts1 = parse_collab_dump_options([
    "--prefix", "collab/pr/", "--raw", "--include-deleted",
  ])
  assert_eq(opts1.prefix, "collab/pr/")
  assert_true(opts1.raw)
  assert_true(opts1.include_deleted)
  let opts2 = parse_collab_dump_options(["collab/issue/"])
  assert_eq(opts2.prefix, "collab/issue/")
  assert_false(opts2.raw)
  assert_false(opts2.include_deleted)
}

///|
test "collab dump parser: --prefix requires value" {
  ignore(
    parse_collab_dump_options(["--prefix"]) catch {
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
test "collab dump parser: unknown option fails" {
  ignore(
    parse_collab_dump_options(["--unknown"]) catch {
      @git.GitError::InvalidObject(message) => {
        assert_true(message.contains("Unknown collab dump option"))
        return ()
      }
      err => fail("unexpected error: \{err.to_string()}")
    },
  )
  fail("expected invalid object error")
}

///|
test "collab dump summary: includes key and kind" {
  let record = @collab.CollabRecord::new(
    "collab/pr/1/meta", "pr", "payload", "node-a", 10L,
  )
  let out = format_collab_record_summary(record)
  assert_true(out.contains("kind=pr"))
  assert_true(out.contains("key=collab/pr/1/meta"))
}

///|
async test "collab pr list: --state requires a value" {
  handle_collab_pr_list(["--state"]) catch {
    @git.GitError::InvalidObject(message) => {
      assert_true(message.contains("--state requires a value"))
      return ()
    }
    err => fail("unexpected error: \{err.to_string()}")
  }
  fail("expected invalid object error")
}

///|
async test "collab issue list: --state requires a value" {
  handle_collab_issue_list(["--state"]) catch {
    @git.GitError::InvalidObject(message) => {
      assert_true(message.contains("--state requires a value"))
      return ()
    }
    err => fail("unexpected error: \{err.to_string()}")
  }
  fail("expected invalid object error")
}

///|
async test "collab pr import: --limit requires a value" {
  handle_collab_pr_import(["--limit"]) catch {
    @git.GitError::InvalidObject(message) => {
      assert_true(message.contains("--limit requires a value"))
      return ()
    }
    err => fail("unexpected error: \{err.to_string()}")
  }
  fail("expected invalid object error")
}

///|
async test "collab issue import: --limit requires a value" {
  handle_collab_issue_import(["--limit"]) catch {
    @git.GitError::InvalidObject(message) => {
      assert_true(message.contains("--limit requires a value"))
      return ()
    }
    err => fail("unexpected error: \{err.to_string()}")
  }
  fail("expected invalid object error")
}

///|
test "collab parser: parse_gh_prs rejects missing branch names" {
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
test "collab parser: parse_gh_prs captures source repo/ref" {
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
test "collab parser: parse_gh_issues rejects non-array JSON" {
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

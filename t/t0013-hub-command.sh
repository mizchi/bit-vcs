#!/bin/bash
#
# e2e: hub command basics (PR/Issue lifecycle)

source "$(dirname "$0")/test-lib-e2e.sh"

test_expect_success 'hub help shows usage' '
    git_cmd hub | grep -q "Usage: bit hub <subcommand>"
'

test_expect_success 'hub init creates default merge policy file' '
    git_cmd init &&
    git_cmd hub init >/dev/null &&
    test_file_exists .git/hub/policy.toml &&
    grep -q "required_approvals = 0" .git/hub/policy.toml &&
    grep -q "allow_request_changes = true" .git/hub/policy.toml &&
    grep -q "require_signed_records = false" .git/hub/policy.toml
'

test_expect_success 'hub issue lifecycle: create close reopen' '
    git_cmd init &&
    git_cmd hub init >/dev/null &&
    issue_out=$(git_cmd hub issue create --title "Hub issue" --body "Body") &&
    issue_id=$(printf "%s\n" "$issue_out" | head -n1 | cut -d" " -f2) &&
    test -n "$issue_id" &&
    git_cmd hub issue list --open | grep -q "Hub issue" &&
    git_cmd hub issue close "$issue_id" >/dev/null &&
    git_cmd hub issue list --closed | grep -q "Hub issue" &&
    git_cmd hub issue reopen "$issue_id" >/dev/null &&
    git_cmd hub issue list --open | grep -q "Hub issue"
'

test_expect_success 'hub pr lifecycle: create close reopen status' '
    git_cmd init &&
    echo "base" > README.md &&
    git_cmd add README.md &&
    git_cmd commit -m "base" &&
    git_cmd checkout -b feature/hub &&
    echo "feature" > feature.txt &&
    git_cmd add feature.txt &&
    git_cmd commit -m "feature" &&
    git_cmd hub init >/dev/null &&
    pr_out=$(git_cmd hub pr create --title "Hub PR" --body "Body" --head refs/heads/feature/hub --base refs/heads/main) &&
    pr_id=$(printf "%s\n" "$pr_out" | head -n1 | cut -d" " -f2) &&
    test -n "$pr_id" &&
    git_cmd hub pr list --open | grep -q "Hub PR" &&
    git_cmd hub pr close "$pr_id" >/dev/null &&
    git_cmd hub pr list --closed | grep -q "Hub PR" &&
    git_cmd hub pr reopen "$pr_id" >/dev/null &&
    git_cmd hub pr list --open | grep -q "Hub PR" &&
    git_cmd hub pr status | grep -q "Current branch: feature/hub" &&
    git_cmd hub pr status | grep -q "Hub PR"
'

test_expect_success 'pr/issue shortcuts continue to work with hub surface' '
    git_cmd init &&
    git_cmd hub init >/dev/null &&
    git_cmd issue list | grep -q "No issues" &&
    git_cmd pr list | grep -q "No pull requests"
'

test_expect_success 'hub pr proposal: propose/list/import keeps canonical PRs separated' '
    git_cmd init &&
    echo "base" > README.md &&
    git_cmd add README.md &&
    git_cmd commit -m "base" &&
    git_cmd checkout -b feature/proposal &&
    echo "proposal" > proposal.txt &&
    git_cmd add proposal.txt &&
    git_cmd commit -m "proposal" &&
    git_cmd hub init >/dev/null &&
    proposal_out=$(git_cmd hub pr propose --title "Proposal PR" --body "Body" --head refs/heads/feature/proposal --base refs/heads/main) &&
    proposal_id=$(printf "%s\n" "$proposal_out" | head -n1 | cut -d" " -f2) &&
    test -n "$proposal_id" &&
    git_cmd hub pr proposals | grep -q "Proposal PR" &&
    git_cmd hub pr list --open | grep -q "No pull requests" &&
    git_cmd hub pr import-proposal "$proposal_id" >/dev/null &&
    git_cmd hub pr list --open | grep -q "Proposal PR"
'

test_expect_success 'hub pr merge policy: required approvals blocks and then allows merge after approval' '
    git_cmd init &&
    echo "base" > README.md &&
    git_cmd add README.md &&
    git_cmd commit -m "base" &&
    git_cmd checkout -b feature/policy-approve &&
    echo "feature" > policy.txt &&
    git_cmd add policy.txt &&
    git_cmd commit -m "feature" &&
    git_cmd hub init >/dev/null &&
    cat > .git/hub/policy.toml <<-\EOF &&
[merge]
required_approvals = 1
allow_request_changes = true
require_signed_records = false
EOF
    pr_out=$(git_cmd hub pr create --title "Policy PR" --body "Body" --head refs/heads/feature/policy-approve --base refs/heads/main) &&
    pr_id=$(printf "%s\n" "$pr_out" | head -n1 | cut -d" " -f2) &&
    test -n "$pr_id" &&
    if git_cmd hub pr merge "$pr_id" >merge.out 2>merge.err; then
        false
    else
        grep -q "required approvals=1" merge.err
    fi &&
    source_commit=$(git_cmd rev-parse refs/heads/feature/policy-approve) &&
    git_cmd hub pr review "$pr_id" --approve --commit "$source_commit" >/dev/null &&
    git_cmd hub pr merge "$pr_id" >/dev/null &&
    git_cmd hub pr list --merged | grep -q "Policy PR"
'

test_expect_success 'hub pr merge policy: request-changes can block merge' '
    git_cmd init &&
    echo "base" > README.md &&
    git_cmd add README.md &&
    git_cmd commit -m "base" &&
    git_cmd checkout -b feature/policy-rc &&
    echo "feature" > blocked.txt &&
    git_cmd add blocked.txt &&
    git_cmd commit -m "feature" &&
    git_cmd hub init >/dev/null &&
    cat > .git/hub/policy.toml <<-\EOF &&
[merge]
required_approvals = 0
allow_request_changes = false
require_signed_records = false
EOF
    pr_out=$(git_cmd hub pr create --title "Blocked PR" --body "Body" --head refs/heads/feature/policy-rc --base refs/heads/main) &&
    pr_id=$(printf "%s\n" "$pr_out" | head -n1 | cut -d" " -f2) &&
    test -n "$pr_id" &&
    source_commit=$(git_cmd rev-parse refs/heads/feature/policy-rc) &&
    git_cmd hub pr review "$pr_id" --request-changes --commit "$source_commit" >/dev/null &&
    if git_cmd hub pr merge "$pr_id" >merge.out 2>merge.err; then
        false
    else
        grep -q "request-changes review is present" merge.err
    fi
'

test_expect_success 'hub pr merge policy: require_signed_records fails without signing key' '
    git_cmd init &&
    echo "base" > README.md &&
    git_cmd add README.md &&
    git_cmd commit -m "base" &&
    git_cmd checkout -b feature/policy-signed &&
    echo "feature" > unsigned.txt &&
    git_cmd add unsigned.txt &&
    git_cmd commit -m "feature" &&
    git_cmd hub init >/dev/null &&
    cat > .git/hub/policy.toml <<-\EOF &&
[merge]
required_approvals = 0
allow_request_changes = true
require_signed_records = true
EOF
    pr_out=$(git_cmd hub pr create --title "Signed PR" --body "Body" --head refs/heads/feature/policy-signed --base refs/heads/main) &&
    pr_id=$(printf "%s\n" "$pr_out" | head -n1 | cut -d" " -f2) &&
    test -n "$pr_id" &&
    if git_cmd hub pr merge "$pr_id" >merge.out 2>merge.err; then
        false
    else
        grep -q "BIT_COLLAB_SIGN_KEY" merge.err
    fi
'

test_expect_success 'hub pr merge policy: require_signed_records allows merge with matching signing key' '
    git_cmd init &&
    echo "base" > README.md &&
    git_cmd add README.md &&
    git_cmd commit -m "base" &&
    git_cmd checkout -b feature/policy-signed-ok &&
    echo "feature" > signed-ok.txt &&
    git_cmd add signed-ok.txt &&
    git_cmd commit -m "feature" &&
    BIT_COLLAB_SIGN_KEY=sign-key-1 git_cmd hub init >/dev/null &&
    cat > .git/hub/policy.toml <<-\EOF &&
[merge]
required_approvals = 0
allow_request_changes = true
require_signed_records = true
EOF
    pr_out=$(BIT_COLLAB_SIGN_KEY=sign-key-1 git_cmd hub pr create --title "Signed OK PR" --body "Body" --head refs/heads/feature/policy-signed-ok --base refs/heads/main) &&
    pr_id=$(printf "%s\n" "$pr_out" | head -n1 | cut -d" " -f2) &&
    test -n "$pr_id" &&
    BIT_COLLAB_SIGN_KEY=sign-key-1 git_cmd hub pr merge "$pr_id" >/dev/null &&
    git_cmd hub pr list --merged | grep -q "Signed OK PR"
'

test_expect_success 'hub pr merge policy: require_signed_records rejects merge with wrong signing key' '
    git_cmd init &&
    echo "base" > README.md &&
    git_cmd add README.md &&
    git_cmd commit -m "base" &&
    git_cmd checkout -b feature/policy-signed-wrong &&
    echo "feature" > signed-wrong.txt &&
    git_cmd add signed-wrong.txt &&
    git_cmd commit -m "feature" &&
    BIT_COLLAB_SIGN_KEY=writer-key git_cmd hub init >/dev/null &&
    cat > .git/hub/policy.toml <<-\EOF &&
[merge]
required_approvals = 0
allow_request_changes = true
require_signed_records = true
EOF
    pr_out=$(BIT_COLLAB_SIGN_KEY=writer-key git_cmd hub pr create --title "Signed Wrong Key PR" --body "Body" --head refs/heads/feature/policy-signed-wrong --base refs/heads/main) &&
    pr_id=$(printf "%s\n" "$pr_out" | head -n1 | cut -d" " -f2) &&
    test -n "$pr_id" &&
    if BIT_COLLAB_SIGN_KEY=reader-key git_cmd hub pr merge "$pr_id" >merge.out 2>merge.err; then
        false
    else
        grep -q "PR not found" merge.err
    fi
'

test_expect_success 'hub pr merge policy: require_signed_records + required_workflows ignores unsigned workflow records' '
    git_cmd init &&
    echo "base" > README.md &&
    git_cmd add README.md &&
    git_cmd commit -m "base" &&
    git_cmd checkout -b feature/policy-signed-workflow &&
    echo "feature" > signed-workflow.txt &&
    git_cmd add signed-workflow.txt &&
    git_cmd commit -m "feature" &&
    BIT_COLLAB_SIGN_KEY=sign-key-2 git_cmd hub init >/dev/null &&
    cat > .git/hub/policy.toml <<-\EOF &&
[merge]
required_approvals = 0
allow_request_changes = true
require_signed_records = true
required_workflows = ["test"]
EOF
    pr_out=$(BIT_COLLAB_SIGN_KEY=sign-key-2 git_cmd hub pr create --title "Signed Workflow PR" --body "Body" --head refs/heads/feature/policy-signed-workflow --base refs/heads/main) &&
    pr_id=$(printf "%s\n" "$pr_out" | head -n1 | cut -d" " -f2) &&
    test -n "$pr_id" &&
    git_cmd hub pr workflow submit "$pr_id" --task test --status success --fingerprint fp-unsigned --txn txn-unsigned >/dev/null &&
    if BIT_COLLAB_SIGN_KEY=sign-key-2 git_cmd hub pr merge "$pr_id" >merge.out 2>merge.err; then
        false
    else
        grep -q "required workflow '\''test'\'' has no result" merge.err
    fi &&
    BIT_COLLAB_SIGN_KEY=sign-key-2 git_cmd hub pr workflow submit "$pr_id" --task test --status success --fingerprint fp-signed --txn txn-signed >/dev/null &&
    BIT_COLLAB_SIGN_KEY=sign-key-2 git_cmd hub pr merge "$pr_id" >/dev/null &&
    git_cmd hub pr list --merged | grep -q "Signed Workflow PR"
'

test_expect_success 'hub pr merge policy: required_workflows blocks until workflow success is recorded' '
    git_cmd init &&
    echo "base" > README.md &&
    git_cmd add README.md &&
    git_cmd commit -m "base" &&
    git_cmd checkout -b feature/policy-workflow &&
    echo "feature" > workflow.txt &&
    git_cmd add workflow.txt &&
    git_cmd commit -m "feature" &&
    git_cmd checkout main &&
    git_cmd hub init >/dev/null &&
    cat > .git/hub/policy.toml <<-\EOF &&
[merge]
required_approvals = 0
allow_request_changes = true
require_signed_records = false
required_workflows = ["test"]
EOF
    pr_out=$(git_cmd hub pr create --title "Workflow PR" --body "Body" --head refs/heads/feature/policy-workflow --base refs/heads/main) &&
    pr_id=$(printf "%s\n" "$pr_out" | head -n1 | cut -d" " -f2) &&
    test -n "$pr_id" &&
    if git_cmd hub pr merge "$pr_id" >merge.out 2>merge.err; then
        false
    else
        grep -q "required workflow" merge.err
    fi &&
    git_cmd hub pr workflow submit "$pr_id" --task test --status failed --fingerprint fp-failed --txn txn-failed >/dev/null &&
    if git_cmd hub pr merge "$pr_id" >merge2.out 2>merge2.err; then
        false
    else
        grep -q "status=failed" merge2.err
    fi &&
    git_cmd hub pr workflow submit "$pr_id" --task test --status success --fingerprint fp-success --txn txn-success >/dev/null &&
    workflow_list=$(git_cmd hub pr workflow list "$pr_id") &&
    printf "%s\n" "$workflow_list" | grep -q "task=test" &&
    printf "%s\n" "$workflow_list" | grep -q "status=success" &&
    printf "%s\n" "$workflow_list" | grep -q "fingerprint=fp-success" &&
    git_cmd hub pr merge "$pr_id" >/dev/null &&
    git_cmd hub pr list --merged | grep -q "Workflow PR"
'

test_expect_success 'hub search: query and type filter' '
    git_cmd init &&
    echo "base" > README.md &&
    git_cmd add README.md &&
    git_cmd commit -m "base" &&
    git_cmd checkout -b feature/search &&
    echo "feature" > search.txt &&
    git_cmd add search.txt &&
    git_cmd commit -m "feature" &&
    git_cmd hub init >/dev/null &&
    issue_out=$(git_cmd hub issue create --title "Search Issue" --body "issue keyword-issue") &&
    issue_id=$(printf "%s\n" "$issue_out" | head -n1 | cut -d" " -f2) &&
    test -n "$issue_id" &&
    pr_out=$(git_cmd hub pr create --title "Search PR" --body "pr keyword-pr" --head refs/heads/feature/search --base refs/heads/main) &&
    pr_id=$(printf "%s\n" "$pr_out" | head -n1 | cut -d" " -f2) &&
    test -n "$pr_id" &&
    all_out=$(git_cmd hub search "Search") &&
    printf "%s\n" "$all_out" | grep -q "pr #$pr_id" &&
    printf "%s\n" "$all_out" | grep -q "issue #$issue_id" &&
    issue_only=$(git_cmd hub search --type issue "Search") &&
    printf "%s\n" "$issue_only" | grep -q "issue #$issue_id" &&
    ! printf "%s\n" "$issue_only" | grep -q "pr #$pr_id"
'

test_expect_success 'hub search: comment/review and limit filter' '
    git_cmd init &&
    echo "base" > README.md &&
    git_cmd add README.md &&
    git_cmd commit -m "base" &&
    git_cmd checkout -b feature/search-detail &&
    echo "feature" > detail.txt &&
    git_cmd add detail.txt &&
    git_cmd commit -m "feature" &&
    git_cmd hub init >/dev/null &&
    pr_out=$(git_cmd hub pr create --title "Detail PR" --body "detail body" --head refs/heads/feature/search-detail --base refs/heads/main) &&
    pr_id=$(printf "%s\n" "$pr_out" | head -n1 | cut -d" " -f2) &&
    test -n "$pr_id" &&
    git_cmd hub pr comment "$pr_id" --body "token-comment" >/dev/null &&
    source_commit=$(git_cmd rev-parse refs/heads/feature/search-detail) &&
    git_cmd hub pr review "$pr_id" --approve --commit "$source_commit" --body "token-review" >/dev/null &&
    comment_out=$(git_cmd hub search --type comment "token-comment") &&
    printf "%s\n" "$comment_out" | grep -q "pr-comment #$pr_id/" &&
    review_out=$(git_cmd hub search --type review "token-review") &&
    printf "%s\n" "$review_out" | grep -q "pr-review #$pr_id/" &&
    limited_out=$(git_cmd hub search --type pr "Detail" --limit 1) &&
    test "$(printf "%s\n" "$limited_out" | wc -l | tr -d " ")" -eq 1
'

test_done

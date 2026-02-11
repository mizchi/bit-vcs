#!/bin/sh
#
# Security-focused workspace boundary tests
#

test_description='workspace blocks manifest paths that escape workspace root and keeps external repos untouched'

TEST_DIRECTORY=$(cd "$(dirname "$0")" && pwd)
. "$TEST_DIRECTORY/test-lib.sh"

FIXTURE_DIR="$BIT_BUILD_DIR/fixtures/workspace_flow"

test_expect_success 'setup: bootstrap workspace fixture and external repository' '
	"$FIXTURE_DIR/bootstrap.sh" ws &&
	mkdir outside &&
	(cd outside &&
	 git init &&
	 git config user.email "test@example.com" &&
	 git config user.name "Test User" &&
	 echo "outside-v1" > outside.txt &&
	 git add outside.txt &&
	 git commit -m "outside init") &&
	(cd ws &&
	 $BIT workspace init >../ws-security-init.out 2>&1 &&
	 cp "$FIXTURE_DIR/workspace.escape.toml" .git/workspace.toml)
'

test_expect_success 'workspace doctor rejects escaped node path' '
	(cd ws &&
	 if $BIT workspace doctor >../ws-security-doctor.out 2>&1; then
	   false
	 else
	   true
	 fi) &&
	grep "escapes workspace root" ws-security-doctor.out
'

test_expect_success 'workspace commit fails fast and does not mutate any repository HEAD' '
	git -C ws rev-parse HEAD > ws-root-head-before.out &&
	git -C outside rev-parse HEAD > outside-head-before.out &&
	(cd ws &&
	 if $BIT workspace commit -m "should fail due to escaped path" >../ws-security-commit.out 2>&1; then
	   false
	 else
	   true
	 fi) &&
	grep "escapes workspace root" ws-security-commit.out &&
	git -C ws rev-parse HEAD > ws-root-head-after.out &&
	git -C outside rev-parse HEAD > outside-head-after.out &&
	test_cmp ws-root-head-before.out ws-root-head-after.out &&
	test_cmp outside-head-before.out outside-head-after.out &&
	! ls ws/.git/txns/commit-*.json >/dev/null 2>&1
'

test_expect_success 'workspace flow fails fast and does not execute external task command' '
	mkdir flow-logs &&
	(cd ws &&
	 if BIT_WORKSPACE_FLOW_LOG_DIR="$PWD/../flow-logs" $BIT workspace flow test >../ws-security-flow.out 2>&1; then
	   false
	 else
	   true
	 fi) &&
	grep "escapes workspace root" ws-security-flow.out &&
	test_path_is_missing flow-logs/outside.log
'

test_expect_success 'git native compatibility remains intact after rejected workspace operations' '
	git -C outside status --porcelain > outside-native-status.out &&
	(cd outside &&
	 $BIT repo status --porcelain >../outside-bit-status.out 2>&1) &&
	test_cmp outside-native-status.out outside-bit-status.out &&
	git -C outside fsck --full
'

test_done

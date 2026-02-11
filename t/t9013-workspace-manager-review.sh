#!/bin/sh
#
# Manager/operations-focused workspace tests
#

test_description='workspace manifest governance and required-node policy for large project management'

TEST_DIRECTORY=$(cd "$(dirname "$0")" && pwd)
. "$TEST_DIRECTORY/test-lib.sh"

FIXTURE_DIR="$BIT_BUILD_DIR/fixtures/workspace_flow"

test_expect_success 'setup: bootstrap workspace fixture and initialize metadata' '
	"$FIXTURE_DIR/bootstrap.sh" ws &&
	(cd ws &&
	 $BIT workspace init >../ws-manager-init.out 2>&1)
'

test_expect_success 'optional node failure does not fail whole flow transaction' '
	mkdir flow-logs &&
	cp "$FIXTURE_DIR/workspace.optional-fail.toml" ws/.git/workspace.toml &&
	(cd ws &&
	 BIT_WORKSPACE_FLOW_LOG_DIR="$PWD/../flow-logs" $BIT workspace flow test >../ws-manager-flow-optional.out 2>&1
	) &&
	grep "workspace flow txn:" ws-manager-flow-optional.out &&
	grep "(completed)" ws-manager-flow-optional.out &&
	sed -n "s/.*workspace flow txn: \\([^ ]*\\).*/\\1/p" ws-manager-flow-optional.out | head -n 1 > ws-manager-flow-optional.txn &&
	test -s ws-manager-flow-optional.txn &&
	grep "\"node_id\": \"extra\"" ws/.git/txns/$(cat ws-manager-flow-optional.txn).json &&
	grep "\"status\": \"failed\"" ws/.git/txns/$(cat ws-manager-flow-optional.txn).json &&
	test_path_is_file flow-logs/root.log &&
	test_path_is_file flow-logs/dep.log &&
	test_path_is_file flow-logs/leaf.log &&
	test_path_is_missing flow-logs/extra.log
'

test_expect_success 'unknown dependency is rejected before workflow execution' '
	cp "$FIXTURE_DIR/workspace.unknown-dep.toml" ws/.git/workspace.toml &&
	(cd ws &&
	 if BIT_WORKSPACE_FLOW_LOG_DIR="$PWD/../flow-logs" $BIT workspace flow test >../ws-manager-flow-unknown-dep.out 2>&1; then
	   false
	 else
	   true
	 fi) &&
	grep "depends on unknown node" ws-manager-flow-unknown-dep.out
'

test_expect_success 'dependency cycle is rejected before workflow execution' '
	cp "$FIXTURE_DIR/workspace.cycle.toml" ws/.git/workspace.toml &&
	(cd ws &&
	 if BIT_WORKSPACE_FLOW_LOG_DIR="$PWD/../flow-logs" $BIT workspace flow test >../ws-manager-flow-cycle.out 2>&1; then
	   false
	 else
	   true
	 fi) &&
	grep "dependency graph has a cycle" ws-manager-flow-cycle.out
'

test_expect_success 'duplicate node ids are rejected by doctor for governance safety' '
	cp "$FIXTURE_DIR/workspace.duplicate-id.toml" ws/.git/workspace.toml &&
	(cd ws &&
	 if $BIT workspace doctor >../ws-manager-doctor-dup.out 2>&1; then
	   false
	 else
	   true
	 fi) &&
	grep "duplicate node id" ws-manager-doctor-dup.out
'

test_done

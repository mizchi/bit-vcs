#!/bin/bash
#
# e2e: hub sync relay runtime option coverage (auth/signing overrides)

source "$(dirname "$0")/test-lib-e2e.sh"

TEST_COUNT=3
PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0

CASE_1='hub sync relay: --auth-token overrides env for push/fetch'
CASE_2='hub sync relay: --allow-unsigned overrides BIT_COLLAB_REQUIRE_SIGNED'
CASE_3='hub sync relay: --signing-key overrides wrong env key on strict fetch'

SERVER_PID=""
RELAY_PORT=""
RELAY_LOG=""

cleanup_server() {
    if [ -n "$SERVER_PID" ]; then
        kill "$SERVER_PID" 2>/dev/null || true
        sleep 1
        kill -9 "$SERVER_PID" 2>/dev/null || true
        SERVER_PID=""
    fi
}

start_server() {
    local seed="${1:-0}"
    RELAY_PORT=$((12000 + ($$ + seed) % 30000))
    RELAY_LOG="$TRASH_DIR/relay-server.log"
    node "$PROJECT_ROOT/tools/relay-test-server.js" "$RELAY_PORT" >"$RELAY_LOG" 2>&1 &
    SERVER_PID=$!
    sleep 1
    kill -0 "$SERVER_PID"
}

relay_url() {
    echo "relay+http://127.0.0.1:$RELAY_PORT"
}

init_repo() {
    git_cmd init >/dev/null
    echo "init" > README.md
    git_cmd add README.md
    git_cmd commit -m "init" >/dev/null
}

run_case_auth_token_override() {
    setup_test_dir
    trap 'cleanup_server; cleanup_test_dir' EXIT
    start_server 1
    local remote
    remote="$(relay_url)"

    mkdir node-a node-b
    (
        cd node-a
        init_repo
        BIT_COLLAB_SIGN_KEY=sync-key git_cmd hub init >/dev/null
        BIT_COLLAB_SIGN_KEY=sync-key git_cmd hub issue create \
            --title "Relay Signed Issue" \
            --body "signed payload" >/dev/null
        BIT_RELAY_AUTH_TOKEN=env-push git_cmd hub sync push \
            --auth-token cli-push \
            --signing-key sync-key \
            "$remote" >/dev/null
    )

    (
        cd node-b
        init_repo
        git_cmd hub init >/dev/null
        BIT_RELAY_AUTH_TOKEN=env-fetch git_cmd hub sync fetch \
            --auth-token cli-fetch \
            --signing-key sync-key \
            --require-signed \
            "$remote" >/dev/null
        git_cmd hub issue list --open | grep -q "Relay Signed Issue"
    )

    grep -q "AUTH publish Bearer cli-push" "$RELAY_LOG"
    grep -q "AUTH poll Bearer cli-fetch" "$RELAY_LOG"

    cleanup_server
    cleanup_test_dir
    trap - EXIT
}

run_case_allow_unsigned_override() {
    setup_test_dir
    trap 'cleanup_server; cleanup_test_dir' EXIT
    start_server 2
    local remote
    remote="$(relay_url)"

    mkdir node-a node-b
    (
        cd node-a
        init_repo
        git_cmd hub init >/dev/null
        git_cmd hub issue create \
            --title "Unsigned Issue 1" \
            --body "unsigned payload 1" >/dev/null
        git_cmd hub sync push "$remote" >/dev/null
    )

    (
        cd node-b
        init_repo
        git_cmd hub init >/dev/null
        BIT_COLLAB_REQUIRE_SIGNED=true git_cmd hub sync fetch "$remote" >/dev/null
        git_cmd hub issue list --open | grep -q "No issues"
    )

    (
        cd node-a
        git_cmd hub issue create \
            --title "Unsigned Issue 2" \
            --body "unsigned payload 2" >/dev/null
        git_cmd hub sync push "$remote" >/dev/null
    )

    (
        cd node-b
        BIT_COLLAB_REQUIRE_SIGNED=true git_cmd hub sync fetch \
            --allow-unsigned \
            "$remote" >/dev/null
        git_cmd hub issue list --open | grep -q "Unsigned Issue 2"
    )

    cleanup_server
    cleanup_test_dir
    trap - EXIT
}

run_case_signing_key_override() {
    setup_test_dir
    trap 'cleanup_server; cleanup_test_dir' EXIT
    start_server 3
    local remote
    remote="$(relay_url)"

    mkdir node-a node-b
    (
        cd node-a
        init_repo
        BIT_COLLAB_SIGN_KEY=writer-key git_cmd hub init >/dev/null
        BIT_COLLAB_SIGN_KEY=writer-key git_cmd hub issue create \
            --title "Signed Issue 1" \
            --body "signed payload 1" >/dev/null
        BIT_COLLAB_SIGN_KEY=writer-key git_cmd hub sync push \
            --signing-key writer-key \
            "$remote" >/dev/null
    )

    (
        cd node-b
        init_repo
        git_cmd hub init >/dev/null
        BIT_COLLAB_SIGN_KEY=wrong-key BIT_COLLAB_REQUIRE_SIGNED=true \
            git_cmd hub sync fetch "$remote" >/dev/null
        git_cmd hub issue list --open | grep -q "No issues"
    )

    (
        cd node-a
        BIT_COLLAB_SIGN_KEY=writer-key git_cmd hub issue create \
            --title "Signed Issue 2" \
            --body "signed payload 2" >/dev/null
        BIT_COLLAB_SIGN_KEY=writer-key git_cmd hub sync push \
            --signing-key writer-key \
            "$remote" >/dev/null
    )

    (
        cd node-b
        BIT_COLLAB_SIGN_KEY=wrong-key BIT_COLLAB_REQUIRE_SIGNED=true \
            git_cmd hub sync fetch \
                --signing-key writer-key \
                --require-signed \
                "$remote" >/dev/null
        git_cmd hub issue list --open | grep -q "Signed Issue 2"
    )

    cleanup_server
    cleanup_test_dir
    trap - EXIT
}

if ! command -v node >/dev/null 2>&1; then
    SKIP_COUNT=3
    echo -e "${YELLOW}ok 1${NC} - $CASE_1 # SKIP node not found"
    echo -e "${YELLOW}ok 2${NC} - $CASE_2 # SKIP node not found"
    echo -e "${YELLOW}ok 3${NC} - $CASE_3 # SKIP node not found"
    test_done
fi

if ! command -v git >/dev/null 2>&1; then
    SKIP_COUNT=3
    echo -e "${YELLOW}ok 1${NC} - $CASE_1 # SKIP git not found"
    echo -e "${YELLOW}ok 2${NC} - $CASE_2 # SKIP git not found"
    echo -e "${YELLOW}ok 3${NC} - $CASE_3 # SKIP git not found"
    test_done
fi

if run_case_auth_token_override 2>/dev/null; then
    PASS_COUNT=$((PASS_COUNT + 1))
    echo -e "${GREEN}ok 1${NC} - $CASE_1"
else
    FAIL_COUNT=$((FAIL_COUNT + 1))
    echo -e "${RED}not ok 1${NC} - $CASE_1"
fi

if run_case_allow_unsigned_override 2>/dev/null; then
    PASS_COUNT=$((PASS_COUNT + 1))
    echo -e "${GREEN}ok 2${NC} - $CASE_2"
else
    FAIL_COUNT=$((FAIL_COUNT + 1))
    echo -e "${RED}not ok 2${NC} - $CASE_2"
fi

if run_case_signing_key_override 2>/dev/null; then
    PASS_COUNT=$((PASS_COUNT + 1))
    echo -e "${GREEN}ok 3${NC} - $CASE_3"
else
    FAIL_COUNT=$((FAIL_COUNT + 1))
    echo -e "${RED}not ok 3${NC} - $CASE_3"
fi

test_done

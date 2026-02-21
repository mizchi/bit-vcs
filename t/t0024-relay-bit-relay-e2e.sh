#!/bin/bash
#
# e2e: real bit-relay roundtrip scenarios

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT_CANDIDATE="$(cd "$SCRIPT_DIR/.." && pwd)"
if [ -z "${MOONGIT:-}" ] && [ -f "$PROJECT_ROOT_CANDIDATE/_build/native/release/build/cmd/bit/bit.exe" ]; then
    export MOONGIT="$PROJECT_ROOT_CANDIDATE/_build/native/release/build/cmd/bit/bit.exe"
fi

source "$(dirname "$0")/test-lib-e2e.sh"

BIT_RELAY_DIR="${BIT_RELAY_DIR:-$PROJECT_ROOT/../bit-relay}"
RELAY_PORT=""
RELAY_PID=""

make_origin_and_work() {
    git_cmd init source_tmp &&
    (cd source_tmp &&
        echo "initial" > file.txt &&
        git_cmd add file.txt &&
        git_cmd commit -m "initial commit"
    ) &&
    git_cmd clone --bare source_tmp origin.git &&
    rm -rf source_tmp &&
    git_cmd clone origin.git work &&
    (cd work &&
        git_cmd remote set-url origin "file://$(cd .. && pwd)/origin.git"
    )
}

make_named_origin_and_work() {
    local name="$1"
    local marker="$2"
    git_cmd init "source_${name}" &&
    (cd "source_${name}" &&
        echo "$marker" > peer.txt &&
        git_cmd add peer.txt &&
        git_cmd commit -m "initial ${name}"
    ) &&
    git_cmd clone --bare "source_${name}" "origin-${name}.git" &&
    rm -rf "source_${name}" &&
    git_cmd clone "origin-${name}.git" "work-${name}" &&
    (cd "work-${name}" &&
        git_cmd remote set-url origin "file://$(cd .. && pwd)/origin-${name}.git"
    )
}

start_bit_relay_server() {
    local require_signatures="${1:-false}"
    local room_tokens_json="${2:-}"
    RELAY_PORT=$((20000 + RANDOM % 20000))
    if [ -n "$room_tokens_json" ]; then
        HOST=127.0.0.1 PORT="$RELAY_PORT" RELAY_REQUIRE_SIGNATURE="$require_signatures" \
            RELAY_ROOM_TOKENS="$room_tokens_json" \
            deno run --allow-net --allow-env "$BIT_RELAY_DIR/src/deno_main.ts" > relay.log 2>&1 &
    else
        HOST=127.0.0.1 PORT="$RELAY_PORT" RELAY_REQUIRE_SIGNATURE="$require_signatures" \
            deno run --allow-net --allow-env "$BIT_RELAY_DIR/src/deno_main.ts" > relay.log 2>&1 &
    fi
    RELAY_PID=$!

    for _ in $(seq 1 50); do
        if curl -fsS "http://127.0.0.1:$RELAY_PORT/health" >/dev/null 2>&1; then
            return 0
        fi
        sleep 0.2
    done
    return 1
}

stop_bit_relay_server() {
    if [ -n "$RELAY_PID" ]; then
        kill "$RELAY_PID" 2>/dev/null || true
        sleep 1
        kill -9 "$RELAY_PID" 2>/dev/null || true
        RELAY_PID=""
    fi
}

relay_base_url() {
    echo "relay+http://127.0.0.1:$RELAY_PORT"
}

build_relay_url() {
    local room="$1"
    local token="$2"
    git_cmd hub sync issue-url "$(relay_base_url)" --room "$room" --room-token "$token"
}

if ! command -v deno >/dev/null 2>&1; then
    test_skip "bit-relay e2e scenarios" "deno not found"
    test_done
fi

if ! command -v curl >/dev/null 2>&1; then
    test_skip "bit-relay e2e scenarios" "curl not found"
    test_done
fi

if [ ! -f "$BIT_RELAY_DIR/src/deno_main.ts" ]; then
    test_skip "bit-relay e2e scenarios" "bit-relay not found at $BIT_RELAY_DIR"
    test_done
fi

test_expect_success "bit-relay unsigned: clone/push and source issue reaches clone" '
    make_origin_and_work &&
    start_bit_relay_server false &&
    trap "stop_bit_relay_server" EXIT &&
    relay_room="relay-e2e-$RANDOM-$$" &&
    relay_token="token-$RANDOM-$$" &&
    relay_url=$(build_relay_url "$relay_room" "$relay_token") &&
    origin_clone_url="file://$(pwd)/origin.git" &&
    issue_title="relay-e2e-issue-$RANDOM-$$" &&
    (cd work &&
        BIT_RELAY_SENDER=node-a \
            git_cmd hub sync clone-announce \
                "$relay_url" \
                --url "$origin_clone_url" \
                --repo relay-e2e
    ) &&
    git_cmd clone "$relay_url" relay-clone --relay-sender node-a --relay-repo relay-e2e &&
    test_file_exists relay-clone/file.txt &&
    (cd relay-clone &&
        echo "relay-change" > relay-change.txt &&
        git_cmd add relay-change.txt &&
        git_cmd commit -m "relay roundtrip commit" &&
        git_cmd push "$relay_url" main --relay-sender node-a --relay-repo relay-e2e
    ) &&
    relay_head=$(git_cmd -C relay-clone rev-parse HEAD) &&
    origin_head=$(git_cmd -C origin.git rev-parse refs/heads/main) &&
    test "$relay_head" = "$origin_head" &&
    (cd work &&
        git_cmd hub init &&
        git_cmd hub issue create --title "$issue_title" --body "from relay-e2e source" &&
        BIT_RELAY_SENDER=node-a git_cmd hub sync push "$relay_url"
    ) &&
    (cd relay-clone &&
        git_cmd hub init &&
        BIT_RELAY_SENDER=node-b git_cmd hub sync fetch "$relay_url" &&
        git_cmd hub issue list | grep -q "$issue_title"
    ) &&
    stop_bit_relay_server &&
    trap - EXIT
'

test_expect_success "bit-relay unsigned: bidirectional hub issue sync between two clones" '
    make_origin_and_work &&
    start_bit_relay_server false &&
    trap "stop_bit_relay_server" EXIT &&
    relay_room="relay-bidir-$RANDOM-$$" &&
    relay_token="token-$RANDOM-$$" &&
    relay_url=$(build_relay_url "$relay_room" "$relay_token") &&
    origin_clone_url="file://$(pwd)/origin.git" &&
    issue_a="issue-a-$RANDOM-$$" &&
    issue_b="issue-b-$RANDOM-$$" &&
    (cd work &&
        BIT_RELAY_SENDER=node-a \
            git_cmd hub sync clone-announce \
                "$relay_url" \
                --url "$origin_clone_url" \
                --repo relay-bidir &&
        git_cmd hub init &&
        git_cmd hub issue create --title "$issue_a" --body "from node-a" &&
        BIT_RELAY_SENDER=node-a git_cmd hub sync push "$relay_url"
    ) &&
    git_cmd clone "$relay_url" relay-clone --relay-sender node-a --relay-repo relay-bidir &&
    (cd relay-clone &&
        git_cmd hub init &&
        BIT_RELAY_SENDER=node-b git_cmd hub sync fetch "$relay_url" &&
        git_cmd hub issue list | grep -q "$issue_a" &&
        git_cmd hub issue create --title "$issue_b" --body "from node-b" &&
        BIT_RELAY_SENDER=node-b git_cmd hub sync push "$relay_url"
    ) &&
    (cd work &&
        BIT_RELAY_SENDER=node-a git_cmd hub sync fetch "$relay_url" &&
        git_cmd hub issue list | grep -q "$issue_b" &&
        git_cmd hub issue list | grep -q "$issue_a"
    ) &&
    stop_bit_relay_server &&
    trap - EXIT
'

test_expect_success "bit-relay room isolation: clone fails for room without peers" '
    make_named_origin_and_work a from-a &&
    make_named_origin_and_work b from-b &&
    room_a="room-a-$RANDOM-$$" &&
    room_b="room-b-$RANDOM-$$" &&
    room_c="room-c-$RANDOM-$$" &&
    token_a="token-a-$RANDOM-$$" &&
    token_b="token-b-$RANDOM-$$" &&
    token_c="token-c-$RANDOM-$$" &&
    start_bit_relay_server false &&
    trap "stop_bit_relay_server" EXIT &&
    relay_url_a=$(build_relay_url "$room_a" "$token_a") &&
    relay_url_b=$(build_relay_url "$room_b" "$token_b") &&
    relay_url_c=$(build_relay_url "$room_c" "$token_c") &&
    origin_a_clone_url="file://$(pwd)/origin-a.git" &&
    origin_b_clone_url="file://$(pwd)/origin-b.git" &&
    (cd work-a &&
        BIT_RELAY_SENDER=node-a \
            git_cmd hub sync clone-announce \
                "$relay_url_a" \
                --url "$origin_a_clone_url" \
                --repo room-a
    ) &&
    (cd work-b &&
        BIT_RELAY_SENDER=node-b \
            git_cmd hub sync clone-announce \
                "$relay_url_b" \
                --url "$origin_b_clone_url" \
                --repo room-b
    ) &&
    git_cmd clone "$relay_url_a" clone-a --relay-sender node-a --relay-repo room-a &&
    git_cmd clone "$relay_url_b" clone-b --relay-sender node-b --relay-repo room-b &&
    test "$(cat clone-a/peer.txt)" = "from-a" &&
    test "$(cat clone-b/peer.txt)" = "from-b" &&
    test_must_fail git_cmd clone "$relay_url_c" clone-denied --relay-sender node-a --relay-repo room-a &&
    stop_bit_relay_server &&
    trap - EXIT
'

test_done

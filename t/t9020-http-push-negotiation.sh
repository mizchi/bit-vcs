#!/bin/sh
#
# Ensure smart HTTP push negotiates remote objects before building a pack.
#

test_description='bit HTTP push sends only objects missing from advertised refs'

TEST_DIRECTORY=$(cd "$(dirname "$0")" && pwd)
. "$TEST_DIRECTORY/test-lib.sh"

if ! test_have_prereq GIT; then
	test_skip "HTTP push negotiation" "git not found"
	test_done
fi

if ! command -v node >/dev/null 2>&1; then
	test_skip "HTTP push negotiation" "node not found"
	test_done
fi

cleanup_http() {
	if test -n "${SERVER_PID:-}"; then
		kill "$SERVER_PID" 2>/dev/null || true
		wait "$SERVER_PID" 2>/dev/null || true
		SERVER_PID=""
	fi
}
trap 'cleanup_http; cleanup' EXIT

PORT=$((10000 + $$ % 50000))
SERVER_LOG="$TRASH_DIRECTORY/server.log"

test_expect_success 'setup repository with an incompressible base blob' '
	mkdir upstream &&
	(cd upstream &&
	 git init -q &&
	 git config user.email "test@test.com" &&
	 git config user.name "Test" &&
	 node -e '\''let x=1,b=Buffer.alloc(4*1024*1024);for(let i=0;i<b.length;i++){x=(Math.imul(x,1664525)+1013904223)>>>0;b[i]=x>>>24}require("fs").writeFileSync("base.bin",b)'\'' &&
	 git add base.bin &&
	 git commit -q -m base) &&
	git clone -q upstream client &&
	(cd client &&
	 git config user.email "test@test.com" &&
	 git config user.name "Test" &&
	 echo new > new.txt &&
	 git add new.txt &&
	 git commit -q -m new)
'

test_expect_success 'start smart HTTP server' '
	USE_REAL_GIT=1 node "$BIT_BUILD_DIR/tools/http-test-server.js" \
	  "$TRASH_DIRECTORY/upstream" $PORT >"$SERVER_LOG" 2>&1 &
	SERVER_PID=$! &&
	sleep 1 &&
	kill -0 $SERVER_PID
'

test_expect_success 'push a new branch' '
	(cd client && $BIT push "http://localhost:$PORT" HEAD:refs/heads/topic) &&
	test "$(git -C upstream rev-parse refs/heads/topic)" = \
	     "$(git -C client rev-parse HEAD)"
'

test_expect_success 'request excludes the base blob advertised by another ref' '
	request_bytes=$(awk '\''/receive-pack request:/ { print $(NF - 1) }'\'' "$SERVER_LOG" | tail -1) &&
	test -n "$request_bytes" &&
	test "$request_bytes" -lt 262144
'

test_expect_success 'up-to-date push avoids another pack request' '
	request_count_before=$(grep -c "receive-pack request:" "$SERVER_LOG") &&
	(cd client && $BIT push "http://localhost:$PORT" HEAD:refs/heads/topic) &&
	request_count_after=$(grep -c "receive-pack request:" "$SERVER_LOG") &&
	test "$request_count_after" = "$request_count_before"
'

test_done

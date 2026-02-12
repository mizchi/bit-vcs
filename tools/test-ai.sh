#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BIT_BIN="${BIT_BIN:-$ROOT_DIR/_build/native/release/build/bit_cli/bit_cli.exe}"
DEBUG_ROOT="${DEBUG_ROOT:-$ROOT_DIR/tmp}"
DEBUG_REPO="${DEBUG_REPO:-}"
TEST_AI_SKIP_DEMO="${TEST_AI_SKIP_DEMO:-0}"
TEST_AI_AGENT_LOOP="${TEST_AI_AGENT_LOOP:-0}"
TEST_AI_AGENT_MAX_STEPS="${TEST_AI_AGENT_MAX_STEPS:-}"

if [ -z "$DEBUG_REPO" ]; then
    mkdir -p "$DEBUG_ROOT"
    DEBUG_REPO="$(mktemp -d "$DEBUG_ROOT/rebase-ai-debug.XXXXXX")"
else
    if [ -e "$DEBUG_REPO" ] && [ -n "$(ls -A "$DEBUG_REPO" 2>/dev/null)" ]; then
        echo "[test-ai] DEBUG_REPO must be empty: $DEBUG_REPO" >&2
        exit 1
    fi
    mkdir -p "$DEBUG_REPO"
fi

if [ ! -x "$BIT_BIN" ]; then
    echo "[test-ai] bit binary not found, building native release..."
    (cd "$ROOT_DIR" && moon build --target native --release >/dev/null)
fi

if [ ! -x "$BIT_BIN" ]; then
    echo "[test-ai] failed to locate bit binary at: $BIT_BIN" >&2
    exit 1
fi

cd "$DEBUG_REPO"

git init -b main >/dev/null
git config user.name "Debug User"
git config user.email "debug@example.com"

cat > conflict.txt <<'EOF'
line-1: base
line-2: shared
line-3: base
EOF
git add conflict.txt
git commit -m "base" >/dev/null

git checkout -b feature >/dev/null
cat > conflict.txt <<'EOF'
line-1: feature
line-2: shared
line-3: feature
EOF
git add conflict.txt
git commit -m "feature change" >/dev/null

git checkout main >/dev/null
cat > conflict.txt <<'EOF'
line-1: main
line-2: shared
line-3: main
EOF
git add conflict.txt
git commit -m "main change" >/dev/null

git checkout feature >/dev/null

set +e
git rebase main >/dev/null 2>rebase.err
rebase_exit=$?
set -e

if [ "$rebase_exit" -eq 0 ]; then
    echo "[test-ai] expected a conflict but rebase succeeded unexpectedly" >&2
    exit 1
fi

if [ ! -d .git/rebase-merge ]; then
    echo "[test-ai] expected .git/rebase-merge to exist" >&2
    exit 1
fi

if ! grep -q '<<<<<<<' conflict.txt; then
    echo "[test-ai] expected conflict markers in conflict.txt" >&2
    exit 1
fi

demo_exit=-1
demo_args=(rebase-ai --continue)
if [ "$TEST_AI_AGENT_LOOP" = "1" ]; then
    demo_args+=(--agent-loop)
    if [ -n "$TEST_AI_AGENT_MAX_STEPS" ]; then
        demo_args+=(--agent-max-steps "$TEST_AI_AGENT_MAX_STEPS")
    fi
fi
if [ "$TEST_AI_SKIP_DEMO" != "1" ]; then
    echo "[test-ai] Running demo: ${demo_args[*]}"
    set +e
    OPENROUTER_API_KEY="${OPENROUTER_API_KEY:-}" \
        "$BIT_BIN" --no-git-fallback "${demo_args[@]}" >demo.out 2>demo.err
    demo_exit=$?
    set -e

    if [ -n "${OPENROUTER_API_KEY:-}" ]; then
        if [ "$demo_exit" -ne 0 ]; then
            echo "[test-ai] rebase-ai failed even though OPENROUTER_API_KEY is set" >&2
            tail -n 40 demo.err >&2 || true
            exit 1
        fi
        if [ -d .git/rebase-merge ]; then
            echo "[test-ai] rebase should have completed, but .git/rebase-merge still exists" >&2
            exit 1
        fi
    else
        if [ "$demo_exit" -eq 0 ]; then
            echo "[test-ai] rebase-ai succeeded without OPENROUTER_API_KEY (unexpected in conflict demo)" >&2
            exit 1
        fi
        if [ ! -d .git/rebase-merge ]; then
            echo "[test-ai] expected rebase to remain in progress without OPENROUTER_API_KEY" >&2
            exit 1
        fi
    fi
fi

echo "TEST_AI_REPO=$DEBUG_REPO"
echo "TEST_AI_BIT_BIN=$BIT_BIN"
echo "TEST_AI_DEMO_EXIT=$demo_exit"
echo "TEST_AI_AGENT_LOOP=$TEST_AI_AGENT_LOOP"
if [ -f demo.err ]; then
    echo "TEST_AI_DEMO_ERR=$(pwd)/demo.err"
fi
if [ -f demo.out ]; then
    echo "TEST_AI_DEMO_OUT=$(pwd)/demo.out"
fi

cat <<EOF
[test-ai] Prepared a conflict repository for rebase-ai debug.

Repo:
  $DEBUG_REPO

Current status:
$(git status --short --branch)

Demo command:
  OPENROUTER_API_KEY=... "$BIT_BIN" --no-git-fallback ${demo_args[*]}

Manual retry:
  cd "$DEBUG_REPO"
  "$BIT_BIN" --no-git-fallback ${demo_args[*]}
  "$BIT_BIN" --no-git-fallback rebase-ai --abort
  "$BIT_BIN" --no-git-fallback rebase-ai --skip

Notes:
  - If OPENROUTER_API_KEY is unset, demo intentionally fails and leaves rebase in progress.
  - If OPENROUTER_API_KEY is set, demo must finish rebase and clear rebase state.
  - Set TEST_AI_AGENT_LOOP=1 to run in agent-loop mode.
  - Set TEST_AI_AGENT_MAX_STEPS=<n> for --agent-max-steps.
  - Set DEBUG_REPO=/path/to/empty-dir to use a fixed location.
  - Set BIT_BIN=/path/to/bit_cli.exe to use a custom binary.
  - Set TEST_AI_SKIP_DEMO=1 to only prepare conflict state.
EOF

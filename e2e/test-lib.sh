#!/bin/bash
# Simple test framework for moongit e2e tests
# Usage: source test-lib.sh

set -e

# Configuration
TEST_DIR="${TEST_DIR:-$(cd "$(dirname "$0")" && pwd)}"
PROJECT_ROOT="${PROJECT_ROOT:-$(cd "$TEST_DIR/.." && pwd)}"
MOONGIT="${MOONGIT:-$PROJECT_ROOT/target/native/release/build/cmd/bit/bit.exe}"
if [ ! -f "$MOONGIT" ] && [ -f "$PROJECT_ROOT/_build/native/release/build/cmd/bit/bit.exe" ]; then
    MOONGIT="$PROJECT_ROOT/_build/native/release/build/cmd/bit/bit.exe"
fi
if [ ! -f "$MOONGIT" ] && [ -f "$PROJECT_ROOT/tools/git-shim/moon" ]; then
    MOONGIT="$PROJECT_ROOT/tools/git-shim/moon"
fi

# Build moongit if not exists
if [ ! -f "$MOONGIT" ]; then
    echo "Building moongit..."
    (cd "$PROJECT_ROOT" && moon build --target native --release)
fi

# Test state
TEST_COUNT=0
PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0
TEST_NAME=""
TRASH_DIR=""

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Run moongit with --no-git-fallback
git_cmd() {
    "$MOONGIT" --no-git-fallback "$@"
}

# Run moongit (allowing fallback for comparison tests)
git_with_fallback() {
    "$MOONGIT" "$@"
}

# Create a fresh trash directory for each test file
setup_test_dir() {
    TRASH_DIR=$(mktemp -d)
    cd "$TRASH_DIR"
    export HOME="$TRASH_DIR"
    export GIT_AUTHOR_NAME="Test User"
    export GIT_AUTHOR_EMAIL="test@example.com"
    export GIT_COMMITTER_NAME="Test User"
    export GIT_COMMITTER_EMAIL="test@example.com"
    export GIT_COMMITTER_DATE="1234567890"
}

cleanup_test_dir() {
    if [ -n "$TRASH_DIR" ] && [ -d "$TRASH_DIR" ]; then
        rm -rf "$TRASH_DIR"
    fi
}

# Test functions
test_expect_success() {
    local name="$1"
    local script="$2"
    TEST_COUNT=$((TEST_COUNT + 1))
    TEST_NAME="$name"

    # Create fresh trash dir for this test
    local old_dir=$(pwd)
    setup_test_dir

    if (eval "$script") 2>/dev/null; then
        PASS_COUNT=$((PASS_COUNT + 1))
        echo -e "${GREEN}ok $TEST_COUNT${NC} - $name"
    else
        FAIL_COUNT=$((FAIL_COUNT + 1))
        echo -e "${RED}not ok $TEST_COUNT${NC} - $name"
    fi

    cleanup_test_dir
    cd "$old_dir" 2>/dev/null || true
}

test_expect_failure() {
    local name="$1"
    local script="$2"
    TEST_COUNT=$((TEST_COUNT + 1))
    TEST_NAME="$name"

    local old_dir=$(pwd)
    setup_test_dir

    if ! (eval "$script") 2>/dev/null; then
        PASS_COUNT=$((PASS_COUNT + 1))
        echo -e "${GREEN}ok $TEST_COUNT${NC} - $name (expected failure)"
    else
        FAIL_COUNT=$((FAIL_COUNT + 1))
        echo -e "${RED}not ok $TEST_COUNT${NC} - $name (should have failed)"
    fi

    cleanup_test_dir
    cd "$old_dir" 2>/dev/null || true
}

test_skip() {
    local name="$1"
    local reason="$2"
    TEST_COUNT=$((TEST_COUNT + 1))
    SKIP_COUNT=$((SKIP_COUNT + 1))
    echo -e "${YELLOW}ok $TEST_COUNT${NC} - $name # SKIP $reason"
}

# Summary
test_done() {
    echo ""
    echo "# passed all $PASS_COUNT test(s)"
    if [ $FAIL_COUNT -gt 0 ]; then
        echo "# failed $FAIL_COUNT test(s)"
    fi
    if [ $SKIP_COUNT -gt 0 ]; then
        echo "# skipped $SKIP_COUNT test(s)"
    fi
    echo "1..$TEST_COUNT"

    if [ $FAIL_COUNT -gt 0 ]; then
        exit 1
    fi
    exit 0
}

# Assertion helpers
test_cmp() {
    diff -u "$1" "$2"
}

test_file_exists() {
    test -f "$1"
}

test_dir_exists() {
    test -d "$1"
}

test_path_is_missing() {
    ! test -e "$1"
}

# Cleanup on exit
trap cleanup_test_dir EXIT

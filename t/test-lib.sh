#!/bin/sh
# Test framework for bit (MoonBit Git implementation)
# Inspired by git/t/test-lib.sh

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

# Test counters
test_count=0
test_success=0
test_failure=0
test_skip=0

# Test directory setup
if test -z "$TEST_DIRECTORY"; then
	TEST_DIRECTORY=$(cd "$(dirname "$0")" && pwd)
fi
BIT_BUILD_DIR="${TEST_DIRECTORY%/t}"

# Find bit binary
if test -x "$BIT_BUILD_DIR/target/release/build/cmd/bit/bit"; then
	BIT="$BIT_BUILD_DIR/target/release/build/cmd/bit/bit"
elif test -x "$BIT_BUILD_DIR/target/release/build/cmd/bit/bit.exe"; then
	BIT="$BIT_BUILD_DIR/target/release/build/cmd/bit/bit.exe"
elif test -x "$BIT_BUILD_DIR/_build/native/release/build/cmd/bit/bit"; then
	BIT="$BIT_BUILD_DIR/_build/native/release/build/cmd/bit/bit"
elif test -x "$BIT_BUILD_DIR/_build/native/release/build/cmd/bit/bit.exe"; then
	BIT="$BIT_BUILD_DIR/_build/native/release/build/cmd/bit/bit.exe"
elif test -x "$BIT_BUILD_DIR/target/release/build/main/main"; then
	BIT="$BIT_BUILD_DIR/target/release/build/main/main"
elif test -x "$BIT_BUILD_DIR/_build/native/release/build/main/main"; then
	BIT="$BIT_BUILD_DIR/_build/native/release/build/main/main"
else
	BIT="bit"
fi

# Create trash directory for test
TRASH_DIRECTORY="$TEST_DIRECTORY/trash-directory.$(basename "$0" .sh)"
rm -rf "$TRASH_DIRECTORY"
mkdir -p "$TRASH_DIRECTORY"
cd "$TRASH_DIRECTORY" || exit 1

# Cleanup on exit
cleanup() {
	cd "$TEST_DIRECTORY" || exit 1
	if test "$test_failure" = 0 && test -z "$BIT_TEST_KEEP_TRASH"; then
		rm -rf "$TRASH_DIRECTORY"
	fi
}
trap cleanup EXIT

# Print test description
test_description() {
	echo "# $1"
}

# Run a test
# Usage: test_expect_success 'description' 'command'
test_expect_success() {
	test_count=$((test_count + 1))
	desc="$1"
	shift

	if test -n "$BIT_TEST_DEBUG"; then
		# Debug mode: show output
		if eval "$@"; then
			test_success=$((test_success + 1))
			printf "${GREEN}ok %d${NC} - %s\n" "$test_count" "$desc"
			return 0
		else
			test_failure=$((test_failure + 1))
			printf "${RED}not ok %d${NC} - %s\n" "$test_count" "$desc"
			echo "# Failed command:"
			echo "# $*"
			return 1
		fi
	else
		if eval "$@" >/dev/null 2>&1; then
			test_success=$((test_success + 1))
			printf "${GREEN}ok %d${NC} - %s\n" "$test_count" "$desc"
			return 0
		else
			test_failure=$((test_failure + 1))
			printf "${RED}not ok %d${NC} - %s\n" "$test_count" "$desc"
			if test -n "$BIT_TEST_VERBOSE"; then
				echo "# Failed command:"
				echo "# $*"
			fi
			return 1
		fi
	fi
}

# Run a test expecting failure
test_expect_failure() {
	test_count=$((test_count + 1))
	desc="$1"
	shift

	if eval "$@" >/dev/null 2>&1; then
		test_failure=$((test_failure + 1))
		printf "${RED}not ok %d${NC} - %s (unexpected success)\n" "$test_count" "$desc"
		return 1
	else
		test_success=$((test_success + 1))
		printf "${GREEN}ok %d${NC} - %s\n" "$test_count" "$desc"
		return 0
	fi
}

# Skip a test
test_skip() {
	test_count=$((test_count + 1))
	test_skip=$((test_skip + 1))
	desc="$1"
	reason="${2:-skipped}"
	printf "${YELLOW}ok %d${NC} - %s # SKIP %s\n" "$test_count" "$desc" "$reason"
}

# Compare two files
test_cmp() {
	diff -u "$1" "$2"
}

# Check if file exists
test_path_is_file() {
	test -f "$1"
}

# Check if directory exists
test_path_is_dir() {
	test -d "$1"
}

# Check if path is missing
test_path_is_missing() {
	! test -e "$1"
}

# Check line count
test_line_count() {
	test "$(wc -l < "$2" | tr -d ' ')" "$1" "$3"
}

# Create a commit with bit
test_commit() {
	msg="${1:-test commit}"
	file="${2:-file.txt}"
	echo "${3:-content}" > "$file"
	$BIT add "$file" &&
	$BIT commit -m "$msg"
}

# Print final results
test_done() {
	echo
	echo "# passed: $test_success"
	echo "# failed: $test_failure"
	echo "# skipped: $test_skip"
	echo "# total: $test_count"

	if test "$test_failure" -gt 0; then
		exit 1
	fi
	exit 0
}

# Check prerequisites
test_have_prereq() {
	case "$1" in
	GIT)
		command -v git >/dev/null 2>&1
		;;
	CURL)
		command -v curl >/dev/null 2>&1
		;;
	*)
		return 1
		;;
	esac
}

# Git compatibility helpers
git_init() {
	git init "$@"
}

git_commit() {
	git add -A && git commit -m "${1:-commit}"
}

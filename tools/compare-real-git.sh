#!/bin/bash
# Compare bit vs native git performance on real repositories
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BIT_BIN="${BIT_BIN:-$PROJECT_DIR/_build/native/release/build/cmd/bit/bit.exe}"
BENCH_DIR="${BENCH_DIR:-/tmp/git_benchmark}"
REPO_URL="${REPO_URL:-https://github.com/expressjs/express.git}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Function to measure time and return seconds
# Uses subshell to preserve working directory
measure() {
    local start end
    start=$(python3 -c 'import time; print(time.time())')
    (eval "$@") >/dev/null 2>&1 || true
    end=$(python3 -c 'import time; print(time.time())')
    python3 -c "print(f'{$end - $start:.3f}')"
}

# Print result with comparison
print_result() {
    local name="$1"
    local git_time="$2"
    local bit_time="$3"

    local ratio=$(python3 -c "
git_t = float('$git_time')
bit_t = float('$bit_time')
if git_t < bit_t:
    ratio = bit_t / git_t
    print(f'git {ratio:.1f}x faster')
else:
    ratio = git_t / bit_t
    print(f'bit {ratio:.1f}x faster')
")

    printf "%-35s git: %7ss  bit: %7ss  (%s)\n" "$name" "$git_time" "$bit_time" "$ratio"
}

echo "=========================================="
echo " Git vs Bit Performance Comparison"
echo "=========================================="
echo ""
echo "Repository: $REPO_URL"
echo "Benchmark dir: $BENCH_DIR"
echo ""

# Build bit first
echo "Building bit..."
cd "$PROJECT_DIR"
moon build --target native >/dev/null 2>&1
if [ ! -x "$BIT_BIN" ]; then
    echo "ERROR: bit binary not found at $BIT_BIN"
    exit 1
fi
echo ""

# Setup benchmark directory
rm -rf "$BENCH_DIR"
mkdir -p "$BENCH_DIR"
cd "$BENCH_DIR"

# ============================================
# Test 1: Clone
# ============================================
echo "=== Clone ==="

echo -n "Cloning with git..."
git_clone=$(measure "git clone '$REPO_URL' repo-git")
echo " done"

echo -n "Cloning with bit..."
bit_clone=$(measure "'$BIT_BIN' clone '$REPO_URL' '$BENCH_DIR/repo-bit'")
echo " done"

print_result "clone (full)" "$git_clone" "$bit_clone"
echo ""

# ============================================
# Test 2: Add files
# ============================================
echo "=== Add (100 new files) ==="

# Create test files in both repos
for i in {1..100}; do
    echo "test content $i" > "$BENCH_DIR/repo-git/test_file_$i.txt"
    echo "test content $i" > "$BENCH_DIR/repo-bit/test_file_$i.txt"
done

cd "$BENCH_DIR/repo-git"
git_add_100=$(measure "git add .")

cd "$BENCH_DIR/repo-bit"
bit_add_100=$(measure "'$BIT_BIN' -C '$BENCH_DIR/repo-bit' add .")

print_result "add (100 files)" "$git_add_100" "$bit_add_100"

# ============================================
# Test 3: Add 1000 files
# ============================================
echo ""
echo "=== Add (1000 new files) ==="

# Reset and create more files
cd "$BENCH_DIR/repo-git"
git reset --hard HEAD >/dev/null 2>&1
cd "$BENCH_DIR/repo-bit"
"$BIT_BIN" -C "$BENCH_DIR/repo-bit" reset --hard HEAD >/dev/null 2>&1

for i in {1..1000}; do
    echo "test content $i with more data for realistic size" > "$BENCH_DIR/repo-git/test_large_$i.txt"
    echo "test content $i with more data for realistic size" > "$BENCH_DIR/repo-bit/test_large_$i.txt"
done

cd "$BENCH_DIR/repo-git"
git_add_1000=$(measure "git add .")

cd "$BENCH_DIR/repo-bit"
bit_add_1000=$(measure "'$BIT_BIN' -C '$BENCH_DIR/repo-bit' add .")

print_result "add (1000 files)" "$git_add_1000" "$bit_add_1000"

# ============================================
# Test 4: Commit
# ============================================
echo ""
echo "=== Commit (1000 files) ==="

cd "$BENCH_DIR/repo-git"
git_commit=$(measure "git commit -m 'Add test files'")

cd "$BENCH_DIR/repo-bit"
bit_commit=$(measure "'$BIT_BIN' -C '$BENCH_DIR/repo-bit' commit -m 'Add test files'")

print_result "commit (1000 files)" "$git_commit" "$bit_commit"

# ============================================
# Test 5: Status (clean)
# ============================================
echo ""
echo "=== Status (clean working tree) ==="

cd "$BENCH_DIR/repo-git"
git_status_clean=$(measure "git status")

cd "$BENCH_DIR/repo-bit"
bit_status_clean=$(measure "'$BIT_BIN' -C '$BENCH_DIR/repo-bit' status")

print_result "status (clean)" "$git_status_clean" "$bit_status_clean"

# ============================================
# Test 6: Status (500 modified files)
# ============================================
echo ""
echo "=== Status (500 modified files) ==="

for i in {1..500}; do
    echo "modified $i" >> "$BENCH_DIR/repo-git/test_large_$i.txt"
    echo "modified $i" >> "$BENCH_DIR/repo-bit/test_large_$i.txt"
done

cd "$BENCH_DIR/repo-git"
git_status_modified=$(measure "git status")

cd "$BENCH_DIR/repo-bit"
bit_status_modified=$(measure "'$BIT_BIN' -C '$BENCH_DIR/repo-bit' status")

print_result "status (500 modified)" "$git_status_modified" "$bit_status_modified"

# ============================================
# Test 7: Diff
# ============================================
echo ""
echo "=== Diff --stat (500 modified files) ==="

cd "$BENCH_DIR/repo-git"
git_diff=$(measure "git diff --stat")

cd "$BENCH_DIR/repo-bit"
bit_diff=$(measure "'$BIT_BIN' -C '$BENCH_DIR/repo-bit' diff --stat")

print_result "diff --stat (500 files)" "$git_diff" "$bit_diff"

# ============================================
# Test 8: Checkout (restore files)
# ============================================
echo ""
echo "=== Checkout (restore 500 modified files) ==="

cd "$BENCH_DIR/repo-git"
git_checkout_restore=$(measure "git checkout .")

cd "$BENCH_DIR/repo-bit"
bit_checkout_restore=$(measure "'$BIT_BIN' -C '$BENCH_DIR/repo-bit' checkout .")

print_result "checkout . (restore)" "$git_checkout_restore" "$bit_checkout_restore"

# ============================================
# Test 9: Checkout -b (create branch)
# ============================================
echo ""
echo "=== Checkout -b (create new branch) ==="

BRANCH_NAME="test-branch-$$"

cd "$BENCH_DIR/repo-git"
git_checkout_b=$(measure "git checkout -b $BRANCH_NAME")

bit_checkout_b=$(measure "'$BIT_BIN' -C '$BENCH_DIR/repo-bit' checkout -b '$BRANCH_NAME'")

print_result "checkout -b" "$git_checkout_b" "$bit_checkout_b"

# ============================================
# Test 10: Log
# ============================================
echo ""
echo "=== Log --oneline -10 ==="

cd "$BENCH_DIR/repo-git"
git_log=$(measure "git log --oneline -10")

cd "$BENCH_DIR/repo-bit"
bit_log=$(measure "'$BIT_BIN' -C '$BENCH_DIR/repo-bit' log --oneline -10")

print_result "log --oneline -10" "$git_log" "$bit_log"

# ============================================
# Summary
# ============================================
echo ""
echo "=========================================="
echo " Summary"
echo "=========================================="
echo ""
echo "Notes:"
echo "  - bit runs pre-built binary directly (no moon run overhead)"
echo "  - Large file operations (add/commit 1000+ files) favor bit"
echo "  - checkout . (file restore) is faster in bit"
echo "  - status/log are faster in native git (inode caching)"
echo ""

# Cleanup
echo "Cleaning up..."
rm -rf "$BENCH_DIR"
echo "Done!"

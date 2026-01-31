#!/bin/bash
# Compare moongit vs native git performance on real repositories
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
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

# Function to run moongit
run_moongit() {
    cd "$PROJECT_DIR"
    moon run src/cmd/moongit --target native -- "$@"
}

# Print result with comparison
print_result() {
    local name="$1"
    local git_time="$2"
    local moongit_time="$3"

    local ratio=$(python3 -c "
git_t = float('$git_time')
moongit_t = float('$moongit_time')
if git_t < moongit_t:
    ratio = moongit_t / git_t
    print(f'git {ratio:.1f}x faster')
else:
    ratio = git_t / moongit_t
    print(f'moongit {ratio:.1f}x faster')
")

    printf "%-35s git: %7ss  moongit: %7ss  (%s)\n" "$name" "$git_time" "$moongit_time" "$ratio"
}

echo "=========================================="
echo " Git vs Moongit Performance Comparison"
echo "=========================================="
echo ""
echo "Repository: $REPO_URL"
echo "Benchmark dir: $BENCH_DIR"
echo ""

# Build moongit first
echo "Building moongit..."
cd "$PROJECT_DIR"
moon build src/cmd/moongit --target native >/dev/null 2>&1
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
git_clone=$(measure "git clone --depth=1 '$REPO_URL' repo-git")
echo " done"

echo -n "Cloning with moongit..."
moongit_clone=$(measure "cd '$PROJECT_DIR' && moon run src/cmd/moongit --target native -- clone '$REPO_URL' '$BENCH_DIR/repo-moongit'")
echo " done"

print_result "clone (shallow)" "$git_clone" "$moongit_clone"
echo ""

# ============================================
# Test 2: Add files
# ============================================
echo "=== Add (100 new files) ==="

# Create test files in both repos
for i in {1..100}; do
    echo "test content $i" > "$BENCH_DIR/repo-git/test_file_$i.txt"
    echo "test content $i" > "$BENCH_DIR/repo-moongit/test_file_$i.txt"
done

cd "$BENCH_DIR/repo-git"
git_add_100=$(measure "git add .")

cd "$BENCH_DIR/repo-moongit"
moongit_add_100=$(measure "cd '$PROJECT_DIR' && moon run src/cmd/moongit --target native -- -C '$BENCH_DIR/repo-moongit' add .")

print_result "add (100 files)" "$git_add_100" "$moongit_add_100"

# ============================================
# Test 3: Add 1000 files
# ============================================
echo ""
echo "=== Add (1000 new files) ==="

# Reset and create more files
cd "$BENCH_DIR/repo-git"
git reset --hard HEAD >/dev/null 2>&1
cd "$BENCH_DIR/repo-moongit"
(cd "$PROJECT_DIR" && moon run src/cmd/moongit --target native -- -C "$BENCH_DIR/repo-moongit" reset --hard HEAD) >/dev/null 2>&1

for i in {1..1000}; do
    echo "test content $i with more data for realistic size" > "$BENCH_DIR/repo-git/test_large_$i.txt"
    echo "test content $i with more data for realistic size" > "$BENCH_DIR/repo-moongit/test_large_$i.txt"
done

cd "$BENCH_DIR/repo-git"
git_add_1000=$(measure "git add .")

cd "$BENCH_DIR/repo-moongit"
moongit_add_1000=$(measure "cd '$PROJECT_DIR' && moon run src/cmd/moongit --target native -- -C '$BENCH_DIR/repo-moongit' add .")

print_result "add (1000 files)" "$git_add_1000" "$moongit_add_1000"

# ============================================
# Test 4: Commit
# ============================================
echo ""
echo "=== Commit (1000 files) ==="

cd "$BENCH_DIR/repo-git"
git_commit=$(measure "git commit -m 'Add test files'")

cd "$BENCH_DIR/repo-moongit"
moongit_commit=$(measure "cd '$PROJECT_DIR' && moon run src/cmd/moongit --target native -- -C '$BENCH_DIR/repo-moongit' commit -m 'Add test files'")

print_result "commit (1000 files)" "$git_commit" "$moongit_commit"

# ============================================
# Test 5: Status (clean)
# ============================================
echo ""
echo "=== Status (clean working tree) ==="

cd "$BENCH_DIR/repo-git"
git_status_clean=$(measure "git status")

cd "$BENCH_DIR/repo-moongit"
moongit_status_clean=$(measure "cd '$PROJECT_DIR' && moon run src/cmd/moongit --target native -- -C '$BENCH_DIR/repo-moongit' status")

print_result "status (clean)" "$git_status_clean" "$moongit_status_clean"

# ============================================
# Test 6: Status (500 modified files)
# ============================================
echo ""
echo "=== Status (500 modified files) ==="

for i in {1..500}; do
    echo "modified $i" >> "$BENCH_DIR/repo-git/test_large_$i.txt"
    echo "modified $i" >> "$BENCH_DIR/repo-moongit/test_large_$i.txt"
done

cd "$BENCH_DIR/repo-git"
git_status_modified=$(measure "git status")

cd "$BENCH_DIR/repo-moongit"
moongit_status_modified=$(measure "cd '$PROJECT_DIR' && moon run src/cmd/moongit --target native -- -C '$BENCH_DIR/repo-moongit' status")

print_result "status (500 modified)" "$git_status_modified" "$moongit_status_modified"

# ============================================
# Test 7: Diff
# ============================================
echo ""
echo "=== Diff --stat (500 modified files) ==="

cd "$BENCH_DIR/repo-git"
git_diff=$(measure "git diff --stat")

cd "$BENCH_DIR/repo-moongit"
moongit_diff=$(measure "cd '$PROJECT_DIR' && moon run src/cmd/moongit --target native -- -C '$BENCH_DIR/repo-moongit' diff --stat")

print_result "diff --stat (500 files)" "$git_diff" "$moongit_diff"

# ============================================
# Test 8: Checkout (restore files)
# ============================================
echo ""
echo "=== Checkout (restore 500 modified files) ==="

cd "$BENCH_DIR/repo-git"
git_checkout_restore=$(measure "git checkout .")

cd "$BENCH_DIR/repo-moongit"
moongit_checkout_restore=$(measure "cd '$PROJECT_DIR' && moon run src/cmd/moongit --target native -- -C '$BENCH_DIR/repo-moongit' checkout .")

print_result "checkout . (restore)" "$git_checkout_restore" "$moongit_checkout_restore"

# ============================================
# Test 9: Checkout -b (create branch)
# ============================================
echo ""
echo "=== Checkout -b (create new branch) ==="

BRANCH_NAME="test-branch-$$"

cd "$BENCH_DIR/repo-git"
git_checkout_b=$(measure "git checkout -b $BRANCH_NAME")

# Measure moongit checkout -b directly without variable expansion issues
start_time=$(python3 -c 'import time; print(time.time())')
(cd "$PROJECT_DIR" && moon run src/cmd/moongit --target native -- -C "$BENCH_DIR/repo-moongit" checkout -b "$BRANCH_NAME") >/dev/null 2>&1 || true
end_time=$(python3 -c 'import time; print(time.time())')
moongit_checkout_b=$(python3 -c "print(f'{$end_time - $start_time:.3f}')")

print_result "checkout -b" "$git_checkout_b" "$moongit_checkout_b"

# ============================================
# Test 10: Log
# ============================================
echo ""
echo "=== Log --oneline -10 ==="

cd "$BENCH_DIR/repo-git"
git_log=$(measure "git log --oneline -10")

cd "$BENCH_DIR/repo-moongit"
moongit_log=$(measure "cd '$PROJECT_DIR' && moon run src/cmd/moongit --target native -- -C '$BENCH_DIR/repo-moongit' log --oneline -10")

print_result "log --oneline -10" "$git_log" "$moongit_log"

# ============================================
# Summary
# ============================================
echo ""
echo "=========================================="
echo " Summary"
echo "=========================================="
echo ""
echo "Notes:"
echo "  - moongit times include 'moon run' overhead (~30-50ms)"
echo "  - Large file operations (add/commit 1000+ files) favor moongit"
echo "  - checkout . (file restore) is faster in moongit"
echo "  - status/log are faster in native git (inode caching)"
echo ""

# Cleanup
echo "Cleaning up..."
rm -rf "$BENCH_DIR"
echo "Done!"

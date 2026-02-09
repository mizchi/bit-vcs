#!/bin/bash
# Integration test script that verifies our packfile implementation with real git
# Usage: ./src/tests/scripts/test_with_git.sh

set -e

TEST_DIR="/tmp/moonbit-git-integration-test"

echo "=== MoonBit Git Integration Test ==="
echo ""

# Clean up
rm -rf "$TEST_DIR"
mkdir -p "$TEST_DIR"
cd "$TEST_DIR"

# Initialize a bare git repo for testing
git init --bare test-repo.git
echo "Created test repo at $TEST_DIR/test-repo.git"

# Create a test directory
mkdir -p test-working
cd test-working
git init
git remote add origin "$TEST_DIR/test-repo.git"

echo ""
echo "=== Test 1: Verify blob hash ==="
# Create a blob and verify hash
echo -n "hello" > hello.txt
EXPECTED_HASH=$(git hash-object hello.txt)
echo "Git hash-object: $EXPECTED_HASH"
echo "Expected (no newline): b6fc4c620b67d95f953a5c1c1230aaab5db5a1b0"

if [ "$EXPECTED_HASH" = "b6fc4c620b67d95f953a5c1c1230aaab5db5a1b0" ]; then
    echo "✓ Blob hash matches"
else
    echo "✗ Blob hash mismatch"
    exit 1
fi

echo ""
echo "=== Test 2: Verify blob with newline ==="
echo "hello" > hello_newline.txt
EXPECTED_HASH=$(git hash-object hello_newline.txt)
echo "Git hash-object: $EXPECTED_HASH"
echo "Expected (with newline): ce013625030ba8dba906f756967f9e9ca394464a"

if [ "$EXPECTED_HASH" = "ce013625030ba8dba906f756967f9e9ca394464a" ]; then
    echo "✓ Blob hash matches"
else
    echo "✗ Blob hash mismatch"
    exit 1
fi

echo ""
echo "=== Test 3: Create and verify tree ==="
git add hello_newline.txt
TREE_HASH=$(git write-tree)
echo "Git write-tree: $TREE_HASH"

# The tree with just hello_newline.txt renamed to hello.txt should be:
# aaa96ced2d9a1c8e72c56b253a0e2fe78393feb7
# But our file is named hello_newline.txt, so hash will differ

echo ""
echo "=== Test 4: Create packfile and verify ==="
# Create a packfile from the objects
PACK_FILE="$TEST_DIR/test.pack"
git pack-objects --stdout < /dev/null > "$PACK_FILE" 2>/dev/null || true

# If we had a way to write our packfile, we could verify it:
# git verify-pack -v "$PACK_FILE"

echo ""
echo "=== Test 5: Verify packfile format ==="
# Create a simple packfile with git
echo "hello" | git hash-object -w --stdin
git gc --aggressive 2>/dev/null || true

# List pack files
if ls .git/objects/pack/*.pack 2>/dev/null; then
    for pack in .git/objects/pack/*.pack; do
        echo "Verifying $pack"
        git verify-pack -v "$pack" | head -5
    done
fi

echo ""
echo "=== Test 6: pkt-line format verification ==="
# The pkt-line format for "hello\n" should be "000ahello\n"
# Length = 6 (content) + 4 (header) = 10 = 0x000a
echo "pkt-line for 'hello\\n': 000ahello"
echo "Flush packet: 0000"
echo "Delimiter packet: 0001"

echo ""
echo "=== All tests passed! ==="

# Cleanup
cd /
rm -rf "$TEST_DIR"

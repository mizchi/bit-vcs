#!/bin/bash
# Generate a compatibility table from git test allowlist
# Usage: bash tools/generate-compat-table.sh

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ALLOWLIST="$SCRIPT_DIR/git-test-allowlist.txt"
GIT_T_DIR="${GIT_T_DIR:-$SCRIPT_DIR/../third_party/git/t}"

# Parse allowlist and organize by category
declare -A categories
current_category=""

while IFS= read -r line; do
  # Skip empty lines
  [[ -z "$line" ]] && continue
  # Detect category comments
  if [[ "$line" =~ ^#[[:space:]]*(.+)$ ]]; then
    current_category="${BASH_REMATCH[1]}"
    continue
  fi
  # Skip other comments
  [[ "$line" =~ ^# ]] && continue
  # Add test to category
  if [[ -n "$current_category" ]]; then
    categories["$current_category"]+="$line "
  fi
done < "$ALLOWLIST"

# Calculate totals
total_tests=0
for category in "${!categories[@]}"; do
  tests="${categories[$category]}"
  test_count=$(echo "$tests" | wc -w | tr -d ' ')
  total_tests=$((total_tests + test_count))
done

echo "# Git Compatibility Table"
echo ""
echo "**$total_tests tests** passing with moongit git-shim."
echo ""
echo "| Category | Tests | Status |"
echo "|----------|-------|--------|"

for category in "${!categories[@]}"; do
  tests="${categories[$category]}"
  test_count=$(echo "$tests" | wc -w | tr -d ' ')
  echo "| $category | $test_count | ✅ |"
done
echo "| **Total** | **$total_tests** | |"

echo ""
echo "## Test Files"
echo ""

for category in "${!categories[@]}"; do
  echo "### $category"
  echo ""
  for test in ${categories[$category]}; do
    echo "- \`$test\`"
  done
  echo ""
done

echo "---"
echo "Generated: $(date -u +"%Y-%m-%d %H:%M:%S UTC")"

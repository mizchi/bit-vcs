#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
repo="$root/third_party/git"
cleanup_script="$root/tools/clean-git-test-artifacts.sh"

cleanup() {
  git -C "$repo" restore --worktree --staged -- . >/dev/null 2>&1 || true
  "$cleanup_script"
}

trap cleanup EXIT

make -C "$repo" test "$@"

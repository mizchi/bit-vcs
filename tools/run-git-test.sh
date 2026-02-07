#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
repo="$root/third_party/git"

cleanup() {
  git -C "$repo" restore --worktree --staged -- . >/dev/null 2>&1 || true
}

trap cleanup EXIT

make -C "$repo" test "$@"

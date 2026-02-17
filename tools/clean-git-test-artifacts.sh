#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

cleanup_paths=(
  "$root/badobjects"
  "$root/t/fallback-git"
  "$root/t/primary-git"
  "$root/t/shim.log"
  "$root/t/t0022-shim-random.sh"
  "$root/t/tmptrace"
  "$root/t/trace"
)

for path in "${cleanup_paths[@]}"; do
  rm -rf -- "$path"
done

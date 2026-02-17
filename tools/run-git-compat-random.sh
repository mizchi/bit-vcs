#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: tools/run-git-compat-random.sh [options]

Options:
  --shard N          1-based shard index (default: 1)
  --shards N         total number of shards (default: 1)
  --seed VALUE       override random seed value
  --ratio N          random ratio 0..100 (default: 50)
  --help             show this help message
EOF
}

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

shard="${COMPAT_RANDOM_SHARD:-1}"
shards="${COMPAT_RANDOM_SHARDS:-1}"
seed="${COMPAT_RANDOM_SEED:-}"
seed_source="${COMPAT_RANDOM_SEED_SOURCE:-}"
ratio="${COMPAT_RANDOM_RATIO:-${SHIM_RANDOM_RATIO:-50}}"
run_id="${COMPAT_RANDOM_RUN_ID:-${GITHUB_RUN_ID:-local-run-$(date -u +%Y%m%dT%H%M%SZ)}}"
output_dir="${COMPAT_RANDOM_OUTPUT_DIR:-$root_dir/compat-random-results}"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --shard)
      shift
      shard="${1:?--shard requires a value}"
      ;;
    --shards)
      shift
      shards="${1:?--shards requires a value}"
      ;;
    --seed)
      shift
      seed="${1:?--seed requires a value}"
      ;;
    --ratio)
      shift
      ratio="${1:?--ratio requires a value}"
      ;;
    --help)
      usage
      exit 0
      ;;
    *)
      echo "unknown option: $1" >&2
      usage
      exit 1
      ;;
  esac
  shift
done

is_uint() {
  case "${1:-}" in
    ''|*[!0-9]*)
      return 1
      ;;
    *)
      return 0
      ;;
  esac
}

derive_seed() {
  input="${1:-}"
  if command -v sha256sum >/dev/null 2>&1; then
    hash="$(printf '%s' "$input" | sha256sum 2>/dev/null | awk '{print $1}' | cut -c1-8)"
    case "$hash" in
      ''|*[!0-9A-Fa-f]*)
        ;;
      *)
        printf '%u' "$((16#$hash))"
        return 0
        ;;
    esac
  fi
  if command -v cksum >/dev/null 2>&1; then
    sum="$(printf '%s' "$input" | cksum | awk '{print $1}')"
    if is_uint "$sum"; then
      printf '%u' "$((sum % 2147483648))"
      return 0
    fi
  fi
  printf '%s' "$(date -u +%s)"
}

if ! is_uint "$shard" || ! is_uint "$shards"; then
  echo "shard and shards must be integers" >&2
  exit 1
fi
if [ "$shard" -lt 1 ] || [ "$shards" -lt 1 ] || [ "$shard" -gt "$shards" ]; then
  echo "invalid shard range: shard=$shard shards=$shards" >&2
  exit 1
fi
if ! is_uint "$ratio" || [ "$ratio" -lt 0 ] || [ "$ratio" -gt 100 ]; then
  echo "ratio must be integer in 0..100" >&2
  exit 1
fi

run_ts="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
main_head="$(git -C "$root_dir" rev-parse HEAD)"
main_head_short="$(git -C "$root_dir" rev-parse --short=12 HEAD)"

if [ -z "$seed" ]; then
  if [ -z "$seed_source" ]; then
    seed_source="${run_ts}-${main_head_short}"
  fi
  seed="$(derive_seed "$seed_source")"
fi

if [ -z "$seed" ]; then
  echo "failed to generate seed" >&2
  exit 1
fi

tests="$(tools/select-git-tests.sh "$shard" "$shards" "$root_dir/tools/git-test-allowlist.txt")"
test_count="$(printf '%s' "$tests" | wc -w | tr -d ' ')"
tests_for_record="$(printf '%s' "$tests" | tr '\n' ' ' | tr ',' ';' | tr -s ' ')"

run_dir="$output_dir/$run_id"
mkdir -p "$run_dir"
log_file="$run_dir/compat-shard-${shard}-of-${shards}.log"
record_file="$run_dir/compat-shard-${shard}-of-${shards}.record.tsv"

start_ts="$(date +%s)"

set +e
(
  set -euo pipefail
  cd "$root_dir"
  tools/apply-git-test-patches.sh
  moon update
  moon build --target native

  real_git="$(pwd)/third_party/git/git"
  exec_path="$(pwd)/third_party/git"
  if [ ! -x "$real_git" ]; then
    real_git="$(
      /usr/bin/which git 2>/dev/null || true
    )"
    if [ -z "$real_git" ]; then
      echo "real git path is not found" >&2
      exit 1
    fi
    exec_path="$($real_git --exec-path)"
  fi

  bin_path=""
  for candidate in \
    "_build/native/release/build/cmd/bit/bit.exe" \
    "_build/native/debug/build/cmd/bit/bit.exe"; do
    if [ -f "$candidate" ]; then
      bin_path="$candidate"
      break
    fi
  done
  if [ -z "$bin_path" ]; then
    echo "bit binary not found in _build/native/*/build/cmd/bit/bit.exe" >&2
    exit 1
  fi
  cp "$bin_path" tools/git-shim/moon
  chmod +x tools/git-shim/moon
  echo "$real_git" > tools/git-shim/real-git-path

  tests="$(tools/select-git-tests.sh "$shard" "$shards" "$root_dir/tools/git-test-allowlist.txt")"
  GIT_SHIM_RANDOM_MODE=1 GIT_SHIM_RANDOM_RATIO="$ratio" GIT_SHIM_RANDOM_SEED="$seed" GIT_SHIM_RANDOM_SALT="$run_id-$shard-$shards" \
  SHIM_RANDOM_MODE=1 SHIM_RANDOM_RATIO="$ratio" SHIM_RANDOM_SEED="$seed" SHIM_RANDOM_SALT="$run_id-$shard-$shards" \
  SHIM_MOON="$(pwd)/tools/git-shim/moon" SHIM_CMDS="receive-pack upload-pack pack-objects index-pack" \
  GIT_TEST_INSTALLED="$(pwd)/tools/git-shim/bin" GIT_TEST_EXEC_PATH="$exec_path" \
  GIT_TEST_DEFAULT_HASH=sha1 \
  tools/run-git-test.sh T="$tests"
) > "$log_file" 2>&1
exit_code=$?
set -euo pipefail

end_ts="$(date +%s)"
duration_sec=$((end_ts - start_ts))

if [ "$exit_code" -eq 0 ]; then
  status="success"
else
  status="failure"
fi

cat > "$record_file" <<EOF
run_id,run_timestamp,seed,seed_source,main_head,main_head_short,random_ratio,shard,shards,status,exit_code,duration_seconds,test_count,tests,log_file
$run_id,$run_ts,$seed,$seed_source,$main_head,$main_head_short,$ratio,$shard,$shards,$status,$exit_code,$duration_sec,$test_count,$tests_for_record,$log_file
EOF

echo "run_id: $run_id"
echo "shard: $shard/$shards"
echo "status: $status (exit=$exit_code)"
echo "seed: $seed"
echo "seed_source: $seed_source"
echo "log: $log_file"
echo "record: $record_file"

if [ "$exit_code" -ne 0 ]; then
  echo "run failed, exit_code=$exit_code" >&2
  exit "$exit_code"
fi

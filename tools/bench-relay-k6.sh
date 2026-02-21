#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCENARIO_PATH="$SCRIPT_DIR/relay-k6-scenario.js"
SERVER_PATH="$SCRIPT_DIR/relay-test-server.js"
SIGNER_PATH="$SCRIPT_DIR/relay-k6-signer.js"

if ! command -v k6 >/dev/null 2>&1; then
  echo "k6 command not found" >&2
  exit 1
fi

if ! command -v node >/dev/null 2>&1; then
  echo "node command not found" >&2
  exit 1
fi

RELAY_BASE_URL="${RELAY_BASE_URL:-}"
RELAY_PORT="${RELAY_PORT:-18787}"
RELAY_SERVER_LOG="${RELAY_SERVER_LOG:-$SCRIPT_DIR/.relay-k6-server.log}"
RELAY_SIGNER_URL="${RELAY_SIGNER_URL:-}"
RELAY_SIGNER_PORT="${RELAY_SIGNER_PORT:-18788}"
RELAY_SIGNER_LOG="${RELAY_SIGNER_LOG:-$SCRIPT_DIR/.relay-k6-signer.log}"
SERVER_PID=""
SIGNER_PID=""

cleanup() {
  if [ -n "${SERVER_PID}" ]; then
    kill "${SERVER_PID}" 2>/dev/null || true
    sleep 1
    kill -9 "${SERVER_PID}" 2>/dev/null || true
    SERVER_PID=""
  fi
  if [ -n "${SIGNER_PID}" ]; then
    kill "${SIGNER_PID}" 2>/dev/null || true
    sleep 1
    kill -9 "${SIGNER_PID}" 2>/dev/null || true
    SIGNER_PID=""
  fi
}

if [ -z "${RELAY_BASE_URL}" ]; then
  RELAY_BASE_URL="http://127.0.0.1:${RELAY_PORT}"
  node "${SERVER_PATH}" "${RELAY_PORT}" >"${RELAY_SERVER_LOG}" 2>&1 &
  SERVER_PID=$!
  trap cleanup EXIT
  sleep 1
  if ! kill -0 "${SERVER_PID}" 2>/dev/null; then
    echo "failed to start relay test server: ${SERVER_PATH}" >&2
    exit 1
  fi
fi

if [ -z "${RELAY_SIGNER_URL}" ] && \
  { [ -n "${RELAY_SIGN_PRIVATE_KEY_FILE:-}" ] || [ -n "${BIT_RELAY_SIGN_PRIVATE_KEY_FILE:-}" ]; }; then
  node "${SIGNER_PATH}" "${RELAY_SIGNER_PORT}" >"${RELAY_SIGNER_LOG}" 2>&1 &
  SIGNER_PID=$!
  trap cleanup EXIT
  sleep 1
  if ! kill -0 "${SIGNER_PID}" 2>/dev/null; then
    echo "failed to start relay signer: ${SIGNER_PATH}" >&2
    exit 1
  fi
  RELAY_SIGNER_URL="http://127.0.0.1:${RELAY_SIGNER_PORT}"
fi

if [ -n "${RELAY_SIGNER_URL}" ] && [ -z "${RELAY_SENDER_PREFIX:-}" ]; then
  RELAY_SENDER_PREFIX="k6-signed-$(date +%s)"
fi

export RELAY_BASE_URL
export RELAY_SIGNER_URL
export RELAY_SENDER_PREFIX

echo "k6 target: ${RELAY_BASE_URL}"
echo "k6 scenario: ${SCENARIO_PATH}"
if [ -n "${RELAY_SIGNER_URL}" ]; then
  echo "k6 signer: ${RELAY_SIGNER_URL}"
fi
k6 run "$@" "${SCENARIO_PATH}"

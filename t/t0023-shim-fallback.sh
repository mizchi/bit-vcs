#!/bin/sh
#
# Test git-shim fallback logic for unsupported commands.

. "$(dirname "$0")/test-lib.sh"

test_description="git-shim fallback to alternate real git for unsupported subcommands"

shim="$BIT_BUILD_DIR/tools/git-shim/bin/git"

setup_stubs() {
cat >primary-git <<'EOF'
#!/bin/sh
has_send_email=0
for arg in "$@"; do
  if [ "$arg" = "send-email" ]; then
    has_send_email=1
    break
  fi
done
if [ "$has_send_email" -eq 1 ]; then
  echo "git: 'send-email' is not a git command." >&2
  exit 1
fi
echo "primary:$*" >> "$SHIM_TEST_TRACE"
exit 0
EOF
chmod +x primary-git

cat >fallback-git <<'EOF'
#!/bin/sh
echo "fallback:$*" >> "$SHIM_TEST_TRACE"
exit 0
EOF
chmod +x fallback-git
}

test_expect_success 'fallback is used when primary git does not support subcommand' '
  test_path_is_file "$shim" &&
  setup_stubs &&
  : >trace &&
  SHIM_TEST_TRACE="$PWD/trace" \
  SHIM_REAL_GIT="$PWD/primary-git" \
  SHIM_REAL_GIT_FALLBACK="$PWD/fallback-git" \
  "$shim" send-email --from=ci@example.com &&
  grep -q "^fallback:send-email --from=ci@example.com$" trace &&
  ! grep -q "^primary:send-email " trace
'

test_expect_success 'no fallback when primary git supports subcommand' '
  setup_stubs &&
  : >trace &&
  SHIM_TEST_TRACE="$PWD/trace" \
  SHIM_REAL_GIT="$PWD/primary-git" \
  SHIM_REAL_GIT_FALLBACK="$PWD/fallback-git" \
  "$shim" status &&
  grep -q "^primary:status$" trace &&
  ! grep -q "^fallback:" trace
'

test_expect_success 'fallback is used when primary lacks help target subcommand' '
  setup_stubs &&
  : >trace &&
  SHIM_TEST_TRACE="$PWD/trace" \
  SHIM_REAL_GIT="$PWD/primary-git" \
  SHIM_REAL_GIT_FALLBACK="$PWD/fallback-git" \
  "$shim" help send-email &&
  grep -q "^fallback:help send-email$" trace &&
  ! grep -q "^primary:help send-email$" trace
'

test_expect_success 'fallback is used when primary lacks help target with help options' '
  setup_stubs &&
  : >trace &&
  SHIM_TEST_TRACE="$PWD/trace" \
  SHIM_REAL_GIT="$PWD/primary-git" \
  SHIM_REAL_GIT_FALLBACK="$PWD/fallback-git" \
  "$shim" help --man send-email &&
  grep -q "^fallback:help --man send-email$" trace &&
  ! grep -q "^primary:help --man send-email$" trace
'

test_expect_success 'fallback is used when global option appears before help' '
  setup_stubs &&
  : >trace &&
  SHIM_TEST_TRACE="$PWD/trace" \
  SHIM_REAL_GIT="$PWD/primary-git" \
  SHIM_REAL_GIT_FALLBACK="$PWD/fallback-git" \
  "$shim" --git-dir=.git help send-email &&
  grep -q "^fallback:--git-dir=.git help send-email$" trace
'

test_done

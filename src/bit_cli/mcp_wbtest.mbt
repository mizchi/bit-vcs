///|
test "mcp: help arg detector" {
  assert_true(mcp_has_help_arg(["-h"]))
  assert_true(mcp_has_help_arg(["help"]))
  assert_true(mcp_has_help_arg(["--help", "extra"]))
  assert_false(mcp_has_help_arg(["--verbose"]))
  assert_false(mcp_has_help_arg([]))
}

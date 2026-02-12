#!/bin/bash
#
# e2e: mcp subcommand wiring and git compatibility non-regression

source "$(dirname "$0")/test-lib-e2e.sh"

test_expect_success 'mcp: --help prints usage and exits' '
    git_cmd mcp --help >out &&
    grep -q "Usage: bit mcp" out &&
    grep -q "Start bit MCP server" out
'

test_expect_success 'mcp: help subcommand path works' '
    git_cmd help mcp >help.out &&
    grep -q "Usage: bit mcp" help.out
'

test_expect_success 'mcp: command exists in shell completion list' '
    git_cmd completion bash >completion.sh &&
    grep -q "mcp" completion.sh
'

test_expect_success 'mcp help does not break normal git workflow' '
    git_cmd init &&
    git_cmd mcp --help >/dev/null &&
    echo "hello" >hello.txt &&
    git_cmd add hello.txt &&
    git_cmd commit -m "mcp help non-regression" &&
    git_cmd log --oneline | grep -q "mcp help non-regression"
'

test_done

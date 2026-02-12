#!/bin/bash
#
# e2e: rebase-ai command compatibility and AI-trigger behavior

source "$(dirname "$0")/test-lib-e2e.sh"

test_expect_success 'rebase-ai: clean rebase succeeds without OPENROUTER_API_KEY when no conflict' '
    git_cmd init &&
    echo "base" > shared.txt &&
    git_cmd add shared.txt &&
    git_cmd commit -m "base" &&
    git_cmd checkout -b feature &&
    echo "feature" > feature.txt &&
    git_cmd add feature.txt &&
    git_cmd commit -m "feature" &&
    git_cmd checkout main &&
    echo "main" > main.txt &&
    git_cmd add main.txt &&
    git_cmd commit -m "main" &&
    git_cmd checkout feature &&
    OPENROUTER_API_KEY="" git_cmd rebase-ai main >/dev/null &&
    test_path_is_missing .git/rebase-merge
'

test_expect_success 'rebase-ai: conflict requires OPENROUTER_API_KEY and --abort works' '
    git_cmd init &&
    echo "base" > conflict.txt &&
    git_cmd add conflict.txt &&
    git_cmd commit -m "base" &&
    git_cmd checkout -b feature &&
    echo "feature" > conflict.txt &&
    git_cmd add conflict.txt &&
    git_cmd commit -m "feature" &&
    git_cmd checkout main &&
    echo "main" > conflict.txt &&
    git_cmd add conflict.txt &&
    git_cmd commit -m "main" &&
    git_cmd checkout feature &&
    if OPENROUTER_API_KEY="" git_cmd rebase-ai main >rebase.out 2>rebase.err; then
        false
    else
        grep -q "OPENROUTER_API_KEY" rebase.err
    fi &&
    test_dir_exists .git/rebase-merge &&
    OPENROUTER_API_KEY="" git_cmd rebase-ai --abort >/dev/null &&
    test_path_is_missing .git/rebase-merge
'

test_expect_success 'rebase-ai: --agent-loop conflict requires OPENROUTER_API_KEY and --abort works' '
    git_cmd init &&
    echo "base" > conflict.txt &&
    git_cmd add conflict.txt &&
    git_cmd commit -m "base" &&
    git_cmd checkout -b feature &&
    echo "feature" > conflict.txt &&
    git_cmd add conflict.txt &&
    git_cmd commit -m "feature" &&
    git_cmd checkout main &&
    echo "main" > conflict.txt &&
    git_cmd add conflict.txt &&
    git_cmd commit -m "main" &&
    git_cmd checkout feature &&
    if OPENROUTER_API_KEY="" git_cmd rebase-ai --agent-loop main >loop.out 2>loop.err; then
        false
    else
        grep -q "OPENROUTER_API_KEY" loop.err
    fi &&
    test_dir_exists .git/rebase-merge &&
    OPENROUTER_API_KEY="" git_cmd rebase-ai --abort >/dev/null &&
    test_path_is_missing .git/rebase-merge
'

test_expect_success 'rebase-ai: --continue without rebase in progress fails' '
    git_cmd init &&
    echo "base" > README.md &&
    git_cmd add README.md &&
    git_cmd commit -m "base" &&
    if git_cmd rebase-ai --continue >continue.out 2>continue.err; then
        false
    else
        grep -q "No rebase in progress" continue.err
    fi
'

test_done

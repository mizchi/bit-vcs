#!/bin/bash
#
# e2e: debug helper creates intentional conflict state for rebase-ai

source "$(dirname "$0")/test-lib-e2e.sh"

test_expect_success 'test-ai helper creates rebase conflict and supports abort' '
    OPENROUTER_API_KEY="" DEBUG_ROOT="$TRASH_DIR" BIT_BIN="$MOONGIT" "$PROJECT_ROOT/tools/test-ai.sh" >setup.out &&
    repo_dir=$(grep "^TEST_AI_REPO=" setup.out | sed "s/^TEST_AI_REPO=//") &&
    demo_exit=$(grep "^TEST_AI_DEMO_EXIT=" setup.out | sed "s/^TEST_AI_DEMO_EXIT=//") &&
    test -n "$repo_dir" &&
    test "$demo_exit" != "0" &&
    test_dir_exists "$repo_dir/.git/rebase-merge" &&
    grep -q "<<<<<<<" "$repo_dir/conflict.txt" &&
    (cd "$repo_dir" && "$MOONGIT" --no-git-fallback rebase-ai --abort >/dev/null) &&
    test_path_is_missing "$repo_dir/.git/rebase-merge"
'

test_done

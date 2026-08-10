#!/bin/sh
#
# Linked worktree private/common git directory separation
#

test_description='linked worktree commits use shared objects, refs, and config'

TEST_DIRECTORY=$(cd "$(dirname "$0")" && pwd)
. "$TEST_DIRECTORY/test-lib.sh"

test_expect_success 'setup main repository and linked worktree' '
	mkdir repo &&
	(cd repo &&
	 $BIT init -q . &&
	 $BIT config user.name repro &&
	 $BIT config user.email repro@example.invalid &&
	 printf "base\n" >sample.txt &&
	 $BIT add sample.txt &&
	 $BIT commit -m base >/dev/null &&
	 $BIT rev-parse HEAD >../base &&
	 $BIT worktree add -b repro/worktree ../worker HEAD)
'

test_expect_success 'repository-local config is visible in linked worktree' '
	(cd worker &&
	 test "$($BIT config user.name)" = repro &&
	 test "$($BIT config user.email)" = repro@example.invalid)
'

test_expect_success 'linked worktree commit has clean index and status' '
	(cd worker &&
	 printf "worker\n" >>sample.txt &&
	 $BIT add sample.txt &&
	 $BIT commit -m worker >/dev/null &&
	 $BIT rev-parse HEAD >../worker-commit &&
	 $BIT diff --quiet &&
	 $BIT diff --cached --quiet &&
	 test -z "$($BIT status --porcelain)")
'

test_expect_success 'linked commit is stored in the common object database' '
	commit=$(cat worker-commit) &&
	prefix=$(printf "%s" "$commit" | cut -c1-2) &&
	suffix=$(printf "%s" "$commit" | cut -c3-) &&
	test_path_is_file "repo/.git/objects/$prefix/$suffix" &&
	test_path_is_missing repo/.git/worktrees/worker/objects
'

test_expect_success 'main worktree can show and diff linked commit' '
	base=$(cat base) &&
	commit=$(cat worker-commit) &&
	(cd repo &&
	 $BIT show --stat --oneline "$commit" >/dev/null &&
	 $BIT diff "$base" "$commit" -- >/dev/null)
'

test_expect_success 'worktree list reports linked commit' '
	commit=$(cat worker-commit) &&
	(cd repo && $BIT worktree list --porcelain >../worktree-list) &&
	grep "HEAD $commit" worktree-list
'

test_expect_success 'main worktree can cherry-pick linked commit' '
	commit=$(cat worker-commit) &&
	(cd repo && $BIT cherry-pick "$commit" >/dev/null)
'

test_expect_success 'clean linked worktree can be removed without force' '
	(cd repo && $BIT worktree remove ../worker) &&
	test_path_is_missing worker
'

test_done

#!/bin/sh
#
# Basic git notes tests (subset of git t3301-notes.sh)
#

test_description='git notes basic behavior'

TEST_DIRECTORY=$(cd "$(dirname "$0")" && pwd)
. "$TEST_DIRECTORY/test-lib.sh"

# Setup repository with two commits

test_expect_success 'setup: repo with commits' '
	mkdir repo &&
	(cd repo &&
	 $BIT init &&
	 echo "one" > file.txt &&
	 $BIT add file.txt &&
	 $BIT commit -m "c1" &&
	 echo "two" >> file.txt &&
	 $BIT add file.txt &&
	 $BIT commit -m "c2")
'

test_expect_success 'notes list is empty initially' '
	(cd repo &&
	 $BIT notes list > out &&
	 test "$(wc -l < out | tr -d " ")" = "0")
'

test_expect_failure 'notes show fails without note' '
	(cd repo &&
	 $BIT notes show HEAD)
'

test_expect_failure 'notes add without message fails' '
	(cd repo &&
	 $BIT notes add HEAD)
'

test_expect_success 'notes add creates note and show prints it' '
	(cd repo &&
	 $BIT notes add -m "note-1" HEAD &&
	 echo "note-1" > expect &&
	 $BIT notes show HEAD > actual &&
	 test_cmp expect actual)
'

test_expect_success 'notes list shows note blob and commit' '
	(cd repo &&
	 $BIT notes list > out &&
	 test "$(wc -l < out | tr -d " ")" = "1" &&
	 commit=$(cut -d" " -f2 out) &&
	 test "$commit" = "$( $BIT rev-parse HEAD )")
'

test_expect_failure 'notes add without -f on existing note fails' '
	(cd repo &&
	 $BIT notes add -m "note-2" HEAD)
'

test_expect_success 'notes add -f overwrites note' '
	(cd repo &&
	 $BIT notes add -f -m "note-2" HEAD &&
	 echo "note-2" > expect &&
	 $BIT notes show HEAD > actual &&
	 test_cmp expect actual)
'

test_expect_success 'notes remove deletes note' '
	(cd repo &&
	 $BIT notes remove HEAD)
'

test_expect_failure 'notes show fails after remove' '
	(cd repo &&
	 $BIT notes show HEAD)
'

test_expect_success 'notes list empty after remove' '
	(cd repo &&
	 $BIT notes list > out &&
	 test "$(wc -l < out | tr -d " ")" = "0")
'

test_expect_success 'notes prune removes notes for missing object' '
	mkdir prune &&
	(cd prune &&
	 $BIT init &&
	 echo "prune" > p.txt &&
	 $BIT add p.txt &&
	 $BIT commit -m "p1" &&
	 $BIT notes add -m "note" HEAD &&
	 commit=$( $BIT rev-parse HEAD ) &&
	 obj_dir=$(printf "%s" "$commit" | cut -c1-2) &&
	 obj_file=$(printf "%s" "$commit" | cut -c3-) &&
	 rm -f ".git/objects/$obj_dir/$obj_file" &&
	 $BIT notes prune > out &&
	 grep "Pruned 1 notes" out &&
	 $BIT notes list > list &&
	 test "$(wc -l < list | tr -d " ")" = "0")
'

test_done

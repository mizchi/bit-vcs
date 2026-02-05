#!/bin/sh
#
# Additional git notes tests (multi-note scenarios)
#

test_description='git notes multiple entries'

TEST_DIRECTORY=$(cd "$(dirname "$0")" && pwd)
. "$TEST_DIRECTORY/test-lib.sh"

test_expect_success 'setup: repo with three commits' '
	mkdir repo &&
	(cd repo &&
	 $BIT init &&
	 echo "one" > file.txt &&
	 $BIT add file.txt &&
	 $BIT commit -m "c1" &&
	 echo "two" >> file.txt &&
	 $BIT add file.txt &&
	 $BIT commit -m "c2" &&
	 echo "three" >> file.txt &&
	 $BIT add file.txt &&
	 $BIT commit -m "c3" &&
	 c1=$( $BIT rev-parse HEAD~2 ) &&
	 c2=$( $BIT rev-parse HEAD~1 ) &&
	 c3=$( $BIT rev-parse HEAD ) &&
	 echo "$c1" > c1 &&
	 echo "$c2" > c2 &&
	 echo "$c3" > c3)
'

test_expect_success 'notes add on explicit commits' '
	(cd repo &&
	 c1=$(cat c1) &&
	 c3=$(cat c3) &&
	 $BIT notes add -m "note-c1" "$c1" &&
	 $BIT notes add -m "note-c3" "$c3")
'

test_expect_success 'notes show works for commit id and HEAD' '
	(cd repo &&
	 c1=$(cat c1) &&
	 echo "note-c1" > expect1 &&
	 $BIT notes show "$c1" > actual1 &&
	 test_cmp expect1 actual1 &&
	 echo "note-c3" > expect2 &&
	 $BIT notes show HEAD > actual2 &&
	 test_cmp expect2 actual2)
'

test_expect_success 'notes list includes both commits' '
	(cd repo &&
	 c1=$(cat c1) &&
	 c3=$(cat c3) &&
	 $BIT notes list > list &&
	 test_line_count = list 2 &&
	 grep " $c1" list &&
	 grep " $c3" list)
'

test_expect_success 'notes remove only removes target' '
	(cd repo &&
	 c1=$(cat c1) &&
	 c3=$(cat c3) &&
	 $BIT notes remove "$c1" &&
	 $BIT notes list > list &&
	 test_line_count = list 1 &&
	 grep " $c3" list)
'

test_expect_failure 'notes show fails for removed note' '
	(cd repo &&
	 c1=$(cat c1) &&
	 $BIT notes show "$c1")
'

test_expect_success 'notes add -f updates existing note' '
	(cd repo &&
	 c3=$(cat c3) &&
	 $BIT notes add -f -m "note-c3-v2" "$c3" &&
	 echo "note-c3-v2" > expect &&
	 $BIT notes show "$c3" > actual &&
	 test_cmp expect actual)
'

test_expect_failure 'notes show fails on unknown revision' '
	(cd repo &&
	 $BIT notes show does-not-exist)
'

test_expect_failure 'notes add fails on unknown revision' '
	(cd repo &&
	 $BIT notes add -m "nope" does-not-exist)
'

test_done

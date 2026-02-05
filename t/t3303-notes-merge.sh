#!/bin/sh
#
# Notes merge tests
#

test_description='git notes merge'

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

test_expect_success 'setup: add notes on different refs' '
	(cd repo &&
	 c1=$(cat c1) &&
	 c2=$(cat c2) &&
	 $BIT notes add -m "note-c1" "$c1" &&
	 $BIT notes --ref=other add -m "note-c2" "$c2")
'

test_expect_success 'notes merge brings other ref notes' '
	(cd repo &&
	 c1=$(cat c1) &&
	 c2=$(cat c2) &&
	 $BIT notes merge other &&
	 $BIT notes list > list &&
	 test_line_count = list 2 &&
	 grep " $c1" list &&
	 grep " $c2" list &&
	 echo "note-c2" > expect &&
	 $BIT notes show "$c2" > actual &&
	 test_cmp expect actual)
'

test_expect_success 'setup: conflicting notes in both refs' '
	(cd repo &&
	 c3=$(cat c3) &&
	 $BIT notes add -m "note-c3-ours" "$c3" &&
	 $BIT notes --ref=other add -m "note-c3-theirs" "$c3")
'

test_expect_failure 'notes merge fails on conflict' '
	(cd repo &&
	 $BIT notes merge other)
'

test_done

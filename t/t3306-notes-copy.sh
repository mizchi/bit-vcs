#!/bin/sh
#
# Notes copy tests
#

test_description='git notes copy'

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

test_expect_success 'notes copy from c1 to c2' '
	(cd repo &&
	 c1=$(cat c1) &&
	 c2=$(cat c2) &&
	 $BIT notes add -m "note-c1" "$c1" &&
	 $BIT notes copy "$c1" "$c2" &&
	 echo "note-c1" > expect &&
	 $BIT notes show "$c2" > actual &&
	 test_cmp expect actual)
'

test_expect_failure 'notes copy fails when dest already has note' '
	(cd repo &&
	 c1=$(cat c1) &&
	 c2=$(cat c2) &&
	 $BIT notes copy "$c1" "$c2")
'

test_expect_success 'notes copy -f overwrites dest note' '
	(cd repo &&
	 c1=$(cat c1) &&
	 c2=$(cat c2) &&
	 $BIT notes add -f -m "note-c2" "$c2" &&
	 $BIT notes copy -f "$c1" "$c2" &&
	 echo "note-c1" > expect &&
	 $BIT notes show "$c2" > actual &&
	 test_cmp expect actual)
'

test_expect_failure 'notes copy fails when source has no note' '
	(cd repo &&
	 c2=$(cat c2) &&
	 c3=$(cat c3) &&
	 $BIT notes copy "$c3" "$c2")
'

test_done

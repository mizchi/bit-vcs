#!/bin/sh
#
# Notes rewrite tests
#

test_description='git notes rewrite'

TEST_DIRECTORY=$(cd "$(dirname "$0")" && pwd)
. "$TEST_DIRECTORY/test-lib.sh"

test_expect_success 'setup: repo with two commits' '
	mkdir repo &&
	(cd repo &&
	 $BIT init &&
	 echo "one" > file.txt &&
	 $BIT add file.txt &&
	 $BIT commit -m "c1" &&
	 echo "two" >> file.txt &&
	 $BIT add file.txt &&
	 $BIT commit -m "c2" &&
	 c1=$( $BIT rev-parse HEAD~1 ) &&
	 c2=$( $BIT rev-parse HEAD ) &&
	 echo "$c1" > c1 &&
	 echo "$c2" > c2)
'

test_expect_success 'rewrite moves note to new commit' '
	(cd repo &&
	 c1=$(cat c1) &&
	 c2=$(cat c2) &&
	 $BIT notes add -m "note-c1" "$c1" &&
	 $BIT notes rewrite "$c1" "$c2" &&
	 echo "note-c1" > expect &&
	 $BIT notes show "$c2" > actual &&
	 test_cmp expect actual)
'

test_expect_failure 'rewrite removes old note' '
	(cd repo &&
	 c1=$(cat c1) &&
	 $BIT notes show "$c1")
'

test_expect_success 'rewrite fails when dest has note' '
	(cd repo &&
	 c1=$(cat c1) &&
	 c2=$(cat c2) &&
	 $BIT notes add -m "note-c1-new" "$c1" &&
	 ! $BIT notes rewrite "$c1" "$c2")
'

test_expect_success 'rewrite -f overwrites dest' '
	(cd repo &&
	 c1=$(cat c1) &&
	 c2=$(cat c2) &&
	 $BIT notes rewrite -f "$c1" "$c2" &&
	 echo "note-c1-new" > expect &&
	 $BIT notes show "$c2" > actual &&
	 test_cmp expect actual)
'

test_done

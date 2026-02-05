#!/bin/sh
#
# Notes merge auto-resolve tests
#

test_description='git notes merge auto-resolve'

TEST_DIRECTORY=$(cd "$(dirname "$0")" && pwd)
. "$TEST_DIRECTORY/test-lib.sh"

test_expect_success 'setup: repo with commit' '
	mkdir repo &&
	(cd repo &&
	 $BIT init &&
	 echo "one" > file.txt &&
	 $BIT add file.txt &&
	 $BIT commit -m "c1" &&
	 c1=$( $BIT rev-parse HEAD ) &&
	 echo "$c1" > c1)
'

test_expect_success 'setup: conflicting notes' '
	(cd repo &&
	 c1=$(cat c1) &&
	 $BIT notes add -m "note-ours" "$c1" &&
	 $BIT notes --ref=other add -m "note-theirs" "$c1")
'

test_expect_success 'merge --strategy=ours keeps ours' '
	(cd repo &&
	 c1=$(cat c1) &&
	 $BIT notes merge --strategy=ours other &&
	 echo "note-ours" > expect &&
	 $BIT notes show "$c1" > actual &&
	 test_cmp expect actual)
'

test_expect_success 'merge --strategy=theirs overwrites' '
	(cd repo &&
	 c1=$(cat c1) &&
	 $BIT notes --ref=other add -f -m "note-theirs-2" "$c1" &&
	 $BIT notes merge --strategy=theirs other &&
	 echo "note-theirs-2" > expect &&
	 $BIT notes show "$c1" > actual &&
	 test_cmp expect actual)
'

test_expect_success 'merge --strategy=union concatenates' '
	(cd repo &&
	 c1=$(cat c1) &&
	 $BIT notes add -f -m "ours-1" "$c1" &&
	 $BIT notes --ref=other add -f -m "theirs-1" "$c1" &&
	 $BIT notes merge --strategy=union other &&
	 printf "ours-1\ntheirs-1\n" > expect &&
	 $BIT notes show "$c1" > actual &&
	 test_cmp expect actual)
'

test_expect_success 'merge --strategy=cat_sort_uniq sorts unique lines' '
	(cd repo &&
	 c1=$(cat c1) &&
	 $BIT notes add -f -m "b" "$c1" &&
	 $BIT notes append -m "c" "$c1" &&
	 $BIT notes --ref=other add -f -m "a" "$c1" &&
	 $BIT notes --ref=other append -m "c" "$c1" &&
	 $BIT notes merge --strategy=cat_sort_uniq other &&
	 printf "a\nb\nc\n" > expect &&
	 $BIT notes show "$c1" > actual &&
	 test_cmp expect actual)
'

test_done

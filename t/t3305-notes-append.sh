#!/bin/sh
#
# Notes append tests
#

test_description='git notes append'

TEST_DIRECTORY=$(cd "$(dirname "$0")" && pwd)
. "$TEST_DIRECTORY/test-lib.sh"

test_expect_success 'setup: repo with commit' '
	mkdir repo &&
	(cd repo &&
	 $BIT init &&
	 echo "one" > file.txt &&
	 $BIT add file.txt &&
	 $BIT commit -m "c1")
'

test_expect_success 'notes append creates note when missing' '
	(cd repo &&
	 $BIT notes append -m "first" HEAD &&
	 echo "first" > expect &&
	 $BIT notes show HEAD > actual &&
	 test_cmp expect actual)
'

test_expect_success 'notes append adds new line' '
	(cd repo &&
	 $BIT notes append -m "second" HEAD &&
	 printf "first\nsecond\n" > expect &&
	 $BIT notes show HEAD > actual &&
	 test_cmp expect actual)
'

test_done

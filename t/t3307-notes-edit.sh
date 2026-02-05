#!/bin/sh
#
# Notes edit tests
#

test_description='git notes edit'

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

test_expect_failure 'notes edit requires message' '
	(cd repo &&
	 $BIT notes edit HEAD)
'

test_expect_success 'notes edit creates note' '
	(cd repo &&
	 $BIT notes edit -m "edit-1" HEAD &&
	 echo "edit-1" > expect &&
	 $BIT notes show HEAD > actual &&
	 test_cmp expect actual)
'

test_expect_success 'notes edit overwrites existing note' '
	(cd repo &&
	 $BIT notes edit -m "edit-2" HEAD &&
	 echo "edit-2" > expect &&
	 $BIT notes show HEAD > actual &&
	 test_cmp expect actual)
'

test_done

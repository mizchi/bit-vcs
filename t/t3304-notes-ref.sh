#!/bin/sh
#
# Notes --ref tests
#

test_description='git notes --ref'

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

test_expect_success 'notes add with --ref' '
	(cd repo &&
	 $BIT notes --ref=review add -m "note-review" HEAD)
'

test_expect_failure 'default ref does not see custom ref note' '
	(cd repo &&
	 $BIT notes show HEAD)
'

test_expect_success 'custom ref show works' '
	(cd repo &&
	 echo "note-review" > expect &&
	 $BIT notes --ref=review show HEAD > actual &&
	 test_cmp expect actual)
'

test_expect_success 'custom ref list includes commit' '
	(cd repo &&
	 commit=$( $BIT rev-parse HEAD ) &&
	 $BIT notes --ref=review list > list &&
	 test_line_count = list 1 &&
	 grep " $commit" list)
'

test_expect_success 'full ref path works' '
	(cd repo &&
	 $BIT notes --ref=refs/notes/extra add -m "note-extra" HEAD &&
	 echo "note-extra" > expect &&
	 $BIT notes --ref=extra show HEAD > actual &&
	 test_cmp expect actual)
'

test_done

///| Tests for diff3 content-level merge

///|
test "myers_diff: identical inputs" {
  let a = ["a\n", "b\n", "c\n"]
  let edits = myers_diff(a, a)
  // All should be Keep operations
  let mut keep_count = 0
  for e in edits {
    match e {
      Keep(_, _) => keep_count = keep_count + 1
      _ => ()
    }
  }
  assert_eq(keep_count, 3)
}

///|
test "myers_diff: empty inputs" {
  let edits = myers_diff([], [])
  assert_eq(edits.length(), 0)
}

///|
test "myers_diff: insert into empty" {
  let edits = myers_diff([], ["a\n", "b\n"])
  assert_eq(edits.length(), 2)
  for e in edits {
    match e {
      Insert(_) => ()
      _ => assert_true(false)
    }
  }
}

///|
test "myers_diff: delete all" {
  let edits = myers_diff(["a\n", "b\n"], [])
  assert_eq(edits.length(), 2)
  for e in edits {
    match e {
      Delete(_) => ()
      _ => assert_true(false)
    }
  }
}

///|
test "myers_diff: single change in middle" {
  let old = ["a\n", "b\n", "c\n"]
  let new = ["a\n", "x\n", "c\n"]
  let edits = myers_diff(old, new)
  let changes = extract_changes(edits)
  assert_eq(changes.length(), 1)
  assert_eq(changes[0].base_start, 1)
  assert_eq(changes[0].base_end, 2)
  assert_eq(changes[0].new_start, 1)
  assert_eq(changes[0].new_end, 2)
}

///|
test "content_merge: only ours changed" {
  let base = "a\nb\nc\n"
  let ours = "a\nx\nc\n"
  let theirs = "a\nb\nc\n"
  let result = content_merge(base, ours, theirs, ContentMergeOptions::default())
  assert_false(result.has_conflicts)
  assert_eq(result.content, "a\nx\nc\n")
}

///|
test "content_merge: only theirs changed" {
  let base = "a\nb\nc\n"
  let ours = "a\nb\nc\n"
  let theirs = "a\ny\nc\n"
  let result = content_merge(base, ours, theirs, ContentMergeOptions::default())
  assert_false(result.has_conflicts)
  assert_eq(result.content, "a\ny\nc\n")
}

///|
test "content_merge: both changed same way" {
  let base = "a\nb\nc\n"
  let ours = "a\nx\nc\n"
  let theirs = "a\nx\nc\n"
  let result = content_merge(base, ours, theirs, ContentMergeOptions::default())
  assert_false(result.has_conflicts)
  assert_eq(result.content, "a\nx\nc\n")
}

///|
test "content_merge: non-overlapping changes" {
  let base = "a\nb\nc\nd\ne\n"
  let ours = "a\nx\nc\nd\ne\n"
  let theirs = "a\nb\nc\ny\ne\n"
  let result = content_merge(base, ours, theirs, ContentMergeOptions::default())
  assert_false(result.has_conflicts)
  assert_eq(result.content, "a\nx\nc\ny\ne\n")
}

///|
test "content_merge: conflict - merge style" {
  let base = "a\nb\nc\n"
  let ours = "a\nx\nc\n"
  let theirs = "a\ny\nc\n"
  let result = content_merge(base, ours, theirs, ContentMergeOptions::default())
  assert_true(result.has_conflicts)
  assert_eq(result.conflict_count, 1)
  assert_true(result.content.contains("<<<<<<< HEAD"))
  assert_true(result.content.contains("======="))
  assert_true(result.content.contains(">>>>>>> incoming"))
  assert_true(result.content.contains("x\n"))
  assert_true(result.content.contains("y\n"))
}

///|
test "content_merge: conflict - diff3 style" {
  let base = "a\nb\nc\n"
  let ours = "a\nx\nc\n"
  let theirs = "a\ny\nc\n"
  let opts : ContentMergeOptions = {
    conflict_style: ConflictStyle::Diff3,
    ours_label: "HEAD",
    base_label: "base",
    theirs_label: "incoming",
    marker_size: 7,
    favor: MergeFavor::NoFavor,
  }
  let result = content_merge(base, ours, theirs, opts)
  assert_true(result.has_conflicts)
  assert_true(result.content.contains("||||||| base"))
  assert_true(result.content.contains("b\n"))
}

///|
test "content_merge: favor ours" {
  let base = "a\nb\nc\n"
  let ours = "a\nx\nc\n"
  let theirs = "a\ny\nc\n"
  let opts : ContentMergeOptions = {
    ..ContentMergeOptions::default(),
    favor: MergeFavor::FavorOurs,
  }
  let result = content_merge(base, ours, theirs, opts)
  assert_false(result.has_conflicts)
  assert_eq(result.content, "a\nx\nc\n")
}

///|
test "content_merge: favor theirs" {
  let base = "a\nb\nc\n"
  let ours = "a\nx\nc\n"
  let theirs = "a\ny\nc\n"
  let opts : ContentMergeOptions = {
    ..ContentMergeOptions::default(),
    favor: MergeFavor::FavorTheirs,
  }
  let result = content_merge(base, ours, theirs, opts)
  assert_false(result.has_conflicts)
  assert_eq(result.content, "a\ny\nc\n")
}

///|
test "content_merge: empty base" {
  let base = ""
  let ours = "a\n"
  let theirs = "b\n"
  let result = content_merge(base, ours, theirs, ContentMergeOptions::default())
  assert_true(result.has_conflicts)
  assert_eq(result.conflict_count, 1)
}

///|
test "content_merge: all empty" {
  let result = content_merge("", "", "", ContentMergeOptions::default())
  assert_false(result.has_conflicts)
  assert_eq(result.content, "")
}

///|
test "content_merge: no trailing newline" {
  let base = "a\nb\nc"
  let ours = "a\nx\nc"
  let theirs = "a\nb\nc"
  let result = content_merge(base, ours, theirs, ContentMergeOptions::default())
  assert_false(result.has_conflicts)
  assert_eq(result.content, "a\nx\nc")
}

///|
test "split_lines: basic" {
  let lines = split_lines("a\nb\nc\n")
  assert_eq(lines.length(), 3)
  assert_eq(lines[0], "a\n")
  assert_eq(lines[1], "b\n")
  assert_eq(lines[2], "c\n")
}

///|
test "split_lines: no trailing newline" {
  let lines = split_lines("a\nb")
  assert_eq(lines.length(), 2)
  assert_eq(lines[0], "a\n")
  assert_eq(lines[1], "b")
}

///|
test "split_lines: empty string" {
  let lines = split_lines("")
  assert_eq(lines.length(), 0)
}

///|
test "is_binary_content: text" {
  let data = Bytes::from_array([65, 66, 67, 10]) // "ABC\n"
  assert_false(is_binary_content(data))
}

///|
test "is_binary_content: binary with null byte" {
  let data = Bytes::from_array([65, 0, 67, 10]) // "A\0C\n"
  assert_true(is_binary_content(data))
}

///|
test "content_merge: multi-line conflict" {
  let base = "header\na\nb\nfooter\n"
  let ours = "header\nx\ny\nfooter\n"
  let theirs = "header\np\nq\nfooter\n"
  let result = content_merge(base, ours, theirs, ContentMergeOptions::default())
  assert_true(result.has_conflicts)
  assert_eq(result.conflict_count, 1)
  assert_true(result.content.has_prefix("header\n"))
  assert_true(result.content.has_suffix("footer\n"))
}

///|
test "content_merge: marker size" {
  let base = "a\nb\nc\n"
  let ours = "a\nx\nc\n"
  let theirs = "a\ny\nc\n"
  let opts : ContentMergeOptions = {
    ..ContentMergeOptions::default(),
    marker_size: 3,
  }
  let result = content_merge(base, ours, theirs, opts)
  assert_true(result.content.contains("<<< HEAD"))
  assert_true(result.content.contains("===\n"))
  assert_true(result.content.contains(">>> incoming"))
}

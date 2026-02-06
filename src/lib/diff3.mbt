///| Content-level 3-way merge using Myers diff + diff3 algorithm

///|
pub enum ConflictStyle {
  Merge
  Diff3
}

///|
pub enum MergeFavor {
  NoFavor
  FavorOurs
  FavorTheirs
}

///|
pub struct ContentMergeOptions {
  conflict_style : ConflictStyle
  ours_label : String
  base_label : String
  theirs_label : String
  marker_size : Int
  favor : MergeFavor
}

///|
pub fn ContentMergeOptions::default() -> ContentMergeOptions {
  {
    conflict_style: ConflictStyle::Merge,
    ours_label: "HEAD",
    base_label: "parent",
    theirs_label: "incoming",
    marker_size: 7,
    favor: MergeFavor::NoFavor,
  }
}

///|
pub fn ContentMergeOptions::favor_ours() -> ContentMergeOptions {
  { ..ContentMergeOptions::default(), favor: MergeFavor::FavorOurs }
}

///|
pub fn ContentMergeOptions::favor_theirs() -> ContentMergeOptions {
  { ..ContentMergeOptions::default(), favor: MergeFavor::FavorTheirs }
}

///|
pub struct ContentMergeResult {
  content : String
  has_conflicts : Bool
  conflict_count : Int
}

///|
priv enum EditOp {
  Keep(Int, Int)
  Delete(Int)
  Insert(Int)
}

///|
priv struct ChangeRange {
  base_start : Int
  base_end : Int
  new_start : Int
  new_end : Int
}

///|
priv enum Diff3Section {
  Clean(Array[String])
  Conflict(
    ours~ : Array[String],
    base~ : Array[String],
    theirs~ : Array[String]
  )
}

///|
fn split_lines(text : String) -> Array[String] {
  if text.length() == 0 {
    return []
  }
  let lines : Array[String] = []
  let sb = StringBuilder::new()
  for c in text {
    sb.write_char(c)
    if c == '\n' {
      lines.push(sb.to_string())
      sb.reset()
    }
  }
  let remaining = sb.to_string()
  if remaining.length() > 0 {
    lines.push(remaining)
  }
  lines
}

///|
fn myers_diff(old : Array[String], new : Array[String]) -> Array[EditOp] {
  let n = old.length()
  let m = new.length()
  if n == 0 && m == 0 {
    return []
  }
  if n == 0 {
    return Array::makei(m, fn(j) { EditOp::Insert(j) })
  }
  if m == 0 {
    return Array::makei(n, fn(i) { EditOp::Delete(i) })
  }
  let max = n + m
  let size = 2 * max + 1
  // v[k + max] = x-coordinate of the furthest reaching path for diagonal k
  let v : Array[Int] = Array::make(size, 0)
  // Store traces for backtracking
  let traces : Array[Array[Int]] = []
  let mut found = false
  let mut final_d = 0
  for d = 0; d <= max; d = d + 1 {
    traces.push(v.copy())
    for k = -d; k <= d; k = k + 2 {
      let idx = k + max
      let mut x = if k == -d || (k != d && v[idx - 1] < v[idx + 1]) {
        v[idx + 1]
      } else {
        v[idx - 1] + 1
      }
      let mut y = x - k
      while x < n && y < m && old[x] == new[y] {
        x = x + 1
        y = y + 1
      }
      v[idx] = x
      if x >= n && y >= m {
        final_d = d
        found = true
        break
      }
    }
    if found {
      break
    }
  }
  // Backtrack to find the edit sequence
  let edits : Array[EditOp] = []
  let mut cx = n
  let mut cy = m
  for d = final_d; d > 0; d = d - 1 {
    let prev_v = traces[d]
    let k = cx - cy
    let idx = k + max
    let prev_k = if k == -d || (k != d && prev_v[idx - 1] < prev_v[idx + 1]) {
      k + 1
    } else {
      k - 1
    }
    let prev_x = prev_v[prev_k + max]
    let prev_y = prev_x - prev_k
    // Diagonal moves (matches)
    while cx > prev_x && cy > prev_y {
      cx = cx - 1
      cy = cy - 1
      edits.push(EditOp::Keep(cx, cy))
    }
    if cx > prev_x {
      cx = cx - 1
      edits.push(EditOp::Delete(cx))
    } else if cy > prev_y {
      cy = cy - 1
      edits.push(EditOp::Insert(cy))
    }
  }
  // Remaining diagonal moves at d=0
  while cx > 0 && cy > 0 {
    cx = cx - 1
    cy = cy - 1
    edits.push(EditOp::Keep(cx, cy))
  }
  edits.rev()
}

///|
fn extract_changes(edits : Array[EditOp]) -> Array[ChangeRange] {
  let changes : Array[ChangeRange] = []
  let mut i = 0
  let len = edits.length()
  while i < len {
    match edits[i] {
      Keep(_, _) => i = i + 1
      _ => {
        let mut base_start = -1
        let mut base_end = -1
        let mut new_start = -1
        let mut new_end = -1
        while i < len {
          match edits[i] {
            Keep(_, _) => break
            Delete(bi) => {
              if base_start < 0 {
                base_start = bi
              }
              base_end = bi + 1
              i = i + 1
            }
            Insert(ni) => {
              if new_start < 0 {
                new_start = ni
              }
              new_end = ni + 1
              i = i + 1
            }
          }
        }
        // For insert-only changes, base range is empty at the insert point
        // We need to find the base position from the surrounding context
        if base_start < 0 && base_end < 0 {
          // Pure insert - find position from the new_start
          // The base position is where the insert happens in the base sequence
          // Look at the previous Keep to determine base position
          let pos = find_base_pos_for_insert(edits, i)
          base_start = pos
          base_end = pos
        }
        if base_start < 0 {
          base_start = base_end
        }
        if new_start < 0 && new_end < 0 {
          // Pure delete
          let pos = find_new_pos_for_delete(edits, i)
          new_start = pos
          new_end = pos
        }
        if new_start < 0 {
          new_start = new_end
        }
        changes.push({ base_start, base_end, new_start, new_end })
      }
    }
  }
  changes
}

///|
fn find_base_pos_for_insert(edits : Array[EditOp], current_idx : Int) -> Int {
  // Look backward for the last Keep or Delete to find base position
  let mut j = current_idx - 1
  while j >= 0 {
    match edits[j] {
      Keep(bi, _) => return bi + 1
      Delete(bi) => return bi + 1
      _ => j = j - 1
    }
  }
  0
}

///|
fn find_new_pos_for_delete(edits : Array[EditOp], current_idx : Int) -> Int {
  let mut j = current_idx - 1
  while j >= 0 {
    match edits[j] {
      Keep(_, ni) => return ni + 1
      Insert(ni) => return ni + 1
      _ => j = j - 1
    }
  }
  0
}

///|
fn ranges_overlap(a : ChangeRange, b : ChangeRange) -> Bool {
  // Empty ranges at the same position count as overlapping (both insert at same point)
  if a.base_start == a.base_end && b.base_start == b.base_end {
    a.base_start == b.base_start
  } else if a.base_start == a.base_end {
    a.base_start >= b.base_start && a.base_start < b.base_end
  } else if b.base_start == b.base_end {
    b.base_start >= a.base_start && b.base_start < a.base_end
  } else {
    a.base_start < b.base_end && b.base_start < a.base_end
  }
}

///|
fn lines_equal(
  a : Array[String],
  a_start : Int,
  a_end : Int,
  b : Array[String],
  b_start : Int,
  b_end : Int,
) -> Bool {
  let a_len = a_end - a_start
  let b_len = b_end - b_start
  if a_len != b_len {
    return false
  }
  for i in 0..<a_len {
    if a[a_start + i] != b[b_start + i] {
      return false
    }
  }
  true
}

///|
fn slice_lines(lines : Array[String], start : Int, end : Int) -> Array[String] {
  let result : Array[String] = []
  for i in start..<end {
    result.push(lines[i])
  }
  result
}

///|
fn diff3_merge(
  base : Array[String],
  ours : Array[String],
  theirs : Array[String],
) -> Array[Diff3Section] {
  let edits_ours = myers_diff(base, ours)
  let edits_theirs = myers_diff(base, theirs)
  let changes_ours = extract_changes(edits_ours)
  let changes_theirs = extract_changes(edits_theirs)
  let sections : Array[Diff3Section] = []
  let mut oi = 0
  let mut ti = 0
  let mut base_pos = 0
  while oi < changes_ours.length() || ti < changes_theirs.length() {
    let ours_change = if oi < changes_ours.length() {
      Some(changes_ours[oi])
    } else {
      None
    }
    let theirs_change = if ti < changes_theirs.length() {
      Some(changes_theirs[ti])
    } else {
      None
    }
    match (ours_change, theirs_change) {
      (Some(o), Some(t)) =>
        if ranges_overlap(o, t) {
          // Emit clean lines before the overlap
          let overlap_start = if o.base_start < t.base_start {
            o.base_start
          } else {
            t.base_start
          }
          if base_pos < overlap_start {
            sections.push(
              Diff3Section::Clean(slice_lines(base, base_pos, overlap_start)),
            )
          }
          // Check if both sides made the same change
          let ours_lines = slice_lines(ours, o.new_start, o.new_end)
          let theirs_lines = slice_lines(theirs, t.new_start, t.new_end)
          if lines_equal(
              ours_lines,
              0,
              ours_lines.length(),
              theirs_lines,
              0,
              theirs_lines.length(),
            ) {
            sections.push(Diff3Section::Clean(ours_lines))
          } else {
            let overlap_end = if o.base_end > t.base_end {
              o.base_end
            } else {
              t.base_end
            }
            let base_lines = slice_lines(base, overlap_start, overlap_end)
            sections.push(
              Diff3Section::Conflict(
                ours=ours_lines,
                base=base_lines,
                theirs=theirs_lines,
              ),
            )
          }
          let new_base_pos = if o.base_end > t.base_end {
            o.base_end
          } else {
            t.base_end
          }
          base_pos = new_base_pos
          oi = oi + 1
          ti = ti + 1
        } else if o.base_start <= t.base_start {
          // Ours comes first, no overlap
          if base_pos < o.base_start {
            sections.push(
              Diff3Section::Clean(slice_lines(base, base_pos, o.base_start)),
            )
          }
          sections.push(
            Diff3Section::Clean(slice_lines(ours, o.new_start, o.new_end)),
          )
          base_pos = o.base_end
          oi = oi + 1
        } else {
          // Theirs comes first, no overlap
          if base_pos < t.base_start {
            sections.push(
              Diff3Section::Clean(slice_lines(base, base_pos, t.base_start)),
            )
          }
          sections.push(
            Diff3Section::Clean(slice_lines(theirs, t.new_start, t.new_end)),
          )
          base_pos = t.base_end
          ti = ti + 1
        }
      (Some(o), None) => {
        if base_pos < o.base_start {
          sections.push(
            Diff3Section::Clean(slice_lines(base, base_pos, o.base_start)),
          )
        }
        sections.push(
          Diff3Section::Clean(slice_lines(ours, o.new_start, o.new_end)),
        )
        base_pos = o.base_end
        oi = oi + 1
      }
      (None, Some(t)) => {
        if base_pos < t.base_start {
          sections.push(
            Diff3Section::Clean(slice_lines(base, base_pos, t.base_start)),
          )
        }
        sections.push(
          Diff3Section::Clean(slice_lines(theirs, t.new_start, t.new_end)),
        )
        base_pos = t.base_end
        ti = ti + 1
      }
      (None, None) => break
    }
  }
  // Remaining base lines
  if base_pos < base.length() {
    sections.push(
      Diff3Section::Clean(slice_lines(base, base_pos, base.length())),
    )
  }
  sections
}

///|
fn render_marker(ch : Char, size : Int, label : String) -> String {
  let sb = StringBuilder::new()
  for _ in 0..<size {
    sb.write_char(ch)
  }
  if label.length() > 0 {
    sb.write_char(' ')
    sb.write_string(label)
  }
  sb.write_char('\n')
  sb.to_string()
}

///|
pub fn content_merge(
  base_text : String,
  ours_text : String,
  theirs_text : String,
  options : ContentMergeOptions,
) -> ContentMergeResult {
  let base_lines = split_lines(base_text)
  let ours_lines = split_lines(ours_text)
  let theirs_lines = split_lines(theirs_text)
  let sections = diff3_merge(base_lines, ours_lines, theirs_lines)
  let sb = StringBuilder::new()
  let mut conflict_count = 0
  for section in sections {
    match section {
      Diff3Section::Clean(lines) =>
        for line in lines {
          sb.write_string(line)
        }
      Diff3Section::Conflict(ours~, base~, theirs~) =>
        match options.favor {
          MergeFavor::FavorOurs =>
            for line in ours {
              sb.write_string(line)
            }
          MergeFavor::FavorTheirs =>
            for line in theirs {
              sb.write_string(line)
            }
          MergeFavor::NoFavor => {
            conflict_count = conflict_count + 1
            sb.write_string(
              render_marker('<', options.marker_size, options.ours_label),
            )
            for line in ours {
              sb.write_string(line)
            }
            match options.conflict_style {
              ConflictStyle::Diff3 => {
                sb.write_string(
                  render_marker('|', options.marker_size, options.base_label),
                )
                for line in base {
                  sb.write_string(line)
                }
              }
              ConflictStyle::Merge => ()
            }
            sb.write_string(render_marker('=', options.marker_size, ""))
            for line in theirs {
              sb.write_string(line)
            }
            sb.write_string(
              render_marker('>', options.marker_size, options.theirs_label),
            )
          }
        }
    }
  }
  { content: sb.to_string(), has_conflicts: conflict_count > 0, conflict_count }
}

///|
fn is_binary_content(data : Bytes) -> Bool {
  let check_len = if data.length() < 8000 { data.length() } else { 8000 }
  for i in 0..<check_len {
    if data[i] == b'\x00' {
      return true
    }
  }
  false
}

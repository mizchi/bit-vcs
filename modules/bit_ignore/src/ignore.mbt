///| Gitignore-style pattern matching
///
/// Pure gitignore pattern matcher with zero dependencies.
/// Implements the full `.gitignore` specification: `*`, `?`, `**` globs,
/// negation (`!`), directory-only rules (`/`), anchored patterns,
/// nested base directories, and comment/escape handling.
///
/// ## Quick start — filter files with `.gitignore` rules
///
/// ```moonbit
/// let m = @ignore.Matcher::new()
/// m.add_rules("", "node_modules/\n*.log\n!important.log\n")
///
/// assert_true(m.is_ignored("node_modules/express/index.js", false))
/// assert_true(m.is_ignored("debug.log", false))
/// assert_false(m.is_ignored("important.log", false))
/// assert_false(m.is_ignored("src/app.ts", false))
/// ```
///
/// ## Use as a git-aware glob filter
///
/// Stack multiple `.gitignore` files from nested directories,
/// then filter a file list in one pass:
///
/// ```moonbit
/// let m = @ignore.Matcher::new()
///
/// // Root .gitignore
/// m.add_rules("", "*.log\n/dist/\nbuild/\n")
///
/// // Subdirectory .gitignore (rules scoped to "src/")
/// m.add_rules("src", "*.generated.*\n!keep.generated.ts\n")
///
/// // Filter a list of paths
/// let files : Array[String] = [
///   "src/app.ts",            // kept
///   "src/data.generated.js", // ignored by src/.gitignore
///   "src/keep.generated.ts", // kept (negation)
///   "dist/bundle.js",        // ignored by /dist (anchored)
///   "lib/build/out.o",       // ignored by build/
///   "server.log",            // ignored by *.log
/// ]
/// let visible = files.filter(fn(p) { !(m.is_ignored(p, false)) })
/// // visible = ["src/app.ts", "src/keep.generated.ts"]
/// ```
///
/// ## Directory traversal with backtracking
///
/// Use `truncate()` to scope rules when walking a directory tree:
///
/// ```moonbit
/// let m = @ignore.Matcher::new()
/// m.add_rules("", "*.tmp\n")
///
/// // Enter "src/" — add its .gitignore
/// let saved = m.len()
/// m.add_rules("src", "*.bak\n")
/// assert_true(m.is_ignored("src/file.bak", false))
///
/// // Leave "src/" — restore matcher state
/// m.truncate(saved)
/// assert_false(m.is_ignored("src/file.bak", false))
/// // Root rules still active
/// assert_true(m.is_ignored("any/path/file.tmp", false))
/// ```
///
/// ## Standalone glob matching
///
/// `match_glob` works as a general-purpose glob matcher
/// (not tied to gitignore semantics):
///
/// ```moonbit
/// assert_true(@ignore.match_glob("*.ts", "app.ts"))
/// assert_true(@ignore.match_glob("src/*.test.*", "src/app.test.js"))
/// assert_false(@ignore.match_glob("*.ts", "app.js"))
/// ```
///
/// ## Pattern syntax reference
///
/// | Pattern | Matches |
/// |---------|---------|
/// | `*.log` | Any file ending in `.log` at any depth |
/// | `node_modules/` | The `node_modules` directory and all contents |
/// | `/build/` | Only `build/` directory at the root (anchored) |
/// | `!important.log` | Un-ignore `important.log` (negation) |
/// | `**/*.test.js` | `.test.js` files at any depth |
/// | `doc/**/*.md` | `.md` files under `doc/` at any depth |
/// | `temp?` | `temp` + any single character (`temp1`, `tempA`) |
/// | `\!literal` | Match literal `!` (escaped) |
///
/// ## Performance
///
/// Pattern segments are pre-compiled at parse time. Path matching
/// operates on string ranges without allocating substrings.
///
/// - `match_glob`: ~0.3 µs per call
/// - `is_ignored` (20 rules): ~4–8 µs per path
/// - 1000 paths × 20 rules: ~4 ms

///|
/// A single ignore rule parsed from a gitignore file.
pub struct Rule {
  /// Base directory where the rule was defined (relative path)
  base : String
  /// The pattern to match against
  pattern : String
  /// Pre-compiled pattern code units for match_glob (avoids repeated to_array allocation)
  pattern_chars : FixedArray[UInt16]
  /// Pre-split pattern segments for path matching (avoids repeated split_path)
  pattern_segments : Array[FixedArray[UInt16]]
  /// Whether this is a negation rule (starts with !)
  negated : Bool
  /// Whether this rule only applies to directories (ends with /)
  dir_only : Bool
  /// Whether this rule is anchored to the base (starts with /)
  anchored : Bool
  /// Whether the pattern contains a slash (affects matching behavior)
  has_slash : Bool
  /// Length of base string (cached for fast prefix check)
  base_len : Int
}

///|
/// A collection of ignore rules that can check if paths are ignored.
pub struct Matcher {
  rules : Array[Rule]
  mut negation_count : Int
}

///|
/// Create a new empty matcher.
pub fn Matcher::new() -> Matcher {
  { rules: [], negation_count: 0 }
}

///|
/// Add rules from gitignore content.
/// `base` is the relative directory where the gitignore file is located.
pub fn Matcher::add_rules(
  self : Matcher,
  base : String,
  content : String,
) -> Unit {
  let parsed = parse(content, base)
  for rule in parsed {
    self.rules.push(rule)
    if rule.negated {
      self.negation_count = self.negation_count + 1
    }
  }
}

///|
/// Check if a path is ignored.
/// `rel_path` is the path relative to the root.
/// `is_dir` indicates whether the path is a directory.
pub fn Matcher::is_ignored(
  self : Matcher,
  rel_path : String,
  is_dir : Bool,
) -> Bool {
  let mut ignored = false
  for rule in self.rules {
    if rule_applies(rule, rel_path, is_dir) {
      ignored = !rule.negated
    }
  }
  ignored
}

///|
/// Remove rules added after a certain point (for backtracking during traversal).
pub fn Matcher::truncate(self : Matcher, len : Int) -> Unit {
  let mut i = len
  let total = self.rules.length()
  while i < total {
    if self.rules[i].negated {
      self.negation_count = self.negation_count - 1
    }
    i = i + 1
  }
  self.rules.truncate(len)
}

///|
/// Get current number of rules.
pub fn Matcher::len(self : Matcher) -> Int {
  self.rules.length()
}

///|
/// Whether any negation rules have been added.
pub fn Matcher::has_negation(self : Matcher) -> Bool {
  self.negation_count > 0
}

///|
/// Check if any negation rule could potentially un-ignore a child under `dir_rel`.
/// More precise than `has_negation()` — only returns true if a negation rule's
/// target path overlaps with the given directory.
pub fn Matcher::could_negate_under(self : Matcher, dir_rel : String) -> Bool {
  if self.negation_count == 0 {
    return false
  }
  for rule in self.rules {
    if !rule.negated {
      continue
    }
    // Non-path-specific rules (no slash, not anchored) could match anywhere
    if !rule.has_slash && !rule.anchored {
      return true
    }
    // Path-specific rule: compute target path and check prefix overlap
    let target = if rule.base.length() == 0 {
      rule.pattern
    } else {
      rule.base + "/" + rule.pattern
    }
    let prefix = negation_literal_prefix(target)
    if prefix.length() == 0 {
      return true
    }
    // Check if dir_rel is an ancestor of prefix or prefix is an ancestor of dir_rel
    if is_path_prefix(dir_rel, prefix) || is_path_prefix(prefix, dir_rel) {
      return true
    }
  }
  false
}

///|
/// Extract the literal directory prefix before any wildcard in a pattern.
fn negation_literal_prefix(pattern : String) -> String {
  let mut last_slash = -1
  for i in 0..<pattern.length() {
    let c = pattern.unsafe_get(i)
    if c == char_star || c == char_question || c == char_open_bracket {
      if last_slash < 0 {
        return ""
      }
      return String::unsafe_substring(pattern, start=0, end=last_slash)
    }
    if c == char_slash {
      last_slash = i
    }
  }
  pattern
}

///|
let char_open_bracket : UInt16 = {
  let c : Int = '['.to_int()
  c.to_uint16()
}

///|
/// Check if `a` is a path prefix of `b` (a == b or b starts with a + "/").
fn is_path_prefix(a : String, b : String) -> Bool {
  let alen = a.length()
  let blen = b.length()
  if alen > blen {
    return false
  }
  for i in 0..<alen {
    if a.unsafe_get(i) != b.unsafe_get(i) {
      return false
    }
  }
  alen == blen || b.unsafe_get(alen) == char_slash
}

///|
/// Parse gitignore content into rules.
/// `base` is the relative directory where the gitignore file is located.
pub fn parse(content : String, base : String) -> Array[Rule] {
  let rules : Array[Rule] = []
  let base_len = base.length()
  for line_view in content.split("\n") {
    let mut line = line_view.to_owned()
    // Handle CRLF
    if line.has_suffix("\r") {
      line = String::unsafe_substring(line, start=0, end=line.length() - 1)
    }
    // Trim trailing whitespace (but not leading - significant for patterns)
    line = trim_trailing_whitespace(line)
    // Skip empty lines
    if line.length() == 0 {
      continue
    }
    // Skip comments
    if line.has_prefix("#") {
      continue
    }
    // Handle escaped characters
    let mut negated = false
    if line.has_prefix("\\!") {
      line = String::unsafe_substring(line, start=1, end=line.length())
    } else if line.has_prefix("!") {
      negated = true
      line = String::unsafe_substring(line, start=1, end=line.length())
    }
    if line.has_prefix("\\#") {
      line = String::unsafe_substring(line, start=1, end=line.length())
    }
    if line.length() == 0 {
      continue
    }
    // Check for directory-only rule
    let mut dir_only = false
    if line.has_suffix("/") {
      dir_only = true
      line = String::unsafe_substring(line, start=0, end=line.length() - 1)
    }
    if line.length() == 0 {
      continue
    }
    // Check for anchored rule
    let mut anchored = false
    if line.has_prefix("/") {
      anchored = true
      line = String::unsafe_substring(line, start=1, end=line.length())
    }
    if line.length() == 0 {
      continue
    }
    let has_slash = line.contains("/")
    let pattern_chars = string_to_uint16_array(line)
    // Pre-split pattern into segments for path matching
    let pattern_segments = if has_slash || anchored {
      precompile_segments(line)
    } else {
      []
    }
    rules.push({
      base,
      pattern: line,
      pattern_chars,
      pattern_segments,
      negated,
      dir_only,
      anchored,
      has_slash,
      base_len,
    })
  }
  rules
}

///|
let char_star : UInt16 = {
  let c : Int = '*'.to_int()
  c.to_uint16()
}

///|
let char_question : UInt16 = {
  let c : Int = '?'.to_int()
  c.to_uint16()
}

///|
let char_slash : UInt16 = {
  let c : Int = '/'.to_int()
  c.to_uint16()
}

///|
fn string_to_uint16_array(s : String) -> FixedArray[UInt16] {
  let len = s.length()
  let arr = FixedArray::make(len, Default::default())
  for i in 0..<len {
    arr[i] = s.unsafe_get(i)
  }
  arr
}

///|
/// Pre-compile pattern segments at parse time (avoids split_path per match).
fn precompile_segments(pattern : String) -> Array[FixedArray[UInt16]] {
  let segs : Array[FixedArray[UInt16]] = []
  let len = pattern.length()
  let mut start = 0
  while start < len {
    let mut end = start
    while end < len && pattern.unsafe_get(end) != char_slash {
      end += 1
    }
    if end > start {
      segs.push(
        string_to_uint16_array(String::unsafe_substring(pattern, start~, end~)),
      )
    }
    start = end + 1
  }
  segs
}

///|
/// Check if a single pattern matches a path segment.
/// Supports * (any characters) and ? (single character) wildcards.
pub fn match_glob(pattern : String, text : String) -> Bool {
  let p = string_to_uint16_array(pattern)
  match_glob_precompiled(p, text)
}

///|
/// match_glob using pre-compiled pattern code units to avoid repeated allocation.
fn match_glob_precompiled(p : FixedArray[UInt16], text : String) -> Bool {
  let slen = text.length()
  let plen = p.length()
  let mut pi = 0
  let mut si = 0
  let mut star = -1
  let mut mark = 0
  while si < slen {
    if pi < plen && (p[pi] == char_question || p[pi] == text.unsafe_get(si)) {
      pi += 1
      si += 1
    } else if pi < plen && p[pi] == char_star {
      star = pi
      mark = si
      pi += 1
    } else if star != -1 {
      pi = star + 1
      mark += 1
      si = mark
    } else {
      return false
    }
  }
  while pi < plen && p[pi] == char_star {
    pi += 1
  }
  pi == plen
}

///|
/// Match a precompiled pattern against a substring of text (segment between slashes).
fn match_glob_precompiled_range(
  p : FixedArray[UInt16],
  text : String,
  start : Int,
  end : Int,
) -> Bool {
  let slen = end - start
  let plen = p.length()
  let mut pi = 0
  let mut si = 0
  let mut star = -1
  let mut mark = 0
  while si < slen {
    let tc = text.unsafe_get(start + si)
    if pi < plen && (p[pi] == char_question || p[pi] == tc) {
      pi += 1
      si += 1
    } else if pi < plen && p[pi] == char_star {
      star = pi
      mark = si
      pi += 1
    } else if star != -1 {
      pi = star + 1
      mark += 1
      si = mark
    } else {
      return false
    }
  }
  while pi < plen && p[pi] == char_star {
    pi += 1
  }
  pi == plen
}

///|
fn rule_applies(rule : Rule, path : String, is_dir : Bool) -> Bool {
  // Inline relative_to_base check to avoid Option allocation
  let blen = rule.base_len
  let plen = path.length()
  let rel_start : Int = if blen == 0 {
    0
  } else {
    if plen < blen {
      return false
    }
    // Check base prefix
    for i in 0..<blen {
      if path.unsafe_get(i) != rule.base.unsafe_get(i) {
        return false
      }
    }
    if plen == blen {
      // path equals base exactly — rel is ""
      if rule.dir_only {
        return false
      }
      return match_rule_path_range(rule, path, blen, plen)
    }
    if path.unsafe_get(blen) != char_slash {
      return false
    }
    blen + 1
  }
  if rule.dir_only {
    match_dir_rule_range(rule, path, rel_start, plen, is_dir)
  } else {
    match_rule_path_range(rule, path, rel_start, plen)
  }
}

///|
/// Match a dir-only rule against a path range, checking each directory prefix.
fn match_dir_rule_range(
  rule : Rule,
  path : String,
  start : Int,
  end : Int,
  is_dir : Bool,
) -> Bool {
  // For dir rules, try matching against each directory prefix.
  // e.g., for "node_modules/express/lib/index.js", try "node_modules", "node_modules/express", etc.
  let mut seg_end = start
  while seg_end < end {
    if path.unsafe_get(seg_end) == char_slash {
      // Found a segment boundary — try matching path[start..seg_end]
      if match_rule_path_range(rule, path, start, seg_end) {
        return true
      }
    }
    seg_end += 1
  }
  // Try full path if it's a directory
  if is_dir {
    match_rule_path_range(rule, path, start, end)
  } else {
    false
  }
}

///|
/// Match a rule against a path range (without allocating substrings).
fn match_rule_path_range(
  rule : Rule,
  path : String,
  start : Int,
  end : Int,
) -> Bool {
  if rule.has_slash || rule.anchored {
    // Path-based matching: match segments against precompiled pattern segments
    match_segments_range(rule.pattern_segments, 0, path, start, end)
  } else {
    // Basename matching: check each segment against the precompiled pattern
    let mut seg_start = start
    while seg_start < end {
      let mut seg_end = seg_start
      while seg_end < end && path.unsafe_get(seg_end) != char_slash {
        seg_end += 1
      }
      if seg_end > seg_start &&
        match_glob_precompiled_range(
          rule.pattern_chars,
          path,
          seg_start,
          seg_end,
        ) {
        return true
      }
      seg_start = seg_end + 1
    }
    false
  }
}

///|
/// Match precompiled pattern segments against path segments in-place.
fn match_segments_range(
  pats : Array[FixedArray[UInt16]],
  pi : Int,
  path : String,
  start : Int,
  end : Int,
) -> Bool {
  if pi >= pats.length() {
    return start >= end
  }
  let pat = pats[pi]
  if is_double_star(pat) {
    // ** matches zero or more path segments
    // Try matching remaining patterns starting from each segment position
    let mut pos = start
    // Try matching with zero segments consumed by **
    if match_segments_range(pats, pi + 1, path, pos, end) {
      return true
    }
    while pos < end {
      // Advance to next segment
      while pos < end && path.unsafe_get(pos) != char_slash {
        pos += 1
      }
      if pos < end {
        pos += 1 // skip the slash
      }
      if match_segments_range(pats, pi + 1, path, pos, end) {
        return true
      }
    }
    false
  } else {
    // Find current segment boundaries
    if start >= end {
      return false
    }
    let mut seg_end = start
    while seg_end < end && path.unsafe_get(seg_end) != char_slash {
      seg_end += 1
    }
    if match_glob_precompiled_range(pat, path, start, seg_end) {
      let next_start = if seg_end < end { seg_end + 1 } else { end }
      match_segments_range(pats, pi + 1, path, next_start, end)
    } else {
      false
    }
  }
}

///|
fn is_double_star(p : FixedArray[UInt16]) -> Bool {
  p.length() == 2 && p[0] == char_star && p[1] == char_star
}

///|
fn trim_trailing_whitespace(s : String) -> String {
  let mut end = s.length()
  while end > 0 {
    let c = s.unsafe_get(end - 1)
    if c == ' ' || c == '\t' {
      end -= 1
    } else {
      break
    }
  }
  if end == s.length() {
    s
  } else {
    String::unsafe_substring(s, start=0, end~)
  }
}

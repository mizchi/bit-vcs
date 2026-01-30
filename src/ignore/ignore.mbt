///| Gitignore-style pattern matching

///|
/// A single ignore rule parsed from a gitignore file.
pub struct Rule {
  /// Base directory where the rule was defined (relative path)
  base : String
  /// The pattern to match against
  pattern : String
  /// Whether this is a negation rule (starts with !)
  negated : Bool
  /// Whether this rule only applies to directories (ends with /)
  dir_only : Bool
  /// Whether this rule is anchored to the base (starts with /)
  anchored : Bool
  /// Whether the pattern contains a slash (affects matching behavior)
  has_slash : Bool
}

///|
/// A collection of ignore rules that can check if paths are ignored.
pub struct Matcher {
  rules : Array[Rule]
}

///|
/// Create a new empty matcher.
pub fn Matcher::new() -> Matcher {
  { rules: [] }
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
      ignored = not(rule.negated)
    }
  }
  ignored
}

///|
/// Remove rules added after a certain point (for backtracking during traversal).
pub fn Matcher::truncate(self : Matcher, len : Int) -> Unit {
  self.rules.truncate(len)
}

///|
/// Get current number of rules.
pub fn Matcher::len(self : Matcher) -> Int {
  self.rules.length()
}

///|
/// Parse gitignore content into rules.
/// `base` is the relative directory where the gitignore file is located.
pub fn parse(content : String, base : String) -> Array[Rule] {
  let rules : Array[Rule] = []
  for line_view in content.split("\n") {
    let mut line = line_view.to_string()
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
    rules.push({ base, pattern: line, negated, dir_only, anchored, has_slash })
  }
  rules
}

///|
/// Check if a single pattern matches a path segment.
/// Supports * (any characters) and ? (single character) wildcards.
pub fn match_glob(pattern : String, text : String) -> Bool {
  let p = pattern.to_array()
  let s = text.to_array()
  let mut pi = 0
  let mut si = 0
  let mut star = -1
  let mut mark = 0
  while si < s.length() {
    if pi < p.length() && (p[pi] == '?' || p[pi] == s[si]) {
      pi += 1
      si += 1
    } else if pi < p.length() && p[pi] == '*' {
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
  while pi < p.length() && p[pi] == '*' {
    pi += 1
  }
  pi == p.length()
}

///|
fn rule_applies(rule : Rule, path : String, is_dir : Bool) -> Bool {
  match relative_to_base(path, rule.base) {
    None => false
    Some(rel) =>
      if rule.dir_only {
        match_dir_rule(rule, rel, is_dir)
      } else {
        match_rule_path(rule, rel)
      }
  }
}

///|
fn match_dir_rule(rule : Rule, rel : String, is_dir : Bool) -> Bool {
  let segs = split_path(rel)
  let max_len = if is_dir { segs.length() } else { segs.length() - 1 }
  if max_len <= 0 {
    return false
  }
  for len in 1..<=max_len {
    let prefix = join_segments(segs, len)
    if match_rule_path(rule, prefix) {
      return true
    }
  }
  false
}

///|
fn match_rule_path(rule : Rule, rel : String) -> Bool {
  if rule.has_slash || rule.anchored {
    match_path(rule.pattern, rel)
  } else {
    let segs = split_path(rel)
    for seg in segs {
      if match_glob(rule.pattern, seg) {
        return true
      }
    }
    false
  }
}

///|
fn match_path(pattern : String, path : String) -> Bool {
  let pats = split_path(pattern)
  let segs = split_path(path)
  match_segments(pats, 0, segs, 0)
}

///|
fn match_segments(
  pats : Array[String],
  pi : Int,
  segs : Array[String],
  si : Int,
) -> Bool {
  if pi >= pats.length() {
    return si >= segs.length()
  }
  let pat = pats[pi]
  if pat == "**" {
    let mut k = si
    while true {
      if match_segments(pats, pi + 1, segs, k) {
        return true
      }
      if k >= segs.length() {
        break
      }
      k += 1
    }
    false
  } else {
    if si >= segs.length() {
      return false
    }
    if match_glob(pat, segs[si]) {
      match_segments(pats, pi + 1, segs, si + 1)
    } else {
      false
    }
  }
}

///|
fn relative_to_base(path : String, base : String) -> String? {
  if base == "" {
    return Some(path)
  }
  if path == base {
    return Some("")
  }
  if path.has_prefix(base + "/") {
    let start = base.length() + 1
    Some(String::unsafe_substring(path, start~, end=path.length()))
  } else {
    None
  }
}

///|
fn split_path(path : String) -> Array[String] {
  let out : Array[String] = []
  if path.length() == 0 {
    return out
  }
  for part_view in path.split("/") {
    let part = part_view.to_string()
    if part.length() == 0 {
      continue
    }
    out.push(part)
  }
  out
}

///|
fn join_segments(segs : Array[String], len : Int) -> String {
  if len <= 0 {
    return ""
  }
  let sb = StringBuilder::new()
  for i in 0..<len {
    if i > 0 {
      sb.write_char('/')
    }
    sb.write_string(segs[i])
  }
  sb.to_string()
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

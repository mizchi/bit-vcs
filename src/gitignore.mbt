///| Gitignore parsing + working tree listing

///|
priv struct IgnoreRule {
  base : String
  pattern : String
  negated : Bool
  dir_only : Bool
  anchored : Bool
  has_slash : Bool
}

///|
priv struct IgnoreMatcher {
  rules : Array[IgnoreRule]
}

///|
fn IgnoreMatcher::new() -> IgnoreMatcher {
  { rules: [] }
}

///|
fn IgnoreMatcher::push_rules(
  self : IgnoreMatcher,
  base : String,
  content : String,
) -> Unit {
  let parsed = parse_gitignore(content, base)
  for rule in parsed {
    self.rules.push(rule)
  }
}

///|
fn IgnoreMatcher::is_ignored(
  self : IgnoreMatcher,
  rel_path : String,
  is_dir : Bool,
) -> Bool {
  let mut ignored = false
  for rule in self.rules {
    match rule_applies(rule, rel_path, is_dir) {
      true => ignored = not(rule.negated)
      false => ()
    }
  }
  ignored
}

///|
/// Check if a relative path is ignored by .gitignore files under root.
/// This mimics `git ls-files --others --exclude-standard` behavior for ignores.
pub fn is_ignored_path(
  fs : &RepoFileSystem,
  root : String,
  rel_path : String,
  is_dir : Bool,
) -> Bool raise GitError {
  let matcher = IgnoreMatcher::new()
  let segments = split_path(rel_path)
  let mut base = ""
  // root .gitignore
  let root_ignore = join_path(root, ".gitignore")
  if fs.is_file(root_ignore) {
    let content = @utf8.decode_lossy(fs.read_file(root_ignore)[:])
    matcher.push_rules(base, content)
  }
  for i in 0..<segments.length() {
    let seg = segments[i]
    base = if base == "" { seg } else { base + "/" + seg }
    let dir_path = join_path(root, base)
    if fs.is_dir(dir_path) {
      let ignore_path = join_path(dir_path, ".gitignore")
      if fs.is_file(ignore_path) {
        let content = @utf8.decode_lossy(fs.read_file(ignore_path)[:])
        matcher.push_rules(base, content)
      }
    }
  }
  matcher.is_ignored(rel_path, is_dir)
}

///|
/// List files under root, excluding ignored paths and .git.
pub fn list_working_files(
  fs : &RepoFileSystem,
  root : String,
) -> Array[String] raise GitError {
  let matcher = IgnoreMatcher::new()
  let out : Array[String] = []
  walk_dir(fs, root, "", matcher, out)
  out
}

///|
fn walk_dir(
  fs : &RepoFileSystem,
  root : String,
  rel : String,
  matcher : IgnoreMatcher,
  out : Array[String],
) -> Unit raise GitError {
  let dir = if rel == "" { root } else { join_path(root, rel) }
  let prev_len = matcher.rules.length()
  let ignore_path = join_path(dir, ".gitignore")
  if fs.is_file(ignore_path) {
    let content = @utf8.decode_lossy(fs.read_file(ignore_path)[:])
    matcher.push_rules(rel, content)
  }
  let entries = fs.readdir(dir)
  for name in entries {
    if name == "." || name == ".." {
      continue
    }
    if rel == "" && name == ".git" {
      continue
    }
    let child_rel = if rel == "" { name } else { rel + "/" + name }
    let child_path = join_path(root, child_rel)
    let is_dir = fs.is_dir(child_path)
    let is_file = fs.is_file(child_path)
    if matcher.is_ignored(child_rel, is_dir) {
      // Still traverse to allow negations in nested .gitignore
      if is_dir {
        walk_dir(fs, root, child_rel, matcher, out)
      }
      continue
    }
    if is_dir {
      walk_dir(fs, root, child_rel, matcher, out)
    } else if is_file {
      out.push(child_rel)
    }
  }
  matcher.rules.truncate(prev_len)
}

///|
fn parse_gitignore(content : String, base : String) -> Array[IgnoreRule] {
  let rules : Array[IgnoreRule] = []
  for line_view in content.split("\n") {
    let mut line = line_view.to_string()
    if line.has_suffix("\r") {
      line = String::unsafe_substring(line, start=0, end=line.length() - 1)
    }
    if line.length() == 0 {
      continue
    }
    if line.has_prefix("#") {
      continue
    }
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
    let mut dir_only = false
    if line.has_suffix("/") {
      dir_only = true
      line = String::unsafe_substring(line, start=0, end=line.length() - 1)
    }
    if line.length() == 0 {
      continue
    }
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
fn rule_applies(rule : IgnoreRule, path : String, is_dir : Bool) -> Bool {
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
fn match_dir_rule(rule : IgnoreRule, rel : String, is_dir : Bool) -> Bool {
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
fn match_rule_path(rule : IgnoreRule, rel : String) -> Bool {
  if rule.has_slash || rule.anchored {
    match_path(rule.pattern, rel)
  } else {
    let segs = split_path(rel)
    for seg in segs {
      if match_segment(rule.pattern, seg) {
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
    if match_segment(pat, segs[si]) {
      match_segments(pats, pi + 1, segs, si + 1)
    } else {
      false
    }
  }
}

///|
fn match_segment(pattern : String, text : String) -> Bool {
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

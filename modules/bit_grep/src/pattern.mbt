///|
pub(all) enum GrepPatternType {
  Fixed
  Basic
  Extended
  Perl
} derive(Eq, Debug)

///|
pub(all) struct GrepMatchSpan {
  start_column : Int
  end_column : Int
} derive(Eq, Debug)

///|
pub(all) enum GrepExprToken {
  Pattern(String)
  And
  Or
  Not
  LParen
  RParen
} derive(Eq, Debug)

///|
pub(all) enum GrepExpr {
  Pattern(String)
  And(GrepExpr, GrepExpr)
  Or(GrepExpr, GrepExpr)
  Not(GrepExpr)
} derive(Eq, Debug)

///|
pub(all) struct GrepExprMatch {
  matched : Bool
  span : GrepMatchSpan?
} derive(Eq, Debug)

///|
fn grep_pattern_show_string(value : String) -> String {
  let buf = StringBuilder::new()
  buf.write_char('"')
  for c in value {
    if c == '"' {
      buf.write_string("\\\"")
    } else if c == '\\' {
      buf.write_string("\\\\")
    } else if c == '\n' {
      buf.write_string("\\n")
    } else if c == '\r' {
      buf.write_string("\\r")
    } else if c == '\t' {
      buf.write_string("\\t")
    } else {
      buf.write_char(c)
    }
  }
  buf.write_char('"')
  buf.to_string()
}

///|
pub impl Show for GrepPatternType with fn output(self, logger) {
  match self {
    Fixed => logger.write_string("Fixed")
    Basic => logger.write_string("Basic")
    Extended => logger.write_string("Extended")
    Perl => logger.write_string("Perl")
  }
}

///|
pub impl Show for GrepMatchSpan with fn output(self, logger) {
  logger.write_string(
    "{start_column: " +
    self.start_column.to_string() +
    ", end_column: " +
    self.end_column.to_string() +
    "}",
  )
}

///|
pub impl Show for GrepExprToken with fn output(self, logger) {
  match self {
    Pattern(pattern) =>
      logger.write_string("Pattern(" + grep_pattern_show_string(pattern) + ")")
    And => logger.write_string("And")
    Or => logger.write_string("Or")
    Not => logger.write_string("Not")
    LParen => logger.write_string("LParen")
    RParen => logger.write_string("RParen")
  }
}

///|
pub impl Show for GrepExpr with fn output(self, logger) {
  match self {
    Pattern(pattern) =>
      logger.write_string("Pattern(" + grep_pattern_show_string(pattern) + ")")
    And(lhs, rhs) =>
      logger.write_string(
        "And(" + lhs.to_string() + ", " + rhs.to_string() + ")",
      )
    Or(lhs, rhs) =>
      logger.write_string(
        "Or(" + lhs.to_string() + ", " + rhs.to_string() + ")",
      )
    Not(inner) => logger.write_string("Not(" + inner.to_string() + ")")
  }
}

///|
pub impl Show for GrepExprMatch with fn output(self, logger) {
  logger.write_string(
    "{matched: " +
    self.matched.to_string() +
    ", span: " +
    Repr(self.span).to_string() +
    "}",
  )
}

///|
priv enum GrepRegexAtom {
  Any
  Literal(Char)
  Class(Array[Char])
}

///|
pub fn parse_grep_pattern_type_name(value : String) -> GrepPatternType {
  match value.to_lower() {
    "fixed" => GrepPatternType::Fixed
    "extended" => GrepPatternType::Extended
    "perl" => GrepPatternType::Perl
    _ => GrepPatternType::Basic
  }
}

///|
pub fn resolve_grep_pattern_type(
  rfs : &@bit.RepoFileSystem,
  git_dir : String,
  cli_override : GrepPatternType?,
  config_override : String?,
) -> GrepPatternType {
  match cli_override {
    Some(value) => value
    None =>
      match config_override {
        Some(value) => parse_grep_pattern_type_name(value)
        None =>
          match
            @bitlib.read_config_value(
              rfs,
              git_dir + "/config",
              "grep",
              "patterntype",
            ) {
            Some(value) => parse_grep_pattern_type_name(value)
            None => GrepPatternType::Basic
          }
      }
  }
}

///|
pub fn grep_or_expr_from_patterns(patterns : Array[String]) -> GrepExpr? {
  if patterns.length() == 0 {
    return None
  }
  let mut expr = GrepExpr::Pattern(patterns[0])
  for i in 1..<patterns.length() {
    expr = GrepExpr::Or(expr, GrepExpr::Pattern(patterns[i]))
  }
  Some(expr)
}

///|
pub fn parse_grep_expr(
  tokens : Array[GrepExprToken],
) -> GrepExpr raise @bit.GitError {
  let (expr, next_index) = grep_parse_or_expr(tokens, 0)
  if next_index != tokens.length() {
    grep_raise_invalid_expression()
  }
  expr
}

///|
pub fn validate_grep_expr(
  expr : GrepExpr,
  pattern_type : GrepPatternType,
) -> Unit raise @bit.GitError {
  match expr {
    GrepExpr::Pattern(pattern) =>
      validate_grep_patterns([pattern], pattern_type)
    GrepExpr::And(lhs, rhs) | GrepExpr::Or(lhs, rhs) => {
      validate_grep_expr(lhs, pattern_type)
      validate_grep_expr(rhs, pattern_type)
    }
    GrepExpr::Not(inner) => validate_grep_expr(inner, pattern_type)
  }
}

///|
pub fn grep_eval_expr(
  message : String,
  expr : GrepExpr,
  pattern_type : GrepPatternType,
  ignore_case : Bool,
  word_regexp? : Bool = false,
) -> GrepExprMatch {
  match expr {
    GrepExpr::Pattern(pattern) => {
      let span = grep_first_match_span(
        message,
        pattern,
        pattern_type,
        ignore_case,
        word_regexp~,
      )
      { matched: span is Some(_), span }
    }
    GrepExpr::And(lhs, rhs) => {
      let left = grep_eval_expr(
        message,
        lhs,
        pattern_type,
        ignore_case,
        word_regexp~,
      )
      let right = grep_eval_expr(
        message,
        rhs,
        pattern_type,
        ignore_case,
        word_regexp~,
      )
      {
        matched: left.matched && right.matched,
        span: grep_pick_earliest_span(left.span, right.span),
      }
    }
    GrepExpr::Or(lhs, rhs) => {
      let left = grep_eval_expr(
        message,
        lhs,
        pattern_type,
        ignore_case,
        word_regexp~,
      )
      let right = grep_eval_expr(
        message,
        rhs,
        pattern_type,
        ignore_case,
        word_regexp~,
      )
      {
        matched: left.matched || right.matched,
        span: grep_pick_earliest_span(left.span, right.span),
      }
    }
    GrepExpr::Not(inner) => {
      let result = grep_eval_expr(
        message,
        inner,
        pattern_type,
        ignore_case,
        word_regexp~,
      )
      { matched: !result.matched, span: result.span }
    }
  }
}

///|
pub fn grep_collect_expr_match_spans(
  message : String,
  expr : GrepExpr,
  pattern_type : GrepPatternType,
  ignore_case : Bool,
  word_regexp? : Bool = false,
) -> Array[GrepMatchSpan] {
  match expr {
    GrepExpr::Pattern(pattern) =>
      grep_collect_pattern_match_spans(
        message, pattern, pattern_type, ignore_case, word_regexp,
      )
    GrepExpr::And(lhs, rhs) => {
      let left = grep_eval_expr(
        message,
        lhs,
        pattern_type,
        ignore_case,
        word_regexp~,
      )
      let right = grep_eval_expr(
        message,
        rhs,
        pattern_type,
        ignore_case,
        word_regexp~,
      )
      if !(left.matched && right.matched) {
        return []
      }
      let out : Array[GrepMatchSpan] = []
      grep_append_unique_spans(
        out,
        grep_collect_expr_match_spans(
          message,
          lhs,
          pattern_type,
          ignore_case,
          word_regexp~,
        ),
      )
      grep_append_unique_spans(
        out,
        grep_collect_expr_match_spans(
          message,
          rhs,
          pattern_type,
          ignore_case,
          word_regexp~,
        ),
      )
      out
    }
    GrepExpr::Or(lhs, rhs) => {
      let out : Array[GrepMatchSpan] = []
      grep_append_unique_spans(
        out,
        grep_collect_expr_match_spans(
          message,
          lhs,
          pattern_type,
          ignore_case,
          word_regexp~,
        ),
      )
      grep_append_unique_spans(
        out,
        grep_collect_expr_match_spans(
          message,
          rhs,
          pattern_type,
          ignore_case,
          word_regexp~,
        ),
      )
      out
    }
    GrepExpr::Not(_) => []
  }
}

///|
pub fn grep_patterns_match_message(
  message : String,
  patterns : Array[String],
  pattern_type : GrepPatternType,
  ignore_case : Bool,
) -> Bool {
  match grep_or_expr_from_patterns(patterns) {
    Some(expr) =>
      grep_eval_expr(message, expr, pattern_type, ignore_case).matched
    None => true
  }
}

///|
pub fn validate_grep_patterns(
  patterns : Array[String],
  pattern_type : GrepPatternType,
) -> Unit raise @bit.GitError {
  if pattern_type == GrepPatternType::Fixed {
    return
  }
  for pattern in patterns {
    validate_grep_pattern(pattern)
  }
}

///|
fn validate_grep_pattern(pattern : String) -> Unit raise @bit.GitError {
  let chars = pattern.to_array()
  let mut i = 0
  let mut in_class = false
  while i < chars.length() {
    let c = chars[i]
    if c == '\\' {
      if i + 1 >= chars.length() {
        raise @bit.GitError::InvalidObject(
          "fatal: invalid regular expression: " + pattern,
        )
      }
      i += 2
      continue
    }
    if in_class {
      if c == ']' {
        in_class = false
      }
      i += 1
      continue
    }
    if c == '[' {
      in_class = true
      i += 1
      continue
    }
    if c == '(' || c == ')' {
      raise @bit.GitError::InvalidObject(
        "fatal: invalid regular expression: " + pattern,
      )
    }
    i += 1
  }
  if in_class {
    raise @bit.GitError::InvalidObject(
      "fatal: invalid regular expression: " + pattern,
    )
  }
}

///|
pub fn grep_message_matches_pattern(
  message : String,
  pattern : String,
  pattern_type : GrepPatternType,
  ignore_case : Bool,
) -> Bool {
  grep_eval_expr(message, GrepExpr::Pattern(pattern), pattern_type, ignore_case).matched
}

///|
pub fn grep_patterns_first_match_span(
  message : String,
  patterns : Array[String],
  pattern_type : GrepPatternType,
  ignore_case : Bool,
  word_regexp? : Bool = false,
) -> GrepMatchSpan? {
  match grep_or_expr_from_patterns(patterns) {
    Some(expr) =>
      grep_eval_expr(message, expr, pattern_type, ignore_case, word_regexp~).span
    None => Some({ start_column: 1, end_column: 1 })
  }
}

///|
pub fn grep_first_match_span(
  message : String,
  pattern : String,
  pattern_type : GrepPatternType,
  ignore_case : Bool,
  word_regexp? : Bool = false,
) -> GrepMatchSpan? {
  if pattern == "" {
    return Some({ start_column: 1, end_column: 1 })
  }
  let source = if ignore_case { message.to_lower() } else { message }
  let needle = if ignore_case { pattern.to_lower() } else { pattern }
  match pattern_type {
    GrepPatternType::Fixed =>
      grep_fixed_first_match_span(source, needle, word_regexp)
    GrepPatternType::Basic
    | GrepPatternType::Extended
    | GrepPatternType::Perl =>
      grep_regex_like_first_match_span(
        source, needle, pattern_type, word_regexp,
      )
  }
}

///|
fn grep_collect_pattern_match_spans(
  message : String,
  pattern : String,
  pattern_type : GrepPatternType,
  ignore_case : Bool,
  word_regexp : Bool,
) -> Array[GrepMatchSpan] {
  if pattern == "" {
    return []
  }
  let source = if ignore_case { message.to_lower() } else { message }
  let needle = if ignore_case { pattern.to_lower() } else { pattern }
  match pattern_type {
    GrepPatternType::Fixed =>
      grep_collect_fixed_match_spans(source, needle, word_regexp)
    GrepPatternType::Basic
    | GrepPatternType::Extended
    | GrepPatternType::Perl =>
      grep_collect_regex_like_match_spans(
        source, needle, pattern_type, word_regexp,
      )
  }
}

///|
fn grep_fixed_first_match_span(
  text : String,
  pattern : String,
  word_regexp : Bool,
) -> GrepMatchSpan? {
  let chars = text.to_array()
  let pattern_len = pattern.to_array().length()
  let mut offset = 0
  while offset <= chars.length() {
    let rest = String::unsafe_substring(text, start=offset, end=text.length())
    match rest.find(pattern) {
      Some(rel_idx) => {
        let start = offset + rel_idx
        let end_column = start + pattern_len
        if !word_regexp || grep_is_word_match(chars, start, end_column) {
          return Some({ start_column: start + 1, end_column })
        }
        offset = start + 1
      }
      None => return None
    }
  }
  None
}

///|
fn grep_collect_fixed_match_spans(
  text : String,
  pattern : String,
  word_regexp : Bool,
) -> Array[GrepMatchSpan] {
  let chars = text.to_array()
  let pattern_len = pattern.to_array().length()
  let spans : Array[GrepMatchSpan] = []
  let mut offset = 0
  while offset <= chars.length() {
    let rest = String::unsafe_substring(text, start=offset, end=text.length())
    match rest.find(pattern) {
      Some(rel_idx) => {
        let start = offset + rel_idx
        let end_column = start + pattern_len
        if !word_regexp || grep_is_word_match(chars, start, end_column) {
          spans.push({ start_column: start + 1, end_column })
          offset = if end_column > start { end_column } else { start + 1 }
        } else {
          offset = start + 1
        }
      }
      None => break
    }
  }
  spans
}

///|
fn grep_regex_like_first_match_span(
  text : String,
  pattern : String,
  pattern_type : GrepPatternType,
  word_regexp : Bool,
) -> GrepMatchSpan? {
  let text_chars = text.to_array()
  let pattern_chars = pattern.to_array()
  let mut start = 0
  while start <= text_chars.length() {
    match
      grep_regex_like_match_end_at(
        text_chars, start, pattern_chars, pattern_type,
      ) {
      Some(end_column) =>
        if !word_regexp || grep_is_word_match(text_chars, start, end_column) {
          return Some({ start_column: start + 1, end_column })
        }
      None => ()
    }
    start += 1
  }
  None
}

///|
fn grep_collect_regex_like_match_spans(
  text : String,
  pattern : String,
  pattern_type : GrepPatternType,
  word_regexp : Bool,
) -> Array[GrepMatchSpan] {
  let text_chars = text.to_array()
  let pattern_chars = pattern.to_array()
  let spans : Array[GrepMatchSpan] = []
  let mut start = 0
  while start <= text_chars.length() {
    match
      grep_regex_like_match_end_at(
        text_chars, start, pattern_chars, pattern_type,
      ) {
      Some(end_column) =>
        if !word_regexp || grep_is_word_match(text_chars, start, end_column) {
          spans.push({ start_column: start + 1, end_column })
          start = if end_column > start { end_column } else { start + 1 }
        } else {
          start += 1
        }
      None => start += 1
    }
  }
  spans
}

///|
fn grep_regex_like_match_end_at(
  text : Array[Char],
  start : Int,
  pattern : Array[Char],
  pattern_type : GrepPatternType,
) -> Int? {
  let mut pi = 0
  if pattern.length() > 0 && pattern[0] == '^' {
    if start != 0 {
      return None
    }
    pi = 1
  }
  grep_regex_like_match_here(text, start, pattern, pi, pattern_type)
}

///|
fn grep_regex_like_match_here(
  text : Array[Char],
  ti : Int,
  pattern : Array[Char],
  pi : Int,
  pattern_type : GrepPatternType,
) -> Int? {
  if pi >= pattern.length() {
    return Some(ti)
  }
  if pattern[pi] == '$' && pi + 1 == pattern.length() {
    if ti == text.length() {
      return Some(ti)
    }
    return None
  }
  let (atom, next_pi) = grep_regex_like_parse_atom(pattern, pi)
  let (quantifier, after_atom) = grep_regex_like_parse_quantifier(
    pattern, next_pi, pattern_type,
  )
  match quantifier {
    Some('*') => {
      let mut max_ti = ti
      while max_ti < text.length() &&
            grep_regex_like_atom_matches(atom, text[max_ti]) {
        max_ti += 1
      }
      let mut cur = max_ti
      while true {
        match
          grep_regex_like_match_here(
            text, cur, pattern, after_atom, pattern_type,
          ) {
          Some(end_column) => return Some(end_column)
          None => ()
        }
        if cur == ti {
          break
        }
        cur -= 1
      }
      None
    }
    Some('+') => {
      if ti >= text.length() || !grep_regex_like_atom_matches(atom, text[ti]) {
        return None
      }
      let mut max_ti = ti + 1
      while max_ti < text.length() &&
            grep_regex_like_atom_matches(atom, text[max_ti]) {
        max_ti += 1
      }
      let mut cur = max_ti
      while true {
        match
          grep_regex_like_match_here(
            text, cur, pattern, after_atom, pattern_type,
          ) {
          Some(end_column) => return Some(end_column)
          None => ()
        }
        if cur == ti + 1 {
          break
        }
        cur -= 1
      }
      None
    }
    _ => {
      if ti >= text.length() {
        return None
      }
      if !grep_regex_like_atom_matches(atom, text[ti]) {
        return None
      }
      grep_regex_like_match_here(
        text,
        ti + 1,
        pattern,
        after_atom,
        pattern_type,
      )
    }
  }
}

///|
fn grep_regex_like_parse_atom(
  pattern : Array[Char],
  pi : Int,
) -> (GrepRegexAtom, Int) {
  let pc = pattern[pi]
  if pc == '\\' {
    if pi + 1 < pattern.length() {
      return (GrepRegexAtom::Literal(pattern[pi + 1]), pi + 2)
    }
    return (GrepRegexAtom::Literal('\\'), pi + 1)
  }
  if pc == '.' {
    return (GrepRegexAtom::Any, pi + 1)
  }
  if pc == '[' {
    match grep_regex_like_class_end(pattern, pi + 1) {
      Some(class_end) => {
        let chars : Array[Char] = []
        for idx in (pi + 1)..<class_end {
          chars.push(pattern[idx])
        }
        return (GrepRegexAtom::Class(chars), class_end + 1)
      }
      None => ()
    }
  }
  (GrepRegexAtom::Literal(pc), pi + 1)
}

///|
fn grep_regex_like_class_end(pattern : Array[Char], start : Int) -> Int? {
  let mut idx = start
  while idx < pattern.length() {
    if pattern[idx] == ']' {
      return Some(idx)
    }
    idx += 1
  }
  None
}

///|
fn grep_regex_like_parse_quantifier(
  pattern : Array[Char],
  pi : Int,
  pattern_type : GrepPatternType,
) -> (Char?, Int) {
  if pi >= pattern.length() {
    return (None, pi)
  }
  let pc = pattern[pi]
  if pc == '*' {
    return (Some('*'), pi + 1)
  }
  if pc == '+' && pattern_type != GrepPatternType::Basic {
    return (Some('+'), pi + 1)
  }
  (None, pi)
}

///|
fn grep_regex_like_atom_matches(atom : GrepRegexAtom, c : Char) -> Bool {
  match atom {
    GrepRegexAtom::Any => true
    GrepRegexAtom::Literal(value) => value == c
    GrepRegexAtom::Class(chars) => {
      for value in chars {
        if value == c {
          return true
        }
      }
      false
    }
  }
}

///|
fn grep_parse_or_expr(
  tokens : Array[GrepExprToken],
  start : Int,
) -> (GrepExpr, Int) raise @bit.GitError {
  let (initial_expr, initial_next_index) = grep_parse_and_expr(tokens, start)
  let mut expr = initial_expr
  let mut next_index = initial_next_index
  while next_index < tokens.length() {
    match tokens[next_index] {
      GrepExprToken::Or => {
        let (rhs, rhs_next) = grep_parse_and_expr(tokens, next_index + 1)
        expr = GrepExpr::Or(expr, rhs)
        next_index = rhs_next
      }
      _ => break
    }
  }
  (expr, next_index)
}

///|
fn grep_parse_and_expr(
  tokens : Array[GrepExprToken],
  start : Int,
) -> (GrepExpr, Int) raise @bit.GitError {
  let (initial_expr, initial_next_index) = grep_parse_unary_expr(tokens, start)
  let mut expr = initial_expr
  let mut next_index = initial_next_index
  while next_index < tokens.length() {
    match tokens[next_index] {
      GrepExprToken::And => {
        let (rhs, rhs_next) = grep_parse_unary_expr(tokens, next_index + 1)
        expr = GrepExpr::And(expr, rhs)
        next_index = rhs_next
      }
      _ => break
    }
  }
  (expr, next_index)
}

///|
fn grep_parse_unary_expr(
  tokens : Array[GrepExprToken],
  start : Int,
) -> (GrepExpr, Int) raise @bit.GitError {
  if start >= tokens.length() {
    raise @bit.GitError::InvalidObject("fatal: invalid grep pattern expression")
  }
  match tokens[start] {
    GrepExprToken::Not => {
      let (inner, next_index) = grep_parse_unary_expr(tokens, start + 1)
      (GrepExpr::Not(inner), next_index)
    }
    GrepExprToken::LParen => {
      let (inner, next_index) = grep_parse_or_expr(tokens, start + 1)
      if next_index >= tokens.length() ||
        tokens[next_index] != GrepExprToken::RParen {
        raise @bit.GitError::InvalidObject(
          "fatal: invalid grep pattern expression",
        )
      }
      (inner, next_index + 1)
    }
    GrepExprToken::Pattern(pattern) => (GrepExpr::Pattern(pattern), start + 1)
    _ =>
      raise @bit.GitError::InvalidObject(
        "fatal: invalid grep pattern expression",
      )
  }
}

///|
fn grep_raise_invalid_expression() -> Unit raise @bit.GitError {
  raise @bit.GitError::InvalidObject("fatal: invalid grep pattern expression")
}

///|
fn grep_pick_earliest_span(
  lhs : GrepMatchSpan?,
  rhs : GrepMatchSpan?,
) -> GrepMatchSpan? {
  match lhs {
    Some(left) =>
      match rhs {
        Some(right) =>
          if left.start_column < right.start_column ||
            (
              left.start_column == right.start_column &&
              left.end_column <= right.end_column
            ) {
            Some(left)
          } else {
            Some(right)
          }
        None => Some(left)
      }
    None => rhs
  }
}

///|
fn grep_append_unique_spans(
  out : Array[GrepMatchSpan],
  spans : Array[GrepMatchSpan],
) -> Unit {
  for span in spans {
    let mut inserted = false
    for i in 0..<out.length() {
      let current = out[i]
      if current == span {
        inserted = true
        break
      }
      if span.start_column < current.start_column ||
        (
          span.start_column == current.start_column &&
          span.end_column < current.end_column
        ) {
        out.insert(i, span)
        inserted = true
        break
      }
    }
    if !inserted {
      out.push(span)
    }
  }
}

///|
fn grep_is_word_match(
  text : Array[Char],
  start : Int,
  end_column : Int,
) -> Bool {
  let before_is_word = if start <= 0 {
    false
  } else {
    grep_is_word_char(text[start - 1])
  }
  let after_is_word = if end_column >= text.length() {
    false
  } else {
    grep_is_word_char(text[end_column])
  }
  !before_is_word && !after_is_word
}

///|
fn grep_is_word_char(c : Char) -> Bool {
  ('a' <= c && c <= 'z') ||
  ('A' <= c && c <= 'Z') ||
  ('0' <= c && c <= '9') ||
  c == '_'
}

///|
pub fn extract_commit_message_from_raw(data : Bytes) -> String {
  let text = @utf8.decode_lossy(data[:])
  match text.find("\n\n") {
    Some(idx) =>
      String::unsafe_substring(text, start=idx + 2, end=text.length())
    None => ""
  }
}

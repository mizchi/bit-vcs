///|
enum GrepPatternType {
  Fixed
  Basic
  Extended
  Perl
}

///|
fn parse_grep_pattern_type_name(value : String) -> GrepPatternType {
  match value.to_lower() {
    "fixed" => GrepPatternType::Fixed
    "extended" => GrepPatternType::Extended
    "perl" => GrepPatternType::Perl
    _ => GrepPatternType::Basic
  }
}

///|
fn resolve_grep_pattern_type(
  rfs : &@git.RepoFileSystem,
  git_dir : String,
  cli_override : GrepPatternType?,
) -> GrepPatternType {
  match cli_override {
    Some(value) => value
    None =>
      match get_config_override("grep.patterntype") {
        Some(value) => parse_grep_pattern_type_name(value)
        None =>
          match @gitlib.read_config_value(
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
fn grep_patterns_match_message(
  message : String,
  patterns : Array[String],
  pattern_type : GrepPatternType,
  ignore_case : Bool,
) -> Bool {
  if patterns.length() == 0 {
    return true
  }
  for pattern in patterns {
    if grep_message_matches_pattern(message, pattern, pattern_type, ignore_case) {
      return true
    }
  }
  false
}

///|
fn grep_message_matches_pattern(
  message : String,
  pattern : String,
  pattern_type : GrepPatternType,
  ignore_case : Bool,
) -> Bool {
  let source = if ignore_case {
    message.to_lower()
  } else {
    message
  }
  let needle = if ignore_case {
    pattern.to_lower()
  } else {
    pattern
  }
  match pattern_type {
    GrepPatternType::Fixed => source.contains(needle)
    GrepPatternType::Basic |
    GrepPatternType::Extended |
    GrepPatternType::Perl => grep_regex_like_contains(source, needle)
  }
}

///|
fn grep_regex_like_contains(text : String, pattern : String) -> Bool {
  if pattern.length() == 0 {
    return true
  }
  let text_chars = text.to_array()
  let pattern_chars = pattern.to_array()
  for start in 0..<text_chars.length() {
    if grep_regex_like_match_at(text_chars, start, pattern_chars) {
      return true
    }
  }
  false
}

///|
fn grep_regex_like_match_at(
  text : Array[Char],
  start : Int,
  pattern : Array[Char],
) -> Bool {
  let mut ti = start
  let mut pi = 0
  while pi < pattern.length() {
    if ti >= text.length() {
      return false
    }
    let pc = pattern[pi]
    if pc == '\\' {
      if pi + 1 < pattern.length() {
        let escaped = pattern[pi + 1]
        if text[ti] != escaped {
          return false
        }
        ti += 1
        pi += 2
        continue
      }
      if text[ti] != '\\' {
        return false
      }
      ti += 1
      pi += 1
      continue
    }
    if pc == '.' {
      ti += 1
      pi += 1
      continue
    }
    if text[ti] != pc {
      return false
    }
    ti += 1
    pi += 1
  }
  true
}

///|
fn extract_commit_message_from_raw(data : Bytes) -> String {
  let text = decode_bytes(data)
  match text.find("\n\n") {
    Some(idx) => String::unsafe_substring(text, start=idx + 2, end=text.length())
    None => ""
  }
}

///|

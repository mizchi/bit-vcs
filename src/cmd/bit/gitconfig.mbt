///| Gitconfig parsing helpers (global aliases only)

///|
pub enum AliasResolution {
  Resolved(String, Array[String])
  Shell(String)
}

///|
pub fn load_global_aliases(fs : OsFs) -> Map[String, String] {
  let empty : Map[String, String] = {}
  let path = find_global_gitconfig_path()
  match path {
    Some(p) => {
      if not(fs.is_file(p)) {
        return empty
      }
      let bytes = fs.read_file(p) catch { _ => return empty }
      return parse_gitconfig_aliases(decode_bytes(bytes))
    }
    None => ()
  }
  empty
}

///|
pub fn apply_alias_overrides(
  aliases : Map[String, String],
  overrides : Array[(String, String)],
) -> Unit {
  for pair in overrides {
    let key = pair.0
    if key.to_lower().has_prefix("alias.") {
      let name = String::unsafe_substring(key, start=6, end=key.length())
      if name.length() > 0 {
        aliases.set(name, pair.1)
      }
    }
  }
}

///|
pub fn parse_gitconfig_aliases(content : String) -> Map[String, String] {
  let aliases : Map[String, String] = {}
  let mut in_alias_section = false
  for line_view in content.split("\n") {
    let line = trim_string(line_view.to_string())
    if line.length() == 0 || line.has_prefix("#") || line.has_prefix(";") {
      continue
    }
    match parse_section_name(line) {
      Some(section) => {
        in_alias_section = section == "alias"
        continue
      }
      None => ()
    }
    if in_alias_section {
      match parse_key_value_line(line) {
        Some((key, value)) => if key.length() > 0 { aliases.set(key, value) }
        None => ()
      }
    }
  }
  aliases
}

///|
pub fn resolve_alias(
  aliases : Map[String, String],
  cmd : String,
  rest : Array[String],
) -> AliasResolution {
  match aliases.get(cmd) {
    None => Resolved(cmd, rest)
    Some(value) => {
      let trimmed = trim_string(value)
      if trimmed.has_prefix("!") {
        let body = String::unsafe_substring(
          trimmed,
          start=1,
          end=trimmed.length(),
        )
        Shell(body)
      } else {
        let tokens = split_alias_command(trimmed)
        if tokens.length() == 0 {
          Resolved(cmd, rest)
        } else {
          let new_rest : Array[String] = []
          for i in 1..<tokens.length() {
            new_rest.push(tokens[i])
          }
          for arg in rest {
            new_rest.push(arg)
          }
          Resolved(tokens[0], new_rest)
        }
      }
    }
  }
}

///|
pub fn split_alias_command(value : String) -> Array[String] {
  let args : Array[String] = []
  let sb = StringBuilder::new()
  let mut in_single = false
  let mut in_double = false
  let mut escape = false
  for c in value {
    if escape {
      let out = match c {
        'n' => '\n'
        't' => '\t'
        'r' => '\r'
        _ => c
      }
      sb.write_char(out)
      escape = false
      continue
    }
    if c == '\\' && not(in_single) {
      escape = true
      continue
    }
    if c == '\'' && not(in_double) {
      in_single = not(in_single)
      continue
    }
    if c == '"' && not(in_single) {
      in_double = not(in_double)
      continue
    }
    if (c == ' ' || c == '\t') && not(in_single) && not(in_double) {
      if not(sb.is_empty()) {
        args.push(sb.to_string())
        sb.reset()
      }
      continue
    }
    sb.write_char(c)
  }
  if escape {
    sb.write_char('\\')
  }
  if not(sb.is_empty()) {
    args.push(sb.to_string())
  }
  args
}

///|
fn find_global_gitconfig_path() -> String? {
  match @sys.get_env_var("GIT_CONFIG_GLOBAL") {
    Some(path) => Some(path)
    None =>
      match @sys.get_env_var("HOME") {
        Some(home) => Some(home + "/.gitconfig")
        None =>
          match @sys.get_env_var("USERPROFILE") {
            Some(home) => Some(home + "/.gitconfig")
            None => None
          }
      }
  }
}

///|
fn parse_section_name(line : String) -> String? {
  if not(line.has_prefix("[")) || not(line.has_suffix("]")) {
    return None
  }
  if line.length() < 2 {
    return None
  }
  let inner = String::unsafe_substring(line, start=1, end=line.length() - 1)
  let trimmed = trim_string(inner)
  if trimmed.length() == 0 {
    return None
  }
  let mut end = trimmed.length()
  for i in 0..<trimmed.length() {
    let c = trimmed.unsafe_get(i)
    if c == (' ' : UInt16) || c == ('\t' : UInt16) {
      end = i
      break
    }
  }
  Some(String::unsafe_substring(trimmed, start=0, end~).to_lower())
}

///|
fn parse_key_value_line(line : String) -> (String, String)? {
  let trimmed = trim_string(line)
  if trimmed.length() == 0 || trimmed.has_prefix("#") || trimmed.has_prefix(";") {
    return None
  }
  match trimmed.find("=") {
    Some(eq_idx) => {
      let key = trim_chars(
        String::unsafe_substring(trimmed, start=0, end=eq_idx),
        " \t",
      )
      let value = trim_chars(
        String::unsafe_substring(
          trimmed,
          start=eq_idx + 1,
          end=trimmed.length(),
        ),
        " \t",
      )
      Some((key, unquote_value(value)))
    }
    None => {
      let mut sep = -1
      for i in 0..<trimmed.length() {
        let c = trimmed.unsafe_get(i)
        if c == (' ' : UInt16) || c == ('\t' : UInt16) {
          sep = i
          break
        }
      }
      if sep < 0 {
        Some((trimmed, ""))
      } else {
        let key = trim_chars(
          String::unsafe_substring(trimmed, start=0, end=sep),
          " \t",
        )
        let value = trim_chars(
          String::unsafe_substring(trimmed, start=sep + 1, end=trimmed.length()),
          " \t",
        )
        Some((key, unquote_value(value)))
      }
    }
  }
}

///|
fn unquote_value(value : String) -> String {
  let trimmed = trim_chars(value, " \t")
  if trimmed.length() < 2 {
    return trimmed
  }
  let first = trimmed.unsafe_get(0)
  let last = trimmed.unsafe_get(trimmed.length() - 1)
  if (first == ('"' : UInt16) && last == ('"' : UInt16)) ||
    (first == ('\'' : UInt16) && last == ('\'' : UInt16)) {
    let inner = String::unsafe_substring(
      trimmed,
      start=1,
      end=trimmed.length() - 1,
    )
    return unescape_config_string(inner)
  }
  trimmed
}

///|
fn unescape_config_string(value : String) -> String {
  let sb = StringBuilder::new()
  let mut escape = false
  for c in value {
    if escape {
      let out = match c {
        'n' => '\n'
        't' => '\t'
        'r' => '\r'
        _ => c
      }
      sb.write_char(out)
      escape = false
      continue
    }
    if c == '\\' {
      escape = true
      continue
    }
    sb.write_char(c)
  }
  if escape {
    sb.write_char('\\')
  }
  sb.to_string()
}

///| git check-attr - check gitattributes for paths

///|
async fn handle_check_attr(args : Array[String]) -> Unit raise Error {
  let fs = OsFs::new()
  let mut all = false
  let mut use_stdin = false
  let mut nul_terminated = false
  let positional : Array[String] = []
  let mut past_dashdash = false
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    if past_dashdash {
      positional.push(arg)
      i += 1
      continue
    }
    match arg {
      "-a" | "--all" => all = true
      "--stdin" => use_stdin = true
      "-z" => nul_terminated = true
      "--cached" => ()
      "-h" | "--help" => {
        show_simple_command_help(
          "git check-attr [-a | --all | <attr>...] [--] <pathname>...",
          summary="Display gitattributes information.",
        )
        return
      }
      "--" => past_dashdash = true
      _ if arg.has_prefix("--source=") => ()
      _ if arg.has_prefix("-") => warn_unimplemented_arg("check-attr", arg)
      _ => positional.push(arg)
    }
    i += 1
  }
  // Determine which attrs to check and which paths to check
  let attrs : Array[String] = []
  let paths : Array[String] = []
  if all {
    // All positional args are paths
    paths.append(positional)
    // First positional args (before --) are attrs, rest are paths
    // If -- was used, positional only has paths and we need attrs from before
    // Re-parse: attrs come before --, paths come after
  } else if past_dashdash {
    // positional has paths (after --), need to re-extract attrs from args
    let mut j = 0
    while j < args.length() {
      let a = args[j]
      if a == "--" {
        break
      }
      if !a.has_prefix("-") {
        attrs.push(a)
      }
      j += 1
    }
  } else if positional.length() > 0 {
    // First arg is attr, rest are paths
    attrs.push(positional[0])
    for k in 1..<positional.length() {
      paths.push(positional[k])
    }
  }
  // Read paths from stdin if --stdin
  if use_stdin {
    let data = read_all_stdin()
    let text = decode_bytes(data)
    let sep = if nul_terminated { "\u0000" } else { "\n" }
    for part_view in text.split(sep) {
      let part = part_view.to_owned()
      if part.length() > 0 {
        paths.push(part)
      }
    }
  }
  if paths.length() == 0 && !use_stdin {
    eprint_line(
      "usage: git check-attr [-a | --all | <attr>...] [--] <pathname>...",
    )
    @sys.exit(1)
    return
  }
  // Load gitattributes
  let root = get_work_root()
  let git_dir = find_git_dir(fs)
  let rules = check_attr_load_rules(fs, root, git_dir)
  let line_sep = if nul_terminated { "\u0000" } else { "\n" }
  let field_sep = if nul_terminated { "\u0000" } else { ": " }
  for path in paths {
    let resolved = check_attr_resolve(rules, path)
    if all {
      // Print all resolved attributes
      for entry in resolved {
        print_str(path + field_sep + entry.0 + field_sep + entry.1 + line_sep)
      }
    } else {
      // Print requested attributes
      for attr in attrs {
        let value = check_attr_find_value(resolved, attr)
        print_str(path + field_sep + attr + field_sep + value + line_sep)
      }
    }
  }
}

///|
struct CheckAttrRule {
  pattern : String
  attrs : Array[(String, String)]
}

///|
fn check_attr_load_rules(
  fs : OsFs,
  root : String,
  git_dir : String,
) -> Array[CheckAttrRule] {
  let rules : Array[CheckAttrRule] = []
  // Read .gitattributes from working tree root
  let root_attr = root + "/.gitattributes"
  if fs.is_file(root_attr) {
    let content = decode_bytes(
      fs.read_file(root_attr) catch {
        _ => Default::default()
      },
    )
    check_attr_parse_rules(content, rules)
  }
  // Read .git/info/attributes (lower priority, appended after)
  let info_attr = git_dir + "/info/attributes"
  if fs.is_file(info_attr) {
    let content = decode_bytes(
      fs.read_file(info_attr) catch {
        _ => Default::default()
      },
    )
    check_attr_parse_rules(content, rules)
  }
  rules
}

///|
fn check_attr_parse_rules(
  content : String,
  rules : Array[CheckAttrRule],
) -> Unit {
  for line_view in content.split("\n") {
    let mut line = line_view.to_owned()
    // Handle CRLF
    if line.has_suffix("\r") {
      line = String::unsafe_substring(line, start=0, end=line.length() - 1)
    }
    let trimmed = line.trim().to_owned()
    if trimmed.length() == 0 || trimmed.has_prefix("#") {
      continue
    }
    // Split into words by spaces and tabs
    let words : Array[String] = []
    let mut start = 0
    let tlen = trimmed.length()
    while start < tlen {
      // Skip whitespace
      while start < tlen {
        let c = trimmed.unsafe_get(start)
        if c == ' ' || c == '\t' {
          start += 1
        } else {
          break
        }
      }
      if start >= tlen {
        break
      }
      let mut end = start
      while end < tlen {
        let c = trimmed.unsafe_get(end)
        if c == ' ' || c == '\t' {
          break
        }
        end += 1
      }
      if end > start {
        words.push(String::unsafe_substring(trimmed, start~, end~))
      }
      start = end
    }
    if words.length() < 2 {
      continue
    }
    let pattern = words[0]
    let attrs : Array[(String, String)] = []
    for j in 1..<words.length() {
      let token = words[j]
      if token.has_prefix("-") {
        // Unset: -attr
        let attr_name = String::unsafe_substring(
          token,
          start=1,
          end=token.length(),
        )
        if attr_name.length() > 0 {
          attrs.push((attr_name, "unset"))
        }
      } else {
        match token.find("=") {
          Some(eq_idx) => {
            let attr_name = String::unsafe_substring(token, start=0, end=eq_idx)
            let attr_value = String::unsafe_substring(
              token,
              start=eq_idx + 1,
              end=token.length(),
            )
            attrs.push((attr_name, attr_value))
          }
          None =>
            // Set: attr (value is "set")
            attrs.push((token, "set"))
        }
      }
    }
    rules.push({ pattern, attrs })
  }
}

///|
fn check_attr_resolve(
  rules : Array[CheckAttrRule],
  path : String,
) -> Array[(String, String)] {
  let resolved : Map[String, String] = Map([])
  let order : Array[String] = []
  let normalized = if path.has_prefix("./") {
    String::unsafe_substring(path, start=2, end=path.length())
  } else {
    path
  }
  for rule in rules {
    if check_attr_pattern_matches(normalized, rule.pattern) {
      for attr in rule.attrs {
        if !resolved.contains(attr.0) {
          order.push(attr.0)
        }
        resolved[attr.0] = attr.1
      }
    }
  }
  let result : Array[(String, String)] = []
  for name in order {
    match resolved.get(name) {
      Some(value) => result.push((name, value))
      None => ()
    }
  }
  result
}

///|
fn check_attr_pattern_matches(path : String, pattern : String) -> Bool {
  if pattern == path {
    return true
  }
  if pattern.has_prefix("*.") {
    return path.has_suffix(
      String::unsafe_substring(pattern, start=1, end=pattern.length()),
    )
  }
  if pattern.contains("/") {
    return @ignore.match_glob(pattern, path)
  }
  // Match against basename only
  let basename = match path.rev_find("/") {
    Some(idx) =>
      String::unsafe_substring(path, start=idx + 1, end=path.length())
    None => path
  }
  @ignore.match_glob(pattern, basename)
}

///|
fn check_attr_find_value(
  resolved : Array[(String, String)],
  attr : String,
) -> String {
  for entry in resolved {
    if entry.0 == attr {
      return entry.1
    }
  }
  "unspecified"
}

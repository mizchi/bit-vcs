///|
fn build_rule_content(rng : Lcg, len : Int) -> String {
  let sb = StringBuilder::new()
  for _ in 0..<len {
    let v = rng.next_int() % 100
    let c = if v < 5 {
      '\n'
    } else if v < 7 {
      '#'
    } else if v < 9 {
      '!'
    } else {
      (v % 95 + 32).unsafe_to_char()
    }
    sb.write_char(c)
  }
  sb.to_string()
}

///|
fn build_pattern(rng : Lcg, len : Int) -> String {
  let sb = StringBuilder::new()
  for _ in 0..<len {
    let v = rng.next_int() % 10
    let c = match v {
      0 => '*'
      1 => '?'
      2 => '['
      3 => ']'
      4 => '.'
      5 => '/'
      _ => (v % 26 + 97).unsafe_to_char()
    }
    sb.write_char(c)
  }
  sb.to_string()
}

///|
fn build_path(rng : Lcg, len : Int) -> String {
  let sb = StringBuilder::new()
  for _ in 0..<len {
    let v = rng.next_int() % 20
    let c = if v == 0 { '/' } else { (v % 26 + 97).unsafe_to_char() }
    sb.write_char(c)
  }
  sb.to_string()
}

///|
test "fuzz: ignore parse and match" {
  let rng = Lcg::new(13579)
  for _ in 0..<128 {
    let content = build_rule_content(rng, rng.next_int() % 200)
    let m = @ignore.Matcher::new()
    m.add_rules("", content)
    let path = build_path(rng, rng.next_int() % 40)
    ignore(m.is_ignored(path, false))
    let pat = build_pattern(rng, rng.next_int() % 32)
    ignore(@ignore.match_glob(pat, path))
    ignore(@ignore.parse(content, ""))
  }
}

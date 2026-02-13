///|
test "clone caps contain token: direct token word" {
  let caps = ["multi_ack thin-pack filter side-band-64k"]
  assert_true(clone_caps_contain_token(caps, "filter"))
}

///|
test "clone caps contain token: token with value" {
  let caps = ["filter=blob:none"]
  assert_true(clone_caps_contain_token(caps, "filter"))
}

///|
test "clone caps contain token: fetch equals token" {
  let caps = ["fetch=filter", "agent=git/2.45.0"]
  assert_true(clone_caps_contain_token(caps, "filter"))
}

///|
test "clone caps contain token: fetch embedded token list" {
  let caps = ["fetch=shallow deepen-since filter", "agent=git/2.45.0"]
  assert_true(clone_caps_contain_token(caps, "filter"))
}

///|
test "clone caps contain token: missing token" {
  let caps = ["multi_ack thin-pack", "fetch=shallow deepen-since"]
  assert_false(clone_caps_contain_token(caps, "filter"))
}

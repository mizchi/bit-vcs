///|
pub enum DocError {
  InvalidPageName(String)
  PageNotFound(String)
  EmptyBody
}

///|
fn docs_dir(root : String) -> String {
  root + "/.bit/docs"
}

///|
fn normalize_page_name(raw : String) -> String {
  if raw.has_suffix(".md") && raw.length() > 3 {
    return (try! raw[:raw.length() - 3]).to_string()
  }
  raw
}

///|
fn is_valid_page_name(page_name : String) -> Bool {
  let page = normalize_page_name(page_name)
  if page.length() == 0 {
    return false
  }
  if page == "." || page == ".." {
    return false
  }
  if page.has_prefix("/") {
    return false
  }
  for token in ["\\", "\n", "\r", "\t"] {
    if page.contains(token) {
      return false
    }
  }
  for view in page.split("/") {
    let seg = view.to_string()
    if seg.length() == 0 || seg == "." || seg == ".." {
      return false
    }
  }
  true
}

///|
pub fn list_pages(
  rfs : &@bit.RepoFileSystem,
  root : String,
  prefix : String?,
) -> Array[String] {
  let pages : Array[String] = []
  collect_pages(rfs, docs_dir(root), "", prefix, pages)
  let sorted : Array[String] = []
  for page in pages {
    let mut inserted = false
    for i in 0..<sorted.length() {
      if page_lex_less(page, sorted[i]) {
        sorted.insert(i, page)
        inserted = true
        break
      }
    }
    if not(inserted) {
      sorted.push(page)
    }
  }
  sorted
}

///|
pub fn read_page(
  rfs : &@bit.RepoFileSystem,
  root : String,
  page_name : String,
) -> Result[String, DocError] raise @bit.GitError {
  let page = normalize_page_name(page_name)
  let path = match resolve_page_path(root, page_name) {
    Some(path) => path
    None => return Err(InvalidPageName(page_name))
  }
  if not(rfs.is_file(path)) {
    return Err(PageNotFound(page))
  }
  Ok(decode_bytes(rfs.read_file(path)))
}

///|
pub fn put_page(
  wfs : &@bit.FileSystem,
  root : String,
  page_name : String,
  body : String,
) -> Result[String, DocError] raise @bit.GitError {
  if body.length() == 0 {
    return Err(EmptyBody)
  }
  let page = normalize_page_name(page_name)
  let path = match resolve_page_path(root, page_name) {
    Some(path) => path
    None => return Err(InvalidPageName(page_name))
  }
  wfs.mkdir_p(parent_dir(path))
  wfs.write_string(path, body + "\n")
  Ok(page)
}

///|
pub fn append_page(
  wfs : &@bit.FileSystem,
  rfs : &@bit.RepoFileSystem,
  root : String,
  page_name : String,
  message : String,
  timestamp : Int64,
) -> Result[String, DocError] raise @bit.GitError {
  if message.length() == 0 {
    return Err(EmptyBody)
  }
  let page = normalize_page_name(page_name)
  let path = match resolve_page_path(root, page_name) {
    Some(path) => path
    None => return Err(InvalidPageName(page_name))
  }
  wfs.mkdir_p(parent_dir(path))
  let mut content = if rfs.is_file(path) {
    decode_bytes(rfs.read_file(path))
  } else {
    ""
  }
  if content.length() > 0 && not(content.has_suffix("\n")) {
    content = content + "\n"
  }
  content = content + "- [\{timestamp}] \{message}\n"
  wfs.write_string(path, content)
  Ok(page)
}

///|
pub fn remove_page(
  wfs : &@bit.FileSystem,
  rfs : &@bit.RepoFileSystem,
  root : String,
  page_name : String,
) -> Result[String, DocError] raise @bit.GitError {
  let page = normalize_page_name(page_name)
  let path = match resolve_page_path(root, page_name) {
    Some(path) => path
    None => return Err(InvalidPageName(page_name))
  }
  if not(rfs.is_file(path)) {
    return Err(PageNotFound(page))
  }
  wfs.remove_file(path)
  Ok(page)
}

///|
fn resolve_page_path(root : String, page_name : String) -> String? {
  let page = normalize_page_name(page_name)
  if not(is_valid_page_name(page)) {
    return None
  }
  Some(docs_dir(root) + "/" + page + ".md")
}

///|
fn collect_pages(
  rfs : &@bit.RepoFileSystem,
  abs_dir : String,
  rel_dir : String,
  prefix : String?,
  out : Array[String],
) -> Unit {
  if not(rfs.is_dir(abs_dir)) {
    return
  }
  let entries = rfs.readdir(abs_dir) catch { _ => [] }
  for entry in entries {
    if entry == "." || entry == ".." {
      continue
    }
    let abs_path = abs_dir + "/" + entry
    let rel_path = if rel_dir.length() == 0 {
      entry
    } else {
      rel_dir + "/" + entry
    }
    if rfs.is_dir(abs_path) {
      collect_pages(rfs, abs_path, rel_path, prefix, out)
      continue
    }
    if not(entry.has_suffix(".md")) {
      continue
    }
    let page = (try! rel_path[:rel_path.length() - 3]).to_string()
    match prefix {
      Some(p) if not(page.has_prefix(p)) => continue
      _ => ()
    }
    out.push(page)
  }
}

///|
fn decode_bytes(data : Bytes) -> String {
  @encoding.decoder(@encoding.Encoding::UTF8).decode_lossy(data[:])
}

///|
fn parent_dir(path : String) -> String {
  if path.length() == 0 || path == "/" {
    return "/"
  }
  let sep = @path.sep.to_string()
  match path.rev_find(sep) {
    None => ""
    Some(idx) => if idx == 0 { sep } else { (try! path[:idx]).to_string() }
  }
}

///|
fn page_lex_less(a : String, b : String) -> Bool {
  let min_len = if a.length() < b.length() { a.length() } else { b.length() }
  for i in 0..<min_len {
    let lhs = a.unsafe_get(i)
    let rhs = b.unsafe_get(i)
    if lhs < rhs {
      return true
    }
    if lhs > rhs {
      return false
    }
  }
  a.length() < b.length()
}

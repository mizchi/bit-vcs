///| Ref storage helpers (loose/packed refs)

///|
fn decode_bytes_lossy_refs(data : Bytes) -> String {
  @utf8.decode_lossy(data[:])
}

///|
fn trim_string_refs(s : String) -> String {
  let mut start = 0
  let mut end = s.length()
  while start < end {
    let c = s.unsafe_get(start)
    if c == ' ' || c == '\t' || c == '\n' || c == '\r' {
      start += 1
    } else {
      break
    }
  }
  while end > start {
    let c = s.unsafe_get(end - 1)
    if c == ' ' || c == '\t' || c == '\n' || c == '\r' {
      end -= 1
    } else {
      break
    }
  }
  if start == 0 && end == s.length() {
    s
  } else {
    String::unsafe_substring(s, start~, end~)
  }
}

///|
pub fn collect_loose_ref_ids(
  fs : &@bit.RepoFileSystem,
  dir : String,
  prefix : String,
  out : Map[String, @bit.ObjectId],
  filter_prefix : String?,
) -> Unit {
  if !fs.is_dir(dir) {
    return ()
  }
  // Early-exit: when a refname-prefix filter is set, skip whole
  // subtrees whose refname can never intersect with the filter
  // (e.g. don't walk `refs/tags/` when the caller asked for
  // `refs/heads/`). Before this guard the recursion stepped into
  // every `.git/refs/*` directory and filtered at the file level.
  if filter_prefix is Some(pfx) &&
    prefix.length() > 0 &&
    !refs_subtree_intersects_filter(prefix, pfx) {
    return ()
  }
  let entries = fs.readdir(dir) catch { _ => [] }
  for entry in entries {
    if entry == "." || entry == ".." {
      continue
    }
    let path = dir + "/" + entry
    let name = if prefix.length() == 0 { entry } else { prefix + "/" + entry }
    if fs.is_dir(path) {
      collect_loose_ref_ids(fs, path, name, out, filter_prefix)
    } else if fs.is_file(path) {
      if filter_prefix is Some(pfx) && !name.has_prefix(pfx) {
        continue
      }
      let content = decode_bytes_lossy_refs(
        fs.read_file(path) catch {
          _ => continue
        },
      )
      let hex = trim_string_refs(content)
      if hex.length() == 0 {
        continue
      }
      let id = @bit.ObjectId::from_hex(hex) catch { _ => continue }
      out[name] = id
    }
  }
}

///|
/// Whether refnames under directory `dir_refname` can intersect the
/// caller-supplied `filter_prefix`. Used to prune the loose-ref
/// recursion without reading every directory entry. Both inputs are
/// refname-style paths (no leading `/`).
///
/// A refname under `dir_refname/` matches `filter_prefix` iff one of
/// the two strings is a prefix of the other (after appending `/` to
/// the directory):
///   * filter narrower than dir: filter starts with `dir + "/"`
///   * dir inside filter range:  `dir + "/"` starts with filter
fn refs_subtree_intersects_filter(
  dir_refname : String,
  filter_prefix : String,
) -> Bool {
  let with_slash = dir_refname + "/"
  filter_prefix.has_prefix(with_slash) || with_slash.has_prefix(filter_prefix)
}

///|
pub fn collect_packed_ref_ids(
  fs : &@bit.RepoFileSystem,
  git_dir : String,
  out : Map[String, @bit.ObjectId],
  filter_prefix : String?,
) -> Unit {
  let packed_path = git_dir + "/packed-refs"
  if !fs.is_file(packed_path) {
    return ()
  }
  let packed = fs.read_file(packed_path) catch { _ => Default::default() }
  let text = @utf8.decode_lossy(packed[:])
  for line_view in text.split("\n") {
    let line = trim_string_refs(line_view.to_owned())
    if line.length() == 0 {
      continue
    }
    if line.has_prefix("#") || line.has_prefix("^") {
      continue
    }
    let space = line.find(" ")
    match space {
      None => continue
      Some(idx) => {
        if idx + 1 >= line.length() {
          continue
        }
        let id_hex = String::unsafe_substring(line, start=0, end=idx)
        let refname = String::unsafe_substring(
          line,
          start=idx + 1,
          end=line.length(),
        )
        if filter_prefix is Some(pfx) && !refname.has_prefix(pfx) {
          continue
        }
        if out.contains(refname) {
          continue
        }
        let id = @bit.ObjectId::from_hex(id_hex) catch { _ => continue }
        out[refname] = id
      }
    }
  }
}

///|
pub fn list_refs_with_ids(
  fs : &@bit.RepoFileSystem,
  git_dir : String,
  filter_prefix : String?,
) -> Map[String, @bit.ObjectId] {
  let out : Map[String, @bit.ObjectId] = Map([])
  // Collect from reftable if present
  if fs.is_dir(git_dir + "/reftable") {
    let reftable_refs = @reftable.collect_reftable_refs(fs, git_dir) catch {
      _ => []
    }
    for pair in reftable_refs {
      let (name, id) = pair
      let matches = match filter_prefix {
        Some(p) => name.has_prefix(p)
        None => true
      }
      if matches {
        out[name] = id
      }
    }
  }
  let refs_dir = git_dir + "/refs"
  collect_loose_ref_ids(fs, refs_dir, "refs", out, filter_prefix)
  collect_packed_ref_ids(fs, git_dir, out, filter_prefix)
  out
}

///|

///|
/// A single packed-refs entry with its optional peeled (`^<oid>`) line.
pub(all) struct PackedRefEntry {
  refname : String
  oid : String
  peeled : String?
} derive(Debug, Eq)

///|
/// Parse packed-refs text into entries. Header (`#`) and blank lines are
/// dropped; a `^` line is attached to the entry that precedes it.
pub fn parse_packed_refs_text(text : String) -> Array[PackedRefEntry] {
  let entries : Array[PackedRefEntry] = []
  for line_view in text.split("\n") {
    let line = line_view.to_owned()
    if line.length() == 0 || line.has_prefix("#") {
      continue
    }
    if line.has_prefix("^") {
      if entries.length() > 0 {
        let last = entries[entries.length() - 1]
        entries[entries.length() - 1] = {
          refname: last.refname,
          oid: last.oid,
          peeled: Some(
            String::unsafe_substring(line, start=1, end=line.length()),
          ),
        }
      }
      continue
    }
    match line.find(" ") {
      Some(idx) =>
        if idx > 0 && idx + 1 < line.length() {
          entries.push({
            refname: String::unsafe_substring(
              line,
              start=idx + 1,
              end=line.length(),
            ),
            oid: String::unsafe_substring(line, start=0, end=idx),
            peeled: None,
          })
        }
      None => ()
    }
  }
  entries
}

///|
/// Serialize entries into canonical packed-refs text: exactly one entry per
/// refname (later duplicates win), sorted by refname, with git's standard
/// header. Every packed-refs write MUST go through this (or produce the same
/// invariants): real git trusts the `sorted` trait and binary-searches the
/// file, so an unsorted or duplicated file breaks ref resolution in real git.
pub fn serialize_packed_refs_entries(entries : Array[PackedRefEntry]) -> String {
  let dedup : Map[String, PackedRefEntry] = Map([])
  for e in entries {
    dedup[e.refname] = e
  }
  let unique : Array[PackedRefEntry] = dedup.iter().map(kv => kv.1).collect()
  // NOTE: String::compare is length-first in MoonBit; git requires plain
  // byte order (memcmp) for the `sorted` trait, which lexical_compare gives.
  unique.sort_by((a, b) => String::lexical_compare(a.refname, b.refname))
  let buf = StringBuilder::new()
  // Trailing space after "sorted" matches real git's header byte-for-byte.
  buf.write_string("# pack-refs with: peeled fully-peeled sorted \n")
  for e in unique {
    buf.write_string(e.oid + " " + e.refname + "\n")
    match e.peeled {
      Some(p) => buf.write_string("^" + p + "\n")
      None => ()
    }
  }
  buf.to_string()
}

///|
pub fn rewrite_packed_refs(
  fs : &@bit.FileSystem,
  rfs : &@bit.RepoFileSystem,
  git_dir : String,
  transform : (String) -> String?,
) -> Unit raise @bit.GitError {
  let packed_path = git_dir + "/packed-refs"
  if !rfs.is_file(packed_path) {
    return ()
  }
  let data = rfs.read_file(packed_path) catch { _ => Default::default() }
  let text = @utf8.decode_lossy(data[:])
  let entries = parse_packed_refs_text(text)
  let kept : Array[PackedRefEntry] = []
  for e in entries {
    match transform(e.refname) {
      Some(new_ref) =>
        kept.push({ refname: new_ref, oid: e.oid, peeled: e.peeled })
      None => ()
    }
  }
  if kept.length() == 0 {
    fs.remove_file(packed_path) catch {
      _ => ()
    }
  } else {
    fs.write_string(packed_path, serialize_packed_refs_entries(kept))
  }
}

///|
pub fn remove_packed_ref(
  fs : &@bit.FileSystem,
  rfs : &@bit.RepoFileSystem,
  git_dir : String,
  refname : String,
) -> Unit raise @bit.GitError {
  rewrite_packed_refs(fs, rfs, git_dir, fn(name) {
    if name == refname {
      None
    } else {
      Some(name)
    }
  })
}

///|
pub fn remove_packed_refs_with_prefix(
  fs : &@bit.FileSystem,
  rfs : &@bit.RepoFileSystem,
  git_dir : String,
  prefix : String,
  exact : String,
) -> Unit raise @bit.GitError {
  rewrite_packed_refs(fs, rfs, git_dir, fn(name) {
    if name == exact || name.has_prefix(prefix) {
      None
    } else {
      Some(name)
    }
  })
}

///|
pub fn rename_packed_refs_prefix(
  fs : &@bit.FileSystem,
  rfs : &@bit.RepoFileSystem,
  git_dir : String,
  old_prefix : String,
  new_prefix : String,
  old_exact : String,
  new_exact : String,
) -> Unit raise @bit.GitError {
  rewrite_packed_refs(fs, rfs, git_dir, fn(name) {
    if name == old_exact {
      Some(new_exact)
    } else if name.has_prefix(old_prefix) {
      let suffix = String::unsafe_substring(
        name,
        start=old_prefix.length(),
        end=name.length(),
      )
      Some(new_prefix + suffix)
    } else {
      Some(name)
    }
  })
}

///|
pub fn list_remote_tracking_refs(
  fs : &@bit.RepoFileSystem,
  git_dir : String,
  remote_name : String,
) -> Map[String, @bit.ObjectId] {
  let prefix = "refs/remotes/" + remote_name + "/"
  let refs = list_refs_with_ids(fs, git_dir, Some(prefix))
  let out : Map[String, @bit.ObjectId] = Map([])
  for refname, id in refs {
    if !refname.has_prefix(prefix) {
      continue
    }
    let name = String::unsafe_substring(
      refname,
      start=prefix.length(),
      end=refname.length(),
    )
    if name.length() == 0 || name == "HEAD" {
      continue
    }
    out[name] = id
  }
  out
}

///|
pub fn remove_remote_refs(
  fs : &@bit.FileSystem,
  rfs : &@bit.RepoFileSystem,
  git_dir : String,
  name : String,
) -> Unit {
  let refs_dir = git_dir + "/refs/remotes/" + name
  if rfs.is_dir(refs_dir) || rfs.is_file(refs_dir) {
    remove_tree_internal(fs, rfs, refs_dir)
  }
  let logs_dir = git_dir + "/logs/refs/remotes/" + name
  if rfs.is_dir(logs_dir) || rfs.is_file(logs_dir) {
    remove_tree_internal(fs, rfs, logs_dir)
  }
}

///|
fn remove_tree_internal(
  fs : &@bit.FileSystem,
  rfs : &@bit.RepoFileSystem,
  path : String,
) -> Unit {
  if rfs.is_dir(path) {
    let entries = rfs.readdir(path) catch { _ => [] }
    for entry in entries {
      if entry == "." || entry == ".." {
        continue
      }
      remove_tree_internal(fs, rfs, path + "/" + entry)
    }
    fs.remove_dir(path) catch {
      _ => ()
    }
    return ()
  }
  if rfs.is_file(path) {
    fs.remove_file(path) catch {
      _ => ()
    }
  }
}

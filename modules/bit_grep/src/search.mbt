///|
pub(all) struct GrepLineMatch {
  line_number : Int
  column : Int
  line : String
} derive(Eq, Debug)

///|
pub(all) struct GrepFileMatch {
  path : String
  matches : Array[GrepLineMatch]
} derive(Eq, Debug)

///|
fn grep_search_show_string(value : String) -> String {
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
pub impl Show for GrepLineMatch with fn output(self, logger) {
  logger.write_string(
    "{line_number: " +
    self.line_number.to_string() +
    ", column: " +
    self.column.to_string() +
    ", line: " +
    grep_search_show_string(self.line) +
    "}",
  )
}

///|
pub impl Show for GrepFileMatch with fn output(self, logger) {
  logger.write_string(
    "{path: " +
    grep_search_show_string(self.path) +
    ", matches: " +
    Repr(self.matches).to_string() +
    "}",
  )
}

///|
priv struct GrepBlobSource {
  display_path : String
  blob_id : @bit.ObjectId
}

///|
pub fn search_tracked_worktree(
  fs : &@bit.RepoFileSystem,
  git_dir : String,
  root : String,
  patterns : Array[String],
  paths : Array[String],
  pattern_type? : GrepPatternType = GrepPatternType::Fixed,
  ignore_case? : Bool = false,
  invert_match? : Bool = false,
  word_regexp? : Bool = false,
  max_depth? : Int = -1,
) -> Array[GrepFileMatch] raise @bit.GitError {
  let expr = match grep_or_expr_from_patterns(patterns) {
    Some(value) => value
    None => return []
  }
  search_tracked_worktree_expr(
    fs,
    git_dir,
    root,
    expr,
    paths,
    pattern_type~,
    ignore_case~,
    invert_match~,
    word_regexp~,
    max_depth~,
  )
}

///|
pub fn search_tracked_worktree_expr(
  fs : &@bit.RepoFileSystem,
  git_dir : String,
  root : String,
  expr : GrepExpr,
  paths : Array[String],
  pattern_type? : GrepPatternType = GrepPatternType::Fixed,
  ignore_case? : Bool = false,
  invert_match? : Bool = false,
  word_regexp? : Bool = false,
  max_depth? : Int = -1,
) -> Array[GrepFileMatch] raise @bit.GitError {
  let index_entries = @bitlib.read_index_entries(fs, git_dir)
  let assume_unchanged_paths = @bitlib.read_assume_unchanged_paths(fs, git_dir)
  let skip_worktree_paths = @bitlib.read_skip_worktree_paths(fs, git_dir)
  let db = @bitlib.ObjectDb::load(fs, git_dir)
  let matches : Array[GrepFileMatch] = []
  for entry in index_entries {
    if !grep_path_matches_filters(entry.path, paths, max_depth) {
      continue
    }
    let abs_path = root + "/" + entry.path
    let has_worktree_file = fs.is_file(abs_path)
    let content = if assume_unchanged_paths.contains(entry.path) {
      if skip_worktree_paths.contains(entry.path) {
        if !has_worktree_file {
          continue
        }
        @utf8.decode_lossy(fs.read_file(abs_path)[:])
      } else {
        if entry.intent_to_add {
          continue
        }
        let obj = db.get(fs, entry.id)
        guard obj is Some(blob) else { continue }
        @utf8.decode_lossy(blob.data[:])
      }
    } else if skip_worktree_paths.contains(entry.path) {
      if !has_worktree_file {
        continue
      }
      @utf8.decode_lossy(fs.read_file(abs_path)[:])
    } else {
      if entry.intent_to_add {
        continue
      }
      if !has_worktree_file {
        continue
      }
      @utf8.decode_lossy(fs.read_file(abs_path)[:])
    }
    let file_matches = collect_line_matches(
      content, expr, pattern_type, ignore_case, invert_match, word_regexp,
    )
    if file_matches.length() > 0 {
      matches.push({ path: entry.path, matches: file_matches })
    }
  }
  matches
}

///|
pub fn list_tracked_worktree_candidate_paths(
  fs : &@bit.RepoFileSystem,
  git_dir : String,
  paths : Array[String],
  max_depth? : Int = -1,
) -> Array[String] raise @bit.GitError {
  let index_entries = @bitlib.read_index_entries(fs, git_dir)
  let assume_unchanged_paths = @bitlib.read_assume_unchanged_paths(fs, git_dir)
  let out : Array[String] = []
  for entry in index_entries {
    if !grep_path_matches_filters(entry.path, paths, max_depth) {
      continue
    }
    if entry.intent_to_add && assume_unchanged_paths.contains(entry.path) {
      continue
    }
    out.push(entry.path)
  }
  out
}

///|
pub fn search_index(
  fs : &@bit.RepoFileSystem,
  git_dir : String,
  patterns : Array[String],
  paths : Array[String],
  pattern_type? : GrepPatternType = GrepPatternType::Fixed,
  ignore_case? : Bool = false,
  invert_match? : Bool = false,
  word_regexp? : Bool = false,
  max_depth? : Int = -1,
) -> Array[GrepFileMatch] raise @bit.GitError {
  let expr = match grep_or_expr_from_patterns(patterns) {
    Some(value) => value
    None => return []
  }
  search_index_expr(
    fs,
    git_dir,
    expr,
    paths,
    pattern_type~,
    ignore_case~,
    invert_match~,
    word_regexp~,
    max_depth~,
  )
}

///|
pub fn search_index_expr(
  fs : &@bit.RepoFileSystem,
  git_dir : String,
  expr : GrepExpr,
  paths : Array[String],
  pattern_type? : GrepPatternType = GrepPatternType::Fixed,
  ignore_case? : Bool = false,
  invert_match? : Bool = false,
  word_regexp? : Bool = false,
  max_depth? : Int = -1,
) -> Array[GrepFileMatch] raise @bit.GitError {
  let index_entries = @bitlib.read_index_entries(fs, git_dir)
  let sources = collect_index_blob_sources(index_entries, paths, max_depth)
  let db = @bitlib.ObjectDb::load(fs, git_dir)
  search_blob_sources(
    db, fs, sources, expr, pattern_type, ignore_case, invert_match, word_regexp,
  )
}

///|
pub fn list_index_candidate_paths(
  fs : &@bit.RepoFileSystem,
  git_dir : String,
  paths : Array[String],
  max_depth? : Int = -1,
) -> Array[String] raise @bit.GitError {
  let index_entries = @bitlib.read_index_entries(fs, git_dir)
  grep_collect_candidate_paths(index_entries, paths, max_depth)
}

///|
pub fn search_treeish(
  fs : &@bit.RepoFileSystem,
  git_dir : String,
  spec : String,
  patterns : Array[String],
  paths : Array[String],
  pattern_type? : GrepPatternType = GrepPatternType::Fixed,
  ignore_case? : Bool = false,
  invert_match? : Bool = false,
  word_regexp? : Bool = false,
  max_depth? : Int = -1,
) -> Array[GrepFileMatch] raise @bit.GitError {
  let expr = match grep_or_expr_from_patterns(patterns) {
    Some(value) => value
    None => return []
  }
  search_treeish_expr(
    fs,
    git_dir,
    spec,
    expr,
    paths,
    pattern_type~,
    ignore_case~,
    invert_match~,
    word_regexp~,
    max_depth~,
  )
}

///|
pub fn search_treeish_expr(
  fs : &@bit.RepoFileSystem,
  git_dir : String,
  spec : String,
  expr : GrepExpr,
  paths : Array[String],
  pattern_type? : GrepPatternType = GrepPatternType::Fixed,
  ignore_case? : Bool = false,
  invert_match? : Bool = false,
  word_regexp? : Bool = false,
  max_depth? : Int = -1,
) -> Array[GrepFileMatch] raise @bit.GitError {
  let db = @bitlib.ObjectDb::load(fs, git_dir)
  let tree_id = match @bitrepo.rev_parse(fs, git_dir, spec + "^{tree}") {
    Some(id) => id
    None =>
      raise @bit.GitError::InvalidObject(
        "fatal: ambiguous argument '" + spec + "': unknown revision or path",
      )
  }
  let tree_paths = collect_tree_blob_sources(db, fs, tree_id, "", spec)
  let filtered_sources = filter_blob_sources_by_paths(
    tree_paths, paths, max_depth,
  )
  search_blob_sources(
    db, fs, filtered_sources, expr, pattern_type, ignore_case, invert_match, word_regexp,
  )
}

///|
pub fn list_treeish_candidate_paths(
  fs : &@bit.RepoFileSystem,
  git_dir : String,
  spec : String,
  paths : Array[String],
  max_depth? : Int = -1,
) -> Array[String] raise @bit.GitError {
  let db = @bitlib.ObjectDb::load(fs, git_dir)
  let tree_id = match @bitrepo.rev_parse(fs, git_dir, spec + "^{tree}") {
    Some(id) => id
    None =>
      raise @bit.GitError::InvalidObject(
        "fatal: ambiguous argument '" + spec + "': unknown revision or path",
      )
  }
  let sources = filter_blob_sources_by_paths(
    collect_tree_blob_sources(db, fs, tree_id, "", spec),
    paths,
    max_depth,
  )
  let out : Array[String] = []
  for source in sources {
    out.push(source.display_path)
  }
  out
}

///|
pub fn search_plain_worktree_expr(
  fs : &@bit.RepoFileSystem,
  root : String,
  expr : GrepExpr,
  paths : Array[String],
  pattern_type? : GrepPatternType = GrepPatternType::Fixed,
  ignore_case? : Bool = false,
  invert_match? : Bool = false,
  word_regexp? : Bool = false,
  max_depth? : Int = -1,
  exclude_standard? : Bool = false,
) -> Array[GrepFileMatch] raise @bit.GitError {
  let candidate_paths = list_plain_worktree_candidate_paths(
    fs,
    root,
    paths,
    max_depth~,
    exclude_standard~,
  )
  search_worktree_paths(
    fs, root, candidate_paths, expr, pattern_type, ignore_case, invert_match, word_regexp,
  )
}

///|
pub fn list_plain_worktree_candidate_paths(
  fs : &@bit.RepoFileSystem,
  root : String,
  paths : Array[String],
  max_depth? : Int = -1,
  exclude_standard? : Bool = false,
) -> Array[String] raise @bit.GitError {
  let out : Array[String] = []
  let matcher = @ignore.Matcher::new()
  grep_walk_plain_dir(fs, root, "", exclude_standard, matcher, out)
  out.sort_by((a, b) => String::lexical_compare(a, b))
  let filtered : Array[String] = []
  for path in out {
    if grep_path_matches_filters(path, paths, max_depth) {
      filtered.push(path)
    }
  }
  filtered
}

///|
pub fn search_untracked_worktree_expr(
  fs : &@bit.RepoFileSystem,
  git_dir : String,
  root : String,
  expr : GrepExpr,
  paths : Array[String],
  pattern_type? : GrepPatternType = GrepPatternType::Fixed,
  ignore_case? : Bool = false,
  invert_match? : Bool = false,
  word_regexp? : Bool = false,
  max_depth? : Int = -1,
) -> Array[GrepFileMatch] raise @bit.GitError {
  let candidate_paths = list_untracked_worktree_candidate_paths(
    fs,
    git_dir,
    root,
    paths,
    max_depth~,
  )
  search_worktree_paths(
    fs, root, candidate_paths, expr, pattern_type, ignore_case, invert_match, word_regexp,
  )
}

///|
pub fn list_untracked_worktree_candidate_paths(
  fs : &@bit.RepoFileSystem,
  git_dir : String,
  root : String,
  paths : Array[String],
  max_depth? : Int = -1,
) -> Array[String] raise @bit.GitError {
  let tracked_entries = @bitlib.read_index_entries(fs, git_dir)
  let tracked : Map[String, Bool] = Map([])
  for entry in tracked_entries {
    tracked[entry.path] = true
  }
  let visible_paths = @bitlib.list_working_files(fs, root)
  let out : Array[String] = []
  for path in visible_paths {
    if tracked.contains(path) {
      continue
    }
    if grep_path_matches_filters(path, paths, max_depth) {
      out.push(path)
    }
  }
  out.sort_by((a, b) => String::lexical_compare(a, b))
  out
}

///|
fn search_worktree_paths(
  fs : &@bit.RepoFileSystem,
  root : String,
  candidate_paths : Array[String],
  expr : GrepExpr,
  pattern_type : GrepPatternType,
  ignore_case : Bool,
  invert_match : Bool,
  word_regexp : Bool,
) -> Array[GrepFileMatch] raise @bit.GitError {
  let matches : Array[GrepFileMatch] = []
  for path in candidate_paths {
    let abs_path = root + "/" + path
    if !fs.is_file(abs_path) {
      continue
    }
    let content = @utf8.decode_lossy(fs.read_file(abs_path)[:])
    let file_matches = collect_line_matches(
      content, expr, pattern_type, ignore_case, invert_match, word_regexp,
    )
    if file_matches.length() > 0 {
      matches.push({ path, matches: file_matches })
    }
  }
  matches
}

///|
fn grep_walk_plain_dir(
  fs : &@bit.RepoFileSystem,
  root : String,
  rel : String,
  exclude_standard : Bool,
  matcher : @ignore.Matcher,
  out : Array[String],
) -> Unit raise @bit.GitError {
  let dir = if rel == "" { root } else { @bit.join_path(root, rel) }
  match @bitio.readdir_typed(dir) {
    Some(typed_entries) =>
      grep_walk_plain_dir_typed(
        fs, root, rel, dir, exclude_standard, matcher, out, typed_entries,
      )
    None =>
      grep_walk_plain_dir_fallback(
        fs, root, rel, dir, exclude_standard, matcher, out,
      )
  }
}

///|
fn grep_walk_plain_dir_typed(
  fs : &@bit.RepoFileSystem,
  root : String,
  rel : String,
  dir : String,
  exclude_standard : Bool,
  matcher : @ignore.Matcher,
  out : Array[String],
  typed_entries : Array[(String, Int)],
) -> Unit raise @bit.GitError {
  let mut has_gitignore = false
  for entry in typed_entries {
    if entry.0 == ".gitignore" {
      has_gitignore = true
      break
    }
  }
  let prev_len = matcher.len()
  if exclude_standard && has_gitignore {
    let ignore_path = @bit.join_path(dir, ".gitignore")
    let content = @utf8.decode_lossy(fs.read_file(ignore_path)[:])
    matcher.add_rules(rel, content)
  }
  for entry in typed_entries {
    let name = entry.0
    let d_type = entry.1
    if name == ".git" || name == ".bit" || name == ".jj" {
      continue
    }
    let child_rel = if rel == "" { name } else { rel + "/" + name }
    let is_dir = if d_type == 4 {
      true
    } else if d_type == 10 || d_type == 0 {
      fs.is_dir(@bit.join_path(root, child_rel))
    } else {
      false
    }
    if exclude_standard && matcher.is_ignored(child_rel, is_dir) {
      if is_dir && matcher.has_negation() {
        grep_walk_plain_dir(fs, root, child_rel, exclude_standard, matcher, out)
      }
      continue
    }
    if is_dir {
      grep_walk_plain_dir(fs, root, child_rel, exclude_standard, matcher, out)
    } else {
      out.push(child_rel)
    }
  }
  if exclude_standard {
    matcher.truncate(prev_len)
  }
}

///|
fn grep_walk_plain_dir_fallback(
  fs : &@bit.RepoFileSystem,
  root : String,
  rel : String,
  dir : String,
  exclude_standard : Bool,
  matcher : @ignore.Matcher,
  out : Array[String],
) -> Unit raise @bit.GitError {
  let entries = fs.readdir(dir)
  let mut has_gitignore = false
  for name in entries {
    if name == ".gitignore" {
      has_gitignore = true
      break
    }
  }
  let prev_len = matcher.len()
  if exclude_standard && has_gitignore {
    let ignore_path = @bit.join_path(dir, ".gitignore")
    let content = @utf8.decode_lossy(fs.read_file(ignore_path)[:])
    matcher.add_rules(rel, content)
  }
  for name in entries {
    if name == "." ||
      name == ".." ||
      name == ".git" ||
      name == ".bit" ||
      name == ".jj" {
      continue
    }
    let child_rel = if rel == "" { name } else { rel + "/" + name }
    let child_path = @bit.join_path(root, child_rel)
    let is_dir = fs.is_dir(child_path)
    if exclude_standard && matcher.is_ignored(child_rel, is_dir) {
      if is_dir && matcher.has_negation() {
        grep_walk_plain_dir(fs, root, child_rel, exclude_standard, matcher, out)
      }
      continue
    }
    if is_dir {
      grep_walk_plain_dir(fs, root, child_rel, exclude_standard, matcher, out)
    } else {
      out.push(child_rel)
    }
  }
  if exclude_standard {
    matcher.truncate(prev_len)
  }
}

///|
fn collect_tracked_paths(
  index_entries : Array[@bitlib.IndexEntry],
  paths : Array[String],
  max_depth : Int,
) -> Array[String] {
  let files_to_search : Array[String] = []
  for entry in index_entries {
    if grep_path_matches_filters(entry.path, paths, max_depth) {
      files_to_search.push(entry.path)
    }
  }
  files_to_search
}

///|
fn grep_collect_candidate_paths(
  index_entries : Array[@bitlib.IndexEntry],
  paths : Array[String],
  max_depth : Int,
) -> Array[String] {
  let files_to_search : Array[String] = []
  for entry in index_entries {
    if entry.intent_to_add {
      continue
    }
    if grep_path_matches_filters(entry.path, paths, max_depth) {
      files_to_search.push(entry.path)
    }
  }
  files_to_search
}

///|
fn collect_index_paths(
  index_entries : Array[@bitlib.IndexEntry],
  paths : Array[String],
  max_depth : Int,
) -> Array[String] {
  collect_tracked_paths(index_entries, paths, max_depth)
}

///|
fn collect_index_blob_sources(
  index_entries : Array[@bitlib.IndexEntry],
  paths : Array[String],
  max_depth : Int,
) -> Array[GrepBlobSource] {
  let selected_paths = collect_index_paths(index_entries, paths, max_depth)
  let selected : Map[String, Bool] = Map([])
  for path in selected_paths {
    selected[path] = true
  }
  let sources : Array[GrepBlobSource] = []
  for entry in index_entries {
    if selected.get(entry.path).unwrap_or(false) {
      sources.push({ display_path: entry.path, blob_id: entry.id })
    }
  }
  sources
}

///|
fn collect_tree_blob_sources(
  db : @bitlib.ObjectDb,
  fs : &@bit.RepoFileSystem,
  tree_id : @bit.ObjectId,
  prefix : String,
  spec : String,
) -> Array[GrepBlobSource] raise @bit.GitError {
  let sources : Array[GrepBlobSource] = []
  let tree_obj = db.get(fs, tree_id)
  guard tree_obj is Some(obj) else { return sources }
  let entries = @bit.parse_tree(obj.data)
  for entry in entries {
    let path = if prefix == "" { entry.name } else { prefix + "/" + entry.name }
    if entry.mode.has_prefix("100") {
      sources.push({ display_path: spec + ":" + path, blob_id: entry.id })
    } else if entry.mode == "40000" || entry.mode == "040000" {
      let sub_sources = collect_tree_blob_sources(db, fs, entry.id, path, spec)
      for source in sub_sources {
        sources.push(source)
      }
    }
  }
  sources
}

///|
fn filter_blob_sources_by_paths(
  sources : Array[GrepBlobSource],
  paths : Array[String],
  max_depth : Int,
) -> Array[GrepBlobSource] {
  if paths.length() == 0 && max_depth < 0 {
    return sources
  }
  let filtered : Array[GrepBlobSource] = []
  for source in sources {
    let path = strip_treeish_display_prefix(source.display_path)
    if grep_path_matches_filters(path, paths, max_depth) {
      filtered.push(source)
    }
  }
  filtered
}

///|
fn strip_treeish_display_prefix(display_path : String) -> String {
  match display_path.find(":") {
    Some(idx) =>
      String::unsafe_substring(
        display_path,
        start=idx + 1,
        end=display_path.length(),
      )
    None => display_path
  }
}

///|
fn grep_path_matches_filters(
  path : String,
  filters : Array[String],
  max_depth : Int,
) -> Bool {
  if filters.length() == 0 {
    return max_depth < 0 || grep_path_depth(path) <= max_depth
  }
  for filter in filters {
    let normalized = grep_normalize_path_filter(filter)
    if grep_filter_has_glob(normalized) {
      if grep_glob_matches(path, normalized) {
        return true
      }
      continue
    }
    if normalized == "" {
      if max_depth < 0 || grep_path_depth(path) <= max_depth {
        return true
      }
      continue
    }
    if path == normalized {
      return true
    }
    if path.has_prefix(normalized + "/") {
      if max_depth < 0 {
        return true
      }
      let rel = String::unsafe_substring(
        path,
        start=normalized.length() + 1,
        end=path.length(),
      )
      if grep_path_depth(rel) <= max_depth {
        return true
      }
    }
  }
  false
}

///|
fn grep_filter_has_glob(path : String) -> Bool {
  path.contains("*") || path.contains("?") || path.contains("[")
}

///|
fn grep_glob_matches(path : String, pattern : String) -> Bool {
  grep_glob_match_chars(path.to_array(), 0, pattern.to_array(), 0)
}

///|
fn grep_glob_match_chars(
  text : Array[Char],
  ti : Int,
  pattern : Array[Char],
  pi : Int,
) -> Bool {
  if pi >= pattern.length() {
    return ti >= text.length()
  }
  let pc = pattern[pi]
  if pc == '*' {
    let mut next_ti = ti
    while next_ti <= text.length() {
      if grep_glob_match_chars(text, next_ti, pattern, pi + 1) {
        return true
      }
      next_ti += 1
    }
    return false
  }
  if ti >= text.length() {
    return false
  }
  if pc == '?' {
    return grep_glob_match_chars(text, ti + 1, pattern, pi + 1)
  }
  if pc == '[' {
    let class_end = grep_glob_class_end(pattern, pi)
    if class_end <= pi + 1 {
      return text[ti] == '[' &&
        grep_glob_match_chars(text, ti + 1, pattern, pi + 1)
    }
    if grep_glob_class_matches(pattern, pi, class_end, text[ti]) {
      return grep_glob_match_chars(text, ti + 1, pattern, class_end + 1)
    }
    return false
  }
  if text[ti] == pc {
    return grep_glob_match_chars(text, ti + 1, pattern, pi + 1)
  }
  false
}

///|
fn grep_glob_class_end(pattern : Array[Char], start : Int) -> Int {
  let mut i = start + 1
  while i < pattern.length() {
    if pattern[i] == ']' {
      return i
    }
    i += 1
  }
  start
}

///|
fn grep_glob_class_matches(
  pattern : Array[Char],
  start : Int,
  class_end : Int,
  c : Char,
) -> Bool {
  let mut i = start + 1
  while i < class_end {
    if pattern[i] == c {
      return true
    }
    i += 1
  }
  false
}

///|
fn grep_normalize_path_filter(path : String) -> String {
  if path == "." {
    ""
  } else if path.has_suffix("/") {
    String::unsafe_substring(path, start=0, end=path.length() - 1)
  } else {
    path
  }
}

///|
fn grep_path_depth(path : String) -> Int {
  let mut depth = 0
  for c in path.to_array() {
    if c == '/' {
      depth += 1
    }
  }
  depth
}

///|
fn search_blob_sources(
  db : @bitlib.ObjectDb,
  fs : &@bit.RepoFileSystem,
  sources : Array[GrepBlobSource],
  expr : GrepExpr,
  pattern_type : GrepPatternType,
  ignore_case : Bool,
  invert_match : Bool,
  word_regexp : Bool,
) -> Array[GrepFileMatch] raise @bit.GitError {
  let matches : Array[GrepFileMatch] = []
  for source in sources {
    let obj = db.get(fs, source.blob_id)
    guard obj is Some(blob) else { continue }
    let file_matches = collect_line_matches(
      @utf8.decode_lossy(blob.data[:]),
      expr,
      pattern_type,
      ignore_case,
      invert_match,
      word_regexp,
    )
    if file_matches.length() > 0 {
      matches.push({ path: source.display_path, matches: file_matches })
    }
  }
  matches
}

///|
fn collect_line_matches(
  content : String,
  expr : GrepExpr,
  pattern_type : GrepPatternType,
  ignore_case : Bool,
  invert_match : Bool,
  word_regexp : Bool,
) -> Array[GrepLineMatch] {
  let matches : Array[GrepLineMatch] = []
  let lines : Array[String] = []
  for line_view in content.split("\n") {
    lines.push(line_view.to_owned())
  }
  let last = lines.length() - 1
  for i in 0..<lines.length() {
    let line_number = i + 1
    let line = lines[i]
    if content.has_suffix("\n") && i == last && line == "" {
      continue
    }
    let result = grep_eval_expr(
      line,
      expr,
      pattern_type,
      ignore_case,
      word_regexp~,
    )
    let matched = result.matched
    let should_output = if invert_match { !matched } else { matched }
    if should_output {
      let column = match result.span {
        Some(value) => value.start_column
        None => 1
      }
      matches.push({ line_number, column, line })
    }
  }
  matches
}

///| Working tree operations: status, add, commit

///|
pub struct Status {
  staged_added : Array[String]
  staged_modified : Array[String]
  staged_deleted : Array[String]
  unstaged_modified : Array[String]
  unstaged_deleted : Array[String]
  untracked : Array[String]
}

///|
/// Get status similar to `git status --porcelain` buckets.
pub async fn status(
  fs : &@bit.RepoFileSystem,
  root : String,
  run_filter_cmd? : FilterCmd,
) -> Status raise @bit.GitError {
  let profile = profile_enabled()
  let mut t0 = profile_start(profile)
  let git_dir = join_path(root, ".git")
  let actual_git_dir = if fs.is_file(git_dir) {
    resolve_gitdir(fs, git_dir)
  } else {
    git_dir
  }
  let common_git_dir = resolve_common_git_dir(fs, actual_git_dir)
  let autocrlf = read_autocrlf_setting(fs, common_git_dir)
  let skip_worktree_paths = read_skip_worktree_paths(fs, actual_git_dir)
  let racy_git = racy_git_enabled()
  let (index_entries, cache_tree) = read_index_entries_with_cache_tree(
    fs, actual_git_dir,
  )
  t0 = profile_lap(profile, "status read_index_entries", t0)
  let (unstaged_modified, unstaged_deleted, untracked) = index_guided_status_walk(
    fs,
    root,
    actual_git_dir,
    index_entries,
    skip_worktree_paths,
    autocrlf,
    racy_git,
    run_filter_cmd?,
  )
  t0 = profile_lap(profile, "status index_guided_walk", t0)
  // Build index_map for staged changes detection
  let index_map : Map[String, IndexEntry] = Map([])
  for e in index_entries {
    if skip_worktree_paths.contains(e.path) {
      continue
    }
    index_map[e.path] = e
  }
  let staged_added : Array[String] = []
  let staged_modified : Array[String] = []
  let staged_deleted : Array[String] = []
  collect_staged_changes_from_head(
    fs, actual_git_dir, cache_tree, index_map, skip_worktree_paths, staged_modified,
    staged_deleted,
  )
  t0 = profile_lap(profile, "status read_head_entries", t0)
  for path in index_map.keys() {
    staged_added.push(path)
  }
  staged_added.sort()
  staged_modified.sort()
  staged_deleted.sort()
  unstaged_modified.sort()
  unstaged_deleted.sort()
  untracked.sort()
  ignore(profile_lap(profile, "status sort", t0))
  {
    staged_added,
    staged_modified,
    staged_deleted,
    unstaged_modified,
    unstaged_deleted,
    untracked,
  }
}

///|
/// Format status in porcelain-like lines.
pub async fn status_porcelain(
  fs : &@bit.RepoFileSystem,
  root : String,
) -> Array[String] raise @bit.GitError {
  let s = status(fs, root)
  status_porcelain_from(s)
}

///|
pub fn status_porcelain_from(s : Status) -> Array[String] {
  let tracked_count = s.staged_added.length() +
    s.staged_modified.length() +
    s.staged_deleted.length() +
    s.unstaged_modified.length() +
    s.unstaged_deleted.length()
  if tracked_count == 0 && s.untracked.length() == 0 {
    return []
  }
  let xmap : Map[String, Char] = Map([], capacity=tracked_count)
  let ymap : Map[String, Char] = Map([], capacity=tracked_count)
  for p in s.staged_added {
    xmap[p] = 'A'
  }
  for p in s.staged_modified {
    xmap[p] = 'M'
  }
  for p in s.staged_deleted {
    xmap[p] = 'D'
  }
  for p in s.unstaged_modified {
    ymap[p] = 'M'
  }
  for p in s.unstaged_deleted {
    ymap[p] = 'D'
  }
  // xmap.keys() ∪ ymap.keys() — paths touched by either side.
  let list : Array[String] = Array::new(capacity=tracked_count)
  for p in xmap.keys() {
    list.push(p)
  }
  for p in ymap.keys() {
    if !xmap.contains(p) {
      list.push(p)
    }
  }
  list.sort()
  let out : Array[String] = Array::new(
    capacity=list.length() + s.untracked.length(),
  )
  for p in list {
    let x = xmap.get(p).unwrap_or(' ')
    let y = ymap.get(p).unwrap_or(' ')
    out.push("\{x}\{y} \{p}")
  }
  for p in s.untracked {
    out.push("?? \{p}")
  }
  out
}

///|
/// Add files to index (like `git add`).
pub fn add_paths(
  fs : &@bit.FileSystem,
  rfs : &@bit.RepoFileSystem,
  root : String,
  paths : Array[String],
  algo? : @object.HashAlgorithm = @object.HashAlgorithm::Sha1,
) -> Unit raise @bit.GitError {
  let git_dir = join_path(root, ".git")
  let actual_git_dir = if rfs.is_file(git_dir) {
    resolve_gitdir(rfs, git_dir)
  } else {
    git_dir
  }
  let common_git_dir = resolve_common_git_dir(rfs, actual_git_dir)
  let effective_algo = match algo {
    @object.HashAlgorithm::Sha1 => repo_hash_algorithm(rfs, common_git_dir)
    _ => algo
  }
  let autocrlf = read_autocrlf_setting(rfs, common_git_dir)
  let entries = read_index_entries(rfs, actual_git_dir)
  let map : Map[String, IndexEntry] = Map([])
  for e in entries {
    map[e.path] = e
  }
  let all_paths = expand_paths(rfs, root, paths)
  for path in all_paths {
    let abs = join_path(root, path)
    if rfs.is_file(abs) {
      let content = rfs.read_file(abs)
      let attrs = resolve_eol_attrs(rfs, root, path)
      let storage_content = match attrs.filter {
        Some("lfs") => lfs_clean_content(fs, rfs, common_git_dir, content)
        _ => content
      }
      let normalized = clean_for_storage(storage_content, attrs, autocrlf)
      let id = write_loose_object(
        fs,
        common_git_dir,
        @bit.ObjectType::Blob,
        normalized,
        algo=effective_algo,
      )
      compat_record_blob_mapping(fs, rfs, common_git_dir, id, normalized)
      let size = content.length()
      let (mtime_sec, mtime_nsec, dev, ino, uid, gid) = match
        @bitio.worktree_entry_meta_sync(rfs, abs) {
        Some(info) =>
          (
            info.mtime_sec.unwrap_or(0),
            info.mtime_nsec.unwrap_or(0),
            info.dev.unwrap_or(0),
            info.ino.unwrap_or(0),
            info.uid.unwrap_or(0),
            info.gid.unwrap_or(0),
          )
        None => (0, 0, 0, 0, 0, 0)
      }
      map[path] = {
        path,
        id,
        mode: default_file_mode(),
        size,
        mtime_sec,
        mtime_nsec,
        intent_to_add: false,
        dev,
        ino,
        uid,
        gid,
      }
    } else {
      map.remove(path)
    }
  }
  let out = map.values().to_array()
  write_index_entries_preserving_cache_tree(fs, rfs, actual_git_dir, out)
}

///|
/// Add files to index with worktree mode detection (native).
pub async fn add_paths_async(
  fs : &@bit.FileSystem,
  rfs : &@bit.RepoFileSystem,
  root : String,
  paths : Array[String],
  run_filter_cmd? : FilterCmd,
  warnings? : Array[String],
) -> Unit raise @bit.GitError {
  let git_dir = join_path(root, ".git")
  let actual_git_dir = if rfs.is_file(git_dir) {
    resolve_gitdir(rfs, git_dir)
  } else {
    git_dir
  }
  let common_git_dir = resolve_common_git_dir(rfs, actual_git_dir)
  let effective_algo = repo_hash_algorithm(rfs, common_git_dir)
  let autocrlf = read_autocrlf_setting(rfs, common_git_dir)
  let core_filemode = read_core_filemode_setting(rfs, common_git_dir)
  let entries = read_index_entries(rfs, actual_git_dir)
  let map : Map[String, IndexEntry] = Map([])
  for e in entries {
    map[e.path] = e
  }
  let all_paths = expand_paths_async(rfs, root, paths)
  for path in all_paths {
    let abs = join_path(root, path)
    let meta = @bitio.worktree_entry_meta(rfs, abs)
    match meta {
      None => map.remove(path)
      Some(info) => {
        // Skip unchanged files: if stat matches index entry, no re-hash needed
        match map.get(path) {
          Some(existing) => {
            let stat_matches = match
              (info.size, info.mtime_sec, info.mtime_nsec) {
              (Some(sz), Some(ms), Some(mn)) =>
                sz == existing.size &&
                (existing.mtime_sec != 0 || existing.mtime_nsec != 0) &&
                ms == existing.mtime_sec &&
                mn == existing.mtime_nsec &&
                (!core_filemode || info.mode == existing.mode)
              _ => false
            }
            if stat_matches {
              continue
            }
          }
          _ => ()
        }
        match info.kind {
          @bitio.WorktreeKindMeta::Regular => {
            let content = rfs.read_file(abs)
            let attrs = resolve_eol_attrs(rfs, root, path)
            let storage_content = match attrs.filter {
              Some("lfs") => lfs_clean_content(fs, rfs, common_git_dir, content)
              Some(name) =>
                match run_filter_cmd {
                  Some(run_cmd) => {
                    let (clean_cmd, _) = read_filter_commands(
                      rfs, common_git_dir, name,
                    )
                    match clean_cmd {
                      Some(cmd) =>
                        (run_cmd.run)(root, actual_git_dir, cmd, content)
                      None => content
                    }
                  }
                  None => content
                }
              None => content
            }
            let normalized = clean_for_storage(storage_content, attrs, autocrlf)
            let entry_size = match attrs.filter {
              Some("lfs") => content.length()
              _ => storage_content.length()
            }
            // Collect CRLF conversion warnings
            match warnings {
              Some(warns) =>
                if !is_binary_bytes(storage_content) {
                  collect_crlf_warnings(
                    warns, path, storage_content, normalized, attrs, autocrlf,
                  )
                }
              None => ()
            }
            let id = write_loose_object(
              fs,
              common_git_dir,
              @bit.ObjectType::Blob,
              normalized,
              algo=effective_algo,
            )
            compat_record_blob_mapping(fs, rfs, common_git_dir, id, normalized)
            let size = entry_size
            let (mtime_sec, mtime_nsec) = info.mtime()
            let dev = info.dev.unwrap_or(0)
            let ino = info.ino.unwrap_or(0)
            let uid = info.uid.unwrap_or(0)
            let gid = info.gid.unwrap_or(0)
            let mode = if core_filemode {
              info.mode
            } else {
              match map.get(path) {
                Some(existing) => existing.mode
                None => default_file_mode()
              }
            }
            map[path] = {
              path,
              id,
              mode,
              size,
              mtime_sec,
              mtime_nsec,
              intent_to_add: false,
              dev,
              ino,
              uid,
              gid,
            }
          }
          @bitio.WorktreeKindMeta::Symlink =>
            match @bitio.read_symlink_target_path(abs) {
              Some(target) => {
                let bytes = @utf8.encode(target)
                let id = write_loose_object(
                  fs,
                  common_git_dir,
                  @bit.ObjectType::Blob,
                  bytes,
                  algo=effective_algo,
                )
                compat_record_blob_mapping(fs, rfs, common_git_dir, id, bytes)
                let size = bytes.length()
                let (mtime_sec, mtime_nsec) = info.mtime()
                let dev = info.dev.unwrap_or(0)
                let ino = info.ino.unwrap_or(0)
                let uid = info.uid.unwrap_or(0)
                let gid = info.gid.unwrap_or(0)
                map[path] = {
                  path,
                  id,
                  mode: info.mode,
                  size,
                  mtime_sec,
                  mtime_nsec,
                  intent_to_add: false,
                  dev,
                  ino,
                  uid,
                  gid,
                }
              }
              None => ()
            }
        }
      }
    }
  }
  let out = map.values().to_array()
  write_index_entries_preserving_cache_tree(fs, rfs, actual_git_dir, out)
}

///|
/// @bit.Commit current index and update HEAD.
pub fn commit(
  fs : &@bit.FileSystem,
  rfs : &@bit.RepoFileSystem,
  root : String,
  message : String,
  author : String,
  author_timestamp : Int64,
  committer? : String = author,
  committer_timestamp? : Int64 = author_timestamp,
  allow_empty? : Bool = false,
  timezone? : String = "+0000",
  encoding? : String = "UTF-8",
  author_timezone? : String? = None,
  committer_timezone? : String? = None,
  algo? : @object.HashAlgorithm = @object.HashAlgorithm::Sha1,
) -> @bit.ObjectId raise @bit.GitError {
  let git_dir = join_path(root, ".git")
  let actual_git_dir = if rfs.is_file(git_dir) {
    resolve_gitdir(rfs, git_dir)
  } else {
    git_dir
  }
  let common_git_dir = resolve_common_git_dir(rfs, actual_git_dir)
  let effective_algo = match algo {
    @object.HashAlgorithm::Sha1 => repo_hash_algorithm(rfs, common_git_dir)
    _ => algo
  }
  let parent = resolve_head_commit(rfs, actual_git_dir)
  let entries = read_index_entries(rfs, actual_git_dir)
  let tree_id = if entries.length() == 0 {
    if !allow_empty {
      raise @bit.GitError::InvalidObject("Empty index")
    }
    match parent {
      Some(parent_id) => {
        let db = ObjectDb::load_lazy(rfs, common_git_dir)
        let parent_tree = match db.get(rfs, parent_id) {
          Some(obj) if obj.obj_type == @bit.ObjectType::Commit =>
            (@bit.parse_commit(obj.data).tree |> Some) catch {
              _ => None
            }
          _ => None
        }
        match parent_tree {
          Some(tree) => tree
          None => {
            let (empty_tree_id, empty_tree_compressed) = @object.create_tree_with_algo(
              effective_algo,
              [],
            )
            write_object_bytes(
              fs, common_git_dir, empty_tree_id, empty_tree_compressed,
            )
            empty_tree_id
          }
        }
      }
      None => {
        let (empty_tree_id, empty_tree_compressed) = @object.create_tree_with_algo(
          effective_algo,
          [],
        )
        write_object_bytes(
          fs, common_git_dir, empty_tree_id, empty_tree_compressed,
        )
        empty_tree_id
      }
    }
  } else {
    write_tree_from_index(
      fs,
      rfs,
      common_git_dir,
      entries,
      missing_ok=true,
      algo=effective_algo,
    )
  }
  let parents = match parent {
    Some(p) => [p]
    None => []
  }
  let resolved_author_timezone = author_timezone.unwrap_or(timezone)
  let resolved_committer_timezone = committer_timezone.unwrap_or(timezone)
  let commit = @bit.Commit::new(
    tree_id,
    parents,
    author,
    author_timestamp,
    resolved_author_timezone,
    committer,
    committer_timestamp,
    resolved_committer_timezone,
    message,
    encoding~,
  )
  let (commit_id, compressed) = @object.create_commit_with_algo(
    effective_algo, commit,
  )
  write_object_bytes(fs, common_git_dir, commit_id, compressed)
  compat_record_commit_mapping(fs, rfs, common_git_dir, commit_id, commit)
  update_head_ref(fs, rfs, actual_git_dir, commit_id)
  append_head_update_reflogs(
    fs,
    rfs,
    actual_git_dir,
    parent.unwrap_or(@bit.ObjectId::zero()),
    commit_id,
    if parent is None {
      "commit (initial): " + worktree_commit_subject(message)
    } else {
      "commit: " + worktree_commit_subject(message)
    },
    committer~,
    timestamp=committer_timestamp,
    timezone=resolved_committer_timezone,
  )
  if entries.length() > 0 {
    write_index_entries_with_tree(fs, rfs, actual_git_dir, entries, tree_id)
  }
  commit_id
}

///|
fn expand_paths(
  fs : &@bit.RepoFileSystem,
  root : String,
  paths : Array[String],
) -> Array[String] raise @bit.GitError {
  let result : Array[String] = []
  let all = list_working_files(fs, root)
  for p in paths {
    let path = normalize_rel_path(p)
    // Handle "." specially - add all files
    if path == "." {
      for f in all {
        result.push(f)
      }
      continue
    }
    let abs = join_path(root, path)
    if fs.is_dir(abs) {
      let prefix = if path.has_suffix("/") { path } else { path + "/" }
      for f in all {
        if f.has_prefix(prefix) {
          result.push(f)
        }
      }
    } else {
      result.push(path)
    }
  }
  result
}

///|
async fn expand_paths_async(
  fs : &@bit.RepoFileSystem,
  root : String,
  paths : Array[String],
) -> Array[String] raise @bit.GitError {
  let result : Array[String] = []
  let all = list_working_files_async(fs, root)
  for p in paths {
    let path = normalize_rel_path(p)
    // Handle "." specially - add all files
    if path == "." {
      for f in all {
        result.push(f)
      }
      continue
    }
    let abs = join_path(root, path)
    if fs.is_dir(abs) {
      let prefix = if path.has_suffix("/") { path } else { path + "/" }
      for f in all {
        if f.has_prefix(prefix) {
          result.push(f)
        }
      }
    } else {
      result.push(path)
    }
  }
  result
}

///|
fn normalize_rel_path(path : String) -> String raise @bit.GitError {
  if path == "." {
    return "."
  }
  let normalized = if path.has_prefix("./") {
    String::unsafe_substring(path, start=2, end=path.length())
  } else {
    path
  }
  if normalized == "." || normalized == "" {
    return "."
  }
  normalize_repo_path(normalized) catch {
    _ => raise @bit.GitError::InvalidObject("invalid path: " + path)
  }
}

///|
fn default_file_mode() -> Int {
  33188 // 0o100644
}

///|
pub enum AutoCrlf {
  Off
  Input
  On
}

///|
pub fn read_autocrlf_setting(
  fs : &@bit.RepoFileSystem,
  git_dir : String,
) -> AutoCrlf {
  let mut value : AutoCrlf? = None
  match @bitio.env_get("HOME") {
    None => ()
    Some(home) => {
      let candidates : Array[String] = []
      if @bitio.env_get("XDG_CONFIG_HOME") is Some(base) {
        candidates.push(base + "/git/config")
      }
      candidates.push(home + "/.gitconfig")
      for path in candidates {
        if fs.is_file(path) {
          value = read_autocrlf_from_config(fs, path)
          break
        }
      }
    }
  }
  let local_path = join_path(git_dir, "config")
  if fs.is_file(local_path) {
    match read_autocrlf_from_config(fs, local_path) {
      Some(v) => value = Some(v)
      None => ()
    }
  }
  // GIT_CONFIG_OVERRIDES has highest priority (set by `git -c key=value`)
  match @bitio.env_get("GIT_CONFIG_OVERRIDES") {
    Some(env_value) =>
      for line_view in env_value.split("\n") {
        let line = line_view.to_owned().trim().to_owned()
        if line.to_lower().has_prefix("core.autocrlf=") {
          let v = String::unsafe_substring(line, start=14, end=line.length())
            .trim()
            .to_owned()
            .to_lower()
          value = Some(parse_autocrlf_value(v))
        }
      }
    None => ()
  }
  match value {
    Some(v) => v
    None => AutoCrlf::Off
  }
}

///|
fn read_autocrlf_from_config(
  fs : &@bit.RepoFileSystem,
  path : String,
) -> AutoCrlf? {
  let bytes = fs.read_file(path) catch { _ => return None }
  let content = @utf8.decode_lossy(bytes[:])
  parse_autocrlf_from_content(content)
}

///|
fn parse_autocrlf_from_content(content : String) -> AutoCrlf? {
  let mut section = ""
  let mut value : AutoCrlf? = None
  for line_view in content.split("\n") {
    let line = line_view.trim().to_owned()
    if line.length() == 0 {
      continue
    }
    if line.has_prefix("#") || line.has_prefix(";") {
      continue
    }
    if line.has_prefix("[") && line.has_suffix("]") {
      let inner = String::unsafe_substring(line, start=1, end=line.length() - 1)
      let inner_trim = inner.trim().to_owned()
      let section_name = match inner_trim.find(" ") {
        Some(i) => String::unsafe_substring(inner_trim, start=0, end=i)
        None => inner_trim
      }
      section = section_name.to_lower()
      continue
    }
    if section != "core" {
      continue
    }
    match line.find("=") {
      None => ()
      Some(idx) => {
        let key = String::unsafe_substring(line, start=0, end=idx)
          .trim()
          .to_owned()
          .to_lower()
        if key != "autocrlf" {
          continue
        }
        let raw_value = String::unsafe_substring(
            line,
            start=idx + 1,
            end=line.length(),
          )
          .trim()
          .to_owned()
          .to_lower()
        value = raw_value |> parse_autocrlf_value |> Some
      }
    }
  }
  value
}

///|
pub fn read_core_eol_setting(
  fs : &@bit.RepoFileSystem,
  git_dir : String,
) -> EolAttr {
  let mut value : EolAttr = EolAttr::Unspecified
  match @bitio.env_get("HOME") {
    None => ()
    Some(home) => {
      let candidates : Array[String] = []
      if @bitio.env_get("XDG_CONFIG_HOME") is Some(base) {
        candidates.push(base + "/git/config")
      }
      candidates.push(home + "/.gitconfig")
      for path in candidates {
        if fs.is_file(path) {
          match read_core_eol_from_config(fs, path) {
            Some(v) => value = v
            None => ()
          }
          break
        }
      }
    }
  }
  let local_path = join_path(git_dir, "config")
  if fs.is_file(local_path) {
    match read_core_eol_from_config(fs, local_path) {
      Some(v) => value = v
      None => ()
    }
  }
  // GIT_CONFIG_OVERRIDES has highest priority
  match @bitio.env_get("GIT_CONFIG_OVERRIDES") {
    Some(env_value) =>
      for line_view in env_value.split("\n") {
        let line = line_view.to_owned().trim().to_owned()
        if line.to_lower().has_prefix("core.eol=") {
          let v = String::unsafe_substring(line, start=9, end=line.length())
            .trim()
            .to_owned()
            .to_lower()
          value = parse_eol_value(v)
        }
      }
    None => ()
  }
  value
}

///|
fn read_core_eol_from_config(
  fs : &@bit.RepoFileSystem,
  path : String,
) -> EolAttr? {
  let bytes = fs.read_file(path) catch { _ => return None }
  let content = @utf8.decode_lossy(bytes[:])
  let mut section = ""
  let mut value : EolAttr? = None
  for line_view in content.split("\n") {
    let line = line_view.trim().to_owned()
    if line.length() == 0 {
      continue
    }
    if line.has_prefix("#") || line.has_prefix(";") {
      continue
    }
    if line.has_prefix("[") && line.has_suffix("]") {
      let inner = String::unsafe_substring(line, start=1, end=line.length() - 1)
      let inner_trim = inner.trim().to_owned()
      let section_name = match inner_trim.find(" ") {
        Some(i) => String::unsafe_substring(inner_trim, start=0, end=i)
        None => inner_trim
      }
      section = section_name.to_lower()
      continue
    }
    if section != "core" {
      continue
    }
    match line.find("=") {
      None => ()
      Some(idx) => {
        let key = String::unsafe_substring(line, start=0, end=idx)
          .trim()
          .to_owned()
          .to_lower()
        if key != "eol" {
          continue
        }
        let raw_value = String::unsafe_substring(
            line,
            start=idx + 1,
            end=line.length(),
          )
          .trim()
          .to_owned()
          .to_lower()
        value = Some(parse_eol_value(raw_value))
      }
    }
  }
  value
}

///|
fn parse_eol_value(value : String) -> EolAttr {
  match value {
    "lf" => EolAttr::Lf
    "crlf" => EolAttr::Crlf
    "native" => EolAttr::Lf // On Linux/macOS, native = LF
    _ => EolAttr::Unspecified
  }
}

///|
fn parse_autocrlf_value(value : String) -> AutoCrlf {
  match value {
    "true" | "yes" | "1" => AutoCrlf::On
    "input" => AutoCrlf::Input
    _ => AutoCrlf::Off
  }
}

///|
fn read_core_filemode_setting(
  fs : &@bit.RepoFileSystem,
  git_dir : String,
) -> Bool {
  let local_path = join_path(git_dir, "config")
  if !fs.is_file(local_path) {
    return true
  }
  match read_core_filemode_from_config(fs, local_path) {
    Some(v) => v
    None => true
  }
}

///|
/// Return whether executable-bit changes are significant for this repository.
pub fn core_filemode_enabled(
  fs : &@bit.RepoFileSystem,
  git_dir : String,
) -> Bool {
  read_core_filemode_setting(fs, git_dir)
}

///|
fn read_core_filemode_from_config(
  fs : &@bit.RepoFileSystem,
  path : String,
) -> Bool? {
  let bytes = fs.read_file(path) catch { _ => return None }
  let content = @utf8.decode_lossy(bytes[:])
  let mut section = ""
  let mut value : Bool? = None
  for line_view in content.split("\n") {
    let line = line_view.trim().to_owned()
    if line.length() == 0 {
      continue
    }
    if line.has_prefix("#") || line.has_prefix(";") {
      continue
    }
    if line.has_prefix("[") && line.has_suffix("]") {
      let inner = String::unsafe_substring(line, start=1, end=line.length() - 1)
      let inner_trim = inner.trim().to_owned()
      let section_name = match inner_trim.find(" ") {
        Some(i) => String::unsafe_substring(inner_trim, start=0, end=i)
        None => inner_trim
      }
      section = section_name.to_lower()
      continue
    }
    if section != "core" {
      continue
    }
    match line.find("=") {
      Some(idx) => {
        let key = String::unsafe_substring(line, start=0, end=idx)
          .trim()
          .to_owned()
          .to_lower()
        if key != "filemode" {
          continue
        }
        let raw_value = String::unsafe_substring(
            line,
            start=idx + 1,
            end=line.length(),
          )
          .trim()
          .to_owned()
          .to_lower()
        if raw_value == "true" ||
          raw_value == "yes" ||
          raw_value == "on" ||
          raw_value == "1" {
          value = Some(true)
        } else if raw_value == "false" ||
          raw_value == "no" ||
          raw_value == "off" ||
          raw_value == "0" {
          value = Some(false)
        }
      }
      None => ()
    }
  }
  value
}

///|
fn racy_git_enabled() -> Bool {
  match @bitio.env_get("BIT_RACY_GIT") {
    Some(v) => v != "" && v != "0"
    None => false
  }
}

///|
pub fn normalize_worktree_content(
  content : Bytes,
  autocrlf : AutoCrlf,
) -> Bytes {
  match autocrlf {
    Off => content
    Input | On =>
      if is_binary_bytes(content) {
        content
      } else {
        normalize_crlf_to_lf(content)
      }
  }
}

///|
pub fn is_binary_bytes(content : Bytes) -> Bool {
  let limit = if content.length() > 8000 { 8000 } else { content.length() }
  for i in 0..<limit {
    if content[i] == b'\x00' {
      return true
    }
  }
  false
}

///|
fn collect_crlf_warnings(
  warns : Array[String],
  path : String,
  original : Bytes,
  normalized : Bytes,
  attrs : FileEolAttrs,
  autocrlf : AutoCrlf,
) -> Unit {
  // Check if content was actually changed (CRLF→LF normalization happened)
  let has_crlf_in_original = bytes_contains_crlf(original)
  if has_crlf_in_original && original.length() != normalized.length() {
    // CRLF was replaced by LF in the repository
    // Now check if smudge would convert back to CRLF
    let would_crlf = match attrs.text {
      Unset => false
      Set | Auto =>
        match attrs.eol {
          Crlf => true
          Lf | Unspecified => autocrlf is On
        }
      Unspecified => autocrlf is On
    }
    if would_crlf {
      warns.push(
        "warning: in the working copy of '\{path}', CRLF will be replaced by LF the next time Git touches it",
      )
    } else {
      warns.push(
        "warning: in the working copy of '\{path}', CRLF will be replaced by LF",
      )
    }
  } else if !has_crlf_in_original && bytes_contains_lf(original) {
    // File has LF only. Check if smudge would add CRLF
    let would_crlf = match attrs.text {
      Unset => false
      Set | Auto =>
        match attrs.eol {
          Crlf => true
          Lf | Unspecified => autocrlf is On
        }
      Unspecified => autocrlf is On
    }
    if would_crlf {
      warns.push(
        "warning: in the working copy of '\{path}', LF will be replaced by CRLF",
      )
    }
  }
}

///|
fn bytes_contains_crlf(content : Bytes) -> Bool {
  let mut i = 0
  while i + 1 < content.length() {
    if content[i] == b'\r' && content[i + 1] == b'\n' {
      return true
    }
    i += 1
  }
  false
}

///|
fn bytes_contains_lf(content : Bytes) -> Bool {
  for i in 0..<content.length() {
    if content[i] == b'\n' {
      return true
    }
  }
  false
}

///|
pub fn normalize_crlf_to_lf(content : Bytes) -> Bytes {
  let out : Array[Byte] = []
  let mut i = 0
  let mut changed = false
  while i < content.length() {
    if content[i] == b'\r' &&
      i + 1 < content.length() &&
      content[i + 1] == b'\n' {
      out.push(b'\n')
      i += 2
      changed = true
      continue
    }
    out.push(content[i])
    i += 1
  }
  if !changed {
    return content
  }
  Bytes::from_array(FixedArray::makei(out.length(), i => out[i]))
}

///|
pub fn write_loose_object(
  fs : &@bit.FileSystem,
  git_dir : String,
  obj_type : @bit.ObjectType,
  content : Bytes,
  algo? : @object.HashAlgorithm = @object.HashAlgorithm::Sha1,
) -> @bit.ObjectId raise @bit.GitError {
  let (id, compressed) = @object.create_object_with_algo(
    algo, obj_type, content,
  )
  write_object_bytes(fs, git_dir, id, compressed)
  id
}

///|
pub fn write_object_bytes(
  fs : &@bit.FileSystem,
  git_dir : String,
  id : @bit.ObjectId,
  compressed : Bytes,
) -> Unit raise @bit.GitError {
  let hex = id.to_hex()
  let path = join_path(
    git_dir,
    "objects/" +
    String::unsafe_substring(hex, start=0, end=2) +
    "/" +
    String::unsafe_substring(hex, start=2, end=hex.length()),
  )
  let dir = join_path(
    git_dir,
    "objects/" + String::unsafe_substring(hex, start=0, end=2),
  )
  fs.mkdir_p(dir)
  fs.write_file(path, compressed) catch {
    // Loose objects may already exist as read-only files.
    @bit.GitError::IoError(msg) if msg.contains("Permission denied") => {
      fs.remove_file(path) catch {
        _ => raise @bit.GitError::IoError(msg)
      }
      fs.write_file(path, compressed)
    }
    err => raise err
  }
}

///|
pub fn resolve_head_commit(
  fs : &@bit.RepoFileSystem,
  git_dir : String,
) -> @bit.ObjectId? raise @bit.GitError {
  match read_head_ref(fs, git_dir) {
    Branch(name) => resolve_ref(fs, git_dir, "refs/heads/" + name)
    Detached(id) => Some(id)
  }
}

///|
pub fn update_head_ref(
  fs : &@bit.FileSystem,
  rfs : &@bit.RepoFileSystem,
  git_dir : String,
  commit_id : @bit.ObjectId,
) -> Unit raise @bit.GitError {
  let common_git_dir = resolve_common_git_dir(rfs, git_dir)
  let head_path = join_path(git_dir, "HEAD")
  let head = read_head_ref(rfs, git_dir) catch {
    _ => HeadRef::Detached(commit_id)
  }
  match head {
    Branch(name) => {
      let refname = "refs/heads/" + name
      if rfs.is_dir(join_path(common_git_dir, "reftable")) {
        update_ref_reftable(fs, rfs, common_git_dir, refname, commit_id)
      } else {
        let ref_path = join_path(common_git_dir, refname)
        let dir = parent_dir(ref_path)
        fs.mkdir_p(dir)
        fs.write_string(ref_path, commit_id.to_hex() + "\n")
      }
    }
    Detached(_) => fs.write_string(head_path, commit_id.to_hex() + "\n")
  }
}

///|
fn append_head_update_reflogs(
  fs : &@bit.FileSystem,
  rfs : &@bit.RepoFileSystem,
  git_dir : String,
  old_id : @bit.ObjectId,
  new_id : @bit.ObjectId,
  message : String,
  committer? : String = "unknown <unknown>",
  timestamp? : Int64 = 0L,
  timezone? : String = reflog_env_timezone(),
) -> Unit raise @bit.GitError {
  let (author, email) = reflog_parse_identity(committer)
  let (should_log_head, _) = should_log_ref(rfs, git_dir, "HEAD", false)
  if should_log_head {
    append_reflog(
      fs, rfs, git_dir, "HEAD", old_id, new_id, author, email, timestamp, timezone,
      message,
    )
  }
  match read_head_ref(rfs, git_dir) {
    Branch(name) => {
      let refname = "refs/heads/" + name
      let common_git_dir = resolve_common_git_dir(rfs, git_dir)
      let (should_log_branch, _) = should_log_ref(
        rfs, common_git_dir, refname, false,
      )
      if should_log_branch {
        append_reflog(
          fs, rfs, common_git_dir, refname, old_id, new_id, author, email, timestamp,
          timezone, message,
        )
      }
    }
    Detached(_) => ()
  }
}

///|
fn update_ref_reftable(
  fs : &@bit.FileSystem,
  rfs : &@bit.RepoFileSystem,
  git_dir : String,
  refname : String,
  commit_id : @bit.ObjectId,
) -> Unit raise @bit.GitError {
  // Determine next update_index
  let tables = @reftable.load_tables(rfs, git_dir)
  let max_index = if tables.length() > 0 {
    let last = tables[tables.length() - 1]
    match @reftable.parse_header(last) {
      Some(h) => h.max_update_index
      None => 0UL
    }
  } else {
    0UL
  }
  let next_index = max_index + 1UL
  let record : @reftable.RefRecord = {
    refname,
    update_index: next_index,
    value: @reftable.RefValue::Val1(commit_id),
  }
  let table_data = @reftable.write_reftable(
    [record],
    4096,
    next_index,
    next_index,
  )
  // Write table file
  let reftable_dir = git_dir + "/reftable"
  let pad_hex = reftable_index_to_hex12(next_index)
  let table_name = "0x" + pad_hex + "-0x" + pad_hex + "-00000000.ref"
  let table_path = reftable_dir + "/" + table_name
  fs.write_file(table_path, table_data)
  // Update tables.list
  let existing_names = @reftable.read_tables_list(rfs, git_dir)
  existing_names.push(table_name)
  let tables_list = existing_names.join("\n") + "\n"
  fs.write_string(reftable_dir + "/tables.list", tables_list)
}

///|
fn reftable_index_to_hex12(value : UInt64) -> String {
  let hex_chars : FixedArray[Byte] = [
    b'0', b'1', b'2', b'3', b'4', b'5', b'6', b'7', b'8', b'9', b'a', b'b', b'c',
    b'd', b'e', b'f',
  ]
  let buf = StringBuilder::new()
  for i = 11; i >= 0; i = i - 1 {
    let shift = i * 4
    let nibble = ((value >> shift.to_uint64().to_int()) & 0xfUL).to_int()
    buf.write_char(Int::unsafe_to_char(hex_chars[nibble].to_int()))
  }
  buf.to_string()
}

///|
pub fn write_tree_from_index(
  fs : &@bit.FileSystem,
  rfs : &@bit.RepoFileSystem,
  git_dir : String,
  entries : Array[IndexEntry],
  prefix? : String? = None,
  missing_ok? : Bool = false,
  algo? : @object.HashAlgorithm = @object.HashAlgorithm::Sha1,
) -> @bit.ObjectId raise @bit.GitError {
  let object_git_dir = resolve_common_git_dir(rfs, git_dir)
  let effective_algo = match algo {
    @object.HashAlgorithm::Sha1 => repo_hash_algorithm(rfs, object_git_dir)
    _ => algo
  }
  // If prefix is specified, filter entries and strip prefix from paths
  let rel_entries = match prefix {
    Some(p) => {
      // Ensure prefix ends with /
      let prefix_with_slash = if p.has_suffix("/") { p } else { p + "/" }
      let result : Array[IndexEntry] = []
      for e in entries {
        if worktree_is_zero_object_id(e.id) {
          continue
        }
        if e.path.has_prefix(prefix_with_slash) {
          // Strip the prefix from the path
          let new_path = String::unsafe_substring(
            e.path,
            start=prefix_with_slash.length(),
            end=e.path.length(),
          )
          result.push({
            path: new_path,
            id: e.id,
            mode: e.mode,
            size: e.size,
            mtime_sec: e.mtime_sec,
            mtime_nsec: e.mtime_nsec,
            intent_to_add: e.intent_to_add,
            dev: e.dev,
            ino: e.ino,
            uid: e.uid,
            gid: e.gid,
          })
        }
      }
      result
    }
    None => {
      let result : Array[IndexEntry] = []
      for e in entries {
        if worktree_is_zero_object_id(e.id) {
          continue
        }
        result.push(e)
      }
      result
    }
  }
  let object_db = if missing_ok {
    None
  } else {
    Some(ObjectDb::load_lazy(rfs, object_git_dir))
  }
  write_tree_from_entries(
    fs,
    rfs,
    object_git_dir,
    rel_entries,
    object_db,
    algo=effective_algo,
  )
}

///|
fn write_tree_from_entries(
  fs : &@bit.FileSystem,
  rfs : &@bit.RepoFileSystem,
  git_dir : String,
  entries : Array[IndexEntry],
  object_db : ObjectDb?,
  algo? : @object.HashAlgorithm = @object.HashAlgorithm::Sha1,
) -> @bit.ObjectId raise @bit.GitError {
  let effective_algo = match algo {
    @object.HashAlgorithm::Sha1 => repo_hash_algorithm(rfs, git_dir)
    _ => algo
  }
  let file_entries : Array[@bit.TreeEntry] = []
  let dir_map : Map[String, Array[IndexEntry]] = Map([])
  for e in entries {
    if worktree_is_zero_object_id(e.id) {
      continue
    }
    if !is_gitlink_mode_int(e.mode) {
      match object_db {
        Some(db) =>
          match db.get(rfs, e.id) {
            None =>
              raise @bit.GitError::InvalidObject(
                "Object not found: " + e.id.to_hex(),
              )
            Some(_) => ()
          }
        None => ()
      }
    }
    match split_first(e.path) {
      (name, None) => {
        let mode = @string_utils.mode_to_string(e.mode)
        file_entries.push(@bit.TreeEntry::new(mode, name, e.id))
      }
      (name, Some(rest)) =>
        match dir_map.get(name) {
          Some(list) =>
            list.push({
              path: rest,
              id: e.id,
              mode: e.mode,
              size: e.size,
              mtime_sec: e.mtime_sec,
              mtime_nsec: e.mtime_nsec,
              intent_to_add: e.intent_to_add,
              dev: e.dev,
              ino: e.ino,
              uid: e.uid,
              gid: e.gid,
            })
          None =>
            dir_map[name] = [
              {
                path: rest,
                id: e.id,
                mode: e.mode,
                size: e.size,
                mtime_sec: e.mtime_sec,
                mtime_nsec: e.mtime_nsec,
                intent_to_add: e.intent_to_add,
                dev: e.dev,
                ino: e.ino,
                uid: e.uid,
                gid: e.gid,
              },
            ]
        }
    }
  }
  for dir_name, list in dir_map {
    let sub_id = write_tree_from_entries(
      fs,
      rfs,
      git_dir,
      list,
      object_db,
      algo=effective_algo,
    )
    file_entries.push(@bit.TreeEntry::new("40000", dir_name, sub_id))
  }
  // Git sorts tree entries by name, with directories having "/" appended for comparison
  file_entries.sort_by(fn(a, b) {
    let a_key = if a.mode == "40000" { a.name + "/" } else { a.name }
    let b_key = if b.mode == "40000" { b.name + "/" } else { b.name }
    compare_strings_lexicographic(a_key, b_key)
  })
  let (tree_id, compressed) = @object.create_tree_with_algo(
    effective_algo, file_entries,
  )
  write_object_bytes(fs, git_dir, tree_id, compressed)
  compat_record_tree_mapping(fs, rfs, git_dir, tree_id, file_entries)
  tree_id
}

///|
fn worktree_is_zero_object_id(id : @bit.ObjectId) -> Bool {
  id.is_zero()
}

///|
fn split_first(path : String) -> (String, String?) {
  match path.find("/") {
    None => (path, None)
    Some(idx) => {
      let name = String::unsafe_substring(path, start=0, end=idx)
      let rest = String::unsafe_substring(
        path,
        start=idx + 1,
        end=path.length(),
      )
      (name, Some(rest))
    }
  }
}

///|
/// Lexicographic string comparison (byte-by-byte ASCII order)
fn compare_strings_lexicographic(a : String, b : String) -> Int {
  let a_len = a.length()
  let b_len = b.length()
  let min_len = if a_len < b_len { a_len } else { b_len }
  for i in 0..<min_len {
    let a_char = a.unsafe_get(i).to_int()
    let b_char = b.unsafe_get(i).to_int()
    if a_char < b_char {
      return -1
    } else if a_char > b_char {
      return 1
    }
  }
  // If all characters are equal, shorter string comes first
  if a_len < b_len {
    -1
  } else if a_len > b_len {
    1
  } else {
    0
  }
}

// mode_to_string and to_octal_string are defined in string_utils.mbt

///|
fn trim_worktree_text(s : String) -> String {
  let mut start = 0
  let mut end = s.length()
  while start < end {
    let c = s[start]
    if c == ' ' || c == '\n' || c == '\r' || c == '\t' {
      start += 1
    } else {
      break
    }
  }
  while end > start {
    let c = s[end - 1]
    if c == ' ' || c == '\n' || c == '\r' || c == '\t' {
      end -= 1
    } else {
      break
    }
  }
  String::unsafe_substring(s, start~, end~)
}

///|
fn resolve_worktree_common_git_dir(
  fs : &@bit.RepoFileSystem,
  git_dir : String,
) -> String {
  let commondir_path = join_path(git_dir, "commondir")
  if !fs.is_file(commondir_path) {
    return git_dir
  }
  let raw = @utf8.decode_lossy(
    (fs.read_file(commondir_path) catch { _ => Default::default() })[:],
  )
  let rel = trim_worktree_text(raw)
  if rel.length() == 0 {
    return git_dir
  }
  if rel.has_prefix("/") {
    normalize_path(rel)
  } else {
    normalize_path(join_path(git_dir, rel))
  }
}

///|
fn collect_staged_changes_from_head(
  fs : &@bit.RepoFileSystem,
  git_dir : String,
  cache_tree : IndexCacheTree?,
  index_map : Map[String, IndexEntry],
  skip_worktree_paths : Map[String, Bool],
  staged_modified : Array[String],
  staged_deleted : Array[String],
) -> Unit raise @bit.GitError {
  let head = resolve_head_commit(fs, git_dir)
  match head {
    None => return
    Some(commit_id) => {
      let common_git_dir = resolve_worktree_common_git_dir(fs, git_dir)
      let db = ObjectDb::load_lazy(fs, common_git_dir)
      // `git status` does not re-hash HEAD tree/commit objects on read (git
      // trusts the object store); skip the per-object SHA verification that
      // otherwise runs for every loose object walked here.
      db.set_skip_verify(true)
      let commit_obj = db.get(fs, commit_id)
      match commit_obj {
        None => return
        Some(obj) => {
          if obj.obj_type != @bit.ObjectType::Commit {
            raise @bit.GitError::InvalidObject("Object is not a commit")
          }
          let info = @bit.parse_commit(obj.data)
          collect_staged_changes_db(
            db,
            fs,
            info.tree,
            "",
            cache_tree,
            index_map,
            skip_worktree_paths,
            staged_modified,
            staged_deleted,
          )
        }
      }
    }
  }
}

///|
fn collect_staged_changes_db(
  db : ObjectDb,
  fs : &@bit.RepoFileSystem,
  tree_id : @bit.ObjectId,
  prefix : String,
  cache_tree : IndexCacheTree?,
  index_map : Map[String, IndexEntry],
  skip_worktree_paths : Map[String, Bool],
  staged_modified : Array[String],
  staged_deleted : Array[String],
) -> Unit raise @bit.GitError {
  match cache_tree {
    Some(tree) if index_cache_tree_matches_tree(tree, tree_id) => {
      index_map_remove_tree_paths(index_map, prefix)
      return
    }
    _ => ()
  }
  let tree_obj = db.get(fs, tree_id)
  match tree_obj {
    None => raise @bit.GitError::InvalidObject("Missing tree object")
    Some(obj) => {
      if obj.obj_type != @bit.ObjectType::Tree {
        raise @bit.GitError::InvalidObject("Object is not a tree")
      }
      let entries = @bit.parse_tree(obj.data)
      for entry in entries {
        let path = if prefix.length() == 0 {
          entry.name
        } else {
          prefix + "/" + entry.name
        }
        if skip_worktree_paths.contains(path) {
          continue
        }
        if is_tree_mode(entry.mode) {
          collect_staged_changes_db(
            db,
            fs,
            entry.id,
            path,
            index_cache_tree_child(cache_tree, entry.name),
            index_map,
            skip_worktree_paths,
            staged_modified,
            staged_deleted,
          )
        } else {
          let mode = worktree_parse_octal(entry.mode)
          match index_map.get(path) {
            Some(index_entry) => {
              if index_entry.id != entry.id || index_entry.mode != mode {
                staged_modified.push(path)
              }
              index_map.remove(path)
            }
            None => staged_deleted.push(path)
          }
        }
      }
    }
  }
}

///|
fn index_cache_tree_matches_tree(
  cache_tree : IndexCacheTree,
  tree_id : @bit.ObjectId,
) -> Bool {
  match cache_tree.oid {
    Some(cache_tree_id) =>
      cache_tree.entry_count >= 0 && cache_tree_id == tree_id
    None => false
  }
}

///|
fn index_cache_tree_child(
  cache_tree : IndexCacheTree?,
  name : String,
) -> IndexCacheTree? {
  match cache_tree {
    None => None
    Some(tree) => {
      for subtree in tree.subtrees {
        if subtree.name == name {
          return Some(subtree)
        }
      }
      None
    }
  }
}

///|
fn index_map_remove_tree_paths(
  index_map : Map[String, IndexEntry],
  prefix : String,
) -> Unit {
  let paths : Array[String] = []
  for path in index_map.keys() {
    if prefix.length() == 0 || path.has_prefix(prefix + "/") {
      paths.push(path)
    }
  }
  for path in paths {
    index_map.remove(path)
  }
}

///|
fn worktree_parse_octal(s : String) -> Int {
  let mut result = 0
  for c in s {
    if c < '0' || c > '7' {
      continue
    }
    result = result * 8 + (c.to_int() - '0'.to_int())
  }
  result
}

///|
/// Commit with amend (replace the last commit).
pub fn commit_amend(
  fs : &@bit.FileSystem,
  rfs : &@bit.RepoFileSystem,
  root : String,
  message : String,
  author : String,
  author_timestamp : Int64,
  committer? : String = author,
  committer_timestamp? : Int64 = author_timestamp,
  timezone? : String = "+0000",
  encoding? : String = "UTF-8",
  author_timezone? : String? = None,
  committer_timezone? : String? = None,
  algo? : @object.HashAlgorithm = @object.HashAlgorithm::Sha1,
) -> @bit.ObjectId raise @bit.GitError {
  let git_dir = join_path(root, ".git")
  let actual_git_dir = if rfs.is_file(git_dir) {
    resolve_gitdir(rfs, git_dir)
  } else {
    git_dir
  }
  let common_git_dir = resolve_common_git_dir(rfs, actual_git_dir)
  let effective_algo = match algo {
    @object.HashAlgorithm::Sha1 => repo_hash_algorithm(rfs, common_git_dir)
    _ => algo
  }
  let entries = read_index_entries(rfs, actual_git_dir)
  if entries.length() == 0 {
    raise @bit.GitError::InvalidObject("Empty index")
  }
  let tree_id = write_tree_from_index(
    fs,
    rfs,
    common_git_dir,
    entries,
    algo=effective_algo,
  )
  // Get the parent of the current HEAD (grandparent of new commit)
  let current_head = resolve_head_commit(rfs, actual_git_dir)
  let parents = match current_head {
    Some(head_id) => {
      // Get parent of current HEAD
      let db = ObjectDb::load_lazy(rfs, common_git_dir)
      let obj = db.get(rfs, head_id)
      match obj {
        Some(o) => {
          let info = @bit.parse_commit(o.data)
          info.parents
        }
        None => []
      }
    }
    None => []
  }
  let resolved_author_timezone = author_timezone.unwrap_or(timezone)
  let resolved_committer_timezone = committer_timezone.unwrap_or(timezone)
  let commit = @bit.Commit::new(
    tree_id,
    parents,
    author,
    author_timestamp,
    resolved_author_timezone,
    committer,
    committer_timestamp,
    resolved_committer_timezone,
    message,
    encoding~,
  )
  let (commit_id, compressed) = @object.create_commit_with_algo(
    effective_algo, commit,
  )
  write_object_bytes(fs, common_git_dir, commit_id, compressed)
  compat_record_commit_mapping(fs, rfs, common_git_dir, commit_id, commit)
  update_head_ref(fs, rfs, actual_git_dir, commit_id)
  append_head_update_reflogs(
    fs,
    rfs,
    actual_git_dir,
    current_head.unwrap_or(@bit.ObjectId::zero()),
    commit_id,
    "commit (amend): " + worktree_commit_subject(message),
    committer~,
    timestamp=committer_timestamp,
    timezone=resolved_committer_timezone,
  )
  commit_id
}

///|
fn worktree_commit_subject(message : String) -> String {
  match message.find("\n") {
    Some(idx) => String::unsafe_substring(message, start=0, end=idx)
    None => message
  }
}

///|
fn reflog_parse_identity(identity : String) -> (String, String) {
  let trimmed = identity.trim().to_owned()
  match trimmed.find("<") {
    Some(start) =>
      match trimmed.find(">") {
        Some(end) if end > start => {
          let name = String::unsafe_substring(trimmed, start=0, end=start)
            .trim()
            .to_owned()
          let email = String::unsafe_substring(trimmed, start=start + 1, end~)
          (if name.length() == 0 { "unknown" } else { name }, email)
        }
        _ => (trimmed, "unknown")
      }
    None => (trimmed, "unknown")
  }
}

///|
fn reflog_env_timezone() -> String {
  "+0000"
}

///|
/// Remove files from index (and optionally working tree).
pub fn rm_paths(
  fs : &@bit.FileSystem,
  rfs : &@bit.RepoFileSystem,
  root : String,
  paths : Array[String],
  cached? : Bool = false,
  force? : Bool = false,
  recursive? : Bool = false,
) -> Unit raise @bit.GitError {
  let git_dir = join_path(root, ".git")
  let actual_git_dir = if rfs.is_file(git_dir) {
    resolve_gitdir(rfs, git_dir)
  } else {
    git_dir
  }
  let entries = read_index_entries(rfs, actual_git_dir)
  let skip_worktree_paths = read_skip_worktree_paths(rfs, actual_git_dir)
  let map : Map[String, IndexEntry] = Map([])
  for e in entries {
    map[e.path] = e
  }
  // Expand paths if recursive
  let all_paths = if recursive {
    expand_rm_paths(rfs, root, paths, map)
  } else {
    paths
  }
  let removed_submodule_paths : Array[String] = []
  ignore(force)
  for path in all_paths {
    let norm_path = normalize_rel_path(path)
    let tracked_entry = map.get(norm_path)
    match map.get(norm_path) {
      Some(entry) if is_gitlink_mode_int(entry.mode) =>
        removed_submodule_paths.push(norm_path)
      _ => ()
    }
    // Remove from index
    map.remove(norm_path)
    // Remove from working tree unless --cached
    if !cached {
      let abs = join_path(root, norm_path)
      if rfs.is_file(abs) {
        fs.remove_file(abs)
        rm_prune_empty_parent_dirs(fs, rfs, root, norm_path)
      } else if tracked_entry is Some(entry) &&
        is_gitlink_mode_int(entry.mode) &&
        rfs.is_dir(abs) {
        remove_worktree_path_recursive(fs, rfs, abs)
        rm_prune_empty_parent_dirs(fs, rfs, root, norm_path)
      }
    }
  }
  let out : Array[IndexEntry] = Array::new(capacity=map.length())
  let remaining_skip_worktree_paths : Map[String, Bool] = Map([])
  let remaining_skip_paths : Array[String] = []
  for path, entry in map {
    out.push(entry)
    if skip_worktree_paths.contains(path) {
      remaining_skip_worktree_paths[path] = true
      remaining_skip_paths.push(path)
    }
  }
  write_skip_worktree_paths(fs, actual_git_dir, remaining_skip_paths)
  write_index_entries_with_skip_worktree(
    fs, actual_git_dir, out, remaining_skip_worktree_paths,
  )
  if !cached {
    rm_update_gitmodules_after_submodule_removal(
      fs, rfs, root, removed_submodule_paths,
    )
  }
}

///|
fn rm_update_gitmodules_after_submodule_removal(
  fs : &@bit.FileSystem,
  rfs : &@bit.RepoFileSystem,
  root : String,
  removed_submodule_paths : Array[String],
) -> Unit raise @bit.GitError {
  if removed_submodule_paths.length() == 0 {
    return
  }
  let gitmodules_path = join_path(root, ".gitmodules")
  if !rfs.is_file(gitmodules_path) {
    return
  }
  let removed_paths : Map[String, Bool] = Map([])
  for path in removed_submodule_paths {
    removed_paths[path] = true
  }
  let content = decode_bytes_lossy(rfs.read_file(gitmodules_path))
  let updated = rm_remove_gitmodules_sections_by_path(content, removed_paths)
  if updated == content {
    return
  }
  fs.write_string(gitmodules_path, updated)
  add_paths(fs, rfs, root, [".gitmodules"])
}

///|
fn rm_remove_gitmodules_sections_by_path(
  content : String,
  removed_paths : Map[String, Bool],
) -> String {
  let out : Array[String] = []
  let mut section_lines : Array[String] = []
  let mut in_submodule = false
  let mut current_path : String? = None
  let mut have_section = false
  let flush_section = fn() {
    if !have_section {
      return
    }
    if in_submodule &&
      current_path is Some(path) &&
      removed_paths.contains(path) {
      return
    }
    for line in section_lines {
      out.push(line)
    }
  }
  for line_view in content.split("\n") {
    let line = line_view.to_owned()
    let trimmed = line.trim(chars=" \t").to_owned()
    if trimmed.has_prefix("[") && trimmed.has_suffix("]") {
      flush_section()
      section_lines = [line]
      have_section = true
      in_submodule = trimmed.has_prefix("[submodule \"") &&
        trimmed.has_suffix("\"]")
      current_path = None
      continue
    }
    if !have_section {
      out.push(line)
      continue
    }
    section_lines.push(line)
    if in_submodule && trimmed.has_prefix("path = ") {
      current_path = Some(
        String::unsafe_substring(trimmed, start=7, end=trimmed.length()),
      )
    }
  }
  flush_section()
  out.join("\n")
}

///|
fn rm_prune_empty_parent_dirs(
  fs : &@bit.FileSystem,
  rfs : &@bit.RepoFileSystem,
  root : String,
  path : String,
) -> Unit {
  let mut current = match path.rev_find("/") {
    Some(idx) => String::unsafe_substring(path, start=0, end=idx)
    None => return
  }
  while current.length() > 0 {
    let abs = join_path(root, current)
    if !rfs.is_dir(abs) {
      return
    }
    let entries = rfs.readdir(abs) catch { _ => return }
    if entries.length() > 0 {
      return
    }
    fs.remove_dir(abs) catch {
      _ => return
    }
    current = match current.rev_find("/") {
      Some(idx) => String::unsafe_substring(current, start=0, end=idx)
      None => return
    }
  }
}

///|
fn expand_rm_paths(
  rfs : &@bit.RepoFileSystem,
  root : String,
  paths : Array[String],
  index_map : Map[String, IndexEntry],
) -> Array[String] raise @bit.GitError {
  let result : Array[String] = []
  for p in paths {
    let norm_path = normalize_rel_path(p)
    if norm_path == "." || norm_path == "" {
      for entry_path in index_map.keys() {
        result.push(entry_path)
      }
      continue
    }
    let abs = join_path(root, norm_path)
    if rfs.is_dir(abs) {
      // Add all index entries under this directory
      let prefix = if norm_path.has_suffix("/") {
        norm_path
      } else {
        norm_path + "/"
      }
      for entry_path in index_map.keys() {
        if entry_path.has_prefix(prefix) || entry_path == norm_path {
          result.push(entry_path)
        }
      }
    } else {
      result.push(norm_path)
    }
  }
  result
}

///|
/// Move/rename a file in the index and working tree.
pub fn mv_path(
  fs : &@bit.FileSystem,
  rfs : &@bit.RepoFileSystem,
  root : String,
  source : String,
  dest : String,
  force? : Bool = false,
) -> Unit raise @bit.GitError {
  let git_dir = join_path(root, ".git")
  let actual_git_dir = if rfs.is_file(git_dir) {
    resolve_gitdir(rfs, git_dir)
  } else {
    git_dir
  }
  let src_norm = normalize_rel_path(source)
  let mut dst_norm = normalize_rel_path(dest)
  let src_abs = join_path(root, src_norm)
  let mut dst_abs = join_path(root, dst_norm)
  // Check source exists
  if !rfs.is_file(src_abs) && !rfs.is_dir(src_abs) {
    raise @bit.GitError::InvalidObject("source '\{source}' does not exist")
  }
  // If dest is a directory, move source into it (like `mv file dir/`)
  if rfs.is_dir(dst_abs) {
    let basename = match src_norm.rev_find("/") {
      Some(i) =>
        String::unsafe_substring(src_norm, start=i + 1, end=src_norm.length())
      None => src_norm
    }
    dst_norm = join_path(dst_norm, basename)
    dst_abs = join_path(root, dst_norm)
  }
  // Check dest doesn't exist (unless force)
  if (rfs.is_file(dst_abs) || rfs.is_dir(dst_abs)) && !force {
    raise @bit.GitError::InvalidObject("destination '\{dest}' already exists")
  }
  // Read index
  let entries = read_index_entries(rfs, actual_git_dir)
  let map : Map[String, IndexEntry] = Map([])
  for e in entries {
    map[e.path] = e
  }
  // Find source entry
  guard map.get(src_norm) is Some(src_entry) else {
    raise @bit.GitError::InvalidObject("'\{source}' not in index")
  }
  // Remove source, add dest
  map.remove(src_norm)
  map[dst_norm] = {
    path: dst_norm,
    id: src_entry.id,
    mode: src_entry.mode,
    size: src_entry.size,
    mtime_sec: src_entry.mtime_sec,
    mtime_nsec: src_entry.mtime_nsec,
    intent_to_add: src_entry.intent_to_add,
    dev: src_entry.dev,
    ino: src_entry.ino,
    uid: src_entry.uid,
    gid: src_entry.gid,
  }
  // Move file on disk
  if rfs.is_dir(src_abs) {
    mv_copy_directory_recursive(fs, rfs, src_abs, dst_abs)
    let src_gitfile = join_path(src_abs, ".git")
    let dst_gitfile = join_path(dst_abs, ".git")
    if rfs.is_file(src_gitfile) && rfs.is_file(dst_gitfile) {
      mv_rewrite_gitfile_after_directory_move(
        fs, rfs, src_abs, dst_abs, dst_gitfile,
      )
    }
    remove_worktree_path_recursive(fs, rfs, src_abs)
  } else {
    let content = rfs.read_file(src_abs)
    let dst_dir = parent_dir(dst_abs)
    if dst_dir.length() > 0 {
      fs.mkdir_p(dst_dir)
    }
    fs.write_file(dst_abs, content)
    fs.remove_file(src_abs)
  }
  // Write index
  let out = map.values().to_array()
  write_index_entries(fs, actual_git_dir, out)
  if is_gitlink_mode_int(src_entry.mode) {
    mv_update_submodule_paths_after_move(
      fs, rfs, root, actual_git_dir, src_norm, dst_norm,
    )
  }
}

///|
fn mv_update_submodule_paths_after_move(
  fs : &@bit.FileSystem,
  rfs : &@bit.RepoFileSystem,
  root : String,
  git_dir : String,
  src_path : String,
  dst_path : String,
) -> Unit raise @bit.GitError {
  let gitmodules_path = join_path(root, ".gitmodules")
  if rfs.is_file(gitmodules_path) {
    let content = decode_bytes_lossy(rfs.read_file(gitmodules_path))
    let updated = mv_update_submodule_path_in_config(
      content, src_path, dst_path,
    )
    if updated != content {
      fs.write_string(gitmodules_path, updated)
      add_paths(fs, rfs, root, [".gitmodules"])
    }
  }
  let config_path = join_path(git_dir, "config")
  if rfs.is_file(config_path) {
    let content = decode_bytes_lossy(rfs.read_file(config_path))
    let updated = mv_update_submodule_path_in_config(
      content, src_path, dst_path,
    )
    if updated != content {
      fs.write_string(config_path, updated)
    }
  }
}

///|
fn mv_update_submodule_path_in_config(
  content : String,
  src_path : String,
  dst_path : String,
) -> String {
  let out : Array[String] = []
  let mut in_submodule = false
  for line_view in content.split("\n") {
    let line = line_view.to_owned()
    let trimmed = line.trim()
    if trimmed.has_prefix("[") && trimmed.has_suffix("]") {
      in_submodule = trimmed.has_prefix("[submodule \"")
      out.push(line)
      continue
    }
    if in_submodule && trimmed == "path = " + src_path {
      out.push("\tpath = " + dst_path)
    } else {
      out.push(line)
    }
  }
  out.join("\n")
}

///|
fn mv_copy_directory_recursive(
  fs : &@bit.FileSystem,
  rfs : &@bit.RepoFileSystem,
  src : String,
  dst : String,
) -> Unit raise @bit.GitError {
  fs.mkdir_p(dst)
  for entry in rfs.readdir(src) {
    let src_child = join_path(src, entry)
    let dst_child = join_path(dst, entry)
    if rfs.is_dir(src_child) {
      mv_copy_directory_recursive(fs, rfs, src_child, dst_child)
    } else if rfs.is_file(src_child) {
      fs.write_file(dst_child, rfs.read_file(src_child))
    }
  }
}

///|
fn mv_rewrite_gitfile_after_directory_move(
  fs : &@bit.FileSystem,
  rfs : &@bit.RepoFileSystem,
  src_abs : String,
  dst_abs : String,
  dst_gitfile : String,
) -> Unit raise @bit.GitError {
  let content = trim_worktree_text(
    @string_utils.decode_bytes(rfs.read_file(dst_gitfile)),
  )
  if !content.has_prefix("gitdir: ") {
    return ()
  }
  let rel_gitdir = String::unsafe_substring(
    content,
    start=8,
    end=content.length(),
  )
  let modules_dir = normalize_path(src_abs + "/" + rel_gitdir)
  let rewritten = tree_ops_get_rel_path(dst_abs, modules_dir)
  fs.write_string(dst_gitfile, "gitdir: \{rewritten}\n")
}

///|
/// LF→CRLF expansion (smudge direction).
pub fn convert_lf_to_crlf(content : Bytes) -> Bytes {
  let out : Array[Byte] = []
  let mut i = 0
  let mut changed = false
  while i < content.length() {
    let b = content[i]
    if b == b'\n' && (i == 0 || content[i - 1] != b'\r') {
      out.push(b'\r')
      out.push(b'\n')
      changed = true
    } else {
      out.push(b)
    }
    i += 1
  }
  if !changed {
    return content
  }
  Bytes::from_array(FixedArray::makei(out.length(), fn(i) { out[i] }))
}

///|
/// Smudge: blob→working tree expansion.
pub fn smudge_worktree_content(content : Bytes, autocrlf : AutoCrlf) -> Bytes {
  match autocrlf {
    Off | Input => content
    On =>
      if is_binary_bytes(content) {
        content
      } else {
        convert_lf_to_crlf(content)
      }
  }
}

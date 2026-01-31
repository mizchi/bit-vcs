///| Read operations for GitFs (RepoFileSystem trait implementation)

///|
fn is_tree_mode(mode : String) -> Bool {
  mode == "040000" || mode == "40000"
}

///|
pub fn GitFs::read_file(
  self : GitFs,
  backing_fs : &@git.RepoFileSystem,
  path : String,
) -> Bytes raise @git.GitError {
  let norm = normalize_path(path)
  if self.working.deleted.contains(norm) {
    raise @git.GitError::IoError("File not found: \{path}")
  }
  if self.working.files.get(norm) is Some(data) {
    return data
  }
  if self.cache.get_blob(norm) is Some(data) {
    return data
  }
  let obj_id = self.resolve_path(backing_fs, norm)
  guard obj_id is Some(id) else {
    raise @git.GitError::IoError("File not found: \{path}")
  }
  let db = self.get_db(backing_fs)
  let obj = db.get(backing_fs, id)
  guard obj is Some(o) else {
    raise @git.GitError::IoError("Blob not found: \{id}")
  }
  if o.obj_type != @git.ObjectType::Blob {
    raise @git.GitError::InvalidObject("Not a file: \{path}")
  }
  self.cache.set_blob(norm, o.data)
  o.data
}

///|
pub fn GitFs::readdir(
  self : GitFs,
  backing_fs : &@git.RepoFileSystem,
  path : String,
) -> Array[String] raise @git.GitError {
  let norm = normalize_path(path)
  let entries : Map[String, Bool] = {}
  for item in self.working.files.to_array() {
    let (file_path, _) = item
    let rel = if norm.length() == 0 {
      file_path
    } else if file_path.has_prefix(norm + "/") {
      String::unsafe_substring(
        file_path,
        start=norm.length() + 1,
        end=file_path.length(),
      )
    } else {
      continue
    }
    match split_first(rel) {
      (name, _) => entries[name] = true
    }
  }
  for item in self.working.dirs.to_array() {
    let (dir_path, _) = item
    let rel = if norm.length() == 0 {
      dir_path
    } else if dir_path.has_prefix(norm + "/") {
      String::unsafe_substring(
        dir_path,
        start=norm.length() + 1,
        end=dir_path.length(),
      )
    } else {
      continue
    }
    match split_first(rel) {
      (name, _) => entries[name] = true
    }
  }
  self.readdir_from_layers(backing_fs, norm, entries)
  self.readdir_from_tree(backing_fs, norm, self.base_tree, entries)
  for item in self.working.deleted.to_array() {
    let (del_path, _) = item
    if parent_dir(del_path) == norm ||
      (norm.length() == 0 && not(del_path.contains("/"))) {
      entries.remove(basename(del_path))
    }
  }
  let out : Array[String] = []
  for item in entries.to_array() {
    let (name, _) = item
    out.push(name)
  }
  out.sort()
  out
}

///|
fn GitFs::readdir_from_layers(
  self : GitFs,
  backing_fs : &@git.RepoFileSystem,
  norm : String,
  entries : Map[String, Bool],
) -> Unit {
  for layer in self.layers {
    self.readdir_from_tree(backing_fs, norm, layer.tree_id, entries) catch {
      _ => ()
    }
  }
}

///|
fn GitFs::readdir_from_tree(
  self : GitFs,
  backing_fs : &@git.RepoFileSystem,
  path : String,
  tree_id : @git.ObjectId,
  entries : Map[String, Bool],
) -> Unit raise @git.GitError {
  if tree_id == @git.ObjectId::zero() {
    return
  }
  let tree_entries = self.get_tree_entries(backing_fs, tree_id)
  if path.length() == 0 {
    for entry in tree_entries {
      entries[entry.name] = true
    }
    return
  }
  let parts = split_path(path)
  let mut current_entries = tree_entries
  for i = 0; i < parts.length(); i = i + 1 {
    let part = parts[i]
    let mut found = false
    for entry in current_entries {
      if entry.name == part {
        if is_tree_mode(entry.mode) {
          current_entries = self.get_tree_entries(backing_fs, entry.id)
          found = true
          break
        } else {
          return
        }
      }
    }
    if not(found) {
      return
    }
  }
  for entry in current_entries {
    entries[entry.name] = true
  }
}

///|
pub fn GitFs::is_dir(
  self : GitFs,
  backing_fs : &@git.RepoFileSystem,
  path : String,
) -> Bool {
  let norm = normalize_path(path)
  if norm.length() == 0 {
    return true
  }
  if self.working.deleted.contains(norm) {
    return false
  }
  if self.working.dirs.contains(norm) {
    return true
  }
  for item in self.working.files.to_array() {
    let (file_path, _) = item
    if file_path.has_prefix(norm + "/") {
      return true
    }
  }
  self.is_dir_in_tree(backing_fs, norm)
}

///|
fn GitFs::is_dir_in_tree(
  self : GitFs,
  backing_fs : &@git.RepoFileSystem,
  path : String,
) -> Bool {
  for layer in self.layers {
    if self.check_dir_in_tree(backing_fs, layer.tree_id, path) {
      return true
    }
  }
  self.check_dir_in_tree(backing_fs, self.base_tree, path)
}

///|
fn GitFs::check_dir_in_tree(
  self : GitFs,
  backing_fs : &@git.RepoFileSystem,
  tree_id : @git.ObjectId,
  path : String,
) -> Bool {
  if tree_id == @git.ObjectId::zero() {
    return false
  }
  let parts = split_path(path)
  if parts.length() == 0 {
    return true
  }
  let mut current_tree = tree_id
  for i = 0; i < parts.length(); i = i + 1 {
    let part = parts[i]
    let entries = self.get_tree_entries(backing_fs, current_tree) catch {
      _ => return false
    }
    let mut found = false
    for entry in entries {
      if entry.name == part {
        if is_tree_mode(entry.mode) {
          current_tree = entry.id
          found = true
          break
        } else {
          return false
        }
      }
    }
    if not(found) {
      return false
    }
  }
  true
}

///|
pub fn GitFs::is_file(
  self : GitFs,
  backing_fs : &@git.RepoFileSystem,
  path : String,
) -> Bool {
  let norm = normalize_path(path)
  if self.working.deleted.contains(norm) {
    return false
  }
  if self.working.files.contains(norm) {
    return true
  }
  self.resolve_path(backing_fs, norm) is Some(_)
}

///|
/// Check if file exists in base tree (ignoring working layer)
pub fn GitFs::exists_in_base(
  self : GitFs,
  backing_fs : &@git.RepoFileSystem,
  path : String,
) -> Bool {
  let norm = normalize_path(path)
  // Check layers and base_tree directly
  for layer in self.layers {
    if self.find_in_tree(backing_fs, layer.tree_id, norm) is Some(_) {
      return true
    }
  }
  self.find_in_tree(backing_fs, self.base_tree, norm) is Some(_)
}

///|
fn GitFs::resolve_path(
  self : GitFs,
  backing_fs : &@git.RepoFileSystem,
  path : String,
) -> @git.ObjectId? {
  if self.cache.get_path(path) is Some(cached) {
    return cached
  }
  for layer in self.layers {
    if self.find_in_tree(backing_fs, layer.tree_id, path) is Some(id) {
      self.cache.set_path(path, Some(id))
      return Some(id)
    }
  }
  let result = self.find_in_tree(backing_fs, self.base_tree, path)
  self.cache.set_path(path, result)
  result
}

///|
fn GitFs::find_in_tree(
  self : GitFs,
  backing_fs : &@git.RepoFileSystem,
  tree_id : @git.ObjectId,
  path : String,
) -> @git.ObjectId? {
  if tree_id == @git.ObjectId::zero() {
    return None
  }
  let parts = split_path(path)
  if parts.length() == 0 {
    return None
  }
  let mut current_tree = tree_id
  for i = 0; i < parts.length(); i = i + 1 {
    let part = parts[i]
    let entries = self.get_tree_entries(backing_fs, current_tree) catch {
      _ => return None
    }
    let mut found = false
    for entry in entries {
      if entry.name == part {
        if i == parts.length() - 1 {
          if not(is_tree_mode(entry.mode)) {
            return Some(entry.id)
          } else {
            return None
          }
        } else if is_tree_mode(entry.mode) {
          current_tree = entry.id
          found = true
          break
        } else {
          return None
        }
      }
    }
    if not(found) {
      return None
    }
  }
  None
}

///|
fn GitFs::get_tree_entries(
  self : GitFs,
  backing_fs : &@git.RepoFileSystem,
  tree_id : @git.ObjectId,
) -> Array[@git.TreeEntry] raise @git.GitError {
  if self.cache.get_tree(tree_id) is Some(entries) {
    return entries
  }
  let db = self.get_db(backing_fs)
  let obj = db.get(backing_fs, tree_id)
  guard obj is Some(o) else {
    raise @git.GitError::InvalidObject("Tree not found: \{tree_id}")
  }
  if o.obj_type != @git.ObjectType::Tree {
    raise @git.GitError::InvalidObject("Not a tree: \{tree_id}")
  }
  let entries = @git.parse_tree(o.data)
  self.cache.set_tree(tree_id, entries)
  entries
}

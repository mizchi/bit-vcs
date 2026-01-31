///| GitFs construction and initialization

///|
pub fn GitFs::from_commit(
  backing_fs : &@git.RepoFileSystem,
  git_dir : String,
  commit_id : @git.ObjectId,
  config? : GitFsConfig = GitFsConfig::default(),
) -> GitFs raise @git.GitError {
  let db = @lib.ObjectDb::load(backing_fs, git_dir)
  let obj = db.get(backing_fs, commit_id)
  guard obj is Some(commit_obj) else {
    raise @git.GitError::InvalidObject("Commit not found: \{commit_id}")
  }
  if commit_obj.obj_type != @git.ObjectType::Commit {
    raise @git.GitError::InvalidObject("Object is not a commit")
  }
  let info = @git.parse_commit(commit_obj.data)
  {
    git_dir,
    base_tree: info.tree,
    base_commit: Some(commit_id),
    working: WorkingLayer::new(),
    layers: [],
    cache: ObjectCache::new(config.max_cache_bytes),
    config,
    cached_db: Some(db),
  }
}

///|
/// Create GitFs from commit using lazy object loading (shallow/fast)
/// This is much faster than from_commit for large repositories
pub fn GitFs::from_commit_lazy(
  backing_fs : &@git.RepoFileSystem,
  git_dir : String,
  commit_id : @git.ObjectId,
  config? : GitFsConfig = GitFsConfig::default(),
) -> GitFs raise @git.GitError {
  let db = @lib.ObjectDb::load_lazy(backing_fs, git_dir)
  let obj = db.get(backing_fs, commit_id)
  guard obj is Some(commit_obj) else {
    raise @git.GitError::InvalidObject("Commit not found: \{commit_id}")
  }
  if commit_obj.obj_type != @git.ObjectType::Commit {
    raise @git.GitError::InvalidObject("Object is not a commit")
  }
  let info = @git.parse_commit(commit_obj.data)
  {
    git_dir,
    base_tree: info.tree,
    base_commit: Some(commit_id),
    working: WorkingLayer::new(),
    layers: [],
    cache: ObjectCache::new(config.max_cache_bytes),
    config,
    cached_db: Some(db),
  }
}

///|
pub fn GitFs::from_tree(
  git_dir : String,
  tree_id : @git.ObjectId,
  config? : GitFsConfig = GitFsConfig::default(),
) -> GitFs {
  {
    git_dir,
    base_tree: tree_id,
    base_commit: None,
    working: WorkingLayer::new(),
    layers: [],
    cache: ObjectCache::new(config.max_cache_bytes),
    config,
    cached_db: None,
  }
}

///|
pub fn GitFs::from_branch(
  backing_fs : &@git.RepoFileSystem,
  git_dir : String,
  branch : String,
  config? : GitFsConfig = GitFsConfig::default(),
) -> GitFs raise @git.GitError {
  let commit_id = @lib.resolve_ref(backing_fs, git_dir, "refs/heads/" + branch)
  match commit_id {
    Some(id) => GitFs::from_commit(backing_fs, git_dir, id, config~)
    None =>
      raise @git.GitError::InvalidObject(
        "Branch not found: refs/heads/" + branch,
      )
  }
}

///|
pub fn GitFs::empty(
  git_dir : String,
  config? : GitFsConfig = GitFsConfig::default(),
) -> GitFs {
  {
    git_dir,
    base_tree: @git.ObjectId::zero(),
    base_commit: None,
    working: WorkingLayer::new(),
    layers: [],
    cache: ObjectCache::new(config.max_cache_bytes),
    config,
    cached_db: None,
  }
}

///|
/// Get or load the ObjectDb (cached for performance)
pub fn GitFs::get_db(
  self : GitFs,
  backing_fs : &@git.RepoFileSystem,
) -> @lib.ObjectDb raise @git.GitError {
  match self.cached_db {
    Some(db) => db
    None => {
      let db = @lib.ObjectDb::load(backing_fs, self.git_dir)
      self.cached_db = Some(db)
      db
    }
  }
}

///|
pub fn GitFs::is_dirty(self : GitFs) -> Bool {
  self.working.is_dirty()
}

///|
pub fn GitFs::git_dir(self : GitFs) -> String {
  self.git_dir
}

///|
pub fn GitFs::base_tree(self : GitFs) -> @git.ObjectId {
  self.base_tree
}

///|
pub fn GitFs::base_commit(self : GitFs) -> @git.ObjectId? {
  self.base_commit
}

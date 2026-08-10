///|
struct OsObjectStore {
  git_dir : String
  // Cached lazily-loaded ObjectDb. Reused across get/has calls so pack
  // indexes are parsed at most once per store instance.
  mut cached_db : @bitlib.ObjectDb?
}

///|
/// Return a cached ObjectDb, building it lazily on first use.
///
/// Rebuilding the ObjectDb on every `get`/`has` re-parsed each pack `.idx`
/// from scratch, and parsing an index hex-encodes every object id it
/// contains. Once `bit issue` blobs were packed by gc, every object read
/// re-hashed the entire pack index, making hub operations extremely slow.
/// Caching the db lets `LazyPackIndex` keep its parsed index between reads.
fn OsObjectStore::object_db(
  self : OsObjectStore,
  fs : OsFs,
) -> @bitlib.ObjectDb raise @bitcore.GitError {
  match self.cached_db {
    Some(db) => db
    None => {
      let db = @bitlib.ObjectDb::load_lazy(fs, self.git_dir)
      self.cached_db = Some(db)
      db
    }
  }
}

///|
impl @bitlib.ObjectStore for OsObjectStore with fn get(self, id) {
  let fs = OsFs::new()
  let db = self.object_db(fs)
  db.get(fs, id)
}

///|
impl @bitlib.ObjectStore for OsObjectStore with fn put(self, obj_type, content) {
  let fs = OsFs::new()
  let (id, compressed) = @bitcore.create_object(obj_type, content)
  let hex = id.to_hex()
  let dir = self.git_dir +
    "/objects/" +
    String::unsafe_substring(hex, start=0, end=2)
  let path = dir + "/" + String::unsafe_substring(hex, start=2, end=40)
  fs.mkdir_p(dir)
  fs.write_file(path, compressed)
  id
}

///|
impl @bitlib.ObjectStore for OsObjectStore with fn has(self, id) {
  let fs = OsFs::new()
  let db = self.object_db(fs)
  let obj = db.get(fs, id)
  obj is Some(_)
}

///|
struct OsRefStore {
  git_dir : String
}

///|
impl @bitlib.RefStore for OsRefStore with fn resolve(self, ref_name) {
  let fs = OsFs::new()
  @bitlib.resolve_ref(fs, self.git_dir, ref_name)
}

///|
impl @bitlib.RefStore for OsRefStore with fn update(self, ref_name, id) {
  let fs = OsFs::new()
  match id {
    Some(commit_id) => {
      let ref_path = self.git_dir + "/" + ref_name
      let dir = os_parent_path(ref_path)
      fs.mkdir_p(dir)
      fs.write_string(ref_path, commit_id.to_hex() + "\n")
    }
    None => ()
  }
}

///|
impl @bitlib.RefStore for OsRefStore with fn list(self, _prefix) {
  ignore(self)
  []
}

///|
fn os_parent_path(path : String) -> String {
  match path.rev_find("/") {
    None => "."
    Some(0) => "."
    Some(idx) => String::unsafe_substring(path, start=0, end=idx)
  }
}

///|
struct OsClock {
  time : Int64
}

///|
impl @bitlib.Clock for OsClock with fn now(self) {
  self.time
}

///|
priv enum HubRepoBackendKind {
  Bit
  Git
}

///|
priv trait HubRepoBackend {
  fn resolve_git_dir(Self, String) -> String
  fn current_branch_name(Self, String) -> String?
}

///|
priv struct BitHubRepoBackend {}

///|
priv struct GitHubRepoBackend {}

///|
fn parse_hub_repo_backend_kind(value : String) -> HubRepoBackendKind? {
  match trim_string(value).to_lower() {
    "bit" => Some(HubRepoBackendKind::Bit)
    "git" | "libgit2" => Some(HubRepoBackendKind::Git)
    _ => None
  }
}

///|
fn can_use_hub_git_backend() -> Bool {
  hub_libgit2_is_loaded() == 1 || hub_libgit2_init() >= 0
}

///|
fn resolve_hub_repo_backend_kind() -> HubRepoBackendKind {
  match @sys.get_env_var("BIT_HUB_BACKEND") {
    Some(raw) =>
      match parse_hub_repo_backend_kind(raw) {
        Some(HubRepoBackendKind::Bit) => HubRepoBackendKind::Bit
        Some(HubRepoBackendKind::Git) =>
          if can_use_hub_git_backend() {
            HubRepoBackendKind::Git
          } else {
            HubRepoBackendKind::Bit
          }
        None =>
          if can_use_hub_git_backend() {
            HubRepoBackendKind::Git
          } else {
            HubRepoBackendKind::Bit
          }
      }
    None =>
      if can_use_hub_git_backend() {
        HubRepoBackendKind::Git
      } else {
        HubRepoBackendKind::Bit
      }
  }
}

///|
fn trim_trailing_path_separator(path : String) -> String {
  let mut end = path.length()
  while end > 1 {
    if path.code_unit_at(end - 1).to_int() != 47 {
      break
    }
    end -= 1
  }
  if end == path.length() {
    path
  } else {
    String::unsafe_substring(path, start=0, end~)
  }
}

///|
fn resolve_hub_common_git_dir(git_dir : String) -> String {
  let fs = OsFs::new()
  let resolved_git_dir = normalize_path(trim_trailing_path_separator(git_dir))
  let commondir_path = resolved_git_dir + "/commondir"
  if fs.is_file(commondir_path) {
    let raw = @utf8.decode_lossy(
      (fs.read_file(commondir_path) catch { _ => Default::default() })[:],
    )
    let rel = raw.trim(chars=" \t\r\n").to_owned()
    if rel.length() > 0 {
      if rel.has_prefix("/") {
        return normalize_path(rel)
      }
      return normalize_path(resolved_git_dir + "/" + rel)
    }
  }
  resolved_git_dir
}

///|
fn resolve_hub_git_dir_with_bit_backend(root : String) -> String {
  let fs = OsFs::new()
  let git_path = root + "/.git"
  let git_dir = if fs.is_file(git_path) {
    @bitlib.resolve_gitdir(fs, git_path)
  } else {
    git_path
  }
  resolve_hub_common_git_dir(git_dir)
}

///|
fn resolve_hub_git_dir_with_git_backend(root : String) -> String {
  if !can_use_hub_git_backend() {
    return resolve_hub_git_dir_with_bit_backend(root)
  }
  match hub_git_repository_path(root) {
    Some(git_dir) => resolve_hub_common_git_dir(git_dir)
    None => resolve_hub_git_dir_with_bit_backend(root)
  }
}

///|
impl HubRepoBackend for BitHubRepoBackend with fn resolve_git_dir(_self, root) {
  resolve_hub_git_dir_with_bit_backend(root)
}

///|
impl HubRepoBackend for BitHubRepoBackend with fn current_branch_name(
  _self,
  root,
) {
  let git_dir = resolve_hub_git_dir_with_bit_backend(root)
  detect_current_branch_name(git_dir)
}

///|
impl HubRepoBackend for GitHubRepoBackend with fn resolve_git_dir(_self, root) {
  resolve_hub_git_dir_with_git_backend(root)
}

///|
impl HubRepoBackend for GitHubRepoBackend with fn current_branch_name(
  _self,
  root,
) {
  if !can_use_hub_git_backend() {
    let fallback = BitHubRepoBackend::{  }
    return HubRepoBackend::current_branch_name(fallback, root)
  }
  match hub_git_head_ref_name(root) {
    Some(name) => parse_branch_ref_name(name)
    None => {
      let fallback = BitHubRepoBackend::{  }
      HubRepoBackend::current_branch_name(fallback, root)
    }
  }
}

///|
/// Resolve git_dir for hub operations, handling worktrees.
/// In a worktree, .git is a file pointing to .git/worktrees/<name>.
/// Hub data (refs/notes) lives in the shared common git dir.
fn resolve_hub_git_dir(root : String) -> String {
  match resolve_hub_repo_backend_kind() {
    HubRepoBackendKind::Bit => {
      let backend = BitHubRepoBackend::{  }
      HubRepoBackend::resolve_git_dir(backend, root)
    }
    HubRepoBackendKind::Git => {
      let backend = GitHubRepoBackend::{  }
      HubRepoBackend::resolve_git_dir(backend, root)
    }
  }
}

///|
fn detect_hub_current_branch_name(root : String) -> String? {
  match resolve_hub_repo_backend_kind() {
    HubRepoBackendKind::Bit => {
      let backend = BitHubRepoBackend::{  }
      HubRepoBackend::current_branch_name(backend, root)
    }
    HubRepoBackendKind::Git => {
      let backend = GitHubRepoBackend::{  }
      HubRepoBackend::current_branch_name(backend, root)
    }
  }
}

///|
fn make_hub_stores(
  git_dir : String,
) -> (&@bitlib.ObjectStore, &@bitlib.RefStore, &@bitlib.Clock) {
  let objects : OsObjectStore = { git_dir, cached_db: None }
  let refs : OsRefStore = { git_dir, }
  let clock : OsClock = { time: get_commit_timestamp() }
  (objects, refs, clock)
}

///|
/// Load hub store, auto-initializing if needed.
fn load_hub_store(
  objects : &@bitlib.ObjectStore,
  refs : &@bitlib.RefStore,
) -> @hub.Hub raise @bitcore.GitError {
  @hub.Hub::init(
    objects,
    refs,
    signing_key=get_hub_signing_key(),
    require_signed=get_hub_require_signed(),
  )
}

///|
fn ensure_hub_initialized(git_dir : String) -> Unit raise @bitcore.GitError {
  let fs = OsFs::new()
  let (objects, refs, _clock) = make_hub_stores(git_dir)
  let _ = load_hub_store(objects, refs)
  ensure_hub_merge_policy_file(fs, git_dir)
}

///|
async fn handle_hub_init(args : Array[String]) -> Unit raise Error {
  for arg in args {
    if arg.has_prefix("-") {
      warn_unimplemented_arg("init", arg)
    }
  }
  let root = get_work_root()
  let git_dir = resolve_hub_git_dir(root)
  let fs = OsFs::new()
  let (objects, refs, _clock) = make_hub_stores(git_dir)
  let _ = load_hub_store(objects, refs)
  ensure_hub_merge_policy_file(fs, git_dir)
  print_line("Initialized hub metadata")
}

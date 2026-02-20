///|
/// Repository path parsed from URL or shorthand
pub struct RepoPath {
  /// Host (None = github.com implicit, Some("github.com") = explicit but normalized)
  host : String?
  /// Username or organization
  user : String
  /// Repository name
  repo : String
  /// Subdirectory for sparse checkout (optional)
  subdir : String?
} derive(Show, Eq)

///|
pub fn RepoPath::new(
  user : String,
  repo : String,
  host? : String? = None,
  subdir? : String? = None,
) -> RepoPath {
  { host, user, repo, subdir }
}

///|
pub fn RepoPath::full_name(self : RepoPath) -> String {
  "\{self.user}/\{self.repo}"
}

///|
pub fn RepoPath::host_name(self : RepoPath) -> String {
  self.host.unwrap_or("github.com")
}

///|
/// Get the clone URL (always includes host)
pub fn RepoPath::clone_url(self : RepoPath, ssh? : Bool = false) -> String {
  let host = self.host.unwrap_or("github.com")
  if ssh {
    "git@\{host}:\{self.user}/\{self.repo}.git"
  } else {
    "https://\{host}/\{self.user}/\{self.repo}.git"
  }
}

///|
/// Get the local path under bhq root
/// github.com is normalized (no host in path)
pub fn RepoPath::local_path(self : RepoPath, root : String) -> String {
  match self.host {
    None | Some("github.com") => "\{root}/\{self.user}/\{self.repo}"
    Some(host) => "\{root}/\{host}/\{self.user}/\{self.repo}"
  }
}

///|
/// Check if this repo requires sparse checkout
pub fn RepoPath::needs_sparse(self : RepoPath) -> Bool {
  self.subdir is Some(_)
}

///|
/// Configuration for hq command
pub struct HqConfig {
  /// Primary root directory
  root : String
  /// Whether to use ghq compatibility mode
  ghq_compat : Bool
}

///|
pub fn HqConfig::new(root : String, ghq_compat? : Bool = false) -> HqConfig {
  { root, ghq_compat }
}

///|
/// Options for hq get command
pub struct HqGetOptions {
  /// Update if already exists (git pull)
  update : Bool
  /// Use shallow clone (--depth=1)
  shallow : Bool
  /// Explicit clone depth. 0 means use default behavior.
  depth : Int
  /// Use SSH protocol
  ssh : Bool
  /// Specific branch to clone
  branch : String?
  /// Unshallow existing repository before update
  unshallow : Bool
}

///|
pub fn HqGetOptions::default() -> HqGetOptions {
  {
    update: false,
    shallow: false,
    depth: 0,
    ssh: false,
    branch: None,
    unshallow: false,
  }
}

///|
pub fn HqGetOptions::new(
  update? : Bool = false,
  shallow? : Bool = false,
  depth? : Int = 0,
  ssh? : Bool = false,
  branch? : String? = None,
  unshallow? : Bool = false,
) -> HqGetOptions {
  { update, shallow, depth, ssh, branch, unshallow }
}

///|
/// Result of hq get operation
pub(all) enum HqGetResult {
  Cloned(String) // Successfully cloned to path
  Updated(String) // Successfully updated existing repo
  Skipped(String) // Already exists, no update requested
  Error(String) // Error message
} derive(Show, Eq)

///| Remote path helpers facade

///|
pub fn resolve_local_repo_path(
  fs : &@bit.RepoFileSystem,
  root : String,
  url : String,
) -> String? {
  @bitremote.resolve_local_repo_path(fs, root, url)
}

///|
pub fn resolve_gitdir(fs : &@bit.RepoFileSystem, bit_path : String) -> String {
  @bitremote.resolve_gitdir(fs, bit_path)
}

///|
/// Resolve the repository directory that owns shared metadata such as
/// objects, refs, and config. `git_dir` may be either a `.git` marker file or
/// an already-resolved linked-worktree administration directory.
pub fn resolve_common_git_dir(
  fs : &@bit.RepoFileSystem,
  git_dir : String,
) -> String {
  let actual_git_dir = if fs.is_file(git_dir) {
    resolve_gitdir(fs, git_dir)
  } else {
    git_dir
  }
  match resolve_ref_commondir(fs, actual_git_dir) {
    Some(common_git_dir) => common_git_dir
    None => actual_git_dir
  }
}

///|
pub fn detect_git_dir(
  fs : &@bit.RepoFileSystem,
  path : String,
) -> (String, Bool)? {
  @bitremote.detect_git_dir(fs, path)
}

///|
pub fn is_bare_git_dir(git_dir : String) -> Bool {
  @bitremote.is_bare_git_dir(git_dir)
}

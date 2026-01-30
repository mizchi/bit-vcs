///| Minimal filesystem abstraction for git materialization

///|
pub(open) trait FileSystem {
  mkdir_p(Self, String) -> Unit raise GitError
  write_file(Self, String, Bytes) -> Unit raise GitError
  write_string(Self, String, String) -> Unit raise GitError
  remove_file(Self, String) -> Unit raise GitError
  remove_dir(Self, String) -> Unit raise GitError
}

///|
/// Read-only filesystem abstraction for loading git objects
pub(open) trait RepoFileSystem {
  read_file(Self, String) -> Bytes raise GitError
  readdir(Self, String) -> Array[String] raise GitError
  is_dir(Self, String) -> Bool
  is_file(Self, String) -> Bool
}

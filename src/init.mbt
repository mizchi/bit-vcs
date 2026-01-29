///| Git repository initialization

///|
/// Initialize a repository at `root` with a default branch.
pub fn init_repo(
  fs : &FileSystem,
  root : String,
  default_branch? : String = "main",
) -> Unit raise GitError {
  let git_dir = join_path(root, ".git")
  fs.mkdir_p(git_dir)
  fs.mkdir_p(join_path(git_dir, "objects"))
  fs.mkdir_p(join_path(git_dir, "refs/heads"))
  fs.write_string(
    join_path(git_dir, "HEAD"),
    "ref: refs/heads/" + default_branch + "\n",
  )
}

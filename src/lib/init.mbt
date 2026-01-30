///| Git repository initialization

///|
/// Initialize a repository at `root` with a default branch.
pub fn init_repo(
  fs : &@git.FileSystem,
  root : String,
  default_branch? : String = "main",
) -> Unit raise @git.GitError {
  let git_dir = join_path(root, ".git")
  fs.mkdir_p(git_dir)
  fs.mkdir_p(join_path(git_dir, "objects"))
  fs.mkdir_p(join_path(git_dir, "objects/info"))
  fs.mkdir_p(join_path(git_dir, "objects/pack"))
  fs.mkdir_p(join_path(git_dir, "refs/heads"))
  fs.mkdir_p(join_path(git_dir, "refs/tags"))
  fs.mkdir_p(join_path(git_dir, "info"))
  fs.mkdir_p(join_path(git_dir, "hooks"))
  fs.write_string(
    join_path(git_dir, "HEAD"),
    "ref: refs/heads/" + default_branch + "\n",
  )
  // Create config file
  let config = "[core]\n\trepositoryformatversion = 0\n\tfilemode = true\n\tbare = false\n"
  fs.write_string(join_path(git_dir, "config"), config)
  // Create description file
  fs.write_string(
    join_path(git_dir, "description"),
    "Unnamed repository; edit this file 'description' to name the repository.\n",
  )
  // Create info/exclude
  fs.write_string(join_path(git_dir, "info/exclude"), "")
}

///| Git repository initialization

///|
/// Initialize a repository at `root` with a default branch.
/// If `bare` is true, creates a bare repository (no working tree).
/// If the repository already exists, this is a reinit and preserves existing HEAD.
pub fn init_repo(
  fs : &@git.FileSystem,
  root : String,
  default_branch? : String = "main",
  bare? : Bool = false,
) -> Unit raise @git.GitError {
  // For bare repos, git_dir is the root itself; otherwise it's root/.git
  let git_dir = if bare { root } else { join_path(root, ".git") }
  let head_path = join_path(git_dir, "HEAD")
  fs.mkdir_p(git_dir)
  fs.mkdir_p(join_path(git_dir, "objects"))
  fs.mkdir_p(join_path(git_dir, "objects/info"))
  fs.mkdir_p(join_path(git_dir, "objects/pack"))
  fs.mkdir_p(join_path(git_dir, "refs/heads"))
  fs.mkdir_p(join_path(git_dir, "refs/tags"))
  fs.mkdir_p(join_path(git_dir, "info"))
  fs.mkdir_p(join_path(git_dir, "hooks"))
  // Always write HEAD (git init always updates HEAD with default branch)
  fs.write_string(head_path, "ref: refs/heads/" + default_branch + "\n")
  // Create/update config file with appropriate bare setting
  let bare_str = if bare { "true" } else { "false" }
  let config = "[core]\n\trepositoryformatversion = 0\n\tfilemode = true\n\tbare = " +
    bare_str +
    "\n"
  fs.write_string(join_path(git_dir, "config"), config)
  // Create description file
  fs.write_string(
    join_path(git_dir, "description"),
    "Unnamed repository; edit this file 'description' to name the repository.\n",
  )
  // Create info/exclude
  fs.write_string(join_path(git_dir, "info/exclude"), "")
}

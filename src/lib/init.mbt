///| Git repository initialization

///|
pub(all) struct InitOptions {
  default_branch : String
  bare : Bool
  separate_git_dir : String?
  template_dir : String?
  ref_format : String
  object_format : String
}

///|
pub fn InitOptions::new() -> InitOptions {
  {
    default_branch: "main",
    bare: false,
    separate_git_dir: None,
    template_dir: None,
    ref_format: "files",
    object_format: "sha1",
  }
}

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
  init_repo_with_options(fs, root, {
    default_branch,
    bare,
    separate_git_dir: None,
    template_dir: None,
    ref_format: "files",
    object_format: "sha1",
  })
}

///|
/// Initialize a repository with full options including separate-git-dir and template.
pub fn init_repo_with_options(
  fs : &@git.FileSystem,
  root : String,
  opts : InitOptions,
) -> Unit raise @git.GitError {
  let bare = opts.bare
  // Determine git directory location
  let git_dir = match opts.separate_git_dir {
    Some(sep_dir) => sep_dir
    None => if bare { root } else { join_path(root, ".git") }
  }
  let head_path = join_path(git_dir, "HEAD")
  // Create git directory structure
  fs.mkdir_p(git_dir)
  fs.mkdir_p(join_path(git_dir, "objects"))
  fs.mkdir_p(join_path(git_dir, "objects/info"))
  fs.mkdir_p(join_path(git_dir, "objects/pack"))
  fs.mkdir_p(join_path(git_dir, "refs/heads"))
  fs.mkdir_p(join_path(git_dir, "refs/tags"))
  fs.mkdir_p(join_path(git_dir, "info"))
  if opts.template_dir is None {
    fs.mkdir_p(join_path(git_dir, "hooks"))
  }
  // If separate-git-dir, create .git file pointing to actual git dir
  if opts.separate_git_dir is Some(_) && not(bare) {
    let gitfile_path = join_path(root, ".git")
    fs.write_string(gitfile_path, "gitdir: " + git_dir + "\n")
  }
  // Always write HEAD (git init always updates HEAD with default branch)
  fs.write_string(head_path, "ref: refs/heads/" + opts.default_branch + "\n")
  // Create/update config file with appropriate bare setting
  let bare_str = if bare { "true" } else { "false" }
  let mut repository_format_version = "0"
  if opts.ref_format == "reftable" || opts.object_format != "sha1" {
    repository_format_version = "1"
  }
  let mut config = "[core]\n\trepositoryformatversion = " +
    repository_format_version +
    "\n\tfilemode = true\n\tbare = " +
    bare_str +
    "\n"
  if opts.ref_format == "reftable" {
    fs.mkdir_p(join_path(git_dir, "reftable"))
    let tables_list_path = join_path(git_dir, "reftable/tables.list")
    fs.write_string(tables_list_path, "")
  }
  let extension_lines : Array[String] = []
  if opts.ref_format == "reftable" {
    extension_lines.push("\trefStorage = reftable")
  }
  if opts.object_format != "sha1" {
    extension_lines.push("\tobjectFormat = " + opts.object_format)
  }
  if extension_lines.length() > 0 {
    config += "[extensions]\n" + extension_lines.join("\n") + "\n"
  }
  fs.write_string(join_path(git_dir, "config"), config)
  // Create description file
  fs.write_string(
    join_path(git_dir, "description"),
    "Unnamed repository; edit this file 'description' to name the repository.\n",
  )
  // Create info/exclude
  fs.write_string(join_path(git_dir, "info/exclude"), "")
}

///|
/// Copy template directory contents to git directory.
/// This should be called after init_repo_with_options if template_dir is specified.
pub fn apply_template(
  wfs : &@git.FileSystem,
  rfs : &@git.RepoFileSystem,
  git_dir : String,
  template_dir : String,
) -> Unit raise @git.GitError {
  copy_dir_recursive(wfs, rfs, template_dir, git_dir)
}

///|
fn copy_dir_recursive(
  wfs : &@git.FileSystem,
  rfs : &@git.RepoFileSystem,
  src : String,
  dst : String,
) -> Unit raise @git.GitError {
  if not(rfs.is_dir(src)) {
    return
  }
  wfs.mkdir_p(dst)
  let entries = rfs.readdir(src)
  for entry in entries {
    if entry == "." || entry == ".." {
      continue
    }
    let src_path = join_path(src, entry)
    let dst_path = join_path(dst, entry)
    if rfs.is_dir(src_path) {
      copy_dir_recursive(wfs, rfs, src_path, dst_path)
    } else if rfs.is_file(src_path) {
      // Don't overwrite existing files
      if not(rfs.is_file(dst_path)) {
        let content = rfs.read_file(src_path)
        wfs.write_file(dst_path, content)
      }
    }
  }
}

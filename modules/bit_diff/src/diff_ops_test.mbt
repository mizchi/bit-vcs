///| Regression coverage for linked-worktree git-dir indirection.

///|
test "diff_index resolves linked worktree gitdir" {
  let fs = @bit.TestFs::new()
  ignore(@bitlib.init_repo(fs, "/repo")) catch {
    _ => ()
  }
  fs.write_string("/repo/a.txt", "base\n")
  @bitlib.add_paths(fs, fs, "/repo", ["a.txt"])
  let base = @bitlib.commit(
    fs, fs, "/repo", "base\n", "Test <test@example.com>", 1700000000L,
  )
  @bitlib.create_worktree(
    fs,
    fs,
    "/repo",
    "/worker",
    Some(base.to_hex()),
    new_branch=Some("feature"),
  )

  inspect(diff_index(fs, "/worker").length(), content="0")
}

///| Native promisor adapter - provides fetch_objects_http callback

///|
/// Create a PromisorDb with native HTTP fetch capability
pub fn native_promisor_db(
  fs : &@git.RepoFileSystem,
  git_dir : String,
  lazy_load? : Bool = true,
) -> @gitlib.PromisorDb raise @git.GitError {
  @gitlib.PromisorDb::new(
    fs,
    git_dir,
    lazy_load~,
    fetch_fn=Some(async fn(
      remote : String,
      wants : Array[@git.ObjectId],
    ) -> Result[Array[@git.PackObject], @git.GitError] noraise {
      let result : Result[Array[@git.PackObject], @git.GitError] = Ok(
        @gitionative.fetch_objects_http(remote, wants, true, depth=0),
      ) catch {
        e => Err(e)
      }
      result
    }),
  )
}

///| Tests for cancellation propagation in native agent runtime

///|
async fn capture_cancel_error() -> Error {
  let err_ref : Ref[Error?] = Ref::new(None)
  @async.with_task_group(async fn(root) {
    let task = root.spawn(allow_failure=true, async fn() {
      @async.sleep(10000) catch {
        err => {
          err_ref.val = Some(err)
          if @async.is_being_cancelled() || @async.is_cancellation_error(err) {
            raise err
          }
        }
      }
    })
    @async.sleep(10)
    task.cancel()
    ignore(try? task.wait())
  })
  match err_ref.val {
    Some(err) => err
    None => @git.GitError::IoError("expected cancellation error")
  }
}

///|
async test "return_or_raise_cancellation returns fallback for non-cancel error" {
  let err : Error = @git.GitError::IoError("boom")
  let result = return_or_raise_cancellation(err, "ok")
  assert_eq(result, "ok")
}

///|
async test "return_or_raise_cancellation re-raises cancellation error" {
  let cancel_err = capture_cancel_error()
  assert_true(@async.is_cancellation_error(cancel_err))
  let result = try? return_or_raise_cancellation(cancel_err, "fallback")
  inspect(result, content="Err(Cancelled)")
}

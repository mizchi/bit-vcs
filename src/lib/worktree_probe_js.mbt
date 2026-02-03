///|
/// Worktree probe helpers (JS target: no symlink/exec support)

///|
priv enum WorktreeKind {
  Regular
  Symlink(target~ : String)
}

///|
priv struct WorktreeEntry {
  kind : WorktreeKind
  mode : Int
  mtime_sec : Int?
  mtime_nsec : Int?
}

///|
priv enum WorktreeKindMeta {
  Regular
  Symlink
}

///|
priv struct WorktreeEntryMeta {
  kind : WorktreeKindMeta
  mode : Int
  size : Int?
  mtime_sec : Int?
  mtime_nsec : Int?
}

///|
async fn worktree_entry(
  fs : &@git.RepoFileSystem,
  abs_path : String,
) -> WorktreeEntry? noraise {
  let meta = worktree_entry_meta(fs, abs_path)
  match meta {
    None => None
    Some(info) =>
      match info.kind {
        WorktreeKindMeta::Regular =>
          Some({
            kind: WorktreeKind::Regular,
            mode: info.mode,
            mtime_sec: info.mtime_sec,
            mtime_nsec: info.mtime_nsec,
          })
        WorktreeKindMeta::Symlink =>
          match read_symlink_target_path(abs_path) {
            Some(target) =>
              Some({
                kind: WorktreeKind::Symlink(target~),
                mode: info.mode,
                mtime_sec: info.mtime_sec,
                mtime_nsec: info.mtime_nsec,
              })
            None => None
          }
      }
  }
}

///|
async fn worktree_entry_meta(
  fs : &@git.RepoFileSystem,
  abs_path : String,
) -> WorktreeEntryMeta? noraise {
  ignore(try? @async.with_timeout_opt(0, async fn() { () }))
  match try_readlink(abs_path) {
    Some(_) =>
      Some({
        kind: WorktreeKindMeta::Symlink,
        mode: 0o120000,
        size: None,
        mtime_sec: None,
        mtime_nsec: None,
      })
    None =>
      if fs.is_file(abs_path) {
        Some({
          kind: WorktreeKindMeta::Regular,
          mode: 0o100644,
          size: None,
          mtime_sec: None,
          mtime_nsec: None,
        })
      } else {
        None
      }
  }
}

///|
fn read_symlink_target_path(path : String) -> String? {
  try_readlink(path)
}

///|
fn try_readlink(path : String) -> String? {
  ignore(path)
  None
}

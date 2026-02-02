///|
priv enum WorktreeKind {
  Regular
  Symlink(target~ : String)
}

///|
priv struct WorktreeEntry {
  kind : WorktreeKind
  mode : Int
  size : Int?
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
            size: info.size,
            mtime_sec: info.mtime_sec,
            mtime_nsec: info.mtime_nsec,
          })
        WorktreeKindMeta::Symlink =>
          match read_symlink_target_path(abs_path) {
            Some(target) =>
              Some({
                kind: WorktreeKind::Symlink(target=target),
                mode: info.mode,
                size: info.size,
                mtime_sec: info.mtime_sec,
                mtime_nsec: info.mtime_nsec,
              })
            None => None
          }
      }
  }
}

///|
async fn build_regular_entry(
  abs_path : String,
  use_os : Bool,
) -> WorktreeEntry {
  if not(use_os) {
    return {
      kind: WorktreeKind::Regular,
      mode: 0o100644,
      size: None,
      mtime_sec: None,
      mtime_nsec: None,
    }
  }
  let exec = @afs.can_execute(abs_path) catch { _ => false }
  let mode = if exec { 0o100755 } else { 0o100644 }
  let mut size : Int? = None
  let mut mtime_sec : Int? = None
  let mut mtime_nsec : Int? = None
  let open_result : Result[@afs.File, Error] = try? @afs.open(
    abs_path,
    mode=@afs.Mode::ReadOnly,
  )
  match open_result {
    Ok(file) => {
      let size_result : Result[Int64, Error] = try? file.size()
      match size_result {
        Ok(s) => size = Some(s.to_int())
        Err(_) => ()
      }
      let mtime_result : Result[(Int64, Int), Error] = try? file.mtime()
      match mtime_result {
        Ok((sec, nsec)) => {
          mtime_sec = Some(sec.to_int())
          mtime_nsec = Some(nsec)
        }
        Err(_) => ()
      }
      file.close()
    }
    Err(_) => ()
  }
  { kind: WorktreeKind::Regular, mode, size, mtime_sec, mtime_nsec }
}

///|
async fn worktree_entry_meta(
  fs : &@git.RepoFileSystem,
  abs_path : String,
) -> WorktreeEntryMeta? noraise {
  let kind_result : Result[@afs.FileKind, Error] = try? @afs.kind(
    abs_path,
    follow_symlink=false,
  )
  match kind_result {
    Ok(@afs.FileKind::SymLink) => {
      let mut mtime_sec : Int? = None
      let mut mtime_nsec : Int? = None
      let mtime_result : Result[(Int64, Int), Error] = try? @afs.mtime(
        abs_path,
        follow_symlink=false,
      )
      match mtime_result {
        Ok((sec, nsec)) => {
          mtime_sec = Some(sec.to_int())
          mtime_nsec = Some(nsec)
        }
        Err(_) => ()
      }
      Some({
        kind: WorktreeKindMeta::Symlink,
        mode: 0o120000,
        size: None,
        mtime_sec,
        mtime_nsec,
      })
    }
    Ok(@afs.FileKind::Regular) => {
      let entry = try build_regular_entry(abs_path, true) catch { _ => return None }
      Some({
        kind: WorktreeKindMeta::Regular,
        mode: entry.mode,
        size: entry.size,
        mtime_sec: entry.mtime_sec,
        mtime_nsec: entry.mtime_nsec,
      })
    }
    Ok(_) => None
    Err(_) =>
      if fs.is_file(abs_path) {
        let entry = try build_regular_entry(abs_path, false) catch {
          _ => return None
        }
        Some({
          kind: WorktreeKindMeta::Regular,
          mode: entry.mode,
          size: entry.size,
          mtime_sec: entry.mtime_sec,
          mtime_nsec: entry.mtime_nsec,
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
  let path_buf = string_to_cstring(path)
  let mut buf_len = 256
  while buf_len <= 131072 {
    let buf = Bytes::new(buf_len)
    let read_len = readlink(path_buf, buf, buf.length())
    if read_len < 0 {
      return None
    }
    if read_len < buf.length() {
      return Some(buf.to_unchecked_string(length=read_len))
    }
    buf_len *= 2
  }
  let buf = Bytes::new(131072)
  let read_len = readlink(path_buf, buf, buf.length())
  if read_len < 0 {
    None
  } else {
    Some(buf.to_unchecked_string(length=read_len))
  }
}

///|
fn string_to_cstring(path : String) -> Bytes {
  let encoded = @utf8.encode(path.to_string_view())
  Bytes::add(encoded, Bytes::make(1, b'\x00'))
}

///|
#borrow(path_buf, buf)
extern "c" fn readlink(path_buf : Bytes, buf : Bytes, size : Int) -> Int =
  "readlink"

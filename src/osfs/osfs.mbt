///| OsFs - OS filesystem implementation for @git.FileSystem and @git.RepoFileSystem

///|
pub struct OsFs {
  priv dummy : Int
}

///|
pub fn OsFs::new() -> OsFs {
  { dummy: 0 }
}

///|
fn io_error(err : @fs.IOError) -> @git.GitError {
  @git.GitError::IoError(err.to_string())
}

///|
fn ensure_dir(path : String) -> Unit raise @git.GitError {
  let is_dir = @fs.is_dir(path) catch { _ => false }
  if is_dir {
    return
  }
  // Recursively create parent directories
  let parts = path.split("/").collect()
  let mut current = ""
  for part_view in parts {
    let part = part_view.to_string()
    if part.length() == 0 {
      current = "/"
      continue
    }
    current = if current.length() == 0 || current == "/" {
      current + part
    } else {
      current + "/" + part
    }
    let exists = @fs.is_dir(current) catch { _ => false }
    if not(exists) {
      @fs.create_dir(current) catch {
        err => raise io_error(err)
      }
    }
  }
}

///|
pub impl @git.FileSystem for OsFs with mkdir_p(_self, path) {
  ensure_dir(path)
}

///|
pub impl @git.FileSystem for OsFs with write_file(_self, path, content) {
  @fs.write_bytes_to_file(path, content) catch {
    err => raise io_error(err)
  }
}

///|
pub impl @git.FileSystem for OsFs with write_string(_self, path, content) {
  @fs.write_string_to_file(path, content) catch {
    err => raise io_error(err)
  }
}

///|
pub impl @git.FileSystem for OsFs with remove_file(_self, path) {
  @fs.remove_file(path) catch {
    err => raise io_error(err)
  }
}

///|
pub impl @git.FileSystem for OsFs with remove_dir(_self, path) {
  @fs.remove_dir(path) catch {
    err => raise io_error(err)
  }
}

///|
pub impl @git.RepoFileSystem for OsFs with read_file(_self, path) {
  @fs.read_file_to_bytes(path) catch {
    err => raise io_error(err)
  }
}

///|
pub impl @git.RepoFileSystem for OsFs with readdir(_self, path) {
  @fs.read_dir(path) catch {
    err => raise io_error(err)
  }
}

///|
pub impl @git.RepoFileSystem for OsFs with is_dir(_self, path) {
  @fs.is_dir(path) catch {
    _ => false
  }
}

///|
pub impl @git.RepoFileSystem for OsFs with is_file(_self, path) {
  @fs.is_file(path) catch {
    _ => false
  }
}

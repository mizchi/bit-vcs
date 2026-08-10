///| git http-fetch - download objects via dumb HTTP

///|
async fn handle_http_fetch(args : Array[String]) -> Unit raise Error {
  let mut verbose = false
  let mut write_ref = ""
  let positional : Array[String] = []
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    match arg {
      "-h" | "--help" => {
        show_simple_command_help(
          "git http-fetch [-v] [-w <filename>] <commit-id> <url>",
          summary="Download objects from a remote repository via dumb HTTP.",
        )
        return
      }
      "-v" => verbose = true
      "-w" => {
        i += 1
        if i < args.length() {
          write_ref = args[i]
        }
      }
      "--recover" | "-a" | "-c" => () // accepted but ignored
      _ if arg.has_prefix("-") => warn_unimplemented_arg("http-fetch", arg)
      _ => positional.push(arg)
    }
    i += 1
  }
  if positional.length() < 2 {
    eprint_line("usage: git http-fetch [-v] [-w <filename>] <commit-id> <url>")
    @sys.exit(1)
    return
  }
  let commit_id = positional[0]
  let url = positional[1]
  let root = get_work_root()
  let fs = OsFs::new()
  let git_dir = resolve_git_dir(fs, root)
  let objects_dir = git_dir + "/objects"
  let headers : Map[String, String] = Map([])
  // Try to fetch the pack list
  let packs_url = url + "/objects/info/packs"
  if verbose {
    eprint_line("Getting \{packs_url}")
  }
  let (_resp, packs_data) = @bitnative.native_http_get(packs_url, headers) catch {
    _ => {
      // No packs info, try loose object fetch
      http_fetch_loose_object(url, commit_id, objects_dir, headers, verbose)
      if write_ref.length() > 0 {
        http_fetch_write_ref(git_dir, write_ref, commit_id)
      }
      return
    }
  }
  let packs_text = decode_bytes(packs_data)
  // Parse pack list and download packs
  for line_view in packs_text.split("\n") {
    let line = line_view.to_owned()
    if line.has_prefix("P ") {
      let pack_name = line[2:].to_owned()
      if pack_name.length() > 0 {
        let pack_url = url + "/objects/pack/" + pack_name
        if verbose {
          eprint_line("Getting \{pack_url}")
        }
        let (_presp, pack_data) = @bitnative.native_http_get(pack_url, headers) catch {
          err => {
            eprint_line("warning: failed to fetch \{pack_url}: \{err}")
            continue
          }
        }
        let pack_path = objects_dir + "/pack/" + pack_name
        ensure_dir(objects_dir + "/pack")
        @fs.write_bytes_to_file(pack_path, pack_data) catch {
          err => {
            eprint_line(
              "error: cannot write \{pack_path}: \{@debug.render(Repr(err))}",
            )
            continue
          }
        }
        // Fetch corresponding .idx if pack
        if pack_name.has_suffix(".pack") {
          let idx_name = pack_name[:pack_name.length() - 5].to_owned() + ".idx"
          let idx_url = url + "/objects/pack/" + idx_name
          if verbose {
            eprint_line("Getting \{idx_url}")
          }
          let (_iresp, idx_data) = @bitnative.native_http_get(idx_url, headers) catch {
            _ => continue
          }
          let idx_path = objects_dir + "/pack/" + idx_name
          @fs.write_bytes_to_file(idx_path, idx_data) catch {
            _ => ()
          }
        }
      }
    }
  }
  if write_ref.length() > 0 {
    http_fetch_write_ref(git_dir, write_ref, commit_id)
  }
}

///|
async fn http_fetch_loose_object(
  url : String,
  oid_hex : String,
  objects_dir : String,
  headers : Map[String, String],
  verbose : Bool,
) -> Unit raise Error {
  if oid_hex.length() < 4 {
    return
  }
  let prefix = oid_hex[:2].to_owned()
  let suffix = oid_hex[2:].to_owned()
  let obj_url = url + "/objects/" + prefix + "/" + suffix
  if verbose {
    eprint_line("Getting \{obj_url}")
  }
  let (_resp, data) = @bitnative.native_http_get(obj_url, headers) catch {
    err => {
      eprint_line("error: cannot fetch \{obj_url}: \{err}")
      @sys.exit(1)
      return
    }
  }
  let dir = objects_dir + "/" + prefix
  ensure_dir(dir)
  let path = dir + "/" + suffix
  @fs.write_bytes_to_file(path, data) catch {
    err => {
      eprint_line(
        "error: cannot write \{path}: \{@debug.render(Repr(err))}",
      )
      @sys.exit(1)
      return
    }
  }
}

///|
fn http_fetch_write_ref(
  git_dir : String,
  ref_name : String,
  commit_id : String,
) -> Unit raise Error {
  let ref_path = git_dir + "/" + ref_name
  let parent = parent_dir(ref_path)
  if parent.length() > 0 {
    ensure_dir(parent)
  }
  let content = commit_id + "\n"
  let content_bytes = Bytes::from_array(
    content.to_array().map(fn(c) { c.to_int().to_byte() }),
  )
  @fs.write_bytes_to_file(ref_path, content_bytes) catch {
    err =>
      raise @bitcore.GitError::IoError(
        "cannot write ref \{ref_path}: \{@debug.render(Repr(err))}",
      )
  }
}

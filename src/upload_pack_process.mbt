///| Upload-pack over git-upload-pack (native targets)

///|
priv struct ProcessSpec {
  cmd : String
  args : Array[String]
  extra_env : Map[String, String]?
}

///|
fn ensure_remote_path(spec : RemoteSpec) -> String raise GitError {
  if spec.path.length() == 0 {
    raise GitError::ProtocolError("Remote path is empty")
  }
  spec.path
}

///|
fn ssh_remote_path(spec : RemoteSpec, path : String) -> String {
  if spec.raw.has_prefix("ssh://") && not(path.has_prefix("/")) {
    "/\{path}"
  } else {
    path
  }
}

///|
fn build_upload_pack_process_spec(
  spec : RemoteSpec,
  advertise_refs~ : Bool,
  prefer_v2~ : Bool,
) -> ProcessSpec raise GitError {
  let path = ensure_remote_path(spec)
  match spec.kind {
    RemoteKind::Http =>
      raise GitError::ProtocolError(
        "HTTP transport is not supported by process client",
      )
    RemoteKind::File => {
      let args : Array[String] = []
      args.push("--stateless-rpc")
      if advertise_refs {
        args.push("--advertise-refs")
      }
      args.push(path)
      let extra_env = if prefer_v2 {
        Some({ "GIT_PROTOCOL": "version=2" })
      } else {
        None
      }
      { cmd: "git-upload-pack", args, extra_env }
    }
    RemoteKind::Ssh => {
      let host = match spec.host {
        None => raise GitError::ProtocolError("SSH remote missing host")
        Some(v) => v
      }
      let args : Array[String] = [host]
      if prefer_v2 {
        args.push("env")
        args.push("GIT_PROTOCOL=version=2")
      }
      args.push("git-upload-pack")
      args.push("--stateless-rpc")
      if advertise_refs {
        args.push("--advertise-refs")
      }
      args.push(ssh_remote_path(spec, path))
      { cmd: "ssh", args, extra_env: None }
    }
  }
}

///|
fn bytes_to_string_lossy(data : Bytes) -> String {
  @utf8.decode_lossy(data[:])
}

///|
fn cleanup_temp_files(paths : Array[String]) -> Unit {
  for path in paths {
    @fs.remove_file(path) catch {
      _ => ()
    }
  }
}

///|
async fn run_process_with_files(
  spec : ProcessSpec,
  stdin_data : Bytes?,
) -> (Int, Bytes, Bytes) raise GitError {
  let nonce = @async.now()
  let base = "/tmp/moonbit-git-upload-pack-\{nonce}"
  let stdout_path = "\{base}.out"
  let stderr_path = "\{base}.err"
  let stdin_path = "\{base}.in"
  let cleanup_paths = [stdout_path, stderr_path, stdin_path]
  let stdout = @process.redirect_to_file(stdout_path, truncate=true) catch {
    e => raise GitError::IoError("failed to open stdout file: \{e}")
  }
  let stderr = @process.redirect_to_file(stderr_path, truncate=true) catch {
    e => raise GitError::IoError("failed to open stderr file: \{e}")
  }
  let stdin = match stdin_data {
    None => None
    Some(data) => {
      @fs.write_bytes_to_file(stdin_path, data) catch {
        e => raise GitError::IoError("failed to write stdin temp file: \{e}")
      }
      let input = @process.redirect_from_file(stdin_path) catch {
        e => raise GitError::IoError("process stdin failed: \{e}")
      }
      Some(input)
    }
  }
  let code = match spec.extra_env {
    None =>
      match stdin {
        None =>
          @process.run(spec.cmd, spec.args, inherit_env=true, stdout~, stderr~) catch {
            e => {
              cleanup_temp_files(cleanup_paths)
              raise GitError::IoError("process failed: \{e}")
            }
          }
        Some(input) =>
          @process.run(
            spec.cmd,
            spec.args,
            inherit_env=true,
            stdin=input,
            stdout~,
            stderr~,
          ) catch {
            e => {
              cleanup_temp_files(cleanup_paths)
              raise GitError::IoError("process failed: \{e}")
            }
          }
      }
    Some(env) =>
      match stdin {
        None =>
          @process.run(
            spec.cmd,
            spec.args,
            extra_env=env,
            inherit_env=true,
            stdout~,
            stderr~,
          ) catch {
            e => {
              cleanup_temp_files(cleanup_paths)
              raise GitError::IoError("process failed: \{e}")
            }
          }
        Some(input) =>
          @process.run(
            spec.cmd,
            spec.args,
            extra_env=env,
            inherit_env=true,
            stdin=input,
            stdout~,
            stderr~,
          ) catch {
            e => {
              cleanup_temp_files(cleanup_paths)
              raise GitError::IoError("process failed: \{e}")
            }
          }
      }
  }
  let out = @fs.read_file_to_bytes(stdout_path) catch {
    e => {
      cleanup_temp_files(cleanup_paths)
      raise GitError::IoError("failed to read stdout: \{e}")
    }
  }
  let err = @fs.read_file_to_bytes(stderr_path) catch {
    e => {
      cleanup_temp_files(cleanup_paths)
      raise GitError::IoError("failed to read stderr: \{e}")
    }
  }
  cleanup_temp_files(cleanup_paths)
  (code, out, err)
}

///|
async fn run_upload_pack_process(
  spec : ProcessSpec,
  stdin_data : Bytes?,
) -> Bytes raise GitError {
  let (code, stdout, stderr) = run_process_with_files(spec, stdin_data)
  if code != 0 {
    let args_joined = spec.args.join(" ")
    let cmdline = "\{spec.cmd} \{args_joined}"
    let err = bytes_to_string_lossy(stderr)
    let detail = if err.length() > 0 { ": \{err}" } else { "" }
    raise GitError::IoError(
      "git-upload-pack failed (exit=\{code}): \{cmdline}\{detail}",
    )
  }
  stdout
}

///|
pub async fn upload_pack_info_refs_process(
  remote : String,
  prefer_v2 : Bool,
) -> Bytes raise GitError {
  let spec = parse_remote(remote)
  let proc = build_upload_pack_process_spec(
    spec,
    advertise_refs=true,
    prefer_v2~,
  )
  run_upload_pack_process(proc, None)
}

///|
pub async fn upload_pack_request_process(
  remote : String,
  body : Bytes,
  prefer_v2 : Bool,
) -> Bytes raise GitError {
  let spec = parse_remote(remote)
  let proc = build_upload_pack_process_spec(
    spec,
    advertise_refs=false,
    prefer_v2~,
  )
  run_upload_pack_process(proc, Some(body))
}

///|
pub async fn discover_upload_refs_process(
  remote : String,
  prefer_v2 : Bool,
) -> (
  Array[(ObjectId, String)],
  Array[String],
  ProtocolVersion,
  Map[String, String],
) raise GitError {
  let adv = upload_pack_info_refs_process(remote, prefer_v2)
  let version = detect_protocol_version(adv)
  if version == ProtocolVersion::V2 {
    let caps = parse_v2_advertised_caps(adv)
    let req = build_ls_refs_request("git/moonbit", [
      "refs/heads/", "refs/tags/", "HEAD",
    ])
    let resp = upload_pack_request_process(remote, req, true)
    let parsed = parse_ls_refs_response(resp)
    return (parsed.refs, caps, version, parsed.symrefs)
  }
  let refs = parse_refs(adv)
  let caps = parse_v0_advertised_caps(adv)
  (refs, caps, ProtocolVersion::V0, {})
}

///|
pub async fn fetch_pack_process(
  remote : String,
  wants : Array[ObjectId],
  prefer_v2 : Bool,
) -> Bytes raise GitError {
  let (refs, caps, version, _symrefs) = discover_upload_refs_process(
    remote, prefer_v2,
  )
  let wants = if wants.length() == 0 {
    let ids : Array[ObjectId] = []
    for item in refs {
      let (id, _) = item
      ids.push(id)
    }
    ids
  } else {
    wants
  }
  if version == ProtocolVersion::V2 {
    let req = build_fetch_request_v2("git/moonbit", wants)
    let resp = upload_pack_request_process(remote, req, true)
    return extract_pack_from_v2_response(resp)
  }
  let req = build_fetch_request_v0("git/moonbit", wants, caps)
  let resp = upload_pack_request_process(remote, req, false)
  extract_pack_from_v0_response(resp)
}

///|
pub async fn fetch_objects_process(
  remote : String,
  wants : Array[ObjectId],
  prefer_v2 : Bool,
) -> Array[PackObject] raise GitError {
  let pack = fetch_pack_process(remote, wants, prefer_v2)
  parse_packfile(pack)
}

///|
pub async fn clone_process(
  remote : String,
  prefer_v2 : Bool,
) -> (Array[(ObjectId, String)], Array[PackObject]) raise GitError {
  let (refs, _caps, _version, symrefs) = discover_upload_refs_process(
    remote, prefer_v2,
  )
  let wants = select_default_wants(refs, symrefs)
  let pack = fetch_pack_process(remote, wants, prefer_v2)
  let objects = parse_packfile(pack)
  (refs, objects)
}

///|
/// Clone and checkout into filesystem under `root`.
pub async fn clone_process_to_fs(
  remote : String,
  prefer_v2 : Bool,
  fs : &FileSystem,
  root : String,
) -> Array[(ObjectId, String)] raise GitError {
  let (refs, _caps, _version, symrefs) = discover_upload_refs_process(
    remote, prefer_v2,
  )
  let wants = select_default_wants(refs, symrefs)
  let default_ref = select_default_ref(refs, symrefs)
  match default_ref {
    None => return refs
    Some(_) => ()
  }
  if wants.length() == 0 {
    return refs
  }
  let pack = fetch_pack_process(remote, wants, prefer_v2)
  let objects = parse_packfile(pack)
  let store = ObjectStore::from_pack(objects)
  match default_ref {
    None => ()
    Some((refname, commit_id)) => {
      materialize_clone_to_fs(store, commit_id, refname, remote, fs, root)
      let git_dir = join_path(root, ".git")
      write_packfile_with_index(fs, git_dir, pack, objects)
    }
  }
  refs
}

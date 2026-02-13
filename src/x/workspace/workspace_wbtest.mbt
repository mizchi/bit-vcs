///|
fn issues_contain(issues : Array[String], needle : String) -> Bool {
  for issue in issues {
    if issue.contains(needle) {
      return true
    }
  }
  false
}

///|
test "workspace: flow graph conversion preserves node shape" {
  let root = workspace_new_node()
  root.id = "root"
  root.path = "."
  root.depends_on = []
  let dep = workspace_new_node()
  dep.id = "dep"
  dep.path = "dep"
  dep.required = false
  dep.depends_on = ["root"]
  let manifest : WorkspaceManifest = { version: 1, nodes: [root, dep] }
  let flow_nodes = workspace_flow_nodes(manifest)
  assert_eq(flow_nodes.length(), 2)
  assert_eq(flow_nodes[0].id, "root")
  assert_eq(flow_nodes[1].id, "dep")
  assert_eq(flow_nodes[1].required, false)
  assert_eq(flow_nodes[1].depends_on.length(), 1)
  assert_eq(flow_nodes[1].depends_on[0], "root")
}

///|
test "workspace: flow ir keeps selected dependency edges" {
  let root = workspace_new_node()
  root.id = "root"
  root.path = "."
  root.depends_on = []
  root.tasks["test"] = workspace_new_task(cmd="echo root")
  let dep = workspace_new_node()
  dep.id = "dep"
  dep.path = "dep"
  dep.depends_on = ["root"]
  dep.tasks["test"] = workspace_new_task(cmd="echo dep")
  let extra = workspace_new_node()
  extra.id = "extra"
  extra.path = "extra"
  extra.depends_on = []
  extra.tasks["test"] = workspace_new_task(cmd="echo extra")
  let manifest : WorkspaceManifest = { version: 1, nodes: [root, dep, extra] }
  let selected : Map[String, Bool] = { "root": true, "dep": true }
  let ir = workspace_flow_ir(manifest, selected, "test")
  assert_eq(ir.nodes.length(), 2)
  assert_eq(ir.tasks.length(), 2)
  let task_map : Map[String, @bitflow.FlowTask] = {}
  for task in ir.tasks {
    task_map[task.id] = task
  }
  assert_true(task_map.get("root") is Some(_))
  assert_true(task_map.get("dep") is Some(_))
  assert_true(task_map.get("extra") is None)
  match task_map.get("dep") {
    Some(task) => {
      assert_eq(task.needs.length(), 1)
      assert_eq(task.needs[0], "root")
    }
    None => fail("dep task missing")
  }
}

///|
test "workspace: parse manifest with dependencies and tasks" {
  let manifest_text =
    #|version = 1
    #|
    #|[[nodes]]
    #|id = "root"
    #|path = "."
    #|required = true
    #|depends_on = []
    #|task.test = "just test"
    #|
    #|[[nodes]]
    #|id = "foo"
    #|path = "foo"
    #|required = false
    #|depends_on = ["root"]
    #|task.check = "just check"
  let parsed = parse_workspace_manifest(manifest_text)
  assert_eq(parsed.version, 1)
  assert_eq(parsed.nodes.length(), 2)
  let root = parsed.nodes[0]
  let foo = parsed.nodes[1]
  assert_eq(root.id, "root")
  assert_eq(root.path, ".")
  assert_eq(root.required, true)
  assert_eq(root.depends_on.length(), 0)
  match root.tasks.get("test") {
    Some(task) => assert_eq(task.cmd, "just test")
    None => fail("root test task missing")
  }
  assert_eq(foo.id, "foo")
  assert_eq(foo.required, false)
  assert_eq(foo.depends_on.length(), 1)
  assert_eq(foo.depends_on[0], "root")
  match foo.tasks.get("check") {
    Some(task) => assert_eq(task.cmd, "just check")
    None => fail("foo check task missing")
  }
}

///|
test "workspace: parse manifest supports extended task fields" {
  let manifest_text =
    #|version = 1
    #|
    #|[[nodes]]
    #|id = "root"
    #|path = "."
    #|required = true
    #|depends_on = []
    #|task.test = "just test"
    #|task.test.srcs = ["src/**"]
    #|task.test.outs = ["dist/**"]
    #|task.test.cwd = "pkg"
    #|task.test.trigger_mode = "manual"
    #|task.test.env.MODE = "ci"
  let parsed = parse_workspace_manifest(manifest_text)
  assert_eq(parsed.nodes.length(), 1)
  match parsed.nodes[0].tasks.get("test") {
    Some(task) => {
      assert_eq(task.cmd, "just test")
      assert_eq(task.srcs.length(), 1)
      assert_eq(task.srcs[0], "src/**")
      assert_eq(task.outs.length(), 1)
      assert_eq(task.outs[0], "dist/**")
      assert_eq(task.cwd, "pkg")
      assert_eq(task.trigger_mode, "manual")
      assert_eq(task.env.get("MODE").unwrap_or(""), "ci")
    }
    None => fail("extended task config not parsed")
  }
}

///|
test "workspace: format and parse roundtrip keeps node shape" {
  let node = workspace_new_node()
  node.id = "pkg"
  node.path = "packages/pkg"
  node.required = false
  node.depends_on = ["root"]
  node.tasks["lint"] = workspace_new_task(cmd="just lint")
  let manifest : WorkspaceManifest = {
    version: 1,
    nodes: [workspace_new_node(), node],
  }
  let text = format_workspace_manifest(manifest)
  let reparsed = parse_workspace_manifest(text)
  assert_eq(reparsed.nodes.length(), 2)
  assert_eq(reparsed.nodes[1].id, "pkg")
  assert_eq(reparsed.nodes[1].path, "packages/pkg")
  assert_eq(reparsed.nodes[1].required, false)
  assert_eq(reparsed.nodes[1].depends_on.length(), 1)
  assert_eq(reparsed.nodes[1].depends_on[0], "root")
  match reparsed.nodes[1].tasks.get("lint") {
    Some(task) => assert_eq(task.cmd, "just lint")
    None => fail("lint task missing after roundtrip")
  }
}

///|
test "workspace: flow ir preserves extended task metadata" {
  let root = workspace_new_node()
  root.id = "root"
  root.path = "."
  root.depends_on = []
  let task = workspace_new_task(cmd="just test")
  task.srcs = ["src/**"]
  task.outs = ["dist/**"]
  task.env["MODE"] = "ci"
  task.cwd = "pkg"
  task.trigger_mode = "manual"
  root.tasks["test"] = task
  let manifest : WorkspaceManifest = { version: 1, nodes: [root] }
  let selected : Map[String, Bool] = { "root": true }
  let ir = workspace_flow_ir(manifest, selected, "test")
  assert_eq(ir.tasks.length(), 1)
  let ir_task = ir.tasks[0]
  assert_eq(ir_task.cmd, "just test")
  assert_eq(ir_task.srcs.length(), 1)
  assert_eq(ir_task.srcs[0], "src/**")
  assert_eq(ir_task.outs.length(), 1)
  assert_eq(ir_task.outs[0], "dist/**")
  assert_eq(ir_task.env.get("MODE").unwrap_or(""), "ci")
  assert_eq(ir_task.cwd, "pkg")
  assert_eq(ir_task.trigger_mode, "manual")
}

///|
test "workspace: flow template manifest scaffolds expected node graph" {
  let manifest = workspace_manifest_for_template(Some("flow")) catch {
    err => fail("unexpected error: \{err.to_string()}")
  }
  assert_eq(manifest.nodes.length(), 4)
  assert_eq(manifest.nodes[0].id, "root")
  assert_eq(manifest.nodes[1].id, "dep")
  assert_eq(manifest.nodes[2].id, "leaf")
  assert_eq(manifest.nodes[3].id, "extra")
  assert_eq(manifest.nodes[1].depends_on[0], "root")
  assert_eq(manifest.nodes[2].depends_on[0], "dep")
  match manifest.nodes[0].tasks.get("test") {
    Some(task) => assert_true(task.cmd.contains("BIT_WORKSPACE_FLOW_LOG_DIR"))
    None => fail("flow template root test task missing")
  }
}

///|
test "workspace: manifest template rejects unknown name" {
  ignore(
    workspace_manifest_for_template(Some("nope-template")) catch {
      @git.GitError::InvalidObject(message) => {
        assert_true(message.contains("unknown workspace template"))
        return ()
      }
      err => fail("unexpected error: \{err.to_string()}")
    },
  )
  fail("expected invalid object error")
}

///|
test "workspace: expand affected follows workspace dependency graph" {
  let root = workspace_new_node()
  root.id = "root"
  root.path = "."
  root.depends_on = []
  let dep = workspace_new_node()
  dep.id = "dep"
  dep.path = "dep"
  dep.depends_on = ["root"]
  let leaf = workspace_new_node()
  leaf.id = "leaf"
  leaf.path = "leaf"
  leaf.depends_on = ["dep"]
  let extra = workspace_new_node()
  extra.id = "extra"
  extra.path = "extra"
  extra.depends_on = []
  let manifest : WorkspaceManifest = {
    version: 1,
    nodes: [root, dep, leaf, extra],
  }
  let initial : Map[String, Bool] = { "dep": true }
  let affected = expand_affected_node_ids(manifest, initial)
  assert_eq(affected.get("root") is Some(_), true)
  assert_eq(affected.get("dep") is Some(_), true)
  assert_eq(affected.get("leaf") is Some(_), true)
  assert_eq(affected.get("extra") is Some(_), false)
}

///|
test "workspace: implicit translation activates inside workspace root tree" {
  let fs = @osfs.OsFs::new()
  let root = "/tmp/bit-test-workspace-translate-" +
    get_current_timestamp().to_string()
  let nested = root + "/nested/leaf"
  fs.mkdir_p(root + "/.bit")
  fs.mkdir_p(nested)
  fs.write_string(root + "/.bit/workspace.toml", "version = 1\n")
  let (cmd, rest) = workspace_translate_implicit_command(
    Some(nested),
    "status",
    [],
  )
  assert_eq(cmd, "workspace")
  assert_eq(rest.length(), 1)
  assert_eq(rest[0], "status")
  fs.remove_file(root + "/.bit/workspace.toml") catch {
    _ => ()
  }
  fs.remove_dir(root + "/.bit") catch {
    _ => ()
  }
  fs.remove_dir(root + "/nested/leaf") catch {
    _ => ()
  }
  fs.remove_dir(root + "/nested") catch {
    _ => ()
  }
  fs.remove_dir(root) catch {
    _ => ()
  }
}

///|
test "workspace: implicit translation is skipped outside workspace" {
  let root = "/tmp/bit-test-workspace-skip-" +
    get_current_timestamp().to_string()
  let fs = @osfs.OsFs::new()
  fs.mkdir_p(root)
  let (cmd, rest) = workspace_translate_implicit_command(Some(root), "status", [
    "--short",
  ])
  assert_eq(cmd, "status")
  assert_eq(rest.length(), 1)
  assert_eq(rest[0], "--short")
  fs.remove_dir(root) catch {
    _ => ()
  }
}

///|
test "workspace: flow cache key keeps task and node scope" {
  let key = workspace_flow_cache_key("test", "pkg")
  assert_eq(key, "test::pkg")
}

///|
test "workspace: bitflow cache plan reflects task metadata changes" {
  let node = workspace_new_node()
  node.id = "pkg"
  node.path = "pkg"
  node.depends_on = []
  let task = workspace_new_task(cmd="just test")
  task.srcs = ["src/**"]
  task.outs = ["dist/**"]
  task.cwd = "pkg"
  task.trigger_mode = "auto"
  node.tasks["test"] = task
  let manifest : WorkspaceManifest = { version: 1, nodes: [node] }
  let selected : Map[String, Bool] = { "pkg": true }
  let signatures : Map[String, String] = { "pkg": "pkg-1" }
  let ir1 = workspace_flow_ir(manifest, selected, "test")
  let cache : Map[String, String] = {}
  let plan1 = @bitflow.plan_task_cache(ir1, signatures, cache)
  assert_eq(plan1.issues.length(), 0)
  assert_eq(plan1.decisions.length(), 1)
  assert_eq(plan1.decisions[0].hit, false)
  cache[plan1.decisions[0].cache_key] = plan1.decisions[0].fingerprint
  let plan2 = @bitflow.plan_task_cache(ir1, signatures, cache)
  assert_eq(plan2.decisions.length(), 1)
  assert_eq(plan2.decisions[0].hit, true)
  match manifest.nodes[0].tasks.get("test") {
    Some(updated_task) => {
      updated_task.trigger_mode = "manual"
      manifest.nodes[0].tasks["test"] = updated_task
    }
    None => fail("task missing for metadata update")
  }
  let ir2 = workspace_flow_ir(manifest, selected, "test")
  let plan3 = @bitflow.plan_task_cache(ir2, signatures, cache)
  assert_eq(plan3.decisions.length(), 1)
  assert_eq(plan3.decisions[0].hit, false)
}

///|
test "workspace: flow fingerprint changes when dependency signature changes" {
  let node = workspace_new_node()
  node.id = "pkg"
  node.path = "pkg"
  node.depends_on = ["root"]
  let task = workspace_new_task(cmd="just test")
  task.srcs = ["src/**"]
  task.outs = ["dist/**"]
  task.env["MODE"] = "test"
  task.cwd = "pkg"
  let signatures : Map[String, String] = { "pkg": "pkg-1", "root": "root-1" }
  let fp1 = workspace_flow_fingerprint(node, task, signatures)
  signatures["root"] = "root-2"
  let fp2 = workspace_flow_fingerprint(node, task, signatures)
  assert_eq(fp1 == fp2, false)
}

///|
test "workspace: directory hash changes when file content changes" {
  let fs = @osfs.OsFs::new()
  let root = "/tmp/bit-test-workspace-dirhash-" +
    get_current_timestamp().to_string()
  fs.mkdir_p(root + "/nested")
  fs.write_string(root + "/nested/file.txt", "hello\n")
  let hash1 = @fingerprint.directory_fingerprint(
    fs,
    root,
    @fingerprint.FingerprintMode::Fast,
  )
  fs.write_string(root + "/nested/file.txt", "hello world\n")
  let hash2 = @fingerprint.directory_fingerprint(
    fs,
    root,
    @fingerprint.FingerprintMode::Fast,
  )
  assert_eq(hash1 == hash2, false)
  fs.remove_file(root + "/nested/file.txt") catch {
    _ => ()
  }
  fs.remove_dir(root + "/nested") catch {
    _ => ()
  }
  fs.remove_dir(root) catch {
    _ => ()
  }
}

///|
test "workspace: directory hash ignores .git and .bit metadata dirs" {
  let fs = @osfs.OsFs::new()
  let root = "/tmp/bit-test-workspace-dirhash-ignore-" +
    get_current_timestamp().to_string()
  fs.mkdir_p(root)
  fs.write_string(root + "/tracked.txt", "payload\n")
  let hash1 = @fingerprint.directory_fingerprint(
    fs,
    root,
    @fingerprint.FingerprintMode::Fast,
  )
  fs.mkdir_p(root + "/.git")
  fs.mkdir_p(root + "/.bit")
  fs.write_string(root + "/.git/HEAD", "ref: refs/heads/main\n")
  fs.write_string(root + "/.bit/WORKSPACE", "metadata\n")
  let hash2 = @fingerprint.directory_fingerprint(
    fs,
    root,
    @fingerprint.FingerprintMode::Fast,
  )
  assert_eq(hash1, hash2)
  fs.remove_file(root + "/tracked.txt") catch {
    _ => ()
  }
  fs.remove_file(root + "/.git/HEAD") catch {
    _ => ()
  }
  fs.remove_file(root + "/.bit/WORKSPACE") catch {
    _ => ()
  }
  fs.remove_dir(root + "/.git") catch {
    _ => ()
  }
  fs.remove_dir(root + "/.bit") catch {
    _ => ()
  }
  fs.remove_dir(root) catch {
    _ => ()
  }
}

///|
async test "workspace: node signature changes by fingerprint mode" {
  let fs = @osfs.OsFs::new()
  let root = "/tmp/bit-test-workspace-signature-mode-" +
    get_current_timestamp().to_string()
  let cleanup_before : Result[Int, Error] = try? @process.run(
    "rm",
    ["-rf", root],
    inherit_env=true,
  )
  ignore(cleanup_before)
  fs.mkdir_p(root)
  let init_code = try
    @process.collect_output(
      "git",
      ["init", "-b", "main"],
      inherit_env=true,
      cwd=root,
    )
  catch {
    _ => -1
  } noraise {
    (code, _, _) => code
  }
  if init_code != 0 {
    let cleanup_failed : Result[Int, Error] = try? @process.run(
      "rm",
      ["-rf", root],
      inherit_env=true,
    )
    ignore(cleanup_failed)
    return
  }
  fs.write_string(root + "/file.txt", "payload\n")
  let fast = workspace_node_directory_signature_with_mode(
    fs,
    root,
    @fingerprint.FingerprintMode::Fast,
  )
  let git = workspace_node_directory_signature_with_mode(
    fs,
    root,
    @fingerprint.FingerprintMode::GitCompat,
  )
  match (fast, git) {
    (Some(fast_sig), Some(git_sig)) => assert_eq(fast_sig == git_sig, false)
    _ => fail("workspace signature should exist for initialized repository")
  }
  let cleanup_after : Result[Int, Error] = try? @process.run(
    "rm",
    ["-rf", root],
    inherit_env=true,
  )
  ignore(cleanup_after)
}

///|
test "workspace: path containment rejects escape outside workspace root" {
  let workspace_root = "/tmp/ws"
  let inside_path = workspace_node_abs_path(workspace_root, "dep")
  let escaped_path = workspace_node_abs_path(workspace_root, "../outside")
  assert_eq(path_is_within_workspace_root(workspace_root, inside_path), true)
  assert_eq(path_is_within_workspace_root(workspace_root, escaped_path), false)
}

///|
test "workspace: manifest issues include governance and security violations" {
  let fs = @osfs.OsFs::new()
  let node1 = workspace_new_node()
  node1.id = "dup"
  node1.path = "."
  node1.depends_on = []
  let node2 = workspace_new_node()
  node2.id = "dup"
  node2.path = "../outside"
  node2.depends_on = ["missing"]
  let manifest : WorkspaceManifest = { version: 1, nodes: [node1, node2] }
  let issues = workspace_manifest_issues(fs, "/tmp/ws", manifest, false)
  assert_true(issues_contain(issues, "duplicate node id"))
  assert_true(issues_contain(issues, "escapes workspace root"))
  assert_true(issues_contain(issues, "depends on unknown node"))
}

///|
test "workspace: default star workflow file is bitflow.star" {
  assert_eq(workspace_default_star_file(), "bitflow.star")
}

///|
test "workspace: parse star flow ir supports load and external inputs" {
  let fs = @osfs.OsFs::new()
  let root = "/tmp/bit-test-workspace-star-ir-" +
    get_current_timestamp().to_string()
  fs.mkdir_p(root + "/defs")
  let root_star =
    #|var(name="flow_mark", type="string", required=True)
    #|workflow(name="ci")
    #|node(id="root", depends_on=[])
    #|task(id="root:test", node="root", cmd=["echo", flow_mark], needs=[])
    #|load(path="defs/dep.star")
    #|entrypoint(targets=["dep:test"])
  let dep_star =
    #|node(id="dep", depends_on=["root"])
    #|task(id="dep:test", node="dep", cmd=["echo", flow_mark], needs=["root:test"])
  fs.write_string(root + "/bitflow.star", root_star)
  fs.write_string(root + "/defs/dep.star", dep_star)
  let ir = workspace_parse_star_flow_ir(
    fs,
    root,
    "bitflow.star",
    Some("dep:test"),
    { "flow_mark": "from-input" },
  ) catch {
    err => fail("unexpected parse error: \{err.to_string()}")
  }
  assert_eq(ir.nodes.length(), 2)
  assert_eq(ir.tasks.length(), 2)
  assert_eq(ir.entry_targets.length(), 1)
  assert_eq(ir.entry_targets[0], "dep:test")
  let task_map : Map[String, @bitflow.FlowTask] = {}
  for task in ir.tasks {
    task_map[task.id] = task
  }
  match task_map.get("root:test") {
    Some(task) => assert_eq(task.cmd, "echo from-input")
    None => fail("root:test missing")
  }
  match task_map.get("dep:test") {
    Some(task) => assert_eq(task.cmd, "echo from-input")
    None => fail("dep:test missing")
  }
  fs.remove_file(root + "/bitflow.star") catch {
    _ => ()
  }
  fs.remove_file(root + "/defs/dep.star") catch {
    _ => ()
  }
  fs.remove_dir(root + "/defs") catch {
    _ => ()
  }
  fs.remove_dir(root) catch {
    _ => ()
  }
}

///|
test "workspace: implicit translation includes flow command inside workspace" {
  let fs = @osfs.OsFs::new()
  let root = "/tmp/bit-test-workspace-flow-translate-" +
    get_current_timestamp().to_string()
  let nested = root + "/nested"
  fs.mkdir_p(root + "/.bit")
  fs.mkdir_p(nested)
  fs.write_string(root + "/.bit/workspace.toml", "version = 1\n")
  let (cmd, rest) = workspace_translate_implicit_command(Some(nested), "flow", [
    "test",
  ])
  assert_eq(cmd, "workspace")
  assert_eq(rest.length(), 2)
  assert_eq(rest[0], "flow")
  assert_eq(rest[1], "test")
  fs.remove_file(root + "/.bit/workspace.toml") catch {
    _ => ()
  }
  fs.remove_dir(root + "/.bit") catch {
    _ => ()
  }
  fs.remove_dir(root + "/nested") catch {
    _ => ()
  }
  fs.remove_dir(root) catch {
    _ => ()
  }
}

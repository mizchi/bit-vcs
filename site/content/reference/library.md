---
title: Library API
section: reference
slug: library
order: 2
nav_label: Library API
summary: MoonBit types and functions for embedding bit in your own programs — agents, CI runners, editor plugins.
meta: moonbit
kicker: // reference · R2
h1: Library API.
lead: bit is a MoonBit library first, a CLI second. Every CLI command is a thin shell around a public function. Embed bit directly in your agent, editor plugin, or CI runner — no subprocess required.
prev_href: cli.html
prev_kicker: prev · R1
prev_label: CLI commands
next_href: env.html
next_kicker: next · R3
next_label: Environment
---

## Package layout

Source is organized in five layers, dependencies flow downward only.

| Layer | Path | What lives here |
| --- | --- | --- |
| core | `src/core/` | Object types, SHA, ref store primitives. |
| mid  | `src/mid/`  | Index, pack, merge, diff algorithms. |
| high | `src/high/` | Porcelain operations (commit, rebase, …). |
| ext  | `src/ext/`  | Hub, relay, LFS, AI, workspace. |
| cmd  | `src/cmd/`  | CLI entry points. |

## Storage runtime

The entry point for embedding. Any storage that implements `FileSystem` and `RepoFileSystem` can host a repository.

### Traits

```moonbit
pub trait FileSystem {
  write_string(Self, String, String) -> Unit
  write_bytes(Self, String, Bytes) -> Unit
  mkdir_p(Self, String) -> Unit
  remove(Self, String) -> Unit
  rename(Self, String, String) -> Unit
}

pub trait RepoFileSystem {
  read_string(Self, String) -> String?
  read_bytes(Self, String) -> Bytes?
  exists(Self, String) -> Bool
  readdir(Self, String) -> Array[String]
  stat(Self, String) -> FileStat?
}
```

### Entry function

```moonbit
pub fn run_storage_command[F : FileSystem + RepoFileSystem](
  fs   : F,
  rfs  : F,
  root : String,
  cmd  : String,
  args : Array[String]
) -> String
```

### In-memory backend

`TestFs` is the reference implementation. Use it for agents, tests, and ephemeral repos.

```moonbit
let fs = @bit.TestFs::new()
let root = "/agent-repo"

run_storage_command(fs, fs, root, "init", ["-q"])
fs.write_string(root + "/note.txt", "hello, peer")
run_storage_command(fs, fs, root, "add", ["note.txt"])
run_storage_command(fs, fs, root, "commit", ["-m", "agent snapshot"])

let head = run_storage_command(fs, fs, root, "rev-parse", ["HEAD"])
println("head: \{head}")
```

## Fs — virtual filesystem

Mount any commit as a read-only filesystem with lazy blob loading.

```moonbit
let mounted = @bit.Fs::from_commit(fs, ".git", commit_id)
let entries = mounted.readdir(fs, "src")
let content = mounted.read_file(fs, "src/main.mbt")?

for name in entries {
  println("- \{name}")
}
```

| Method | Description |
| --- | --- |
| `Fs::from_commit(fs, gitdir, sha)` | Open a virtual FS rooted at a commit's tree. |
| `Fs::from_tree(fs, gitdir, sha)` | Open from a tree object directly. |
| `readdir(self, fs, path)` | List entries in a directory. |
| `read_file(self, fs, path)` | Read a blob lazily. |
| `stat(self, fs, path)` | Get entry metadata (mode, size). |

## Kv — distributed KV store

Git-backed key/value store with gossip sync. Useful when you want a small, replicated config alongside the repository.

```moonbit
let db = @bit.Kv::init(fs, fs, git_dir, node_id="aurora.local")

db.set(fs, fs, "users/alice/profile", profile_bytes, ts=now())
let value = db.get(fs, fs, "users/alice/profile")?

db.sync_with_peer(fs, fs, "relay://bit.example.com/u/me/kv")
```

## Hub — PR / Issue API

Same data the `bit pr` and `bit issue` CLI commands operate on. Drive PRs from an agent, write a custom triage UI, or wire it into your editor.

```moonbit
let hub = @bit.Hub::init(fs, fs, git_dir)

let pr = hub.create_pr(
  fs, fs,
  title          = "Replace gossip backoff with token bucket",
  body           = "fixes thrashing under high churn",
  source_branch  = "feature/token-bucket",
  target_branch  = "main",
  author         = "ubugeeei",
  ts             = now()
)

hub.review(fs, fs, pr.id, status=Approve, commit=Some(pr.head))?
hub.merge(fs, fs, pr.id)?
```

| Function | Returns |
| --- | --- |
| `Hub::init(fs, rfs, gitdir)` | `Hub` |
| `hub.create_pr(...)` | `Pr` |
| `hub.list_prs(state)` | `Array[Pr]` |
| `hub.review(id, status, commit?)` | `Result[Review, Error]` |
| `hub.merge(id)` | `Result[Sha, Error]` |
| `hub.create_issue(...)` | `Issue` |
| `hub.link(issue_id, pr_id)` | `Unit` |

## Node — peer protocol

Open sessions with other peers, exchange refs, fetch object graphs.

```moonbit
let peer = @bit.Node::from_uri("bit://aurora.local:9418/repo")
peer.handshake(timeout=2.s)?

let local_refs = @bit.refs(fs, ".git")
let wants      = local_refs.diff(peer.refs())
peer.fetch(wants)?

println("now at: \{peer.refs().get(\"refs/heads/main\")}")
```

| Function | Description |
| --- | --- |
| `Node::from_uri(uri)` | Create a peer session (lazy connect). |
| `peer.handshake(timeout?)` | Open the session, exchange capabilities. |
| `peer.refs()` | Snapshot of remote refs. |
| `peer.fetch(wants)` | Download objects reachable from `wants`. |
| `peer.send(bit)` | Push a single object or pack. |
| `peer.close()` | Drop the session. |

<div class="callout">
<p class="kicker">// see also</p>
<p>The <a href="cli.html">CLI Reference</a> documents the same surface, packaged as commands. The mapping is one-to-one: <code>bit pr create</code> ↔ <code>Hub::create_pr</code>, <code>bit fetch</code> ↔ <code>Node::fetch</code>, and so on.</p>
</div>

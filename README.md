# bit

**Git as a library** - A Git implementation in [MoonBit](https://docs.moonbitlang.com) that you can embed, extend, and use programmatically.

## Quick Start

```bash
# Install
curl -fsSL https://raw.githubusercontent.com/mizchi/bit/main/install.sh | bash

# Clone a repository
bit clone @user/repo

# Clone a subdirectory (monorepo friendly)
bit clone @user/repo/packages/core

# Paste GitHub URL directly
bit clone https://github.com/user/repo/tree/main/src/lib
```

## Why bit?

| | Git CLI | bit |
|---|---------|-------------|
| Compatibility | - | ✅ 4,205 tests pass |
| Use as library | ❌ | ✅ Embed in your app |
| Clone subdirectory | ❌ | ✅ `@user/repo/path` |
| Virtual filesystem | ❌ | ✅ Fs API |
| Partial clone | ✅ | ✅ + on-demand fetch |
| Target platforms | Native | Native, WASM, JS |

## GitHub Shorthand

Clone from GitHub using `@user/repo` shorthand or paste browser URLs directly:

```bash
# Full repository
bit clone @mizchi/bit

# Subdirectory only (great for monorepos)
bit clone @mizchi/bit/src/x/fs
bit clone @mizchi/bit/src/x/fs ./my-local-dir

# GitHub browser URL - just copy & paste
bit clone https://github.com/user/repo/tree/main/packages/core

# Single file download (/blob/ URL)
bit clone https://github.com/user/repo/blob/main/README.md
```

The `@` prefix distinguishes GitHub shorthand from local paths.

## Full Git Compatibility

All standard Git operations work:

```bash
bit init
bit clone https://github.com/user/repo
bit checkout -b feature
bit add .
bit commit -m "changes"
bit push origin feature
```

**Supported commands**: `init`, `clone`, `status`, `add`, `commit`, `log`, `show`, `diff`, `branch`, `checkout`, `switch`, `merge`, `rebase`, `reset`, `cherry-pick`, `remote`, `fetch`, `pull`, `push`, `pack-objects`, `index-pack`, `cat-file`, `ls-files`, `ls-tree`, `rev-parse`, and more.

## Use as Library

```bash
moon add mizchi/bit
```

```moonbit
// Mount repository as virtual filesystem
let fs = Fs::from_commit(fs, ".git", commit_id)

// Browse without checkout (instant)
let files = fs.readdir(fs, "src")

// Read file (fetches on-demand if partial clone)
let content = fs.read_file(fs, "src/main.mbt")
```

## Partial Clone

```bash
# Clone metadata only (~100KB vs full clone)
bit clone --filter=blob:none https://github.com/user/large-repo
```

```moonbit
// Prefetch files matching pattern
fs.prefetch_glob(fs, fs, "src/**/*.mbt")

// Or prefetch in breadth-first order
fs.prefetch_bfs(fs, fs, limit=50)
```

## Build from Source

```bash
moon build --target native
just install  # installs to ~/.local/bin/bit
```

## Test Coverage

**4,205 tests pass** from Git's official test suite.

```bash
just test             # Unit tests
just git-t-allowlist  # Git compatibility tests
```

## Extensions (src/x/)

Experimental features built on the core Git implementation.

| Extension | Description |
|-----------|-------------|
| **Fs** | Virtual filesystem - mount any commit, lazy blob loading |
| **Subdir** | Work with subdirectories as independent repos |
| **Collab** | Git-native PR/Issues (WIP) |
| **Kv** | Distributed KV store with Gossip sync (WIP) |

## Architecture

```
┌─────────────────────────────────────────────────┐
│  Your Application                               │
├─────────────────────────────────────────────────┤
│  Fs (Virtual Filesystem)                        │
│  - Mount any commit as filesystem               │
│  - Lazy blob loading / Prefetch APIs            │
├─────────────────────────────────────────────────┤
│  PromisorDb (On-demand Fetch)                   │
│  - Partial clone support                        │
├─────────────────────────────────────────────────┤
│  ObjectDb (Object Database)                     │
│  - Pack/loose object access                     │
├─────────────────────────────────────────────────┤
│  Git Protocol v1/v2                             │
│  - Smart HTTP transport                         │
└─────────────────────────────────────────────────┘
```

## License

Apache-2.0

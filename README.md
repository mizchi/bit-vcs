# moonbit-git

A Git implementation in [MoonBit](https://docs.moonbitlang.com), focusing on packfile operations and protocol support.

## Features

### Core Git Operations
- **Packfile**: Create, parse, and verify Git packfiles with REF_DELTA and OFS_DELTA support
- **Pack Index**: Generate `.idx` files compatible with Git
- **Object Database**: Read/write loose objects and packed objects
- **SHA-1**: Pure MoonBit SHA-1 implementation

### Git Commands
A pure MoonBit implementation of Git commands, passing the official Git test suite:

**Core Operations**: `init`, `clone`, `status`, `add`, `commit`, `log`, `show`, `diff`

**Branch Operations**: `branch`, `checkout`, `switch`, `merge`, `rebase`, `reset`, `cherry-pick`

**Remote Operations**: `remote`, `fetch`, `pull`, `push`, `clone`

**Plumbing**: `pack-objects`, `index-pack`, `receive-pack`, `upload-pack`, `cat-file`, `hash-object`, `ls-files`, `ls-tree`, `rev-parse`, `rev-list`, `show-ref`, `symbolic-ref`, `update-ref`, `write-tree`, `verify-pack`, `unpack-objects`, `bundle`, `config`, `reflog`, `read-tree`, `update-index`, `mktree`, `send-pack`, `request-pull`, `range-diff`, `multi-pack-index`

**Other**: `tag`, `stash`, `worktree`, `rm`, `mv`, `grep`, `blame`, `describe`, `bisect`, `notes`, `format-patch`, `shortlog`, `gc`, `clean`, `revert`, `sparse-checkout`, `submodule`, `cherry`

### Protocol Support
- Git protocol v1/v2
- Smart HTTP transport
- Pkt-line encoding/decoding
- `.gitignore` parsing

## Project Structure

```
src/
├── packfile.mbt          # Packfile creation with delta compression
├── packfile_parse.mbt    # Packfile parsing
├── pack_index_write.mbt  # Pack index generation
├── object.mbt            # Git object types (blob, tree, commit, tag)
├── sha1.mbt              # SHA-1 implementation
├── pktline.mbt           # Pkt-line protocol
├── remote.mbt            # Remote operations
├── upload_pack_*.mbt     # Upload-pack implementation
├── lib/                  # High-level Git operations
│   ├── receive_pack.mbt  # Receive-pack implementation
│   ├── smart_http.mbt    # Smart HTTP helpers
│   ├── object_db.mbt     # Object database
│   └── ...
└── cmd/
    └── moongit/          # Native git command interceptor
        ├── main.mbt
        ├── pack_objects.mbt
        ├── index_pack.mbt
        └── pack_helpers.mbt
```

## Quick Commands

```bash
just              # check + test
just fmt          # format code
just check        # type check (js + native)
just test         # run tests (js + native)
just release-check # fmt + info + check + test
```

## Moongit

`moongit` is a native binary that intercepts specific Git commands and handles them in MoonBit:

```bash
# Build moongit
moon build --target native

# Copy to tools directory
cp _build/native/release/build/cmd/moongit/moongit.exe tools/git-shim/moon

# Or install to ~/.local/bin
just install
```

### Key Features

- **No fallback to system git** - Pure MoonBit implementation
- **Full protocol support** - Git protocol v1/v2, Smart HTTP transport
- **Packfile operations** - REF_DELTA and OFS_DELTA compression
- **Configuration** - `pack.packSizeLimit` for splitting large packs

## Testing

### Unit Tests
```bash
just test  # Runs 260 tests (116 js + 144 native)
```

### Git Upstream Test Suite Compatibility

The implementation passes Git's official test suite with pure MoonBit (no fallback to system git):

```bash
cd third_party/git/t
SHIM_CMDS="init config ls-files ..." bash t0001-init.sh
```

| Test File | Tests | Status |
|-----------|-------|--------|
| t0001-init.sh | 102 | ✅ All pass |
| t1300-config.sh | 485 | ✅ All pass |
| t1400-update-ref.sh | 313 | ✅ All pass |
| t1500-rev-parse.sh | 81 | ✅ All pass |
| t2400-worktree-add.sh | 232 | ✅ All pass |
| t2401-worktree-prune.sh | 13 | ✅ All pass |
| t2402-worktree-list.sh | 27 | ✅ All pass |
| t3000-ls-files-others.sh | 15 | ✅ All pass |
| t3200-branch.sh | 167 | ✅ All pass |
| t3903-stash.sh | 140 | ✅ All pass |
| t5500-fetch-pack.sh | 377 | ✅ All pass |
| t5510-fetch.sh | 215 | ✅ All pass |
| t5601-clone.sh | 115 | ✅ All pass |
| t7004-tag.sh | 231 | ✅ All pass |
| t7600-merge.sh | 83 | ✅ All pass |
| t4150-am.sh | 87 | ✅ All pass |
| t4100-apply-stat.sh | 19 | ✅ All pass |
| t1450-fsck.sh | 95 | ✅ All pass |
| t5304-prune.sh | 32 | ✅ All pass |
| t0601-reffiles-pack-refs.sh | 47 | ✅ All pass |
| t7700-repack.sh | 47 | ✅ All pass |
| t7900-maintenance.sh | 72 | ✅ All pass |
| t6000-rev-list-misc.sh | 22 | ✅ All pass |
| t6005-rev-list-count.sh | 6 | ✅ All pass |
| t6009-rev-list-parent.sh | 15 | ✅ All pass |
| t6014-rev-list-all.sh | 4 | ✅ All pass |
| t6017-rev-list-stdin.sh | 37 | ✅ All pass |
| t6020-bundle-misc.sh | 37 | ✅ All pass |

**3,000+ tests pass** across core Git operations.

### Oracle Testing

Native tests use Git as an oracle to verify correctness:
- Blob/Tree/Commit hash comparison with `git hash-object`
- Packfile verification with `git verify-pack` and `git unpack-objects`
- Tree format compatibility with `git write-tree`
- Protocol compatibility with `git cat-file`, `git diff-tree`, `git ls-files`

## Current Limitations

- SHA256 object format: Not supported (errors on SHA256 repos)
- SHA1 collision detection: Not implemented
- Some advanced options (e.g., `--stdin-packs`, `--filter`, `--threads`)

## Roadmap: Not Yet Implemented

The following Git commands are not yet implemented in moongit:

**Patch/Email Workflow**
- `send-email` - Send patches as emails
- `format-patch` - Prepare patches for email (partial)
- `mailinfo`, `mailsplit` - Email parsing utilities

**Advanced Operations**
- `archive` - Create archive of files
- `fast-export`, `fast-import` - Stream-based import/export
- `filter-branch` - Rewrite branch history
- `replace` - Replace objects

**Plumbing Commands**
- `name-rev` - Find symbolic names for revs
- `var` - Show Git logical variables

**Interactive/UI**
- `add -i/-p` - Interactive staging
- `rebase -i` - Interactive rebase
- `mergetool`, `difftool` - External tool integration
- `gui`, `citool` - Graphical interfaces

**Collaboration**
- `imap-send` - Send patches via IMAP
- `credential` - Credential helpers

**Other**
- `rerere` - Reuse recorded resolution
- `show-branch` - Show branches and commits
- `whatchanged` - Show commit logs with diff

## License

Apache-2.0

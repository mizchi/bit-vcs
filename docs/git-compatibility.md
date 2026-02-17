# Git Compatibility Details

This document tracks detailed Git compatibility behavior for `bit`, including standalone coverage (`--no-git-fallback`), explicitly unsupported paths, fallback boundaries, and git/t validation snapshots.

## Standalone Test Coverage (Current)

Standalone coverage is validated with `git_cmd` in `t/test-lib-e2e.sh`, which runs `bit --no-git-fallback ...` (no real-git dependency in these tests).

Current standalone integration coverage (`t/t0001-*.sh` to `t/t0021-*.sh`) includes:

- repository lifecycle and core porcelain: `init`, `status`, `add`, `commit`, `branch`, `checkout`/`switch`, `reset`, `log`, `tag`
- transport-style workflows in standalone mode: `clone`, `fetch`, `pull`, `push`, `bundle`
- plumbing used by normal flows: `hash-object`, `cat-file`, `ls-files`, `ls-tree`, `write-tree`, `update-ref`, `fsck`
- feature flows: `hub`, `rebase-ai`, `mcp`, `hq`
- randomized parity smoke coverage: `t0011-random-ops.sh` (seeds 1, 2, 3; 25 operations each; compares git vs bit repo shape and status)

Representative files:

- `t/t0001-init.sh`
- `t/t0003-plumbing.sh`
- `t/t0005-fallback.sh`
- `t/t0018-commit-workflow.sh`
- `t/t0019-clone-local.sh`
- `t/t0020-push-fetch-pull.sh`
- `t/t0021-hq-get.sh`

## Randomized Compatibility Verification

2026-02-17

- `t/t0011-random-ops.sh` was executed and passed for seeds `1`, `2`, and `3` with `25` operations each.
  - Covered operations set: `init`, `commit-new`, `commit-mod`, `commit-rm`, `branch`, `switch`, `merge`.
  - Verification checks:
    - `git fsck --strict` (both repos)
    - matching branch refs
    - matching `rev-parse <branch>^{tree}`
    - both repos clean (`status --porcelain` empty)
- `t/t0012-random-maintenance.sh` was added and executed with seeds `101`, `202`, and `303` with `35` operations each.
  - Covered operations set: `init`, `commit-new`, `commit-mod`, `commit-rm`, `branch`, `switch`, `merge`, `status`, `gc`, `repack`.
  - Verification checks:
    - `git fsck --strict` (both repos)
    - matching branch refs
    - matching `rev-parse <branch>^{tree}`
    - both repos clean (`status --porcelain` empty)
- `t/t0013-random-pack.sh` was added and executed with seeds `1001` and `1002` with `40` operations each.
  - Covered operations set: `init`, `commit-new`, `commit-mod`, `commit-rm`, `branch`, `switch`, `merge`, `pack-objects`, `repack`, `gc`, `index-pack`, `status`.
  - Verification checks:
    - `git fsck --strict` (both repos)
    - matching branch refs
    - matching `rev-parse <branch>^{tree}`
    - both repos clean (`status --porcelain` empty)
- `t/t0014-random-rebase.sh` was added and executed with seeds `501` and `502` with `50` operations each.
  - Covered operations set: `init`, `commit-new`, `commit-mod`, `commit-rm`, `branch`, `switch`, `rebase`, `status`, `tag`.
  - Verification checks:
    - `git fsck --strict` (both repos)
    - matching branch refs
    - matching `rev-parse <branch>^{tree}`
    - both repos clean (`status --porcelain` empty)
- `t/t0015-random-midx.sh` was added and executed with seeds `701` and `702` with `60` operations each.
  - Covered operations set: `init`, `commit-new`, `commit-mod`, `commit-rm`, `branch`, `switch`, `rebase`, `status`, `repack`, `multi-pack-index write` (including `--bitmap`), `multi-pack-index verify`, `multi-pack-index expire`.
  - Verification checks:
    - `git fsck --strict` (both repos)
    - matching branch refs
    - matching `rev-parse <branch>^{tree}`
    - both repos clean (`status --porcelain` empty)
    - if git-side multi-pack-index exists, bit-side multi-pack-index exists
- `t/t0016-random-add-pack.sh` was added and executed with seeds `801`, `802`, `803`, and `804` with `55` operations each.
  - Covered operations set: `init`, `commit-new`, `commit-mod`, `commit-rm`, `branch`, `switch`, `add`, `add .`, `add -A`, `add --refresh`, `status`, `pack-objects`, `index-pack`, `gc`, `repack`.
  - Verification checks:
    - `git fsck --strict` (both repos)
    - matching branch refs
    - matching `rev-parse <branch>^{tree}`
    - both repos clean (`status --porcelain` empty)
- `t/t0020-random-reset-mv.sh` was added and executed with seeds `901`, `902`, `903`, and `904` with `45` operations each, and extended with seeds `905`, `906` with `70` operations each.
  - Covered operations set: `init`, `commit-new`, `commit-mod`, `commit-rm`, `branch`, `switch`, `mv`, `rm`, `rm --cached`, `reset --soft`, `reset --mixed`, `reset --hard`, `status`, `pack-objects`, `index-pack`, `repack`, `gc`.
  - Verification checks:
    - `git fsck --strict` (both repos)
    - matching branch refs
    - matching `rev-parse <branch>^{tree}`
    - matching `status --porcelain` output

## Explicitly Unsupported In Standalone Mode

The following are intentionally rejected with explicit standalone-mode errors (covered by `t/t0005-fallback.sh` and command-level checks):

- signed commit modes (`commit -S`, `commit --gpg-sign`)
- interactive rebase (`rebase -i`)
- reftable-specific paths (`clone --ref-format=reftable`, `update-ref` on reftable repo)
- cloning from local bundle file (`clone <bundle-file>`)
- SHA-256 object-format compatibility paths (`hash-object -w` with `compatObjectFormat=sha256`, `write-tree` on non-sha1 repo)
- `cat-file --batch-all-objects` with `%(objectsize:disk)`
- unsupported option sets for `index-pack` and `pack-objects`

## Where Git Fallback Exists

- Main `bit` command dispatch in `src/cmd/bit/main.mbt` does not auto-delegate unknown commands to system git.
- Git fallback/delegation is implemented in the shim layer `tools/git-shim/bin/git`.
  - The shim delegates to `SHIM_REAL_GIT` by default.
  - CI `git-compat` (`.github/workflows/ci.yml`) runs upstream `git/t` via this shim (`SHIM_REAL_GIT`, `SHIM_MOON`, `SHIM_CMDS`).

## Git Test Suite (git/t)

706 test files from the official Git test suite are in the allowlist.

Allowlist run (`just git-t-allowlist-shim-strict`) on macOS:

| | Count |
|---|---|
| success | 24,279 |
| failed | 0 |
| broken (prereq skip) | 177 |
| total | 24,858 |

177 broken tests are skipped due to missing prerequisites, not failures:

| Category | Prereqs | Skips | Notes |
|---|---|---|---|
| Platform | MINGW, WINDOWS, NATIVE_CRLF, SYMLINKS_WINDOWS | ~72 | Windows-only tests |
| GPG signing | GPG, GPG2, GPGSM, RFC1991 | ~127 | `brew install gnupg` to enable |
| Terminal | TTY | ~33 | Requires interactive terminal |
| Build config | EXPENSIVE, BIT_SHA256, PCRE, HTTP2, SANITIZE_LEAK, RUNTIME_PREFIX | ~30 | Optional build/test flags |
| Filesystem | SETFACL, LONG_REF, TAR_HUGE, TAR_NEEDS_PAX_FALLBACK | ~10 | Platform-specific capabilities |
| Negative prereqs | !AUTOIDENT, !CASE_INSENSITIVE_FS, !LONG_IS_64BIT, !PTHREADS, !SYMLINKS | ~7 | Tests requiring feature absence |

5 test files are excluded from the allowlist:

- `t5310` (bitmap)
- `t5316` (delta depth)
- `t5317` (filter-objects)
- `t5332` (multi-pack reuse)
- `t5400` (send-pack)

Full upstream run (`just git-t`) summary on macOS (2026-02-07):

| | Count |
|---|---|
| success | 31,832 |
| failed | 0 |
| broken (known breakage / prereq skip) | 397 |
| total | 33,046 |

## Local Test Snapshot (2026-02-12)

- `just check`: pass
- `just test`: pass (`js/lib 215 pass`, `native 811 pass`)
- `just e2e` (`t/run-tests.sh t00`): pass
- `just test-subdir` (`t/run-tests.sh t900`): pass
- `just git-t-allowlist`: pass (`success 24,279 / failed 0 / broken 177`)

## Performance Snapshot (2026-02-12)

| Operation | Time |
|---|---|
| checkout 100 files | 37.25 ms |
| commit 100 files | 9.86 ms |
| create_packfile 100 | 6.62 ms |
| create_packfile_with_delta 100 | 10.03 ms |
| add_paths 100 files | 7.42 ms |
| status clean (small) | 2.38 ms |

## Related Distributed/Agent Tests

- `just test-distributed`: focused checks for `x/agent`, `x/hub`, `x/kv`
- strategy and invariants: `docs/distributed-testing.md`

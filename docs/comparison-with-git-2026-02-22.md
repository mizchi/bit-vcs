# Git vs Bit Performance Comparison (2026-02-22)

Repository: expressjs/express (full clone)

## Before lstat optimization

| Scenario | git | bit | Result |
|----------|-----|-----|--------|
| clone (full) | 1.810s | 16.849s | git 9.3x faster |
| add (100 files) | 0.111s | 0.680s | git 6.1x faster |
| add (1000 files) | 0.549s | 1.109s | git 2.0x faster |
| commit (1000 files) | 0.159s | 0.500s | git 3.1x faster |
| status (clean) | 0.046s | 0.236s | git 5.1x faster |
| status (500 modified) | 0.052s | 0.226s | git 4.3x faster |
| diff --stat (500 files) | 0.111s | 0.310s | git 2.8x faster |
| checkout . (restore) | 0.149s | 0.040s | bit 3.7x faster |
| checkout -b | 0.053s | 1.151s | git 21.7x faster |
| log --oneline -10 | 0.048s | 0.114s | git 2.4x faster |

## After lstat optimization

| Scenario | git | bit | Result |
|----------|-----|-----|--------|
| clone (full) | 1.350s | 13.442s | git 10.0x faster |
| add (100 files) | 0.066s | 0.257s | git 3.9x faster |
| add (1000 files) | 0.372s | 0.443s | git 1.2x faster |
| commit (1000 files) | 0.059s | 0.340s | git 5.8x faster |
| status (clean) | 0.025s | 0.064s | git 2.6x faster |
| status (500 modified) | 0.026s | 0.065s | git 2.5x faster |
| diff --stat (500 files) | 0.064s | 0.069s | git 1.1x faster |
| checkout . (restore) | 0.079s | 0.020s | bit 4.0x faster |
| checkout -b | 0.024s | 0.784s | git 32.7x faster |
| log --oneline -10 | 0.024s | 0.104s | git 4.3x faster |

## After all optimizations (lstat + checkout-b + commit + log)

| Scenario | git | bit | Result |
|----------|-----|-----|--------|
| clone (full) | 1.438s | 12.836s | git 8.9x faster |
| add (100 files) | 0.066s | 0.254s | git 3.8x faster |
| add (1000 files) | 0.367s | 0.405s | git 1.1x faster |
| commit (1000 files) | 0.061s | 0.101s | git 1.7x faster |
| status (clean) | 0.027s | 0.065s | git 2.4x faster |
| status (500 modified) | 0.026s | 0.064s | git 2.5x faster |
| diff --stat (500 files) | 0.068s | 0.068s | equal |
| checkout . (restore) | 0.080s | 0.020s | bit 4.0x faster |
| checkout -b | 0.023s | 0.021s | bit 1.1x faster |
| log --oneline -10 | 0.023s | 0.064s | git 2.8x faster |

## Improvement summary

| Scenario | Before | After all | Change |
|----------|--------|-----------|--------|
| checkout -b | git 21.7x faster | bit 1.1x faster | **reversed** |
| diff --stat | git 2.8x faster | equal | **closed** |
| status (clean) | git 5.1x faster | git 2.4x faster | 2.1x improvement |
| status (500 modified) | git 4.3x faster | git 2.5x faster | 1.7x improvement |
| commit (1000 files) | git 3.1x faster | git 1.7x faster | 1.8x improvement |
| add (1000 files) | git 2.0x faster | git 1.1x faster | nearly equal |
| log --oneline -10 | git 2.4x faster | git 2.8x faster | no change |

## Status Benchmark (bit internal, moon bench)

| Scenario | Before | After | Speedup |
|----------|--------|-------|---------|
| clean 100 files | 3.69 ms | 2.63 ms | 1.40x |
| clean 1000 files | 32.52 ms | 20.26 ms | 1.61x |
| clean 5000 files | 173.22 ms | 97.10 ms | 1.78x |
| dirty 100/100 files | 3.69 ms | 2.74 ms | 1.35x |
| dirty 500/1000 files | 34.61 ms | 20.53 ms | 1.69x |
| dirty 2500/5000 files | 181.61 ms | 100.33 ms | 1.81x |

## What changed

### 1. lstat optimization (status, diff, add)

Replaced multi-syscall `worktree_entry_meta` with single `lstat()` C FFI call.

Before (7 syscalls per file):
1. `readlink()` - symlink check
2. `is_file()` - stat
3. `access()` - executable check
4. `open()` - open file
5. `fstat()` - get size
6. `fstat()` - get mtime
7. `close()` - close file

After (1 syscall per file):
1. `lstat()` - file type, mode, size, mtime all at once

Files: `src/io/native/worktree_probe_native.mbt`, `src/io/native/lstat_stub.c`

### 2. checkout -b optimization

Skip full tree checkout when creating a branch on the same commit.
Pass `checkout_files=false` to `switch_branch` when no start-point is given.

File: `src/cmd/bit/checkout.mbt`

### 3. commit + log lazy ObjectDb

Replace eager `ObjectDb::load()` with `ObjectDb::load_lazy()` to avoid scanning
all loose objects and parsing all pack indexes upfront.

For commit, also pass `missing_ok=true` to `write_tree_from_index` to skip
per-blob existence checks.

Files: `src/lib/log.mbt`, `src/lib/worktree.mbt`

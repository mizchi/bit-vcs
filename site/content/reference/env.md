---
title: Environment
section: reference
slug: env
order: 3
nav_label: Environment
summary: Every `BIT_*` variable bit reads, and the Git-compat variables it honors (`GIT_EDITOR`, `GIT_CONFIG_GLOBAL`, …).
meta: 12 vars
kicker: // reference · R3
h1: Environment variables.
lead: Every `BIT_*` variable bit reads, plus the Git-compat variables it honors. Set them in your shell rc, in `.envrc`, or per-command.
prev_href: library.html
prev_kicker: prev · R2
prev_label: Library API
next_href: ../
next_kicker: end
next_label: Back to home
---

## bit-native

| Variable | Default | Effect |
| --- | --- | --- |
| `BIT_BENCH_GIT_DIR` | — | Override `.git` path for `bench_real` (vfs benchmarks). |
| `BIT_PACK_CACHE_LIMIT` | `2` | Max packfiles kept in memory. `0` disables the cache. |
| `BIT_RACY_GIT` | unset | When set, rehash even if `stat` matches — avoids racy-git false negatives on fast filesystems. |
| `BIT_WORKSPACE_FINGERPRINT_MODE` | `git` | `git` for add-all-style snapshots, `fast` for per-node directory hashes. |
| `BIT_HUB_INIT_PROMPT` | `1` (interactive) | Force-on (`1`) or force-off (`0`) the `bit pr init` / `bit issue init` prompts. |

## Git-compat

bit honors the standard Git environment so existing tooling, hooks, and editors keep working.

| Variable | Effect |
| --- | --- |
| `GIT_DIR` | Override the location of the repository's `.git` directory. |
| `GIT_WORK_TREE` | Override the working tree root. |
| `GIT_CONFIG_GLOBAL` | Path to global config (default `~/.gitconfig`). |
| `GIT_EDITOR` | Editor used for commit messages, rebase conflict markers. |
| `GIT_SEQUENCE_EDITOR` | Editor used for the rebase todo list. |
| `GIT_AUTHOR_NAME` / `GIT_AUTHOR_EMAIL` | Override commit author identity. |
| `GIT_COMMITTER_NAME` / `GIT_COMMITTER_EMAIL` | Override committer identity. |

## AI assist

| Variable | Effect |
| --- | --- |
| `OPENROUTER_API_KEY` | Required for any `bit ai *` subcommand. |

<div class="callout callout--acid">
<p class="kicker">// note</p>
<p>bit never reads secrets from the repository — keys live only in the environment. If you set <code>OPENROUTER_API_KEY</code> via <code>.envrc</code>, make sure that file is git-ignored.</p>
</div>

---
title: CLI commands
section: reference
slug: cli
order: 1
nav_label: CLI commands
summary: Every subcommand grouped by surface — porcelain, plumbing, hub, relay, extensions, AI. Flags, exit codes, examples.
meta: 108 commands
kicker: // reference · R1
h1: CLI commands.
lead: bit implements 108 Git commands natively. Anything not listed here falls back to Git's surface — read [going distributed](../learn/distributed.html) for the protocol-level differences.
prev_href: ./
prev_kicker: back
prev_label: Reference
next_href: library.html
next_kicker: next · R2
next_label: Library API
---

## Porcelain

Everyday commands. Identical surface to Git.

| Command | Description |
| --- | --- |
| `bit init` | Create an empty `.git/` in the current directory. |
| `bit clone <url>` | Clone over HTTP, relay, or a subdirectory URL (see extensions). |
| `bit add <path>…` | Stage files. Supports `-A`, `-p`, `--update`. |
| `bit commit -m <msg>` | Record staged changes. `--amend`, `--no-edit`, `--allow-empty`. |
| `bit status` | Working tree state in Git's exact line format. |
| `bit log` | Native graph renderer. `--graph`, `--stat`, `--name-only`, `--topo-order`. |
| `bit diff` | Worktree vs index, or any two trees / commits. |
| `bit checkout` | Switch branches, restore files. `-b` creates. |
| `bit branch` | List, create, delete branches. |
| `bit merge` | Three-way merge with conflict markers. |
| `bit rebase` | Native `-i` with editor injection. |
| `bit cherry-pick <sha>` | Apply commits onto HEAD. |
| `bit revert <sha>` | Reverse a commit. |
| `bit fetch` | Download refs and objects from a remote. |
| `bit pull` | Fetch and merge / rebase. |
| `bit push` | Upload refs and objects. HTTPS, relay, LFS upload. |
| `bit remote` | Manage remotes. |
| `bit tag` | Lightweight and annotated tags. |
| `bit stash` | Shelve worktree state. |
| `bit reset` | `--soft`, `--mixed`, `--hard`. |

## Plumbing

Low-level operations on Git objects. Same surface as Git's plumbing.

| Command | Description |
| --- | --- |
| `bit hash-object` | Compute the SHA-1 of a file (optionally write to objects). |
| `bit cat-file` | Print object type, size, or contents. |
| `bit rev-parse` | Resolve refs and revisions to SHAs. |
| `bit ls-tree` | List tree contents. |
| `bit ls-files` | List files in the index. |
| `bit update-ref` | Move a ref atomically. |
| `bit pack-objects` | Build a packfile. |
| `bit unpack-objects` | Explode a packfile into loose objects. |
| `bit symbolic-ref` | Read or write a symbolic ref like `HEAD`. |

## Hub — PRs and issues

Local, server-less collaboration backed by Git objects. Sync via relay.

| Command | Description |
| --- | --- |
| `bit pr init` | Initialize hub metadata in the current repo (writes `.git/hub/policy.toml`). |
| `bit pr create` | `--title`, `--body`, `--head`, `--base`. Opens a local PR. |
| `bit pr list` | `--open`, `--closed`, `--all`. |
| `bit pr review <id>` | `--approve`, `--request-changes`, `--commit <sha>`. |
| `bit pr merge <id>` | Merge into base. Honors policy. |
| `bit pr search <q>` | Full-text over PR titles and bodies. |
| `bit issue create` | `--title`, `--body`, `--parent <id>`. |
| `bit issue list` | `--open`, `--tree`, `--all`, `--parent`. |
| `bit issue link <issue> <pr>` | Cross-link issue ↔ PR. |
| `bit issue search <q>` | Full-text over issues. |

## Relay

Sync PR and issue metadata between peers via an HTTP relay.

| Command | Description |
| --- | --- |
| `bit relay sync push <url>` | Upload hub notes to a relay. |
| `bit relay sync fetch <url>` | Download hub notes from a relay. |
| `bit relay serve` | Run a relay host locally. Supports LFS Batch API. |

## Extensions

| Command | Description |
| --- | --- |
| `bit subdir-clone <url> <path> <dst>` | Clone a subdirectory as an independent repo. |
| `bit clone user/repo:path` | Shorthand for subdir-clone via the standard clone command. |
| `bit hq get <user/repo>` | `ghq`-compatible repo manager. Default root: `~/bhq`. |
| `bit hq list` | List all repos under hq. |
| `bit workspace flow <task>` | Workspace fingerprint-based task runner. |
| `bit fingerprint` | Workspace / PR fingerprint helpers. |
| `bit completion <shell>` | Emit shell completion script. `bash` or `zsh`. |

## AI assist

AI-assisted conflict resolution via OpenRouter. Default model: `moonshotai/kimi-k2`. Requires `OPENROUTER_API_KEY`.

| Command | Description |
| --- | --- |
| `bit ai rebase <base>` | Rebase with AI resolving conflicts. `--continue`, `--abort`, `--skip`. |
| `bit ai merge <branch>` | Merge with AI assist. |
| `bit ai commit` | AI commit message (`--split` for multi-commit suggestion). |
| `bit ai cherry-pick <sha>` | Cherry-pick with AI conflict resolution. |
| `bit ai revert <sha>` | Revert with AI. |

### Common AI flags

- `--model <id>` — override the OpenRouter model.
- `--max-ai-rounds <n>` — bound conflict-resolution turns.
- `--agent-loop` — give the AI an agent loop, not single-shot.
- `--agent-max-steps <n>` — bound the agent loop.

<div class="callout">
<p class="kicker">// see also</p>
<p>The <a href="library.html">Library API</a> exposes the same surface to MoonBit code — drive any of the above from an agent without spawning a process.</p>
</div>

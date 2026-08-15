---
title: Concept
section: learn
slug: concept
order: 0
nav_label: Concept
summary: What bit is, what is interesting about it, and the five-concept mental model that makes everything else fall into place.
meta: ~7 min
kicker: // guide · 00 — the idea
h1: What bit is.
lead: bit is a Git implementation in MoonBit. It speaks the Git wire protocol, it produces a normal `.git/`, and any Git client can read what it writes. Underneath, bit treats distribution as the default — not a feature bolted onto a central server, but the entire premise.
prev_href: ./
prev_kicker: back
prev_label: Learning Guide
next_href: install.html
next_kicker: next · 01
next_label: Install bit
---

## What's interesting

Three things distinguish bit from "yet another Git client."

**PRs and issues live inside the repo.** Pull requests, reviews, and issues are written as Git objects under `refs/notes/bit-hub`. Replicate the repo and you replicate the work. GitHub can go away. Your project history — and the conversations around it — survive intact.

**bit is a library before it is a tool.** Every CLI command is a thin shell over a MoonBit function. Drop bit into an agent, an editor plugin, or a CI runner — you do not shell out, you call it. Mount an in-memory filesystem and you have a working repository in five lines.

**Convergence is gossip, not consensus.** Peers reconcile by walking object graphs until they meet a common ancestor. No election, no quorum, no leader. A laptop offline for a week catches up the moment it touches a peer.

## A five-concept mental model

These five words carry the whole system. If you have them straight, the CLI and the library both stop surprising you.

### Node

A node is any process holding a copy of the repository. Your laptop is a node. A CI runner is a node. A relay host is a node. Nodes are symmetric — there is no "primary" — and they are addressed by URI:

```text
bit://aurora.local:9418/repo
relay://bit.example.com/u/mizchi/bit
https://github.com/mizchi/bit.git
```

### Source

Source is whoever wrote the commit you are looking at. It is a fact, not a place. The pink dot in the bit logo represents the source node; in any given moment, *any* node can become it.

```moonbit
let commit = @bit.head(fs, ".git")?
println("author: \{commit.author}")
println("source: \{commit.committer.tz}@\{commit.committer.email}")
```

### Bit

A bit is a single edge between two peers — one unit of exchange. Communication is content-addressed: peers ask for object hashes, never filenames. The protocol is therefore naturally idempotent and naturally deduplicating.

### Convergence

Two peers handshake, exchange ref tips, and walk the graph backwards until they meet. Bytes flow in both directions. Disagreement persists as parallel heads until a human merges them. There is no server-side reconciliation step. There is no server.

### Hub

PRs and issues are stored as Git objects. The hub is not a service — it is a particular shape of commit graph. `bit pr create` writes objects. `bit relay sync push` replicates them. The hub survives forks because it has no "outside" to survive against.

## What follows from this

Implications you can feel as soon as you start using it.

- The hub survives forks. Fork a repo, get every PR and issue with it.
- Agents drive bit without a shell. The same MoonBit functions the CLI calls, your agent can call directly.
- You can clone a single subdirectory of a 50 GB monorepo with `bit clone user/repo:src/lib`.
- A merge conflict resolved by AI is just commits plus a note — no third-party state, no external dashboard.
- You can write your own bit-aware tool in MoonBit in an afternoon. The library API is the surface.

## What bit is not

Equally important — bit refuses several adjacent identities.

- **Not a Git replacement.** It *is* Git. The bytes on disk are valid Git, the wire protocol is Git's, the SHA-1 history is interchangeable. Use it next to vanilla `git` if you want.
- **Not a blockchain.** No consensus, no tokens, no proof-of-anything. Convergence is gossip.
- **Not a P2P file share.** bit is collaboration software that happens to be distributed. The unit of meaning is a commit, not a file.
- **Not an LLM agent.** AI assist is one optional command (`bit ai rebase`), not the architecture.

## What's next

Now that you have the model, the rest of the guide is mostly muscle memory.

- Read [Install bit](install.html) and get the binary on PATH.
- Walk through [Your first commit](first-commit.html) for the porcelain refresher.
- Hit [Going distributed](distributed.html) to see two peers converge.

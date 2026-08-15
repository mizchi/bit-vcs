---
title: Going distributed
section: learn
slug: distributed
order: 3
nav_label: Going distributed
summary: Clone over HTTP and over a bit relay. Push, fetch, and watch gossip converge two peers.
meta: ~10 min
kicker: // guide · 03
h1: Going distributed.
lead: bit was built on the premise that source control should not depend on a central host. In this chapter you will clone a repository over HTTP and over a bit *relay*, push commits in both directions, and watch two peers converge through gossip.
prev_href: first-commit.html
prev_kicker: prev · 02
prev_label: Your first commit
next_href: hub.html
next_kicker: next · 04
next_label: PRs & issues
---

## Mental model

A bit **node** is any process holding a copy of the repository. Your laptop, a CI runner, a relay host — all peers, no master. Two peers reconcile by exchanging ref tips and walking the object graph until they meet a common ancestor.

| Mode | Trigger | Direction |
| --- | --- | --- |
| push | explicit | local → remote |
| fetch | explicit | remote → local |
| gossip | periodic, on handshake | both |
| relay sync | via relay host | both, async |

## Clone over HTTP

This is the standard Git path. bit speaks `git-upload-pack` and `git-receive-pack` over smart HTTP.

```bash
$ bit clone https://github.com/user/repo
$ cd repo
$ bit remote -v
origin  https://github.com/user/repo (fetch)
origin  https://github.com/user/repo (push)
```

## Clone over a relay

A *relay* is a lightweight bit-aware host. It speaks the bit protocol over HTTP and supports async sync — useful when peers are not online at the same time.

```bash
$ bit clone relay://bit.example.com/u/me/repo
$ cd repo
```

## Two peers, one truth

Open two terminals. In the first, simulate node A:

```bash
$ bit clone relay://bit.example.com/u/me/repo a
$ cd a
$ echo "from A" >> note.txt
$ bit add . && bit commit -m "A writes"
$ bit push origin main
```

In the second terminal, node B:

```bash
$ bit clone relay://bit.example.com/u/me/repo b
$ cd b
$ bit fetch origin
$ bit log --oneline
a8c2f6e (origin/main) A writes
1d0e7c2 root commit
```

B now holds A's history without ever talking to A directly. The relay carried the bytes asynchronously.

## Concurrent writes

Two peers writing at the same time produce two heads. bit's history graph is content-addressed, so collisions are deterministic — both heads are valid until a merge or rebase reconciles them. There is no server vote.

<div class="callout">
<p class="kicker">// recommendation</p>
<p>Use <code>bit ai rebase</code> when the conflict is mechanical (formatting drift, import re-orderings). For semantic conflicts, do the merge by hand — the AI assist is wrong often enough that you want to read what it proposes.</p>
</div>

## Inspect the graph

```bash
$ bit log --graph --oneline --all
*   1f02776 (HEAD -> main) merge: reconcile A and B
|\
| * e871d71 B writes
* | a8c2f6e A writes
|/
* 1d0e7c2 root commit
```

## From MoonBit

The same flow scripted against the library. `Node::from_uri` opens a peer session; `fetch` walks the graph diff.

```moonbit
let peer = @bit.Node::from_uri("bit://aurora.local:9418/repo")
peer.handshake(timeout=2.s)?

let local_refs = @bit.refs(fs, ".git")
let wants      = local_refs.diff(peer.refs())
peer.fetch(wants)?

println("now at: \{peer.refs().get(\"refs/heads/main\")}")
```

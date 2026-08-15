---
title: Your first commit
section: learn
slug: first-commit
order: 2
nav_label: Your first commit
summary: Initialize a repo, write a file, stage it, commit it, read the log. Git muscle memory works — bit is a drop-in.
meta: ~5 min
kicker: // guide · 02
h1: Your first commit.
lead: If you have ever used Git, you already know this. bit reuses the porcelain — `init`, `add`, `commit`, `log` all behave the way you expect. The first commit is a sanity check that the binary works.
prev_href: install.html
prev_kicker: prev · 01
prev_label: Install bit
next_href: distributed.html
next_kicker: next · 03
next_label: Going distributed
---

## Initialize a repository

```bash
$ mkdir hello-bit
$ cd hello-bit
$ bit init
Initialized empty bit repository in .git/
```

bit writes a standard `.git/` directory. Any existing Git tool can read it. There is no parallel `.bit/` store.

## Write and stage

```bash
$ echo "hello, peer" > note.txt
$ bit add note.txt
$ bit status
On branch main

Changes to be committed:
        new file:   note.txt
```

<div class="callout">
<p class="kicker">// note</p>
<p>The <em>status</em> output is intentionally identical to Git's. bit emits the same line shapes so your editor's plugins, your hooks, and your <code>grep</code> incantations keep working.</p>
</div>

## Commit

```bash
$ bit commit -m "first node speaks"
[main (root-commit) a8c2f6e] first node speaks
 1 file changed, 1 insertion(+)
 create mode 100644 note.txt
```

## Read the log

```bash
$ bit log --graph --oneline
* a8c2f6e (HEAD -> main) first node speaks
```

The graph renderer is native — `--graph`, `--stat`, `--name-only`, `--name-status`, and `--topo-order` all run inside bit without shelling out.

## What just happened

bit wrote three Git objects under `.git/objects/`:

- a **blob** for `note.txt` (the file contents)
- a **tree** describing the directory snapshot
- a **commit** pointing at the tree, with your author identity and message

These are the same object types every Git client speaks. Anything you commit with bit can be pushed to a Git server, and anything cloned from a Git server can be operated on by bit.

## Try it from MoonBit

The same flow, scripted against an in-memory filesystem — no shell involved. This is how agents drive bit.

```moonbit
let fs = @bit.TestFs::new()
let root = "/hello-bit"

run_storage_command(fs, fs, root, "init", ["-q"])
fs.write_string(root + "/note.txt", "hello, peer")
run_storage_command(fs, fs, root, "add", ["note.txt"])
run_storage_command(fs, fs, root, "commit", ["-m", "first node speaks"])

let head = run_storage_command(fs, fs, root, "rev-parse", ["HEAD"])
println("commit: \{head}")
```

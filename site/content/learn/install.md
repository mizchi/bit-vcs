---
title: Install bit
section: learn
slug: install
order: 1
nav_label: Install bit
summary: One-line install on macOS & Linux, MoonBit toolchain, shell completion. The 30-second on-ramp.
meta: ~5 min
kicker: // guide · 01
h1: Install bit.
lead: Two install paths — a single curl line, or via the MoonBit toolchain if you already have one. Both produce a `bit` binary on PATH.
prev_href: ./
prev_kicker: back
prev_label: Learning Guide
next_href: first-commit.html
next_kicker: next · 02
next_label: Your first commit
---

## Supported platforms

- Linux x86_64
- macOS arm64 & x86_64

Windows is not supported yet. WSL works.

## One-line install

```bash
$ curl -fsSL https://raw.githubusercontent.com/mizchi/bit-vcs/main/install.sh | bash
```

The script detects your OS and architecture, downloads the matching release, and drops the binary at `~/.local/bin/bit`. Add it to your shell's `PATH` if it isn't already.

<div class="callout">
<p class="kicker">// note</p>
<p>Read the script before you pipe it to bash — that's the rule for every install script on the internet, not just this one. Mirror at <a href="https://github.com/mizchi/bit-vcs/blob/main/install.sh">github.com/mizchi/bit-vcs</a>.</p>
</div>

## Via the MoonBit toolchain

If you have `moon` installed:

```bash
$ moon install mizchi/bit/cmd/bit
```

This builds bit from source against your toolchain. Useful if you want to track main or contribute patches.

## Verify

```bash
$ bit --version
bit 0.1.0 — distributed git in moonbit
```

## Shell completion

bit ships its own completion generator. Pick your shell and source the output from your rc file.

### bash

```bash
eval "$(bit completion bash)"
```

### zsh

```bash
eval "$(bit completion zsh)"
```

## Uninstall

```bash
$ rm ~/.local/bin/bit
```

That's it. bit has no daemons, no system services, no cache outside your repos.

<div class="callout callout--acid">
<p class="kicker">// caveat</p>
<p>bit is experimental. Data corruption is possible in worst-case scenarios. Always keep a Git backup of important repositories until you have stress-tested your workflow.</p>
</div>

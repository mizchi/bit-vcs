# bit — documentation site

The static documentation site for **bit**. Deployed to GitHub Pages from this
folder. Markdown content under [`content/`](content/) is rendered to HTML at
build time using [`mizchi/markdown`](https://github.com/mizchi/markdown.mbt)
(MoonBit) wrapped by a tiny renderer in
[`tools/docs-build-mbt/`](../tools/docs-build-mbt/) and orchestrated by
[`tools/build-docs.mjs`](../tools/build-docs.mjs).

## Layout

```
site/
├── index.html              ← landing page (hand-written, brand-heavy)
├── content/                ← MARKDOWN SOURCE — author here
│   ├── learn/
│   │   ├── index.md
│   │   ├── concept.md
│   │   ├── install.md
│   │   ├── first-commit.md
│   │   └── distributed.md
│   └── reference/
│       ├── index.md
│       ├── cli.md
│       ├── library.md
│       └── env.md
├── learn/                  ← BUILD OUTPUT (overwritten by build-docs.mjs)
├── reference/              ← BUILD OUTPUT
├── assets/
│   ├── tokens.css          ← brand design tokens (copied from /brand)
│   ├── site.css            ← site-level layout + components
│   ├── syntax.js           ← MoonBit / bash syntax highlighter
│   ├── site.js             ← nav toggle, copy buttons
│   └── img/                ← logo, wordmark, lockups (copied from /brand)
├── .nojekyll               ← tell GitHub Pages not to run Jekyll
└── README.md               ← you are here
```

## Build

The pipeline is two steps. The MoonBit renderer compiles once and is reused
on every content change.

```sh
# 1. build the MoonBit renderer (one-time, or after dep bumps)
cd tools/docs-build-mbt && moon update && moon build --target js --release && cd -

# 2. render markdown to HTML
node tools/build-docs.mjs
```

This writes `site/learn/*.html` and `site/reference/*.html`. The
hand-written `site/index.html` is left alone.

## Preview locally

After building, open `site/index.html` in a browser or serve from a real
HTTP server (recommended — the clipboard API needs a secure context):

```sh
python3 -m http.server -d site 8080
# open http://localhost:8080
```

## Deploy

Pushed automatically by [`.github/workflows/pages.yml`](../.github/workflows/pages.yml)
on every push to `main` or `brand` that touches `site/`, `brand/`,
`tools/build-docs.mjs`, or `tools/docs-build-mbt/`.

The workflow:

1. Installs the MoonBit toolchain.
2. Builds the MoonBit renderer (`moon build --target js --release`).
3. Re-syncs brand assets (`tokens.css` + logo SVGs) from `brand/` into
   `site/assets/`.
4. Runs `node tools/build-docs.mjs` to render markdown to HTML.
5. Uploads the `site/` folder to GitHub Pages.

To enable Pages: in the repo's **Settings → Pages**, set the source to
**GitHub Actions**. The workflow handles the rest.

## Authoring content

Every chapter is a markdown file under `site/content/<section>/<slug>.md`
with a frontmatter block. Frontmatter keys are flat (no nesting); structure
is encoded by named fields like `prev_href` and `next_label`.

### Frontmatter

```yaml
---
title: Install bit          # <title> and H1 fallback
section: learn              # learn | reference
slug: install               # filename without .md
order: 1                    # sort order in sidenav and chapter list
nav_label: Install bit      # label in sidenav (optional, defaults to title)
summary: One-line install…  # shown on the section index TOC
meta: ~5 min                # right-column meta on the index TOC
kicker: // guide · 01       # mono kicker above the H1
h1: Install bit.            # H1 text (defaults to title)
lead: Two install paths …   # lead paragraph — markdown is rendered inline
prev_href: ./               # pager left
prev_kicker: back
prev_label: Learning Guide
next_href: first-commit.html
next_kicker: next · 02
next_label: Your first commit
---
```

For section index pages, add `template: index` and omit `prev_*` / `next_*`.
The chapter list is auto-generated from sibling pages.

### Code blocks

Fenced code blocks are post-processed into our `.codeblock` structure with
a language label and copy button. Supported `data-lang` values for the
syntax highlighter:

- `moonbit` / `mbt` — MoonBit syntax
- `bash` / `sh` — shell prompts and comments
- anything else — plain text

### Callouts

Inline HTML is the simplest path:

```html
<div class="callout">
<p class="kicker">// note</p>
<p>Body text. Inline HTML inside is plain HTML — markdown is not parsed here.</p>
</div>

<div class="callout callout--acid">
<p class="kicker">// caveat</p>
<p>Acid variant for warnings.</p>
</div>
```

## Updating brand assets

Don't edit `site/assets/tokens.css` or `site/assets/img/*.svg` directly —
edit the originals in [`brand/`](../brand/) and re-sync:

```sh
cp brand/tokens/tokens.css site/assets/tokens.css
cp brand/logo/*.svg site/assets/img/
```

The Pages workflow does this automatically on every deploy.

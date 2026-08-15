#!/usr/bin/env node
// tools/build-docs.mjs
// Reads site/content/**/*.md, renders bodies via mizchi/markdown (via the
// MoonBit→JS module under tools/docs-build-mbt/), and writes site/<section>/*.html
// using inline templates that carry the bit brand layout.
//
// Frontmatter format: a leading `---` / `---` fenced block of flat key:value
// pairs (no nesting; structure encoded in named fields like prev_href / next_href).
//
// Usage:
//   1. (once) build the renderer:
//        cd tools/docs-build-mbt && moon build --target js --release
//   2. node tools/build-docs.mjs

import fs from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(here, "..");
const contentDir = path.join(root, "site/content");
const outDir = path.join(root, "site");
const rendererPath = path.join(
  root,
  "tools/docs-build-mbt/_build/js/release/build/render/render.js",
);

// ── load renderer ────────────────────────────────────────────────────────
const { render } = await import(rendererPath).catch((err) => {
  console.error(
    `\nFailed to load MoonBit renderer at:\n  ${rendererPath}\n\n` +
      `Build it first:\n  cd tools/docs-build-mbt && moon build --target js --release\n`,
  );
  throw err;
});

// ── frontmatter parser ────────────────────────────────────────────────────
function parseFrontmatter(src) {
  const m = src.match(/^---\r?\n([\s\S]*?)\r?\n---\r?\n([\s\S]*)$/);
  if (!m) return { meta: {}, body: src };
  const meta = {};
  for (const raw of m[1].split(/\r?\n/)) {
    const line = raw.replace(/^\s+|\s+$/g, "");
    if (!line || line.startsWith("#")) continue;
    const kv = line.match(/^([A-Za-z_][\w-]*)\s*:\s*(.*)$/);
    if (!kv) continue;
    let [, k, v] = kv;
    v = v.replace(/^["']|["']$/g, "");
    if (/^-?\d+$/.test(v)) meta[k] = Number(v);
    else if (v === "true" || v === "false") meta[k] = v === "true";
    else meta[k] = v;
  }
  return { meta, body: m[2] };
}

// ── walk content tree ────────────────────────────────────────────────────
async function walk(dir) {
  const out = [];
  for (const ent of await fs.readdir(dir, { withFileTypes: true })) {
    const p = path.join(dir, ent.name);
    if (ent.isDirectory()) out.push(...(await walk(p)));
    else if (ent.isFile() && ent.name.endsWith(".md")) out.push(p);
  }
  return out;
}

// ── HTML post-processing ─────────────────────────────────────────────────
function slugify(s) {
  return s
    .toLowerCase()
    .replace(/<[^>]+>/g, "")
    .replace(/[^\p{Letter}\p{Number}]+/gu, "-")
    .replace(/^-|-$/g, "");
}

function transformHeadings(html) {
  // Number h2s "// 001" and add id + data-num. Leave h3/h4 alone.
  let i = 1;
  const out = html.replace(
    /<h2(?:\s+[^>]*)?>([\s\S]*?)<\/h2>/g,
    (_, inner) => {
      const id = slugify(inner) || `s-${i}`;
      const num = `// ${String(i).padStart(3, "0")}`;
      i++;
      return `<h2 id="${id}" data-num="${num}">${inner}</h2>`;
    },
  );
  return out;
}

function transformCodeBlocks(html) {
  // mizchi/markdown emits <pre><code class="language-X">…</code></pre>.
  // Wrap in our .codeblock structure and hand the language off via data-lang
  // so site/assets/syntax.js can pick it up.
  return html.replace(
    /<pre><code(?:\s+class="language-([a-zA-Z0-9_-]+)")?>([\s\S]*?)<\/code><\/pre>/g,
    (_, lang, code) => {
      const langLabel = `// ${lang || "txt"}`;
      const dataLang = lang || "";
      return (
        `<div class="codeblock">` +
        `<div class="codeblock__bar"><span class="lang">${langLabel}</span>` +
        `<button class="codeblock__copy">copy</button></div>` +
        `<pre><code data-lang="${dataLang}">${code}</code></pre>` +
        `</div>`
      );
    },
  );
}

// Render a short string of markdown as inline HTML (no <p> wrapper).
// Useful for frontmatter fields like `lead` where we want `code` and **bold**
// to render but the result is dropped into an inline context.
function renderInline(md) {
  if (!md) return "";
  const html = render(md).trim();
  return html
    .replace(/^<p>/, "")
    .replace(/<\/p>$/, "")
    .replace(/<\/p>\s*<p>/g, "<br><br>");
}

function extractToc(html) {
  const items = [];
  const re = /<h2\s+id="([^"]+)"\s+data-num="\/\/ (\d+)">([\s\S]*?)<\/h2>/g;
  let m;
  while ((m = re.exec(html)) !== null) {
    items.push({ id: m[1], num: m[2], label: m[3].replace(/<[^>]+>/g, "").trim() });
  }
  return items;
}

// ── sidenav generation ───────────────────────────────────────────────────
function sidenavFor(pages, section, activeSlug) {
  const sectionPages = pages
    .filter(
      (p) =>
        p.meta.section === section &&
        p.meta.slug !== "index" &&
        p.meta.template !== "landing",
    )
    .sort((a, b) => (a.meta.order ?? 99) - (b.meta.order ?? 99));

  const items = sectionPages.map((p) => {
    const href = `${p.meta.slug}.html`;
    const num =
      p.meta.order != null ? String(p.meta.order).padStart(2, "0") : "";
    const label = num ? `${num} ${p.meta.nav_label || p.meta.title}` : p.meta.title;
    const active = p.meta.slug === activeSlug ? ' class="active"' : "";
    return `      <li><a href="${href}"${active}>${label}</a></li>`;
  });

  const otherSection = section === "learn" ? "reference" : "learn";
  const otherLink =
    section === "learn"
      ? '      <li><a href="../reference/">Reference</a></li>'
      : '      <li><a href="../learn/">Learning Guide</a></li>';

  return `    <h4>// ${section === "learn" ? "Learning Guide" : "Reference"}</h4>
    <ul>
${items.join("\n")}
    </ul>
    <h4>// More</h4>
    <ul>
${otherLink}
      <li><a href="../">Home</a></li>
    </ul>`;
}

// ── chapter list for index pages ─────────────────────────────────────────
function chapterListFor(pages, section) {
  const sectionPages = pages
    .filter(
      (p) =>
        p.meta.section === section &&
        p.meta.slug !== "index" &&
        p.meta.template !== "landing",
    )
    .sort((a, b) => (a.meta.order ?? 99) - (b.meta.order ?? 99));

  const items = sectionPages.map((p) => {
    const href = `${p.meta.slug}.html`;
    const num = String(p.meta.order ?? 0).padStart(2, "0");
    const tag = section === "learn" ? num : `R${p.meta.order ?? "?"}`;
    return `    <a class="chapter" href="${href}">
      <div class="chapter__num">// ${tag}</div>
      <div>
        <h3 class="chapter__h">${p.meta.nav_label || p.meta.title}</h3>
        <p class="chapter__p">${renderInline(p.meta.summary || "")}</p>
      </div>
      <div class="chapter__meta">${p.meta.meta || ""}</div>
    </a>`;
  });

  return `  <nav class="chapters" aria-label="chapters">
${items.join("\n")}
  </nav>`;
}

// ── templates ────────────────────────────────────────────────────────────
function pageHead({ title, description, rootPath }) {
  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>${title}</title>${
    description
      ? `\n<meta name="description" content="${description}">`
      : ""
  }
<link rel="icon" href="${rootPath}assets/img/logo.svg" type="image/svg+xml">
<link rel="stylesheet" href="${rootPath}assets/tokens.css">
<link rel="stylesheet" href="${rootPath}assets/site.css">
</head>`;
}

function topbar({ rootPath, activeSection }) {
  const cls = (s) => (activeSection === s ? ' class="active"' : "");
  return `<header class="topbar">
  <div class="topbar__brand">
    <a href="${rootPath}" class="plain"><img src="${rootPath}assets/img/wordmark.svg" alt="bit"></a>
    <span class="ver">docs · v0.1</span>
  </div>
  <button class="topbar__menu" aria-label="menu"><span></span><span></span><span></span></button>
  <nav>
    <a href="${rootPath}learn/"${cls("learn")}>Learn</a>
    <a href="${rootPath}reference/"${cls("reference")}>Reference</a>
    <a href="https://github.com/mizchi/bit" target="_blank" rel="noopener">GitHub ↗</a>
  </nav>
</header>`;
}

function footer({ rootPath, sectionLabel }) {
  return `<footer class="site">
  <span>bit · ${sectionLabel}</span>
  <span><a href="${rootPath}">Home</a> · <a href="${rootPath}learn/">Learn</a> · <a href="${rootPath}reference/">Reference</a></span>
</footer>`;
}

function tocAside(items) {
  if (!items.length) return "";
  const lis = items
    .map(
      (it) =>
        `      <li><a href="#${it.id}"><span class="num">${it.num}</span> ${it.label}</a></li>`,
    )
    .join("\n");
  return `  <aside class="toc">
    <h4>// on this page</h4>
    <ul>
${lis}
    </ul>
  </aside>`;
}

function pager(meta) {
  if (!meta.prev_href && !meta.next_href) return "";
  const left = meta.prev_href
    ? `  <a href="${meta.prev_href}">
    <span class="pager__k">← ${meta.prev_kicker || "back"}</span>
    <span class="pager__t">${meta.prev_label || ""}</span>
  </a>`
    : `  <span></span>`;
  const right = meta.next_href
    ? `  <a class="next" href="${meta.next_href}">
    <span class="pager__k">${meta.next_kicker || "next"} →</span>
    <span class="pager__t">${meta.next_label || ""}</span>
  </a>`
    : `  <span></span>`;
  return `<nav class="pager">
${left}
${right}
</nav>`;
}

function chapterPageTemplate({
  meta,
  rootPath,
  sidenav,
  body,
  toc,
  description,
}) {
  return `${pageHead({ title: meta.title, description, rootPath })}
<body>
${topbar({ rootPath, activeSection: meta.section })}

<div class="layout">

  <aside class="side">
${sidenav}
  </aside>

  <article>
    <header class="title">
      <p class="kicker">${meta.kicker || ""}</p>
      <h1>${meta.h1 || meta.title}</h1>${
        meta.lead ? `\n      <p class="lead">${renderInline(meta.lead)}</p>` : ""
      }
    </header>

${body}

${pager(meta)}
  </article>

${toc}

</div>

${footer({ rootPath, sectionLabel: `${meta.section} · ${meta.slug}` })}

<script src="${rootPath}assets/syntax.js"></script>
<script src="${rootPath}assets/site.js"></script>
</body>
</html>
`;
}

function indexPageTemplate({ meta, rootPath, body, chapterList, description }) {
  return `${pageHead({ title: meta.title, description, rootPath })}
<body>
${topbar({ rootPath, activeSection: meta.section })}

<section class="hero">
  <div class="hero__tag">
    <span><strong>bit / ${meta.section}</strong></span>
    <span>${meta.hero_tag || ""}</span>
  </div>

  <p class="kicker">${meta.kicker || ""}</p>
  <h1 class="hero__head" style="font-size: clamp(48px, 9vw, 96px);">${meta.h1 || meta.title}</h1>${
    meta.lead
      ? `\n  <p class="hero__sub" style="margin-top: var(--space-5);">${renderInline(meta.lead)}</p>`
      : ""
  }
</section>

<section class="section" style="padding-top: 0;">
${chapterList}
</section>

${body ? `<section class="section">\n${body}\n</section>\n` : ""}

${footer({ rootPath, sectionLabel: meta.section })}

<script src="${rootPath}assets/syntax.js"></script>
<script src="${rootPath}assets/site.js"></script>
</body>
</html>
`;
}

// ── per-page renderer ────────────────────────────────────────────────────
function renderPage(page, pages) {
  const isIndex = page.meta.slug === "index" || page.meta.template === "index";
  const rootPath = "../"; // all rendered pages live under site/<section>/

  const rawHtml = render(page.body || "");
  const body = transformCodeBlocks(transformHeadings(rawHtml));
  const toc = isIndex ? "" : tocAside(extractToc(body));
  const sidenav = sidenavFor(pages, page.meta.section, page.meta.slug);

  if (isIndex) {
    return indexPageTemplate({
      meta: page.meta,
      rootPath,
      body,
      chapterList: chapterListFor(pages, page.meta.section),
      description: page.meta.description,
    });
  }
  return chapterPageTemplate({
    meta: page.meta,
    rootPath,
    sidenav,
    body,
    toc,
    description: page.meta.description,
  });
}

// ── main ────────────────────────────────────────────────────────────────
const files = await walk(contentDir);
const pages = await Promise.all(
  files.map(async (f) => {
    const src = await fs.readFile(f, "utf8");
    const { meta, body } = parseFrontmatter(src);
    const rel = path.relative(contentDir, f).replace(/\\/g, "/"); // posix
    // Section/slug derived from path if not given in frontmatter
    if (!meta.section || !meta.slug) {
      const parts = rel.replace(/\.md$/, "").split("/");
      meta.section ||= parts[0];
      meta.slug ||= parts.slice(1).join("/") || "index";
    }
    return { file: f, meta, body };
  }),
);

let wrote = 0;
for (const page of pages) {
  const html = renderPage(page, pages);
  const slug = page.meta.slug === "index" ? "index" : page.meta.slug;
  const out = path.join(outDir, page.meta.section, `${slug}.html`);
  await fs.mkdir(path.dirname(out), { recursive: true });
  await fs.writeFile(out, html);
  wrote++;
  console.log(`  ${path.relative(root, out)}`);
}

console.log(`\nbuilt ${wrote} page${wrote === 1 ? "" : "s"}.`);

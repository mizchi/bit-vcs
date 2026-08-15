# bit docs-build (MoonBit)

A tiny MoonBit project that wraps [`mizchi/markdown`](https://github.com/mizchi/markdown.mbt)
into a single ESM-friendly `render(source) -> html` function. The `tools/build-docs.mjs`
Node script imports the compiled JS output, walks `site/content/**/*.md`, and writes
`site/learn/*.html` + `site/reference/*.html`.

## Build

```sh
moon update
moon build --target js --release
```

Output: `_build/js/release/build/render/render.js` exporting `{ render }`.

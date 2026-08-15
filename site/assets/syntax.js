// bit — minimal MoonBit syntax highlighter
// Vanilla JS, no deps. Tokenizes via a single ordered regex (Crockford-style).
// Classes match site.css: tok-cm, tok-kw, tok-ty, tok-str, tok-num, tok-fn, tok-pm
(function () {
  const KEYWORDS = new Set([
    "let", "fn", "match", "if", "else", "for", "while", "return", "mut",
    "loop", "break", "continue", "as", "in", "with", "struct", "enum",
    "trait", "impl", "type", "typealias", "test", "guard", "raise",
    "try", "catch", "self", "and", "or", "not", "where", "is",
    "derive", "init", "new"
  ]);
  const PREAMBLE = new Set([
    "pub", "priv", "extern", "import", "package", "fnalias", "traitalias",
    "typealias", "async"
  ]);
  const TYPES = new Set([
    "Int", "Int64", "UInt", "UInt64", "Double", "Float", "Bool", "String",
    "Char", "Bytes", "Unit", "Array", "FixedArray", "Map", "HashMap",
    "HashSet", "Option", "Result", "Iter", "Ref", "BigInt", "Json"
  ]);
  const CONSTS = new Set(["true", "false", "None", "Some", "Ok", "Err", "Nil"]);

  // ordered token regex — first hit wins
  const RE = new RegExp([
    "(\\/\\/[^\\n]*)",                       // 1 line comment
    "(\\/\\*[\\s\\S]*?\\*\\/)",              // 2 block comment
    "(b?\"(?:\\\\.|[^\"\\\\])*\")",          // 3 string / b-string
    "('(?:\\\\.|[^'\\\\])')",                // 4 char literal
    "(0x[0-9a-fA-F_]+|0b[01_]+|0o[0-7_]+|[0-9][0-9_]*(?:\\.[0-9_]+)?(?:[eE][+-]?[0-9_]+)?[a-zA-Z]*)", // 5 number
    "([A-Za-z_][A-Za-z0-9_]*)",              // 6 ident
    "([^\\s\\w]+)"                            // 7 punct (passthrough)
  ].join("|"), "g");

  function esc(s) {
    return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
  }

  function highlight(src) {
    let out = "";
    let lastIndex = 0;
    let m;
    RE.lastIndex = 0;
    while ((m = RE.exec(src)) !== null) {
      if (m.index > lastIndex) out += esc(src.slice(lastIndex, m.index));
      const [_, lc, bc, str, ch, num, id, punct] = m;
      if (lc)      out += `<span class="tok-cm">${esc(lc)}</span>`;
      else if (bc) out += `<span class="tok-cm">${esc(bc)}</span>`;
      else if (str)out += `<span class="tok-str">${esc(str)}</span>`;
      else if (ch) out += `<span class="tok-str">${esc(ch)}</span>`;
      else if (num)out += `<span class="tok-num">${esc(num)}</span>`;
      else if (id) {
        if (PREAMBLE.has(id))       out += `<span class="tok-pm">${id}</span>`;
        else if (KEYWORDS.has(id))  out += `<span class="tok-kw">${id}</span>`;
        else if (TYPES.has(id))     out += `<span class="tok-ty">${id}</span>`;
        else if (CONSTS.has(id))    out += `<span class="tok-kw">${id}</span>`;
        else {
          // function call detection: ident followed by '('
          const next = src[m.index + id.length];
          if (next === "(") out += `<span class="tok-fn">${id}</span>`;
          else out += id;
        }
      } else if (punct) out += esc(punct);
      lastIndex = RE.lastIndex;
    }
    if (lastIndex < src.length) out += esc(src.slice(lastIndex));
    return out;
  }

  // bash/shell minimal: comments + strings + prompt
  function shellHighlight(src) {
    return esc(src)
      .replace(/(^|\n)(\$|#) /g, (_, nl, sigil) => `${nl}<span class="tok-kw">${sigil}</span> `)
      .replace(/(#[^\n]*)/g, '<span class="tok-cm">$1</span>')
      .replace(/("[^"]*"|'[^']*')/g, '<span class="tok-str">$1</span>');
  }

  function init() {
    document.querySelectorAll('pre code[data-lang]').forEach((el) => {
      const lang = el.dataset.lang;
      const src = el.textContent;
      if (lang === "moonbit" || lang === "mbt") el.innerHTML = highlight(src);
      else if (lang === "bash" || lang === "sh") el.innerHTML = shellHighlight(src);
    });

    document.querySelectorAll('.codeblock__copy').forEach((btn) => {
      btn.addEventListener("click", () => {
        const code = btn.closest('.codeblock').querySelector('pre code');
        if (!code) return;
        navigator.clipboard.writeText(code.textContent).then(() => {
          btn.textContent = "copied";
          btn.classList.add("copied");
          setTimeout(() => { btn.textContent = "copy"; btn.classList.remove("copied"); }, 1400);
        });
      });
    });
  }

  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", init);
  else init();
})();

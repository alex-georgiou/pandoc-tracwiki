# md2tracwiki

A [pandoc](https://pandoc.org) custom writer (written in Lua) that renders
documents as [Trac wiki](https://trac.edgewall.org/wiki/WikiFormatting)
markup.

Requires pandoc >= 2.17 (new-style Lua writers) with Lua scripting support
(`pandoc --version` should list `+lua`). Developed against pandoc 3.6.1.

## Usage

```sh
pandoc --from=markdown -t /path/to/tracwiki.lua input.md > output.txt
```

The writer file can also live on the pandoc user data directory
(`~/.local/share/pandoc`) so it can be referenced by name:

```sh
pandoc -t tracwiki.lua input.md
```

For a self-contained page (writes the metadata `title` as a top-level
heading), use `--standalone`.

## Supported markup

Writers are new-style (a global `Writer(doc, opts)` function) and handle the
AST directly. Conversion summary:

| Pandoc                        | Trac wiki                                        |
| ----------------------------- | ------------------------------------------------ |
| Headings                      | `= h1 =`, `== h2 ==`, … with ` #id`              |
| Bold / Italic                 | `'''x'''` / `''x''`                              |
| Strikeout / Underline         | `~~x~~` / `__x__`                                |
| Superscript / Subscript       | `^x^` / `,,x,,`                                  |
| Inline code                   | `` `x` `` (falls back to `{{{x}}}` with backticks in text) |
| Math                          | `` `$…` `` inline, `{{{…}}}` display-block       |
| Code blocks                   | `{{{` … `}}}`, with `{{{#!lang` when a class is set |
| Bullet / ordered lists        | ` * ` / ` 1. `, nested lists indented 3 spaces   |
| Definition lists              | `term:: definition`                              |
| Blockquotes                   | `> ` prefix per line (nested with `> >`)         |
| Tables                        | `|| a || b ||` rows; `||=Title=||` centered/`||=Title =||` left/`||= Title=||` right header cells |
| Horizontal rule               | `----`                                           |
| Hard line break               | `[[BR]]`                                         |
| External links                | `[url text]` (bare URL when text equals URL)     |
| Internal / wiki links         | `[wiki:Page text]`, anchors `[#section label]`   |
| Images                        | `[[Image(src, alt=…, title=…)]]`                 |
| Raw trac blocks / inlines     | passed through verbatim                          |

### Notes and limitations

- Trac has no native footnotes; `Note` elements are rendered inline in
  parentheses.
- Heading identifiers are always emitted (`#id`); set an explicit id in the
  source (`## Section {#my-id}`) to control the anchor.
- Table cells with multiple blocks are joined with `[[BR]]`; no colspan or
  rowspan handling.
- Unsupported block/inline types (e.g. `Cite`, `SmallCaps`) degrade to their
  plain-text content; raw `html`/`latex` is dropped (only `trac`-formatted raw
  content is preserved).

## Tests

Tests run against the locally installed `pandoc` binary (no `lua` or `busted`
required). Each case in `tests/cases/` is a Markdown (or pandoc JSON) fixture
with a committed golden-file expectation. The runner converts each fixture
with this writer and `diff`s the result.

```sh
tests/run_tests.sh          # run all tests
tests/run_tests.sh -u       # regenerate golden files from current output
```

### Adding a case

1. Add `tests/cases/<name>.md` (Markdown) or `tests/cases/<name>.json`
   (pandoc JSON AST).
2. Run `tests/run_tests.sh -u` to generate `tests/cases/<name>.expected`.
3. Review the generated file against the Trac syntax before committing.
4. Run `tests/run_tests.sh` to confirm it passes.
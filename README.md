# pandoc-tracwiki

A [pandoc](https://pandoc.org) custom writer **and reader** (both in one Lua
script) that renders documents as
[Trac wiki](https://trac.edgewall.org/wiki/WikiFormatting) markup and parses
Trac wiki markup back into pandoc's AST.

Requires pandoc >= 3.1 (single-script custom readers/writers) with Lua
scripting support (`pandoc --version` should list `+lua`). Developed against
pandoc 3.6.1. See [LIMITATIONS.md](LIMITATIONS.md) for known gaps.

## Usage

```sh
# Markdown / JSON -> Trac wiki
pandoc --from=markdown -t /path/to/tracwiki.lua input.md > output.txt

# Trac wiki -> pandoc (to Markdown here)
pandoc -f /path/to/tracwiki.lua -t markdown page.txt
```

Once installed (see below), both can be referenced by name from any
directory:

```sh
pandoc -t tracwiki.lua input.md
pandoc -f tracwiki.lua page.txt
```

For a self-contained page (writes the metadata `title` as a top-level
heading), use `--standalone`.

## Install

Pandoc looks for custom writers in the `custom` subdirectory of its user data
directory (default `~/.local/share/pandoc`). Install with:

```sh
make install
```

or manually:

```sh
mkdir -p ~/.local/share/pandoc/custom
cp tracwiki.lua ~/.local/share/pandoc/custom/tracwiki.lua
```

Verify from any directory: `printf 'Hi\n' | pandoc -t tracwiki.lua` and
`printf '= Hi =\n' | pandoc -f tracwiki.lua -t markdown`.

To install system-wide (all users), point `PANDOC_DATA_DIR` at the system
data directory (requires sudo):

```sh
sudo make install PANDOC_DATA_DIR=/usr/local/share/pandoc
```

Other targets:

```sh
make uninstall   # remove the installed writer/reader
make test        # run both golden-file test suites
make test-reader # only the reader suite
```

## Writing to Trac

The writer is a new-style Lua `Writer(doc, opts)` handling the AST directly.
Conversion summary:

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
- Only explicitly authored heading ids are emitted (`## Section {#my-id}` →
  `== Section #my-id ==`). Pandoc's implicitly auto-generated ids are
  suppressed; Trac derives its own readable anchors otherwise.
- Table cells with multiple blocks are joined with `[[BR]]`; no colspan or
  rowspan handling.
- Unsupported block/inline types (e.g. `Cite`, `SmallCaps`) degrade to their
  plain-text content; raw `html`/`latex` is dropped (only `trac`-formatted raw
  content is preserved).

## Reading from Trac

The same script defines a `Reader(input, opts)`, so `pandoc -f tracwiki.lua`
parses Trac wiki markup. Supported:

| Trac wiki                                        | Pandoc                              |
| ------------------------------------------------ | ----------------------------------- |
| `= h1 =`, `== h2 ==` (with optional ` #id`)      | Headings (id preserved)             |
| `'''x'''` / `''x''`                              | Strong / Emph (nestable)            |
| `~~x~~` / `__x__` / `^x^` / `,,x,,`              | Strikeout / Underline / Sup / Sub   |
| backtick `` `x` `` or `{{{x}}}` inline           | Code                                |
| `{{{…}}}` blocks, `{{{#!lang …}}}`               | CodeBlock (class)                   |
| `{{{#!comment …}}}`                              | removed                             |
| ` * ` / ` 1. ` / ` a. ` / ` i. ` lists (nested) | BulletList / OrderedList (styles)   |
| `term:: definition`                              | DefinitionList                      |
| `> ` / `> > ` quotes, 2-space indented quote     | BlockQuote                          |
| `|| a || b ||` tables (`=` header cells)         | Table (SimpleTable)                 |
| `----`                                           | HorizontalRule                      |
| `[[BR]]` / trailing `\\`                         | LineBreak                           |
| `[url text]`, `[wiki:Page text]`, `[#anchor x]`  | Link                                |
| `[=#anchor text]`                                | Span with `identifier`              |
| `[[Image(src, alt=…, title=…)]]`                 | Image                               |
| `[[Macro(...)]]` (unknown)                       | `RawInline` `trac` (passthrough)    |

Enable Trac-style CamelCase auto-linking with `pandoc -f tracwiki.lua+camelcase`
(`Extensions = { camelcase = "disable" }` keeps it off by default).

### Reader notes and limitations

- Coverage targets a round-trip + common dialect, not the full WikiFormatting
  spec: div/span/table processor blocks pass through as `RawBlock` `trac`,
  `#!wikitext`-style processors become a classed `CodeBlock`, and unknown
  `[[Macro(...)]]` survive only in a Trac-to-Trac round trip.
- Ordered-list restart numbers (e.g. `3.` after a `1.`) are not preserved in
  the AST; the list continues from the first marker's number.
- Table cell spans, `||>` scissors and non-trivial alignment hints are not
  merged; header/alignment is inferred from `=`/whitespace in the cell.
- `ticket:`, `#123`, `changeset:` style Trac refs are read as literal text.
- Paragraph line-wrapping newlines become `SoftBreak`; a `SoftBreak` directly
  after a `[[BR]]`/`\\` reads back as a space (writer cosmetics only).

## Tests

Tests run against the locally installed `pandoc` binary (no `lua` or `busted`
required). The writer suite (`tests/cases/`) converts each Markdown (or pandoc
JSON) fixture with this writer and diffs against a committed golden file. The
reader suite (`tests/reader_cases/`) feeds each `.trac` fixture through the
reader into Markdown, and additionally checks that re-processing every writer
golden with `pandoc -f tracwiki.lua -t tracwiki.lua` is a fixed point
(running it twice yields the same output).

```sh
tests/run_writer_tests.sh          # run all writer tests
tests/run_writer_tests.sh -u       # regenerate writer golden files
tests/run_reader_tests.sh          # run all reader tests
tests/run_reader_tests.sh -u       # regenerate reader golden files
```

### Adding a case

Writer cases:

1. Add `tests/cases/<name>.md` (Markdown) or `tests/cases/<name>.json`
   (pandoc JSON AST).
2. Run `tests/run_writer_tests.sh -u` to generate `tests/cases/<name>.expected`.
3. Review the generated file against the Trac syntax before committing.
4. Run `tests/run_writer_tests.sh` to confirm it passes.

Reader cases:

1. Add `tests/reader_cases/<name>.trac` (Trac wiki markup).
2. Run `tests/run_reader_tests.sh -u` to generate
   `tests/reader_cases/<name>.expected`.
3. Review the generated file against the pandoc Markdown you expect.
4. Run `tests/run_reader_tests.sh` to confirm it passes.
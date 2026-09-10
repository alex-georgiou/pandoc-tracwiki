# Limitations

`tracwiki.lua` is a pandoc <-> Trac wiki reader and writer (both directions
in a single script) focused on round-tripping everyday content in a common
Trac dialect. It is **not** a complete implementation of
[Trac WikiFormatting](https://trac.edgewall.org/wiki/WikiFormatting). Known
gaps are listed below, per direction.

## Writer (pandoc -> Trac)

- **Footnotes**: Trac has no native footnote syntax. `Note` elements are
  rendered inline in parentheses instead.

- **Heading ids**: only explicitly authored ids are emitted
  (`## Section {#my-id}` -> `== Section #my-id ==`). Pandoc's implicitly
  auto-generated ids are suppressed because Trac derives its own readable
  anchors otherwise.

- **Tables**: a cell holding multiple blocks is joined with `[[BR]]`.
  Colspan and rowspan are not supported.

- **Unhandled AST elements** (e.g. `Cite`, `SmallCaps`) degrade to their
  plain-text content. Raw `html` / `latex` blocks and inlines are dropped;
  only already-`trac`-formatted raw content is passed through verbatim.

- **Math**: `$…$` and `$$…$$` are kept as literal text. Trac has no native
  math support, so dollar signs are not interpreted as math delimiters.

- **Definition lists** are written as `term:: definition`; a term with no
  definition line is written as a bare `term::`.

## Reader (Trac -> pandoc)

Coverage targets a round-trip plus the common dialect rather than the full
spec:

- Processor blocks `{{{#!div`, `#!span`, `#!table`, `#!tr`, `#!th`, `#!td`
  pass through as `RawBlock` (`trac` format). Other `#!lang` blocks become a
  `CodeBlock` carrying the language as a class. `#!comment` blocks are
  dropped entirely.
- Unknown `[[Macro(...)]]` are kept as `RawInline` (`trac` format) and
  survive only a Trac-to-Trac round trip; they do not map to a pandoc
  element.

Specific gaps:

- **Ordered-list restart numbers**: a `3.` following a `1.` is read into a
  single `OrderedList`; the restart number is not representable in the AST,
  so the list continues from the first marker's number.

- **Table detail**: cell spans, `||>` scissors and non-trivial alignment
  hints are not merged. Header cells and left/right alignment are inferred
  from a `=` cell prefix and leading/trailing cell whitespace.

- **Trac references**: bare `ticket:`, `changeset:` and `#123` style refs
  are read as literal text; only bracketed `[#anchor label]` and
  `[wiki:Page text]` forms are linkified.

- **Images / macros**: `[[Image(...)]]` maps `alt`, `title` and `link`
  attributes; other `[[...]]` attributes and wiki-link text containing spaces
  are not mapped and stay literal.

- **Blockquotes inside list items** are not parsed - a `>` (or indented)
  line within an item reads as literal text. Indented (2-space) blockquotes
  only work at the top level.

- **Alpha / roman lists**: single-letter alpha markers `a.`-`z.` and roman
  `i.`-`x.` are recognized; continuations such as `xi.` are read as plain
  text.

- **Escape scope**: `\` and `!` escape only the immediately following markup
  character.

- **Heading ids**: read from a trailing ` #id`; a literal heading that ends
  in `#word` is therefore interpreted as an anchor.

- **Paragraph wrapping**: an interior newline becomes a `SoftBreak`. A
  `SoftBreak` directly after a `[[BR]]` / trailing `\\` reads back as a
  space when rewritten, so the output differs stylistically from the source
  on the first pass (see below).

## Round trip

`pandoc -f tracwiki.lua -t tracwiki.lua` is a fixed point: the second pass
always equals the first pass. It can differ stylistically from the original
source on the first pass, e.g. `{{{\n#!lang` (processor on its own line) is
normalized to `{{{#!lang`. The idempotence property is enforced by
`tests/run_reader_tests.sh`, which re-processes every writer golden once more
and requires an identical result.
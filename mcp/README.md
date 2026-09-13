# pandoc-tracwiki MCP server

An [MCP](https://modelcontextprotocol.io) server that exposes the
`pandoc-tracwiki` conversions (Markdown <-> Trac wiki markup) as tools. Any MCP
client - IDE, agent, chat app - can convert documents in either direction by
calling a tool instead of shelling out to pandoc directly.

The server is thin: it spawns the `pandoc` binary with the `tracwiki.lua`
reader/writer from this repository. Everything Trac-related is handled by
pandoc + `tracwiki.lua` (see the repo README and `LIMITATIONS.md`), not by the
server.

## Requirements

- **Node.js >= 18** (used by the MCP SDK)
- **pandoc >= 3.1** with Lua scripting (`pandoc --version` should list
  `+lua`) on `PATH`
- A checkout of this repository (the server locates `../tracwiki.lua`
  relative to its own location)

## Install

From the repository checkout:

```sh
cd mcp
npm install
```

This installs the local dependencies and creates `mcp/node_modules`
(git-ignored). `package-lock.json` is committed for reproducible installs.

Smoke-test the install:

```sh
npm test                 # runs the test suite (or: make test-mcp from the repo root)
```

The tests reuse the repo's golden files and also drive the server over real
JSON-RPC stdio, so a green run means both the conversion logic and the MCP
protocol wiring work.

## Run

The server speaks MCP over **stdio**; it must be launched by an MCP client, not
run by hand in a terminal (it reads requests from stdin and writes responses to
stdout).

```sh
node index.js            # or: npm start
```

The client config points at `node <absolute path to mcp/index.js>` - see
[Register with a client](#register-with-a-client). Use an **absolute** path: an
MCP client launches the process with its own working directory, so a relative
path like `mcp/index.js` will not resolve.

### Configuration

By default the server shells out to `pandoc` on `PATH` and uses the
`tracwiki.lua` bundled with the repo. Override either via environment
variables (they can be set per-client, see the `env` examples below):

| Variable                    | Default                               |
| --------------------------- | ------------------------------------- |
| `PANDOC_TRACWIKI_PANDOC`    | `pandoc` (first match on `PATH`)      |
| `PANDOC_TRACWIKI_LUA`       | `<repo>/tracwiki.lua`                 |

## Tools

| Tool                    | Inputs                                              | Output            |
| ----------------------- | --------------------------------------------------- | ----------------- |
| `tracwiki_to_markdown`  | `tracwiki` string, optional `camelcase`             | Markdown          |
| `markdown_to_tracwiki`  | `markdown` string, optional `format`, `standalone`  | Trac wiki markup  |
| `normalize_tracwiki`    | `tracwiki` string                                   | Trac wiki markup  |

- `tracwiki_to_markdown`: parses Trac wiki markup into pandoc Markdown. Pass
  `camelcase: true` to auto-link CamelCase words as wiki page links (off by
  default, matching the underlying reader).
- `markdown_to_tracwiki`: renders Markdown as Trac wiki markup. `format`
  selects the pandoc input format (default `markdown-tex_math_dollars`);
  `standalone` renders a document's metadata `title` as a top-level `= title =`
  heading.
- `normalize_tracwiki`: read-then-write round trip (`trac -> trac`). This is
  an idempotent fixed point - running it twice yields identical output - and
  is handy to clean up hand-edited Trac markup.

## Register with a client

All three registrations below run the same command. Replace the path with your
absolute path to `mcp/index.js`.

### opencode

`opencode` / `~/.config/opencode/opencode.json`:

```json
{
  "mcp": {
    "pandoc-tracwiki": {
      "type": "local",
      "command": ["node", "/absolute/path/to/pandoc-tracwiki/mcp/index.js"],
      "enabled": false
    }
  }
}
```

Set `"enabled": true` to activate. To point at a different pandoc binary or Lua
script, add an `"environment"` block.

### Claude Desktop

`claude_desktop_config.json`:

- macOS: `~/Library/Application Support/Claude/claude_desktop_config.json`
- Linux: `~/.config/Claude/claude_desktop_config.json`
- Windows: `%APPDATA%\Claude\claude_desktop_config.json`

```json
{
  "mcpServers": {
    "pandoc-tracwiki": {
      "command": "node",
      "args": ["C:\\absolute\\path\\to\\pandoc-tracwiki\\mcp\\index.js"],
      "env": {}
    }
  }
}
```

Restart Claude Desktop after editing. With Claude Code use `claude mcp add
pandoc-tracwiki -- node /absolute/path/to/pandoc-tracwiki/mcp/index.js`
instead.

### Visual Studio Code

VS Code (1.105+) stores project MCP servers in `.vscode/mcp.json` (add to your
workspace), or via **Add MCP Server** from the command palette:

```json
{
  "servers": {
    "pandoc-tracwiki": {
      "type": "stdio",
      "command": "node",
      "args": ["/absolute/path/to/pandoc-tracwiki/mcp/index.js"]
      // "env": { "PANDOC_TRACWIKI_PANDOC": "/usr/local/bin/pandoc" }
    }
  }
}
```

`type` may be omitted if the command is run from a terminal. Trust the
workspace (or approve the MCP server) when prompted, then reload the window.

## Troubleshooting

- **"pandoc executable not found"** on a tool call - `pandoc` is not on the
  client's `PATH`. Set `PANDOC_TRACWIKI_PANDOC` to the full path.
- **Lua script errors / wrong output** - the server found a
  `tracwiki.lua` that is not the one you expect. Set `PANDOC_TRACWIKI_LUA` to
  the repo's `tracwiki.lua`.
- **Server fails to start** - check Node is >= 18 (`node --version`), then run
  `node index.js` in a terminal; startup errors are printed to stderr.
- **Tests fail** - `NODE_ENV`, PATH or `PANDOC_TRACWIKI_*` overrides affect the
  test run too; unset them and try `make test-mcp` again.

## License

MIT - see [LICENSE](../LICENSE).
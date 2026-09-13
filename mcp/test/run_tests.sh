#!/usr/bin/env bash
#
# MCP server tests: exercises converter.js against the repo's golden files and
# drives the server over real JSON-RPC stdio.
#
# Usage:
#   mcp/test/run_tests.sh   run all MCP tests
#
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
mcp_dir="$(dirname "$script_dir")"

if ! command -v pandoc >/dev/null 2>&1; then
  echo "error: pandoc not found on PATH" >&2
  exit 1
fi

if [ ! -d "$mcp_dir/node_modules" ]; then
  npm --prefix "$mcp_dir" install --no-audit --no-fund >/dev/null
fi

exec node "$script_dir/test.js"
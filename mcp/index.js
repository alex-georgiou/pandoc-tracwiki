#!/usr/bin/env node
'use strict';

const { McpServer } = require('@modelcontextprotocol/sdk/server/mcp.js');
const { StdioServerTransport } = require('@modelcontextprotocol/sdk/server/stdio.js');
const z = require('zod');

const converter = require('./converter.js');

const server = new McpServer({ name: 'pandoc-tracwiki', version: '0.1.0' });

function errorResult(prefix, err) {
  return {
    content: [{ type: 'text', text: `${prefix}: ${err.message || String(err)}` }],
    isError: true,
  };
}

server.tool(
  'tracwiki_to_markdown',
  'Convert Trac wiki markup to pandoc Markdown.',
  {
    tracwiki: z.string().describe('Trac wiki markup to convert'),
    camelcase: z
      .boolean()
      .optional()
      .describe('Auto-link CamelCase words as wiki page links'),
  },
  async ({ tracwiki, camelcase }) => {
    try {
      const markdown = await converter.toMarkdown(tracwiki, { camelcase: !!camelcase });
      return { content: [{ type: 'text', text: markdown }] };
    } catch (err) {
      return errorResult('Conversion failed', err);
    }
  }
);

server.tool(
  'markdown_to_tracwiki',
  'Convert Markdown to Trac wiki markup.',
  {
    markdown: z.string().describe('Markdown to convert'),
    format: z
      .string()
      .optional()
      .describe('Pandoc input format (default: markdown-tex_math_dollars)'),
    standalone: z
      .boolean()
      .optional()
      .describe('Render the document metadata title as a top-level heading'),
  },
  async ({ markdown, format, standalone }) => {
    try {
      const trac = await converter.toTrac(markdown, { format, standalone: !!standalone });
      return { content: [{ type: 'text', text: trac }] };
    } catch (err) {
      return errorResult('Conversion failed', err);
    }
  }
);

server.tool(
  'normalize_tracwiki',
  'Normalize Trac wiki markup via a read-then-write round trip (an idempotent fixed point).',
  {
    tracwiki: z.string().describe('Trac wiki markup to normalize'),
  },
  async ({ tracwiki }) => {
    try {
      const normalized = await converter.normalizeTrac(tracwiki);
      return { content: [{ type: 'text', text: normalized }] };
    } catch (err) {
      return errorResult('Conversion failed', err);
    }
  }
);

async function main() {
  const transport = new StdioServerTransport();
  await server.connect(transport);
}

main().catch((err) => {
  console.error('Failed to start pandoc-tracwiki MCP server:', err.message);
  process.exit(1);
});
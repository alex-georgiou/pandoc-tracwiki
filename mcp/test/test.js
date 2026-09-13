'use strict';

const { spawn } = require('node:child_process');
const fs = require('node:fs');
const path = require('node:path');
const readline = require('node:readline');

const converter = require('../converter.js');

const root = path.resolve(__dirname, '..', '..');
const casesDir = path.join(root, 'tests', 'cases');
const readerCasesDir = path.join(root, 'tests', 'reader_cases');

let failures = 0;

function fail(label) {
  failures += 1;
  console.log('FAIL ' + label);
}

function ok(label) {
  console.log('PASS ' + label);
}

function showDiff(expected, actual) {
  const e = expected.split('\n');
  const a = actual.split('\n');
  const n = Math.max(e.length, a.length);
  for (let i = 0; i < n; i++) {
    if (e[i] !== a[i]) {
      console.log(`  first diff at line ${i + 1}:`);
      console.log(`    expected: ${JSON.stringify(e[i])}`);
      console.log(`    actual:   ${JSON.stringify(a[i])}`);
      return;
    }
  }
}

async function testWriterCases() {
  const files = fs.readdirSync(casesDir).sort();
  for (const f of files) {
    const m = f.match(/^(.+)\.(md|json)$/);
    if (!m) continue;
    const expected = fs.readFileSync(path.join(casesDir, `${m[1]}.expected`), 'utf8');
    const input = fs.readFileSync(path.join(casesDir, f), 'utf8');
    const format = m[2] === 'json' ? 'json' : 'markdown-tex_math_dollars';
    const trac = await converter.toTrac(input, { format });
    if (trac === expected) ok(`writer ${f}`);
    else {
      fail(`writer ${f}`);
      showDiff(expected, trac);
    }
  }

  for (const f of files) {
    if (!f.endsWith('.expected')) continue;
    const once = await converter.normalizeTrac(fs.readFileSync(path.join(casesDir, f), 'utf8'));
    const twice = await converter.normalizeTrac(once);
    if (once === twice) ok(`idempotence ${f}`);
    else fail(`idempotence ${f}`);
  }
}

async function testReaderCases() {
  const files = fs.readdirSync(readerCasesDir).sort();
  for (const f of files) {
    if (!f.endsWith('.trac')) continue;
    const base = path.basename(f, '.trac');
    const expected = fs.readFileSync(path.join(readerCasesDir, `${base}.expected`), 'utf8');
    const input = fs.readFileSync(path.join(readerCasesDir, f), 'utf8');
    const markdown = await converter.toMarkdown(input, { camelcase: base.includes('camelcase') });
    if (markdown === expected) ok(`reader ${f}`);
    else {
      fail(`reader ${f}`);
      showDiff(expected, markdown);
    }
  }
}

function makeClient(proc) {
  const pending = new Map();
  const rl = readline.createInterface({ input: proc.stdout });
  rl.on('line', (line) => {
    if (!line.trim()) return;
    const msg = JSON.parse(line);
    if (msg.id === undefined) return;
    const p = pending.get(msg.id);
    if (p) {
      pending.delete(msg.id);
      p.resolve(msg);
    }
  });
  let nextId = 1;
  return {
    close: () => rl.close(),
    send(method, params) {
      const id = nextId++;
      const msg = { jsonrpc: '2.0', id, method };
      if (params !== undefined) msg.params = params;
      proc.stdin.write(JSON.stringify(msg) + '\n');
      return new Promise((resolve, reject) => {
        const timer = setTimeout(() => {
          if (pending.delete(id)) reject(new Error(`timeout waiting for ${method}`));
        }, 15000);
        pending.set(id, { resolve: (m) => { clearTimeout(timer); resolve(m); } });
      });
    },
  };
}

async function testProtocol() {
  const proc = spawn(process.execPath, [path.join(__dirname, '..', 'index.js')], {
    stdio: ['pipe', 'pipe', 'pipe'],
  });
  let stderr = '';
  proc.stderr.on('data', (d) => { stderr += d; });
  const client = makeClient(proc);
  try {
    const init = await client.send('initialize', {
      protocolVersion: '2024-11-05',
      capabilities: {},
      clientInfo: { name: 'pandoc-tracwiki-test', version: '0.0.0' },
    });
    if (init.result && init.result.serverInfo && init.result.serverInfo.name === 'pandoc-tracwiki') {
      ok('protocol initialize');
    } else {
      fail('protocol initialize');
      console.log(`  got: ${JSON.stringify(init)}`);
    }

    client.send('notifications/initialized', {});

    const list = await client.send('tools/list', {});
    const names = list.result.tools.map((t) => t.name).sort();
    const expectedNames = ['markdown_to_tracwiki', 'normalize_tracwiki', 'tracwiki_to_markdown'];
    if (JSON.stringify(names) === JSON.stringify(expectedNames)) {
      ok('protocol tools/list');
    } else {
      fail('protocol tools/list');
      console.log(`  got: ${JSON.stringify(names)}`);
    }

    const cases = [
      {
        name: 'tracwiki_to_markdown',
        label: 'protocol tracwiki_to_markdown',
        params: { name: 'tracwiki_to_markdown', arguments: { tracwiki: '= Hi =\n' } },
        expectedText: '# Hi\n',
        assertError: false,
      },
      {
        name: 'markdown_to_tracwiki',
        label: 'protocol markdown_to_tracwiki',
        params: { name: 'markdown_to_tracwiki', arguments: { markdown: '# Hi\n' } },
        expectedText: '= Hi =\n',
        assertError: false,
      },
      {
        name: 'normalize_tracwiki',
        label: 'protocol normalize_tracwiki',
        params: { name: 'normalize_tracwiki', arguments: { tracwiki: '= Hi =\n' } },
        expectedText: '= Hi =\n',
        assertError: false,
      },
      {
        name: 'markdown_to_tracwiki_bad_format',
        label: 'protocol error on bad format',
        params: { name: 'markdown_to_tracwiki', arguments: { markdown: 'x', format: 'not-a-real-format' } },
        expectedText: null,
        assertError: true,
      },
    ];

    for (const c of cases) {
      const res = await client.send('tools/call', c.params);
      const result = res.result || {};
      const text = result.content && result.content[0] ? result.content[0].text : null;
      const failed = result.isError === true;
      if (c.assertError) {
        if (failed && text !== null) ok(c.label);
        else {
          fail(c.label);
          console.log(`  expected error, got: ${JSON.stringify(result)}`);
        }
      } else if (!failed && text === c.expectedText) {
        ok(c.label);
      } else {
        fail(c.label);
        console.log(`  expected ${JSON.stringify(c.expectedText)}, got ${JSON.stringify(text)}`);
      }
    }
  } finally {
    proc.kill();
    client.close();
  }
  if (stderr.trim()) console.log(`(server stderr: ${stderr.trim()})`);
}

(async function main() {
  await testWriterCases();
  await testReaderCases();
  await testProtocol();
  if (failures > 0) {
    console.log(`${failures} test(s) failed`);
    process.exit(1);
  }
  console.log('all MCP tests passed');
})();
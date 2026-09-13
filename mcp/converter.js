'use strict';

const { spawn } = require('node:child_process');
const path = require('node:path');

const MAX_INPUT_CHARS = 1_000_000;
const TIMEOUT_MS = 15_000;
const MAX_OUTPUT_BYTES = 16 * 1024 * 1024;

function resolvePandoc() {
  return process.env.PANDOC_TRACWIKI_PANDOC || 'pandoc';
}

function resolveLuaScript() {
  const fromEnv = process.env.PANDOC_TRACWIKI_LUA;
  if (fromEnv) return path.resolve(fromEnv);
  return path.resolve(__dirname, '..', 'tracwiki.lua');
}

function readerFlavor(camelcase) {
  const lua = resolveLuaScript();
  return camelcase ? `${lua}+camelcase` : lua;
}

function coerce(text) {
  return typeof text === 'string' ? text : String(text ?? '');
}

function checkSize(text) {
  if (text.length > MAX_INPUT_CHARS) {
    throw new Error(`input too large (${text.length} chars, max ${MAX_INPUT_CHARS})`);
  }
}

function run(args, input) {
  return new Promise((resolve, reject) => {
    const child = spawn(resolvePandoc(), args, { stdio: ['pipe', 'pipe', 'pipe'] });
    let stdout = '';
    let stderr = '';
    let settled = false;
    const timer = setTimeout(() => {
      child.kill('SIGTERM');
    }, TIMEOUT_MS);
    child.stdout.on('data', (d) => {
      stdout += d;
      if (stdout.length > MAX_OUTPUT_BYTES) {
        settled = true;
        clearTimeout(timer);
        child.kill('SIGTERM');
        reject(new Error(`output too large (over ${MAX_OUTPUT_BYTES} bytes)`));
      }
    });
    child.stderr.on('data', (d) => { stderr += d; });
    child.on('error', (err) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      if (err.code === 'ENOENT') {
        reject(new Error('pandoc executable not found; set PANDOC_TRACWIKI_PANDOC to its path'));
      } else {
        reject(new Error(String(err.message || err)));
      }
    });
    child.on('close', (code, signal) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      if (code === 0) {
        resolve(stdout);
      } else if (signal === 'SIGTERM') {
        reject(new Error(`pandoc timed out after ${TIMEOUT_MS}ms`));
      } else {
        reject(new Error(stderr.trim() || `pandoc exited with code ${code}`));
      }
    });
    child.stdin.on('error', () => {});
    child.stdin.end(input);
  });
}

async function toTrac(markdown, options = {}) {
  const format = options.format || 'markdown-tex_math_dollars';
  const text = coerce(markdown);
  checkSize(text);
  const args = [`--from=${format}`, `--to=${resolveLuaScript()}`];
  if (options.standalone) args.push('--standalone');
  return run(args, text);
}

async function toMarkdown(tracwiki, options = {}) {
  const text = coerce(tracwiki);
  checkSize(text);
  return run([`--from=${readerFlavor(options.camelcase)}`, '--to=markdown'], text);
}

async function normalizeTrac(tracwiki) {
  const text = coerce(tracwiki);
  checkSize(text);
  const lua = resolveLuaScript();
  return run([`--from=${lua}`, `--to=${lua}`], text);
}

module.exports = {
  toTrac,
  toMarkdown,
  normalizeTrac,
  resolveLuaScript,
  MAX_INPUT_CHARS,
  TIMEOUT_MS,
};
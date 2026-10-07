#!/usr/bin/env node
// Generate this repository's copies of the pinned versions from the one file
// they are edited in, packages/app-tooling/versions.json:
//
//   scripts/lib/versions.sh               from its `shell` list (every line)
//   packages/app-tooling/lib/versions.sh  the package's byte-identical copy
//   .mise.toml                            from its `mise` list, between the
//                                         versions:start / versions:end markers
//                                         only; the rest of the file is kept
//
// Usage: render-versions.mjs [--check]   fail naming every generated file that
//                                        is not what versions.json generates
//        render-versions.mjs --write     rewrite every generated file
//
// `make check-version-pins` runs the check. A version is never edited in a
// generated file: change versions.json and run --write.
import { readFileSync, writeFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

export const ROOT = path.join(path.dirname(fileURLToPath(import.meta.url)), '..', '..');
export const SOURCE = 'packages/app-tooling/versions.json';
export const SHELL_FILES = ['scripts/lib/versions.sh', 'packages/app-tooling/lib/versions.sh'];
export const MISE_FILE = '.mise.toml';
export const MISE_START = '# versions:start';
export const MISE_END = '# versions:end';
export const FIX = 'node scripts/self/render-versions.mjs --write';
const HEADER = `Generated from ${SOURCE} by scripts/self/render-versions.mjs - do not edit.`;
const HOW = `Change a version in versions.json, then run: ${FIX}`;

// What may appear inside the double quotes of a generated line: nothing a
// shell expands, quotes or runs, and nothing TOML would need escaped.
const SAFE_VALUE = /^[A-Za-z0-9_./ -]+$/;
const SHELL_NAME = /^[A-Z][A-Z0-9_]*$/;
const BARE_KEY = /^[A-Za-z0-9_-]+$/;

/** `# line` for each comment line, a bare `#` for an empty one. */
function commentLines(entry) {
  return (entry.comment ?? []).map((line) => (line === '' ? '#' : `# ${line}`));
}

/**
 * The version of one entry: from `tools` when it names a tool there, from its
 * own `own` field (`version` or `value`) otherwise - never both, so a version
 * is written once.
 */
function resolve(table, entry, own, where) {
  if (entry.tool !== undefined && table.tools?.[entry.tool] !== undefined) {
    if (entry[own] !== undefined) {
      throw new Error(`${where} names the tool ${entry.tool}, whose version is in tools, and also sets its own ${own}; keep one`);
    }
    return table.tools[entry.tool].version;
  }
  if (entry[own] === undefined) {
    throw new Error(entry.tool === undefined ? `${where} has neither tool nor ${own}` : `${where} names ${entry.tool}, which is not in tools, and sets no ${own}`);
  }
  return entry[own];
}

function safe(value, where) {
  if (typeof value !== 'string' || !SAFE_VALUE.test(value)) {
    throw new Error(`${where} has the value ${JSON.stringify(value)}, which is not a plain string of letters, digits, dots, dashes, slashes, underscores and spaces`);
  }
  return value;
}

function list(table, key) {
  if (!Array.isArray(table[key])) throw new Error(`${SOURCE} has no ${key} list`);
  return table[key];
}

/** The whole of scripts/lib/versions.sh. */
export function renderShell(table) {
  const lines = ['#!/usr/bin/env bash', `# ${HEADER}`, `# ${HOW}`, '# shellcheck shell=bash'];
  list(table, 'shell').forEach((entry, index) => {
    const where = `${SOURCE} shell[${index}]`;
    if (typeof entry.name !== 'string' || !SHELL_NAME.test(entry.name)) {
      throw new Error(`${where} has the name ${JSON.stringify(entry.name)}, which is not an upper-case shell variable name`);
    }
    const value = safe(resolve(table, entry, 'value', `${where} (${entry.name})`), `${where} (${entry.name})`);
    lines.push(...commentLines(entry), `export ${entry.name}="${value}"`);
  });
  return `${lines.join('\n')}\n`;
}

/** The [tools] block of .mise.toml, without the markers around it. */
export function renderMise(table) {
  const lines = [`# ${HEADER}`, `# ${HOW}`, '[tools]'];
  list(table, 'mise').forEach((entry, index) => {
    const where = `${SOURCE} mise[${index}]`;
    if (typeof entry.tool !== 'string' || entry.tool === '') throw new Error(`${where} has no tool`);
    const version = safe(resolve(table, entry, 'version', `${where} (${entry.tool})`), `${where} (${entry.tool})`);
    const key = BARE_KEY.test(entry.tool) ? entry.tool : JSON.stringify(entry.tool);
    lines.push(...commentLines(entry), `${key} = "${version}"`);
  });
  return `${lines.join('\n')}\n`;
}

/** `text` with everything between the two marker lines replaced by `block`. */
export function splice(text, block) {
  const lines = text.split('\n');
  const start = lines.indexOf(MISE_START);
  if (start === -1) throw new Error(`${MISE_FILE} has lost its ${MISE_START} line; put it back above the [tools] block`);
  const end = lines.indexOf(MISE_END, start + 1);
  if (end === -1) throw new Error(`${MISE_FILE} has no ${MISE_END} line after ${MISE_START}; put it back below the [tools] block`);
  return [...lines.slice(0, start + 1), block.replace(/\n$/, ''), ...lines.slice(end)].join('\n');
}

/** Every generated file and the text it should hold, given a reader. */
export function render(table, read) {
  const shell = renderShell(table);
  return [
    ...SHELL_FILES.map((file) => ({ file, text: shell })),
    { file: MISE_FILE, text: splice(read(MISE_FILE), renderMise(table)) },
  ];
}

function readSource(read) {
  let raw;
  try {
    raw = read(SOURCE);
  } catch (error) {
    throw new Error(`cannot read ${SOURCE}: ${error.message}`);
  }
  try {
    return JSON.parse(raw);
  } catch (error) {
    throw new Error(`${SOURCE} is not valid JSON: ${error.message}`);
  }
}

/**
 * The whole program, returning its exit code. The root, the file reader and
 * writer and both output streams arrive through `io`, so the tests run every
 * path in-process against a tree of their own; the defaults are the real ones.
 */
export function main(argv, io = {}) {
  const root = io.root ?? ROOT;
  const out = io.out ?? ((line) => process.stdout.write(`${line}\n`));
  const err = io.err ?? ((line) => process.stderr.write(`${line}\n`));
  const read = (file) => readFileSync(path.join(root, file), 'utf8');
  const current = (file) => {
    try {
      return read(file);
    } catch {
      return null;
    }
  };
  if (argv.length > 1 || (argv.length === 1 && !['--check', '--write'].includes(argv[0]))) {
    err(`::error::unknown arguments: ${argv.join(' ')} (usage: render-versions.mjs [--check|--write])`);
    return 2;
  }
  const write = argv[0] === '--write';
  let files;
  try {
    const table = readSource(read);
    files = render(table, (file) => {
      try {
        return read(file);
      } catch (error) {
        throw new Error(`cannot read ${file}: ${error.message}`);
      }
    });
  } catch (error) {
    err(`::error::${error.message}`);
    return 1;
  }
  const stale = files.filter(({ file, text }) => current(file) !== text);
  if (write) {
    for (const { file, text } of stale) writeFileSync(path.join(root, file), text);
    out(stale.length === 0 ? 'generated versions already up to date' : `rewrote ${stale.map(({ file }) => file).join(', ')}`);
    return 0;
  }
  for (const { file } of stale) {
    err(`::error::${file} is not what ${SOURCE} generates - edit versions.json, never this file, then run: ${FIX}`);
  }
  return stale.length === 0 ? 0 : 1;
}

if (import.meta.main) process.exitCode = main(process.argv.slice(2));

// scripts/self/render-versions.mjs: the program that generates
// scripts/lib/versions.sh, the package's copy of it and the [tools] block of
// .mise.toml from packages/app-tooling/versions.json, and fails
// `make check-version-pins` when any of them has drifted.
//
// Covered here: what each generated file reads like from a fixture
// versions.json (the header, comments with an empty line, a version taken from
// `tools`, one of the entry's own, a key TOML has to quote); every refusal of a
// malformed entry; the splice between the .mise.toml markers, which leaves the
// rest of the file byte-identical, and its refusal when a marker is gone; and
// the program over a tree of its own - the check passing on generated files,
// failing on a hand edit of each one or a missing one and naming the file and
// the fix, --write rewriting and saying so, a missing or malformed
// versions.json, a missing .mise.toml or marker, and bad arguments. Last, that
// the committed files are what the generator writes, run as a program.
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdirSync, mkdtempSync, readFileSync, rmSync, unlinkSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { after, test } from 'node:test';
import { fileURLToPath } from 'node:url';
import {
  FIX,
  MISE_END,
  MISE_FILE,
  MISE_START,
  ROOT,
  SHELL_FILES,
  SOURCE,
  main,
  renderMise,
  renderShell,
  splice,
} from '../scripts/self/render-versions.mjs';

const REPO = path.join(path.dirname(fileURLToPath(import.meta.url)), '..');
const SCRIPT = path.join(REPO, 'scripts/self/render-versions.mjs');
const scratch = mkdtempSync(path.join(tmpdir(), 'render-versions-'));
after(() => rmSync(scratch, { recursive: true, force: true }));

const HEADER = [
  '# Generated from packages/app-tooling/versions.json by scripts/self/render-versions.mjs - do not edit.',
  '# Change a version in versions.json, then run: node scripts/self/render-versions.mjs --write',
];

const FIXTURE = {
  tools: {
    yq: { version: '4.53.6', args: ['--version'], match: 'exact' },
    node: { version: '24', args: ['--version'], match: 'major' },
  },
  mise: [
    { tool: 'yq' },
    { tool: 'node', comment: ['Major only.'] },
    { tool: 'act', version: '0.2.89', comment: ['First line.', '', 'After a gap.'] },
    { tool: 'aqua:owner/tool', version: '1.0.0' },
  ],
  shell: [
    { name: 'MAESTRO_VERSION', value: '2.10.0' },
    { name: 'MAESTRO_SHA256', value: 'ab12', comment: ['The zip.', ''] },
    { name: 'YQ_VERSION', tool: 'yq' },
    { name: 'NAMES', value: 'ndk/27.0 build-tools/35.0.0' },
  ],
};

const SHELL_TEXT = [
  '#!/usr/bin/env bash',
  ...HEADER,
  '# shellcheck shell=bash',
  'export MAESTRO_VERSION="2.10.0"',
  '# The zip.',
  '#',
  'export MAESTRO_SHA256="ab12"',
  'export YQ_VERSION="4.53.6"',
  'export NAMES="ndk/27.0 build-tools/35.0.0"',
  '',
].join('\n');

const MISE_BLOCK = [
  ...HEADER,
  '[tools]',
  'yq = "4.53.6"',
  '# Major only.',
  'node = "24"',
  '# First line.',
  '#',
  '# After a gap.',
  'act = "0.2.89"',
  '"aqua:owner/tool" = "1.0.0"',
  '',
].join('\n');

// What surrounds the markers in a fixture .mise.toml, which the generator
// must leave exactly as it is.
const BEFORE = '# A comment above the markers, kept.\n';
const AFTER = '\n[env]\nFOO = "bar"\n';

const fixed = (table) => structuredClone(table);
const withEntry = (key, entry) => ({ ...fixed(FIXTURE), [key]: [entry] });

// --- the generated text ----------------------------------------------------

test('versions.sh is the header, then each entry with its comment, in order', () => {
  assert.equal(renderShell(FIXTURE), SHELL_TEXT);
});

test('the [tools] block takes a listed tool from tools, its own version otherwise, and quotes a key TOML cannot leave bare', () => {
  assert.equal(renderMise(FIXTURE), MISE_BLOCK);
});

// --- refusals --------------------------------------------------------------

test('an entry naming a tool in tools and also setting its own version is refused, so a version is written once', () => {
  assert.throws(() => renderShell(withEntry('shell', { name: 'YQ_VERSION', tool: 'yq', value: '1' })), /shell\[0\] \(YQ_VERSION\) names the tool yq, whose version is in tools, and also sets its own value; keep one/);
  assert.throws(() => renderMise(withEntry('mise', { tool: 'yq', version: '1' })), /mise\[0\] \(yq\) names the tool yq, whose version is in tools, and also sets its own version; keep one/);
});

test('an entry with neither a tool nor a value of its own is refused', () => {
  assert.throws(() => renderShell(withEntry('shell', { name: 'LOST' })), /shell\[0\] \(LOST\) has neither tool nor value/);
});

test('an entry naming a tool that is not in tools, with no version of its own, is refused', () => {
  assert.throws(() => renderMise(withEntry('mise', { tool: 'act' })), /mise\[0\] \(act\) names act, which is not in tools, and sets no version/);
  assert.throws(() => renderMise({ mise: [{ tool: 'act' }] }), /names act, which is not in tools/);
});

test('a shell name that is not an upper-case variable name is refused', () => {
  assert.throws(() => renderShell(withEntry('shell', { name: 'lower', value: '1' })), /shell\[0\] has the name "lower", which is not an upper-case shell variable name/);
  assert.throws(() => renderShell(withEntry('shell', { value: '1' })), /has the name undefined/);
});

test('a value a shell would expand or TOML would need escaped is refused', () => {
  assert.throws(() => renderShell(withEntry('shell', { name: 'X', value: '$(rm -rf /)' })), /shell\[0\] \(X\) has the value "\$\(rm -rf \/\)", which is not a plain string/);
  assert.throws(() => renderMise(withEntry('mise', { tool: 'act', version: '1"2' })), /mise\[0\] \(act\) has the value "1\\"2"/);
  assert.throws(() => renderShell(withEntry('shell', { name: 'X', value: 34 })), /has the value 34/);
});

test('a mise entry without a tool is refused', () => {
  assert.throws(() => renderMise(withEntry('mise', { version: '1' })), /mise\[0\] has no tool/);
  assert.throws(() => renderMise(withEntry('mise', { tool: '', version: '1' })), /mise\[0\] has no tool/);
});

test('a versions.json without the shell or mise list is refused', () => {
  assert.throws(() => renderShell({ tools: {} }), new RegExp(`${SOURCE} has no shell list`));
  assert.throws(() => renderMise({ tools: {}, mise: {} }), new RegExp(`${SOURCE} has no mise list`));
});

// --- the splice ------------------------------------------------------------

test('the splice replaces only what is between the markers', () => {
  const text = `${BEFORE}${MISE_START}\nold = "1"\n${MISE_END}${AFTER}`;
  assert.equal(splice(text, 'new = "2"\n'), `${BEFORE}${MISE_START}\nnew = "2"\n${MISE_END}${AFTER}`);
});

test('the splice refuses a file that has lost either marker', () => {
  assert.throws(() => splice(`[tools]\n${MISE_END}\n`, ''), /\.mise\.toml has lost its # versions:start line/);
  assert.throws(() => splice(`${MISE_START}\n[tools]\n`, ''), /\.mise\.toml has no # versions:end line after # versions:start/);
  assert.throws(() => splice(`${MISE_END}\n${MISE_START}\n`, ''), /has no # versions:end line after/);
});

// --- the program, over a tree of its own -----------------------------------

let trees = 0;
/** A fresh tree holding a fixture versions.json and, unless told otherwise, generated files. */
function tree({ table = FIXTURE, generated = true, mise = `${BEFORE}${MISE_START}\n${MISE_END}${AFTER}` } = {}) {
  const root = path.join(scratch, `tree-${(trees += 1)}`);
  for (const dir of ['packages/app-tooling/lib', 'scripts/lib']) mkdirSync(path.join(root, dir), { recursive: true });
  writeFileSync(path.join(root, SOURCE), typeof table === 'string' ? table : JSON.stringify(table));
  if (mise !== null) writeFileSync(path.join(root, MISE_FILE), mise);
  if (generated) {
    for (const file of SHELL_FILES) writeFileSync(path.join(root, file), SHELL_TEXT);
    writeFileSync(path.join(root, MISE_FILE), `${BEFORE}${MISE_START}\n${MISE_BLOCK}${MISE_END}${AFTER}`);
  }
  return root;
}

function run(argv, root) {
  const out = [];
  const err = [];
  const code = main(argv, { root, out: (line) => out.push(line), err: (line) => err.push(line) });
  return { code, out, err };
}

const read = (root, file) => readFileSync(path.join(root, file), 'utf8');
const stale = (file) => `::error::${file} is not what ${SOURCE} generates - edit versions.json, never this file, then run: ${FIX}`;

test('the check passes silently when every generated file is what versions.json generates, with or without --check', () => {
  const root = tree();
  assert.deepEqual(run(['--check'], root), { code: 0, out: [], err: [] });
  assert.deepEqual(run([], root), { code: 0, out: [], err: [] });
});

test('a hand edit of versions.sh fails the check, naming the file and the command that fixes it', () => {
  const root = tree();
  writeFileSync(path.join(root, 'scripts/lib/versions.sh'), SHELL_TEXT.replace('4.53.6', '4.53.7'));
  assert.deepEqual(run([], root), { code: 1, out: [], err: [stale('scripts/lib/versions.sh')] });
});

test('a hand edit of the [tools] block fails the check, naming .mise.toml and the fix', () => {
  const root = tree();
  writeFileSync(path.join(root, MISE_FILE), read(root, MISE_FILE).replace('act = "0.2.89"', 'act = "0.2.90"'));
  assert.deepEqual(run([], root), { code: 1, out: [], err: [stale(MISE_FILE)] });
});

test('an edit outside the markers is not drift', () => {
  const root = tree();
  writeFileSync(path.join(root, MISE_FILE), `${read(root, MISE_FILE)}BAR = "baz"\n`);
  assert.equal(run([], root).code, 0);
});

test('a missing generated file is drift too, and every stale file is named in one run', () => {
  const root = tree({ generated: false });
  assert.deepEqual(run([], root), { code: 1, out: [], err: [...SHELL_FILES, MISE_FILE].map(stale) });
});

test('--write rewrites every stale file, leaves the rest of .mise.toml as it was, and says what it rewrote', () => {
  const root = tree({ generated: false });
  writeFileSync(path.join(root, 'scripts/lib/versions.sh'), SHELL_TEXT);
  assert.deepEqual(run(['--write'], root), {
    code: 0,
    out: ['rewrote packages/app-tooling/lib/versions.sh, .mise.toml'],
    err: [],
  });
  for (const file of SHELL_FILES) assert.equal(read(root, file), SHELL_TEXT);
  assert.equal(read(root, MISE_FILE), `${BEFORE}${MISE_START}\n${MISE_BLOCK}${MISE_END}${AFTER}`);
  assert.equal(run([], root).code, 0);
});

test('--write on files that are already current says there was nothing to do', () => {
  assert.deepEqual(run(['--write'], tree()), { code: 0, out: ['generated versions already up to date'], err: [] });
});

test('a missing versions.json stops it with an error naming the file', () => {
  const root = tree();
  unlinkSync(path.join(root, SOURCE));
  const result = run([], root);
  assert.equal(result.code, 1);
  assert.match(result.err.join('\n'), /^::error::cannot read packages\/app-tooling\/versions\.json: ENOENT/);
});

test('a versions.json that is not JSON stops it with an error naming the file', () => {
  const result = run(['--write'], tree({ table: '{ "tools": ', generated: false }));
  assert.equal(result.code, 1);
  assert.match(result.err.join('\n'), /^::error::packages\/app-tooling\/versions\.json is not valid JSON: /);
  assert.deepEqual(result.out, []);
});

test('a malformed entry stops it before anything is written', () => {
  const root = tree({ table: withEntry('shell', { name: 'X' }), generated: false });
  const result = run(['--write'], root);
  assert.equal(result.code, 1);
  assert.deepEqual(result.err, [`::error::${SOURCE} shell[0] (X) has neither tool nor value`]);
  assert.throws(() => read(root, 'scripts/lib/versions.sh'), /ENOENT/);
});

test('a missing .mise.toml stops it with an error naming the file', () => {
  const result = run([], tree({ generated: false, mise: null }));
  assert.equal(result.code, 1);
  assert.match(result.err.join('\n'), /^::error::cannot read \.mise\.toml: ENOENT/);
});

test('a .mise.toml without its markers stops it with an error saying where they go', () => {
  const result = run([], tree({ generated: false, mise: '[tools]\nnode = "24"\n' }));
  assert.equal(result.code, 1);
  assert.deepEqual(result.err, [`::error::.mise.toml has lost its ${MISE_START} line; put it back above the [tools] block`]);
});

test('an unknown argument, or more than one, is a usage error', () => {
  const usage = (args) => `::error::unknown arguments: ${args} (usage: render-versions.mjs [--check|--write])`;
  assert.deepEqual(run(['--fix'], tree()), { code: 2, out: [], err: [usage('--fix')] });
  assert.deepEqual(run(['--check', '--write'], tree()), { code: 2, out: [], err: [usage('--check --write')] });
});

test('without io it writes to the real stdout and stderr', (t) => {
  const root = tree({ generated: false });
  const stderr = t.mock.method(process.stderr, 'write', () => true);
  assert.equal(main([], { root }), 1);
  assert.equal(stderr.mock.calls[0].arguments[0], `${stale(SHELL_FILES[0])}\n`);
  stderr.mock.restore();
  const stdout = t.mock.method(process.stdout, 'write', () => true);
  assert.equal(main(['--write'], { root }), 0);
  stdout.mock.restore();
  assert.match(stdout.mock.calls[0].arguments[0], /^rewrote /);
});

// --- the real files --------------------------------------------------------

test('the committed versions.sh, its package copy and .mise.toml are what versions.json generates', () => {
  assert.equal(ROOT, REPO);
  assert.deepEqual(run([], REPO), { code: 0, out: [], err: [] });
});

test('run as a program, the check passes on the committed files', () => {
  // The environment spreads process.env so the coverage directory the test
  // runner sets reaches the child.
  const result = spawnSync(process.execPath, [SCRIPT, '--check'], { encoding: 'utf8', env: { ...process.env } });
  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.stderr, '');
});

test('imported, it runs nothing', () => {
  const result = spawnSync(process.execPath, ['--input-type=module', '-e', `await import(${JSON.stringify(SCRIPT)}); console.log('imported');`], {
    encoding: 'utf8',
    env: { ...process.env },
  });
  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.stdout, 'imported\n');
});

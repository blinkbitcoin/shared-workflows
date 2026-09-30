import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { chmodSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';
import { DEFAULT_ALLOWED, findViolations, licenseAllowed, main, parseArgs } from './bin/check-licenses.mjs';

const BIN = fileURLToPath(new URL('./bin/check-licenses.mjs', import.meta.url));

test('flags packages outside the allowlist and ignores allowed ones', () => {
  const report = {
    MIT: [{ name: 'a' }],
    'GPL-3.0': [{ name: 'b' }],
    '(MIT OR Apache-2.0)': [{ name: 'c' }],
  };
  assert.deepEqual(findViolations(report), [{ name: 'b', license: 'GPL-3.0' }]);
});

test('OR expression is allowed when any alternative is allowed', () => {
  assert.deepEqual(findViolations({ '(MIT OR GPL-3.0)': [{ name: 'a' }] }), []);
});

test('AND expression is a violation unless every conjunct is allowed', () => {
  assert.deepEqual(findViolations({ '(GPL-3.0 AND MIT)': [{ name: 'a' }] }), [{ name: 'a', license: '(GPL-3.0 AND MIT)' }]);
});

test('AND expression is allowed when every conjunct is allowed', () => {
  assert.deepEqual(findViolations({ 'MIT AND Apache-2.0': [{ name: 'a' }] }), []);
});

test('plain unknown license string is a violation', () => {
  assert.deepEqual(findViolations({ UNLICENSED: [{ name: 'a' }] }), [{ name: 'a', license: 'UNLICENSED' }]);
});

test('a nested group is conservatively a violation', () => {
  assert.deepEqual(findViolations({ '((MIT OR ISC) AND Apache-2.0)': [{ name: 'a' }] }), [
    { name: 'a', license: '((MIT OR ISC) AND Apache-2.0)' },
  ]);
});

test("the organisation's default holds the licences the template accepted", () => {
  assert.deepEqual(DEFAULT_ALLOWED, [
    'MIT',
    'Apache-2.0',
    'BSD-2-Clause',
    'BSD-3-Clause',
    'ISC',
    '0BSD',
    'CC0-1.0',
    'Unlicense',
    'MPL-2.0',
    'CC-BY-4.0',
    'Python-2.0',
    'BlueOak-1.0.0',
  ]);
});

test('a wider allowlist lets a licence through that the default refuses', () => {
  assert.equal(licenseAllowed('LGPL-3.0-only'), false);
  assert.equal(licenseAllowed('LGPL-3.0-only', [...DEFAULT_ALLOWED, 'LGPL-3.0-only']), true);
});

test('parseArgs takes each --allow and --root, and refuses anything else', () => {
  assert.deepEqual(parseArgs(['--allow', 'LGPL-3.0-only', '--allow', 'Zlib', '--root', 'app'], '/w'), {
    root: path.resolve('/w', 'app'),
    extra: ['LGPL-3.0-only', 'Zlib'],
  });
  assert.deepEqual(parseArgs([], '/w'), { root: '/w', extra: [] });
  assert.throws(() => parseArgs(['--allow'], '/w'), /unexpected --allow: pass --allow SPDX-IDENTIFIER and --root DIR/);
  assert.throws(() => parseArgs(['--allow', 'MIT OR GPL'], '/w'), /unexpected --allow MIT OR GPL/);
  assert.throws(() => parseArgs(['--root'], '/w'), /unexpected --root/);
  assert.throws(() => parseArgs(['--nope', 'x'], '/w'), /unexpected --nope x/);
});

/** Captures what `main` writes, and answers the licence listing with `report`. */
const run = (report, argv = []) => {
  const out = [];
  const err = [];
  const roots = [];
  const code = main(argv, {
    cwd: '/repo',
    licenses: (root) => {
      roots.push(root);
      return typeof report === 'string' ? report : JSON.stringify(report);
    },
    log: (line) => out.push(line),
    error: (line) => err.push(line),
  });
  return { code, out, err, roots };
};

test('main asks for the production licences in the root and passes an allowed set', () => {
  const { code, out, err, roots } = run({ MIT: [{ name: 'a' }, { name: 'b' }], ISC: [{ name: 'c' }] });
  assert.equal(code, 0);
  assert.deepEqual(roots, ['/repo']);
  assert.deepEqual(out, ['licenses ok (3 packages)']);
  assert.deepEqual(err, []);
});

test('main names every disallowed package and fails, saying where an accepted licence goes', () => {
  const { code, out, err } = run({ 'GPL-3.0': [{ name: 'b' }, { name: 'c' }] });
  assert.equal(code, 1);
  assert.deepEqual(out, []);
  assert.deepEqual(err, [
    'disallowed license GPL-3.0: b',
    'disallowed license GPL-3.0: c',
    'licenses: 2 package(s) outside the allowlist; a licence this repository accepts goes in an --allow',
  ]);
});

test('an --allow passes a licence the default refuses', () => {
  assert.equal(run({ 'LGPL-3.0-only': [{ name: 'a' }] }, ['--allow', 'LGPL-3.0-only']).code, 0);
});

test('main fails on a report it cannot read, and on a bad argument', () => {
  const broken = run('not json');
  assert.equal(broken.code, 1);
  assert.match(broken.err[0], /^licenses: could not read `pnpm licenses list --json --prod` in \/repo: /);
  const bad = run({}, ['--nope']);
  assert.deepEqual(bad, { code: 1, out: [], err: ['licenses: unexpected --nope: pass --allow SPDX-IDENTIFIER and --root DIR'], roots: [] });
});

test('as a command it reads the report from pnpm on PATH, in --root', (t) => {
  const bin = mkdtempSync(path.join(tmpdir(), 'check-licenses-bin-'));
  t.after(() => rmSync(bin, { recursive: true, force: true }));
  const pnpm = path.join(bin, 'pnpm');
  writeFileSync(pnpm, '#!/bin/sh\n[ "$*" = "licenses list --json --prod" ] || exit 9\necho "{\\"GPL-3.0\\":[{\\"name\\":\\"$(basename "$PWD")\\"}]}"\n');
  chmodSync(pnpm, 0o755);
  const result = spawnSync(process.execPath, [BIN, '--root', bin], {
    encoding: 'utf8',
    env: { ...process.env, PATH: `${bin}${path.delimiter}${process.env.PATH}` },
  });
  assert.equal(result.status, 1);
  assert.match(result.stderr, new RegExp(`^disallowed license GPL-3.0: ${path.basename(bin)}\n`));
});

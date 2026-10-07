import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { after, test } from 'node:test';
import { fileURLToPath } from 'node:url';
import { foreignResolutions, main } from './bin/check-lockfile.mjs';

const BIN = fileURLToPath(new URL('./bin/check-lockfile.mjs', import.meta.url));
const SHA = 'e'.repeat(40);
const OTHER = 'f'.repeat(40);
const REGISTRY = '    resolution: {integrity: sha512-abc==}';
const OFF_PATH = '    resolution: {integrity: sha512-abc==, tarball: https://registry.npmjs.org/@scope/x/-/x-1.0.0.tgz}';
const shared = (sha, dir = '/packages/app-tooling', repo = 'blinkbitcoin/shared-workflows') =>
  `    resolution: {gitHosted: true, integrity: sha512-def==, path: ${dir}, tarball: https://codeload.github.com/${repo}/tar.gz/${sha}}`;

const dirs = [];
after(() => {
  for (const dir of dirs) rmSync(dir, { recursive: true, force: true });
});
function consumer(lockLines, sha = SHA) {
  const root = mkdtempSync(path.join(tmpdir(), 'check-lockfile-'));
  dirs.push(root);
  mkdirSync(path.join(root, '.github', 'workflows'), { recursive: true });
  writeFileSync(
    path.join(root, '.github', 'workflows', 'ci.yml'),
    `jobs:\n  code:\n    uses: blinkbitcoin/shared-workflows/.github/workflows/check.yml@${sha} # v1.0.0\n`,
  );
  if (lockLines !== null) writeFileSync(path.join(root, 'pnpm-lock.yaml'), `lockfileVersion: '9.0'\n${lockLines.join('\n')}\n`);
  return root;
}
function run(argv, cwd) {
  const out = { log: [], error: [] };
  const code = main(argv, { cwd, log: (l) => out.log.push(l), error: (l) => out.error.push(l) });
  return { code, ...out };
}

test('registry packages, with or without an explicit tarball, pass', () => {
  assert.deepEqual(foreignResolutions([REGISTRY, OFF_PATH].join('\n'), SHA), []);
});

test("this family's packages pass at the workflows pin, under any packages/ directory", () => {
  const text = [shared(SHA), shared(SHA, '/packages/another-package')].join('\n');
  assert.deepEqual(foreignResolutions(text, SHA), []);
});

test('the same package at another commit, from another repository, or outside packages/ fails', () => {
  const text = [shared(OTHER), shared(SHA, '/packages/app-tooling', 'someone/shared-workflows'), shared(SHA, '/scripts')].join('\n');
  assert.equal(foreignResolutions(text, SHA).length, 3);
});

test('with no single pin, no git source passes', () => {
  assert.deepEqual(foreignResolutions(shared(SHA), null), [`1: ${shared(SHA).trim()}`]);
});

test('with a tag, which moves, no git source passes', () => {
  assert.equal(foreignResolutions(shared(SHA), 'v0').length, 1);
});

test('any other source fails, named by line', () => {
  const text = ['lockfileVersion: 9', REGISTRY, '    resolution: {type: git, repo: https://x, commit: 1}'].join('\n');
  assert.deepEqual(foreignResolutions(text, SHA), ['3: resolution: {type: git, repo: https://x, commit: 1}']);
});

test('main reports ok for a clean lockfile', () => {
  const root = consumer([REGISTRY, shared(SHA)]);
  assert.deepEqual(run([], root), { code: 0, log: ['lockfile ok'], error: [] });
  assert.equal(run(['--root', root], '/').code, 0);
});

test('main lists every foreign resolution and fails', () => {
  const root = consumer([REGISTRY, shared(OTHER)]);
  const { code, error } = run([], root);
  assert.equal(code, 1);
  assert.deepEqual(error, ['pnpm-lock.yaml resolves packages from outside the npm registry:', `3: ${shared(OTHER).trim()}`]);
});

test('main fails without a lockfile', () => {
  const root = consumer(null);
  assert.deepEqual(run([], root), { code: 1, log: [], error: [`no pnpm-lock.yaml in ${root}`] });
});

test('a bad argument is a usage error', () => {
  assert.deepEqual(run(['--nope'], '/'), { code: 2, log: [], error: ['usage: check-lockfile [--root DIR]'] });
});

test('runs as a program', () => {
  const root = consumer([REGISTRY]);
  const result = spawnSync(process.execPath, [BIN, '--root', root], { encoding: 'utf8' });
  assert.equal(result.status, 0);
  assert.equal(result.stdout, 'lockfile ok\n');
});

test('main answers --help with its usage on stdout and exit 0, before anything else', async () => {
  const out = [];
  const err = [];
  const code = await main(['--help'], { log: (line) => out.push(line), error: (line) => err.push(line) });
  assert.equal(code, 0);
  assert.match(out.join(''), /^ +check-lockfile(?: |$)/m);
  assert.deepEqual(err, []);
});

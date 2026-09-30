import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { after, test } from 'node:test';
import { fileURLToPath } from 'node:url';
import { main, parseArgs, readCallers } from './bin/fix-tooling-pin.mjs';
import { specFor, tarballFor } from './lib/pin.mjs';

const BIN = fileURLToPath(new URL('./bin/fix-tooling-pin.mjs', import.meta.url));
const SHA = 'c'.repeat(40);
const OLD = 'd'.repeat(40);
const dirs = [];
after(() => {
  for (const dir of dirs) rmSync(dir, { recursive: true, force: true });
});

/** A consumer checkout: workflow files, a package.json and a lockfile. */
function consumer({ workflows = { 'ci.yml': callAt(SHA) }, pkg = pkgAt(OLD), lockfile = lockAt(OLD) } = {}) {
  const root = mkdtempSync(path.join(tmpdir(), 'fix-tooling-pin-'));
  dirs.push(root);
  mkdirSync(path.join(root, '.github', 'workflows'), { recursive: true });
  for (const [name, text] of Object.entries(workflows)) writeFileSync(path.join(root, '.github', 'workflows', name), text);
  if (pkg !== null) writeFileSync(path.join(root, 'package.json'), `${JSON.stringify(pkg, null, 2)}\n`);
  if (lockfile !== null) writeFileSync(path.join(root, 'pnpm-lock.yaml'), lockfile);
  return root;
}
function callAt(sha) {
  return `jobs:\n  code:\n    uses: blinkbitcoin/shared-workflows/.github/workflows/check.yml@${sha} # v1.0.0\n`;
}
function pkgAt(sha) {
  return {
    name: 'app',
    dependencies: { '@blinkbitcoin/expo-runtime': specFor(sha, '/packages/expo-runtime') },
    devDependencies: { '@blinkbitcoin/app-tooling': specFor(sha, '/packages/app-tooling'), typescript: '^6.0.0' },
  };
}
function lockAt(sha) {
  return ['/packages/expo-runtime', '/packages/app-tooling'].map((dir) => `    version: ${tarballFor(sha, dir)}\n`).join('');
}
/** An io that records what it was told and, as `pnpm install`, writes `lockfile`. */
function io(root, lockfile) {
  const out = { log: [], error: [], exec: [] };
  return {
    out,
    options: {
      cwd: root,
      log: (line) => out.log.push(line),
      error: (line) => out.error.push(line),
      exec: (cmd, args, opts) => {
        out.exec.push([cmd, args, opts.cwd]);
        if (lockfile !== undefined) writeFileSync(path.join(root, 'pnpm-lock.yaml'), lockfile);
      },
    },
  };
}

test('moves every package of this family to the workflows pin, relocks, and says so', () => {
  const root = consumer();
  const { out, options } = io(root, lockAt(SHA));
  assert.equal(main([], options), 0);
  const pkg = JSON.parse(readFileSync(path.join(root, 'package.json'), 'utf8'));
  assert.equal(pkg.devDependencies['@blinkbitcoin/app-tooling'], specFor(SHA, '/packages/app-tooling'));
  assert.equal(pkg.dependencies['@blinkbitcoin/expo-runtime'], specFor(SHA, '/packages/expo-runtime'));
  assert.equal(pkg.devDependencies.typescript, '^6.0.0');
  assert.deepEqual(out.exec, [['pnpm', ['install'], root]]);
  assert.deepEqual(out.log, [`@blinkbitcoin/expo-runtime, @blinkbitcoin/app-tooling at the workflows pin, ${SHA}`]);
  assert.deepEqual(out.error, []);
});

test('--root works on another directory', () => {
  const root = consumer();
  const { options } = io(root, lockAt(SHA));
  assert.equal(main(['--root', root], { ...options, cwd: '/' }), 0);
});

test('fails when the install leaves the lockfile behind', () => {
  const root = consumer();
  const { out, options } = io(root, lockAt(OLD));
  assert.equal(main([], options), 1);
  assert.match(out.error[0], /pnpm-lock\.yaml does not resolve @blinkbitcoin\/expo-runtime/);
});

test('refuses to guess when the workflows pin no single commit, and changes nothing', () => {
  const root = consumer({ workflows: { 'a.yml': callAt(SHA), 'b.yml': callAt(OLD) } });
  const { out, options } = io(root);
  assert.equal(main([], options), 1);
  assert.match(out.error[0], /the calls pin 2 refs/);
  assert.deepEqual(out.exec, []);
});

test('refuses a tag, which no package can be held to', () => {
  const root = consumer({ workflows: { 'ci.yml': 'jobs:\n  a:\n    uses: blinkbitcoin/shared-workflows/.github/workflows/check.yml@v0\n' } });
  const { out, options } = io(root);
  assert.equal(main([], options), 1);
  assert.match(out.error[0], /at v0, a tag that moves: pin a commit SHA/);
  assert.deepEqual(out.exec, []);
});

test('fails without a package.json', () => {
  const root = consumer({ pkg: null });
  const { out, options } = io(root);
  assert.equal(main([], options), 1);
  assert.deepEqual(out.error, [`no package.json in ${root}`]);
});

test('fails when package.json takes nothing from this family in the pinned form', () => {
  const root = consumer({ pkg: { devDependencies: { '@blinkbitcoin/app-tooling': 'github:blinkbitcoin/shared-workflows#main' } } });
  const { out, options } = io(root);
  assert.equal(main([], options), 1);
  assert.match(out.error[0], /takes no package from shared-workflows/);
  assert.deepEqual(out.exec, []);
});

test('a bad argument is a usage error', () => {
  const { out, options } = io('/nowhere');
  assert.equal(main(['--nope'], options), 2);
  assert.deepEqual(out.error, ['usage: fix-tooling-pin [--root DIR]']);
});

test('parseArgs defaults to the working directory and resolves --root against it', () => {
  assert.deepEqual(parseArgs([], '/work'), { root: '/work' });
  assert.deepEqual(parseArgs(['--root', 'app'], '/work'), { root: path.resolve('/work', 'app') });
  assert.ok(parseArgs(['--root'], '/work').error);
});

test('readCallers reads .yml and .yaml in name order, and nothing without a workflows directory', () => {
  const root = consumer({ workflows: { 'b.yaml': 'b', 'a.yml': 'a', 'notes.md': 'x' } });
  assert.deepEqual(readCallers(root), [
    { name: 'a.yml', text: 'a' },
    { name: 'b.yaml', text: 'b' },
  ]);
  assert.deepEqual(readCallers(path.join(root, 'missing')), []);
});

test('runs as a program', () => {
  const root = consumer({ workflows: { 'ci.yml': 'name: CI\n' } });
  const result = spawnSync(process.execPath, [BIN, '--root', root], { encoding: 'utf8' });
  assert.equal(result.status, 1);
  assert.match(result.stderr, /no workflow calls shared-workflows/);
});

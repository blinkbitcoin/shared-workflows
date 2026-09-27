import assert from 'node:assert/strict';
import { execFileSync, spawnSync } from 'node:child_process';
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { after, test } from 'node:test';
import { fileURLToPath } from 'node:url';
import { isShell, localePrefixes, main, scan } from './bin/check-shell-locale.mjs';

const SCRIPT = fileURLToPath(new URL('./bin/check-shell-locale.mjs', import.meta.url));
const roots = [];
after(() => {
  for (const root of roots) rmSync(root, { recursive: true, force: true });
});

for (const line of [
  'VC_GREP_OUTPUT="$(LC_ALL=C grep -aoE -e "$1" -- "$2" 2>"$err")" || rc=$?',
  '    LC_ALL=C grep -aqF -e "$value" -- "$1" || rc=$?',
  "elif ! printf '%s' \"$ID\" | LC_ALL=C grep -qE '^[0-9]+$'; then",
  'LANG=C sort -u list.txt',
  'LC_COLLATE=C LANG=C tr a-z A-Z',
  'FOO=1 LC_ALL=C sed -n p',
  'x=$(LANGUAGE=en git status)',
  '  run: LC_ALL=C make check',
  'LC_ALL="C" grep x',
  'out=$(LC_ALL=C REPO_ROOT="$TREE" "$CHECK" --platform ios 2>&1)',
]) {
  test(`the guard catches ${JSON.stringify(line)}`, () => {
    assert.equal(localePrefixes(line).length, 1, `missed ${line}`);
  });
}

for (const line of [
  'VC_GREP_OUTPUT="$(env LC_ALL=C grep -aoE -e "$1" -- "$2" 2>"$err")" || rc=$?',
  'env -i LC_ALL=C PATH="$PATH" sort',
  'export LC_ALL=C',
  'export LC_ALL=C LANG=C',
  'local LC_ALL=C',
  'LC_ALL=C',
  'LC_ALL=C; grep x',
  '# the prefix: LC_ALL=C grep, which crashes bash',
  'MY_LC_ALL=C grep x',
  'echo "$LC_ALL" grep',
  'check_not_contains "a name passes under LC_ALL=C" "name.txt" "$out"',
]) {
  test(`the guard allows ${JSON.stringify(line)}`, () => {
    assert.deepEqual(localePrefixes(line), []);
  });
}

test('a finding names the line and stops at the first match on it', () => {
  assert.deepEqual(localePrefixes('true\nLANG=C LC_ALL=C sort\n'), ['2: LANG=C LC_ALL=C sort']);
});

test('the guard reads shell files and nothing else', () => {
  assert.ok(isShell('scripts/release/verify-ios.sh', ''));
  assert.ok(isShell('scripts/hooks/lib.bash', ''));
  assert.ok(isShell('test/hooks.bats', ''));
  assert.ok(isShell('Makefile', ''));
  assert.ok(isShell('.github/workflows/ci.yml', ''));
  assert.ok(isShell('scripts/hooks/pre-commit', '#!/usr/bin/env bash\nset -e\n'));
  assert.ok(isShell('bin/tool', '#!/bin/sh\n'));
  assert.ok(!isShell('scripts/ports.mjs', '#!/usr/bin/env node\n'));
  assert.ok(!isShell('docs/local-dev.md', 'LC_ALL=C grep\n'));
  assert.ok(!isShell('app.config.ts', ''));
});

const files = {
  'a.sh': 'sort | LC_ALL=C uniq\n',
  'b.sh': 'env LC_ALL=C sort\n',
  'notes.md': 'LC_ALL=C grep\n',
  'gone.sh': null,
};
const fake = { list: () => Object.keys(files), read: (file) => files[path.basename(file)] };

test('the scan counts the shell files it read and names each offender by file and line', () => {
  assert.deepEqual(scan('/repo', fake), { scanned: 2, offenders: ['a.sh:1: sort | LC_ALL=C uniq'] });
});

const capture = () => {
  const out = [];
  const err = [];
  return { out, err, io: { log: (l) => out.push(l), error: (l) => err.push(l) } };
};

test('main fails on an offender, naming it and the fix', () => {
  const { out, err, io } = capture();
  assert.equal(main([], { ...io, cwd: '/repo', ...fake }), 1);
  assert.deepEqual(out, []);
  assert.equal(err[0], 'a.sh:1: sort | LC_ALL=C uniq');
  assert.match(err[1], /1 locale variable\(s\) set as a command prefix.*env LC_ALL=C cmd/);
});

test('main passes a clean tree and says how many files it read', () => {
  const { out, io } = capture();
  assert.equal(main([], { ...io, list: () => ['b.sh'], read: () => 'env LC_ALL=C sort\n' }), 0);
  assert.deepEqual(out, ['shell locale ok (1 shell files)']);
});

test('main refuses a tree with no shell file, rather than passing by reading nothing', () => {
  const { err, io } = capture();
  assert.equal(main(['--root', 'x'], { ...io, cwd: '/repo', list: () => ['README.md'], read: () => '' }), 1);
  assert.deepEqual(err, ['shell locale: no shell file found under /repo/x; the file filter or the root is wrong']);
});

test('main reports a root git cannot list', () => {
  const { err, io } = capture();
  const list = () => {
    throw new Error('not a git repository');
  };
  assert.equal(main([], { ...io, cwd: '/repo', list }), 1);
  assert.deepEqual(err, ['shell locale: could not list the files of /repo: not a git repository']);
});

test('as a command it scans the tracked files of --root', () => {
  const root = mkdtempSync(path.join(tmpdir(), 'shell-locale-'));
  roots.push(root);
  const git = (...args) => execFileSync('git', args, { cwd: root, stdio: 'pipe' });
  git('init', '--quiet');
  mkdirSync(path.join(root, 'scripts'));
  writeFileSync(path.join(root, 'scripts/ok.sh'), 'env LC_ALL=C sort\n');
  writeFileSync(path.join(root, 'untracked.sh'), 'LC_ALL=C sort x\n');
  git('add', 'scripts/ok.sh');
  const clean = spawnSync(process.execPath, [SCRIPT, '--root', root], { encoding: 'utf8', env: process.env });
  assert.equal(clean.status, 0, clean.stderr);
  assert.equal(clean.stdout, 'shell locale ok (1 shell files)\n');
  writeFileSync(path.join(root, 'scripts/bad.sh'), 'x="$(LC_ALL=C grep y z)"\n');
  writeFileSync(path.join(root, 'scripts/deleted.sh'), 'LC_ALL=C sort x\n');
  git('add', 'scripts/bad.sh', 'scripts/deleted.sh');
  rmSync(path.join(root, 'scripts/deleted.sh')); // tracked, but gone from the tree: skipped
  const dirty = spawnSync(process.execPath, [SCRIPT, '--root', root], { encoding: 'utf8', env: process.env });
  assert.equal(dirty.status, 1);
  assert.match(dirty.stderr, /^scripts\/bad\.sh:1: /m);
  assert.doesNotMatch(dirty.stderr, /untracked\.sh|deleted\.sh/);
});

test('--root with no directory after it checks the working directory', () => {
  const { err, io } = capture();
  assert.equal(main(['--root'], { ...io, cwd: '/repo', list: () => [], read: () => '' }), 1);
  assert.deepEqual(err, ['shell locale: no shell file found under /repo; the file filter or the root is wrong']);
});

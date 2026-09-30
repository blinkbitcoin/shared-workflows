import assert from 'node:assert/strict';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { test } from 'node:test';
import {
  DEPENDENCY_KEYS,
  isStructuralManifestChange,
  readAtRef,
  readWorkingCopy,
  structuralManifests,
} from './lib/manifest-structural.mjs';

const base = {
  name: 'app',
  version: '1.0.0',
  packageManager: 'pnpm@12.3.4',
  scripts: { test: 'jest' },
  dependencies: { expo: '54.0.0' },
  devDependencies: { jest: '30.0.0' },
  expo: { install: { exclude: ['react-native'] } },
};

test('an identical manifest is not a structural change', () => {
  assert.equal(isStructuralManifestChange(base, { ...base }), false);
});

test('a dependency bump is not structural', () => {
  assert.equal(isStructuralManifestChange(base, { ...base, dependencies: { expo: '54.1.0' } }), false);
});

test('an added dependency is not structural', () => {
  assert.equal(
    isStructuralManifestChange(base, { ...base, devDependencies: { ...base.devDependencies, knip: '5.0.0' } }),
    false,
  );
});

test('a version bump is not structural', () => {
  assert.equal(isStructuralManifestChange(base, { ...base, version: '1.1.0' }), false);
});

test('every dependency key is treated as bookkeeping, not structure', () => {
  for (const key of DEPENDENCY_KEYS) {
    assert.equal(
      isStructuralManifestChange({ ...base, [key]: { a: '1' } }, { ...base, [key]: { a: '2' } }),
      false,
      `${key} should not be structural`,
    );
  }
});

test('a scripts change is structural', () => {
  assert.equal(isStructuralManifestChange(base, { ...base, scripts: { test: 'jest', 'check:docs': 'x' } }), true);
});

test('a packageManager change is structural', () => {
  assert.equal(isStructuralManifestChange(base, { ...base, packageManager: 'pnpm@13.0.0' }), true);
});

test('an engines change is structural', () => {
  assert.equal(isStructuralManifestChange(base, { ...base, engines: { node: '>=24' } }), true);
});

test('an expo.install.exclude change is structural', () => {
  assert.equal(isStructuralManifestChange(base, { ...base, expo: { install: { exclude: [] } } }), true);
});

test('reordering keys is not a change', () => {
  assert.equal(isStructuralManifestChange(base, { scripts: { test: 'jest' }, ...base, name: 'app' }), false);
  assert.equal(isStructuralManifestChange(base, { ...base, scripts: { test: 'jest', a: undefined } }), false);
});

test('an added or deleted manifest is always structural', () => {
  assert.equal(isStructuralManifestChange(undefined, base), true);
  assert.equal(isStructuralManifestChange(base, undefined), true);
  assert.equal(isStructuralManifestChange(undefined, undefined), true);
});

test('structuralManifests keeps only the files whose change is structural', () => {
  const before = { 'a/package.json': base, 'b/package.json': base };
  const after = {
    'a/package.json': { ...base, dependencies: { expo: '54.2.0' } },
    'b/package.json': { ...base, scripts: {} },
  };
  assert.deepEqual(
    structuralManifests(Object.keys(before), (f) => before[f], (f) => after[f]),
    ['b/package.json'],
  );
});

test('readAtRef parses the file git shows at the ref, in the directory it is given', () => {
  const calls = [];
  const exec = (command, args, options) => {
    calls.push([command, ...args, options.cwd, options.env]);
    return '{"name":"app"}';
  };
  assert.deepEqual(readAtRef('origin/main', 'package.json', { cwd: '/repo', env: { A: '1' }, exec }), { name: 'app' });
  assert.deepEqual(calls, [['git', 'show', 'origin/main:package.json', '/repo', { A: '1' }]]);
});

test('readAtRef reads a file absent at the ref as undefined, and runs git by default', () => {
  const exec = () => {
    throw new Error('fatal: path does not exist');
  };
  assert.equal(readAtRef('origin/main', 'package.json', { exec }), undefined);
  const dir = mkdtempSync(path.join(tmpdir(), 'manifest-structural-git-'));
  try {
        // Without git's own variables: a pre-push hook's GIT_DIR would outrank cwd.
    const env = { ...Object.fromEntries(Object.entries(process.env).filter(([key]) => !key.startsWith('GIT_'))), GIT_CEILING_DIRECTORIES: dir };
    assert.equal(readAtRef('HEAD', 'package.json', { cwd: dir, env }), undefined);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test('readWorkingCopy parses the file, and a missing or broken one is undefined', () => {
  const dir = mkdtempSync(path.join(tmpdir(), 'manifest-structural-'));
  try {
    const good = path.join(dir, 'good.json');
    const broken = path.join(dir, 'broken.json');
    writeFileSync(good, '{"name":"app"}');
    writeFileSync(broken, '{');
    assert.deepEqual(readWorkingCopy(good), { name: 'app' });
    assert.equal(readWorkingCopy(broken), undefined);
    assert.equal(readWorkingCopy(path.join(dir, 'absent.json')), undefined);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

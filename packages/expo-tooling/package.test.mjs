import assert from 'node:assert/strict';
import { existsSync, readFileSync } from 'node:fs';
import { test } from 'node:test';

const read = (path) => readFileSync(new URL(path, import.meta.url), 'utf8');
const pkg = JSON.parse(read('./package.json'));

/** Every file an export points at, `types` included. */
const targets = Object.values(pkg.exports).flatMap((target) =>
  typeof target === 'string' ? [target] : Object.values(target),
);

test('every export points at a file that exists', () => {
  for (const target of targets) assert.ok(existsSync(new URL(target, import.meta.url)), target);
});

test('every exported file is in the published file list', () => {
  const published = (target) =>
    target === './package.json' || pkg.files.some((entry) => target === `./${entry}` || target.startsWith(`./${entry}/`));
  for (const target of targets) assert.ok(published(target), target);
});

test('it bundles nothing', () => {
  assert.equal(pkg.dependencies, undefined);
});

test('release-please releases it as its own component, from the version in its package.json', () => {
  const config = JSON.parse(read('../../release-please-config.json'));
  const manifest = JSON.parse(read('../../.release-please-manifest.json'));
  assert.equal(pkg.name, '@blinkbitcoin/expo-tooling');
  assert.equal(manifest['packages/expo-tooling'], pkg.version);
  const entry = config.packages['packages/expo-tooling'];
  assert.equal(entry['release-type'], 'node');
  assert.equal(entry['package-name'], pkg.name);
  assert.equal(entry.component, 'expo-tooling');
});

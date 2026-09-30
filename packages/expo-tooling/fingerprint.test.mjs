import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { test } from 'node:test';
import { createFingerprintConfig, IGNORE_PATHS, SOURCE_SKIPS } from './lib/fingerprint.mjs';

const require = createRequire(import.meta.url);
const today = require('./fixtures/template/fingerprint/today.cjs');
const future = require('./fixtures/template/fingerprint/future.cjs');
const fingerprintIgnore = readFileSync(new URL('./fixtures/template/fingerprint/today.fingerprintignore', import.meta.url), 'utf8');

// @expo/fingerprint's collectIgnorePathsAsync: its defaults, then the
// configuration's `ignorePaths`, then every non-empty trimmed line of
// .fingerprintignore - comment lines included, which minimatch reads as
// patterns that match nothing.
const ignoreFileLines = (text) => text.split('\n').map((line) => line.trim()).filter(Boolean);

test("the template's future fingerprint.config.js skips the same sources as today's", () => {
  assert.deepStrictEqual(future.sourceSkips, today.sourceSkips);
});

test('its ignorePaths are what .fingerprintignore held, so that file can go', () => {
  const lines = ignoreFileLines(fingerprintIgnore);
  const comments = lines.filter((line) => line.startsWith('#'));
  assert.ok(comments.length > 0, 'the comparison is not vacuous: the file has comments');
  assert.deepStrictEqual(future.ignorePaths, lines.filter((line) => !line.startsWith('#')));
  assert.equal(today.ignorePaths, undefined, 'today every ignore path comes from the file');
});

test('no ignore path is negated, so moving them ahead of the file lines changes nothing', () => {
  for (const glob of future.ignorePaths) assert.ok(!glob.startsWith('!'), glob);
});

test("an app's ignore paths are appended, and each call gets its own lists", () => {
  const config = createFingerprintConfig({ ignorePaths: ['storybook/**'] });
  assert.deepEqual(config.ignorePaths, [...IGNORE_PATHS, 'storybook/**']);
  config.sourceSkips.push('changed');
  assert.deepEqual(createFingerprintConfig().sourceSkips, SOURCE_SKIPS);
});

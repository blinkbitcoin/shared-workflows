import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { test } from 'node:test';
import { IGNORE_PATHS, SOURCE_SKIPS } from './expo/fingerprint.mjs';
import {
  BUMPED_VERSIONS,
  fingerprintInputProblems,
  HASH_PATTERN,
  hashProgram,
  ignoreFileLines,
  NO_VERSIONS,
  PLATFORMS,
} from './lib/fingerprint-inputs.mjs';

const shared = { sourceSkips: [...SOURCE_SKIPS], ignorePaths: [...IGNORE_PATHS] };

test('both native platforms, and a release that changes both version inputs', () => {
  assert.deepEqual(PLATFORMS, ['ios', 'android']);
  assert.deepEqual(NO_VERSIONS, { APP_VERSION: '', APP_BUILD_NUMBER: '' });
  assert.deepEqual(Object.keys(BUMPED_VERSIONS), Object.keys(NO_VERSIONS));
  for (const value of Object.values(BUMPED_VERSIONS)) assert.notEqual(value, '');
  assert.match('0123456789abcdef0123456789abcdef01234567', HASH_PATTERN);
  assert.doesNotMatch('0123', HASH_PATTERN);
});

test('an ignore file adds its patterns, not its comments or blank lines', () => {
  assert.deepEqual(ignoreFileLines('# a comment\n\n  docs/**  \n#x\nscripts/**\n'), ['docs/**', 'scripts/**']);
  assert.deepEqual(ignoreFileLines(''), []);
});

test('the shared configuration has no problems, in either order', () => {
  assert.deepEqual(fingerprintInputProblems(shared), []);
  assert.deepEqual(fingerprintInputProblems({ ...shared, sourceSkips: [...SOURCE_SKIPS].reverse() }), []);
});

test("an app's own extra ignore paths are fine", () => {
  assert.deepEqual(fingerprintInputProblems({ ...shared, ignorePaths: [...IGNORE_PATHS, 'storybook/**'] }), []);
});

test('ignore paths may come from .fingerprintignore, as the library appends it', () => {
  assert.deepEqual(fingerprintInputProblems({ sourceSkips: SOURCE_SKIPS }, `# why\n${IGNORE_PATHS.join('\n')}\n`), []);
  assert.deepEqual(fingerprintInputProblems({ sourceSkips: SOURCE_SKIPS, ignorePaths: IGNORE_PATHS.slice(0, 2) }, IGNORE_PATHS.slice(2).join('\n')), []);
});

test('a configuration that is not an object is one problem, naming the fix', () => {
  for (const config of [null, undefined, 'x', 3]) {
    assert.deepEqual(fingerprintInputProblems(config), [
      'fingerprint.config.js exports no configuration object; export createFingerprintConfig() from @blinkbitcoin/app-tooling/expo/fingerprint',
    ]);
  }
});

test('source skips that are not exactly the shared ones are named, with what they should be', () => {
  for (const sourceSkips of [['ExpoConfigVersions'], [...SOURCE_SKIPS, 'Extra'], undefined, 'ExpoConfigVersions']) {
    const [problem, ...rest] = fingerprintInputProblems({ ...shared, sourceSkips });
    assert.deepEqual(rest, []);
    assert.equal(
      problem,
      `fingerprint.config.js's sourceSkips is ${JSON.stringify(sourceSkips)}, not ${JSON.stringify(SOURCE_SKIPS)}: a configuration sourceSkips replaces the library's defaults, so both have to be listed`,
    );
  }
});

test('every shared ignore path that is missing is named, whatever the ignorePaths field holds', () => {
  assert.deepEqual(fingerprintInputProblems({ ...shared, ignorePaths: IGNORE_PATHS.filter((glob) => glob !== 'scripts/**' && glob !== 'docs/**') }), [
    'the fingerprint does not ignore docs/**, scripts/**: add them to fingerprint.config.js\'s ignorePaths (createFingerprintConfig() has them all)',
  ]);
  assert.match(fingerprintInputProblems({ sourceSkips: SOURCE_SKIPS, ignorePaths: 'docs/**' })[0], /^the fingerprint does not ignore docs\/\*\*, \*\*\/\*\.md,/);
});

test('both problems at once are both reported', () => {
  assert.equal(fingerprintInputProblems({}).length, 2);
});

test('the hash program prints what createFingerprintAsync returns for the platform, from the working directory', (t) => {
  const root = mkdtempSync(path.join(tmpdir(), 'fingerprint-inputs-'));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  const library = path.join(root, 'node_modules/@expo/fingerprint');
  mkdirSync(library, { recursive: true });
  writeFileSync(path.join(library, 'package.json'), '{"name":"@expo/fingerprint","main":"index.js"}');
  writeFileSync(
    path.join(library, 'index.js'),
    'exports.createFingerprintAsync = async (root, options) => ({ hash: `${require("path").basename(root)}:${options.platforms.join(",")}` });',
  );
  const out = execFileSync(process.execPath, ['-e', hashProgram('android')], { cwd: root, encoding: 'utf8' });
  assert.equal(out, `${path.basename(root)}:android`);
});

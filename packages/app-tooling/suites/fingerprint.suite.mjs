// The OTA runtime version of an Expo app. With `runtimeVersion: { policy:
// 'fingerprint' }` a fingerprint that moves on a version bump makes every
// published update incompatible with every shipped build. Whether it moves
// depends on the app's own configuration and plugins, so it is asserted
// against the app rather than assumed: the library resolves, the configuration
// loads and keeps the shared lists, and a release's version inputs move
// neither platform's hash.
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { existsSync, readFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import path from 'node:path';
import { test } from 'node:test';
import {
  BUMPED_VERSIONS,
  fingerprintInputProblems,
  HASH_PATTERN,
  hashProgram,
  NO_VERSIONS,
  PLATFORMS,
} from '../lib/fingerprint-inputs.mjs';

const root = process.env.APP_ROOT;
if (!root) throw new Error('APP_ROOT is not set: run the app suites through test-app');
const requireFromApp = createRequire(path.join(root, 'package.json'));

const hash = (platform, versions) =>
  execFileSync(process.execPath, ['-e', hashProgram(platform)], {
    cwd: root,
    encoding: 'utf8',
    env: { ...process.env, ...versions },
  });

test('@expo/fingerprint resolves from the app root', () => {
  try {
    requireFromApp.resolve('@expo/fingerprint');
  } catch (e) {
    assert.fail(`@expo/fingerprint does not resolve from ${root}: add it as a devDependency and install (${e.message})`);
  }
});

test('fingerprint.config.js loads and keeps the shared source skips and ignore paths', () => {
  let config;
  try {
    config = requireFromApp('./fingerprint.config.js');
  } catch (e) {
    assert.fail(`fingerprint.config.js does not load, and @expo/fingerprint would silently use its defaults: ${e.message}`);
  }
  const ignoreFile = path.join(root, '.fingerprintignore');
  const ignoreText = existsSync(ignoreFile) ? readFileSync(ignoreFile, 'utf8') : '';
  assert.deepEqual(fingerprintInputProblems(config, ignoreText), []);
});

for (const platform of PLATFORMS) {
  test(`a version bump does not move the ${platform} fingerprint`, () => {
    const base = hash(platform, NO_VERSIONS);
    assert.match(base, HASH_PATTERN, `the ${platform} fingerprint is not a hash: ${JSON.stringify(base)}`);
    assert.equal(
      hash(platform, BUMPED_VERSIONS),
      base,
      `the ${platform} fingerprint moved when APP_VERSION and APP_BUILD_NUMBER changed: the app configuration or a plugin puts the version into a source the fingerprint reads`,
    );
  });
}

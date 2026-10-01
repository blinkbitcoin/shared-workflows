// What the fingerprint suite (suites/fingerprint.suite.mjs) holds an app to,
// as data and pure functions, so they are tested on their own here and the
// suite is left with the reading and the running.
//
// @expo/fingerprint fails open: a fingerprint.config.js that throws is caught,
// logged only under DEBUG, and replaced by the defaults. So "the hash did not
// move" proves nothing about the configuration on its own; these say what the
// configuration has to hold.
import { IGNORE_PATHS, SOURCE_SKIPS } from '../expo/fingerprint.mjs';

/** The platforms a native fingerprint is taken for. */
export const PLATFORMS = ['ios', 'android'];

/** A release's version inputs, empty, and as a later release sets them. */
export const NO_VERSIONS = { APP_VERSION: '', APP_BUILD_NUMBER: '' };
export const BUMPED_VERSIONS = { APP_VERSION: '9.9.9', APP_BUILD_NUMBER: '777' };

/** A fingerprint hash: @expo/fingerprint's default algorithm is SHA-1. */
export const HASH_PATTERN = /^[0-9a-f]{40}$/;

/**
 * The patterns a .fingerprintignore adds: the library appends every non-empty
 * trimmed line, and a comment line is a pattern that matches nothing, so it is
 * left out here.
 */
export function ignoreFileLines(text) {
  return text
    .split('\n')
    .map((line) => line.trim())
    .filter((line) => line !== '' && !line.startsWith('#'));
}

/**
 * What is wrong with an app's fingerprint inputs: its loaded
 * fingerprint.config.js and the text of its .fingerprintignore ('' when it has
 * none). An empty list is a pass.
 */
export function fingerprintInputProblems(config, ignoreFileText = '') {
  if (config === null || typeof config !== 'object') {
    return ['fingerprint.config.js exports no configuration object; export createFingerprintConfig() from @blinkbitcoin/app-tooling/expo/fingerprint'];
  }
  const problems = [];
  const skips = Array.isArray(config.sourceSkips) ? [...config.sourceSkips].sort() : config.sourceSkips;
  if (JSON.stringify(skips) !== JSON.stringify([...SOURCE_SKIPS].sort())) {
    problems.push(
      `fingerprint.config.js's sourceSkips is ${JSON.stringify(config.sourceSkips)}, not ${JSON.stringify(SOURCE_SKIPS)}: a configuration sourceSkips replaces the library's defaults, so both have to be listed`,
    );
  }
  const ignored = new Set([...(Array.isArray(config.ignorePaths) ? config.ignorePaths : []), ...ignoreFileLines(ignoreFileText)]);
  const missing = IGNORE_PATHS.filter((glob) => !ignored.has(glob));
  if (missing.length > 0) {
    problems.push(`the fingerprint does not ignore ${missing.join(', ')}: add them to fingerprint.config.js's ignorePaths (createFingerprintConfig() has them all)`);
  }
  return problems;
}

/**
 * A `node -e` program that prints the app's fingerprint hash for `platform`,
 * reaching the library through a plain require from the working directory. Not
 * through node_modules/.bin/fingerprint: its shim exports NODE_PATH, and can
 * make a package resolve inside that one invocation and nowhere else.
 */
export function hashProgram(platform) {
  return (
    "require('@expo/fingerprint')" +
    `.createFingerprintAsync(process.cwd(), { platforms: [${JSON.stringify(platform)}] })` +
    '.then((f) => process.stdout.write(f.hash));'
  );
}

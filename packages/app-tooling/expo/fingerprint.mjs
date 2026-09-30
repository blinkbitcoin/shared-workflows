// The @expo/fingerprint configuration (runtimeVersion policy "fingerprint")
// for an Expo app of this family: which sources may change the native runtime,
// and so the window in which an OTA update is compatible.

/**
 * A configuration `sourceSkips` REPLACES @expo/fingerprint's
 * DEFAULT_SOURCE_SKIPS rather than merging with it (normalizeOptionsAsync
 * spreads the configuration over the defaults), so the default is listed
 * explicitly. This is exactly `DEFAULT_SOURCE_SKIPS | ExpoConfigVersions`:
 *
 *   - PackageJsonAndroidAndIosScriptsIfNotContainRun - the library default
 *   - ExpoConfigVersions - version, buildNumber and versionCode change on every
 *     release but never change the native runtime, so they must not
 *     invalidate OTA updates
 *
 * Names, not numbers: `normalizeSourceSkips` accepts enum names, so the app's
 * configuration file needs no `require('@expo/fingerprint')` - and a failed
 * require there would be swallowed by the library, which catches, logs only
 * under DEBUG, and silently falls back to its defaults.
 */
export const SOURCE_SKIPS = ['ExpoConfigVersions', 'PackageJsonAndroidAndIosScriptsIfNotContainRun'];

/**
 * Paths that cannot change the native runtime, so they must not change the
 * fingerprint. What a `.fingerprintignore` used to hold: the library appends
 * that file's lines to these, so the two are the same list.
 *
 * `scripts/` is CI and developer tooling only. `plugins/` and `modules/` are
 * top-level siblings, not children of `scripts/` - they DO reach the native
 * projects and are deliberately left fingerprinted.
 */
export const IGNORE_PATHS = [
  'docs/**',
  '**/*.md',
  '.maestro/**',
  'e2e/**',
  'coverage/**',
  'dist/**',
  'scripts/**',
];

/**
 * @param {object} [options]
 * @param {string[]} [options.ignorePaths] appended to the generic list
 */
export function createFingerprintConfig({ ignorePaths = [] } = {}) {
  return {
    sourceSkips: [...SOURCE_SKIPS],
    ignorePaths: [...IGNORE_PATHS, ...ignorePaths],
  };
}

// Fingerprint (runtimeVersion policy "fingerprint") inputs.
//
// A config `sourceSkips` REPLACES @expo/fingerprint's DEFAULT_SOURCE_SKIPS
// rather than merging with it (normalizeOptionsAsync spreads the config over
// the defaults), so the default has to be listed explicitly. This list is
// exactly `DEFAULT_SOURCE_SKIPS | SourceSkips.ExpoConfigVersions`:
//
//   - PackageJsonAndroidAndIosScriptsIfNotContainRun — the library default
//   - ExpoConfigVersions — version/buildNumber/versionCode change on every
//     release but never change the native runtime, so they must not
//     invalidate OTA updates
//
// The names are strings on purpose: `normalizeSourceSkips` accepts enum names,
// so this file needs no `require('@expo/fingerprint')` — and a failed require
// here would be swallowed by the library (it catches, logs only under DEBUG,
// and silently falls back to the defaults). Guarded by
// scripts/release/fingerprint.test.mjs.
module.exports = {
  sourceSkips: ['ExpoConfigVersions', 'PackageJsonAndroidAndIosScriptsIfNotContainRun'],
};

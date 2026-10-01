// What createFingerprintConfig() returns, written out: the fixture app has no
// @blinkbitcoin/app-tooling to require.
module.exports = {
  sourceSkips: ['ExpoConfigVersions', 'PackageJsonAndroidAndIosScriptsIfNotContainRun'],
  ignorePaths: ['docs/**', '**/*.md', '.maestro/**', 'e2e/**', 'coverage/**', 'dist/**', 'scripts/**'],
};

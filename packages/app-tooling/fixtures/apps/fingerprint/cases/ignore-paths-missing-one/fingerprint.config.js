// scripts/** dropped: a change to CI tooling would move the runtime version.
module.exports = {
  sourceSkips: ['ExpoConfigVersions', 'PackageJsonAndroidAndIosScriptsIfNotContainRun'],
  ignorePaths: ['docs/**', '**/*.md', '.maestro/**', 'e2e/**', 'coverage/**', 'dist/**'],
};

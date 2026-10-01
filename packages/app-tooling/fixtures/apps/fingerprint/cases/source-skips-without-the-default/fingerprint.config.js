// The version skip alone: it replaces the library's default skip instead of
// adding to it, which no hash comparison can see.
module.exports = {
  sourceSkips: ['ExpoConfigVersions'],
  ignorePaths: ['docs/**', '**/*.md', '.maestro/**', 'e2e/**', 'coverage/**', 'dist/**', 'scripts/**'],
};

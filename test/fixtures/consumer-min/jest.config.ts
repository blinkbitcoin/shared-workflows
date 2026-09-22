// The Jest half of the `.workflows/` ignore list in docs/consumer-guide.md.
//
// This one is not optional in the way the others are: shared-workflows ships
// its own *.test.mjs under packages/, and a consumer's jest-expo project will
// collect them and die on `import.meta` - a red Unit job over a file the
// consumer does not own.
export default {
  testPathIgnorePatterns: ['/node_modules/', '/\\.workflows/'],
};

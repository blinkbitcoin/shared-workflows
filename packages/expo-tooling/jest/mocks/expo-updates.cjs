// Stand-in for the native expo-updates module: createJestConfig maps
// `expo-updates` here, so anything that reads update metadata in a test gets
// inert defaults, and the functions are `jest.fn`s a test can inspect or
// re-implement. `jest` is the object Jest puts in every module's scope.
'use strict';

// `__esModule`, the shape Babel gives an ES module: `import * as` then reads
// this object itself rather than a per-file copy, so a `jest.spyOn` in a test
// reaches the code under test.
Object.defineProperty(exports, '__esModule', { value: true });
Object.assign(exports, {
  isEnabled: false,
  updateId: null,
  channel: null,
  runtimeVersion: 'test-runtime',
  checkForUpdateAsync: jest.fn(async () => ({ isAvailable: false })),
  fetchUpdateAsync: jest.fn(async () => ({ isNew: false })),
  reloadAsync: jest.fn(async () => {}),
  setUpdateRequestHeadersOverride: jest.fn(),
});

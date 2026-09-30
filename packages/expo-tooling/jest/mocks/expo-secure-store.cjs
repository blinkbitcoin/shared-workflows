// Stand-in for the native expo-secure-store module: an in-memory map with the
// same asynchronous surface. createJestConfig maps `expo-secure-store` here.
// `__reset` clears it between tests.
'use strict';

const store = new Map();

// `__esModule`, the shape Babel gives an ES module: `import * as` then reads
// this object itself rather than a per-file copy, so a `jest.spyOn` in a test
// reaches the code under test.
Object.defineProperty(exports, '__esModule', { value: true });
Object.assign(exports, {
  async getItemAsync(key) {
    return store.get(key) ?? null;
  },
  async setItemAsync(key, value) {
    store.set(key, value);
  },
  async deleteItemAsync(key) {
    store.delete(key);
  },
  __reset() {
    store.clear();
  },
});

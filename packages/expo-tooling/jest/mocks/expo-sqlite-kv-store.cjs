// Stand-in for expo-sqlite's key-value store: an in-memory map behind the
// default export's asynchronous surface. createJestConfig maps
// `expo-sqlite/kv-store` here. `__reset` clears it between tests.
'use strict';

const store = new Map();

const Storage = {
  async getItem(key) {
    return store.get(key) ?? null;
  },
  async setItem(key, value) {
    store.set(key, value);
  },
  async removeItem(key) {
    store.delete(key);
  },
  __reset() {
    store.clear();
  },
};

// The shape Babel gives an ES module, so `import Storage from
// 'expo-sqlite/kv-store'` reads `default` exactly as it did from a TypeScript
// stand-in.
Object.defineProperty(exports, '__esModule', { value: true });
exports.default = Storage;

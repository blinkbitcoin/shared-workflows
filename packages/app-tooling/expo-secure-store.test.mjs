import assert from 'node:assert/strict';
import { test } from 'node:test';
import store from './expo/jest/mocks/expo-secure-store.cjs';

test('it reads Babel\'s ES module shape, so `import * as` sees this object itself', () => {
  assert.equal(store.__esModule, true);
});

test('an item round-trips, a missing one reads as null, and a deleted one is gone', async () => {
  assert.equal(await store.getItemAsync('token'), null);
  await store.setItemAsync('token', 'abc');
  assert.equal(await store.getItemAsync('token'), 'abc');
  await store.deleteItemAsync('token');
  assert.equal(await store.getItemAsync('token'), null);
});

test('__reset clears every item', async () => {
  await store.setItemAsync('a', '1');
  await store.setItemAsync('b', '2');
  store.__reset();
  assert.equal(await store.getItemAsync('a'), null);
  assert.equal(await store.getItemAsync('b'), null);
});

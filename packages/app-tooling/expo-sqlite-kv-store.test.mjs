import assert from 'node:assert/strict';
import { test } from 'node:test';
import mock from './expo/jest/mocks/expo-sqlite-kv-store.cjs';

const Storage = mock.default;

test('the store is the default export, in Babel\'s ES module shape', () => {
  assert.equal(mock.__esModule, true);
  assert.equal(typeof Storage.getItem, 'function');
});

test('an item round-trips, a missing one reads as null, and a removed one is gone', async () => {
  assert.equal(await Storage.getItem('locale'), null);
  await Storage.setItem('locale', 'es');
  assert.equal(await Storage.getItem('locale'), 'es');
  await Storage.removeItem('locale');
  assert.equal(await Storage.getItem('locale'), null);
});

test('__reset clears every item', async () => {
  await Storage.setItem('a', '1');
  Storage.__reset();
  assert.equal(await Storage.getItem('a'), null);
});

import assert from 'node:assert/strict';
import { test } from 'node:test';
// `jest` first: the stand-in builds its functions with `jest.fn` as it loads.
import './fixtures/stubs/jest-globals.mjs';
import updates from './expo/jest/mocks/expo-updates.cjs';

test('update metadata reads as inert defaults', () => {
  assert.equal(updates.__esModule, true);
  assert.equal(updates.isEnabled, false);
  assert.equal(updates.updateId, null);
  assert.equal(updates.channel, null);
  assert.equal(updates.runtimeVersion, 'test-runtime');
});

test('the functions are jest.fn stand-ins that find and fetch nothing', async () => {
  assert.deepEqual(await updates.checkForUpdateAsync(), { isAvailable: false });
  assert.deepEqual(await updates.fetchUpdateAsync(), { isNew: false });
  assert.equal(await updates.reloadAsync(), undefined);
  assert.equal(updates.setUpdateRequestHeadersOverride({ a: 'b' }), undefined);
  assert.deepEqual(updates.setUpdateRequestHeadersOverride.calls, [[{ a: 'b' }]]);
});

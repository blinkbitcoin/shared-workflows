import assert from 'node:assert/strict';
import { test } from 'node:test';
// The lifecycle globals first: a Jest setup file registers its hooks on them
// as it is evaluated, and module evaluation follows import order.
import { registered } from './fixtures/stubs/jest-globals.mjs';
import setup from './expo/jest/setup-console.cjs';

test('the setup file exports nothing and installs the guard on the Jest globals', () => {
  assert.deepEqual(setup, {});
  assert.equal(registered.beforeEach.length, 1);
  assert.equal(registered.afterEach.length, 1);
});

test('the hooks it registered start the recorder and fail a noisy test', () => {
  const [start] = registered.beforeEach;
  const [finish] = registered.afterEach;
  start();
  console.error('slipped out');
  assert.throws(finish, /console\.error: slipped out/);
});

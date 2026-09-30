import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import { test } from 'node:test';
import guard from './expo/jest/console.cjs';

const {
  allowConsole,
  assertSilent,
  createConsoleRecorder,
  formatCall,
  formatFailure,
  GUARDED_METHODS,
  installConsoleGuard,
  matches,
} = guard;

/** A stand-in console, so the recorder is driven without touching the real one. */
function fakeConsole() {
  const seen = [];
  const target = {
    error: (...args) => seen.push(`real error ${args.join(' ')}`),
    warn: (...args) => seen.push(`real warn ${args.join(' ')}`),
  };
  return { target, seen };
}

/** Lifecycle hooks that hand back what was registered, as Jest's globals would take it. */
function fakeHooks() {
  const registered = { beforeEach: [], afterEach: [] };
  return {
    registered,
    beforeEach: (fn) => registered.beforeEach.push(fn),
    afterEach: (fn) => registered.afterEach.push(fn),
  };
}

test('the guard fires: an unmatched line is reported by stop()', () => {
  const { target } = fakeConsole();
  const recorder = createConsoleRecorder(target);
  recorder.start();
  target.warn('something slipped out');
  assert.deepEqual(recorder.stop(), [{ method: 'warn', message: 'something slipped out' }]);
});

test('a silent test reports nothing', () => {
  const recorder = createConsoleRecorder(fakeConsole().target);
  recorder.start();
  assert.deepEqual(recorder.stop(), []);
});

test('console.log is not guarded - only error and warn are', () => {
  assert.deepEqual(GUARDED_METHODS, ['error', 'warn']);
  assert.ok(Object.isFrozen(GUARDED_METHODS));
});

test('recording joins arguments and names Errors readably', () => {
  const { target } = fakeConsole();
  const recorder = createConsoleRecorder(target);
  recorder.start();
  target.error('failed:', new TypeError('bad prop'), { id: 1 });
  assert.deepEqual(recorder.stop(), [{ method: 'error', message: 'failed: TypeError: bad prop [object Object]' }]);
});

test('an allowance without a matcher permits every line on that method', () => {
  const { target } = fakeConsole();
  const recorder = createConsoleRecorder(target);
  recorder.start();
  recorder.allow('warn');
  target.warn('anything at all');
  assert.deepEqual(recorder.stop(), []);
});

test('an allowance is scoped to its method', () => {
  const { target } = fakeConsole();
  const recorder = createConsoleRecorder(target);
  recorder.start();
  recorder.allow('warn');
  target.error('boom');
  assert.deepEqual(recorder.stop(), [{ method: 'error', message: 'boom' }]);
});

test('a string matcher allows only the lines containing it', () => {
  const { target } = fakeConsole();
  const recorder = createConsoleRecorder(target);
  recorder.start();
  recorder.allow('warn', 'GraphQL error in X');
  target.warn('[warn] GraphQL error in X', 'meta');
  target.warn('[warn] something else');
  assert.deepEqual(recorder.stop(), [{ method: 'warn', message: '[warn] something else' }]);
});

test('a RegExp matcher works the same way', () => {
  const { target } = fakeConsole();
  const recorder = createConsoleRecorder(target);
  recorder.start();
  recorder.allow('error', /^\[error] Network/);
  target.error('[error] Network error in X');
  target.error('trailing [error] Network error in X');
  assert.deepEqual(recorder.stop(), [{ method: 'error', message: 'trailing [error] Network error in X' }]);
});

test('allowances and recorded calls do not leak into the next test', () => {
  const { target } = fakeConsole();
  const recorder = createConsoleRecorder(target);
  recorder.start();
  recorder.allow('warn');
  target.warn('allowed here');
  recorder.stop();
  recorder.start();
  target.warn('not allowed any more');
  assert.deepEqual(recorder.stop(), [{ method: 'warn', message: 'not allowed any more' }]);
});

test('stop() restores the real methods', () => {
  const { target, seen } = fakeConsole();
  const recorder = createConsoleRecorder(target);
  recorder.start();
  target.warn('captured');
  recorder.stop();
  target.warn('passed through');
  assert.deepEqual(seen, ['real warn passed through']);
});

test('a spy installed on top is never mistaken for the real method', () => {
  const { target, seen } = fakeConsole();
  const recorder = createConsoleRecorder(target);
  recorder.start();
  // A test that spies takes the method over: the recorder sees nothing.
  const outer = target.warn;
  target.warn = () => {};
  target.warn('swallowed by the spy');
  assert.deepEqual(recorder.stop(), []);
  // ...and the pristine method comes back, not the recorder and not the spy.
  assert.notEqual(target.warn, outer);
  target.warn('passed through');
  assert.deepEqual(seen, ['real warn passed through']);
});

test('matches() treats an absent matcher as "anything"', () => {
  assert.equal(matches(undefined, 'whatever'), true);
  assert.equal(matches('needle', 'a needle here'), true);
  assert.equal(matches('needle', 'nothing here'), false);
  assert.equal(matches(/^a/, 'abc'), true);
});

test('the failure message names every call and points at the usual cause', () => {
  const message = formatFailure([
    { method: 'error', message: 'not wrapped in act(...)' },
    { method: 'warn', message: 'deprecated' },
  ]);
  assert.match(message, /console\.error: not wrapped in act\(\.\.\.\)/);
  assert.match(message, /console\.warn: deprecated/);
  assert.match(message, /await waitFor/);
  assert.equal(formatCall({ method: 'warn', message: 'x' }), 'console.warn: x');
});

// assertSilent is what the ambient afterEach calls. Driving it here is the only
// way to reach its throwing branch: an afterEach cannot fail itself and then
// report on it.
test('assertSilent stops the recorder and says nothing when the test was silent', () => {
  const { target, seen } = fakeConsole();
  const recorder = createConsoleRecorder(target);
  recorder.start();
  assert.doesNotThrow(() => assertSilent(recorder));
  // It stops as well as asserts: the real methods are back afterwards.
  target.warn('passed through');
  assert.deepEqual(seen, ['real warn passed through']);
});

test('assertSilent throws a message naming every unexpected line', () => {
  const { target } = fakeConsole();
  const recorder = createConsoleRecorder(target);
  recorder.start();
  target.error('not wrapped in act(...)');
  target.warn('and a warning');
  assert.throws(
    () => assertSilent(recorder),
    /console\.error: not wrapped in act\(\.\.\.\)[\s\S]*console\.warn: and a warning/,
  );
});

// The shared recorder wraps the process's real console, the way it wraps the
// console of a Jest test file. Each case restores it through the hooks.
test('installConsoleGuard wires the shared recorder into the lifecycle hooks it is given', () => {
  const hooks = fakeHooks();
  installConsoleGuard(hooks);
  assert.equal(hooks.registered.beforeEach.length, 1);
  assert.equal(hooks.registered.afterEach.length, 1);
  const [start] = hooks.registered.beforeEach;
  const [finish] = hooks.registered.afterEach;

  start();
  console.warn('a line nobody allowed');
  assert.throws(finish, /console\.warn: a line nobody allowed/);

  start();
  allowConsole('warn', 'deliberate');
  console.warn('deliberate output');
  assert.doesNotThrow(finish);
});

test('installConsoleGuard defaults to the lifecycle globals a Jest setup file sees', () => {
  const hooks = fakeHooks();
  const saved = { beforeEach: globalThis.beforeEach, afterEach: globalThis.afterEach };
  Object.assign(globalThis, { beforeEach: hooks.beforeEach, afterEach: hooks.afterEach });
  try {
    installConsoleGuard();
  } finally {
    Object.assign(globalThis, saved);
  }
  assert.equal(hooks.registered.beforeEach.length, 1);
  assert.equal(hooks.registered.afterEach.length, 1);
});

test('a second copy of the module shares the first one\'s recorder', () => {
  // Jest loads the setup file by its absolute path and a test's allowConsole
  // by package name; were those two copies, an allowance made through one
  // would have to reach the recorder the other installed.
  const require = createRequire(import.meta.url);
  const file = require.resolve('./expo/jest/console.cjs');
  delete require.cache[file];
  const second = require(file);
  assert.notEqual(second, guard, 'a fresh evaluation of the module');

  const hooks = fakeHooks();
  installConsoleGuard(hooks);
  const [start] = hooks.registered.beforeEach;
  const [finish] = hooks.registered.afterEach;
  start();
  second.allowConsole('error', 'through the second copy');
  console.error('allowed through the second copy');
  assert.doesNotThrow(finish);
});

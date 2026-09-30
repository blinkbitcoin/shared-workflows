// Tests are silent on `console.error` and `console.warn`. An app logs through
// its own injectable logger, and React Native reports un-acted state updates
// and invalid props through `console.error`, so a line on either method during
// a test is a bug - usually a missing `await waitFor`, not a logging need.
//
// `console.log` is deliberately NOT guarded: Metro, jest-expo and the Expo
// modules log progress through it in ways an app suite does not control.
//
// Two opt-outs, both explicit:
//   - `allowConsole('warn', /deprecated/)` - this test expects that line.
//   - `jest.spyOn(console, 'warn')` - a test that asserts on the logging takes
//     the method over and the recorder never sees the call.
//
// CommonJS and plain JavaScript on purpose: Jest loads it from node_modules,
// which it does not transform, and the plain-node `plugins` project loads it
// too, so it imports nothing.
'use strict';

const GUARDED_METHODS = Object.freeze(['error', 'warn']);

const formatArg = (arg) => (arg instanceof Error ? `${arg.name}: ${arg.message}` : String(arg));

const formatCall = ({ method, message }) => `console.${method}: ${message}`;

const matches = (matcher, message) => {
  if (matcher === undefined) return true;
  return typeof matcher === 'string' ? message.includes(matcher) : matcher.test(message);
};

const isAllowed = (allowances, call) =>
  allowances.some(
    (allowance) => allowance.method === call.method && matches(allowance.matcher, call.message),
  );

/**
 * Record `console.error` / `console.warn` on `target` between `start` and
 * `stop`. A factory with no Jest dependency, so it is unit-testable directly -
 * `afterEach` cannot observe its own failure.
 *
 * The pristine methods are captured once, at construction, so a nested spy
 * installed by a test can never be mistaken for the real implementation.
 */
const createConsoleRecorder = (target = console) => {
  const pristine = { error: target.error, warn: target.warn };
  let calls = [];
  let allowances = [];

  return {
    start() {
      calls = [];
      allowances = [];
      for (const method of GUARDED_METHODS) {
        target[method] = (...args) => {
          calls.push({ method, message: args.map(formatArg).join(' ') });
        };
      }
    },
    stop() {
      for (const method of GUARDED_METHODS) {
        target[method] = pristine[method];
      }
      const unexpected = calls.filter((call) => !isAllowed(allowances, call));
      calls = [];
      allowances = [];
      return unexpected;
    },
    allow(method, matcher) {
      allowances.push({ method, matcher });
    },
  };
};

const formatFailure = (unexpected) =>
  [
    'unexpected console output during the test:',
    ...unexpected.map(formatCall),
    '',
    'A console line is usually a missing `await waitFor`, not a logging need.',
    "Deliberate output opts out with allowConsole('warn', /matcher/).",
  ].join('\n');

// One recorder per test file's global, not per copy of this module: Jest
// loads the setup file by its absolute path and a test's `allowConsole` by
// package name, and should those ever resolve to two copies, an allowance
// registered on one would never reach the recorder the other installed.
const RECORDER = Symbol.for('@blinkbitcoin/app-tooling/expo/console-recorder');
globalThis[RECORDER] ??= createConsoleRecorder();
const recorder = globalThis[RECORDER];

/**
 * Allow matching `console[method]` output for the remainder of the current
 * test. Without a matcher every line on that method is allowed; with one, only
 * matching lines are - anything else still fails the test.
 */
const allowConsole = (method, matcher) => {
  recorder.allow(method, matcher);
};

/**
 * Stop `target` and throw when it recorded output no allowance covered. The
 * seam a test drives directly: the ambient `afterEach` cannot observe its own
 * failure.
 */
const assertSilent = (target) => {
  const unexpected = target.stop();
  if (unexpected.length > 0) {
    throw new Error(formatFailure(unexpected));
  }
};

/**
 * Wire the recorder into the Jest lifecycle. `hooks` defaults to the globals a
 * Jest setup file sees.
 */
const installConsoleGuard = (hooks = globalThis) => {
  hooks.beforeEach(() => {
    recorder.start();
  });
  hooks.afterEach(() => {
    assertSilent(recorder);
  });
};

module.exports = {
  GUARDED_METHODS,
  allowConsole,
  assertSilent,
  createConsoleRecorder,
  formatCall,
  formatFailure,
  installConsoleGuard,
  matches,
};

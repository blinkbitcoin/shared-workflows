import assert from 'node:assert/strict';
import { test } from 'node:test';
import { isCommit, pinProblems, pinsIn, sharedDeps, specFor, tarballFor, workflowsPin } from './lib/pin.mjs';

const SHA = 'a'.repeat(40);
const OTHER = 'b'.repeat(40);
const call = (sha = SHA, comment = ' # v1.2.3') =>
  `jobs:\n  code:\n    uses: blinkbitcoin/shared-workflows/.github/workflows/check.yml@${sha}${comment}\n`;
const callers = (...texts) => texts.map((text, i) => ({ name: `ci-${i}.yml`, text }));
const pkgAt = (sha, dir = '/packages/app-tooling') => ({
  devDependencies: { '@blinkbitcoin/app-tooling': specFor(sha, dir), typescript: '^6.0.0' },
});
const lockAt = (sha, dir = '/packages/app-tooling') => `    version: ${tarballFor(sha, dir)}\n`;

test('pinsIn reads each shared call with its line, workflow, ref and comment', () => {
  const text = `name: CI\n${call()}    other:\n    uses: actions/checkout@v7\n    uses: blinkbitcoin/shared-workflows/.github/workflows/test-unit.yml@${OTHER}\n`;
  assert.deepEqual(pinsIn(text), [
    { line: 4, workflow: 'check.yml', ref: SHA, comment: 'v1.2.3' },
    { line: 7, workflow: 'test-unit.yml', ref: OTHER, comment: '' },
  ]);
});

test('workflowsPin returns the one commit every call is on', () => {
  assert.deepEqual(workflowsPin(callers(call(), call())), { pin: SHA, problems: [] });
});

test('workflowsPin says when nothing calls shared-workflows', () => {
  assert.deepEqual(workflowsPin(callers('name: CI\n')), { pin: null, problems: ['no workflow calls shared-workflows'] });
});

test('workflowsPin accepts one tag for every call, as the guide teaches', () => {
  assert.deepEqual(workflowsPin(callers(call('v0', ''), call('v0', ''))), { pin: 'v0', problems: [] });
});

test('workflowsPin rejects a SHA with no version beside it', () => {
  assert.deepEqual(workflowsPin(callers(call(SHA, ''))), {
    pin: null,
    problems: ['ci-0.yml:3 has no "# vX.Y.Z" beside its pin'],
  });
});

test('workflowsPin rejects calls on two commits', () => {
  const { pin, problems } = workflowsPin(callers(call(SHA), call(OTHER)));
  assert.equal(pin, null);
  assert.match(problems[0], /the calls pin 2 refs \(a{40}, b{40}\)/);
});

test('sharedDeps finds this family in either dependency field, and nothing else', () => {
  const pkg = {
    dependencies: { '@blinkbitcoin/expo-runtime': specFor(SHA, '/packages/expo-runtime'), react: '19.0.0' },
    devDependencies: { '@blinkbitcoin/app-tooling': 'github:blinkbitcoin/shared-workflows#main', jest: 1 },
  };
  assert.deepEqual(sharedDeps(pkg), [
    { name: '@blinkbitcoin/expo-runtime', field: 'dependencies', spec: specFor(SHA, '/packages/expo-runtime'), commit: SHA, dir: '/packages/expo-runtime' },
    { name: '@blinkbitcoin/app-tooling', field: 'devDependencies', spec: 'github:blinkbitcoin/shared-workflows#main', commit: null, dir: null },
  ]);
  assert.deepEqual(sharedDeps(null), []);
  assert.deepEqual(sharedDeps({}), []);
});

test('pinProblems is empty when calls, package.json and the lockfile agree', () => {
  assert.deepEqual(pinProblems({ callers: callers(call()), pkg: pkgAt(SHA), lockfile: lockAt(SHA) }), []);
});

test('pinProblems reports the calls first and stops there', () => {
  assert.deepEqual(pinProblems({ callers: callers('name: CI\n'), pkg: pkgAt(OTHER), lockfile: '' }), [
    'no workflow calls shared-workflows',
  ]);
});

test('pinProblems names a package at another commit, and the command that fixes it', () => {
  assert.deepEqual(pinProblems({ callers: callers(call()), pkg: pkgAt(OTHER), lockfile: lockAt(OTHER) }), [
    `package.json takes @blinkbitcoin/app-tooling at ${OTHER}, but the workflows pin ${SHA}: run \`pnpm exec fix-tooling-pin\``,
  ]);
});

test('pinProblems names a lockfile that was not refreshed', () => {
  assert.deepEqual(pinProblems({ callers: callers(call()), pkg: pkgAt(SHA), lockfile: lockAt(OTHER) }), [
    `pnpm-lock.yaml does not resolve @blinkbitcoin/app-tooling at ${SHA}: run \`pnpm exec fix-tooling-pin\``,
  ]);
});

test('pinProblems names a spec that is not the pinned github form', () => {
  const pkg = { devDependencies: { '@blinkbitcoin/app-tooling': 'github:blinkbitcoin/shared-workflows#main' } };
  assert.deepEqual(pinProblems({ callers: callers(call()), pkg, lockfile: null }), [
    'package.json takes @blinkbitcoin/app-tooling as github:blinkbitcoin/shared-workflows#main, not github:blinkbitcoin/shared-workflows#<sha>&path:/packages/<name>',
  ]);
});

test('pinProblems skips the lockfile when there is none', () => {
  assert.deepEqual(pinProblems({ callers: callers(call()), pkg: pkgAt(SHA), lockfile: null }), []);
});

test('pinProblems holds no package to a tag, which moves', () => {
  assert.deepEqual(pinProblems({ callers: callers(call('v0', '')), pkg: pkgAt(OTHER), lockfile: '' }), []);
});

test('isCommit tells a full SHA from a tag or a short SHA', () => {
  assert.equal(isCommit(SHA), true);
  assert.equal(isCommit('v0'), false);
  assert.equal(isCommit('abc1234'), false);
});

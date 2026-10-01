import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { after, test } from 'node:test';
import { fileURLToPath } from 'node:url';
import {
  isTracked,
  main,
  nativeStack,
  parseArgs,
  readDependencies,
  readText,
  resolveNativeStack,
  STACKS,
} from './lib/native-stack.mjs';

const BIN = fileURLToPath(new URL('./lib/native-stack.mjs', import.meta.url));

const temporary = [];
after(() => {
  for (const dir of temporary) rmSync(dir, { recursive: true, force: true });
});
/** A directory holding `files`, optionally a git repository with them committed. */
function tree(files = {}, { git = false } = {}) {
  const root = mkdtempSync(path.join(tmpdir(), 'native-stack-'));
  temporary.push(root);
  for (const [name, text] of Object.entries(files)) {
    mkdirSync(path.dirname(path.join(root, name)), { recursive: true });
    writeFileSync(path.join(root, name), text);
  }
  if (git) {
    const env = { ...process.env, GIT_CONFIG_GLOBAL: '/dev/null', GIT_CONFIG_NOSYSTEM: '1' };
    for (const args of [['init', '-q'], ['add', '-A']]) {
      const result = spawnSync('git', ['-C', root, ...args], { env, encoding: 'utf8' });
      assert.equal(result.status, 0, result.stderr);
    }
  }
  return root;
}

const EXPO = JSON.stringify({ dependencies: { expo: '~57.0.0' } });

/** A stream stand-in that keeps what was written. */
function sink() {
  const chunks = [];
  return { write: (text) => chunks.push(text), text: () => chunks.join('') };
}

test('the two stacks, in the order the documentation lists them', () => {
  assert.deepEqual(STACKS, ['expo', 'bare']);
});

test('an input wins over everything the repository says', () => {
  assert.deepEqual(resolveNativeStack({ input: 'bare', dependencies: { expo: '1' } }), { stack: 'bare', reason: 'the native-stack input' });
  assert.deepEqual(resolveNativeStack({ input: ' expo ', iosTracked: true }), { stack: 'expo', reason: 'the native-stack input' });
});

test('an input that is not a stack is refused, naming the value and the choices', () => {
  assert.throws(() => resolveNativeStack({ input: 'Expo' }), {
    message: '::error::native-stack is "Expo": expected expo, bare or empty (empty detects it from the repository)',
  });
});

test('with no input, expo as a dependency and an untracked ios/ is the expo stack', () => {
  assert.deepEqual(resolveNativeStack({ dependencies: { expo: '1' } }), { stack: 'expo', reason: 'expo is a dependency and git tracks no ios/' });
});

test('with no input, a tracked ios/ is bare even with expo as a dependency', () => {
  assert.deepEqual(resolveNativeStack({ dependencies: { expo: '1' }, iosTracked: true }), {
    stack: 'bare',
    reason: 'git tracks ios/, so the native projects are committed source',
  });
});

test('with no input and no expo dependency, the stack is bare', () => {
  assert.deepEqual(resolveNativeStack(), { stack: 'bare', reason: 'expo is not a dependency in package.json' });
  assert.equal(resolveNativeStack({ input: '', dependencies: { react: '1' } }).stack, 'bare');
});

test('git answers whether ios/ is tracked, and a directory that is not a repository tracks nothing', () => {
  assert.equal(isTracked(tree({ 'ios/Podfile': '' }, { git: true }), 'ios'), true);
  assert.equal(isTracked(tree({ 'ios/Podfile': '', '.gitignore': 'ios/\n' }, { git: true }), 'ios'), false);
  assert.equal(isTracked(tree({ 'android/build.gradle': '' }, { git: true }), 'ios'), false);
  assert.equal(isTracked(tree({ 'ios/Podfile': '' }), 'ios'), false);
});

test('git missing or failing reads as nothing tracked', () => {
  const calls = [];
  const run = (command, args) => {
    calls.push([command, ...args]);
    return { status: null, stdout: '' };
  };
  assert.equal(isTracked('/app', 'ios', run), false);
  assert.deepEqual(calls, [['git', '-C', '/app', 'ls-files', '--', 'ios']]);
});

test('dependencies merge both tables, and no package.json is none', () => {
  const files = { '/app/package.json': JSON.stringify({ dependencies: { a: '1' }, devDependencies: { expo: '2' } }) };
  const read = (file) => files[file] ?? null;
  assert.deepEqual(readDependencies('/app', read), { a: '1', expo: '2' });
  assert.deepEqual(readDependencies('/elsewhere', read), {});
  assert.deepEqual(readDependencies('/app', () => '{}'), {});
});

test('a package.json that does not parse is an error naming the file', () => {
  assert.throws(() => readDependencies('/app', () => '{'), { message: /^::error::\/app\/package\.json is not valid JSON: / });
});

test('a file is read as text, and one that is not there as null', () => {
  const root = tree({ 'a.txt': 'hello' });
  assert.equal(readText(path.join(root, 'a.txt')), 'hello');
  assert.equal(readText(path.join(root, 'absent.txt')), null);
});

test('a repository is resolved from disk with the default readers', () => {
  assert.equal(nativeStack(tree({ 'package.json': EXPO })).stack, 'expo');
  assert.equal(nativeStack(tree({ 'package.json': EXPO, 'ios/Podfile': '' }, { git: true })).stack, 'bare');
  assert.equal(nativeStack(tree({ 'package.json': '{}' })).stack, 'bare');
});

test('git is not asked when an input decides', () => {
  const tracked = () => assert.fail('git was asked although the input decides');
  assert.equal(nativeStack('/app', 'expo', { read: () => null, tracked }).stack, 'expo');
});

test('arguments default to the working directory and no input, and both flags are read', () => {
  assert.deepEqual(parseArgs([], '/work'), { root: '/work', input: '' });
  assert.equal(parseArgs([]).root, process.cwd());
  assert.deepEqual(parseArgs(['--root', '/app', '--input', 'bare'], '/work'), { root: '/app', input: 'bare' });
  assert.deepEqual(parseArgs(['--input', ''], '/work'), { root: '/work', input: '' });
});

test('an unknown argument, or a flag without its value, is refused', () => {
  assert.throws(() => parseArgs(['--stack', 'bare']), { message: /^::error::unknown argument: --stack \(usage: / });
  assert.throws(() => parseArgs(['--root']), { message: '::error::--root needs a value' });
});

test('the program prints the stack on stdout and the reason on stderr', () => {
  const stdout = sink();
  const stderr = sink();
  const code = main(['--root', '/app'], { stdout, stderr, read: () => EXPO, tracked: () => false });
  assert.equal(code, 0);
  assert.equal(stdout.text(), 'expo\n');
  assert.equal(stderr.text(), 'native stack: expo (expo is a dependency and git tracks no ios/)\n');
});

test('the program checks the working directory when given no root', () => {
  const stdout = sink();
  const seen = [];
  main([], { stdout, stderr: sink(), cwd: '/work', read: (file) => (seen.push(file), null), tracked: () => false });
  assert.deepEqual(seen, ['/work/package.json']);
  assert.equal(stdout.text(), 'bare\n');
});

test('the program turns every error into one line and exit 1', () => {
  const stdout = sink();
  const stderr = sink();
  assert.equal(main(['--input', 'native'], { stdout, stderr, read: () => null }), 1);
  assert.equal(stdout.text(), '');
  assert.match(stderr.text(), /^::error::native-stack is "native": [^\n]*\n$/);
});

test('run as a program, it prints the stack and exits 0, or 1 on a bad input', () => {
  const root = tree({ 'package.json': EXPO });
  const ok = spawnSync(process.execPath, [BIN, '--root', root], { encoding: 'utf8' });
  assert.equal(ok.status, 0, ok.stderr);
  assert.equal(ok.stdout, 'expo\n');
  const bad = spawnSync(process.execPath, [BIN, '--input', 'x'], { encoding: 'utf8', cwd: root });
  assert.equal(bad.status, 1);
  assert.match(bad.stderr, /^::error::native-stack is "x"/);
});

test('the defaults are the real process', () => {
  // Only the parts that do not write: an unknown argument fails before any
  // output but the error line, which goes to the real stderr.
  const saved = process.stderr.write;
  const lines = [];
  process.stderr.write = (text) => (lines.push(text), true);
  try {
    assert.equal(main(['--nope']), 1);
  } finally {
    process.stderr.write = saved;
  }
  assert.match(lines.join(''), /unknown argument: --nope/);
});

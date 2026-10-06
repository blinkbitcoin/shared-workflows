import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { after, test } from 'node:test';
import { fileURLToPath } from 'node:url';
import {
  check,
  checkCommand,
  checkTool,
  compareVersions,
  DEFAULTS,
  main,
  mergeRequirements,
  parseVersion,
  readRequirements,
} from './bin/doctor.mjs';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const tmp = mkdtempSync(path.join(tmpdir(), 'doctor-'));
after(() => rmSync(tmp, { recursive: true, force: true }));

let n = 0;
/** A throwaway repository holding the files a case hands it. */
const repository = (files = {}) => {
  const dir = path.join(tmp, `repository-${++n}`);
  mkdirSync(dir, { recursive: true });
  for (const [name, text] of Object.entries(files)) writeFileSync(path.join(dir, name), text);
  return dir;
};

/** A `run` that answers each command from `outputs`: a string, or an error to throw. */
const fakeRun = (outputs) => (command) => {
  const answer = outputs[command];
  if (answer instanceof Error) throw answer;
  return answer;
};

const failed = (streams) => Object.assign(new Error('exit 1'), streams);

test('parseVersion extracts the first semver-ish token', () => {
  assert.deepEqual(parseVersion('Xcode 26.6\nBuild version 17F45'), [26, 6, 0]);
  assert.deepEqual(parseVersion('v24.13.0'), [24, 13, 0]);
  assert.equal(parseVersion('no version here'), null);
});

test('compareVersions orders numerically', () => {
  assert.equal(compareVersions([26, 6, 0], [26, 4, 0]), 1);
  assert.equal(compareVersions([1, 2, 3], [1, 2, 3]), 0);
  assert.equal(compareVersions([0, 9, 0], [1, 0, 0]), -1);
});

test('checkTool accepts a version at or above the minimum', () => {
  const tool = { command: 'node --version', minimum: '24.0.0' };
  assert.deepEqual(checkTool(tool, fakeRun({ 'node --version': 'v24.13.1\n' })), { ok: true, version: '24.13.1' });
});

test('checkTool rejects a version below the minimum', () => {
  const tool = { command: 'pod --version', minimum: '1.16.0' };
  assert.deepEqual(checkTool(tool, fakeRun({ 'pod --version': '1.15.2' })), {
    ok: false,
    reason: 'found 1.15.2, need >= 1.16.0',
  });
});

test('checkTool reads the version a failing command still printed', () => {
  // Some tools print their version and exit non-zero; the output is the answer.
  const tool = { command: 'watchman --version', minimum: '2024.0.0' };
  assert.equal(checkTool(tool, fakeRun({ 'watchman --version': failed({ stdout: '2025.1.6.0\n' }) })).ok, true);
});

test('checkTool reports a command with no output as not found', () => {
  const tool = { command: 'ruby --version', minimum: '3.3.0' };
  assert.deepEqual(checkTool(tool, fakeRun({ 'ruby --version': failed({}) })), { ok: false, reason: 'not found' });
  assert.deepEqual(checkTool(tool, fakeRun({ 'ruby --version': failed({ stdout: '' }) })), {
    ok: false,
    reason: 'not found',
  });
});

test('checkTool reports output with no version in it', () => {
  const tool = { command: 'java -version 2>&1', minimum: '17.0.0' };
  assert.deepEqual(checkTool(tool, fakeRun({ 'java -version 2>&1': ' no java here \n' })), {
    ok: false,
    reason: 'no version in its output: no java here',
  });
});

test('checkCommand reports the exit status, from whichever stream said why', () => {
  assert.deepEqual(checkCommand({ command: 'true' }, () => ''), { ok: true });
  const onStdout = checkCommand({ command: 'bundle check' }, () => {
    throw failed({ stdout: "Could not find gem 'fastlane'.\nmore noise\n" });
  });
  assert.deepEqual(onStdout, { ok: false, reason: "Could not find gem 'fastlane'." });
  // `bundle check` reports on stderr with an empty stdout.
  const onStderr = checkCommand({ command: 'bundle check' }, () => {
    throw failed({ stdout: '', stderr: 'The following gems are missing\n * fastlane\n' });
  });
  assert.equal(onStderr.reason, 'The following gems are missing');
  const silent = checkCommand({ command: 'x' }, () => {
    throw failed({ stdout: '  ', stderr: null });
  });
  assert.deepEqual(silent, { ok: false, reason: 'command failed' });
});

test('mergeRequirements: a repository replaces by name, adds, and skips', () => {
  const base = {
    tools: [
      { name: 'node', minimum: '24.0.0' },
      { name: 'maestro', minimum: '2.10.0' },
    ],
    commands: [{ name: 'ruby gems' }],
    env: [{ name: 'ANDROID_HOME' }],
  };
  const merged = mergeRequirements(base, {
    tools: [{ name: 'node', minimum: '25.0.0' }, { name: 'bun', minimum: '1.0.0' }, { name: 'maestro', skip: true }],
  });
  assert.deepEqual(merged, {
    tools: [
      { name: 'node', minimum: '25.0.0' },
      { name: 'bun', minimum: '1.0.0' },
    ],
    commands: [{ name: 'ruby gems' }],
    env: [{ name: 'ANDROID_HOME' }],
  });
  assert.deepEqual(mergeRequirements({}), { tools: [], commands: [], env: [] });
});

test('readRequirements is the package file alone, or with the repository file on top', () => {
  const defaults = JSON.parse(readFileSync(DEFAULTS, 'utf8'));
  assert.deepEqual(readRequirements(repository()), mergeRequirements(defaults));
  const root = repository({ 'doctor.requirements.json': JSON.stringify({ env: [{ name: 'APP_PORT_BASE', hint: 'mise trust' }] }) });
  const req = readRequirements(root);
  assert.deepEqual(req.env.map((v) => v.name), ['ANDROID_HOME', 'APP_PORT_BASE']);
});

test('readRequirements names a malformed file', () => {
  const root = repository({ 'doctor.requirements.json': '{ nope' });
  assert.throws(() => readRequirements(root), (error) => error.message.startsWith(path.join(root, 'doctor.requirements.json')));
});

test('the package requirements check the Ruby gems only where there is a Gemfile', () => {
  const gems = readRequirements(repository()).commands.find((entry) => entry.command === 'bundle check');
  assert.ok(gems, 'no `bundle check` entry in doctor.requirements.json');
  assert.equal(gems.when, 'Gemfile');
});

test("the maestro minimum is not newer than the version setup installs", () => {
  const versions = readFileSync(path.join(HERE, 'lib', 'versions.sh'), 'utf8');
  const pinned = parseVersion(/MAESTRO_VERSION="([^"]+)"/.exec(versions)[1]);
  const maestro = readRequirements(repository()).tools.find((tool) => tool.name === 'maestro');
  assert.ok(compareVersions(parseVersion(maestro.minimum), pinned) <= 0, `maestro minimum ${maestro.minimum} is newer than the pin`);
});

const REQ = {
  tools: [
    { name: 'node', command: 'node --version', minimum: '24.0.0', hint: 'mise install' },
    { name: 'xcodebuild', command: 'xcodebuild -version', minimum: '26.4.0', hint: 'Install Xcode', platform: 'darwin' },
    { name: 'maestro', command: 'maestro --version', minimum: '2.0.0', hint: 'curl maestro', optional: true },
  ],
  commands: [{ name: 'ruby gems', command: 'bundle check', hint: 'bundle install', when: 'Gemfile' }],
  env: [{ name: 'APP_PORT_BASE', hint: 'mise trust' }],
};

/** Runs `check` against REQ and captures what it writes. */
const doctor = (options) => {
  let text = '';
  const code = check(REQ, { write: (chunk) => (text += chunk), ...options });
  return { code, lines: text.split('\n') };
};

test('check reports all good when every check passes', () => {
  const { code, lines } = doctor({
    platform: 'darwin',
    env: { APP_PORT_BASE: 'from-mise' },
    exists: () => true,
    run: fakeRun({
      'node --version': 'v24.13.0',
      'xcodebuild -version': 'Xcode 26.4',
      'maestro --version': '2.1.0',
      'bundle check': '',
    }),
  });
  assert.equal(code, 0);
  assert.deepEqual(lines, [
    'ok    node 24.13.0',
    'ok    xcodebuild 26.4.0',
    'ok    maestro 2.1.0',
    'ok    ruby gems',
    'ok    $APP_PORT_BASE=from-mise',
    '',
    'All good.',
    '',
  ]);
});

test('check skips other platforms and absent files, warns on optional tools and counts every failure', () => {
  const { code, lines } = doctor({
    platform: 'linux',
    env: {},
    exists: () => false,
    run: fakeRun({ 'node --version': 'v22.1.0', 'maestro --version': failed({}) }),
  });
  assert.equal(code, 1);
  assert.deepEqual(lines, [
    'FAIL  node: found 22.1.0, need >= 24.0.0. Fix: mise install',
    'warn  maestro: not found. Fix: curl maestro',
    'FAIL  $APP_PORT_BASE is not set. Fix: mise trust',
    '',
    '2 problem(s). Fix them and run the doctor again.',
    '',
  ]);
});

test('check fails a command that fails', () => {
  const { code, lines } = doctor({
    platform: 'linux',
    env: { APP_PORT_BASE: '8080' },
    exists: () => true,
    run: fakeRun({
      'node --version': 'v24.0.0',
      'maestro --version': '2.1.0',
      'bundle check': failed({ stderr: 'Could not find gem fastlane' }),
    }),
  });
  assert.equal(code, 1);
  assert.ok(lines.includes('FAIL  ruby gems: Could not find gem fastlane. Fix: bundle install'));
});

test('main checks the directory it runs in, or the one --root names', () => {
  const root = repository({
    'doctor.requirements.json': JSON.stringify({
      tools: [],
      commands: [],
      env: [{ name: 'ANDROID_HOME', skip: true }, { name: 'DOCTOR_CASE', hint: 'set it' }],
    }),
  });
  const defaults = path.join(tmp, 'empty.json');
  writeFileSync(defaults, '{}');
  for (const [argv, cwd] of [[[], root], [['--root', path.basename(root)], tmp]]) {
    let text = '';
    const code = main(argv, { cwd, defaults, env: { DOCTOR_CASE: 'yes' }, write: (chunk) => (text += chunk) });
    assert.equal(code, 0, text);
    assert.match(text, /ok {4}\$DOCTOR_CASE=yes/);
  }
});

test('main: a bad argument or a malformed requirements file is a usage error', () => {
  const errors = [];
  assert.equal(main(['--nope'], { error: (line) => errors.push(line) }), 2);
  assert.equal(errors[0], 'usage: doctor [--root DIR]');
  const root = repository({ 'doctor.requirements.json': '{ nope' });
  assert.equal(main([], { cwd: root, error: (line) => errors.push(line) }), 2);
  assert.match(errors[1], /^doctor: .*doctor\.requirements\.json/);
});

test('as a program it checks the package requirements and fails when nothing is on PATH', () => {
  const result = spawnSync(process.execPath, [path.join(HERE, 'bin', 'doctor.mjs')], {
    cwd: repository(),
    encoding: 'utf8',
    // An empty PATH makes every tool "not found" on any machine. The rest of the
    // environment is kept so NODE_V8_COVERAGE lets the child count toward coverage.
    env: { ...process.env, PATH: '', ANDROID_HOME: '' },
  });
  assert.equal(result.status, 1);
  assert.match(result.stdout, /^FAIL {2}node: not found\. Fix: bash node_modules\/@blinkbitcoin\/app-tooling\/setup\/toolchain\.sh$/m);
  assert.match(result.stdout, /problem\(s\)\. Fix them and run the doctor again\./);
});

test('main answers --help with its usage on stdout and exit 0, before anything else', async () => {
  const out = [];
  const err = [];
  const code = await main(['--help'], { write: (text) => out.push(text), error: (line) => err.push(line) });
  assert.equal(code, 0);
  assert.match(out.join(''), /^ +doctor(?: |$)/m);
  assert.deepEqual(err, []);
});

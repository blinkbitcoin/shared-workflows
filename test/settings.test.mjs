// scripts/security/settings.mjs: the program that turns the resolved security
// settings into the `name=value` step outputs check-security.yml gates on, for
// scripts/security/settings.sh.
//
// Covered here: the rows (the three fixed ones first, then one per job in the
// resolver's order, a list of several fail-on values and an empty one), their
// lines, and every way out of main - printed, the wrong number of arguments,
// an argument that is not JSON, JSON that is not the settings object - plus the
// program run as a program and imported, when it runs nothing.
// test/settings.bats runs it through the shell script against the real resolver.
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import path from 'node:path';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';
import { USAGE, formatRows, main, outputRows } from '../scripts/security/settings.mjs';

const ROOT = path.join(path.dirname(fileURLToPath(import.meta.url)), '..');
const SCRIPT = path.join(ROOT, 'scripts/security/settings.mjs');

/** A writable stream stand-in that keeps what was written. */
function sink() {
  return { text: '', write(chunk) { this.text += chunk; } };
}

const SETTINGS = {
  enabled: true,
  severity: 'high',
  failOn: ['deterministic', 'review'],
  jobs: { dependencies: true, code: false, review: false },
};

test('outputRows puts enabled, severity and fail-on first, then each job in order', () => {
  assert.deepEqual(outputRows(SETTINGS), [
    ['enabled', true],
    ['severity', 'high'],
    ['fail-on', 'deterministic,review'],
    ['dependencies', true],
    ['code', false],
    ['review', false],
  ]);
});

test('outputRows publishes an empty fail-on as empty', () => {
  assert.deepEqual(outputRows({ ...SETTINGS, failOn: [], jobs: {} })[2], ['fail-on', '']);
});

test('outputRows refuses what is not the settings object', () => {
  assert.throws(() => outputRows({ enabled: true }), TypeError);
  assert.throws(() => outputRows({ ...SETTINGS, jobs: null }), TypeError);
});

test('formatRows writes one name=value line each', () => {
  assert.equal(formatRows([['enabled', false], ['fail-on', '']]), 'enabled=false\nfail-on=\n');
});

test('main prints the outputs for the settings it is given', () => {
  const stdout = sink();
  const stderr = sink();
  assert.equal(main([JSON.stringify(SETTINGS)], { stdout, stderr }), 0);
  assert.equal(
    stdout.text,
    'enabled=true\nseverity=high\nfail-on=deterministic,review\ndependencies=true\ncode=false\nreview=false\n',
  );
  assert.equal(stderr.text, '');
});

test('main refuses anything but one argument, naming its usage', () => {
  for (const argv of [[], ['{}', '{}']]) {
    const stdout = sink();
    const stderr = sink();
    assert.equal(main(argv, { stdout, stderr }), 2);
    assert.equal(stderr.text, `::error::${USAGE}\n`);
    assert.equal(stdout.text, '');
  }
});

test('main fails on an argument that is not JSON, printing no output', () => {
  const stdout = sink();
  const stderr = sink();
  assert.equal(main(['not the settings object at all'], { stdout, stderr }), 1);
  assert.match(stderr.text, /^settings\.mjs: Unexpected token/);
  assert.equal(stdout.text, '');
});

test('main fails on JSON that is not the settings object, printing no partial answer', () => {
  const stdout = sink();
  const stderr = sink();
  assert.equal(main([JSON.stringify({ enabled: true, severity: 'high' })], { stdout, stderr }), 1);
  assert.match(stderr.text, /^settings\.mjs: /);
  assert.equal(stdout.text, '');
});

test('run as a program it prints the outputs and exits 0', () => {
  const result = spawnSync(process.execPath, [SCRIPT, JSON.stringify(SETTINGS)], { encoding: 'utf8' });
  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stdout, /^enabled=true\nseverity=high\n/);
});

test('run as a program on something that is not JSON it exits 1', () => {
  const result = spawnSync(process.execPath, [SCRIPT, 'nope'], { encoding: 'utf8' });
  assert.equal(result.status, 1);
  assert.equal(result.stdout, '');
});

test('imported, it runs nothing', () => {
  const result = spawnSync(process.execPath, ['--input-type=module', '-e', `await import(${JSON.stringify(SCRIPT)});`], {
    encoding: 'utf8',
  });
  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.stdout, '');
  assert.equal(result.stderr, '');
});

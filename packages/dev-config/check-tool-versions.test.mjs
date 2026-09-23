import assert from 'node:assert/strict';
import { test } from 'node:test';
import {
  checkTools,
  extractVersion,
  formatResult,
  readTable,
  satisfies,
} from './bin/check-tool-versions.mjs';

// The real output of every tool the baseline pins, captured from the binaries
// mise installs. If a tool changes its banner, this is where it shows up.
const REAL_OUTPUT = {
  actionlint: '1.7.12\ninstalled by downloading from release page\n',
  shellcheck: 'ShellCheck - shell script analysis tool\nversion: 0.11.0\nlicense: GNU GPL v3\n',
  typos: 'typos-cli 1.50.1\n',
  yq: 'yq (https://github.com/mikefarah/yq/) version v4.53.6\n',
  lefthook: '2.1.14\n',
  zizmor: 'zizmor 1.30.1\n',
  gitleaks: '8.30.1\n',
  bats: 'Bats 1.14.0\n',
  node: 'v24.20.0\n',
  pnpm: '12.3.4\n',
};

test('every pinned tool is recognised from its real --version output', () => {
  const table = readTable();
  const run = (name) => ({ status: 0, stdout: REAL_OUTPUT[name], stderr: '' });
  const results = checkTools(table, Object.keys(table.tools), run);
  assert.deepEqual(
    results.filter((r) => r.status !== 'ok'),
    [],
  );
});

test('the table covers exactly the tools whose output this test pins', () => {
  assert.deepEqual(Object.keys(readTable().tools).sort(), Object.keys(REAL_OUTPUT).sort());
});

test('a version leading with a URL is still read correctly', () => {
  assert.equal(extractVersion(REAL_OUTPUT.yq), '4.53.6');
});

test('a banner line before the version does not win', () => {
  assert.equal(extractVersion(REAL_OUTPUT.shellcheck), '0.11.0');
});

test('a per-tool pattern overrides the first-number rule', () => {
  assert.equal(extractVersion('build 2026 tool v3.4.5', 'tool v(\\d+\\.\\d+\\.\\d+)'), '3.4.5');
});

test('no number anywhere yields undefined rather than a bogus version', () => {
  assert.equal(extractVersion('command not found'), undefined);
});

test('major matching accepts a newer patch, exact matching does not', () => {
  assert.equal(satisfies('24.20.0', '24', 'major'), true);
  assert.equal(satisfies('25.1.0', '24', 'major'), false);
  assert.equal(satisfies('1.50.2', '1.50.1', 'exact'), false);
  assert.equal(satisfies('1.50.1', '1.50.1', 'exact'), true);
});

test('an undefined version never satisfies a pin', () => {
  assert.equal(satisfies(undefined, '1.0.0', 'exact'), false);
  assert.equal(satisfies(undefined, '24', 'major'), false);
});

test('a skewed tool is reported as a mismatch, naming both versions', () => {
  const table = readTable();
  const run = () => ({ status: 0, stdout: 'typos-cli 1.49.0\n', stderr: '' });
  const [result] = checkTools(table, ['typos'], run);
  assert.equal(result.status, 'mismatch');
  assert.match(formatResult(result), /MISMATCH typos is 1\.49\.0, baseline pins 1\.50\.1/);
});

test('a tool that is not installed is missing, not a mismatch', () => {
  const run = () => ({ status: null });
  const [result] = checkTools(readTable(), ['typos'], run);
  assert.equal(result.status, 'missing');
  assert.match(formatResult(result), /not on PATH/);
});

test('a tool absent from the table is reported rather than silently passing', () => {
  const run = () => ({ status: 0, stdout: '1.0.0' });
  const [result] = checkTools(readTable(), ['nonesuch'], run);
  assert.equal(result.status, 'unknown');
});

test('a subset can be checked, for repos that do not use every tool', () => {
  const run = (name) => ({ status: 0, stdout: REAL_OUTPUT[name], stderr: '' });
  const results = checkTools(readTable(), ['node', 'shellcheck'], run);
  assert.deepEqual(
    results.map((r) => r.name),
    ['node', 'shellcheck'],
  );
});

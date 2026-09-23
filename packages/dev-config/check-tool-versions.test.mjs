import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, rmSync, symlinkSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { after, test } from 'node:test';
import { fileURLToPath } from 'node:url';
import {
  checkTools,
  extractVersion,
  formatResult,
  isProgram,
  main,
  readTable,
  runTool,
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

test('no output at all yields undefined rather than a bogus version', () => {
  assert.equal(extractVersion(undefined), undefined);
  assert.equal(extractVersion(null), undefined);
});

test('a tool with no args of its own is asked --version', () => {
  const calls = [];
  const run = (name, args) => {
    calls.push([name, args]);
    return { status: 0, stdout: '1.0.0\n' };
  };
  const [result] = checkTools({ tools: { plain: { version: '1.0.0', match: 'exact' } } }, ['plain'], run);
  assert.deepEqual(calls, [['plain', ['--version']]]);
  assert.equal(result.status, 'ok');
});

test('a version printed on stderr alone is still read', () => {
  const run = () => ({ status: 0, stderr: 'typos-cli 1.50.1\n' });
  const [result] = checkTools(readTable(), ['typos'], run);
  assert.deepEqual(result, { name: 'typos', status: 'ok', want: '1.50.1', found: '1.50.1' });
});

test('each result is formatted as one aligned line', () => {
  assert.equal(formatResult({ name: 'node', status: 'ok', found: '24.20.0' }), '  ok       node 24.20.0');
  assert.equal(formatResult({ name: 'nonesuch', status: 'unknown' }), '  unknown  nonesuch is not in versions.json');
  assert.equal(formatResult({ name: 'typos', status: 'missing', want: '1.50.1' }), '  missing  typos is not on PATH (baseline pins 1.50.1)');
  assert.equal(formatResult({ name: 'typos', status: 'mismatch', want: '1.50.1', found: '1.49.0' }), '  MISMATCH typos is 1.49.0, baseline pins 1.50.1');
  assert.equal(formatResult({ name: 'typos', status: 'mismatch', want: '1.50.1' }), '  MISMATCH typos is unreadable, baseline pins 1.50.1');
});

// --- the program ----------------------------------------------------------------

const BIN = fileURLToPath(new URL('./bin/check-tool-versions.mjs', import.meta.url));
const temporaryDirectories = [];
after(() => {
  for (const dir of temporaryDirectories) rmSync(dir, { recursive: true, force: true });
});

function temporaryDirectory() {
  const dir = mkdtempSync(path.join(tmpdir(), 'dev-config-tools-'));
  temporaryDirectories.push(dir);
  return dir;
}

function sink() {
  return {
    text: '',
    write(chunk) {
      this.text += chunk;
      return true;
    },
  };
}

function runMain(argv, options = {}) {
  const stdout = sink();
  const stderr = sink();
  const code = main(argv, { stdout, stderr, ...options });
  return { code, stdout: stdout.text, stderr: stderr.text };
}

const realRun = (name) => ({ status: 0, stdout: REAL_OUTPUT[name], stderr: '' });

test('the runner returns what the tool printed and its exit code', () => {
  const result = runTool(process.execPath, ['--version']);
  assert.equal(result.status, 0);
  assert.equal(result.stdout, `${process.version}\n`);
});

test('the runner reports a command that never started as status null', () => {
  assert.deepEqual(runTool('dev-config-no-such-command', ['--version']), { status: null });
});

test('with no arguments the program checks every pinned tool and exits 0 when all agree', () => {
  const table = readTable();
  const names = Object.keys(table.tools);
  const { code, stdout, stderr } = runMain([], { table, run: realRun });
  assert.equal(code, 0);
  assert.equal(stderr, '');
  const lines = stdout.trimEnd().split('\n');
  assert.equal(lines.length, names.length + 1);
  assert.deepEqual(lines.slice(0, -1).map((line) => line.split(/\s+/)[2]), names);
  assert.equal(lines.at(-1), `tool versions ok (${names.length} checked)`);
});

test('named tools are the only ones checked', () => {
  const { code, stdout } = runMain(['node'], { run: realRun });
  assert.equal(code, 0);
  assert.equal(stdout, '  ok       node 24.20.0\ntool versions ok (1 checked)\n');
});

test('a disagreeing, missing or unknown tool fails the program, naming each', () => {
  const run = (name) => (name === 'typos' ? { status: 0, stdout: 'typos-cli 1.49.0\n' } : { status: null });
  const { code, stdout, stderr } = runMain(['typos', 'node', 'nonesuch'], { run });
  assert.equal(code, 1);
  assert.equal(
    stdout,
    '  MISMATCH typos is 1.49.0, baseline pins 1.50.1\n  missing  node is not on PATH (baseline pins 24)\n  unknown  nonesuch is not in versions.json\n',
  );
  assert.equal(stderr, '::error::tool versions disagree with the baseline: typos, node, nonesuch\n');
});

test('the file counts as a program only when node was started on it, through any symlink', () => {
  const url = new URL('./bin/check-tool-versions.mjs', import.meta.url).href;
  const link = path.join(temporaryDirectory(), 'check-tool-versions');
  symlinkSync(BIN, link);
  assert.equal(isProgram(url, BIN), true);
  assert.equal(isProgram(url, link), true);
  assert.equal(isProgram(url, fileURLToPath(import.meta.url)), false);
  assert.equal(isProgram(url, undefined), false);
  assert.equal(isProgram(url, path.join(temporaryDirectory(), 'absent.mjs')), false);
});

test('run as a program, it reports and exits 1 for a tool the table does not know', () => {
  // A tool that is not pinned needs nothing installed, so this holds on any machine.
  const result = spawnSync(process.execPath, [BIN, 'not-a-tool'], { encoding: 'utf8' });
  assert.equal(result.status, 1);
  assert.equal(result.stdout, '  unknown  not-a-tool is not in versions.json\n');
  assert.equal(result.stderr, '::error::tool versions disagree with the baseline: not-a-tool\n');
});

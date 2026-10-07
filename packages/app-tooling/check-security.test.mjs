import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { after, test } from 'node:test';
import { fileURLToPath } from 'node:url';
import { main, SCAN } from './bin/check-security.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));
const tmp = mkdtempSync(path.join(tmpdir(), 'check-security-'));
after(() => rmSync(tmp, { recursive: true, force: true }));

// The environment a child sees: the caller's, less anything that would steer
// the settings resolver or make a missing tool a failure, plus the case's own.
const env = (extra = {}) => {
  const base = { ...process.env };
  for (const key of Object.keys(base)) if (key.startsWith('SECURITY_') || key === 'CI') delete base[key];
  delete base.GITHUB_WORKSPACE;
  return { ...base, ...extra };
};

let n = 0;
/** A throwaway repository to scan, with the files a case hands it. */
const repository = (files = {}) => {
  const dir = path.join(tmp, `repository-${++n}`);
  mkdirSync(dir, { recursive: true });
  for (const [name, text] of Object.entries(files)) writeFileSync(path.join(dir, name), text);
  return dir;
};

const POLICY_OK = [
  'minimumReleaseAge: 1440',
  'strictDepBuilds: true',
  'trustPolicy: no-downgrade',
  '',
].join('\n');

/** Runs the program the way a consumer does, in `cwd`, and captures it. */
const program = (args, cwd, extra) =>
  spawnSync(process.execPath, [path.join(here, 'bin', 'check-security.mjs'), ...args], {
    cwd,
    encoding: 'utf8',
    env: env(extra),
  });

test('SCAN is the package copy of the runner loop', () => {
  assert.equal(SCAN, path.join(here, 'security', 'scan.sh'));
  assert.ok(existsSync(SCAN));
});

test('main runs the loop in the given directory with the arguments, and returns its code', () => {
  const calls = [];
  const run = (command, args, options) => {
    calls.push({ command, args, options });
    return { status: 3 };
  };
  assert.equal(main(['policy', 'code'], { run, cwd: '/somewhere' }), 3);
  assert.deepEqual(calls, [
    { command: 'bash', args: [SCAN, 'policy', 'code'], options: { cwd: '/somewhere', stdio: 'inherit' } },
  ]);
});

test('a loop killed by a signal is a failure, not a pass', () => {
  assert.equal(main([], { run: () => ({ status: null, signal: 'SIGTERM' }) }), 1);
});

test('bash that cannot be started is thrown, not read as an exit code', () => {
  const error = new Error('spawn bash ENOENT');
  assert.throws(() => main([], { run: () => ({ error }) }), /ENOENT/);
});

test('with scanning switched off it says so and passes', () => {
  const run = program([], repository({ 'package.json': '{}' }), { SECURITY_ENABLED: 'false' });
  assert.equal(run.status, 0, run.stderr);
  assert.match(run.stdout, /security scanning is disabled/);
});

test('one job against a compliant repository writes its SARIF and passes the verdict', () => {
  const dir = repository({ 'pnpm-workspace.yaml': POLICY_OK });
  const run = program(['policy'], dir);
  assert.equal(run.status, 0, run.stderr + run.stdout);
  const sarif = JSON.parse(readFileSync(path.join(dir, '.security', 'policy.sarif'), 'utf8'));
  assert.equal(sarif.runs[0].tool.driver.name, 'policy');
});

test('a finding that blocks fails the run', () => {
  const run = program(['policy'], repository({ 'pnpm-workspace.yaml': 'strictDepBuilds: false\n' }));
  assert.equal(run.status, 1, run.stderr + run.stdout);
});

test('an unknown job is a usage error', () => {
  const run = program(['nope'], repository());
  assert.equal(run.status, 2);
  assert.match(run.stderr, /unknown security job: nope/);
});

test('main answers --help with its usage on stdout and exit 0, before anything else', async () => {
  const out = [];
  const err = [];
  const code = await main(['--help'], { log: (line) => out.push(line), run: () => assert.fail('--help ran something') });
  assert.equal(code, 0);
  assert.match(out.join(''), /^ +check-security(?: |$)/m);
  assert.deepEqual(err, []);
});

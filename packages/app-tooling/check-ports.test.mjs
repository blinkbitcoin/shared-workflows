import assert from 'node:assert/strict';
import { execFileSync, spawnSync } from 'node:child_process';
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { after, test } from 'node:test';
import { fileURLToPath } from 'node:url';
import { main, offenders, trackedFiles } from './bin/check-ports.mjs';
import { isAllowed, isBinary, portPattern } from './lib/port-literals.mjs';

const BIN = fileURLToPath(new URL('./bin/check-ports.mjs', import.meta.url));
const work = mkdtempSync(path.join(tmpdir(), 'check-ports-'));
after(() => rmSync(work, { recursive: true, force: true }));
const PORTS = [8080, 8081, 8082, 8083, 8089, 4000];
const pattern = portPattern(PORTS);

// Every shape a port has been written in, including the two a plain revert of a
// mock API server and a Maestro script would bring back. A check that misses
// those is decoration.
test('the pattern catches a number used as a port', () => {
  for (const line of [
    // A template literal with an escaped `$` so a linter does not read the shell
    // parameter expansion as a botched JS one; the string is byte-identical.
    `METRO_PORT="\${METRO_PORT:-8081}"`,
    'const port = Number(process.env.MOCK_API_PORT ?? 4000);',
    'MOCK_API_PORT=8082',
    'pnpm exec expo serve dist -p 8083',
    '  const port = 8083;',
    '  webServer: { port: 8083 },',
    'const metroPort = 8081;',
    "  use: { baseURL: 'http://localhost:8089' },",
    'adb reverse tcp:8081 tcp:8081',
    'url=http%3A%2F%2Flocalhost%3A8081',
    'url=http%3a%2f%2flocalhost%3a8081',
    '| `make dev-api` | Local GraphQL mock API on :4000 |',
    '`server.ts` starts on port 4000.',
    'the mock API on 4000 and',
  ]) {
    assert.ok(pattern.test(line), `missed ${line}`);
  }
});

// ...without sweeping in the numbers that merely look like ports: a store note
// character limit is the same shape as `port: 8083`, which is why the check keys
// on a prefix at all.
test('the pattern ignores numbers that merely look like ports', () => {
  for (const line of [
    'TESTFLIGHT_NOTES_LIMIT = 4000',
    'export const STORE_LIMITS = { testflight: 4000, play: 500, appstore: 4000 };',
    '| App Store | release notes ("What\'s New") | 4000 characters |',
    '        write_release_notes!(dir, kind: :appstore, limit: 4000)',
    'truncated at word boundaries (4000 TestFlight, 500 Play), optionally',
    'const APP_BUILD_NUMBER = 8081234;',
    'support 4000 users',
  ]) {
    assert.ok(!pattern.test(line), `should not match ${line}`);
  }
});

test('an allowed path is the file itself or anything under a prefix', () => {
  assert.ok(isAllowed('docs/decisions/0001.md', ['docs/decisions/']));
  assert.ok(isAllowed('.mise.toml', ['.mise.toml']));
  assert.ok(!isAllowed('docs/other.md', ['docs/decisions/', '.mise.toml']));
  assert.ok(!isAllowed('a', []));
});

test('a NUL in the first chunk marks a file as not text', () => {
  writeFileSync(path.join(work, 'binary'), Buffer.from([1, 0, 2]));
  writeFileSync(path.join(work, 'text'), 'port: 8081');
  assert.equal(isBinary(path.join(work, 'binary')), true);
  assert.equal(isBinary(path.join(work, 'text')), false);
});

test('offenders names file, line and text, and skips binary, unreadable and vanished files', () => {
  const files = { 'a.sh': 'ok\nport: 8081 # here\n', 'b.md': 'nothing', 'c.bin': 'port: 8081', 'd.txt': 'x', 'e.txt': 'x' };
  const found = offenders('/r', Object.keys(files), pattern, {
    isText: (absolute) => {
      if (absolute.endsWith('d.txt')) throw new Error('gone');
      return !absolute.endsWith('c.bin');
    },
    read: (absolute) => {
      if (absolute.endsWith('e.txt')) throw new Error('unreadable');
      return files[path.basename(absolute)];
    },
  });
  assert.deepEqual(found, ['a.sh:2: port: 8081 # here']);
});

test('trackedFiles lists what git tracks, whatever the name', () => {
  const dir = path.join(work, 'repo');
  mkdirSync(dir);
  execFileSync('git', ['init', '-q'], { cwd: dir });
  writeFileSync(path.join(dir, 'with space.txt'), 'x');
  execFileSync('git', ['add', '.'], { cwd: dir });
  assert.deepEqual(trackedFiles(dir), ['with space.txt']);
});

function run(argv, { files = {}, found = [], listed = ['a.sh', 'docs/decisions/x.md'], env } = {}) {
  const out = { log: [], error: [], scanned: [] };
  const code = main(argv, {
    cwd: '/app',
    env,
    list: () => listed,
    scan: (root, list, regex) => {
      out.scanned.push([root, list, regex]);
      return found;
    },
    log: (line) => out.log.push(line),
    error: (line) => out.error.push(line),
  });
  return { code, ...out };
}

test('with nothing hardcoded it passes, naming the ports it looked for and how many files are allowed', () => {
  assert.deepEqual(run([]).log, ['ports ok (8080, 8081, 8082, 8083; 0 allowed)']);
});

test('the retired ports and an app-specific table are part of what it looks for, and an allowed path is not scanned', async () => {
  const { readFileSync } = await import('node:fs');
  const dir = path.join(work, 'configured');
  mkdirSync(dir);
  writeFileSync(
    path.join(dir, 'app-tooling.json'),
    JSON.stringify({ ports: { base: 9000, services: { api: { offset: 5, env: 'API_PORT', what: 'x' } }, retired: [4000], allow: { 'docs/decisions/': 'history', '.mise.toml': 'the default' } } }),
  );
  const out = { log: [], scanned: [] };
  const code = main(['--root', dir], {
    cwd: work,
    list: () => ['a.sh', 'docs/decisions/x.md', '.mise.toml'],
    scan: (root, list, regex) => {
      out.scanned.push([root, list, regex.source]);
      return [];
    },
    log: (line) => out.log.push(line),
    error() {},
  });
  assert.equal(code, 0);
  assert.deepEqual(out.log, ['ports ok (9000, 9005, 4000; 2 allowed)']);
  assert.deepEqual(out.scanned[0].slice(0, 2), [dir, ['a.sh']]);
  assert.ok(readFileSync(path.join(dir, 'app-tooling.json'), 'utf8').includes('retired'));
});

test('a finding fails the run, listing each line and how to fix it', () => {
  const result = run([], { found: ['a.sh:2: port: 8081'] });
  assert.equal(result.code, 1);
  assert.equal(result.error[0], 'a.sh:2: port: 8081');
  assert.match(result.error[1], /^check-ports: 1 hardcoded port\(s\)\. Derive them from APP_PORT_BASE with `ports`, or name the file in "ports\.allow"/);
});

test('a bad configuration exits 2, naming what is wrong', () => {
  const dir = path.join(work, 'bad');
  mkdirSync(dir);
  const check = (config) => {
    writeFileSync(path.join(dir, 'app-tooling.json'), JSON.stringify(config));
    const errors = [];
    const code = main(['--root', dir], { cwd: work, list: () => [], scan: () => [], log() {}, error: (line) => errors.push(line) });
    return { code, errors };
  };
  for (const [config, reason] of [
    [{ ports: { retired: ['4000'] } }, /"ports\.retired" must be a list of port numbers/],
    [{ ports: { retired: 4000 } }, /"ports\.retired" must be a list of port numbers/],
    [{ ports: { retired: [70000] } }, /"ports\.retired" must be a list of port numbers/],
    [{ ports: { allow: ['x'] } }, /"ports\.allow" must be an object of non-empty strings/],
    [{ ports: { allow: { x: '' } } }, /"ports\.allow" must be an object of non-empty strings/],
    [{ ports: { base: 0 } }, /"ports\.base" must be a port number/],
  ]) {
    const { code, errors } = check(config);
    assert.equal(code, 2, JSON.stringify(config));
    assert.match(errors[0], reason, JSON.stringify(config));
  }
});

test('an error that is not about the configuration is not swallowed', () => {
  assert.throws(() => main([], { cwd: '/app', list: () => { throw new TypeError('boom'); }, log() {}, error() {} }), TypeError);
});

test('a bad argument exits 2 with the usage', () => {
  for (const argv of [['--nope'], ['--root'], ['x']]) {
    const result = run(argv);
    assert.deepEqual([result.code, result.error], [2, ['usage: check-ports [--root DIR]']], argv.join(' '));
  }
});

test('as a program it fails on a tracked file that hardcodes a port, and passes once it is allowed', () => {
  const dir = path.join(work, 'program');
  mkdirSync(dir);
  execFileSync('git', ['init', '-q'], { cwd: dir });
  writeFileSync(path.join(dir, 'start.sh'), 'serve -p 8081\n');
  execFileSync('git', ['add', '.'], { cwd: dir });
  const failed = spawnSync(process.execPath, [BIN], { cwd: dir, encoding: 'utf8' });
  assert.equal(failed.status, 1);
  assert.match(failed.stderr, /start\.sh:1: serve -p 8081/);
  writeFileSync(path.join(dir, 'app-tooling.json'), '{"ports":{"allow":{"start.sh":"a reviewed exception"}}}');
  execFileSync('git', ['add', '.'], { cwd: dir });
  const passed = spawnSync(process.execPath, [BIN], { cwd: dir, encoding: 'utf8' });
  assert.equal(passed.status, 0);
  assert.match(passed.stdout, /^ports ok \(8080, 8081, 8082, 8083; 1 allowed\)/);
});

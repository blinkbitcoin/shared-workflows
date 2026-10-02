import assert from 'node:assert/strict';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { after, test } from 'node:test';
import { isAllowed, isBinary, portPattern } from './lib/port-literals.mjs';

const work = mkdtempSync(path.join(tmpdir(), 'port-literals-'));
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


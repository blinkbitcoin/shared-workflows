import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { after, test } from 'node:test';
import { fileURLToPath } from 'node:url';
import { main } from './bin/ports.mjs';
import {
  BASE_DEFAULT,
  BASE_VAR,
  baseFrom,
  envLines,
  mockApiUrl,
  PortError,
  portFrom,
  resolvePorts,
  SERVICES,
  tableLines,
} from './lib/ports.mjs';

const BIN = fileURLToPath(new URL('./bin/ports.mjs', import.meta.url));
const work = mkdtempSync(path.join(tmpdir(), 'ports-'));
after(() => rmSync(work, { recursive: true, force: true }));

test('the base is 8080 and every service has its own consecutive offset and variable', () => {
  assert.equal(BASE_DEFAULT, 8080);
  // Metro is +1 on purpose: 8081 is Expo's default and what the dev-client deep link assumes.
  assert.deepEqual(Object.values(SERVICES).map((s) => s.offset), [1, 2, 3]);
  const names = Object.values(SERVICES).map((s) => s.env);
  assert.equal(new Set(names).size, names.length);
});

test('with nothing set every service is the base plus its offset', () => {
  assert.deepEqual(resolvePorts({}), { base: 8080, metro: 8081, mockApi: 8082, webPreview: 8083 });
});

test('the base moves every service, and one override moves only its own', () => {
  assert.deepEqual(resolvePorts({ [BASE_VAR]: '8090' }), { base: 8090, metro: 8091, mockApi: 8092, webPreview: 8093 });
  assert.deepEqual(resolvePorts({ [BASE_VAR]: '8090', MOCK_API_PORT: '4444' }), { base: 8090, metro: 8091, mockApi: 4444, webPreview: 8093 });
  assert.equal(resolvePorts({ METRO_PORT: '' }).metro, 8081, 'an empty override is unset');
});

test('a value that is not a port fails naming the variable, rather than a server that never comes up', () => {
  for (const bad of ['abc', '0', '65536', '80a', '-1', '8 0']) {
    assert.throws(() => portFrom('METRO_PORT', bad, 1), (e) => e instanceof PortError && /METRO_PORT must be a port number \(1-65535\)/.test(e.message), bad);
  }
  assert.throws(() => baseFrom({ [BASE_VAR]: 'x' }), PortError);
  assert.equal(portFrom('X', undefined, 7), 7);
  assert.equal(portFrom('X', '65535', 7), 65535);
  assert.equal(baseFrom({}, 9000), 9000);
});

test("the mock API URL is localhost on its port, at the family's path unless told another", () => {
  assert.equal(mockApiUrl(8082), 'http://localhost:8082/graphql');
  assert.equal(mockApiUrl(8082, '/q'), 'http://localhost:8082/q');
});

test('the export lines hold every service, Expo\'s Metro variable and the API URL', () => {
  assert.deepEqual(envLines({}), [
    'export APP_PORT_BASE=8080',
    'export METRO_PORT=8081',
    'export MOCK_API_PORT=8082',
    'export WEB_PREVIEW_PORT=8083',
    'export RCT_METRO_PORT=8081',
    'export EXPO_PUBLIC_API_URL=http://localhost:8082/graphql',
  ]);
  assert.ok(envLines({ [BASE_VAR]: '8090' }).includes('export EXPO_PUBLIC_API_URL=http://localhost:8092/graphql'));
});

test("an app's own table replaces the family's, and the Expo values appear only for the services they name", () => {
  const services = { api: { offset: 5, env: 'API_PORT', what: 'the api' } };
  assert.deepEqual(envLines({}, { base: 9000, services }), ['export APP_PORT_BASE=9000', 'export API_PORT=9005']);
  assert.deepEqual(resolvePorts({ API_PORT: '1234' }, { base: 9000, services }), { base: 9000, api: 1234 });
  assert.deepEqual(envLines({}, { services: { metro: SERVICES.metro } }), ['export APP_PORT_BASE=8080', 'export METRO_PORT=8081', 'export RCT_METRO_PORT=8081']);
  assert.deepEqual(envLines({}, { apiPath: '/q' }).slice(-1), ['export EXPO_PUBLIC_API_URL=http://localhost:8082/q']);
});

test('the table lists each service with its port, offset, variable and what listens there', () => {
  assert.deepEqual(tableLines({}), [
    'APP_PORT_BASE=8080 (default 8080)',
    '  8081   base+1  METRO_PORT  Metro / the Expo dev server',
    '  8082   base+2  MOCK_API_PORT  the mock API',
    '  8083   base+3  WEB_PREVIEW_PORT  the static web preview',
  ]);
  assert.equal(tableLines({}, { base: 9000 })[0], 'APP_PORT_BASE=9000 (default 9000)');
});

function run(argv, { env = {}, files = {} } = {}) {
  const out = { log: [], error: [] };
  const code = main(argv, {
    env,
    cwd: '/app',
    read: (file) => files[file] ?? null,
    log: (line) => out.log.push(line),
    error: (line) => out.error.push(line),
  });
  return { code, ...out };
}

test('--sh prints the export lines and no argument the table', () => {
  assert.equal(run(['--sh']).log[0].split('\n')[0], 'export APP_PORT_BASE=8080');
  assert.match(run([]).log[0], /^APP_PORT_BASE=8080 \(default 8080\)\n {2}8081 /);
});

test("the app's own table comes from the ports section of app-tooling.json, read from --root when given", () => {
  const files = { '/app/app-tooling.json': '{"ports":{"base":9000,"services":{"api":{"offset":5,"env":"API_PORT","what":"the api"}}}}' };
  assert.deepEqual(run(['--sh'], { files }).log, ['export APP_PORT_BASE=9000\nexport API_PORT=9005']);
  const elsewhere = { '/other/app-tooling.json': '{"ports":{"base":7000}}' };
  assert.equal(run(['--sh', '--root', '/other'], { files: elsewhere }).log[0].split('\n')[0], 'export APP_PORT_BASE=7000');
});

test('a bad variable or a bad configuration exits 2 with the reason, and a bad argument with the usage', () => {
  const bad = run(['--sh'], { env: { MOCK_API_PORT: 'x' } });
  assert.equal(bad.code, 2);
  assert.deepEqual(bad.error, ['ports: MOCK_API_PORT must be a port number (1-65535), got "x"']);
  const config = run([], { files: { '/app/app-tooling.json': '{"ports":{"base":0}}' } });
  assert.equal(config.code, 2);
  assert.match(config.error[0], /^ports: app-tooling\.json: "ports\.base" must be a port number/);
  for (const argv of [['--nope'], ['--root'], ['--sh', 'x']]) {
    const usage = run(argv);
    assert.deepEqual([usage.code, usage.error], [2, ['usage: ports [--sh] [--root DIR]']], argv.join(' '));
  }
});

test('an error that is not about ports is not swallowed', () => {
  assert.throws(() => main([], { cwd: '/app', read: () => { throw new TypeError('boom'); }, log() {}, error() {} }), TypeError);
});

test('as a program it prints the exports, and fails on a bad variable', () => {
  const ok = spawnSync(process.execPath, [BIN, '--sh'], { cwd: work, encoding: 'utf8', env: { PATH: process.env.PATH } });
  assert.equal(ok.status, 0);
  assert.match(ok.stdout, /^export APP_PORT_BASE=8080\n/);
  writeFileSync(path.join(work, 'app-tooling.json'), '{"ports":{"base":8500}}');
  const moved = spawnSync(process.execPath, [BIN, '--sh'], { cwd: work, encoding: 'utf8', env: { PATH: process.env.PATH, MOCK_API_PORT: '4000' } });
  assert.match(moved.stdout, /export APP_PORT_BASE=8500\nexport METRO_PORT=8501\nexport MOCK_API_PORT=4000\n/);
  const bad = spawnSync(process.execPath, [BIN], { cwd: work, encoding: 'utf8', env: { PATH: process.env.PATH, APP_PORT_BASE: 'x' } });
  assert.equal(bad.status, 2);
});

test('main answers --help with its usage on stdout and exit 0, before anything else', async () => {
  const out = [];
  const err = [];
  const code = await main(['--help'], { log: (line) => out.push(line), error: (line) => err.push(line) });
  assert.equal(code, 0);
  assert.match(out.join(''), /^ +ports(?: |$)/m);
  assert.deepEqual(err, []);
});

import assert from 'node:assert/strict';
import { spawn, spawnSync } from 'node:child_process';
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { after, before, test } from 'node:test';
import { fileURLToPath } from 'node:url';
import { main, normalizeBasePath, resolveRequest, startServer } from './bin/serve-dist.mjs';

const PROGRAM = path.join(path.dirname(fileURLToPath(import.meta.url)), 'bin', 'serve-dist.mjs');

let dist;
let server;
let port;

before(async () => {
  dist = mkdtempSync(path.join(tmpdir(), 'serve-dist-'));
  mkdirSync(path.join(dist, 'details'));
  mkdirSync(path.join(dist, 'guide'));
  writeFileSync(path.join(dist, 'index.html'), 'home');
  writeFileSync(path.join(dist, 'settings.html'), 'settings');
  writeFileSync(path.join(dist, '404.html'), 'not-found shell');
  writeFileSync(path.join(dist, 'details', '[id].html'), 'details');
  writeFileSync(path.join(dist, 'guide', 'index.html'), 'guide');
  server = startServer({ dist, basePath: '/repo', port: 0 });
  await new Promise((resolve) => server.once('listening', resolve));
  port = server.address().port;
});

after(() => {
  server.close();
  rmSync(dist, { recursive: true, force: true });
});

test('normalizes the base path the way Pages needs it', () => {
  assert.equal(normalizeBasePath(undefined), '');
  assert.equal(normalizeBasePath(''), '');
  assert.equal(normalizeBasePath(' / '), '');
  assert.equal(normalizeBasePath('/repo'), '/repo');
  assert.equal(normalizeBasePath('repo/'), '/repo');
});

test('resolves the root, an html route and a directory index', () => {
  assert.equal(resolveRequest(dist, '/repo', '/repo').file, path.join(dist, 'index.html'));
  assert.equal(resolveRequest(dist, '/repo', '/repo/').file, path.join(dist, 'index.html'));
  assert.equal(resolveRequest(dist, '/repo', '/repo/settings').file, path.join(dist, 'settings.html'));
  assert.equal(resolveRequest(dist, '/repo', '/repo/settings?tab=2').file, path.join(dist, 'settings.html'));
  assert.equal(resolveRequest(dist, '', '/settings').file, path.join(dist, 'settings.html'));
  assert.deepEqual(resolveRequest(dist, '', '/guide'), { file: path.join(dist, 'guide', 'index.html'), status: 200 });
});

test('a path with no file gets 404.html with a 404, like Pages', () => {
  const hit = resolveRequest(dist, '/repo', '/repo/details/42');
  assert.equal(hit.file, path.join(dist, '404.html'));
  assert.equal(hit.status, 404);
});

test('a path outside the base path is not this site', () => {
  assert.equal(resolveRequest(dist, '/repo', '/settings'), null);
  assert.equal(resolveRequest(dist, '/repo', '/repository/x'), null);
});

test('a path that escapes dist is answered with the 404 page, not a file', () => {
  const hit = resolveRequest(dist, '', '/../serve-dist.mjs');
  assert.deepEqual(hit, { file: path.join(dist, '404.html'), status: 404 });
});

test('serves over http with the status and type Pages would send', async () => {
  const get = (p) => fetch(`http://localhost:${port}${p}`);
  const home = await get('/repo/');
  assert.equal(home.status, 200);
  assert.equal(home.headers.get('content-type'), 'text/html; charset=utf-8');
  assert.equal(home.headers.get('cache-control'), 'no-store');
  assert.equal(await home.text(), 'home');
  assert.equal(await (await get('/repo/settings')).text(), 'settings');
  const deep = await get('/repo/details/42');
  assert.equal(deep.status, 404);
  assert.equal(await deep.text(), 'not-found shell');
  const elsewhere = await get('/elsewhere');
  assert.equal(elsewhere.status, 404);
  assert.equal(await elsewhere.text(), 'not found');
});

test('a path that is not valid percent-encoding is a 400, not a crash', () => {
  assert.deepEqual(resolveRequest(dist, '/repo', '/repo/%E0%A4%A'), { file: null, status: 400 });
});

test('a malformed request is answered 400 and the server keeps serving', async () => {
  const bad = await fetch(`http://localhost:${port}/repo/%E0%A4%A`);
  assert.equal(bad.status, 400);
  assert.equal(await bad.text(), 'bad request');
  // The next request still reaches it: the URIError used to stop the process.
  const home = await fetch(`http://localhost:${port}/repo/`);
  assert.equal(home.status, 200);
  assert.equal(await home.text(), 'home');
});

test('an unknown extension is served as a plain byte stream', async () => {
  writeFileSync(path.join(dist, 'data.bin'), 'bytes');
  const response = await fetch(`http://localhost:${port}/repo/data.bin`);
  assert.equal(response.headers.get('content-type'), 'application/octet-stream');
  assert.equal(await response.text(), 'bytes');
});

test('a missing 404 page is answered with plain text', async () => {
  const bare = mkdtempSync(path.join(tmpdir(), 'serve-dist-bare-'));
  const plain = startServer({ dist: bare, basePath: '', port: 0 });
  try {
    await new Promise((resolve) => plain.once('listening', resolve));
    const response = await fetch(`http://localhost:${plain.address().port}/nothing`);
    assert.equal(response.status, 404);
    assert.equal(await response.text(), 'not found');
  } finally {
    plain.close();
    rmSync(bare, { recursive: true, force: true });
  }
});

test('a request without a url is treated as the root', () => {
  const written = {};
  const response = {
    writeHead: (status, headers) => Object.assign(written, { status, headers }),
    end: (body) => Object.assign(written, { body }),
  };
  server.emit('request', {}, response);
  assert.deepEqual(written, {
    status: 404,
    headers: { 'content-type': 'text/plain' },
    body: 'not found',
  });
});

/** Runs `main` with a fake server start and captures what it writes. */
const runMain = (argv, env, cwd = path.dirname(dist)) => {
  const started = [];
  const out = [];
  const err = [];
  const code = main(argv, {
    env,
    cwd,
    start: (options) => started.push(options),
    log: (line) => out.push(line),
    error: (line) => err.push(line),
  });
  return { code, started, out, err };
};

test('main serves the directory it is given under the base path on the preview port', () => {
  const { code, started, out, err } = runMain([path.basename(dist)], {
    WEB_PREVIEW_PORT: '8093',
    EXPO_PUBLIC_BASE_URL: 'repo/',
  });
  assert.equal(code, 0);
  assert.deepEqual(started, [{ dist, basePath: '/repo', port: 8093 }]);
  assert.deepEqual(out, [`serving ${dist} at http://localhost:8093/repo (404 -> 404.html)`]);
  assert.deepEqual(err, []);
});

test('main serves dist in the current directory by default, at the root', () => {
  const app = mkdtempSync(path.join(tmpdir(), 'serve-dist-app-'));
  try {
    mkdirSync(path.join(app, 'dist'));
    const { code, started, out } = runMain([], { WEB_PREVIEW_PORT: '8093' }, app);
    assert.equal(code, 0);
    assert.deepEqual(started, [{ dist: path.join(app, 'dist'), basePath: '', port: 8093 }]);
    assert.deepEqual(out, [`serving ${path.join(app, 'dist')} at http://localhost:8093/ (404 -> 404.html)`]);
  } finally {
    rmSync(app, { recursive: true, force: true });
  }
});

test('main without a preview port starts nothing and exits 1', () => {
  const { code, started, err } = runMain([dist], {});
  assert.equal(code, 1);
  assert.deepEqual(started, []);
  assert.deepEqual(err, [
    'WEB_PREVIEW_PORT is not set; export the port the suite expects the preview on before starting it',
  ]);
});

test('main with no export to serve starts nothing and exits 1, naming the directory', () => {
  const missing = path.join(dist, 'nowhere');
  const { code, started, err } = runMain([missing], { WEB_PREVIEW_PORT: '8093' });
  assert.equal(code, 1);
  assert.deepEqual(started, []);
  assert.deepEqual(err, [`no web export at ${missing}; export the site first (the app's build:web)`]);
  const file = runMain([path.join(dist, 'index.html')], { WEB_PREVIEW_PORT: '8093' });
  assert.equal(file.code, 1, 'a file is not an export directory');
});

test('as a command it refuses to start without a preview port', () => {
  const result = spawnSync(process.execPath, [PROGRAM, dist], {
    encoding: 'utf8',
    env: { ...process.env, WEB_PREVIEW_PORT: '' },
  });
  assert.equal(result.status, 1);
  assert.match(result.stderr, /WEB_PREVIEW_PORT is not set/);
});

test('as a command it serves until it is stopped', async () => {
  const probe = startServer({ dist, basePath: '', port: 0 });
  await new Promise((resolve) => probe.once('listening', resolve));
  const free = probe.address().port;
  await new Promise((resolve) => probe.close(resolve));
  const app = mkdtempSync(path.join(tmpdir(), 'serve-dist-program-'));
  mkdirSync(path.join(app, 'dist'));
  writeFileSync(path.join(app, 'dist', 'index.html'), 'program home');
  const served = spawn(process.execPath, [PROGRAM], {
    cwd: app,
    env: { ...process.env, WEB_PREVIEW_PORT: String(free), EXPO_PUBLIC_BASE_URL: '' },
  });
  try {
    const line = await new Promise((resolve) => served.stdout.once('data', (chunk) => resolve(String(chunk))));
    assert.match(line, /^serving .*dist at http:\/\/localhost:\d+\/ \(404 -> 404\.html\)/);
    const response = await fetch(`http://localhost:${free}/`);
    assert.equal(await response.text(), 'program home');
  } finally {
    served.kill();
    await new Promise((resolve) => served.once('exit', resolve));
    rmSync(app, { recursive: true, force: true });
  }
});

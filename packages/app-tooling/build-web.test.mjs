import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { after, test } from 'node:test';
import { fileURLToPath } from 'node:url';
import { main } from './bin/build-web.mjs';

const BIN = fileURLToPath(new URL('./bin/build-web.mjs', import.meta.url));
const work = mkdtempSync(path.join(tmpdir(), 'build-web-'));
after(() => rmSync(work, { recursive: true, force: true }));

function run(argv, { status = 0, error, present = true } = {}) {
  const calls = { run: [], copy: [], error: [] };
  const code = main(argv, {
    cwd: '/app',
    run: (command, args, options) => {
      calls.run.push([command, args, options]);
      return { status, error };
    },
    exists: (file) => {
      calls.exists = file;
      return present;
    },
    copy: (from, to) => calls.copy.push([from, to]),
    error: (line) => calls.error.push(line),
  });
  return { code, ...calls };
}

test('it exports the web target with the arguments it was given, then publishes the router\'s not-found page as 404.html', () => {
  const result = run(['--dev', '--clear']);
  assert.equal(result.code, 0);
  assert.deepEqual(result.run, [['pnpm', ['exec', 'expo', 'export', '--platform', 'web', '--dev', '--clear'], { cwd: '/app' }]]);
  assert.deepEqual(result.copy, [['/app/dist/+not-found.html', '/app/dist/404.html']]);
});

test('a failed export is its exit status, and copies nothing', () => {
  const failed = run([], { status: 3 });
  assert.deepEqual([failed.code, failed.copy], [3, []]);
  assert.equal(run([], { status: null }).code, 1, 'killed by a signal');
});

test('a command that could not run says so', () => {
  const result = run([], { error: new Error('spawn pnpm ENOENT'), status: null });
  assert.equal(result.code, 1);
  assert.deepEqual(result.error, ['build-web: could not run pnpm exec expo: spawn pnpm ENOENT']);
});

test('an export with no not-found page fails naming why there is no 404.html', () => {
  const result = run([], { present: false });
  assert.equal(result.code, 1);
  assert.match(result.error[0], /no dist\/\+not-found\.html, so there is no 404\.html to publish/);
  assert.deepEqual(result.copy, []);
});

test('as a program it runs pnpm and copies the page', () => {
  const bin = path.join(work, 'bin');
  mkdirSync(bin);
  writeFileSync(
    path.join(bin, 'pnpm'),
    '#!/bin/sh\nmkdir -p dist\necho "page" > "dist/+not-found.html"\necho "$@" > args.txt\n',
  );
  chmodSync(path.join(bin, 'pnpm'), 0o755);
  const result = spawnSync(process.execPath, [BIN, '--dev'], { cwd: work, encoding: 'utf8', env: { PATH: `${bin}:${process.env.PATH}` } });
  assert.equal(result.status, 0, result.stderr);
  assert.equal(readFileSync(path.join(work, 'args.txt'), 'utf8').trim(), 'exec expo export --platform web --dev');
  assert.ok(existsSync(path.join(work, 'dist', '404.html')));
});

test('main answers --help with its usage on stdout and exit 0, before anything else', async () => {
  const out = [];
  const err = [];
  const code = await main(['--help'], { log: (line) => out.push(line), error: (line) => err.push(line), run: () => assert.fail('--help ran something') });
  assert.equal(code, 0);
  assert.match(out.join(''), /^ +build-web(?: |$)/m);
  assert.deepEqual(err, []);
});

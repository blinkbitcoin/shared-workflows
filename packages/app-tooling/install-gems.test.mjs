import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { chmodSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { after, test } from 'node:test';
import { fileURLToPath } from 'node:url';
import { main } from './bin/install-gems.mjs';

const BIN = fileURLToPath(new URL('./bin/install-gems.mjs', import.meta.url));
const work = mkdtempSync(path.join(tmpdir(), 'install-gems-'));
after(() => rmSync(work, { recursive: true, force: true }));

const io = (statuses = []) => {
  const out = { log: [], error: [], calls: [] };
  return {
    out,
    options: {
      env: {},
      log: (line) => out.log.push(line),
      error: (line) => out.error.push(line),
      run: (args) => {
        out.calls.push(args.join(' '));
        return statuses.shift() ?? 0;
      },
    },
  };
};

test('it points bundler at vendor/bundle, then installs', () => {
  const { out, options } = io();
  assert.equal(main([], options), 0);
  assert.deepEqual(out.calls, ['config set --local path vendor/bundle', 'install']);
});

test('NO_BUNDLE=1 skips it and says so', () => {
  const { out, options } = io();
  assert.equal(main([], { ...options, env: { NO_BUNDLE: '1' } }), 0);
  assert.deepEqual(out.calls, []);
  assert.deepEqual(out.log, ['NO_BUNDLE=1: skipping bundle install (check-release will need it)']);
});

test('any other NO_BUNDLE value installs', () => {
  const { out, options } = io();
  main([], { ...options, env: { NO_BUNDLE: '0' } });
  assert.equal(out.calls.length, 2);
});

test('a failing step stops there with its status', () => {
  const first = io([3]);
  assert.equal(main([], first.options), 3);
  assert.deepEqual(first.out.calls, ['config set --local path vendor/bundle']);
  assert.deepEqual(first.out.error, ['install-gems: bundle config failed (exit 3)']);
  const second = io([0, 5]);
  assert.equal(main([], second.options), 5);
  assert.deepEqual(second.out.error, ['install-gems: bundle install failed (exit 5)']);
});

test('an argument is refused', () => {
  const { out, options } = io();
  assert.equal(main(['--nope'], options), 1);
  assert.deepEqual(out.error, ['install-gems: unexpected --nope: it takes no arguments']);
  assert.deepEqual(out.calls, []);
});

test('as a command it runs bundle, and a bundle that cannot start is a failure', () => {
  const bin = path.join(work, 'bin');
  const log = path.join(work, 'calls.log');
  spawnSync('mkdir', ['-p', bin]);
  writeFileSync(path.join(bin, 'bundle'), `#!/bin/sh\necho "$@" >> "${log}"\n`);
  chmodSync(path.join(bin, 'bundle'), 0o755);
  const ok = spawnSync(process.execPath, [BIN], { encoding: 'utf8', env: { ...process.env, PATH: bin, NO_BUNDLE: '' } });
  assert.equal(ok.status, 0, ok.stderr);
  assert.equal(readFileSync(log, 'utf8'), 'config set --local path vendor/bundle\ninstall\n');
  const missing = spawnSync(process.execPath, [BIN], { encoding: 'utf8', env: { ...process.env, PATH: path.join(work, 'empty'), NO_BUNDLE: '' } });
  assert.equal(missing.status, 1);
  assert.match(missing.stderr, /bundle config failed \(exit 1\)/);
});

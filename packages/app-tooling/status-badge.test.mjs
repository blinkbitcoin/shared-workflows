import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { after, describe, test } from 'node:test';
import { fileURLToPath } from 'node:url';
import { BadgeError, STATUS_RESULTS } from './lib/badge.mjs';
import { main as statusMain, writeStatusBadge } from './bin/status-badge.mjs';

const tmp = mkdtempSync(path.join(tmpdir(), 'status-badge-'));
after(() => rmSync(tmp, { recursive: true, force: true }));

/** A fresh output directory per case, so no test reads another's leftovers. */
let n = 0;
const outDir = () => path.join(tmp, `out-${++n}`);

describe('writeStatusBadge', () => {
  test('renders each known result', () => {
    for (const [result, expected] of Object.entries(STATUS_RESULTS)) {
      const dir = outDir();
      const badge = writeStatusBadge({ outDir: dir, name: 'unit', label: 'Unit', result });
      assert.equal(badge.message, expected.message);
      assert.ok(readFileSync(path.join(dir, 'unit.svg'), 'utf8').includes(expected.message));
    }
  });

  test('an unknown result is an error', () => {
    assert.throws(
      () => writeStatusBadge({ outDir: outDir(), name: 'unit', label: 'Unit', result: 'green' }),
      BadgeError,
    );
  });

  test('a name that is not a file-safe slug is an error', () => {
    for (const name of ['../evil', 'Unit', 'unit.svg', '']) {
      assert.throws(
        () => writeStatusBadge({ outDir: outDir(), name, label: 'Unit', result: 'success' }),
        BadgeError,
      );
    }
  });

  test('a missing label is an error', () => {
    assert.throws(
      () => writeStatusBadge({ outDir: outDir(), name: 'unit', label: '', result: 'success' }),
      BadgeError,
    );
  });
});

/** Captures what a `main` writes, instead of letting it reach the test output. */
const capture = () => {
  const out = [];
  const err = [];
  return { out, err, io: { log: (line) => out.push(line), error: (line) => err.push(line) } };
};

const HERE = path.dirname(fileURLToPath(import.meta.url));

/**
 * Runs a badge script as a command, in `cwd`. The environment is inherited so
 * the coverage run (NODE_V8_COVERAGE) sees the child too.
 */
const runScript = (script, args, { cwd, env = {} }) =>
  spawnSync(process.execPath, [path.join(HERE, 'bin', script), ...args], {
    cwd,
    encoding: 'utf8',
    env: { ...process.env, ...env },
  });

describe('status-badge main', () => {
  test('writes the named badge and reports it', () => {
    const dir = outDir();
    const { out, io } = capture();
    assert.equal(statusMain(['e2e', 'E2E', 'cancelled', '--out', dir], io), 0);
    assert.deepEqual(out, ['status-badge: E2E: cancelled']);
    assert.ok(readFileSync(path.join(dir, 'e2e.svg'), 'utf8').includes('cancelled'));
  });

  test('a bad result exits 1 with the reason and the usage line', () => {
    const { err, io } = capture();
    assert.equal(statusMain(['unit', 'Unit', 'green', '--out', outDir()], io), 1);
    assert.match(err[0], /unknown job result "green"/);
    assert.equal(
      err[1],
      'usage: status-badge <name> <label> <success|failure|cancelled|skipped> [--out DIR]',
    );
  });

  test('an error that is not a badge error is not swallowed', () => {
    const blocker = path.join(tmp, 'status-blocker');
    writeFileSync(blocker, '');
    assert.throws(
      () => statusMain(['unit', 'Unit', 'success', '--out', path.join(blocker, 'x')], capture().io),
      { code: 'ENOTDIR' },
    );
  });

  test('as a command it writes into coverage/badge by default', () => {
    const cwd = mkdtempSync(path.join(tmp, 'cwd-'));
    const ok = runScript('status-badge.mjs', ['unit', 'Unit', 'success'], { cwd });
    assert.equal(ok.status, 0, ok.stderr);
    assert.equal(ok.stdout, 'status-badge: Unit: passing\n');
    assert.ok(readFileSync(path.join(cwd, 'coverage/badge/unit.svg'), 'utf8').includes('passing'));

    const bad = runScript('status-badge.mjs', [], { cwd });
    assert.equal(bad.status, 1);
    assert.match(bad.stderr, /usage: status-badge </);
  });
});

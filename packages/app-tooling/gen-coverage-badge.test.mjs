import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { after, describe, test } from 'node:test';
import { fileURLToPath } from 'node:url';
import * as badge from './lib/badge.mjs';
import { BadgeError, COLORS } from './lib/badge.mjs';
import {
  argValue,
  BADGE_DIR,
  main as coverageMain,
  SUMMARY_PATH,
  writeCoverageBadge,
} from './bin/gen-coverage-badge.mjs';

const tmp = mkdtempSync(path.join(tmpdir(), 'gen-coverage-badge-'));
after(() => rmSync(tmp, { recursive: true, force: true }));

/** A fresh output directory per case, so no test reads another's leftovers. */
let n = 0;
const outDir = () => path.join(tmp, `out-${++n}`);

const summaryWith = (covered, total) => ({
  total: { lines: { covered, total, skipped: 0, pct: (covered / total) * 100 } },
});

// gen-badges imports them from here, as the template's scripts did.
test('the default paths are the ones the badge library holds', () => {
  assert.equal(BADGE_DIR, badge.BADGE_DIR);
  assert.equal(SUMMARY_PATH, badge.SUMMARY_PATH);
});

describe('argValue', () => {
  test('reads a flag value and falls back when it is absent or dangling', () => {
    assert.equal(argValue(['--out', 'dir'], '--out', 'x'), 'dir');
    assert.equal(argValue([], '--out', 'x'), 'x');
    assert.equal(argValue(['--out'], '--out', 'x'), 'x');
  });
});

describe('writeCoverageBadge', () => {
  test('measures a real summary and writes both files', () => {
    const dir = outDir();
    const summaryFile = path.join(tmp, 'summary.json');
    writeFileSync(summaryFile, JSON.stringify(summaryWith(9, 10)));
    const result = writeCoverageBadge({ outDir: dir, summaryFile });
    assert.equal(result.message, '90%');
    assert.ok(readFileSync(path.join(dir, 'coverage.svg'), 'utf8').includes('90%'));
    assert.equal(JSON.parse(readFileSync(path.join(dir, 'coverage.json'), 'utf8')).message, '90%');
  });

  test('a placeholder reads no summary at all', () => {
    const dir = outDir();
    const result = writeCoverageBadge({
      outDir: dir,
      summaryFile: path.join(tmp, 'does-not-exist.json'),
      status: 'failing',
    });
    assert.equal(result.message, 'failing');
    assert.ok(readFileSync(path.join(dir, 'coverage.svg'), 'utf8').includes(COLORS.red));
  });

  test('a missing summary without a placeholder is an error', () => {
    assert.throws(
      () => writeCoverageBadge({ outDir: outDir(), summaryFile: path.join(tmp, 'nope.json') }),
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

describe('gen-coverage-badge main', () => {
  test('measures the summary named by --summary into --out', () => {
    const dir = outDir();
    const summaryFile = path.join(tmp, 'main-summary.json');
    writeFileSync(summaryFile, JSON.stringify(summaryWith(1, 2)));
    const { out, err, io } = capture();
    assert.equal(coverageMain(['--out', dir, '--summary', summaryFile], io), 0);
    assert.deepEqual(out, ['gen-coverage-badge: 50% (1/2 lines)']);
    assert.deepEqual(err, []);
    assert.ok(readFileSync(path.join(dir, 'coverage.svg'), 'utf8').includes('50%'));
  });

  test('a --status placeholder reads no summary', () => {
    const dir = outDir();
    const { out, io } = capture();
    assert.equal(coverageMain(['--status', 'pending', '--out', dir], io), 0);
    assert.deepEqual(out, ['gen-coverage-badge: pending (placeholder)']);
  });

  test('a missing summary exits 1 with the reason', () => {
    const { out, err, io } = capture();
    const code = coverageMain(['--out', outDir(), '--summary', path.join(tmp, 'gone.json')], io);
    assert.equal(code, 1);
    assert.deepEqual(out, []);
    assert.match(err[0], /gone\.json is missing or unreadable/);
  });

  test('an unknown --status exits 1', () => {
    const { err, io } = capture();
    assert.equal(coverageMain(['--status', 'green', '--out', outDir()], io), 1);
    assert.equal(err.length, 1);
  });

  test('an error that is not a badge error is not swallowed', () => {
    const blocker = path.join(tmp, 'a-file-not-a-directory');
    writeFileSync(blocker, '');
    assert.throws(
      () =>
        coverageMain(['--status', 'failing', '--out', path.join(blocker, 'badge')], capture().io),
      { code: 'ENOTDIR' },
    );
  });

  test('as a command it writes coverage/badge from coverage/coverage-summary.json', () => {
    const cwd = mkdtempSync(path.join(tmp, 'cwd-'));
    const missing = runScript('gen-coverage-badge.mjs', [], { cwd });
    assert.equal(missing.status, 1);
    assert.match(missing.stderr, /coverage\/coverage-summary\.json is missing/);

    const placeholder = runScript('gen-coverage-badge.mjs', ['--status', 'failing'], { cwd });
    assert.equal(placeholder.status, 0, placeholder.stderr);
    assert.equal(placeholder.stdout, 'gen-coverage-badge: failing (placeholder)\n');
    assert.ok(readFileSync(path.join(cwd, 'coverage/badge/coverage.svg'), 'utf8'));
  });
});

test('coverageMain answers --help with its usage on stdout and exit 0, before anything else', async () => {
  const out = [];
  const err = [];
  const code = await coverageMain(['--help'], { log: (line) => out.push(line), error: (line) => err.push(line) });
  assert.equal(code, 0);
  assert.match(out.join(''), /^ +gen-coverage-badge(?: |$)/m);
  assert.deepEqual(err, []);
});

import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';
import {
  emptyCoverageFiles,
  formatEmptyFiles,
  main,
  readSummary,
  summaryFiles,
} from './bin/check-coverage-empty.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));
const FIXTURE = path.join(here, 'fixtures/coverage-summary.json');
const fixture = JSON.parse(readFileSync(FIXTURE, 'utf8'));

test('reports every file with no statements and skips the totals row', () => {
  assert.deepEqual(emptyCoverageFiles(fixture), [
    '/repo/src/app/(tabs)/index.tsx',
    '/repo/src/types/only.ts',
  ]);
});

test('a fully covered report has no empty rows', () => {
  const covered = {
    total: fixture.total,
    '/repo/src/lib/storage.ts': fixture['/repo/src/lib/storage.ts'],
  };
  assert.deepEqual(emptyCoverageFiles(covered), []);
});

test('a row with covered statements is never empty, however low its percentage', () => {
  const partial = {
    '/repo/src/a.ts': { statements: { total: 10, covered: 1, skipped: 0, pct: 10 } },
  };
  assert.deepEqual(emptyCoverageFiles(partial), []);
});

test('a malformed row without a statements block is not reported as empty', () => {
  // Guards the optional chaining: a summary shape we do not recognise must not
  // be read as "nothing to cover" and fail the build for the wrong reason.
  assert.deepEqual(emptyCoverageFiles({ '/repo/src/a.ts': {} }), []);
});

test('each line names the file relative to the repo root and the fix', () => {
  const lines = formatEmptyFiles(['/repo/src/types/only.ts'], '/repo');
  assert.equal(lines.length, 1);
  assert.match(lines[0], /^src\/types\/only\.ts has no statements to cover/);
  assert.match(lines[0], /coveragePathIgnorePatterns/);
});

test('the file count excludes the totals row rather than assuming one', () => {
  assert.equal(summaryFiles(fixture).length, 3);
  // A summary with no `total` row must not under-report by one.
  assert.equal(summaryFiles({ '/repo/src/a.ts': {} }).length, 1);
});

test('readSummary parses a real summary file', () => {
  const { summary, error } = readSummary(FIXTURE);
  assert.equal(error, undefined);
  assert.deepEqual(summaryFiles(summary).length, 3);
});

// The two failure paths below are what stops the check from being vacuous when
// `json-summary` is dropped from `coverageReporters`: no report must read as a
// failure, never as "no empty rows".
test('readSummary reports a missing report and names the reporter', () => {
  const { summary, error } = readSummary(path.join(here, 'fixtures/does-not-exist.json'));
  assert.equal(summary, undefined);
  assert.match(error, /is missing or unreadable/);
  assert.match(error, /json-summary/);
});

test('readSummary reports a malformed report rather than throwing', async (t) => {
  const dir = await mkdtemp(path.join(tmpdir(), 'coverage-empty-'));
  t.after(() => rm(dir, { recursive: true, force: true }));
  const file = path.join(dir, 'coverage-summary.json');
  writeFileSync(file, '{ not json');

  const { summary, error } = readSummary(file);

  assert.equal(summary, undefined);
  assert.match(error, /is missing or unreadable/);
  assert.match(error, /json-summary/);
});

/** Captures what `main` writes, instead of letting it reach the test output. */
const capture = () => {
  const out = [];
  const err = [];
  return { out, err, io: { log: (line) => out.push(line), error: (line) => err.push(line) } };
};

test('main passes a summary with no empty rows and counts its files', async (t) => {
  const { out, err, io } = capture();
  const clean = {
    total: fixture.total,
    '/repo/src/lib/storage.ts': fixture['/repo/src/lib/storage.ts'],
  };
  const dir = await mkdtemp(path.join(tmpdir(), 'coverage-empty-main-'));
  t.after(() => rm(dir, { recursive: true, force: true }));
  const file = path.join(dir, 'clean.json');
  writeFileSync(file, JSON.stringify(clean));
  assert.equal(main(file, io), 0);
  assert.deepEqual(out, ['coverage: no empty rows (1 files)']);
  assert.deepEqual(err, []);
});

test('main fails with one line per empty file', () => {
  const { out, err, io } = capture();
  assert.equal(main(FIXTURE, io), 1);
  assert.deepEqual(out, []);
  assert.equal(err.length, 2);
  assert.match(err[0], /has no statements to cover/);
});

test('main fails when the summary is missing', () => {
  const { err, io } = capture();
  assert.equal(main(path.join(here, 'fixtures/absent.json'), io), 1);
  assert.match(err[0], /is missing or unreadable/);
});

test('as a command it reads coverage/coverage-summary.json from the working directory', async (t) => {
  const cwd = await mkdtemp(path.join(tmpdir(), 'coverage-empty-cwd-'));
  t.after(() => rm(cwd, { recursive: true, force: true }));
  const run = () =>
    spawnSync(process.execPath, [path.join(here, 'bin/check-coverage-empty.mjs')], {
      cwd,
      encoding: 'utf8',
      env: process.env, // keeps NODE_V8_COVERAGE, so the child counts toward coverage
    });

  const missing = run();
  assert.equal(missing.status, 1);
  assert.match(missing.stderr, /coverage\/coverage-summary\.json is missing/);

  mkdirSync(path.join(cwd, 'coverage'));
  writeFileSync(path.join(cwd, 'coverage/coverage-summary.json'), readFileSync(FIXTURE));
  const empty = run();
  assert.equal(empty.status, 1);
  assert.match(empty.stderr, /has no statements to cover/);
});

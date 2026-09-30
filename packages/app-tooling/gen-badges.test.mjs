import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import {
  mkdirSync,
  mkdtempSync,
  readFileSync,
  realpathSync,
  rmSync,
  symlinkSync,
  writeFileSync,
} from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { after, describe, test } from 'node:test';
import { fileURLToPath } from 'node:url';
import { BadgeError, COLORS } from './lib/badge.mjs';
import { coverageModeFor, renderBadges, main as renderMain } from './bin/gen-badges.mjs';

const tmp = mkdtempSync(path.join(tmpdir(), 'badge-render-'));
after(() => rmSync(tmp, { recursive: true, force: true }));

/** A fresh output directory per case, so no test reads another's leftovers. */
let n = 0;
const outDir = () => path.join(tmp, `out-${++n}`);

const summaryWith = (covered, total) => ({
  total: { lines: { covered, total, skipped: 0, pct: (covered / total) * 100 } },
});

describe('coverageModeFor', () => {
  test('only a failure writes the red placeholder', () => {
    assert.equal(coverageModeFor('success'), 'measure');
    assert.equal(coverageModeFor('failure'), 'failing');
    for (const result of ['skipped', 'cancelled', '']) {
      assert.equal(coverageModeFor(result), 'skip');
    }
  });
});

describe('renderBadges', () => {
  const summaryFile = path.join(tmp, 'render-summary.json');
  writeFileSync(summaryFile, JSON.stringify(summaryWith(348, 348)));

  test('a green run renders coverage plus both statuses', () => {
    const dir = outDir();
    const written = renderBadges({
      BADGE_OUT_DIR: dir,
      BADGE_COVERAGE_SUMMARY: summaryFile,
      BADGE_UNIT: 'success',
      BADGE_E2E: 'success',
    });
    assert.deepEqual(written, ['coverage.svg', 'unit.svg', 'e2e.svg']);
    assert.ok(readFileSync(path.join(dir, 'coverage.svg'), 'utf8').includes('100%'));
    assert.ok(readFileSync(path.join(dir, 'e2e.svg'), 'utf8').includes('passing'));
  });

  test('a failed Unit renders the red placeholder without reading the summary', () => {
    const dir = outDir();
    renderBadges({
      BADGE_OUT_DIR: dir,
      BADGE_COVERAGE_SUMMARY: path.join(tmp, 'absent.json'),
      BADGE_UNIT: 'failure',
      BADGE_E2E: 'skipped',
    });
    const svg = readFileSync(path.join(dir, 'coverage.svg'), 'utf8');
    assert.ok(svg.includes('failing'));
    assert.ok(svg.includes(COLORS.red));
    assert.ok(readFileSync(path.join(dir, 'unit.svg'), 'utf8').includes('failing'));
  });

  test('a skipped Unit writes no coverage badge, so publishing leaves it alone', () => {
    const dir = outDir();
    const written = renderBadges({
      BADGE_OUT_DIR: dir,
      BADGE_UNIT: 'skipped',
      BADGE_E2E: 'skipped',
    });
    assert.deepEqual(written, ['unit.svg', 'e2e.svg']);
    assert.throws(() => readFileSync(path.join(dir, 'coverage.svg')));
  });

  test('BADGE_COVERAGE overrides the derived mode', () => {
    const dir = outDir();
    renderBadges({
      BADGE_OUT_DIR: dir,
      BADGE_COVERAGE: 'pending',
      BADGE_UNIT: 'skipped',
      BADGE_E2E: 'skipped',
    });
    assert.ok(readFileSync(path.join(dir, 'coverage.svg'), 'utf8').includes('pending'));
  });

  test('labels are overridable', () => {
    const dir = outDir();
    renderBadges({
      BADGE_OUT_DIR: dir,
      BADGE_UNIT: 'success',
      BADGE_E2E: 'success',
      BADGE_COVERAGE: 'skip',
      BADGE_UNIT_LABEL: 'Tests',
      BADGE_E2E_LABEL: 'Device',
    });
    assert.ok(readFileSync(path.join(dir, 'unit.svg'), 'utf8').includes('Tests'));
    assert.ok(readFileSync(path.join(dir, 'e2e.svg'), 'utf8').includes('Device'));
  });

  test('a security verdict renders security.svg after the suites', () => {
    const dir = outDir();
    const written = renderBadges({
      BADGE_OUT_DIR: dir,
      BADGE_UNIT: 'skipped',
      BADGE_E2E: 'skipped',
      BADGE_SECURITY: '{"verdict":"informational","highest":"medium","canBlock":true}',
    });
    assert.deepEqual(written, ['unit.svg', 'e2e.svg', 'security.svg']);
    assert.ok(readFileSync(path.join(dir, 'security.svg'), 'utf8').includes('medium findings'));
  });

  test('BADGE_SECURITY_LABEL renames the security badge', () => {
    const dir = outDir();
    renderBadges({
      BADGE_OUT_DIR: dir,
      BADGE_UNIT: 'skipped',
      BADGE_E2E: 'skipped',
      BADGE_SECURITY: '{"verdict":"pass","highest":"none","canBlock":true}',
      BADGE_SECURITY_LABEL: 'Scan',
    });
    assert.ok(readFileSync(path.join(dir, 'security.svg'), 'utf8').includes('Scan'));
  });

  test('no security verdict writes no security badge, so publishing leaves it alone', () => {
    const dir = outDir();
    const written = renderBadges({
      BADGE_OUT_DIR: dir,
      BADGE_UNIT: 'skipped',
      BADGE_E2E: 'skipped',
    });
    assert.ok(!written.includes('security.svg'));
    assert.throws(() => readFileSync(path.join(dir, 'security.svg')));
  });

  test('an unset job result is an error rather than a green badge', () => {
    assert.throws(
      () => renderBadges({ BADGE_OUT_DIR: outDir(), BADGE_COVERAGE: 'skip' }),
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

describe('render main', () => {
  test('renders from the environment it is given', () => {
    const dir = outDir();
    const code = renderMain(
      { BADGE_OUT_DIR: dir, BADGE_UNIT: 'skipped', BADGE_E2E: 'success' },
      capture().io,
    );
    assert.equal(code, 0);
    assert.ok(readFileSync(path.join(dir, 'e2e.svg'), 'utf8').includes('passing'));
  });

  test('a badge error exits 1 with the reason', () => {
    const { err, io } = capture();
    assert.equal(renderMain({ BADGE_OUT_DIR: outDir(), BADGE_COVERAGE: 'skip' }, io), 1);
    assert.match(err[0], /unknown job result ""/);
  });

  test('an unrecognised security verdict exits 1 with the reason', () => {
    const { err, io } = capture();
    const env = {
      BADGE_OUT_DIR: outDir(),
      BADGE_UNIT: 'skipped',
      BADGE_E2E: 'skipped',
      BADGE_SECURITY: '{"verdict":"nope"}',
    };
    assert.equal(renderMain(env, io), 1);
    assert.match(err[0], /unknown verdict/);
  });

  test('an error that is not a badge error is not swallowed', () => {
    const blocker = path.join(tmp, 'render-blocker');
    writeFileSync(blocker, '');
    assert.throws(
      () =>
        renderMain(
          { BADGE_OUT_DIR: path.join(blocker, 'x'), BADGE_UNIT: 'skipped', BADGE_E2E: 'skipped' },
          capture().io,
        ),
      { code: 'ENOTDIR' },
    );
  });

  test('as a command it reads the environment and defaults to coverage/', () => {
    const cwd = mkdtempSync(path.join(tmp, 'cwd-'));
    mkdirSync(path.join(cwd, 'coverage'));
    writeFileSync(
      path.join(cwd, 'coverage/coverage-summary.json'),
      JSON.stringify(summaryWith(3, 4)),
    );
    const ok = runScript('gen-badges.mjs', [], {
      cwd,
      env: { BADGE_UNIT: 'success', BADGE_E2E: 'skipped', BADGE_OUT_DIR: '', BADGE_COVERAGE: '' },
    });
    assert.equal(ok.status, 0, ok.stderr);
    assert.ok(readFileSync(path.join(cwd, 'coverage/badge/coverage.svg'), 'utf8').includes('75%'));

    const bad = runScript('gen-badges.mjs', [], {
      cwd,
      env: { BADGE_UNIT: 'nonsense', BADGE_E2E: 'skipped', BADGE_COVERAGE: 'skip' },
    });
    assert.equal(bad.status, 1);
    assert.match(bad.stderr, /unknown job result "nonsense"/);
  });

  // `pnpm exec gen-badges` reaches it through a link in node_modules/.bin;
  // a guard that saw that as "imported" would render nothing and exit 0.
  test('run through a link, as node_modules/.bin holds it, it still renders', () => {
    const cwd = realpathSync(mkdtempSync(path.join(tmp, 'link-')));
    const link = path.join(cwd, 'gen-badges');
    symlinkSync(path.join(HERE, 'bin', 'gen-badges.mjs'), link);
    const run = spawnSync(process.execPath, [link], {
      cwd,
      encoding: 'utf8',
      env: { ...process.env, BADGE_UNIT: 'skipped', BADGE_E2E: 'success', BADGE_OUT_DIR: 'out' },
    });
    assert.equal(run.status, 0, run.stderr);
    assert.ok(readFileSync(path.join(cwd, 'out/e2e.svg'), 'utf8').includes('passing'));
  });
});

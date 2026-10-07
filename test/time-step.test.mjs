// scripts/self/time-step.mjs: the program the Makefile puts in front of every
// recipe line of the gates `make check` runs, to time it.
//
// Covered here: the exit status it hands back (a status, a signal with a
// number, a signal without one), every way out of main - the usage errors (no
// target, no `--`, `--` in the wrong place, no command), a command that runs,
// fails, or cannot start, with TIMING_DIR set (the directory made before the
// command, one record appended) and unset (nothing written), and a directory or
// record that cannot be written (a warning, the command's status kept) - plus
// the program run as a program, timed and untimed, and imported, when it runs
// nothing. The Makefile's use of it is held by test/self-workflows.bats.
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { existsSync, mkdtempSync, readFileSync, rmSync } from 'node:fs';
import { constants, tmpdir } from 'node:os';
import path from 'node:path';
import { after, test } from 'node:test';
import { fileURLToPath } from 'node:url';
import { USAGE, exitStatus, main } from '../scripts/self/time-step.mjs';

const ROOT = path.join(path.dirname(fileURLToPath(import.meta.url)), '..');
const SCRIPT = path.join(ROOT, 'scripts/self/time-step.mjs');

const scratch = mkdtempSync(path.join(tmpdir(), 'time-step-'));
after(() => rmSync(scratch, { recursive: true, force: true }));

/** A writable stream stand-in that keeps what was written. */
function sink() {
  return { text: '', write(chunk) { this.text += chunk; } };
}

/** A clock that returns each of `times` in turn. */
function clock(...times) {
  return () => times.shift();
}

/** The environment without the TIMING_DIR a `make check` around this suite exports. */
function cleanEnv(extra = {}) {
  const env = { ...process.env, ...extra };
  if (!('TIMING_DIR' in extra)) delete env.TIMING_DIR;
  return env;
}

test('exitStatus is the status when the command exited', () => {
  assert.equal(exitStatus({ status: 0, signal: null }), 0);
  assert.equal(exitStatus({ status: 3, signal: null }), 3);
});

test('exitStatus is 128 plus the signal number when a signal killed the command', () => {
  assert.equal(exitStatus({ status: null, signal: 'SIGTERM' }), 128 + constants.signals.SIGTERM);
  assert.equal(exitStatus({ status: null, signal: 'SIGINT' }), 130);
});

test('exitStatus is 1 for a signal with no number here', () => {
  assert.equal(exitStatus({ status: null, signal: 'SIGNOTREAL' }), 1);
});

test('main refuses arguments without a target, a -- in second place or a command, running nothing', () => {
  for (const argv of [[], ['t'], ['t', '--'], ['--', 'echo'], ['t', 'echo'], ['t', 'x', '--', 'echo'], ['', '--', 'echo']]) {
    const stderr = sink();
    let ran = false;
    assert.equal(main(argv, { stderr, spawn: () => { ran = true; } }), 2, JSON.stringify(argv));
    assert.equal(stderr.text, `::error::${USAGE}\n`);
    assert.equal(ran, false);
  }
});

test('main with TIMING_DIR makes the directory before the command and appends one record after it', () => {
  const calls = [];
  const stderr = sink();
  const status = main(['test-unit', '--', 'bats', '--jobs', '4', 'test/'], {
    env: { TIMING_DIR: 'runs/one' },
    now: clock(1000, 3500),
    mkdir: (dir, options) => calls.push(['mkdir', dir, options]),
    spawn: (command, args, options) => {
      calls.push(['spawn', command, args, options]);
      return { status: 0, signal: null };
    },
    append: (file, text) => calls.push(['append', file, text]),
    stderr,
  });
  assert.equal(status, 0);
  assert.deepEqual(calls, [
    ['mkdir', 'runs/one', { recursive: true }],
    ['spawn', 'bats', ['--jobs', '4', 'test/'], { stdio: 'inherit' }],
    [
      'append',
      path.join('runs/one', 'targets.jsonl'),
      '{"target":"test-unit","command":"bats --jobs 4 test/","start":1000,"end":3500,"status":0}\n',
    ],
  ]);
  assert.equal(stderr.text, '');
});

test('main hands back a failing command status, and records it', () => {
  let record = '';
  const status = main(['check-ci', '--', 'false'], {
    env: { TIMING_DIR: 'd' },
    now: clock(1, 2),
    mkdir: () => {},
    spawn: () => ({ status: 7, signal: null }),
    append: (file, text) => { record = text; },
    stderr: sink(),
  });
  assert.equal(status, 7);
  assert.equal(JSON.parse(record).status, 7);
});

test('main records a command that cannot start as 127 and says why', () => {
  let record = '';
  const stderr = sink();
  const status = main(['check-ci', '--', 'no-such-tool'], {
    env: { TIMING_DIR: 'd' },
    now: clock(1, 2),
    mkdir: () => {},
    spawn: () => ({ status: null, signal: null, error: new Error('spawnSync no-such-tool ENOENT') }),
    append: (file, text) => { record = text; },
    stderr,
  });
  assert.equal(status, 127);
  assert.equal(JSON.parse(record).status, 127);
  assert.equal(stderr.text, '::error::time-step: cannot run no-such-tool: spawnSync no-such-tool ENOENT\n');
});

test('main without TIMING_DIR runs the command untimed and writes nothing', () => {
  let wrote = false;
  const status = main(['check-spell', '--', 'typos'], {
    env: {},
    mkdir: () => { wrote = true; },
    spawn: () => ({ status: 0, signal: null }),
    append: () => { wrote = true; },
    stderr: sink(),
  });
  assert.equal(status, 0);
  assert.equal(wrote, false);
});

test('main warns when the directory or the record cannot be written, and keeps the command status', () => {
  const stderr = sink();
  const status = main(['check-spell', '--', 'typos'], {
    env: { TIMING_DIR: '/read-only' },
    now: clock(1, 2),
    mkdir: () => { throw new Error('EACCES'); },
    spawn: () => ({ status: 4, signal: null }),
    append: () => { throw new Error('ENOENT'); },
    stderr,
  });
  assert.equal(status, 4);
  assert.equal(
    stderr.text,
    '::warning::time-step: cannot create /read-only: EACCES\n' +
      '::warning::time-step: cannot record check-spell in /read-only: ENOENT\n',
  );
});

test('run as a program it passes the streams through, exits with the command status and records the run', () => {
  const dir = path.join(scratch, 'program', 'run');
  const result = spawnSync(process.execPath, [SCRIPT, 'demo', '--', 'sh', '-c', 'echo out; echo err >&2; exit 3'], {
    encoding: 'utf8',
    env: cleanEnv({ TIMING_DIR: dir }),
  });
  assert.equal(result.status, 3);
  assert.equal(result.stdout, 'out\n');
  assert.equal(result.stderr, 'err\n');
  const lines = readFileSync(path.join(dir, 'targets.jsonl'), 'utf8').trim().split('\n');
  assert.equal(lines.length, 1);
  const record = JSON.parse(lines[0]);
  assert.equal(record.target, 'demo');
  assert.equal(record.command, 'sh -c echo out; echo err >&2; exit 3');
  assert.equal(record.status, 3);
  assert.ok(record.end >= record.start && record.start > 1_600_000_000_000, JSON.stringify(record));
});

test('run as a program without TIMING_DIR it runs the command and writes nothing', () => {
  const result = spawnSync(process.execPath, [SCRIPT, 'demo', '--', 'sh', '-c', 'pwd'], {
    encoding: 'utf8',
    cwd: scratch,
    env: cleanEnv(),
  });
  assert.equal(result.status, 0, result.stderr);
  assert.equal(existsSync(path.join(scratch, 'targets.jsonl')), false);
});

test('run as a program a command killed by a signal exits 128 plus its number', () => {
  const result = spawnSync(process.execPath, [SCRIPT, 'demo', '--', 'sh', '-c', 'kill -TERM $$'], {
    encoding: 'utf8',
    env: cleanEnv(),
  });
  assert.equal(result.status, 128 + constants.signals.SIGTERM, result.stderr);
});

test('run as a program with no arguments it exits 2 with its usage', () => {
  const result = spawnSync(process.execPath, [SCRIPT], { encoding: 'utf8', env: cleanEnv() });
  assert.equal(result.status, 2);
  assert.equal(result.stderr, `::error::${USAGE}\n`);
});

test('imported, it runs nothing', () => {
  const result = spawnSync(process.execPath, ['--input-type=module', '-e', `await import(${JSON.stringify(SCRIPT)});`], {
    encoding: 'utf8',
    env: cleanEnv(),
  });
  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.stdout, '');
  assert.equal(result.stderr, '');
});

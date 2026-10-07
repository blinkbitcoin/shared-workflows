#!/usr/bin/env node
// Run one recipe line of a make target and record how long it took, for
// scripts/self/timing-report.mjs. The Makefile puts it in front of every recipe
// line of every gate `make check` runs ($(TIMED)), so a run says where its
// minutes went instead of leaving it to a guess.
//
//   time-step.mjs TARGET -- COMMAND [ARG...]
//
// COMMAND runs with this process's standard streams, and its exit status is
// this program's. Killed by a signal, it exits 128 plus the signal's number,
// the shell's convention (1 for a signal this platform has no number for); a
// COMMAND that cannot be started at all exits 127, as the shell does for a
// command it cannot find.
//
// With TIMING_DIR set, the directory is created before COMMAND starts - so a
// command may write its own reports into it (bats' junit report.xml, node's
// junit files) - and one JSON line is appended to TIMING_DIR/targets.jsonl:
//
//   {"target":"test-unit","command":"bats --jobs 8 ...","start":1760000000000,"end":1760000012345,"status":0}
//
// `start` and `end` are epoch milliseconds (Date.now()); `command` is the
// arguments joined by spaces, for reading rather than re-running. Without
// TIMING_DIR the command runs untimed, so the program still works by hand. A
// record that cannot be written is a warning, never a failure: timing is
// advice, and must not fail the gate it times (the pre-push hook runs these).
import { spawnSync } from 'node:child_process';
import { appendFileSync, mkdirSync, realpathSync } from 'node:fs';
import { constants } from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

export const USAGE = 'usage: time-step.mjs TARGET -- COMMAND [ARG...]';

/**
 * The exit status a finished spawnSync result stands for: its own status, else
 * 128 plus the number of the signal that killed it, else 1.
 */
export function exitStatus(result) {
  if (result.status !== null) return result.status;
  const number = constants.signals[result.signal];
  return number === undefined ? 1 : 128 + number;
}

/**
 * The whole program, returning its exit code. The process runner, the clock,
 * the environment and the file writers arrive through the second argument, so
 * the tests reach every path in-process; the defaults are the real ones.
 */
export function main(
  argv,
  {
    spawn = spawnSync,
    now = Date.now,
    env = process.env,
    mkdir = mkdirSync,
    append = appendFileSync,
    stderr = process.stderr,
  } = {},
) {
  const separator = argv.indexOf('--');
  if (separator !== 1 || argv[0] === '' || argv.length < 3) {
    stderr.write(`::error::${USAGE}\n`);
    return 2;
  }
  const target = argv[0];
  const [command, ...args] = argv.slice(2);
  const dir = env.TIMING_DIR;

  if (dir) {
    try {
      mkdir(dir, { recursive: true });
    } catch (error) {
      stderr.write(`::warning::time-step: cannot create ${dir}: ${error.message}\n`);
    }
  }

  const start = now();
  const result = spawn(command, args, { stdio: 'inherit' });
  const end = now();
  let status;
  if (result.error) {
    stderr.write(`::error::time-step: cannot run ${command}: ${result.error.message}\n`);
    status = 127;
  } else {
    status = exitStatus(result);
  }

  if (dir) {
    const record = { target, command: [command, ...args].join(' '), start, end, status };
    try {
      append(path.join(dir, 'targets.jsonl'), `${JSON.stringify(record)}\n`);
    } catch (error) {
      stderr.write(`::warning::time-step: cannot record ${target} in ${dir}: ${error.message}\n`);
    }
  }
  return status;
}

// Run as a program rather than imported - the same guard as artifact-hashes.mjs.
if (process.argv[1] && fileURLToPath(import.meta.url) === realpathSync(path.resolve(process.argv[1]))) {
  process.exitCode = main(process.argv.slice(2));
}

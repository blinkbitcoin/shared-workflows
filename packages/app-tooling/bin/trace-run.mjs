#!/usr/bin/env node
// Shows where a GitHub Actions run spent its time: each job's queue and run
// time, the slowest steps, and the critical path, read with the reader's own
// gh login (no workflow permission, nothing added to the workflow).
//
//   trace-run <run URL | owner/repository run-id> [options]
//   e.g. trace-run https://github.com/blinkbitcoin/app/actions/runs/123456789
//        trace-run blinkbitcoin/app 123456789 --logs --compare 123000000
//
//   --attempt N    that attempt of the run (default: its latest, or the one the URL names)
//   --logs         also read each job's log and list its `trace: <phase> <seconds>s`
//                  lines under the step that wrote them
//   --top N        how many slowest steps, and comparison rows, to show (default 15)
//   --sort end|run the jobs table in the order the jobs finished (default), or
//                  by run time, longest first
//   --json FILE    also write the whole tree (run, jobs, steps, phases, critical
//                  path, slowest steps, comparison) to FILE
//   --compare RUN  line up another run's jobs and steps against this one: a run
//                  URL, a run id in the same repository, or owner/repository run-id
//
// The critical path is derived from the timestamps alone: each job on it is the
// one that finished last before the next one started. The workflow file is not
// read. A job still running is measured up to now. Exits 2 on a usage error and
// 1 when gh is missing or fails.
import { spawnSync } from 'node:child_process';
import { writeFileSync } from 'node:fs';
import { isProgram } from '../lib/is-program.mjs';
import {
  analyse,
  attachPhases,
  compareReports,
  parseArgs,
  parseJsonStream,
  renderComparison,
  renderReport,
  toJson,
  TraceError,
  tracePhases,
  USAGE,
  UsageError,
} from '../lib/trace-run.mjs';
import { answerHelp } from '../lib/usage.mjs';

/** Runs `gh` with `args` and returns spawnSync's result; a job log can be large, hence the buffer. */
export function runGh(args, command = 'gh') {
  return spawnSync(command, args, { encoding: 'utf8', maxBuffer: 512 * 1024 * 1024 });
}

/** What `gh` printed, or a TraceError that says why there is nothing: gh missing, or gh failing with its own message. */
export function ghText(gh, args) {
  const result = gh(args);
  if (result.error?.code === 'ENOENT') {
    throw new TraceError('gh is not installed or not on PATH: install gh and run gh auth login');
  }
  if (result.error) throw new TraceError(`gh did not run: ${result.error.message}`);
  if (result.status !== 0) {
    throw new TraceError(`gh ${args.join(' ')} failed (exit ${result.status}):\n${(result.stderr ?? '').trim()}`);
  }
  return result.stdout;
}

/** Every JSON value `gh` printed, at least one. */
export function ghJson(gh, args) {
  const values = parseJsonStream(ghText(gh, args));
  if (values.length === 0) throw new TraceError(`gh ${args.join(' ')} answered nothing`);
  return values;
}

/**
 * The gh flag that lets `gh api` print a body holding terminal escape
 * sequences: a job log has colour codes, and a recent gh refuses to print one
 * without it. The log is only parsed, never printed, and lib/trace-run.mjs
 * strips the sequences from what it keeps.
 */
export const ESCAPES_FLAG = '--allow-escape-sequences';

/** A job's log, through `gh api`; with ESCAPES_FLAG, or without it for a gh too old to know it. */
export function ghLog(gh, logPath) {
  try {
    return ghText(gh, ['api', ESCAPES_FLAG, logPath]);
  } catch (error) {
    if (!error.message.includes(`unknown flag: ${ESCAPES_FLAG}`)) throw error;
    return ghText(gh, ['api', logPath]);
  }
}

/**
 * Fetches one run and its jobs (every page) and turns them into a report; with
 * `logs`, also each finished job's log, whose `trace:` lines go under their
 * steps. A log that cannot be read (expired, or the job has not finished) is a
 * warning, not a failure: the timings stand without it.
 */
export function loadRun(ref, { gh, now, logs = false, warn }) {
  const base = `repos/${ref.repository}/actions`;
  const [run] = ghJson(gh, ['api', `${base}/runs/${ref.runId}`]);
  const attempt = ref.attempt ?? run.run_attempt;
  const pages = ghJson(gh, ['api', '--paginate', `${base}/runs/${ref.runId}/attempts/${attempt}/jobs?per_page=100`]);
  const report = analyse({ ...run, repository: ref.repository, attempt }, pages.flatMap((page) => page.jobs), now);
  if (logs) {
    for (const job of report.jobs) {
      if (job.completed === null) {
        warn(`trace-run: no log for ${job.name} yet, so no phases for it: the job has not finished`);
        continue;
      }
      try {
        attachPhases(job, tracePhases(ghLog(gh, `${base}/jobs/${job.id}/logs`)));
      } catch (error) {
        if (!(error instanceof TraceError)) throw error;
        warn(`trace-run: no log for ${job.name}, so no phases for it: ${error.message.split('\n').at(-1)}`);
      }
    }
  }
  return report;
}

/**
 * The whole program, returning its exit code. `gh`, the clock, the file writer
 * and both output streams arrive through the second argument, so the tests run
 * every path in-process against recorded answers; the defaults are the real ones.
 */
export function main(
  argv,
  { gh = runGh, now = Date.now, writeFile = writeFileSync, stdout = process.stdout, stderr = process.stderr } = {},
) {
  if (answerHelp(argv, import.meta.url, (text) => stdout.write(`${text}\n`))) return 0;
  let options;
  try {
    options = parseArgs(argv);
  } catch (error) {
    if (!(error instanceof UsageError)) throw error;
    stderr.write(`trace-run: ${error.message}\n${USAGE}\n`);
    return 2;
  }
  const warn = (line) => stderr.write(`${line}\n`);
  try {
    const at = now();
    const report = loadRun(options.target, { gh, now: at, logs: options.logs, warn });
    const lines = renderReport(report, options);
    let comparison;
    if (options.compare) {
      const other = loadRun(options.compare, { gh, now: at, warn });
      comparison = compareReports(report, other);
      lines.push(...renderComparison(comparison, report, other, options.top));
    }
    stdout.write(`${lines.join('\n')}\n`);
    if (options.json) {
      writeFile(options.json, `${JSON.stringify(toJson(report, { top: options.top, comparison }), null, 2)}\n`);
      stdout.write(`\nwrote ${options.json}\n`);
    }
    return 0;
  } catch (error) {
    if (!(error instanceof TraceError)) throw error;
    stderr.write(`trace-run: ${error.message}\n`);
    return 1;
  }
}

// `exitCode`, not `process.exit()`: the process ends once stdout has drained.
if (isProgram(import.meta.url, process.argv[1])) process.exitCode = main(process.argv.slice(2));

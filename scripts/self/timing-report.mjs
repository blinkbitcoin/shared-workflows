#!/usr/bin/env node
// Say where a `make check` or `make test` run spent its time: each make target,
// the slowest tests and the suites that hold them.
//
//   timing-report.mjs [DIR]
//
// DIR is one run's timing directory, .timing/<run> - the TIMING_DIR the
// Makefile hands scripts/self/time-step.mjs. Without it, the last run under
// .timing/ by name: the Makefile names a run by its start time
// (20261007T190700), so that is the newest, and CI names its one run per job.
// `latest` is never a candidate.
//
// It reads DIR/targets.jsonl - one line per timed recipe line, written by
// time-step.mjs, summed per target - and every JUnit report under DIR: bats'
// report.xml and node's test-package.xml and test-scripts.xml. It prints the
// wall clock (first start to last end), each target with its duration, status
// and share of that, the 20 slowest tests with their suite, and the 20 suites
// that took longest, each with its test count and summed time. It writes all of
// it, every suite included, to DIR/timing.json, points .timing/latest (a
// symbolic link beside DIR) at DIR, and with GITHUB_STEP_SUMMARY set appends
// the same as markdown tables to the job's summary.
//
// Exit 1, naming the file, for no .timing directory, a run with nothing timed,
// a line of targets.jsonl that is not a record, or a JUnit report that cannot
// be read; 2 for more than one argument.
import {
  appendFileSync,
  existsSync,
  readFileSync,
  readdirSync,
  realpathSync,
  rmSync,
  symlinkSync,
  writeFileSync,
} from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

export const USAGE = 'usage: timing-report.mjs [DIR]';
export const TOP = 20;

/** A duration in milliseconds as a person reads it: `38 ms`, `4.2 s`, `3 min 7.0 s`. */
export function formatDuration(ms) {
  if (ms < 1000) return `${Math.round(ms)} ms`;
  const seconds = ms / 1000;
  if (seconds < 60) return `${seconds.toFixed(1)} s`;
  const minutes = Math.floor(seconds / 60);
  return `${minutes} min ${(seconds - minutes * 60).toFixed(1)} s`;
}

/** A share of the wall clock as a whole percentage. */
export function formatShare(share) {
  return `${Math.round(share * 100)}%`;
}

/** How a target's exit status reads in the report. */
export function formatStatus(status) {
  return status === 0 ? 'ok' : `failed (exit ${status})`;
}

/**
 * The records of a targets.jsonl, in file order. Blank lines are skipped;
 * anything else that is not a record throws, naming `file` and the line.
 */
export function parseTargets(text, file) {
  const records = [];
  text.split('\n').forEach((line, index) => {
    if (!line.trim()) return;
    const where = `${file} line ${index + 1}`;
    let record;
    try {
      record = JSON.parse(line);
    } catch (error) {
      throw new Error(`${where} is not JSON: ${error.message}`);
    }
    const valid =
      record !== null &&
      typeof record === 'object' &&
      typeof record.target === 'string' &&
      record.target !== '' &&
      Number.isFinite(record.start) &&
      Number.isFinite(record.end) &&
      record.end >= record.start &&
      Number.isInteger(record.status);
    if (!valid) {
      throw new Error(`${where} is not a timing record (target, start <= end in epoch milliseconds, integer status): ${line}`);
    }
    records.push(record);
  });
  return records;
}

const ENTITIES = { lt: '<', gt: '>', quot: '"', apos: "'", amp: '&' };

/** XML character references and the five named entities, decoded once. */
export function decodeXml(text) {
  return text.replace(/&(#x[0-9a-fA-F]+|#[0-9]+|[a-z]+);/g, (whole, name) => {
    if (name.startsWith('#x')) return String.fromCodePoint(Number.parseInt(name.slice(2), 16));
    if (name.startsWith('#')) return String.fromCodePoint(Number.parseInt(name.slice(1), 10));
    return ENTITIES[name] ?? whole;
  });
}

const TESTCASE = /<testcase((?:\s+[\w:.-]+="[^"]*")*)\s*\/?>/y;
const ATTRIBUTE = /([\w:.-]+)="([^"]*)"/g;

/** Line number (1-based) of offset `at` in `text`. */
function lineOf(text, at) {
  return text.slice(0, at).split('\n').length;
}

/**
 * The test cases of one JUnit report: `{ name, suite, ms }` each. The suite is
 * the case's `file` attribute relative to `cwd` (node's reporter) or else its
 * `classname` (bats names the file there). A regular expression rather than an
 * XML parser: both reporters write one flat element per case, and this
 * repository installs no dependency for a report. Throws, naming `file`, on a
 * report with no testsuite element or a case it cannot read.
 */
export function parseJunit(text, file, cwd) {
  if (!/<testsuites?[\s>]/.test(text)) {
    throw new Error(`${file} is not a JUnit report: it has no <testsuites> or <testsuite> element`);
  }
  const cases = [];
  for (const found of text.matchAll(/<testcase[\s/>]/g)) {
    TESTCASE.lastIndex = found.index;
    const element = TESTCASE.exec(text);
    const where = `${file} line ${lineOf(text, found.index)}`;
    if (!element) throw new Error(`${where}: a <testcase> element that cannot be read`);
    const attributes = {};
    for (const [, key, value] of element[1].matchAll(ATTRIBUTE)) attributes[key] = decodeXml(value);
    const seconds = Number(attributes.time);
    if (!attributes.name || attributes.time === undefined || attributes.time === '' || !(seconds >= 0)) {
      throw new Error(`${where}: a <testcase> without a name or a numeric time`);
    }
    const suite = attributes.file ? path.relative(cwd, attributes.file) : (attributes.classname ?? '');
    cases.push({ name: attributes.name, suite, ms: Math.round(seconds * 1000) });
  }
  return cases;
}

/**
 * Everything the report says, from the step records and the test cases: the
 * wall clock, the targets in the order they started, the slowest tests and
 * every suite, longest first.
 */
export function summarise(records, cases) {
  const start = Math.min(...records.map((record) => record.start));
  const end = Math.max(...records.map((record) => record.end));
  const wall = end - start;

  const targets = new Map();
  for (const record of [...records].sort((a, b) => a.start - b.start)) {
    const entry = targets.get(record.target) ?? { target: record.target, ms: 0, steps: 0, status: 0 };
    entry.ms += record.end - record.start;
    entry.steps += 1;
    if (entry.status === 0) entry.status = record.status;
    targets.set(record.target, entry);
  }
  for (const entry of targets.values()) entry.share = wall > 0 ? entry.ms / wall : 0;

  const suites = new Map();
  for (const test of cases) {
    const entry = suites.get(test.suite) ?? { suite: test.suite, tests: 0, ms: 0 };
    entry.tests += 1;
    entry.ms += test.ms;
    suites.set(test.suite, entry);
  }

  const byTime = (a, b) => b.ms - a.ms;
  return {
    wall: { start, end, ms: wall },
    targets: [...targets.values()],
    tests: cases.length,
    slowest: [...cases].sort(byTime).slice(0, TOP),
    suites: [...suites.values()].sort(byTime),
  };
}

/** The report as plain text, for a terminal or a CI log. */
export function formatText(summary, label) {
  const lines = [`Timing of ${label}: ${formatDuration(summary.wall.ms)} wall clock`, '', 'Targets'];
  const width = Math.max(...summary.targets.map((entry) => entry.target.length));
  for (const entry of summary.targets) {
    lines.push(
      `  ${entry.target.padEnd(width)}  ${formatDuration(entry.ms).padStart(14)}  ${formatShare(entry.share).padStart(4)}  ${formatStatus(entry.status)}`,
    );
  }
  if (summary.tests === 0) {
    lines.push('', 'No JUnit report in this run, so no test timings.');
    return `${lines.join('\n')}\n`;
  }
  lines.push('', `Slowest tests (${summary.slowest.length} of ${summary.tests})`);
  for (const test of summary.slowest) {
    lines.push(`  ${formatDuration(test.ms).padStart(14)}  ${test.suite}  ${test.name}`);
  }
  const suites = summary.suites.slice(0, TOP);
  lines.push('', `Slowest suites (${suites.length} of ${summary.suites.length}; every suite is in timing.json)`);
  for (const suite of suites) {
    lines.push(`  ${formatDuration(suite.ms).padStart(14)}  ${String(suite.tests).padStart(4)} tests  ${suite.suite}`);
  }
  return `${lines.join('\n')}\n`;
}

/** A table cell: pipes escaped, line breaks flattened. */
function cell(text) {
  return String(text).replace(/\|/g, '\\|').replace(/\n/g, ' ');
}

/** The report as markdown tables, for a GitHub job summary. */
export function formatMarkdown(summary, label) {
  const lines = [
    `### Timing of ${cell(label)}`,
    '',
    `${formatDuration(summary.wall.ms)} wall clock.`,
    '',
    '| Target | Duration | Share | Status |',
    '|---|---:|---:|---|',
  ];
  for (const entry of summary.targets) {
    lines.push(`| ${cell(entry.target)} | ${formatDuration(entry.ms)} | ${formatShare(entry.share)} | ${formatStatus(entry.status)} |`);
  }
  if (summary.tests > 0) {
    lines.push('', `Slowest tests (${summary.slowest.length} of ${summary.tests}):`, '', '| Duration | Suite | Test |', '|---:|---|---|');
    for (const test of summary.slowest) {
      lines.push(`| ${formatDuration(test.ms)} | ${cell(test.suite)} | ${cell(test.name)} |`);
    }
    const suites = summary.suites.slice(0, TOP);
    lines.push('', `Slowest suites (${suites.length} of ${summary.suites.length}):`, '', '| Duration | Tests | Suite |', '|---:|---:|---|');
    for (const suite of suites) {
      lines.push(`| ${formatDuration(suite.ms)} | ${suite.tests} | ${cell(suite.suite)} |`);
    }
  }
  return `${lines.join('\n')}\n\n`;
}

/**
 * The newest run under `root` (.timing): the last directory by name, `latest`
 * left out. Throws when `root` does not exist or holds no run.
 */
export function newestRun(root) {
  if (!existsSync(root)) {
    throw new Error(`no ${root} directory: run make check or make test first, which time themselves into it`);
  }
  const runs = readdirSync(root, { withFileTypes: true })
    .filter((entry) => entry.isDirectory() && entry.name !== 'latest')
    .map((entry) => entry.name)
    .sort();
  if (runs.length === 0) throw new Error(`no run under ${root}: run make check or make test first`);
  return path.join(root, runs.at(-1));
}

/** Every *.xml file under `dir`, at any depth, in name order. */
export function junitFiles(dir) {
  return readdirSync(dir, { recursive: true, withFileTypes: true })
    .filter((entry) => entry.isFile() && entry.name.endsWith('.xml'))
    .map((entry) => path.join(entry.parentPath, entry.name))
    .sort();
}

/**
 * The whole program, returning its exit code. The working directory, the
 * environment and the output streams arrive through the second argument, so
 * the tests run every path of it in-process; the defaults are the real ones.
 */
export function main(argv, { cwd = process.cwd(), env = process.env, stdout = process.stdout, stderr = process.stderr } = {}) {
  if (argv.length > 1) {
    stderr.write(`::error::${USAGE}\n`);
    return 2;
  }
  try {
    const here = realpathSync(cwd);
    const given = argv[0] ? path.resolve(here, argv[0]) : newestRun(path.join(here, '.timing'));
    if (!existsSync(given)) throw new Error(`no run directory ${given}`);
    const dir = realpathSync(given);
    const label = path.relative(here, dir) || '.';

    const targetsFile = path.join(dir, 'targets.jsonl');
    if (!existsSync(targetsFile)) throw new Error(`${targetsFile} does not exist: nothing in this run was timed`);
    const records = parseTargets(readFileSync(targetsFile, 'utf8'), targetsFile);
    if (records.length === 0) throw new Error(`${targetsFile} is empty: nothing in this run was timed`);
    const cases = junitFiles(dir).flatMap((file) => parseJunit(readFileSync(file, 'utf8'), file, here));

    const summary = summarise(records, cases);
    writeFileSync(path.join(dir, 'timing.json'), `${JSON.stringify({ run: label, ...summary }, null, 2)}\n`);
    const latest = path.join(path.dirname(dir), 'latest');
    rmSync(latest, { force: true });
    symlinkSync(path.basename(dir), latest);
    stdout.write(formatText(summary, label));
    if (env.GITHUB_STEP_SUMMARY) appendFileSync(env.GITHUB_STEP_SUMMARY, formatMarkdown(summary, label));
  } catch (error) {
    stderr.write(`::error::timing-report: ${error.message}\n`);
    return 1;
  }
  return 0;
}

// Run as a program rather than imported - the same guard as artifact-hashes.mjs.
if (process.argv[1] && fileURLToPath(import.meta.url) === realpathSync(path.resolve(process.argv[1]))) {
  process.exitCode = main(process.argv.slice(2));
}

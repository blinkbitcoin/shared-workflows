// Where a GitHub Actions run spent its time, from what the REST API says about
// it: the arguments `trace-run` takes, the jobs and steps turned into
// durations, the critical path, the `trace:` phase lines of the job logs, and
// the text and JSON the program prints. Everything here is pure; the program in
// bin/trace-run.mjs fetches through `gh` and hands the answers in.

/** An argument the program cannot use: it prints the usage and exits 2. */
export class UsageError extends Error {}

/** A fetch that failed or answered something unreadable: the program exits 1. */
export class TraceError extends Error {}

export const USAGE =
  'usage: trace-run <run URL | owner/repository run-id> [--attempt N] [--logs] [--top N] [--sort end|run] ' +
  '[--json FILE] [--compare <run URL | run-id | owner/repository run-id>]';

/** How many steps the slowest-steps table, and rows the comparison, show unless `--top` says. */
export const TOP_DEFAULT = 15;

/** The orders the jobs table takes: when each job finished, or its run time, longest first. */
export const SORTS = ['end', 'run'];

const RUN_URL =
  /^https:\/\/github\.com\/([\w.-]+)\/([\w.-]+)\/actions\/runs\/(\d+)(?:\/attempts\/(\d+))?(?:[/?#].*)?$/;
const REPOSITORY = /^[\w.-]+\/[\w.-]+$/;
const RUN_ID = /^\d+$/;

/** A run's URL as `{ repository, runId, attempt }`, the attempt only when the URL names one; null otherwise. */
export function parseRunUrl(text) {
  const match = RUN_URL.exec(text);
  if (!match) return null;
  const ref = { repository: `${match[1]}/${match[2]}`, runId: match[3] };
  if (match[4]) ref.attempt = Number(match[4]);
  return ref;
}

/**
 * The run the words name: a run URL, `owner/repository run-id`, or - when
 * `repository` is given, for `--compare` - a bare run id in that repository.
 */
export function runRef(words, repository) {
  if (words.length === 1) {
    const ref = parseRunUrl(words[0]);
    if (ref) return ref;
    if (repository && RUN_ID.test(words[0])) return { repository, runId: words[0] };
  } else if (words.length === 2 && REPOSITORY.test(words[0]) && RUN_ID.test(words[1])) {
    return { repository: words[0], runId: words[1] };
  }
  throw new UsageError(`not a run: ${words.join(' ')} (give a run URL, or owner/repository and a run id)`);
}

function positiveInteger(flag, value) {
  if (!/^[1-9]\d*$/.test(value)) throw new UsageError(`${flag} takes a whole number from 1, got "${value}"`);
  return Number(value);
}

/** The command line as `{ target, compare, attempt, logs, top, sort, json }`; a UsageError when it does not parse. */
export function parseArgs(argv) {
  const options = { logs: false, top: TOP_DEFAULT, sort: 'end' };
  const positional = [];
  let compareWords;
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    if (arg === '--logs') {
      options.logs = true;
      continue;
    }
    if (!['--attempt', '--top', '--sort', '--json', '--compare'].includes(arg)) {
      if (arg.startsWith('-')) throw new UsageError(`unknown option ${arg}`);
      positional.push(arg);
      continue;
    }
    const value = argv[++i];
    if (value === undefined) throw new UsageError(`${arg} needs a value`);
    if (arg === '--attempt') options.attempt = positiveInteger(arg, value);
    else if (arg === '--top') options.top = positiveInteger(arg, value);
    else if (arg === '--json') options.json = value;
    else if (arg === '--sort') {
      if (!SORTS.includes(value)) throw new UsageError(`--sort takes ${SORTS.join(' or ')}, got "${value}"`);
      options.sort = value;
    } else if (REPOSITORY.test(value) && RUN_ID.test(argv[i + 1] ?? '')) {
      compareWords = [value, argv[++i]];
    } else {
      compareWords = [value];
    }
  }
  if (positional.length === 0) throw new UsageError('name a run: its URL, or owner/repository and a run id');
  const target = runRef(positional);
  if (options.attempt !== undefined) target.attempt = options.attempt;
  const compare = compareWords ? runRef(compareWords, target.repository) : undefined;
  return { ...options, target, compare };
}

/**
 * Every JSON value in `text`, in order. `gh api --paginate` prints one value
 * per page with nothing between them (`{...}{...}`), which no single
 * `JSON.parse` reads; `--slurp` would wrap them in an array, but only from gh
 * 2.48, and the reader's gh is whatever they installed.
 */
export function parseJsonStream(text) {
  const values = [];
  let depth = 0;
  let start = 0;
  let inString = false;
  let escaped = false;
  for (let i = 0; i < text.length; i++) {
    const char = text[i];
    if (inString) {
      if (escaped) escaped = false;
      else if (char === '\\') escaped = true;
      else if (char === '"') inString = false;
    } else if (char === '"') {
      inString = true;
    } else if (char === '{' || char === '[') {
      if (depth === 0) start = i;
      depth++;
    } else if (char === '}' || char === ']') {
      depth--;
      if (depth === 0) values.push(parseValue(text.slice(start, i + 1)));
    }
  }
  if (depth !== 0 || inString) throw new TraceError('gh answered JSON that stops part-way through a value');
  return values;
}

function parseValue(text) {
  try {
    return JSON.parse(text);
  } catch (error) {
    throw new TraceError(`gh answered something that is not JSON: ${error.message}`);
  }
}

/** Names made unique in order: the second `build` is `build [2]`, so matrix jobs and repeated steps keep their own rows. */
export function uniqueNames(names) {
  const seen = new Map();
  return names.map((name) => {
    const count = (seen.get(name) ?? 0) + 1;
    seen.set(name, count);
    return count === 1 ? name : `${name} [${count}]`;
  });
}

const time = (iso) => (iso ? Date.parse(iso) : null);
const seconds = (from, to) => Math.max(0, (to - from) / 1000);
const state = (item) => item.conclusion ?? (item.started_at ? 'running' : 'queued');

/** The latest-ending of `jobs`, or undefined when there are none. */
const lastToEnd = (jobs) => jobs.reduce((latest, job) => (latest === undefined || job.end > latest.end ? job : latest), undefined);

/**
 * The chain of jobs that decided when the run finished: the job that ended
 * last, then the job that ended last before it started, and so on back. It is
 * read from the timestamps alone; the workflow file and its `needs:` are not.
 */
export function criticalPath(jobs) {
  const ran = jobs.filter((job) => job.started !== null);
  const path = [];
  let current = lastToEnd(ran);
  while (current) {
    path.unshift(current);
    const { started } = current;
    current = lastToEnd(ran.filter((job) => !path.includes(job) && job.end <= started));
  }
  return path;
}

/**
 * The run as durations: each job's queue time (created to started) and run time
 * (started to completed), each step's time, the wall clock (first job created
 * to last job finished) and the critical path. A job or step still going is
 * measured up to `now`, in milliseconds since the epoch.
 */
export function analyse(run, rawJobs, now) {
  const jobNames = uniqueNames(rawJobs.map((job) => job.name));
  const jobs = rawJobs.map((job, index) => {
    const created = time(job.created_at);
    const started = time(job.started_at);
    const completed = time(job.completed_at);
    const end = started === null ? null : (completed ?? now);
    const stepNames = uniqueNames((job.steps ?? []).map((step) => step.name));
    return {
      id: job.id,
      name: jobNames[index],
      conclusion: state(job),
      runner: job.runner_name || (job.labels ?? []).join(', ') || null,
      created,
      started,
      completed,
      end,
      queue_s: seconds(created, started ?? now),
      run_s: started === null ? null : seconds(started, end),
      phases: [],
      steps: (job.steps ?? []).map((step, number) => {
        const stepStarted = time(step.started_at);
        return {
          name: stepNames[number],
          conclusion: state(step),
          started: stepStarted,
          s: stepStarted === null ? null : seconds(stepStarted, time(step.completed_at) ?? now),
          phases: [],
        };
      }),
    };
  });
  const running = jobs.some((job) => job.completed === null);
  const start = jobs.length === 0 ? null : Math.min(...jobs.map((job) => job.created));
  const finish = running ? now : Math.max(...jobs.map((job) => job.completed));
  return {
    run: {
      id: run.id,
      name: run.name,
      repository: run.repository,
      attempt: run.attempt,
      url: run.html_url,
      sha: run.head_sha,
      workflow: run.path,
    },
    start,
    running,
    wall_s: start === null ? null : seconds(start, finish),
    jobs,
    critical_path: criticalPath(jobs),
  };
}

const LOG_LINE = /^\uFEFF?(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(?:\.\d+)?Z) (.*)$/;
const TRACE_LINE = /^trace: (.+) ([0-9]+(\.[0-9])?)s$/;
// Colour codes (ESC [ ... letter) first, then any other control character, so
// nothing a log carries reaches the reader's terminal.
const ESCAPE_SEQUENCE = /\u001b\[[0-9;?]*[ -/]*[@-~]/g;
const CONTROL = /[\u0000-\u001f\u007f]/g;

/**
 * The `trace: <phase> <seconds>s` lines of a job log, each with the time it was
 * written. A log line is an ISO timestamp, a space, then the text; the line is
 * what our scripts print as they close a log group.
 */
export function tracePhases(log) {
  const phases = [];
  for (const line of log.split('\n')) {
    const stamped = LOG_LINE.exec(line.replace(ESCAPE_SEQUENCE, '').replace(CONTROL, ''));
    const trace = stamped && TRACE_LINE.exec(stamped[2]);
    if (trace) phases.push({ at: Date.parse(stamped[1]), name: trace[1], s: Number(trace[2]) });
  }
  return phases;
}

/**
 * Files each phase under the step that was running when its line was written:
 * the last step to start at or before it (the API keeps whole seconds, so a
 * step's start is its second). A phase before every step stays on the job.
 */
export function attachPhases(job, phases) {
  for (const { at, name, s } of phases) {
    const step = job.steps.filter((candidate) => candidate.started !== null && candidate.started <= at).at(-1);
    (step ?? job).phases.push({ name, s });
  }
  return job;
}

/** Every step that started, slowest first, with its job; the first `top` of them. */
export function slowestSteps(report, top) {
  const steps = report.jobs.flatMap((job) =>
    job.steps.filter((step) => step.s !== null).map((step) => ({ job: job.name, step: step.name, s: step.s, conclusion: step.conclusion })),
  );
  return steps.sort((a, b) => b.s - a.s).slice(0, top);
}

/** A duration for a reader: 0.9s, 42s, 4m 12s, 1h 02m; `-` when there is none. */
export function formatDuration(s) {
  if (s === null) return '-';
  const tenths = Math.round(s * 10) / 10;
  if (tenths < 60) return `${tenths}s`;
  const whole = Math.round(s);
  if (whole < 3600) return `${Math.floor(whole / 60)}m ${String(whole % 60).padStart(2, '0')}s`;
  return `${Math.floor(whole / 3600)}h ${String(Math.floor((whole % 3600) / 60)).padStart(2, '0')}m`;
}

/** A change in duration, signed: +1m 02s, -30s, 0s; `-` when either side is missing. */
export function formatChange(s) {
  if (s === null) return '-';
  const sign = s > 0 ? '+' : s < 0 ? '-' : '';
  return `${sign}${formatDuration(Math.abs(s))}`;
}

/** Rows as aligned text lines, two spaces in, `align` one `l` or `r` per column. */
export function table(headers, rows, align) {
  const widths = headers.map((header, column) => Math.max(header.length, ...rows.map((row) => row[column].length)));
  const line = (cells) =>
    `  ${cells.map((cell, column) => (align[column] === 'r' ? cell.padStart(widths[column]) : cell.padEnd(widths[column]))).join('  ')}`.trimEnd();
  return [line(headers), ...rows.map(line)];
}

const at = (report, ms) => (ms === null ? '-' : `+${formatDuration(seconds(report.start, ms))}`);
const LAST = Number.MAX_SAFE_INTEGER;

function sortedJobs(jobs, sort) {
  // A job that has not started has neither: it goes last either way.
  const key = sort === 'run' ? (job) => -(job.run_s ?? -1) : (job) => job.end ?? LAST;
  return [...jobs].sort((a, b) => key(a) - key(b));
}

/** The text report: the run, its jobs, the slowest steps, the critical path and, with `logs`, the phases. */
export function renderReport(report, { top = TOP_DEFAULT, sort = 'end', logs = false } = {}) {
  const { run } = report;
  const lines = [
    `${run.name} #${run.id}, attempt ${run.attempt}, ${run.repository}`,
    run.url,
    `commit ${run.sha.slice(0, 7)}, ${run.workflow}`,
    `wall clock ${formatDuration(report.wall_s)}, from the first job created to the last job finished` +
      (report.running ? ' (still running: measured up to now)' : ''),
    '',
    sort === 'run' ? 'Jobs, longest run first' : 'Jobs, in the order they finished',
    ...table(
      ['Job', 'Queue', 'Run', 'Ends at', 'Result', 'Runner'],
      sortedJobs(report.jobs, sort).map((job) => [
        job.name,
        formatDuration(job.queue_s),
        formatDuration(job.run_s),
        at(report, job.end),
        job.conclusion,
        job.runner ?? '-',
      ]),
      'lrrrll',
    ),
    '',
    `Slowest steps (top ${top})`,
    ...table(
      ['Job / step', 'Time', 'Result'],
      slowestSteps(report, top).map((step) => [`${step.job} / ${step.step}`, formatDuration(step.s), step.conclusion]),
      'lrl',
    ),
    '',
    'Critical path: each job follows the job that finished last before it started',
    '(read from the timestamps; the workflow file and its needs: are not read)',
    ...table(
      ['Job', 'Queue', 'Run', 'Ends at'],
      report.critical_path.map((job) => [job.name, formatDuration(job.queue_s), formatDuration(job.run_s), at(report, job.end)]),
      'lrrr',
    ),
  ];
  if (logs) lines.push('', 'Phases, from the trace: lines in the job logs', ...renderPhases(report));
  return lines;
}

function renderPhases(report) {
  const lines = [];
  for (const job of report.jobs) {
    const owners = [{ title: `${job.name} (before its first step)`, phases: job.phases }].concat(
      job.steps.map((step) => ({ title: `${job.name} / ${step.name}`, phases: step.phases })),
    );
    for (const { title, phases } of owners.filter((owner) => owner.phases.length > 0)) {
      lines.push(`  ${title}`, ...table(['Phase', 'Time'], phases.map((phase) => [phase.name, formatDuration(phase.s)]), 'lr').slice(1).map((line) => `  ${line}`));
    }
  }
  return lines.length > 0 ? lines : ['  none: no job log has a trace: line'];
}

function durations(report) {
  const map = new Map([['wall clock', report.wall_s]]);
  for (const job of report.jobs) {
    map.set(job.name, job.run_s);
    for (const step of job.steps) map.set(`${job.name} / ${step.name}`, step.s);
  }
  return map;
}

/**
 * The two runs side by side: the wall clock, each job's run time by job name
 * and each step's time by job and step name, with the change from `other` to
 * `report`, the largest increase first and the rows one run lacks last.
 */
export function compareReports(report, other) {
  const mine = durations(report);
  const theirs = durations(other);
  const rows = [...new Set([...mine.keys(), ...theirs.keys()])].map((name) => {
    const this_s = mine.get(name) ?? null;
    const other_s = theirs.get(name) ?? null;
    return { name, this_s, other_s, change_s: this_s === null || other_s === null ? null : this_s - other_s };
  });
  const rank = (row) => row.change_s ?? -Number.MAX_VALUE;
  return rows.sort((a, b) => rank(b) - rank(a));
}

/** The comparison as text, its first `top` rows. */
export function renderComparison(rows, report, other, top = TOP_DEFAULT) {
  return [
    '',
    `Compared with run #${other.run.id} (${other.run.url}), largest increase first (top ${top})`,
    ...table(
      ['Job / step', `#${report.run.id}`, `#${other.run.id}`, 'Change'],
      rows.slice(0, top).map((row) => [row.name, formatDuration(row.this_s), formatDuration(row.other_s), formatChange(row.change_s)]),
      'lrrr',
    ),
  ];
}

const iso = (ms) => (ms === null ? null : new Date(ms).toISOString());

/** The whole tree as one JSON-ready object, for `--json`. */
export function toJson(report, { top = TOP_DEFAULT, comparison } = {}) {
  const tree = {
    run: { ...report.run, wall_s: report.wall_s, running: report.running },
    jobs: report.jobs.map((job) => ({
      name: job.name,
      queue_s: job.queue_s,
      run_s: job.run_s,
      conclusion: job.conclusion,
      runner: job.runner,
      started_at: iso(job.started),
      completed_at: iso(job.completed),
      phases: job.phases,
      steps: job.steps.map((step) => ({ name: step.name, s: step.s, conclusion: step.conclusion, phases: step.phases })),
    })),
    critical_path: report.critical_path.map((job) => ({ name: job.name, queue_s: job.queue_s, run_s: job.run_s })),
    slowest: slowestSteps(report, top),
  };
  if (comparison) tree.comparison = comparison;
  return tree;
}

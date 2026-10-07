import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { chmodSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { after, test } from 'node:test';
import { fileURLToPath } from 'node:url';
import { ESCAPES_FLAG, ghJson, ghLog, ghText, loadRun, main, runGh } from './bin/trace-run.mjs';
import {
  analyse,
  attachPhases,
  compareReports,
  criticalPath,
  formatChange,
  formatDuration,
  parseArgs,
  parseJsonStream,
  parseRunUrl,
  renderReport,
  runRef,
  slowestSteps,
  table,
  toJson,
  TraceError,
  tracePhases,
  uniqueNames,
  USAGE,
  UsageError,
} from './lib/trace-run.mjs';

const BIN = fileURLToPath(new URL('./bin/trace-run.mjs', import.meta.url));
const work = mkdtempSync(path.join(tmpdir(), 'trace-run-'));
after(() => rmSync(work, { recursive: true, force: true }));

// Recorded answers of the GitHub REST API, cut to the fields trace-run reads.
const T = (clock) => `2026-10-01T${clock}Z`;
const step = (name, from, to, conclusion = 'success') => ({
  name,
  status: 'completed',
  conclusion,
  started_at: T(from),
  completed_at: T(to),
});
const RUN = {
  id: 1001,
  name: 'CI',
  run_attempt: 2,
  head_sha: '0123456789abcdef0123456789abcdef01234567',
  path: '.github/workflows/ci.yml',
  html_url: 'https://github.com/blinkbitcoin/app/actions/runs/1001',
};
// Page one: two Linux jobs. Page two: a macOS job queued twenty minutes whose
// build step failed, an E2E job that waited for the Android build, and the
// report job that waited for everything. A step name holds braces and an
// escaped quote, the characters a page splitter could trip on.
const PAGE_ONE = {
  total_count: 5,
  jobs: [
    {
      id: 1,
      name: 'Lint',
      conclusion: 'success',
      created_at: T('10:00:00'),
      started_at: T('10:00:05'),
      completed_at: T('10:02:05'),
      runner_name: 'GitHub Actions 2',
      labels: ['ubuntu-latest'],
      steps: [step('Set up job', '10:00:05', '10:00:07'), step('Run lint {all} "fast"', '10:00:07', '10:02:00'), step('Complete job', '10:02:00', '10:02:05')],
    },
    {
      id: 2,
      name: 'Build Android',
      conclusion: 'success',
      created_at: T('10:00:00'),
      started_at: T('10:00:10'),
      completed_at: T('10:12:10'),
      runner_name: '',
      labels: ['ubuntu-latest'],
      steps: [step('Set up job', '10:00:10', '10:00:12'), step('Build', '10:00:12', '10:12:00'), step('Complete job', '10:12:00', '10:12:10')],
    },
  ],
};
const PAGE_TWO = {
  total_count: 5,
  jobs: [
    {
      id: 3,
      name: 'Build iOS',
      conclusion: 'failure',
      created_at: T('10:00:00'),
      started_at: T('10:20:00'),
      completed_at: T('10:35:00'),
      runner_name: null,
      labels: ['macos-15'],
      steps: [step('Set up job', '10:20:00', '10:20:02'), step('Build', '10:20:02', '10:34:00', 'failure'), step('Upload', '10:34:00', '10:34:00', 'skipped')],
    },
    {
      id: 4,
      name: 'E2E Android',
      conclusion: 'success',
      created_at: T('10:12:15'),
      started_at: T('10:12:20'),
      completed_at: T('10:30:00'),
      steps: [step('Run Maestro', '10:12:20', '10:30:00')],
    },
    {
      id: 5,
      name: 'Report',
      conclusion: 'success',
      created_at: T('10:35:05'),
      started_at: T('10:35:10'),
      completed_at: T('10:36:10'),
      labels: [],
      steps: [step('Report', '10:35:10', '10:36:10')],
    },
  ],
};
// gh --paginate prints each page as it comes, with nothing between them.
const PAGES = `${JSON.stringify(PAGE_ONE, null, 2)}${JSON.stringify(PAGE_TWO)}\n`;
const LOGS = {
  1: `﻿${T('10:00:04.5000000')} trace: restore cache 0.5s\r\n${T('10:00:30.0000000')} trace: biome 12s\r\n`,
  2: `${T('10:00:12.1000000')} ##[group]Run build\n${T('10:11:59.9000000')} trace: gradle assemble 700.3s\n`,
  4: [
    `${T('10:12:20.1000000')} ##[group]Run Maestro`,
    `${T('10:13:00.5000000')} \u001b[36mtrace: boot emulator 40.2s\u001b[0m`,
    `${T('10:29:59.9000000')} trace: run flows 1019s`,
    `${T('10:29:59.9100000')} trace: not a phase 12.34s`,
    'trace: no timestamp 1s',
    '',
  ].join('\n'),
  5: `${T('10:35:11.0000000')} nothing traced here\n`,
};
const NOW = Date.parse(T('11:00:00'));

/** A fake gh answering from `answers` by its arguments, recording each call. */
function fakeGh(answers) {
  const calls = [];
  const gh = (args) => {
    calls.push(args.join(' '));
    const answer = answers[args.join(' ')];
    if (answer === undefined) return { status: 1, stdout: '', stderr: `gh: Not Found (HTTP 404)\n` };
    return typeof answer === 'function' ? answer() : { status: 0, stdout: answer, stderr: '' };
  };
  return { gh, calls };
}

const RUN_PATH = 'api repos/blinkbitcoin/app/actions/runs/1001';
const JOBS_PATH = 'api --paginate repos/blinkbitcoin/app/actions/runs/1001/attempts/2/jobs?per_page=100';
const logPath = (id) => `api --allow-escape-sequences repos/blinkbitcoin/app/actions/jobs/${id}/logs`;
const ANSWERS = {
  [RUN_PATH]: JSON.stringify(RUN),
  [JOBS_PATH]: PAGES,
  [logPath(1)]: LOGS[1],
  [logPath(2)]: LOGS[2],
  [logPath(4)]: LOGS[4],
  [logPath(5)]: LOGS[5],
};

// The run before it: the same jobs, faster, and one job this run no longer has.
const OTHER_RUN = { ...RUN, id: 1000, run_attempt: 1, html_url: 'https://github.com/blinkbitcoin/app/actions/runs/1000' };
const OTHER_JOBS = {
  jobs: [
    { ...PAGE_ONE.jobs[1], completed_at: T('10:08:10'), steps: [step('Build', '10:00:12', '10:08:00')] },
    { ...PAGE_TWO.jobs[0], started_at: T('10:01:00'), completed_at: T('10:14:00'), conclusion: 'success', steps: [step('Build', '10:01:02', '10:13:00')] },
    { ...PAGE_TWO.jobs[2], name: 'Old job', created_at: T('10:14:00'), started_at: T('10:14:05'), completed_at: T('10:15:00'), steps: [] },
  ],
};
const COMPARE_ANSWERS = {
  ...ANSWERS,
  'api repos/blinkbitcoin/app/actions/runs/1000': JSON.stringify(OTHER_RUN),
  'api --paginate repos/blinkbitcoin/app/actions/runs/1000/attempts/1/jobs?per_page=100': JSON.stringify(OTHER_JOBS),
};

/** main with a fake gh, a fixed clock and captured output. */
function run(argv, answers = ANSWERS) {
  const out = [];
  const err = [];
  const written = {};
  const { gh, calls } = fakeGh(answers);
  const code = main(argv, {
    gh,
    now: () => NOW,
    writeFile: (file, text) => {
      written[file] = text;
    },
    stdout: { write: (text) => out.push(text) },
    stderr: { write: (text) => err.push(text) },
  });
  return { code, out: out.join(''), err: err.join(''), written, calls };
}

test('a run URL names the repository and run, and the attempt only when it says one', () => {
  assert.deepEqual(parseRunUrl('https://github.com/blinkbitcoin/app/actions/runs/1001'), { repository: 'blinkbitcoin/app', runId: '1001' });
  assert.deepEqual(parseRunUrl('https://github.com/o/r.js/actions/runs/7/attempts/3'), { repository: 'o/r.js', runId: '7', attempt: 3 });
  assert.deepEqual(parseRunUrl('https://github.com/o/r/actions/runs/7/job/99?pr=1'), { repository: 'o/r', runId: '7' });
  for (const bad of ['https://github.com/o/r/pull/7', 'http://github.com/o/r/actions/runs/7', 'https://github.com/o/r/actions/runs/x', 'o/r 7']) {
    assert.equal(parseRunUrl(bad), null, bad);
  }
});

test('a run is a URL or owner/repository and a run id; a bare id only beside a repository', () => {
  assert.deepEqual(runRef(['o/r', '7']), { repository: 'o/r', runId: '7' });
  assert.deepEqual(runRef(['7'], 'o/r'), { repository: 'o/r', runId: '7' });
  assert.deepEqual(runRef(['https://github.com/a/b/actions/runs/8'], 'o/r'), { repository: 'a/b', runId: '8' });
  for (const words of [['7'], ['o/r', 'x'], ['o', '7'], ['a', 'b', 'c'], ['x'], ['nope'], ['o/r', '7', '8']]) {
    assert.throws(() => runRef(words, words[0] === 'nope' ? 'o/r' : undefined), (e) => e instanceof UsageError && /^not a run: /.test(e.message), words.join(' '));
  }
});

test('the options parse, with their defaults', () => {
  assert.deepEqual(parseArgs(['o/r', '7']), { logs: false, top: 15, sort: 'end', target: { repository: 'o/r', runId: '7' }, compare: undefined });
  const all = parseArgs(['https://github.com/o/r/actions/runs/7/attempts/2', '--attempt', '3', '--logs', '--top', '5', '--sort', 'run', '--json', 'out.json', '--compare', '6']);
  assert.deepEqual(all, {
    logs: true,
    top: 5,
    sort: 'run',
    attempt: 3,
    json: 'out.json',
    target: { repository: 'o/r', runId: '7', attempt: 3 },
    compare: { repository: 'o/r', runId: '6' },
  });
  assert.deepEqual(parseArgs(['o/r', '7', '--compare', 'a/b', '9']).compare, { repository: 'a/b', runId: '9' });
  assert.deepEqual(parseArgs(['--compare', 'https://github.com/a/b/actions/runs/9', 'o/r', '7']).compare, { repository: 'a/b', runId: '9' });
  // owner/repository with no run id after it is not taken as two words.
  assert.throws(() => parseArgs(['o/r', '7', '--compare', 'a/b']), /not a run: a\/b/);
});

test('every malformed command line is a usage error naming what is wrong', () => {
  const cases = [
    [[], /name a run/],
    [['o/r', '7', '--nope'], /unknown option --nope/],
    [['o/r', '7', '-x'], /unknown option -x/],
    [['o/r', '7', '--top'], /--top needs a value/],
    [['o/r', '7', '--attempt', '0'], /--attempt takes a whole number from 1, got "0"/],
    [['o/r', '7', '--top', 'ten'], /--top takes a whole number/],
    [['o/r', '7', '--sort', 'name'], /--sort takes end or run, got "name"/],
    [['https://github.com/o/r/pull/7'], /not a run/],
  ];
  for (const [argv, message] of cases) assert.throws(() => parseArgs(argv), (e) => e instanceof UsageError && message.test(e.message), argv.join(' '));
});

test('concatenated pages are read as separate values, strings and escapes included', () => {
  assert.deepEqual(parseJsonStream('{"a":"}{\\"\\\\"}[1,[2]]\n{"b":2}'), [{ a: '}{"\\' }, [1, [2]], { b: 2 }]);
  assert.deepEqual(parseJsonStream(PAGES).map((page) => page.jobs.length), [2, 3]);
  assert.deepEqual(parseJsonStream(''), []);
});

test('a page that is not JSON, or stops part-way, is a TraceError', () => {
  assert.throws(() => parseJsonStream('{"a":}'), (e) => e instanceof TraceError && /not JSON/.test(e.message));
  assert.throws(() => parseJsonStream('{"a":[1'), (e) => e instanceof TraceError && /stops part-way/.test(e.message));
  assert.throws(() => parseJsonStream('"open'), (e) => e instanceof TraceError && /stops part-way/.test(e.message));
});

test('repeated names get a counter, so matrix jobs keep their own rows', () => {
  assert.deepEqual(uniqueNames(['build', 'test', 'build', 'build']), ['build', 'test', 'build [2]', 'build [3]']);
});

test('durations read as a person would say them', () => {
  assert.equal(formatDuration(null), '-');
  assert.equal(formatDuration(0), '0s');
  assert.equal(formatDuration(0.85), '0.9s');
  assert.equal(formatDuration(42), '42s');
  assert.equal(formatDuration(59.96), '1m 00s');
  assert.equal(formatDuration(252), '4m 12s');
  assert.equal(formatDuration(3720), '1h 02m');
  assert.equal(formatChange(62), '+1m 02s');
  assert.equal(formatChange(-30), '-30s');
  assert.equal(formatChange(0), '0s');
  assert.equal(formatChange(null), '-');
});

test('a table aligns its columns left or right and drops trailing spaces', () => {
  assert.deepEqual(table(['Name', 'Time'], [['a', '1s'], ['long name', '10m 00s']], 'lr'), ['  Name          Time', '  a               1s', '  long name  10m 00s']);
  assert.deepEqual(table(['A', 'B'], [], 'll'), ['  A  B']);
});

const jobs = () => parseJsonStream(PAGES).flatMap((page) => page.jobs);
const report = () => analyse({ ...RUN, repository: 'blinkbitcoin/app', attempt: 2 }, jobs(), NOW);

test('each job has its queue and run time, each step its time, and the run its wall clock', () => {
  const r = report();
  assert.equal(r.wall_s, 36 * 60 + 10);
  assert.equal(r.running, false);
  const ios = r.jobs.find((job) => job.name === 'Build iOS');
  assert.deepEqual([ios.queue_s, ios.run_s, ios.conclusion, ios.runner], [1200, 900, 'failure', 'macos-15']);
  assert.deepEqual(ios.steps.map((s) => [s.name, s.s, s.conclusion]), [['Set up job', 2, 'success'], ['Build', 838, 'failure'], ['Upload', 0, 'skipped']]);
  assert.deepEqual(r.jobs.map((job) => job.runner), ['GitHub Actions 2', 'ubuntu-latest', 'macos-15', null, null]);
  assert.deepEqual(r.run, { id: 1001, name: 'CI', repository: 'blinkbitcoin/app', attempt: 2, url: RUN.html_url, sha: RUN.head_sha, workflow: '.github/workflows/ci.yml' });
});

test('the critical path walks back from the last job to finish through the job that ended last before each started', () => {
  assert.deepEqual(report().critical_path.map((job) => job.name), ['Build Android', 'Build iOS', 'Report']);
  // The E2E job waited for the Android build: alone, the pair is the path.
  const pair = analyse(RUN, [PAGE_ONE.jobs[1], PAGE_TWO.jobs[1]], NOW);
  assert.deepEqual(pair.critical_path.map((job) => job.name), ['Build Android', 'E2E Android']);
  assert.deepEqual(criticalPath([]), []);
  // Zero-length jobs at one instant cannot send the walk round in a circle.
  const instant = { started: 5, end: 5 };
  const other = { started: 5, end: 5 };
  assert.equal(criticalPath([instant, other]).length, 2);
});

test('a run still going is measured up to now: a running job, a running step, a queued step and a queued job', () => {
  const live = analyse(RUN, [
    {
      id: 9,
      name: 'Build',
      status: 'in_progress',
      conclusion: null,
      created_at: T('10:50:00'),
      started_at: T('10:51:00'),
      completed_at: null,
      steps: [
        { name: 'Compile', status: 'in_progress', conclusion: null, started_at: T('10:52:00'), completed_at: null },
        { name: 'Upload', status: 'queued', conclusion: null, started_at: null, completed_at: null },
      ],
    },
    { id: 10, name: 'Deploy', status: 'queued', conclusion: null, created_at: T('10:55:00'), started_at: null, completed_at: null },
  ], NOW);
  assert.equal(live.running, true);
  assert.equal(live.wall_s, 600);
  const [build, deploy] = live.jobs;
  assert.deepEqual([build.conclusion, build.queue_s, build.run_s, build.end], ['running', 60, 540, NOW]);
  assert.deepEqual(build.steps.map((s) => [s.conclusion, s.s]), [['running', 480], ['queued', null]]);
  assert.deepEqual([deploy.conclusion, deploy.queue_s, deploy.run_s, deploy.end, deploy.steps], ['queued', 300, null, null, []]);
  assert.deepEqual(live.critical_path.map((job) => job.name), ['Build']);
  const text = renderReport(live).join('\n');
  assert.match(text, /wall clock 10m 00s, from the first job created to the last job finished \(still running: measured up to now\)/);
  assert.match(text, /^ {2}Build +1m 00s +9m 00s +\+10m 00s +running +-$/m);
  assert.match(text, /^ {2}Deploy +5m 00s +- +- +queued +-$/m, 'the queued job sorts last, with no run time');
  assert.match(renderReport(live, { sort: 'run' }).join('\n'), /longest run first\n.*\n {2}Build .*\n {2}Deploy /);
});

test('a run with no jobs has no wall clock and an empty path', () => {
  const empty = analyse(RUN, [], NOW);
  assert.deepEqual([empty.wall_s, empty.start, empty.running, empty.critical_path], [null, null, false, []]);
});

test('the trace: lines of a log are read with their time; everything else is not', () => {
  assert.deepEqual(tracePhases(LOGS[4]), [
    { at: Date.parse(T('10:13:00.5')), name: 'boot emulator', s: 40.2 },
    { at: Date.parse(T('10:29:59.9')), name: 'run flows', s: 1019 },
  ]);
  assert.deepEqual(tracePhases(LOGS[1]).map((p) => p.name), ['restore cache', 'biome'], 'a byte-order mark and CRLF endings are fine');
  assert.deepEqual(tracePhases(LOGS[5]), []);
});

test('a phase goes under the step running when it was written, or on the job before any step', () => {
  const r = report();
  const lint = attachPhases(r.jobs[0], tracePhases(LOGS[1]));
  assert.deepEqual(lint.phases, [{ name: 'restore cache', s: 0.5 }]);
  assert.deepEqual(lint.steps[1].phases, [{ name: 'biome', s: 12 }]);
  const live = analyse(RUN, [{ ...PAGE_TWO.jobs[1], steps: [{ name: 'Waiting', started_at: null }] }], NOW);
  assert.deepEqual(attachPhases(live.jobs[0], tracePhases(LOGS[4])).phases.map((p) => p.name), ['boot emulator', 'run flows']);
});

test('the slowest steps are every started step, slowest first, cut to top', () => {
  const r = report();
  assert.deepEqual(slowestSteps(r, 3).map((s) => `${s.job} / ${s.step} ${s.s}`), ['E2E Android / Run Maestro 1060', 'Build iOS / Build 838', 'Build Android / Build 708']);
  assert.equal(slowestSteps(r, 100).length, 11, 'every step of the five jobs, the skipped one included');
});

test('the text report has the header, the jobs in the order they finished, the slowest steps and the critical path', () => {
  const { code, out, err, calls } = run(['https://github.com/blinkbitcoin/app/actions/runs/1001', '--top', '3']);
  assert.equal(code, 0, err);
  assert.equal(err, '');
  assert.deepEqual(calls, [RUN_PATH, JOBS_PATH], 'no log is fetched without --logs, and the attempt is the run\'s latest');
  assert.equal(
    out,
    [
      'CI #1001, attempt 2, blinkbitcoin/app',
      'https://github.com/blinkbitcoin/app/actions/runs/1001',
      'commit 0123456, .github/workflows/ci.yml',
      'wall clock 36m 10s, from the first job created to the last job finished',
      '',
      'Jobs, in the order they finished',
      '  Job              Queue      Run   Ends at  Result   Runner',
      '  Lint                5s   2m 00s   +2m 05s  success  GitHub Actions 2',
      '  Build Android      10s  12m 00s  +12m 10s  success  ubuntu-latest',
      '  E2E Android         5s  17m 40s  +30m 00s  success  -',
      '  Build iOS      20m 00s  15m 00s  +35m 00s  failure  macos-15',
      '  Report              5s   1m 00s  +36m 10s  success  -',
      '',
      'Slowest steps (top 3)',
      '  Job / step                    Time  Result',
      '  E2E Android / Run Maestro  17m 40s  success',
      '  Build iOS / Build          13m 58s  failure',
      '  Build Android / Build      11m 48s  success',
      '',
      'Critical path: each job follows the job that finished last before it started',
      '(read from the timestamps; the workflow file and its needs: are not read)',
      '  Job              Queue      Run   Ends at',
      '  Build Android      10s  12m 00s  +12m 10s',
      '  Build iOS      20m 00s  15m 00s  +35m 00s',
      '  Report              5s   1m 00s  +36m 10s',
      '',
    ].join('\n'),
  );
});

test('--sort run lists the jobs by run time, longest first', () => {
  const { out } = run(['blinkbitcoin/app', '1001', '--sort', 'run']);
  const jobsTable = out.split('Jobs, longest run first\n')[1].split('\n\n')[0].split('\n').slice(1);
  assert.deepEqual(jobsTable.map((line) => line.trim().split(/ {2,}/)[0]), ['E2E Android', 'Build iOS', 'Build Android', 'Lint', 'Report']);
});

test('--logs reads each job log and lists its phases under their steps; a log it cannot read is a warning', () => {
  const { code, out, err, calls } = run(['blinkbitcoin/app', '1001', '--logs']);
  assert.equal(code, 0);
  assert.deepEqual(calls.slice(2), [1, 2, 3, 4, 5].map(logPath));
  assert.equal(err, 'trace-run: no log for Build iOS, so no phases for it: gh: Not Found (HTTP 404)\n');
  assert.ok(
    out.endsWith(
      [
        'Phases, from the trace: lines in the job logs',
        '  Lint (before its first step)',
        '    restore cache  0.5s',
        '  Lint / Run lint {all} "fast"',
        '    biome   12s',
        '  Build Android / Build',
        '    gradle assemble  11m 40s',
        '  E2E Android / Run Maestro',
        '    boot emulator    40.2s',
        '    run flows      16m 59s',
        '',
      ].join('\n'),
    ),
    out,
  );
});

test('--logs over logs with no trace: line says so', () => {
  const answers = { ...ANSWERS, [logPath(1)]: '', [logPath(2)]: '', [logPath(3)]: '', [logPath(4)]: '' };
  assert.match(run(['blinkbitcoin/app', '1001', '--logs'], answers).out, /Phases, from the trace: lines in the job logs\n {2}none: no job log has a trace: line\n$/);
});

test('--attempt reads that attempt, over the run\'s latest and over the URL', () => {
  const answers = { ...ANSWERS, 'api --paginate repos/blinkbitcoin/app/actions/runs/1001/attempts/1/jobs?per_page=100': JSON.stringify(PAGE_ONE) };
  const viaFlag = run(['https://github.com/blinkbitcoin/app/actions/runs/1001/attempts/2', '--attempt', '1'], answers);
  assert.equal(viaFlag.code, 0);
  assert.match(viaFlag.out, /^CI #1001, attempt 1,/);
  const viaUrl = run(['https://github.com/blinkbitcoin/app/actions/runs/1001/attempts/1'], answers);
  assert.match(viaUrl.out, /^CI #1001, attempt 1,/);
});

test('--compare lines up the other run, the largest increase first and the rows one side lacks last', () => {
  const { code, out } = run(['blinkbitcoin/app', '1001', '--compare', '1000', '--top', '6'], COMPARE_ANSWERS);
  assert.equal(code, 0);
  assert.ok(
    out.endsWith(
      [
        'Compared with run #1000 (https://github.com/blinkbitcoin/app/actions/runs/1000), largest increase first (top 6)',
        '  Job / step               #1001    #1000    Change',
        '  wall clock             36m 10s  15m 00s  +21m 10s',
        '  Build Android          12m 00s   8m 00s   +4m 00s',
        '  Build Android / Build  11m 48s   7m 48s   +4m 00s',
        '  Build iOS              15m 00s  13m 00s   +2m 00s',
        '  Build iOS / Build      13m 58s  11m 58s   +2m 00s',
        '  Lint                    2m 00s        -         -',
        '',
      ].join('\n'),
    ),
    out,
  );
  const rows = compareReports(report(), report());
  assert.ok(rows.every((row) => row.change_s === 0));
  const other = analyse(OTHER_RUN, OTHER_JOBS.jobs, NOW);
  assert.deepEqual(compareReports(report(), other).at(-1), { name: 'Old job', this_s: null, other_s: 55, change_s: null });
});

test('--json writes the whole tree, and says where', () => {
  const { code, out, written } = run(['blinkbitcoin/app', '1001', '--logs', '--top', '2', '--json', 'trace.json', '--compare', 'blinkbitcoin/app', '1000'], COMPARE_ANSWERS);
  assert.equal(code, 0);
  assert.match(out, /\nwrote trace\.json\n$/);
  const tree = JSON.parse(written['trace.json']);
  assert.deepEqual(Object.keys(tree), ['run', 'jobs', 'critical_path', 'slowest', 'comparison']);
  assert.deepEqual(tree.run, { id: 1001, name: 'CI', repository: 'blinkbitcoin/app', attempt: 2, url: RUN.html_url, sha: RUN.head_sha, workflow: '.github/workflows/ci.yml', wall_s: 2170, running: false });
  assert.deepEqual(tree.jobs[3], {
    name: 'E2E Android',
    queue_s: 5,
    run_s: 1060,
    conclusion: 'success',
    runner: null,
    started_at: '2026-10-01T10:12:20.000Z',
    completed_at: '2026-10-01T10:30:00.000Z',
    phases: [],
    steps: [{ name: 'Run Maestro', s: 1060, conclusion: 'success', phases: [{ name: 'boot emulator', s: 40.2 }, { name: 'run flows', s: 1019 }] }],
  });
  assert.deepEqual(tree.critical_path.map((job) => job.name), ['Build Android', 'Build iOS', 'Report']);
  assert.deepEqual(tree.slowest.map((s) => s.step), ['Run Maestro', 'Build']);
  assert.equal(tree.comparison[0].name, 'wall clock');
  const plain = toJson(analyse(RUN, [PAGE_TWO.jobs[1]], NOW));
  assert.equal(plain.comparison, undefined);
  assert.equal(toJson(analyse(RUN, [{ ...PAGE_TWO.jobs[1], started_at: null, completed_at: null }], NOW)).jobs[0].started_at, null);
});

test('a usage error prints the reason and the usage, and exits 2', () => {
  for (const argv of [[], ['https://github.com/o/r/pull/7'], ['o/r', '7', '--top']]) {
    const result = run(argv);
    assert.equal(result.code, 2, argv.join(' '));
    assert.match(result.err, /^trace-run: .+\nusage: trace-run /, argv.join(' '));
    assert.ok(result.err.endsWith(`${USAGE}\n`));
    assert.equal(result.out, '');
  }
});

test('--help prints the header on stdout and exits 0, before anything else', () => {
  const { code, out, err } = run(['--nope', '--help']);
  assert.equal(code, 0);
  assert.equal(err, '');
  assert.match(out, /^Shows where a GitHub Actions run spent its time/);
  assert.match(out, /^ {2}trace-run <run URL \| owner\/repository run-id> \[options\]$/m);
});

test('a missing gh names the fix, and a failing gh is reported with its own message; both exit 1', () => {
  const missing = run(['o/r', '7'], { [`api repos/o/r/actions/runs/7`]: () => ({ error: Object.assign(new Error('spawn gh ENOENT'), { code: 'ENOENT' }) }) });
  assert.deepEqual([missing.code, missing.err], [1, 'trace-run: gh is not installed or not on PATH: install gh and run gh auth login\n']);
  const denied = run(['o/r', '7'], { [`api repos/o/r/actions/runs/7`]: () => ({ error: Object.assign(new Error('spawn gh EACCES'), { code: 'EACCES' }) }) });
  assert.deepEqual([denied.code, denied.err], [1, 'trace-run: gh did not run: spawn gh EACCES\n']);
  const failing = run(['o/r', '7']);
  assert.equal(failing.code, 1);
  assert.equal(failing.err, 'trace-run: gh api repos/o/r/actions/runs/7 failed (exit 1):\ngh: Not Found (HTTP 404)\n');
  const silent = run(['o/r', '7'], { [`api repos/o/r/actions/runs/7`]: () => ({ status: 4 }) });
  assert.equal(silent.err, 'trace-run: gh api repos/o/r/actions/runs/7 failed (exit 4):\n\n');
  const nothing = run(['o/r', '7'], { [`api repos/o/r/actions/runs/7`]: '\n' });
  assert.equal(nothing.err, 'trace-run: gh api repos/o/r/actions/runs/7 answered nothing\n');
  const garbage = run(['o/r', '7'], { [`api repos/o/r/actions/runs/7`]: '{"id":}' });
  assert.match(garbage.err, /^trace-run: gh answered something that is not JSON: /);
  const jobsMissing = run(['blinkbitcoin/app', '1001'], { [RUN_PATH]: ANSWERS[RUN_PATH] });
  assert.match(jobsMissing.err, /attempts\/2\/jobs\?per_page=100 failed/);
});

test('an error that is not about the run is not swallowed', () => {
  const boom = () => {
    throw new TypeError('boom');
  };
  assert.throws(() => main([42], { stdout: { write() {} }, stderr: { write() {} } }), TypeError);
  assert.throws(() => main(['o/r', '7'], { gh: boom, now: () => NOW, stdout: { write() {} }, stderr: { write() {} } }), /boom/);
  const { gh } = fakeGh({ ...ANSWERS, [logPath(1)]: boom });
  assert.throws(() => loadRun({ repository: 'blinkbitcoin/app', runId: '1001' }, { gh, now: NOW, logs: true, warn() {} }), /boom/);
});

test('a job log is read with the escape-sequence flag, and without it from a gh too old to know it', () => {
  assert.equal(ESCAPES_FLAG, '--allow-escape-sequences');
  const old = (args) =>
    args.includes(ESCAPES_FLAG)
      ? { status: 1, stderr: `unknown flag: ${ESCAPES_FLAG}\n\nUsage:  gh api <endpoint> [flags]\n` }
      : { status: 0, stdout: `log of ${args.join(' ')}` };
  assert.equal(ghLog(old, 'repos/o/r/actions/jobs/1/logs'), 'log of api repos/o/r/actions/jobs/1/logs');
  const gone = () => ({ status: 1, stderr: 'gh: HTTP 410' });
  assert.throws(() => ghLog(gone, 'repos/o/r/actions/jobs/1/logs'), (e) => e instanceof TraceError && /HTTP 410/.test(e.message));
});

test('--logs does not ask for the log of a job that has not finished', () => {
  const live = { ...PAGE_ONE.jobs[0], conclusion: null, completed_at: null };
  const answers = { [RUN_PATH]: ANSWERS[RUN_PATH], [JOBS_PATH]: JSON.stringify({ jobs: [live] }) };
  const { code, err, calls } = run(['blinkbitcoin/app', '1001', '--logs'], answers);
  assert.equal(code, 0);
  assert.deepEqual(calls, [RUN_PATH, JOBS_PATH]);
  assert.equal(err, 'trace-run: no log for Lint yet, so no phases for it: the job has not finished\n');
});

test('ghText and ghJson hand back what gh printed', () => {
  const { gh } = fakeGh(ANSWERS);
  assert.equal(ghText(gh, RUN_PATH.split(' ')), JSON.stringify(RUN));
  assert.equal(ghJson(gh, JOBS_PATH.split(' ')).length, 2);
});

test('runGh runs the command it is given, and a command that is not there is ENOENT', () => {
  const ran = runGh(['-e', 'process.stdout.write("hello")'], process.execPath);
  assert.deepEqual([ran.status, ran.stdout], [0, 'hello']);
  const missing = runGh(['api'], path.join(work, 'no-such-gh'));
  assert.equal(missing.error.code, 'ENOENT');
  assert.throws(() => ghText((args) => runGh(args, path.join(work, 'no-such-gh')), ['api']), /install gh and run gh auth login/);
});

// A gh on PATH that answers from the recorded fixtures, for the program runs.
function fakeGhOnPath() {
  const dir = mkdtempSync(path.join(work, 'bin-'));
  writeFileSync(path.join(dir, 'answers.json'), JSON.stringify(ANSWERS));
  const program = path.join(dir, 'gh');
  writeFileSync(
    program,
    `#!${process.execPath}\nconst answers = require(${JSON.stringify(path.join(dir, 'answers.json'))});\n` +
      `const answer = answers[process.argv.slice(2).join(' ')];\n` +
      `if (answer === undefined) { process.stderr.write('gh: Not Found (HTTP 404)\\n'); process.exit(1); }\n` +
      'process.stdout.write(answer);\n',
  );
  chmodSync(program, 0o755);
  return dir;
}

test('as a program it reads the run through the gh on PATH and writes --json', () => {
  const dir = fakeGhOnPath();
  const json = path.join(work, 'program.json');
  const result = spawnSync(process.execPath, [BIN, 'blinkbitcoin/app', '1001', '--json', json], {
    encoding: 'utf8',
    env: { PATH: `${dir}${path.delimiter}${process.env.PATH}` },
  });
  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stdout, /^CI #1001, attempt 2, blinkbitcoin\/app\n/);
  assert.equal(JSON.parse(readFileSync(json, 'utf8')).jobs.length, 5);
});

test('as a program with no arguments it prints the usage and exits 2', () => {
  const result = spawnSync(process.execPath, [BIN], { encoding: 'utf8' });
  assert.equal(result.status, 2);
  assert.match(result.stderr, /^trace-run: name a run/);
});

test('imported, it runs nothing', async () => {
  const before = process.exitCode;
  await import('./bin/trace-run.mjs');
  assert.equal(process.exitCode, before);
});

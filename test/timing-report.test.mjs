// scripts/self/timing-report.mjs: the report `make check`, `make test`,
// `make report-timing` and each self-ci job print of where a run spent its time.
//
// Covered here: the formatting of durations, shares and statuses; the
// targets.jsonl reader (blank lines, a line that is not JSON, a record missing
// a field or running backwards); XML entity decoding; the JUnit reader over a
// trimmed bats report and a trimmed node report from real runs (a failing case
// with a child element, node's doubly escaped quotes, a suite taken from
// `file`, from `classname` or from neither) and every report it refuses; the
// summary (targets summed per name in start order, the first failure kept, a
// zero wall clock, suites grouped and sorted); the text and markdown renderings
// with and without tests; finding the newest run; and every way out of main -
// the newest run or a named one, the summary file, the `latest` link replaced,
// the job summary appended, too many arguments, no .timing directory, no run,
// a missing directory, nothing timed, an empty targets.jsonl, a malformed line
// or report, and a write that fails - plus the program run as a program and
// imported, when it runs nothing.
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import {
  mkdirSync,
  mkdtempSync,
  readFileSync,
  readlinkSync,
  realpathSync,
  rmSync,
  symlinkSync,
  writeFileSync,
} from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { after, test } from 'node:test';
import { fileURLToPath } from 'node:url';
import {
  TOP,
  USAGE,
  decodeXml,
  formatDuration,
  formatMarkdown,
  formatShare,
  formatStatus,
  formatText,
  junitFiles,
  main,
  newestRun,
  parseJunit,
  parseTargets,
  summarise,
} from '../scripts/self/timing-report.mjs';

const ROOT = path.join(path.dirname(fileURLToPath(import.meta.url)), '..');
const SCRIPT = path.join(ROOT, 'scripts/self/timing-report.mjs');
const FIXTURES = path.join(ROOT, 'test/fixtures/timing');

const scratch = realpathSync(mkdtempSync(path.join(tmpdir(), 'timing-report-')));
after(() => rmSync(scratch, { recursive: true, force: true }));

/** A writable stream stand-in that keeps what was written. */
function sink() {
  return { text: '', write(chunk) { this.text += chunk; } };
}

/** A fresh working directory under the scratch directory. */
let made = 0;
function workdir() {
  made += 1;
  const dir = path.join(scratch, `work-${made}`);
  mkdirSync(dir, { recursive: true });
  return dir;
}

/** One targets.jsonl line. */
function line(target, start, end, status = 0) {
  return `${JSON.stringify({ target, command: `run ${target}`, start, end, status })}\n`;
}

/**
 * A run directory `cwd/.timing/NAME` holding `targets` as its targets.jsonl
 * (left out when null) and the two fixture reports, the node one under a
 * subdirectory with its paths rooted at `cwd`.
 */
function run(cwd, name, targets, { reports = true } = {}) {
  const dir = path.join(cwd, '.timing', name);
  mkdirSync(path.join(dir, 'nested'), { recursive: true });
  if (targets !== null) writeFileSync(path.join(dir, 'targets.jsonl'), targets);
  if (reports) {
    writeFileSync(path.join(dir, 'report.xml'), readFileSync(path.join(FIXTURES, 'bats-report.xml')));
    const node = readFileSync(path.join(FIXTURES, 'node-report.xml'), 'utf8').replaceAll('@ROOT@', cwd);
    writeFileSync(path.join(dir, 'nested', 'test-scripts.xml'), node);
    writeFileSync(path.join(dir, 'notes.txt'), 'not a report');
  }
  return dir;
}

test('formatDuration reads in milliseconds under a second, seconds under a minute and minutes and seconds above', () => {
  assert.equal(formatDuration(0), '0 ms');
  assert.equal(formatDuration(38.4), '38 ms');
  assert.equal(formatDuration(999), '999 ms');
  assert.equal(formatDuration(1000), '1.0 s');
  assert.equal(formatDuration(4249), '4.2 s');
  assert.equal(formatDuration(59_940), '59.9 s');
  assert.equal(formatDuration(60_000), '1 min 0.0 s');
  assert.equal(formatDuration(187_000), '3 min 7.0 s');
});

test('formatShare is a whole percentage and formatStatus says ok or the exit status', () => {
  assert.equal(formatShare(0.456), '46%');
  assert.equal(formatShare(0), '0%');
  assert.equal(formatStatus(0), 'ok');
  assert.equal(formatStatus(2), 'failed (exit 2)');
});

test('parseTargets reads each record in file order and skips blank lines', () => {
  const records = parseTargets(`${line('a', 1, 2)}\n  \n${line('b', 3, 5, 1)}`, 'f');
  assert.deepEqual(records.map((record) => [record.target, record.start, record.end, record.status]), [
    ['a', 1, 2, 0],
    ['b', 3, 5, 1],
  ]);
  assert.deepEqual(parseTargets('', 'f'), []);
});

test('parseTargets names the file and line of a line that is not JSON', () => {
  assert.throws(() => parseTargets(`${line('a', 1, 2)}{oops\n`, 'run/targets.jsonl'), {
    message: /^run\/targets\.jsonl line 2 is not JSON: /,
  });
});

test('parseTargets refuses a record without a target, times, an order or an integer status', () => {
  const bad = [
    'null',
    '[]',
    '"text"',
    '{"start":1,"end":2,"status":0}',
    '{"target":"","start":1,"end":2,"status":0}',
    '{"target":"a","end":2,"status":0}',
    '{"target":"a","start":1,"status":0}',
    '{"target":"a","start":3,"end":2,"status":0}',
    '{"target":"a","start":1,"end":2}',
    '{"target":"a","start":1,"end":2,"status":1.5}',
  ];
  for (const text of bad) {
    assert.throws(() => parseTargets(`${text}\n`, 'f'), {
      message: `f line 1 is not a timing record (target, start <= end in epoch milliseconds, integer status): ${text}`,
    });
  }
});

test('decodeXml decodes the named entities and character references, and leaves the unknown alone', () => {
  assert.equal(decodeXml('&lt;a&gt; &quot;b&quot; &apos;c&apos; &amp;d'), '<a> "b" \'c\' &d');
  assert.equal(decodeXml('&#65;&#x42;&#x1F600;'), 'AB\u{1F600}');
  assert.equal(decodeXml('&nbsp; &amp;quot;'), '&nbsp; &quot;');
});

test('parseJunit reads a bats report: classname as the suite, seconds as milliseconds, a failing case too', () => {
  const cases = parseJunit(readFileSync(path.join(FIXTURES, 'bats-report.xml'), 'utf8'), 'report.xml', '/repo');
  assert.deepEqual(cases, [
    { name: 'AGENTS.md exists - the command table is the agent-facing contract', suite: 'docs-contract.bats', ms: 6 },
    { name: 'no make target is named after the tool it runs', suite: 'docs-contract.bats', ms: 138 },
    { name: 'a failing case <with> "markup"', suite: 'docs-contract.bats', ms: 42 },
    { name: 'require_cmd fails naming the missing tool and the fix', suite: 'require-cmd.bats', ms: 8 },
    { name: 'no bats file skips a test for want of a tool .mise.toml pins', suite: 'require-cmd.bats', ms: 1299 },
  ]);
});

test('parseJunit reads a node report: the file relative to the working directory as the suite', () => {
  const text = readFileSync(path.join(FIXTURES, 'node-report.xml'), 'utf8').replaceAll('@ROOT@', '/repo');
  assert.deepEqual(parseJunit(text, 'test-scripts.xml', '/repo'), [
    { name: 'truthy &quot;x&quot; & <y>', suite: 'test/mod.test.mjs', ms: 0 },
    { name: 'top level', suite: 'test/mod.test.mjs', ms: 2500 },
  ]);
});

test('parseJunit gives a case with neither file nor classname an empty suite, and a report without cases none', () => {
  assert.deepEqual(parseJunit('<testsuite><testcase name="n" time="1"/></testsuite>', 'f', '/'), [
    { name: 'n', suite: '', ms: 1000 },
  ]);
  assert.deepEqual(parseJunit('<testsuites>\n</testsuites>', 'f', '/'), []);
});

test('parseJunit refuses a file that is not a JUnit report, naming it', () => {
  for (const text of ['', 'not xml', '<testsuitesx/>']) {
    assert.throws(() => parseJunit(text, 'run/report.xml', '/'), {
      message: 'run/report.xml is not a JUnit report: it has no <testsuites> or <testsuite> element',
    });
  }
});

test('parseJunit refuses a case it cannot read, naming the file and the line', () => {
  assert.throws(() => parseJunit('<testsuites>\n<testcase name=bare time="1"/>\n</testsuites>', 'r.xml', '/'), {
    message: 'r.xml line 2: a <testcase> element that cannot be read',
  });
  assert.throws(() => parseJunit('<testsuites>\n<testcase name="cut', 'r.xml', '/'), {
    message: 'r.xml line 2: a <testcase> element that cannot be read',
  });
});

test('parseJunit refuses a case without a name or a numeric time', () => {
  for (const element of [
    '<testcase time="1"/>',
    '<testcase name="" time="1"/>',
    '<testcase name="n"/>',
    '<testcase name="n" time=""/>',
    '<testcase name="n" time="soon"/>',
    '<testcase name="n" time="-1"/>',
  ]) {
    assert.throws(() => parseJunit(`<testsuites>${element}</testsuites>`, 'r.xml', '/'), {
      message: 'r.xml line 1: a <testcase> without a name or a numeric time',
    }, element);
  }
});

test('summarise sums each target in start order, keeps its first failure and takes shares of the wall clock', () => {
  const summary = summarise(
    [
      { target: 'test-unit', start: 400, end: 1000, status: 0 },
      { target: 'check-ci', start: 0, end: 100, status: 2 },
      { target: 'check-ci', start: 100, end: 400, status: 0 },
    ],
    [],
  );
  assert.deepEqual(summary.wall, { start: 0, end: 1000, ms: 1000 });
  assert.deepEqual(summary.targets, [
    { target: 'check-ci', ms: 400, steps: 2, status: 2, share: 0.4 },
    { target: 'test-unit', ms: 600, steps: 1, status: 0, share: 0.6 },
  ]);
  assert.equal(summary.tests, 0);
  assert.deepEqual(summary.slowest, []);
  assert.deepEqual(summary.suites, []);
});

test('summarise gives every target a zero share when the wall clock is zero', () => {
  const summary = summarise([{ target: 'a', start: 5, end: 5, status: 0 }], []);
  assert.equal(summary.wall.ms, 0);
  assert.equal(summary.targets[0].share, 0);
});

test('summarise keeps the slowest tests, at most TOP, and every suite, longest first', () => {
  const cases = [];
  for (let index = 0; index < TOP + 5; index += 1) cases.push({ name: `t${index}`, suite: index % 2 ? 'odd' : 'even', ms: index });
  const summary = summarise([{ target: 'a', start: 0, end: 1, status: 0 }], cases);
  assert.equal(summary.tests, TOP + 5);
  assert.equal(summary.slowest.length, TOP);
  assert.equal(summary.slowest[0].name, `t${TOP + 4}`);
  assert.equal(summary.slowest.at(-1).name, 't5');
  assert.deepEqual(summary.suites.map((suite) => [suite.suite, suite.tests]), [
    ['even', 13],
    ['odd', 12],
  ]);
});

test('formatText lists the targets, the slowest tests and the slowest suites', () => {
  const summary = summarise(
    [
      { target: 'check-ci', start: 0, end: 30_000, status: 1 },
      { target: 'test-unit', start: 30_000, end: 120_000, status: 0 },
    ],
    [
      { name: 'slow one', suite: 'a.bats', ms: 61_000 },
      { name: 'quick one', suite: 'b.bats', ms: 500 },
    ],
  );
  assert.equal(
    formatText(summary, '.timing/r'),
    [
      'Timing of .timing/r: 2 min 0.0 s wall clock',
      '',
      'Targets',
      '  check-ci           30.0 s   25%  failed (exit 1)',
      '  test-unit    1 min 30.0 s   75%  ok',
      '',
      'Slowest tests (2 of 2)',
      '     1 min 1.0 s  a.bats  slow one',
      '          500 ms  b.bats  quick one',
      '',
      'Slowest suites (2 of 2; every suite is in timing.json)',
      '     1 min 1.0 s     1 tests  a.bats',
      '          500 ms     1 tests  b.bats',
      '',
    ].join('\n'),
  );
});

test('formatText says so when the run has no test timings', () => {
  const text = formatText(summarise([{ target: 'check-spell', start: 0, end: 1000, status: 0 }], []), 'r');
  assert.equal(text, 'Timing of r: 1.0 s wall clock\n\nTargets\n  check-spell           1.0 s  100%  ok\n\nNo JUnit report in this run, so no test timings.\n');
});

test('formatMarkdown renders tables, escaping pipes and line breaks in a cell', () => {
  const summary = summarise(
    [{ target: 'test-unit', start: 0, end: 2000, status: 0 }],
    [{ name: 'a | b\nc', suite: 'x.bats', ms: 1500 }],
  );
  assert.equal(
    formatMarkdown(summary, 'run|1'),
    [
      '### Timing of run\\|1',
      '',
      '2.0 s wall clock.',
      '',
      '| Target | Duration | Share | Status |',
      '|---|---:|---:|---|',
      '| test-unit | 2.0 s | 100% | ok |',
      '',
      'Slowest tests (1 of 1):',
      '',
      '| Duration | Suite | Test |',
      '|---:|---|---|',
      '| 1.5 s | x.bats | a \\| b c |',
      '',
      'Slowest suites (1 of 1):',
      '',
      '| Duration | Tests | Suite |',
      '|---:|---:|---|',
      '| 1.5 s | 1 | x.bats |',
      '',
      '',
    ].join('\n'),
  );
});

test('formatMarkdown leaves out the test tables when there are no tests', () => {
  const text = formatMarkdown(summarise([{ target: 'a', start: 0, end: 1, status: 3 }], []), 'r');
  assert.ok(text.endsWith('| a | 1 ms | 100% | failed (exit 3) |\n\n'), text);
  assert.ok(!text.includes('Slowest'), text);
});

test('newestRun takes the last run by name, never latest nor a file', () => {
  const root = path.join(workdir(), '.timing');
  for (const name of ['20261007T090000', '20261007T190000', '20261006T235959']) mkdirSync(path.join(root, name), { recursive: true });
  writeFileSync(path.join(root, 'zz-a-file'), '');
  symlinkSync('20261006T235959', path.join(root, 'latest'));
  assert.equal(newestRun(root), path.join(root, '20261007T190000'));
});

test('newestRun fails with no .timing directory, and with no run in it', () => {
  const root = path.join(workdir(), '.timing');
  assert.throws(() => newestRun(root), {
    message: `no ${root} directory: run make check or make test first, which time themselves into it`,
  });
  mkdirSync(path.join(root, 'latest'), { recursive: true });
  assert.throws(() => newestRun(root), { message: `no run under ${root}: run make check or make test first` });
});

test('junitFiles finds every .xml at any depth, in name order', () => {
  const cwd = workdir();
  const dir = run(cwd, 'r', '');
  assert.deepEqual(junitFiles(dir), [path.join(dir, 'nested', 'test-scripts.xml'), path.join(dir, 'report.xml')]);
});

test('main reports the newest run, writes timing.json, points latest at it and appends the job summary', () => {
  const cwd = workdir();
  run(cwd, '20261007T090000', line('old', 0, 1));
  const dir = run(cwd, '20261007T190000', line('check-ci', 0, 1000, 0) + line('test-unit', 1000, 4000, 0));
  symlinkSync('20261007T090000', path.join(cwd, '.timing', 'latest'));
  const summaryFile = path.join(cwd, 'summary.md');
  writeFileSync(summaryFile, 'before\n');
  const stdout = sink();
  const stderr = sink();
  assert.equal(main([], { cwd, env: { GITHUB_STEP_SUMMARY: summaryFile }, stdout, stderr }), 0);
  assert.equal(stderr.text, '');
  assert.match(stdout.text, /^Timing of \.timing\/20261007T190000: 4\.0 s wall clock\n/);
  assert.match(stdout.text, /\n  test-unit\s+3\.0 s\s+75%\s+ok\n/);
  assert.match(stdout.text, /Slowest tests \(7 of 7\)\n\s+2\.5 s  test\/mod\.test\.mjs  top level\n\s+1\.3 s  require-cmd\.bats  no bats file/);
  const written = JSON.parse(readFileSync(path.join(dir, 'timing.json'), 'utf8'));
  assert.equal(written.run, '.timing/20261007T190000');
  assert.equal(written.tests, 7);
  assert.deepEqual(written.suites.map((suite) => suite.suite), ['test/mod.test.mjs', 'require-cmd.bats', 'docs-contract.bats']);
  assert.equal(readlinkSync(path.join(cwd, '.timing', 'latest')), '20261007T190000');
  const markdown = readFileSync(summaryFile, 'utf8');
  assert.ok(markdown.startsWith('before\n### Timing of .timing/20261007T190000\n'), markdown);
});

test('main reports a run named on the command line, through latest too, and leaves the job summary alone without one', () => {
  const cwd = workdir();
  run(cwd, 'b-newer', line('x', 0, 1));
  run(cwd, 'a-older', line('check-spell', 0, 2000, 1), { reports: false });
  const stdout = sink();
  assert.equal(main(['.timing/a-older'], { cwd, env: {}, stdout, stderr: sink() }), 0);
  assert.equal(stdout.text, 'Timing of .timing/a-older: 2.0 s wall clock\n\nTargets\n  check-spell           2.0 s  100%  failed (exit 1)\n\nNo JUnit report in this run, so no test timings.\n');
  assert.equal(readlinkSync(path.join(cwd, '.timing', 'latest')), 'a-older');
  const again = sink();
  assert.equal(main(['.timing/latest'], { cwd, env: { GITHUB_STEP_SUMMARY: '' }, stdout: again, stderr: sink() }), 0);
  assert.equal(again.text, stdout.text);
  assert.equal(readlinkSync(path.join(cwd, '.timing', 'latest')), 'a-older');
});

test('main labels a run that is the working directory itself as .', () => {
  const cwd = workdir();
  writeFileSync(path.join(cwd, 'targets.jsonl'), line('a', 0, 1000));
  const stdout = sink();
  assert.equal(main([cwd], { cwd, env: {}, stdout, stderr: sink() }), 0);
  assert.match(stdout.text, /^Timing of \.: 1\.0 s wall clock/);
});

test('main refuses more than one argument', () => {
  const stderr = sink();
  assert.equal(main(['a', 'b'], { stderr }), 2);
  assert.equal(stderr.text, `::error::${USAGE}\n`);
});

test('main fails, saying why, with no .timing directory, a missing run, nothing timed or an empty record', () => {
  const cwd = workdir();
  const expect = (argv, message) => {
    const stderr = sink();
    assert.equal(main(argv, { cwd, env: {}, stdout: sink(), stderr }), 1, message);
    assert.equal(stderr.text, `::error::timing-report: ${message}\n`);
  };
  expect([], `no ${path.join(cwd, '.timing')} directory: run make check or make test first, which time themselves into it`);
  expect(['.timing/gone'], `no run directory ${path.join(cwd, '.timing', 'gone')}`);
  const untimed = run(cwd, 'untimed', null);
  expect(['.timing/untimed'], `${path.join(untimed, 'targets.jsonl')} does not exist: nothing in this run was timed`);
  const empty = run(cwd, 'empty', '\n');
  expect(['.timing/empty'], `${path.join(empty, 'targets.jsonl')} is empty: nothing in this run was timed`);
});

test('main fails naming a malformed targets.jsonl line or JUnit report', () => {
  const cwd = workdir();
  const lines = run(cwd, 'lines', `${line('a', 0, 1)}garbage\n`);
  const stderr = sink();
  assert.equal(main(['.timing/lines'], { cwd, env: {}, stdout: sink(), stderr }), 1);
  assert.match(stderr.text, new RegExp(`^::error::timing-report: ${path.join(lines, 'targets.jsonl')} line 2 is not JSON: `));

  const report = run(cwd, 'report', line('a', 0, 1));
  writeFileSync(path.join(report, 'broken.xml'), '');
  const again = sink();
  assert.equal(main(['.timing/report'], { cwd, env: {}, stdout: sink(), stderr: again }), 1);
  assert.equal(
    again.text,
    `::error::timing-report: ${path.join(report, 'broken.xml')} is not a JUnit report: it has no <testsuites> or <testsuite> element\n`,
  );
});

test('main fails when the job summary cannot be written', () => {
  const cwd = workdir();
  run(cwd, 'r', line('a', 0, 1));
  const stderr = sink();
  assert.equal(main([], { cwd, env: { GITHUB_STEP_SUMMARY: cwd }, stdout: sink(), stderr }), 1);
  assert.match(stderr.text, /^::error::timing-report: EISDIR/);
});

test('run as a program it prints the report of the newest run and exits 0', () => {
  const cwd = workdir();
  run(cwd, 'r', line('check-ci', 0, 1500));
  const env = { ...process.env };
  delete env.GITHUB_STEP_SUMMARY;
  const result = spawnSync(process.execPath, [SCRIPT], { cwd, encoding: 'utf8', env });
  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stdout, /^Timing of \.timing\/r: 1\.5 s wall clock\n/);
});

test('run as a program with too many arguments it exits 2 with its usage', () => {
  const result = spawnSync(process.execPath, [SCRIPT, 'a', 'b'], { encoding: 'utf8' });
  assert.equal(result.status, 2);
  assert.equal(result.stderr, `::error::${USAGE}\n`);
});

test('imported, it runs nothing', () => {
  const result = spawnSync(process.execPath, ['--input-type=module', '-e', `await import(${JSON.stringify(SCRIPT)});`], {
    encoding: 'utf8',
  });
  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.stdout, '');
  assert.equal(result.stderr, '');
});

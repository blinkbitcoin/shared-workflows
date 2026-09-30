import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { chmodSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';
import { annotation, ENGINE_OF, main, severityOf, summarize, verdict } from './lib/security-verdict.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));

const result = (severity, ruleId = 'r') => ({
  ruleId,
  level: severity === 'low' ? 'note' : severity === 'medium' ? 'warning' : 'error',
  message: { text: 'boom' },
  properties: {
    'security-severity': { critical: '9.0', high: '7.0', medium: '4.0', low: '1.0' }[severity],
  },
  locations: [
    { physicalLocation: { artifactLocation: { uri: 'f.ts' }, region: { startLine: 1 } } },
  ],
});

const doc = (tool, results, successful = true, rules = []) => ({
  version: '2.1.0',
  runs: [
    {
      tool: { driver: { name: tool, rules } },
      results,
      invocations: [{ executionSuccessful: successful }],
    },
  ],
});

const entry = (job, document) => ({ job, document });

test('severity comes from security-severity, then from level', () => {
  assert.equal(severityOf(result('critical')), 'critical');
  assert.equal(severityOf({ level: 'error' }), 'high');
  assert.equal(severityOf({ level: 'warning' }), 'medium');
  assert.equal(severityOf({ level: 'note' }), 'low');
  assert.equal(severityOf({}), 'medium');
  assert.equal(
    severityOf({ properties: { 'security-severity': 'not a number' }, level: 'note' }),
    'low',
  );
});

// osv-scanner (and CodeQL) put the CVSS score on the rule that fired, not on
// the result itself - every osv-scanner result is `level: warning` with no
// properties at all. A result with no severity of its own must fall back to
// its rule's, not to the level, or every finding grades medium regardless of
// how severe it actually is.
test('a result with no severity of its own falls back to its rule', () => {
  assert.equal(
    severityOf({ level: 'warning' }, { properties: { 'security-severity': '9.5' } }),
    'critical',
  );
  assert.equal(
    severityOf({ level: 'warning' }, { properties: { 'security-severity': '7.5' } }),
    'high',
  );
});

test("the result's own severity still wins over its rule's", () => {
  assert.equal(
    severityOf(
      { level: 'warning', properties: { 'security-severity': '9.5' } },
      { properties: { 'security-severity': '2.0' } },
    ),
    'critical',
  );
});

test('a result with neither its own nor a rule severity still falls back to level', () => {
  assert.equal(severityOf({ level: 'error' }, {}), 'high');
  assert.equal(severityOf({ level: 'error' }, undefined), 'high');
});

// The unit tests above call severityOf directly with a hand-built rule; this
// exercises the actual wiring - a SARIF document shaped exactly like
// osv-scanner's own output, with the score on tool.driver.rules[] and the
// result carrying only a ruleId - so a forgotten thread-through would fail
// here even if severityOf itself were correct.
test("summarize threads a run's rules through to grade results that carry no severity of their own", () => {
  const bare = { ruleId: 'CVE-2026-41907', level: 'warning', message: { text: 'boom' } };
  const s = summarize([
    entry(
      'dependencies',
      doc('osv-scanner', [bare], true, [
        { id: 'CVE-2026-41907', properties: { 'security-severity': '7.5' } },
      ]),
    ),
  ]);
  assert.deepEqual(s.counts, { critical: 0, high: 1, medium: 0, low: 0 });
});

test('every job maps to an engine class', () => {
  assert.equal(ENGINE_OF.dependencies, 'deterministic');
  assert.equal(ENGINE_OF.binaries, 'deterministic');
  assert.equal(ENGINE_OF.review, 'review');
  assert.equal(ENGINE_OF['review-codebase'], 'openant');
});

test('counts, highest severity and skipped jobs', () => {
  const s = summarize([
    entry('dependencies', doc('osv-scanner', [result('high'), result('low')])),
    entry('code', doc('semgrep', [], false)),
  ]);
  assert.deepEqual(s.counts, { critical: 0, high: 1, medium: 0, low: 1 });
  assert.equal(s.highest, 'high');
  assert.deepEqual(s.skipped, ['code']);
});

test('a finding at the threshold from a fail-on engine fails', () => {
  const v = verdict({
    entries: [entry('dependencies', doc('osv-scanner', [result('high')]))],
    severity: 'high',
    failOn: ['deterministic'],
  });
  assert.equal(v.verdict, 'fail');
  assert.equal(v.exitCode, 1);
});

test('the same finding below the threshold passes', () => {
  const v = verdict({
    entries: [entry('dependencies', doc('osv-scanner', [result('medium')]))],
    severity: 'high',
    failOn: ['deterministic'],
  });
  assert.equal(v.verdict, 'pass');
  assert.equal(v.exitCode, 0);
});

test('a finding from an engine that is not in fail-on is informational', () => {
  const v = verdict({
    entries: [entry('review', doc('review', [result('critical')]))],
    severity: 'high',
    failOn: ['deterministic'],
  });
  assert.equal(v.verdict, 'informational');
  assert.equal(v.exitCode, 0);
});

test('severity none never fails', () => {
  const v = verdict({
    entries: [entry('dependencies', doc('osv-scanner', [result('critical')]))],
    severity: 'none',
    failOn: ['deterministic'],
  });
  assert.equal(v.verdict, 'informational');
  assert.equal(v.exitCode, 0);
});

test('an unrecognized severity throws rather than behaving like none', () => {
  assert.throws(
    () =>
      verdict({
        entries: [entry('dependencies', doc('osv-scanner', [result('critical')]))],
        severity: 'bogus',
        failOn: ['deterministic'],
      }),
    /severity: expected one of none, low, medium, high, critical, got "bogus"/,
  );
});

// settings.mjs's parseList accepts any comma-separated string, so a dropped
// letter (SECURITY_FAIL_ON=deterministc) or a stray value never reaches
// ENGINE_CLASSES - failOn.includes(...) just quietly never matches, every
// finding reads as informational, and nothing can ever block, however
// severe. Same fail-open class as the unrecognized-severity case above,
// same fix: throw, naming the bad value, rather than silently disarming
// the gate.
test('an unrecognized failOn entry throws rather than silently disarming the gate', () => {
  assert.throws(
    () =>
      verdict({
        entries: [entry('dependencies', doc('osv-scanner', [result('high')]))],
        severity: 'high',
        failOn: ['deterministc'],
      }),
    /failOn: unrecognized engine class "deterministc", expected one of/,
  );
});

test('every failOn entry must be a known engine class, not just the first', () => {
  assert.throws(
    () =>
      verdict({
        entries: [entry('dependencies', doc('osv-scanner', [result('high')]))],
        severity: 'high',
        failOn: ['deterministic', 'not-a-class'],
      }),
    /failOn: unrecognized engine class "not-a-class"/,
  );
});

// An empty failOn is a legitimate choice - a consumer who wants every
// scanner advisory-only - but it must never look like an ordinary pass: a
// high finding is still found and still printed, it is simply guaranteed
// never to block, and that has to be visible on the one line most likely to
// be the only one read.
test('an empty failOn is allowed, but never blocks, and says so in the summary', () => {
  const v = verdict({
    entries: [entry('dependencies', doc('osv-scanner', [result('critical')]))],
    severity: 'high',
    failOn: [],
  });
  assert.equal(v.exitCode, 0);
  assert.equal(v.verdict, 'informational');
  assert.ok(v.lines.some((line) => /failOn is empty: nothing can block/.test(line)));
});

test('a non-empty failOn carries no such note', () => {
  const v = verdict({
    entries: [entry('dependencies', doc('osv-scanner', [result('critical')]))],
    severity: 'high',
    failOn: ['deterministic'],
  });
  assert.ok(!v.lines.some((line) => /failOn is empty/.test(line)));
});

// A SARIF file whose basename is not a known job (e.g. a future job renamed
// without updating ENGINE_OF, or a stray file dropped into the output
// directory) must never be silently unblockable. Before this test existed,
// `failOn.includes(ENGINE_OF[f.job])` evaluated to `failOn.includes(undefined)`
// - always false - so a critical finding from such a file printed as merely
// "informational" and exited 0, no matter how severe.
test('a SARIF from an unrecognized job fails loudly rather than becoming unblockable', () => {
  assert.throws(
    () =>
      verdict({
        entries: [entry('mobile-android', doc('some-scanner', [result('critical')]))],
        severity: 'high',
        failOn: ['deterministic'],
      }),
    /mobile-android\.sarif: unrecognized job "mobile-android"/,
  );
});

test('a suppressed result is not a finding, but is visible as suppressed, not absent', () => {
  const suppressed = { ...result('critical'), suppressions: [{ kind: 'inSource' }] };
  const v = verdict({
    entries: [entry('dependencies', doc('osv-scanner', [suppressed]))],
    severity: 'high',
    failOn: ['deterministic'],
  });
  assert.equal(v.verdict, 'pass');
  assert.equal(v.counts.critical, 0);
  // Dropping a suppressed result from counts and findings is correct - it must
  // never block - but dropping it with no trace at all makes a deliberate
  // suppression indistinguishable from a vulnerability that was never found.
  assert.equal(v.suppressed, 1);
  assert.ok(v.lines.some((line) => /1 suppressed/.test(line)));
});

test('summarize counts suppressed results across documents and jobs', () => {
  const suppressedOnce = { ...result('high'), suppressions: [{ kind: 'inSource' }] };
  const suppressedTwice = { ...result('low', 'other-rule'), suppressions: [{ kind: 'external' }] };
  const s = summarize([
    entry('dependencies', doc('osv-scanner', [suppressedOnce])),
    entry('code', doc('semgrep', [suppressedTwice, result('medium')])),
  ]);
  assert.equal(s.suppressed, 2);
  // The one unsuppressed result still counts normally.
  assert.deepEqual(s.counts, { critical: 0, high: 0, medium: 1, low: 0 });
});

test('the summary names skipped jobs so they are never read as clean', () => {
  const v = verdict({
    entries: [entry('code', doc('semgrep', [], false))],
    severity: 'high',
    failOn: ['deterministic'],
  });
  assert.ok(v.lines.some((line) => /code: skipped/.test(line)));
  assert.ok(!v.lines.some((line) => /code: clean/.test(line)));
});

test('a job that ran and found nothing is clean', () => {
  const v = verdict({
    entries: [entry('dependencies', doc('osv-scanner', []))],
    severity: 'high',
    failOn: ['deterministic'],
  });
  assert.ok(v.lines.some((line) => /dependencies: clean/.test(line)));
});

// On a laptop missing osv-scanner and semgrep, both jobs skip and only the
// policy scanner runs clean - zero findings either way. Before this test
// existed the headline still read "security: pass", the exact word a human
// or an agent greps for to decide nothing needs attention, even though most
// of the gate never ran. The exit code must still be 0: nothing ran, so
// nothing blocks - only the word changes.
test('a run with zero findings is "skipped", not "pass", when any job skipped', () => {
  const allSkipped = verdict({
    entries: [
      entry('dependencies', doc('osv-scanner', [], false)),
      entry('code', doc('semgrep', [], false)),
    ],
    severity: 'high',
    failOn: ['deterministic'],
  });
  assert.equal(allSkipped.verdict, 'skipped');
  assert.equal(allSkipped.exitCode, 0);
  assert.ok(allSkipped.lines.some((line) => /^security: skipped, /.test(line)));

  const oneSkippedOneClean = verdict({
    entries: [
      entry('dependencies', doc('osv-scanner', [], false)),
      entry('policy', doc('policy', [])),
    ],
    severity: 'high',
    failOn: ['deterministic'],
  });
  assert.equal(oneSkippedOneClean.verdict, 'skipped');
  assert.equal(oneSkippedOneClean.exitCode, 0);
});

test('a run with zero findings and nothing skipped is still "pass"', () => {
  const v = verdict({
    entries: [entry('dependencies', doc('osv-scanner', []))],
    severity: 'high',
    failOn: ['deterministic'],
  });
  assert.equal(v.verdict, 'pass');
});

test('the CLI prints the summary and returns the exit code', () => {
  const out = [];
  const readEntries = () => [entry('dependencies', doc('osv-scanner', [result('critical')]))];
  const code = main(['.security'], {
    log: (l) => out.push(l),
    error: () => {},
    env: {},
    readEntries,
    writeVerdict: () => {},
  });
  assert.equal(code, 1);
  assert.ok(out.some((line) => /security: fail/.test(line)));
});

test('a missing directory exits 2 with advice', () => {
  const out = [];
  const readEntries = () => {
    throw new Error('ENOENT');
  };
  assert.equal(main([], { log: () => {}, error: (l) => out.push(l), env: {}, readEntries }), 2);
  assert.match(out[0], /run a scanner first/);
});

// Every test above injects readEntries, which never exercises the module's
// own directory reader - the function that lists *.sarif files and parses
// them, and the path every real run takes. This writes real SARIF files to a
// temporary directory and calls main() without injecting readEntries, so the
// 100% coverage gate has to mean what it says.
test('the real directory reader lists *.sarif files and parses them', () => {
  const dir = mkdtempSync(path.join(tmpdir(), 'verdict-read-'));
  try {
    writeFileSync(
      path.join(dir, 'dependencies.sarif'),
      JSON.stringify(doc('osv-scanner', [result('critical')])),
    );
    writeFileSync(path.join(dir, 'code.sarif'), JSON.stringify(doc('semgrep', [], false)));
    writeFileSync(path.join(dir, 'notes.txt'), 'not a sarif file');
    const out = [];
    const code = main([dir], {
      log: (l) => out.push(l),
      error: () => {},
      env: { SECURITY_SEVERITY: 'high', SECURITY_FAIL_ON: 'deterministic' },
    });
    assert.equal(code, 1);
    assert.ok(out.some((line) => /dependencies: 1 finding\(s\)/.test(line)));
    assert.ok(out.some((line) => /code: skipped/.test(line)));
    assert.ok(out.some((line) => /security: fail/.test(line)));
    assert.deepEqual(JSON.parse(readFileSync(path.join(dir, 'verdict.json'), 'utf8')), {
      verdict: 'fail',
      highest: 'critical',
      canBlock: true,
    });
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

// A directory that does not exist and a directory that exists but holds a
// malformed SARIF file are different problems - "run a scanner first" sends
// someone looking for a scanner that never ran, when the real issue is one
// bad file sitting right there. This exercises the module's own reader (no
// injected readEntries), so the distinction has to survive the real
// readdirSync/readFileSync/JSON.parse path, not just a mocked one.
test('a malformed SARIF file names itself, distinct from a missing directory', () => {
  const missing = [];
  // Inside a private temporary directory, not a fixed name in the shared one:
  // main() now writes verdict.json into the directory it is given, and a
  // predictable path under os.tmpdir() is one another user could create first
  // (CodeQL js/insecure-temporary-file).
  const parent = mkdtempSync(path.join(tmpdir(), 'verdict-missing-'));
  try {
    assert.equal(
      main([path.join(parent, 'does-not-exist')], {
        log: () => {},
        error: (l) => missing.push(l),
        env: {},
      }),
      2,
    );
  } finally {
    rmSync(parent, { recursive: true, force: true });
  }
  assert.match(missing[0], /run a scanner first/);

  const dir = mkdtempSync(path.join(tmpdir(), 'verdict-malformed-'));
  try {
    writeFileSync(path.join(dir, 'code.sarif'), '{ not valid json');
    const out = [];
    const code = main([dir], { log: () => {}, error: (l) => out.push(l), env: {} });
    assert.equal(code, 2);
    assert.match(out[0], /code\.sarif: not valid JSON/);
    assert.doesNotMatch(out[0], /run a scanner first/);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

// A file readFileSync cannot open at all (permissions, a dangling symlink)
// and a file that opens fine but is not valid JSON are different problems -
// conflating them, as an earlier version of read() did by wrapping both in
// one try, sent "not valid JSON" for a permission error that has nothing to
// do with JSON. Root bypasses file-mode permission checks entirely, so this
// skips rather than false-passing when the test runs as root (some CI
// containers do).
test('an unreadable SARIF file names itself, distinct from a malformed one', (t) => {
  if (process.getuid?.() === 0) {
    t.skip('running as root: file-mode permissions are not enforced');
    return;
  }
  const dir = mkdtempSync(path.join(tmpdir(), 'verdict-unreadable-'));
  const file = path.join(dir, 'code.sarif');
  try {
    writeFileSync(file, JSON.stringify(doc('semgrep', [])));
    chmodSync(file, 0o000);
    const out = [];
    const code = main([dir], { log: () => {}, error: (l) => out.push(l), env: {} });
    assert.equal(code, 2);
    assert.match(out[0], /code\.sarif: could not be read/);
    assert.doesNotMatch(out[0], /not valid JSON/);
  } finally {
    chmodSync(file, 0o644);
    rmSync(dir, { recursive: true, force: true });
  }
});

// The functions below read SARIF fields defensively (`?? []`) because the
// spec makes several of them optional, and this module reads whatever a
// scanner wrote, not only what sarif.mjs produces. The tests above never
// exercise those fallbacks - every document, run and result they build is
// fully populated - so these fill in the malformed-but-spec-legal shapes:
// a document with no runs, a run with no results or invocations, and a
// result with no ruleId or message.

test('a document with no runs at all counts nothing and is not skipped', () => {
  const s = summarize([entry('dependencies', {})]);
  assert.deepEqual(s.counts, { critical: 0, high: 0, medium: 0, low: 0 });
  assert.deepEqual(s.skipped, []);
});

test('a run with no results and no invocations is clean, not skipped', () => {
  const s = summarize([entry('dependencies', { runs: [{}] })]);
  assert.deepEqual(s.counts, { critical: 0, high: 0, medium: 0, low: 0 });
  assert.deepEqual(s.skipped, []);
});

test('a finding with no ruleId or message text still gets recorded, with placeholders', () => {
  const bare = { level: 'note', locations: [] };
  const s = summarize([entry('dependencies', doc('tool', [bare]))]);
  assert.equal(s.findings[0].ruleId, '<no rule>');
  assert.equal(s.findings[0].message, '');
});

// The shape sarif.mjs's skipped() actually produces: an executionSuccessful:
// false invocation carrying a toolExecutionNotifications note. Only this
// shape exercises the code that reads the reason out of it - the tests
// above only ever see a skipped run with no notification at all, which
// takes the 'no reason given' fallback instead.
const skippedWithReason = (tool, reason) => ({
  version: '2.1.0',
  runs: [
    {
      tool: { driver: { name: tool } },
      results: [],
      invocations: [
        {
          executionSuccessful: false,
          toolExecutionNotifications: [{ level: 'note', message: { text: `skipped: ${reason}` } }],
        },
      ],
    },
  ],
});

test('a skipped job with a reported reason uses that reason in the summary', () => {
  const v = verdict({
    entries: [entry('code', skippedWithReason('semgrep', 'not installed'))],
    severity: 'high',
    failOn: ['deterministic'],
  });
  assert.ok(v.lines.includes('code: skipped: not installed'));
});

// A SARIF document may carry more than one run, and per spec only
// invocations is optional per run - so a run that never reports invocations
// at all can sit next to one that does. That run's `run.invocations ?? []`
// fallback only fires while the job is still read as skipped, which needs
// another run in the same document to report the failure.
test('a skipped job with a run that reports no invocations at all still finds the reason', () => {
  const document = {
    version: '2.1.0',
    runs: [
      { tool: { driver: { name: 'first' } }, results: [] },
      {
        tool: { driver: { name: 'second' } },
        results: [],
        invocations: [
          {
            executionSuccessful: false,
            toolExecutionNotifications: [
              { level: 'note', message: { text: 'skipped: no key configured' } },
            ],
          },
        ],
      },
    ],
  };
  const v = verdict({
    entries: [entry('review', document)],
    severity: 'high',
    failOn: ['deterministic'],
  });
  assert.ok(v.lines.includes('review: skipped: no key configured'));
});

// import.meta.main only runs when the file is its own entry point - never
// when it is merely imported under `node --test`. Spawn it as a child
// process, the way settings.test.mjs and codeql-findings.test.mjs both do, so
// that arm is actually covered rather than assumed.
test('as a command it reads *.sarif files from the directory named on the command line', () => {
  const script = path.join(here, 'lib', 'security-verdict.mjs');
  const dir = mkdtempSync(path.join(tmpdir(), 'verdict-cli-'));
  try {
    writeFileSync(
      path.join(dir, 'dependencies.sarif'),
      JSON.stringify(doc('osv-scanner', [result('critical')])),
    );
    // The inherited environment keeps NODE_V8_COVERAGE, so the child counts,
    // and it also runs the file as the entry point rather than an import, so
    // `import.meta.main` is true here the way it never is under `node --test`.
    // SECURITY_SEVERITY/SECURITY_FAIL_ON are pinned so the result cannot
    // change because a developer or runner happens to have one exported.
    const childEnv = {
      ...process.env,
      SECURITY_SEVERITY: 'high',
      SECURITY_FAIL_ON: 'deterministic',
    };
    const run = (...args) =>
      spawnSync(process.execPath, [script, ...args], { encoding: 'utf8', env: childEnv });
    const found = run(dir);
    assert.equal(found.status, 1);
    assert.match(found.stdout, /security: fail/);

    const missing = run(path.join(dir, 'nonexistent'));
    assert.equal(missing.status, 2);
    assert.match(missing.stderr, /run a scanner first/);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

// check-security.yml uploads SARIF from the default branch only, so on a pull
// request code scanning no longer puts a finding on the diff. These workflow
// commands do instead: an error for a finding that blocks, a warning for one
// that is only reported, nothing below the severity floor.
test('a blocking finding annotates as an error and a reported one as a warning', () => {
  const v = verdict({
    entries: [
      entry('dependencies', doc('osv-scanner', [result('critical', 'GHSA-1')])),
      entry('review', doc('review', [result('high', 'llm/1')])),
      entry('code', doc('semgrep', [result('low', 'minor')])),
    ],
    severity: 'medium',
    failOn: ['deterministic'],
  });
  assert.deepEqual(v.annotations, [
    '::error file=f.ts,line=1,title=Security critical%3A GHSA-1::boom',
    '::warning file=f.ts,line=1,title=Security high%3A llm/1::boom',
  ]);
});

test('an annotation escapes what would end its properties or its message', () => {
  const line = annotation('warning', {
    severity: 'medium',
    ruleId: 'a:b,c',
    message: '50%\r\nnext',
    file: 'dir,x/y:z.ts',
    line: 7,
  });
  assert.equal(
    line,
    '::warning file=dir%2Cx/y%3Az.ts,line=7,title=Security medium%3A a%3Ab%2Cc::50%25%0D%0Anext',
  );
});

test('an annotation without a location, or a message, still names the rule', () => {
  assert.equal(
    annotation('error', { severity: 'high', ruleId: 'r', message: '' }),
    '::error title=Security high%3A r::r',
  );
  assert.equal(
    annotation('error', { severity: 'high', ruleId: 'r', message: 'm', file: 'a.ts' }),
    '::error file=a.ts,title=Security high%3A r::m',
  );
});

test('the CLI prints annotations on a runner only', () => {
  const run = (env) => {
    const out = [];
    main(['.security'], {
      log: (l) => out.push(l),
      error: () => {},
      env,
      readEntries: () => [entry('dependencies', doc('osv-scanner', [result('critical')]))],
      writeVerdict: () => {},
    });
    return out.filter((line) => line.startsWith('::'));
  };
  assert.deepEqual(run({ GITHUB_ACTIONS: 'true' }), [
    '::error file=f.ts,line=1,title=Security critical%3A r::boom',
  ]);
  assert.deepEqual(run({}), []);
});

test('canBlock says whether anything in this run could have failed it', () => {
  const entries = [entry('dependencies', doc('osv-scanner', []))];
  assert.equal(verdict({ entries, severity: 'high', failOn: ['deterministic'] }).canBlock, true);
  assert.equal(verdict({ entries, severity: 'high', failOn: [] }).canBlock, false);
  assert.equal(verdict({ entries, severity: 'none', failOn: ['deterministic'] }).canBlock, false);
});

test('the CLI hands the verdict file its word, highest severity and canBlock', () => {
  const written = [];
  const code = main(['.security'], {
    log: () => {},
    error: () => {},
    env: { SECURITY_SEVERITY: 'high', SECURITY_FAIL_ON: 'deterministic' },
    readEntries: () => [entry('dependencies', doc('osv-scanner', [result('critical')]))],
    writeVerdict: (dir, outcome) => written.push({ dir, outcome }),
  });
  assert.equal(code, 1);
  assert.equal(written.length, 1);
  assert.equal(written[0].dir, '.security');
  assert.equal(written[0].outcome.verdict, 'fail');
  assert.equal(written[0].outcome.highest, 'critical');
  assert.equal(written[0].outcome.canBlock, true);
});

test('a verdict file that cannot be written exits 2 and names the file', () => {
  const out = [];
  const code = main(['.security'], {
    log: () => {},
    error: (l) => out.push(l),
    env: {},
    readEntries: () => [entry('dependencies', doc('osv-scanner', []))],
    writeVerdict: () => {
      throw new Error('EROFS');
    },
  });
  assert.equal(code, 2);
  assert.match(out[0], /verdict\.json: could not be written \(EROFS\)/);
});

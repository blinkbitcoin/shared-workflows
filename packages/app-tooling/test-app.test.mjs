import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { existsSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';
import { ConfigError } from './lib/config.mjs';
import { main, parseArgs, plan, runSuites, SUITES_DIR } from './bin/test-app.mjs';
import { SUITES } from './suites/index.mjs';

const BIN = fileURLToPath(new URL('./bin/test-app.mjs', import.meta.url));

const suites = {
  beta: { file: 'beta.suite.mjs', stacks: ['expo', 'bare'], needs: [] },
  alpha: { file: 'alpha.suite.mjs', stacks: ['expo'], needs: ['alpha.config.js'] },
};

test('every registered suite has its file beside the registry, a stack and a list of needs', () => {
  const names = Object.keys(SUITES);
  assert.ok(names.length > 0);
  for (const name of names) {
    const { file, stacks, needs } = SUITES[name];
    assert.equal(file, `${name}.suite.mjs`);
    assert.ok(existsSync(path.join(SUITES_DIR, file)), file);
    assert.ok(stacks.length > 0 && stacks.every((stack) => ['expo', 'bare'].includes(stack)), name);
    assert.ok(Array.isArray(needs), name);
  }
});

test('parseArgs takes --root, each --suite and --list, and refuses anything else', () => {
  assert.deepEqual(parseArgs([], '/w'), { root: '/w', only: [], list: false });
  assert.deepEqual(parseArgs(['--list', '--root', 'app', '--suite', 'a', '--suite', 'b'], '/w'), {
    root: path.resolve('/w', 'app'),
    only: ['a', 'b'],
    list: true,
  });
  assert.throws(() => parseArgs(['--suite'], '/w'), /^Error: unexpected --suite: pass --root DIR, --suite NAME \(repeatable\) and --list$/);
  assert.throws(() => parseArgs(['--root'], '/w'), /unexpected --root:/);
  assert.throws(() => parseArgs(['--nope', 'x'], '/w'), /unexpected --nope x:/);
});

test('plan runs, in name order, each suite for this stack whose files are there', () => {
  assert.deepEqual(plan({ suites, stack: 'expo', exists: () => true }), [
    { name: 'alpha', run: true, file: path.join(SUITES_DIR, 'alpha.suite.mjs') },
    { name: 'beta', run: true, file: path.join(SUITES_DIR, 'beta.suite.mjs') },
  ]);
});

test('plan gives the reason for each suite it skips', () => {
  assert.deepEqual(plan({ suites, stack: 'bare', exists: () => true })[0], {
    name: 'alpha',
    run: false,
    reason: 'a bare app (it is for expo)',
  });
  const asked = [];
  const missing = plan({ suites, stack: 'expo', exists: (file) => asked.push(file) && false });
  assert.deepEqual(missing[0], { name: 'alpha', run: false, reason: 'no alpha.config.js' });
  assert.deepEqual(asked, ['alpha.config.js']);
  assert.deepEqual(plan({ suites, stack: 'expo', exists: () => true, skip: { beta: 'notes are written by hand' } })[1], {
    name: 'beta',
    run: false,
    reason: 'turned off in app-tooling.json: notes are written by hand',
  });
});

test('plan narrows to the suites asked for, and refuses a name that is not one', () => {
  assert.deepEqual(
    plan({ suites, stack: 'expo', exists: () => true, only: ['beta'] }).map((step) => step.name),
    ['beta'],
  );
  assert.throws(() => plan({ suites, stack: 'expo', exists: () => true, only: ['beta', 'gamma'] }), {
    message: 'no suite named gamma; the suites are alpha, beta',
  });
});

test('plan refuses a skip for a suite that does not exist, as a configuration error', () => {
  assert.throws(
    () => plan({ suites, stack: 'expo', exists: () => true, skip: { gama: 'typo' } }),
    (e) => e instanceof ConfigError && e.message === 'app-tooling.json: appSuites.skip names gama, which is not a suite; the suites are alpha, beta',
  );
});

test('runSuites runs node --test with the spec reporter from the app, with APP_ROOT and without the parent test context', (t) => {
  const calls = [];
  const before = process.env.NODE_TEST_CONTEXT;
  t.after(() => {
    if (before === undefined) delete process.env.NODE_TEST_CONTEXT;
    else process.env.NODE_TEST_CONTEXT = before;
  });
  process.env.NODE_TEST_CONTEXT = 'child-v8';
  const status = runSuites(['/s/a.suite.mjs'], '/app', (command, args, options) => {
    calls.push({ command, args, options });
    return { status: 3 };
  });
  assert.equal(status, 3);
  const [{ command, args, options }] = calls;
  assert.equal(command, process.execPath);
  assert.deepEqual(args, ['--test', '--test-reporter=spec', '/s/a.suite.mjs']);
  assert.equal(options.cwd, '/app');
  assert.equal(options.stdio, 'inherit');
  assert.equal(options.env.APP_ROOT, '/app');
  assert.equal('NODE_TEST_CONTEXT' in options.env, false);
  assert.equal(runSuites([], '/app', () => ({ status: null })), 1, 'a run killed by a signal is a failure');
});

/** A throwaway repository: `files` maps a relative path to its text. */
const repository = (t, files = {}) => {
  const root = mkdtempSync(path.join(tmpdir(), 'test-app-'));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  for (const [file, text] of Object.entries(files)) {
    mkdirSync(path.dirname(path.join(root, file)), { recursive: true });
    writeFileSync(path.join(root, file), text);
  }
  return root;
};

const expoApp = { 'package.json': '{"dependencies":{"expo":"*"}}', 'alpha.config.js': '' };

/** Runs main against `root` with the fake suites, recording what it would run. */
const capture = (root, argv = []) => {
  const out = [];
  const err = [];
  const ran = [];
  const code = main(['--root', root, ...argv], {
    cwd: '/elsewhere',
    suites,
    run: (files, appRoot) => {
      ran.push({ files, appRoot });
      return 5;
    },
    log: (line) => out.push(line),
    error: (line) => err.push(line),
  });
  return { code, out, err, ran };
};

test('main prints a line per suite, runs those that apply from the app root, and exits with their status', (t) => {
  const root = repository(t, expoApp);
  const { code, out, err, ran } = capture(root);
  assert.equal(code, 5);
  assert.deepEqual(out, ['run alpha', 'run beta']);
  assert.deepEqual(err, []);
  assert.deepEqual(ran, [{ files: [path.join(SUITES_DIR, 'alpha.suite.mjs'), path.join(SUITES_DIR, 'beta.suite.mjs')], appRoot: root }]);
});

test('main finds the app under the working-directory its callers pass', (t) => {
  const root = repository(t, {
    '.github/workflows/ci.yml': 'jobs:\n  check:\n    uses: blinkbitcoin/shared-workflows/.github/workflows/check.yml@v0\n    with:\n      working-directory: app\n',
    'app/package.json': '{"dependencies":{"expo":"*"}}',
    'app/alpha.config.js': '',
  });
  assert.equal(capture(root).ran[0].appRoot, path.join(root, 'app'));
});

test('main reads the skips from app-tooling.json, and --list prints the plan without running it', (t) => {
  const root = repository(t, { ...expoApp, 'app-tooling.json': '{"appSuites":{"skip":{"alpha":"covered elsewhere"}}}' });
  const { code, out, ran } = capture(root, ['--list']);
  assert.deepEqual({ code, out, ran }, {
    code: 0,
    out: ['skip alpha: turned off in app-tooling.json: covered elsewhere', 'run beta'],
    ran: [],
  });
});

test('main passes, saying so, when no suite applies', (t) => {
  const root = repository(t, { 'package.json': '{}' });
  const { code, out, ran } = capture(root, ['--suite', 'alpha']);
  assert.deepEqual({ code, out, ran }, { code: 0, out: ['skip alpha: a bare app (it is for expo)', 'app suites: none applies to this app'], ran: [] });
});

test('main exits 2 on a configuration that is wrong, and 1 on a bad argument, an unknown suite or an unreadable app', (t) => {
  const badSection = capture(repository(t, { ...expoApp, 'app-tooling.json': '{"appSuites":{"skip":["alpha"]}}' }));
  assert.deepEqual(badSection, { code: 2, out: [], err: ['app suites: app-tooling.json: "appSuites.skip" must be an object of non-empty strings'], ran: [] });
  assert.equal(capture(repository(t, { ...expoApp, 'app-tooling.json': '{"appSuites":{"skip":{"x":"y"}}}' })).code, 2);
  assert.equal(capture(repository(t, expoApp), ['--nope']).err[0], 'app suites: unexpected --nope: pass --root DIR, --suite NAME (repeatable) and --list');
  assert.deepEqual(capture(repository(t, expoApp), ['--suite', 'gamma']).err, ['app suites: no suite named gamma; the suites are alpha, beta']);
  const unreadable = capture(repository(t, { 'package.json': '{' }));
  assert.equal(unreadable.code, 1);
  assert.match(unreadable.err[0], /^app suites: ::error::.*package\.json is not valid JSON/);
});

test('as a command it lists the real suites for the repository it is pointed at', (t) => {
  const root = repository(t, { 'package.json': '{}' });
  const result = spawnSync(process.execPath, [BIN, '--root', root, '--list'], { encoding: 'utf8' });
  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.stdout, 'skip fingerprint: a bare app (it is for expo)\nskip store-notes: no store-notes.prompt.md\n');
});

test('main answers --help with its usage on stdout and exit 0, before anything else', async () => {
  const out = [];
  const err = [];
  const code = await main(['--help'], { log: (line) => out.push(line), error: (line) => err.push(line), run: () => assert.fail('--help ran something') });
  assert.equal(code, 0);
  assert.match(out.join(''), /^ +test-app(?: |$)/m);
  assert.deepEqual(err, []);
});

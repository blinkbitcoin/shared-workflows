import assert from 'node:assert/strict';
import { execFileSync, spawnSync } from 'node:child_process';
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { after, test } from 'node:test';
import { fileURLToPath } from 'node:url';
import { coveredFiles, main, nodeArguments, scriptModules } from './bin/test-scripts.mjs';

const BIN = fileURLToPath(new URL('./bin/test-scripts.mjs', import.meta.url));
const work = mkdtempSync(path.join(tmpdir(), 'test-scripts-'));
after(() => rmSync(work, { recursive: true, force: true }));
const CONFIG = { sources: ['scripts/**/*.mjs'], tests: ['scripts/**/*.test.mjs'] };

test('the modules are the sources less the tests, sorted, once each', () => {
  const glob = (_root, pattern) => (pattern === 'scripts/**/*.test.mjs' ? ['scripts/b.test.mjs'] : ['scripts/b.mjs', 'scripts/b.test.mjs', 'scripts/a.mjs']);
  assert.deepEqual(scriptModules('/r', { sources: ['scripts/**/*.mjs', 'scripts/*.mjs'], tests: ['scripts/**/*.test.mjs'] }, glob), ['scripts/a.mjs', 'scripts/b.mjs']);
});

test('the covered files are the SF lines of an lcov report, relative to the root', () => {
  const lcov = 'TN:\nSF:/r/scripts/a.mjs\nFNF:1\nend_of_record\nSF:/r/scripts/sub/b.mjs \nend_of_record\n';
  assert.deepEqual([...coveredFiles(lcov, '/r')], ['scripts/a.mjs', 'scripts/sub/b.mjs']);
  assert.deepEqual([...coveredFiles('SF:scripts/a.mjs\nSF:./scripts/c.mjs\n', '/r')], ['scripts/a.mjs', 'scripts/c.mjs'], 'relative to the root, as an outer test runner reports them');
  assert.deepEqual([...coveredFiles('', '/r')], []);
});

test('node is told the 100% gates, the coverage sources, both reporters and the tests', () => {
  assert.deepEqual(nodeArguments({ sources: ['a/**/*.mjs', 'b/*.mjs'], tests: ['a/**/*.test.mjs'] }, '/tmp/lcov.info'), [
    '--test',
    '--experimental-test-coverage',
    '--test-coverage-lines=100',
    '--test-coverage-branches=100',
    '--test-coverage-functions=100',
    '--test-coverage-include=a/**/*.mjs',
    '--test-coverage-include=b/*.mjs',
    '--test-reporter=spec',
    '--test-reporter-destination=stdout',
    '--test-reporter=lcov',
    '--test-reporter-destination=/tmp/lcov.info',
    'a/**/*.test.mjs',
  ]);
});

function run(argv, { config = null, siblings = 0, result = { status: 0 }, lcov = 'SF:/app/scripts/a.mjs\nend_of_record\n', modules = ['scripts/a.mjs'] } = {}) {
  const out = { log: [], error: [], ran: [], removed: [], siblings: [] };
  const code = main(argv, {
    cwd: '/app',
    read: (file) => {
      if (file === '/app/app-tooling.json') return config;
      if (file.endsWith('lcov.info')) return lcov;
      return null;
    },
    glob: (_root, pattern) => (pattern.endsWith('.test.mjs') ? [] : modules),
    checkSiblings: (args) => {
      out.siblings.push(args);
      return siblings;
    },
    makeTemp: () => '/tmp/ts',
    remove: (directory) => out.removed.push(directory),
    run: (command, args, options) => {
      out.ran.push([command, args, options]);
      return result;
    },
    log: (line) => out.log.push(line),
    error: (line) => out.error.push(line),
  });
  return { code, ...out };
}

test('with every module covered it runs the siblings check, then node, and passes', () => {
  const result = run([]);
  assert.equal(result.code, 0);
  assert.deepEqual(result.siblings, [['--root', '/app']]);
  assert.equal(result.ran[0][0], process.execPath);
  assert.deepEqual(result.ran[0][1], nodeArguments(CONFIG, '/tmp/ts/lcov.info'));
  assert.deepEqual(result.ran[0][2], { cwd: '/app' });
  assert.deepEqual(result.log, ['script tests ok (1 modules at 100%)']);
  assert.deepEqual(result.removed, ['/tmp/ts']);
});

test('a missing sibling test stops the run before any test, with the sibling check\'s own exit code', () => {
  const result = run([], { siblings: 1 });
  assert.equal(result.code, 1);
  assert.deepEqual(result.ran, []);
  assert.deepEqual(result.removed, [], 'nothing was created');
});

test('node failing, on a test or on the coverage gate, is its own exit status; a signal or a failure to start is 1', () => {
  assert.equal(run([], { result: { status: 1 } }).code, 1);
  assert.equal(run([], { result: { status: 7 } }).code, 7);
  assert.equal(run([], { result: { status: null } }).code, 1);
  const broken = run([], { result: { status: null, error: new Error('spawn ENOENT') } });
  assert.equal(broken.code, 1);
  assert.deepEqual(broken.error, ['test-scripts: could not run node: spawn ENOENT']);
  assert.deepEqual(broken.removed, ['/tmp/ts']);
});

test('a module no test loaded is named, because the coverage report cannot show what it never saw', () => {
  const result = run([], { modules: ['scripts/a.mjs', 'scripts/orphan.mjs'] });
  assert.equal(result.code, 1);
  assert.equal(result.error[0], 'scripts/orphan.mjs: no test loaded it, so the coverage report does not contain it');
  assert.match(result.error[1], /^test-scripts: 1 script module\(s\) are not covered at all\./);
  assert.equal(run([], { lcov: null, modules: ['scripts/a.mjs'] }).code, 1, 'no report at all is every module missing');
});

test('the sources and tests come from the configuration, and a bad configuration or no module exits 2', () => {
  const configured = run([], { config: '{"testScripts":{"sources":["tools/**/*.mjs"],"tests":["tools/**/*.test.mjs"]}}', lcov: 'SF:/app/tools/a.mjs\n', modules: ['tools/a.mjs'] });
  assert.equal(configured.code, 0);
  assert.ok(configured.ran[0][1].includes('--test-coverage-include=tools/**/*.mjs'));
  const wrong = run([], { config: '{"testScripts":{"sources":[]}}' });
  assert.equal(wrong.code, 2);
  assert.match(wrong.error[0], /^test-scripts: app-tooling\.json: "testScripts\.sources" must name at least one path pattern/);
  const none = run([], { modules: [] });
  assert.equal(none.code, 2);
  assert.match(none.error[0], /no script module matches scripts\/\*\*\/\*\.mjs; name them in "testScripts\.sources"/);
  assert.throws(() => main([], { cwd: '/app', read: () => { throw new TypeError('boom'); }, log() {}, error() {} }), TypeError);
});

test('the root is read through a link to the real directory, which is how node reports coverage', () => {
  const seen = [];
  main(['--root', '/link/app'], {
    cwd: '/',
    realpath: (directory) => directory.replace('/link', '/real'),
    read: () => null,
    glob: (_root, pattern) => (pattern.endsWith('.test.mjs') ? [] : ['scripts/a.mjs']),
    checkSiblings: (args) => {
      seen.push(args);
      return 1;
    },
    log() {},
    error() {},
  });
  assert.deepEqual(seen, [['--root', '/real/app']]);
});

test('--root names another directory, and a bad argument exits 2 with the usage', () => {
  assert.deepEqual(run(['--root', '/other']).siblings, [['--root', '/other']]);
  for (const argv of [['--nope'], ['--root'], ['x']]) {
    const result = run(argv);
    assert.deepEqual([result.code, result.error], [2, ['usage: test-scripts [--root DIR]']], argv.join(' '));
  }
});

// The real thing, in a throwaway repository: node, the 100% gate and the report.
function project(name, files) {
  const dir = path.join(work, name);
  mkdirSync(dir, { recursive: true });
  writeFileSync(path.join(dir, 'app-tooling.json'), JSON.stringify({ testSiblings: { sources: { 'scripts/**/*.mjs': ['.test.mjs'] }, exclude: ['**/*.test.mjs'] } }));
  for (const [file, text] of Object.entries(files)) {
    mkdirSync(path.dirname(path.join(dir, file)), { recursive: true });
    writeFileSync(path.join(dir, file), text);
  }
  execFileSync('git', ['init', '-q'], { cwd: dir });
  execFileSync('git', ['add', '.'], { cwd: dir });
  return dir;
}
const exec = (dir) => spawnSync(process.execPath, [BIN], { cwd: dir, encoding: 'utf8' });
const MODULE = 'export const double = (n) => n * 2;\n';
const TEST = "import assert from 'node:assert/strict';\nimport test from 'node:test';\nimport { double } from './a.mjs';\ntest('doubles', () => assert.equal(double(2), 4));\n";

test('as a program it passes a module that its own test covers at 100%', () => {
  const dir = project('green', { 'scripts/a.mjs': MODULE, 'scripts/a.test.mjs': TEST });
  const result = exec(dir);
  assert.equal(result.status, 0, result.stdout + result.stderr);
  assert.match(result.stdout, /script tests ok \(1 modules at 100%\)/);
});

test('as a program it fails a module the tests cover only in part', () => {
  const dir = project('partial', { 'scripts/a.mjs': 'export const f = (n) => (n ? 1 : 2);\nexport const g = () => 3;\n', 'scripts/a.test.mjs': "import test from 'node:test';\nimport { f } from './a.mjs';\ntest('f', () => f(1));\n" });
  assert.notEqual(exec(dir).status, 0);
});

test('as a program it names a module whose test file never imports it, which coverage alone would pass', () => {
  const dir = project('orphan', {
    'scripts/a.mjs': MODULE,
    'scripts/a.test.mjs': TEST,
    'scripts/b.mjs': 'export const untested = () => 1;\n',
    'scripts/b.test.mjs': "import test from 'node:test';\ntest('nothing', () => {});\n",
  });
  const result = exec(dir);
  assert.equal(result.status, 1);
  assert.match(result.stderr, /scripts\/b\.mjs: no test loaded it/);
});

test('as a program it stops at a script with no test file of its own', () => {
  const dir = project('sibling', { 'scripts/a.mjs': MODULE, 'scripts/a.test.mjs': TEST, 'scripts/c.mjs': 'export const c = 1;\n' });
  const result = exec(dir);
  assert.notEqual(result.status, 0);
  assert.match(result.stdout + result.stderr, /scripts\/c\.mjs/);
});

test('with the defaults it runs node itself, in the app, and passes the app\'s own coverage', () => {
  const dir = project('defaults', { 'scripts/a.mjs': MODULE, 'scripts/a.test.mjs': TEST });
  const logs = [];
  const errors = [];
  // This test is itself running under node:test: the child node must not take that for its own context.
  const code = main(['--root', dir], { log: (line) => logs.push(line), error: (line) => errors.push(line) });
  assert.equal(code, 0, errors.join('\n'));
  assert.deepEqual(logs, ['script tests ok (1 modules at 100%)']);
});

test('a directory with no app-tooling.json and no scripts reads as the defaults and finds no module', () => {
  const dir = path.join(work, 'nothing');
  mkdirSync(dir);
  const errors = [];
  assert.equal(main(['--root', dir], { log() {}, error: (line) => errors.push(line) }), 2);
  assert.match(errors[0], /no script module matches scripts\/\*\*\/\*\.mjs/);
});

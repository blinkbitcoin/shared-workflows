import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { after, test } from 'node:test';
import { fileURLToPath } from 'node:url';
import { copyApp, DEFAULT_EXCLUDE, describeFailure, failures, isExcluded, main } from './bin/check-prebuild.mjs';

const BIN = fileURLToPath(new URL('./bin/check-prebuild.mjs', import.meta.url));
const work = mkdtempSync(path.join(tmpdir(), 'check-prebuild-'));
after(() => rmSync(work, { recursive: true, force: true }));
const put = (root, file, text = '') => {
  mkdirSync(path.dirname(path.join(root, file)), { recursive: true });
  writeFileSync(path.join(root, file), text);
};

test('a path is excluded when it is one of the entries or lies under one, and a sibling with the same prefix is not', () => {
  assert.ok(isExcluded('node_modules', DEFAULT_EXCLUDE));
  assert.ok(isExcluded('ios/App/Info.plist', DEFAULT_EXCLUDE));
  assert.ok(isExcluded('.claude/worktrees/x/package.json', DEFAULT_EXCLUDE));
  assert.ok(!isExcluded('iosx/file', DEFAULT_EXCLUDE));
  assert.ok(!isExcluded('src/ios/file', DEFAULT_EXCLUDE), 'only at the root');
  assert.ok(!isExcluded('', DEFAULT_EXCLUDE));
});

test("a failure is the assertion's own message, else what was found", () => {
  assert.equal(describeFailure({ message: 'no stamp' }, 'a lacks "x"'), 'no stamp');
  assert.equal(describeFailure({ message: null }, 'a lacks "x"'), 'a lacks "x"');
});

test('each assertion kind holds or fails against the generated files, and every failure is listed', () => {
  const dir = path.join(work, 'generated');
  put(dir, 'ios/App/Info.plist', '<key>AppBuildStamp</key>\n<key>EXUpdatesEnabled</key>\n  <false/>');
  put(dir, 'ios/Other/Info.plist', 'nothing');
  put(dir, 'ios/App/Splash.colorset/Contents.json');
  const ok = [
    { kind: 'contains', value: 'AppBuildStamp', file: 'ios/*/Info.plist', message: null },
    { kind: 'absent', value: 'Certificate', file: 'ios/*/Info.plist', message: null },
    { kind: 'pattern', value: '<key>EXUpdatesEnabled</key>\\s*<false/>', file: 'ios/*/Info.plist', message: null },
    { kind: 'exists', value: 'ios/**/Splash.colorset', file: null, message: null },
  ];
  assert.deepEqual(failures(dir, ok), []);
  assert.deepEqual(
    failures(dir, [
      { kind: 'contains', value: 'Missing', file: 'ios/*/Info.plist', message: null },
      { kind: 'absent', value: 'AppBuildStamp', file: 'ios/*/Info.plist', message: 'stamp must not be there' },
      { kind: 'pattern', value: '<true/>', file: 'ios/*/Info.plist', message: null },
      { kind: 'contains', value: 'x', file: 'ios/*/Gone.plist', message: null },
      { kind: 'exists', value: 'ios/**/Nope.colorset', file: null, message: 'no splash' },
      { kind: 'exists', value: 'ios/**/Nope.colorset', file: null, message: null },
    ]),
    [
      'ios/*/Info.plist lacks "Missing"',
      'stamp must not be there',
      'ios/*/Info.plist has no match for "<true/>"',
      'ios/*/Gone.plist: no file matches',
      'no splash',
      'nothing matches ios/**/Nope.colorset',
    ],
  );
  // The text of one file among several is enough for contains and pattern, and any one holding it fails absent.
  assert.deepEqual(failures(dir, [{ kind: 'absent', value: 'nothing', file: 'ios/*/Info.plist', message: null }]), ['ios/Other/Info.plist holds "nothing"']);
});

test('copyApp leaves out what is excluded and links node_modules instead of copying it', () => {
  const app = path.join(work, 'app');
  put(app, 'src/index.ts', 'x');
  put(app, 'app.config.ts', 'config');
  put(app, 'ios/old/Info.plist', 'stale');
  put(app, 'node_modules/pkg/index.js', 'dep');
  put(app, '.claude/worktrees/w/package.json', 'other checkout');
  put(app, 'vendor/gems/a.rb', 'gem');
  const sandbox = path.join(work, 'sandbox');
  copyApp(app, sandbox, [...DEFAULT_EXCLUDE, 'vendor']);
  assert.equal(readFileSync(path.join(sandbox, 'src/index.ts'), 'utf8'), 'x');
  assert.ok(existsSync(path.join(sandbox, 'app.config.ts')));
  for (const gone of ['ios', '.claude/worktrees', 'vendor']) assert.ok(!existsSync(path.join(sandbox, gone)), gone);
  assert.ok(existsSync(path.join(sandbox, 'node_modules/pkg/index.js')), 'reachable through the link');
  assert.equal(readFileSync(path.join(sandbox, 'node_modules', 'pkg', 'index.js'), 'utf8'), 'dep');
  // An app with no node_modules gets none: nothing to link.
  const bare = path.join(work, 'bare');
  put(bare, 'a.txt');
  const bareSandbox = path.join(work, 'bare-sandbox');
  copyApp(bare, bareSandbox, DEFAULT_EXCLUDE);
  assert.ok(!existsSync(path.join(bareSandbox, 'node_modules')));
});

const CONFIG = JSON.stringify({
  prebuild: {
    scenarios: {
      default: { label: 'OTA off', env: { APP_VARIANT: 'production' }, assert: [{ file: 'ios/*/Info.plist', contains: 'stamp' }] },
      ota: { label: 'OTA on', env: { OTA_ENABLED: 'true' }, assert: [{ file: 'ios/*/Info.plist', contains: 'ota' }] },
    },
  },
});

function run(argv, { config = CONFIG, runResult = { status: 0 }, wrong = [] } = {}) {
  const out = { log: [], error: [], ran: [], copied: [], removed: [], checked: [] };
  let n = 0;
  const code = main(argv, {
    cwd: '/app',
    env: { PATH: '/bin' },
    read: (file) => (file === '/app/app-tooling.json' ? config : null),
    makeSandbox: (name) => `/tmp/sandbox-${name}`,
    copy: (root, sandbox, exclude) => out.copied.push([root, sandbox, exclude]),
    run: (command, args, options) => {
      out.ran.push([command, args, options]);
      return typeof runResult === 'function' ? runResult(n++) : runResult;
    },
    check: (sandbox, assertions) => {
      out.checked.push([sandbox, assertions.length]);
      return typeof wrong === 'function' ? wrong(sandbox) : wrong;
    },
    remove: (directory) => out.removed.push(directory),
    log: (line) => out.log.push(line),
    error: (line) => out.error.push(line),
  });
  return { code, ...out };
}

test('each scenario gets its own copy, runs the prebuild with its environment, is checked, and is removed', () => {
  const result = run([]);
  assert.equal(result.code, 0);
  assert.deepEqual(result.log, ['prebuild check passed (OTA off)', 'prebuild check passed (OTA on)']);
  assert.deepEqual(result.copied.map(([, sandbox]) => sandbox), ['/tmp/sandbox-default', '/tmp/sandbox-ota']);
  assert.deepEqual(result.copied[0][2], DEFAULT_EXCLUDE);
  const [command, args, options] = result.ran[0];
  assert.equal(command, './node_modules/.bin/expo');
  assert.deepEqual(args, ['prebuild', '--platform', 'all', '--clean', '--no-install']);
  assert.deepEqual(options, { cwd: '/tmp/sandbox-default', env: { PATH: '/bin', EXPO_NO_GIT_STATUS: '1', APP_VARIANT: 'production' } });
  assert.equal(result.ran[1][2].env.OTA_ENABLED, 'true');
  assert.deepEqual(result.removed, ['/tmp/sandbox-default', '/tmp/sandbox-ota']);
  // A scenario's own variable wins over the one the runner sets for every prebuild.
  const own = run([], { config: JSON.stringify({ prebuild: { scenarios: { a: { env: { EXPO_NO_GIT_STATUS: '0' }, assert: [{ exists: 'x' }] } } } }) });
  assert.equal(own.ran[0][2].env.EXPO_NO_GIT_STATUS, '0');
});

test('a failing assertion names the scenario and fails the run, and the other scenarios still run', () => {
  const result = run([], { wrong: (sandbox) => (sandbox.endsWith('default') ? ['no stamp', 'no encryption key'] : []) });
  assert.equal(result.code, 1);
  assert.deepEqual(result.error, ['check-prebuild (OTA off): no stamp', 'check-prebuild (OTA off): no encryption key']);
  assert.deepEqual(result.log, ['prebuild check passed (OTA on)']);
});

test('a prebuild that fails, or cannot start, is reported and that scenario is not checked', () => {
  const failed = run([], { runResult: (n) => (n === 0 ? { status: 3 } : { status: 0 }) });
  assert.equal(failed.code, 1);
  assert.deepEqual(failed.error, ['check-prebuild (OTA off): the prebuild failed with exit status 3']);
  assert.deepEqual(failed.checked.map(([sandbox]) => sandbox), ['/tmp/sandbox-ota']);
  const missing = run([], { runResult: { status: null, error: new Error('spawn ENOENT') } });
  assert.deepEqual(missing.error[0], 'check-prebuild (OTA off): the prebuild failed: spawn ENOENT');
  assert.equal(missing.removed.length, 2, 'every sandbox is removed, failed or not');
});

test('--keep leaves the sandbox and says where, and --root reads another directory\'s configuration', () => {
  const kept = run(['--keep']);
  assert.deepEqual(kept.removed, []);
  assert.deepEqual(kept.log.filter((line) => line.startsWith('kept ')), ['kept /tmp/sandbox-default', 'kept /tmp/sandbox-ota']);
  const elsewhere = [];
  main(['--root', '/other'], {
    cwd: '/app',
    read: (file) => {
      elsewhere.push(file);
      return CONFIG;
    },
    makeSandbox: () => '/tmp/s',
    copy: () => {},
    run: () => ({ status: 0 }),
    check: () => [],
    remove: () => {},
    log() {},
    error() {},
  });
  assert.deepEqual(elsewhere, ['/other/app-tooling.json']);
});

test('a missing or wrong configuration exits 2 naming the reason, and a bad argument exits 2 with the usage', () => {
  const none = run([], { config: null });
  assert.equal(none.code, 2);
  assert.match(none.error[0], /^check-prebuild: app-tooling\.json: no "prebuild" section/);
  const wrong = run([], { config: '{"prebuild":{"scenarios":{}}}' });
  assert.equal(wrong.code, 2);
  for (const argv of [['--nope'], ['--root'], ['x']]) {
    const result = run(argv);
    assert.deepEqual([result.code, result.error], [2, ['usage: check-prebuild [--root DIR] [--keep]']], argv.join(' '));
  }
  assert.throws(() => main([], { cwd: '/app', read: () => { throw new TypeError('boom'); }, log() {}, error() {} }), TypeError);
});

test('with the defaults it reads the configuration from disk, and a root with none is a configuration error', () => {
  const empty = path.join(work, 'empty');
  mkdirSync(empty);
  const errors = [];
  assert.equal(main(['--root', empty], { log() {}, error: (line) => errors.push(line) }), 2);
  assert.match(errors[0], /no "prebuild" section/);
});

test('as a program it copies the app, runs the configured command in the copy, and checks what it wrote', () => {
  const app = path.join(work, 'program');
  put(app, 'app.config.ts', 'config');
  put(app, 'ios/stale/Info.plist', 'stale');
  mkdirSync(path.join(app, 'node_modules'));
  put(app, 'gen.mjs', "import { mkdirSync, writeFileSync } from 'node:fs'; mkdirSync('ios/App', { recursive: true }); writeFileSync('ios/App/Info.plist', `stamp ${process.env.APP_VARIANT} ${process.env.EXPO_NO_GIT_STATUS}`);");
  const config = (contains) => ({
    prebuild: { command: ['node', 'gen.mjs'], scenarios: { default: { label: 'default', env: { APP_VARIANT: 'production' }, assert: [{ file: 'ios/*/Info.plist', contains }, { file: 'ios/*/Info.plist', absent: 'stale' }] } } },
  });
  writeFileSync(path.join(app, 'app-tooling.json'), JSON.stringify(config('stamp production 1')));
  const passed = spawnSync(process.execPath, [BIN], { cwd: app, encoding: 'utf8' });
  assert.equal(passed.status, 0, passed.stderr);
  assert.match(passed.stdout, /prebuild check passed \(default\)/);
  assert.ok(!existsSync(path.join(app, 'ios/App')), 'the generated project stays in the copy');
  writeFileSync(path.join(app, 'app-tooling.json'), JSON.stringify(config('never written')));
  const failed = spawnSync(process.execPath, [BIN], { cwd: app, encoding: 'utf8' });
  assert.equal(failed.status, 1);
  assert.match(failed.stderr, /check-prebuild \(default\): ios\/\*\/Info\.plist lacks "never written"/);
});

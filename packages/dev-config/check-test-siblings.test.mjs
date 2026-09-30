import assert from 'node:assert/strict';
import { execFileSync, spawnSync } from 'node:child_process';
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { after, describe, test } from 'node:test';
import { fileURLToPath } from 'node:url';
import { globToRegExp, main, parseArgs, problems, siblingsOf, sourceRule } from './bin/check-test-siblings.mjs';

const BIN = fileURLToPath(new URL('./bin/check-test-siblings.mjs', import.meta.url));

// The template's rules, as it will pass them.
const TEMPLATE = [
  '--source', 'scripts/**/*.{mjs,sh}=.test.mjs',
  '--source', 'src/**/*.{ts,tsx}=.test.ts,.test.tsx',
  '--source', 'plugins/*.ts=.test.ts,.test.tsx',
  '--source', 'modules/*/index.ts=.test.ts,.test.tsx',
  '--exclude', 'src/graphql/generated/**',
  '--exclude', 'src/i18n/locales/**',
  '--exclude', 'src/test/**',
  '--exclude', 'src/__tests__/**',
  '--exclude', '**/*.d.ts',
  '--mirror', 'src/app/=src/__tests__/app/',
];
const options = parseArgs(TEMPLATE, '/repo');
// The rule alone, without the stale-exclude report, for the cases about siblings.
const missing = (files) => problems(files, { ...options, excludes: options.excludes.filter((glob) => files.some((f) => globToRegExp(glob).test(f))) }).found;
const without = (files) => missing(files).map((line) => line.split(' ')[0]);

describe('globs', () => {
  test('** crosses directories, * and ? stay inside one, {a,b} is either', () => {
    const glob = globToRegExp('scripts/**/*.{mjs,sh}');
    for (const file of ['scripts/a.mjs', 'scripts/lib/b.sh', 'scripts/x/y/c.mjs']) assert.ok(glob.test(file), file);
    for (const file of ['scripts/a.ts', 'other/a.mjs', 'scripts.mjs']) assert.ok(!glob.test(file), file);
    assert.ok(globToRegExp('modules/*/index.ts').test('modules/h/index.ts'));
    assert.ok(!globToRegExp('modules/*/index.ts').test('modules/h/src/index.ts'));
    assert.ok(globToRegExp('a?.ts').test('ab.ts'));
    assert.ok(globToRegExp('src/**').test('src/a/b.ts'));
    assert.ok(globToRegExp('a.b+c(d).ts').test('a.b+c(d).ts'));
    assert.ok(!globToRegExp('a.ts').test('abts'));
    assert.ok(globToRegExp('x,y.ts').test('x,y.ts'));
  });
});

describe('the rule', () => {
  test('names a file without a sibling, and not one with', () => {
    const files = [
      'scripts/a.mjs',
      'scripts/a.test.mjs',
      'scripts/lib/b.mjs',
      'src/c.ts',
      'src/c.test.tsx',
      'src/D.tsx',
      'src/E.tsx',
      'src/E.test.tsx',
      'src/F.web.tsx',
      'plugins/with-g.ts',
      'plugins/with-g.test.ts',
      'modules/h/index.ts',
    ];
    assert.deepEqual(without(files), ['scripts/lib/b.mjs', 'src/D.tsx', 'src/F.web.tsx', 'modules/h/index.ts']);
  });

  test('says which test to add', () => {
    assert.deepEqual(missing(['src/D.tsx', 'scripts/b.sh']), [
      'src/D.tsx has no test of its own: add src/D.test.ts or src/D.test.tsx',
      'scripts/b.sh has no test of its own: add scripts/b.test.mjs',
    ]);
  });

  test('a test in a caller, or in a __tests__ directory, is not a sibling', () => {
    const files = ['src/lib/a.ts', 'src/lib/lib.test.ts', 'modules/h/index.ts', 'modules/h/__tests__/index.test.ts'];
    assert.deepEqual(without(files), ['src/lib/a.ts', 'modules/h/index.ts']);
  });

  test("a script's test must be a script", () => {
    assert.deepEqual(without(['scripts/a.mjs', 'scripts/a.test.ts']), ['scripts/a.mjs']);
  });

  test('a shell script needs a test file named after it', () => {
    const files = ['scripts/a.sh', 'scripts/a.test.mjs', 'scripts/e2e/b.sh', 'scripts/e2e/b.test.sh', 'scripts/lib/c.sh', 'scripts/lib/lib.test.mjs'];
    assert.deepEqual(without(files), ['scripts/e2e/b.sh', 'scripts/lib/c.sh']);
  });

  test('a route is tested from its mirror, and a test beside it does not count', () => {
    const files = ['src/app/_layout.tsx', 'src/__tests__/app/_layout.test.tsx', 'src/app/details/[id].tsx', 'src/app/details/[id].test.tsx'];
    assert.deepEqual(without(files), ['src/app/details/[id].tsx', 'src/app/details/[id].test.tsx']);
    assert.deepEqual(siblingsOf('src/app/details/[id].tsx', sourceRule('src/app/details/[id].tsx', options), options.mirrors), [
      'src/__tests__/app/details/[id].test.ts',
      'src/__tests__/app/details/[id].test.tsx',
    ]);
  });

  test('leaves out generated code, test support and files that are not modules', () => {
    const files = [
      'src/graphql/generated/graphql.ts',
      'src/i18n/locales/en/messages.ts',
      'src/test/setup.ts',
      'src/global.d.ts',
      'src/features/home/hello.graphql',
      'plugins/helpers/x.ts',
      'modules/h/src/HelloNativeModule.ts',
    ];
    assert.deepEqual(missing(files), []);
  });

  test('the first --source a file matches decides its suffixes', () => {
    const own = parseArgs(['--source', 'scripts/*.mjs=.spec.mjs', '--source', '**/*.mjs=.test.mjs'], '/r');
    assert.deepEqual(sourceRule('scripts/a.mjs', own).suffixes, ['.spec.mjs']);
    assert.deepEqual(sourceRule('lib/a.mjs', own).suffixes, ['.test.mjs']);
    assert.equal(sourceRule('lib/a.test.mjs', own), null);
  });
});

describe('route tests', () => {
  test('none sits under src/app/, where expo-router would load it as a route', () => {
    assert.deepEqual(missing(['src/app/a.tsx', 'src/app/a.test.tsx', 'src/__tests__/app/a.test.tsx']), [
      'src/app/a.test.tsx is a test under src/app/, where every file is loaded as something else: move it under src/__tests__/app/',
    ]);
  });

  test('each one under src/__tests__/app/ mirrors a route that exists', () => {
    const files = [
      'src/app/a.tsx',
      'src/app/b.ts',
      'src/__tests__/app/a.test.tsx',
      'src/__tests__/app/b.test.ts',
      'src/__tests__/app/renamed.test.tsx',
      'src/__tests__/app/helpers.ts',
    ];
    assert.deepEqual(missing(files), ['src/__tests__/app/renamed.test.tsx mirrors no file under src/app/: rename or remove it to match']);
  });
});

describe('no allowlist', () => {
  test('--allow is refused, with the reason', () => {
    assert.throws(() => parseArgs(['--allow', 'scripts/x.mjs=needs a device'], '/r'), /there is no --allow: a file with no test gets one/);
  });

  test('an --exclude naming one file is refused as the allowlist it would be', () => {
    assert.throws(
      () => parseArgs(['--source', 'src/**/*.ts=.test.ts', '--exclude', 'src/hard.ts'], '/r'),
      /--exclude src\/hard\.ts names one file, which is an allowlist entry/,
    );
    assert.deepEqual(parseArgs(['--source', 'a/*.ts=.test.ts', '--exclude', 'vendor/'], '/r').excludes, ['vendor/']);
  });

  test('a directory --exclude covers everything under it, and one that matches nothing is reported', () => {
    const own = parseArgs(['--source', '**/*.ts=.test.ts', '--exclude', 'vendor/', '--exclude', 'gone/**'], '/r');
    assert.deepEqual(problems(['vendor/a.ts', 'b.ts', 'b.test.ts'], own), { sources: 1, found: ['--exclude gone/** matches no file; drop it'] });
  });

  test('this program keeps no list of excused files', () => {
    const own = readFileSync(BIN, 'utf8');
    assert.doesNotMatch(own, /^const [A-Z_]*(ALLOW|EXCUS|EXEMPT)[A-Z_]* =/m);
  });
});

test('parseArgs reads every option, and refuses a malformed one', () => {
  assert.deepEqual(options.root, '/repo');
  assert.equal(options.sources.length, 4);
  assert.deepEqual(options.mirrors, [{ from: 'src/app/', to: 'src/__tests__/app/' }]);
  assert.equal(parseArgs(['--root', 'app', '--source', 'a/*.ts=.test.ts'], '/w').root, path.resolve('/w', 'app'));
  assert.throws(() => parseArgs([], '/w'), /name the source files with at least one --source GLOB=SUFFIX/);
  for (const bad of [['--source'], ['--mirror'], ['--source', 'a/*.ts'], ['--source', 'a/*.ts=test.ts'], ['--mirror', 'src/app=src/__tests__/app'], ['--exclude'], ['--root'], ['--nope', 'x']]) {
    assert.throws(() => parseArgs(bad, '/w'), /unexpected .*: pass --source GLOB=SUFFIX\[,SUFFIX\], --exclude GLOB, --mirror FROM\/=TO\/ and --root DIR/, bad.join(' '));
  }
});

/** Runs main over an in-memory file list. */
function run(files, argv = TEMPLATE) {
  const out = { log: [], error: [] };
  const roots = [];
  const listFiles = (root) => {
    roots.push(root);
    if (files instanceof Error) throw files;
    return files;
  };
  const code = main(argv, { cwd: '/repo', listFiles, log: (l) => out.log.push(l), error: (l) => out.error.push(l) });
  return { code, roots, ...out };
}

const TREE = [
  'scripts/a.mjs',
  'scripts/a.test.mjs',
  'src/app/index.tsx',
  'src/__tests__/app/index.test.tsx',
  'src/graphql/generated/graphql.ts',
  'src/i18n/locales/en/messages.ts',
  'src/test/setup.ts',
  'src/global.d.ts',
];

test('main passes a tree that holds the rule, counting its sources once', () => {
  assert.deepEqual(run([...TREE, 'scripts/a.mjs']), { code: 0, roots: ['/repo'], log: ['test siblings ok (2 source files)'], error: [] });
});

test('main names every problem and fails', () => {
  const { code, log, error } = run([...TREE, 'scripts/b.sh']);
  assert.equal(code, 1);
  assert.deepEqual(log, []);
  assert.deepEqual(error, ['scripts/b.sh has no test of its own: add scripts/b.test.mjs', 'test siblings: 1 problem(s)']);
});

test('main fails on bad arguments and on a file list it cannot read', () => {
  assert.deepEqual(run(TREE, ['--allow', 'x']).error, [
    'test siblings: there is no --allow: a file with no test gets one, against fakes of whatever it needs',
  ]);
  const broken = run(new Error('not a git repository'));
  assert.equal(broken.code, 1);
  assert.deepEqual(broken.error, ['test siblings: could not list the files of /repo: not a git repository']);
});

const dirs = [];
after(() => {
  for (const dir of dirs) rmSync(dir, { recursive: true, force: true });
});

test('as a command it lists the tracked and the untracked files git does not ignore', () => {
  const root = mkdtempSync(path.join(tmpdir(), 'test-siblings-'));
  dirs.push(root);
  // Git's own variables are dropped: a pre-push hook exports GIT_DIR, which
  // would point these calls at the repository being pushed.
  const env = { ...Object.fromEntries(Object.entries(process.env).filter(([key]) => !key.startsWith('GIT_'))), GIT_CONFIG_GLOBAL: '/dev/null' };
  const git = (...args) => execFileSync('git', args, { cwd: root, env });
  git('init', '-q');
  mkdirSync(path.join(root, 'lib'));
  writeFileSync(path.join(root, '.gitignore'), 'build/\n');
  writeFileSync(path.join(root, 'lib', 'a.mjs'), '');
  writeFileSync(path.join(root, 'lib', 'a.test.mjs'), '');
  git('add', '-A');
  mkdirSync(path.join(root, 'build'));
  writeFileSync(path.join(root, 'build', 'out.mjs'), '');
  writeFileSync(path.join(root, 'lib', 'new.mjs'), '');
  const result = spawnSync(process.execPath, [BIN, '--root', root, '--source', '**/*.mjs=.test.mjs'], { encoding: 'utf8', env });
  assert.equal(result.status, 1, result.stdout);
  assert.equal(result.stderr, 'lib/new.mjs has no test of its own: add lib/new.test.mjs\ntest siblings: 1 problem(s)\n');
  writeFileSync(path.join(root, 'lib', 'new.test.mjs'), '');
  const ok = spawnSync(process.execPath, [BIN, '--source', '**/*.mjs=.test.mjs'], { cwd: root, encoding: 'utf8', env });
  assert.equal(ok.status, 0, ok.stderr);
  assert.equal(ok.stdout, 'test siblings ok (2 source files)\n');
});

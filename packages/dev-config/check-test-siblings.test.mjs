import assert from 'node:assert/strict';
import { execFileSync, spawnSync } from 'node:child_process';
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { after, describe, test } from 'node:test';
import { fileURLToPath } from 'node:url';
import { configRules, globToRegExp, main, parseArgs, problems, resolveRules, siblingsOf, sourceRule } from './bin/check-test-siblings.mjs';

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
    assert.deepEqual(problems(['vendor/a.ts', 'b.ts', 'b.test.ts'], own), { sources: 1, found: ['exclude gone/** matches no file; drop it'] });
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
  assert.deepEqual(parseArgs([], '/w'), { root: '/w', sources: [], excludes: [], mirrors: [] });
  for (const bad of [['--source'], ['--mirror'], ['--source', 'a/*.ts'], ['--source', 'a/*.ts=test.ts'], ['--mirror', 'src/app=src/__tests__/app'], ['--exclude'], ['--root'], ['--nope', 'x']]) {
    assert.throws(() => parseArgs(bad, '/w'), /unexpected .*: pass --source GLOB=SUFFIX\[,SUFFIX\], --exclude GLOB, --mirror FROM\/=TO\/ and --root DIR/, bad.join(' '));
  }
});

/** Runs main over an in-memory file list. */
function run(files, argv = TEMPLATE, config = {}) {
  const out = { log: [], error: [] };
  const read = (file) => config[file] ?? null;
  const roots = [];
  const listFiles = (root) => {
    roots.push(root);
    if (files instanceof Error) throw files;
    return files;
  };
  const code = main(argv, { cwd: '/repo', listFiles, read, log: (l) => out.log.push(l), error: (l) => out.error.push(l) });
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

// The template's rules as its dev-config.json will hold them.
const TEMPLATE_FILE = JSON.stringify({
  testSiblings: {
    sources: {
      'scripts/**/*.{mjs,sh}': ['.test.mjs'],
      'src/**/*.{ts,tsx}': ['.test.ts', '.test.tsx'],
      'plugins/*.ts': ['.test.ts', '.test.tsx'],
      'modules/*/index.ts': ['.test.ts', '.test.tsx'],
    },
    exclude: ['src/graphql/generated/**', 'src/i18n/locales/**', 'src/test/**', 'src/__tests__/**', '**/*.d.ts'],
    mirror: { 'src/app/': 'src/__tests__/app/' },
  },
  docs: { architecture: ['scripts/'] },
});
const withFile = (text) => ({ '/repo/dev-config.json': text });

describe('dev-config.json', () => {
  test('with no flags the rules come from the file, and give what the flags gave', () => {
    assert.deepEqual(run([...TREE, 'scripts/b.sh'], [], withFile(TEMPLATE_FILE)), run([...TREE, 'scripts/b.sh']));
    assert.equal(run(TREE, [], withFile(TEMPLATE_FILE)).code, 0);
  });

  test('configRules keeps the order of sources, so the first match still decides', () => {
    const rules = configRules(JSON.parse(TEMPLATE_FILE).testSiblings);
    assert.deepEqual(rules.sources.map(({ glob, suffixes }) => [glob, suffixes]), options.sources.map(({ glob, suffixes }) => [glob, suffixes]));
    assert.deepEqual(rules.excludes, options.excludes);
    assert.deepEqual(rules.mirrors, options.mirrors);
    assert.deepEqual(configRules({}), { sources: [], excludes: [], mirrors: [] });
  });

  test('a flag overrides its own field of the file, and leaves the others', () => {
    const file = configRules(JSON.parse(TEMPLATE_FILE).testSiblings);
    const flags = parseArgs(['--source', 'lib/*.mjs=.spec.mjs'], '/repo');
    const merged = resolveRules(flags, file);
    assert.deepEqual(merged.sources.map(({ glob }) => glob), ['lib/*.mjs']);
    assert.deepEqual(merged.excludes, file.excludes);
    assert.deepEqual(merged.mirrors, file.mirrors);
    assert.deepEqual(resolveRules(flags, null), flags);
    const { code, error } = run(['lib/a.mjs', 'scripts/b.sh'], ['--source', 'lib/*.mjs=.spec.mjs', '--exclude', 'scripts/'], withFile(TEMPLATE_FILE));
    assert.equal(code, 1);
    assert.deepEqual(error, ['lib/a.mjs has no test of its own: add lib/a.spec.mjs', 'test siblings: 1 problem(s)']);
  });

  test('no rules in the flags or the file is a usage error', () => {
    assert.deepEqual(run(TREE, []).error, ['test siblings: name the source files with --source GLOB=SUFFIX, or with "testSiblings.sources" in dev-config.json']);
    assert.equal(run(TREE, [], withFile('{"docs":{}}')).code, 1);
  });

  test('an exclude in the file that matches nothing fails, as the flag does', () => {
    const file = JSON.stringify({ testSiblings: { sources: { '**/*.mjs': ['.test.mjs'] }, exclude: ['gone/**'] } });
    assert.deepEqual(run(['a.mjs', 'a.test.mjs'], [], withFile(file)).error, ['exclude gone/** matches no file; drop it', 'test siblings: 1 problem(s)']);
  });

  for (const [what, file, reason] of [
    ['invalid JSON', '{', /^test siblings: dev-config\.json: not valid JSON: /],
    ['an unknown key', '{"testSiblings":{"excludes":[]}}', /unknown key "testSiblings\.excludes"/],
    ['a single-file exclude', '{"testSiblings":{"exclude":["src/hard.ts"]}}', /"testSiblings\.exclude" entry src\/hard\.ts names one file, which is an allowlist entry/],
    ['sources that are not an object', '{"testSiblings":{"sources":["a"]}}', /"testSiblings\.sources" must be an object of glob to test suffixes/],
    ['sources that are null', '{"testSiblings":{"sources":null}}', /"testSiblings\.sources" must be an object/],
    ['a suffix list that is not a list', '{"testSiblings":{"sources":{"a/*":".test.mjs"}}}', /"testSiblings\.sources\.a\/\*" must be a list of non-empty strings/],
    ['an empty suffix list', '{"testSiblings":{"sources":{"a/*":[]}}}', /must list test suffixes that start with a dot/],
    ['a suffix without its dot', '{"testSiblings":{"sources":{"a/*":["test.mjs"]}}}', /must list test suffixes that start with a dot/],
    ['an exclude that is not a list', '{"testSiblings":{"exclude":"a/**"}}', /"testSiblings\.exclude" must be a list of non-empty strings/],
    ['a mirror that is not a map', '{"testSiblings":{"mirror":["src/app/"]}}', /"testSiblings\.mirror" must be an object of non-empty strings/],
    ['a mirror between files', '{"testSiblings":{"mirror":{"src/app":"src/__tests__/app/"}}}', /maps a directory to a directory, each ending in a slash/],
  ]) {
    test(`a file with ${what} exits 2 with the reason`, () => {
      const { code, error, roots } = run(TREE, [], withFile(file));
      assert.equal(code, 2);
      assert.equal(error.length, 1);
      assert.match(error[0], reason);
      assert.deepEqual(roots, [], 'nothing is listed once the file is wrong');
    });
  }

  test('the file is read from --root', () => {
    const read = [];
    main(['--root', 'app'], { cwd: '/w', listFiles: () => [], read: (file) => (read.push(file), null), log: () => {}, error: () => {} });
    assert.deepEqual(read, ['/w/app/dev-config.json']);
  });
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
  writeFileSync(path.join(root, 'dev-config.json'), JSON.stringify({ testSiblings: { sources: { '**/*.mjs': ['.test.mjs'] } } }));
  const fromFile = spawnSync(process.execPath, [BIN], { cwd: root, encoding: 'utf8', env });
  assert.equal(fromFile.status, 0, fromFile.stderr);
  assert.equal(fromFile.stdout, 'test siblings ok (2 source files)\n');
});

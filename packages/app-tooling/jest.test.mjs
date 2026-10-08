import assert from 'node:assert/strict';
import { existsSync, mkdirSync, mkdtempSync, realpathSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { after, test } from 'node:test';
import future from './fixtures/template/jest/future.ts';
import today from './fixtures/template/jest/today.ts';
import {
  COLLECT_COVERAGE_FROM,
  CONSOLE_SETUP,
  COVERAGE_PATH_IGNORE_PATTERNS,
  createJestConfig,
  EXPO_MOCKS,
  FAKE_TIMERS,
  IGNORED_DIRECTORIES,
  IMPORT_META_URL_PLUGIN,
  MSW_FETCH_INTERCEPTOR,
  mswFetchMapper,
  SCRIPT_TRANSFORM,
  scriptTransform,
  TEST_PATH_IGNORE_PATTERNS,
  TRANSFORM_PACKAGES,
  transformIgnorePattern,
  WORKFLOWS,
  WORKTREES,
} from './expo/jest.mjs';

// fixtures/template/jest/today.ts is the template's jest.config.ts as it is
// before the switch, byte for byte; future.ts is the file it becomes. The
// template's switch moves the console guard and the three Expo stand-ins into
// this package, so the configuration differs from today's in exactly the
// paths that point at them, and nowhere else. This spells each of those out.
function movedIntoThePackage(config) {
  const expected = structuredClone(config);
  const [app, plugins] = expected.projects;
  for (const [pattern, stub] of Object.entries(EXPO_MOCKS)) {
    assert.match(app.moduleNameMapper[pattern], /^<rootDir>\/src\/test\/mocks\//);
    app.moduleNameMapper[pattern] = stub;
  }
  // src/test/setup.ts stops installing the guard; the preset appends it.
  app.setupFilesAfterEnv.push(CONSOLE_SETUP);
  // src/test/setup.plugins.ts held nothing but the guard, and is deleted.
  assert.deepEqual(plugins.setupFilesAfterEnv, ['<rootDir>/src/test/setup.plugins.ts']);
  plugins.setupFilesAfterEnv = [CONSOLE_SETUP];
  for (const project of expected.projects) {
    project.coveragePathIgnorePatterns = project.coveragePathIgnorePatterns
      // The stand-ins now live under node_modules, which is ignored already.
      .filter((pattern) => pattern !== '<rootDir>/src/test/mocks/')
      .map((pattern) =>
        pattern === '<rootDir>/src/test/(env|setup|setup\\.plugins)\\.ts$'
          ? '<rootDir>/src/test/(env|setup)\\.ts$'
          : pattern,
      );
  }
  return expected;
}

// Since the switch the preset also carries what msw 3 needs, for every app:
// `@msw/.*` transformed, queueMicrotask left real under fake timers, and,
// from what is installed where the configuration is built (here: neither
// jest-expo nor msw), jest-expo's transform with the plugin and msw 3's
// `fetch` mapping.
function withMsw3Support(config) {
  const expected = structuredClone(config);
  const [app] = expected.projects;
  const [pattern] = app.transformIgnorePatterns;
  assert.equal(pattern, transformIgnorePattern(TRANSFORM_PACKAGES.filter((name) => name !== '@msw/.*')));
  app.transformIgnorePatterns = [transformIgnorePattern(TRANSFORM_PACKAGES)];
  app.fakeTimers = FAKE_TIMERS;
  app.transform = { ...app.transform, ...scriptTransform(process.cwd()) };
  app.moduleNameMapper = { ...mswFetchMapper(process.cwd()), ...app.moduleNameMapper };
  return expected;
}

test("the template's future jest.config.ts is today's, with the moved files pointing into the package", () => {
  assert.deepStrictEqual(future, withMsw3Support(movedIntoThePackage(today)));
});

test('today and the future collect coverage from the same files with the same gate', () => {
  assert.deepStrictEqual(future.collectCoverageFrom, today.collectCoverageFrom);
  assert.deepStrictEqual(future.coverageReporters, today.coverageReporters);
  assert.deepStrictEqual(future.coverageThreshold, today.coverageThreshold);
});

test('the files the configuration points into this package exist', () => {
  assert.ok(existsSync(CONSOLE_SETUP), CONSOLE_SETUP);
  for (const stub of Object.values(EXPO_MOCKS)) assert.ok(existsSync(stub), stub);
  assert.ok(existsSync(IMPORT_META_URL_PLUGIN), IMPORT_META_URL_PLUGIN);
});

test('with no options the configuration is the generic one', () => {
  const config = createJestConfig();
  const [app, plugins] = config.projects;
  assert.deepEqual(app.setupFiles, []);
  assert.deepEqual(app.setupFilesAfterEnv, [CONSOLE_SETUP]);
  assert.deepEqual(app.moduleNameMapper, EXPO_MOCKS);
  assert.deepEqual(app.testPathIgnorePatterns, TEST_PATH_IGNORE_PATTERNS);
  assert.deepEqual(app.coveragePathIgnorePatterns, COVERAGE_PATH_IGNORE_PATTERNS);
  assert.deepEqual(plugins.coveragePathIgnorePatterns, COVERAGE_PATH_IGNORE_PATTERNS);
  assert.deepEqual(app.transformIgnorePatterns, [transformIgnorePattern(TRANSFORM_PACKAGES)]);
  assert.deepEqual(plugins.setupFilesAfterEnv, [CONSOLE_SETUP]);
  assert.deepEqual(config.collectCoverageFrom, COLLECT_COVERAGE_FROM);
  assert.deepEqual(config.coverageThreshold.global, { lines: 100, branches: 100, functions: 100, statements: 100 });
});

test("the app's aliases are matched before the Expo stand-ins", () => {
  const { moduleNameMapper } = createJestConfig({ moduleNameMapper: { '^@/(.*)$': '<rootDir>/src/$1' } }).projects[0];
  assert.deepEqual(Object.keys(moduleNameMapper), ['^@/(.*)$', ...Object.keys(EXPO_MOCKS)]);
});

test('the console guard runs after the app setup, and can be left out', () => {
  const on = createJestConfig({ setupFilesAfterEnv: ['<rootDir>/setup.ts'] });
  assert.deepEqual(on.projects[0].setupFilesAfterEnv, ['<rootDir>/setup.ts', CONSOLE_SETUP]);
  const off = createJestConfig({ setupFilesAfterEnv: ['<rootDir>/setup.ts'], consoleGuard: false });
  assert.deepEqual(off.projects[0].setupFilesAfterEnv, ['<rootDir>/setup.ts']);
  assert.deepEqual(off.projects[1].setupFilesAfterEnv, []);
});

test("an app's extra packages, test ignores and coverage list extend or replace the generic ones", () => {
  const config = createJestConfig({
    transformPackages: ['my-esm-package'],
    testPathIgnorePatterns: ['/fixtures/'],
    coveragePathIgnorePatterns: ['<rootDir>/generated/'],
    collectCoverageFrom: ['app/**/*.ts'],
  });
  const [app, plugins] = config.projects;
  assert.match(app.transformIgnorePatterns[0], /\|standard-navigation\|my-esm-package\)$/);
  assert.deepEqual(app.testPathIgnorePatterns, [...TEST_PATH_IGNORE_PATTERNS, '/fixtures/']);
  assert.deepEqual(plugins.coveragePathIgnorePatterns, [...COVERAGE_PATH_IGNORE_PATTERNS, '<rootDir>/generated/']);
  assert.deepEqual(config.collectCoverageFrom, ['app/**/*.ts']);
});

test('the transform ignore pattern skips pnpm store directories and lets the named packages through', () => {
  const pattern = new RegExp(transformIgnorePattern(TRANSFORM_PACKAGES));
  assert.ok(pattern.test('node_modules/lodash/index.js'), 'an ordinary package is not transformed');
  assert.ok(!pattern.test('node_modules/expo-router/build/index.js'), 'expo-router is transformed');
  assert.ok(!pattern.test('node_modules/@lingui/core/dist/index.mjs'), '@lingui is transformed');
  assert.ok(!pattern.test('node_modules/.pnpm/msw@2.0.0/node_modules/msw/lib/core.mjs'), 'the pnpm hop is skipped');
});

test('the worktree ignore is anchored to the root, so a worktree still runs its own tests', () => {
  const pattern = (rootDir) => new RegExp(WORKTREES.replace('<rootDir>', rootDir));
  assert.ok(pattern('/repo').test('/repo/.claude/worktrees/topic/src/a.test.ts'), 'another checkout is ignored');
  const worktree = '/repo/.claude/worktrees/topic';
  assert.ok(!pattern(worktree).test(`${worktree}/src/a.test.ts`), "a worktree's own tests are not");
});

test('the .workflows ignore is anchored to the root, so a checkout under a .workflows directory still runs its own tests', () => {
  const pattern = (rootDir) => new RegExp(WORKFLOWS.replace('<rootDir>', rootDir));
  assert.ok(pattern('/repo').test('/repo/.workflows/packages/app-tooling/jest.test.mjs'), "shared-workflows' checkout is ignored");
  const nested = '/runner/.workflows/consumer';
  assert.ok(!pattern(nested).test(`${nested}/src/a.test.ts`), "a nested checkout's own tests are not");
});

test('both projects keep the worktrees and .workflows out of the module map, the tests and coverage', () => {
  const config = createJestConfig();
  assert.deepEqual(IGNORED_DIRECTORIES, [WORKTREES, WORKFLOWS]);
  for (const project of config.projects) {
    assert.deepEqual(project.modulePathIgnorePatterns, IGNORED_DIRECTORIES, project.displayName);
    for (const directory of IGNORED_DIRECTORIES) {
      assert.ok(project.coveragePathIgnorePatterns.includes(directory), `${project.displayName} coverage: ${directory}`);
    }
  }
  for (const directory of IGNORED_DIRECTORIES) assert.ok(config.projects[0].testPathIgnorePatterns.includes(directory), directory);
  // A copy per project: an app changing one project's list leaves the other's alone.
  assert.notEqual(config.projects[0].modulePathIgnorePatterns, config.projects[1].modulePathIgnorePatterns);
  assert.notEqual(config.projects[0].modulePathIgnorePatterns, IGNORED_DIRECTORIES);
});

// Apps as installed: each a directory under the system temporary directory
// with the node_modules a case needs, removed when the file's tests end.
const apps = [];
after(() => {
  for (const root of apps) rmSync(root, { recursive: true, force: true });
});

/** A directory holding `files` (path to content), its real path. */
function installed(files) {
  const root = realpathSync(mkdtempSync(join(tmpdir(), 'jest-preset-')));
  apps.push(root);
  for (const [path, content] of Object.entries(files)) {
    mkdirSync(dirname(join(root, path)), { recursive: true });
    writeFileSync(join(root, path), typeof content === 'string' ? content : JSON.stringify(content));
  }
  return root;
}

/** jest-expo, its preset exporting `preset` (source, so it can also throw). */
const jestExpo = (preset) => ({
  'node_modules/jest-expo/package.json': { name: 'jest-expo', version: '57.0.5' },
  'node_modules/jest-expo/jest-preset.js': `module.exports = ${preset};`,
});

/** jest-expo's script entry as its preset builds it in an app at /app. */
const JEST_EXPO_OPTIONS = {
  root: '/app',
  babelrcRoots: ['/app'],
  babelrc: false,
  configFile: false,
  extends: '/app/babel.config.js',
  caller: { name: 'metro', bundler: 'metro', platform: 'ios' },
};
const JEST_EXPO = jestExpo(
  JSON.stringify({ transform: { [SCRIPT_TRANSFORM]: ['babel-jest', JEST_EXPO_OPTIONS], '^.+\\.(bmp|png)$': 'asset' } }),
);

/** msw, installed at `at` (a node_modules directory), with nothing of its own beyond package.json. */
const msw = (at, version) => ({ [`${at}/msw/package.json`]: { name: 'msw', version, exports: { './package.json': './package.json' } } });

/** msw 3's `@mswjs/interceptors` (0.45) at `at`: ES modules, `./fetch` by environment. */
const interceptors3 = (at) => ({
  [`${at}/@mswjs/interceptors/package.json`]: {
    name: '@mswjs/interceptors',
    version: '0.45.6',
    type: 'module',
    exports: {
      './fetch': { browser: './lib/browser/interceptors/fetch/web.js', default: './lib/node/interceptors/fetch/node.js' },
    },
  },
  [`${at}/@mswjs/interceptors/lib/node/interceptors/fetch/node.js`]: '',
  [`${at}/@mswjs/interceptors/lib/browser/interceptors/fetch/web.js`]: '',
});

/** msw 2's `@mswjs/interceptors` (0.41) at `at`: both module systems, other file names. */
const interceptors2 = (at) => ({
  [`${at}/@mswjs/interceptors/package.json`]: {
    name: '@mswjs/interceptors',
    version: '0.41.9',
    exports: {
      './fetch': {
        import: './lib/node/interceptors/fetch/index.mjs',
        browser: './lib/browser/interceptors/fetch/index.mjs',
        require: './lib/node/interceptors/fetch/index.cjs',
        default: './lib/node/interceptors/fetch/index.cjs',
      },
    },
  },
  [`${at}/@mswjs/interceptors/lib/node/interceptors/fetch/index.cjs`]: '',
  [`${at}/@mswjs/interceptors/lib/browser/interceptors/fetch/index.mjs`]: '',
});

const browserFetch = (interceptors) => join(interceptors, 'lib', 'browser', 'interceptors', 'fetch', 'web.js');

test('@msw/* is transformed: msw 3 requires its ES-module-only @msw/url', () => {
  assert.ok(TRANSFORM_PACKAGES.includes('@msw/.*'));
  const pattern = new RegExp(transformIgnorePattern(TRANSFORM_PACKAGES));
  assert.ok(!pattern.test('node_modules/@msw/url/build/index.mjs'), '@msw/url is transformed');
  assert.ok(!pattern.test('node_modules/.pnpm/@msw+url@0.1.2/node_modules/@msw/url/build/index.mjs'), 'and under pnpm');
});

test("jest-expo's script transform gains the import.meta.url plugin, its own options kept", () => {
  const root = installed(JEST_EXPO);
  assert.deepStrictEqual(scriptTransform(root), {
    [SCRIPT_TRANSFORM]: ['babel-jest', { ...JEST_EXPO_OPTIONS, plugins: [IMPORT_META_URL_PLUGIN] }],
  });
});

test("the plugin goes after any jest-expo already passes, and an entry without options gets them", () => {
  const withPlugins = installed(jestExpo(`{ transform: { '\\\\.[jt]sx?$': ['babel-jest', { plugins: ['its-own'] }] } }`));
  assert.deepStrictEqual(scriptTransform(withPlugins)[SCRIPT_TRANSFORM], ['babel-jest', { plugins: ['its-own', IMPORT_META_URL_PLUGIN] }]);
  const bare = installed(jestExpo(`{ transform: { '\\\\.[jt]sx?$': ['babel-jest'] } }`));
  assert.deepStrictEqual(scriptTransform(bare)[SCRIPT_TRANSFORM], ['babel-jest', { plugins: [IMPORT_META_URL_PLUGIN] }]);
});

test("jest-expo's transform is left in place when it is not installed or has no such entry", () => {
  assert.deepStrictEqual(scriptTransform(installed({})), {});
  assert.deepStrictEqual(scriptTransform(installed(jestExpo('{}'))), {});
  assert.deepStrictEqual(scriptTransform(installed(jestExpo(`{ transform: { '\\\\.[jt]sx?$': 'babel-jest' } }`))), {});
});

test('a jest-expo that fails to load fails the configuration, as Jest would', () => {
  const root = installed(jestExpo('(() => { throw new Error("jest-expo is broken"); })()'));
  assert.throws(() => scriptTransform(root), /jest-expo is broken/);
});

test("under msw 3, its fetch interceptor maps to the browser build, found from msw's own directory", () => {
  const hoisted = installed({ ...msw('node_modules', '3.0.1'), ...interceptors3('node_modules') });
  assert.deepStrictEqual(mswFetchMapper(hoisted), {
    [MSW_FETCH_INTERCEPTOR]: browserFetch(join(hoisted, 'node_modules', '@mswjs', 'interceptors')),
  });
  // msw 3 with its own interceptors nested, beside another package's older copy at the top.
  const nested = installed({
    ...msw('node_modules', '3.0.1'),
    ...interceptors3('node_modules/msw/node_modules'),
    ...interceptors2('node_modules'),
  });
  assert.deepStrictEqual(mswFetchMapper(nested), {
    [MSW_FETCH_INTERCEPTOR]: browserFetch(join(nested, 'node_modules', 'msw', 'node_modules', '@mswjs', 'interceptors')),
  });
  // The mapped file is a real one, and the pattern matches what msw imports, and only that.
  assert.ok(existsSync(mswFetchMapper(hoisted)[MSW_FETCH_INTERCEPTOR]));
  const pattern = new RegExp(MSW_FETCH_INTERCEPTOR);
  assert.ok(pattern.test('@mswjs/interceptors/fetch'));
  assert.ok(!pattern.test('@mswjs/interceptors/fetch/web'));
  assert.ok(!pattern.test('@mswjs/interceptors/ClientRequest'));
});

test('there is no mapping under msw 2, without msw, or without its interceptors', () => {
  assert.deepStrictEqual(mswFetchMapper(installed({ ...msw('node_modules', '2.15.0'), ...interceptors2('node_modules') })), {});
  assert.deepStrictEqual(mswFetchMapper(installed({})), {});
  assert.deepStrictEqual(mswFetchMapper(installed(msw('node_modules', '3.0.1'))), {});
});

test("fake timers leave queueMicrotask real: msw 3 schedules each request with it", () => {
  assert.deepEqual(FAKE_TIMERS, { doNotFake: ['queueMicrotask'] });
  const [app, plugins] = createJestConfig().projects;
  assert.deepEqual(app.fakeTimers, FAKE_TIMERS);
  // A copy: an app changing its configuration leaves the preset's alone.
  assert.notEqual(app.fakeTimers.doNotFake, FAKE_TIMERS.doNotFake);
  assert.equal(plugins.fakeTimers, undefined);
});

test('the app project reads jest-expo and msw from appRoot: the plugin on the script transform, the fetch mapping first', () => {
  const root = installed({ ...JEST_EXPO, ...msw('node_modules', '3.0.1'), ...interceptors3('node_modules') });
  const [app, plugins] = createJestConfig({ appRoot: root, moduleNameMapper: { '^@/(.*)$': '<rootDir>/src/$1' } }).projects;
  assert.deepStrictEqual(app.transform, { '\\.mjs$': 'babel-jest', ...scriptTransform(root) });
  assert.deepEqual(Object.keys(app.moduleNameMapper), [MSW_FETCH_INTERCEPTOR, '^@/(.*)$', ...Object.keys(EXPO_MOCKS)]);
  assert.equal(app.moduleNameMapper[MSW_FETCH_INTERCEPTOR], browserFetch(join(root, 'node_modules', '@mswjs', 'interceptors')));
  // The plugins project runs no jest-expo and no msw.
  assert.deepEqual(Object.keys(plugins.transform), ['^.+\\.tsx?$']);
  assert.equal(plugins.moduleNameMapper, undefined);
});

test("an app's own mapping of the fetch interceptor replaces msw 3's", () => {
  const root = installed({ ...msw('node_modules', '3.0.1'), ...interceptors3('node_modules') });
  const { moduleNameMapper } = createJestConfig({ appRoot: root, moduleNameMapper: { [MSW_FETCH_INTERCEPTOR]: '<rootDir>/fetch.js' } }).projects[0];
  assert.equal(moduleNameMapper[MSW_FETCH_INTERCEPTOR], '<rootDir>/fetch.js');
});

test('without jest-expo or msw where it runs, the app project keeps the plain transforms and mappings', () => {
  const root = installed({});
  const [app] = createJestConfig({ appRoot: root }).projects;
  assert.deepStrictEqual(app.transform, { '\\.mjs$': 'babel-jest' });
  assert.deepStrictEqual(app.moduleNameMapper, EXPO_MOCKS);
});

test('appRoot is the working directory by default', (t) => {
  const root = installed({ ...JEST_EXPO, ...msw('node_modules', '3.0.1'), ...interceptors3('node_modules') });
  const before = process.cwd();
  process.chdir(root);
  t.after(() => process.chdir(before));
  assert.deepStrictEqual(createJestConfig().projects[0], createJestConfig({ appRoot: root }).projects[0]);
  assert.ok(MSW_FETCH_INTERCEPTOR in createJestConfig().projects[0].moduleNameMapper);
});

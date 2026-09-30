import assert from 'node:assert/strict';
import { existsSync } from 'node:fs';
import { test } from 'node:test';
import future from './fixtures/template/jest/future.ts';
import today from './fixtures/template/jest/today.ts';
import {
  COLLECT_COVERAGE_FROM,
  CONSOLE_SETUP,
  COVERAGE_PATH_IGNORE_PATTERNS,
  createJestConfig,
  EXPO_MOCKS,
  TEST_PATH_IGNORE_PATTERNS,
  TRANSFORM_PACKAGES,
  transformIgnorePattern,
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

test("the template's future jest.config.ts is today's, with the moved files pointing into the package", () => {
  assert.deepStrictEqual(future, movedIntoThePackage(today));
});

test('today and the future collect coverage from the same files with the same gate', () => {
  assert.deepStrictEqual(future.collectCoverageFrom, today.collectCoverageFrom);
  assert.deepStrictEqual(future.coverageReporters, today.coverageReporters);
  assert.deepStrictEqual(future.coverageThreshold, today.coverageThreshold);
});

test('the files the configuration points into this package exist', () => {
  assert.ok(existsSync(CONSOLE_SETUP), CONSOLE_SETUP);
  for (const stub of Object.values(EXPO_MOCKS)) assert.ok(existsSync(stub), stub);
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

// The Jest configuration every Expo app of this family runs: two projects (the
// app under jest-expo, the config plugins under plain node), the worktree
// ignores, the transforms, the silent-tests guard, stand-ins for three native
// Expo modules, and coverage at 100%. An app passes only its own paths.
//
// Nothing here is imported from jest or jest-expo: a Jest configuration is
// data, and every tool it names ('jest-expo', 'babel-jest',
// 'babel-preset-expo') is resolved by Jest from the app's own root.
import { fileURLToPath } from 'node:url';

/** A path inside this package, absolute, so Jest finds it from any rootDir. */
const own = (relative) => fileURLToPath(new URL(relative, import.meta.url));

/**
 * Claude Code puts git worktrees under `.claude/worktrees/<name>/`: whole
 * checkouts of the repository, each with its own node_modules. Jest's crawl
 * does not read `.gitignore`, so without this it runs every worktree's suites
 * as well, against a second copy of React ("Invalid hook call"). Anchored to
 * `<rootDir>` because a worktree's own root is itself under `.claude/worktrees/`
 * - an unanchored `/\.claude/worktrees/` would ignore every test there.
 * `modulePathIgnorePatterns` keeps their package.json files and `__mocks__`
 * out of the module map, which otherwise reports them as naming collisions.
 */
export const WORKTREES = '<rootDir>/\\.claude/worktrees/';

/** The file every project's `setupFilesAfterEnv` ends with: the silent-tests guard. */
export const CONSOLE_SETUP = own('../jest/setup-console.cjs');

/**
 * Stand-ins for native Expo modules, wired in through `moduleNameMapper`. A
 * module an app does not install is never imported, so mapping it costs
 * nothing.
 */
export const EXPO_MOCKS = {
  '^expo-secure-store$': own('../jest/mocks/expo-secure-store.cjs'),
  '^expo-sqlite/kv-store$': own('../jest/mocks/expo-sqlite-kv-store.cjs'),
  '^expo-updates$': own('../jest/mocks/expo-updates.cjs'),
};

/**
 * Every entry is a claim that the file has no behaviour a test could assert,
 * so the generic list is short; an app appends its own generated and
 * zero-statement paths. Unlike the other coverage options this one is scoped
 * to a project, not to the root configuration, so both projects carry it - a
 * root-level copy is silently ignored when `projects` is set.
 */
export const COVERAGE_PATH_IGNORE_PATTERNS = [
  // Jest's own default, which declaring this option would otherwise drop.
  '/node_modules/',
  // Other checkouts of this repository, not files of this one.
  WORKTREES,
  // Ambient type declarations: erased at build time, no runtime statements.
  '\\.d\\.ts$',
];

/**
 * Packages that ship untranspiled code and so must go through the transform.
 * The (?!\.pnpm/) guard in the pattern skips pnpm's nested
 * `.pnpm/<pkg>/node_modules/` hop, so the list matches against the real inner
 * package name, not the pnpm store directory.
 */
export const TRANSFORM_PACKAGES = [
  '((jest-)?react-native|@react-native(-community)?)',
  'expo(nent)?',
  '@expo(nent)?/.*',
  '@expo-google-fonts/.*',
  'react-navigation',
  '@react-navigation/.*',
  '@sentry/react-native',
  'native-base',
  'react-native-svg',
  '@lingui/.*',
  '@messageformat/.*',
  'msw',
  '@mswjs/.*',
  '@open-draft/.*',
  '@bundled-es-modules/.*',
  'until-async',
  'rettime',
  'outvariant',
  'strict-event-emitter',
  'is-node-process',
  'headers-polyfill',
  'path-to-regexp',
  'cookie',
  'statuses',
  'tough-cookie',
  'picocolors',
  'standard-navigation',
];

/**
 * Paths the app project never collects tests from.
 *
 * `/plugins/` because the app project has no explicit `testMatch`: without
 * it, jest-expo would pick the plugin suites up as well and every plugin test
 * would run twice. `/.workflows/` because CI checks shared-workflows out into
 * the workspace, and it ships its own `*.test.mjs`; jest-expo would pick those
 * up and fail on `import.meta`. `<rootDir>/rules/` holds Semgrep's own
 * `<rule-id>.test.tsx` fixtures (deliberately uninstantiable snippets, never a
 * Jest suite), anchored to the root so an app's own `src/rules/` is still
 * tested.
 */
export const TEST_PATH_IGNORE_PATTERNS = [
  '/node_modules/',
  '/e2e/',
  '/plugins/',
  '/scripts/',
  '<rootDir>/rules/',
  '/\\.workflows/',
  WORKTREES,
];

/** What the coverage gate measures: the app, the local modules' wrappers, the config plugins. */
export const COLLECT_COVERAGE_FROM = [
  'src/**/*.{ts,tsx}',
  // Only the module's public wrapper: everything under `modules/*/src/` is
  // either the `requireNativeModule` bridge or type-only.
  'modules/*/index.ts',
  'plugins/*.ts',
  '!src/**/*.test.*',
  '!plugins/*.test.ts',
];

/**
 * The regular expression for `transformIgnorePatterns`: ignore node_modules,
 * except the packages that have to be transformed.
 */
export const transformIgnorePattern = (packages) =>
  `node_modules/(?!\\.pnpm/)(?!${packages.join('|')})`;

/**
 * The effective Jest configuration.
 *
 * @param {object} [options]
 * @param {string[]} [options.setupFiles] the app project's `setupFiles` (environment variables)
 * @param {string[]} [options.setupFilesAfterEnv] the app project's own setup files; the console guard is appended
 * @param {Record<string, string>} [options.moduleNameMapper] the app's aliases, matched before the Expo stand-ins
 * @param {string[]} [options.coveragePathIgnorePatterns] appended to the generic list, in both projects
 * @param {string[]} [options.testPathIgnorePatterns] appended to the app project's generic list
 * @param {string[]} [options.transformPackages] more packages the app project has to transform
 * @param {string[]} [options.collectCoverageFrom] replaces the generic list
 * @param {boolean} [options.consoleGuard] false leaves the silent-tests guard out (an adopting repository with noisy suites)
 */
export function createJestConfig({
  setupFiles = [],
  setupFilesAfterEnv = [],
  moduleNameMapper = {},
  coveragePathIgnorePatterns = [],
  testPathIgnorePatterns = [],
  transformPackages = [],
  collectCoverageFrom = COLLECT_COVERAGE_FROM,
  consoleGuard = true,
} = {}) {
  const coverageIgnores = [...COVERAGE_PATH_IGNORE_PATTERNS, ...coveragePathIgnorePatterns];
  // Last on purpose: its `afterEach` then runs after RNTL's auto-cleanup and
  // MSW's reset, so an un-acted update surfacing during unmount still fails
  // the test.
  const guard = consoleGuard ? [CONSOLE_SETUP] : [];
  return {
    // Two projects: the app suite (jest-expo, React Native environment) and
    // the config plugins suite (plain node, no React Native preset - plugins
    // run inside the Expo CLI). Project-scoped options (setupFiles,
    // moduleNameMapper, transforms, ...) live inside each project; only the
    // coverage options Jest treats as global stay at the top level.
    projects: [
      {
        displayName: 'app',
        preset: 'jest-expo',
        // 15s, not Jest's 5s: screen-level suites finish well inside a second
        // on an idle machine and have gone over 5s under load, which is a
        // flake, not a real failure.
        testTimeout: 15000,
        setupFiles,
        setupFilesAfterEnv: [...setupFilesAfterEnv, ...guard],
        moduleNameMapper: { ...moduleNameMapper, ...EXPO_MOCKS },
        // Lingui 6 ships `.mjs`, which jest-expo's transform does not cover;
        // Jest merges this with the preset's own `transform` map, so
        // jest-expo's `.[jt]sx?` entry stays intact.
        transform: {
          '\\.mjs$': 'babel-jest',
        },
        transformIgnorePatterns: [
          transformIgnorePattern([...TRANSFORM_PACKAGES, ...transformPackages]),
        ],
        testPathIgnorePatterns: [...TEST_PATH_IGNORE_PATTERNS, ...testPathIgnorePatterns],
        modulePathIgnorePatterns: [WORKTREES],
        coveragePathIgnorePatterns: coverageIgnores,
      },
      {
        displayName: 'plugins',
        testEnvironment: 'node',
        testTimeout: 15000,
        // The console guard applies to both projects; this one needs no other
        // setup, because the app's pulls in React Native and MSW.
        setupFilesAfterEnv: guard,
        testMatch: ['<rootDir>/plugins/**/*.test.ts'],
        modulePathIgnorePatterns: [WORKTREES],
        // `.tsx` is in the pattern even though no plugin suite uses JSX:
        // coverage options are global, so this project also instruments the
        // app's untested `.tsx` files and needs a transform for them.
        transform: {
          '^.+\\.tsx?$': ['babel-jest', { presets: ['babel-preset-expo'] }],
        },
        coveragePathIgnorePatterns: coverageIgnores,
      },
    ],
    collectCoverageFrom,
    // `json-summary` is what `check-coverage-empty` (from
    // @blinkbitcoin/dev-config) reads after the run.
    coverageReporters: ['text', 'lcov', 'json-summary'],
    coverageThreshold: {
      global: { lines: 100, branches: 100, functions: 100, statements: 100 },
    },
  };
}

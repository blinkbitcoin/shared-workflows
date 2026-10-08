// The Jest configuration every Expo app of this family runs: two projects (the
// app under jest-expo, the config plugins under plain node), the worktree
// ignores, the transforms, the silent-tests guard, stand-ins for three native
// Expo modules, what msw 3 needs under jest-expo, and coverage at 100%. An app
// passes only its own paths.
//
// A Jest configuration is data, and every tool it names ('jest-expo',
// 'babel-jest', 'babel-preset-expo') is resolved by Jest from the app's own
// root. Two things are read from the app's installed packages as the
// configuration is built, both from the app's root: jest-expo's script
// transform, which gains one Babel plugin, and the layout of msw's
// interceptors, which decides whether `fetch` needs mapping.
import { createRequire } from 'node:module';
import { join, sep } from 'node:path';
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

/**
 * Every CI job checks shared-workflows out under `.workflows/`: a whole
 * repository with its own package.json files and tests, none of it the app's
 * code. Anchored to `<rootDir>` like the worktrees, so a checkout that itself
 * sits under a `.workflows/` directory still runs its own tests.
 */
export const WORKFLOWS = '<rootDir>/\\.workflows/';

/** The directories no project walks into: module map, tests or coverage. */
export const IGNORED_DIRECTORIES = [WORKTREES, WORKFLOWS];

/** `require` as a module in `directory` would have it, for an app's installed packages. */
const requireFrom = (directory) => createRequire(join(directory, 'package.json'));

/** The file every project's `setupFilesAfterEnv` ends with: the silent-tests guard. */
export const CONSOLE_SETUP = own('./jest/setup-console.cjs');

/**
 * Stand-ins for native Expo modules, wired in through `moduleNameMapper`. A
 * module an app does not install is never imported, so mapping it costs
 * nothing.
 */
export const EXPO_MOCKS = {
  '^expo-secure-store$': own('./jest/mocks/expo-secure-store.cjs'),
  '^expo-sqlite/kv-store$': own('./jest/mocks/expo-sqlite-kv-store.cjs'),
  '^expo-updates$': own('./jest/mocks/expo-updates.cjs'),
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
  // Other checkouts of this repository and of shared-workflows, not files of this one.
  ...IGNORED_DIRECTORIES,
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
  // msw 3's CommonJS build requires these, and they ship only ES modules
  // (`@msw/url`): untransformed, Jest throws "Must use import to load ES Module".
  '@msw/.*',
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
  WORKFLOWS,
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
 * The Babel plugin that gives a dependency its own file as `import.meta.url`
 * (see the file). Without it msw 3's interceptors throw "Invalid URL:
 * ./llhttp/llhttp.wasm" as `msw/node` loads.
 */
export const IMPORT_META_URL_PLUGIN = own('./jest/import-meta-url.cjs');

/** jest-expo's `transform` key for scripts, the entry the plugin is added to. */
export const SCRIPT_TRANSFORM = '\\.[jt]sx?$';

/**
 * jest-expo's script transform with `IMPORT_META_URL_PLUGIN` added to its Babel
 * options, as a `transform` map of one entry; empty when jest-expo is not
 * installed or has no such entry, which leaves its own in place. jest-expo's
 * options (its Babel configuration file, roots and caller) are kept exactly:
 * they are read from its preset as installed in `appRoot`, which resolves
 * them from the working directory.
 */
export function scriptTransform(appRoot) {
  let presetFile;
  try {
    presetFile = requireFrom(appRoot).resolve('jest-expo/jest-preset');
  } catch {
    return {};
  }
  const entry = requireFrom(appRoot)(presetFile).transform?.[SCRIPT_TRANSFORM];
  if (!Array.isArray(entry)) return {};
  const [transformer, options = {}] = entry;
  const plugins = [...(options.plugins ?? []), IMPORT_META_URL_PLUGIN];
  return { [SCRIPT_TRANSFORM]: [transformer, { ...options, plugins }] };
}

/** The `moduleNameMapper` pattern for the module msw imports to intercept `fetch`. */
export const MSW_FETCH_INTERCEPTOR = '^@mswjs/interceptors/fetch$';

/** msw 3's interceptor, for Node: it intercepts at the socket. */
const NODE_FETCH = join('lib', 'node', 'interceptors', 'fetch', 'node.js');

/** The same interceptor's browser build: it replaces `globalThis.fetch`. */
const BROWSER_FETCH = join('lib', 'browser', 'interceptors', 'fetch', 'web.js');

/**
 * Under msw 3, maps its `fetch` interceptor to the browser build, as a
 * `moduleNameMapper` of one entry; empty under msw 2 and when msw is not
 * installed.
 *
 * msw 3's Node interceptor (`@mswjs/interceptors` 0.45) no longer replaces
 * `globalThis.fetch`: it calls the real one and intercepts at the socket. Under
 * jest-expo the global `fetch` is Expo's, which opens no Node socket, so no
 * request reaches msw and Expo's `fetch` fails ("Unsupported BodyInit type").
 * The browser build replaces `globalThis.fetch` the way msw 2's interceptor
 * did. msw 2's (0.41) lays the files out differently
 * (`lib/node/interceptors/fetch/index.cjs`) and needs nothing, so the mapping
 * is added only for msw 3's layout. The interceptors package does not export
 * its package.json, so the path comes from resolving the export msw imports,
 * from msw's own directory.
 */
export function mswFetchMapper(appRoot) {
  let nodeFetch;
  try {
    const msw = requireFrom(appRoot).resolve('msw/package.json');
    nodeFetch = createRequire(msw).resolve('@mswjs/interceptors/fetch');
  } catch {
    return {};
  }
  if (!nodeFetch.endsWith(sep + NODE_FETCH)) return {};
  return { [MSW_FETCH_INTERCEPTOR]: nodeFetch.slice(0, -NODE_FETCH.length) + BROWSER_FETCH };
}

/**
 * The app project's `fakeTimers`: fake timers leave `queueMicrotask` real.
 * msw 3 finishes each request by emitting its response event from a
 * `queueMicrotask` callback, which Jest fakes by default: with fake timers on,
 * `response:mocked` never fires and every request after the first waits for
 * ever, so a screen test stays on its loading state. expo-router's
 * `renderRouter` turns fake timers on itself, and Jest applies this to a bare
 * `jest.useFakeTimers()` too. This holds for every app, with or without msw: a
 * test can no longer step a `queueMicrotask` callback with Jest's timer
 * functions; it runs as the current task ends, as it does outside a test.
 */
export const FAKE_TIMERS = { doNotFake: ['queueMicrotask'] };

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
 * @param {Record<string, string>} [options.moduleNameMapper] the app's aliases, matched after msw 3's `fetch` mapping (the same key replaces it) and before the Expo stand-ins
 * @param {string[]} [options.coveragePathIgnorePatterns] appended to the generic list, in both projects
 * @param {string[]} [options.testPathIgnorePatterns] appended to the app project's generic list
 * @param {string[]} [options.transformPackages] more packages the app project has to transform
 * @param {string[]} [options.collectCoverageFrom] replaces the generic list
 * @param {boolean} [options.consoleGuard] false leaves the silent-tests guard out (an adopting repository with noisy suites)
 * @param {string} [options.appRoot] where jest-expo and msw are read from; the working directory, where Jest and jest-expo run, by default
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
  appRoot = process.cwd(),
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
        moduleNameMapper: { ...mswFetchMapper(appRoot), ...moduleNameMapper, ...EXPO_MOCKS },
        fakeTimers: { doNotFake: [...FAKE_TIMERS.doNotFake] },
        // Lingui 6 ships `.mjs`, which jest-expo's transform does not cover.
        // Jest merges this map with the preset's own `transform`; the
        // `.[jt]sx?` entry replaces jest-expo's with the same transform and
        // options plus the `import.meta.url` plugin.
        transform: {
          '\\.mjs$': 'babel-jest',
          ...scriptTransform(appRoot),
        },
        transformIgnorePatterns: [
          transformIgnorePattern([...TRANSFORM_PACKAGES, ...transformPackages]),
        ],
        testPathIgnorePatterns: [...TEST_PATH_IGNORE_PATTERNS, ...testPathIgnorePatterns],
        modulePathIgnorePatterns: [...IGNORED_DIRECTORIES],
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
        modulePathIgnorePatterns: [...IGNORED_DIRECTORIES],
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
    // @blinkbitcoin/app-tooling) reads after the run.
    coverageReporters: ['text', 'lcov', 'json-summary'],
    coverageThreshold: {
      global: { lines: 100, branches: 100, functions: 100, statements: 100 },
    },
  };
}

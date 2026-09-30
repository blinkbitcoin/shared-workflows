import type { Config } from 'jest';

/**
 * Claude Code puts git worktrees under `.claude/worktrees/<name>/`: whole
 * checkouts of this repository, each with its own node_modules. Jest's crawl
 * does not read `.gitignore`, so without this it runs every worktree's suites
 * as well, against a second copy of React ("Invalid hook call"). Anchored to
 * `<rootDir>` because a worktree's own root is itself under `.claude/worktrees/`
 * - an unanchored `/\.claude/worktrees/` would ignore every test there.
 * `modulePathIgnorePatterns` keeps their package.json files and `__mocks__`
 * out of the module map, which otherwise reports them as naming collisions.
 */
const worktrees = '<rootDir>/\\.claude/worktrees/';

/**
 * Every entry is a claim that the file has no behaviour a test could assert.
 * The thresholds below are 100%, so anything not on this list has to be tested.
 *
 * Unlike the other coverage options this one is scoped to a project, not to the
 * root config, so both projects below spread it in — a root-level copy is
 * silently ignored when `projects` is set.
 */
const coveragePathIgnorePatterns = [
  // Jest's own default, which declaring this option would otherwise drop.
  '/node_modules/',
  // Other checkouts of this repository, not files of this one.
  worktrees,
  // Ambient type declarations: erased at build time, no runtime statements.
  '\\.d\\.ts$',
  // Jest setup files: every suite runs them, but they execute before this
  // project's instrumentation is installed, so they report 0% however
  // thoroughly they run. Not measurable units, rather than untested ones.
  '<rootDir>/src/test/(env|setup|setup\\.plugins)\\.ts$',
  // Jest manual mocks: stand-ins for native modules, wired in through
  // `moduleNameMapper`. Fixtures, not app behaviour.
  '<rootDir>/src/test/mocks/',
  // GraphQL codegen output: written by `make gen-graphql`, reviewed as a diff.
  '<rootDir>/src/graphql/generated/',
  // Compiled Lingui catalogs: written by `make gen-i18n` from the `.po` files.
  '<rootDir>/src/i18n/locales/',
  // Pure re-export barrels. expo-router route files that only re-export the
  // screen or handler they point at carry zero statements, so including them
  // would lift the percentage while asserting nothing. Each still has its own
  // test under `src/__tests__/app/`, pinning what it re-exports.
  '<rootDir>/src/app/\\(tabs\\)/(index|settings)\\.tsx$',
  '<rootDir>/src/app/\\+native-intent\\.tsx$',
  // The `requireNativeModule` binding for the Swift/Kotlin half, plus the
  // type-only file next to it. The wrapper that validates input and maps the
  // missing-module failure is `modules/hello-native/index.ts`, and it is tested.
  '<rootDir>/modules/[^/]+/src/',
];

const config: Config = {
  // Two projects: the app suite (jest-expo, RN environment) and the config
  // plugins suite (plain node, no RN preset — plugins run inside the Expo CLI).
  // Project-scoped options (setupFiles, moduleNameMapper, transforms, …) must
  // live inside each project; only the coverage options Jest treats as global
  // (`collectCoverageFrom`, `coverageReporters`, `coverageThreshold`) stay at
  // the top level.
  projects: [
    {
      displayName: 'app',
      preset: 'jest-expo',
      // 15s, not Jest's 5s. The screen-level RNTL suites finish well inside a
      // second when the machine is idle, but two SettingsScreen tests went over
      // 5s under load, which is a flake, not a real failure.
      testTimeout: 15000,
      setupFiles: ['<rootDir>/src/test/env.ts'],
      setupFilesAfterEnv: ['<rootDir>/src/test/setup.ts'],
      moduleNameMapper: {
        '^@/(.*)$': '<rootDir>/src/$1',
        '^expo-secure-store$': '<rootDir>/src/test/mocks/expo-secure-store.ts',
        '^expo-sqlite/kv-store$': '<rootDir>/src/test/mocks/expo-sqlite-kv-store.ts',
        '^expo-updates$': '<rootDir>/src/test/mocks/expo-updates.ts',
      },
      // Lingui 6 ships `.mjs`, which jest-expo's transform does not cover; Jest
      // merges this with the preset's own `transform` map (see
      // mergeOptionWithPreset in jest-config), so jest-expo's `.[jt]sx?` entry
      // stays intact.
      transform: {
        '\\.mjs$': 'babel-jest',
      },
      // The (?!\.pnpm/) guard skips pnpm's nested `.pnpm/<pkg>/node_modules/` hop so the
      // exclusion list below matches against the real inner package name, not the pnpm store dir.
      transformIgnorePatterns: [
        'node_modules/(?!\\.pnpm/)(?!((jest-)?react-native|@react-native(-community)?)|expo(nent)?|@expo(nent)?/.*|@expo-google-fonts/.*|react-navigation|@react-navigation/.*|@sentry/react-native|native-base|react-native-svg|@lingui/.*|@messageformat/.*|msw|@mswjs/.*|@open-draft/.*|@bundled-es-modules/.*|until-async|rettime|outvariant|strict-event-emitter|is-node-process|headers-polyfill|path-to-regexp|cookie|statuses|tough-cookie|picocolors|standard-navigation)',
      ],
      // `/plugins/` stays ignored here because the app project has no explicit
      // `testMatch`: without it, jest-expo would pick the plugin suites up as
      // well and every plugin test would run twice (once per project).
      // `/.workflows/` because CI checks shared-workflows out into the
      // workspace, and it ships its own `*.test.mjs`. jest-expo would pick
      // those up and fail on `import.meta` - a consumer's Unit job going red
      // over a file the consumer does not own. It is the seventh entry in the
      // guide's `.workflows/` ignore list, added when that repo grew tests.
      // `<rootDir>/rules/` holds Semgrep's own `<rule-id>.test.tsx` fixture
      // convention (paired with `<rule-id>.yaml`, asserted by
      // `semgrep --test rules/` and `make check-security-code`) -
      // deliberately uninstantiable snippets like a bare
      // `AsyncStorage.setItem(...)` with no import, never a Jest suite.
      // Anchored to the repository root, unlike the bare `/plugins/`-style
      // entries above: a consumer's own nested `src/rules/` (an unrelated
      // directory name they are free to use) must still be tested,
      // type-checked and linted normally, matching the root-anchored `rules`
      // entries in `tsconfig.json`'s `exclude`, `biome.json`'s
      // `files.includes`, and `eslint.config.mjs`'s `globalIgnores`.
      testPathIgnorePatterns: [
        '/node_modules/',
        '/e2e/',
        '/plugins/',
        '/scripts/',
        '<rootDir>/rules/',
        '/\\.workflows/',
        worktrees,
      ],
      modulePathIgnorePatterns: [worktrees],
      coveragePathIgnorePatterns,
    },
    {
      displayName: 'plugins',
      testEnvironment: 'node',
      testTimeout: 15000,
      // The console guard applies to both projects; this one gets its own setup
      // file because `src/test/setup.ts` pulls in RNTL and MSW.
      setupFilesAfterEnv: ['<rootDir>/src/test/setup.plugins.ts'],
      testMatch: ['<rootDir>/plugins/**/*.test.ts'],
      modulePathIgnorePatterns: [worktrees],
      // `.tsx` is in the pattern even though no plugin suite uses JSX: coverage
      // options are global, so this project also instruments the app's untested
      // `.tsx` files (e.g. platform variants) and needs a transform for them.
      transform: {
        '^.+\\.tsx?$': ['babel-jest', { presets: ['babel-preset-expo'] }],
      },
      coveragePathIgnorePatterns,
    },
  ],
  collectCoverageFrom: [
    'src/**/*.{ts,tsx}',
    // Only the module's public wrapper: everything under `modules/*/src/` is
    // either the `requireNativeModule` bridge or type-only (see the ignore list).
    'modules/*/index.ts',
    'plugins/*.ts',
    '!src/**/*.test.*',
    '!plugins/*.test.ts',
  ],
  // `json-summary` is what `check-coverage-empty` (from @blinkbitcoin/dev-config)
  // reads after the run.
  coverageReporters: ['text', 'lcov', 'json-summary'],
  coverageThreshold: {
    global: { lines: 100, branches: 100, functions: 100, statements: 100 },
  },
};

export default config;

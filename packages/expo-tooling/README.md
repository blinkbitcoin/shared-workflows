# @blinkbitcoin/expo-tooling

The Expo and React Native counterpart of
[`@blinkbitcoin/dev-config`](../dev-config): the configuration every app of
this family runs — Jest, ESLint, Biome, Metro, Playwright, lefthook,
fingerprint, TypeScript and commitlint — as presets an app extends. The app's
own files shrink to the handful of lines that are genuinely its own: its
paths, its generated code, its scope list.

It comes in the way dev-config does, as a git dependency at the commit the
workflows are pinned to:

```json
"@blinkbitcoin/expo-tooling": "github:blinkbitcoin/shared-workflows#<sha>&path:/packages/expo-tooling"
```

`fix-tooling-pin` and `check-lockfile` from dev-config already handle it, like
any other `packages/<name>` of this repository.

## What each preset is

| Import | What it gives | The app keeps |
| --- | --- | --- |
| `@blinkbitcoin/expo-tooling/jest` | `createJestConfig(options)`: the app and plugins projects, worktree ignores, transforms, the console guard, the Expo stand-ins, 100% thresholds, `json-summary` | setup files, aliases, generated and zero-statement paths |
| `@blinkbitcoin/expo-tooling/jest/console` | `allowConsole`, and the recorder behind the silent-tests guard | nothing |
| `@blinkbitcoin/expo-tooling/jest/mocks/*` | stand-ins for `expo-secure-store`, `expo-sqlite/kv-store`, `expo-updates`, mapped by the Jest preset | nothing |
| `@blinkbitcoin/expo-tooling/eslint` | `createEslintConfig(options)`: generic ignores, Expo's preset, every rule Biome owns switched off, Node globals | generated paths, extra Node files |
| `@blinkbitcoin/expo-tooling/biome` | a Biome base to `extends`: formatter, recommended rules, generic excludes, `noConsole` off for tooling paths | restricted imports, overrides for its own files, generated excludes |
| `@blinkbitcoin/expo-tooling/metro` | `withSharedMetroConfig(config, { web })`: the worktree block, and the web `tslib` and `wasm` fixes | the `getDefaultConfig(__dirname)` call |
| `@blinkbitcoin/expo-tooling/playwright` | `createPlaywrightConfig(options)`: ports and base path from the environment, the mock API and preview servers | the `defineConfig` call |
| `@blinkbitcoin/expo-tooling/lefthook.yml` | the pre-commit, commit-msg and pre-push hooks, for lefthook's `extends:` | hooks of its own |
| `@blinkbitcoin/expo-tooling/fingerprint` | `createFingerprintConfig(options)`: the source skips and the ignore paths `.fingerprintignore` held | nothing |
| `@blinkbitcoin/expo-tooling/tsconfig.base.json` | the strict compiler flags and `types` | `baseUrl`, `paths`, `include`, `exclude`, `ignoreDeprecations` |
| `@blinkbitcoin/expo-tooling/commitlint` | a commitlint base to `extends`: Conventional Commits, no body or footer line limit | the scope list |

The exact file each of the template's configuration files becomes is in
[the consumer guide](../../docs/consumer-guide.md#expo-tooling-presets), along
with how each tool merges a base with the app's file.

## Peer dependencies, nothing bundled

`dependencies` is empty. Every tool a preset names is the app's: `jest`,
`jest-expo`, `eslint`, `eslint-config-expo`, `globals`, `@biomejs/biome`,
`@playwright/test`, `lefthook`, `@expo/fingerprint`, `typescript` and
`@commitlint/config-conventional` are optional peer dependencies, so an app
installs the ones for the presets it uses and pnpm links them to this package.
Two presets import a peer themselves (ESLint's imports `eslint/config`,
`eslint-config-expo` and `globals`; commitlint's base extends
`@commitlint/config-conventional`); the rest are plain data or take what the
app passes in. The lower bounds are a real floor where one exists (`eslint`
9.22 for `eslint/config`, TypeScript 5.0 for an `extends` array, lefthook 2.0
for the hooks file) and otherwise the version the template runs today.

Node 22.12 or later: `metro.config.js` and `fingerprint.config.js` are
CommonJS and `require()` the ES module presets.

## Tests

`make test-package` at the repository root, 100% lines, branches and
functions. Each preset's test evaluates the template's configuration file as it
is today (`fixtures/template/<tool>/today.*`, a byte-for-byte copy) and the
file it becomes (`future.*`), and compares what the two produce. The peers are
not installed here, so `fixtures/stubs/` stands in for them, the same stand-ins
for both files; lefthook is the real one, through `lefthook dump`. The consumer
guide shows each `future.*` file, and `package.test.mjs` holds the two
byte-identical.

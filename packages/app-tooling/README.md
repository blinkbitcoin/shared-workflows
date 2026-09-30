# @blinkbitcoin/app-tooling

The shared app tooling, in one package. Install it as a devDependency in any
repo on the baseline, whatever package manager or toolchain provisioner that
repo uses. Its top level is the developer tooling that is not React Native
specific: the pinned tool table, the checks that enforce it, the contract
checker, the repository guards, the security scanners `check-security.yml`
runs ([Security scanning](#security-scanning)), the CI badge renderer and the
store notes generator the release workflows run ([`gen-store-notes`](#gen-store-notes)),
and the E2E suite runners and web preview server a laptop runs ([End-to-end suites](#end-to-end-suites)). Under
`expo/` are the presets an Expo app extends ([Expo presets](#expo-presets)).

```sh
pnpm add -D @blinkbitcoin/app-tooling   # or npm install --save-dev
```

A consumer of the workflows takes it as a git dependency at the commit the
workflows are pinned to instead ([One commit of shared-workflows](#one-commit-of-shared-workflows)):

```json
"@blinkbitcoin/app-tooling": "github:blinkbitcoin/shared-workflows#<sha>&path:/packages/app-tooling"
```

Node 22.12 or later, for the whole package: an app's `metro.config.js` and
`fingerprint.config.js` are CommonJS and `require()` the ES module presets,
which node does without a flag from 22.12.

## The pinned tool table

`versions.json` is the one place a tool version is written down. Everything
else — `.mise.toml` here, a `flake.nix` elsewhere, a workflow input default —
is checked against it rather than trusted to match.

## `check-tool-versions`

```sh
check-tool-versions                       # every tool in the table
check-tool-versions typos shellcheck      # only the ones this repo uses
```

It asks each tool its own version and compares. That is deliberate: reading
`.mise.toml` would prove only that a file says `24`, and would be useless in a
repo that provisions through Nix. Running `node --version` proves what a
developer and CI will actually run, under any provisioner.

Name the tools your repo actually uses. A repo with no `typos` should not be
told its `typos` is missing.

`match: "major"` pins only the major version, for runtimes deliberately held
loose (`node`, `pnpm`). Everything else is exact.

## `check-contract`

```sh
check-contract                     # this repository, against the contract
check-contract --skeleton          # ...and what would clear every failure
check-contract --json              # the same findings, machine-readable
check-contract --profile checks    # before you have written a caller
```

Answers "is this repository wired up for the shared workflows?" in one report.
Every gate in that family already fails with a good message; what none of them
can do is tell you the *other* eight things that are also missing, because each
runs in its own job and stops at the first. So a repository that does not yet
satisfy the contract learns it serially — a screen of parallel reds, then the
next missing piece one push later. This collapses that into one report, with a
fix per finding.

`check.yml` runs it as its first job. Running it here gets the same answer
before you push.

It reports **blocked** for a gate you asked for that cannot run, and
**degraded** for one where shared-workflows has a fallback — the gate still
runs, just not the one this repository defined. It reads your own
`.github/workflows/` to decide what applies: a repository that never calls
`test-e2e.yml` is not told it is missing Maestro flows.

`contract.json` is the table it reads — what wants each thing, which workflow
input switches it off, whether a fallback exists, and the fix. The consumer
guide's tables are generated from the same file, so the two cannot disagree.
Its `no-copy` rows work the other way round: they block a repository that
still holds its own copy of something this package or the workflows ship, such
as a guard program or `resolve-version.sh`
([No copies of this family](../../docs/consumer-guide.md#no-copies-of-this-family)).

It also holds every call your workflows make to this family against
`interfaces.json`: each reusable workflow's inputs (with their types and which
are required), secrets and outputs, rendered from the workflows themselves.
An input the workflow does not declare, a required one left out, a literal of
the wrong type (`dry-run: 'true'` for a boolean), an undeclared secret, or an
output read that the workflow does not produce are each a blocked finding,
named by file and job. GitHub checks all of that only when the run starts, on
`main`, after the change merged; and a renamed output is worse, because it
reads as empty and a `!= 'false'` gate on it quietly runs every time.

Unlike `check-tool-versions`, this one is specific to the React Native workflow
family rather than to any repository on the baseline.

## Repository guards

Twelve checks for rules a repository on the baseline holds itself to, each a
program and a module (`@blinkbitcoin/app-tooling/<name>`) whose functions a
test can import. The template wrote them first; they live here so the template,
this repository and the next consumer run the same code.

```sh
check-docs-tables [--max 120] [file...]     # a markdown table cell line over the limit
check-diagrams [--all] [file...]            # a mermaid block that does not parse
check-shell-locale [--min-files N]          # LC_ALL=C cmd instead of env LC_ALL=C cmd
check-make-target-names [--require-mise]    # a make target named after the tool it runs
check-workflow-names --group ci=CI ...      # a workflow file or display name outside its group
check-coverage-empty [summary.json]         # a Jest coverage row with nothing to cover
check-make-recipes [--allow T=REASON]       # a make recipe with logic in it, not one call to a tested script
check-test-siblings [--source GLOB=SUFFIX]  # a source file without a test file of its own
check-ignored-directories                   # a tool that walks into .workflows/ or .claude/worktrees/
check-docs [--architecture PREFIX]          # docs freshness, the command table, then three of the above
check-licenses [--allow SPDX]               # a production dependency under a license outside the allowlist
check-code-scanning [--config FILE]         # CodeQL on this machine, with the configuration CI reads
```

- `check-docs-tables` measures each `<br>` segment of a cell's visible text,
  skipping fenced code. With no files it reads `README.md`, `AGENTS.md`,
  `CONTRIBUTING.md`, `SECURITY.md` and `docs/**/*.md`, less `docs/superpowers/`.
- `check-diagrams` renders a diagram of its own first and only then the docs',
  so nothing in a doc can decide whether the gate runs. Offline on a laptop it
  skips with a warning; under `CI` a toolchain that cannot render fails. With no
  files it checks the docs changed against `origin/main`; `--all` checks them
  all. The mermaid CLI version is pinned in the module.
- `check-shell-locale` reads every tracked shell file: scripts, bats files, the
  Makefile and the workflows' `run:` blocks. The prefix makes bash itself
  switch locale, which crashes a forked Homebrew bash on macOS now and then.
  `--min-files N` fails a run that read fewer than N shell files, so a root or
  filter that lost most of them fails rather than passing on the rest.
- `check-make-target-names` takes the tools from `.mise.toml` and the unscoped
  packages in `package.json`, spares `setup-` targets, and fails on an
  `--allow` that no longer applies. A missing `.mise.toml` reads as no tools;
  `--require-mise` fails instead, for a repository that pins its tools there.
  It follows the Makefile's `include` and `-include` lines to the files that
  exist, so a target in a shared `.mk` fragment is held to the rule too.
- `check-workflow-names` requires every file in `.github/workflows` to be
  `PREFIX.yml` or `PREFIX-*.yml` for a group, and, where the group has a
  display name, its `name:` to be `DISPLAY` or `DISPLAY / ...`, with more than
  blanks after the slash. `--min-files N` fails a directory with fewer files.
- `check-coverage-empty` fails on a file with zero statements in a
  `coverage-summary.json`, which reads as 0% while the totals stay at 100%.
- `check-make-recipes` holds every recipe to one line calling one script or
  program (`bash X.sh`, `node X.mjs`, `pnpm exec P`, `pnpm [run] S`), or none
  at all for an aggregate. `&&`, `||`, `;`, a pipe, a redirect, a backtick,
  `$(shell ...)`, a second line or a `\` continuation is logic, which belongs in a
  script its own test covers and that CI and a laptop can run without make. It
  follows `include`s, so a shared `.mk` fragment is held to the same rule, and
  fails on an `--allow` that no longer applies.
- `check-test-siblings` holds every source file to a test file of its own,
  beside it, so a module reached only through a caller's test fails the day
  that caller stops calling it. Its rules are the `testSiblings` section of
  [`app-tooling.json`](#the-configuration-file), or these flags:
  - `--source GLOB=SUFFIX[,SUFFIX]` (repeatable; `sources` in the file, glob to
    a list of suffixes) says which files are sources and what their test is
    called: the name without its last extension, plus a suffix. The first
    source a file matches decides.
  - `--exclude GLOB` (`exclude`) takes a class of files out of scope (generated
    code, test support), and must be a glob or a directory; one naming a single
    file is refused as the allowlist entry it would be, in the file too, and
    one that matches nothing fails.
  - `--mirror FROM/=TO/` (`mirror`, FROM to TO) is for a directory whose every
    file is loaded as something else (expo-router's `src/app/`): its files are
    tested from the same path under TO, a test under FROM fails, and a test
    under TO that mirrors nothing fails.
  - There is no `--allow`, and passing one fails with the reason. The files are
    the tracked ones plus untracked files git does not ignore.
- `check-ignored-directories` asks each tool that walks the tree whether it
  skips `.workflows/` (every CI job's checkout of this repository) and
  `.claude/worktrees/` (Claude Code's whole checkouts of the repository):
  - Jest, Metro and ESLint by behaviour, loading the repository's own
    configuration and ESLint from its node_modules, so install first.
  - Biome, tsc, knip, typos, `.gitignore`, `.semgrepignore` and the CodeQL
    configuration by what their files say.
  - Every zizmor call in a tracked file must pass `--config`, since a worktree's
    `.git` is a file and zizmor would read the outer checkout's policy.
  - A tool whose configuration file is absent is skipped. `--directory DIR`
    (repeatable) replaces the pair.
  - `--worktrees DIR` names the one that holds checkouts of this repository,
    where Jest's patterns must be anchored to `<rootDir>`: a worktree's own root
    is under it.
- `check-docs` is a docs check in one call. Its rules are the `docs` section
  of [`app-tooling.json`](#the-configuration-file) (`architecture`, and
  `allowTargetNames` as target to reason), or the flags below. Its steps, in
  order:
  1. An advisory: paths under an `--architecture PREFIX` changed without a
     change under `--docs` (default `docs/`). A package.json counts only for a
     structural change, not a dependency bump; a Dependabot pull request is
     never warned about.
  2. The command table in `--agents` (default `AGENTS.md`) and the Makefile's
     `##`-documented targets agree both ways, includes followed.
  3. `check-make-target-names`, each `--allow-target-name TARGET=REASON` passed
     as its `--allow`.
  4. `check-docs-tables`.
  5. `check-diagrams`, with `--all` under CI.

  The advisory compares a pull request with `origin/$BASE_REF`, a push with
  `HEAD~1` and a laptop with `origin/<--default-branch>` (default `main`), and
  fails open, out loud, when it cannot.
- `check-licenses` reads `pnpm licenses list --json --prod` and fails on a
  package whose SPDX expression the allowlist does not satisfy: every conjunct
  of an AND, one alternative of an OR. The allowlist is the organisation's
  (`MIT`, `Apache-2.0`, `BSD-2-Clause`, `BSD-3-Clause`, `ISC`, `0BSD`,
  `CC0-1.0`, `Unlicense`, `MPL-2.0`, `CC-BY-4.0`, `Python-2.0`,
  `BlueOak-1.0.0`) plus each `--allow` the repository adds.
- `check-code-scanning` runs CodeQL on this machine with the language, query
  suite, packs and `paths-ignore` of the configuration `check-code-scanning.yml` reads
  (`--config`, default `.github/codeql/codeql-config.yml`), so an inline
  `// codeql[rule-id]` marker shows as suppressing its finding or not before a
  push. It needs `codeql` on PATH or the `gh codeql` extension, writes to
  `.codeql/`, and fails while a finding is open. Only
  `javascript-typescript` is mapped, and an entry it cannot map stops the run
  rather than analysing less than CI.

`make help` is a program too, so the one-liner every Makefile carried
(`grep ... $(MAKEFILE_LIST) | sort | awk ...`) is not logic in a recipe:

```sh
help [--root DIR]    # every ##-documented target, sorted, includes followed
```

### The configuration file

A repository's own rules for these programs live in one file at its root,
`app-tooling.json`, named after the package, with a section per program, so
each make recipe is one short call and the rules are data a reviewer reads in
one place:

```json
{
  "testSiblings": {
    "sources": {
      "scripts/**/*.{mjs,sh}": [".test.mjs"],
      "src/**/*.{ts,tsx}": [".test.ts", ".test.tsx"],
      "plugins/*.ts": [".test.ts", ".test.tsx"],
      "modules/*/index.ts": [".test.ts", ".test.tsx"]
    },
    "exclude": ["src/graphql/generated/**", "src/i18n/locales/**", "src/test/**", "src/__tests__/**", "**/*.d.ts"],
    "mirror": { "src/app/": "src/__tests__/app/" }
  },
  "docs": {
    "architecture": ["app.config.ts", "plugins/", "modules/", "src/graphql/", "scripts/", "Makefile"],
    "allowTargetNames": {
      "gen-graphql": "GraphQL is what it generates, the typed documents, not the tool that does it"
    }
  }
}
```

That is the template's file. The file is optional, and so is each section.
A flag overrides its own field: any `--source` replaces `sources`, any
`--architecture` replaces `architecture`, and so on, and the other fields still
come from the file. A file that is there and wrong exits 2 with the reason:
JSON that does not parse, a section or key this version does not know (an
`excludes` written for `exclude` would otherwise check nothing), a field of the wrong type, or
a single-file exclude.

### How the template calls them

Once the template takes the release that ships these, each of its own copies
becomes one line:

| Target or script | The call |
| --- | --- |
| `make help` | `pnpm exec help` |
| `check-docs` | `pnpm exec check-docs` |
| `test-scripts` (siblings) | `pnpm exec check-test-siblings` |
| `check-ignored-directories` | `pnpm exec check-ignored-directories` |
| `check:licenses` | `check-licenses` |
| `check:generated` | `bash node_modules/@blinkbitcoin/app-tooling/checks/generated.sh` |
| `check-code-scanning` | `pnpm exec check-code-scanning` |
| `check:expo-health` | `bash node_modules/@blinkbitcoin/app-tooling/checks/expo-health.sh` |
| lefthook `post-merge` | `bash node_modules/@blinkbitcoin/app-tooling/hooks/install-if-lockfile-changed.sh post-merge {1}` |
| lefthook `post-checkout` | `bash node_modules/@blinkbitcoin/app-tooling/hooks/install-if-lockfile-changed.sh post-checkout {1} {2} {3}` |
| `setup-maestro` | `MAESTRO_DIR=... bash node_modules/@blinkbitcoin/app-tooling/ci/maestro-install.sh` |

Each deleted copy then has a `no-copy` row in `contract.json`, so it cannot
come back.

## Expo presets

The configuration every Expo app of this family runs — Jest, ESLint, Biome,
Metro, Playwright, lefthook, fingerprint, TypeScript and commitlint — as
presets an app extends, under `expo/`. The app's own files shrink to the
handful of lines that are genuinely its own: its paths, its generated code, its
scope list.

| Import | What it gives | The app keeps |
| --- | --- | --- |
| `@blinkbitcoin/app-tooling/expo/jest` | `createJestConfig(options)`: the app and plugins projects, the ignored directories,<br>transforms, the console guard, the Expo stand-ins, 100% thresholds, `json-summary` | setup files, aliases, generated and zero-statement paths |
| `@blinkbitcoin/app-tooling/expo/jest/console` | `allowConsole`, and the recorder behind the silent-tests guard | nothing |
| `@blinkbitcoin/app-tooling/expo/jest/mocks/*` | stand-ins for `expo-secure-store`, `expo-sqlite/kv-store`, `expo-updates`,<br>mapped by the Jest preset | nothing |
| `@blinkbitcoin/app-tooling/expo/eslint` | `createEslintConfig(options)`: generic ignores, Expo's preset, every rule Biome owns<br>switched off, Node globals | generated paths, extra Node files |
| `@blinkbitcoin/app-tooling/expo/biome` | a Biome base to `extends`: formatter, recommended rules, generic excludes,<br>`noConsole` off for tooling paths | restricted imports, overrides for its own files, generated excludes |
| `@blinkbitcoin/app-tooling/expo/metro` | `withSharedMetroConfig(config, { web })`: the worktree block, and the web `tslib`<br>and `wasm` fixes | the `getDefaultConfig(__dirname)` call |
| `@blinkbitcoin/app-tooling/expo/playwright` | `createPlaywrightConfig(options)`: ports and base path from the environment,<br>the mock API and preview servers | the `defineConfig` call |
| `@blinkbitcoin/app-tooling/expo/lefthook.yml` | the pre-commit, commit-msg and pre-push hooks, for lefthook's `extends:` | hooks of its own |
| `@blinkbitcoin/app-tooling/expo/fingerprint` | `createFingerprintConfig(options)`: the source skips and the ignore paths<br>`.fingerprintignore` held | nothing |
| `@blinkbitcoin/app-tooling/expo/tsconfig.base.json` | the strict compiler flags and `types` | `baseUrl`, `paths`, `include`, `exclude`, `ignoreDeprecations` |
| `@blinkbitcoin/app-tooling/expo/commitlint` | a commitlint base to `extends`: Conventional Commits, no body or footer line limit | the scope list |

lefthook reads its `extends:` as a path, not a package export:
`node_modules/@blinkbitcoin/app-tooling/expo/lefthook.yml`.

The exact file each of the template's configuration files becomes is in
[the consumer guide](../../docs/consumer-guide.md#expo-presets), along with how
each tool merges a base with the app's file.

### Peer dependencies, nothing bundled

`dependencies` is empty. Every tool a preset names is the app's: `jest`,
`jest-expo`, `eslint`, `eslint-config-expo`, `globals`, `@biomejs/biome`,
`@playwright/test`, `lefthook`, `@expo/fingerprint`, `typescript` and
`@commitlint/config-conventional` are optional peer dependencies, so an app
installs the ones for the presets it uses and pnpm links them to this package;
a repository that uses none of the presets installs none of them. Two presets
import a peer themselves (ESLint's imports `eslint/config`,
`eslint-config-expo` and `globals`; commitlint's base extends
`@commitlint/config-conventional`); the rest are plain data or take what the
app passes in. The lower bounds are a real floor where one exists (`eslint`
9.22 for `eslint/config`, TypeScript 5.0 for an `extends` array, lefthook 2.0
for the hooks file) and otherwise the version the template runs today.

### Tests

`make test-package` at the repository root, 100% lines, branches and
functions, like every other module here. Each preset's test sits at the
package root beside the others (`expo/eslint.mjs` has `eslint.test.mjs`) and
evaluates the template's configuration file as it is today
(`fixtures/template/<tool>/today.*`, a byte-for-byte copy) and the file it
becomes (`future.*`), and compares what the two produce. The peers are not
installed here, so `fixtures/stubs/` stands in for them, the same stand-ins
for both files; lefthook is the real one, through `lefthook dump`. The
consumer guide shows each `future.*` file, and `package.test.mjs` holds the
two byte-identical.

## One commit of shared-workflows

A consumer calls the workflows pinned to a commit SHA and takes this package
as a git dependency at that same commit. Dependabot moves the `uses:`
pins and cannot move a git dependency with them, so two programs keep the rest
in step:

```sh
fix-tooling-pin [--root DIR]    # move every @blinkbitcoin/* git dependency to the workflows pin, then pnpm install
check-lockfile [--root DIR]     # every lockfile resolution is the npm registry, or this family at the pin
```

- `fix-tooling-pin` refuses to run while the calls pin more than one commit, a
  branch or tag, or a SHA with no `# vX.Y.Z` beside it. After the install it
  checks the lockfile, so a pin it could not reach fails.
- `check-lockfile` allows one git source, shared-workflows' `packages/<name>` at
  the workflows pin. CI already runs that commit's code, so installing it adds
  no trust. Another repository, path or commit fails, and so does every git
  source when the calls pin no single commit.
- `check-contract`'s `pin.one-commit` row asserts the same agreement:
  every call, and each package in `package.json` and `pnpm-lock.yaml`.

## CI badges

`gen-badges` draws the badges `publish-badges.yml` publishes to a
consumer's `gh-pages`: coverage (line coverage from Jest's
`coverage/coverage-summary.json`), Unit, E2E and Security, each a shields.io
"flat" SVG plus its endpoint JSON, with no dependency. `publish-badges.yml`
runs it from its own checkout of this repository unless the caller names a
script of its own in `badges-script`, so a consumer needs nothing for CI. A
laptop runs the same program from the installed package:

```sh
BADGE_UNIT=success BADGE_E2E=skipped gen-badges   # every badge the environment asks for, into coverage/badge
gen-coverage-badge [--status failing|pending] [--out DIR] [--summary FILE]
gen-status-badge <name> <label> <success|failure|cancelled|skipped> [--out DIR]
```

- `gen-badges` takes no arguments. It reads `BADGE_UNIT` and `BADGE_E2E`
  (GitHub job results), `BADGE_UNIT_LABEL` / `BADGE_E2E_LABEL`,
  `BADGE_COVERAGE` (`measure`, `failing`, `pending` or `skip`),
  `BADGE_COVERAGE_SUMMARY`, `BADGE_OUT_DIR`, and `BADGE_SECURITY` /
  `BADGE_SECURITY_LABEL` (`check-security.yml`'s verdict line).
- Only a Unit *failure* draws the red coverage placeholder. A skipped Unit
  draws no coverage badge, and no verdict draws no Security badge, so
  publishing leaves the ones already published.
- An unknown job result, verdict or colour exits 1 rather than drawing a green
  badge.
- `gen-coverage-badge` and `gen-status-badge` draw one badge each, with the same code.

## The checks CI runs, for a laptop

`check.yml` runs four shell checks from this repository. The package
carries byte-identical copies, so a consumer's `make check` runs exactly what
CI runs, at the same commit:

```sh
bash node_modules/@blinkbitcoin/app-tooling/checks/generated.sh    # runs your gen:i18n and gen:graphql, fails on a diff under their paths
bash node_modules/@blinkbitcoin/app-tooling/checks/secrets.sh      # gitleaks over the whole history, at the pinned version
bash node_modules/@blinkbitcoin/app-tooling/checks/expo-health.sh  # Expo SDK drift as a warning, then expo-doctor
bash node_modules/@blinkbitcoin/app-tooling/ci/check-ci.sh         # actionlint, zizmor and shellcheck at the pinned versions
```

- **Paths:**
  - `I18N_PATHS` defaults to `src/i18n/locales`.
  - `GRAPHQL_PATHS` defaults to `src/graphql/generated`.
  - `WORKFLOWS_SHELLCHECK_PATHS` names the directories shellcheck lints (default `scripts`).
- **zizmor policy:** a repository without its own `.github/zizmor.yml` gets this family's, which the package carries as `zizmor.yml`.
- **The Expo health check:** `expo install --check` is advisory. Drift is printed, counted in a warning (an annotation under Actions) and never fails: Expo publishes patches most weeks, and a release cooldown refuses each for a day. Doctor then runs with its own version check off, and its status is the gate's. It is your pinned `expo-doctor` devDependency, or the latest through `pnpm dlx`; with no `expo` dependency the drift half is skipped.
- **Run with `bash`, not as a program:** the scripts source `lib/` beside them, and a `node_modules/.bin` link would break that.

## Security scanning

`check-security.yml` runs the scanners under `scripts/security/` in
shared-workflows, and the modules they call (`lib/security-*.mjs`: the
settings resolver, the SARIF helpers, the bundle, binaries and review checks,
and the verdict). The package carries byte-identical copies of the runners in
`security/`, beside those modules, so a laptop runs what CI runs:

```sh
pnpm exec check-security              # every job security-settings.json switches on, then the verdict
pnpm exec check-security code bundle  # those jobs only, then their verdict
```

- **What you keep:** `security-settings.json` at your repository root, which is
  optional. `security-settings.json` in this package is every key at its
  default, with a `$comment` beside each option, ready to copy. You also keep
  the files the settings name: your Semgrep rules (`jobs.code.rules`) and, if
  you need one, a `.mobsf` with reasoned mobsfscan suppressions. You keep no
  scanner code. A `scripts/security/` in your repository is a
  `no-copy.security` failure in the contract check.
- **The jobs:**
  - `dependencies`: osv-scanner over `pnpm-lock.yaml`.
  - `code`: Semgrep's TypeScript, secrets and OWASP packs plus your rules.
  - `policy`: your `pnpm-workspace.yaml` install policy.
  - `sbom`: a CycloneDX bill from the lockfile.
  - `bundle`: `expo export`, then what the bundle gives away.
  - `mobile`: mobsfscan over a fresh Expo prebuild.
  - `binaries`: MASTG checks over `APK=` / `IPA=`.
  - `review` and `review-codebase`: the LLM reviews. These are off until a
    provider, a model and a key are set.
- **Missing tools:** a tool that is not installed is a skip on a laptop and a
  failure under `CI`.
- **Output:** one SARIF per job in `.security/` (`SECURITY_DIR`).
- **Exit code:** the verdict's. The program exits 1 while a finding blocks.

## `gen-store-notes`

```sh
gen-store-notes --from-commits [RANGE] --out -                   # since the last v* tag, as JSON on stdout
gen-store-notes --from-body RELEASE_BODY.md --body-section --out dist/
gen-store-notes --tag v1.4.0                                     # that release's body, read with gh
gen-store-notes --pr 67                                          # that pull request's body, read with gh
gen-store-notes --preview                                        # --tag/--pr, else $TAG/$PR, else the commits
gen-store-notes --help
```

The store notes for a build, for the app in the working directory:
grouped plain-text prose (New, Improved, Fixed) from a release-please body or
from conventional commit subjects, cut to each store's limit, written as
`store-notes.json` and `store-notes.txt` for the lanes. `build-prepare.yml` and
`pr-store-notes.yml` run this program from the workflows checkout, so a
consumer ships no generator of its own (the contract's `no-copy.gen-store-notes`
row).

- **Source:** exactly one of `--from-body`, `--from-commits`, `--tag` or `--pr`.
  `--tag` and `--pr` read the body with the GitHub CLI (`gh release view` and
  `gh pr view`, in the working directory's repository) and imply
  `--body-section`. A missing `gh`, a tag or pull request that is not there,
  and an empty body each fail with the reason.
- **`--preview`:** the source a laptop preview wants, with no logic in the
  caller: `--tag` or `--pr` when given, else `$TAG`, else `$PR`, else the
  commits since the last `v*` tag. Only `--preview` reads `TAG` and `PR`, so a
  CI step that happens to carry either keeps its source. A make target is one
  line, and make passes its command-line variables through the environment:

  ```make
  store-notes: ## Preview store notes for HEAD (TAG=vX.Y.Z uses that release body, PR=N that release PR's body)
  	pnpm exec gen-store-notes --preview
  ```

- **Locales:** `--locales a,b`, else `$STORE_NOTES_LOCALES`, else the locale
  directories under `fastlane/metadata/ios`, else `en-US`.
- **LLM pass:** optional, with `STORE_NOTES_LLM_PROVIDER` (`anthropic` or
  `openai`), `STORE_NOTES_LLM_MODEL`, `STORE_NOTES_LLM_EFFORT`,
  `STORE_NOTES_LLM_EXTRA_PARAMS`, `OPENAI_BASE_URL` and the provider's API
  key. An answer that fails validation falls back to the deterministic notes.
- **Prompt:** `store-notes.prompt.md` in this package, which owns the locales,
  limits and answer format the generator validates, then the app's own
  `store-notes.prompt.md` when it keeps one, for its product and tone. The
  app's part may use `{{locales}}` and `{{limit}}` too.

The provider adapters are exported for an app's own LLM calls:
`@blinkbitcoin/app-tooling/llm` (`adapterFor`, `KEY_ENV`, `EFFORTS`,
`parseEffort`, `parseExtraParams`) and `@blinkbitcoin/app-tooling/llm-request`
(`thinks`, `mergeRequest`, `unfence`). They use `fetch` and nothing else.

The consumer guide's
[Store notes](../../docs/consumer-guide.md#store-notes) section has the
whole contract, with an example of what an app adds to the prompt.

## Git hooks and machine setup

Two more scripts, for a repository's own hooks and setup rather than for CI:

```sh
bash node_modules/@blinkbitcoin/app-tooling/hooks/install-if-lockfile-changed.sh post-merge {1}
bash node_modules/@blinkbitcoin/app-tooling/hooks/install-if-lockfile-changed.sh post-checkout {1} {2} {3}
bash node_modules/@blinkbitcoin/app-tooling/ci/maestro-install.sh
```

- `hooks/install-if-lockfile-changed.sh` reinstalls dependencies when a merge or
  a branch checkout moved the lockfile, from lefthook's `post-merge` and
  `post-checkout` with git's own hook arguments. It works out the revisions
  itself: lefthook's `{1}` expands inside `HEAD@{1}`. `WORKFLOWS_LOCKFILE`
  (default `pnpm-lock.yaml`) and `WORKFLOWS_INSTALL_CMD` (default
  `pnpm install --frozen-lockfile`) change what it watches and runs.
- `ci/maestro-install.sh` installs Maestro at the pinned version from the
  release archive, checked against its pinned SHA-256: the script the `maestro`
  action runs. `MAESTRO_DIR` (default `~/.maestro`) is where it goes;
  `MAESTRO_VERSION` with its `MAESTRO_SHA256` picks another version.

### Machine setup and the doctor

A machine with [mise](https://mise.jdx.dev) becomes one that builds and tests
the app in the current directory. Run each script from the app's root; each is
idempotent, so it is also the first thing to re-run when the toolchain
misbehaves:

```sh
bash node_modules/@blinkbitcoin/app-tooling/setup/all.sh [--yes] [--boot]   # all of the below, then the doctor
bash node_modules/@blinkbitcoin/app-tooling/setup/toolchain.sh              # mise's pinned tools, watchman, the app's install
bash node_modules/@blinkbitcoin/app-tooling/setup/android.sh [--yes] [--boot]  # SDK, React Native's SDK pins, the emulator
bash node_modules/@blinkbitcoin/app-tooling/setup/ios.sh [--boot]             # Xcode checks, the simulator runtime, CocoaPods
pnpm exec doctor                                                              # what is installed, and the fix for what is not
```

- **Pins:** the Android command-line tools, the emulator, CocoaPods and Maestro
  are pinned in `lib/versions.sh`. The SDK packages React Native builds with
  come from the app's own `node_modules/react-native`.
- **Install step:** `toolchain.sh` runs the app's `make install` when its
  Makefile has one. Otherwise it runs `pnpm install --frozen-lockfile`, and
  `bundle install` when there is a Gemfile.
- **`ANDROID_HOME`:** `android.sh` records it in the app's `.env.local`.
- **The doctor's checks:** `doctor.requirements.json` lists the tools, commands
  and environment the doctor checks, each with the script that fixes it. An app
  adds or replaces entries by name in its own `doctor.requirements.json`, and
  drops one with `"skip": true`. An entry with `when` applies only when that
  file exists (the Ruby gems only where there is a Gemfile).

## End-to-end suites

`e2e/` holds byte-identical copies of the scripts `test-e2e.yml` runs on the
device, so a laptop launches the app and runs the Maestro flows the way CI
does: the same deep link, the same retry once on a real failure, and the same
check that the suite ran flows at all. From the app's root, with the app
installed and Metro running:

```sh
e2e=node_modules/@blinkbitcoin/app-tooling/e2e
bash $e2e/ios-simulator.sh pick                  # the booted iPhone simulator, remembered in WORKFLOWS_OUT
bash $e2e/app-launch.sh ios                      # the dev client's deep link to Metro
bash $e2e/ios-maestro.sh [maestro arguments]     # the suite, retried once, junit in WORKFLOWS_OUT
bash $e2e/android-maestro.sh [maestro arguments] # install the debug APK, reverse the ports, launch, run, forensics
```

- **Ports and hooks:** `WORKFLOWS_METRO_PORT` (default 8081),
  `WORKFLOWS_MOCK_API_PORT` (8082, reversed into the emulator) and
  `WORKFLOWS_E2E_SETUP_SCRIPT` / `WORKFLOWS_E2E_TEARDOWN_SCRIPT`, scripts
  relative to the app's root run around the suite. Nothing here derives a port:
  an app exports its own before calling these.
- **Metro you started yourself** writes no `metro.log`; when it answers on its
  port, `app-launch.sh` launches without waiting for the bundle receipt.
- **The app id and URL scheme** come from `expo config` (`pnpm`, `yq`), unless
  `WORKFLOWS_APP_ID` is set. `ios-simulator.sh pick` needs `jq`.
- **Every variable** is in the environment table of `scripts/e2e/README.md` in
  shared-workflows.

`serve-dist` is the web suite's preview server, and the `expo/playwright`
preset's default `previewCommand`. It serves `dist/` in the current directory
(or the directory it is given) the way GitHub Pages does: under
`EXPO_PUBLIC_BASE_URL`, `/settings` from `settings.html`, and `404.html` with a
404 for a path with no file. The port is `WEB_PREVIEW_PORT`; it fails, naming
the variable, when that is unset, and when there is no export to serve.

```sh
pnpm exec serve-dist          # dist/ on WEB_PREVIEW_PORT
pnpm exec serve-dist build    # another directory
```

## Release scripts

`release/verify-ios.sh <ipa-or-app> [--no-signing] [--dsym DIR]` and
`release/verify-android.sh <aab> <apk> [--cert-sha256 X]` are the release
artifact gates your fastlane `verify` lanes run, with `lib/verify-common.sh`
beside them. Run them from the repository root (they read `build-info.json`,
`.env.example` and the store metadata there, and skip what is absent), with
`bash`.

`release/resolve-version.sh` and `release/build-info.sh` are the scripts
`build-prepare.yml` runs to decide a build's version and build number and to
write its `build-info.json`, with the two libraries they source in `lib/`. A
consumer runs them on a laptop from the installed package, so `make version`
there answers exactly what CI will build:

```sh
bash node_modules/@blinkbitcoin/app-tooling/release/resolve-version.sh [dir]
bash node_modules/@blinkbitcoin/app-tooling/release/build-info.sh --standalone
```

`--standalone` is for a laptop, where no earlier step ran: it resolves the
version and build number and computes both fingerprints (the consumer's
`fingerprint:generate`) for whatever is not already in the environment. In CI,
without it, a missing version stays fatal.

They are byte-identical copies of `scripts/release/` and `scripts/lib/` in
shared-workflows, refreshed by `scripts/self/package-copies.sh --write` and
held identical on every commit by `test/package-copies.bats`, so they cannot
say one thing on a laptop and another in a release.

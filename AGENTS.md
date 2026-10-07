# Agent guide

The shared engineering baseline, in two halves. Reusable GitHub Actions
workflows, composite actions and bash scripts for building, testing and
releasing React Native apps, Expo or bare; and the one package a repo installs,
`packages/app-tooling`, published as `@blinkbitcoin/app-tooling`: the
developer tooling that is not React Native specific at its top level, and
under `expo/` the Jest, ESLint, Biome, Metro, Playwright, lefthook,
fingerprint, TypeScript and commitlint presets an Expo app extends. Consumers
pin `@v0` and call the workflows; nothing here is copied into their repos. The published
contract is [`docs/consumer-guide.md`](docs/consumer-guide.md) — a change to an
input, output, secret or env var is a change to every app that pins this repo.

Read this file before touching anything. `make help` is the source of truth for
commands, and `test/docs-contract.bats` fails the build if it and the table
below drift apart.

## Layout

```
.github/workflows/  the reusable workflows (workflow_call) + this repo's self-* CI
.github/actions/    composite actions (setup, maestro, forensics, free-disk, native-key)
scripts/checks/     the check.yml steps (audit, commits, expo-health and expo-only, generated, secrets)
scripts/ci/         shared CI plumbing (changed-class, check-ci, pnpm-install, tool-version, gh-pages badges)
scripts/e2e/        simulators, emulators, Metro, Maestro, forensics collection
scripts/native/     prebuild, pods, iOS/Android builds and packaging; expo/ and bare/ hold
                    each native stack's prebuild, app-config, metro-start and fingerprint
scripts/ota/        expo-updates export, fingerprint gate, publish, smoke
scripts/release/    version and store notes resolution, fastlane invocation, release assets,
                    the artifact verifiers (verify-ios, verify-android; lib/verify-common.sh),
                    the release PR's dispatches (dispatch-release-pr-ci, dispatch-at-tag)
scripts/security/   check-security.yml: one scanner runner per job and their lib/runner.sh,
                    scan.sh (every job, then the verdict), and the CI bridges
                    (settings, run-job, verdict, label-sarif, binaries-fetch)
scripts/setup/      a consumer's machine setup (toolchain, android, ios, all), pins in lib/versions.sh
                    (generated from packages/app-tooling/versions.json)
scripts/web/        web export, Playwright install and run
scripts/hooks/      git hooks a consumer installs from the package (install-if-lockfile-changed)
scripts/self/       this repo's own upkeep (check-version-pins, render-versions, tag-major, smoke-local,
                    package-copies, render-contract-table, check-store-notes-section,
                    changed-gates)
scripts/lib/        sourced bash helpers (common, versions, *-env, expo-config,
                    changed-files) and native-stack, the dispatch to scripts/native/<stack>/;
                    e2e-env is one entry over shared-env (shared with release-env) and
                    e2e-app, e2e-ios, e2e-maestro and e2e-metro
test/               the bats suite + fixtures/ (consumer-min, the Expo caller the guide is held to;
                    consumer-bare, a bare React Native app; both kept byte-identical to the guide)
plugins/            store-release, the Claude Code plugin apps install (four store skills, each
                    with its offline suite under skills/<name>/tests); .claude-plugin/ at the
                    root is the marketplace that offers it
packages/           app-tooling (tooling any repo installs; expo/ holds the Expo presets,
                    security/ the scanner copies and lib/security-*.mjs their modules,
                    lib/native-stack.mjs the Expo-or-bare rule every part applies,
                    e2e/ the Maestro suite runner copies, bin/serve-dist.mjs the web preview,
                    fixtures/template/ the template's files, before and after)
deploy/ota/         the self-hosted OTA update server (Docker Compose), only needed with OTA on
docs/               consumer-guide, adopting-an-existing-repo, release-runbook, ota, security,
                    decisions/ (the architecture decision records), cache-keys, forensics,
                    runners; README.md is the index
```

## Commands

Every row is a make target; nothing here is run through a package manager.

| Target | |
|---|---|
| `make setup-hooks` | Install the git hooks (lefthook, from `.mise.toml`) — clone-wide, see the worktree rule |
| `make check` | Everything self-ci runs: `check-ci`, the four test suites, the version checks, `check-spell` and `check-secrets` |
| `make check-ci` | The CI code: shellcheck over every script under `scripts/` (bash strict), actionlint over the workflows and composite actions, and zizmor's security audit of both (offline, medium and up; policy in `.github/zizmor.yml`, passed with `--config`) |
| `make test` | Every test suite: `test-unit`, `test-package`, `test-scripts` and `test-fastlane` |
| `make test-unit` | The bats suite over the scripts, the workflows' shape and the docs' facts |
| `make test-package` | `node:test` over every package under `packages/`, 100% lines, branches and functions |
| `make test-scripts` | `node:test` for the Node scripts under `scripts/`, one test file each, 100% coverage |
| `make test-fastlane` | Unit tests of the Ruby lanes the package ships (`packages/app-tooling/fastlane`), under Bundler, gems in `.gems/` |
| `make check-version-pins` | Fail when `scripts/lib/versions.sh` or the `[tools]` block of `.mise.toml` is not what `packages/app-tooling/versions.json` generates, or a workflow default disagrees with it |
| `make check-tool-versions` | Fail when an installed tool is not the version `packages/app-tooling/versions.json` pins |
| `make check-spell` | typos over the whole repo |
| `make check-secrets` | Scan the whole git history for committed secrets (gitleaks) |
| `make test-smoke-local` | Prepare against the template with nektos/act — Docker and a pushed branch required; not part of `check` (CONTRIBUTING.md, "Running the release pipeline locally") |
| `make test-smoke-local-android` | `test-smoke-local`, then the unsigned Android build, amd64 with a provisioned Android SDK |
| `make help` | Show every target with its description |

## Rules of the road

- **Do all branch work in a git worktree**
  (`git worktree add ../shared-workflows-<topic> -b <branch> origin/main`),
  never by switching branches in the shared clone: several agent sessions share
  that checkout, and a commit made there lands on whatever branch another
  session left checked out. **`make setup-hooks` is the one thing that is not
  worktree-scoped:** a worktree shares `.git/hooks` with the main checkout, so
  running it from a topic worktree makes these hooks live in every worktree of
  the clone. That is intended once this is on `main` — one `make setup-hooks` per
  physical clone — but a branch that changes `lefthook.yml` changes what every
  sibling worktree runs. `mise exec -- lefthook uninstall` reverses it.
- **Prove the checkout is current before reading a line of it.** A worktree
  your tooling made for you may have been cut from a local `main` that is
  weeks old, and a review of stale code is guessing: one session reviewed a
  tree 117 commits behind and reported findings in files that had since moved
  or been fixed. Before any review, investigation or change, run
  `git fetch origin` and then `git rev-list --count HEAD..origin/main`; it must
  print `0`. If it does not and the branch has no commits of its own, move it
  with `git merge --ff-only origin/main`; if it has commits, rebase them onto
  `origin/main` first. Name the commit you worked from (`git rev-parse --short
  HEAD`) in the review or PR, and fetch again before pushing.
- **The consumer guide is the contract.** Adding, renaming or re-defaulting a
  workflow input, output or secret without the matching
  `docs/consumer-guide.md` row is a breaking change shipped silently.
  `test/consumer-contract.bats` holds the guide and the fixtures under
  `test/fixtures/consumer-min/` byte-identical — when it fails, both copies
  move together or neither does. A real consumer passes inputs of its own, so
  it is held to the fixture only where it must not diverge: its `ci.yml`
  trigger block, which is where a second docs rule (`paths-ignore`) would creep
  back in beside `check.yml`'s classifier.
- **Anything generic lives here, and a consumer only calls it.** That covers
  code (checks, runners, scanners, release scripts, test and build presets)
  and it covers the pipeline itself: which jobs run, in what order, behind
  which gates, and what they are called. A consumer keeps its own settings,
  allowlists, baselines and prompts, and thin callers of about 20 lines: the
  trigger, one `uses:` at the pin, its variables and secrets. If a change
  here needs a consumer to rename, reorder or rewrite jobs, the change is in
  the wrong place. When a consumer's copy of something is deleted, add a
  `no-copy` row to `packages/app-tooling/contract.json`, so the copy cannot
  come back.
- **Every PR tests everything it adds or changes, in the same PR.** That means
  the happy path, every error path and every branch a reviewer could ask
  about, and the PR description names the tests that cover the change. Every
  script gets its own test file with a case for each exit path (the rule
  below), every workflow
  rule gets a `test/workflow-shape.bats` or `test/consumer-contract.bats`
  assertion, and every package under `packages/` is gated by
  `make test-package` at 100% lines, branches and functions. A threshold is never lowered and no file
  is excluded from coverage to make a PR pass; if something truly cannot be
  tested, the PR says what and why.
- **Shell lives in `scripts/`, never inline in a workflow.** A `run:` block of
  more than a couple of lines is unshellcheckable, untestable and unreadable in
  a run log; give it a file under the matching `scripts/<area>/` and a bats
  test. Everything under `scripts/` is `shellcheck -x` clean under
  `set -euo pipefail`.
- **`set -e` does not reach everywhere, so a step that can fail there says
  so.** It does not stop on a failing `$(...)` inside a command's arguments
  or a `case` word, on a failure inside a function its caller reads through
  `$(...)`, or on the command feeding a loop through `< <(...)`. Read the
  value on a line of its own (`udid="$(workflows_sim_udid)"`), end a step
  inside such a function with `|| return` or `|| die "..."`, and list into a
  variable before looping over it. Each of these once let a script carry on
  with an empty value (`ios-simulator.sh`, `workflows_app_id`,
  `workflows_fingerprint`, `smoke-local.sh`, `cancel-runs.sh`).
- **A required environment variable is checked with `require_env`, never a
  bare `${NAME:?}`.** The bare form exits with bash's own "parameter null or
  not set" line: no `::error::` annotation on the run and no word on where the
  value comes from. `require_env GH_REPO:owner/name TAG` (in
  `scripts/lib/common.sh`) names every missing or empty variable at once, each
  with its hint, and `require_uint NAME...` does the same for a non-negative
  integer. A positional `${1:?usage: ...}` and the `rm -rf "${dir:?}/..."`
  guard on a lower-case local stay as they are.
  `test/no-bare-required-variable.bats` fails on a new bare check.
- **Never set a locale as a command prefix in shell code.** Write
  `env LC_ALL=C sort`, not `LC_ALL=C sort`: with the prefix, bash itself
  switches locale for the one command, and a Homebrew bash on macOS doing that
  inside `$(...)` or a pipeline now and then dies with SIGSEGV (status 139),
  reported as if the command had failed. `env` sets the variable in the
  command's own process, so bash never changes locale. The template learned
  this from an intermittent release-verification failure; its
  `scripts/shell-locale.test.mjs` is the guard.
- **Every script has its own test file, and that file runs it and covers
  every branch and exit path. No exceptions, no allowlist.**
  - **The file:**
    - `scripts/ci/x.sh` has `test/x.bats` (`test/ci-x.bats` when another script is also called `x`).
    - A Node script `scripts/lib/x.mjs` has `test/x.test.mjs`, under `make test-scripts`' 100% gate.
    - A package's program, module or Expo preset, `packages/<package>/bin/x.mjs`, `lib/x.mjs` or `expo/x.mjs`, has `packages/<package>/x.test.mjs`; so does a Jest runtime file, `packages/<package>/expo/jest/**/x.cjs`.
    - A package's byte-identical copy of a script is tested by its original's own test plus `test/package-copies.bats`.
  - **What counts:**
    - A case in a shared suite (`plumbing.bats`, `fallback-gates.bats`) is welcome on top, but it is never the script's own test.
    - A file that only greps the script does not count.
  - **"It needs Xcode" is not an exception.** A script that needs Xcode, a simulator, CocoaPods, Gradle, an emulator, Maestro or a network is run against fakes of those tools on `PATH` that record their calls. `stub_cmd NAME [BODY]` in `test/test_helper.bash` writes one (`stub_calls NAME` reads back what it was called with); `test/app-launch.bats` and `test/native-ios-build.bats` show the larger cases. Eight scripts once sat on an allowlist as "cannot run from a test", and every one of them could.
  - **Where tests live:** in `test/`, not beside the script, because `scripts/` is what callers check out and what shellcheck lints.
  - **Enforced:** `test/script-coverage.bats` fails naming every script without its own test, and fails if an allowlist comes back.
- **Tests run in parallel, so each one stands alone.** `make test-unit` runs
  one bats job per core (the suite goes from about eight minutes to two), and
  CI does the same. A test uses its own `$BATS_TEST_TMPDIR`, never a fixed path
  another test also writes, and polls for a background process instead of
  sleeping a fixed time: a busy machine overruns any fixed wait. A test that
  passes alone and fails in the parallel run is a broken test.
- **Every assertion ends in `|| fail "..."`** — bash 3.2 (macOS's
  `/bin/bash`) does not honour `errexit` for a bare `[[ ]]`, so an unguarded
  assertion cannot fail a test locally. `test/assertions-enforced.bats`
  enforces this.
- **A test that needs a tool `.mise.toml` pins opens with `require_cmd
  <tool>`, never `command -v <tool> || skip`.** A missing pinned tool is a
  broken setup: `require_cmd` (`test/test_helper.bash`) fails the test and
  names the fix, where the skip once let a shell without yq report green with
  every workflow shape and contract assertion skipped. A tool the toolchain
  does not pin (python3, curl, the claude CLI, mise itself) may still
  skip. `test/require-cmd.bats` enforces this.
- **Tool versions live in `packages/app-tooling/versions.json`**, the only
  file a version is edited in. `node scripts/self/render-versions.mjs --write`
  generates `scripts/lib/versions.sh` (and its package copy) and the `[tools]`
  block of `.mise.toml`, between its `# versions:start` / `# versions:end`
  markers, from it; never edit those by hand. The workflow input defaults that
  mirror a pin stay hand-written and move in the same change.
  `make check-version-pins` fails on a generated file that has drifted and on a
  default that disagrees.
- **Jobs check this repo out into `.workflows/`** via `job.workflow_repository` /
  `job.workflow_sha`, and reference everything through `$WORKFLOWS_DIR`. Never reference
  a path under `scripts/` or `.github/actions/` from a consumer-visible
  interface.
- **Permissions start at `contents: read`** at the top of a workflow; a job
  that needs more declares the extra scope *and* re-declares `contents: read`,
  because a job-level `permissions:` block replaces the top-level one rather
  than extending it. The one exception is `build-prepare.yml`, which has no
  block at any level: a `permissions` block anywhere in a called workflow
  replaces the *caller's* grant too, and that job must take the caller's
  `contents: write` / `actions: read|write` as given (v0.6.2; the shape test
  holds both halves).
- **A change to `build-prepare.yml`, `build-android.yml` or the scripts
  they run gets `make test-smoke-local` before the PR.** No gate in this repo
  executes those workflows - they only run inside a consumer - and v0.6.0
  broke every consumer's internal release with `make check` green. (The one
  reusable workflow a gate here does execute is `pr-store-notes.yml`: the
  `Store notes` job in `self-ci.yml` runs it against the template in a
  dry run on every change, and `self-release.yml` runs it again before `v0`
  moves - see `self-store-notes.yml`.) The smoke
  runs the Linux jobs for real with act, against the template, from the
  pushed branch: Prepare in about a minute and a quarter once act's cache is
  warm (three minutes the first time). Runs from different worktrees can
  overlap, and each removes its containers when it ends. A change that
  reaches `build-android.yml` or what it runs gets
  `make test-smoke-local-android` too: about 25 minutes warm, amd64 under
  emulation with an Android SDK the script provisions once (it asks before
  accepting the SDK licences). It cannot see the token a called workflow really receives,
  tag rules, or macOS; for those, push a throwaway caller on a `scratch/*`
  branch and read the job's "Set up job" log before merging
  (CONTRIBUTING.md, "Running the release pipeline locally").
- **Conventional commits with a closed scope enum**
  (`commitlint.config.mjs`): `actions app-tooling checks ci dependencies docs e2e lib native ota
  release self test tooling web workflows`. Squash merges take the PR title as
  the commit message, so `pr-title.yml` lints the title too.
- **Releases are release-please's job.** `self-release.yml` cuts the version
  and re-points the moving `v0`/`v0.<minor>` tags through
  `scripts/self/tag-major.sh`; never move a tag or edit a version by hand.
  Each release PR it opens carries two CI runs: a red `pull_request` run that
  GitHub creates for a `GITHUB_TOKEN`-opened PR and never gives a job, and a
  green `workflow_dispatch` run that `scripts/release/dispatch-release-pr-ci.sh`
  starts on each release PR's branch. `self-release.yml` does this through
  `pr-release.yml`, the reusable workflow consumers call, from the same
  commit. The green one is the signal. The red one goes away only when the PR
  is opened by the RELEASE_TAGGER App (the guarded step in `pr-release.yml`;
  needs the App's two secrets on this repo).
  There are two release PRs, one per component - the workflows and
  `app-tooling` (`separate-pull-requests`) - and each bumps
  `.release-please-manifest.json`. `always-update` in
  `release-please-config.json` rebuilds every open one on each push to
  `main`, so merging one never leaves the other conflicting. Each rebuild is a
  force push, which dismisses an approval: approve a release PR right
  before merging it.

  The chain, end to end:

  ```mermaid
  sequenceDiagram
    autonumber
    participant main as main
    participant rel as self-release.yml
    participant pr as release PR branch
    participant ci as self-ci.yml
    participant tags as tags and packages
    main->>rel: push to main
    rel->>rel: pr-release.yml mints an App token when both RELEASE_TAGGER secrets exist, else uses GITHUB_TOKEN
    rel->>pr: release-please opens each release PR, or rebuilds it on this main (always-update)
    rel->>ci: dispatch-release-pr-ci.sh starts self-ci.yml (ci-workflow) on each PR branch
    ci-->>pr: the green dispatched run is the signal
    Note over pr: the pull_request run GitHub creates for a GITHUB_TOKEN-opened PR gets no job and is noise
    pr->>main: squash merge
    main->>rel: push to main
    rel->>tags: release-created, tag vX.Y.Z and its release
    rel->>rel: store-notes job runs pr-store-notes.yml against the template, dry run, from that commit
    rel->>tags: major-tag job moves v0 and the minor tag to that commit, only after that dry run passed
    rel->>tags: publish-app-tooling job publishes the npm package, when paths-released names it
    rel->>pr: the other component's open release PR is rebuilt on the new main, manifest included
  ```

- **No vague abbreviations, anywhere a human reads.** Write the word:
  identifiers, organisation, credentials, repository, configuration,
  environment. This applies to prose, plans, commit messages, comments and
  names alike. Keep an abbreviation only when it is the industry's own name
  for the thing (App Store Connect's `ASC_`, OTA, 2FA, API, JSON, CI, CD) and
  expand an uncommon one on first use. A prefix made of the family's initials
  was rejected for exactly this reason; so was "ids" for identifiers in a
  status message.
- **A make target is named for what it checks or does, never after the tool
  that does it.** `check-ci`, not `zizmor`; `check-spell`, not
  `typos`. A tool's name tells a reader nothing
  until they already know the tool. It belongs in the `##` description, where
  `make help` shows it beside the name. `test/docs-contract.bats` fails on a
  target named after a tool pinned in `.mise.toml`.
- **Workflow files carry their stage in the name.** GitHub reads only the top
  level of `.github/workflows/`, so the prefix is the only grouping there is:
  `check-` (or `check.yml`) runs static gates on every change and never runs a
  test, `test-` runs test suites, `build-` makes artifacts, `publish-` ships to
  a store, a release, OTA or badges, `pr-` hooks pull request events, and
  `self-` is this repository's own CI. The display name is the file stem in
  words (`publish-ota.yml` is "Publish OTA"). A new workflow takes one of these
  (`test/workflow-shape.bats` fails otherwise). Renaming a callable workflow
  breaks every consumer: commit it as `feat(workflows)!:` with a
  `BREAKING CHANGE:` footer naming old and new, and open the template PR that
  follows it at the same time. The same PR updates every reference, not just
  the ones spelled `.yml`: `uses:` paths, test loops over workflow names, the
  consumer guide's headings and the anchors that point at them, `contract.json`
  toggles, fixtures, diagrams, and prose. Before pushing, `git grep` the old name
  without its suffix; only `CHANGELOG.md` and `docs/superpowers/` may still
  hold it.
- **Docs and diagrams ship in the same PR as the change, never as a
  follow-up.** Any change to a name, input, output, job, file, flow, count or
  default updates every doc that describes it, in the same PR: prose, tables,
  README and AGENTS.md, and every diagram (mermaid blocks, ASCII drawings in
  code fences, SVGs under `docs/assets/`). Before pushing, `git grep` each
  thing the diff renamed or changed, spelled every way a reader would meet it
  (with and without `.yml`, the display name, the job name), and read each
  diagram that shows the part you touched; a diagram that still draws the old
  flow is drift even when no text search finds it. The PR description names
  the docs it updated, or says why none needed to change. Mechanically
  enforced on top: adding or removing a `##`-documented make target without
  updating the command table above is a hard failure, and so is a
  `<!--count:...-->` marker that disagrees with the tree
  (`test/docs-facts.bats`; the counts that grow with ordinary PRs are round
  floors, `1800+ tests`, which hold until the count crosses the next step).

## Rules every app of the family follows

The rules above are for this repository. These are the ones its checks enforce in
an app, written once here so an app's own `AGENTS.md` can link to them and keep
only what is specific to it. Each names the program in `@blinkbitcoin/app-tooling`
that holds the rule, and the section of the app's `app-tooling.json` that tunes it.

- **Every source file has its own sibling test, and that file alone covers it at
  100%.** `foo.mjs` has `foo.test.mjs` and `Foo.tsx` has `Foo.test.tsx` (a `.ts`
  module may use `.test.tsx`), in the same directory. A directory-wide test file,
  a `__tests__/` directory, or a module's tests living in a caller's test file does
  not count, even when global coverage is 100%. The one exception is a route
  directory whose files a router loads as routes (expo-router's `src/app/`): a
  route's test mirrors its path under a directory the app names (`mirror` in the
  config), such as `src/__tests__/app/`. Check a module with its own test alone:
  `node --test --experimental-test-coverage --test-coverage-include=<file>.mjs
  <file>.test.mjs`, or `jest <file>.test.tsx --coverage
  --collectCoverageFrom=<file>.tsx`. `check-test-siblings` (rules in the
  `testSiblings` section: `sources`, `exclude`, `mirror`) fails naming every file
  without one. **No exceptions, no allowlist**: a module that needs a device, a
  simulator, a native build or the network is tested against fakes of them, and the
  check fails if an allowlist comes back. A shell script is held to the same rule,
  with its test named after it and running the script against fake tools on `PATH`
  (the rule for scripts above).
- **Global coverage is not enough.** It says every line ran somewhere, not that its
  own test ran it; the sibling rule closes that gap, so deleting a caller's test
  never silently uncovers the module it used. The shared Jest preset holds coverage
  at 100% lines, branches, functions and statements, and a file with nothing to
  assert goes in the app's `coveragePathIgnorePatterns` **with a one-line reason**;
  an entry without one is not mergeable, and a native module's TypeScript wrapper
  does not qualify just because the native half is Swift or Kotlin.
  `check-coverage-empty` also fails on any file with zero statements, so a
  re-export barrel cannot lift the number while testing nothing; one kept under
  `coveragePathIgnorePatterns` still has its sibling test, pinning what it
  re-exports.
- **A script's command-line entry is `main(argv, io)`**: an exported function that
  returns the exit code and is tested in-process. The entry itself is only an
  `import.meta.main` guard that sets `process.exitCode` from `main`, which one
  subprocess run per script covers.
- **Tests are silent.** `console.error` and `console.warn` during a test fails it
  (the shared Jest preset's guard, in every project). A console line is usually a
  missing `await waitFor`, not a logging need; a deliberate one opts out with
  `allowConsole(method, matcher)` from
  `@blinkbitcoin/app-tooling/expo/jest/console`, or by spying on the method.
- **Worktrees under `.claude/worktrees/` are not the checkout.** Claude Code puts
  whole checkouts there, `node_modules` included, so every tool that walks the tree
  excludes the directory itself (Jest and Metro anchored to the root, since a
  worktree's own root is under it too). The same goes for `.workflows/`, where every
  CI job checks this repository out. A new tool adds its entry;
  `check-ignored-directories` holds the existing ones, and the Expo presets already
  carry them.
- **Workflow files carry their stage in the name** (the rule above), and an app's
  callers use the same prefixes: `ci.yml` and `ci-*.yml` run on every change and
  display as `CI` / `CI / ...`; `cd-*.yml` make releases and display as
  `CD / ...`. `check-workflow-names` fails on a workflow without the prefix and the
  matching display name.
- **A make target is named for what it checks or does** (the rule above), enforced
  in an app by `check-make-target-names`: it fails on a target with a word that names
  a tool pinned in `.mise.toml` or a package in `package.json`. A `setup-` target
  installs the tool it names, and any other exception needs an entry in the
  `docs.allowTargetNames` section of `app-tooling.json`, target to reason.

## Testing map

| Layer | Where | Run with |
|---|---|---|
| Pure bash scripts, one test file each | `test/<name>.bats` | `make test-unit` |
| The Node scripts under `scripts/`, one test file each, 100% lines, branches and functions | `test/<name>.test.mjs` | `make test-scripts` |
| The Ruby lanes every app imports: helpers, promotion logic, the recorded arguments replayed against the real fastlane actions, and the package Fastfile loaded by real fastlane | `packages/app-tooling/fastlane/test/lanes_test.rb` | `make test-fastlane` (CI's `Unit / Ruby`) |
| The store-release plugin: marketplace and manifest shape, the skills' paths through `${CLAUDE_PLUGIN_ROOT}`, and each skill's offline suite | `test/store-release-plugin.bats`, `plugins/store-release/skills/*/tests/run.sh` | `make test-unit` |
| Workflow and action shape (inputs, permissions, step names) | `test/workflow-shape.bats`, `test/actions-shape.bats` | `make test-unit` |
| The Linux release jobs, executed for real (Prepare, Android) | `.github/workflows/self-smoke-local.yml` via act | `make test-smoke-local` |
| The consumer contract: guide ↔ fixtures ↔ `contract.json` ↔ the workflows | `test/consumer-contract.bats`, `test/contract-program.bats` | `make test-unit` |
| The app-tooling programs and modules at 100% lines, branches and functions: the contract checker's rules (including a consumer's make-ci gate set against CI and the lane secret names), `contract.json` against `contract.schema.json` and its profiles against the workflow files, the tool-version check, the store notes generator and its LLM adapters, and each program's flags, messages and exit codes | `packages/app-tooling/*.test.mjs` | `make test-package` |
| Each Expo preset (`expo/`) against the template: the template's file as it is and the file it becomes, evaluated under the same stand-ins and compared (lefthook through the real `lefthook dump`); the guide's examples are those files | `packages/app-tooling/*.test.mjs` | `make test-package` |
| Failures at the contract boundary carry a fix, not just a cause | `test/contract-errors.bats` | `make test-unit` |
| Hooks, the hook environment and the docs command table | `test/hooks.bats`, `test/git-env.bats`, `test/docs-contract.bats` | `make test-unit` |
| That every zizmor command here names its policy with `--config` | `test/zizmor-config.bats` | `make test-unit` |
| That a test needing a pinned tool fails without it rather than skipping, and `require_cmd` itself | `test/require-cmd.bats` | `make test-unit` |
| The checkable facts in the docs (counts, job lists, action pins) | `test/docs-facts.bats` | `make test-unit` |
| That every script has its own test file that runs it, with no exceptions | `test/script-coverage.bats` | `make test-unit` |
| `pr-store-notes.yml` executed for real against the template, in a dry run, and its `section` output checked | `.github/workflows/self-store-notes.yml`, `scripts/self/check-store-notes-section.sh` | every PR (`self-ci.yml`), and before `v0` moves (`self-release.yml`) |
| The family end to end, against a real consumer | `.github/workflows/self-smoke.yml` | `workflow_dispatch` |

**Nothing here checks out a consumer, except to dry-run a workflow.** The
suite reads this repository and `test/fixtures/consumer-min` only. The one CI
job that checks a consumer out is the store notes dry run, and it tests this
repository's `pr-store-notes.yml` against the template's `main`, not the
template against a rule: the generator it runs is this repository's own
`gen-store-notes`, and a red dry run from a broken setup on that `main` (its store
metadata, its prompt addendum) is a deliberate trade, because the template is where every release here
is first executed. A consumer is held to the contract by its own
`Contract` job, against the version of this repository it calls, and it is the
consumer's PR that fails when it drifts - see "The contract check" in
`docs/consumer-guide.md`. A rule that spans this repository and its consumers is
a `contract.json` requirement, never a test here that reads another
repository's checkout.

## Where to look next

- What consumers may call, and with what: [`docs/consumer-guide.md`](docs/consumer-guide.md).
- Why a cache missed: [`docs/cache-keys.md`](docs/cache-keys.md).
- What a failed E2E run leaves behind: [`docs/forensics.md`](docs/forensics.md).
- Runner labels, macOS billing, KVM and disk: [`docs/runners.md`](docs/runners.md).
- Contributing workflow and PR expectations: [`CONTRIBUTING.md`](CONTRIBUTING.md).
  Vulnerability reports: [`SECURITY.md`](SECURITY.md).

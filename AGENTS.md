# Agent guide

The shared engineering baseline, in two halves. Reusable GitHub Actions
workflows, composite actions and bash scripts for building, testing and
releasing React Native (Expo) apps; and `packages/dev-config`, published as
`@blinkbitcoin/dev-config`, which is the developer tooling a repo installs and
is not React Native specific. Consumers pin `@v0` and call the workflows;
nothing here is copied into their repos. The published
contract is [`docs/consumer-guide.md`](docs/consumer-guide.md) — a change to an
input, output, secret or env var is a change to every app that pins this repo.

Read this file before touching anything. `make help` is the source of truth for
commands, and `test/docs-contract.bats` fails the build if it and the table
below drift apart.

## Layout

```
.github/workflows/  the reusable workflows (workflow_call) + this repo's self-* CI
.github/actions/    composite actions (setup, maestro, forensics, free-disk, native-key)
scripts/checks/     the check-code.yml steps (audit, codegen, commitlint, expo-doctor, i18n)
scripts/ci/         shared CI plumbing (changed-class, lint-ci, pnpm-install, tool-version, gh-pages badges)
scripts/e2e/        simulators, emulators, Metro, Maestro, forensics collection
scripts/native/     prebuild, pods, iOS/Android builds and packaging
scripts/ota/        expo-updates export, fingerprint gate, publish, smoke
scripts/release/    version/notes resolution, fastlane invocation, release assets
scripts/web/        web export, Playwright install and run
scripts/self/       this repo's own upkeep (check-versions, tag-major, act-smoke,
                    dispatch-release-pr-ci, render-contract-table,
                    check-rehearsal-section, changed-gates)
scripts/lib/        sourced bash helpers (common, versions, *-env, expo-config,
                    changed-files)
test/               the bats suite + fixtures/ (consumer callers, kept byte-identical)
docs/               consumer-guide, adopting-an-existing-repo, cache-keys,
                    forensics, runners
```

## Commands

Every row is a make target; nothing here is run through a package manager.

| Target | |
|---|---|
| `make hooks` | Install the git hooks (lefthook, from `.mise.toml`) — clone-wide, see the worktree rule |
| `make check` | Everything self-ci runs: the nine gates below |
| `make lint-scripts` | shellcheck every script under `scripts/` (bash strict) |
| `make lint-workflows` | Lint the workflows and composite actions (actionlint) |
| `make workflow-security` | Security audit of the workflows and actions (zizmor, offline, medium and up; policy in `.github/zizmor.yml`, passed with `--config`) |
| `make test` | The bats suite over the pure scripts |
| `make test-package` | `node:test` over `packages/dev-config` |
| `make test-script-modules` | `node:test` for the Node scripts under `scripts/`, one test file each, 100% coverage |
| `make check-versions` | Fail when a workflow default disagrees with `scripts/lib/versions.sh` |
| `make tool-versions` | Fail when an installed tool is not the version `packages/dev-config/versions.json` pins |
| `make spell` | typos over the whole repo |
| `make secrets` | Scan the whole git history for committed secrets (gitleaks) |
| `make smoke-local` | Prepare against the template with nektos/act — Docker and a pushed branch required; not part of `check` (CONTRIBUTING.md, "Running the release pipeline locally") |
| `make smoke-local-android` | `smoke-local`, then the unsigned Android build |
| `make help` | Show every target with its description |

## Rules of the road

- **Do all branch work in a git worktree**
  (`git worktree add ../shared-workflows-<topic> -b <branch> origin/main`),
  never by switching branches in the shared clone: several agent sessions share
  that checkout, and a commit made there lands on whatever branch another
  session left checked out. **`make hooks` is the one thing that is not
  worktree-scoped:** a worktree shares `.git/hooks` with the main checkout, so
  running it from a topic worktree makes these hooks live in every worktree of
  the clone. That is intended once this is on `main` — one `make hooks` per
  physical clone — but a branch that changes `lefthook.yml` changes what every
  sibling worktree runs. `mise exec -- lefthook uninstall` reverses it.
- **The consumer guide is the contract.** Adding, renaming or re-defaulting a
  workflow input, output or secret without the matching
  `docs/consumer-guide.md` row is a breaking change shipped silently.
  `test/consumer-contract.bats` holds the guide and the fixtures under
  `test/fixtures/consumer-min/` byte-identical — when it fails, both copies
  move together or neither does. A real consumer passes inputs of its own, so
  it is held to the fixture only where it must not diverge: its `ci.yml`
  trigger block, which is where a second docs rule (`paths-ignore`) would creep
  back in beside `check-code.yml`'s classifier.
- **Every PR tests everything it adds or changes, in the same PR.** That means
  the happy path, every error path and every branch a reviewer could ask
  about, and the PR description names the tests that cover the change. Every
  script gets its own test file with a case for each exit path (the rule
  below), every workflow
  rule gets a `test/workflow-shape.bats` or `test/consumer-contract.bats`
  assertion, and `packages/dev-config` is gated by `make test-package` at
  100% lines, branches and functions. A threshold is never lowered and no file
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
  `workflows_fingerprint`, `act-smoke.sh`, `cancel-runs.sh`).
- **Every script has its own test file, and that file runs it and covers
  each of its exit paths.** `scripts/ci/x.sh` has `test/x.bats`
  (`test/ci-x.bats` when another script is also called `x`); a Node script
  `scripts/lib/x.mjs` has `test/x.test.mjs` under `make test-script-modules`'
  100% gate; a dev-config program `packages/dev-config/bin/x.mjs` has
  `packages/dev-config/x.test.mjs`. A case in a shared suite (`plumbing.bats`,
  `fallback-gates.bats`) is welcome on top but is never the script's own test,
  and a file that only greps the script does not count. Tests live in `test/`
  rather than beside the script because `scripts/` is what callers check out
  and shellcheck lints. `test/script-coverage.bats` fails naming every script
  without one; a script that truly cannot run from a test goes in its
  `ALLOWED` list with the reason.
- **Every assertion ends in `|| fail "..."`** — bash 3.2 (macOS's
  `/bin/bash`) does not honour `errexit` for a bare `[[ ]]`, so an unguarded
  assertion cannot fail a test locally. `test/assertions-enforced.bats`
  enforces this.
- **Tool versions live in `scripts/lib/versions.sh`**, mirrored into
  `.mise.toml` and into workflow input defaults. Never bump one copy alone;
  `make check-versions` is what catches it.
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
  they run gets `make smoke-local` before the PR.** No gate in this repo
  executes those workflows - they only run inside a consumer - and v0.6.0
  broke every consumer's internal release with `make check` green. (The one
  reusable workflow a gate here does execute is `pr-release-notes.yml`: the
  `Consumer rehearsal` job in `self-ci.yml` runs it against the template in a
  dry run on every change, and `self-release.yml` runs it again before `v0`
  moves - see `self-rehearsal.yml`.) The smoke
  runs the Linux jobs for real with act, against the template, from the
  pushed branch. It cannot see the token a called workflow really receives,
  tag rules, or macOS; for those, push a throwaway caller on a `scratch/*`
  branch and read the job's "Set up job" log before merging
  (CONTRIBUTING.md, "Running the release pipeline locally").
- **Conventional commits with a closed scope enum**
  (`commitlint.config.mjs`): `actions checks ci deps dev-config docs e2e lib native ota
  release self test tooling web workflows`. Squash merges take the PR title as
  the commit message, so `pr-title.yml` lints the title too.
- **Releases are release-please's job.** `self-release.yml` cuts the version
  and re-points the moving `v0`/`v0.<minor>` tags through
  `scripts/self/tag-major.sh`; never move a tag or edit a version by hand.
  Each release PR it opens carries two CI runs: a red `pull_request` run that
  GitHub creates for a `GITHUB_TOKEN`-opened PR and never gives a job, and a
  green `workflow_dispatch` run that `scripts/self/dispatch-release-pr-ci.sh`
  starts on each release PR's branch. The green one is the signal. The red
  one goes away only when the PR is opened by the RELEASE_TAGGER App (the
  guarded step in `self-release.yml`; needs the App's two secrets on this
  repo).
  There are two release PRs, one per package (`separate-pull-requests`),
  and both bump `.release-please-manifest.json`. `always-update` in
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
    rel->>rel: mint an App token when both RELEASE_TAGGER secrets exist, else use GITHUB_TOKEN
    rel->>pr: release-please opens each release PR, or rebuilds it on this main (always-update)
    rel->>ci: dispatch-release-pr-ci.sh starts self-ci.yml on each PR branch
    ci-->>pr: the green dispatched run is the signal
    Note over pr: the pull_request run GitHub creates for a GITHUB_TOKEN-opened PR gets no job and is noise
    pr->>main: squash merge
    main->>rel: push to main
    rel->>tags: release_created, tag vX.Y.Z and its release
    rel->>rel: rehearsal job runs pr-release-notes.yml against the template, dry run, from that commit
    rel->>tags: major-tag job moves v0 and the minor tag to that commit, only after the rehearsal passed
    rel->>tags: publish-dev-config job publishes the npm package, when it released too
    rel->>pr: the other package's open release PR is rebuilt on the new main, manifest included
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
  that does it.** `workflow-security`, not `zizmor`; `lint-scripts`, not
  `shellcheck`. A tool's name tells a reader nothing
  until they already know the tool. It belongs in the `##` description, where
  `make help` shows it beside the name. `test/docs-contract.bats` fails on a
  target named after a tool pinned in `.mise.toml`.
- **Workflow files carry their stage in the name.** GitHub reads only the top
  level of `.github/workflows/`, so the prefix is the only grouping there is:
  `check-` gates every change, `build-` makes artifacts, `publish-` ships to a
  store, a release, OTA or badges, `pr-` hooks pull request events, and `self-`
  is this repository's own CI. A new workflow takes one of these
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
  (`test/docs-facts.bats`).

## Testing map

| Layer | Where | Run with |
|---|---|---|
| Pure bash scripts, one test file each | `test/<name>.bats` | `make test` |
| The Node scripts under `scripts/`, one test file each, 100% lines, branches and functions | `test/<name>.test.mjs` | `make test-script-modules` |
| Workflow and action shape (inputs, permissions, step names) | `test/workflow-shape.bats`, `test/actions-shape.bats` | `make test` |
| The Linux release jobs, executed for real (Prepare, Android) | `.github/workflows/self-act-smoke.yml` via act | `make smoke-local` |
| The consumer contract: guide ↔ fixtures ↔ `contract.json` ↔ the workflows | `test/consumer-contract.bats`, `test/contract-doctor.bats` | `make test` |
| Both dev-config programs at 100% lines, branches and functions: the contract checker's rules (including a consumer's make-ci gate set against CI and the lane secret names), the tool-version check, and each program's flags, messages and exit codes | `packages/dev-config/*.test.mjs` | `make test-package` |
| Failures at the contract boundary carry a fix, not just a cause | `test/contract-errors.bats` | `make test` |
| Hooks, the hook environment and the docs command table | `test/hooks.bats`, `test/git-env.bats`, `test/docs-contract.bats` | `make test` |
| That every zizmor command here names its policy with `--config` | `test/zizmor-config.bats` | `make test` |
| The checkable facts in the docs (counts, job lists, action pins) | `test/docs-facts.bats` | `make test` |
| That every script has its own test file that runs it, or is allow-listed with a reason | `test/script-coverage.bats` | `make test` |
| `pr-release-notes.yml` executed for real against the template, in a dry run, and its `section` output checked | `.github/workflows/self-rehearsal.yml`, `scripts/self/check-rehearsal-section.sh` | every PR (`self-ci.yml`), and before `v0` moves (`self-release.yml`) |
| The family end to end, against a real consumer | `.github/workflows/self-smoke.yml` | `workflow_dispatch` |

**Nothing here checks out a consumer, except to rehearse a workflow.** The
suite reads this repository and `test/fixtures/consumer-min` only. The one CI
job that checks a consumer out is the consumer rehearsal, and it tests this
repository's `pr-release-notes.yml` against the template's `main`, not the
template against a rule: a red rehearsal from a broken generator on that
`main` is a deliberate trade, because the template is where every release here
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

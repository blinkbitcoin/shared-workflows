# Contributing

Start with [`AGENTS.md`](AGENTS.md) — it has the folder map, the full command
table and the rules CI enforces. This file covers the workflow around a change.

## Setup

```sh
mise trust && mise install   # node, pnpm, shellcheck, actionlint, zizmor, gitleaks, bats, yq, typos, lefthook, act
make setup-hooks                   # install the git hooks (once per clone, see below)
make check                   # verify the toolchain by running every gate
```

`make setup-hooks` installs into `.git/hooks`, which a `git worktree` **shares with
the main checkout**. So it is one command per clone rather than per worktree,
and running it from a topic worktree makes these hooks live in every worktree
of that clone — including the main one. `mise exec -- lefthook uninstall`
reverses it.

There is no `package.json` and nothing to `npm install`: every tool comes from
`.mise.toml`, and the hooks call them through `mise exec --` so a hook and CI
run the same pinned binary. The one exception is commitlint, which npx fetches
on demand with the same invocation `scripts/checks/commits.sh` uses in CI.

## Branching

- Branch off `main`, one logical change per branch. `main` is protected;
  nothing lands except by pull request.
- **Work in a worktree**, not by switching branches in the shared clone:
  `git worktree add ../shared-workflows-<topic> -b <branch> origin/main`.
  Several sessions share the main checkout, and a commit made there lands on
  whatever branch someone else left checked out.
- Name the branch for the change (`ci/hooks-and-hygiene`, `fix/metro-prewarm`).
- Rebase on `main` rather than merging it back in; the squash merge discards
  the branch history anyway.
- **Several dependent pull requests go through `gh stack`** (the
  [`github/gh-stack`](https://github.com/github/gh-stack) GitHub CLI
  extension), never hand-stacked branches kept in line with manual rebases. One
  branch per reviewable change, each based on the one below it; `gh stack`
  owns the restacking after a review comment lands in the middle, and writes
  the "part N of M" navigation into each pull request body. A hand-stacked
  chain loses that: the rebase after every change to a lower branch is manual,
  a missed one silently puts a reviewed commit back into the next pull
  request's diff, and the reviewer has no way to see where in the stack they
  are.

## Commits and PR titles

Conventional Commits with a closed scope list, enforced by `commitlint` in the
`commit-msg` hook and again on the PR title by `pr-title.yml`:

```
<type>(<scope>): <subject>
```

Scopes: `actions app-tooling checks ci deps docs e2e lib native ota release self test
tooling web workflows` (`commitlint.config.mjs` is the source of truth).

Pull requests are **squash-merged**, so GitHub uses the **PR title** as the
commit message on `main` — and release-please reads those messages to decide
the next version and write the changelog that consumers read before moving
their pin. Mark breaking changes with `!` (`feat(workflows)!: ...`) or a
`BREAKING CHANGE:` footer, and say in the PR body what a consumer has to change.

## Before you push

```sh
make check   # check-ci (shellcheck, actionlint, zizmor), test (bats, the packages, the Node scripts), check-version-pins, check-tool-versions, check-spell (typos), check-secrets (gitleaks)
```

The `pre-push` hook runs exactly that, and `pre-commit` runs a faster subset on
staged files (shellcheck, actionlint and zizmor when anything under `.github/`
is staged, typos, gitleaks over the staged diff). They are a safety net, not a substitute: `self-ci.yml` runs the same
gate on every PR. Escape hatches exist for genuinely broken tooling
(`git commit --no-verify`, `LEFTHOOK=0 git push`), and personal additions go in
a gitignored `lefthook-local.yml` rather than in `lefthook.yml`.

### A new script needs a test file of its own

Every script has its own test file, named after it, that runs it and covers
each of its exit paths:

| Script | Its test |
| --- | --- |
| `scripts/ci/check-ci.sh` | `test/check-ci.bats` |
| `scripts/ota/export.sh` | `test/ota-export.bats` (`scripts/web/export.sh` already has `test/export.bats`) |
| `scripts/lib/env-validate.mjs` | `test/env-validate.test.mjs` (`make test-scripts`, 100% gate) |
| `packages/app-tooling/bin/check-tool-versions.mjs` | `packages/app-tooling/check-tool-versions.test.mjs` |
| `packages/app-tooling/lib/pin.mjs` | `packages/app-tooling/pin.test.mjs` |
| `packages/app-tooling/expo/eslint.mjs` (an Expo preset) | `packages/app-tooling/eslint.test.mjs` |
| `packages/app-tooling/expo/jest/mocks/expo-updates.cjs` | `packages/app-tooling/expo-updates.test.mjs` |
| `packages/app-tooling/checks/generated.sh` (a copy) | the original's `test/generated.bats`, plus `test/package-copies.bats` |

A case in a shared suite such as `plumbing.bats` or `fallback-gates.bats` is
fine on top, but it is never the script's own test: when the suite changes,
the script silently loses its coverage, and a reader looking for a script's
contract should find it in one file. Tests sit in `test/` rather than beside
the script because `scripts/` is what callers check out and what shellcheck
lints.

`test/script-coverage.bats` fails naming every script under `scripts/` or
`packages/` without such a file. It started as a check that some
test runs each script, which is how sixteen scripts came to have coverage at
all — three of them in the `setup` action, on the path of every job of every
workflow — and now asks for the script's own file.

"Executed" means a test runs it, not that a test mentions it. Ten scripts were
named only by tests that read their source — a grep for a pattern, an assertion
about a comment — which reads as coverage in a listing while asserting nothing
about behaviour.

There is no allowlist and no exception. A script that needs Xcode, a
simulator, CocoaPods, Gradle, an emulator, Maestro or the network runs against
fakes of those tools on `PATH` that record how they were called. The fakes
return what the case needs, and the test asserts the arguments, the outputs and
every error path. `test/app-launch.bats` and `test/native-ios-build.bats` show
the pattern.

An allowlist used to excuse eight scripts as "cannot run from a bats suite":
the native builds, the Maestro runners and Metro. Every one of them could.
`test/script-coverage.bats` now fails if an allowlist comes back.

`make test-package` holds every Node package under `packages/` at 100% lines,
branches and functions. Each program's command-line entry is a `main(argv, { ... })` that
takes its streams, environment and filesystem as arguments and returns the exit
code, so every flag, message and exit path is a `node:test` case in-process; one
case per program also runs the file as a real child process, which node's
coverage follows. Never lower a threshold, exclude a file or add a coverage
ignore comment to make a change fit; if a line truly cannot be tested, the PR
says which and why.

### Numbers in the docs

A count in a doc — how many scripts, how many tests — is marked so a test can
check it:

```markdown
<sub><!--count:scripts-->12<!--/count--> scripts · <!--count:tests-->34<!--/count--> tests</sub>
```

`test/docs-facts.bats` derives each one from the repository and fails when they
disagree. The numbers above are made up: a marker inside a fenced block is an
example, and the extractor strips fences before it looks. HTML comments do not render, so the docs read normally. An unmarked
number is not checked — marking one is how you opt in — but the counts the
README leads with are marked and a case fails if a marker disappears.

The same file holds job lists to `yq '.jobs[].name'` and any
`owner/action@vN` a doc names to the version the workflows really pin. Both
were wrong when it was written: the `Contract` job was in no table, and the
guide quoted `create-github-app-token@v2` where the workflows pin `@v3`.

### How consumers are held to the contract

This repository never checks out a consumer to check it against a rule, in
CI or in a test. (The store notes dry run in `self-store-notes.yml` checks the
template out to execute this repository's `pr-store-notes.yml`, not to judge
the template.) The direction is the other way round: each consumer's `check.yml` run starts with a
`Contract` job, which reads [`packages/app-tooling/contract.json`](packages/app-tooling/contract.json)
from the exact version of this repository that consumer calls and checks the
consumer against it. A consumer that has drifted fails **its own** PR, and a
change here is never red because of the state of some consumer's `main`.
"The contract check" in [`docs/consumer-guide.md`](docs/consumer-guide.md#the-contract-check)
has the diagram.

That puts a rule that spans repositories in one of two places:

- **A requirement in `contract.json`**, checked by
  `packages/app-tooling/bin/check-contract.mjs`. That covers package scripts,
  files, lanes, the rule that `make ci` and CI run the same gates in both
  directions, and the rule that the lanes read only the `APP_REVIEW_*` names
  `publish-store.yml` passes. Its tests use in-memory fixture consumers,
  aligned and misaligned.
- **The consumer's own tests**, when the consumer ships a copy of a script
  from here (`resolve-version.sh`, `build-info.sh`). Its CI has this repository
  checked out at `$WORKFLOWS_DIR`, so it compares its copy with ours.

`test/consumer-contract.bats` binds `contract.json` to the workflows here: every
script a checks or unit step runs has a requirement, gated on that step's input.

### Running the release pipeline locally

`make check` cannot execute a reusable workflow, and the PR's CI executes only
one: `pr-store-notes.yml`, in a dry run against the template
(`self-store-notes.yml`, the `Store notes` jobs). The build and publish
workflows only ever run inside a consumer. v0.6.0 shipped a Prepare job
that exited 127 on every consumer's next push with every gate green. Before a
change to `build-prepare.yml` or `build-android.yml` goes out, run the
Linux half of a consumer's internal release here with [nektos/act]:

```sh
make test-smoke-local           # Prepare, against the template at main
make test-smoke-local-android   # Prepare, then the unsigned Android build (much longer)
```

Allow a quarter of an hour: Setup installs every pinned tool into a fresh
container on each run (15 minutes of a 16-minute Prepare on an arm64 Mac).
It needs Docker running and the current branch **pushed**: build-prepare checks
this repository out into `.workflows` from GitHub at the local HEAD, so the
working tree itself is not what runs, the pushed commit is. The script refuses
an unpushed or detached HEAD rather than letting the job fail inside act.
`WORKFLOWS_SMOKE_REPOSITORY` and `WORKFLOWS_SMOKE_REF` pick another consumer.

The jobs are Linux containers, so a Mac runs them too (arm64 natively; tested
with OrbStack). act's artifact server listens on `127.0.0.1`, which the job
reaches over the host network act gives it. act would otherwise pick the host's
default-route address, and behind a VPN that is the tunnel's own address: the
`build-info` upload then times out after every step before it has passed.
A Docker that cannot reach the host's loopback from a host-network container
takes another address through `WORKFLOWS_ACT_ARTIFACT_ADDR`.

What it shows: the steps of the Linux jobs, in order, with the real scripts.
What it cannot show: the token a called workflow really receives (act hands
every job a full-scope token, so a `permissions` mistake looks fine - v0.6.1's
did), GitHub's tag and ref rules, and anything on a macOS runner. For those,
push a throwaway caller on a `scratch/*` branch and read the job's "Set up
job" log on GitHub before merging.

[nektos/act]: https://github.com/nektos/act

## What a change usually needs

- **A script change** needs a case in the script's own test file
  (`test/<name>.bats`, or `test/<name>.test.mjs` for a Node script), with
  every assertion ending in `|| fail "..."` (see the header of
  `test/assertions-enforced.bats` for why).
- **A workflow interface change** — an input, output, secret or env var — needs
  the matching row in [`docs/consumer-guide.md`](docs/consumer-guide.md), and
  the fixtures under `test/fixtures/consumer-min/` updated in the same commit.
  `test/consumer-contract.bats` keeps the guide's examples and the fixtures
  byte-identical.
- **A new gate** - a step in `check.yml` or `test-unit.yml` that runs a consumer
  script - needs its requirement in `contract.json`, gated on the step's input;
  `test/consumer-contract.bats` fails until it has one. From the next release,
  every consumer's `Contract` job then requires `make ci` to reach it, and fails
  a consumer whose `make ci` runs a gate no CI step does. It used to be a
  comment, and four gates ran locally and in no CI job at all.
- **A change to a script the consumer also ships** — today
  `scripts/release/resolve-version.sh` and `scripts/release/build-info.sh` —
  has to move both copies. They are contract-identical, not byte-identical. The
  consumer's own tests compare its copy with this one through `$WORKFLOWS_DIR`,
  so a change here that the consumer's copy does not follow turns the
  consumer's CI red on its next run.
- **A tool version bump** moves `scripts/lib/versions.sh` *and* the mirrors in
  `.mise.toml` and the workflow defaults; `make check-version-pins` is what fails
  otherwise.
- **A change to an Expo preset** (`packages/app-tooling/expo/`) keeps its test green: the test
  evaluates the template's file as it was and the file it becomes
  (`packages/app-tooling/fixtures/template/<tool>/`), and the change has to
  keep producing the template's configuration, or say in the PR what the
  template has to change with it. The consumer guide shows each `future.*`
  file, and `package.test.mjs` fails until both move together.
- **A new `##`-documented make target** needs a row in the `AGENTS.md` command
  table, and vice versa — `test/docs-contract.bats` checks both directions.

## Pull requests

Fill in the template checklist honestly. Keep PRs reviewable; split mechanical
churn into its own commit. If a change is breaking for a repo pinned at `@v0`,
say so in the PR body — the pin is the only thing standing between a mistake
here and every consumer's CI.

Releases are automated: release-please keeps a release PR open on `main`, and
squash-merging it cuts the version and re-points the moving `v0`/`v0.<minor>` tags.
Never move a tag or edit a version by hand. There is one release PR per
component (the workflows and `@blinkbitcoin/app-tooling`), and every push to
`main` rebuilds each open one on that `main` (`always-update` in
`release-please-config.json`), so merging one never leaves the other
conflicting. Each rebuild dismisses an approval: approve a release PR right
before merging it.

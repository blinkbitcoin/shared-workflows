# Contributing

Start with [`AGENTS.md`](AGENTS.md) — it has the folder map, the full command
table and the rules CI enforces. This file covers the workflow around a change.

## Setup

```sh
mise trust && mise install   # node, pnpm, shellcheck, actionlint, zizmor, gitleaks, bats, yq, typos, lefthook, act
make hooks                   # install the git hooks (once per clone, see below)
make check                   # verify the toolchain by running every gate
```

`make hooks` installs into `.git/hooks`, which a `git worktree` **shares with
the main checkout**. So it is one command per clone rather than per worktree,
and running it from a topic worktree makes these hooks live in every worktree
of that clone — including the main one. `mise exec -- lefthook uninstall`
reverses it.

There is no `package.json` and nothing to `npm install`: every tool comes from
`.mise.toml`, and the hooks call them through `mise exec --` so a hook and CI
run the same pinned binary. The one exception is commitlint, which npx fetches
on demand with the same invocation `scripts/checks/commitlint.sh` uses in CI.

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

Scopes: `actions checks ci deps dev-config docs e2e lib native ota release self test
tooling web workflows` (`commitlint.config.mjs` is the source of truth).

Pull requests are **squash-merged**, so GitHub uses the **PR title** as the
commit message on `main` — and release-please reads those messages to decide
the next version and write the changelog that consumers read before moving
their pin. Mark breaking changes with `!` (`feat(workflows)!: ...`) or a
`BREAKING CHANGE:` footer, and say in the PR body what a consumer has to change.

## Before you push

```sh
make check   # shellcheck, actionlint, zizmor, bats, test-package, check-versions, tool-versions, typos, gitleaks
```

The `pre-push` hook runs exactly that, and `pre-commit` runs a faster subset on
staged files (shellcheck, actionlint and zizmor when anything under `.github/`
is staged, typos, gitleaks over the staged diff). They are a safety net, not a substitute: `self-ci.yml` runs the same
gate on every PR. Escape hatches exist for genuinely broken tooling
(`git commit --no-verify`, `LEFTHOOK=0 git push`), and personal additions go in
a gitignored `lefthook-local.yml` rather than in `lefthook.yml`.

### A new script needs a test

`test/script-coverage.bats` fails when a script under `scripts/` or
`packages/dev-config/bin/` is executed by no test. Nothing enforced that before,
which is how sixteen scripts came to have no coverage at all — three of them in
the `setup` action, on the path of every job of every workflow.

"Executed" means a test runs it, not that a test mentions it. Ten scripts were
named only by tests that read their source — a grep for a pattern, an assertion
about a comment — which reads as coverage in a listing while asserting nothing
about behaviour.

If a script genuinely cannot run from a bats suite, add it to `ALLOWED` in that
file **with the reason**. The list is checked both ways: an entry naming a
script that no longer exists fails, and so does an entry for a script that has
since gained a test. An allowlist that outlives what it excuses is where
coverage goes to be forgotten.

`make test-package` carries coverage thresholds for the Node package, set at the
measured baseline so they ratchet. Raise them when a change covers more; never
lower them to make a change fit.

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

### The parity cases, and the eight skips you will see

Eight cases need a real consumer checkout. Six compare something here against
the consumer's own copy of it — `resolve-version.sh`, `build-info.sh`, the App
Review names the fastlane lanes read, and the three that hold the consumer's
`make ci` / `make check` to the gates CI runs. The other two check that the
consumer satisfies the contract at all. This repo serves any consumer, so it
has no business guessing where one sits on your machine: without a checkout to
point at, those cases **skip**, and say `parity NOT verified` rather than
implying the two copies agree.

Point them at a checkout to run them:

```sh
WORKFLOWS_TEMPLATE_DIR=../react-native-mobile-template \
WORKFLOWS_CONSUMER_ROOT=../react-native-mobile-template \
  mise exec -- bats test/
```

`WORKFLOWS_TEMPLATE_DIR` is what the parity cases read; `WORKFLOWS_CONSUMER_ROOT` is what
`consumer-contract.bats` reads. Setting both is the configuration CI uses.

Add `WORKFLOWS_PARITY_REQUIRED=1` to turn a would-be skip into a failure. `self-ci.yml`'s
`parity` job sets it, because a parity case that silently runs against nothing
and reports green is the exact failure the whole mechanism exists to prevent.
Do not add it to a plain local run unless you have supplied a checkout.

### Running the release pipeline locally

`make check` cannot execute a reusable workflow, and neither can the PR's CI:
the workflows only ever run inside a consumer. v0.6.0 shipped a Prepare job
that exited 127 on every consumer's next push with every gate green. Before a
change to `expo-prepare.yml` or `expo-build-android.yml` goes out, run the
Linux half of a consumer's internal release here with [nektos/act]:

```sh
make smoke-local           # Prepare, against the template at main (~2 min)
make smoke-local-android   # Prepare, then the unsigned Android build (much longer)
```

It needs Docker running and the current branch **pushed**: expo-prepare checks
this repository out into `.workflows` from GitHub at the local HEAD, so the
working tree itself is not what runs, the pushed commit is. The script refuses
an unpushed or detached HEAD rather than letting the job fail inside act.
`WORKFLOWS_SMOKE_REPOSITORY` and `WORKFLOWS_SMOKE_REF` pick another consumer.

What it shows: the steps of the Linux jobs, in order, with the real scripts.
What it cannot show: the token a called workflow really receives (act hands
every job a full-scope token, so a `permissions` mistake looks fine - v0.6.1's
did), GitHub's tag and ref rules, and anything on a macOS runner. For those,
push a throwaway caller on a `scratch/*` branch and read the job's "Set up
job" log on GitHub before merging.

[nektos/act]: https://github.com/nektos/act

## What a change usually needs

- **A script change** needs a `test/*.bats` case, with every assertion ending
  in `|| fail "..."` (see the header of `test/assertions-enforced.bats` for
  why).
- **A workflow interface change** — an input, output, secret or env var — needs
  the matching row in [`docs/consumer-guide.md`](docs/consumer-guide.md), and
  the fixtures under `test/fixtures/consumer-min/` updated in the same commit.
  `test/consumer-contract.bats` keeps the guide's examples and the fixtures
  byte-identical, and separately checks the live consumer's `on:` block when
  `WORKFLOWS_CONSUMER_ROOT` points at one.
- **A new gate** - a step in `checks.yml` or `unit.yml` - needs the matching
  target in the consumer's `Makefile`, reachable from `make ci`. The two cases
  at the end of `test/consumer-contract.bats` read the workflow YAML and the
  consumer's Makefile and fail in both directions, so "CI and `make` run the
  same gates" is a mechanism rather than a comment. It used to be a comment,
  and four gates ran locally and in no CI job at all.
- **A change to a script the consumer also ships** — today
  `scripts/release/resolve-version.sh` and `scripts/release/build-info.sh` —
  has to move both copies. They are contract-identical, not byte-identical, and
  the parity cases above are what holds them together; run them with
  `WORKFLOWS_TEMPLATE_DIR` set before you push, because a laptop run skips them.
- **A tool version bump** moves `scripts/lib/versions.sh` *and* the mirrors in
  `.mise.toml` and the workflow defaults; `make check-versions` is what fails
  otherwise.
- **A new `##`-documented make target** needs a row in the `AGENTS.md` command
  table, and vice versa — `test/docs-contract.bats` checks both directions.

## Pull requests

Fill in the template checklist honestly. Keep PRs reviewable; split mechanical
churn into its own commit. If a change is breaking for a repo pinned at `@v0`,
say so in the PR body — the pin is the only thing standing between a mistake
here and every consumer's CI.

Releases are automated: release-please keeps a release PR open on `main`, and
squash-merging it cuts the version and re-points the moving `v0`/`v0.<minor>` tags.
Never move a tag or edit a version by hand.

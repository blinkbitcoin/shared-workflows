# @blinkbitcoin/dev-config

The shared developer-tooling baseline. Install it as a devDependency in any
repo on the baseline, whatever package manager or toolchain provisioner that
repo uses.

```sh
pnpm add -D @blinkbitcoin/dev-config   # or npm install --save-dev
```

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

## `check-consumer-contract`

```sh
check-consumer-contract                     # this repository, against the contract
check-consumer-contract --skeleton          # ...and what would clear every failure
check-consumer-contract --json              # the same findings, machine-readable
check-consumer-contract --profile checks    # before you have written a caller
```

Answers "is this repository wired up for the shared workflows?" in one report.
Every gate in that family already fails with a good message; what none of them
can do is tell you the *other* eight things that are also missing, because each
runs in its own job and stops at the first. So a repository that does not yet
satisfy the contract learns it serially — a screen of parallel reds, then the
next missing piece one push later. This collapses that into one report, with a
fix per finding.

`check-code.yml` runs it as its first job. Running it here gets the same answer
before you push.

It reports **blocked** for a gate you asked for that cannot run, and
**degraded** for one where shared-workflows has a fallback — the gate still
runs, just not the one this repository defined. It reads your own
`.github/workflows/` to decide what applies: a repository that never calls
`check-e2e.yml` is not told it is missing Maestro flows.

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

Seven checks for rules a repository on the baseline holds itself to, each a
program and a module (`@blinkbitcoin/dev-config/<name>`) whose functions a
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

## One commit of shared-workflows

A consumer calls the workflows pinned to a commit SHA and takes this family's
packages as git dependencies at that same commit. Dependabot moves the `uses:`
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
- `check-consumer-contract`'s `pin.one-commit` row asserts the same agreement:
  every call, and each package in `package.json` and `pnpm-lock.yaml`.
## The checks CI runs, for a laptop

`check-code.yml` runs four shell checks from this repository. The package
carries byte-identical copies, so a consumer's `make check` runs exactly what
CI runs, at the same commit:

```sh
bash node_modules/@blinkbitcoin/dev-config/checks/i18n.sh      # runs your i18n:extract, fails on a diff under I18N_PATHS
bash node_modules/@blinkbitcoin/dev-config/checks/codegen.sh   # runs your codegen, fails on a diff under CODEGEN_PATHS
bash node_modules/@blinkbitcoin/dev-config/checks/secrets.sh   # gitleaks over the whole history, at the pinned version
bash node_modules/@blinkbitcoin/dev-config/ci/lint-ci.sh       # actionlint, zizmor and shellcheck at the pinned versions
```

- **Paths:**
  - `I18N_PATHS` defaults to `src/i18n/locales`.
  - `CODEGEN_PATHS` defaults to `src/graphql/generated`.
  - `WORKFLOWS_SHELLCHECK_PATHS` names the directories shellcheck lints (default `scripts`).
- **Switches:** `WORKFLOWS_ACTIONLINT`, `WORKFLOWS_ZIZMOR` and `WORKFLOWS_SHELLCHECK` turn one half off.
- **zizmor policy:** a repository without its own `.github/zizmor.yml` gets this family's, which the package carries as `zizmor.yml`.
- **Run with `bash`, not as a program:** the scripts source `lib/` beside them, and a `node_modules/.bin` link would break that.

## Release scripts

`release/resolve-version.sh` and `release/build-info.sh` are the scripts
`build-prepare.yml` runs to decide a build's version and build number and to
write its `build-info.json`, with the two libraries they source in `lib/`. A
consumer runs them on a laptop from the installed package, so `make version`
there answers exactly what CI will build:

```sh
bash node_modules/@blinkbitcoin/dev-config/release/resolve-version.sh [dir]
bash node_modules/@blinkbitcoin/dev-config/release/build-info.sh --standalone
```

`--standalone` is for a laptop, where no earlier step ran: it resolves the
version and build number and computes both fingerprints (the consumer's
`fingerprint:generate`) for whatever is not already in the environment. In CI,
without it, a missing version stays fatal.

They are byte-identical copies of `scripts/release/` and `scripts/lib/` in
shared-workflows, refreshed by `scripts/self/package-copies.sh --write` and
held identical on every commit by `test/package-copies.bats`, so they cannot
say one thing on a laptop and another in a release.

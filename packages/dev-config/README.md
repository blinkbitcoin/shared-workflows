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

Six checks for rules a repository on the baseline holds itself to, each a
program and a module (`@blinkbitcoin/dev-config/<name>`) whose functions a
test can import. The template wrote them first; they live here so the template,
this repository and the next consumer run the same code.

```sh
check-docs-tables [--max 120] [file...]     # a markdown table cell line over the limit
check-diagrams [--all] [file...]            # a mermaid block that does not parse
check-shell-locale [--root DIR]             # LC_ALL=C cmd instead of env LC_ALL=C cmd
check-make-target-names [--allow T=REASON]  # a make target named after the tool it runs
check-workflow-names --group ci=CI ...      # a workflow file or display name outside its group
check-coverage-empty [summary.json]         # a Jest coverage row with nothing to cover
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
- `check-make-target-names` takes the tools from `.mise.toml` and the unscoped
  packages in `package.json`, spares `setup-` targets, and fails on an
  `--allow` that no longer applies.
- `check-workflow-names` requires every file in `.github/workflows` to be
  `PREFIX.yml` or `PREFIX-*.yml` for a group, and, where the group has a
  display name, its `name:` to be `DISPLAY` or `DISPLAY / ...`.
- `check-coverage-empty` fails on a file with zero statements in a
  `coverage-summary.json`, which reads as 0% while the totals stay at 100%.

## Release scripts

`release/resolve-version.sh` and `release/build-info.sh` are the scripts
`build-prepare.yml` runs to decide a build's version and build number and to
write its `build-info.json`, with the two libraries they source in `lib/`. A
consumer runs them on a laptop from the installed package, so `make version`
there answers exactly what CI will build:

```sh
bash node_modules/@blinkbitcoin/dev-config/release/resolve-version.sh [dir]
```

They are byte-identical copies of `scripts/release/` and `scripts/lib/` in
shared-workflows, refreshed by `scripts/self/package-copies.sh --write` and
held identical on every commit by `test/package-copies.bats`, so they cannot
say one thing on a laptop and another in a release.

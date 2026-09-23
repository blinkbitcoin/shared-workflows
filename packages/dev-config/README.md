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

Unlike `check-tool-versions`, this one is specific to the React Native workflow
family rather than to any repository on the baseline.

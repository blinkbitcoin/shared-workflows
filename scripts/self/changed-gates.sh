#!/usr/bin/env bash
# Which of this repository's narrow CI gates a diff range can affect, so
# self-ci.yml skips the rest. Writes:
#
#   ci        true when check-ci (shellcheck, actionlint, zizmor) has something new to read
#   versions  true when check-version-pins or check-tool-versions has something new to read
#   package   true when the Package job's suites have something new to read: a
#             package's suite (anything under packages/), or test-scripts
#
# Include-based, unlike the consumer classifier (scripts/ci/changed-class.sh):
# each of these gates is one make target whose inputs are known exactly, so
# "some changed path is an input" is the precise question. The gates with no
# class here - bats, gitleaks, typos, commitlint - read the whole tree
# or the whole history and run on every change.
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"
source "$(dirname "$0")/../lib/changed-files.sh"
base="${1:-}"
head="${2:?usage: changed-gates.sh BASE_SHA HEAD_SHA}"

# What changes how every gate runs: the recipes, the pinned tools, the three
# self workflows and this classifier itself. Any of them runs every gate.
every_gate='^Makefile$|^\.mise\.toml$|^\.github/workflows/self-(ci|checks|unit)\.yml$|^scripts/self/changed-gates\.sh$|^scripts/lib/(common|changed-files)\.sh$'
# `make check-ci` reads every script under scripts/ and plugins/ (shellcheck,
# and .shellcheckrc), and the workflows, the composite actions and the linters'
# own configuration under .github/ (actionlint and zizmor).
ci_patterns="$every_gate"'|^(scripts|plugins)/.*\.sh$|^\.shellcheckrc$|^\.github/'
# The files scripts/self/check-version-pins.sh compares, the generator
# render-versions.mjs and the package's copy of versions.sh it writes, and the
# check-tool-versions check.
versions_patterns="$every_gate"'|^scripts/lib/versions\.sh$|^packages/app-tooling/lib/versions\.sh$|^scripts/self/(check-version-pins\.sh|render-versions\.mjs)$|^packages/app-tooling/versions\.json$|^packages/app-tooling/bin/check-tool-versions\.mjs$|^\.github/workflows/(test-e2e|build-android)\.yml$|^\.github/actions/maestro/'
# The Package job runs `make test-package` (everything under packages/; its
# suites also read the workflow files) and `make test-scripts`: the Node
# scripts under scripts/ and test/*.test.mjs, which evaluate the pipelines'
# job graphs from .github/workflows/, run the release scripts (and the lib they
# source) end to end, and hold the contract table in
# docs/adopting-an-existing-repo.md to its generator.
package_patterns="$every_gate"'|^packages/|^scripts/.*\.mjs$|^scripts/(release|lib)/|^test/[^/]+\.test\.mjs$|^test/lib/|^\.github/workflows/[^/]+\.yml$|^docs/adopting-an-existing-repo\.md$'

run_every_gate() {
  gh_output ci true
  gh_output versions true
  gh_output package true
  exit 0
}

# No answer is "run every gate", exactly as for the consumer classes.
files=$(changed_files "$base" "$head") || run_every_gate

# The patterns are fixed text in this file and test/changed-gates.bats runs each
# one, so one that does not compile never reaches CI; `set -e` stops the step
# loudly if it somehow does.
ci=$(any_path_matches "$ci_patterns" "$files")
versions=$(any_path_matches "$versions_patterns" "$files")
package=$(any_path_matches "$package_patterns" "$files")
gh_output ci "$ci"
gh_output versions "$versions"
gh_output package "$package"

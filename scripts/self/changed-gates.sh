#!/usr/bin/env bash
# Which of this repository's narrow CI gates a diff range can affect, so
# self-ci.yml skips the rest. Writes:
#
#   code      true when check-ci (shellcheck, actionlint, zizmor) has something new to read
#   tooling   true when check-version-pins or check-tool-versions has something new to read
#   package   true when a package's suite (anything under packages/) has something new to read
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
# `make check-ci` reads every script under scripts/ (shellcheck, and
# .shellcheckrc), and the workflows, the composite actions and the linters'
# own configuration under .github/ (actionlint and zizmor).
code_globs="$every_gate"'|^scripts/.*\.sh$|^\.shellcheckrc$|^\.github/'
# The files scripts/self/check-version-pins.sh compares, and the check-tool-versions check.
tooling_globs="$every_gate"'|^scripts/lib/versions\.sh$|^scripts/self/check-version-pins\.sh$|^packages/app-tooling/versions\.json$|^packages/app-tooling/bin/check-tool-versions\.mjs$|^\.github/workflows/(check-e2e|build-android)\.yml$|^\.github/actions/maestro/'
package_globs="$every_gate"'|^packages/'

run_every_gate() {
  gh_output code true
  gh_output tooling true
  gh_output package true
  exit 0
}

# No answer is "run every gate", exactly as for the consumer classes.
files=$(changed_files "$base" "$head") || run_every_gate

# The patterns are fixed text in this file and test/changed-gates.bats runs each
# one, so one that does not compile never reaches CI; `set -e` stops the step
# loudly if it somehow does.
code=$(any_path_matches "$code_globs" "$files")
tooling=$(any_path_matches "$tooling_globs" "$files")
package=$(any_path_matches "$package_globs" "$files")
gh_output code "$code"
gh_output tooling "$tooling"
gh_output package "$package"

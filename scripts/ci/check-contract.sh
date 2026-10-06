#!/usr/bin/env bash
# Report every unmet requirement of this workflow family in the consumer, in one
# place, before the gates that would each die on their own.
#
# A thin wrapper, like every other step's script: check.yml wires the inputs and
# this resolves the consumer root and calls the checker.
#
# The checker lives in packages/app-tooling rather than here because a consumer
# should be able to run the same check on a laptop before pushing, and that
# package is how this repo ships anything installable. It is plain node with no
# dependencies on purpose: this step runs BEFORE the setup action, so the
# toolchain it would otherwise need is exactly what may be missing.
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"
require_cmd node

checker="$(cd "$(dirname "$0")/../.." && pwd)/packages/app-tooling/bin/check-contract.mjs"
[ -f "$checker" ] || die "check-contract.sh: no checker at $checker"

# Two steps, not `cd "$(consumer_root)"`: a command substitution used as an
# argument does not propagate its exit status, and `cd ""` is a successful
# no-op. Same reason as pnpm-install.sh.
# A contract-only run gates nothing. It is opt-in and useful - "would these
# workflows work here?" answered in seconds rather than runner-minutes - but a
# green Checks that ran no gate is exactly the shape of result someone reads as
# "it passed". So the run says what it was.
if [ "${WORKFLOWS_CONTRACT_ONLY:-}" = "true" ]; then
  warn 'contract-only run: the contract was checked and NO gate ran. This is not a passing build.'
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    gh_summary '> **Contract-only run.** No gate ran - this is not a passing build.' ''
  fi
fi

root="$(consumer_root)"
# check.yml's native-stack input, when the caller sets one. The checker also
# reads the callers' own `with: native-stack:`, but a value wired to an
# expression is only known here, at run time.
stack=()
[ -z "${NATIVE_STACK:-}" ] || stack=(--native-stack "$NATIVE_STACK")
# Expanded with ${stack[@]+...}: an empty array is "unbound" under set -u in
# bash before 4.4.
exec node "$checker" --root "$root" --skeleton ${stack[@]+"${stack[@]}"}

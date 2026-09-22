#!/usr/bin/env bash
# Report every unmet requirement of this workflow family in the consumer, in one
# place, before the gates that would each die on their own.
#
# A thin wrapper, like every other step's script: checks.yml wires the inputs and
# this resolves the consumer root and calls the checker.
#
# The checker lives in packages/dev-config rather than here because a consumer
# should be able to run the same check on a laptop before pushing, and that
# package is how this repo ships anything installable. It is plain node with no
# dependencies on purpose: this step runs BEFORE the setup action, so the
# toolchain it would otherwise need is exactly what may be missing.
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"
require_cmd node

checker="$(cd "$(dirname "$0")/../.." && pwd)/packages/dev-config/bin/check-consumer-contract.mjs"
[ -f "$checker" ] || die "contract-check.sh: no checker at $checker"

# Two steps, not `cd "$(consumer_root)"`: a command substitution used as an
# argument does not propagate its exit status, and `cd ""` is a successful
# no-op. Same reason as pnpm-install.sh.
root="$(consumer_root)"
exec node "$checker" --root "$root" --skeleton

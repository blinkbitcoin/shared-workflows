#!/usr/bin/env bash
# Maestro E2E on the booted iOS simulator.
# Needs: app installed and launched (app-launch.sh), Metro running.
# Output: $WORKFLOWS_OUT/maestro/junit.xml + debug output (screenshots, per-flow logs).
# Usage: ios-maestro.sh [MAESTRO-TEST-ARGUMENTS...] (appended to `maestro test`, e.g. a
#        local `--include-tags smoke`)
# No `set -e`: the suite's failure is handled here (retry, forensics), not by
# the shell exiting mid-script. The suite run itself is maestro-suite.sh's.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/../lib/common.sh"
source "$HERE/../lib/e2e-env.sh"
export PATH="$HOME/.maestro/bin:$PATH"
# shellcheck source=scripts/e2e/maestro-suite.sh
. "$HERE/maestro-suite.sh"
require_cmd maestro

prepare_maestro_suite

trap 'workflows_run_hook WORKFLOWS_E2E_TEARDOWN_SCRIPT || true' EXIT
workflows_run_hook WORKFLOWS_E2E_SETUP_SCRIPT || die "WORKFLOWS_E2E_SETUP_SCRIPT failed"

# Address the picked simulator explicitly: a developer Mac (and a warm runner)
# can have an Android emulator attached at the same time, and Maestro otherwise
# picks whichever device it finds first.
udid="$(workflows_sim_udid)"
run_maestro_suite ios iOS --udid "$udid" -- "$@"
exit "$?"

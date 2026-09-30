#!/usr/bin/env bash
# Maestro E2E on the booted iOS simulator.
# Needs: app installed and launched (app-launch.sh), Metro running.
# Output: $WORKFLOWS_OUT/maestro/junit.xml + debug output (screenshots, per-flow logs).
# Usage: ios-maestro.sh [MAESTRO-TEST-ARGUMENTS...] (appended to `maestro test`, e.g. a
#        local `--include-tags smoke`)
# No `set -e`: the suite's failure is handled here (retry, forensics), not by
# the shell exiting mid-script.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/../lib/common.sh"
source "$HERE/../lib/e2e-env.sh"
export PATH="$HOME/.maestro/bin:$PATH"
# shellcheck source=scripts/e2e/maestro-bound.sh
. "$HERE/maestro-bound.sh"
require_cmd maestro

# The driver installs and launches its runner on first use, minutes on a cold
# device; the value must stay below the suite bound (see the helper) so a
# runner that fails to launch is retried instead of burning the bound.
export MAESTRO_DRIVER_STARTUP_TIMEOUT
MAESTRO_DRIVER_STARTUP_TIMEOUT="$(workflows_driver_startup_timeout 300000)" || exit 1

root="$(consumer_root)"
cd "$root" || exit 1
flows="$WORKFLOWS_MAESTRO_FLOWS"
[ -d "$flows" ] || die "no flows directory at $root/$flows (WORKFLOWS_MAESTRO_FLOWS)"
out="$WORKFLOWS_OUT/maestro"
mkdir -p "$out"

trap 'workflows_run_hook WORKFLOWS_E2E_TEARDOWN_SCRIPT || true' EXIT
workflows_run_hook WORKFLOWS_E2E_SETUP_SCRIPT || die "WORKFLOWS_E2E_SETUP_SCRIPT failed"

args=(test "$flows" --platform ios)
# Address the picked simulator explicitly: a developer Mac (and a warm runner)
# can have an Android emulator attached at the same time, and Maestro otherwise
# picks whichever device it finds first.
args+=(--udid "$(workflows_sim_udid)")
[ -f "$flows/config.yaml" ] && args+=(--config "$flows/config.yaml")
args+=(
  -e "APP_ID=$(workflows_app_id ios)"
  --debug-output "$out"
  --flatten-debug-output
  --format junit
  --output "$out/junit.xml"
)
# The consumer's config.yaml usually carries includeTags already; the env var is
# for narrowing a single run (a smoke-only PR job) without editing the config.
[ -n "${WORKFLOWS_MAESTRO_INCLUDE_TAGS:-}" ] && args+=(--include-tags "$WORKFLOWS_MAESTRO_INCLUDE_TAGS")
[ -n "${WORKFLOWS_MAESTRO_EXCLUDE_TAGS:-}" ] && args+=(--exclude-tags "$WORKFLOWS_MAESTRO_EXCLUDE_TAGS")
# Whatever the caller passes goes last, so a developer can narrow or extend one
# local run without an environment variable for every Maestro flag.
args+=("$@")

bound=$((WORKFLOWS_SUITE_TIMEOUT_MINUTES * 60))
status=0
group "maestro test (iOS, bound ${WORKFLOWS_SUITE_TIMEOUT_MINUTES}m)"
bounded_maestro "$bound" maestro "${args[@]}" || status=$?
endgroup

# A hung driver is not retried - the second attempt would only run into the
# step's timeout-minutes and cost another suite's worth of wall clock.
if [ "$status" -ne 0 ] && [ "$status" -ne 124 ]; then
  log "::warning::Maestro suite failed (status $status) - rerunning the suite once"
  status=0
  group "maestro test (iOS, retry)"
  bounded_maestro "$bound" maestro "${args[@]}" || status=$?
  endgroup
fi
# A green suite still has to have been a suite. Maestro exits 0 when its flow
# selection matches nothing, so success is only success once the junit report
# says how many flows actually ran.
if [ "$status" -eq 0 ]; then
  workflows_assert_suite_ran "$out/junit.xml" "iOS"
fi
exit "$status"

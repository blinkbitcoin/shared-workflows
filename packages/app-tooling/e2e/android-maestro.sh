#!/usr/bin/env bash
# The whole on-device half of the Android E2E job in one file: install, wire,
# record, launch, run the suite, collect forensics. It is a single file on
# purpose - reactivecircus/android-emulator-runner executes each line of its
# `script:` input as its own `sh -c`, so multi-step shell cannot live inline.
# Needs: emulator up, debug APK built, Metro running.
# Output: $WORKFLOWS_OUT/maestro/junit.xml, $WORKFLOWS_OUT/forensics/*
# Usage: android-maestro.sh [MAESTRO-TEST-ARGUMENTS...] (appended to `maestro test`, e.g. a
#        local `--include-tags smoke`)
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/../lib/common.sh"
source "$HERE/../lib/e2e-env.sh"
export PATH="$HOME/.maestro/bin:$PATH"
# shellcheck source=scripts/e2e/maestro-bound.sh
. "$HERE/maestro-bound.sh"
require_cmd maestro adb

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

bash "$HERE/android-emulator.sh" prepare || die "android-emulator.sh prepare failed"
bash "$HERE/android-emulator.sh" record start || true

# shellcheck disable=SC2329  # invoked by the EXIT trap below
cleanup() {
  bash "$HERE/android-emulator.sh" record stop || true
  bash "$HERE/collect-forensics.sh" android || true
  workflows_run_hook WORKFLOWS_E2E_TEARDOWN_SCRIPT || true
}
trap cleanup EXIT

workflows_run_hook WORKFLOWS_E2E_SETUP_SCRIPT || die "WORKFLOWS_E2E_SETUP_SCRIPT failed"
bash "$HERE/app-launch.sh" android || die "app-launch.sh android failed"

# --platform android so an iOS simulator on the same machine is never picked.
args=(test "$flows" --platform android)
[ -f "$flows/config.yaml" ] && args+=(--config "$flows/config.yaml")
args+=(
  -e "APP_ID=$(workflows_app_id android)"
  --debug-output "$out"
  --flatten-debug-output
  --format junit
  --output "$out/junit.xml"
)
[ -n "${WORKFLOWS_MAESTRO_INCLUDE_TAGS:-}" ] && args+=(--include-tags "$WORKFLOWS_MAESTRO_INCLUDE_TAGS")
[ -n "${WORKFLOWS_MAESTRO_EXCLUDE_TAGS:-}" ] && args+=(--exclude-tags "$WORKFLOWS_MAESTRO_EXCLUDE_TAGS")
# Whatever the caller passes goes last, so a developer can narrow or extend one
# local run without an environment variable for every Maestro flag.
args+=("$@")

bound=$((WORKFLOWS_SUITE_TIMEOUT_MINUTES * 60))
status=0
group "maestro test (Android, bound ${WORKFLOWS_SUITE_TIMEOUT_MINUTES}m)"
bounded_maestro "$bound" maestro "${args[@]}" || status=$?
endgroup

if [ "$status" -ne 0 ] && [ "$status" -ne 124 ]; then
  log "::warning::Maestro suite failed (status $status) - rerunning the suite once"
  status=0
  group "maestro test (Android, retry)"
  bounded_maestro "$bound" maestro "${args[@]}" || status=$?
  endgroup
fi
# A green suite still has to have been a suite. Maestro exits 0 when its flow
# selection matches nothing, so success is only success once the junit report
# says how many flows actually ran.
if [ "$status" -eq 0 ]; then
  workflows_assert_suite_ran "$out/junit.xml" "Android"
fi
exit "$status"

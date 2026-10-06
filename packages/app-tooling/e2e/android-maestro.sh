#!/usr/bin/env bash
# The whole on-device half of the Android E2E job in one file: install, wire,
# record, launch, run the suite, collect forensics. It is a single file on
# purpose - reactivecircus/android-emulator-runner executes each line of its
# `script:` input as its own `sh -c`, so multi-step shell cannot live inline.
# The suite run itself is maestro-suite.sh's, shared with ios-maestro.sh.
# Needs: emulator up, debug APK built, Metro running.
# Output: $WORKFLOWS_OUT/maestro/junit.xml, $WORKFLOWS_OUT/forensics/*
# Usage: android-maestro.sh [MAESTRO-TEST-ARGUMENTS...] (appended to `maestro test`, e.g. a
#        local `--include-tags smoke`)
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/../lib/common.sh"
source "$HERE/../lib/e2e-env.sh"
export PATH="$HOME/.maestro/bin:$PATH"
# shellcheck source=scripts/e2e/maestro-suite.sh
. "$HERE/maestro-suite.sh"
require_cmd maestro adb

prepare_maestro_suite

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

run_maestro_suite android Android -- "$@"
exit "$?"

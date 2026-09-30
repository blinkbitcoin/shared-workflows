#!/usr/bin/env bash
# The Expo project health check: SDK drift is advisory, expo-doctor blocks.
#
# check.yml runs it for a consumer that ships no `check:expo-health` script of
# its own, and @blinkbitcoin/app-tooling ships it as checks/expo-health.sh, so a
# consumer's `make check-dependencies` runs exactly this on a laptop.
#
# `expo install --check` and expo-doctor's version check both demand whatever
# patch the SDK expects *today*, and Expo publishes patches most weeks. A
# pnpm `minimumReleaseAge` refuses a patch until it is a day old, so for that
# day the two disagree, and every open pull request went red on a version the
# repository could not install yet. So the drift is reported, not enforced: the
# table is printed, CI gets a warning annotation, and the exit status is
# doctor's alone, with its version check switched off because the drift check
# above has already run it. Doctor's other checks - config sync, package.json
# conflicts, duplicate native modules - stay blocking: those are real
# breakage, not the calendar. A consumer with no expo dependency has no SDK to
# drift from, and the drift check is skipped.
#
# Doctor is the consumer's own pinned copy (a devDependency) when there is one,
# and otherwise the latest published version through `pnpm dlx`.
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"
require_cmd pnpm node

root="$(consumer_root)"
cd "$root"

# has_dependency NAME [KEYS] - whether package.json names NAME under one of the
# comma-separated KEYS (default dependencies,devDependencies).
has_dependency() {
  DEPENDENCY_NAME="$1" DEPENDENCY_KEYS="${2:-dependencies,devDependencies}" node -e "
    const pkg = require('./package.json');
    const found = process.env.DEPENDENCY_KEYS.split(',').some((key) => pkg[key]?.[process.env.DEPENDENCY_NAME]);
    process.exit(found ? 0 : 1);" 2>/dev/null
}

if has_dependency expo; then
  drift_status=0
  drift_output="$(pnpm exec expo install --check 2>&1)" || drift_status=$?
  printf '%s\n' "$drift_output"
  if [ "$drift_status" -ne 0 ]; then
    behind="$(printf '%s\n' "$drift_output" | grep -cE '^[[:space:]]+[^[:space:]]+@[^[:space:]]+ - expected version:' || true)"
    msg="Expo SDK drift: ${behind} package(s) behind the SDK's expected patch. Advisory - run 'pnpm expo install --check' when the release cooldown lets the patch in."
    log "warning: $msg"
    if [ -n "${GITHUB_ACTIONS:-}" ]; then echo "::warning title=Expo SDK drift::$msg"; fi
  fi
else
  log "no expo dependency in package.json: the SDK drift check is skipped"
fi

export EXPO_DOCTOR_SKIP_DEPENDENCY_VERSION_CHECK=1
if has_dependency expo-doctor devDependencies; then
  pnpm exec expo-doctor
else
  pnpm dlx expo-doctor@latest
fi

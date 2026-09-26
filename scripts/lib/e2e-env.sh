#!/usr/bin/env bash
# Shared env contract for scripts/native and scripts/e2e. Source it after
# common.sh; do not execute. Every variable is optional and has a default, so a
# consumer only sets what it needs to override (see scripts/e2e/README.md).
# shellcheck shell=bash

WORKFLOWS_DEV_CLIENT="${WORKFLOWS_DEV_CLIENT:-true}"
WORKFLOWS_MAESTRO_FLOWS="${WORKFLOWS_MAESTRO_FLOWS:-.maestro}"
WORKFLOWS_SUITE_TIMEOUT_MINUTES="${WORKFLOWS_SUITE_TIMEOUT_MINUTES:-10}"
WORKFLOWS_METRO_PORT="${WORKFLOWS_METRO_PORT:-8081}"
# Host-side mock API the E2E setup hook starts (the template's mock GraphQL
# server listens on 4000). Reversed into the emulator so the app's localhost
# URLs work unchanged; empty disables the reverse entirely.
WORKFLOWS_MOCK_API_PORT="${WORKFLOWS_MOCK_API_PORT-4000}"
WORKFLOWS_OUT="${WORKFLOWS_OUT:-${RUNNER_TEMP:-/tmp}/workflows}"
export WORKFLOWS_DEV_CLIENT WORKFLOWS_MAESTRO_FLOWS WORKFLOWS_SUITE_TIMEOUT_MINUTES WORKFLOWS_METRO_PORT WORKFLOWS_MOCK_API_PORT WORKFLOWS_OUT
mkdir -p "$WORKFLOWS_OUT"

# Immutable "the run started here" stamp. collect-forensics.sh needs a fixed
# instant to select crash reports from, and metro.log cannot serve: it is
# appended throughout the run, so its mtime is the last Metro write. Created by
# whichever script sources this file first, then never touched again.
WORKFLOWS_RUN_START="$WORKFLOWS_OUT/run-start"
WORKFLOWS_RUN_START_FRESH=
if [ ! -e "$WORKFLOWS_RUN_START" ]; then
  : > "$WORKFLOWS_RUN_START" 2>/dev/null && WORKFLOWS_RUN_START_FRESH=1
fi
# WORKFLOWS_RUN_START_FRESH says "this process created the stamp", i.e. nothing ran
# before it. A collector that stamps the run itself would select nothing at all,
# so it falls back to a time window instead.
export WORKFLOWS_RUN_START WORKFLOWS_RUN_START_FRESH

# Publish WORKFLOWS_OUT/WORKFLOWS_RUN_START to $GITHUB_ENV so every later step in the job
# (including composite actions, e.g. `forensics`'s default `path` input) can
# see them without re-sourcing this file. gh_env_once's guard is file-based
# (checks $GITHUB_ENV itself), so it dedupes across the many separate steps -
# each its own process - that source this file within one job, not just
# within one process.
gh_env_once WORKFLOWS_OUT "$WORKFLOWS_OUT"
gh_env_once WORKFLOWS_RUN_START "$WORKFLOWS_RUN_START"

# Directory holding scripts/lib, resolved from this file so callers in any
# subdirectory (scripts/native, scripts/e2e) find expo-config.sh.
WORKFLOWS_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export WORKFLOWS_LIB_DIR

# workflows_platform [ARG] -> ios|android. Positional argument wins over WORKFLOWS_PLATFORM.
workflows_platform() {
  local p="${1:-${WORKFLOWS_PLATFORM:-}}"
  case "$p" in
    ios | android) printf '%s\n' "$p" ;;
    *) die "platform must be ios or android (got '${p}'); pass it as \$1 or set WORKFLOWS_PLATFORM" ;;
  esac
}

workflows_expo_config() { bash "$WORKFLOWS_LIB_DIR/expo-config.sh" "$1"; }

# workflows_app_id PLATFORM -> the application id under test. WORKFLOWS_APP_ID wins; the
# default comes straight from the resolved Expo config, which already carries
# any variant suffix (the template's app.config.ts appends `.dev` itself), so
# nothing is appended here.
workflows_app_id() {
  if [ -n "${WORKFLOWS_APP_ID:-}" ]; then printf '%s\n' "$WORKFLOWS_APP_ID"; return 0; fi
  # Read on its own line: a failing `$(...)` in a `case` word never stops the
  # shell, so an unknown platform used to answer an empty id with status 0.
  local platform
  platform="$(workflows_platform "${1:-}")" || return
  case "$platform" in
    ios) workflows_expo_config ios.bundleIdentifier ;;
    android) workflows_expo_config android.package ;;
  esac
}

workflows_scheme() { workflows_expo_config scheme; }

# workflows_ios_scheme -> the Xcode scheme/target name. Derived from the Expo config
# (`name` stripped of non-alphanumerics, which is what prebuild generates) but
# validated against the workspace prebuild actually wrote: the workspace name is
# authoritative, a disagreement is only a warning so the build still runs.
workflows_ios_scheme() {
  local root ws ws_name cfg_name
  # Read through `$(...)` by its callers, where `set -e` does not reach.
  root="$(consumer_root)" || die "the consumer's working directory does not exist: ${GITHUB_WORKSPACE:-$PWD}/${WORKING_DIRECTORY:-.}"
  ws="$(find "$root/ios" -maxdepth 1 -name '*.xcworkspace' 2>/dev/null | head -1)"
  [ -n "$ws" ] || die "no ios/*.xcworkspace in $root - run prebuild.sh ios and pods.sh first"
  ws_name="$(basename "$ws" .xcworkspace)"
  # The workspace name is what we return, always. The Expo config is only a
  # cross-check, and asking for it runs `pnpm exec expo config` - which on a
  # cache hit means installing the whole dependency tree (~80s) to produce a
  # warning that changes nothing. Best-effort: when the config is not already
  # available, skip the comparison rather than make every caller pay for it.
  if cfg_name="$(workflows_expo_config ios.scheme-name 2>/dev/null)" &&
    [ -n "$cfg_name" ] && [ "$ws_name" != "$cfg_name" ]; then
    printf '::warning::expo-config scheme-name (%s) disagrees with the generated workspace (%s); using the workspace name\n' \
      "$cfg_name" "$ws_name" >&2
  fi
  printf '%s\n' "$ws_name"
}

# workflows_driver_startup_timeout DEFAULT_MS -> the MAESTRO_DRIVER_STARTUP_TIMEOUT
# to export, honouring an explicit environment value, and refusing one that is
# not strictly below the suite bound. Maestro throws IOSDriverTimeoutException
# ("iOS driver not ready in time") when this expires - a real, retryable failure
# the maestro scripts rerun once. With the value at or above the bound the bound
# fires first, exits 124, and 124 is never retried: a driver that failed to
# launch (`TEST EXECUTE FAILED` in xctest_runner_*.log, seen at 77s on a loaded
# runner) then costs the whole bound and zero flows run. Healthy runner startups
# measured 86s and 144s; 300000 leaves 2x headroom and half the bound for flows.
workflows_driver_startup_timeout() {
  local default_ms="${1:?usage: workflows_driver_startup_timeout DEFAULT_MS}"
  local ms="${MAESTRO_DRIVER_STARTUP_TIMEOUT:-$default_ms}"
  local bound_ms=$((WORKFLOWS_SUITE_TIMEOUT_MINUTES * 60 * 1000))
  case "$ms" in *[!0-9]* | '') die "MAESTRO_DRIVER_STARTUP_TIMEOUT must be milliseconds, got '$ms'" ;; esac
  [ "$ms" -lt "$bound_ms" ] ||
    die "MAESTRO_DRIVER_STARTUP_TIMEOUT=$ms is not below the suite bound (${bound_ms}ms): a driver that fails to start would burn the bound (exit 124, never retried) instead of failing fast and being retried"
  printf '%s\n' "$ms"
}

# workflows_ios_unified_log_predicate -> the `log stream --predicate` that
# ios-simulator.sh records next to the video. The app id (from the Expo config,
# or WORKFLOWS_APP_ID) and its URL scheme narrow the firehose to the lines that
# explain a deep link: SpringBoard presenting/dismissing the "Open in <app>?"
# alert, the app's scene being deactivated behind it, and FrontBoard handing
# the UIOpenURLAction to the app.
workflows_ios_unified_log_predicate() {
  local app_id scheme
  app_id="$(workflows_app_id ios 2>/dev/null || printf '%s' "${WORKFLOWS_APP_ID:-}")"
  scheme="$(workflows_scheme 2>/dev/null || true)"
  printf '%s' "(process == \"SpringBoard\" AND (category == \"AlertItems\" OR category == \"AlertItemStack\" OR category == \"SceneDeactivation\"))"
  printf '%s' " OR (subsystem == \"com.apple.FrontBoard\" AND category == \"SceneClient\")"
  [ -n "$app_id" ] && printf '%s' " OR eventMessage CONTAINS \"$app_id\""
  [ -n "$scheme" ] && printf '%s' " OR eventMessage CONTAINS \"$scheme://\""
  printf '\n'
}

# Debug unless a caller asks for Release. Release is what makes an iOS E2E app
# self-contained: the JS bundle is embedded and expo-dev-client's launcher is
# not in the build, so the app runs on `simctl launch` alone - no Metro, no
# deep link, no "Open in <app>?" prompt. Each of those is a step that has to
# succeed on every run, and each has failed on a runner.
WORKFLOWS_IOS_CONFIGURATION="${WORKFLOWS_IOS_CONFIGURATION:-Debug}"
WORKFLOWS_IOS_PRODUCTS_DIR="ios/build/Build/Products/$WORKFLOWS_IOS_CONFIGURATION-iphonesimulator"
WORKFLOWS_ANDROID_APK="android/app/build/outputs/apk/debug/app-debug.apk"
export WORKFLOWS_IOS_CONFIGURATION WORKFLOWS_IOS_PRODUCTS_DIR WORKFLOWS_ANDROID_APK

# The picked simulator is remembered in $WORKFLOWS_OUT so every later step addresses
# it explicitly: `booted` is ambiguous on a developer Mac with several
# simulators up, and GITHUB_ENV does not reach a local shell.
workflows_sim_udid() {
  if [ -n "${WORKFLOWS_SIM_UDID:-}" ]; then printf '%s\n' "$WORKFLOWS_SIM_UDID"; return 0; fi
  [ -f "$WORKFLOWS_OUT/sim-udid" ] || die "no simulator selected - run ios-simulator.sh pick first"
  cat "$WORKFLOWS_OUT/sim-udid"
}

# workflows_run_hook VAR_NAME - run a consumer-relative hook script when the variable
# names one. Missing file is fatal: a silently skipped setup hook produces a
# confusing suite failure later.
workflows_run_hook() {
  local var="$1" path="${!1:-}" root
  [ -n "$path" ] || return 0
  root="$(consumer_root)"
  [ -f "$root/$path" ] || die "$var points at a missing file: $root/$path"
  log "running $var: $path"
  (cd "$root" && bash "$path")
}

# workflows_assert_suite_ran JUNIT_PATH PLATFORM - fail when the suite ran no tests.
#
# Maestro exits 0 when its flow selection matches nothing at all: a tag filter
# that no flow carries, a renamed .maestro/flows directory, a config.yaml whose
# includeTags stopped matching. The job then goes green having tested nothing,
# which is the most expensive kind of pass - it is indistinguishable from a real
# one, and it stays green until someone ships a broken build.
#
# The junit report Maestro already writes carries the count, so no extra run is
# needed. Only the `tests` attribute is read here; whether individual tests
# failed is already in Maestro's own exit status.
workflows_assert_suite_ran() {
  local junit="$1" platform="$2" tests
  if [ ! -f "$junit" ]; then
    die "$platform: Maestro reported success but wrote no junit report at $junit - the suite cannot be shown to have run"
  fi
  # The attribute off the <testsuites>/<testsuite> element. sed rather than an
  # XML parser: the runners have no xmllint guarantee, and this is one attribute
  # in a file Maestro generates to a fixed shape.
  tests="$(sed -n 's/.*[^a-zA-Z]tests="\([0-9][0-9]*\)".*/\1/p' "$junit" | head -1)"
  if [ -z "$tests" ]; then
    die "$platform: no tests= count in $junit - cannot confirm the suite ran"
  fi
  if [ "$tests" -eq 0 ]; then
    die "$platform: Maestro exited 0 but ran 0 flows. Check the flows directory and the tag filters (WORKFLOWS_MAESTRO_INCLUDE_TAGS='${WORKFLOWS_MAESTRO_INCLUDE_TAGS:-}', WORKFLOWS_MAESTRO_EXCLUDE_TAGS='${WORKFLOWS_MAESTRO_EXCLUDE_TAGS:-}') - a suite that selects nothing passes without testing anything."
  fi
  log "$platform: Maestro ran $tests flow(s)"
}

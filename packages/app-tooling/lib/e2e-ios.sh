#!/usr/bin/env bash
# The iOS simulator side of E2E: which simulator a run addresses, and what its
# unified log keeps. Part of the env contract scripts/lib/e2e-env.sh
# assembles; source that, after common.sh.
# shellcheck shell=bash

source "$(dirname "${BASH_SOURCE[0]}")/e2e-app.sh"

# workflows_ios_unified_log_predicate -> the `log stream --predicate` that
# ios-simulator.sh records next to the video. The app id (from the stack's
# app-config, or WORKFLOWS_APP_ID) and its URL scheme narrow the firehose to the lines that
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

# The picked simulator is remembered in $WORKFLOWS_OUT so every later step addresses
# it explicitly: `booted` is ambiguous on a developer Mac with several
# simulators up, and GITHUB_ENV does not reach a local shell.
workflows_sim_udid() {
  if [ -n "${WORKFLOWS_SIM_UDID:-}" ]; then printf '%s\n' "$WORKFLOWS_SIM_UDID"; return 0; fi
  [ -f "$WORKFLOWS_OUT/sim-udid" ] || die "no simulator selected - run ios-simulator.sh pick first"
  cat "$WORKFLOWS_OUT/sim-udid"
}

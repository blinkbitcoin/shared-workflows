#!/usr/bin/env bash
# The app under E2E test: its identifiers (asked of the consumer's native
# stack), where its debug builds land, and the consumer's hook scripts. Part
# of the env contract scripts/lib/e2e-env.sh assembles; source that, after
# common.sh. Sourcing it creates no file and publishes nothing.
# shellcheck shell=bash

source "$(dirname "${BASH_SOURCE[0]}")/shared-env.sh"

WORKFLOWS_DEV_CLIENT="${WORKFLOWS_DEV_CLIENT:-true}"
# Debug unless a caller asks for Release. Release is what makes an iOS E2E app
# self-contained: the JS bundle is embedded and expo-dev-client's launcher is
# not in the build, so the app runs on `simctl launch` alone - no Metro, no
# deep link, no "Open in <app>?" prompt. Each of those is a step that has to
# succeed on every run, and each has failed on a runner.
WORKFLOWS_IOS_CONFIGURATION="${WORKFLOWS_IOS_CONFIGURATION:-Debug}"
WORKFLOWS_IOS_PRODUCTS_DIR="ios/build/Build/Products/$WORKFLOWS_IOS_CONFIGURATION-iphonesimulator"
WORKFLOWS_ANDROID_APK="android/app/build/outputs/apk/debug/app-debug.apk"
export WORKFLOWS_DEV_CLIENT WORKFLOWS_IOS_CONFIGURATION WORKFLOWS_IOS_PRODUCTS_DIR WORKFLOWS_ANDROID_APK

# workflows_app_config KEY -> one identifier of the app, from the consumer's
# native stack: scripts/native/<stack>/app-config.sh, chosen by native-stack.sh.
# KEY is ios-bundle-id, android-package, scheme (the URL scheme) or ios-scheme
# (the Xcode scheme). The Expo stack reads `expo config`; the bare stack reads
# the committed native projects.
workflows_app_config() { bash "$WORKFLOWS_LIB_DIR/native-stack.sh" app-config "$1"; }

# workflows_app_id PLATFORM -> the application id under test. WORKFLOWS_APP_ID wins; the
# default comes from the stack's app-config. For Expo that is the resolved
# config, which already carries any variant suffix (the template's
# app.config.ts appends `.dev` itself), so nothing is appended here.
workflows_app_id() {
  if [ -n "${WORKFLOWS_APP_ID:-}" ]; then printf '%s\n' "$WORKFLOWS_APP_ID"; return 0; fi
  # Read on its own line: a failing `$(...)` in a `case` word never stops the
  # shell, so an unknown platform used to answer an empty id with status 0.
  local platform
  platform="$(workflows_platform "${1:-}")" || return
  case "$platform" in
    ios) workflows_app_config ios-bundle-id ;;
    android) workflows_app_config android-package ;;
  esac
}

# workflows_scheme -> the app's URL scheme (empty for a bare app that has none).
workflows_scheme() { workflows_app_config scheme; }

# workflows_ios_scheme -> the Xcode scheme/target name: the ios/*.xcworkspace
# name, for both stacks (the Expo stack cross-checks it against the config).
workflows_ios_scheme() { workflows_app_config ios-scheme; }

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

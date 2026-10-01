#!/usr/bin/env bash
# Shared env contract for scripts/release and scripts/ota. Source it after
# common.sh; do not execute.
# shellcheck shell=bash

# Where every release artifact this family produces is staged. Mirrors
# scripts/lib/e2e-env.sh's WORKFLOWS_OUT so a job that does both keeps one directory.
WORKFLOWS_OUT="${WORKFLOWS_OUT:-${RUNNER_TEMP:-/tmp}/workflows}"
# Fastlane reads this to decide where to drop the .ipa/.aab it builds.
WORKFLOWS_OUTPUT_DIR="${WORKFLOWS_OUTPUT_DIR:-$WORKFLOWS_OUT}"
WORKFLOWS_RELEASE_META_DIR="${WORKFLOWS_RELEASE_META_DIR:-$WORKFLOWS_OUT/build-info}"
WORKFLOWS_OTA_DIR="${WORKFLOWS_OTA_DIR:-$WORKFLOWS_OUT/ota}"
# Where the artifacts a release job downloads are staged for release-assets.sh.
WORKFLOWS_ASSETS_DIR="${WORKFLOWS_ASSETS_DIR:-$WORKFLOWS_OUT/assets}"
export WORKFLOWS_OUT WORKFLOWS_OUTPUT_DIR WORKFLOWS_RELEASE_META_DIR WORKFLOWS_OTA_DIR WORKFLOWS_ASSETS_DIR
mkdir -p "$WORKFLOWS_OUT"

# Publish the directories to $GITHUB_ENV so a later step's `with:` block can
# interpolate ${{ env.WORKFLOWS_RELEASE_META_DIR }} without re-running a script.
# gh_env_once's guard is file-based, so this dedupes across the separate
# processes that each step in one job is.
gh_env_once WORKFLOWS_OUT "$WORKFLOWS_OUT"
gh_env_once WORKFLOWS_OUTPUT_DIR "$WORKFLOWS_OUTPUT_DIR"
gh_env_once WORKFLOWS_RELEASE_META_DIR "$WORKFLOWS_RELEASE_META_DIR"
gh_env_once WORKFLOWS_OTA_DIR "$WORKFLOWS_OTA_DIR"
gh_env_once WORKFLOWS_ASSETS_DIR "$WORKFLOWS_ASSETS_DIR"

# This directory, absolute: a script that cd's into the consumer before asking
# for a fingerprint must still find native-stack.sh beside this file.
WORKFLOWS_RELEASE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# workflows_release_platform [ARG] -> ios|android
workflows_release_platform() {
  local p="${1:-${WORKFLOWS_PLATFORM:-}}"
  case "$p" in
    ios | android) printf '%s\n' "$p" ;;
    *) die "platform must be ios or android (got '${p}')" ;;
  esac
}

# workflows_fingerprint PLATFORM -> the native fingerprint for that platform:
# the hash of everything a store build of it depends on natively, so an OTA
# update or a release can tell whether two commits need different binaries.
#
# WORKFLOWS_FINGERPRINT_IOS / WORKFLOWS_FINGERPRINT_ANDROID short-circuit the computation. That is not only a
# test seam: a job that already computed the fingerprint in an earlier step
# (build-prepare does) passes it down instead of paying for a second, slower and
# possibly *different* run - fingerprint input includes node_modules, so the
# same commit can hash differently after an unrelated install.
#
# Otherwise the consumer's native stack computes it: native-stack.sh runs
# scripts/native/<stack>/fingerprint.sh, which prints one hash on stdout -
# @expo/fingerprint's for the Expo stack, a sha256 over the tracked native
# files for the bare stack. build-info.json keeps the same field names either way.
workflows_fingerprint() {
  local platform override out
  # Every caller reads this through `$(...)`, where `set -e` does not reach, so
  # each step that can fail says `|| return` itself; without it an unknown
  # platform, or a working directory that does not exist, ran the CLI anyway.
  platform="$(workflows_release_platform "${1:-}")" || return
  case "$platform" in
    ios) override="${WORKFLOWS_FINGERPRINT_IOS:-}" ;;
    android) override="${WORKFLOWS_FINGERPRINT_ANDROID:-}" ;;
  esac
  if [ -n "$override" ]; then printf '%s\n' "$override"; return 0; fi

  # Each stack's script fails rather than print an empty hash.
  out="$(bash "$WORKFLOWS_RELEASE_LIB_DIR/native-stack.sh" fingerprint "$platform")" ||
    die "could not compute the $platform fingerprint (the error above says why)"
  printf '%s\n' "$out"
}

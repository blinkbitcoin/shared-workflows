#!/usr/bin/env bash
# Shared env contract for scripts/release and scripts/ota. Source it after
# common.sh; do not execute.
# shellcheck shell=bash

# Where every release artifact this family produces is staged. Mirrors
# scripts/lib/e2e-env.sh's WORKFLOWS_OUT so a job that does both keeps one directory.
WORKFLOWS_OUT="${WORKFLOWS_OUT:-${RUNNER_TEMP:-/tmp}/workflows}"
# Fastlane reads this to decide where to drop the .ipa/.aab it builds.
WORKFLOWS_OUTPUT_DIR="${WORKFLOWS_OUTPUT_DIR:-$WORKFLOWS_OUT}"
WORKFLOWS_RELEASE_META_DIR="${WORKFLOWS_RELEASE_META_DIR:-$WORKFLOWS_OUT/release-meta}"
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

# workflows_release_platform [ARG] -> ios|android
workflows_release_platform() {
  local p="${1:-${WORKFLOWS_PLATFORM:-}}"
  case "$p" in
    ios | android) printf '%s\n' "$p" ;;
    *) die "platform must be ios or android (got '${p}')" ;;
  esac
}

# workflows_fingerprint PLATFORM -> the @expo/fingerprint hash for that platform.
#
# WORKFLOWS_FINGERPRINT_IOS / WORKFLOWS_FINGERPRINT_ANDROID short-circuit the computation. That is not only a
# test seam: a job that already computed the fingerprint in an earlier step
# (build-prepare does) passes it down instead of paying for a second, slower and
# possibly *different* run - fingerprint input includes node_modules, so the
# same commit can hash differently after an unrelated install.
#
# The CLI is @expo/fingerprint's `fingerprint` bin (verified against the
# installed version): `fingerprint fingerprint:generate --platform ios`, run in
# the consumer root so the consumer's fingerprint.config.js is picked up
# automatically. It prints a JSON object carrying `.hash`; a bare-hash output
# from an older version is still accepted.
#
# `npx --no`, not `npx --yes`: the bin must come from the consumer's own
# devDependency. `--yes` would happily install some unrelated npm package
# called "fingerprint" and hash the app with it.
workflows_fingerprint() {
  local platform override out root
  # Every caller reads this through `$(...)`, where `set -e` does not reach, so
  # each step that can fail says `|| return` itself; without it an unknown
  # platform, or a working directory that does not exist, ran the CLI anyway.
  platform="$(workflows_release_platform "${1:-}")" || return
  case "$platform" in
    ios) override="${WORKFLOWS_FINGERPRINT_IOS:-}" ;;
    android) override="${WORKFLOWS_FINGERPRINT_ANDROID:-}" ;;
  esac
  if [ -n "$override" ]; then printf '%s\n' "$override"; return 0; fi

  require_cmd npx
  root="$(consumer_root)" || die "the consumer's working directory does not exist: ${GITHUB_WORKSPACE:-$PWD}/${WORKING_DIRECTORY:-.}"
  out="$(cd "$root" && npx --no fingerprint fingerprint:generate --platform "$platform")" ||
    die "fingerprint:generate failed for $platform (is @expo/fingerprint a devDependency of the consumer?)"
  case "$out" in
    *'{'*)
      require_cmd yq
      out="$(printf '%s' "$out" | yq -r '.hash // ""')"
      ;;
    *)
      out="$(printf '%s\n' "$out" | tr -d '[:space:]')"
      ;;
  esac
  [ -n "$out" ] || die "could not read a fingerprint hash for $platform out of fingerprint:generate's output"
  printf '%s\n' "$out"
}

#!/usr/bin/env bash
# The Expo stack's app identifiers, out of the resolved Expo config
# (scripts/lib/expo-config.sh, which caches `expo config --json --type public`
# per commit). scripts/lib/native-stack.sh dispatches here; callers ask through
# workflows_app_config in scripts/lib/e2e-env.sh.
#
# Keys, and where each comes from - an explicit workflow input wins, as on the
# bare stack (IOS_BUNDLE_ID, ANDROID_PACKAGE and IOS_SCHEME, which test-e2e.yml
# exports for its `ios-bundle-id`, `android-package` and `ios-scheme` inputs),
# and then `expo config` is not asked at all:
#   ios-bundle-id    IOS_BUNDLE_ID, else ios.bundleIdentifier
#   android-package  ANDROID_PACKAGE, else android.package
#   scheme           the URL scheme, `scheme`
#   ios-scheme       IOS_SCHEME, else the Xcode scheme: the name of the
#                    ios/*.xcworkspace that prebuild wrote, cross-checked against
#                    the config's `name` stripped of non-alphanumerics (what
#                    prebuild generates)
# Usage: app-config.sh KEY
set -euo pipefail
source "$(dirname "$0")/../../lib/common.sh"

lib="$(cd "$(dirname "$0")/../../lib" && pwd)"
expo_config() { bash "$lib/expo-config.sh" "$1"; }
# input VALUE - print VALUE and end the script when it is set.
input() { if [ -n "$1" ]; then printf '%s\n' "$1"; exit 0; fi; }

key="${1:-}"
case "$key" in
  ios-bundle-id) input "${IOS_BUNDLE_ID:-}"; expo_config ios.bundleIdentifier ;;
  android-package) input "${ANDROID_PACKAGE:-}"; expo_config android.package ;;
  scheme) expo_config scheme ;;
  ios-scheme)
    input "${IOS_SCHEME:-}"
    root="$(consumer_root)" ||
      die "the consumer's working directory does not exist: ${GITHUB_WORKSPACE:-$PWD}/${WORKING_DIRECTORY:-.}"
    # `|| ws=""`: find fails on a missing ios/, and pipefail would end the
    # script there without a word.
    ws="$(find "$root/ios" -maxdepth 1 -name '*.xcworkspace' 2>/dev/null | head -1)" || ws=""
    [ -n "$ws" ] || die "no ios/*.xcworkspace in $root - run prebuild.sh ios and pods.sh first"
    ws_name="$(basename "$ws" .xcworkspace)"
    # The workspace name is what we return, always. The Expo config is only a
    # cross-check, and asking for it runs `pnpm exec expo config` - which on a
    # cache hit means installing the whole dependency tree (~80s) to produce a
    # warning that changes nothing. Best-effort: when the config is not already
    # available, skip the comparison rather than make every caller pay for it.
    if cfg_name="$(expo_config ios.scheme-name 2>/dev/null)" &&
      [ -n "$cfg_name" ] && [ "$ws_name" != "$cfg_name" ]; then
      warn "expo-config scheme-name ($cfg_name) disagrees with the generated workspace ($ws_name); using the workspace name"
    fi
    printf '%s\n' "$ws_name"
    ;;
  *) die "unknown app-config key '$key' (one of: ios-bundle-id, android-package, scheme, ios-scheme)" ;;
esac

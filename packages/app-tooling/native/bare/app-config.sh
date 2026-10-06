#!/usr/bin/env bash
# The bare stack's app identifiers, read out of the committed native projects:
# a bare app has no `expo config` to ask. scripts/lib/native-stack.sh
# dispatches here; callers ask through workflows_app_config in
# scripts/lib/e2e-app.sh.
#
# Keys, and where each comes from - an explicit workflow input always wins
# (IOS_BUNDLE_ID, ANDROID_PACKAGE and IOS_SCHEME are what test-e2e.yml,
# build-ios.yml, build-android.yml and publish-store.yml export for their
# `ios-bundle-id`, `android-package` and `ios-scheme` inputs):
#   ios-bundle-id    IOS_BUNDLE_ID, else PRODUCT_BUNDLE_IDENTIFIER from
#                    `xcodebuild -showBuildSettings -json` on the workspace and
#                    scheme (the application target's), else the first literal
#                    PRODUCT_BUNDLE_IDENTIFIER in ios/*.xcodeproj/project.pbxproj
#   android-package  ANDROID_PACKAGE, else `applicationId` in
#                    android/app/build.gradle or build.gradle.kts, plus the debug
#                    build type's applicationIdSuffix when one is set, unless
#                    WORKFLOWS_ANDROID_VARIANT is release (it defaults to debug:
#                    every caller today is test-e2e.yml's, whose app is
#                    assembleDebug; the release workflows pass the input)
#   scheme           the URL scheme: the first CFBundleURLSchemes entry in the
#                    app's Info.plist, else the first non-web android:scheme in
#                    android/app/src/main/AndroidManifest.xml; empty when the app
#                    declares none (a bare app without deep links has none)
#   ios-scheme       IOS_SCHEME, else the name of the single ios/*.xcworkspace
# Usage: app-config.sh KEY
set -euo pipefail
source "$(dirname "$0")/../../lib/common.sh"

key="${1:-}"
root="$(consumer_root)" ||
  die "the consumer's working directory does not exist: ${GITHUB_WORKSPACE:-$PWD}/${WORKING_DIRECTORY:-.}"
cd "$root"

# The single ios/*.xcworkspace's name. Zero or several is a question only the
# consumer can answer.
workspace_name() {
  local found count
  # `|| found=""` and the like below: find fails on a missing ios/, and
  # pipefail would end the script there without a word.
  found="$(find ios -maxdepth 1 -name '*.xcworkspace' 2>/dev/null | env LC_ALL=C sort)" || found=""
  count="$(printf '%s' "$found" | grep -c . || true)"
  [ "$count" -ne 0 ] || die_fix "no ios/*.xcworkspace in $root" \
    "commit the workspace (run pod install in ios/ once), or pass the ios-scheme input" "expo-or-bare"
  [ "$count" -eq 1 ] || die_fix "$count workspaces in $root/ios ($(printf '%s' "$found" | tr '\n' ' ')), so the Xcode scheme is ambiguous" \
    "keep one ios/*.xcworkspace, or pass the ios-scheme input" "expo-or-bare"
  basename "$found" .xcworkspace
}

ios_scheme() {
  if [ -n "${IOS_SCHEME:-}" ]; then printf '%s\n' "$IOS_SCHEME"; return 0; fi
  workspace_name
}

# PRODUCT_BUNDLE_IDENTIFIER of the application target, from xcodebuild's JSON.
# Prints nothing when xcodebuild or node is missing (a Linux runner), there is
# no single workspace, or the workspace does not resolve (no Pods yet); the
# pbxproj is read instead.
bundle_id_from_xcodebuild() {
  local scheme json
  command -v xcodebuild >/dev/null 2>&1 || return 0
  command -v node >/dev/null 2>&1 || return 0
  scheme="$(ios_scheme 2>/dev/null)" || return 0
  json="$(xcodebuild -showBuildSettings -json -workspace "ios/$scheme.xcworkspace" -scheme "$scheme" \
    -configuration "${WORKFLOWS_IOS_CONFIGURATION:-Debug}" 2>/dev/null)" || return 0
  printf '%s' "$json" | node -e '
    let s = "";
    process.stdin.on("data", (c) => (s += c)).on("end", () => {
      let targets = [];
      try { targets = JSON.parse(s); } catch { return; }
      if (!Array.isArray(targets)) return;
      const settings = targets.map((t) => (t && t.buildSettings) || {});
      const app = settings.find((b) => b.WRAPPER_EXTENSION === "app" && b.PRODUCT_BUNDLE_IDENTIFIER)
        ?? settings.find((b) => b.PRODUCT_BUNDLE_IDENTIFIER);
      if (app) process.stdout.write(String(app.PRODUCT_BUNDLE_IDENTIFIER));
    });'
}

# The literal PRODUCT_BUNDLE_IDENTIFIER values in the project, test targets
# and build-setting references ($(...)) left out, first one first.
bundle_ids_from_pbxproj() {
  local project
  project="$(find ios -maxdepth 2 -path 'ios/Pods' -prune -o -name project.pbxproj -path '*.xcodeproj/*' -print 2>/dev/null | env LC_ALL=C sort | head -1)" || project=""
  [ -n "$project" ] || return 0
  sed -n -E 's/^[[:space:]]*PRODUCT_BUNDLE_IDENTIFIER = "?([^";]*)"?;.*/\1/p' "$project" |
    grep -v -e '[$][(]' -e '[Tt]ests$' | awk '!seen[$0]++' || true
}

ios_bundle_id() {
  local id ids count listed
  if [ -n "${IOS_BUNDLE_ID:-}" ]; then printf '%s\n' "$IOS_BUNDLE_ID"; return 0; fi
  id="$(bundle_id_from_xcodebuild)"
  if [ -n "$id" ]; then printf '%s\n' "$id"; return 0; fi
  ids="$(bundle_ids_from_pbxproj)"
  [ -n "$ids" ] || die_fix "no bundle identifier in $root/ios: xcodebuild did not answer and no project.pbxproj names a literal PRODUCT_BUNDLE_IDENTIFIER" \
    "set PRODUCT_BUNDLE_IDENTIFIER on the app target, or pass the ios-bundle-id input" "expo-or-bare"
  count="$(printf '%s\n' "$ids" | grep -c .)"
  if [ "$count" -ne 1 ]; then
    listed="$(printf '%s\n' "$ids" | paste -sd' ' -)"
    warn "$count bundle identifiers in the project ($listed); using the first. Pass the ios-bundle-id input to choose"
  fi
  printf '%s\n' "$ids" | head -1
}

# The debug build type's applicationIdSuffix in one Gradle file, or nothing.
# The block is `debug {` (Groovy, and Kotlin's accessor), `getByName("debug") {`
# or `named("debug") {`; the suffix is `applicationIdSuffix ".x"` or
# `applicationIdSuffix = ".x"`. A block named debug elsewhere (signingConfigs)
# never sets a suffix, so it is read without harm. Line comments are dropped
# first, so a commented-out suffix does not count.
debug_suffix() {
  awk -v q="'" '
    BEGIN {
      quote = "[\"" q "]"
      opens = "(^|[^[:alnum:]_.])(debug|(getByName|named)\\(" quote "debug" quote "\\))[[:space:]]*\\{"
      suffix = "applicationIdSuffix[[:space:]]*=?[[:space:]]*" quote "[^\"" q "]*" quote
    }
    {
      line = $0
      sub(/\/\/.*/, "", line)
      rest = line
      if (!inside && match(line, opens)) {
        inside = 1
        rest = substr(line, RSTART + RLENGTH)
        # The depth the block opens at: the braces before it on this line count.
        before = substr(line, 1, RSTART)
        start = depth + gsub(/\{/, "{", before) - gsub(/\}/, "}", before)
      }
      if (inside && match(rest, suffix)) {
        value = substr(rest, RSTART, RLENGTH)
        sub("^[^\"" q "]*" quote, "", value)
        sub(quote "$", "", value)
        print value
        exit
      }
      depth += gsub(/\{/, "{", line) - gsub(/\}/, "}", line)
      if (inside && depth <= start) inside = 0
    }
  ' "$1"
}

# The application id of the build under test. The e2e build is assembleDebug,
# so by default the debug build type's applicationIdSuffix is appended: that is
# the id the emulator installs. WORKFLOWS_ANDROID_VARIANT=release answers the
# bare applicationId, for a caller asking about the release build.
android_package() {
  local gradle id variant="${WORKFLOWS_ANDROID_VARIANT:-debug}"
  case "$variant" in
    debug | release) ;;
    *) die "WORKFLOWS_ANDROID_VARIANT must be debug or release (got '$variant')" ;;
  esac
  if [ -n "${ANDROID_PACKAGE:-}" ]; then printf '%s\n' "$ANDROID_PACKAGE"; return 0; fi
  for gradle in android/app/build.gradle android/app/build.gradle.kts; do
    [ -f "$gradle" ] || continue
    # applicationId "x", applicationId 'x' and applicationId = "x" (Kotlin).
    id="$(sed -n -E "s/^[[:space:]]*applicationId[[:space:]]*(=[[:space:]]*)?[\"']([^\"']+)[\"'].*/\\2/p" "$gradle" | head -1)"
    [ -n "$id" ] || continue
    [ "$variant" = release ] || id="$id$(debug_suffix "$gradle")"
    printf '%s\n' "$id"
    return 0
  done
  die_fix "no literal applicationId in $root/android/app/build.gradle or build.gradle.kts" \
    "write applicationId as a string literal in defaultConfig, or pass the android-package input" "expo-or-bare"
}

# The first CFBundleURLSchemes string in the app's Info.plist: the one beside
# the workspace's scheme when there is one, else the first non-test target's.
ios_url_scheme() {
  local plist="" candidate name
  name="$(find ios -maxdepth 1 -name '*.xcworkspace' 2>/dev/null | env LC_ALL=C sort | head -1)" || name=""
  name="$(basename "${name:-none}" .xcworkspace)"
  if [ -f "ios/$name/Info.plist" ]; then
    plist="ios/$name/Info.plist"
  else
    for candidate in ios/*/Info.plist; do
      case "$candidate" in *Tests/* | ios/Pods/*) continue ;; esac
      if [ -f "$candidate" ]; then plist="$candidate"; break; fi
    done
  fi
  [ -n "$plist" ] || return 0
  awk '
    /<key>CFBundleURLSchemes<\/key>/ { inside = 1; next }
    inside && /<\/array>/ { inside = 0; next }
    inside && /<string>/ {
      value = $0
      sub(/.*<string>/, "", value); sub(/<\/string>.*/, "", value)
      if (value != "" && value !~ /\$\(/) { print value; exit }
    }
  ' "$plist"
}

android_url_scheme() {
  local manifest="android/app/src/main/AndroidManifest.xml"
  [ -f "$manifest" ] || return 0
  grep -o 'android:scheme="[^"]*"' "$manifest" | sed 's/^android:scheme="//; s/"$//' |
    grep -v -x -e http -e https | head -1 || true
}

url_scheme() {
  local scheme
  scheme="$(ios_url_scheme)"
  [ -n "$scheme" ] || scheme="$(android_url_scheme)"
  printf '%s\n' "$scheme"
}

case "$key" in
  ios-bundle-id) ios_bundle_id ;;
  android-package) android_package ;;
  scheme) url_scheme ;;
  ios-scheme) ios_scheme ;;
  *) die "unknown app-config key '$key' (one of: ios-bundle-id, android-package, scheme, ios-scheme)" ;;
esac

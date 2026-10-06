#!/usr/bin/env bash
# Simulator build of the consumer app, Debug unless WORKFLOWS_IOS_CONFIGURATION
# says Release (see e2e-app.sh for why a caller would). Generic destination on
# purpose: the build needs no concrete device (the app is installed on the
# booted one later), and xcodebuild's device enumeration intermittently returns
# only placeholders on fresh runners. Code signing is off - a simulator build
# never needs it and a runner has no keychain.
# Needs: prebuild.sh ios + pods.sh.
# Output: $WORKFLOWS_IOS_PRODUCTS_DIR/<scheme>.app
# Usage: ios-build.sh
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"
source "$(dirname "$0")/../lib/e2e-env.sh"

require_cmd xcodebuild
root="$(consumer_root)"
cd "$root"

# WORKFLOWS_XCODE selects a runner's Xcode before anything reads xcodebuild's version.
if [ -n "${WORKFLOWS_XCODE:-}" ]; then
  log "selecting Xcode $WORKFLOWS_XCODE"
  sudo xcode-select -s "/Applications/Xcode_$WORKFLOWS_XCODE.app"
fi

scheme="$(workflows_ios_scheme)"
log "Xcode scheme: $scheme"

# xcbeautify keeps the log readable; without it the raw xcodebuild output is
# still complete, so a missing formatter is never fatal.
formatter=(cat)
if command -v xcbeautify >/dev/null 2>&1; then
  formatter=(xcbeautify)
elif command -v xcpretty >/dev/null 2>&1; then
  formatter=(xcpretty)
fi

group "xcodebuild ($scheme, $WORKFLOWS_IOS_CONFIGURATION, iphonesimulator)"
set +e
xcodebuild \
  -workspace "ios/$scheme.xcworkspace" \
  -scheme "$scheme" \
  -configuration "$WORKFLOWS_IOS_CONFIGURATION" \
  -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath ios/build \
  CODE_SIGNING_ALLOWED=NO \
  build | "${formatter[@]}"
status=${PIPESTATUS[0]}
set -e
endgroup
[ "$status" -eq 0 ] || die "xcodebuild failed with status $status"

app="$WORKFLOWS_IOS_PRODUCTS_DIR/$scheme.app"
[ -d "$app" ] || die "build succeeded but $app is missing"
log "built $app"
gh_output app_path "$root/$app"

#!/usr/bin/env bash
# Compute the @expo/fingerprint hash for both platforms and publish them as
# step outputs `fingerprint-ios` / `fingerprint-android` plus $GITHUB_ENV FINGERPRINT_IOS / FINGERPRINT_ANDROID
# (build-info.sh reads the latter).
#
# Usage: fingerprint.sh
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"
source "$(dirname "$0")/../lib/release-env.sh"

group "fingerprint"
fp_ios="$(workflows_fingerprint ios)"
fp_android="$(workflows_fingerprint android)"
log "ios=$fp_ios android=$fp_android"
endgroup

gh_output fingerprint-ios "$fp_ios"
gh_output fingerprint-android "$fp_android"
gh_env FINGERPRINT_IOS "$fp_ios"
gh_env FINGERPRINT_ANDROID "$fp_android"

#!/usr/bin/env bash
# Download the pinned bundletool jar and publish BUNDLETOOL_JAR.
#
# The consumer's `android build` lane derives the universal APK from the .aab
# with bundletool, and no GitHub-hosted runner image ships it - so without this
# step the lane fails at the point where the .aab is already built, which is the
# most expensive place in the release to fail.
#
# Google publishes no checksum file alongside the jar, so verification is
# opt-in: set BUNDLETOOL_SHA256 to the expected digest and it is enforced.
#
# Env: BUNDLETOOL_VERSION (required; pinned in scripts/lib/versions.sh and in
#      build-android.yml's `bundletool-version` input, kept equal by
#      scripts/self/check-versions.sh), BUNDLETOOL_SHA256 (optional).
# Usage: bundletool-install.sh
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"
require_cmd curl

version="${BUNDLETOOL_VERSION:?bundletool-install.sh needs BUNDLETOOL_VERSION}"
dest="${RUNNER_TEMP:-/tmp}/bundletool.jar"
url="https://github.com/google/bundletool/releases/download/${version}/bundletool-all-${version}.jar"

# bundletool is a jar; without a JRE the lane fails later with a far less
# obvious error than this one.
command -v java >/dev/null 2>&1 ||
  die "java is not on PATH - bundletool needs a JRE; use a runner image that ships one or add actions/setup-java"

group "install bundletool $version"
curl -fsSL --retry 3 --retry-delay 2 -o "$dest" "$url" ||
  die "could not download bundletool $version from $url"
[ -s "$dest" ] || die "bundletool download produced an empty file"

if [ -n "${BUNDLETOOL_SHA256:-}" ]; then
  if command -v shasum >/dev/null 2>&1; then
    actual="$(shasum -a 256 "$dest" | cut -d' ' -f1)"
  else
    actual="$(sha256sum "$dest" | cut -d' ' -f1)"
  fi
  [ "$actual" = "$BUNDLETOOL_SHA256" ] ||
    die "bundletool sha256 mismatch: expected $BUNDLETOOL_SHA256, got $actual"
  log "sha256 verified"
else
  log "BUNDLETOOL_SHA256 not set - skipping checksum verification (google publishes no checksum file; set it to pin the bytes)"
fi

java -jar "$dest" version >&2 || die "the downloaded bundletool jar does not run"
endgroup

gh_env BUNDLETOOL_JAR "$dest"

#!/usr/bin/env bash
# Pack @blinkbitcoin/app-tooling into one tarball and name it, so the release
# attests and publishes the same file.
#
# `npm publish --provenance` signs only for registry.npmjs.org, and the package
# goes to GitHub Packages. self-release.yml's publish-app-tooling job therefore
# packs here, attests the tarball with actions/attest-build-provenance, and
# publishes that tarball: what a consumer installs is byte for byte what was
# attested, which `gh attestation verify` checks.
#
# Usage: pack-app-tooling.sh PACKAGE_DIR DESTINATION_DIR
# Output: tarball=<absolute path> to $GITHUB_OUTPUT (stdout when unset).
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"

[ "$#" -eq 2 ] || die "usage: pack-app-tooling.sh PACKAGE_DIR DESTINATION_DIR"
package_dir="$1"
destination="$2"
[ -f "$package_dir/package.json" ] || die "no package.json in '$package_dir'; nothing to pack"
mkdir -p "$destination"
destination="$(cd "$destination" && pwd -P)"

# --json puts the report on stdout and npm's notices on stderr, so a lifecycle
# script's output cannot be mistaken for the file name.
report="$(cd "$package_dir" && npm pack --json --pack-destination "$destination")" ||
  die "npm pack failed in '$package_dir'"
count="$(printf '%s' "$report" | jq -r 'if type == "array" then length else error("not an array") end')" ||
  die "npm pack did not report a JSON array: $report"
[ "$count" = "1" ] || die "npm pack reported $count packages, not one: $report"
filename="$(printf '%s' "$report" | jq -r '.[0].filename // empty')"
[ -n "$filename" ] || die "npm pack reported no file name: $report"

tarball="$destination/$filename"
[ -f "$tarball" ] || die "npm pack reported '$filename', which is not in '$destination'"
log "packed $tarball"
gh_output tarball "$tarball"

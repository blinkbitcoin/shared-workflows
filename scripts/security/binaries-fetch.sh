#!/usr/bin/env bash
# Download a release's built binaries for the binaries job to check.
#
# Usage: binaries-fetch.sh TAG DIR
#   GH_TOKEN, GH_REPO   the token and the consumer repository to read from
#
# The assets on the release tag are what the stores receive, so they - not a
# rebuild - are what the MASTG checks read. The directory is handed to the
# consumer's runner as SECURITY_BINARIES_DIR.
#
#   no tag                     a caller that turned binaries on without saying
#                              which release: fails, naming the fix
#   no such release            fails: the gate cannot check what does not exist
#   a release with no binaries a notice, and the consumer's runner then reports
#                              the job as skipped rather than clean
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"
require_cmd gh

tag="${1:-}"
dir="${2:?usage: binaries-fetch.sh TAG DIR}"
[ -n "$tag" ] || die_fix \
  "the binaries job is on, but no release-tag was given" \
  "pass release-tag: <the release to check> to check-security.yml, or binaries: false for a tier with no release" \
  "check-securityyml"

gh release view "$tag" --json tagName >/dev/null 2>&1 \
  || die "release $tag was not found in ${GH_REPO:-this repository}: there is nothing to check"

mkdir -p "$dir"
# gh exits non-zero both when no asset matches and when the download itself
# breaks. Only the first is the "no binaries" case; anything else is a failure
# of this step, not a release that happens to be empty.
if ! err="$(gh release download "$tag" --dir "$dir" --clobber \
  --pattern '*.apk' --pattern '*.aab' --pattern '*.ipa' 2>&1 >/dev/null)"; then
  # gh says "no assets to download" for a release with no assets at all and
  # "no assets match the file pattern" when it has only other files.
  grep -qiE 'no assets (to download|match)' <<<"$err" || die "downloading the binaries of $tag failed: $err"
fi

found="$(find "$dir" -maxdepth 1 -type f \( -name '*.apk' -o -name '*.aab' -o -name '*.ipa' \) | wc -l | tr -d ' ')"
if [ "$found" -eq 0 ]; then
  printf '::notice::release %s carries no .apk, .aab or .ipa - the binaries job will report skipped, not clean\n' "$tag"
else
  log "binaries: $found file(s) from $tag in $dir"
fi
gh_env SECURITY_BINARIES_DIR "$(cd "$dir" && pwd -P)"

#!/usr/bin/env bash
# Run .github/workflows/self-act-smoke.yml on this machine with nektos/act:
# the Linux half of a consumer's internal release (Prepare, and with --android
# the Android build) against the workflows in this checkout. See the comment
# at the top of that workflow for what act can and cannot show.
#
# Usage: act-smoke.sh [--android]
# Env:   WORKFLOWS_SMOKE_REPOSITORY / WORKFLOWS_SMOKE_REF - the consumer
#        (default: the template at main)
#        WORKFLOWS_ACT_IMAGE - runner image for ubuntu-latest
#        WORKFLOWS_ACT_CACHE - where the substitute artifact actions are kept
#        WORKFLOWS_ACT_ARGS  - extra arguments appended to act (e.g. -v)
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"
require_cmd git act docker gh

android=false
for arg in "$@"; do
  case "$arg" in
    --android) android=true ;;
    *) die "unknown argument: $arg (usage: act-smoke.sh [--android])" ;;
  esac
done

workflow=.github/workflows/self-act-smoke.yml
[ -f "$workflow" ] || die "run from the repository root: $workflow not found in $PWD"

docker info >/dev/null 2>&1 || die "docker is not running - act needs a Docker daemon"

# build-prepare checks out this repository into .workflows *from GitHub*, at the
# ref act derives from the local HEAD, and actions/checkout then verifies that
# the ref still points at the local sha. A branch that is not pushed, or has
# moved since, fails inside the job with a confusing "does not point to the
# expected commit"; a detached HEAD resolves to whatever tag sits on it. Say
# so here instead.
branch="$(git rev-parse --abbrev-ref HEAD)"
[ "$branch" != "HEAD" ] || die "detached HEAD - check out a branch and push it first"
local_sha="$(git rev-parse HEAD)"
remote_sha="$(git ls-remote origin "refs/heads/$branch" | cut -f1)"
[ -n "$remote_sha" ] || die "branch '$branch' is not on origin - push it first (act clones this repository from GitHub at the local HEAD)"
[ "$remote_sha" = "$local_sha" ] || die "branch '$branch' on origin is at ${remote_sha:0:7}, HEAD is ${local_sha:0:7} - push first"

# arm64 hosts run the arm64 image natively; anything else takes act's default.
arch_args=()
case "$(uname -m)" in
  arm64 | aarch64) arch_args=(--container-architecture linux/arm64) ;;
esac

image="${WORKFLOWS_ACT_IMAGE:-catthehacker/ubuntu:act-latest}"
artifacts="$(mktemp -d "${TMPDIR:-/tmp}/act-smoke-artifacts.XXXXXX")"
trap 'rm -rf "$artifacts"' EXIT

# act's artifact server speaks the v4 artifact protocol and rejects the
# `mime_type` field upload-artifact@v7 sends (nektos/act #6022, #6114; no
# release carries a fix). The workflows keep v7/v8 - that is what runs on
# GitHub - and act is told to run the last v4 of each in their place, from a
# pinned checkout made on first use.
cache="${WORKFLOWS_ACT_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/act-smoke}"
substitute() {
  local action="$1" tag="$2" dir
  dir="$cache/$action-$tag"
  if [ ! -d "$dir" ]; then
    log "act smoke: fetching actions/$action@$tag into $dir (once)"
    # `|| die`, not `set -e`: this runs inside `$(...)`, which `set -e` does
    # not reach, and a half-cloned directory would make every later run skip
    # the fetch.
    git -c advice.detachedHead=false clone -q --depth 1 --branch "$tag" \
      "https://github.com/actions/$action" "$dir" ||
      { rm -rf "$dir"; die "could not fetch actions/$action@$tag into $dir"; }
  fi
  printf '%s\n' "$dir"
}
upload_v4="$(substitute upload-artifact v4.6.2)"
download_v4="$(substitute download-artifact v4.3.0)"

# The token is only read by the two checkouts (both public repositories) and,
# with `reserve-tag: false`, never writes anything.
token="$(gh auth token)"

log "act smoke: branch $branch at ${local_sha:0:7}, android=$android"
# shellcheck disable=SC2086 # WORKFLOWS_ACT_ARGS is a deliberate word-split
act workflow_dispatch \
  -W "$workflow" \
  -P "ubuntu-latest=$image" \
  "${arch_args[@]}" \
  --artifact-server-path "$artifacts" \
  --local-repository "actions/upload-artifact@v7=$upload_v4" \
  --local-repository "actions/download-artifact@v8=$download_v4" \
  -s GITHUB_TOKEN="$token" \
  --input "repository=${WORKFLOWS_SMOKE_REPOSITORY:-blinkbitcoin/react-native-mobile-template}" \
  --input "ref=${WORKFLOWS_SMOKE_REF:-main}" \
  --input "android=$android" \
  ${WORKFLOWS_ACT_ARGS:-}

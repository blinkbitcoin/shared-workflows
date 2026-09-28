#!/usr/bin/env bash
# Resolve the version and build number for a release run.
#
# This is this repo's own copy of the consumer's scripts/release/resolve-version.sh
# and MUST keep the same contract: it prints
#
#   APP_VERSION=X.Y.Z
#   APP_BUILD_NUMBER=N
#
# on stdout and writes `version` / `build-number` to $GITHUB_OUTPUT. A consumer
# that ships its own copy and this one must never disagree, or a tag build and
# an OTA build of the same commit get different version strings.
#
# It deliberately does NOT write $GITHUB_ENV. Resolving a version and publishing
# it into a job's environment are two jobs, and the consumer's copy also runs on
# a developer machine under `make version`, where $GITHUB_ENV does not exist. The
# steps that need APP_VERSION / APP_BUILD_NUMBER take them from this step's
# outputs explicitly - see the Build info and Release notes steps in
# .github/workflows/build-prepare.yml. That also keeps the two copies comparable:
# test/resolve-version.bats compares stdout and $GITHUB_OUTPUT, and a write to a
# third channel from only one copy is a drift the test cannot see.
#
# Version, first match wins:
#   1. a `vX.Y.Z` tag pointing at HEAD (the tag build itself)
#   2. a release-please release commit (`chore(<scope>): release X.Y.Z`) - HEAD's
#      own subject after a squash/rebase merge, or HEAD^2's after a merge commit
#   3. a version inside $RELEASE_PR_TITLE (the release-please PR being built)
#   4. a version inside the title of the open `autorelease: pending` PR (via gh)
#   5. the newest stable `vX.Y.Z` tag with its patch component bumped by one
#   6. 0.0.1 when the repo has no stable version tag at all (0.0.0, bumped)
#
# Source 2 exists because of a real gap: on the merge commit of a release-please
# PR none of the other sources hit. The tag does not exist yet (release-please
# creates it from that very push), there is no $RELEASE_PR_TITLE on a `push`
# event, and the PR is closed so `autorelease: pending` finds nothing - so the
# release build of `1.2.0` resolved as a patch bump of the *previous* tag,
# 1.1.1, and shipped a store build labelled with a version nothing else knows.
#
# Prerelease tags (`v1.2.3-rc.1`) are ignored *entirely*, at every step: they
# never win at HEAD and never seed the patch bump. A repository that has only
# ever cut release candidates therefore starts at 0.0.1 - which is what the
# template's copy does, and keeping the two identical is the whole point.
#
# Build number: first-parent commit count + $BUILD_NUMBER_OFFSET (default 1000).
# First-parent on purpose: a merge of a long-lived branch must not jump the
# build number by that branch's whole history, and App Store Connect / Play
# both reject a build number that ever goes backwards.
#
# Usage: resolve-version.sh [dir]   (default: the consumer root)
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"
require_cmd git

dir="${1:-}"
[ -n "$dir" ] || dir="$(consumer_root)"
[ -d "$dir" ] || die "resolve-version.sh: no such directory: $dir"
cd "$dir"

# `|| true` throughout: every one of these is an optional source, and with
# `set -o pipefail` a no-match grep would otherwise abort the script.
extract_version() { printf '%s' "${1:-}" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true; }

version=""
origin=""

tag="$(git tag --points-at HEAD 2>/dev/null | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | head -1 || true)"
if [ -n "$tag" ]; then
  version="${tag#v}"
  origin="tag at HEAD ($tag)"
fi

# release-please scopes its release commit with the release branch's name, so the
# subject on `main` is `chore(main): release 1.2.0` and on `master` it is
# `chore(master): release 1.2.0`. Hardcoding `main` meant a consumer releasing
# from any other branch matched nothing here and fell through to the patch bump,
# stamping a wrong version on a real release - the same class of silent fallback
# the HEAD^2 lookup below exists to close. $GITHUB_REF_NAME is the branch the
# workflow is running on, which is the release branch on the push that matters;
# WORKFLOWS_RELEASE_SCOPE overrides it for a consumer whose release-please config sets
# a scope that is not the branch name.
release_scope="${WORKFLOWS_RELEASE_SCOPE:-${GITHUB_REF_NAME:-main}}"
release_prefix="chore($release_scope): release "

# The release commit is matched on its exact subject shape rather than on any
# commit that happens to carry a version. The version is taken from that subject,
# not from a grep of the whole message, so a body mentioning another version
# cannot win.
#
# HEAD *and* HEAD^2, matching the template's copy: `HEAD` covers a squash or
# rebase merge, which carries the PR title as its subject; `HEAD^2` covers a
# merge commit, whose own subject is `Merge pull request #N from …` and whose
# second parent is the release commit itself. Without the second-parent lookup a
# repository whose merge button is set to "Create a merge commit" falls silently
# back to the patch bump - the original bug, harder to spot because the fix
# looks present. Both are matched anchored, so a commit that merely quotes the
# subject ("Merge pull request #12 from chore(main): release 9.9.9") is not a
# release commit.
release_subject() {
  local rev subject
  for rev in HEAD 'HEAD^2'; do
    subject="$(git log -1 --format='%s' "$rev" 2>/dev/null || true)"
    case "$subject" in
      "$release_prefix"*) printf '%s' "$subject"; return 0 ;;
    esac
  done
  printf ''
}

if [ -z "$version" ]; then
  subject="$(release_subject)"
  if [ -n "$subject" ]; then
    # Strip the prefix literally rather than matching it as a regex: a scope is a
    # branch name, so it may contain `/`, `.` or `+`, every one of which means
    # something else inside an ERE or a sed address.
    candidate="$(printf '%s' "${subject#"$release_prefix"}" | grep -oE '^[0-9]+\.[0-9]+\.[0-9]+' || true)"
    if [ -n "$candidate" ]; then
      version="$candidate"
      origin="release-please release commit ($subject)"
    fi
  fi
fi

if [ -z "$version" ] && [ -n "${RELEASE_PR_TITLE:-}" ]; then
  version="$(extract_version "$RELEASE_PR_TITLE")"
  [ -z "$version" ] || origin="RELEASE_PR_TITLE"
fi

# The GH_TOKEN gate matches the template's copy: without a token `gh pr list`
# fails anyway, and on a self-hosted runner an unauthenticated call can block on
# an interactive auth prompt instead of failing fast.
if [ -z "$version" ] && [ -n "${GH_TOKEN:-}" ] && command -v gh >/dev/null 2>&1; then
  title="$(gh pr list --state open --label 'autorelease: pending' --json title --jq '.[0].title' 2>/dev/null || true)"
  version="$(extract_version "$title")"
  [ -z "$version" ] || origin="open 'autorelease: pending' PR title"
fi

if [ -z "$version" ]; then
  last="$(git tag --list 'v*' --sort=-v:refname 2>/dev/null | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | head -1 || true)"
  if [ -n "$last" ]; then
    base="${last#v}"
    origin="patch bump of the newest stable tag ($last)"
  else
    # 0.0.0 rather than a literal default, so the "no tags yet" case goes
    # through the same bump and lands on 0.0.1.
    base="0.0.0"
    origin="patch bump of 0.0.0 (no stable v* tag in this repository)"
  fi
  IFS=. read -r major minor patch <<< "$base"
  version="$major.$minor.$((patch + 1))"
fi

# Belt and braces: every branch above assigns, so an empty version here means
# one of them silently produced nothing rather than that no source matched.
[ -n "$version" ] || die "could not resolve a version (no tag, no release PR title, no v* tag)"

count="$(git rev-list --count --first-parent HEAD)"
offset="${BUILD_NUMBER_OFFSET:-1000}"
case "$offset" in
  '' | *[!0-9]*) die "BUILD_NUMBER_OFFSET must be a non-negative integer (got '$offset')" ;;
esac
build="$((count + offset))"

log "version $version from $origin; build $build ($count first-parent commits + offset $offset)"
printf 'APP_VERSION=%s\n' "$version"
printf 'APP_BUILD_NUMBER=%s\n' "$build"
gh_output version "$version"
gh_output build-number "$build"

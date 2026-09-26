#!/usr/bin/env bash
# The changed-file list of a diff range, for the change classifiers. Source it;
# do not execute. Sourced by scripts/ci/changed-class.sh (the consumer family's
# classes) and scripts/self/changed-gates.sh (this repository's own CI), so the
# two agree on what "the diff" is and on when there is no answer.
# shellcheck shell=bash

# changed_files BASE HEAD - print the paths the range changed, one per line.
#
# Returns 1, having printed nothing, whenever the range cannot be classified.
# Every caller treats that as "run everything": an unreadable diff must never
# read as "nothing relevant changed". Under `set -euo pipefail` an abort here
# would fail the step instead, and a red Checks job is a worse answer than a
# needlessly complete matrix. Each path says why on stderr as a ::notice::, so
# a maintainer looking at a full matrix can tell "could not classify" from
# "really relevant".
changed_files() {
  local base="${1:-}" head="${2:-}" files
  if [ -z "$base" ]; then
    log "::notice::no base sha for this event - running everything"
    return 1
  fi

  # github.event.before is the all-zero sha on the first push of a new branch:
  # there is no previous commit to diff against.
  case "$base" in
    *[!0]*) ;;
    *)
      log "::notice::base $base is the all-zero sha (first push of a branch) - running everything"
      return 1
      ;;
  esac

  # Both ends of the range have to be objects in THIS checkout, or `git diff`
  # exits non-zero and takes the step with it:
  #   - base: a force-push can strand the recorded `before`, and a shallow clone
  #     may never have fetched it;
  #   - head: `$HEAD_SHA` is `github.sha`, which names a commit of the *workflow's*
  #     repository, while the `changes` job checks out `inputs.repository` at
  #     `inputs.ref` - so a consumer that overrides either hands us a sha this
  #     repository has never seen.
  # `cat-file -e` tests that the object is PRESENT, not that it is reachable from
  # a ref; a dangling commit git has not gc'd yet passes and then diffs fine.
  if ! git cat-file -e "$base^{commit}" 2>/dev/null; then
    log "::notice::base $base is not present in this checkout - running everything"
    return 1
  fi
  if ! git cat-file -e "$head^{commit}" 2>/dev/null; then
    log "::notice::head $head is not present in this checkout - running everything"
    return 1
  fi

  # Use merge-base (three-dot) semantics so commits landed on the target branch
  # after the PR branch forked don't leak into the diff and flip a docs-only PR
  # to false. Fall back to a plain two-dot diff only when merge-base can't be
  # computed (e.g. a shallow clone missing the common ancestor).
  if git merge-base "$base" "$head" >/dev/null 2>&1; then
    files=$(git diff --name-only "$base...$head")
  else
    log "warning: git merge-base failed for $base..$head; falling back to two-dot diff (may include unrelated target-branch changes)"
    files=$(git diff --name-only "$base" "$head")
  fi
  # An empty range (a re-run on the base itself, an empty merge) has nothing to
  # classify, so it runs everything too.
  [ -n "$files" ] || return 1
  printf '%s\n' "$files"
}

# reject_empty_alternative NAME VALUE - die when VALUE, a '|'-joined list of
# ERE alternatives, has an empty one.
#
# `docs/|` means "docs/ OR the empty string", and the empty string matches every
# path, so the pattern would call every change irrelevant and skip every job it
# gates. A trailing `|` is the easy way to write that by accident, in YAML
# especially. Unlike the runtime paths above, a malformed *input* is a hard
# error: it is a human mistake in a workflow file, it is fixable in one edit, and
# failing open on it would mean quietly ignoring what the operator asked for on
# every run from here on.
reject_empty_alternative() {
  case "$2" in
    '|'* | *'|' | *'||'*)
      die "$1 has an empty alternative ('$2'): an empty alternative matches every path, which would classify every change as irrelevant and skip every job it gates"
      ;;
  esac
}

# every_path_matches PATTERN FILES - print true when every line of FILES matches
# the ERE PATTERN, false when one does not. Returns 2, printing nothing, when the
# pattern does not compile.
#
# `|| true` would swallow the one case that matters. grep has three outcomes,
# and only two of them are answers:
#
#   0  some path does not match  -> false
#   1  every path matches        -> true
#   2+ the pattern did not compile -> no answer at all
#
# On 2 grep also prints nothing, so an unswallowed output is empty and
# indistinguishable from "every path matches" - which is how a malformed
# `docs-globs` once classified a pure code change as docs-only and skipped the
# entire matrix green. The status has to be read, not the output.
every_path_matches() {
  local rest status
  set +e
  rest=$(grep -Ev "$1" <<<"$2")
  status=$?
  set -e
  if [ "$status" -ge 2 ]; then
    return 2
  fi
  if [ "$status" -eq 1 ] && [ -z "$rest" ]; then
    echo true
  else
    echo false
  fi
}

# any_path_matches PATTERN FILES - print true when some line of FILES matches
# the ERE PATTERN, false when none does. Returns 2 on a pattern that does not
# compile, for the same reason as above.
any_path_matches() {
  local status
  set +e
  # A here-string, not `printf | grep -q`: -q exits on the first match, and
  # under pipefail the printf it cut off would turn a match into status 141.
  grep -Eq "$1" <<<"$2"
  status=$?
  set -e
  case "$status" in
    0) echo true ;;
    1) echo false ;;
    *) return 2 ;;
  esac
}

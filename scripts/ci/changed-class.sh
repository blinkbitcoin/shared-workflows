#!/usr/bin/env bash
# Classify a diff range as docs-only or not, so callers can skip expensive
# native builds/tests for PRs that only touch documentation.
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"
base="${1:-}"
head="${2:?usage: changed-class.sh BASE_SHA HEAD_SHA}"
# DOCS_GLOBS *replaces* the default pattern (the escape hatch for a consumer
# whose docs live nowhere near docs/); DOCS_GLOBS_EXTRA *adds* alternatives to
# whichever pattern is in force. check-code.yml's `docs-globs` input is wired to
# DOCS_GLOBS_EXTRA, because "extra alternatives" is what it promises - passing
# it as a replacement would silently stop treating docs/ and **.md as docs and
# run the full suite on every docs-only PR.
#
# `(^|/)LICENSE$`, not `^LICENSE$`: a monorepo keeps a copy of the licence next
# to every package, and the anchored form matched only the root one - so a
# five-line copyright bump ran the whole native matrix.
default_docs_globs='^docs/|\.md$|(^|/)LICENSE$|^\.github/ISSUE_TEMPLATE/|^\.github/PULL_REQUEST_TEMPLATE'
docs_globs="${DOCS_GLOBS:-$default_docs_globs}"
# An `[ ... ] && x` one-liner would exit the script under `set -e` when the
# variable is empty (the list's status is the failing test's), so: an if.
#
# An empty alternative is rejected rather than appended. `docs/|` means "docs/ OR
# the empty string", and the empty string matches every line, so `grep -Ev` would
# select nothing, $non_docs would come back empty, and the classifier would
# report docs-only=true for a pure code change - the whole matrix skipping green.
# A trailing `|` is the easy way to write that by accident, in YAML especially.
if [ -n "${DOCS_GLOBS_EXTRA:-}" ]; then
  # Unlike the runtime paths below, a malformed *input* is a hard error. It is a
  # human mistake in a workflow file, it is fixable in one edit, and failing open
  # on it would mean quietly ignoring what the operator asked for on every run
  # from here on.
  case "$DOCS_GLOBS_EXTRA" in
    '|'* | *'|' | *'||'*)
      die "DOCS_GLOBS_EXTRA has an empty alternative ('$DOCS_GLOBS_EXTRA'): an empty alternative matches every path, which would classify every change as docs-only and skip the whole matrix"
      ;;
  esac
  docs_globs="$docs_globs|$DOCS_GLOBS_EXTRA"
fi

# Every "cannot classify" path below fails OPEN: docs-only=false and exit 0, so
# the caller runs the full pipeline. Under `set -euo pipefail` an abort here
# would fail the step instead, and a red Checks job is a worse answer than a
# needlessly complete matrix. An unreadable diff must never read as "docs".
# Each path says why on stderr as a ::notice::, so a maintainer looking at a
# full matrix can tell "could not classify" from "really not docs".
if [ -z "$base" ]; then
  log "::notice::no base sha for this event - running everything"
  gh_output docs-only false
  exit 0
fi

# github.event.before is the all-zero sha on the first push of a new branch:
# there is no previous commit to diff against.
case "$base" in
  *[!0]*) ;;
  *)
    log "::notice::base $base is the all-zero sha (first push of a branch) - running everything"
    gh_output docs-only false
    exit 0
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
  gh_output docs-only false
  exit 0
fi
if ! git cat-file -e "$head^{commit}" 2>/dev/null; then
  log "::notice::head $head is not present in this checkout - running everything"
  gh_output docs-only false
  exit 0
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
if [ -z "$files" ]; then
  gh_output docs-only false
  exit 0
fi

# `|| true` would swallow the one case that matters. grep has three outcomes,
# and only two of them are answers:
#
#   0  some path is not a doc      -> not docs-only
#   1  every path is a doc         -> docs-only
#   2+ the pattern did not compile -> no answer at all
#
# On 2 grep also prints nothing, so an unswallowed `$non_docs` is empty and
# indistinguishable from "every path is a doc" - which is how a malformed
# `docs-globs` used to classify a pure code change as docs-only and skip the
# entire matrix green. The status has to be read, not the output.
set +e
non_docs=$(printf '%s\n' "$files" | grep -Ev "$docs_globs")
grep_status=$?
set -e
if [ "$grep_status" -ge 2 ]; then
  # Fail open, like every other "cannot classify" path above: a needlessly
  # complete matrix is a far better answer than a silently skipped one.
  log "::notice::could not apply the docs pattern (grep exited $grep_status; pattern: $docs_globs) - running everything"
  gh_output docs-only false
  exit 0
fi
if [ "$grep_status" -eq 1 ] && [ -z "$non_docs" ]; then
  gh_output docs-only true
else
  gh_output docs-only false
fi

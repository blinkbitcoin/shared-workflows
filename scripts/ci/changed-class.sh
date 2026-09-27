#!/usr/bin/env bash
# Classify a diff range so callers skip the jobs it cannot affect. Writes:
#
#   docs-only      true when every changed path is documentation
#   unit-changed   true when some changed path can affect the unit suite
#   e2e-changed    true when some changed path can affect the native E2E suite
#   web-changed    true when some changed path can affect the web build
#
# The three suite classes are ignore-based: a class is affected unless EVERY
# changed path matches its irrelevant pattern (the docs pattern, the class's own
# default and the caller's extra). A path nobody listed - a new directory, a new
# config file - therefore runs the job. Getting a list wrong costs a needless
# run, never a skipped regression.
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"
source "$(dirname "$0")/../lib/changed-files.sh"
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
if [ -n "${DOCS_GLOBS_EXTRA:-}" ]; then
  reject_empty_alternative DOCS_GLOBS_EXTRA "$DOCS_GLOBS_EXTRA"
  docs_globs="$docs_globs|$DOCS_GLOBS_EXTRA"
fi

# What each suite never reads, beyond the docs. Test files are irrelevant to E2E
# but not to the web build: Playwright's default testMatch takes `*.test.*` as
# well as `*.spec.*`. Nothing under .github/ is on any list - a changed caller
# workflow can change how every suite runs. `Gemfile` is irrelevant to unit and
# web only: CocoaPods runs under it in the iOS E2E build.
default_unit_ignore_globs='^\.maestro/|^e2e/|(^|/)playwright\.config\.[cm]?[jt]s$|^fastlane/|(^|/)Gemfile(\.lock)?$'
default_e2e_ignore_globs='(^|/)__tests__/|(^|/)__snapshots__/|\.test\.[cm]?[jt]sx?$|(^|/)jest\.config\.[cm]?[jt]s$|^e2e/web/|(^|/)playwright\.config\.[cm]?[jt]s$|^fastlane/'
default_web_ignore_globs='^\.maestro/|(^|/)__snapshots__/|(^|/)jest\.config\.[cm]?[jt]s$|^fastlane/|(^|/)Gemfile(\.lock)?$'

# class_globs DEFAULT EXTRA_NAME - the irrelevant pattern for one suite.
class_globs() {
  local globs="$docs_globs|$1" extra="${!2:-}"
  if [ -n "$extra" ]; then
    reject_empty_alternative "$2" "$extra"
    globs="$globs|$extra"
  fi
  printf '%s' "$globs"
}
unit_globs=$(class_globs "$default_unit_ignore_globs" UNIT_IGNORE_GLOBS_EXTRA)
e2e_globs=$(class_globs "$default_e2e_ignore_globs" E2E_IGNORE_GLOBS_EXTRA)
web_globs=$(class_globs "$default_web_ignore_globs" WEB_IGNORE_GLOBS_EXTRA)

# The answer when there is no answer: run everything.
run_everything() {
  gh_output docs-only false
  gh_output unit-changed true
  gh_output e2e-changed true
  gh_output web-changed true
  exit 0
}

# Every "cannot classify" path fails OPEN (see changed_files), and so does a
# pattern that does not compile: a needlessly complete matrix is a far better
# answer than a silently skipped one.
files=$(changed_files "$base" "$head") || run_everything

# irrelevant CLASS PATTERN - set $answer to whether every changed path matches
# PATTERN. Called directly, never inside a command substitution: from in there
# run_everything's outputs would land in a variable, not in $GITHUB_OUTPUT.
irrelevant() {
  if ! answer=$(every_path_matches "$2" "$files"); then
    log "::notice::could not apply the $1 pattern (it does not compile: $2) - running everything"
    run_everything
  fi
}
# changed IRRELEVANT - a suite class is the negation of "every path irrelevant".
changed() { if [ "$1" = true ]; then echo false; else echo true; fi; }

irrelevant docs "$docs_globs"; docs_only=$answer
irrelevant unit "$unit_globs"; unit_changed=$(changed "$answer")
irrelevant e2e "$e2e_globs"; e2e_changed=$(changed "$answer")
irrelevant web "$web_globs"; web_changed=$(changed "$answer")

gh_output docs-only "$docs_only"
gh_output unit-changed "$unit_changed"
gh_output e2e-changed "$e2e_changed"
gh_output web-changed "$web_changed"

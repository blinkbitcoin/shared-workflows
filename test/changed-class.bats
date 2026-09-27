#!/usr/bin/env bats
load test_helper

setup() {
  repo="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$repo"
  git -C "$repo" init -q -b main
  git -C "$repo" config user.email "test@example.com"
  git -C "$repo" config user.name "Test"
}

# has_line LINE - the output holds LINE exactly. The script writes one line per
# class, so a whole-output comparison would pin every other class too.
has_line() { grep -qxF "$1" <<<"$output"; }

commit_file() {
  local path="$1"
  mkdir -p "$(dirname "$repo/$path")"
  echo "content $RANDOM" >> "$repo/$path"
  git -C "$repo" add "$path"
  git -C "$repo" commit -q -m "touch $path"
}

@test "docs-only=true when only docs/ files changed" {
  commit_file "README.md"
  base=$(git -C "$repo" rev-parse HEAD)
  commit_file "docs/x.md"
  head=$(git -C "$repo" rev-parse HEAD)
  cd "$repo" && run bash "$REPO_ROOT/scripts/ci/changed-class.sh" "$base" "$head"
  [ "$status" -eq 0 ]
  has_line "docs-only=true" || fail "expected docs-only=true, got: $output"
}

@test "docs-only=false when a src file changed" {
  commit_file "README.md"
  base=$(git -C "$repo" rev-parse HEAD)
  commit_file "src/a.ts"
  head=$(git -C "$repo" rev-parse HEAD)
  cd "$repo" && run bash "$REPO_ROOT/scripts/ci/changed-class.sh" "$base" "$head"
  [ "$status" -eq 0 ]
  has_line "docs-only=false" || fail "expected docs-only=false, got: $output"
}

@test "docs-only=true when README.md and docs/ changed together" {
  commit_file "other.txt"
  base=$(git -C "$repo" rev-parse HEAD)
  commit_file "README.md"
  commit_file "docs/y.md"
  head=$(git -C "$repo" rev-parse HEAD)
  cd "$repo" && run bash "$REPO_ROOT/scripts/ci/changed-class.sh" "$base" "$head"
  [ "$status" -eq 0 ]
  has_line "docs-only=true" || fail "expected docs-only=true, got: $output"
}

@test "docs-only=false when a workflow file changed" {
  commit_file "README.md"
  base=$(git -C "$repo" rev-parse HEAD)
  commit_file ".github/workflows/ci.yml"
  head=$(git -C "$repo" rev-parse HEAD)
  cd "$repo" && run bash "$REPO_ROOT/scripts/ci/changed-class.sh" "$base" "$head"
  [ "$status" -eq 0 ]
  has_line "docs-only=false" || fail "expected docs-only=false, got: $output"
}

@test "docs-only=true when base branch advances with a src/ change after the PR forked (merge-base semantics)" {
  commit_file "README.md"
  fork_point=$(git -C "$repo" rev-parse HEAD)
  git -C "$repo" checkout -q -b pr "$fork_point"
  commit_file "docs/x.md"
  head=$(git -C "$repo" rev-parse HEAD)
  git -C "$repo" checkout -q main
  commit_file "src/unrelated.ts"
  base=$(git -C "$repo" rev-parse HEAD)
  cd "$repo" && run bash "$REPO_ROOT/scripts/ci/changed-class.sh" "$base" "$head"
  [ "$status" -eq 0 ]
  has_line "docs-only=true" || fail "expected docs-only=true, got: $output"
}

@test "DOCS_GLOBS_EXTRA is additive: the built-in docs patterns still apply" {
  commit_file "other.txt"
  base=$(git -C "$repo" rev-parse HEAD)
  commit_file "spec/a.txt"
  commit_file "docs/x.md"
  head=$(git -C "$repo" rev-parse HEAD)
  cd "$repo" && DOCS_GLOBS_EXTRA='^spec/' run bash "$REPO_ROOT/scripts/ci/changed-class.sh" "$base" "$head"
  [ "$status" -eq 0 ]
  has_line "docs-only=true" || fail "expected docs-only=true, got: $output"
}

@test "DOCS_GLOBS_EXTRA does not make a src file docs" {
  commit_file "other.txt"
  base=$(git -C "$repo" rev-parse HEAD)
  commit_file "spec/a.txt"
  commit_file "src/a.ts"
  head=$(git -C "$repo" rev-parse HEAD)
  cd "$repo" && DOCS_GLOBS_EXTRA='^spec/' run bash "$REPO_ROOT/scripts/ci/changed-class.sh" "$base" "$head"
  [ "$status" -eq 0 ]
  has_line "docs-only=false" || fail "expected docs-only=false, got: $output"
}

@test "DOCS_GLOBS still replaces the default pattern outright" {
  commit_file "other.txt"
  base=$(git -C "$repo" rev-parse HEAD)
  commit_file "docs/x.md"
  head=$(git -C "$repo" rev-parse HEAD)
  cd "$repo" && DOCS_GLOBS='^spec/' run bash "$REPO_ROOT/scripts/ci/changed-class.sh" "$base" "$head"
  [ "$status" -eq 0 ]
  has_line "docs-only=false" || fail "expected docs-only=false, got: $output"
}

# workflow_dispatch (and, once PR 9 adds one, schedule) carries no base at all.
# It fails open like the other unclassifiable paths, and says so: a maintainer
# looking at a full matrix has to be able to tell "could not classify" from
# "really not docs".
@test "docs-only=false when BASE is empty (dispatch-shaped event), with a notice" {
  commit_file "docs/x.md"
  head=$(git -C "$repo" rev-parse HEAD)
  cd "$repo" && run bash "$REPO_ROOT/scripts/ci/changed-class.sh" "" "$head"
  [ "$status" -eq 0 ]
  grep -qF "docs-only=false" <<<"$output" || fail "expected docs-only=false, got: $output"
  grep -qF "::notice::" <<<"$output" || fail "expected a ::notice:: annotation, got: $output"
}

# check-code.yml now passes github.event.before on a push, so the classifier sees
# push-shaped ranges too. A merge to main that only moved docs must skip the
# matrix exactly as the PR that preceded it did.
#
# Honest label: this case is documentation, not a guard. The script never cared
# which event produced its two shas, so it passes against the pre-fix script
# too. What actually has to hold is the BASE_SHA expression, and that is pinned
# by workflow-shape.bats ("check-code.yml classifies pushes too").
@test "docs-only=true for a push-shaped range (previous tip -> new tip) of only docs/" {
  commit_file "src/a.ts"
  before=$(git -C "$repo" rev-parse HEAD)
  commit_file "docs/guide.md"
  commit_file "docs/other.md"
  head=$(git -C "$repo" rev-parse HEAD)
  cd "$repo" && run bash "$REPO_ROOT/scripts/ci/changed-class.sh" "$before" "$head"
  [ "$status" -eq 0 ]
  has_line "docs-only=true" || fail "expected docs-only=true, got: $output"
}

# `^LICENSE$` matched only the root copy, so a copyright bump across a
# monorepo's per-package LICENSE files ran the whole native matrix.
@test "docs-only=true for a per-package LICENSE, not just the root one" {
  commit_file "other.txt"
  base=$(git -C "$repo" rev-parse HEAD)
  commit_file "LICENSE"
  commit_file "packages/core/LICENSE"
  head=$(git -C "$repo" rev-parse HEAD)
  cd "$repo" && run bash "$REPO_ROOT/scripts/ci/changed-class.sh" "$base" "$head"
  [ "$status" -eq 0 ]
  has_line "docs-only=true" || fail "expected docs-only=true, got: $output"
}

@test "docs-only=false when a LICENSE-adjacent path is not a LICENSE file" {
  commit_file "other.txt"
  base=$(git -C "$repo" rev-parse HEAD)
  commit_file "src/LICENSE.ts"
  head=$(git -C "$repo" rev-parse HEAD)
  cd "$repo" && run bash "$REPO_ROOT/scripts/ci/changed-class.sh" "$base" "$head"
  [ "$status" -eq 0 ]
  has_line "docs-only=false" || fail "expected docs-only=false, got: $output"
}

# github.event.before on the first push of a new branch. Failing open here
# means docs-only=false and exit 0 - never an aborted step under `set -e`.
@test "all-zero BASE fails open: docs-only=false, exit 0, with a notice" {
  commit_file "docs/x.md"
  head=$(git -C "$repo" rev-parse HEAD)
  zero=0000000000000000000000000000000000000000
  cd "$repo" && run bash "$REPO_ROOT/scripts/ci/changed-class.sh" "$zero" "$head"
  [ "$status" -eq 0 ]
  grep -qF "docs-only=false" <<<"$output" || fail "expected docs-only=false, got: $output"
  grep -qF "::notice::" <<<"$output" || fail "expected a ::notice:: annotation, got: $output"
}

# A force-push or a shallow clone can leave the recorded base absent from the
# checkout; `git diff` would exit non-zero and take the step with it.
@test "absent BASE fails open: docs-only=false, exit 0, with a notice" {
  commit_file "docs/x.md"
  head=$(git -C "$repo" rev-parse HEAD)
  missing=deadbeefdeadbeefdeadbeefdeadbeefdeadbeef
  cd "$repo" && run bash "$REPO_ROOT/scripts/ci/changed-class.sh" "$missing" "$head"
  [ "$status" -eq 0 ]
  grep -qF "docs-only=false" <<<"$output" || fail "expected docs-only=false, got: $output"
  grep -qF "::notice::base $missing" <<<"$output" || fail "expected a notice naming the base, got: $output"
}

# The head half of the range is just as able to be absent: HEAD_SHA is
# github.sha, a commit of the *workflow's* repository, while the changes job
# checks out inputs.repository at inputs.ref. A consumer that overrides either
# hands the script a sha this checkout has never seen - and the step must stay
# green, since "never fails the build" is this job's whole contract.
@test "absent HEAD fails open: docs-only=false, exit 0, with a notice" {
  commit_file "docs/x.md"
  base=$(git -C "$repo" rev-parse HEAD)
  missing=deadbeefdeadbeefdeadbeefdeadbeefdeadbeef
  cd "$repo" && run bash "$REPO_ROOT/scripts/ci/changed-class.sh" "$base" "$missing"
  [ "$status" -eq 0 ]
  grep -qF "docs-only=false" <<<"$output" || fail "expected docs-only=false, got: $output"
  grep -qF "::notice::head $missing" <<<"$output" || fail "expected a notice naming the head, got: $output"
}

@test "all-zero HEAD fails open too" {
  commit_file "docs/x.md"
  base=$(git -C "$repo" rev-parse HEAD)
  zero=0000000000000000000000000000000000000000
  cd "$repo" && run bash "$REPO_ROOT/scripts/ci/changed-class.sh" "$base" "$zero"
  [ "$status" -eq 0 ]
  grep -qF "docs-only=false" <<<"$output" || fail "expected docs-only=false, got: $output"
}

# --- a pattern that does not compile must not read as "everything is docs" ----
#
# grep prints nothing on exit 2 (a bad ERE) exactly as it does on exit 1 (no
# match), so a `|| true` made the two indistinguishable: $non_docs came back
# empty, the classifier said docs-only=true, and every job in the matrix skipped
# green on a pure code change. Verified against the pre-fix script, which really
# did answer `docs-only=true` here.

@test "a docs pattern that does not compile fails open, it does not skip the matrix" {
  commit_file "README.md"
  base=$(git -C "$repo" rev-parse HEAD)
  commit_file "src/a.ts"
  head=$(git -C "$repo" rev-parse HEAD)
  cd "$repo" && DOCS_GLOBS='[' run bash "$REPO_ROOT/scripts/ci/changed-class.sh" "$base" "$head"
  [ "$status" -eq 0 ] || fail "a bad pattern failed the step instead of failing open: $output"
  contains "$output" "docs-only=false" || fail "a bad pattern classified a code change as docs: $output"
  contains "$output" "::notice::" || fail "no ::notice:: explaining why the matrix ran in full: $output"
}

@test "a docs pattern that does not compile fails open even on a docs-only change" {
  # The answer is still "run everything": with no working pattern the script has
  # no basis to call anything docs, and over-running is the safe direction.
  commit_file "README.md"
  base=$(git -C "$repo" rev-parse HEAD)
  commit_file "docs/x.md"
  head=$(git -C "$repo" rev-parse HEAD)
  cd "$repo" && DOCS_GLOBS='[' run bash "$REPO_ROOT/scripts/ci/changed-class.sh" "$base" "$head"
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  contains "$output" "docs-only=false" || fail "a bad pattern still classified: $output"
}

@test "a trailing pipe in DOCS_GLOBS_EXTRA is refused, not appended" {
  # `docs/|` is "docs/ OR the empty string", and the empty string matches every
  # path - so every change would classify as docs-only. A trailing pipe is the
  # easy way to write that by accident, in YAML especially. Unlike the runtime
  # paths, a malformed input is a hard error: it is a human mistake, fixable in
  # one edit, and failing open on it would ignore the operator silently forever.
  commit_file "README.md"
  base=$(git -C "$repo" rev-parse HEAD)
  commit_file "src/a.ts"
  head=$(git -C "$repo" rev-parse HEAD)
  cd "$repo" && DOCS_GLOBS_EXTRA='foo/|' run bash "$REPO_ROOT/scripts/ci/changed-class.sh" "$base" "$head"
  [ "$status" -ne 0 ] || fail "an empty alternative was accepted: $output"
  contains "$output" "empty alternative" || fail "the error does not say what is wrong: $output"
  not_contains "$output" "docs-only=true" || fail "it classified anyway: $output"
}

@test "a leading pipe and a doubled pipe in DOCS_GLOBS_EXTRA are refused too" {
  commit_file "README.md"
  base=$(git -C "$repo" rev-parse HEAD)
  commit_file "src/a.ts"
  head=$(git -C "$repo" rev-parse HEAD)
  for bad in '|foo/' 'foo/||bar/'; do
    cd "$repo" && DOCS_GLOBS_EXTRA="$bad" run bash "$REPO_ROOT/scripts/ci/changed-class.sh" "$base" "$head"
    [ "$status" -ne 0 ] || fail "DOCS_GLOBS_EXTRA='$bad' was accepted: $output"
  done
}

@test "a well-formed DOCS_GLOBS_EXTRA still adds alternatives" {
  # The guard must reject only the empty alternative, not the feature.
  commit_file "README.md"
  base=$(git -C "$repo" rev-parse HEAD)
  commit_file "handbook/x.txt"
  head=$(git -C "$repo" rev-parse HEAD)
  cd "$repo" && DOCS_GLOBS_EXTRA='^handbook/' run bash "$REPO_ROOT/scripts/ci/changed-class.sh" "$base" "$head"
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  has_line "docs-only=true" || fail "expected docs-only=true, got: $output"
}

# --- the suite classes ---------------------------------------------------------
#
# Each class is ignore-based: "changed" unless every path is on its irrelevant
# list. These cases walk one representative path per list entry through all
# three classes, so a pattern that grew too wide shows up as a class going
# false where it must stay true.

# classify_change PATH... - commit PATHs on top of a base and classify the range.
classify_change() {
  commit_file "base.txt"
  base=$(git -C "$repo" rev-parse HEAD)
  local path
  for path in "$@"; do commit_file "$path"; done
  head=$(git -C "$repo" rev-parse HEAD)
  cd "$repo" && run bash "$REPO_ROOT/scripts/ci/changed-class.sh" "$base" "$head"
}

# expect DOCS UNIT E2E WEB - the four answers, in output order.
expect() {
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  has_line "docs-only=$1" || fail "expected docs-only=$1, got: $output"
  has_line "unit-changed=$2" || fail "expected unit-changed=$2, got: $output"
  has_line "e2e-changed=$3" || fail "expected e2e-changed=$3, got: $output"
  has_line "web-changed=$4" || fail "expected web-changed=$4, got: $output"
}

@test "a source change affects every suite" {
  classify_change "src/app.ts"
  expect false true true true
}

@test "a docs-only change affects no suite" {
  classify_change "docs/x.md" "README.md"
  expect true false false false
}

@test "a Maestro flow change runs E2E only" {
  classify_change ".maestro/flows/login.yaml"
  expect false false true false
}

@test "a unit test change runs unit and web, not E2E" {
  # Web, because Playwright's default testMatch takes *.test.* too.
  classify_change "src/lib/format.test.ts"
  expect false true false true
}

@test "a __tests__ directory, a snapshot and the jest config are irrelevant to E2E" {
  classify_change "src/__tests__/a.ts" "src/__snapshots__/a.snap" "jest.config.ts"
  expect false true false true
}

@test "a snapshot and the jest config are irrelevant to the web build too" {
  classify_change "src/__snapshots__/a.snap" "jest.config.ts"
  expect false true false false
}

@test "a web E2E change runs the web build only" {
  classify_change "e2e/web/login.spec.ts" "playwright.config.ts"
  expect false false false true
}

@test "a fastlane change affects no suite, and is not docs" {
  classify_change "fastlane/Fastfile"
  expect false false false false
}

@test "a Gemfile change runs E2E only: CocoaPods runs under it in the iOS build" {
  classify_change "Gemfile" "Gemfile.lock"
  expect false false true false
}

@test "a workflow change affects every suite" {
  classify_change ".github/workflows/ci.yml"
  expect false true true true
}

@test "a lockfile change affects every suite" {
  classify_change "pnpm-lock.yaml"
  expect false true true true
}

@test "one relevant path among irrelevant ones still runs the suite" {
  classify_change ".maestro/flows/login.yaml" "src/app.ts"
  expect false true true true
}

@test "DOCS_GLOBS_EXTRA is irrelevant to every suite as well" {
  commit_file "base.txt"
  base=$(git -C "$repo" rev-parse HEAD)
  commit_file "handbook/x.txt"
  head=$(git -C "$repo" rev-parse HEAD)
  cd "$repo" && DOCS_GLOBS_EXTRA='^handbook/' run bash "$REPO_ROOT/scripts/ci/changed-class.sh" "$base" "$head"
  expect true false false false
}

@test "UNIT_IGNORE_GLOBS_EXTRA widens the unit class alone" {
  commit_file "base.txt"
  base=$(git -C "$repo" rev-parse HEAD)
  commit_file "tools/a.sh"
  head=$(git -C "$repo" rev-parse HEAD)
  cd "$repo" && UNIT_IGNORE_GLOBS_EXTRA='^tools/' run bash "$REPO_ROOT/scripts/ci/changed-class.sh" "$base" "$head"
  expect false false true true
}

@test "E2E_IGNORE_GLOBS_EXTRA widens the E2E class alone" {
  commit_file "base.txt"
  base=$(git -C "$repo" rev-parse HEAD)
  commit_file "tools/a.sh"
  head=$(git -C "$repo" rev-parse HEAD)
  cd "$repo" && E2E_IGNORE_GLOBS_EXTRA='^tools/' run bash "$REPO_ROOT/scripts/ci/changed-class.sh" "$base" "$head"
  expect false true false true
}

@test "WEB_IGNORE_GLOBS_EXTRA widens the web class alone" {
  commit_file "base.txt"
  base=$(git -C "$repo" rev-parse HEAD)
  commit_file "tools/a.sh"
  head=$(git -C "$repo" rev-parse HEAD)
  cd "$repo" && WEB_IGNORE_GLOBS_EXTRA='^tools/' run bash "$REPO_ROOT/scripts/ci/changed-class.sh" "$base" "$head"
  expect false true true false
}

@test "an empty alternative in any suite extra is refused" {
  commit_file "base.txt"
  base=$(git -C "$repo" rev-parse HEAD)
  commit_file "src/a.ts"
  head=$(git -C "$repo" rev-parse HEAD)
  for name in UNIT_IGNORE_GLOBS_EXTRA E2E_IGNORE_GLOBS_EXTRA WEB_IGNORE_GLOBS_EXTRA; do
    for bad in 'foo/|' '|foo/' 'foo/||bar/'; do
      cd "$repo" && run env "$name=$bad" bash "$REPO_ROOT/scripts/ci/changed-class.sh" "$base" "$head"
      [ "$status" -ne 0 ] || fail "$name='$bad' was accepted: $output"
      contains "$output" "$name has an empty alternative" || fail "the error does not name $name: $output"
    done
  done
}

@test "a suite extra that does not compile fails open for every class" {
  commit_file "base.txt"
  base=$(git -C "$repo" rev-parse HEAD)
  commit_file "docs/x.md"
  head=$(git -C "$repo" rev-parse HEAD)
  cd "$repo" && E2E_IGNORE_GLOBS_EXTRA='[' run bash "$REPO_ROOT/scripts/ci/changed-class.sh" "$base" "$head"
  expect false true true true
  contains "$output" "::notice::could not apply the e2e pattern" || fail "no notice naming the pattern: $output"
}

@test "every cannot-classify path runs every suite, not just the docs gate" {
  commit_file "docs/x.md"
  head=$(git -C "$repo" rev-parse HEAD)
  cd "$repo" && run bash "$REPO_ROOT/scripts/ci/changed-class.sh" "" "$head"
  expect false true true true
}

@test "an empty range runs every suite" {
  commit_file "docs/x.md"
  head=$(git -C "$repo" rev-parse HEAD)
  cd "$repo" && run bash "$REPO_ROOT/scripts/ci/changed-class.sh" "$head" "$head"
  expect false true true true
}

# DOCS_GLOBS replaces the docs pattern, and the docs pattern is part of every
# suite's irrelevant list - so the replacement has to reach the classes too, in
# both directions.
@test "DOCS_GLOBS replaces the docs part of every suite's list as well" {
  commit_file "base.txt"
  base=$(git -C "$repo" rev-parse HEAD)
  commit_file "handbook/x.txt"
  head=$(git -C "$repo" rev-parse HEAD)
  cd "$repo" && DOCS_GLOBS='^handbook/' run bash "$REPO_ROOT/scripts/ci/changed-class.sh" "$base" "$head"
  expect true false false false
  commit_file "docs/x.md"
  head=$(git -C "$repo" rev-parse HEAD)
  cd "$repo" && DOCS_GLOBS='^handbook/' run bash "$REPO_ROOT/scripts/ci/changed-class.sh" "$base" "$head"
  # docs/ is no longer docs under the replacement, so it runs every suite.
  expect false true true true
}

# When the two ends share no history, merge-base fails and the classifier falls
# back to a two-dot diff with a warning - it still answers, it does not abort.
@test "unrelated histories fall back to a two-dot diff and still classify" {
  commit_file "docs/a.md"
  base=$(git -C "$repo" rev-parse HEAD)
  git -C "$repo" checkout -q --orphan unrelated
  git -C "$repo" rm -rq --cached .
  rm -rf "$repo/docs"
  commit_file ".maestro/flows/login.yaml"
  head=$(git -C "$repo" rev-parse HEAD)
  cd "$repo" && run bash "$REPO_ROOT/scripts/ci/changed-class.sh" "$base" "$head"
  # The two-dot diff holds the deleted docs/a.md and the added flow.
  expect false false true false
  contains "$output" "falling back to two-dot diff" || fail "no warning about the fallback: $output"
}

# One representative path per list entry is what the cases above walk. This
# walks the spellings each entry has to accept - every extension the pattern
# promises, the entry nested below the root where it is not anchored - and the
# near misses it must not accept.
@test "every spelling of every built-in list entry classifies as documented" {
  # path | unit-changed e2e-changed web-changed
  checked=0
  while IFS='|' read -r path want; do
    [ -n "$path" ] || continue
    checked=$((checked + 1))
    commit_file "base.txt"
    base=$(git -C "$repo" rev-parse HEAD)
    commit_file "$path"
    head=$(git -C "$repo" rev-parse HEAD)
    cd "$repo" && run bash "$REPO_ROOT/scripts/ci/changed-class.sh" "$base" "$head"
    [ "$status" -eq 0 ] || fail "$path: exited $status: $output"
    read -r unit e2e web <<<"$want"
    has_line "unit-changed=$unit" || fail "$path: expected unit-changed=$unit, got: $output"
    has_line "e2e-changed=$e2e" || fail "$path: expected e2e-changed=$e2e, got: $output"
    has_line "web-changed=$web" || fail "$path: expected web-changed=$web, got: $output"
  done <<'CASES'
jest.config.js|true false false
jest.config.mjs|true false false
packages/app/jest.config.cjs|true false false
src/a.test.js|true false true
src/a.test.jsx|true false true
src/a.test.tsx|true false true
src/a.test.mjs|true false true
src/a.test.cts|true false true
packages/app/src/__tests__/a.ts|true false true
packages/app/Gemfile|false true false
packages/app/Gemfile.lock|false true false
playwright.config.js|false false true
packages/web/playwright.config.mts|false false true
e2e/native/helper.ts|false true true
.maestro/config.yaml|false true false
src/latest.ts|true true true
src/test-utils.ts|true true true
src/a.test-helpers.ts|true true true
src/jest.config.ts.bak|true true true
fastlane-plugin/a.rb|true true true
app/fastlane/Fastfile|true true true
Gemfile.local|true true true
src/.maestro/x.yaml|true true true
.github/workflows/ci-web.yml|true true true
.github/ISSUE_TEMPLATE/bug.md|false false false
CASES
  # A loop that read nothing would pass by vacuum.
  [ "$checked" -eq 25 ] || fail "walked $checked cases, expected 25"
}

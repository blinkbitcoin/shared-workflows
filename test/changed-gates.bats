#!/usr/bin/env bats
# scripts/self/changed-gates.sh: which of this repository's narrow CI gates a
# diff can affect. The diff logic it shares with the consumer classifier is
# scripts/lib/changed-files.sh, whose own cases are in changed-files.bats.
load test_helper

setup() {
  repo="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$repo"
  git -C "$repo" init -q -b main
  git -C "$repo" config user.email "test@example.com"
  git -C "$repo" config user.name "Test"
}

commit_file() {
  local path="$1"
  mkdir -p "$(dirname "$repo/$path")"
  echo "content $RANDOM" >> "$repo/$path"
  git -C "$repo" add "$path"
  git -C "$repo" commit -q -m "touch $path"
}

has_line() { grep -qxF "$1" <<<"$output"; }

# gates_for PATH... - commit PATHs on top of a base and classify the range.
gates_for() {
  commit_file "base.txt"
  base=$(git -C "$repo" rev-parse HEAD)
  local path
  for path in "$@"; do commit_file "$path"; done
  head=$(git -C "$repo" rev-parse HEAD)
  cd "$repo" && run bash "$REPO_ROOT/scripts/self/changed-gates.sh" "$base" "$head"
}

# expect CODE TOOLING PACKAGE
expect() {
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  has_line "code=$1" || fail "expected code=$1, got: $output"
  has_line "tooling=$2" || fail "expected tooling=$2, got: $output"
  has_line "package=$3" || fail "expected package=$3, got: $output"
}

@test "a docs change runs none of the narrow gates" {
  gates_for "README.md" "docs/consumer-guide.md"
  expect false false false
}

@test "a test change runs none of the narrow gates" {
  # Tests run bats, which has no class and runs on every change.
  gates_for "test/foo.bats"
  expect false false false
}

@test "a script change runs code" {
  gates_for "scripts/ci/foo.sh"
  expect true false false
}

@test "a non-shell file under scripts/ does not run code" {
  gates_for "scripts/lib/env-validate.mjs"
  expect false false false
}

@test "a reusable workflow change runs code" {
  gates_for ".github/workflows/check-unit.yml"
  expect true false false
}

@test "the shellcheck and actionlint configuration run code" {
  gates_for ".shellcheckrc" ".github/actionlint.yaml"
  expect true false false
}

@test "a composite action change runs no narrow gate unless check-versions reads it" {
  gates_for ".github/actions/setup/action.yml"
  expect false false false
}

@test "the maestro action runs tooling" {
  gates_for ".github/actions/maestro/action.yml"
  expect false true false
}

@test "the workflows check-versions reads run code and tooling" {
  gates_for ".github/workflows/check-e2e.yml"
  expect true true false
  gates_for ".github/workflows/build-android.yml"
  expect true true false
}

@test "the pinned versions run tooling (and code, for the shell file)" {
  gates_for "scripts/lib/versions.sh"
  expect true true false
  gates_for "scripts/self/check-versions.sh"
  expect true true false
}

@test "the baseline's versions run tooling and package" {
  gates_for "packages/dev-config/versions.json"
  expect false true true
  gates_for "packages/dev-config/bin/check-tool-versions.mjs"
  expect false true true
}

@test "any other dev-config change runs package alone" {
  gates_for "packages/dev-config/contract.json"
  expect false false true
}

@test "what changes how every gate runs runs every gate" {
  for path in Makefile .mise.toml .github/workflows/self-ci.yml .github/workflows/self-checks.yml \
    .github/workflows/self-unit.yml scripts/self/changed-gates.sh scripts/lib/common.sh \
    scripts/lib/changed-files.sh; do
    gates_for "$path"
    [ "$status" -eq 0 ] || fail "$path: exited $status: $output"
    has_line "code=true" || fail "$path did not run code: $output"
    has_line "tooling=true" || fail "$path did not run tooling: $output"
    has_line "package=true" || fail "$path did not run package: $output"
  done
}

@test "no base (a push to main, the release PR's dispatch) runs every gate" {
  commit_file "README.md"
  head=$(git -C "$repo" rev-parse HEAD)
  cd "$repo" && run bash "$REPO_ROOT/scripts/self/changed-gates.sh" "" "$head"
  expect true true true
  contains "$output" "::notice::no base sha" || fail "no notice saying why: $output"
}

@test "an absent base runs every gate" {
  commit_file "README.md"
  head=$(git -C "$repo" rev-parse HEAD)
  cd "$repo" && run bash "$REPO_ROOT/scripts/self/changed-gates.sh" deadbeefdeadbeefdeadbeefdeadbeefdeadbeef "$head"
  expect true true true
}

@test "the head argument is required" {
  cd "$repo" && run bash "$REPO_ROOT/scripts/self/changed-gates.sh" abc
  [ "$status" -ne 0 ] || fail "ran without a head: $output"
  contains "$output" "usage: changed-gates.sh" || fail "no usage line: $output"
}

@test "an unrelated-history range still classifies the self gates" {
  commit_file "a.txt"
  base=$(git -C "$repo" rev-parse HEAD)
  git -C "$repo" checkout -q --orphan unrelated
  git -C "$repo" rm -rq --cached .
  rm -f "$repo/a.txt"
  commit_file "packages/dev-config/x.json"
  head=$(git -C "$repo" rev-parse HEAD)
  cd "$repo" && run bash "$REPO_ROOT/scripts/self/changed-gates.sh" "$base" "$head"
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  has_line "code=false" || fail "expected code=false: $output"
  has_line "tooling=false" || fail "expected tooling=false: $output"
  has_line "package=true" || fail "expected package=true: $output"
}

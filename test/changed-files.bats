#!/usr/bin/env bats
# scripts/lib/changed-files.sh, called directly: the diff logic the consumer
# classifier (changed-class.bats) and the self-CI classifier (changed-gates.bats)
# share. Those two suites run it through their scripts; these cases pin each
# helper's answers and return codes on their own.
load test_helper

setup() {
  repo="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$repo"
  git -C "$repo" init -q -b main
  git -C "$repo" config user.email "test@example.com"
  git -C "$repo" config user.name "Test"
  source "$REPO_ROOT/scripts/lib/common.sh"
  source "$REPO_ROOT/scripts/lib/changed-files.sh"
}

commit_file() {
  local path="$1"
  mkdir -p "$(dirname "$repo/$path")"
  echo "content $RANDOM" >> "$repo/$path"
  git -C "$repo" add "$path"
  git -C "$repo" commit -q -m "touch $path"
}

has_line() { grep -qxF "$1" <<<"$output"; }


@test "any_path_matches answers true, false, and 2 for a pattern that does not compile" {
  [ "$(any_path_matches '^src/' $'docs/a.md\nsrc/b.ts')" = true ] || fail "a match was not true"
  [ "$(any_path_matches '^lib/' $'docs/a.md\nsrc/b.ts')" = false ] || fail "no match was not false"
  run any_path_matches '[' 'src/b.ts'
  [ "$status" -eq 2 ] || fail "a bad pattern returned $status, not 2: $output"
  has_line true && fail "a bad pattern printed an answer: $output"
  has_line false && fail "a bad pattern printed an answer: $output"
  true
}

@test "any_path_matches is not fooled by an early grep exit on a long list" {
  # `printf | grep -q` under pipefail turns an early match into status 141.
  set -o pipefail
  list="src/first.ts"
  for i in $(seq 1 20000); do list+=$'\n'"docs/file$i.md"; done
  [ "$(any_path_matches '^src/' "$list")" = true ] || fail "an early match on a long list was not true"
}

@test "every_path_matches answers true, false, and 2 for a pattern that does not compile" {
  [ "$(every_path_matches '^docs/' $'docs/a.md\ndocs/b.md')" = true ] || fail "all matching was not true"
  [ "$(every_path_matches '^docs/' $'docs/a.md\nsrc/b.ts')" = false ] || fail "one non-match was not false"
  run every_path_matches '[' 'docs/a.md'
  [ "$status" -eq 2 ] || fail "a bad pattern returned $status, not 2: $output"
}

@test "changed_files prints the three-dot diff and returns 1 on an empty range" {
  commit_file "a.txt"
  base=$(git -C "$repo" rev-parse HEAD)
  commit_file "src/b.ts"
  head=$(git -C "$repo" rev-parse HEAD)
  cd "$repo"
  [ "$(changed_files "$base" "$head")" = "src/b.ts" ] || fail "wrong file list"
  run changed_files "$head" "$head"
  [ "$status" -eq 1 ] || fail "an empty range returned $status, not 1: $output"
}

@test "changed_files falls back to a two-dot diff, with a warning, when the ends share no history" {
  commit_file "a.txt"
  base=$(git -C "$repo" rev-parse HEAD)
  git -C "$repo" checkout -q --orphan unrelated
  git -C "$repo" rm -rq --cached .
  rm -f "$repo/a.txt"
  commit_file "packages/dev-config/x.json"
  head=$(git -C "$repo" rev-parse HEAD)
  cd "$repo"
  run changed_files "$base" "$head"
  [ "$status" -eq 0 ] || fail "the fallback failed: $output"
  contains "$output" "falling back to two-dot diff" || fail "no warning: $output"
  has_line "a.txt" || fail "the two-dot diff lost the deleted file: $output"
  has_line "packages/dev-config/x.json" || fail "the two-dot diff lost the added file: $output"
}

@test "changed_files returns 1 with a notice for each range it cannot read" {
  commit_file "a.txt"
  head=$(git -C "$repo" rev-parse HEAD)
  cd "$repo"
  run changed_files "" "$head"
  [ "$status" -eq 1 ] || fail "no base returned $status: $output"
  contains "$output" "::notice::no base sha" || fail "no notice for a missing base: $output"
  run changed_files 0000000000000000000000000000000000000000 "$head"
  [ "$status" -eq 1 ] || fail "an all-zero base returned $status: $output"
  contains "$output" "all-zero sha" || fail "no notice for an all-zero base: $output"
  run changed_files deadbeefdeadbeefdeadbeefdeadbeefdeadbeef "$head"
  [ "$status" -eq 1 ] || fail "an absent base returned $status: $output"
  contains "$output" "::notice::base deadbeef" || fail "no notice naming the base: $output"
  run changed_files "$head" deadbeefdeadbeefdeadbeefdeadbeefdeadbeef
  [ "$status" -eq 1 ] || fail "an absent head returned $status: $output"
  contains "$output" "::notice::head deadbeef" || fail "no notice naming the head: $output"
}

@test "reject_empty_alternative accepts a well-formed list and dies on an empty alternative" {
  run reject_empty_alternative SOME_GLOBS '^a/|^b/'
  [ "$status" -eq 0 ] || fail "a well-formed list was refused: $output"
  for bad in 'a/|' '|a/' 'a/||b/'; do
    run reject_empty_alternative SOME_GLOBS "$bad"
    [ "$status" -eq 1 ] || fail "'$bad' was accepted"
    contains "$output" "::error::SOME_GLOBS has an empty alternative" || fail "the error does not name the variable: $output"
  done
}

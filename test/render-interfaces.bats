#!/usr/bin/env bats
# Every assertion ends in `|| fail "..."` - see test_helper.bash.
#
# scripts/self/render-interfaces.sh: the workflow_call interfaces
# check-consumer-contract holds a consumer's calls to, rendered into
# packages/app-tooling/interfaces.json. The committed file must be what the
# script renders today: an input added to a workflow without a re-render would
# otherwise read to every consumer as an input that does not exist.
load test_helper

INTERFACES="$REPO_ROOT/packages/app-tooling/interfaces.json"

@test "the committed interfaces.json is what the workflows render to today" {
  out="$BATS_TEST_TMPDIR/interfaces.json"
  run bash "$REPO_ROOT/scripts/self/render-interfaces.sh" "$out"
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  diff -u "$INTERFACES" "$out" \
    || fail "packages/app-tooling/interfaces.json is stale - run: bash scripts/self/render-interfaces.sh"
  contains "$output" "wrote the interfaces of" || fail "the render was not reported: $output"
}

# The reusable workflows a consumer can call: every workflow_call file but self-*.
reusable_workflows() {
  local f name
  for f in "$REPO_ROOT"/.github/workflows/*.yml; do
    name="$(basename "$f")"
    case "$name" in
      self-*) ;;
      *) [ "$(yq -r '.on | has("workflow_call")' "$f")" != "true" ] || printf '%s\n' "$name" ;;
    esac
  done | sort
}

@test "every reusable workflow but this repository's own CI is in it, and nothing else" {
  want="$(reusable_workflows)"
  got="$(yq -r '.workflows | keys | .[]' "$INTERFACES" | sort)"
  [ "$(grep -c . <<<"$want")" -ge 10 ] || fail "found only '$want' - the workflow listing is wrong"
  [ "$got" = "$want" ] || fail "interfaces.json covers:
$got
but the reusable workflows are:
$want"
}

@test "an input keeps its type and required flag, a secret its required flag, and outputs are listed" {
  [ "$(yq -r '.workflows."publish-store.yml".inputs.version.required' "$INTERFACES")" = "true" ] \
    || fail "publish-store's required version input lost its flag"
  [ "$(yq -r '.workflows."publish-store.yml".inputs."dry-run".type' "$INTERFACES")" = "boolean" ] \
    || fail "publish-store's dry-run lost its boolean type"
  [ "$(yq -r '.workflows."publish-store.yml".inputs.repository.type' "$INTERFACES")" = "string" ] \
    || fail "an input with no required: did not default to optional string"
  [ "$(yq -r '.workflows."publish-ota.yml".secrets.OTA_PUBLISH_TOKEN.required' "$INTERFACES")" = "false" ] \
    || fail "publish-ota's secret lost its required flag"
  [ "$(yq -r '.workflows."check-code.yml".outputs | join(" ")' "$INTERFACES")" = \
    "$(yq -r '.on.workflow_call.outputs | keys | join(" ")' "$REPO_ROOT/.github/workflows/check-code.yml")" ] \
    || fail "check-code's outputs are not the ones it declares"
  [ "$(yq -r '.workflows."pr-closed.yml".inputs | length' "$INTERFACES")" = "0" ] \
    || fail "a workflow with no inputs did not render as an empty table"
}

@test "a tree with no reusable workflow is fatal" {
  tree="$BATS_TEST_TMPDIR/tree"
  mkdir -p "$tree/scripts/self" "$tree/scripts/lib" "$tree/.github/workflows"
  cp "$REPO_ROOT/scripts/self/render-interfaces.sh" "$tree/scripts/self/"
  cp "$REPO_ROOT/scripts/lib/common.sh" "$tree/scripts/lib/"
  printf 'name: Self\non:\n  workflow_call: {}\n' > "$tree/.github/workflows/self-ci.yml"
  printf 'name: Push\non:\n  push: {}\n' > "$tree/.github/workflows/push.yml"
  run bash "$tree/scripts/self/render-interfaces.sh" "$BATS_TEST_TMPDIR/out.json"
  [ "$status" -ne 0 ] || fail "rendered from a tree with no reusable workflow: $output"
  contains "$output" "no reusable workflow found under $tree/.github/workflows" || fail "output: $output"
}

@test "without yq it is fatal, and names the command" {
  noyq="$BATS_TEST_TMPDIR/noyq"
  mkdir -p "$noyq"
  for c in bash dirname; do
    p="$(command -v "$c")" && ln -sf "$p" "$noyq/$c"
  done
  PATH="$noyq" run bash "$REPO_ROOT/scripts/self/render-interfaces.sh" "$BATS_TEST_TMPDIR/out.json"
  [ "$status" -ne 0 ] || fail "ran without yq: $output"
  contains "$output" "missing command: yq" || fail "output: $output"
}

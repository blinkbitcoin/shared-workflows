#!/usr/bin/env bats
load test_helper

setup() {
  ACTIONS=("$REPO_ROOT"/.github/actions/*/action.yml)
}

@test "at least the five composite actions exist" {
  count=0
  for a in "${ACTIONS[@]}"; do [ -f "$a" ] && count=$((count + 1)); done
  [ "$count" -ge 5 ]
}

@test "every action declares runs.using: composite" {
  for a in "${ACTIONS[@]}"; do
    using=$(yq -r '.runs.using' "$a")
    [ "$using" = "composite" ]
  done
}

@test "every step has a name" {
  for a in "${ACTIONS[@]}"; do
    missing=$(yq -r '[.runs.steps[] | select(has("name") | not)] | length' "$a")
    [ "$missing" -eq 0 ]
  done
}

@test "every run: step starts with 'bash '" {
  for a in "${ACTIONS[@]}"; do
    bad=$(yq -r '[.runs.steps[] | select(has("run")) | .run | select(test("^bash ") | not)] | length' "$a")
    [ "$bad" -eq 0 ]
  done
}

@test "every input has a description and a default" {
  for a in "${ACTIONS[@]}"; do
    bad=$(yq -r '[(.inputs // {}) | to_entries[] | select((.value.description // "") == "" or (.value | has("default") | not))] | length' "$a")
    [ "$bad" -eq 0 ]
  done
}

# native-key computes cache keys and needs only yq. mise also reads the
# consumer's .mise.toml from the checkout, so an unrestricted install pulled in
# every tool the consumer pins - a PyPI failure installing one of them failed
# an Android build in a step that never uses it.
@test "native-key installs yq and nothing else" {
  a="$REPO_ROOT/.github/actions/native-key/action.yml"
  step='[.runs.steps[] | select((.uses // "") | test("^jdx/mise-action@"))]'
  [ "$(yq -r "$step | length" "$a")" -eq 1 ] || fail "native-key no longer has exactly one mise-action step"
  [ "$(yq -r "$step[0].with.install_args" "$a")" = "yq" ] \
    || fail "native-key's mise-action installs more than yq: install_args is '$(yq -r "$step[0].with.install_args" "$a")'"
}

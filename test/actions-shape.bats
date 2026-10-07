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

# A job that does not install (install: 'false') used to restore the pnpm store
# and then save it untouched under the current lockfile's key: after a lockfile
# change, a stale store under the exact key every later job hits. And the key
# hashed '**/pnpm-lock.yaml', which also matched .workflows/'s fixture
# lockfiles, so a fixture change moved every consumer's key.
@test "setup caches the pnpm store only for a job that installs, keyed on the consumer's own lockfile" {
  a="$REPO_ROOT/.github/actions/setup/action.yml"
  for name in "Resolve pnpm store path" "Cache pnpm store"; do
    cond="$(yq -r ".runs.steps[] | select(.name == \"$name\") | .if" "$a")"
    [ "$cond" = "inputs.install == 'true'" ] || fail "'$name' is not gated on install: if is '$cond'"
  done
  key="$(yq -r '.runs.steps[] | select(.name == "Cache pnpm store") | .with.key' "$a")"
  [ "$key" = 'pnpm-${{ runner.os }}-${{ steps.store.outputs.lock-hash }}' ] || fail "unexpected pnpm cache key: $key"
  not_contains "$(cat "$a")" "hashFiles(" || fail "setup hashes files by glob again"
}

# Dependabot's `directory: /` reads .github/workflows/ and a root action.yml
# only, so the pins inside the composite actions were never proposed.
@test "dependabot watches the composite actions' pins as well as the workflows'" {
  cfg="$REPO_ROOT/.github/dependabot.yml"
  dirs="$(yq -r '.updates[] | select(.package-ecosystem == "github-actions") | .directories[]' "$cfg")"
  printf '%s\n' "$dirs" | grep -qx '/' || fail "the workflows are not watched: $dirs"
  printf '%s\n' "$dirs" | grep -qxF '/.github/actions/*' || fail "the composite actions are not watched: $dirs"
}

@test "maestro restores the CLI everywhere and saves it only when the caller says so" {
  # test-e2e.yml passes save-cache: false off the default branch, whose cache
  # scope its own entries would otherwise crowd; the default keeps every other
  # caller saving as before.
  a="$REPO_ROOT/.github/actions/maestro/action.yml"
  [ "$(yq -r '.inputs."save-cache".default' "$a")" = "true" ] || fail "maestro's save-cache input no longer defaults to 'true'"
  [ "$(yq -r '[.runs.steps[] | select((.uses // "") | test("^actions/cache@"))] | length' "$a")" -eq 0 ] \
    || fail "maestro uses actions/cache, which saves whatever the caller asked"
  restore_key=$(yq -r '.runs.steps[] | select((.uses // "") | test("^actions/cache/restore@")) | .with.key' "$a")
  save=$(yq -r '.runs.steps[] | select((.uses // "") | test("^actions/cache/save@"))' "$a")
  [ -n "$restore_key" ] && [ -n "$save" ] || fail "maestro no longer restores and saves its cache in separate steps"
  [ "$(printf '%s' "$save" | yq -r '.with.key')" = "$restore_key" ] || fail "maestro saves under a different key than it restores"
  contains "$(printf '%s' "$save" | yq -r '.if')" "inputs.save-cache == 'true'" || fail "maestro's save is not gated on save-cache"
  contains "$(printf '%s' "$save" | yq -r '.if')" "cache-hit != 'true'" || fail "maestro's save runs on an exact hit too"
}

#!/usr/bin/env bats
# Every assertion ends in `|| fail "..."` - see test_helper.bash.
#
# scripts/self/check-versions.sh (`make check-versions`): every pinned tool
# version agrees across scripts/lib/versions.sh, the workflow and action input
# defaults, .mise.toml and packages/dev-config/versions.json. Its only real
# behaviour is failing when they disagree, so each comparison it makes is
# broken here on its own, in a copy of the files it reads, and must fail the
# gate with exit 1 and name what drifted. Also covered: the unmodified pins
# pass silently, a missing yq stops it with a hint, and several disagreements
# are all reported in one run.

load test_helper

# The files check-versions.sh reads, copied into a tree of their own so a test
# can make them disagree without touching the real ones.
FILES="scripts/self/check-versions.sh
scripts/lib/versions.sh
.github/workflows/check-e2e.yml
.github/workflows/build-android.yml
.github/actions/maestro/action.yml
.mise.toml
packages/dev-config/versions.json"

setup() {
  source "$REPO_ROOT/scripts/lib/versions.sh"
}

# copy_tree - point $TREE and $GATE at a fresh copy of the files the gate
# reads, in a new directory each call so a loop starts every case clean.
copy_tree() {
  local file
  TREE="$(mktemp -d "$BATS_TEST_TMPDIR/tree.XXXXXX")"
  GATE="$TREE/scripts/self/check-versions.sh"
  while read -r file; do
    mkdir -p "$TREE/$(dirname "$file")"
    cp "$REPO_ROOT/$file" "$TREE/$file"
  done <<< "$FILES"
}

# drift FILE SED_EXPRESSION - edit one file in $TREE, and fail when the edit
# changed nothing (so a case cannot pass on an expression that no longer
# matches the file). The .bak copy sed leaves is not a file the gate reads.
drift() {
  sed -i.bak "$2" "$TREE/$1"
  ! cmp -s "$TREE/$1" "$TREE/$1.bak" || fail "the edit to $1 matched nothing: $2"
}

# errors - how many error annotations the last run printed.
errors() { grep -c '::error::' <<< "$output" || true; }

@test "the version agreement gate fails when a pin drifts" {
  # It runs as a gate in `make check`, so a break is loud - but nothing asserted
  # that it *fails* when versions disagree, which is its only real behaviour.
  local work="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$work"
  cp -R "$REPO_ROOT/scripts" "$REPO_ROOT/.github" "$REPO_ROOT/packages" "$work/"
  cp "$REPO_ROOT/.mise.toml" "$work/"
  run mise exec -- bash "$work/scripts/self/check-versions.sh"
  [ "$status" -eq 0 ] || fail "the unmodified tree must pass: $output"

  sed -i.bak 's/^export YQ_VERSION=.*/export YQ_VERSION="0.0.0"/' "$work/scripts/lib/versions.sh"
  run mise exec -- bash "$work/scripts/self/check-versions.sh"
  [ "$status" -ne 0 ] || fail "a drifted yq pin must fail the gate: $output"
  contains "$output" "yq" || fail "does not name the drifted tool: $output"
}

@test "the pins as committed agree, and the gate passes silently" {
  copy_tree
  run bash "$GATE"
  [ "$status" -eq 0 ] || fail "the committed pins must agree: $output"
  [ -z "$output" ] || fail "a passing gate prints nothing: $output"
}

@test "without yq on PATH it stops with an error annotation that says how to run it" {
  copy_tree
  local bin="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$bin"
  ln -s "$(command -v dirname)" "$bin/dirname"
  run env PATH="$bin" "$BASH" "$GATE"
  [ "$status" -eq 1 ] || fail "expected exit 1, got $status: $output"
  contains "$output" "::error::check-versions.sh needs yq on PATH (run it through 'mise exec --')" ||
    fail "the missing yq is not explained: $output"
}

@test "a check-e2e.yml android-api-level default that disagrees fails the gate" {
  copy_tree
  drift .github/workflows/check-e2e.yml "/android-api-level:/,/default:/ s/default: .*/default: 12/"
  run bash "$GATE"
  [ "$status" -eq 1 ] || fail "expected exit 1, got $status: $output"
  contains "$output" "::error::check-e2e.yml android-api-level default (12) != $ANDROID_API_LEVEL" || fail "$output"
  [ "$(errors)" -eq 1 ] || fail "one drift must be one error: $output"
}

@test "a check-e2e.yml maestro-version default that disagrees fails the gate" {
  copy_tree
  drift .github/workflows/check-e2e.yml "/maestro-version:/,/default:/ s/default: .*/default: '0.0.1'/"
  run bash "$GATE"
  [ "$status" -eq 1 ] || fail "expected exit 1, got $status: $output"
  contains "$output" "::error::check-e2e.yml maestro-version default (0.0.1) != $MAESTRO_VERSION" || fail "$output"
  [ "$(errors)" -eq 1 ] || fail "one drift must be one error: $output"
}

@test "a maestro action default that disagrees fails the gate" {
  copy_tree
  drift .github/actions/maestro/action.yml "s/default: '$MAESTRO_VERSION'/default: '0.0.1'/"
  run bash "$GATE"
  [ "$status" -eq 1 ] || fail "expected exit 1, got $status: $output"
  contains "$output" "::error::maestro action default != $MAESTRO_VERSION" || fail "$output"
  [ "$(errors)" -eq 1 ] || fail "one drift must be one error: $output"
}

@test "a build-android.yml bundletool-version default that disagrees fails the gate" {
  copy_tree
  drift .github/workflows/build-android.yml "/bundletool-version:/,/default:/ s/default: .*/default: '0.0.1'/"
  run bash "$GATE"
  [ "$status" -eq 1 ] || fail "expected exit 1, got $status: $output"
  contains "$output" "::error::build-android.yml bundletool-version default (0.0.1) != $BUNDLETOOL_VERSION" || fail "$output"
  [ "$(errors)" -eq 1 ] || fail "one drift must be one error: $output"
}

@test "each tool pinned in .mise.toml that disagrees with versions.sh fails the gate" {
  local tool want
  for tool in shellcheck actionlint yq typos lefthook zizmor gitleaks; do
    copy_tree
    want="$(yq -r ".tools.\"$tool\".version" "$REPO_ROOT/packages/dev-config/versions.json")"
    drift .mise.toml "s/^$tool = \".*\"/$tool = \"0.0.1\"/"
    run bash "$GATE"
    [ "$status" -eq 1 ] || fail "$tool: expected exit 1, got $status: $output"
    contains "$output" "::error::.mise.toml $tool != $want" || fail "$tool: $output"
    [ "$(errors)" -eq 1 ] || fail "$tool: one drift must be one error: $output"
  done
}

@test "a bats pin in .mise.toml that is not an exact version fails the gate" {
  copy_tree
  drift .mise.toml 's/^bats = ".*"/bats = "latest"/'
  run bash "$GATE"
  [ "$status" -eq 1 ] || fail "expected exit 1, got $status: $output"
  contains "$output" "::error::.mise.toml bats must be pinned to an exact version" || fail "$output"
}

@test "each tool in versions.json that disagrees with versions.sh fails the gate" {
  local tool want
  for tool in actionlint shellcheck yq typos lefthook zizmor gitleaks; do
    copy_tree
    want="$(yq -r ".tools.\"$tool\".version" "$REPO_ROOT/packages/dev-config/versions.json")"
    drift packages/dev-config/versions.json "s/\"$tool\": { \"version\": \"[^\"]*\"/\"$tool\": { \"version\": \"0.0.1\"/"
    run bash "$GATE"
    [ "$status" -eq 1 ] || fail "$tool: expected exit 1, got $status: $output"
    contains "$output" "::error::packages/dev-config/versions.json $tool (0.0.1) != versions.sh ($want)" || fail "$tool: $output"
    [ "$(errors)" -eq 1 ] || fail "$tool: one drift must be one error: $output"
  done
}

@test "bats, node or pnpm in versions.json that is not what .mise.toml pins fails the gate" {
  local tool
  for tool in bats node pnpm; do
    copy_tree
    drift packages/dev-config/versions.json "s/\"$tool\": { \"version\": \"[^\"]*\"/\"$tool\": { \"version\": \"99\"/"
    run bash "$GATE"
    [ "$status" -eq 1 ] || fail "$tool: expected exit 1, got $status: $output"
    contains "$output" "::error::packages/dev-config/versions.json $tool (99) is not what .mise.toml pins" || fail "$tool: $output"
    [ "$(errors)" -eq 1 ] || fail "$tool: one drift must be one error: $output"
  done
}

@test "every disagreement is reported in one run, not only the first" {
  copy_tree
  drift .github/workflows/check-e2e.yml "/android-api-level:/,/default:/ s/default: .*/default: 12/"
  drift packages/dev-config/versions.json 's/"node": { "version": "[^"]*"/"node": { "version": "99"/'
  run bash "$GATE"
  [ "$status" -eq 1 ] || fail "expected exit 1, got $status: $output"
  contains "$output" "android-api-level default (12)" || fail "the first drift is missing: $output"
  contains "$output" "versions.json node (99)" || fail "the second drift is missing: $output"
  [ "$(errors)" -eq 2 ] || fail "expected two errors: $output"
}

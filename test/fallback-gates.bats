#!/usr/bin/env bats
# Every assertion ends in `|| fail "..."` - see test_helper.bash.
#
# The five gates this repo implements for a consumer that ships none of its own,
# plus the two libraries and the binary that nothing ran.
#
# The fallbacks were the softest corner of the coverage map: a test named each
# of them, but only to assert that checks.yml still routes through the seam -
# it read their source and never ran them. That reads as coverage in a listing
# while asserting nothing about what they do, which is the distinction
# test/script-coverage.bats now draws.

load test_helper

setup() {
  CONSUMER="$BATS_TEST_TMPDIR/consumer"
  mkdir -p "$CONSUMER"
  export GITHUB_WORKSPACE="$BATS_TEST_TMPDIR"
  export WORKING_DIRECTORY="consumer"
  GITHUB_OUTPUT="$BATS_TEST_TMPDIR/out"
  GITHUB_ENV="$BATS_TEST_TMPDIR/env"
  : > "$GITHUB_OUTPUT"
  : > "$GITHUB_ENV"
  export GITHUB_OUTPUT GITHUB_ENV
  export RUNNER_TEMP="$BATS_TEST_TMPDIR/runner"
  mkdir -p "$RUNNER_TEMP"
  STUB="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$STUB"
  CALLS="$BATS_TEST_TMPDIR/calls"
  : > "$CALLS"
  export WORKFLOWS_TEST_CALLS="$CALLS"
}

# A pnpm that records what it was asked to do and succeeds, unless the test
# names a script that should fail.
stub_pnpm() {
  cat > "$STUB/pnpm" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$WORKFLOWS_TEST_CALLS"
case " $* " in
  *" ${WORKFLOWS_TEST_FAILING_SCRIPT:-__none__} "*) exit 1 ;;
esac
exit 0
SH
  chmod +x "$STUB/pnpm"
  export PATH="$STUB:$PATH"
}

git_consumer() {
  git -C "$CONSUMER" init -q -b main
  git -C "$CONSUMER" config user.email test@example.com
  git -C "$CONSUMER" config user.name test
  printf '{"scripts":{"codegen":"true","i18n:extract":"true"}}\n' > "$CONSUMER/package.json"
  git -C "$CONSUMER" add -A
  git -C "$CONSUMER" commit -q -m "init"
}

# --- audit ---------------------------------------------------------------

@test "the audit fallback runs pnpm audit at the configured level" {
  stub_pnpm
  AUDIT_LEVEL=high run bash "$REPO_ROOT/scripts/checks/audit.sh"
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  run cat "$CALLS"
  contains "$output" "audit" || fail "it did not run an audit: $output"
  contains "$output" "high" || fail "the level was not passed: $output"
}

@test "a vulnerable tree fails the audit gate" {
  stub_pnpm
  WORKFLOWS_TEST_FAILING_SCRIPT="audit" run bash "$REPO_ROOT/scripts/checks/audit.sh"
  [ "$status" -ne 0 ] || fail "a failing audit must fail the gate: $output"
}

# --- codegen and i18n: the two drift gates -------------------------------

@test "the codegen fallback passes when regenerating changes nothing" {
  stub_pnpm
  git_consumer
  run bash "$REPO_ROOT/scripts/checks/codegen.sh"
  [ "$status" -eq 0 ] || fail "a clean tree must pass: $output"
  run cat "$CALLS"
  contains "$output" "codegen" || fail "it did not run codegen: $output"
}

@test "the codegen fallback fails when regenerating leaves a diff" {
  # The whole point of a drift gate: a generated tree that is not what the
  # sources produce. A gate that stops noticing looks exactly like one passing.
  cat > "$STUB/pnpm" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$WORKFLOWS_TEST_CALLS"
mkdir -p "$PWD/src/graphql/generated"
printf 'regenerated\n' >> "$PWD/src/graphql/generated/types.ts"
exit 0
SH
  chmod +x "$STUB/pnpm"
  export PATH="$STUB:$PATH"
  git_consumer
  run bash "$REPO_ROOT/scripts/checks/codegen.sh"
  [ "$status" -ne 0 ] || fail "an uncommitted change must fail the gate: $output"
  contains "$output" "uncommitted or untracked" || fail "it failed for some other reason: $output"
}

@test "the i18n fallback notices an untracked catalogue, not just a modified one" {
  # assert_clean_paths catches a NEW file where a bare `git diff` would not -
  # the difference the consumer guide calls out.
  cat > "$STUB/pnpm" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$WORKFLOWS_TEST_CALLS"
mkdir -p "$PWD/src/i18n/locales"
printf 'new catalogue\n' > "$PWD/src/i18n/locales/de.po"
exit 0
SH
  chmod +x "$STUB/pnpm"
  export PATH="$STUB:$PATH"
  git_consumer
  run bash "$REPO_ROOT/scripts/checks/i18n.sh"
  [ "$status" -ne 0 ] || fail "an untracked catalogue must fail the gate: $output"
}

# --- expo-doctor ---------------------------------------------------------

@test "the expo-doctor fallback prefers the consumer's own pinned copy" {
  # `pnpm dlx expo-doctor@latest` reaches the network and can differ from the
  # version the consumer pinned; the local one wins when it exists.
  stub_pnpm
  printf '{"devDependencies":{"expo-doctor":"^1"}}\n' > "$CONSUMER/package.json"
  run bash "$REPO_ROOT/scripts/checks/expo-doctor.sh"
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  run cat "$CALLS"
  not_contains "$output" "dlx" || fail "it fetched a copy despite a local one: $output"
}

@test "with no pinned copy the expo-doctor fallback fetches one" {
  stub_pnpm
  printf '{}\n' > "$CONSUMER/package.json"
  run bash "$REPO_ROOT/scripts/checks/expo-doctor.sh"
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  run cat "$CALLS"
  contains "$output" "expo-doctor" || fail "it ran no doctor at all: $output"
}

# --- pnpm-install --------------------------------------------------------

@test "the install runs frozen, in the consumer root" {
  # --frozen-lockfile is the point: CI installs the tree someone reviewed.
  stub_pnpm
  printf '{}\n' > "$CONSUMER/package.json"
  : > "$CONSUMER/pnpm-lock.yaml"
  run bash "$REPO_ROOT/scripts/ci/pnpm-install.sh"
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  run cat "$CALLS"
  contains "$output" "install --frozen-lockfile" || fail "not a frozen install: $output"
}

@test "a lockfile out of step with package.json is explained, not left to pnpm" {
  cat > "$STUB/pnpm" <<'SH'
#!/usr/bin/env bash
printf 'ERR_PNPM_OUTDATED_LOCKFILE\n' >&2
exit 1
SH
  chmod +x "$STUB/pnpm"
  printf '{}\n' > "$CONSUMER/package.json"
  : > "$CONSUMER/pnpm-lock.yaml"
  PATH="$STUB:$PATH" run bash "$REPO_ROOT/scripts/ci/pnpm-install.sh"
  [ "$status" -ne 0 ] || fail "a failed install must be fatal: $output"
  contains "$output" "Fix:" || fail "the failure carries no remediation: $output"
  contains "$output" "pnpm-lock.yaml" || fail "does not name what to commit: $output"
}

# --- the libraries and the binary ---------------------------------------

@test "release-env publishes the release directories and derives them from one root" {
  run bash -c 'source "$1/scripts/lib/release-env.sh"; printf "%s\n%s\n" "$WORKFLOWS_OUT" "$WORKFLOWS_ASSETS_DIR"' _ "$REPO_ROOT"
  [ "$status" -eq 0 ] || fail "sourcing it failed: $output"
  contains "$output" "$RUNNER_TEMP" || fail "the output root is not the runner temp: $output"
}

@test "env-validate refuses a credential-shaped name and accepts a plain one" {
  # The one validator behind both build-env and env-json. Its refusal is what
  # stops a secret being published through an input GitHub does not mask.
  WORKFLOWS_ENV_VALIDATE_JSON='{"API_KEY":"x"}' WORKFLOWS_ENV_VALIDATE_LABEL=build-env \
    run mise exec -- node "$REPO_ROOT/scripts/lib/env-validate.mjs"
  [ "$status" -ne 0 ] || fail "a credential-shaped name must be refused: $output"
  contains "$output" "credential" || fail "$output"

  WORKFLOWS_ENV_VALIDATE_JSON='{"MONKEY":"x"}' WORKFLOWS_ENV_VALIDATE_LABEL=build-env \
    run mise exec -- node "$REPO_ROOT/scripts/lib/env-validate.mjs"
  [ "$status" -eq 0 ] || fail "MONKEY is not a credential - the boundary is ^ or _: $output"
}

@test "check-tool-versions runs as a program and reports a mismatch" {
  # Twelve unit tests exercise its exported functions; nothing ran the binary,
  # which is how the advertised `pnpm exec check-tool-versions` could have been
  # broken without a test noticing.
  run mise exec -- node "$REPO_ROOT/packages/dev-config/bin/check-tool-versions.mjs" node
  [ "$status" -eq 0 ] || fail "the pinned node must satisfy its own baseline: $output"
  contains "$output" "node" || fail "it printed nothing about node: $output"

  run mise exec -- node "$REPO_ROOT/packages/dev-config/bin/check-tool-versions.mjs" not-a-tool
  contains "$output" "not in versions.json" || fail "an unknown tool must be reported: $output"
}

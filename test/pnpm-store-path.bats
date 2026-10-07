#!/usr/bin/env bats
# Every assertion ends in `|| fail "..."` - see test_helper.bash.
#
# scripts/ci/pnpm-store-path.sh: the `setup` composite action asks pnpm where
# its store is, from the consumer root, and publishes it as the step output
# `path` that actions/cache saves and restores. A wrong path is a cache that
# silently never hits, so the path is whatever pnpm reports and every failure
# to get one is fatal.
#
# Covers: the path published from the consumer root; printed on stdout when
# there is no $GITHUB_OUTPUT; the lockfile hash, of the consumer's own
# pnpm-lock.yaml only, moving with it, and "none" without one; and fatal with no pnpm on PATH, with pnpm failing,
# or with a working directory that does not exist. pnpm is always a stub.

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
}

# stub_pnpm BODY - put a pnpm on $BATS_TEST_TMPDIR/bin that runs BODY.
stub_pnpm() {
  local stub="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$stub"
  printf '#!/usr/bin/env bash\n%s\n' "$1" > "$stub/pnpm"
  chmod +x "$stub/pnpm"
}

@test "the pnpm store path is whatever pnpm reports, from the consumer root" {
  local stub="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$stub"
  cat > "$stub/pnpm" <<'SH'
#!/usr/bin/env bash
# Prove it ran in the consumer, not wherever bats happened to be.
[ "$1" = "store" ] && [ "$2" = "path" ] || exit 64
printf '%s/.pnpm-store\n' "$PWD"
SH
  chmod +x "$stub/pnpm"
  PATH="$stub:$PATH" run bash "$REPO_ROOT/scripts/ci/pnpm-store-path.sh"
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  run cat "$GITHUB_OUTPUT"
  contains "$output" "consumer/.pnpm-store" || fail "not resolved from the consumer root: $output"
}

@test "no pnpm on PATH names the missing command" {
  local empty="$BATS_TEST_TMPDIR/empty"
  mkdir -p "$empty"
  # Keep the interpreters the script needs, drop pnpm.
  PATH="/usr/bin:/bin" run bash "$REPO_ROOT/scripts/ci/pnpm-store-path.sh"
  [ "$status" -ne 0 ] || fail "must not publish an empty path: $output"
  contains "$output" "pnpm" || fail "does not name the missing command: $output"
}

@test "pnpm failing to report a store is fatal and publishes nothing" {
  stub_pnpm 'echo "ERR_PNPM_NO_STORE" >&2; exit 1'
  PATH="$BATS_TEST_TMPDIR/bin:$PATH" run bash "$REPO_ROOT/scripts/ci/pnpm-store-path.sh"
  [ "$status" -ne 0 ] || fail "a failing pnpm must be fatal: $output"
  contains "$output" "ERR_PNPM_NO_STORE" || fail "pnpm's own error was swallowed: $output"
  run cat "$GITHUB_OUTPUT"
  [ -z "$output" ] || fail "it published a path anyway: $output"
}

@test "a working directory that does not exist is fatal and publishes nothing" {
  stub_pnpm 'printf "%s/.pnpm-store\n" "$PWD"'
  WORKING_DIRECTORY="no-such-directory" PATH="$BATS_TEST_TMPDIR/bin:$PATH" \
    run bash "$REPO_ROOT/scripts/ci/pnpm-store-path.sh"
  [ "$status" -ne 0 ] || fail "a missing working directory must be fatal: $output"
  contains "$output" "no-such-directory" || fail "does not name the directory: $output"
  run cat "$GITHUB_OUTPUT"
  [ -z "$output" ] || fail "it published a path anyway: $output"
}

@test "without GITHUB_OUTPUT the path is printed on stdout" {
  stub_pnpm 'printf "/cache/pnpm-store\n"'
  unset GITHUB_OUTPUT
  PATH="$BATS_TEST_TMPDIR/bin:$PATH" run bash "$REPO_ROOT/scripts/ci/pnpm-store-path.sh"
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  [ "$output" = $'path=/cache/pnpm-store\nlock-hash=none' ] || fail "wrong stdout: $output"
}

# The cache key. Only the consumer's own lockfile counts: this repository is
# checked out inside the workspace as .workflows/, with lockfiles of its own.
@test "lock-hash is the sha256 of the consumer's pnpm-lock.yaml and nothing else" {
  stub_pnpm 'printf "/cache/pnpm-store\n"'
  printf 'lockfileVersion: 9.0\n' > "$CONSUMER/pnpm-lock.yaml"
  want="$(shasum -a 256 "$CONSUMER/pnpm-lock.yaml" | cut -d' ' -f1)"
  mkdir -p "$CONSUMER/.workflows/test/fixtures/consumer-min"
  printf 'lockfileVersion: 9.0\n# a fixture\n' > "$CONSUMER/.workflows/test/fixtures/consumer-min/pnpm-lock.yaml"
  PATH="$BATS_TEST_TMPDIR/bin:$PATH" run bash "$REPO_ROOT/scripts/ci/pnpm-store-path.sh"
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  grep -qx "lock-hash=$want" "$GITHUB_OUTPUT" || fail "wrong lock-hash: $(cat "$GITHUB_OUTPUT")"
}

@test "a changed lockfile changes lock-hash" {
  stub_pnpm 'printf "/cache/pnpm-store\n"'
  printf 'lockfileVersion: 9.0\n' > "$CONSUMER/pnpm-lock.yaml"
  PATH="$BATS_TEST_TMPDIR/bin:$PATH" run bash "$REPO_ROOT/scripts/ci/pnpm-store-path.sh"
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  first="$(grep '^lock-hash=' "$GITHUB_OUTPUT")"
  : > "$GITHUB_OUTPUT"
  printf 'lockfileVersion: 9.0\n# bumped\n' > "$CONSUMER/pnpm-lock.yaml"
  PATH="$BATS_TEST_TMPDIR/bin:$PATH" run bash "$REPO_ROOT/scripts/ci/pnpm-store-path.sh"
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  second="$(grep '^lock-hash=' "$GITHUB_OUTPUT")"
  [ "$first" != "$second" ] || fail "lock-hash did not move with the lockfile: $first"
}

@test "no lockfile hashes as none rather than failing" {
  stub_pnpm 'printf "/cache/pnpm-store\n"'
  PATH="$BATS_TEST_TMPDIR/bin:$PATH" run bash "$REPO_ROOT/scripts/ci/pnpm-store-path.sh"
  [ "$status" -eq 0 ] || fail "a missing lockfile must not fail this step: $output"
  grep -qx 'lock-hash=none' "$GITHUB_OUTPUT" || fail "wrong lock-hash: $(cat "$GITHUB_OUTPUT")"
}

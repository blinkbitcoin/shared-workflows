#!/usr/bin/env bats
# Every assertion ends in `|| fail "..."` - see test_helper.bash.
#
# The four scripts the `setup` composite action runs that nothing tested. They
# are on the path of every job of every workflow in the family, and each one
# answers a question wrongly rather than loudly when it goes wrong: a wrong pnpm
# store path is a cache that silently never hits, a wrong Ruby pin builds the
# lanes against the wrong toolchain, and a wrong WORKFLOWS_DIR makes every later
# `bash "$WORKFLOWS_DIR/..."` exit 127.
#
# They sat beside toolchain-preflight.sh, which does have tests, which is what
# made the gap look accidental rather than considered.

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

# --- ruby-version --------------------------------------------------------

@test "the Ruby pin is read from the consumer's mise config" {
  printf '[tools]\nnode = "24"\nruby = "3.3.6"\n' > "$CONSUMER/.mise.toml"
  run bash "$REPO_ROOT/scripts/ci/ruby-version.sh"
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  run cat "$GITHUB_OUTPUT"
  [ "$output" = "version=3.3.6" ] || fail "wrong pin published: $output"
}

@test "a mise config with no ruby is fatal, naming the tool and the file" {
  # Falling back to a default Ruby would build the lanes against a version
  # nobody chose - the silent-wrong-answer shape this whole file is about.
  printf '[tools]\nnode = "24"\n' > "$CONSUMER/.mise.toml"
  run bash "$REPO_ROOT/scripts/ci/ruby-version.sh"
  [ "$status" -ne 0 ] || fail "a missing ruby pin must be fatal: $output"
  contains "$output" "ruby" || fail "does not name the tool: $output"
  contains "$output" ".mise.toml" || fail "does not name the file: $output"
}

@test "no mise config at all is fatal rather than an empty pin" {
  run bash "$REPO_ROOT/scripts/ci/ruby-version.sh"
  [ "$status" -ne 0 ] || fail "must not publish an empty version: $output"
  run cat "$GITHUB_OUTPUT"
  not_contains "$output" "version=" || fail "it published something anyway: $output"
}

@test "the Ruby pin is read from the consumer, not from this repository" {
  # WORKING_DIRECTORY is what makes these scripts act on the caller's checkout.
  # Reading this repo's own .mise.toml would pin every consumer to our Ruby.
  printf '[tools]\nruby = "3.1.0"\n' > "$CONSUMER/.mise.toml"
  run bash "$REPO_ROOT/scripts/ci/ruby-version.sh"
  run cat "$GITHUB_OUTPUT"
  [ "$output" = "version=3.1.0" ] || fail "did not read the consumer's pin: $output"
}

# --- pnpm-store-path -----------------------------------------------------

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

# --- workflows-env -------------------------------------------------------

@test "WORKFLOWS_DIR is published beside the workspace, not inside the consumer" {
  run bash "$REPO_ROOT/scripts/ci/workflows-env.sh"
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  run cat "$GITHUB_ENV"
  contains "$output" "WORKFLOWS_DIR=$GITHUB_WORKSPACE/.workflows" || fail "wrong WORKFLOWS_DIR: $output"
  contains "$output" "WORKING_DIRECTORY=consumer" || fail "working directory not carried: $output"
}

@test "WORKING_DIRECTORY defaults to the workspace root when unset" {
  unset WORKING_DIRECTORY
  run bash "$REPO_ROOT/scripts/ci/workflows-env.sh"
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  run cat "$GITHUB_ENV"
  contains "$output" "WORKING_DIRECTORY=." || fail "wrong default: $output"
}

@test "the consumer's git exclude gains .workflows/ exactly once" {
  # Appending on every job would grow the file without bound; the guard is a
  # grep, and a grep that stops matching is invisible.
  bash "$REPO_ROOT/scripts/ci/workflows-env.sh"
  bash "$REPO_ROOT/scripts/ci/workflows-env.sh"
  run grep -c '^\.workflows/$' "$CONSUMER/.git/info/exclude"
  [ "$output" = "1" ] || fail "expected one entry, found $output"
}

@test "an existing exclude file keeps what it already had" {
  mkdir -p "$CONSUMER/.git/info"
  printf 'node_modules/\n' > "$CONSUMER/.git/info/exclude"
  bash "$REPO_ROOT/scripts/ci/workflows-env.sh"
  run cat "$CONSUMER/.git/info/exclude"
  contains "$output" "node_modules/" || fail "it clobbered the consumer's own excludes: $output"
  contains "$output" ".workflows/" || fail "$output"
}

# --- yq-version ----------------------------------------------------------

@test "the yq pin comes from the one place versions are written down" {
  run bash "$REPO_ROOT/scripts/ci/yq-version.sh"
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  local pinned
  pinned="$(sed -n 's/^export YQ_VERSION="\(.*\)"$/\1/p' "$REPO_ROOT/scripts/lib/versions.sh")"
  [ -n "$pinned" ] || fail "could not read YQ_VERSION from scripts/lib/versions.sh"
  run cat "$GITHUB_OUTPUT"
  [ "$output" = "version=$pinned" ] || fail "published '$output', versions.sh pins $pinned"
}

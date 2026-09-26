#!/usr/bin/env bats
# Every assertion ends in `|| fail "..."` - see test_helper.bash.
#
# scripts/ci/toolchain-preflight.sh: the setup action's first step. It checks
# that the consumer repository has a mise configuration, a package.json and a
# pnpm-lock.yaml, and refuses the first one missing with what to add and a link
# to the consumer guide's section, before mise-action installs nothing and the
# real symptom appears two steps later. Covered: each refusal and its anchor,
# every mise configuration name it accepts, a working directory below the
# workspace, one that does not exist, and the pass.
# Where the setup action runs it is contract-errors.bats' question.

load test_helper

SCRIPT="$REPO_ROOT/scripts/ci/toolchain-preflight.sh"

@test "a repo with no mise config is told which file is missing, not which command" {
  local root="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$root"
  GITHUB_WORKSPACE="$root" WORKING_DIRECTORY="." run bash "$REPO_ROOT/scripts/ci/toolchain-preflight.sh"
  [ "$status" -eq 1 ] || fail "expected exit 1, got $status"
  contains "$output" "no mise config" || fail "$output"
  contains "$output" ".mise.toml" || fail "the message does not name the file: $output"
  not_contains "$output" "missing command: pnpm" || fail "this is the message it exists to replace: $output"
}

@test "the preflight names each missing piece in turn, and passes on a complete repo" {
  local root="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$root"
  printf '[tools]\nnode = "24"\npnpm = "12"\n' > "$root/.mise.toml"
  GITHUB_WORKSPACE="$root" WORKING_DIRECTORY="." run bash "$REPO_ROOT/scripts/ci/toolchain-preflight.sh"
  contains "$output" "no package.json" || fail "$output"

  printf '{"name":"app"}\n' > "$root/package.json"
  GITHUB_WORKSPACE="$root" WORKING_DIRECTORY="." run bash "$REPO_ROOT/scripts/ci/toolchain-preflight.sh"
  contains "$output" "no pnpm-lock.yaml" || fail "$output"

  : > "$root/pnpm-lock.yaml"
  GITHUB_WORKSPACE="$root" WORKING_DIRECTORY="." run bash "$REPO_ROOT/scripts/ci/toolchain-preflight.sh"
  [ "$status" -eq 0 ] || fail "a complete repo must pass: $output"
}

@test "each refusal exits 1 with a fix and its own section of the consumer guide" {
  local root="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$root"
  GITHUB_WORKSPACE="$root" WORKING_DIRECTORY="." run bash "$SCRIPT"
  [ "$status" -eq 1 ] || fail "no mise configuration: expected exit 1, got $status: $output"
  contains "$output" "Fix: add a .mise.toml with a [tools] table" || fail "no fix for the mise configuration: $output"
  contains "$output" "consumer-guide.md#the-contract-check" || fail "wrong anchor for the mise configuration: $output"

  printf '[tools]\nnode = "24"\n' > "$root/.mise.toml"
  GITHUB_WORKSPACE="$root" WORKING_DIRECTORY="." run bash "$SCRIPT"
  [ "$status" -eq 1 ] || fail "no package.json: expected exit 1, got $status: $output"
  contains "$output" "Fix: this family runs a consumer's package.json scripts by name" ||
    fail "no fix for package.json: $output"
  contains "$output" "consumer-guide.md#script-contract" || fail "wrong anchor for package.json: $output"

  printf '{"name":"app"}\n' > "$root/package.json"
  GITHUB_WORKSPACE="$root" WORKING_DIRECTORY="." run bash "$SCRIPT"
  [ "$status" -eq 1 ] || fail "no lockfile: expected exit 1, got $status: $output"
  contains "$output" "Fix: run pnpm install and commit pnpm-lock.yaml" || fail "no fix for the lockfile: $output"
  contains "$output" "consumer-guide.md#60-second-start" || fail "wrong anchor for the lockfile: $output"
}

@test "every mise configuration file mise reads is accepted, and named when it passes" {
  local name root
  for name in .mise.toml mise.toml .config/mise/config.toml .tool-versions; do
    root="$BATS_TEST_TMPDIR/repo-${name//\//-}"
    mkdir -p "$root/$(dirname "$name")"
    printf 'node 24\n' > "$root/$name"
    printf '{"name":"app"}\n' > "$root/package.json"
    : > "$root/pnpm-lock.yaml"
    GITHUB_WORKSPACE="$root" WORKING_DIRECTORY="." run bash "$SCRIPT"
    [ "$status" -eq 0 ] || fail "$name was not accepted: $output"
    contains "$output" "toolchain preflight: $name, package.json and pnpm-lock.yaml are present" ||
      fail "the pass does not name $name: $output"
  done
}

@test "the first mise configuration in mise's order is the one named" {
  local root="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$root"
  printf 'node 24\n' > "$root/.tool-versions"
  printf '[tools]\nnode = "24"\n' > "$root/mise.toml"
  printf '{"name":"app"}\n' > "$root/package.json"
  : > "$root/pnpm-lock.yaml"
  GITHUB_WORKSPACE="$root" WORKING_DIRECTORY="." run bash "$SCRIPT"
  [ "$status" -eq 0 ] || fail "expected a pass: $output"
  contains "$output" "toolchain preflight: mise.toml," || fail "mise.toml outranks .tool-versions: $output"
}

@test "the working directory, not the workspace root, is what gets checked" {
  # A monorepo caller passes working-directory: the app lives below the root,
  # and a complete root must not make an incomplete app pass.
  local ws="$BATS_TEST_TMPDIR/ws"
  mkdir -p "$ws/apps/mobile"
  printf '[tools]\nnode = "24"\n' > "$ws/.mise.toml"
  printf '{"name":"root"}\n' > "$ws/package.json"
  : > "$ws/pnpm-lock.yaml"
  GITHUB_WORKSPACE="$ws" WORKING_DIRECTORY="apps/mobile" run bash "$SCRIPT"
  [ "$status" -eq 1 ] || fail "the incomplete app passed on the root's files: $output"
  contains "$output" "no mise config in $(cd "$ws/apps/mobile" && pwd -P)" || fail "it checked the wrong directory: $output"

  printf '[tools]\nnode = "24"\n' > "$ws/apps/mobile/.mise.toml"
  printf '{"name":"app"}\n' > "$ws/apps/mobile/package.json"
  : > "$ws/apps/mobile/pnpm-lock.yaml"
  GITHUB_WORKSPACE="$ws" WORKING_DIRECTORY="apps/mobile" run bash "$SCRIPT"
  [ "$status" -eq 0 ] || fail "a complete app below the root must pass: $output"
}

@test "a working directory that does not exist fails instead of checking somewhere else" {
  local ws="$BATS_TEST_TMPDIR/ws"
  mkdir -p "$ws"
  printf '[tools]\nnode = "24"\n' > "$ws/.mise.toml"
  printf '{"name":"root"}\n' > "$ws/package.json"
  : > "$ws/pnpm-lock.yaml"
  GITHUB_WORKSPACE="$ws" WORKING_DIRECTORY="no-such-app" run bash "$SCRIPT"
  [ "$status" -ne 0 ] || fail "a missing working directory passed: $output"
  contains "$output" "no-such-app" || fail "the failure does not name the directory: $output"
  not_contains "$output" "are present" || fail "it reported a pass: $output"
}

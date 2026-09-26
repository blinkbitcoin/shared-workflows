#!/usr/bin/env bats
# Every assertion ends in `|| fail "..."` - see test_helper.bash.
#
# scripts/checks/commitlint.sh: lints a pull request's title, and its commits
# when given a range. A consumer with @commitlint/cli as a devDependency is
# linted by its own commitlint through pnpm, from its own root; any other is
# linted by a pinned commitlint through npx with a conventional-commits
# configuration written to RUNNER_TEMP. Covered: both paths, the range and its
# malformed shapes, a rejected title and a rejected range, a working directory
# below the workspace, and each refusal - no PR_TITLE, no pnpm, no npx.
# That the commit-msg hook pins the same commitlint is hooks.bats' question.
#
# pnpm and npx are stubbed: each call appends its working directory, arguments
# and standard input to a log, and rejects a title containing "REJECT" or, with
# STUB_REJECT_RANGE set, any range. No network.

load test_helper

SCRIPT="$REPO_ROOT/scripts/checks/commitlint.sh"

setup() {
  STUB="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$STUB"
  CALLS="$BATS_TEST_TMPDIR/calls"
  : > "$CALLS"
  export CALLS
  local tool
  for tool in pnpm npx; do
    cat > "$STUB/$tool" <<SH
#!/usr/bin/env bash
input=""
case "\$*" in *--from*) ;; *) input="\$(cat)" ;; esac
printf '%s|%s|%s|%s\n' "$tool" "\$PWD" "\$*" "\$input" >> "\$CALLS"
case "\$input" in *REJECT*) printf 'subject may not be REJECT\n' >&2; exit 1 ;; esac
case "\$*" in *--from*) [ -z "\${STUB_REJECT_RANGE:-}" ] || { printf 'a commit in the range is invalid\n' >&2; exit 1; } ;; esac
exit 0
SH
    chmod +x "$STUB/$tool"
  done
  export PATH="$STUB:$PATH"
  export RUNNER_TEMP="$BATS_TEST_TMPDIR/runner-temp"
  mkdir -p "$RUNNER_TEMP"
  WS="$BATS_TEST_TMPDIR/ws"
  mkdir -p "$WS"
  export GITHUB_WORKSPACE="$WS" WORKING_DIRECTORY="."
  unset PR_TITLE PR_COMMITS_RANGE
}

with_commitlint_dependency() { # [directory]
  printf '{"name":"app","devDependencies":{"@commitlint/cli":"^19"}}\n' > "${1:-$WS}/package.json"
}

# The pinned npx invocation, as the fallback runs it.
NPX_PINS="--yes -p @commitlint/cli@21 -p @commitlint/config-conventional@21 commitlint"

@test "a consumer with @commitlint/cli lints the title with its own commitlint, from its root" {
  with_commitlint_dependency
  PR_TITLE="feat(app): add a thing" run bash "$SCRIPT"
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  [ "$(grep -c . "$CALLS")" -eq 1 ] || fail "expected one call, the title: $(cat "$CALLS")"
  grep -qxF "pnpm|$(cd "$WS" && pwd -P)|exec commitlint|feat(app): add a thing" "$CALLS" ||
    fail "the title was not piped to pnpm exec commitlint in the consumer root: $(cat "$CALLS")"
  ! grep -q '^npx|' "$CALLS" || fail "the npx fallback ran as well: $(cat "$CALLS")"
}

@test "a consumer with @commitlint/cli lints the range with it too" {
  with_commitlint_dependency
  PR_TITLE="fix: a bug" PR_COMMITS_RANGE="base123..head456" run bash "$SCRIPT"
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  grep -qxF "pnpm|$(cd "$WS" && pwd -P)|exec commitlint --from base123 --to head456|" "$CALLS" ||
    fail "the range was not linted from base to head: $(cat "$CALLS")"
}

@test "a consumer without @commitlint/cli is linted by the pinned npx fallback and its written configuration" {
  printf '{"name":"app","dependencies":{"@commitlint/cli":"^19"}}\n' > "$WS/package.json"
  PR_TITLE="feat: a thing" run bash "$SCRIPT"
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  local config="$RUNNER_TEMP/commitlint.config.mjs"
  grep -qF "npx|" "$CALLS" || fail "a runtime dependency is not a devDependency; npx should have run: $(cat "$CALLS")"
  grep -qF "|$NPX_PINS --config $config|feat: a thing" "$CALLS" ||
    fail "npx was not called with the pins and the written configuration: $(cat "$CALLS")"
  grep -qF 'extends: ["@commitlint/config-conventional"]' "$config" ||
    fail "the written configuration does not extend config-conventional: $(cat "$config")"
  ! grep -q '^pnpm|' "$CALLS" || fail "pnpm ran for a consumer without the dependency: $(cat "$CALLS")"
}

@test "a consumer with no package.json at all takes the npx fallback, range included" {
  PR_TITLE="chore: tidy" PR_COMMITS_RANGE="aaa..bbb" run bash "$SCRIPT"
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  grep -qF "|$NPX_PINS --config $RUNNER_TEMP/commitlint.config.mjs|chore: tidy" "$CALLS" ||
    fail "the title was not linted through npx: $(cat "$CALLS")"
  grep -qF "|$NPX_PINS --config $RUNNER_TEMP/commitlint.config.mjs --from aaa --to bbb|" "$CALLS" ||
    fail "the range was not linted through npx: $(cat "$CALLS")"
}

@test "a package.json that is not JSON takes the npx fallback instead of failing" {
  printf '{ "name": "app",, }' > "$WS/package.json"
  PR_TITLE="feat: a thing" run bash "$SCRIPT"
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  grep -q '^npx|' "$CALLS" || fail "npx did not run: $(cat "$CALLS")"
}

@test "with no range, only the title is linted" {
  PR_TITLE="feat: a thing" PR_COMMITS_RANGE="" run bash "$SCRIPT"
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  [ "$(grep -c . "$CALLS")" -eq 1 ] || fail "expected only the title call: $(cat "$CALLS")"
  ! grep -q -- '--from' "$CALLS" || fail "a range was linted without one: $(cat "$CALLS")"
}

@test "a range missing either end is refused, naming the shape it wants" {
  local range
  for range in "base123.." "..head456" ".."; do
    : > "$CALLS"
    PR_TITLE="feat: a thing" PR_COMMITS_RANGE="$range" run bash "$SCRIPT"
    [ "$status" -eq 1 ] || fail "range '$range': expected exit 1, got $status: $output"
    contains "$output" "::error::PR_COMMITS_RANGE must be \"<base-sha>..<head-sha>\", got: $range" ||
      fail "range '$range': the message does not name the shape: $output"
    ! grep -q -- '--from' "$CALLS" || fail "range '$range' was linted: $(cat "$CALLS")"
  done
}

@test "a malformed range is refused on the pnpm path too" {
  with_commitlint_dependency
  PR_TITLE="feat: a thing" PR_COMMITS_RANGE="base123.." run bash "$SCRIPT"
  [ "$status" -eq 1 ] || fail "expected exit 1, got $status: $output"
  contains "$output" "PR_COMMITS_RANGE must be" || fail "$output"
}

@test "a title commitlint rejects fails the step, and the range is not linted after it" {
  PR_TITLE="REJECT this title" PR_COMMITS_RANGE="aaa..bbb" run bash "$SCRIPT"
  [ "$status" -ne 0 ] || fail "a rejected title passed: $output"
  contains "$output" "subject may not be REJECT" || fail "commitlint's reason is not shown: $output"
  ! grep -q -- '--from' "$CALLS" || fail "the range was linted after the title failed: $(cat "$CALLS")"
}

@test "a title rejected by the consumer's own commitlint fails the step" {
  with_commitlint_dependency
  PR_TITLE="REJECT this title" run bash "$SCRIPT"
  [ "$status" -ne 0 ] || fail "a rejected title passed: $output"
}

@test "a range commitlint rejects fails the step" {
  STUB_REJECT_RANGE=1 PR_TITLE="feat: a thing" PR_COMMITS_RANGE="aaa..bbb" run bash "$SCRIPT"
  [ "$status" -ne 0 ] || fail "a rejected range passed: $output"
  contains "$output" "a commit in the range is invalid" || fail "commitlint's reason is not shown: $output"
}

@test "the working directory, not the workspace root, decides which commitlint runs and where" {
  mkdir -p "$WS/apps/mobile"
  with_commitlint_dependency "$WS/apps/mobile"
  WORKING_DIRECTORY="apps/mobile" PR_TITLE="feat: a thing" run bash "$SCRIPT"
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  grep -qxF "pnpm|$(cd "$WS/apps/mobile" && pwd -P)|exec commitlint|feat: a thing" "$CALLS" ||
    fail "commitlint did not run from the working directory: $(cat "$CALLS")"
}

@test "no PR_TITLE is refused before anything runs" {
  run bash "$SCRIPT"
  [ "$status" -ne 0 ] || fail "a missing title passed: $output"
  contains "$output" "PR_TITLE not set" || fail "does not name the variable: $output"
  [ ! -s "$CALLS" ] || fail "commitlint ran without a title: $(cat "$CALLS")"
}

@test "a consumer with @commitlint/cli on a runner without pnpm is refused" {
  # Only what the script needs before its pnpm check: dirname for common.sh and
  # node to read package.json. pnpm, the stub included, is deliberately absent.
  local only="$BATS_TEST_TMPDIR/only"
  mkdir -p "$only"
  ln -s "$(command -v dirname)" "$only/dirname"
  ln -s "$(command -v node)" "$only/node"
  with_commitlint_dependency
  PR_TITLE="feat: a thing" run env PATH="$only" "$BASH" "$SCRIPT"
  [ "$status" -eq 1 ] || fail "expected exit 1, got $status: $output"
  contains "$output" "::error::missing command: pnpm" || fail "does not name the missing command: $output"
}

@test "the npx fallback on a runner without npx is refused" {
  local only="$BATS_TEST_TMPDIR/only"
  mkdir -p "$only"
  ln -s "$(command -v dirname)" "$only/dirname"
  PR_TITLE="feat: a thing" run env PATH="$only" "$BASH" "$SCRIPT"
  [ "$status" -eq 1 ] || fail "expected exit 1, got $status: $output"
  contains "$output" "::error::missing command: npx" || fail "does not name the missing command: $output"
  [ ! -e "$RUNNER_TEMP/commitlint.config.mjs" ] || fail "the configuration was written before the check"
}

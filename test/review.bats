#!/usr/bin/env bats
# scripts/security/review.sh - checks the review switch and git, then runs
# security-review.mjs in the consumer, which writes review.sarif and decides
# every skip of its own. Nothing here reaches a provider: every case stops
# before the module would send a request.
#
# Exit paths covered: switched off, by default and explicitly (a skipped
# SARIF, 0); no git (a skip locally, 1 under CI); the module's own skips, run
# in the consumer's root (0), landing in the default .security when
# SECURITY_DIR is unset; and the module failing on a configuration error (1).
#
# Every assertion ends in `|| fail "..."` - see test_helper.bash.
load test_helper

setup() {
  unset CI GITHUB_WORKSPACE WORKING_DIRECTORY ANDROID_HOME ANDROID_SDK_ROOT
  local var
  for var in $(compgen -e | grep -E '^(SECURITY_|OPENAI_|ANTHROPIC_)' || true); do unset "$var"; done
  export SECURITY_SETTINGS_FILE="$BATS_TEST_TMPDIR/no-security-settings.json"
  export SECURITY_DIR="$BATS_TEST_TMPDIR/out"
  app="$BATS_TEST_TMPDIR/app"
  mkdir -p "$app"
  cd "$app" || return 1
}

# A PATH with only what the runner needs, and no git.
path_without_git() {
  local dir="$BATS_TEST_TMPDIR/bare" tool found
  mkdir -p "$dir"
  for tool in bash env node mkdir dirname; do
    found="$(command -v "$tool" || true)"
    [ -z "$found" ] || ln -sf "$found" "$dir/$tool"
  done
  printf '%s' "$dir"
}

sarif_note() {
  node -e 'const d = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
process.stdout.write((d.runs[0].invocations?.[0]?.toolExecutionNotifications ?? []).map((n) => n.message.text).join("\n"))' "$1"
}

review() { run bash "$REPO_ROOT/scripts/security/review.sh"; }

@test "off by default: it writes a skipped SARIF and exits 0" {
  review
  [ "$status" -eq 0 ] || fail "status $status: $output"
  contains "$(sarif_note "$SECURITY_DIR/review.sarif")" 'disabled' || fail "the skip does not say it is disabled"
}

@test "switched off explicitly, it is the same skip" {
  export SECURITY_REVIEW=false
  review
  [ "$status" -eq 0 ] || fail "status $status: $output"
  contains "$(sarif_note "$SECURITY_DIR/review.sarif")" 'disabled' || fail "the skip does not say it is disabled"
}

@test "switched on with no provider, the runner writes the reviewer's skip" {
  export SECURITY_REVIEW=true
  review
  [ "$status" -eq 0 ] || fail "status $status: $output"
  contains "$output" "review: wrote $SECURITY_DIR/review.sarif" || fail "the log does not say where: $output"
  contains "$(sarif_note "$SECURITY_DIR/review.sarif")" 'no LLM provider configured' || fail "not the reviewer's skip"
}

@test "the reviewer runs in the consumer's root and writes to its .security by default" {
  # The consumer has no prompt file, so the reviewer stops there - before any
  # request - and says so; that proves which directory it looked in.
  unset SECURITY_DIR
  export SECURITY_REVIEW=true SECURITY_LLM_PROVIDER=openai OPENAI_API_KEY=sk-test-review GITHUB_WORKSPACE="$app"
  cd "$BATS_TEST_TMPDIR" || fail "cd"
  review
  [ "$status" -eq 0 ] || fail "status $status: $output"
  [ -s "$app/.security/review.sarif" ] || fail "no SARIF at $app/.security/review.sarif"
  contains "$(sarif_note "$app/.security/review.sarif")" 'security-review.prompt.md is missing' \
    || fail "not the missing-prompt skip: $(sarif_note "$app/.security/review.sarif")"
  not_contains "$output" 'sk-test-review' || fail "the key reached the log"
}

@test "the provider's key is required before anything else" {
  export SECURITY_REVIEW=true SECURITY_LLM_PROVIDER=anthropic
  review
  [ "$status" -eq 0 ] || fail "status $status: $output"
  contains "$(sarif_note "$SECURITY_DIR/review.sarif")" 'ANTHROPIC_API_KEY is not set' || fail "not the missing-key skip"
}

@test "a configuration error in the reviewer fails the run" {
  printf 'prompt\n' > "$app/security-review.prompt.md"
  export SECURITY_REVIEW=true SECURITY_LLM_PROVIDER=openai OPENAI_API_KEY=sk-test SECURITY_LLM_EXTRA_PARAMS='not json'
  review
  [ "$status" -eq 1 ] || fail "a configuration error passed with $status: $output"
  contains "$output" 'review: ' || fail "the reviewer's error is not shown: $output"
  contains "$output" 'SECURITY_LLM_EXTRA_PARAMS' || fail "the error does not name the setting: $output"
}

@test "without git it skips locally" {
  export SECURITY_REVIEW=true
  run env PATH="$(path_without_git)" "$BASH" "$REPO_ROOT/scripts/security/review.sh"
  [ "$status" -eq 0 ] || fail "status $status: $output"
  contains "$(sarif_note "$SECURITY_DIR/review.sarif")" 'git is not installed' || fail "the skip gives no reason"
}

@test "without git it fails under CI" {
  export SECURITY_REVIEW=true
  run env PATH="$(path_without_git)" CI=true "$BASH" "$REPO_ROOT/scripts/security/review.sh"
  [ "$status" -eq 1 ] || fail "a missing git passed under CI with $status: $output"
  contains "$output" 'git is not installed, and under CI that is a failure' || fail "the error: $output"
  [ ! -e "$SECURITY_DIR/review.sarif" ] || fail "CI wrote a skipped SARIF instead of failing"
}

#!/usr/bin/env bats
# secrets.sh, the fallback secret scan. `mise` is stubbed, so these assert what
# gitleaks is asked to scan, not gitleaks itself.
load test_helper

setup() {
  export GITHUB_WORKSPACE="$BATS_TEST_TMPDIR/consumer"
  export WORKING_DIRECTORY=.
  bin="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$bin"
  MISE_LOG="$BATS_TEST_TMPDIR/mise.log"
  export MISE_LOG
  cat > "$bin/mise" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$MISE_LOG"
STUB
  chmod +x "$bin/mise"
  PATH="$bin:$PATH"
  export PATH
  : > "$MISE_LOG"
}

repo_with_two_commits() {
  git init -q "$1"
  # A runner has no global identity; set one per repo, like the other suites.
  git -C "$1" config user.email test@example.com
  git -C "$1" config user.name test
  git -C "$1" commit -q --allow-empty -m one
  git -C "$1" commit -q --allow-empty -m two
}

@test "scans the full git history, redacted" {
  repo_with_two_commits "$GITHUB_WORKSPACE"
  run bash "$REPO_ROOT/scripts/checks/secrets.sh"
  [ "$status" -eq 0 ] || fail "exit $status: $output"
  line="$(cat "$MISE_LOG")"
  [[ "$line" == *"gitleaks git --redact"* ]] || fail "not a redacted history scan: $line"
}

@test "refuses a shallow clone rather than report a partial history as clean" {
  origin="$BATS_TEST_TMPDIR/origin"
  repo_with_two_commits "$origin"
  git clone -q --depth 1 "file://$origin" "$GITHUB_WORKSPACE"
  run bash "$REPO_ROOT/scripts/checks/secrets.sh"
  [ "$status" -ne 0 ] || fail "a shallow clone passed"
  [[ "$output" == *"fetch-depth: 0"* ]] || fail "no fix in the message: $output"
  [ ! -s "$MISE_LOG" ] || fail "gitleaks ran on a shallow clone: $(cat "$MISE_LOG")"
}

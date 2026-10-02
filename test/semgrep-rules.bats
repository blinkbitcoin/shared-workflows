#!/usr/bin/env bats
# scripts/security/rules/ - the Semgrep rules code.sh loads for every consumer.
# `semgrep --test` runs each rule against its fixture (the `ruleid:` and `ok:`
# comments in react-native-secrets.test.tsx), so a rule that stops matching, or
# starts matching ordinary code, fails here before a consumer sees it.
#
# Skipped where semgrep is not installed; check-security.yml's own jobs, and
# the mise toolchain a contributor installs, have it.
#
# Every assertion ends in `|| fail "..."` - see test_helper.bash.
load test_helper

@test "every rule passes its fixture" {
  command -v semgrep >/dev/null 2>&1 || skip "semgrep is not installed (mise install)"
  run semgrep --test --metrics off "$REPO_ROOT/scripts/security/rules"
  [ "$status" -eq 0 ] || fail "semgrep --test: $output"
}

@test "the fixture names every rule the file defines" {
  rules="$REPO_ROOT/scripts/security/rules"
  for id in $(grep -oE '^  - id: [a-z-]+' "$rules/react-native-secrets.yaml" | sed 's/.*: //'); do
    grep -qF "ruleid: $id" "$rules/react-native-secrets.test.tsx" || fail "no positive case for $id"
    grep -qF "ok: $id" "$rules/react-native-secrets.test.tsx" || fail "no negative case for $id"
  done
}

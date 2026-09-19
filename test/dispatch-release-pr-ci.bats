#!/usr/bin/env bats
load test_helper

SCRIPT="$REPO_ROOT/scripts/self/dispatch-release-pr-ci.sh"

setup() {
  # A fake gh that records its arguments; the script must never reach GitHub
  # from a test. Appends (not overwrites) so multi-PR cases record every call.
  bin="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$bin"
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$@" >> "%s/gh.args"\n' "$BATS_TEST_TMPDIR" > "$bin/gh"
  chmod +x "$bin/gh"
  export PATH="$bin:$PATH"
  export GH_TOKEN=fake GH_REPO=blinkbitcoin/shared-workflows
}

@test "dispatches self-ci.yml on the release PR's head branch" {
  PRS_JSON='[{"headBranchName":"release-please--branches--main--components--shared-workflows","number":40}]' \
    run bash "$SCRIPT"
  [ "$status" -eq 0 ] || fail "output: $output"
  args="$(tr '\n' ' ' < "$BATS_TEST_TMPDIR/gh.args")"
  contains "$args" "workflow run self-ci.yml" || fail "args: $args"
  contains "$args" "--repo blinkbitcoin/shared-workflows" || fail "args: $args"
  contains "$args" "--ref release-please--branches--main--components--shared-workflows" || fail "args: $args"
}

@test "dispatches self-ci.yml on every PR in a multi-package release" {
  PRS_JSON='[{"headBranchName":"release-please--branches--main--components--shared-workflows","number":40},{"headBranchName":"release-please--branches--main--components--dev-config","number":41}]' \
    run bash "$SCRIPT"
  [ "$status" -eq 0 ] || fail "output: $output"
  args="$(tr '\n' ' ' < "$BATS_TEST_TMPDIR/gh.args")"
  count="$(grep -c '^workflow$' "$BATS_TEST_TMPDIR/gh.args" || true)"
  [ "$count" -eq 2 ] || fail "expected 2 gh invocations, got $count: args: $args"
  contains "$args" "--ref release-please--branches--main--components--shared-workflows" || fail "args: $args"
  contains "$args" "--ref release-please--branches--main--components--dev-config" || fail "args: $args"
}

@test "an empty PRS_JSON is an error, not a silent skip" {
  PRS_JSON='' run bash "$SCRIPT"
  [ "$status" -ne 0 ] || fail "exited 0 with no PRs"
  contains "$output" "::error::" || fail "output: $output"
  [ ! -f "$BATS_TEST_TMPDIR/gh.args" ] || fail "gh was called anyway"
}

@test "an unset PRS_JSON is an error, not a silent skip" {
  unset PRS_JSON
  run bash "$SCRIPT"
  [ "$status" -ne 0 ] || fail "exited 0 with no PRs"
  contains "$output" "::error::" || fail "output: $output"
  [ ! -f "$BATS_TEST_TMPDIR/gh.args" ] || fail "gh was called anyway"
}

@test "invalid JSON in PRS_JSON is an error" {
  PRS_JSON='not json' run bash "$SCRIPT"
  [ "$status" -ne 0 ] || fail "exited 0 with invalid JSON"
  contains "$output" "::error::" || fail "output: $output"
  [ ! -f "$BATS_TEST_TMPDIR/gh.args" ] || fail "gh was called anyway"
}

@test "PRS_JSON that is valid JSON but not an array is an error" {
  PRS_JSON='{"headBranchName":"x"}' run bash "$SCRIPT"
  [ "$status" -ne 0 ] || fail "exited 0 with a non-array"
  contains "$output" "::error::" || fail "output: $output"
  [ ! -f "$BATS_TEST_TMPDIR/gh.args" ] || fail "gh was called anyway"
}

@test "an empty array in PRS_JSON is an error" {
  PRS_JSON='[]' run bash "$SCRIPT"
  [ "$status" -ne 0 ] || fail "exited 0 with an empty array"
  contains "$output" "::error::" || fail "output: $output"
  contains "$output" "empty array" || fail "output: $output"
  [ ! -f "$BATS_TEST_TMPDIR/gh.args" ] || fail "gh was called anyway"
}

@test "a PR without headBranchName is an error naming the missing field, before any dispatch" {
  PRS_JSON='[{"headBranchName":"release-please--branches--main--components--shared-workflows"},{"number":41}]' \
    run bash "$SCRIPT"
  [ "$status" -ne 0 ] || fail "exited 0 without a branch"
  contains "$output" "headBranchName" || fail "output: $output"
  contains "$output" '"number":41' || fail "output does not echo the offending element: $output"
  [ ! -f "$BATS_TEST_TMPDIR/gh.args" ] || fail "gh was called anyway (validation must happen before any dispatch)"
}

@test "a failed dispatch on one PR does not stop the remaining PRs from being dispatched" {
  # A fake gh that fails when --ref names the first branch, and otherwise
  # behaves like the standard fake (records its args and exits 0).
  cat > "$bin/gh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" >> "$BATS_TEST_TMPDIR/gh.args"
prev=""
for a in "\$@"; do
  if [ "\$prev" = "--ref" ] && [ "\$a" = "release-please--branches--main--components--shared-workflows" ]; then
    exit 1
  fi
  prev="\$a"
done
exit 0
EOF
  chmod +x "$bin/gh"

  PRS_JSON='[{"headBranchName":"release-please--branches--main--components--shared-workflows","number":40},{"headBranchName":"release-please--branches--main--components--dev-config","number":41}]' \
    run bash "$SCRIPT"
  [ "$status" -ne 0 ] || fail "exited 0 despite a failed dispatch"
  contains "$output" "::error::" || fail "output: $output"
  contains "$output" "could not dispatch self-ci.yml on release-please--branches--main--components--shared-workflows" \
    || fail "output: $output"
  args="$(tr '\n' ' ' < "$BATS_TEST_TMPDIR/gh.args")"
  contains "$args" "--ref release-please--branches--main--components--shared-workflows" || fail "args: $args"
  contains "$args" "--ref release-please--branches--main--components--dev-config" || fail "args: $args"
}

@test "fails without GH_REPO" {
  unset GH_REPO
  PRS_JSON='[{"headBranchName":"x"}]' run bash "$SCRIPT"
  [ "$status" -ne 0 ] || fail "exited 0 without GH_REPO"
  contains "$output" "GH_REPO" || fail "output: $output"
}

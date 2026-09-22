#!/usr/bin/env bats
# Every assertion ends in `|| fail "..."` - see test_helper.bash.
#
# fingerprint.sh produces the two hashes that scripts/ota/fingerprint-gate.sh
# later compares against the channel's baseline. The gate has five tests; the
# thing feeding it had none.
#
# That asymmetry is the risk: the gate is the guard standing between an OTA
# update and a crash on launch for every user on a channel, and it can only be
# as good as its inputs. A fingerprint that is wrong, empty, or silently the
# same for both platforms makes the gate pass on a mismatched native build
# without anything looking broken.

load test_helper

SCRIPT="$REPO_ROOT/scripts/release/fingerprint.sh"

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
  STUB="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$STUB"
}

# A fake `npx` standing in for the consumer's @expo/fingerprint bin. It answers
# with whatever the test put in $WORKFLOWS_TEST_FP_<PLATFORM>.
fake_npx() {
  cat > "$STUB/npx" <<'SH'
#!/usr/bin/env bash
platform=""
for a in "$@"; do
  case "$prev" in --platform) platform="$a" ;; esac
  prev="$a"
done
case "$platform" in
  ios) printf '%s\n' "${WORKFLOWS_TEST_FP_IOS:-}" ;;
  android) printf '%s\n' "${WORKFLOWS_TEST_FP_ANDROID:-}" ;;
esac
[ -n "${WORKFLOWS_TEST_FP_FAIL:-}" ] && exit 1
exit 0
SH
  chmod +x "$STUB/npx"
  export PATH="$STUB:$PATH"
}

@test "both platforms are published, to outputs and to the environment" {
  fake_npx
  WORKFLOWS_TEST_FP_IOS='{"hash":"iosaaa111"}' WORKFLOWS_TEST_FP_ANDROID='{"hash":"andbbb222"}' \
    run bash "$SCRIPT"
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  run cat "$GITHUB_OUTPUT"
  contains "$output" "fp-ios=iosaaa111" || fail "$output"
  contains "$output" "fp-android=andbbb222" || fail "$output"
  run cat "$GITHUB_ENV"
  contains "$output" "FINGERPRINT_IOS=iosaaa111" || fail "$output"
  contains "$output" "FINGERPRINT_ANDROID=andbbb222" || fail "$output"
}

@test "the two platforms do not get each other's hash" {
  # A crossed pair passes the gate on the wrong comparison, which is worse than
  # a wrong value: it looks exactly like a correct run.
  fake_npx
  WORKFLOWS_TEST_FP_IOS='{"hash":"iosaaa111"}' WORKFLOWS_TEST_FP_ANDROID='{"hash":"andbbb222"}' \
    bash "$SCRIPT"
  run cat "$GITHUB_OUTPUT"
  not_contains "$output" "fp-ios=andbbb222" || fail "iOS got Android's hash: $output"
  not_contains "$output" "fp-android=iosaaa111" || fail "Android got iOS's hash: $output"
}

@test "a bare-hash output from an older fingerprint CLI is still read" {
  fake_npx
  WORKFLOWS_TEST_FP_IOS='iosplain111' WORKFLOWS_TEST_FP_ANDROID='andplain222' run bash "$SCRIPT"
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  run cat "$GITHUB_OUTPUT"
  contains "$output" "fp-ios=iosplain111" || fail "$output"
}

@test "an empty hash is fatal rather than an empty fingerprint" {
  # The gate treats a build-info.json with no fingerprint block as a failure.
  # Publishing an empty string here would sail past that and compare "" to "".
  fake_npx
  WORKFLOWS_TEST_FP_IOS='{"hash":""}' WORKFLOWS_TEST_FP_ANDROID='{"hash":"andbbb222"}' \
    run bash "$SCRIPT"
  [ "$status" -ne 0 ] || fail "an empty hash must not be published: $output"
  run cat "$GITHUB_OUTPUT"
  not_contains "$output" "fp-ios=" || fail "it published an empty iOS fingerprint: $output"
}

@test "a failing fingerprint CLI is fatal, and asks about the devDependency" {
  fake_npx
  WORKFLOWS_TEST_FP_FAIL=1 WORKFLOWS_TEST_FP_IOS='' run bash "$SCRIPT"
  [ "$status" -ne 0 ] || fail "must not continue without a fingerprint: $output"
  contains "$output" "fingerprint" || fail "$output"
}

@test "a precomputed fingerprint short-circuits the CLI entirely" {
  # expo-prepare passes the value down rather than paying for a second run -
  # which can differ, because fingerprint input includes node_modules.
  cat > "$STUB/npx" <<'SH'
#!/usr/bin/env bash
printf 'the CLI should not have run\n' >&2
exit 1
SH
  chmod +x "$STUB/npx"
  PATH="$STUB:$PATH" WORKFLOWS_FINGERPRINT_IOS=preios WORKFLOWS_FINGERPRINT_ANDROID=preand \
    run bash "$SCRIPT"
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  run cat "$GITHUB_OUTPUT"
  contains "$output" "fp-ios=preios" || fail "$output"
  contains "$output" "fp-android=preand" || fail "$output"
}

@test "what this publishes is what the OTA gate reads" {
  # The chain is fingerprint.sh -> FINGERPRINT_IOS/ANDROID -> build-info.sh's
  # `fingerprint: {ios, android}` -> the gate's `.fingerprint.<platform>`.
  # It is wired by name at every hop, so a rename anywhere turns the gate into
  # a comparison of two empty strings - which passes.
  run grep -cE '\.fingerprint\.\$platform' "$REPO_ROOT/scripts/ota/fingerprint-gate.sh"
  [ "$output" -gt 0 ] || fail "the gate no longer reads .fingerprint.<platform> from the baseline"

  run grep -cE 'process\.env\.FINGERPRINT_IOS' "$REPO_ROOT/scripts/release/build-info.sh"
  [ "$output" -gt 0 ] || fail "build-info.sh no longer reads FINGERPRINT_IOS"
  run grep -cE 'process\.env\.FINGERPRINT_ANDROID' "$REPO_ROOT/scripts/release/build-info.sh"
  [ "$output" -gt 0 ] || fail "build-info.sh no longer reads FINGERPRINT_ANDROID"

  # And the record it writes is keyed the way the gate looks it up.
  run grep -cE '^\s+fingerprint: \{' "$REPO_ROOT/scripts/release/build-info.sh"
  [ "$output" -gt 0 ] || fail "build-info.sh no longer writes a fingerprint block"
}

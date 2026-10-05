#!/usr/bin/env bats
load test_helper

@test "emits hash and formatted cache keys" {
  unset GITHUB_OUTPUT
  RUNNER_OS=Linux RUNNER_ARCH=X64 NATIVE_CACHE_VERSION=v1 XCODE='' \
    run bash "$REPO_ROOT/scripts/ci/native-keys.sh" "$FIXTURES/consumer"
  [ "$status" -eq 0 ]
  hash=$(bash "$REPO_ROOT/scripts/ci/native-hash.sh" "$FIXTURES/consumer")
  [[ "$output" == *"hash=$hash"* ]] || fail "assertion failed; output: $output"
  [[ "$output" == *"ios-key=ios-app-v1-Linux-X64-xcodedefault-$hash"* ]] || fail "assertion failed; output: $output"
  [[ "$output" == *"android-key=android-apk-v1-$hash"* ]] || fail "assertion failed; output: $output"
  [[ "$output" == *"pods-key=pods-v1-Linux-xcodedefault-$hash"* ]] || fail "assertion failed; output: $output"
  printf '%s\n' "$output" | grep -qx 'pods-restore-key=pods-v1-Linux-xcodedefault-' || fail "assertion failed; output: $output"
}

@test "explicit xcode input and a different version/os/arch fold into the ios key" {
  unset GITHUB_OUTPUT
  RUNNER_OS=macOS RUNNER_ARCH=ARM64 NATIVE_CACHE_VERSION=v2 XCODE=16.1 \
    run bash "$REPO_ROOT/scripts/ci/native-keys.sh" "$FIXTURES/consumer"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ios-key=ios-app-v2-macOS-ARM64-xcode16.1-"* ]] || fail "assertion failed; output: $output"
  [[ "$output" == *"pods-key=pods-v2-macOS-xcode16.1-"* ]] || fail "assertion failed; output: $output"
}

@test "defaults NATIVE_CACHE_VERSION to v1 when unset" {
  unset GITHUB_OUTPUT NATIVE_CACHE_VERSION
  RUNNER_OS=Linux RUNNER_ARCH=X64 XCODE='' \
    run bash "$REPO_ROOT/scripts/ci/native-keys.sh" "$FIXTURES/consumer"
  [ "$status" -eq 0 ]
  [[ "$output" == *"android-key=android-apk-v1-"* ]] || fail "assertion failed; output: $output"
}

@test "writes to GITHUB_OUTPUT when set" {
  out="$BATS_TEST_TMPDIR/gh_output"
  : > "$out"
  GITHUB_OUTPUT="$out" RUNNER_OS=Linux RUNNER_ARCH=X64 NATIVE_CACHE_VERSION=v1 XCODE='' \
    run bash "$REPO_ROOT/scripts/ci/native-keys.sh" "$FIXTURES/consumer"
  [ "$status" -eq 0 ]
  grep -q '^hash=' "$out"
  grep -q '^ios-key=ios-app-v1-Linux-X64-xcodedefault-' "$out"
  grep -q '^android-key=android-apk-v1-' "$out"
  grep -q '^pods-key=pods-v1-Linux-xcodedefault-' "$out"
  grep -qx 'pods-restore-key=pods-v1-Linux-xcodedefault-' "$out"
}

# The iOS .app embeds EXPO_PUBLIC_* at bundle time. Without this the E2E job
# restores an .app built against a different API URL and the change that set it
# looks like it did nothing.
@test "environment-variables folds into the ios key and leaves the other keys alone" {
  unset GITHUB_OUTPUT
  RUNNER_OS=macOS RUNNER_ARCH=ARM64 NATIVE_CACHE_VERSION=v1 XCODE='' \
    BUILD_ENV='{"EXPO_PUBLIC_API_URL":"http://localhost:8082/graphql"}' \
    run bash "$REPO_ROOT/scripts/ci/native-keys.sh" "$FIXTURES/consumer"
  [ "$status" -eq 0 ]
  hash=$(bash "$REPO_ROOT/scripts/ci/native-hash.sh" "$FIXTURES/consumer")
  [[ "$output" =~ ios-key=ios-app-v1-macOS-ARM64-xcodedefault-$hash-env[0-9a-f]{8} ]] || fail "assertion failed; output: $output"
  [[ "$output" == *"android-key=android-apk-v1-$hash"* ]] || fail "assertion failed; output: $output"
  [[ "$output" == *"pods-key=pods-v1-macOS-xcodedefault-$hash"* ]] || fail "assertion failed; output: $output"
}

@test "a different environment-variables value produces a different ios key" {
  unset GITHUB_OUTPUT
  key_for() {
    RUNNER_OS=macOS RUNNER_ARCH=ARM64 XCODE='' BUILD_ENV="$1" \
      bash "$REPO_ROOT/scripts/ci/native-keys.sh" "$FIXTURES/consumer" |
      grep '^ios-key='
  }
  a=$(key_for '{"EXPO_PUBLIC_API_URL":"http://localhost:8082/graphql"}')
  b=$(key_for '{"EXPO_PUBLIC_API_URL":"https://api.example.com/graphql"}')
  [ "$a" != "$b" ] || fail "both values produced $a"
}

# Consumers that never pass environment-variables must keep the keys they already have.
@test "an empty or {} environment-variables leaves the ios key byte-identical" {
  unset GITHUB_OUTPUT
  key_for() {
    RUNNER_OS=macOS RUNNER_ARCH=ARM64 XCODE='' BUILD_ENV="$1" \
      bash "$REPO_ROOT/scripts/ci/native-keys.sh" "$FIXTURES/consumer" |
      grep '^ios-key='
  }
  base=$(RUNNER_OS=macOS RUNNER_ARCH=ARM64 XCODE='' \
    bash "$REPO_ROOT/scripts/ci/native-keys.sh" "$FIXTURES/consumer" | grep '^ios-key=')
  [ "$(key_for '')" = "$base" ] || fail "empty environment-variables changed the key"
  [ "$(key_for '{}')" = "$base" ] || fail "{} environment-variables changed the key"
}

# The bump is documented as invalidating every native cache at once. The Pods
# key used to carry neither the version nor Xcode, and its restore prefix
# `pods-{os}-` matched every older entry, so a bump restored the old Pods anyway.
@test "a cache-version or Xcode bump moves both the Pods key and its restore prefix" {
  unset GITHUB_OUTPUT
  pods_for() {
    RUNNER_OS=macOS RUNNER_ARCH=ARM64 NATIVE_CACHE_VERSION="$1" XCODE="$2" \
      bash "$REPO_ROOT/scripts/ci/native-keys.sh" "$FIXTURES/consumer" | grep '^pods-'
  }
  base="$(pods_for v1 16.4)"
  for other in "$(pods_for v2 16.4)" "$(pods_for v1 26.0)"; do
    key_a="$(printf '%s\n' "$base" | grep '^pods-key=')"
    key_b="$(printf '%s\n' "$other" | grep '^pods-key=')"
    prefix_a="$(printf '%s\n' "$base" | grep '^pods-restore-key=')"
    prefix_b="$(printf '%s\n' "$other" | grep '^pods-restore-key=')"
    [ "$key_a" != "$key_b" ] || fail "the Pods key did not move: $key_a"
    [ "$prefix_a" != "$prefix_b" ] || fail "the Pods restore prefix did not move: $prefix_a"
    # The old key must not start with the new prefix, or restore-keys would bring it back.
    case "${key_a#pods-key=}" in "${prefix_b#pods-restore-key=}"*) fail "the new prefix still restores the old key: $prefix_b" ;; esac
  done
}

@test "the Pods key starts with its own restore prefix, so a prefix hit is possible" {
  unset GITHUB_OUTPUT
  run env RUNNER_OS=macOS RUNNER_ARCH=ARM64 NATIVE_CACHE_VERSION=v1 XCODE=16.4 \
    bash "$REPO_ROOT/scripts/ci/native-keys.sh" "$FIXTURES/consumer"
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  key="$(printf '%s\n' "$output" | sed -n 's/^pods-key=//p')"
  prefix="$(printf '%s\n' "$output" | sed -n 's/^pods-restore-key=//p')"
  [ -n "$prefix" ] || fail "no pods-restore-key: $output"
  case "$key" in "$prefix"*) ;; *) fail "key $key does not start with prefix $prefix" ;; esac
}

#!/usr/bin/env bats
load test_helper
# The resolver names its rule on stderr; stdout is the hash alone.
@test "hash is 16 hex chars and stable" {
  run bash -c "bash '$REPO_ROOT/scripts/ci/native-hash.sh' '$FIXTURES/consumer' 2>/dev/null"; [ "$status" -eq 0 ]; [[ "$output" =~ ^[0-9a-f]{16}$ ]] || fail "assertion failed; output: $output"
  first="$output"; run bash -c "bash '$REPO_ROOT/scripts/ci/native-hash.sh' '$FIXTURES/consumer' 2>/dev/null"; [ "$output" = "$first" ] || fail "not stable: $output"
}
@test "hash changes when a native dep version changes but not for a jest bump" {
  cp -R "$FIXTURES/consumer" "$BATS_TEST_TMPDIR/c"
  base=$(bash "$REPO_ROOT/scripts/ci/native-hash.sh" "$BATS_TEST_TMPDIR/c")
  sed -i.bak "258s/\^30\.5\.1/^30.5.2/" "$BATS_TEST_TMPDIR/c/pnpm-lock.yaml"   # jest specifier bump keeps hash
  [ "$(bash "$REPO_ROOT/scripts/ci/native-hash.sh" "$BATS_TEST_TMPDIR/c")" = "$base" ]
  sed -i.bak "129s/57\.0\.20(f4e16336c3bbb067508522a18420e9a2)/57.0.21(f4e16336c3bbb067508522a18420e9a2)/" "$BATS_TEST_TMPDIR/c/pnpm-lock.yaml"   # expo version bump changes hash
  [ "$(bash "$REPO_ROOT/scripts/ci/native-hash.sh" "$BATS_TEST_TMPDIR/c")" != "$base" ]
}
@test "NATIVE_EXTRA_GLOBS folds in the contents of the matched files, not just the pattern" {
  cp -R "$FIXTURES/consumer" "$BATS_TEST_TMPDIR/c"
  mkdir -p "$BATS_TEST_TMPDIR/c/fastlane"
  printf 'lane :one\n' > "$BATS_TEST_TMPDIR/c/fastlane/Fastfile.rb"
  base=$(bash "$REPO_ROOT/scripts/ci/native-hash.sh" "$BATS_TEST_TMPDIR/c")
  with_glob=$(NATIVE_EXTRA_GLOBS='fastlane/*.rb' bash "$REPO_ROOT/scripts/ci/native-hash.sh" "$BATS_TEST_TMPDIR/c")
  [ "$with_glob" != "$base" ]
  printf 'lane :two\n' > "$BATS_TEST_TMPDIR/c/fastlane/Fastfile.rb"
  changed=$(NATIVE_EXTRA_GLOBS='fastlane/*.rb' bash "$REPO_ROOT/scripts/ci/native-hash.sh" "$BATS_TEST_TMPDIR/c")
  [ "$changed" != "$with_glob" ]
}
@test "NATIVE_EXTRA_GLOBS matching nothing is not an error" {
  run env NATIVE_EXTRA_GLOBS='nowhere/*.rb other/*' bash -c "bash '$REPO_ROOT/scripts/ci/native-hash.sh' '$FIXTURES/consumer' 2>/dev/null"
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^[0-9a-f]{16}$ ]] || fail "assertion failed; output: $output"
}

# --- the bare native stack ----------------------------------------------------
#
# A bare app's ios/ and android/ are committed build input, so an edit to them
# must move the cache key; an Expo app's keys must stay exactly what they were.

# A git checkout of the bare fixture to edit freely.
bare_copy() {
  cp -R "$FIXTURES/consumer-bare" "$BATS_TEST_TMPDIR/b"
  git -C "$BATS_TEST_TMPDIR/b" init -q
  git -C "$BATS_TEST_TMPDIR/b" add -A
}

hash_of() { bash "$REPO_ROOT/scripts/ci/native-hash.sh" "$1" 2>/dev/null; }

@test "a bare app's hash moves with an edit to a tracked file under ios/ or android/" {
  bare_copy
  base="$(hash_of "$BATS_TEST_TMPDIR/b")"
  [[ "$base" =~ ^[0-9a-f]{16}$ ]] || fail "not a hash: $base"
  printf '# a pod\n' >> "$BATS_TEST_TMPDIR/b/ios/Podfile"
  ios="$(hash_of "$BATS_TEST_TMPDIR/b")"
  [ "$ios" != "$base" ] || fail "a Podfile edit kept the cache key"
  printf '// a change\n' >> "$BATS_TEST_TMPDIR/b/android/app/build.gradle"
  [ "$(hash_of "$BATS_TEST_TMPDIR/b")" != "$ios" ] || fail "a build.gradle edit kept the cache key"
}

@test "a bare app's untracked build output does not move it, and a deleted tracked file does" {
  bare_copy
  base="$(hash_of "$BATS_TEST_TMPDIR/b")"
  mkdir -p "$BATS_TEST_TMPDIR/b/ios/Pods"
  printf 'generated\n' > "$BATS_TEST_TMPDIR/b/ios/Pods/Manifest.lock"
  [ "$(hash_of "$BATS_TEST_TMPDIR/b")" = "$base" ] || fail "ignored build output moved the key"
  rm "$BATS_TEST_TMPDIR/b/ios/Podfile"
  run bash "$REPO_ROOT/scripts/ci/native-hash.sh" "$BATS_TEST_TMPDIR/b"
  [ "$status" -eq 0 ] || fail "a deleted tracked file failed the hash: $output"
  [ "$(hash_of "$BATS_TEST_TMPDIR/b")" != "$base" ] || fail "a deletion kept the key"
}

@test "an Expo app's hash ignores ios/ and android/, so its keys stay what they were" {
  cp -R "$FIXTURES/consumer" "$BATS_TEST_TMPDIR/e"
  base="$(hash_of "$BATS_TEST_TMPDIR/e")"
  mkdir -p "$BATS_TEST_TMPDIR/e/ios"
  printf 'prebuild output\n' > "$BATS_TEST_TMPDIR/e/ios/Podfile"
  [ "$(hash_of "$BATS_TEST_TMPDIR/e")" = "$base" ] || fail "prebuild output moved an Expo app's key"
}

@test "a bare app with no committed native files hashes exactly as before" {
  cp -R "$FIXTURES/consumer" "$BATS_TEST_TMPDIR/e"
  git -C "$BATS_TEST_TMPDIR/e" init -q
  expo="$(hash_of "$BATS_TEST_TMPDIR/e")"
  [ "$(WORKFLOWS_NATIVE_STACK_INPUT=bare hash_of "$BATS_TEST_TMPDIR/e")" = "$expo" ] || fail "an empty native list changed the key"
}

@test "the stack it hashes for is the one the input names, and an invalid one fails" {
  bare_copy
  bare="$(hash_of "$BATS_TEST_TMPDIR/b")"
  [ "$(WORKFLOWS_NATIVE_STACK_INPUT=expo hash_of "$BATS_TEST_TMPDIR/b")" != "$bare" ] || fail "the input did not decide"
  WORKFLOWS_NATIVE_STACK_INPUT=rn run bash "$REPO_ROOT/scripts/ci/native-hash.sh" "$BATS_TEST_TMPDIR/b"
  [ "$status" -ne 0 ] || fail "accepted rn: $output"
  contains "$output" "could not resolve the native stack of" || fail "output: $output"
}

@test "a bare app outside a git checkout cannot list its native files, and says so" {
  cp -R "$FIXTURES/consumer-bare" "$BATS_TEST_TMPDIR/b"
  WORKFLOWS_NATIVE_STACK_INPUT=bare run bash "$REPO_ROOT/scripts/ci/native-hash.sh" "$BATS_TEST_TMPDIR/b"
  [ "$status" -ne 0 ] || fail "hashed without git: $output"
  contains "$output" "git could not list ios/ and android/" || fail "output: $output"
}

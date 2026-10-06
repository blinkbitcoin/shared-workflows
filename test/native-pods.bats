#!/usr/bin/env bats
# Every assertion ends in `|| fail "..."` - see test_helper.bash.
#
# scripts/native/pods.sh: `pod install` in the consumer's ios/, through bundler
# when the consumer has a Gemfile and bundler is installed, else the bare pod -
# and run again, three times in all, when it fails.
load test_helper

setup() {
  export GITHUB_WORKSPACE="$BATS_TEST_TMPDIR/app" WORKING_DIRECTORY=.
  export WORKFLOWS_OUT="$BATS_TEST_TMPDIR/out"
  mkdir -p "$GITHUB_WORKSPACE/ios"
  bin="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$bin"
  CALLS="$BATS_TEST_TMPDIR/calls"
  export CALLS
  : > "$CALLS"
  # The retries run without their 20-second wait.
  export WORKFLOWS_RETRY_DELAY_SECONDS=0
  for tool in pod bundle; do
    cat > "$bin/$tool" <<STUB
#!/usr/bin/env bash
printf '%s %s | stats=%s\n' "$tool" "\$*" "\${COCOAPODS_DISABLE_STATS:-}" >> "\$CALLS"
[ "\${POD_STATUS:-0}" -eq 0 ] || exit "\$POD_STATUS"
# The first POD_FAIL_FIRST calls fail with status 1, as a network blip would.
[ "\$(wc -l < "\$CALLS")" -gt "\${POD_FAIL_FIRST:-0}" ] || exit 1
printf 'PODS:\n  - A\n  - B\n  - C\n  - D\n  - E\n  - F\n' > Podfile.lock
STUB
    chmod +x "$bin/$tool"
  done
  export PATH="$bin:/usr/bin:/bin"
}

@test "runs pod install through bundler when there is a Gemfile and bundler" {
  touch "$GITHUB_WORKSPACE/Gemfile"
  run bash "$REPO_ROOT/scripts/native/pods.sh"
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  [ "$(cat "$CALLS")" = "bundle exec pod install | stats=1" ] || fail "calls: $(cat "$CALLS")"
  contains "$output" "Podfile.lock (first 5 lines):" || fail "output: $output"
  contains "$output" "  - D" || fail "the lockfile head was not shown: $output"
  not_contains "$output" "  - E" || fail "showed more than 5 lines: $output"
}

@test "runs the bare pod without a Gemfile" {
  run bash "$REPO_ROOT/scripts/native/pods.sh"
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  [ "$(cat "$CALLS")" = "pod install | stats=1" ] || fail "calls: $(cat "$CALLS")"
}

@test "runs the bare pod when there is a Gemfile but no bundler" {
  touch "$GITHUB_WORKSPACE/Gemfile"
  rm "$bin/bundle"
  run bash "$REPO_ROOT/scripts/native/pods.sh"
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  [ "$(cat "$CALLS")" = "pod install | stats=1" ] || fail "calls: $(cat "$CALLS")"
}

@test "without ios/ it names the step that makes it" {
  rmdir "$GITHUB_WORKSPACE/ios"
  run bash "$REPO_ROOT/scripts/native/pods.sh"
  [ "$status" -ne 0 ] || fail "ran without ios/: $output"
  contains "$output" "run prebuild.sh ios first" || fail "output: $output"
  [ ! -s "$CALLS" ] || fail "ran anyway: $(cat "$CALLS")"
}

@test "without bundler or pod, the missing pod is named" {
  rm "$bin/bundle" "$bin/pod"
  run bash "$REPO_ROOT/scripts/native/pods.sh"
  [ "$status" -ne 0 ] || fail "ran without pod: $output"
  contains "$output" "missing command: pod" || fail "output: $output"
}

@test "a pod install that fails every time fails the script after three attempts, with its status" {
  POD_STATUS=5 run bash "$REPO_ROOT/scripts/native/pods.sh"
  [ "$status" -eq 5 ] || fail "expected 5, got $status: $output"
  [ "$(wc -l < "$CALLS")" -eq 3 ] || fail "expected three attempts: $(cat "$CALLS")"
  contains "$output" "attempt 3 of 3 failed with exit status 5: pod - giving up" || fail "output: $output"
}

@test "a pod install that fails once is run again, and the script succeeds" {
  POD_FAIL_FIRST=1 run bash "$REPO_ROOT/scripts/native/pods.sh"
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  [ "$(cat "$CALLS")" = "$(printf 'pod install | stats=1\npod install | stats=1')" ] || fail "calls: $(cat "$CALLS")"
  contains "$output" "attempt 1 of 3 failed with exit status 1: pod - retrying in 0s" || fail "output: $output"
}

@test "a bundled pod install that fails once is run again through bundler" {
  touch "$GITHUB_WORKSPACE/Gemfile"
  POD_FAIL_FIRST=1 run bash "$REPO_ROOT/scripts/native/pods.sh"
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  [ "$(cat "$CALLS")" = "$(printf 'bundle exec pod install | stats=1\nbundle exec pod install | stats=1')" ] || fail "calls: $(cat "$CALLS")"
}

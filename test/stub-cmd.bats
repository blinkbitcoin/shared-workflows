#!/usr/bin/env bats
# Every assertion ends in `|| fail "..."` - see test_helper.bash.
#
# stub_cmd, stub_calls and stub_log in test_helper.bash: the fake commands the
# suite runs scripts against. Covered: a fake that only records, one with a
# body (output and exit status), one whose body comes from stdin, several calls
# to one fake, two fakes at once, a fake that replaces an earlier one, and the
# fakes coming first on PATH, once each, under this test's own directory.
load test_helper

@test "a fake with no body records its arguments and exits 0 silently" {
  stub_cmd gh
  run gh release view "v1.2.3" --json tagName
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  [ -z "$output" ] || fail "printed: $output"
  [ "$(stub_calls gh)" = "release view v1.2.3 --json tagName" ] || fail "recorded: $(stub_calls gh)"
}

@test "a body sets the fake's output and exit status, and sees the call's arguments" {
  stub_cmd curl 'printf "fetched %s\n" "$2"; exit 7'
  run curl -fsSL https://example.test/file
  [ "$status" -eq 7 ] || fail "exited $status: $output"
  [ "$output" = "fetched https://example.test/file" ] || fail "output: $output"
}

@test "a body of - is read from stdin" {
  stub_cmd pnpm - <<'SH'
if [ "$1" = store ]; then printf '/store\n'; exit 0; fi
printf 'unexpected pnpm %s\n' "$*" >&2
exit 2
SH
  run pnpm store path
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  [ "$output" = "/store" ] || fail "output: $output"
  run pnpm install
  [ "$status" -eq 2 ] || fail "exited $status: $output"
  contains "$output" "unexpected pnpm install" || fail "output: $output"
}

@test "every call is recorded, oldest first, even the ones that fail" {
  stub_cmd git 'exit "${FAKE_GIT_STATUS:-0}"'
  git fetch origin
  FAKE_GIT_STATUS=1 run git push origin main
  [ "$status" -eq 1 ] || fail "exited $status"
  git tag v1
  [ "$(stub_calls git)" = "fetch origin
push origin main
tag v1" ] || fail "recorded: $(stub_calls git)"
}

@test "two fakes at once keep separate logs" {
  stub_cmd sudo 'exit 99'
  stub_cmd udevadm
  udevadm trigger --name-match=kvm
  run sudo true
  [ "$status" -eq 99 ] || fail "exited $status"
  [ "$(stub_calls udevadm)" = "trigger --name-match=kvm" ] || fail "udevadm recorded: $(stub_calls udevadm)"
  [ "$(stub_calls sudo)" = "true" ] || fail "sudo recorded: $(stub_calls sudo)"
}

@test "a fake reaches a script run as a child process" {
  stub_cmd yq 'printf "from the fake\n"'
  run bash -c 'yq --version'
  [ "$output" = "from the fake" ] || fail "the child did not run the fake: $output"
  [ "$(stub_calls yq)" = "--version" ] || fail "recorded: $(stub_calls yq)"
}

@test "stubbing a name again replaces the fake and keeps its log" {
  stub_cmd java 'printf "first\n"'
  java -version
  stub_cmd java 'printf "second\n"'
  run java -jar x.jar
  [ "$output" = "second" ] || fail "the fake was not replaced: $output"
  [ "$(stub_calls java)" = "-version
-jar x.jar" ] || fail "recorded: $(stub_calls java)"
}

@test "a fake that was never called has an empty log, at the path stub_log names" {
  stub_cmd shasum
  [ "$(stub_log shasum)" = "$BATS_TEST_TMPDIR/stub-calls/shasum.log" ] || fail "log: $(stub_log shasum)"
  [ -f "$(stub_log shasum)" ] || fail "no log file before the first call"
  [ -z "$(stub_calls shasum)" ] || fail "recorded: $(stub_calls shasum)"
}

@test "the fakes live under this test's directory, first on PATH, added once" {
  stub_cmd one
  stub_cmd two
  [ "${PATH%%:*}" = "$BATS_TEST_TMPDIR/stub-bin" ] || fail "not first on PATH: $PATH"
  count="$(printf '%s\n' "$PATH" | tr ':' '\n' | grep -cxF "$BATS_TEST_TMPDIR/stub-bin")"
  [ "$count" -eq 1 ] || fail "on PATH $count times: $PATH"
  [ "$(command -v one)" = "$BATS_TEST_TMPDIR/stub-bin/one" ] || fail "resolved to $(command -v one)"
}

@test "an argument with spaces or quotes reaches the body intact" {
  stub_cmd echoer 'printf "<%s>" "$@"'
  run echoer "a b" "it's"
  [ "$output" = "<a b><it's>" ] || fail "output: $output"
}

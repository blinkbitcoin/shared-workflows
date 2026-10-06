#!/usr/bin/env bats
load test_helper
setup() { source "$REPO_ROOT/scripts/lib/common.sh"; }
@test "gh_output appends key=value to GITHUB_OUTPUT" {
  GITHUB_OUTPUT="$BATS_TEST_TMPDIR/out"; export GITHUB_OUTPUT
  gh_output hash abc123
  run cat "$GITHUB_OUTPUT"; [ "$output" = "hash=abc123" ]
}
@test "gh_output prints to stdout when GITHUB_OUTPUT is unset" {
  unset GITHUB_OUTPUT
  run gh_output hash abc123; [ "$output" = "hash=abc123" ]
}
@test "die exits 1 with an ::error annotation" {
  run die "boom"; [ "$status" -eq 1 ]; [[ "$output" == *"::error::boom"* ]] || fail "assertion failed; output: $output"
}
@test "die_fix carries the remediation and the contract in one annotation" {
  run die_fix "no mise config in /repo" "add a .mise.toml" "60-second-start"
  [ "$status" -eq 1 ] || fail "die_fix must exit 1; status: $status"
  # One annotation, not three: a second ::error:: would detach from the step.
  [ "$(printf '%s\n' "$output" | grep -c '::error::')" -eq 1 ] || fail "expected one annotation: $output"
  contains "$output" "no mise config in /repo" || fail "$output"
  contains "$output" "%0AFix: add a .mise.toml" || fail "the fix is not on its own line: $output"
  contains "$output" "consumer-guide.md#60-second-start" || fail "no contract link: $output"
}
@test "die_fix without an anchor links the guide itself, not a dangling #" {
  run die_fix "something" "do the thing"
  contains "$output" "Contract: https://github.com/blinkbitcoin/shared-workflows/blob/v0/docs/consumer-guide.md" || fail "expected a guide link: $output"
  not_contains "$output" "consumer-guide.md#" || fail "an empty anchor leaked: $output"
}
@test "die_fix escapes a percent sign so it cannot eat the line breaks" {
  # The annotation encoding is percent-based. Escaping %25 after inserting the
  # %0A newlines would turn each of them into a literal "%0A" in the log.
  run die_fix "coverage fell to 90% of the threshold" "raise it"
  contains "$output" "90%25 of the threshold" || fail "$output"
  contains "$output" "%0AFix: raise it" || fail "the newlines did not survive: $output"
}
# A probe for wait_until: fails until it has been called $1 times, counting its
# calls in a file so the count survives however wait_until runs it.
succeeds_on_try() {
  local tries
  printf 'try\n' >> "$BATS_TEST_TMPDIR/tries"
  tries="$(wc -l < "$BATS_TEST_TMPDIR/tries" | tr -d ' ')"
  [ "$tries" -ge "$1" ]
}
tries() { wc -l < "$BATS_TEST_TMPDIR/tries" | tr -d ' '; }
@test "wait_until returns at once when the command succeeds on the first try" {
  wait_until 30 1 succeeds_on_try 1 || fail "wait_until failed on a command that succeeded"
  [ "$(tries)" -eq 1 ] || fail "ran the command $(tries) times"
  [ "$wait_until_elapsed" -le 1 ] || fail "slept before returning: ${wait_until_elapsed}s"
}
@test "wait_until tries again every INTERVAL until the command succeeds, and reports the real time" {
  wait_until 30 1 succeeds_on_try 3 || fail "wait_until gave up on a command that succeeded on try 3"
  [ "$(tries)" -eq 3 ] || fail "ran the command $(tries) times"
  # Two 1s intervals went by; a busy machine may add to that, never take away.
  [ "$wait_until_elapsed" -ge 2 ] || fail "reported ${wait_until_elapsed}s for two intervals"
}
@test "wait_until gives up once SECONDS of real time have passed, not after a count of tries" {
  # Each try costs 1s of its own on top of the 1s interval. A count of
  # SECONDS/INTERVAL tries would wait 6s; the clock stops it at about 3.
  slow_failure() { sleep 1; return 1; }
  if wait_until 3 1 slow_failure; then fail "wait_until succeeded on a command that never did"; fi
  [ "$wait_until_elapsed" -ge 3 ] || fail "gave up before the deadline: ${wait_until_elapsed}s"
  [ "$wait_until_elapsed" -lt 6 ] || fail "waited a count of tries, not the deadline: ${wait_until_elapsed}s"
}
@test "wait_until never sleeps past the deadline when INTERVAL is longer than what is left" {
  if wait_until 2 30 succeeds_on_try 99; then fail "wait_until succeeded on a command that never did"; fi
  [ "$(tries)" -eq 2 ] || fail "expected a try at the start and one at the deadline, ran $(tries)"
  [ "$wait_until_elapsed" -lt 30 ] || fail "slept a whole interval past a 2s deadline: ${wait_until_elapsed}s"
}
@test "wait_until with SECONDS 0 tries exactly once" {
  if wait_until 0 1 succeeds_on_try 99; then fail "wait_until succeeded on a command that never did"; fi
  [ "$(tries)" -eq 1 ] || fail "ran the command $(tries) times"
}
@test "wait_until runs the command in the caller's shell, so a probe can stop the script" {
  run bash -c '
    source "$1/scripts/lib/common.sh"
    gone() { die "the server exited"; }
    wait_until 30 1 gone
    echo "carried on"
  ' _ "$REPO_ROOT"
  [ "$status" -eq 1 ] || fail "a probe that died did not stop the script: $status $output"
  contains "$output" "::error::the server exited" || fail "output: $output"
  not_contains "$output" "carried on" || fail "the script carried on: $output"
}
@test "wait_until refuses a SECONDS or INTERVAL that is not a whole number, a zero INTERVAL and no command" {
  run wait_until soon 1 true
  [ "$status" -eq 1 ] || fail "accepted SECONDS soon: $output"
  contains "$output" "wait_until: SECONDS must be a whole number, got 'soon'" || fail "output: $output"
  run wait_until 5 '' true
  [ "$status" -eq 1 ] || fail "accepted an empty INTERVAL: $output"
  contains "$output" "wait_until: INTERVAL must be a whole number, got ''" || fail "output: $output"
  run wait_until 5 0 true
  [ "$status" -eq 1 ] || fail "accepted INTERVAL 0: $output"
  contains "$output" "wait_until: INTERVAL must be at least 1 second" || fail "output: $output"
  run wait_until 5 1
  [ "$status" -eq 1 ] || fail "accepted no command: $output"
  contains "$output" "wait_until: no command to run" || fail "output: $output"
}
@test "gh_env_once appends key=value once, even called twice with the same GITHUB_ENV" {
  GITHUB_ENV="$BATS_TEST_TMPDIR/env"; export GITHUB_ENV
  : > "$GITHUB_ENV"
  gh_env_once WORKFLOWS_OUT /tmp/out
  gh_env_once WORKFLOWS_OUT /tmp/out
  [ "$(grep -c '^WORKFLOWS_OUT=' "$GITHUB_ENV")" -eq 1 ]
  grep -qxF "WORKFLOWS_OUT=/tmp/out" "$GITHUB_ENV"
}
@test "gh_env_once exports the variable even when GITHUB_ENV is unset" {
  unset GITHUB_ENV
  gh_env_once FOO bar
  [ "$FOO" = "bar" ]
}
@test "gh_env writes the plain form for a plain value and exports it" {
  GITHUB_ENV="$BATS_TEST_TMPDIR/env"; export GITHUB_ENV
  : > "$GITHUB_ENV"
  gh_env WORKFLOWS_SHA deadbeef
  grep -qx 'WORKFLOWS_SHA=deadbeef' "$GITHUB_ENV" || fail "not the plain form: $(cat "$GITHUB_ENV")"
  [ "$WORKFLOWS_SHA" = "deadbeef" ] || fail "gh_env did not export the value"
}
@test "gh_env routes a newline-bearing value through the heredoc form" {
  GITHUB_ENV="$BATS_TEST_TMPDIR/env"; export GITHUB_ENV
  : > "$GITHUB_ENV"
  gh_env NOTES "$(printf 'one\ntwo')"
  head -1 "$GITHUB_ENV" | grep -q '^NOTES<<__workflows_eof_' || fail "not the heredoc form: $(cat "$GITHUB_ENV")"
  delim="$(head -1 "$GITHUB_ENV" | sed 's/^NOTES<<//')"
  [ "$(tail -1 "$GITHUB_ENV")" = "$delim" ] || fail "the block is not closed with its delimiter: $(cat "$GITHUB_ENV")"
  [ "$NOTES" = "$(printf 'one\ntwo')" ] || fail "gh_env did not export the value intact"
}
@test "gh_env_multiline refuses a value carrying its own delimiter" {
  GITHUB_ENV="$BATS_TEST_TMPDIR/env"; export GITHUB_ENV
  : > "$GITHUB_ENV"
  # Seeding RANDOM makes the generated delimiter reproducible *within one
  # process* (bash re-seeds it in a subshell), which is the only way a value can
  # be crafted to contain it - so the whole case runs inside one `bash -c`.
  run bash -c '
    source "$1/scripts/lib/common.sh"
    RANDOM=42; delim="__workflows_eof_${RANDOM}${RANDOM}"
    RANDOM=42; gh_env_multiline NOTES "before
$delim
after"
  ' _ "$REPO_ROOT"
  [ "$status" -ne 0 ] || fail "accepted a value containing the delimiter"
  contains "$output" "heredoc delimiter" || fail "unexpected message: $output"
}
@test "gh_output_multiline appends the heredoc form to GITHUB_OUTPUT, and exports nothing" {
  GITHUB_OUTPUT="$BATS_TEST_TMPDIR/out"; export GITHUB_OUTPUT
  : > "$GITHUB_OUTPUT"
  gh_output_multiline section "$(printf 'one\nsecond=line')"
  head -1 "$GITHUB_OUTPUT" | grep -q '^section<<__workflows_eof_[0-9]*$' || fail "not the heredoc form: $(cat "$GITHUB_OUTPUT")"
  delim="$(head -1 "$GITHUB_OUTPUT" | sed 's/^section<<//')"
  [ "$(sed -n 2,3p "$GITHUB_OUTPUT")" = "$(printf 'one\nsecond=line')" ] || fail "the value is not intact: $(cat "$GITHUB_OUTPUT")"
  [ "$(tail -1 "$GITHUB_OUTPUT")" = "$delim" ] || fail "the block is not closed with its delimiter: $(cat "$GITHUB_OUTPUT")"
  [ "$(wc -l < "$GITHUB_OUTPUT" | tr -d ' ')" -eq 4 ] || fail "extra lines: $(cat "$GITHUB_OUTPUT")"
  [ -z "${section:-}" ] || fail "an output leaked into the environment"
}
@test "gh_output_multiline prints the heredoc form to stdout when GITHUB_OUTPUT is unset" {
  unset GITHUB_OUTPUT
  run gh_output_multiline section "$(printf 'one\ntwo')"
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  [ "${lines[1]}" = "one" ] || fail "the value is not on stdout: $output"
  [ "${lines[2]}" = "two" ] || fail "the value is not on stdout: $output"
  [ "${lines[0]}" = "section<<${lines[3]}" ] || fail "not a closed heredoc record: $output"
}
@test "gh_output_multiline refuses a value carrying its own delimiter" {
  GITHUB_OUTPUT="$BATS_TEST_TMPDIR/out"; export GITHUB_OUTPUT
  : > "$GITHUB_OUTPUT"
  # Same seeding as the gh_env_multiline case above, for the same reason.
  run bash -c '
    source "$1/scripts/lib/common.sh"
    RANDOM=42; delim="__workflows_eof_${RANDOM}${RANDOM}"
    RANDOM=42; gh_output_multiline section "before
$delim
after"
  ' _ "$REPO_ROOT"
  [ "$status" -ne 0 ] || fail "accepted a value containing the delimiter"
  contains "$output" "heredoc delimiter" || fail "unexpected message: $output"
  contains "$output" '$GITHUB_OUTPUT' || fail "the message names the wrong channel: $output"
  [ ! -s "$GITHUB_OUTPUT" ] || fail "something was written anyway: $(cat "$GITHUB_OUTPUT")"
}
@test "consumer_root honours WORKING_DIRECTORY" {
  GITHUB_WORKSPACE="$BATS_TEST_TMPDIR"; WORKING_DIRECTORY=app; export GITHUB_WORKSPACE WORKING_DIRECTORY
  mkdir -p "$BATS_TEST_TMPDIR/app"
  expected="$(cd "$BATS_TEST_TMPDIR/app" && pwd -P)"
  run consumer_root; [ "$output" = "$expected" ]
}

# --- gh_ref_exists -------------------------------------------------------
#
# `gh` is faked with the answers the real one gives (gh 2.x): the SHA on stdout
# for a ref that exists; for any HTTP error exit 1, the error body on stdout
# (even under --jq) and "gh: <message> (HTTP <status>)" on stderr.

fake_gh() {
  local bin="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$bin"
  cat > "$bin/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$WORKFLOWS_TEST_CALLS"
http_error() {
  printf '{"message":"%s","status":"%s"}\n' "$2" "$1"
  printf 'gh: %s (HTTP %s)\n' "$2" "$1" >&2
  exit 1
}
case "$WORKFLOWS_TEST_ANSWER" in
  exists) printf 'cafe1234\n' ;;
  empty) exit 0 ;;
  404) http_error 404 "Not Found" ;;
  401) http_error 401 "Bad credentials" ;;
  403) http_error 403 "API rate limit exceeded for installation" ;;
  500) http_error 500 "Server Error" ;;
  network) printf 'error connecting to api.github.com\ncheck your internet connection\n' >&2; exit 1 ;;
  silent) exit 4 ;;
esac
SH
  chmod +x "$bin/gh"
  PATH="$bin:$PATH"
  WORKFLOWS_TEST_CALLS="$BATS_TEST_TMPDIR/calls"
  : > "$WORKFLOWS_TEST_CALLS"
  WORKFLOWS_TEST_ANSWER="$1"
  GH_REPO=acme/app
  export PATH WORKFLOWS_TEST_CALLS WORKFLOWS_TEST_ANSWER GH_REPO
}

@test "gh_ref_exists is true for a ref GitHub returns, and leaves its commit in gh_ref_sha" {
  fake_gh exists
  gh_ref_exists tags/v1.2.3 || fail "an existing ref read as absent"
  [ "$gh_ref_sha" = cafe1234 ] || fail "gh_ref_sha is '$gh_ref_sha', not the ref's commit"
  run cat "$WORKFLOWS_TEST_CALLS"
  [ "$output" = "api repos/acme/app/git/ref/tags/v1.2.3 --jq .object.sha" ] || fail "wrong lookup: $output"
}

@test "gh_ref_exists is false only for a 404, and leaves no error body in gh_ref_sha" {
  fake_gh 404
  gh_ref_sha=stale
  rc=0
  gh_ref_exists tags/v1.2.3 || rc=$?
  [ "$rc" -eq 1 ] || fail "a 404 must return 1, returned $rc"
  [ -z "$gh_ref_sha" ] || fail "gh_ref_sha kept '$gh_ref_sha' for a missing ref"
}

@test "gh_ref_exists dies on bad credentials, naming the ref, the repository and gh's answer" {
  fake_gh 401
  run gh_ref_exists tags/v1.2.3
  [ "$status" -eq 1 ] || fail "a 401 must be fatal; status: $status"
  [ "$(printf '%s\n' "$output" | grep -c '::error::')" -eq 1 ] || fail "expected one annotation: $output"
  contains "$output" "tags/v1.2.3" || fail "does not name the ref: $output"
  contains "$output" "acme/app" || fail "does not name the repository: $output"
  contains "$output" "Bad credentials (HTTP 401)" || fail "does not carry gh's answer: $output"
  contains "$output" "GH_TOKEN" || fail "no hint about the token: $output"
}

@test "gh_ref_exists dies on a rate limit, not reading it as absent" {
  fake_gh 403
  run gh_ref_exists tags/v1.2.3
  [ "$status" -eq 1 ] || fail "a 403 must be fatal; status: $status"
  contains "$output" "API rate limit exceeded" || fail "$output"
}

@test "gh_ref_exists dies on a server error" {
  fake_gh 500
  run gh_ref_exists tags/v1.2.3
  [ "$status" -eq 1 ] || fail "a 500 must be fatal; status: $status"
  contains "$output" "Server Error (HTTP 500)" || fail "$output"
  contains "$output" "re-run" || fail "no hint to re-run: $output"
}

@test "gh_ref_exists dies when GitHub cannot be reached, keeping the message on one line" {
  fake_gh network
  run gh_ref_exists tags/v1.2.3
  [ "$status" -eq 1 ] || fail "a network failure must be fatal; status: $status"
  contains "$output" "error connecting to api.github.com check your internet connection" \
    || fail "the message is not joined onto the annotation's line: $output"
}

@test "gh_ref_exists dies on a failure gh gives no message for, saying so" {
  fake_gh silent
  run gh_ref_exists tags/v1.2.3
  [ "$status" -eq 1 ] || fail "a silent failure must be fatal; status: $status"
  contains "$output" "gh api exited 4 with no message" || fail "$output"
}

@test "gh_ref_exists dies on a success that carries no commit" {
  fake_gh empty
  run gh_ref_exists tags/v1.2.3
  [ "$status" -eq 1 ] || fail "an empty answer must be fatal; status: $status"
  contains "$output" "without the commit it points at" || fail "$output"
}

@test "gh_ref_exists needs GH_REPO, and asks GitHub nothing without it" {
  fake_gh exists
  GH_REPO=""
  run gh_ref_exists tags/v1.2.3
  [ "$status" -ne 0 ] || fail "an empty GH_REPO must be refused"
  contains "$output" "GH_REPO not set" || fail "$output"
  [ ! -s "$WORKFLOWS_TEST_CALLS" ] || fail "gh was called: $(cat "$WORKFLOWS_TEST_CALLS")"
}

# package_json_has: present 0, absent 1, no package.json 1, a broken one dies.
@test "package_json_has finds a script, in the directory named or the current one" {
  printf '{"scripts":{"check:lint":"eslint ."}}\n' > "$BATS_TEST_TMPDIR/package.json"
  run package_json_has scripts check:lint "$BATS_TEST_TMPDIR"
  [ "$status" -eq 0 ] || fail "a present script must return 0; status $status: $output"
  cd "$BATS_TEST_TMPDIR"
  run package_json_has scripts check:lint
  [ "$status" -eq 0 ] || fail "the default directory is the current one; status $status: $output"
}
@test "package_json_has returns 1 for an absent, empty or inherited entry, and with no section" {
  printf '{"scripts":{"other":"x","empty":""},"dependencies":["expo"]}\n' > "$BATS_TEST_TMPDIR/package.json"
  for name in check:lint empty constructor toString; do
    run package_json_has scripts "$name" "$BATS_TEST_TMPDIR"
    [ "$status" -eq 1 ] || fail "$name must read as absent; status $status: $output"
    [ -z "$output" ] || fail "absent must be silent: $output"
  done
  run package_json_has devDependencies expo "$BATS_TEST_TMPDIR"
  [ "$status" -eq 1 ] || fail "a missing section must return 1; status $status: $output"
  run package_json_has dependencies expo "$BATS_TEST_TMPDIR"
  [ "$status" -eq 1 ] || fail "a section that is not an object must return 1; status $status: $output"
}
@test "package_json_has looks in each of the comma-separated sections, and only those" {
  printf '{"devDependencies":{"expo":"^55"}}\n' > "$BATS_TEST_TMPDIR/package.json"
  run package_json_has dependencies,devDependencies expo "$BATS_TEST_TMPDIR"
  [ "$status" -eq 0 ] || fail "the second section was not searched; status $status: $output"
  run package_json_has dependencies expo "$BATS_TEST_TMPDIR"
  [ "$status" -eq 1 ] || fail "a section not named was searched; status $status: $output"
}
@test "package_json_has returns 1 when there is no package.json at all" {
  run package_json_has scripts check:lint "$BATS_TEST_TMPDIR/empty-directory"
  [ "$status" -eq 1 ] || fail "no package.json must read as absent; status $status: $output"
  [ -z "$output" ] || fail "absent must be silent: $output"
}
@test "package_json_has dies naming the file and the parse error for a package.json that does not parse" {
  printf '{"scripts":{"check:lint":"eslint ."},}\n' > "$BATS_TEST_TMPDIR/package.json"
  run package_json_has scripts check:lint "$BATS_TEST_TMPDIR"
  [ "$status" -eq 1 ] || fail "a broken package.json must die; status $status: $output"
  contains "$output" "::error::$BATS_TEST_TMPDIR/package.json is not valid JSON: " || fail "no file or cause: $output"
  contains "$output" 'names "check:lint" under scripts' || fail "the probe is not named: $output"
  [ "${#lines[@]}" -eq 1 ] || fail "the annotation spans lines: $output"
}
@test "package_json_has dies for a package.json that is not an object, or cannot be read" {
  printf 'null\n' > "$BATS_TEST_TMPDIR/package.json"
  run package_json_has scripts x "$BATS_TEST_TMPDIR"
  [ "$status" -eq 1 ] || fail "null must die; status $status: $output"
  contains "$output" "::error::$BATS_TEST_TMPDIR/package.json is not a JSON object" || fail "output: $output"
  printf '["scripts"]\n' > "$BATS_TEST_TMPDIR/package.json"
  run package_json_has scripts x "$BATS_TEST_TMPDIR"
  [ "$status" -eq 1 ] || fail "an array must die; status $status: $output"
  contains "$output" "is not a JSON object" || fail "output: $output"
  mkdir -p "$BATS_TEST_TMPDIR/directory/package.json"
  run package_json_has scripts x "$BATS_TEST_TMPDIR/directory"
  [ "$status" -eq 1 ] || fail "an unreadable package.json must die; status $status: $output"
  contains "$output" "::error::$BATS_TEST_TMPDIR/directory/package.json could not be read: " || fail "output: $output"
}
@test "package_json_has dies when node itself fails, rather than reading it as absent" {
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  printf '#!/usr/bin/env bash\nexit 7\n' > "$BATS_TEST_TMPDIR/bin/node"
  chmod +x "$BATS_TEST_TMPDIR/bin/node"
  PATH="$BATS_TEST_TMPDIR/bin:$PATH" run package_json_has scripts x "$BATS_TEST_TMPDIR"
  [ "$status" -eq 1 ] || fail "a failed node must die; status $status: $output"
  contains "$output" "::error::package_json_has: node exited 7 reading $BATS_TEST_TMPDIR/package.json" || fail "output: $output"
}
@test "package_json_has dies in the calling shell, so an if around it cannot swallow a broken file" {
  printf '{' > "$BATS_TEST_TMPDIR/package.json"
  run bash -c 'set -euo pipefail; source "$1/scripts/lib/common.sh"
    if package_json_has scripts x "$2"; then echo present; else echo absent; fi' _ "$REPO_ROOT" "$BATS_TEST_TMPDIR"
  [ "$status" -eq 1 ] || fail "the die did not stop the caller; status $status: $output"
  not_contains "$output" "absent" || fail "a broken file read as absent: $output"
}
@test "package_json_has takes the name as data, never as code" {
  printf '{"scripts":{"a\\"b`$(touch pwned)":"x"}}\n' > "$BATS_TEST_TMPDIR/package.json"
  cd "$BATS_TEST_TMPDIR"
  run package_json_has scripts 'a"b`$(touch pwned)' "$BATS_TEST_TMPDIR"
  [ "$status" -eq 0 ] || fail "a name with quotes was not found; status $status: $output"
  [ ! -e "$BATS_TEST_TMPDIR/pwned" ] || fail "the name was evaluated"
}
@test "require_env returns quietly when every variable is set" {
  WORKFLOWS_A=one WORKFLOWS_B=two run require_env WORKFLOWS_A "WORKFLOWS_B:a hint"
  [ "$status" -eq 0 ] || fail "set variables were refused: $output"
  [ -z "$output" ] || fail "expected no output: $output"
}
@test "require_env names the one missing variable in an ::error:: annotation" {
  unset WORKFLOWS_A
  WORKFLOWS_B=two run require_env WORKFLOWS_A WORKFLOWS_B
  [ "$status" -eq 1 ] || fail "expected exit 1, got $status: $output"
  [ "$output" = "::error::missing required environment variable: WORKFLOWS_A" ] || fail "unexpected message: $output"
}
@test "require_env names every missing variable at once, each with its hint" {
  unset WORKFLOWS_A WORKFLOWS_C WORKFLOWS_D
  WORKFLOWS_B=two run require_env "WORKFLOWS_A:owner/name" WORKFLOWS_B WORKFLOWS_C "WORKFLOWS_D:the file, e.g. ci.yml: a colon stays"
  [ "$status" -eq 1 ] || fail "expected exit 1, got $status: $output"
  [ "$(printf '%s\n' "$output" | grep -c '::error::')" -eq 1 ] || fail "expected one annotation: $output"
  [ "$output" = "::error::missing required environment variables: WORKFLOWS_A (owner/name), WORKFLOWS_C, WORKFLOWS_D (the file, e.g. ci.yml: a colon stays)" ] ||
    fail "unexpected message: $output"
}
@test "require_env counts a set but empty variable as missing" {
  WORKFLOWS_A="" run require_env WORKFLOWS_A
  [ "$status" -eq 1 ] || fail "an empty variable passed: $output"
  [ "$output" = "::error::missing required environment variable: WORKFLOWS_A" ] || fail "unexpected message: $output"
}
@test "require_env stops a script under set -u, with no unbound-variable error" {
  run env -u WORKFLOWS_A bash -c 'set -euo pipefail; source "$1"; require_env WORKFLOWS_A; echo REACHED' _ "$REPO_ROOT/scripts/lib/common.sh"
  [ "$status" -eq 1 ] || fail "expected exit 1, got $status: $output"
  contains "$output" "::error::missing required environment variable: WORKFLOWS_A" || fail "unexpected message: $output"
  not_contains "$output" "unbound variable" || fail "set -u tripped on the indirect read: $output"
  not_contains "$output" "REACHED" || fail "the script carried on: $output"
}
@test "require_env and require_uint refuse a name that is not an identifier, without evaluating it" {
  run require_env 'A[$(touch "$BATS_TEST_TMPDIR/ran")]'
  [ "$status" -eq 1 ] || fail "expected exit 1, got $status: $output"
  contains "$output" "is not a variable name" || fail "unexpected message: $output"
  [ ! -e "$BATS_TEST_TMPDIR/ran" ] || fail "the name was evaluated"
  run require_uint '1BAD'
  [ "$status" -eq 1 ] || fail "require_uint accepted a bad name: $output"
  contains "$output" "::error::require_env: '1BAD' is not a variable name" || fail "unexpected message: $output"
}
@test "require_uint accepts non-negative integers, zero included" {
  WORKFLOWS_A=0 WORKFLOWS_B=42 run require_uint WORKFLOWS_A WORKFLOWS_B
  [ "$status" -eq 0 ] || fail "valid integers were refused: $output"
  [ -z "$output" ] || fail "expected no output: $output"
}
@test "require_uint refuses an unset variable, naming it" {
  unset WORKFLOWS_A
  run require_uint WORKFLOWS_A
  [ "$status" -eq 1 ] || fail "an unset variable passed: $output"
  [ "$output" = "::error::WORKFLOWS_A must be a non-negative integer (got nothing: unset or empty)" ] || fail "unexpected message: $output"
}
@test "require_uint refuses an empty variable, with its hint" {
  WORKFLOWS_A="" run require_uint "WORKFLOWS_A:the suite bound in minutes"
  [ "$status" -eq 1 ] || fail "an empty variable passed: $output"
  [ "$output" = "::error::WORKFLOWS_A (the suite bound in minutes) must be a non-negative integer (got nothing: unset or empty)" ] || fail "unexpected message: $output"
}
@test "require_uint refuses a negative, a non-numeric and a spaced value, naming each value" {
  local value
  for value in -1 abc '1 2' ' 3' 1.5; do
    WORKFLOWS_A="$value" run require_uint WORKFLOWS_A
    [ "$status" -eq 1 ] || fail "'$value' passed: $output"
    [ "$output" = "::error::WORKFLOWS_A must be a non-negative integer (got '$value')" ] || fail "unexpected message for '$value': $output"
  done
}
@test "require_uint names every bad variable in one annotation" {
  unset WORKFLOWS_C
  WORKFLOWS_A=x WORKFLOWS_B=7 run require_uint WORKFLOWS_A WORKFLOWS_B WORKFLOWS_C
  [ "$status" -eq 1 ] || fail "expected exit 1: $output"
  [ "$output" = "::error::WORKFLOWS_A must be a non-negative integer (got 'x'); WORKFLOWS_C must be a non-negative integer (got nothing: unset or empty)" ] ||
    fail "unexpected message: $output"
}

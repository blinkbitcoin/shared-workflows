#!/usr/bin/env bats
# scripts/security/settings.sh - the bridge from check-security.yml to the
# settings resolver, packages/app-tooling/lib/security-settings.mjs, run over
# the consumer's security-settings.json. Covers every way out of it: the
# defaults when the consumer has no settings file, values from the file, an
# environment override, the outputs on GITHUB_OUTPUT and on stdout without it,
# the consumer found through WORKING_DIRECTORY and the script called by a
# relative path, and each failure - no node, an invalid value, a resolver that
# prints nothing, prints something that is not JSON, or prints JSON that is not
# the settings object - plus the skipped row with no name.
#
# The real resolver answers every case it can produce. The resolver outputs it
# never produces (nothing, not JSON, a nameless job) come from a copy of
# settings.sh with a stand-in resolver where the real one would be.
#
# Every assertion ends in `|| fail "..."` - see test_helper.bash.
load test_helper

setup() {
  # The resolver reads SECURITY_* (SECURITY_SETTINGS_FILE among them) and the
  # script finds the consumer through GITHUB_WORKSPACE and WORKING_DIRECTORY;
  # a value leaking in from the caller's shell would decide the outcome.
  unset CI GITHUB_WORKSPACE WORKING_DIRECTORY
  local name
  for name in $(compgen -e); do
    case "$name" in SECURITY_*) unset "$name" ;; esac
  done
}

# A consumer checkout named $1 whose security-settings.json is read from stdin;
# an empty stdin writes no settings file. Prints its path.
consumer_with_settings() {
  local dir="$BATS_TEST_TMPDIR/$1" body
  mkdir -p "$dir"
  body="$(cat)"
  [ -z "$body" ] || printf '%s\n' "$body" > "$dir/security-settings.json"
  printf '%s' "$dir"
}

# A copy of settings.sh and its library, with a stand-in resolver (read from
# stdin) where packages/app-tooling/lib/security-settings.mjs would be. Prints
# the copy's settings.sh.
layout_with_resolver() {
  local root="$BATS_TEST_TMPDIR/layout"
  mkdir -p "$root/scripts/security" "$root/scripts/lib" "$root/packages/app-tooling/lib"
  cp "$REPO_ROOT/scripts/security/settings.sh" "$root/scripts/security/settings.sh"
  cp "$REPO_ROOT/scripts/lib/common.sh" "$root/scripts/lib/common.sh"
  cat > "$root/packages/app-tooling/lib/security-settings.mjs"
  printf '%s' "$root/scripts/security/settings.sh"
}

# A PATH holding only dirname, which the script needs to find its library, so
# that require_cmd cannot find node.
path_without_node() {
  local bin="$BATS_TEST_TMPDIR/bare-bin"
  mkdir -p "$bin"
  ln -sf "$(command -v dirname)" "$bin/dirname"
  printf '%s' "$bin"
}

@test "settings.sh publishes the defaults when the consumer has no settings file" {
  GITHUB_WORKSPACE="$(consumer_with_settings bare < /dev/null)"
  export GITHUB_WORKSPACE
  export GITHUB_OUTPUT="$BATS_TEST_TMPDIR/outputs"
  run bash "$REPO_ROOT/scripts/security/settings.sh"
  [ "$status" -eq 0 ] || fail "settings.sh failed: $output"
  local want
  want="$(printf '%s\n' enabled=true severity=high fail-on=deterministic \
    dependencies=true code=true policy=true sbom=true bundle=true mobile=true binaries=true \
    review=false review-codebase=false)"
  [ "$(cat "$GITHUB_OUTPUT")" = "$want" ] || fail "the published outputs are not the defaults: $(cat "$GITHUB_OUTPUT")"
  contains "$output" 'security: severity=high' || fail "the outputs were not logged: $output"
}

@test "settings.sh publishes the values in the consumer's security-settings.json" {
  GITHUB_WORKSPACE="$(consumer_with_settings from-file <<'EOF'
{
  "enabled": false,
  "severity": "medium",
  "failOn": ["deterministic", "review"],
  "jobs": { "code": { "enabled": false }, "review": { "enabled": true } }
}
EOF
)"
  export GITHUB_WORKSPACE
  export GITHUB_OUTPUT="$BATS_TEST_TMPDIR/outputs"
  run bash "$REPO_ROOT/scripts/security/settings.sh"
  [ "$status" -eq 0 ] || fail "settings.sh failed: $output"
  local want
  for want in enabled=false severity=medium fail-on=deterministic,review code=false review=true dependencies=true; do
    grep -qxF "$want" "$GITHUB_OUTPUT" || fail "no '$want' among the published outputs: $(cat "$GITHUB_OUTPUT")"
  done
}

@test "settings.sh lets an environment variable win over security-settings.json" {
  GITHUB_WORKSPACE="$(consumer_with_settings env-wins <<'EOF'
{ "severity": "medium", "jobs": { "code": { "enabled": true } } }
EOF
)"
  export GITHUB_WORKSPACE
  export GITHUB_OUTPUT="$BATS_TEST_TMPDIR/outputs"
  export SECURITY_CODE=false SECURITY_SEVERITY=critical
  run bash "$REPO_ROOT/scripts/security/settings.sh"
  [ "$status" -eq 0 ] || fail "settings.sh failed: $output"
  grep -qxF 'code=false' "$GITHUB_OUTPUT" || fail "SECURITY_CODE did not win over the file: $(cat "$GITHUB_OUTPUT")"
  grep -qxF 'severity=critical' "$GITHUB_OUTPUT" || fail "SECURITY_SEVERITY did not win over the file: $(cat "$GITHUB_OUTPUT")"
}

# A typo must never read as "off": the resolver throws, and the step fails
# before anything is published.
@test "settings.sh fails on an invalid value and publishes nothing" {
  GITHUB_WORKSPACE="$(consumer_with_settings invalid < /dev/null)"
  export GITHUB_WORKSPACE
  export GITHUB_OUTPUT="$BATS_TEST_TMPDIR/outputs"
  export SECURITY_CODE=maybe
  run bash "$REPO_ROOT/scripts/security/settings.sh"
  [ "$status" -ne 0 ] || fail "an invalid value was read as a valid answer: $output"
  contains "$output" 'SECURITY_CODE: expected true or false, got "maybe"' \
    || fail "the resolver's own message did not reach the log: $output"
  [ ! -s "$GITHUB_OUTPUT" ] || fail "a failed resolution still published outputs: $(cat "$GITHUB_OUTPUT")"
}

@test "settings.sh fails on an invalid value in security-settings.json" {
  GITHUB_WORKSPACE="$(consumer_with_settings invalid-file <<'EOF'
{ "jobs": { "depz": { "enabled": true } } }
EOF
)"
  export GITHUB_WORKSPACE
  export GITHUB_OUTPUT="$BATS_TEST_TMPDIR/outputs"
  run bash "$REPO_ROOT/scripts/security/settings.sh"
  [ "$status" -ne 0 ] || fail "an unknown job was read as a valid answer: $output"
  contains "$output" 'unknown job jobs.depz' || fail "the resolver's own message did not reach the log: $output"
  [ ! -s "$GITHUB_OUTPUT" ] || fail "a failed resolution still published outputs: $(cat "$GITHUB_OUTPUT")"
}

@test "settings.sh prints the outputs on stdout when there is no GITHUB_OUTPUT" {
  GITHUB_WORKSPACE="$(consumer_with_settings stdout < /dev/null)"
  export GITHUB_WORKSPACE
  run bash "$REPO_ROOT/scripts/security/settings.sh"
  [ "$status" -eq 0 ] || fail "settings.sh failed: $output"
  grep -qxF 'fail-on=deterministic' <<<"$output" || fail "the outputs did not reach stdout: $output"
}

# $0 is relative here, and the script moves into the consumer before running
# the resolver: the resolver's path has to be settled before that move.
@test "settings.sh called by a relative path reads the settings in WORKING_DIRECTORY" {
  local workspace="$BATS_TEST_TMPDIR/workspace"
  mkdir -p "$workspace/app"
  printf '{ "severity": "low" }\n' > "$workspace/app/security-settings.json"
  export GITHUB_WORKSPACE="$workspace" WORKING_DIRECTORY=app
  export GITHUB_OUTPUT="$BATS_TEST_TMPDIR/outputs"
  run bash -c 'cd "$1" && bash scripts/security/settings.sh' _ "$REPO_ROOT"
  [ "$status" -eq 0 ] || fail "settings.sh failed: $output"
  grep -qxF 'severity=low' "$GITHUB_OUTPUT" || fail "the settings in WORKING_DIRECTORY were not read: $(cat "$GITHUB_OUTPUT")"
}

@test "settings.sh fails when node is not on the PATH" {
  GITHUB_WORKSPACE="$(consumer_with_settings no-node < /dev/null)"
  export GITHUB_WORKSPACE
  run env PATH="$(path_without_node)" "$BASH" "$REPO_ROOT/scripts/security/settings.sh"
  [ "$status" -eq 1 ] || fail "expected a hard failure, got $status: $output"
  contains "$output" '::error::missing command: node' || fail "the error does not name node: $output"
}

# Empty output read as "no jobs enabled" would switch the whole gate off in
# silence.
@test "settings.sh treats a resolver that prints nothing as fatal, not as all-off" {
  local script
  script="$(layout_with_resolver <<'EOF'
// prints nothing, exits 0
EOF
)"
  GITHUB_WORKSPACE="$(consumer_with_settings silent < /dev/null)"
  export GITHUB_WORKSPACE
  export GITHUB_OUTPUT="$BATS_TEST_TMPDIR/outputs"
  run bash "$script"
  [ "$status" -eq 1 ] || fail "an empty resolver read as a valid answer: $status / $output"
  contains "$output" 'security-settings.mjs printed nothing' || fail "the error does not name the cause: $output"
  [ ! -s "$GITHUB_OUTPUT" ] || fail "an empty answer still published outputs: $(cat "$GITHUB_OUTPUT")"
}

@test "settings.sh rejects resolver output that is not JSON" {
  local script
  script="$(layout_with_resolver <<'EOF'
console.log('not the settings object at all');
EOF
)"
  GITHUB_WORKSPACE="$(consumer_with_settings broken < /dev/null)"
  export GITHUB_WORKSPACE
  export GITHUB_OUTPUT="$BATS_TEST_TMPDIR/outputs"
  run bash "$script"
  [ "$status" -eq 1 ] || fail "unreadable output was read as a valid answer: $status / $output"
  contains "$output" 'printed something that is not the settings object: not the settings object at all' \
    || fail "the error does not say what was wrong: $output"
  [ ! -s "$GITHUB_OUTPUT" ] || fail "a rejected answer still published outputs: $(cat "$GITHUB_OUTPUT")"
}

@test "settings.sh rejects JSON that lacks the settings fields" {
  local script
  script="$(layout_with_resolver <<'EOF'
console.log(JSON.stringify({ enabled: true }));
EOF
)"
  GITHUB_WORKSPACE="$(consumer_with_settings shapeless < /dev/null)"
  export GITHUB_WORKSPACE
  export GITHUB_OUTPUT="$BATS_TEST_TMPDIR/outputs"
  run bash "$script"
  [ "$status" -eq 1 ] || fail "JSON without failOn or jobs was read as a valid answer: $status / $output"
  contains "$output" 'security-settings.mjs printed something that is not the settings object' \
    || fail "the error does not say what was wrong: $output"
  [ ! -s "$GITHUB_OUTPUT" ] || fail "a rejected answer still published outputs: $(cat "$GITHUB_OUTPUT")"
}

@test "settings.sh publishes no output for a job with an empty name" {
  local script
  script="$(layout_with_resolver <<'EOF'
console.log(
  JSON.stringify({ enabled: true, jobs: { '': true, dependencies: true }, severity: 'high', failOn: [] }),
);
EOF
)"
  GITHUB_WORKSPACE="$(consumer_with_settings unnamed < /dev/null)"
  export GITHUB_WORKSPACE
  export GITHUB_OUTPUT="$BATS_TEST_TMPDIR/outputs"
  run bash "$script"
  [ "$status" -eq 0 ] || fail "settings.sh failed: $output"
  grep -qxF 'dependencies=true' "$GITHUB_OUTPUT" || fail "the named job was not published: $(cat "$GITHUB_OUTPUT")"
  grep -qxF 'fail-on=' "$GITHUB_OUTPUT" || fail "an empty failOn was not published as empty: $(cat "$GITHUB_OUTPUT")"
  [ -z "$(grep '^=' "$GITHUB_OUTPUT" || true)" ] || fail "a nameless row reached the outputs: $(cat "$GITHUB_OUTPUT")"
}

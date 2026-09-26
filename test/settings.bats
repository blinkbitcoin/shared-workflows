#!/usr/bin/env bats
# scripts/security/settings.sh - the bridge from check-security.yml to the
# consumer's own policy resolver, scripts/security/config.mjs. Covers every way
# out of it: the published outputs on success, several fail-on values, a row
# with no name, and each failure - no node, no resolver, a resolver that
# crashes, prints nothing, prints something that is not JSON, or prints JSON
# that is not the settings object. The resolver itself lives in the consumer and
# is never reimplemented here; each test hands in a stand-in.
#
# Every assertion ends in `|| fail "..."` - see test_helper.bash.
load test_helper

# A throwaway consumer checkout. $1 names the directory; the script's body is
# read from stdin so a test can hand it any behaviour, including no output at
# all. Nothing is copied from the template: these are stand-ins for the
# consumer's files, not second copies of them.
consumer_with() {
  local dir="$BATS_TEST_TMPDIR/$1" file="$2"
  mkdir -p "$dir/$(dirname "$file")"
  cat > "$dir/$file"
  printf '%s' "$dir"
}

# A PATH holding only dirname, which the script needs to find its library, so
# that require_cmd cannot find node.
path_without_node() {
  local bin="$BATS_TEST_TMPDIR/bare-bin"
  mkdir -p "$bin"
  ln -sf "$(command -v dirname)" "$bin/dirname"
  printf '%s' "$bin"
}

@test "settings.sh publishes enabled, severity, failOn and one output per job" {
  local consumer
  consumer="$(consumer_with on scripts/security/config.mjs <<'EOF'
console.log(
  JSON.stringify({
    enabled: true,
    jobs: { deps: true, code: false, policy: true },
    severity: 'high',
    failOn: ['deterministic'],
  }),
);
EOF
)"
  export GITHUB_WORKSPACE="$consumer"
  export GITHUB_OUTPUT="$BATS_TEST_TMPDIR/outputs"
  run bash "$REPO_ROOT/scripts/security/settings.sh"
  [ "$status" -eq 0 ] || fail "settings.sh failed: $output"
  local written
  written="$(cat "$GITHUB_OUTPUT")"
  local want
  for want in 'enabled=true' 'severity=high' 'fail-on=deterministic' 'deps=true' 'code=false' 'policy=true'; do
    grep -qxF "$want" <<<"$written" || fail "no '$want' among the published outputs: $written"
  done
}

@test "settings.sh fails by name when the consumer ships no resolver" {
  export GITHUB_WORKSPACE="$BATS_TEST_TMPDIR/bare"
  mkdir -p "$GITHUB_WORKSPACE"
  run bash "$REPO_ROOT/scripts/security/settings.sh"
  [ "$status" -eq 1 ] || fail "expected a hard failure, got $status: $output"
  contains "$output" 'scripts/security/config.mjs' || fail "the error does not name the missing file: $output"
  contains "$output" '::error::' || fail "the failure is not a GitHub annotation: $output"
}

# The failure mode worth a test of its own: config.mjs guards its CLI entry with
# `import.meta.main`, undefined before Node 24. An older node runs the file,
# prints nothing, exits 0 - and empty output read as "no jobs enabled" would
# disable the whole gate in silence.
@test "settings.sh treats a resolver that prints nothing as fatal, not as all-off" {
  local consumer
  consumer="$(consumer_with silent scripts/security/config.mjs <<'EOF'
// prints nothing, exits 0
EOF
)"
  export GITHUB_WORKSPACE="$consumer"
  export GITHUB_OUTPUT="$BATS_TEST_TMPDIR/outputs"
  run bash "$REPO_ROOT/scripts/security/settings.sh"
  [ "$status" -ne 0 ] || fail "an empty resolver read as a valid answer: $output"
  contains "$output" 'Node 24' || fail "the error does not name the cause: $output"
}

@test "settings.sh rejects output that is not the settings object" {
  local consumer
  consumer="$(consumer_with broken scripts/security/config.mjs <<'EOF'
console.log('not the settings object at all');
EOF
)"
  export GITHUB_WORKSPACE="$consumer"
  export GITHUB_OUTPUT="$BATS_TEST_TMPDIR/outputs"
  run bash "$REPO_ROOT/scripts/security/settings.sh"
  [ "$status" -ne 0 ] || fail "unreadable output was read as a valid answer: $output"
  contains "$output" 'not the settings object' || fail "the error does not say what was wrong: $output"
}

@test "settings.sh fails when node is not on the PATH" {
  export GITHUB_WORKSPACE="$BATS_TEST_TMPDIR/no-node"
  mkdir -p "$GITHUB_WORKSPACE"
  run env PATH="$(path_without_node)" "$BASH" "$REPO_ROOT/scripts/security/settings.sh"
  [ "$status" -eq 1 ] || fail "expected a hard failure, got $status: $output"
  contains "$output" '::error::missing command: node' || fail "the error does not name node: $output"
}

@test "settings.sh hands back a crashing resolver's failure and publishes nothing" {
  local consumer
  consumer="$(consumer_with crash scripts/security/config.mjs <<'EOF'
console.error('security-policy.json: unknown job "depz"');
process.exit(2);
EOF
)"
  export GITHUB_WORKSPACE="$consumer"
  export GITHUB_OUTPUT="$BATS_TEST_TMPDIR/outputs"
  run bash "$REPO_ROOT/scripts/security/settings.sh"
  [ "$status" -eq 2 ] || fail "expected the resolver's own exit code 2, got $status: $output"
  contains "$output" 'unknown job "depz"' || fail "the resolver's own message did not reach the log: $output"
  [ ! -s "$GITHUB_OUTPUT" ] || fail "a failed resolution still published outputs: $(cat "$GITHUB_OUTPUT")"
}

@test "settings.sh rejects JSON that lacks the settings fields" {
  local consumer
  consumer="$(consumer_with shapeless scripts/security/config.mjs <<'EOF'
console.log(JSON.stringify({ enabled: true }));
EOF
)"
  export GITHUB_WORKSPACE="$consumer"
  export GITHUB_OUTPUT="$BATS_TEST_TMPDIR/outputs"
  run bash "$REPO_ROOT/scripts/security/settings.sh"
  [ "$status" -eq 1 ] || fail "JSON without failOn or jobs was read as a valid answer: $status / $output"
  contains "$output" '::error::scripts/security/config.mjs printed something that is not the settings object' \
    || fail "the error does not say what was wrong: $output"
  [ ! -s "$GITHUB_OUTPUT" ] || fail "a rejected answer still published outputs: $(cat "$GITHUB_OUTPUT")"
}

@test "settings.sh joins several fail-on values with commas and logs every output" {
  local consumer
  consumer="$(consumer_with several scripts/security/config.mjs <<'EOF'
console.log(
  JSON.stringify({ enabled: false, jobs: {}, severity: 'medium', failOn: ['deterministic', 'llm'] }),
);
EOF
)"
  export GITHUB_WORKSPACE="$consumer"
  export GITHUB_OUTPUT="$BATS_TEST_TMPDIR/outputs"
  run bash "$REPO_ROOT/scripts/security/settings.sh"
  [ "$status" -eq 0 ] || fail "settings.sh failed: $output"
  grep -qxF 'fail-on=deterministic,llm' "$GITHUB_OUTPUT" || fail "fail-on was not comma-joined: $(cat "$GITHUB_OUTPUT")"
  grep -qxF 'enabled=false' "$GITHUB_OUTPUT" || fail "enabled=false was not published: $(cat "$GITHUB_OUTPUT")"
  [ "$(wc -l < "$GITHUB_OUTPUT" | tr -d ' ')" -eq 3 ] || fail "no jobs should mean exactly three outputs: $(cat "$GITHUB_OUTPUT")"
  contains "$output" 'security: severity=medium' || fail "the outputs were not logged: $output"
}

@test "settings.sh publishes no output for a job with an empty name" {
  local consumer
  consumer="$(consumer_with unnamed scripts/security/config.mjs <<'EOF'
console.log(
  JSON.stringify({ enabled: true, jobs: { '': true, deps: true }, severity: 'high', failOn: ['deterministic'] }),
);
EOF
)"
  export GITHUB_WORKSPACE="$consumer"
  export GITHUB_OUTPUT="$BATS_TEST_TMPDIR/outputs"
  run bash "$REPO_ROOT/scripts/security/settings.sh"
  [ "$status" -eq 0 ] || fail "settings.sh failed: $output"
  grep -qxF 'deps=true' "$GITHUB_OUTPUT" || fail "the named job was not published: $(cat "$GITHUB_OUTPUT")"
  [ -z "$(grep '^=' "$GITHUB_OUTPUT" || true)" ] || fail "a nameless row reached the outputs: $(cat "$GITHUB_OUTPUT")"
}

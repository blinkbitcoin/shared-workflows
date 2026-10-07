#!/usr/bin/env bats
load test_helper

setup() {
  consumer="$BATS_TEST_TMPDIR/consumer"
  mkdir -p "$consumer/node_modules/.bin"
  cat > "$consumer/package.json" <<'EOF'
{
  "name": "fixture-consumer",
  "version": "0.0.0",
  "private": true,
  "scripts": {
    "typecheck": "touch typecheck.marker"
  }
}
EOF
  cat > "$consumer/node_modules/.bin/knipfake" <<'EOF'
#!/usr/bin/env bash
touch knipfake.marker
EOF
  as_fakes "$consumer/node_modules/.bin/knipfake"
  export GITHUB_WORKSPACE="$consumer"
}

@test "runs an existing package.json script via pnpm run" {
  run bash "$REPO_ROOT/scripts/checks/run-script.sh" typecheck
  [ "$status" -eq 0 ]
  [ -f "$consumer/typecheck.marker" ]
}

@test "falls back to node_modules/.bin via pnpm exec when no matching script exists" {
  run bash "$REPO_ROOT/scripts/checks/run-script.sh" knipfake
  [ "$status" -eq 0 ]
  [ -f "$consumer/knipfake.marker" ]
}

@test "missing script and no binary dies with an ::error:: annotation" {
  run bash "$REPO_ROOT/scripts/checks/run-script.sh" nonexistent-thing
  [ "$status" -eq 1 ]
  [[ "$output" == *"::error::"* ]] || fail "assertion failed; output: $output"
  [[ "$output" == *"nonexistent-thing"* ]] || fail "assertion failed; output: $output"
}

# A pnpm that records its calls, for the cases below that must show it never ran.
stub_pnpm() {
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "pnpm $*" >> "%s/calls"\n' "$BATS_TEST_TMPDIR" > "$BATS_TEST_TMPDIR/bin/pnpm"
  as_fakes "$BATS_TEST_TMPDIR/bin/pnpm"
  : > "$BATS_TEST_TMPDIR/calls"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}

@test "a package.json with no scripts key falls back to the binary, then names the missing script" {
  stub_pnpm
  printf '{"name":"fixture-consumer"}\n' > "$consumer/package.json"
  run bash "$REPO_ROOT/scripts/checks/run-script.sh" knipfake
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  grep -qx 'pnpm exec knipfake' "$BATS_TEST_TMPDIR/calls" || fail "the binary did not run: $(cat "$BATS_TEST_TMPDIR/calls")"
  run bash "$REPO_ROOT/scripts/checks/run-script.sh" typecheck
  [ "$status" -eq 1 ] || fail "expected exit 1, got $status: $output"
  contains "$output" 'consumer package.json has no "typecheck" script' || fail "output: $output"
}

@test "no package.json at all is the same as no such script, not a crash" {
  stub_pnpm
  rm "$consumer/package.json"
  run bash "$REPO_ROOT/scripts/checks/run-script.sh" knipfake
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  grep -qx 'pnpm exec knipfake' "$BATS_TEST_TMPDIR/calls" || fail "the binary did not run: $(cat "$BATS_TEST_TMPDIR/calls")"
  run bash "$REPO_ROOT/scripts/checks/run-script.sh" typecheck
  [ "$status" -eq 1 ] || fail "expected exit 1, got $status: $output"
  contains "$output" 'consumer package.json has no "typecheck" script' || fail "output: $output"
}

@test "a package.json that does not parse fails naming the file, and runs neither the script nor the binary" {
  # It used to read as "no such script" and fall through to the binary.
  stub_pnpm
  printf '{"scripts":{"knipfake":"true"},}\n' > "$consumer/package.json"
  run bash "$REPO_ROOT/scripts/checks/run-script.sh" knipfake
  [ "$status" -eq 1 ] || fail "expected exit 1, got $status: $output"
  contains "$output" "/consumer/package.json is not valid JSON: " || fail "output: $output"
  contains "$output" "::error::" || fail "not an annotation: $output"
  [ ! -s "$BATS_TEST_TMPDIR/calls" ] || fail "pnpm ran anyway: $(cat "$BATS_TEST_TMPDIR/calls")"
}

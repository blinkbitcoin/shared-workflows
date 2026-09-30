#!/usr/bin/env bats
# scripts/security/bundle.sh - exports the JavaScript bundle with the
# consumer's expo and hands every exported bundle to security-bundle.mjs, which
# writes bundle.sarif. A fake expo on PATH (through SECURITY_EXPO_BIN, or at
# the default node_modules/.bin/expo) stands in for the real export.
#
# Exit paths covered: switched off (a skipped SARIF, 0); an invalid switch
# (1); no dependencies (a skip locally, 1 under CI); an empty platform list (a
# skip); an invalid platform (1); an export that fails (nonzero) or writes no
# bundle (1); and a scan (0), over both platforms, one platform, and .js as
# well as .hbc bundles. An empty CI is unset before expo sees it.
#
# Every assertion ends in `|| fail "..."` - see test_helper.bash.
load test_helper

setup() {
  unset CI GITHUB_WORKSPACE WORKING_DIRECTORY ANDROID_HOME ANDROID_SDK_ROOT
  local var
  for var in $(compgen -e | grep -E '^(SECURITY_|OPENAI_|ANTHROPIC_)' || true); do unset "$var"; done
  # Never the settings file of whatever checkout runs the suite.
  export SECURITY_SETTINGS_FILE="$BATS_TEST_TMPDIR/no-security-settings.json"
  export SECURITY_DIR="$BATS_TEST_TMPDIR/out"
  app="$BATS_TEST_TMPDIR/app"
  mkdir -p "$app"
  cd "$app" || return 1
  bin="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$bin"
  CALLS="$BATS_TEST_TMPDIR/calls"
  export CALLS
  : > "$CALLS"
}

# A fake expo that records its arguments and the CI it saw, then writes one
# bundle per --platform the way `expo export` lays them out. $1 is where to
# put it, $2 the bundle's content, $3 its extension.
fake_expo() {
  local file="$1" content="$2" ext="${3:-hbc}"
  mkdir -p "$(dirname "$file")"
  cat > "$file" <<STUB
#!/usr/bin/env bash
printf 'expo %s\n' "\$*" >> "$CALLS"
printf 'CI=%s\n' "\${CI-unset}" >> "$CALLS"
out=""; platforms=()
while [ \$# -gt 0 ]; do
  case "\$1" in --output-dir) out="\$2" ;; --platform) platforms+=("\$2") ;; esac
  shift
done
for p in "\${platforms[@]}"; do
  mkdir -p "\$out/_expo/static/js/\$p"
  printf '%s' '$content' > "\$out/_expo/static/js/\$p/entry.$ext"
  printf 'not a bundle' > "\$out/_expo/static/js/\$p/entry.map"
done
STUB
  chmod +x "$file"
  printf '%s' "$file"
}

# The text of a SARIF's first notification, and its rule ids, space-joined.
sarif_note() {
  node -e 'const d = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
process.stdout.write((d.runs[0].invocations?.[0]?.toolExecutionNotifications ?? []).map((n) => n.message.text).join("\n"))' "$1"
}
rule_ids() {
  node -e 'const d = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
process.stdout.write(d.runs[0].results.map((r) => r.ruleId).join(" "))' "$1"
}

bundle() { run bash "$REPO_ROOT/scripts/security/bundle.sh"; }

@test "switched off, it writes a skipped SARIF and exits 0" {
  export SECURITY_BUNDLE=false
  bundle
  [ "$status" -eq 0 ] || fail "status $status: $output"
  contains "$(sarif_note "$SECURITY_DIR/bundle.sarif")" 'disabled' || fail "the skip does not say it is disabled"
  [ ! -s "$CALLS" ] || fail "expo ran for a disabled job: $(cat "$CALLS")"
}

@test "a switch that is not a boolean fails the run rather than reading as off" {
  export SECURITY_BUNDLE=maybe
  bundle
  [ "$status" -eq 1 ] || fail "an invalid switch passed with $status: $output"
  contains "$output" 'that fails the run, it does not disable it' || fail "the error does not say so: $output"
  [ ! -e "$SECURITY_DIR/bundle.sarif" ] || fail "an invalid switch still wrote a SARIF"
}

@test "exports every platform and reports what the bundle gives away" {
  export SECURITY_EXPO_BIN
  SECURITY_EXPO_BIN="$(fake_expo "$bin/expo" 'http://plain.example.com')"
  bundle
  [ "$status" -eq 0 ] || fail "status $status: $output"
  contains "$output" 'bundle: scanned 2 bundle(s)' || fail "the log does not count the bundles: $output"
  grep -q '^expo export --platform ios --platform android --output-dir ' "$CALLS" \
    || fail "expo was not asked to export both platforms: $(cat "$CALLS")"
  [ "$(rule_ids "$SECURITY_DIR/bundle.sarif")" = 'MASTG-TEST-0233 MASTG-TEST-0233' ] \
    || fail "expected a cleartext finding per platform: $(rule_ids "$SECURITY_DIR/bundle.sarif")"
}

@test "bundle.platforms narrows the export" {
  export SECURITY_EXPO_BIN SECURITY_BUNDLE_PLATFORMS=android
  SECURITY_EXPO_BIN="$(fake_expo "$bin/expo" 'fine')"
  bundle
  [ "$status" -eq 0 ] || fail "status $status: $output"
  contains "$output" 'scanned 1 bundle(s)' || fail "expected one bundle: $output"
  grep -q '^expo export --platform android --output-dir ' "$CALLS" || fail "expo args: $(cat "$CALLS")"
  [ -z "$(rule_ids "$SECURITY_DIR/bundle.sarif")" ] || fail "a clean bundle has findings"
}

@test "a plain .js bundle is scanned as well as Hermes bytecode" {
  export SECURITY_EXPO_BIN SECURITY_BUNDLE_PLATFORMS=ios
  SECURITY_EXPO_BIN="$(fake_expo "$bin/expo" 'http://plain.example.com' js)"
  bundle
  [ "$status" -eq 0 ] || fail "status $status: $output"
  contains "$output" 'scanned 1 bundle(s)' || fail "the .js bundle (and only it, not the .map) was not scanned: $output"
  [ "$(rule_ids "$SECURITY_DIR/bundle.sarif")" = 'MASTG-TEST-0233' ] || fail "the .js bundle was not read"
}

@test "an empty platform list is a skip, not an empty pass" {
  # In the file: an empty environment twin means unset, not an empty list.
  printf '{"jobs":{"bundle":{"platforms":[]}}}' > "$SECURITY_SETTINGS_FILE"
  export SECURITY_EXPO_BIN
  SECURITY_EXPO_BIN="$(fake_expo "$bin/expo" 'fine')"
  bundle
  [ "$status" -eq 0 ] || fail "status $status: $output"
  contains "$(sarif_note "$SECURITY_DIR/bundle.sarif")" 'bundle.platforms is empty' || fail "the skip gives no reason"
  [ ! -s "$CALLS" ] || fail "expo ran with nothing to export: $(cat "$CALLS")"
}

@test "an unknown platform fails the run" {
  export SECURITY_EXPO_BIN SECURITY_BUNDLE_PLATFORMS=windows
  SECURITY_EXPO_BIN="$(fake_expo "$bin/expo" 'fine')"
  bundle
  [ "$status" -eq 1 ] || fail "an invalid platform passed with $status: $output"
  # The resolver validates every key on every read, so this fails at the
  # switch, before the platforms are ever asked for.
  contains "$output" 'SECURITY_BUNDLE_PLATFORMS: expected entries from ios, android, got "windows"' \
    || fail "the error does not name the setting: $output"
  [ ! -s "$CALLS" ] || fail "expo ran with an invalid platform"
}

@test "an export that wrote no bundle fails the job" {
  printf '#!/usr/bin/env bash\nexit 0\n' > "$bin/expo"
  chmod +x "$bin/expo"
  export SECURITY_EXPO_BIN="$bin/expo"
  bundle
  [ "$status" -eq 1 ] || fail "an empty export passed with $status: $output"
  contains "$output" 'expo export wrote no bundle' || fail "the error does not say so: $output"
}

@test "an export that fails fails the job" {
  printf '#!/usr/bin/env bash\necho "metro: cannot resolve module" >&2\nexit 7\n' > "$bin/expo"
  chmod +x "$bin/expo"
  export SECURITY_EXPO_BIN="$bin/expo"
  bundle
  [ "$status" -ne 0 ] || fail "a failed export passed: $output"
  contains "$output" 'metro: cannot resolve module' || fail "expo's error is not shown: $output"
  [ ! -e "$SECURITY_DIR/bundle.sarif" ] || fail "a failed export still wrote a SARIF"
}

@test "without dependencies it skips locally" {
  export SECURITY_EXPO_BIN="$BATS_TEST_TMPDIR/missing-expo"
  bundle
  [ "$status" -eq 0 ] || fail "status $status: $output"
  contains "$(sarif_note "$SECURITY_DIR/bundle.sarif")" 'dependencies are not installed' || fail "the skip gives no reason"
}

@test "without dependencies it fails under CI" {
  export SECURITY_EXPO_BIN="$BATS_TEST_TMPDIR/missing-expo" CI=true
  bundle
  [ "$status" -eq 1 ] || fail "a missing expo passed under CI with $status: $output"
  contains "$output" 'under CI that is a failure, not a skip' || fail "the error does not say why: $output"
  [ ! -e "$SECURITY_DIR/bundle.sarif" ] || fail "CI wrote a skipped SARIF instead of failing"
}

@test "the consumer's own node_modules/.bin/expo is the default, and an empty CI never reaches it" {
  fake_expo "$app/node_modules/.bin/expo" 'fine' > /dev/null
  export CI=''
  bundle
  [ "$status" -eq 0 ] || fail "status $status: $output"
  grep -q '^expo export ' "$CALLS" || fail "the default expo did not run"
  grep -qx 'CI=unset' "$CALLS" || fail "expo saw an empty CI, which it throws on: $(cat "$CALLS")"
}

@test "under CI the export sees CI" {
  fake_expo "$app/node_modules/.bin/expo" 'fine' > /dev/null
  export CI=true
  bundle
  [ "$status" -eq 0 ] || fail "status $status: $output"
  grep -qx 'CI=true' "$CALLS" || fail "CI was not passed through: $(cat "$CALLS")"
}

#!/usr/bin/env bats
# scripts/security/bundle.sh - exports the JavaScript bundle and hands every
# bundle to security-bundle.mjs, which writes bundle.sarif. On the Expo stack
# the consumer's expo exports it; on the bare stack the consumer's react-native
# bundles each platform. A fake expo (through SECURITY_EXPO_BIN, or at the
# default node_modules/.bin/expo) and a fake react-native (SECURITY_REACT_NATIVE_BIN,
# or node_modules/.bin/react-native) stand in for the real tools.
#
# Exit paths covered, Expo: switched off (a skipped SARIF, 0); an invalid
# switch (1); no dependencies (a skip locally, 1 under CI); an empty platform
# list (a skip); an invalid platform (1); an export that fails (nonzero) or
# writes no bundle (1); and a scan (0), over both platforms, one platform, and
# .js as well as .hbc bundles. An empty CI is unset before expo sees it.
#
# Bare: a scan of both platforms with Hermes (unminified, as a Hermes release
# bundles) and without it (minified), the entry file each platform's build
# uses, no entry file (1), a bundle that fails (nonzero) or writes nothing (1),
# no react-native (a skip locally, 1 under CI), and the default binary. The
# stack itself: detected from package.json, a committed ios/ making an Expo
# dependency bare, NATIVE_STACK either way, and an invalid NATIVE_STACK (1).
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
  unset NATIVE_STACK
  # An Expo app unless a case says otherwise: expo is a dependency and git
  # tracks no ios/.
  printf '{"name":"app","dependencies":{"expo":"~57.0.0"}}\n' > "$app/package.json"
}

# A bare React Native app: no expo dependency, and an entry file.
bare_app() {
  printf '{"name":"app","dependencies":{"react-native":"0.85.0"}}\n' > "$app/package.json"
  printf 'import "./src/app";\n' > "$app/index.js"
}

# A fake react-native that records its arguments, then writes $2 as the bundle
# where --bundle-output says. $1 is where to put it.
fake_react_native() {
  local file="$1" content="$2"
  mkdir -p "$(dirname "$file")"
  cat > "$file" <<STUB
#!/usr/bin/env bash
printf 'react-native %s\n' "\$*" >> "$CALLS"
out=""
while [ \$# -gt 0 ]; do
  case "\$1" in --bundle-output) out="\$2" ;; esac
  shift
done
printf '%s' '$content' > "\$out"
STUB
  as_fakes "$file"
  printf '%s' "$file"
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
  as_fakes "$file"
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
  as_fakes "$bin/expo"
  export SECURITY_EXPO_BIN="$bin/expo"
  bundle
  [ "$status" -eq 1 ] || fail "an empty export passed with $status: $output"
  contains "$output" 'expo export wrote no bundle' || fail "the error does not say so: $output"
}

@test "an export that fails fails the job" {
  printf '#!/usr/bin/env bash\necho "metro: cannot resolve module" >&2\nexit 7\n' > "$bin/expo"
  as_fakes "$bin/expo"
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

# --- the bare stack ---------------------------------------------------------

@test "a bare app bundles each platform with react-native, unminified for Hermes" {
  bare_app
  export SECURITY_REACT_NATIVE_BIN
  SECURITY_REACT_NATIVE_BIN="$(fake_react_native "$bin/react-native" 'http://plain.example.com')"
  bundle
  [ "$status" -eq 0 ] || fail "status $status: $output"
  contains "$output" 'bundle: scanned 2 bundle(s) of the bare stack' || fail "the log does not count the bundles: $output"
  contains "$output" 'native stack: bare (expo is not a dependency in package.json)' || fail "the stack is not logged: $output"
  grep -Eq '^react-native bundle --platform ios --dev false --minify false --entry-file index.js --bundle-output .*/ios/index.ios.bundle --assets-dest .*/ios/assets$' "$CALLS" \
    || fail "the iOS bundle was not made as a Hermes release makes it: $(cat "$CALLS")"
  grep -Eq '^react-native bundle --platform android --dev false --minify false --entry-file index.js --bundle-output .*/android/index.android.bundle ' "$CALLS" \
    || fail "the Android bundle was not made as a Hermes release makes it: $(cat "$CALLS")"
  [ "$(rule_ids "$SECURITY_DIR/bundle.sarif")" = 'MASTG-TEST-0233 MASTG-TEST-0233' ] \
    || fail "expected a cleartext finding per platform: $(rule_ids "$SECURITY_DIR/bundle.sarif")"
}

@test "a bare app without Hermes is bundled minified, as its release is" {
  bare_app
  mkdir -p "$app/android" "$app/ios"
  printf 'org.gradle.jvmargs=-Xmx2048m\nhermesEnabled=false\n' > "$app/android/gradle.properties"
  printf "use_react_native!(\n  :path => config[:reactNativePath],\n  :hermes_enabled => false\n)\n" > "$app/ios/Podfile"
  export SECURITY_REACT_NATIVE_BIN
  SECURITY_REACT_NATIVE_BIN="$(fake_react_native "$bin/react-native" 'fine')"
  bundle
  [ "$status" -eq 0 ] || fail "status $status: $output"
  [ "$(grep -c -- '--dev false --minify true ' "$CALLS")" -eq 2 ] || fail "both platforms should be minified: $(cat "$CALLS")"
  [ -z "$(rule_ids "$SECURITY_DIR/bundle.sarif")" ] || fail "a clean bundle has findings"
}

@test "the Podfile's keyword-argument form switches Hermes off too, for iOS alone" {
  bare_app
  mkdir -p "$app/ios"
  printf 'use_react_native!(hermes_enabled: false)\n' > "$app/ios/Podfile"
  export SECURITY_REACT_NATIVE_BIN
  SECURITY_REACT_NATIVE_BIN="$(fake_react_native "$bin/react-native" 'fine')"
  bundle
  [ "$status" -eq 0 ] || fail "status $status: $output"
  grep -q -- '--platform ios --dev false --minify true ' "$CALLS" || fail "iOS without Hermes was not minified: $(cat "$CALLS")"
  grep -q -- '--platform android --dev false --minify false ' "$CALLS" || fail "Android kept Hermes: $(cat "$CALLS")"
}

@test "each platform bundles its own entry file when it has one, and index.ts stands in for index.js" {
  bare_app
  rm "$app/index.js"
  printf 'export {};\n' > "$app/index.ts"
  printf 'import "./src/ios";\n' > "$app/index.ios.js"
  export SECURITY_REACT_NATIVE_BIN
  SECURITY_REACT_NATIVE_BIN="$(fake_react_native "$bin/react-native" 'fine')"
  bundle
  [ "$status" -eq 0 ] || fail "status $status: $output"
  grep -q -- '--platform ios .* --entry-file index.ios.js ' "$CALLS" || fail "iOS did not use index.ios.js: $(cat "$CALLS")"
  grep -q -- '--platform android .* --entry-file index.ts ' "$CALLS" || fail "Android did not fall back to index.ts: $(cat "$CALLS")"
}

@test "index.tsx is the last entry file a bare app may have" {
  bare_app
  rm "$app/index.js"
  printf 'export {};\n' > "$app/index.tsx"
  export SECURITY_REACT_NATIVE_BIN SECURITY_BUNDLE_PLATFORMS=android
  SECURITY_REACT_NATIVE_BIN="$(fake_react_native "$bin/react-native" 'fine')"
  bundle
  [ "$status" -eq 0 ] || fail "status $status: $output"
  grep -q -- '--entry-file index.tsx ' "$CALLS" || fail "index.tsx was not used: $(cat "$CALLS")"
}

@test "a bare app with no entry file fails, naming the files it looked for" {
  bare_app
  rm "$app/index.js"
  export SECURITY_REACT_NATIVE_BIN
  SECURITY_REACT_NATIVE_BIN="$(fake_react_native "$bin/react-native" 'fine')"
  bundle
  [ "$status" -eq 1 ] || fail "no entry file passed with $status: $output"
  contains "$output" 'no index.ios.js, index.js, index.ts or index.tsx' || fail "the error: $output"
  [ ! -s "$CALLS" ] || fail "react-native ran without an entry file"
}

@test "a react-native bundle that wrote nothing fails the job" {
  bare_app
  printf '#!/usr/bin/env bash\nexit 0\n' > "$bin/react-native"
  as_fakes "$bin/react-native"
  export SECURITY_REACT_NATIVE_BIN="$bin/react-native"
  bundle
  [ "$status" -eq 1 ] || fail "an empty bundle passed with $status: $output"
  contains "$output" 'react-native bundle wrote no ' || fail "the error does not say so: $output"
}

@test "a react-native bundle that fails fails the job" {
  bare_app
  printf '#!/usr/bin/env bash\necho "metro: cannot resolve module" >&2\nexit 7\n' > "$bin/react-native"
  as_fakes "$bin/react-native"
  export SECURITY_REACT_NATIVE_BIN="$bin/react-native"
  bundle
  [ "$status" -ne 0 ] || fail "a failed bundle passed: $output"
  contains "$output" 'metro: cannot resolve module' || fail "the error is not shown: $output"
  [ ! -e "$SECURITY_DIR/bundle.sarif" ] || fail "a failed bundle still wrote a SARIF"
}

@test "a bare app without react-native skips locally and fails under CI" {
  bare_app
  export SECURITY_REACT_NATIVE_BIN="$BATS_TEST_TMPDIR/missing-react-native"
  bundle
  [ "$status" -eq 0 ] || fail "status $status: $output"
  contains "$(sarif_note "$SECURITY_DIR/bundle.sarif")" 'dependencies are not installed' || fail "the skip gives no reason"
  rm "$SECURITY_DIR/bundle.sarif"
  CI=true bundle
  [ "$status" -eq 1 ] || fail "a missing react-native passed under CI with $status: $output"
  contains "$output" 'missing-react-native is missing: the bundle job needs dependencies installed' || fail "the error: $output"
}

@test "a bare app's default react-native is its own node_modules/.bin/react-native" {
  bare_app
  fake_react_native "$app/node_modules/.bin/react-native" 'fine' > /dev/null
  bundle
  [ "$status" -eq 0 ] || fail "status $status: $output"
  [ "$(grep -c '^react-native bundle ' "$CALLS")" -eq 2 ] || fail "the default react-native did not run: $(cat "$CALLS")"
}

@test "an expo dependency with a committed ios/ is bundled as a bare app" {
  mkdir -p "$app/ios"
  : > "$app/ios/Podfile"
  printf 'import "./src/app";\n' > "$app/index.js"
  git -C "$app" init -q
  git -C "$app" add ios/Podfile
  export SECURITY_REACT_NATIVE_BIN SECURITY_EXPO_BIN
  SECURITY_REACT_NATIVE_BIN="$(fake_react_native "$bin/react-native" 'fine')"
  SECURITY_EXPO_BIN="$(fake_expo "$bin/expo" 'fine')"
  bundle
  [ "$status" -eq 0 ] || fail "status $status: $output"
  ! grep -q '^expo ' "$CALLS" || fail "expo exported a bare app: $(cat "$CALLS")"
  grep -q '^react-native bundle ' "$CALLS" || fail "react-native did not bundle: $(cat "$CALLS")"
}

@test "NATIVE_STACK decides over the repository, either way" {
  export SECURITY_REACT_NATIVE_BIN SECURITY_EXPO_BIN
  SECURITY_REACT_NATIVE_BIN="$(fake_react_native "$bin/react-native" 'fine')"
  SECURITY_EXPO_BIN="$(fake_expo "$bin/expo" 'fine')"
  printf 'import "./src/app";\n' > "$app/index.js"
  NATIVE_STACK=bare bundle
  [ "$status" -eq 0 ] || fail "status $status: $output"
  ! grep -q '^expo ' "$CALLS" || fail "native-stack: bare still ran expo: $(cat "$CALLS")"
  : > "$CALLS"
  bare_app
  NATIVE_STACK=expo bundle
  [ "$status" -eq 0 ] || fail "status $status: $output"
  ! grep -q '^react-native ' "$CALLS" || fail "native-stack: expo still ran react-native: $(cat "$CALLS")"
  grep -q '^expo export ' "$CALLS" || fail "native-stack: expo did not export: $(cat "$CALLS")"
}

@test "a NATIVE_STACK that is not a stack fails the run instead of picking one" {
  export NATIVE_STACK=native SECURITY_EXPO_BIN
  SECURITY_EXPO_BIN="$(fake_expo "$bin/expo" 'fine')"
  bundle
  [ "$status" -eq 1 ] || fail "an invalid stack passed with $status: $output"
  contains "$output" '::error::native-stack is "native"' || fail "the resolver's error is not shown: $output"
  contains "$output" 'could not resolve the native stack' || fail "the runner does not say why it stopped: $output"
  [ ! -s "$CALLS" ] || fail "a tool ran on an invalid stack"
  [ ! -e "$SECURITY_DIR/bundle.sarif" ] || fail "an invalid stack still wrote a SARIF"
}

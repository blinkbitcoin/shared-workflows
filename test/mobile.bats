#!/usr/bin/env bats
# scripts/security/mobile.sh - makes a fresh Expo prebuild in a temporary copy
# of the consumer and runs mobsfscan over its android/ and ios/, with the
# consumer's .mobsf when there is one. A fake expo (through SECURITY_EXPO_BIN,
# or at the default node_modules/.bin/expo) and a fake mobsfscan on PATH stand
# in for the real tools and record their calls.
#
# Exit paths covered: switched off (a skipped SARIF, 0); no mobsfscan and no
# dependencies (each a skip locally, 1 under CI); a prebuild that fails
# (nonzero); a mobsfscan that crashes (1, its output shown); a .mobsf mobsfscan
# could not read (1); and a scan (0), with and without a .mobsf, with an
# absolute and a relative expo, and with an empty CI unset before expo sees it.
#
# Every assertion ends in `|| fail "..."` - see test_helper.bash.
load test_helper

setup() {
  unset CI GITHUB_WORKSPACE WORKING_DIRECTORY ANDROID_HOME ANDROID_SDK_ROOT
  local var
  for var in $(compgen -e | grep -E '^(SECURITY_|OPENAI_|ANTHROPIC_)' || true); do unset "$var"; done
  export SECURITY_SETTINGS_FILE="$BATS_TEST_TMPDIR/no-security-settings.json"
  export SECURITY_DIR="$BATS_TEST_TMPDIR/out"
  app="$BATS_TEST_TMPDIR/app"
  mkdir -p "$app/src" "$app/node_modules/some-package" "$app/ios" "$app/android" "$app/.git"
  printf 'export {};\n' > "$app/src/index.ts"
  printf 'stale\n' > "$app/ios/stale-project"
  # The runner moves into the canonical path (consumer_root is pwd -P).
  app="$(cd "$app" && pwd -P)"
  cd "$app" || return 1
  bin="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$bin"
  CALLS="$BATS_TEST_TMPDIR/calls"
  export CALLS
  : > "$CALLS"
  PATH="$bin:$PATH"
  export PATH
}

# A fake expo: records its arguments, where it ran, what it saw of CI and
# APP_VARIANT, and whether the copy has the source, the node_modules link and
# none of the working tree's native projects; then writes android/ and ios/.
fake_expo() {
  local file="${1:-$bin/expo}"
  mkdir -p "$(dirname "$file")"
  cat > "$file" <<STUB
#!/usr/bin/env bash
{
  printf 'expo %s\n' "\$*"
  printf 'expo-cwd %s\n' "\$PWD"
  printf 'expo-env CI=%s APP_VARIANT=%s EXPO_NO_GIT_STATUS=%s\n' "\${CI-unset}" "\${APP_VARIANT-}" "\${EXPO_NO_GIT_STATUS-}"
  [ -f src/index.ts ] && echo 'copy has src'
  [ -L node_modules ] && echo 'copy links node_modules'
  [ -e ios/stale-project ] && echo 'copy has the stale ios'
  [ -e .git ] && echo 'copy has .git'
} >> "$CALLS"
mkdir -p android ios
STUB
  chmod +x "$file"
  printf '%s' "$file"
}

# A fake mobsfscan with $1 as its body; the default records its arguments and
# where it ran, and writes a clean SARIF where -o says.
fake_mobsfscan() {
  local body="${1:-}"
  if [ -z "$body" ]; then
    body='printf "mobsfscan %s\n" "$*" >> "$CALLS"
printf "mobsfscan-cwd %s\n" "$PWD" >> "$CALLS"
while [ $# -gt 0 ]; do [ "$1" = -o ] && printf %s "{\"version\":\"2.1.0\",\"runs\":[{\"tool\":{\"driver\":{\"name\":\"mobsfscan\"}},\"results\":[]}]}" > "$2"; shift; done'
  fi
  printf '#!/usr/bin/env bash\n%s\n' "$body" > "$bin/mobsfscan"
  chmod +x "$bin/mobsfscan"
}

# A PATH with only what the runner needs besides the tool under test, so "the
# tool is missing" is true even on a machine that has it.
bare_path() {
  local dir="$BATS_TEST_TMPDIR/bare" tool found
  mkdir -p "$dir"
  for tool in bash env node mkdir grep dirname basename sed cat find sort head tail mktemp rm rsync ln pwd; do
    found="$(command -v "$tool" || true)"
    [ -z "$found" ] || ln -sf "$found" "$dir/$tool"
  done
  printf '%s' "$dir"
}

sarif_note() {
  node -e 'const d = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
process.stdout.write((d.runs[0].invocations?.[0]?.toolExecutionNotifications ?? []).map((n) => n.message.text).join("\n"))' "$1"
}
driver() {
  node -e 'const d = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
process.stdout.write(d.runs[0].tool.driver.name)' "$1"
}

mobile() { run bash "$REPO_ROOT/scripts/security/mobile.sh"; }

@test "switched off, it writes a skipped SARIF and exits 0" {
  export SECURITY_MOBILE=false
  mobile
  [ "$status" -eq 0 ] || fail "status $status: $output"
  contains "$(sarif_note "$SECURITY_DIR/mobile.sarif")" 'disabled' || fail "the skip does not say it is disabled"
}

@test "prebuilds into a copy and hands mobsfscan the .mobsf by name" {
  printf 'ignore-rules: []\n' > "$app/.mobsf"
  fake_mobsfscan
  export SECURITY_EXPO_BIN
  SECURITY_EXPO_BIN="$(fake_expo)"
  mobile
  [ "$status" -eq 0 ] || fail "status $status: $output"
  contains "$output" "mobile: wrote $SECURITY_DIR/mobile.sarif" || fail "the log does not say where: $output"
  grep -qx 'expo prebuild --platform all --clean --no-install' "$CALLS" || fail "expo args: $(cat "$CALLS")"
  grep -qx 'expo-env CI=unset APP_VARIANT=production EXPO_NO_GIT_STATUS=1' "$CALLS" \
    || fail "the prebuild did not get the release environment: $(cat "$CALLS")"
  grep -qx 'copy has src' "$CALLS" || fail "the copy has no source: $(cat "$CALLS")"
  grep -qx 'copy links node_modules' "$CALLS" || fail "the copy does not link node_modules: $(cat "$CALLS")"
  ! grep -qx 'copy has the stale ios' "$CALLS" || fail "the working tree's own ios/ was copied"
  ! grep -qx 'copy has .git' "$CALLS" || fail ".git was copied"
  grep -qx "mobsfscan --sarif --no-fail -c $app/.mobsf -o $SECURITY_DIR/mobile.sarif android ios" "$CALLS" \
    || fail "mobsfscan args: $(cat "$CALLS")"
  ! grep -qx "mobsfscan-cwd $app" "$CALLS" || fail "mobsfscan scanned the working tree, not the copy"
  [ "$(driver "$SECURITY_DIR/mobile.sarif")" = mobsfscan ] || fail "mobsfscan's SARIF is not the one written"
}

@test "no .mobsf: mobsfscan gets no -c" {
  fake_mobsfscan
  export SECURITY_EXPO_BIN
  SECURITY_EXPO_BIN="$(fake_expo)"
  mobile
  [ "$status" -eq 0 ] || fail "status $status: $output"
  grep -qx "mobsfscan --sarif --no-fail -o $SECURITY_DIR/mobile.sarif android ios" "$CALLS" \
    || fail "mobsfscan args: $(cat "$CALLS")"
}

@test "a relative SECURITY_DIR is resolved before mobsfscan runs in the copy" {
  fake_mobsfscan
  export SECURITY_EXPO_BIN SECURITY_DIR=reports
  SECURITY_EXPO_BIN="$(fake_expo)"
  mobile
  [ "$status" -eq 0 ] || fail "status $status: $output"
  [ -s "$app/reports/mobile.sarif" ] || fail "no SARIF at $app/reports/mobile.sarif"
}

@test "the default expo is the consumer's node_modules/.bin/expo, made absolute for the copy" {
  fake_mobsfscan
  fake_expo "$app/node_modules/.bin/expo" > /dev/null
  export CI=''
  mobile
  [ "$status" -eq 0 ] || fail "status $status: $output"
  grep -qx 'expo prebuild --platform all --clean --no-install' "$CALLS" || fail "the default expo did not run: $(cat "$CALLS")"
  grep -q '^expo-cwd .*/app$' "$CALLS" || fail "the prebuild did not run in the copy: $(cat "$CALLS")"
  ! grep -qx "expo-cwd $app" "$CALLS" || fail "the prebuild ran in the working tree"
  grep -q '^expo-env CI=unset ' "$CALLS" || fail "expo saw an empty CI, which it throws on: $(cat "$CALLS")"
}

@test "under CI the prebuild sees CI" {
  fake_mobsfscan
  export SECURITY_EXPO_BIN CI=true
  SECURITY_EXPO_BIN="$(fake_expo)"
  mobile
  [ "$status" -eq 0 ] || fail "status $status: $output"
  grep -q '^expo-env CI=true ' "$CALLS" || fail "CI was not passed through: $(cat "$CALLS")"
}

@test "a prebuild that fails fails the job before mobsfscan runs" {
  fake_mobsfscan
  printf '#!/usr/bin/env bash\necho "config plugin threw" >&2\nexit 4\n' > "$bin/expo"
  chmod +x "$bin/expo"
  export SECURITY_EXPO_BIN="$bin/expo"
  mobile
  [ "$status" -ne 0 ] || fail "a failed prebuild passed: $output"
  contains "$output" 'config plugin threw' || fail "the prebuild's error is not shown: $output"
  ! grep -q '^mobsfscan ' "$CALLS" || fail "mobsfscan ran after a failed prebuild"
}

@test "a .mobsf that mobsfscan could not read fails the job" {
  printf 'ignore-pathz: []\n' > "$app/.mobsf"
  fake_mobsfscan "echo 'The config \`ignore-pathz\` is not supported.' >&2"
  export SECURITY_EXPO_BIN
  SECURITY_EXPO_BIN="$(fake_expo)"
  mobile
  [ "$status" -eq 1 ] || fail "an unread .mobsf passed with $status: $output"
  contains "$output" 'is not supported' || fail "mobsfscan's output is not shown: $output"
  contains "$output" 'mobsfscan could not read .mobsf' || fail "the error does not say why: $output"
}

@test "a mobsfscan crash fails the job and shows its output" {
  fake_mobsfscan 'echo "Traceback: boom" >&2; exit 3'
  export SECURITY_EXPO_BIN
  SECURITY_EXPO_BIN="$(fake_expo)"
  mobile
  [ "$status" -eq 1 ] || fail "a crash passed with $status: $output"
  contains "$output" 'Traceback: boom' || fail "the crash output is not shown: $output"
}

@test "without mobsfscan it skips locally" {
  export SECURITY_EXPO_BIN
  SECURITY_EXPO_BIN="$(fake_expo)"
  run env PATH="$(bare_path)" "$BASH" "$REPO_ROOT/scripts/security/mobile.sh"
  [ "$status" -eq 0 ] || fail "status $status: $output"
  contains "$(sarif_note "$SECURITY_DIR/mobile.sarif")" 'mobsfscan is not installed' || fail "the skip gives no reason"
  [ ! -s "$CALLS" ] || fail "expo ran without mobsfscan: $(cat "$CALLS")"
}

@test "without mobsfscan it fails under CI" {
  run env PATH="$(bare_path)" CI=true "$BASH" "$REPO_ROOT/scripts/security/mobile.sh"
  [ "$status" -eq 1 ] || fail "a missing mobsfscan passed under CI with $status: $output"
  contains "$output" 'mobsfscan is not installed, and under CI that is a failure' || fail "the error: $output"
}

@test "without dependencies it skips locally" {
  fake_mobsfscan
  export SECURITY_EXPO_BIN="$BATS_TEST_TMPDIR/missing-expo"
  mobile
  [ "$status" -eq 0 ] || fail "status $status: $output"
  contains "$(sarif_note "$SECURITY_DIR/mobile.sarif")" 'dependencies are not installed' || fail "the skip gives no reason"
  ! grep -q '^mobsfscan ' "$CALLS" || fail "mobsfscan ran without a prebuild"
}

@test "without dependencies it fails under CI" {
  fake_mobsfscan
  export SECURITY_EXPO_BIN="$BATS_TEST_TMPDIR/missing-expo" CI=true
  mobile
  [ "$status" -eq 1 ] || fail "a missing expo passed under CI with $status: $output"
  contains "$output" 'the mobile job needs dependencies installed, and under CI that is a failure' || fail "the error: $output"
  [ ! -e "$SECURITY_DIR/mobile.sarif" ] || fail "CI wrote a skipped SARIF instead of failing"
}

#!/usr/bin/env bats
# scripts/lib/verify-common.sh - the checklist and the pure verdict helpers the
# release verification gates (verify-ios.sh, verify-android.sh) are built from.
# Each case sources the library in a fresh bash, exactly as the gates do, and
# calls one function: every rule that can fail a release is a function that
# takes text or a file and prints `<status> <detail>`, so the decisions are
# tested here without a 90 MB build.
#
# Covers every function and each of its branches: the checklist (every status,
# an empty and an unknown verdict, the job summary with and without
# GITHUB_STEP_SUMMARY, strict mode from --strict, CI and GITHUB_ACTIONS), the
# grep wrapper's three exit classes, and each verdict helper's ok, warn, skip
# and FAIL paths, including a grep that cannot run and a machine with no node.
# The tool discovery (aapt2 and friends under ANDROID_HOME, bundletool as a
# command or a jar) runs against fake tools on PATH and in a fake SDK.
#
# Ported from the template's scripts/release/verify.test.mjs, case for case,
# then extended to every branch.
#
# Every assertion ends in `|| fail "..."` - see test_helper.bash.
load test_helper

HERMES_MAGIC='\306\037\274\003\301\003\031\037'

setup() {
  unset CI GITHUB_ACTIONS ANDROID_HOME ANDROID_SDK_ROOT BUNDLETOOL_JAR
  local var
  for var in $(compgen -e | grep '^EXPO_PUBLIC_' || true); do unset "$var"; done
  dir="$BATS_TEST_TMPDIR/work"
  mkdir -p "$dir"
  bin="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$bin"
}

# Sources the library in a fresh bash under the gates' own strict mode and runs
# one snippet; the result is in $status and $output.
lib() { run bash -c "set -euo pipefail; source '$REPO_ROOT/scripts/lib/verify-common.sh'; $1"; }

# The same, on PATH $1 only.
lib_on() { run env PATH="$1" "$BASH" -c "set -euo pipefail; source '$REPO_ROOT/scripts/lib/verify-common.sh'; $2"; }

# A PATH with only the tools the library needs, less the ones named in $@.
bare_path() {
  local bare="$BATS_TEST_TMPDIR/bare-$*" tool skip found
  mkdir -p "$bare"
  for tool in bash env grep sed tr head tail sort paste cut comm od mktemp rm cat find basename printenv; do
    for skip in "$@"; do [ "$tool" = "$skip" ] && continue 2; done
    found="$(command -v "$tool" || true)"
    [ -z "$found" ] || ln -sf "$found" "$bare/$tool"
  done
  printf '%s' "$bare"
}

# A file vc_bundle_kind calls Hermes bytecode: the magic, then $2.
hermes_bundle() {
  # shellcheck disable=SC2059  # the format is the escaped magic, on purpose
  printf "$HERMES_MAGIC" > "$1"
  printf '%s' "${2:-}" >> "$1"
  printf '%s' "$1"
}

# The last line of $output.
last_line() { printf '%s' "${lines[${#lines[@]}-1]}"; }

# A grep on PATH that always fails, which is what a broken or absent grep looks
# like from the caller's side.
broken_grep() {
  printf '#!/bin/sh\necho "grep: broken" >&2\nexit 2\n' > "$bin/grep"
  chmod +x "$bin/grep"
}

BADGING="package: name='sv.blink.reactnativemobiletemplate' versionCode='42' versionName='1.2.3' compileSdkVersion='36'
minSdkVersion:'24'
targetSdkVersion:'36'
uses-permission: name='android.permission.INTERNET'
application-label:'RN Mobile Template'"

ENV_EXAMPLE='# comment
EXPO_PUBLIC_API_URL=http://localhost/graphql
EXPO_PUBLIC_APP_NAME=RN Mobile Template
EXPO_PUBLIC_WEB_DOMAIN=
# APP_VERSION is not public
APP_VERSION=1.2.3'

# --- architecture -----------------------------------------------------------

@test "arm64 only passes the architecture check, a simulator slice or nothing fails it" {
  lib 'vc_arch_verdict "arm64"'
  [ "$output" = 'ok arm64 only' ] || fail "arm64: $output"
  lib 'vc_arch_verdict "x86_64 arm64"'
  [ "$output" = 'FAIL expected arm64 only, got arm64 x86_64' ] || fail "a simulator slice: $output"
  lib 'vc_arch_verdict ""'
  [ "$output" = 'FAIL no architectures reported' ] || fail "an empty lipo result: $output"
}

# --- Android ABIs -----------------------------------------------------------

@test "arm libraries pass the ABI check, and an x86, a missing arm or no library fails it" {
  local arm='base/lib/arm64-v8a/libhermes.so
base/lib/armeabi-v7a/libhermes.so'
  lib "vc_abi_verdict '$arm'"
  [ "$output" = 'ok arm64-v8a armeabi-v7a' ] || fail "arm only: $output"
  lib "vc_abi_verdict '$arm
base/lib/x86_64/libhermes.so'"
  [ "$output" = 'FAIL forbidden ABI present: x86_64 (all: arm64-v8a armeabi-v7a x86_64)' ] || fail "x86_64: $output"
  lib "vc_abi_verdict 'base/lib/x86/libhermes.so'"
  [ "$output" = 'FAIL forbidden ABI present: x86 (all: x86)' ] || fail "x86 alone: $output"
  lib "vc_abi_verdict 'lib/riscv64/libhermes.so'"
  [ "$output" = 'FAIL no arm ABI among: riscv64' ] || fail "no arm ABI: $output"
  lib "vc_abi_verdict 'base/res/drawable/icon.png'"
  [ "$output" = 'FAIL no native libraries found' ] || fail "no libraries: $output"
}

# --- aapt2 badging ----------------------------------------------------------

@test "badging fields come off the package line, not a permission line" {
  printf '%s\n' "$BADGING" > "$dir/badging.txt"
  lib "vc_badging_field \"\$(cat '$dir/badging.txt')\" name"
  [ "$output" = 'sv.blink.reactnativemobiletemplate' ] || fail "name: $output"
  lib "vc_badging_field \"\$(cat '$dir/badging.txt')\" versionCode"
  [ "$output" = '42' ] || fail "versionCode: $output"
  lib "vc_badging_field \"\$(cat '$dir/badging.txt')\" versionName"
  [ "$output" = '1.2.3' ] || fail "versionName: $output"
  lib "vc_badging_line_value \"\$(cat '$dir/badging.txt')\" minSdkVersion"
  [ "$output" = '24' ] || fail "minSdkVersion: $output"
  lib "vc_badging_line_value \"\$(cat '$dir/badging.txt')\" sdkVersion"
  [ -z "$output" ] || fail "an absent line is not empty: $output"
}

@test "a debuggable release build fails, a non-debuggable one passes" {
  printf '%s\napplication-debuggable\n' "$BADGING" > "$dir/debuggable.txt"
  printf '%s\n' "$BADGING" > "$dir/release.txt"
  lib "vc_debuggable_verdict \"\$(cat '$dir/debuggable.txt')\""
  [ "$output" = 'FAIL application-debuggable is set' ] || fail "debuggable: $output"
  lib "vc_debuggable_verdict \"\$(cat '$dir/release.txt')\""
  [ "$output" = 'ok not debuggable' ] || fail "release: $output"
}

@test "minSdk below the floor fails, at or above it passes, and an unreadable one fails" {
  lib 'vc_min_sdk_verdict 24 24'
  [ "$output" = 'ok minSdk 24 (>= 24)' ] || fail "at the floor: $output"
  lib 'vc_min_sdk_verdict 21 24'
  [ "$output" = 'FAIL minSdk 21 is below the supported minimum 24' ] || fail "below: $output"
  lib 'vc_min_sdk_verdict "" 24'
  [ "$output" = 'FAIL could not read minSdkVersion (got <empty>)' ] || fail "empty: $output"
  lib 'vc_min_sdk_verdict 2x 24'
  [ "$output" = 'FAIL could not read minSdkVersion (got 2x)' ] || fail "not a number: $output"
}

# --- JS bundle: the dev server ----------------------------------------------

@test "a plain-text bundle that names the Metro dev server fails" {
  printf 'var url = "http://localhost:8081/index.bundle";\n' > "$dir/main.jsbundle"
  lib "vc_dev_server_verdict '$dir/main.jsbundle' text"
  contains "$output" 'FAIL bundle references a Metro dev server: http://localhost:8081' || fail "$output"
}

@test "the emulator loopback address counts as a dev server too" {
  printf 'fetch("http://10.0.2.2:8081/status")' > "$dir/index.android.bundle"
  lib "vc_dev_server_verdict '$dir/index.android.bundle' text"
  contains "$output" 'FAIL bundle references a Metro dev server: http://10.0.2.2:8081/status' || fail "$output"
}

@test "a clean plain-text bundle passes the dev-server check, the kind defaulting to text" {
  printf 'var url = "https://api.example.com/graphql";\n' > "$dir/main.jsbundle"
  lib "vc_dev_server_verdict '$dir/main.jsbundle'"
  [ "$output" = 'ok no dev-server URL in the bundle' ] || fail "$output"
}

@test "a missing bundle fails the dev-server check rather than being skipped" {
  lib 'vc_dev_server_verdict /nope/main.jsbundle text'
  [ "$output" = 'FAIL no JS bundle at /nope/main.jsbundle' ] || fail "$output"
}

@test "React Native's inert getDevServer fallback alone does not fail" {
  printf "var e,t,o='http://localhost:8081/';function f(){}" > "$dir/main.jsbundle"
  lib "vc_dev_server_verdict '$dir/main.jsbundle' text"
  [ "$output" = "ok only React Native's inert getDevServer fallback" ] || fail "$output"
}

@test "adjacent Hermes strings that look like a dev-server URL do not fail" {
  # Verbatim what a real release build of the template produces: RN's FALLBACK
  # 'http://localhost:8081/' packed immediately before Metro's asset
  # httpServerLocation, overlapping on the shared '/'. Two strings; grep -ao
  # reads one URL.
  hermes_bundle "$dir/index.android.bundle" \
    'http://localhost:8081/assets/node_modules/.pnpm/@expo-google-fonts+material-symbols@0.4.45/node_modules/@expo-google-fonts/material-symbols/400Regular' >/dev/null
  lib "vc_dev_server_verdict '$dir/index.android.bundle' hermes"
  [ "$output" = 'ok no development markers in the Hermes bundle' ] || fail "$output"
}

@test "a URL-shaped concatenation in Hermes bytecode is not a dev marker either" {
  hermes_bundle "$dir/index.android.bundle" 'http://localhost:8081/index.bundle' >/dev/null
  lib "vc_dev_server_verdict '$dir/index.android.bundle' hermes"
  [ "$output" = 'ok no development markers in the Hermes bundle' ] || fail "$output"
}

@test "a Hermes bundle carrying real development markers fails" {
  local marker
  for marker in 'dev=true' 'hot=true' 'minify=false' '/.expo/.virtual-metro-entry' 'index.bundle?platform=ios'; do
    hermes_bundle "$dir/index.android.bundle" "x${marker}y" >/dev/null
    lib "vc_dev_server_verdict '$dir/index.android.bundle' hermes"
    contains "$output" 'FAIL bundle carries development markers: ' || fail "expected $marker to fail: $output"
  done
}

@test "a grep that cannot run fails both dev-server scans instead of passing them" {
  broken_grep
  printf 'var url = "http://localhost:8081/index.bundle";\n' > "$dir/main.jsbundle"
  lib "PATH='$bin':\$PATH; vc_dev_server_verdict '$dir/main.jsbundle' text"
  [ "$output" = 'FAIL could not scan the bundle: grep: broken ' ] || fail "text: $output"
  hermes_bundle "$dir/h.bundle" 'x' >/dev/null
  lib "PATH='$bin':\$PATH; vc_dev_server_verdict '$dir/h.bundle' hermes"
  [ "$output" = 'FAIL could not scan the bundle: grep: broken ' ] || fail "hermes: $output"
}

@test "a grep that fails silently still fails the scan, naming its status" {
  printf '#!/bin/sh\nexit 3\n' > "$bin/grep"
  chmod +x "$bin/grep"
  printf 'x' > "$dir/main.jsbundle"
  lib "PATH='$bin':\$PATH; vc_dev_server_verdict '$dir/main.jsbundle' text"
  [ "$output" = 'FAIL could not scan the bundle: grep failed with status 3' ] || fail "text: $output"
  lib "PATH='$bin':\$PATH; vc_dev_server_verdict '$dir/main.jsbundle' hermes"
  [ "$output" = 'FAIL could not scan the bundle: grep failed with status 3' ] || fail "hermes: $output"
}

# --- JS bundle: Hermes ------------------------------------------------------

@test "vc_bundle_kind tells Hermes bytecode from text" {
  hermes_bundle "$dir/h.bundle" >/dev/null
  lib "vc_bundle_kind '$dir/h.bundle'"
  [ "$output" = 'hermes' ] || fail "Hermes: $output"
  printf 'var __d = 1;' > "$dir/p.bundle"
  lib "vc_bundle_kind '$dir/p.bundle'"
  [ "$output" = 'text' ] || fail "text: $output"
  lib "vc_bundle_kind '$dir/absent.bundle'"
  [ "$output" = 'text' ] || fail "an absent file: $output"
}

@test "Hermes bytecode is recognised by its magic, and plain JS, an empty or a missing file fails" {
  hermes_bundle "$dir/hermes.bundle" 'rest' >/dev/null
  lib "vc_hermes_verdict '$dir/hermes.bundle'"
  [ "$output" = 'ok Hermes bytecode' ] || fail "Hermes: $output"
  printf 'var __d = function () {};\n' > "$dir/plain.bundle"
  lib "vc_hermes_verdict '$dir/plain.bundle'"
  contains "$output" 'FAIL not Hermes bytecode (magic 766172205f5f6420, expected c61fbc03c103191f)' || fail "plain: $output"
  : > "$dir/empty.bundle"
  lib "vc_hermes_verdict '$dir/empty.bundle'"
  [ "$output" = "FAIL $dir/empty.bundle is empty or unreadable" ] || fail "empty: $output"
  lib "vc_hermes_verdict '$dir/absent.bundle'"
  [ "$output" = "FAIL no JS bundle at $dir/absent.bundle" ] || fail "absent: $output"
}

# --- grep -------------------------------------------------------------------

@test "vc_grep keeps grep's exit status, its matches and its error" {
  printf 'hello\n' > "$dir/f.txt"
  lib "vc_grep hello '$dir/f.txt' && printf 'rc=0 %s' \"\$VC_GREP_OUTPUT\""
  [ "$output" = 'rc=0 hello' ] || fail "a match: $output"
  lib "vc_grep nope '$dir/f.txt' || printf 'rc=%s' \"\$?\""
  [ "$output" = 'rc=1' ] || fail "no match: $output"
  lib "vc_grep hello '$dir/missing' || printf 'rc=%s [%s]' \"\$?\" \"\$VC_GREP_ERROR\""
  contains "$output" 'rc=2 [' || fail "an error: $output"
  contains "$output" 'missing' || fail "grep's error was not kept: $output"
}

# grep reads bytes, not characters: a bundle is not valid UTF-8. The C locale
# reaches grep through `env`, never as a `LC_ALL=C grep` prefix, which crashes a
# forked bash on macOS now and then (see vc_grep). This pins the half a test
# can see: grep still gets LC_ALL=C, in both places that scan a bundle.
@test "both bundle scans hand grep the C locale" {
  # Matches exactly when it was given the C locale, and says what it got.
  cat > "$bin/grep" <<'STUB'
#!/bin/sh
printf 'LC_ALL=%s\n' "$LC_ALL"
[ "$LC_ALL" = C ]
STUB
  chmod +x "$bin/grep"
  printf 'var API = "https://api.example.com/graphql";\n' > "$dir/main.jsbundle"
  export LC_ALL=en_US.UTF-8
  lib "PATH='$bin':\$PATH; vc_grep x '$dir/main.jsbundle'; printf '%s' \"\$VC_GREP_OUTPUT\""
  [ "$output" = 'LC_ALL=C' ] || fail "vc_grep: $output"
  export EXPO_PUBLIC_API_URL='https://api.example.com/graphql'
  lib "PATH='$bin':\$PATH; vc_public_env_verdict '$dir/main.jsbundle' 'EXPO_PUBLIC_API_URL='"
  [ "$output" = 'LC_ALL=C
ok inlined: EXPO_PUBLIC_API_URL (not checked: none)' ] || fail "vc_public_env_verdict: $output"
}

@test "the text helpers need no tool at all" {
  lib "vc_contains 'abc' b && echo yes; vc_contains 'abc' x || echo no"
  [ "$output" = 'yes
no' ] || fail "vc_contains: $output"
  lib "vc_has_line_starting 'one
two words' two && echo yes; vc_has_line_starting 'one two' two || echo no"
  [ "$output" = 'yes
no' ] || fail "vc_has_line_starting: $output"
}

# --- EXPO_PUBLIC_* ----------------------------------------------------------

@test "EXPO_PUBLIC_ names are read out of .env.example, build-time names are not" {
  lib "vc_public_env_names '$ENV_EXAMPLE'"
  [ "$output" = 'EXPO_PUBLIC_API_URL
EXPO_PUBLIC_APP_NAME
EXPO_PUBLIC_WEB_DOMAIN' ] || fail "$output"
}

@test "a set EXPO_PUBLIC_ value must be inlined in the bundle" {
  printf 'var API = "https://api.example.com/graphql";\n' > "$dir/main.jsbundle"
  export EXPO_PUBLIC_API_URL='https://api.example.com/graphql' EXPO_PUBLIC_APP_NAME='' EXPO_PUBLIC_WEB_DOMAIN=''
  lib "vc_public_env_verdict '$dir/main.jsbundle' '$ENV_EXAMPLE'"
  [ "$output" = 'ok inlined: EXPO_PUBLIC_API_URL (not checked: EXPO_PUBLIC_APP_NAME EXPO_PUBLIC_WEB_DOMAIN)' ] || fail "inlined: $output"
  export EXPO_PUBLIC_API_URL='https://other.example.com/graphql'
  lib "vc_public_env_verdict '$dir/main.jsbundle' '$ENV_EXAMPLE'"
  [ "$output" = 'FAIL value not inlined in the bundle: EXPO_PUBLIC_API_URL' ] || fail "not inlined: $output"
}

@test "unset EXPO_PUBLIC_ names are skipped, never failed" {
  printf 'nothing public here' > "$dir/main.jsbundle"
  lib "vc_public_env_verdict '$dir/main.jsbundle' '$ENV_EXAMPLE'"
  [ "$output" = 'skip nothing checkable in this environment (not checked: EXPO_PUBLIC_API_URL EXPO_PUBLIC_APP_NAME EXPO_PUBLIC_WEB_DOMAIN)' ] || fail "$output"
}

@test "a value too short to prove anything is reported as unchecked, not as found" {
  printf 'var on = true;' > "$dir/main.jsbundle"
  export EXPO_PUBLIC_API_URL='true'
  lib "vc_public_env_verdict '$dir/main.jsbundle' 'EXPO_PUBLIC_API_URL='"
  [ "$output" = 'skip nothing checkable in this environment (not checked: EXPO_PUBLIC_API_URL)' ] || fail "$output"
}

@test "an .env.example with no EXPO_PUBLIC_ names is a skip" {
  printf 'x' > "$dir/main.jsbundle"
  lib "vc_public_env_verdict '$dir/main.jsbundle' 'APP_VERSION=1'"
  [ "$output" = 'skip no EXPO_PUBLIC_* names in .env.example' ] || fail "$output"
}

@test "a grep that cannot scan the bundle for a value fails the check" {
  broken_grep
  printf 'x' > "$dir/main.jsbundle"
  export EXPO_PUBLIC_API_URL='https://api.example.com/graphql'
  lib "PATH='$bin':\$PATH; vc_public_env_verdict '$dir/main.jsbundle' 'EXPO_PUBLIC_API_URL='"
  [ "$(last_line)" = 'FAIL could not scan the bundle for EXPO_PUBLIC_API_URL (grep status 2)' ] || fail "$output"
}

# --- OTA --------------------------------------------------------------------

@test "OTA has to agree with OTA_ENABLED, and is only skipped when it is unset" {
  lib 'vc_ota_verdict false false'
  [ "$output" = 'ok updates enabled=false, matching OTA_ENABLED' ] || fail "false/false: $output"
  lib 'vc_ota_verdict true true'
  [ "$output" = 'ok updates enabled=true, matching OTA_ENABLED' ] || fail "true/true: $output"
  lib 'vc_ota_verdict true false'
  [ "$output" = 'FAIL OTA_ENABLED=true but the artifact says updates enabled=false' ] || fail "true/false: $output"
  lib 'vc_ota_verdict "" true'
  [ "$output" = 'skip OTA_ENABLED not set; artifact says updates enabled=true' ] || fail "unset: $output"
  # No updates configuration at all is what OTA_ENABLED=false looks like.
  lib 'vc_ota_verdict false absent'
  [ "$output" = 'ok no updates configuration, matching OTA_ENABLED=false' ] || fail "false/absent: $output"
  lib 'vc_ota_verdict true absent'
  [ "$output" = 'FAIL OTA_ENABLED=true but the artifact says updates enabled=absent' ] || fail "true/absent: $output"
}

@test "OTA_ENABLED is read the way the app's Expo config reads it" {
  local value
  for value in true TRUE True 1 yes; do
    lib "vc_bool '$value'"
    [ "$output" = 'true' ] || fail "$value: $output"
  done
  for value in false anything 0; do
    lib "vc_bool '$value'"
    [ "$output" = 'false' ] || fail "$value: $output"
  done
  lib 'vc_bool ""'
  [ -z "$output" ] || fail "empty in, empty out: $output"
}

@test "a binary with no runtime version fails: it would never be offered an update" {
  lib 'vc_runtime_version_verdict "" "" ""'
  [ "$output" = 'FAIL updates are enabled but the artifact carries no runtime version (it would never be offered an update)' ] || fail "$output"
}

# The sentinel is what `expo prebuild` really writes under
# `runtimeVersion: { policy: 'fingerprint' }` - see fixtures/verify/ota/README.md.
@test "the fingerprint sentinel is resolved, not compared" {
  lib 'vc_runtime_version_verdict file:fingerprint abc123 abc123'
  [ "$output" = 'ok runtime version abc123 matches the build fingerprint' ] || fail "sentinel: $output"
  lib 'vc_runtime_version_verdict "@string/expo_runtime_version" abc123 abc123'
  [ "$output" = 'ok runtime version abc123 matches the build fingerprint' ] || fail "string resource: $output"
  lib 'vc_runtime_version_verdict file:fingerprint abc123 def456'
  [ "$output" = 'FAIL runtime version abc123 does not match the build fingerprint def456' ] || fail "mismatch: $output"
  # No build-info.json to compare against is not a mismatch.
  lib 'vc_runtime_version_verdict file:fingerprint abc123 ""'
  [ "$output" = 'ok runtime version abc123 (from file:fingerprint; no build-info fingerprint to compare against)' ] || fail "nothing to compare: $output"
}

@test "a sentinel with no fingerprint file behind it fails" {
  lib 'vc_runtime_version_verdict file:fingerprint "" abc123'
  [ "$output" = 'FAIL runtime version is file:fingerprint but the artifact carries no fingerprint file to resolve it from' ] || fail "$output"
}

@test "a pinned literal runtime version is reported, never compared to a fingerprint" {
  lib 'vc_runtime_version_verdict 1.0.0 "" deadbeef'
  [ "$output" = 'ok runtime version 1.0.0 (pinned literal, not a fingerprint policy)' ] || fail "$output"
}

@test "a store build must ask for the production channel" {
  lib 'vc_channel_verdict production production'
  [ "$output" = 'ok update channel production' ] || fail "production: $output"
  lib 'vc_channel_verdict internal production'
  [ "$output" = 'FAIL update channel internal, expected production' ] || fail "internal: $output"
  lib 'vc_channel_verdict "" production'
  [ "$output" = 'FAIL updates are enabled but no expo-channel-name request header is set' ] || fail "none: $output"
}

@test "the channel is read out of the manifest request-header JSON" {
  lib "vc_json_string_field '{\"expo-channel-name\":\"production\",\"other\":\"x\"}' expo-channel-name"
  [ "$output" = 'production' ] || fail "present: $output"
  lib "vc_json_string_field '{\"expo-channel-name\":\"production\"}' missing"
  [ -z "$output" ] || fail "absent: $output"
  lib "vc_json_string_field '{\"expo-channel-name\": \"beta\"}' expo-channel-name"
  [ "$output" = 'beta' ] || fail "spaced: $output"
}

@test "XML entities are undone before the JSON is parsed, &amp; last" {
  local escaped='{&quot;expo-channel-name&quot;:&quot;production&quot;}'
  lib "vc_xml_unescape '$escaped'"
  [ "$output" = '{"expo-channel-name":"production"}' ] || fail "unescape: $output"
  lib "vc_json_string_field \"\$(vc_xml_unescape '$escaped')\" expo-channel-name"
  [ "$output" = 'production' ] || fail "the channel: $output"
  lib "vc_xml_unescape 'a&amp;quot;b &lt;x&gt; &apos;y&apos;'"
  [ "$output" = "a&quot;b <x> 'y'" ] || fail "every entity: $output"
}

@test "a fingerprint is read out of build-info.json, and absence is not a mismatch" {
  printf '{"fingerprint":{"ios":"aaa","android":"bbb"}}' > "$dir/build-info.json"
  lib "vc_build_info_fingerprint '$dir/build-info.json' ios"
  [ "$output" = 'aaa' ] || fail "ios: $output"
  lib "vc_build_info_fingerprint '$dir/build-info.json' android"
  [ "$output" = 'bbb' ] || fail "android: $output"
  lib "vc_build_info_fingerprint '$dir/absent.json' ios"
  [ -z "$output" ] || fail "absent file: $output"
  printf '{"artifacts":{}}' > "$dir/no-fingerprint.json"
  lib "vc_build_info_fingerprint '$dir/no-fingerprint.json' ios"
  [ -z "$output" ] || fail "no fingerprint: $output"
  printf 'not json' > "$dir/bad.json"
  lib "vc_build_info_fingerprint '$dir/bad.json' ios"
  [ "$status" -eq 0 ] && [ -z "$output" ] || fail "invalid JSON: $status $output"
}

@test "with no node to read build-info.json there is nothing to compare against" {
  printf '{"fingerprint":{"ios":"aaa"}}' > "$dir/build-info.json"
  lib_on "$(bare_path)" "vc_build_info_fingerprint '$dir/build-info.json' ios; echo \"[\$?]\""
  [ "$output" = '[0]' ] || fail "$output"
}

# --- certificates -----------------------------------------------------------

@test "the template placeholder certificate warns, any other passes" {
  lib 'vc_cert_placeholder_verdict "$VC_PLACEHOLDER_CERT_SHA256"'
  [ "$output" = 'warn certs/expo-updates-cert.pem is still the template placeholder (its private key was discarded; see certs/README.md)' ] || fail "placeholder: $output"
  lib 'vc_cert_placeholder_verdict deadbeef'
  [ "$output" = 'ok code-signing certificate is not the template placeholder' ] || fail "other: $output"
}

@test "the placeholder constant is the hash of the template's certificate" {
  # test/fixtures/verify/expo-updates-cert.pem is the template's
  # certs/expo-updates-cert.pem. If either moves, this is what says the
  # constant has to move with it. LF only: a CRLF copy hashes to something else,
  # which is how the constant once drifted from the file.
  local pem="$FIXTURES/verify/expo-updates-cert.pem"
  not_contains "$(od -An -c "$pem")" '\r' || fail "the certificate copy must stay LF-only"
  lib "vc_cert_placeholder_verdict \"\$(shasum -a 256 '$pem' | cut -d' ' -f1)\""
  contains "$output" 'warn certs/expo-updates-cert.pem is still the template placeholder' || fail "$output"
}

@test "signing certificate fingerprints compare without colons or case" {
  lib 'vc_cert_verdict "AA:BB:CC" "aabbcc"'
  [ "$output" = 'ok signing certificate SHA-256 aabbcc' ] || fail "equal: $output"
  lib 'vc_cert_verdict "aabbcc" "ddeeff"'
  [ "$output" = 'FAIL signing certificate SHA-256 ddeeff, expected aabbcc' ] || fail "different: $output"
  lib 'vc_cert_verdict "aabbcc" ""'
  [ "$output" = 'FAIL no signing certificate SHA-256 to compare' ] || fail "none: $output"
  lib 'vc_sha_verdict APK "AB CD" "abcd"'
  [ "$output" = 'ok APK SHA-256 abcd' ] || fail "vc_sha_verdict: $output"
  lib "vc_normalize_sha 'Ab:Cd
'"
  [ "$output" = 'abcd' ] || fail "vc_normalize_sha: $output"
}

@test "the debug certificate is recognised whatever the rest of the DN says" {
  local dn
  for dn in 'CN=Android Debug, OU=Android, O=Unknown, L=Unknown, ST=Unknown, C=US' 'CN=Android Debug, O=Android, C=US'; do
    lib "vc_reset; vc_verdict debug-signing \"\$(vc_debug_signing_verdict '$dn')\""
    [ "$output" = "ok debug-signing: signed by the Android debug certificate ($dn)" ] || fail "$dn: $output"
  done
}

# Records one debug-signing verdict for a signer DN, then summarises; the last
# line says whether vc_summary failed the gate and what VC_FAILURES counted.
debug_signing_gate() {
  lib "vc_reset; vc_verdict debug-signing \"\$(vc_debug_signing_verdict '$1')\"; if vc_summary T >/dev/null; then echo \"passed failures=\$VC_FAILURES\"; else echo \"failed failures=\$VC_FAILURES\"; fi"
}

@test "a release certificate fails the debug-signing check by name, and the gate" {
  debug_signing_gate 'CN=Blink Upload, O=Blink, C=SV'
  [ "${lines[0]}" = 'FAIL debug-signing: expected the Android debug certificate (CN=Android Debug), got: CN=Blink Upload, O=Blink, C=SV' ] || fail "$output"
  [ "${lines[1]}" = 'failed failures=1' ] || fail "the gate did not fail: $output"
}

@test "an unsigned APK fails debug-signing rather than reporting an empty signer" {
  debug_signing_gate ''
  [ "${lines[0]}" = 'FAIL debug-signing: expected the Android debug certificate (CN=Android Debug), got no signer' ] || fail "$output"
  [ "${lines[1]}" = 'failed failures=1' ] || fail "the gate did not fail: $output"
}

@test "the debug certificate passes the gate it is asserted in" {
  debug_signing_gate 'CN=Android Debug, O=Android, C=US'
  [ "${lines[1]}" = 'passed failures=0' ] || fail "$output"
}

# --- dSYM -------------------------------------------------------------------

@test "a dSYM must cover every binary UUID, case aside" {
  local binary='UUID: 1A2B3C4D-0000-0000-0000-000000000001 (arm64) /App.app/App'
  lib "vc_dsym_verdict '$binary' 'UUID: 1a2b3c4d-0000-0000-0000-000000000001 (arm64) /App.app.dSYM'"
  [ "$output" = 'ok dSYM covers 1A2B3C4D-0000-0000-0000-000000000001' ] || fail "matching: $output"
  lib "vc_dsym_verdict '$binary' 'UUID: 99999999-0000-0000-0000-000000000009 (arm64) /Other.dSYM'"
  [ "$output" = 'FAIL dSYM does not cover binary UUID(s): 1A2B3C4D-0000-0000-0000-000000000001' ] || fail "other: $output"
  lib "vc_dsym_verdict '$binary' ''"
  [ "$output" = 'FAIL no UUID in the dSYM' ] || fail "empty dSYM: $output"
  lib "vc_dsym_verdict 'no uuid here' '$binary'"
  [ "$output" = 'FAIL no UUID in the app binary' ] || fail "empty binary: $output"
}

# --- store metadata ---------------------------------------------------------

@test "placeholder store metadata warns rather than failing, real copy passes" {
  mkdir -p "$dir/fastlane/metadata/ios/en-US"
  printf 'Replace this text\n' > "$dir/fastlane/metadata/ios/en-US/description.txt"
  lib "vc_metadata_placeholder_verdict '$dir'"
  [ "$output" = 'warn store metadata still has template placeholder text: fastlane/metadata/ios/en-US/description.txt' ] || fail "placeholder: $output"
  printf 'Real copy.\n' > "$dir/fastlane/metadata/ios/en-US/description.txt"
  lib "vc_metadata_placeholder_verdict '$dir'"
  [ "$output" = 'ok no placeholder text in fastlane/metadata' ] || fail "real copy: $output"
}

@test "no fastlane/metadata tree is a skip: an app may not keep one" {
  lib "vc_metadata_placeholder_verdict '$dir'"
  [ "$output" = "skip no fastlane/metadata tree at $dir/fastlane/metadata" ] || fail "$output"
}

@test "a broken grep fails the metadata check instead of passing it" {
  mkdir -p "$dir/fastlane/metadata"
  broken_grep
  lib "PATH='$bin':\$PATH; vc_metadata_placeholder_verdict '$dir'"
  [ "$output" = 'FAIL could not scan fastlane/metadata: grep: broken ' ] || fail "$output"
}

# --- the checklist ----------------------------------------------------------

@test "the checklist exits non-zero on a FAIL and zero otherwise" {
  lib 'vc_reset; vc_ok a fine; vc_summary T && echo EXIT_OK'
  [ "$(last_line)" = 'EXIT_OK' ] || fail "ok: $output"
  lib 'vc_reset; vc_fail a broken; vc_summary T || echo EXIT_FAIL'
  [ "$(last_line)" = 'EXIT_FAIL' ] || fail "FAIL: $output"
  lib 'vc_reset; vc_warn a odd; vc_summary T && echo EXIT_OK'
  [ "$(last_line)" = 'EXIT_OK' ] || fail "warn: $output"
  lib 'vc_reset; vc_skip a absent; vc_summary T && echo EXIT_OK'
  [ "$(last_line)" = 'EXIT_OK' ] || fail "skip: $output"
  lib 'vc_reset; vc_summary T && echo EXIT_OK'
  contains "$output" 'T — 0 checks, 0 failed, 0 warnings, 0 skipped' || fail "empty tally: $output"
  [ "$(last_line)" = 'EXIT_OK' ] || fail "empty: $output"
}

@test "vc_reset empties the checklist and every count" {
  lib 'vc_fail a x; vc_warn b y; vc_skip c z; vc_reset; echo "${#VC_LINES[@]} $VC_FAILURES $VC_WARNINGS $VC_SKIPS"'
  [ "$(last_line)" = '0 0 0 0' ] || fail "$output"
}

@test "vc_expect passes on equal values and fails naming both otherwise" {
  lib 'vc_expect version 1.2.3 1.2.3; vc_expect version 1.2.3 1.2.2'
  [ "$output" = "ok version: 1.2.3
FAIL version: expected '1.2.3', got '1.2.2'" ] || fail "$output"
}

# Every verdict is computed in `$(...)`; a subshell that dies before printing
# hands vc_verdict an empty string. That used to be recorded with an empty
# status, counted as neither a pass nor a failure.
@test "a check that produced no verdict fails the checklist" {
  lib 'vc_reset; vc_verdict expo-public "$(exit 139)"; vc_summary T || echo EXIT_FAIL'
  [ "${lines[0]}" = 'FAIL expo-public: the check produced no verdict (it exited or crashed before printing one)' ] || fail "$output"
  contains "$output" '1 failed' || fail "not counted: $output"
  [ "$(last_line)" = 'EXIT_FAIL' ] || fail "the gate passed: $output"
}

@test "a verdict with an unknown status fails the gate instead of passing it" {
  local verdict
  for verdict in 'fail lowercase' 'FAILED typo' 'error something' ' leading'; do
    lib "vc_reset; vc_verdict thing '$verdict'; vc_summary T >/dev/null || echo \"failures=\$VC_FAILURES\""
    contains "${lines[0]}" 'FAIL thing: unknown verdict status ' || fail "[$verdict]: $output"
    contains "${lines[0]}" "$verdict" || fail "the original verdict is not shown: $output"
    [ "$(last_line)" = 'failures=1' ] || fail "[$verdict] not counted: $output"
  done
  # A bare status with no detail is still a known status.
  lib "vc_reset; vc_verdict thing 'ok'"
  [ "$output" = 'ok thing: ok' ] || fail "bare ok: $output"
}

@test "a verdict with a known status is recorded as that status" {
  lib "vc_reset; vc_verdict a 'ok fine'; vc_verdict b 'warn odd'; vc_verdict c 'skip absent'; vc_verdict d 'FAIL broken'; echo \"failures=\$VC_FAILURES warnings=\$VC_WARNINGS skips=\$VC_SKIPS\""
  [ "$output" = 'ok a: fine
warn b: odd
skip c: absent
FAIL d: broken
failures=1 warnings=1 skips=1' ] || fail "$output"
}

@test "the checklist is mirrored into GITHUB_STEP_SUMMARY, one icon per status" {
  export GITHUB_STEP_SUMMARY="$dir/summary.md"
  : > "$GITHUB_STEP_SUMMARY"
  lib "vc_reset; vc_ok version 1.2.3; vc_fail arch 'x86_64 arm64'; vc_warn metadata odd; vc_skip dsym absent; vc_summary iOS || true"
  local written
  written="$(cat "$GITHUB_STEP_SUMMARY")"
  contains "$written" '### iOS' || fail "no title: $written"
  contains "$written" '| ✅ | `version` | 1.2.3 |' || fail "ok row: $written"
  contains "$written" '| ❌ | `arch` | x86_64 arm64 |' || fail "FAIL row: $written"
  contains "$written" '| ⚠️ | `metadata` | odd |' || fail "warn row: $written"
  contains "$written" '| ⏭️ | `dsym` | absent |' || fail "skip row: $written"
  contains "$written" '4 checks, 1 failed, 1 warnings, 1 skipped' || fail "no tally: $written"
}

@test "an empty checklist still writes its table header to the job summary" {
  export GITHUB_STEP_SUMMARY="$dir/summary.md"
  : > "$GITHUB_STEP_SUMMARY"
  lib 'vc_reset; vc_summary Empty'
  [ "$status" -eq 0 ] || fail "status $status: $output"
  contains "$(cat "$GITHUB_STEP_SUMMARY")" '0 checks, 0 failed, 0 warnings, 0 skipped' || fail "$(cat "$GITHUB_STEP_SUMMARY")"
}

@test "summary cells escape a pipe so the job-summary table survives a path" {
  export GITHUB_STEP_SUMMARY="$dir/summary.md"
  : > "$GITHUB_STEP_SUMMARY"
  lib "vc_reset; vc_fail signature 'apksigner said a|b'; vc_summary A || true"
  contains "$(cat "$GITHUB_STEP_SUMMARY")" '| ❌ | `signature` | apksigner said a\|b |' || fail "$(cat "$GITHUB_STEP_SUMMARY")"
}

# --- missing tools and strict mode -----------------------------------------

@test "a missing tool is a skip, and a present one emits nothing" {
  lib 'vc_reset; vc_init_strict ""; vc_require_cmd thing bash definitely-not-a-real-binary || echo "rc=$?"'
  [ "$output" = 'skip thing: requires definitely-not-a-real-binary, which is not on PATH
rc=1' ] || fail "missing: $output"
  lib 'vc_reset; vc_require_cmd thing bash && echo PRESENT'
  [ "$output" = 'PRESENT' ] || fail "present: $output"
}

@test "one missing tool emits one skip line per check it guards" {
  lib 'vc_reset; vc_init_strict ""; vc_require_cmd_for definitely-not-a-real-binary version build-number bundle-id || echo "rc=$?"'
  [ "$output" = 'skip version: requires definitely-not-a-real-binary, which is not on PATH
skip build-number: requires definitely-not-a-real-binary, which is not on PATH
skip bundle-id: requires definitely-not-a-real-binary, which is not on PATH
rc=1' ] || fail "$output"
}

@test "a tool that is present guards its checks silently" {
  lib 'vc_reset; vc_require_cmd_for bash a b c && echo PRESENT'
  [ "$output" = 'PRESENT' ] || fail "$output"
}

@test "a tool that cannot read the artifact fails every check it guards" {
  lib 'vc_reset; vc_fail_group "aapt2 could not read it" apk-package min-sdk'
  [ "$output" = 'FAIL apk-package: aapt2 could not read it
FAIL min-sdk: aapt2 could not read it' ] || fail "$output"
}

@test "--strict turns a tool-missing skip into a failure" {
  lib 'vc_reset; vc_init_strict 1; vc_require_cmd bundletool definitely-not-a-real-binary || true'
  [ "$output" = 'FAIL bundletool: requires definitely-not-a-real-binary, which is not on PATH (--strict)' ] || fail "$output"
}

@test "CI and GITHUB_ACTIONS turn strict mode on by themselves, CI=false does not" {
  export CI=true
  lib 'vc_init_strict ""; echo "$VC_STRICT"'
  [ "$output" = '1' ] || fail "CI=true: $output"
  unset CI
  export GITHUB_ACTIONS=true
  lib 'vc_init_strict ""; echo "$VC_STRICT"'
  [ "$output" = '1' ] || fail "GITHUB_ACTIONS=true: $output"
  unset GITHUB_ACTIONS
  export CI=false
  lib 'vc_reset; vc_init_strict ""; vc_require_cmd t definitely-not-a-real-binary || true'
  contains "$output" 'skip t: ' || fail "CI=false: $output"
  unset CI
  lib 'vc_init_strict; echo "$VC_STRICT"'
  [ "$output" = '0' ] || fail "nothing given: $output"
}

@test "an input that was never supplied stays a skip even under --strict" {
  lib 'vc_reset; vc_init_strict 1; vc_skip signing-cert "no --cert-sha256 given"'
  [ "$output" = 'skip signing-cert: no --cert-sha256 given' ] || fail "$output"
}

# --- tool discovery ---------------------------------------------------------

@test "an Android build tool on PATH wins over the SDK" {
  printf '#!/bin/sh\n' > "$bin/aapt2"
  chmod +x "$bin/aapt2"
  export ANDROID_HOME="$BATS_TEST_TMPDIR/sdk"
  lib "PATH='$bin':\$PATH; vc_android_build_tool aapt2"
  [ "$output" = "$bin/aapt2" ] || fail "$output"
}

@test "an Android build tool comes from the newest build-tools of ANDROID_HOME or ANDROID_SDK_ROOT" {
  local sdk="$BATS_TEST_TMPDIR/sdk" version
  for version in 34.0.0 35.0.0 9.0.0; do
    mkdir -p "$sdk/build-tools/$version"
    printf '#!/bin/sh\n' > "$sdk/build-tools/$version/aapt2"
    chmod +x "$sdk/build-tools/$version/aapt2"
  done
  export ANDROID_HOME="$sdk"
  lib_on "$(bare_path)" 'vc_android_build_tool aapt2'
  [ "$output" = "$sdk/build-tools/35.0.0/aapt2" ] || fail "ANDROID_HOME: $output"
  unset ANDROID_HOME
  export ANDROID_SDK_ROOT="$sdk"
  lib_on "$(bare_path)" 'vc_android_build_tool aapt2'
  [ "$output" = "$sdk/build-tools/35.0.0/aapt2" ] || fail "ANDROID_SDK_ROOT: $output"
}

@test "no SDK, no build-tools, no version or no executable tool is not found" {
  local sdk="$BATS_TEST_TMPDIR/sdk"
  lib_on "$(bare_path)" 'vc_android_build_tool aapt2 || echo "rc=$?"'
  [ "$output" = 'rc=1' ] || fail "no SDK: $output"
  export ANDROID_HOME="$sdk"
  mkdir -p "$sdk"
  lib_on "$(bare_path)" 'vc_android_build_tool aapt2 || echo "rc=$?"'
  [ "$output" = 'rc=1' ] || fail "no build-tools: $output"
  mkdir -p "$sdk/build-tools"
  lib_on "$(bare_path)" 'vc_android_build_tool aapt2 || echo "rc=$?"'
  [ "$output" = 'rc=1' ] || fail "no version: $output"
  mkdir -p "$sdk/build-tools/35.0.0"
  printf 'not executable' > "$sdk/build-tools/35.0.0/aapt2"
  lib_on "$(bare_path)" 'vc_android_build_tool aapt2 || echo "rc=$?"'
  [ "$output" = 'rc=1' ] || fail "not executable: $output"
}

@test "bundletool is a command on PATH, else a jar run by java, else not found" {
  printf '#!/bin/sh\n' > "$bin/bundletool"
  chmod +x "$bin/bundletool"
  lib_on "$bin:$(bare_path)" 'vc_find_bundletool && echo "${VC_BUNDLETOOL[*]}"'
  [ "$output" = 'bundletool' ] || fail "command: $output"
  rm "$bin/bundletool"
  printf '#!/bin/sh\n' > "$bin/java"
  chmod +x "$bin/java"
  : > "$dir/bundletool.jar"
  export BUNDLETOOL_JAR="$dir/bundletool.jar"
  lib_on "$bin:$(bare_path)" 'vc_find_bundletool && echo "${VC_BUNDLETOOL[*]}"'
  [ "$output" = "java -jar $dir/bundletool.jar" ] || fail "jar: $output"
  # A jar with no java, or a jar that is not there, is no bundletool.
  lib_on "$(bare_path)" 'vc_find_bundletool || echo "rc=$? [${VC_BUNDLETOOL[*]:-}]"'
  [ "$output" = 'rc=1 []' ] || fail "no java: $output"
  export BUNDLETOOL_JAR="$dir/absent.jar"
  lib_on "$bin:$(bare_path)" 'vc_find_bundletool || echo "rc=$?"'
  [ "$output" = 'rc=1' ] || fail "absent jar: $output"
  unset BUNDLETOOL_JAR
  lib_on "$bin:$(bare_path)" 'vc_find_bundletool || echo "rc=$?"'
  [ "$output" = 'rc=1' ] || fail "nothing: $output"
}

#!/usr/bin/env bats
# scripts/release/verify-android.sh - the post-build gate for the Android
# release artifacts: the AAB Play receives and the universal APK built from it,
# each checked on its own and against the other - package, version name and
# code, debuggable, minSdk, the expo-updates meta-data, native ABIs, the APK
# signature and its certificate, a Hermes bundle with no Metro dev server, the
# EXPO_PUBLIC_* values, the R8 mapping, the APK's checksum against
# build-info.json, and the store metadata.
#
# The APK and the AAB are real zips python3 builds (native libraries, the JS
# bundle, the fingerprint asset), read by the real unzip. aapt2, bundletool,
# apksigner and java are fakes on PATH or in a fake ANDROID_HOME, answering
# with a badging dump, the real prebuilt AndroidManifest.xml from
# test/fixtures/verify/ota/ and a signer. The PATH holds only those and the
# ordinary tools, so "the tool is missing" is true even on a machine that has
# it. The app repository is a directory of its own, the current directory (or
# GITHUB_WORKSPACE/WORKING_DIRECTORY), holding only what a case gives it.
#
# Exit paths covered: well-formed artifacts (0), OTA on and off; every usage
# error and a missing file (2); a repository root that does not exist (2); and
# each FAIL (1) - a wrong package, version or code, a debuggable APK, minSdk
# below the floor, a tool that cannot read an artifact, an AAB that is not the
# APK's, OTA not matching OTA_ENABLED, a missing or stale runtime version, the
# wrong channel, no code-signing certificate, an x86 library, a signature
# apksigner rejects, the wrong certificate, a release or no signer under
# --expect-debug-signing, no bundle, a text bundle naming Metro, an
# EXPO_PUBLIC_* value not inlined, an empty mapping, an APK that is not the one
# the build recorded - and every tool missing, a skip locally and a FAIL under
# --strict.
#
# Ported from the template's scripts/release/verify.test.mjs, case for case,
# then extended to every branch: the template had no end-to-end Android case
# that could pass, because no hand-made file was a readable AAB.
#
# Every assertion ends in `|| fail "..."` - see test_helper.bash.
load test_helper

HERMES_MAGIC='\306\037\274\003\301\003\031\037'
PACKAGE=sv.blink.reactnativemobiletemplate
SHA='abababababababababababababababababababababababababababababababab'

setup() {
  unset CI GITHUB_ACTIONS GITHUB_WORKSPACE WORKING_DIRECTORY APP_VERSION APP_BUILD_NUMBER ANDROID_PACKAGE \
    OTA_ENABLED OTA_CHANNEL BUILD_INFO_FILE ANDROID_HOME ANDROID_SDK_ROOT BUNDLETOOL_JAR ANDROID_MIN_SDK \
    ANDROID_MAPPING_TXT ANDROID_UPLOAD_CERT_SHA256
  local var
  for var in $(compgen -e | grep '^EXPO_PUBLIC_' || true); do unset "$var"; done
  mkdir -p "$BATS_TEST_TMPDIR/repo"
  # Physical, as the gate resolves it: on macOS the temporary directory is
  # behind the /var -> /private/var link.
  repo="$(cd "$BATS_TEST_TMPDIR/repo" && pwd -P)"
  cd "$repo" || return 1
  dir="$BATS_TEST_TMPDIR/artifacts"
  mkdir -p "$dir"
  aab="$dir/app-release.aab"
  apk="$dir/app-universal.apk"
  CALLS="$BATS_TEST_TMPDIR/calls"
  export CALLS
  : > "$CALLS"
  bin="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$bin"
  badging
  aab_manifest
  android_tools "$bin"
}

# The badging dump fake aapt2 prints: the release's package line, then $@.
badging() {
  {
    printf "package: name='%s' versionCode='42' versionName='1.2.3' compileSdkVersion='36'\n" "$PACKAGE"
    printf "minSdkVersion:'24'\ntargetSdkVersion:'36'\n"
    printf "uses-permission: name='android.permission.INTERNET'\n"
    [ $# -eq 0 ] || printf '%s\n' "$@"
  } > "$BATS_TEST_TMPDIR/badging.txt"
}

# The manifest fake bundletool prints: the real prebuilt AndroidManifest.xml
# with the release's package and version on its root element, then each sed
# expression in $@ applied.
aab_manifest() {
  local expr
  sed "1s|<manifest |<manifest android:versionCode=\"42\" android:versionName=\"1.2.3\" package=\"$PACKAGE\" |" \
    "$FIXTURES/verify/ota/AndroidManifest.xml" > "$BATS_TEST_TMPDIR/manifest.xml"
  for expr in "$@"; do
    sed -e "$expr" "$BATS_TEST_TMPDIR/manifest.xml" > "$BATS_TEST_TMPDIR/manifest.next"
    mv "$BATS_TEST_TMPDIR/manifest.next" "$BATS_TEST_TMPDIR/manifest.xml"
  done
}

# Fake aapt2, apksigner, bundletool and java in $1, each recording its call.
#   aapt2 dump badging        the badging file; $AAPT2_EMPTY prints nothing
#   apksigner verify          $SIGNER_DN and a SHA-256 digest ($SIGNER_SHA);
#                             $APKSIGNER_EXIT fails it with "DOES NOT VERIFY | x"
#   bundletool dump manifest  the manifest file; $BUNDLETOOL_EMPTY prints nothing
#   java -jar <jar> ...       bundletool, for BUNDLETOOL_JAR
android_tools() {
  local at="$1"
  mkdir -p "$at"
  cat > "$at/aapt2" <<STUB
#!/usr/bin/env bash
printf 'aapt2 %s\n' "\$*" >> "\$CALLS"
[ -n "\${AAPT2_EMPTY:-}" ] || cat "$BATS_TEST_TMPDIR/badging.txt"
STUB
  cat > "$at/bundletool" <<STUB
#!/usr/bin/env bash
printf 'bundletool %s\n' "\$*" >> "\$CALLS"
[ -n "\${BUNDLETOOL_EMPTY:-}" ] || cat "$BATS_TEST_TMPDIR/manifest.xml"
STUB
  cat > "$at/apksigner" <<'STUB'
#!/usr/bin/env bash
printf 'apksigner %s\n' "$*" >> "$CALLS"
if [ -n "${APKSIGNER_EXIT:-}" ]; then echo 'DOES NOT VERIFY | x' >&2; exit "$APKSIGNER_EXIT"; fi
echo 'Verifies'
[ -z "${SIGNER_DN:-}" ] || echo "Signer #1 certificate DN: $SIGNER_DN"
echo "Signer #1 certificate SHA-256 digest: ${SIGNER_SHA-abababababababababababababababababababababababababababababababab}"
STUB
  cat > "$at/java" <<STUB
#!/usr/bin/env bash
printf 'java %s\n' "\$*" >> "\$CALLS"
cat "$BATS_TEST_TMPDIR/manifest.xml"
STUB
  chmod +x "$at/aapt2" "$at/bundletool" "$at/apksigner" "$at/java"
}

# A PATH with the ordinary tools the gate needs, less the ones named in $@.
bare_path() {
  local bare="$BATS_TEST_TMPDIR/bare-$*" tool skip found
  mkdir -p "$bare"
  for tool in bash env dirname basename mktemp rm find sed tr head tail sort paste cut comm od grep printenv \
    cat wc mkdir node shasum unzip; do
    for skip in "$@"; do [ "$tool" = "$skip" ] && continue 2; done
    found="$(command -v "$tool" || true)"
    [ -z "$found" ] || ln -sf "$found" "$bare/$tool"
  done
  printf '%s' "$bare"
}

# artifacts [key=value ...] - writes $apk and $aab as real zips a correct
# release would produce. Keys: abi (the APK's), aab_abi, bundle (hermes, text
# or none), fingerprint (the APK's assets/fingerprint, none to leave it out),
# aab_fingerprint (base/assets/fingerprint in the AAB).
artifacts() {
  python3 - "$apk" "$aab" "$@" <<'PY'
import sys, zipfile
opts = dict(abi="arm64-v8a", aab_abi="arm64-v8a", bundle="hermes", fingerprint="fp-abc", aab_fingerprint="none")
opts.update(arg.split("=", 1) for arg in sys.argv[3:])
magic = bytes([0xC6, 0x1F, 0xBC, 0x03, 0xC1, 0x03, 0x19, 0x1F])
with zipfile.ZipFile(sys.argv[1], "w") as apk:
    apk.writestr("AndroidManifest.xml", b"binary")
    apk.writestr(f"lib/{opts['abi']}/libhermes.so", b"elf")
    if opts["bundle"] == "hermes":
        apk.writestr("assets/index.android.bundle", magic + b"strings")
    elif opts["bundle"] != "none":
        apk.writestr("assets/index.android.bundle", opts["bundle"])
    if opts["fingerprint"] != "none":
        apk.writestr("assets/fingerprint", opts["fingerprint"] + "\n")
with zipfile.ZipFile(sys.argv[2], "w") as aab:
    aab.writestr("base/manifest/AndroidManifest.xml", b"protobuf")
    aab.writestr(f"base/lib/{opts['aab_abi']}/libhermes.so", b"elf")
    if opts["aab_fingerprint"] != "none":
        aab.writestr("base/assets/fingerprint", opts["aab_fingerprint"])
PY
}

# The SHA-256 of $apk.
apk_sha() { shasum -a 256 "$apk" | cut -d' ' -f1; }

# Runs the gate on the fake tools and the ordinary ones; leading NAME=value
# arguments go into its environment. verify_on takes the PATH first and ends
# the environment with --.
verify() {
  local env_args=()
  while [ $# -gt 0 ] && [[ "$1" == *=* ]]; do env_args+=("$1"); shift; done
  verify_on "$bin:$(bare_path)" ${env_args[@]+"${env_args[@]}"} -- "$@"
}
verify_on() {
  local path="$1" env_args=()
  shift
  while [ "$1" != -- ]; do env_args+=("$1"); shift; done
  shift
  run env PATH="$path" ${env_args[@]+"${env_args[@]}"} "$BASH" "$REPO_ROOT/scripts/release/verify-android.sh" "$@"
}

# The environment of the release these artifacts are: every expected value set.
RELEASE=(APP_VERSION=1.2.3 APP_BUILD_NUMBER=42 ANDROID_PACKAGE=sv.blink.reactnativemobiletemplate OTA_ENABLED=true)

# The failure count off the closing tally line.
failed_count() { sed -n 's/.* — [0-9]* checks, \([0-9]*\) failed,.*/\1/p' <<< "$output"; }

# Every check that has a row whether or not its tool is there. debug-signing is
# absent: it only appears with --expect-debug-signing.
TOOL_CHECKS='apk-manifest apk-package apk-version-name apk-version-code debuggable min-sdk aab-manifest
aab-version-code aab-version-name aab-matches-apk ota signature signing-cert'

# --- well-formed artifacts --------------------------------------------------

@test "well-formed artifacts with OTA on pass with exit 0" {
  artifacts
  printf '{"artifacts":{"apkSha256":"%s"},"fingerprint":{"android":"fp-abc"}}' "$(apk_sha)" > "$dir/build-info.json"
  printf 'line 1\nline 2\n' > "$dir/mapping.txt"
  verify "${RELEASE[@]}" "$aab" "$apk" --cert-sha256 "$SHA"
  [ "$status" -eq 0 ] || fail "status $status: $output"
  not_contains "$output" 'FAIL ' || fail "a FAIL in a green run: $output"
  local line
  for line in 'ok artifacts: app-release.aab + app-universal.apk' \
    "ok apk-manifest: $PACKAGE 1.2.3 (42)" "ok apk-package: $PACKAGE" 'ok apk-version-name: 1.2.3' \
    'ok apk-version-code: 42' 'ok debuggable: not debuggable' 'ok min-sdk: minSdk 24 (>= 24)' \
    "ok aab-manifest: $PACKAGE 1.2.3 (42)" 'ok aab-version-code: 42' 'ok aab-version-name: 1.2.3' \
    "ok aab-matches-apk: $PACKAGE 1.2.3 42" 'ok ota: updates enabled=true, matching OTA_ENABLED' \
    'ok ota-runtime-version: runtime version fp-abc matches the build fingerprint' \
    'ok ota-channel: update channel production' 'ok apk-abis: arm64-v8a' 'ok aab-abis: arm64-v8a' \
    'ok signature: apksigner verified app-universal.apk' "ok signing-cert: signing certificate SHA-256 $SHA" \
    'ok hermes: Hermes bytecode' 'ok dev-server: no development markers in the Hermes bundle' \
    'ok mapping: 2 lines' "ok apk-sha: APK SHA-256 $(apk_sha)"; do
    contains "$output" "$line" || fail "missing [$line]: $output"
  done
  contains "$(cat "$CALLS")" "aapt2 dump badging $apk" || fail "$(cat "$CALLS")"
  contains "$(cat "$CALLS")" "bundletool dump manifest --bundle $aab" || fail "$(cat "$CALLS")"
  contains "$(cat "$CALLS")" "apksigner verify --print-certs $apk" || fail "$(cat "$CALLS")"
}

# Past a pipe's buffer, `| head -1` exiting after the first line killed the sed
# still writing with SIGPIPE, and pipefail ended the gate with 141.
@test "the AAB manifest's first package and version win over thousands of later ones" {
  local i
  artifacts
  for ((i = 0; i < 15000; i++)); do
    printf '<x android:versionCode="7" android:versionName="9.9.9" package="other.package"/>\n'
  done >> "$BATS_TEST_TMPDIR/manifest.xml"
  verify "${RELEASE[@]}" "$aab" "$apk"
  contains "$output" "ok aab-manifest: $PACKAGE 1.2.3 (42)" || fail "$output"
  contains "$output" 'ok aab-version-code: 42' || fail "$output"
  contains "$output" 'ok aab-version-name: 1.2.3' || fail "$output"
}

@test "well-formed artifacts with OTA off pass, with no OTA rows past ota" {
  artifacts
  aab_manifest '/expo.modules.updates/d'
  verify "${RELEASE[@]}" OTA_ENABLED=false "$aab" "$apk"
  [ "$status" -eq 0 ] || fail "status $status: $output"
  contains "$output" 'ok ota: no updates configuration, matching OTA_ENABLED=false' || fail "$output"
  not_contains "$output" 'ota-' || fail "$output"
}

@test "the checklist goes to GITHUB_STEP_SUMMARY when CI set it" {
  artifacts
  verify "${RELEASE[@]}" GITHUB_STEP_SUMMARY="$BATS_TEST_TMPDIR/summary.md" "$aab" "$apk"
  contains "$(cat "$BATS_TEST_TMPDIR/summary.md")" '### Android artifact verification' || fail "$(cat "$BATS_TEST_TMPDIR/summary.md")"
}

# --- usage ------------------------------------------------------------------

@test "usage errors and a missing file exit 2 without a checklist" {
  artifacts
  verify
  [ "$status" -eq 2 ] || fail "nothing: $status $output"
  contains "$output" 'usage: verify-android.sh <aab> <apk>' || fail "no usage line: $output"
  verify "$aab"
  [ "$status" -eq 2 ] || fail "one file: $status $output"
  verify "$aab" "$apk" "$apk"
  [ "$status" -eq 2 ] || fail "three files: $status $output"
  verify "$aab" "$apk" --bogus
  [ "$status" -eq 2 ] || fail "an unknown flag: $status $output"
  verify -h
  [ "$status" -eq 2 ] || fail "-h: $status $output"
  verify --help
  [ "$status" -eq 2 ] || fail "--help: $status $output"
  verify "$aab" "$apk" --cert-sha256
  [ "$status" -eq 2 ] || fail "--cert-sha256 with no value: $status $output"
  verify "$aab" "$dir/absent.apk"
  [ "$status" -eq 2 ] || fail "a missing APK: $status $output"
  [ "$output" = "verify-android.sh: no such file: $dir/absent.apk" ] || fail "the message: $output"
  verify "$dir/absent.aab" "$apk"
  [ "$status" -eq 2 ] || fail "a missing AAB: $status $output"
}

@test "a repository root that does not exist exits 2 naming it" {
  artifacts
  verify GITHUB_WORKSPACE="$BATS_TEST_TMPDIR/nowhere" "$aab" "$apk"
  [ "$status" -eq 2 ] || fail "status $status: $output"
  contains "$output" "verify-android.sh: the repository root $BATS_TEST_TMPDIR/nowhere/. does not exist" || fail "$output"
}

# --- missing tools and strict mode ------------------------------------------

@test "every check row stays when its tool is missing" {
  artifacts
  verify_on "$(bare_path)" -- "$aab" "$apk"
  [ "$status" -eq 0 ] || fail "status $status: $output"
  local check
  for check in $TOOL_CHECKS; do
    contains "$output" "skip $check: requires " || fail "$check: $output"
  done
  contains "$output" 'skip aab-matches-apk: requires bundletool' || fail "$output"
}

@test "--strict refuses to pass a check it could not run" {
  artifacts
  verify_on "$(bare_path)" -- "$aab" "$apk" --strict
  [ "$status" -eq 1 ] || fail "status $status: $output"
  local check
  for check in $TOOL_CHECKS; do
    contains "$output" "FAIL $check: requires " || fail "$check: $output"
  done
}

@test "with no unzip the ABI and bundle rows stay, as skips" {
  artifacts
  verify_on "$bin:$(bare_path unzip)" "${RELEASE[@]}" -- "$aab" "$apk"
  local check
  for check in apk-abis aab-abis hermes dev-server expo-public; do
    contains "$output" "skip $check: requires unzip, which is not on PATH" || fail "$check: $output"
  done
  # And the fingerprint cannot be resolved, which is a skip for @string/.
  contains "$output" 'skip ota-runtime-version: manifest declares @string/expo_runtime_version; no assets/fingerprint in the artifact to resolve it from' || fail "$output"
}

# --- the APK manifest -------------------------------------------------------

@test "the Android build tools come from ANDROID_HOME's newest build-tools" {
  artifacts
  android_tools "$BATS_TEST_TMPDIR/sdk/build-tools/35.0.0"
  rm "$bin/aapt2" "$bin/apksigner"
  verify "${RELEASE[@]}" ANDROID_HOME="$BATS_TEST_TMPDIR/sdk" "$aab" "$apk"
  [ "$status" -eq 0 ] || fail "status $status: $output"
  contains "$output" "ok apk-manifest: $PACKAGE 1.2.3 (42)" || fail "$output"
  contains "$output" 'ok signature: ' || fail "$output"
}

@test "an APK aapt2 cannot read fails every APK manifest row" {
  artifacts
  verify "${RELEASE[@]}" AAPT2_EMPTY=1 "$aab" "$apk"
  [ "$status" -eq 1 ] || fail "status $status: $output"
  local check
  for check in apk-manifest apk-package apk-version-name apk-version-code debuggable min-sdk; do
    contains "$output" "FAIL $check: aapt2 could not read $apk" || fail "$check: $output"
  done
  contains "$output" 'skip aab-matches-apk: the APK manifest could not be read' || fail "$output"
}

@test "a wrong package, version name or code fails, and an unset one is a skip" {
  artifacts
  verify APP_VERSION=1.2.4 APP_BUILD_NUMBER=43 ANDROID_PACKAGE=com.example.other "$aab" "$apk"
  [ "$status" -eq 1 ] || fail "status $status: $output"
  contains "$output" "FAIL apk-package: expected 'com.example.other', got '$PACKAGE'" || fail "$output"
  contains "$output" "FAIL apk-version-name: expected '1.2.4', got '1.2.3'" || fail "$output"
  contains "$output" "FAIL apk-version-code: expected '43', got '42'" || fail "$output"
  contains "$output" "FAIL aab-version-code: expected '43', got '42'" || fail "$output"
  contains "$output" "FAIL aab-version-name: expected '1.2.4', got '1.2.3'" || fail "$output"
  verify "$aab" "$apk"
  contains "$output" "skip apk-package: ANDROID_PACKAGE not set; artifact says $PACKAGE" || fail "$output"
  contains "$output" 'skip apk-version-name: APP_VERSION not set; artifact says 1.2.3' || fail "$output"
  contains "$output" 'skip apk-version-code: APP_BUILD_NUMBER not set; artifact says 42' || fail "$output"
  contains "$output" 'skip aab-version-code: APP_BUILD_NUMBER not set; artifact says 42' || fail "$output"
  contains "$output" 'skip aab-version-name: APP_VERSION not set; artifact says 1.2.3' || fail "$output"
}

@test "a debuggable APK fails" {
  artifacts
  badging 'application-debuggable'
  verify "${RELEASE[@]}" "$aab" "$apk"
  [ "$status" -eq 1 ] || fail "status $status: $output"
  contains "$output" 'FAIL debuggable: application-debuggable is set' || fail "$output"
}

@test "minSdk is read from aapt1's sdkVersion too, and ANDROID_MIN_SDK moves the floor" {
  artifacts
  {
    printf "package: name='%s' versionCode='42' versionName='1.2.3'\n" "$PACKAGE"
    printf "sdkVersion:'23'\n"
  } > "$BATS_TEST_TMPDIR/badging.txt"
  verify "${RELEASE[@]}" "$aab" "$apk"
  [ "$status" -eq 1 ] || fail "status $status: $output"
  contains "$output" 'FAIL min-sdk: minSdk 23 is below the supported minimum 24' || fail "$output"
  verify "${RELEASE[@]}" ANDROID_MIN_SDK=23 "$aab" "$apk"
  contains "$output" 'ok min-sdk: minSdk 23 (>= 23)' || fail "$output"
}

# --- the AAB manifest -------------------------------------------------------

@test "an AAB bundletool cannot read fails every AAB row" {
  artifacts
  verify "${RELEASE[@]}" BUNDLETOOL_EMPTY=1 "$aab" "$apk"
  [ "$status" -eq 1 ] || fail "status $status: $output"
  local check
  for check in aab-manifest aab-version-code aab-version-name aab-matches-apk ota; do
    contains "$output" "FAIL $check: bundletool could not read $aab" || fail "$check: $output"
  done
}

@test "bundletool as a jar runs through java" {
  artifacts
  rm "$bin/bundletool"
  : > "$BATS_TEST_TMPDIR/bundletool.jar"
  verify "${RELEASE[@]}" BUNDLETOOL_JAR="$BATS_TEST_TMPDIR/bundletool.jar" "$aab" "$apk"
  [ "$status" -eq 0 ] || fail "status $status: $output"
  contains "$(cat "$CALLS")" "java -jar $BATS_TEST_TMPDIR/bundletool.jar dump manifest --bundle $aab" || fail "$(cat "$CALLS")"
}

@test "an AAB that is not the APK's bundle fails aab-matches-apk" {
  artifacts
  aab_manifest 's/android:versionCode="42"/android:versionCode="41"/'
  verify "${RELEASE[@]}" "$aab" "$apk"
  [ "$status" -eq 1 ] || fail "status $status: $output"
  contains "$output" "FAIL aab-matches-apk: expected '$PACKAGE 1.2.3 41', got '$PACKAGE 1.2.3 42'" || fail "$output"
}

# --- OTA --------------------------------------------------------------------

# The fixtures are the contract with a generator this repository does not
# control, so assert what they say.
@test "the captured prebuild manifest and strings still say what the gate assumes" {
  local manifest strings
  manifest="$(cat "$FIXTURES/verify/ota/AndroidManifest.xml")"
  strings="$(cat "$FIXTURES/verify/ota/strings.xml")"
  contains "$manifest" 'expo.modules.updates.EXPO_RUNTIME_VERSION" android:value="@string/expo_runtime_version"' || fail "runtime version"
  contains "$manifest" 'UPDATES_CONFIGURATION_REQUEST_HEADERS_KEY" android:value="{&quot;expo-channel-name&quot;:&quot;production&quot;}"' || fail "channel"
  contains "$strings" '<string name="expo_runtime_version">file:fingerprint</string>' || fail "strings.xml"
}

@test "OTA not matching OTA_ENABLED fails, and unset is a skip" {
  artifacts
  verify "${RELEASE[@]}" OTA_ENABLED=false "$aab" "$apk"
  [ "$status" -eq 1 ] || fail "status $status: $output"
  contains "$output" 'FAIL ota: OTA_ENABLED=false but the artifact says updates enabled=true' || fail "$output"
  verify APP_VERSION=1.2.3 "$aab" "$apk"
  contains "$output" 'skip ota: OTA_ENABLED not set; artifact says updates enabled=true' || fail "$output"
}

@test "an ENABLED meta-data with no true or false counts as absent" {
  artifacts
  aab_manifest 's/updates.ENABLED" android:value="true"/updates.ENABLED" android:value="maybe"/'
  verify "${RELEASE[@]}" "$aab" "$apk"
  [ "$status" -eq 1 ] || fail "status $status: $output"
  contains "$output" 'FAIL ota: OTA_ENABLED=true but the artifact says updates enabled=absent' || fail "$output"
  not_contains "$output" 'ota-channel' || fail "$output"
}

@test "the runtime version resolves from the AAB when the APK has no fingerprint asset" {
  artifacts fingerprint=none aab_fingerprint=fp-aab
  verify "${RELEASE[@]}" "$aab" "$apk"
  contains "$output" 'ok ota-runtime-version: runtime version fp-aab (from @string/expo_runtime_version' || fail "$output"
}

@test "an @string/ runtime version with no fingerprint asset anywhere is a skip" {
  artifacts fingerprint=none
  verify "${RELEASE[@]}" "$aab" "$apk"
  [ "$status" -eq 0 ] || fail "status $status: $output"
  contains "$output" 'skip ota-runtime-version: manifest declares @string/expo_runtime_version; no assets/fingerprint in the artifact to resolve it from' || fail "$output"
}

@test "the sentinel with no fingerprint fails, a stale one fails, and a literal is reported" {
  artifacts fingerprint=none
  aab_manifest 's|"@string/expo_runtime_version"|"file:fingerprint"|'
  verify "${RELEASE[@]}" "$aab" "$apk"
  [ "$status" -eq 1 ] || fail "status $status: $output"
  contains "$output" 'FAIL ota-runtime-version: runtime version is file:fingerprint but the artifact carries no fingerprint file' || fail "$output"
  artifacts fingerprint=stale
  printf '{"fingerprint":{"android":"fp-abc"}}' > "$dir/build-info.json"
  verify "${RELEASE[@]}" "$aab" "$apk"
  contains "$output" 'FAIL ota-runtime-version: runtime version stale does not match the build fingerprint fp-abc' || fail "$output"
  aab_manifest 's|"@string/expo_runtime_version"|"1.0.0"|'
  verify "${RELEASE[@]}" "$aab" "$apk"
  contains "$output" 'ok ota-runtime-version: runtime version 1.0.0 (pinned literal, not a fingerprint policy)' || fail "$output"
}

@test "an OTA manifest with no runtime version meta-data fails the row instead of ending the gate" {
  # Bug fixed in the move: updates_meta's grep found nothing, its pipeline
  # failed under pipefail, and the `declared_rv=` assignment ended the script
  # with status 1 before the checklist - no FAIL line said why.
  artifacts
  aab_manifest '/expo.modules.updates.EXPO_RUNTIME_VERSION/d'
  verify "${RELEASE[@]}" "$aab" "$apk"
  [ "$status" -eq 1 ] || fail "status $status: $output"
  contains "$output" 'FAIL ota-runtime-version: updates are enabled but the artifact carries no runtime version' || fail "$output"
  contains "$output" 'ok ota-channel: update channel production' || fail "the gate stopped at the runtime version: $output"
  contains "$output" 'Android artifact verification — ' || fail "no checklist: $output"
}

@test "the channel is read XML-escaped out of the manifest, and has to be the expected one" {
  artifacts
  aab_manifest 's/&quot;production&quot;/\&quot;internal\&quot;/'
  verify "${RELEASE[@]}" "$aab" "$apk"
  [ "$status" -eq 1 ] || fail "status $status: $output"
  contains "$output" 'FAIL ota-channel: update channel internal, expected production' || fail "$output"
  verify "${RELEASE[@]}" OTA_CHANNEL=internal "$aab" "$apk"
  contains "$output" 'ok ota-channel: update channel internal' || fail "$output"
  aab_manifest '/UPDATES_CONFIGURATION_REQUEST_HEADERS_KEY/d'
  verify "${RELEASE[@]}" "$aab" "$apk"
  contains "$output" 'FAIL ota-channel: updates are enabled but no expo-channel-name request header is set' || fail "$output"
}

@test "no code-signing certificate meta-data fails; the repository's certificate warns, passes or skips" {
  artifacts
  verify "${RELEASE[@]}" "$aab" "$apk"
  contains "$output" "skip ota-cert: no certs/expo-updates-cert.pem in $repo, or no shasum to hash it" || fail "none: $output"
  mkdir -p "$repo/certs"
  cp "$FIXTURES/verify/expo-updates-cert.pem" "$repo/certs/expo-updates-cert.pem"
  verify "${RELEASE[@]}" "$aab" "$apk"
  [ "$status" -eq 0 ] || fail "a warning failed the gate: $status $output"
  contains "$output" 'warn ota-cert: certs/expo-updates-cert.pem is still the template placeholder' || fail "$output"
  printf 'a real certificate\n' > "$repo/certs/expo-updates-cert.pem"
  verify "${RELEASE[@]}" "$aab" "$apk"
  contains "$output" 'ok ota-cert: code-signing certificate is not the template placeholder' || fail "$output"
  aab_manifest '/CODE_SIGNING_CERTIFICATE/d'
  verify "${RELEASE[@]}" "$aab" "$apk"
  [ "$status" -eq 1 ] || fail "status $status: $output"
  contains "$output" 'FAIL ota-cert: updates are enabled but the manifest carries no CODE_SIGNING_CERTIFICATE meta-data' || fail "$output"
}

# --- native ABIs ------------------------------------------------------------

@test "an x86 library in either artifact fails its ABI row" {
  artifacts abi=x86_64 aab_abi=x86
  verify "${RELEASE[@]}" "$aab" "$apk"
  [ "$status" -eq 1 ] || fail "status $status: $output"
  contains "$output" 'FAIL apk-abis: forbidden ABI present: x86_64 (all: x86_64)' || fail "$output"
  contains "$output" 'FAIL aab-abis: forbidden ABI present: x86 (all: x86)' || fail "$output"
}

# --- signing ----------------------------------------------------------------

@test "an APK apksigner rejects fails the signature with apksigner's reason" {
  artifacts
  verify "${RELEASE[@]}" APKSIGNER_EXIT=1 "$aab" "$apk"
  [ "$status" -eq 1 ] || fail "status $status: $output"
  contains "$output" 'FAIL signature: apksigner verify failed: DOES NOT VERIFY | x' || fail "$output"
}

@test "the signing certificate comes from ANDROID_UPLOAD_CERT_SHA256, and --cert-sha256 overrides it" {
  artifacts
  verify "${RELEASE[@]}" ANDROID_UPLOAD_CERT_SHA256="$(tr '[:lower:]' '[:upper:]' <<< "$SHA")" "$aab" "$apk"
  [ "$status" -eq 0 ] || fail "status $status: $output"
  contains "$output" "ok signing-cert: signing certificate SHA-256 $SHA" || fail "$output"
  verify "${RELEASE[@]}" ANDROID_UPLOAD_CERT_SHA256="$SHA" "$aab" "$apk" --cert-sha256 cdcd
  [ "$status" -eq 1 ] || fail "status $status: $output"
  contains "$output" "FAIL signing-cert: signing certificate SHA-256 $SHA, expected cdcd" || fail "$output"
}

@test "no expected certificate is a skip naming the one the APK has" {
  artifacts
  verify "${RELEASE[@]}" "$aab" "$apk"
  contains "$output" "skip signing-cert: no --cert-sha256 given; APK is signed by $SHA" || fail "$output"
  verify "${RELEASE[@]}" SIGNER_SHA= "$aab" "$apk"
  contains "$output" 'skip signing-cert: no --cert-sha256 given; APK is signed by unknown' || fail "$output"
}

# The unsigned tier's assertion, end to end: the lane passes
# --expect-debug-signing, and a release-signed or unsigned APK must be counted
# as a failure by the gate, not only printed.
@test "--expect-debug-signing fails the gate on anything but the debug certificate" {
  artifacts
  verify "${RELEASE[@]}" SIGNER_DN='CN=Android Debug, O=Android, C=US' "$aab" "$apk" --expect-debug-signing
  [ "$status" -eq 0 ] || fail "debug: status $status: $output"
  contains "$output" 'ok debug-signing: signed by the Android debug certificate (CN=Android Debug, O=Android, C=US)' || fail "$output"
  [ "$(failed_count)" -eq 0 ] || fail "$output"
  local dn
  for dn in 'CN=Blink Upload, O=Blink, C=SV' ''; do
    verify "${RELEASE[@]}" SIGNER_DN="$dn" "$aab" "$apk" --expect-debug-signing
    [ "$status" -eq 1 ] || fail "[$dn]: status $status: $output"
    contains "$output" 'FAIL debug-signing: ' || fail "[$dn]: $output"
    [ "$(failed_count)" -eq 1 ] || fail "[$dn] counted wrong: $output"
  done
}

@test "with no apksigner the debug-signing row stays, and fails under --strict" {
  # Bug fixed in the move: a missing apksigner recorded signature and
  # signing-cert, but --expect-debug-signing's own row vanished.
  artifacts
  verify_on "$(bare_path)" -- "$aab" "$apk" --expect-debug-signing
  contains "$output" 'skip debug-signing: requires apksigner, which is not on PATH' || fail "$output"
  verify_on "$(bare_path)" -- "$aab" "$apk" --expect-debug-signing --strict
  contains "$output" 'FAIL debug-signing: requires apksigner, which is not on PATH (--strict)' || fail "$output"
}

# --- JS bundle --------------------------------------------------------------

@test "an APK with no JS bundle fails every bundle row" {
  artifacts bundle=none
  verify "${RELEASE[@]}" "$aab" "$apk"
  [ "$status" -eq 1 ] || fail "status $status: $output"
  local check
  for check in hermes dev-server expo-public; do
    contains "$output" "FAIL $check: no assets/index.android.bundle in the APK" || fail "$check: $output"
  done
}

@test "a plain-text bundle naming a Metro dev server fails twice over" {
  artifacts bundle='fetch("http://10.0.2.2:8081/status")'
  verify "${RELEASE[@]}" "$aab" "$apk"
  [ "$status" -eq 1 ] || fail "status $status: $output"
  contains "$output" 'FAIL hermes: not Hermes bytecode' || fail "$output"
  contains "$output" 'FAIL dev-server: bundle references a Metro dev server: http://10.0.2.2:8081/status' || fail "$output"
}

@test "the repository's .env.example names the values to find; without one it is a skip" {
  artifacts bundle='var API = "https://api.example.com/graphql";'
  verify "${RELEASE[@]}" "$aab" "$apk"
  contains "$output" "skip expo-public: no .env.example in $repo, so no EXPO_PUBLIC_* names to check" || fail "$output"
  printf 'EXPO_PUBLIC_API_URL=\n' > "$repo/.env.example"
  verify "${RELEASE[@]}" EXPO_PUBLIC_API_URL=https://api.example.com/graphql "$aab" "$apk"
  contains "$output" 'ok expo-public: inlined: EXPO_PUBLIC_API_URL (not checked: none)' || fail "$output"
}

# --- mapping ----------------------------------------------------------------

@test "no mapping is a skip, an empty one fails, and ANDROID_MAPPING_TXT names another" {
  artifacts
  verify "${RELEASE[@]}" "$aab" "$apk"
  contains "$output" "skip mapping: no mapping.txt at $dir/mapping.txt (minification off?)" || fail "$output"
  : > "$dir/mapping.txt"
  verify "${RELEASE[@]}" "$aab" "$apk"
  [ "$status" -eq 1 ] || fail "status $status: $output"
  contains "$output" "FAIL mapping: $dir/mapping.txt is empty" || fail "$output"
  printf 'a\n' > "$BATS_TEST_TMPDIR/other-mapping.txt"
  verify "${RELEASE[@]}" ANDROID_MAPPING_TXT="$BATS_TEST_TMPDIR/other-mapping.txt" "$aab" "$apk"
  contains "$output" 'ok mapping: 1 lines' || fail "$output"
}

# --- provenance -------------------------------------------------------------

# The "APK derived from the exact AAB" gate: the build lane records the APK's
# checksum in the build-info.json next to it.
@test "the APK is compared against the checksum the build recorded next to it" {
  artifacts
  printf '{"artifacts":{"apkSha256":"%s"}}' "$(apk_sha)" > "$dir/build-info.json"
  verify "${RELEASE[@]}" "$aab" "$apk"
  contains "$output" "ok apk-sha: APK SHA-256 $(apk_sha)" || fail "$output"
}

@test "an APK that is not the one the build produced fails" {
  artifacts
  printf '{"artifacts":{"apkSha256":"deadbeef"}}' > "$dir/build-info.json"
  verify "${RELEASE[@]}" "$aab" "$apk"
  [ "$status" -eq 1 ] || fail "status $status: $output"
  contains "$output" "FAIL apk-sha: APK SHA-256 $(apk_sha), expected deadbeef" || fail "$output"
}

@test "no recorded checksum is a skip" {
  artifacts
  printf '{"artifacts":{}}' > "$dir/build-info.json"
  verify "${RELEASE[@]}" "$aab" "$apk"
  contains "$output" 'skip apk-sha: build-info.json carries no artifacts.apkSha256' || fail "$output"
}

@test "BUILD_INFO_FILE overrides the copy next to the APK" {
  artifacts
  printf '{"artifacts":{"apkSha256":"%s"}}' "$(apk_sha)" > "$dir/build-info.json"
  printf '{"artifacts":{"apkSha256":"deadbeef"}}' > "$BATS_TEST_TMPDIR/elsewhere.json"
  verify "${RELEASE[@]}" BUILD_INFO_FILE="$BATS_TEST_TMPDIR/elsewhere.json" "$aab" "$apk"
  [ "$status" -eq 1 ] || fail "status $status: $output"
  contains "$output" 'FAIL apk-sha: ' || fail "$output"
}

@test "with no copy next to the APK, the repository root's build-info.json is read" {
  artifacts
  printf '{"artifacts":{"apkSha256":"deadbeef"}}' > "$repo/build-info.json"
  verify "${RELEASE[@]}" "$aab" "$apk"
  contains "$output" 'FAIL apk-sha: ' || fail "$output"
  rm "$repo/build-info.json"
  verify "${RELEASE[@]}" "$aab" "$apk"
  contains "$output" "skip apk-sha: no build-info.json at $repo/build-info.json" || fail "$output"
}

@test "with no node or no shasum apk-sha is a tool skip" {
  artifacts
  printf '{"artifacts":{"apkSha256":"deadbeef"}}' > "$dir/build-info.json"
  verify_on "$bin:$(bare_path node)" "${RELEASE[@]}" -- "$aab" "$apk"
  contains "$output" 'skip apk-sha: requires node, which is not on PATH' || fail "$output"
  verify_on "$bin:$(bare_path shasum)" "${RELEASE[@]}" -- "$aab" "$apk"
  contains "$output" 'skip apk-sha: requires shasum, which is not on PATH' || fail "$output"
}

# --- store metadata ---------------------------------------------------------

@test "placeholder store metadata in the repository warns without failing" {
  artifacts
  mkdir -p "$repo/fastlane/metadata/android/en-US"
  printf 'Replace this text\n' > "$repo/fastlane/metadata/android/en-US/full_description.txt"
  verify "${RELEASE[@]}" "$aab" "$apk"
  [ "$status" -eq 0 ] || fail "status $status: $output"
  contains "$output" 'warn metadata: store metadata still has template placeholder text: fastlane/metadata/android/en-US/full_description.txt' || fail "$output"
}

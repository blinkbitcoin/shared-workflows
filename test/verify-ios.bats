#!/usr/bin/env bats
# scripts/release/verify-ios.sh - the post-build gate for an iOS release
# artifact (.ipa, .xcarchive or .app): version, build number and bundle
# identifier, an arm64-only binary, signing, provisioning and get-task-allow,
# the expo-updates configuration, a Hermes bundle with no Metro dev server, the
# EXPO_PUBLIC_* values, the dSYM's UUIDs and the store metadata.
#
# Every case runs the script against a hand-made .app, on a PATH of fake
# plutil (python3's plistlib reading the real plist), lipo, codesign and
# dwarfdump that stand in for Xcode's, plus the ordinary tools; the .ipa and a
# zipped dSYM are real zips python3 builds. So it runs the same on Linux and on
# a Mac, and "the tool is missing" is true even on a Mac that has it. The app
# repository is a directory of its own, the current directory (or
# GITHUB_WORKSPACE/WORKING_DIRECTORY), holding only what a case gives it.
#
# Exit paths covered: a well-formed artifact (0) from an .app, an .xcarchive and
# an .ipa; every usage error and a missing artifact (2); a repository root that
# does not exist (2); and each FAIL (1) - no .app, an unsupported artifact, an
# .ipa unzip cannot read, no Info.plist, a wrong version, build number or
# bundle identifier, no executable, a simulator slice, codesign rejecting the
# app, an ad-hoc signature, no provisioning profile, get-task-allow, OTA not
# matching OTA_ENABLED, no update URL, a missing or stale fingerprint, the wrong
# channel, a text bundle naming Metro, an EXPO_PUBLIC_* value not inlined, a
# dSYM that does not cover the binary or cannot be read - and every tool
# missing, a skip locally and a FAIL under --strict or CI.
#
# Ported from the template's scripts/release/verify.test.mjs, case for case,
# then extended to every branch.
#
# Every assertion ends in `|| fail "..."` - see test_helper.bash.
load test_helper

HERMES_MAGIC='\306\037\274\003\301\003\031\037'
BINARY_UUID='UUID: 1A2B3C4D-0000-0000-0000-000000000001 (arm64) Fake'

setup() {
  unset CI GITHUB_ACTIONS GITHUB_WORKSPACE WORKING_DIRECTORY APP_VERSION APP_BUILD_NUMBER IOS_BUNDLE_ID \
    OTA_ENABLED OTA_CHANNEL BUILD_INFO_FILE
  local var
  for var in $(compgen -e | grep '^EXPO_PUBLIC_' || true); do unset "$var"; done
  mkdir -p "$BATS_TEST_TMPDIR/repo"
  # Physical, as the gate resolves it: on macOS the temporary directory is
  # behind the /var -> /private/var link.
  repo="$(cd "$BATS_TEST_TMPDIR/repo" && pwd -P)"
  cd "$repo" || return 1
  dir="$BATS_TEST_TMPDIR/artifacts"
  mkdir -p "$dir"
  CALLS="$BATS_TEST_TMPDIR/calls"
  export CALLS
  : > "$CALLS"
  bin="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$bin"
  xcode_tools
}

# Fake plutil, lipo, codesign and dwarfdump in $bin, each recording its call.
#   plutil -extract <key.path> raw -o - <plist>   python3's plistlib, as plutil reads it
#   lipo -archs <binary>                          the binary's text is its slice list
#   codesign                                      $CODESIGN_VERIFY_EXIT and _OUT for
#                                                 --verify, $CODESIGN_DETAILS for -dv,
#                                                 $ENTITLEMENTS for --entitlements
#   dwarfdump --uuid <path>                       <path>/uuid.txt for a dSYM, <path>.uuid
#                                                 for a binary
xcode_tools() {
  local python
  python="$(command -v python3)"
  { printf '#!%s\n' "$python"; cat <<'PY'; } > "$bin/plutil"
import os, plistlib, sys
with open(os.environ["CALLS"], "a") as calls:
    calls.write("plutil " + " ".join(sys.argv[1:]) + "\n")
key, path = sys.argv[2], sys.argv[-1]
try:
    with open(path, "rb") as f:
        value = plistlib.load(f)
except Exception:
    sys.exit(1)
for part in key.split("."):
    if not isinstance(value, dict) or part not in value:
        sys.exit(1)
    value = value[part]
if isinstance(value, (dict, list)):
    sys.exit(1)
print(("true" if value else "false") if isinstance(value, bool) else value)
PY
  cat > "$bin/lipo" <<'STUB'
#!/usr/bin/env bash
printf 'lipo %s\n' "$*" >> "$CALLS"
cat "$2"
STUB
  cat > "$bin/codesign" <<'STUB'
#!/usr/bin/env bash
printf 'codesign %s\n' "$*" >> "$CALLS"
case "$1" in
  --verify) printf '%s' "${CODESIGN_VERIFY_OUT:-}"; exit "${CODESIGN_VERIFY_EXIT:-0}" ;;
  -dv) printf '%s\n' "${CODESIGN_DETAILS-Authority=Apple Distribution: Blink (TEAM123)
TeamIdentifier=TEAM123}" >&2 ;;
  -d) printf '%s' "${ENTITLEMENTS:-}" ;;
esac
STUB
  cat > "$bin/dwarfdump" <<'STUB'
#!/usr/bin/env bash
printf 'dwarfdump %s\n' "$*" >> "$CALLS"
if [ -d "$2" ]; then cat "$2/uuid.txt"; else cat "$2.uuid"; fi
STUB
  chmod +x "$bin/plutil" "$bin/lipo" "$bin/codesign" "$bin/dwarfdump"
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

# Runs the gate on the fake tools and the ordinary ones; any leading NAME=value
# arguments go into its environment.
verify() {
  local env_args=()
  while [ $# -gt 0 ] && [[ "$1" == *=* ]]; do env_args+=("$1"); shift; done
  verify_on "$bin:$(bare_path)" ${env_args[@]+"${env_args[@]}"} -- "$@"
}

# verify_on PATH [NAME=value ...] -- ARGS...
verify_on() {
  local path="$1" env_args=()
  shift
  while [ "$1" != -- ]; do env_args+=("$1"); shift; done
  shift
  run env PATH="$path" ${env_args[@]+"${env_args[@]}"} "$BASH" "$REPO_ROOT/scripts/release/verify-ios.sh" "$@"
}

# The environment of the release this fake app is: every expected value set.
RELEASE=(APP_VERSION=1.2.3 APP_BUILD_NUMBER=42 IOS_BUNDLE_ID=sv.blink.reactnativemobiletemplate OTA_ENABLED=false)

# fake_app [key=value ...] - a .app a correct release would produce: the right
# version, an arm64 binary, a Hermes bundle, a binary UUID. A case that wants a
# defect overrides exactly that one thing, so a FAIL in its output can only be
# the defect. Keys: version, build, bundle_id, arch, bundle (text|hermes|none),
# expo (a plist to copy in as Expo.plist), fingerprint, executable, plist (no
# to leave Info.plist out), at (the directory to put it in). Prints its path.
fake_app() {
  local version=1.2.3 build=42 bundle_id=sv.blink.reactnativemobiletemplate arch=arm64 bundle=hermes expo='' \
    fingerprint='' executable=Fake plist=yes at="$dir" pair
  for pair in "$@"; do
    # shellcheck disable=SC2163  # the name is the pair's own key
    local "${pair?}"
  done
  local app="$at/Fake.app"
  mkdir -p "$app"
  if [ "$plist" = yes ]; then
    {
      printf '<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0"><dict>\n'
      printf '<key>CFBundleShortVersionString</key><string>%s</string>\n' "$version"
      printf '<key>CFBundleVersion</key><string>%s</string>\n' "$build"
      printf '<key>CFBundleIdentifier</key><string>%s</string>\n' "$bundle_id"
      [ -z "$executable" ] || printf '<key>CFBundleExecutable</key><string>%s</string>\n' "$executable"
      printf '</dict></plist>\n'
    } > "$app/Info.plist"
  fi
  printf '%s\n' "$arch" > "$app/Fake"
  printf '%s\n' "$BINARY_UUID" > "$app/Fake.uuid"
  case "$bundle" in
    # shellcheck disable=SC2059  # the format is the escaped magic, on purpose
    hermes) printf "$HERMES_MAGIC" > "$app/main.jsbundle" ;;
    none) ;;
    *) printf '%s' "$bundle" > "$app/main.jsbundle" ;;
  esac
  [ -z "$expo" ] || cp "$expo" "$app/Expo.plist"
  if [ -n "$fingerprint" ]; then
    # EXUpdates.bundle, not the .app root: that is where the expo-updates build
    # phase writes it, and where the client reads it back from.
    mkdir -p "$app/EXUpdates.bundle"
    printf '%s' "$fingerprint" > "$app/EXUpdates.bundle/fingerprint"
  fi
  printf '%s' "$app"
}

# expo_plist [enabled=true|false] [runtime=X] [channel=Y] [drop=KEY,KEY] - the
# real prebuilt Expo.plist from test/fixtures/verify/ota/, one key rewritten at a
# time. Prints the path of the result.
expo_plist() {
  local out="$BATS_TEST_TMPDIR/Expo.plist"
  python3 - "$FIXTURES/verify/ota/Expo.plist" "$out" "$@" <<'PY'
import plistlib, sys
with open(sys.argv[1], "rb") as f:
    plist = plistlib.load(f)
for arg in sys.argv[3:]:
    key, value = arg.split("=", 1)
    if key == "enabled":
        plist["EXUpdatesEnabled"] = value == "true"
    elif key == "runtime":
        plist["EXUpdatesRuntimeVersion"] = value
    elif key == "channel":
        plist["EXUpdatesRequestHeaders"]["expo-channel-name"] = value
    elif key == "drop":
        for name in value.split(","):
            plist.pop(name, None)
with open(sys.argv[2], "wb") as f:
    plistlib.dump(plist, f)
PY
  printf '%s' "$out"
}

# zip_dir ZIP DIR - a zip of DIR's contents.
zip_dir() {
  python3 - "$1" "$2" <<'PY'
import os, sys, zipfile
with zipfile.ZipFile(sys.argv[1], "w") as z:
    for root, _, files in os.walk(sys.argv[2]):
        for name in files:
            full = os.path.join(root, name)
            z.write(full, os.path.relpath(full, sys.argv[2]))
PY
}

# --- the well-formed artifact ------------------------------------------------

# The case that matters most: a well-formed artifact must come out green.
# Without it every `status 1` below could be satisfied by an unrelated FAIL.
@test "a well-formed .app passes with exit 0" {
  local app
  app="$(fake_app)"
  verify "${RELEASE[@]}" "$app" --no-signing
  [ "$status" -eq 0 ] || fail "status $status: $output"
  not_contains "$output" 'FAIL ' || fail "a FAIL in a green run: $output"
  contains "$output" 'ok artifact: Fake.app from Fake.app' || fail "artifact: $output"
  contains "$output" 'ok version: 1.2.3' || fail "version: $output"
  contains "$output" 'ok build-number: 42' || fail "build number: $output"
  contains "$output" 'ok bundle-id: sv.blink.reactnativemobiletemplate' || fail "bundle id: $output"
  contains "$output" 'ok arch: arm64 only' || fail "arch: $output"
  contains "$output" 'ok ota: no updates configuration, matching OTA_ENABLED=false' || fail "ota: $output"
  contains "$output" 'ok hermes: Hermes bytecode' || fail "hermes: $output"
  contains "$output" 'ok dev-server: no development markers' || fail "dev-server: $output"
  contains "$output" 'iOS artifact verification — 14 checks, 0 failed' || fail "tally: $output"
}

@test "the .app inside an .xcarchive is found and verified" {
  mkdir -p "$dir/App.xcarchive/Products/Applications"
  fake_app at="$dir/App.xcarchive/Products/Applications" >/dev/null
  verify "${RELEASE[@]}" "$dir/App.xcarchive" --no-signing
  [ "$status" -eq 0 ] || fail "status $status: $output"
  contains "$output" 'ok artifact: Fake.app from App.xcarchive' || fail "$output"
}

@test "the .app inside an .ipa is unzipped and verified" {
  mkdir -p "$BATS_TEST_TMPDIR/ipa/Payload"
  fake_app at="$BATS_TEST_TMPDIR/ipa/Payload" >/dev/null
  zip_dir "$dir/App.ipa" "$BATS_TEST_TMPDIR/ipa"
  verify "${RELEASE[@]}" "$dir/App.ipa" --no-signing
  [ "$status" -eq 0 ] || fail "status $status: $output"
  contains "$output" 'ok artifact: Fake.app from App.ipa' || fail "$output"
  contains "$output" 'ok version: 1.2.3' || fail "the unzipped Info.plist was not read: $output"
}

@test "the checklist goes to GITHUB_STEP_SUMMARY when CI set it" {
  local app
  app="$(fake_app)"
  verify "${RELEASE[@]}" GITHUB_STEP_SUMMARY="$BATS_TEST_TMPDIR/summary.md" "$app" --no-signing
  [ "$status" -eq 0 ] || fail "status $status: $output"
  contains "$(cat "$BATS_TEST_TMPDIR/summary.md")" '### iOS artifact verification' || fail "$(cat "$BATS_TEST_TMPDIR/summary.md")"
}

# --- usage ------------------------------------------------------------------

@test "usage errors and a missing artifact exit 2 without a checklist" {
  local app
  app="$(fake_app)"
  verify
  [ "$status" -eq 2 ] || fail "no artifact: $status $output"
  contains "$output" 'usage: verify-ios.sh' || fail "no usage line: $output"
  verify "$app" --bogus
  [ "$status" -eq 2 ] || fail "an unknown flag: $status $output"
  verify -h
  [ "$status" -eq 2 ] || fail "-h: $status $output"
  verify --help
  [ "$status" -eq 2 ] || fail "--help: $status $output"
  verify "$app" "$app"
  [ "$status" -eq 2 ] || fail "two artifacts: $status $output"
  verify "$app" --dsym
  [ "$status" -eq 2 ] || fail "--dsym with no path: $status $output"
  verify "$dir/absent.app"
  [ "$status" -eq 2 ] || fail "a missing artifact: $status $output"
  [ "$output" = "verify-ios.sh: no such artifact: $dir/absent.app" ] || fail "the message: $output"
}

@test "a repository root that does not exist exits 2 naming it" {
  local app
  app="$(fake_app)"
  verify WORKING_DIRECTORY=nowhere "$app" --no-signing
  [ "$status" -eq 2 ] || fail "status $status: $output"
  contains "$output" "verify-ios.sh: the repository root $repo/nowhere does not exist" || fail "$output"
}

# --- the artifact -----------------------------------------------------------

@test "an artifact that holds no .app fails with the checklist" {
  mkdir -p "$dir/Empty.xcarchive"
  verify "$dir/Empty.xcarchive" --no-signing
  [ "$status" -eq 1 ] || fail "status $status: $output"
  contains "$output" "FAIL artifact: no .app found in $dir/Empty.xcarchive" || fail "$output"
  contains "$output" 'iOS artifact verification — 1 checks, 1 failed' || fail "no tally: $output"
}

@test "an unsupported artifact type fails naming the types it takes" {
  mkdir -p "$dir/App.zip"
  verify "$dir/App.zip" --no-signing
  [ "$status" -eq 1 ] || fail "status $status: $output"
  contains "$output" "FAIL artifact: unsupported artifact type: $dir/App.zip (want .ipa, .xcarchive or .app)" || fail "$output"
}

@test "an .ipa unzip cannot read fails the artifact check with unzip's reason, not unzip's status" {
  # Bug fixed in the move: unzip ran bare under set -e, so a corrupt .ipa ended
  # the gate with unzip's status (9) and no checklist.
  printf 'not a zip' > "$dir/Broken.ipa"
  verify "$dir/Broken.ipa" --no-signing
  [ "$status" -eq 1 ] || fail "status $status: $output"
  contains "$output" "FAIL artifact: unzip could not read $dir/Broken.ipa: " || fail "$output"
  contains "$output" 'iOS artifact verification — 1 checks, 1 failed' || fail "no checklist: $output"
}

@test "an .ipa with no app in Payload fails" {
  mkdir -p "$BATS_TEST_TMPDIR/ipa/Payload"
  printf 'x' > "$BATS_TEST_TMPDIR/ipa/Payload/readme.txt"
  zip_dir "$dir/Empty.ipa" "$BATS_TEST_TMPDIR/ipa"
  verify "$dir/Empty.ipa" --no-signing
  [ "$status" -eq 1 ] || fail "status $status: $output"
  contains "$output" "FAIL artifact: no .app found in $dir/Empty.ipa" || fail "$output"
}

@test "with no unzip an .ipa cannot be opened: a skip, then no .app" {
  mkdir -p "$BATS_TEST_TMPDIR/ipa/Payload"
  fake_app at="$BATS_TEST_TMPDIR/ipa/Payload" >/dev/null
  zip_dir "$dir/App.ipa" "$BATS_TEST_TMPDIR/ipa"
  verify_on "$bin:$(bare_path unzip)" -- "$dir/App.ipa" --no-signing
  [ "$status" -eq 1 ] || fail "status $status: $output"
  contains "$output" 'skip artifact: requires unzip, which is not on PATH' || fail "$output"
  contains "$output" "FAIL artifact: no .app found in $dir/App.ipa" || fail "$output"
}

@test "an .app with no Info.plist fails, and so does every value read from it" {
  local app
  app="$(fake_app plist=no)"
  verify "${RELEASE[@]}" "$app" --no-signing
  [ "$status" -eq 1 ] || fail "status $status: $output"
  contains "$output" "FAIL info-plist: no Info.plist in $app" || fail "$output"
  contains "$output" "FAIL version: expected '1.2.3', got ''" || fail "$output"
  # No CFBundleExecutable to read, so the binary is named after the .app.
  contains "$output" 'ok arch: arm64 only' || fail "the executable fallback: $output"
}

# --- version, build number, bundle identifier -------------------------------

@test "a version that is not the one being released fails" {
  local app
  app="$(fake_app version=1.2.2)"
  verify "${RELEASE[@]}" "$app" --no-signing
  [ "$status" -eq 1 ] || fail "status $status: $output"
  contains "$output" "FAIL version: expected '1.2.3', got '1.2.2'" || fail "$output"
  contains "$output" 'ok build-number: 42' || fail "$output"
}

@test "a wrong build number or bundle identifier fails" {
  local app
  app="$(fake_app build=41 bundle_id=com.example.other)"
  verify "${RELEASE[@]}" "$app" --no-signing
  [ "$status" -eq 1 ] || fail "status $status: $output"
  contains "$output" "FAIL build-number: expected '42', got '41'" || fail "$output"
  contains "$output" "FAIL bundle-id: expected 'sv.blink.reactnativemobiletemplate', got 'com.example.other'" || fail "$output"
}

@test "with nothing expected, the values are reported as skips" {
  local app
  app="$(fake_app)"
  verify "$app" --no-signing
  [ "$status" -eq 0 ] || fail "status $status: $output"
  contains "$output" 'skip version: APP_VERSION not set; artifact says 1.2.3' || fail "$output"
  contains "$output" 'skip build-number: APP_BUILD_NUMBER not set; artifact says 42' || fail "$output"
  contains "$output" 'skip bundle-id: IOS_BUNDLE_ID not set; artifact says sv.blink.reactnativemobiletemplate' || fail "$output"
  contains "$output" 'skip ota: OTA_ENABLED not set; artifact says updates enabled=absent' || fail "$output"
}

@test "with no plutil every check it guards is a skip, and a FAIL under --strict" {
  local app
  app="$(fake_app)"
  rm "$bin/plutil"
  verify "${RELEASE[@]}" "$app" --no-signing
  [ "$status" -eq 0 ] || fail "status $status: $output"
  local check
  for check in version build-number bundle-id; do
    contains "$output" "skip $check: requires plutil, which is not on PATH" || fail "$check: $output"
  done
  verify "${RELEASE[@]}" "$app" --no-signing --strict
  [ "$status" -eq 1 ] || fail "--strict: status $status: $output"
  for check in version build-number bundle-id; do
    contains "$output" "FAIL $check: requires plutil, which is not on PATH (--strict)" || fail "$check: $output"
  done
}

@test "CI turns strict mode on by itself" {
  local app
  app="$(fake_app)"
  rm "$bin/plutil"
  verify "${RELEASE[@]}" CI=true "$app" --no-signing
  [ "$status" -eq 1 ] || fail "status $status: $output"
  contains "$output" 'FAIL version: requires plutil, which is not on PATH (--strict)' || fail "$output"
}

# --- architecture -----------------------------------------------------------

@test "an x86_64 slice fails the architecture check" {
  local app
  app="$(fake_app arch=x86_64)"
  verify "${RELEASE[@]}" "$app" --no-signing
  [ "$status" -eq 1 ] || fail "status $status: $output"
  contains "$output" 'FAIL arch: expected arm64 only, got x86_64' || fail "$output"
}

@test "no executable fails the architecture check, and no lipo skips it" {
  local app
  app="$(fake_app executable=Missing)"
  verify "${RELEASE[@]}" "$app" --no-signing
  [ "$status" -eq 1 ] || fail "status $status: $output"
  contains "$output" "FAIL arch: no executable at $app/Missing" || fail "$output"
  app="$(fake_app)"
  rm "$bin/lipo"
  verify "${RELEASE[@]}" "$app" --no-signing
  [ "$status" -eq 0 ] || fail "no lipo: status $status: $output"
  contains "$output" 'skip arch: requires lipo, which is not on PATH' || fail "$output"
}

# --- signing ----------------------------------------------------------------

@test "--no-signing skips every signing check" {
  local app
  app="$(fake_app)"
  verify "${RELEASE[@]}" "$app" --no-signing
  contains "$output" 'skip signing: --no-signing given (unsigned local build)' || fail "$output"
  contains "$output" 'skip provisioning: --no-signing given (unsigned local build)' || fail "$output"
  contains "$output" 'skip get-task-allow: --no-signing given (unsigned local build)' || fail "$output"
  not_contains "$(cat "$CALLS")" 'codesign' || fail "codesign ran: $(cat "$CALLS")"
}

@test "a team-signed app with a profile and no get-task-allow passes signing" {
  local app
  app="$(fake_app)"
  printf 'profile' > "$app/embedded.mobileprovision"
  verify "${RELEASE[@]}" "$app"
  [ "$status" -eq 0 ] || fail "status $status: $output"
  contains "$output" 'ok signing: Apple Distribution: Blink (TEAM123) (team TEAM123)' || fail "$output"
  contains "$output" 'ok provisioning: embedded.mobileprovision present' || fail "$output"
  contains "$output" 'ok get-task-allow: no get-task-allow entitlement' || fail "$output"
  contains "$(cat "$CALLS")" "codesign --verify --strict --verbose=2 $app" || fail "$(cat "$CALLS")"
}

@test "get-task-allow false passes, true fails" {
  local app
  app="$(fake_app)"
  printf 'profile' > "$app/embedded.mobileprovision"
  verify "${RELEASE[@]}" ENTITLEMENTS='<dict><key>get-task-allow</key>
  <false/></dict>' "$app"
  [ "$status" -eq 0 ] || fail "false: status $status: $output"
  contains "$output" 'ok get-task-allow: get-task-allow is false' || fail "$output"
  verify "${RELEASE[@]}" ENTITLEMENTS='<dict><key>get-task-allow</key>
	<true/></dict>' "$app"
  [ "$status" -eq 1 ] || fail "true: status $status: $output"
  contains "$output" 'FAIL get-task-allow: get-task-allow is true (a debug entitlement in a release build)' || fail "$output"
}

@test "an ad-hoc signature, a rejected one and a missing profile fail" {
  local app
  app="$(fake_app)"
  verify "${RELEASE[@]}" CODESIGN_DETAILS='Authority=Someone
TeamIdentifier=not set' "$app"
  [ "$status" -eq 1 ] || fail "status $status: $output"
  contains "$output" 'FAIL signing: signed without a team identifier (ad-hoc?): Someone' || fail "not set: $output"
  contains "$output" 'FAIL provisioning: no embedded.mobileprovision in the .app' || fail "$output"
  verify "${RELEASE[@]}" CODESIGN_DETAILS='' "$app"
  contains "$output" 'FAIL signing: signed without a team identifier (ad-hoc?): no authority' || fail "empty: $output"
  verify "${RELEASE[@]}" CODESIGN_VERIFY_EXIT=1 CODESIGN_VERIFY_OUT='code object is not signed at all
In architecture: arm64' "$app"
  [ "$status" -eq 1 ] || fail "status $status: $output"
  contains "$output" 'FAIL signing: codesign --verify failed: code object is not signed at all In architecture: arm64' || fail "$output"
}

@test "with no codesign both of its rows stay, and the profile is still checked" {
  # Bug fixed in the move: a missing codesign recorded one `signing` skip and
  # dropped provisioning and get-task-allow from the checklist altogether.
  local app
  app="$(fake_app)"
  rm "$bin/codesign"
  verify "${RELEASE[@]}" "$app"
  contains "$output" 'skip signing: requires codesign, which is not on PATH' || fail "$output"
  contains "$output" 'FAIL provisioning: no embedded.mobileprovision in the .app' || fail "$output"
  contains "$output" 'skip get-task-allow: requires codesign, which is not on PATH' || fail "$output"
  printf 'profile' > "$app/embedded.mobileprovision"
  verify "${RELEASE[@]}" "$app" --strict
  [ "$status" -eq 1 ] || fail "--strict: status $status: $output"
  contains "$output" 'FAIL signing: requires codesign, which is not on PATH (--strict)' || fail "$output"
  contains "$output" 'FAIL get-task-allow: requires codesign, which is not on PATH (--strict)' || fail "$output"
}

# --- OTA --------------------------------------------------------------------

# The fixtures are the contract with a generator this repository does not
# control, so assert what they say: if an Expo bump changes it, this fails here
# rather than in a release job.
@test "the captured prebuild Expo.plist still says what the gate assumes" {
  local plist
  plist="$(tr -d '\n' < "$FIXTURES/verify/ota/Expo.plist")"
  [[ "$plist" =~ \<key\>EXUpdatesRuntimeVersion\</key\>[[:space:]]*\<string\>file:fingerprint\</string\> ]] || fail "runtime version"
  [[ "$plist" =~ \<key\>expo-channel-name\</key\>[[:space:]]*\<string\>production\</string\> ]] || fail "channel"
}

@test "a real prebuilt Expo.plist and its fingerprint file pass" {
  local app
  app="$(fake_app expo="$(expo_plist)" fingerprint=$'fp-abc\n')"
  printf '{"fingerprint":{"ios":"fp-abc","android":"fp-xyz"}}' > "$dir/build-info.json"
  verify "${RELEASE[@]}" OTA_ENABLED=true BUILD_INFO_FILE="$dir/build-info.json" "$app" --no-signing
  [ "$status" -eq 0 ] || fail "status $status: $output"
  contains "$output" 'ok ota: updates enabled=true, matching OTA_ENABLED' || fail "$output"
  contains "$output" 'ok ota-url: https://updates.example.com/manifest' || fail "$output"
  contains "$output" 'ok ota-runtime-version: runtime version fp-abc matches the build fingerprint' || fail "$output"
  contains "$output" 'ok ota-channel: update channel production' || fail "$output"
}

@test "build-info.json defaults to the one at the repository root" {
  local app
  app="$(fake_app expo="$(expo_plist)" fingerprint=fp-abc)"
  printf '{"fingerprint":{"ios":"fp-other"}}' > "$repo/build-info.json"
  verify "${RELEASE[@]}" OTA_ENABLED=true "$app" --no-signing
  [ "$status" -eq 1 ] || fail "status $status: $output"
  contains "$output" 'FAIL ota-runtime-version: runtime version fp-abc does not match the build fingerprint fp-other' || fail "$output"
}

@test "the repository root is GITHUB_WORKSPACE/WORKING_DIRECTORY when CI sets them" {
  local app
  app="$(fake_app expo="$(expo_plist)" fingerprint=fp-abc)"
  mkdir -p "$BATS_TEST_TMPDIR/workspace/apps/mobile"
  printf '{"fingerprint":{"ios":"fp-abc"}}' > "$BATS_TEST_TMPDIR/workspace/apps/mobile/build-info.json"
  printf '{"fingerprint":{"ios":"fp-wrong"}}' > "$repo/build-info.json"
  verify "${RELEASE[@]}" OTA_ENABLED=true GITHUB_WORKSPACE="$BATS_TEST_TMPDIR/workspace" WORKING_DIRECTORY=apps/mobile \
    "$app" --no-signing
  [ "$status" -eq 0 ] || fail "status $status: $output"
  contains "$output" 'ok ota-runtime-version: runtime version fp-abc matches the build fingerprint' || fail "$output"
}

@test "the sentinel with no build-info to compare against passes" {
  local app
  app="$(fake_app expo="$(expo_plist)" fingerprint=fp-abc)"
  verify "${RELEASE[@]}" OTA_ENABLED=true BUILD_INFO_FILE="$dir/absent.json" "$app" --no-signing
  [ "$status" -eq 0 ] || fail "status $status: $output"
  contains "$output" 'ok ota-runtime-version: runtime version fp-abc (from file:fingerprint' || fail "$output"
}

@test "an OTA build whose app has no fingerprint file fails" {
  local app
  app="$(fake_app expo="$(expo_plist)")"
  verify "${RELEASE[@]}" OTA_ENABLED=true "$app" --no-signing
  [ "$status" -eq 1 ] || fail "status $status: $output"
  contains "$output" 'FAIL ota-runtime-version: runtime version is file:fingerprint but the artifact carries no fingerprint file' || fail "$output"
}

@test "a fingerprint that is not the one the build recorded fails" {
  local app
  app="$(fake_app expo="$(expo_plist)" fingerprint=stale-fp)"
  printf '{"fingerprint":{"ios":"fp-abc"}}' > "$dir/build-info.json"
  verify "${RELEASE[@]}" OTA_ENABLED=true BUILD_INFO_FILE="$dir/build-info.json" "$app" --no-signing
  [ "$status" -eq 1 ] || fail "status $status: $output"
  contains "$output" 'FAIL ota-runtime-version: runtime version stale-fp does not match' || fail "$output"
}

@test "a plist with no runtime version, no URL and the wrong channel fails each" {
  local app
  app="$(fake_app expo="$(expo_plist channel=internal drop=EXUpdatesRuntimeVersion,EXUpdatesURL)" fingerprint=fp-abc)"
  verify "${RELEASE[@]}" OTA_ENABLED=true "$app" --no-signing
  [ "$status" -eq 1 ] || fail "status $status: $output"
  contains "$output" 'FAIL ota-url: updates are enabled but Expo.plist carries no EXUpdatesURL' || fail "$output"
  contains "$output" 'FAIL ota-runtime-version: updates are enabled but the artifact carries no runtime version' || fail "$output"
  contains "$output" 'FAIL ota-channel: update channel internal, expected production' || fail "$output"
}

@test "a pinned runtime version is reported, and OTA_CHANNEL moves the expected channel" {
  local app
  app="$(fake_app expo="$(expo_plist runtime=1.0.0 channel=beta)")"
  verify "${RELEASE[@]}" OTA_ENABLED=true OTA_CHANNEL=beta "$app" --no-signing
  [ "$status" -eq 0 ] || fail "status $status: $output"
  contains "$output" 'ok ota-runtime-version: runtime version 1.0.0 (pinned literal, not a fingerprint policy)' || fail "$output"
  contains "$output" 'ok ota-channel: update channel beta' || fail "$output"
}

@test "an @string/ runtime version is resolved from the fingerprint file too" {
  local app
  app="$(fake_app expo="$(expo_plist runtime=@string/expo_runtime_version)" fingerprint=fp-abc)"
  verify "${RELEASE[@]}" OTA_ENABLED=true "$app" --no-signing
  contains "$output" 'ok ota-runtime-version: runtime version fp-abc (from @string/expo_runtime_version' || fail "$output"
}

@test "updates off leaves the OTA checks alone, and disagreeing with OTA_ENABLED fails" {
  local app
  app="$(fake_app expo="$(expo_plist enabled=false drop=EXUpdatesURL,EXUpdatesRuntimeVersion,EXUpdatesRequestHeaders)")"
  verify "${RELEASE[@]}" "$app" --no-signing
  [ "$status" -eq 0 ] || fail "status $status: $output"
  contains "$output" 'ok ota: updates enabled=false, matching OTA_ENABLED' || fail "$output"
  not_contains "$output" 'ota-runtime-version' || fail "$output"
  not_contains "$output" 'ota-channel' || fail "$output"
  verify "${RELEASE[@]}" OTA_ENABLED=true "$app" --no-signing
  [ "$status" -eq 1 ] || fail "status $status: $output"
  contains "$output" 'FAIL ota: OTA_ENABLED=true but the artifact says updates enabled=false' || fail "$output"
}

@test "no Expo.plist is no updates configuration, which fails an OTA build" {
  local app
  app="$(fake_app)"
  verify "${RELEASE[@]}" OTA_ENABLED=true "$app" --no-signing
  [ "$status" -eq 1 ] || fail "status $status: $output"
  contains "$output" 'FAIL ota: OTA_ENABLED=true but the artifact says updates enabled=absent' || fail "$output"
}

@test "an Expo.plist with no readable EXUpdatesEnabled counts as absent" {
  local app
  app="$(fake_app expo="$(expo_plist drop=EXUpdatesEnabled)")"
  verify "${RELEASE[@]}" "$app" --no-signing
  [ "$status" -eq 0 ] || fail "status $status: $output"
  contains "$output" 'ok ota: no updates configuration, matching OTA_ENABLED=false' || fail "$output"
}

@test "with no plutil an Expo.plist cannot be read: the ota row is a skip" {
  local app
  app="$(fake_app expo="$(expo_plist)")"
  rm "$bin/plutil"
  verify "${RELEASE[@]}" "$app" --no-signing
  contains "$output" 'skip ota: requires plutil, which is not on PATH' || fail "$output"
}

@test "the template's placeholder certificate warns, another passes, none is a skip" {
  local app
  app="$(fake_app expo="$(expo_plist)" fingerprint=fp-abc)"
  verify "${RELEASE[@]}" OTA_ENABLED=true "$app" --no-signing
  contains "$output" "skip ota-cert: no certs/expo-updates-cert.pem in $repo, or no shasum to hash it" || fail "none: $output"
  mkdir -p "$repo/certs"
  cp "$FIXTURES/verify/expo-updates-cert.pem" "$repo/certs/expo-updates-cert.pem"
  verify "${RELEASE[@]}" OTA_ENABLED=true "$app" --no-signing
  [ "$status" -eq 0 ] || fail "a warning failed the gate: $status $output"
  contains "$output" 'warn ota-cert: certs/expo-updates-cert.pem is still the template placeholder' || fail "placeholder: $output"
  printf 'a real certificate\n' > "$repo/certs/expo-updates-cert.pem"
  verify "${RELEASE[@]}" OTA_ENABLED=true "$app" --no-signing
  contains "$output" 'ok ota-cert: code-signing certificate is not the template placeholder' || fail "another: $output"
  verify_on "$bin:$(bare_path shasum)" "${RELEASE[@]}" OTA_ENABLED=true -- "$app" --no-signing
  contains "$output" "skip ota-cert: no certs/expo-updates-cert.pem in $repo, or no shasum to hash it" || fail "no shasum: $output"
}

# --- JS bundle --------------------------------------------------------------

@test "a plain-text bundle naming a Metro dev server fails twice over" {
  local app
  app="$(fake_app bundle='var u = "http://localhost:8081/index.bundle";')"
  verify "${RELEASE[@]}" "$app" --no-signing
  [ "$status" -eq 1 ] || fail "status $status: $output"
  contains "$output" 'FAIL dev-server: bundle references a Metro dev server' || fail "$output"
  contains "$output" 'FAIL hermes: not Hermes bytecode' || fail "$output"
}

@test "no bundle fails hermes and dev-server, and skips expo-public" {
  local app
  app="$(fake_app bundle=none)"
  verify "${RELEASE[@]}" "$app" --no-signing
  [ "$status" -eq 1 ] || fail "status $status: $output"
  contains "$output" "FAIL hermes: no JS bundle at $app/main.jsbundle" || fail "$output"
  contains "$output" "FAIL dev-server: no JS bundle at $app/main.jsbundle" || fail "$output"
  contains "$output" 'skip expo-public: no JS bundle to scan (the hermes check has failed it)' || fail "$output"
}

@test "no .env.example is nothing to check: a skip that names the repository" {
  local app
  app="$(fake_app)"
  verify "${RELEASE[@]}" "$app" --no-signing
  [ "$status" -eq 0 ] || fail "status $status: $output"
  contains "$output" "skip expo-public: no .env.example in $repo, so no EXPO_PUBLIC_* names to check" || fail "$output"
}

@test "the repository's .env.example names the EXPO_PUBLIC_* values the bundle must inline" {
  local app
  app="$(fake_app bundle='var API = "https://api.example.com/graphql";')"
  printf 'EXPO_PUBLIC_API_URL=\n' > "$repo/.env.example"
  verify APP_VERSION=1.2.3 EXPO_PUBLIC_API_URL=https://api.example.com/graphql "$app" --no-signing
  contains "$output" 'ok expo-public: inlined: EXPO_PUBLIC_API_URL (not checked: none)' || fail "$output"
  verify EXPO_PUBLIC_API_URL=https://other.example.com/graphql "$app" --no-signing
  [ "$status" -eq 1 ] || fail "status $status: $output"
  contains "$output" 'FAIL expo-public: value not inlined in the bundle: EXPO_PUBLIC_API_URL' || fail "$output"
}

# --- dSYM -------------------------------------------------------------------

@test "no --dsym is a skip, and one that does not exist fails" {
  local app
  app="$(fake_app)"
  verify "${RELEASE[@]}" "$app" --no-signing
  contains "$output" 'skip dsym-uuid: no --dsym given' || fail "$output"
  verify "${RELEASE[@]}" "$app" --no-signing --dsym "$dir/absent.dSYM"
  [ "$status" -eq 1 ] || fail "status $status: $output"
  contains "$output" "FAIL dsym-uuid: no such dSYM: $dir/absent.dSYM" || fail "$output"
}

@test "a dSYM directory that covers the binary passes, one that does not fails" {
  local app
  app="$(fake_app)"
  mkdir -p "$dir/dSYMs/Fake.app.dSYM"
  printf 'UUID: 1a2b3c4d-0000-0000-0000-000000000001 (arm64) Fake.app.dSYM\n' > "$dir/dSYMs/Fake.app.dSYM/uuid.txt"
  verify "${RELEASE[@]}" "$app" --no-signing --dsym "$dir/dSYMs"
  [ "$status" -eq 0 ] || fail "status $status: $output"
  contains "$output" 'ok dsym-uuid: dSYM covers 1A2B3C4D-0000-0000-0000-000000000001' || fail "$output"
  printf 'UUID: 99999999-0000-0000-0000-000000000009 (arm64) Other\n' > "$dir/dSYMs/Fake.app.dSYM/uuid.txt"
  verify "${RELEASE[@]}" "$app" --no-signing --dsym "$dir/dSYMs/Fake.app.dSYM"
  [ "$status" -eq 1 ] || fail "status $status: $output"
  contains "$output" 'FAIL dsym-uuid: dSYM does not cover binary UUID(s): 1A2B3C4D-0000-0000-0000-000000000001' || fail "$output"
}

@test "a zipped dSYM is unzipped and checked" {
  local app
  app="$(fake_app)"
  mkdir -p "$BATS_TEST_TMPDIR/dsym/Fake.app.dSYM"
  printf 'UUID: 1A2B3C4D-0000-0000-0000-000000000001 (arm64) Fake.app.dSYM\n' > "$BATS_TEST_TMPDIR/dsym/Fake.app.dSYM/uuid.txt"
  zip_dir "$dir/dSYMs.zip" "$BATS_TEST_TMPDIR/dsym"
  verify "${RELEASE[@]}" "$app" --no-signing --dsym "$dir/dSYMs.zip"
  [ "$status" -eq 0 ] || fail "status $status: $output"
  contains "$output" 'ok dsym-uuid: dSYM covers 1A2B3C4D' || fail "$output"
}

@test "a zipped dSYM unzip cannot read fails its one row, not the whole gate's exit" {
  # Bug fixed in the move: unzip ran bare under set -e here too.
  local app
  app="$(fake_app)"
  printf 'not a zip' > "$dir/dSYMs.zip"
  verify "${RELEASE[@]}" "$app" --no-signing --dsym "$dir/dSYMs.zip"
  [ "$status" -eq 1 ] || fail "status $status: $output"
  contains "$output" "FAIL dsym-uuid: unzip could not read $dir/dSYMs.zip: " || fail "$output"
  [ "$(grep -c 'dsym-uuid:' <<< "$output")" -eq 1 ] || fail "more than one dsym-uuid row: $output"
  contains "$output" 'iOS artifact verification — ' || fail "no checklist: $output"
}

@test "a missing dwarfdump or unzip leaves one skipped dsym-uuid row" {
  # Bug fixed in the move: with no unzip a zipped dSYM recorded the skip, then
  # searched the zip file as if it were a directory and added a second,
  # failing, dsym-uuid row.
  local app
  app="$(fake_app)"
  printf 'x' > "$dir/dSYMs.zip"
  verify_on "$bin:$(bare_path unzip)" "${RELEASE[@]}" -- "$app" --no-signing --dsym "$dir/dSYMs.zip"
  [ "$status" -eq 0 ] || fail "no unzip: status $status: $output"
  contains "$output" 'skip dsym-uuid: requires unzip, which is not on PATH' || fail "$output"
  [ "$(grep -c 'dsym-uuid:' <<< "$output")" -eq 1 ] || fail "more than one dsym-uuid row: $output"
  rm "$bin/dwarfdump"
  verify "${RELEASE[@]}" "$app" --no-signing --dsym "$dir/dSYMs.zip"
  [ "$status" -eq 0 ] || fail "no dwarfdump: status $status: $output"
  contains "$output" 'skip dsym-uuid: requires dwarfdump, which is not on PATH' || fail "$output"
}

# --- store metadata ---------------------------------------------------------

@test "placeholder store metadata in the repository warns without failing" {
  local app
  app="$(fake_app)"
  verify "${RELEASE[@]}" "$app" --no-signing
  contains "$output" "skip metadata: no fastlane/metadata tree at $repo/fastlane/metadata" || fail "none: $output"
  mkdir -p "$repo/fastlane/metadata/ios/en-US"
  printf 'Replace this text\n' > "$repo/fastlane/metadata/ios/en-US/description.txt"
  verify "${RELEASE[@]}" "$app" --no-signing
  [ "$status" -eq 0 ] || fail "status $status: $output"
  contains "$output" 'warn metadata: store metadata still has template placeholder text: fastlane/metadata/ios/en-US/description.txt' || fail "$output"
}

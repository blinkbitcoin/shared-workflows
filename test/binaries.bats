#!/usr/bin/env bats
# scripts/security/binaries.sh - extracts the evidence the OWASP MASTG checks
# need from a release APK (aapt2 for the manifest and the network security
# config, apksigner for the signature) and a release IPA (python3's plistlib
# for Info.plist, openssl for the provisioning profile), then hands it to
# security-binaries.mjs, which writes binaries.sarif. Fake aapt2, apksigner and
# openssl stand in for the real tools, on PATH or in a fake
# ANDROID_HOME/build-tools/<version>/; the IPA is a real zip python3 builds.
#
# Exit paths covered: switched off and nothing to check (skipped SARIFs, 0); a
# named APK or IPA that does not exist (1); the APK path (0), from APK or from
# SECURITY_BINARIES_DIR, with and without a network security config, and with
# the tools found on PATH, under ANDROID_HOME or ANDROID_SDK_ROOT; a network
# config the resource table cannot place and an APK apksigner rejects (1);
# the IPA path (0), with and without a provisioning profile; a file that is not
# an iOS archive (1); and each missing tool - aapt2, apksigner, python3,
# openssl - as a note locally and a failure (1) under CI.
#
# Every assertion ends in `|| fail "..."` - see test_helper.bash.
load test_helper

MANIFEST='N: android=http://schemas.android.com/apk/res/android (line=2)
  E: manifest (line=2)
      E: application (line=5)
        A: http://schemas.android.com/apk/res/android:debuggable(0x0101000f)=true
        A: http://schemas.android.com/apk/res/android:allowBackup(0x01010280)=false
        A: http://schemas.android.com/apk/res/android:networkSecurityConfig(0x01010527)=@0x7f150002'
PLAIN_MANIFEST='N: android=http://schemas.android.com/apk/res/android (line=2)
  E: manifest (line=2)
      E: application (line=5)
        A: http://schemas.android.com/apk/res/android:allowBackup(0x01010280)=false'
NSC='N: x
  E: network-security-config (line=1)
      E: base-config (line=2)
        A: cleartextTrafficPermitted=true'
RESOURCES='    resource 0x7f150002 xml/network_security_config
      () (file) res/xml/nsc.xml type=XML'
SIGNER='Verified using v2 scheme (APK Signature Scheme v2): true
Signer #1 key size (bits): 2048'
PROFILE_PLIST='<?xml version="1.0"?><plist version="1.0"><dict><key>Entitlements</key><dict><key>get-task-allow</key><true/></dict></dict></plist>'

setup() {
  unset CI GITHUB_WORKSPACE WORKING_DIRECTORY ANDROID_HOME ANDROID_SDK_ROOT APK IPA MANIFEST_TEXT RESOURCES_TEXT SIGNER_BODY
  local var
  for var in $(compgen -e | grep -E '^(SECURITY_|OPENAI_|ANTHROPIC_)' || true); do unset "$var"; done
  export SECURITY_SETTINGS_FILE="$BATS_TEST_TMPDIR/no-security-settings.json"
  export SECURITY_DIR="$BATS_TEST_TMPDIR/out"
  app="$BATS_TEST_TMPDIR/app"
  mkdir -p "$app"
  cd "$app" || return 1
  CALLS="$BATS_TEST_TMPDIR/calls"
  export CALLS
  : > "$CALLS"
  bin="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$bin"
}

# Writes fake aapt2 and apksigner into $1. aapt2 answers the manifest dump with
# $MANIFEST_TEXT, any other xmltree with the network config, and the resource
# dump with $RESOURCES_TEXT; apksigner runs $SIGNER_BODY. Both record calls.
android_tools() {
  local dir="$1"
  mkdir -p "$dir"
  printf '%s' "${MANIFEST_TEXT-$MANIFEST}" > "$BATS_TEST_TMPDIR/manifest.txt"
  printf '%s' "$NSC" > "$BATS_TEST_TMPDIR/nsc.txt"
  printf '%s' "${RESOURCES_TEXT-$RESOURCES}" > "$BATS_TEST_TMPDIR/resources.txt"
  printf '%s' "$SIGNER" > "$BATS_TEST_TMPDIR/signer.txt"
  cat > "$dir/aapt2" <<STUB
#!/usr/bin/env bash
printf '%s %s\n' "$dir/aapt2" "\$*" >> "$CALLS"
if [ "\$1 \$2" = "dump xmltree" ] && [ "\$4" = AndroidManifest.xml ]; then cat "$BATS_TEST_TMPDIR/manifest.txt"
elif [ "\$1 \$2" = "dump xmltree" ]; then cat "$BATS_TEST_TMPDIR/nsc.txt"
elif [ "\$1 \$2" = "dump resources" ]; then cat "$BATS_TEST_TMPDIR/resources.txt"
else exit 9; fi
STUB
  cat > "$dir/apksigner" <<STUB
#!/usr/bin/env bash
printf '%s %s\n' "$dir/apksigner" "\$*" >> "$CALLS"
${SIGNER_BODY:-cat "$BATS_TEST_TMPDIR/signer.txt"}
STUB
  chmod +x "$dir/aapt2" "$dir/apksigner"
}

# A fake openssl that "unwraps" any profile into $PROFILE_PLIST.
fake_openssl() {
  printf '%s' "$PROFILE_PLIST" > "$BATS_TEST_TMPDIR/profile.plist"
  cat > "$1/openssl" <<STUB
#!/usr/bin/env bash
printf 'openssl %s\n' "\$*" >> "$CALLS"
cat "$BATS_TEST_TMPDIR/profile.plist"
STUB
  chmod +x "$1/openssl"
}

# An IPA: a zip with Payload/App.app/Info.plist holding the Python literal $2,
# and a stand-in embedded.mobileprovision unless $3 is "no". $1 is its path.
make_ipa() {
  python3 -c '
import ast, plistlib, sys, zipfile
with zipfile.ZipFile(sys.argv[1], "w") as z:
    z.writestr("Payload/App.app/Info.plist", plistlib.dumps(ast.literal_eval(sys.argv[2])))
    if sys.argv[3] == "yes":
        z.writestr("Payload/App.app/embedded.mobileprovision", b"signed-blob")
' "$1" "$2" "${3:-yes}"
}

# A PATH with only what the runner needs, less the tools named in $@, so "the
# tool is missing" is true even on a machine that has it.
bare_path() {
  local dir="$BATS_TEST_TMPDIR/bare" tool found skip
  mkdir -p "$dir"
  for tool in bash env node mkdir grep dirname basename sed cat find sort head tail mktemp rm awk unzip python3 openssl pwd; do
    for skip in "$@"; do [ "$tool" = "$skip" ] && continue 2; done
    found="$(command -v "$tool" || true)"
    [ -z "$found" ] || ln -sf "$found" "$dir/$tool"
  done
  printf '%s' "$dir"
}

sarif_notes() {
  node -e 'const d = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
process.stdout.write((d.runs[0].invocations?.[0]?.toolExecutionNotifications ?? []).map((n) => n.message.text).join("\n"))' "$1"
}
rule_ids() {
  node -e 'const d = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
process.stdout.write(d.runs[0].results.map((r) => r.ruleId).join(" "))' "$1"
}
uris() {
  node -e 'const d = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
process.stdout.write([...new Set(d.runs[0].results.map((r) => r.locations[0].physicalLocation.artifactLocation.uri))].join(" "))' "$1"
}

binaries() { run bash "$REPO_ROOT/scripts/security/binaries.sh"; }
binaries_on() { local path="$1"; shift; run env PATH="$path" "$@" "$BASH" "$REPO_ROOT/scripts/security/binaries.sh"; }

@test "switched off, it writes a skipped SARIF and exits 0" {
  export SECURITY_BINARIES=false APK="$BATS_TEST_TMPDIR/a.apk"
  binaries
  [ "$status" -eq 0 ] || fail "status $status: $output"
  contains "$(sarif_notes "$SECURITY_DIR/binaries.sarif")" 'disabled' || fail "the skip does not say it is disabled"
}

@test "nothing to check is a skip that says how to give it something" {
  binaries
  [ "$status" -eq 0 ] || fail "status $status: $output"
  contains "$(sarif_notes "$SECURITY_DIR/binaries.sarif")" 'no binaries to check (set APK and/or IPA, or SECURITY_BINARIES_DIR)' \
    || fail "the skip gives no way forward"
}

@test "a SECURITY_BINARIES_DIR with no APK or IPA in it is the same skip" {
  export SECURITY_BINARIES_DIR="$BATS_TEST_TMPDIR/assets"
  mkdir -p "$SECURITY_BINARIES_DIR"
  printf 'x' > "$SECURITY_BINARIES_DIR/app.aab"
  binaries
  [ "$status" -eq 0 ] || fail "status $status: $output"
  contains "$(sarif_notes "$SECURITY_DIR/binaries.sarif")" 'no binaries to check' || fail "the AAB was taken for something to check"
}

@test "a named APK that does not exist fails the job" {
  export APK="$BATS_TEST_TMPDIR/nope.apk"
  binaries
  [ "$status" -eq 1 ] || fail "a missing APK passed with $status: $output"
  contains "$output" "binaries: no such file: $APK" || fail "the error does not name the file: $output"
}

@test "a named IPA that does not exist fails the job" {
  export IPA="$BATS_TEST_TMPDIR/nope.ipa"
  binaries
  [ "$status" -eq 1 ] || fail "a missing IPA passed with $status: $output"
  contains "$output" "binaries: no such file: $IPA" || fail "the error does not name the file: $output"
}

@test "the APK is read with aapt2 and apksigner, the network config through the resource table" {
  export APK="$BATS_TEST_TMPDIR/app-universal.apk"
  printf 'not really an apk' > "$APK"
  android_tools "$bin"
  binaries_on "$bin:$PATH"
  [ "$status" -eq 0 ] || fail "status $status: $output"
  contains "$output" "binaries: wrote $SECURITY_DIR/binaries.sarif" || fail "the log does not say where: $output"
  grep -qx "$bin/aapt2 dump xmltree --file AndroidManifest.xml $APK" "$CALLS" || fail "the manifest was not dumped: $(cat "$CALLS")"
  grep -qx "$bin/aapt2 dump resources $APK" "$CALLS" || fail "the resource table was not read: $(cat "$CALLS")"
  grep -qx "$bin/aapt2 dump xmltree --file res/xml/nsc.xml $APK" "$CALLS" || fail "the network config was not dumped: $(cat "$CALLS")"
  grep -qx "$bin/apksigner verify --print-certs -v $APK" "$CALLS" || fail "apksigner did not verify: $(cat "$CALLS")"
  [ "$(rule_ids "$SECURITY_DIR/binaries.sarif")" = 'MASTG-TEST-0226 MASTG-TEST-0235' ] \
    || fail "expected the debuggable and cleartext findings: $(rule_ids "$SECURITY_DIR/binaries.sarif")"
  [ "$(uris "$SECURITY_DIR/binaries.sarif")" = 'app-universal.apk' ] || fail "findings point at: $(uris "$SECURITY_DIR/binaries.sarif")"
}

@test "a manifest that names no network config skips the resource table" {
  export APK="$BATS_TEST_TMPDIR/a.apk" MANIFEST_TEXT="$PLAIN_MANIFEST"
  printf 'x' > "$APK"
  android_tools "$bin"
  binaries_on "$bin:$PATH"
  [ "$status" -eq 0 ] || fail "status $status: $output"
  ! grep -q 'dump resources' "$CALLS" || fail "the resource table was read with no config to find: $(cat "$CALLS")"
  [ -z "$(rule_ids "$SECURITY_DIR/binaries.sarif")" ] || fail "a clean manifest has findings: $(rule_ids "$SECURITY_DIR/binaries.sarif")"
}

@test "SECURITY_BINARIES_DIR supplies the APK and the IPA, the way CI hands them over" {
  export SECURITY_BINARIES_DIR="$BATS_TEST_TMPDIR/assets"
  mkdir -p "$SECURITY_BINARIES_DIR"
  printf 'x' > "$SECURITY_BINARIES_DIR/app.apk"
  printf 'x' > "$SECURITY_BINARIES_DIR/app.aab"
  make_ipa "$SECURITY_BINARIES_DIR/App.ipa" '{}'
  android_tools "$bin"
  fake_openssl "$bin"
  binaries_on "$bin:$PATH"
  [ "$status" -eq 0 ] || fail "status $status: $output"
  grep -qx "$bin/apksigner verify --print-certs -v $SECURITY_BINARIES_DIR/app.apk" "$CALLS" || fail "the APK was not picked up: $(cat "$CALLS")"
  grep -q '^openssl smime ' "$CALLS" || fail "the IPA was not picked up: $(cat "$CALLS")"
  [ "$(uris "$SECURITY_DIR/binaries.sarif")" = 'app.apk App.ipa' ] || fail "findings point at: $(uris "$SECURITY_DIR/binaries.sarif")"
}

@test "an APK named explicitly wins over the one in SECURITY_BINARIES_DIR" {
  export SECURITY_BINARIES_DIR="$BATS_TEST_TMPDIR/assets" APK="$BATS_TEST_TMPDIR/mine.apk"
  mkdir -p "$SECURITY_BINARIES_DIR"
  printf 'x' > "$SECURITY_BINARIES_DIR/app.apk"
  printf 'x' > "$APK"
  android_tools "$bin"
  binaries_on "$bin:$PATH"
  [ "$status" -eq 0 ] || fail "status $status: $output"
  grep -qx "$bin/apksigner verify --print-certs -v $APK" "$CALLS" || fail "the named APK was not the one read: $(cat "$CALLS")"
  ! grep -q "assets/app.apk" "$CALLS" || fail "the directory's APK was read too"
}

@test "the build tools come from the newest ANDROID_HOME build-tools when PATH has none" {
  export APK="$BATS_TEST_TMPDIR/a.apk" ANDROID_HOME="$BATS_TEST_TMPDIR/sdk"
  printf 'x' > "$APK"
  SIGNER_BODY='exit 9' android_tools "$ANDROID_HOME/build-tools/9.0.0"
  SIGNER_BODY='exit 9' android_tools "$ANDROID_HOME/build-tools/34.0.0"
  android_tools "$ANDROID_HOME/build-tools/35.0.0"
  binaries_on "$(bare_path)"
  [ "$status" -eq 0 ] || fail "status $status: $output"
  grep -q "^$ANDROID_HOME/build-tools/35.0.0/aapt2 dump xmltree" "$CALLS" || fail "not the newest aapt2: $(cat "$CALLS")"
  grep -q "^$ANDROID_HOME/build-tools/35.0.0/apksigner verify" "$CALLS" || fail "not the newest apksigner: $(cat "$CALLS")"
  ! grep -q -e '/9.0.0/' -e '/34.0.0/' "$CALLS" || fail "an older build-tools copy ran: $(cat "$CALLS")"
}

@test "ANDROID_SDK_ROOT stands in for ANDROID_HOME" {
  export APK="$BATS_TEST_TMPDIR/a.apk" ANDROID_SDK_ROOT="$BATS_TEST_TMPDIR/sdk"
  printf 'x' > "$APK"
  android_tools "$ANDROID_SDK_ROOT/build-tools/35.0.0"
  binaries_on "$(bare_path)"
  [ "$status" -eq 0 ] || fail "status $status: $output"
  grep -q "^$ANDROID_SDK_ROOT/build-tools/35.0.0/apksigner verify" "$CALLS" || fail "the SDK root was not searched: $(cat "$CALLS")"
}

@test "an SDK with no build-tools, or none holding the tool, leaves the tools missing" {
  export APK="$BATS_TEST_TMPDIR/a.apk" ANDROID_HOME="$BATS_TEST_TMPDIR/sdk"
  printf 'x' > "$APK"
  mkdir -p "$ANDROID_HOME/build-tools"
  binaries_on "$(bare_path)"
  [ "$status" -eq 0 ] || fail "an empty build-tools: status $status: $output"
  contains "$(sarif_notes "$SECURITY_DIR/binaries.sarif")" 'aapt2 is not installed' || fail "an empty build-tools found an aapt2"
  mkdir -p "$ANDROID_HOME/build-tools/35.0.0"
  binaries_on "$(bare_path)"
  [ "$status" -eq 0 ] || fail "a build-tools without the tool: status $status: $output"
  contains "$(sarif_notes "$SECURITY_DIR/binaries.sarif")" 'apksigner is not installed' || fail "an empty version directory found an apksigner"
}

@test "a network config the resource table cannot place fails the job" {
  export APK="$BATS_TEST_TMPDIR/a.apk" RESOURCES_TEXT='    resource 0x7f000000 xml/other'
  printf 'x' > "$APK"
  android_tools "$bin"
  binaries_on "$bin:$PATH"
  [ "$status" -eq 1 ] || fail "an unplaced config passed with $status: $output"
  contains "$output" 'names network security config 0x7f150002, but the resource table has no file for it' \
    || fail "the error does not name the reference: $output"
}

@test "an APK apksigner cannot verify fails the job and shows why" {
  export APK="$BATS_TEST_TMPDIR/a.apk" SIGNER_BODY='echo "DOES NOT VERIFY"; exit 1'
  printf 'x' > "$APK"
  android_tools "$bin"
  binaries_on "$bin:$PATH"
  [ "$status" -eq 1 ] || fail "an unverified APK passed with $status: $output"
  contains "$output" 'DOES NOT VERIFY' || fail "apksigner's output is not shown: $output"
  contains "$output" "binaries: apksigner could not verify $APK" || fail "the error does not name the APK: $output"
}

@test "missing build tools are notes locally, and the run still reports" {
  export APK="$BATS_TEST_TMPDIR/a.apk"
  printf 'x' > "$APK"
  binaries_on "$(bare_path)"
  [ "$status" -eq 0 ] || fail "status $status: $output"
  local notes
  notes="$(sarif_notes "$SECURITY_DIR/binaries.sarif")"
  contains "$notes" 'aapt2 is not installed (Android SDK build-tools; set ANDROID_HOME): those checks did not run' || fail "no aapt2 note: $notes"
  contains "$notes" 'apksigner is not installed (Android SDK build-tools; set ANDROID_HOME): those checks did not run' || fail "no apksigner note: $notes"
}

@test "a missing aapt2 fails under CI" {
  export APK="$BATS_TEST_TMPDIR/a.apk"
  printf 'x' > "$APK"
  binaries_on "$(bare_path)" CI=true
  [ "$status" -eq 1 ] || fail "a missing aapt2 passed under CI with $status: $output"
  contains "$output" 'aapt2 is not installed (Android SDK build-tools; set ANDROID_HOME), and under CI that is a failure' \
    || fail "the error: $output"
}

@test "a missing apksigner fails under CI, with aapt2 present" {
  export APK="$BATS_TEST_TMPDIR/a.apk"
  printf 'x' > "$APK"
  android_tools "$BATS_TEST_TMPDIR/tools"
  mkdir -p "$BATS_TEST_TMPDIR/aapt2-only"
  ln -s "$BATS_TEST_TMPDIR/tools/aapt2" "$BATS_TEST_TMPDIR/aapt2-only/aapt2"
  binaries_on "$BATS_TEST_TMPDIR/aapt2-only:$(bare_path)" CI=true
  [ "$status" -eq 1 ] || fail "a missing apksigner passed under CI with $status: $output"
  contains "$output" 'apksigner is not installed (Android SDK build-tools; set ANDROID_HOME), and under CI that is a failure' \
    || fail "the error: $output"
  grep -q 'aapt2 dump xmltree' "$CALLS" || fail "aapt2 did not run before the failure: $(cat "$CALLS")"
}

@test "the IPA is read through plistlib and its provisioning profile" {
  export IPA="$BATS_TEST_TMPDIR/App.ipa"
  make_ipa "$IPA" '{"NSAppTransportSecurity": {"NSAllowsArbitraryLoads": True}}'
  fake_openssl "$bin"
  binaries_on "$bin:$PATH"
  [ "$status" -eq 0 ] || fail "status $status: $output"
  grep -q '^openssl smime -inform der -verify -noverify -in .*/Payload/App.app/embedded.mobileprovision$' "$CALLS" \
    || fail "the profile was not unwrapped: $(cat "$CALLS")"
  [ "$(rule_ids "$SECURITY_DIR/binaries.sarif")" = 'MASTG-TEST-0261 MASTG-TEST-0322' ] \
    || fail "expected the get-task-allow and ATS findings: $(rule_ids "$SECURITY_DIR/binaries.sarif")"
  [ "$(uris "$SECURITY_DIR/binaries.sarif")" = 'App.ipa' ] || fail "findings point at: $(uris "$SECURITY_DIR/binaries.sarif")"
}

@test "an IPA with no provisioning profile says get-task-allow went unchecked" {
  export IPA="$BATS_TEST_TMPDIR/App.ipa"
  make_ipa "$IPA" '{}' no
  fake_openssl "$bin"
  binaries_on "$bin:$PATH"
  [ "$status" -eq 0 ] || fail "status $status: $output"
  contains "$(sarif_notes "$SECURITY_DIR/binaries.sarif")" 'App.ipa carries no embedded.mobileprovision: the get-task-allow check did not run' \
    || fail "no note: $(sarif_notes "$SECURITY_DIR/binaries.sarif")"
  ! grep -q '^openssl ' "$CALLS" || fail "openssl ran with no profile"
}

@test "a file that is not an iOS archive fails the job" {
  export IPA="$BATS_TEST_TMPDIR/broken.ipa"
  printf 'not a zip' > "$IPA"
  fake_openssl "$bin"
  binaries_on "$bin:$PATH"
  [ "$status" -eq 1 ] || fail "a broken IPA passed with $status: $output"
  contains "$output" "binaries: $IPA has no Payload/*.app/Info.plist - not an iOS app archive" || fail "the error: $output"
}

@test "without python3 the iOS checks are a note locally and a failure under CI" {
  export IPA="$BATS_TEST_TMPDIR/App.ipa"
  make_ipa "$IPA" '{}'
  binaries_on "$(bare_path python3)"
  [ "$status" -eq 0 ] || fail "status $status: $output"
  contains "$(sarif_notes "$SECURITY_DIR/binaries.sarif")" "python3 is not installed (it reads the IPA's property lists): those checks did not run" \
    || fail "no python3 note"
  binaries_on "$(bare_path python3)" CI=true
  [ "$status" -eq 1 ] || fail "a missing python3 passed under CI with $status: $output"
  contains "$output" 'python3 is not installed' || fail "the error: $output"
}

@test "without openssl the iOS checks are a note locally and a failure under CI" {
  export IPA="$BATS_TEST_TMPDIR/App.ipa"
  make_ipa "$IPA" '{}'
  rm -rf "$BATS_TEST_TMPDIR/bare"
  binaries_on "$(bare_path openssl)"
  [ "$status" -eq 0 ] || fail "status $status: $output"
  contains "$(sarif_notes "$SECURITY_DIR/binaries.sarif")" 'openssl is not installed (it unwraps the provisioning profile): those checks did not run' \
    || fail "no openssl note"
  binaries_on "$(bare_path openssl)" CI=true
  [ "$status" -eq 1 ] || fail "a missing openssl passed under CI with $status: $output"
  contains "$output" 'openssl is not installed' || fail "the error: $output"
}

#!/bin/bash
# Offline tests for the store-setup skill: state.sh, preflight.sh and
# identifiers.sh. No network, no real gh/bundle/fastlane, no real console —
# gh and bundle are shell fakes on PATH, and REPO_ROOT/STORE_SETUP_DIR point
# at scratch directories under a temp dir.
#
#   ./tests/run.sh

set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$TESTS_DIR/.." && pwd)"
STATE="$SKILL_DIR/scripts/state.sh"
PREFLIGHT="$SKILL_DIR/scripts/preflight.sh"
IDENTIFIERS="$SKILL_DIR/scripts/identifiers.sh"
SKILL_MD="$SKILL_DIR/SKILL.md"
MODES_MD="$SKILL_DIR/references/modes.md"

# Resolved once, up front: the preflight PATH-manipulation tests below build a
# deliberately minimal PATH (no /usr/bin, no /bin) to control exactly which
# tools preflight.sh can see, so `bash` itself has to be invoked by absolute
# path rather than relying on PATH or the script's own #!/usr/bin/env shebang.
BASH_BIN="$(command -v bash)"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/store-setup-tests.XXXXXX")"
PASS=0
FAIL=0
trap 'rm -rf "$WORK"' EXIT

ok() {
  PASS=$((PASS + 1))
  printf '  \033[32mPASS\033[0m %s\n' "$1"
}
bad() {
  FAIL=$((FAIL + 1))
  printf '  \033[31mFAIL\033[0m %s\n       %s\n' "$1" "$2"
}
check() {
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected '$2', got '$3'"; fi
}

# --- fakes -------------------------------------------------------------------
# `gh`: records argv, serves auth status ok, repo view resolving, and
# `variable list` from whatever $FAKE_GH_VARS points at.
FAKEBIN="$WORK/fakebin"
mkdir -p "$FAKEBIN"
cat >"$FAKEBIN/gh" <<'FAKE_GH'
#!/bin/bash
echo "$@" >>"${GH_LOG:-/dev/null}"
if [ "$1" = "auth" ] && [ "$2" = "status" ]; then
  exit 0
fi
if [ "$1" = "repo" ] && [ "$2" = "view" ]; then
  echo '{"nameWithOwner":"acme/app"}'
  exit 0
fi
if [ "$1" = "variable" ] && [ "$2" = "list" ]; then
  cat "${FAKE_GH_VARS:?FAKE_GH_VARS not set}"
  exit 0
fi
exit 1
FAKE_GH
chmod +x "$FAKEBIN/gh"

cat >"$FAKEBIN/bundle" <<'FAKE_BUNDLE'
#!/bin/bash
if [ "$1" = "--version" ]; then
  echo "Bundler version 2.5.0"
  exit 0
fi
if [ "$1" = "exec" ] && [ "$2" = "fastlane" ]; then
  echo "fastlane 2.239.0"
  exit 0
fi
exit 1
FAKE_BUNDLE
chmod +x "$FAKEBIN/bundle"

export GH_LOG="$WORK/gh.log"
export PATH="$FAKEBIN:$PATH"

# --- scratch repos -------------------------------------------------------------
REPO_RNMT="$WORK/repo-rnmt"
mkdir -p "$REPO_RNMT"
cat >"$REPO_RNMT/app.config.ts" <<'EOF'
const iosBundleId = 'com.example.rnmt';
const androidPackage = 'com.example.rnmt';
EOF
cat >"$REPO_RNMT/package.json" <<'EOF'
{ "name": "rn-mobile-template" }
EOF

REPO_ACME="$WORK/repo-acme"
mkdir -p "$REPO_ACME"
cat >"$REPO_ACME/app.config.ts" <<'EOF'
const iosBundleId = 'com.acme.app';
const androidPackage = 'com.acme.app';
EOF
cat >"$REPO_ACME/package.json" <<'EOF'
{ "name": "acme-app" }
EOF

VARS_RNMT="$WORK/vars-rnmt.json"
cat >"$VARS_RNMT" <<'EOF'
[{"name":"IOS_BUNDLE_ID","value":"com.example.rnmt"},{"name":"ANDROID_PACKAGE","value":"com.example.rnmt"},{"name":"IOS_SCHEME","value":"rnmt"}]
EOF

VARS_ACME_DISAGREE="$WORK/vars-acme.json"
cat >"$VARS_ACME_DISAGREE" <<'EOF'
[{"name":"IOS_BUNDLE_ID","value":"com.acme.app"},{"name":"ANDROID_PACKAGE","value":"com.acme.app"},{"name":"IOS_SCHEME","value":"acme"}]
EOF

VARS_MISSING_SCHEME="$WORK/vars-acme-no-scheme.json"
cat >"$VARS_MISSING_SCHEME" <<'EOF'
[{"name":"IOS_BUNDLE_ID","value":"com.acme.app"},{"name":"ANDROID_PACKAGE","value":"com.acme.app"}]
EOF

# The exact 49-id vocabulary Tasks 3, 4 and 5 depend on, in order.
EXPECTED_STEPS="preflight
identifiers
apple-enrolment
apple-agreements
apple-bundle-id
apple-app-record
apple-asc-key
cred-asc-key
apple-match-repo
cred-match
apple-testflight-groups
apple-privacy-labels
apple-pricing
google-account
google-app-record
cred-upload-keystore
google-play-app-signing
google-service-account
google-play-grant
cred-play-json
google-tracks
google-store-listing-fields
google-content-rating
google-data-safety
google-target-audience
google-app-access
google-pricing
meta-scaffold
meta-ios-copy
meta-android-copy
meta-images
meta-age-rating
meta-review-info
cred-push
gh-environments
toggle-signing
rehearse-dry-run
meta-sync
first-play-upload
toggle-uploads
store-ready
huawei-account
huawei-app-record
huawei-api-client
cred-huawei
huawei-app-signing
huawei-listing
toggle-huawei
huawei-testers"

json_field() {
  # json_field <file> <js-expression-on-obj-named-s>
  node -e "const s = JSON.parse(require('fs').readFileSync(process.argv[1], 'utf8')); process.stdout.write(String($2));" "$1"
}

echo
echo "state.sh guard before init"

export STORE_SETUP_DIR="$WORK/store-unguarded"
out=$("$STATE" next 2>&1)
rc=$?
check "next before init exits 2 (gated, not a crash)" "2" "$rc"
check "next before init prints no stack trace" "no" \
  "$(printf '%s\n' "$out" | grep -Eq '^node:|^[[:space:]]*at ' && echo yes || echo no)"

mkdir -p "$STORE_SETUP_DIR"
cat >"$STORE_SETUP_DIR/state.json" <<'EOF'
{ "schema": 1, "mode": null, "steps": {}, "facts": {} }
EOF
"$STATE" get identifiers >/dev/null 2>&1
check "get on a step absent from an older state.json exits 2, not a crash" "2" "$?"

echo
echo "state.sh init"

export STORE_SETUP_DIR="$WORK/store-init"
out=$("$STATE" init)
rc=$?
check "init exits 0" "0" "$rc"
check "init creates state.json" "yes" "$([ -f "$STORE_SETUP_DIR/state.json" ] && echo yes || echo no)"
check "schema is 1" "1" "$(json_field "$STORE_SETUP_DIR/state.json" 's.schema')"
check "every step starts todo" "49" "$(json_field "$STORE_SETUP_DIR/state.json" 'Object.values(s.steps).filter((x) => x.status === "todo").length')"
check "state.json ends with a trailing newline" "yes" "$([ -n "$(tail -c1 "$STORE_SETUP_DIR/state.json")" ] && echo no || echo yes)"

out2=$("$STATE" init)
rc2=$?
check "second init exits 0" "0" "$rc2"
check "second init prints the state.json path" "yes" "$(printf '%s' "$out2" | grep -qF "$STORE_SETUP_DIR/state.json" && echo yes || echo no)"

"$STATE" set preflight "done" >/dev/null
"$STATE" init >/dev/null
check "second init leaves the file unchanged" "done" "$("$STATE" get preflight)"

"$STATE" init --force >/dev/null
check "init --force resets" "todo" "$("$STATE" get preflight)"

echo
echo "state.sh mode"

"$STATE" mode browser-pause >/dev/null
check "mode accepted exits 0" "0" "$?"
check "mode is recorded" "browser-pause" "$(json_field "$STORE_SETUP_DIR/state.json" 's.mode')"
"$STATE" mode nonsense >/dev/null 2>&1
check "unknown mode exits 64" "64" "$?"

echo
echo "state.sh set / get"

"$STATE" set identifiers "done" >/dev/null
check "set then get round-trips" "done" "$("$STATE" get identifiers)"
"$STATE" set nope "done" >/dev/null 2>&1
check "set on an unknown step exits 64" "64" "$?"
"$STATE" set identifiers weird >/dev/null 2>&1
check "set with an unknown status exits 64" "64" "$?"

echo
echo "state.sh next"

export STORE_SETUP_DIR="$WORK/store-next"
"$STATE" init >/dev/null
check "next on a fresh state is preflight" "preflight" "$("$STATE" next)"
"$STATE" set preflight "done" >/dev/null
check "next after preflight is identifiers" "identifiers" "$("$STATE" next)"
"$STATE" set identifiers "done" >/dev/null
check "next --all lists exactly the four unblocked steps" \
  "apple-enrolment
google-account
cred-upload-keystore
meta-scaffold" "$("$STATE" next --all)"

while read -r id; do
  "$STATE" set "$id" "done" >/dev/null
done < <("$STATE" --list-steps)
"$STATE" next >/dev/null 2>&1
check "next exits 3 when nothing is left" "3" "$?"

echo
echo "state.sh note"

export STORE_SETUP_DIR="$WORK/store-note"
"$STATE" init >/dev/null
"$STATE" note apple_team_id A1B2C3D4E5 >/dev/null
check "note accepted exits 0" "0" "$?"
check "note is stored under facts" "A1B2C3D4E5" "$(json_field "$STORE_SETUP_DIR/state.json" 's.facts.apple_team_id')"

before="$(cat "$STORE_SETUP_DIR/state.json")"
"$STATE" note MATCH_PASSWORD x >/dev/null 2>&1
check "a password-shaped key exits 1" "1" "$?"
check "the file is unchanged after refusal" "$before" "$(cat "$STORE_SETUP_DIR/state.json")"
"$STATE" note asc_key_p8 x >/dev/null 2>&1
check "a p8-shaped key exits 1" "1" "$?"
"$STATE" note demo_password x >/dev/null 2>&1
check "a password-shaped key (any case) exits 1" "1" "$?"

echo
echo "state.sh render / --list-steps"

export STORE_SETUP_DIR="$WORK/store-render"
"$STATE" init >/dev/null
check "render lists every step exactly once" "49" "$("$STATE" render --markdown | wc -l | tr -d ' ')"
check "--list-steps matches the spec exactly, in order" "$EXPECTED_STEPS" "$("$STATE" --list-steps)"

"$STATE" set preflight doing >/dev/null
"$STATE" set identifiers skipped >/dev/null
RENDER_OUT="$("$STATE" render --markdown)"
check "doing renders as - [~], distinct from todo" "- [~] preflight" \
  "$(printf '%s\n' "$RENDER_OUT" | grep '^- \[.\] preflight$')"
check "skipped renders as - [-], distinct from done" "- [-] identifiers" \
  "$(printf '%s\n' "$RENDER_OUT" | grep '^- \[.\] identifiers$')"
check "an untouched step still renders as - [ ]" "- [ ] apple-enrolment" \
  "$(printf '%s\n' "$RENDER_OUT" | grep '^- \[.\] apple-enrolment$')"

echo
echo "preflight.sh"

FAKEBIN_NOGH="$WORK/fakebin-nogh"
mkdir -p "$FAKEBIN_NOGH"
for t in git node openssl base64 keytool sips; do
  p="$(command -v "$t" 2>/dev/null || true)"
  [ -n "$p" ] && ln -sf "$p" "$FAKEBIN_NOGH/$t"
done
cp "$FAKEBIN/bundle" "$FAKEBIN_NOGH/bundle"
PATH="$FAKEBIN_NOGH" "$BASH_BIN" "$PREFLIGHT" >/dev/null 2>&1
check "preflight fails with gh missing from PATH" "1" "$?"

FAKEBIN_WARN="$WORK/fakebin-warn"
mkdir -p "$FAKEBIN_WARN"
for t in git node openssl base64 keytool; do
  p="$(command -v "$t" 2>/dev/null || true)"
  [ -n "$p" ] && ln -sf "$p" "$FAKEBIN_WARN/$t"
done
cp "$FAKEBIN/gh" "$FAKEBIN/bundle" "$FAKEBIN_WARN/"
PATH="$FAKEBIN_WARN" FAKE_GH_VARS="$VARS_ACME_DISAGREE" "$BASH_BIN" "$PREFLIGHT" >/dev/null 2>&1
check "preflight passes when only sips/magick are missing (warn only)" "0" "$?"

out=$(PATH="$FAKEBIN_WARN" FAKE_GH_VARS="$VARS_ACME_DISAGREE" "$BASH_BIN" "$PREFLIGHT" --json 2>&1)
check "--json is valid JSON" "yes" \
  "$(printf '%s' "$out" | node -e 'JSON.parse(require("fs").readFileSync(0, "utf8")); process.stdout.write("yes")' 2>/dev/null || echo no)"

echo
echo "identifiers.sh"

out=$(REPO_ROOT="$REPO_RNMT" FAKE_GH_VARS="$VARS_RNMT" "$IDENTIFIERS" 2>&1)
check "template placeholder identifiers exit 2" "2" "$?"
check "the remedy names make init" "yes" "$(printf '%s' "$out" | grep -q 'make init' && echo yes || echo no)"

out=$(REPO_ROOT="$REPO_RNMT" FAKE_GH_VARS="$VARS_ACME_DISAGREE" "$IDENTIFIERS" 2>&1)
check "gh vars disagreeing with app.config.ts exit 2" "2" "$?"
check "the message says they disagree" "yes" "$(printf '%s' "$out" | grep -qi 'disagree' && echo yes || echo no)"

out=$(REPO_ROOT="$REPO_ACME" FAKE_GH_VARS="$VARS_ACME_DISAGREE" "$IDENTIFIERS" 2>&1)
check "a consistent repo exits 0" "0" "$?"

out=$(REPO_ROOT="$REPO_ACME" FAKE_GH_VARS="$VARS_MISSING_SCHEME" "$IDENTIFIERS" 2>&1)
check "a missing IOS_SCHEME variable exits 2" "2" "$?"
check "the remedy gives the exact gh variable set line" "yes" \
  "$(printf '%s' "$out" | grep -q "gh variable set IOS_SCHEME --body" && echo yes || echo no)"

VARS_TAB="$WORK/vars-acme-tab.json"
cat >"$VARS_TAB" <<'EOF'
[{"name":"IOS_BUNDLE_ID","value":"com.acme.app\textra"},{"name":"ANDROID_PACKAGE","value":"com.acme.app"},{"name":"IOS_SCHEME","value":"acme"}]
EOF
out=$(REPO_ROOT="$REPO_ACME" FAKE_GH_VARS="$VARS_TAB" "$IDENTIFIERS" 2>&1)
check "a tab embedded in a variable value still exits 2 (not silently truncated)" "2" "$?"

# A bare React Native app has no app.config.*: its identifiers are in the Xcode
# project and in android/app/build.gradle, and those are what the gh variables
# are compared with.
REPO_BARE="$WORK/repo-bare"
mkdir -p "$REPO_BARE/ios/Acme.xcodeproj" "$REPO_BARE/android/app"
printf '\t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = com.acme.app;\n' >"$REPO_BARE/ios/Acme.xcodeproj/project.pbxproj"
printf 'android {\n    defaultConfig {\n        applicationId "com.acme.app"\n    }\n}\n' >"$REPO_BARE/android/app/build.gradle"
printf '{ "name": "acme-app" }\n' >"$REPO_BARE/package.json"
out=$(REPO_ROOT="$REPO_BARE" FAKE_GH_VARS="$VARS_ACME_DISAGREE" "$IDENTIFIERS" 2>&1)
check "a bare app whose native projects match the gh variables exits 0" "0" "$?"
check "...and says where it found them" "yes" "$(printf '%s' "$out" | grep -q "app's own configuration" && echo yes || echo no)"

VARS_BARE_OTHER="$WORK/vars-bare-other.json"
cat >"$VARS_BARE_OTHER" <<'EOF'
[{"name":"IOS_BUNDLE_ID","value":"com.other.app"},{"name":"ANDROID_PACKAGE","value":"com.other.app"},{"name":"IOS_SCHEME","value":"acme"}]
EOF
out=$(REPO_ROOT="$REPO_BARE" FAKE_GH_VARS="$VARS_BARE_OTHER" "$IDENTIFIERS" 2>&1)
check "a bare app whose native projects disagree with the gh variables exits 2" "2" "$?"
check "...naming the Xcode project and build.gradle as the place to fix" "yes" "$(printf '%s' "$out" | grep -q 'Xcode project or build.gradle' && echo yes || echo no)"

REPO_NOCONFIG="$WORK/repo-noconfig"
mkdir -p "$REPO_NOCONFIG"
printf '{ "name": "acme-app" }\n' >"$REPO_NOCONFIG/package.json"
out=$(REPO_ROOT="$REPO_NOCONFIG" FAKE_GH_VARS="$VARS_ACME_DISAGREE" "$IDENTIFIERS" 2>&1)
check "a repo with no app configuration at all cannot be checked, and exits 1" "1" "$?"
check "...and says which files it looked for" "yes" "$(printf '%s' "$out" | grep -q 'app.json, ios/\*\*/project.pbxproj' && echo yes || echo no)"

echo
echo "SKILL.md and references/modes.md"

check "SKILL.md names the guided mode" "yes" "$(grep -q 'guided' "$SKILL_MD" && echo yes || echo no)"
check "SKILL.md names the browser-pause mode" "yes" "$(grep -q 'browser-pause' "$SKILL_MD" && echo yes || echo no)"
check "SKILL.md names the browser-full mode" "yes" "$(grep -q 'browser-full' "$SKILL_MD" && echo yes || echo no)"
check "SKILL.md carries the mode prompt verbatim" "yes" \
  "$(grep -qF 'Store setup is roughly forty console steps across two consoles, some irreversible.' "$SKILL_MD" && echo yes || echo no)"
check "SKILL.md has the always-confirm table" "yes" "$(grep -q 'Play App Signing' "$SKILL_MD" && echo yes || echo no)"
check "SKILL.md prohibits match nuke" "yes" "$(grep -qi 'nuke' "$SKILL_MD" && echo yes || echo no)"
check "SKILL.md documents state.sh next" "yes" "$(grep -q 'state.sh next' "$SKILL_MD" && echo yes || echo no)"
# shellcheck disable=SC2016 # the pattern is a literal regex, not a shell expansion
check "SKILL.md checklist has all 49 ids" "49" "$(grep -cE '^\| `[a-z-]+` \|' "$SKILL_MD")"

# shellcheck disable=SC2016 # the patterns are literal regexes, not shell expansions
SKILL_MD_IDS="$(grep -oE '^\| `[a-z0-9-]+` \|' "$SKILL_MD" | sed -E 's/^\| `//; s/` \|$//')"
check "SKILL.md checklist ids match state.sh --list-steps exactly, in order" "" \
  "$(diff <(printf '%s\n' "$SKILL_MD_IDS") <("$STATE" --list-steps))"

check "modes.md carries the mode prompt verbatim too" "yes" \
  "$(grep -qF 'Store setup is roughly forty console steps across two consoles, some irreversible.' "$MODES_MD" && echo yes || echo no)"
check "modes.md carries the always-confirm table too" "yes" "$(grep -q 'Play App Signing' "$MODES_MD" && echo yes || echo no)"
# The two always-confirm tables must be byte-identical: a row added to one and
# not the other is a gate the other document does not know about.
check "the always-confirm table in SKILL.md and modes.md is byte-identical" "" \
  "$(diff <(sed -n '/^| Step | Why |/,/^$/p' "$SKILL_MD") <(sed -n '/^| Step | Why |/,/^$/p' "$MODES_MD"))"
check "modes.md documents login walls and 2FA" "yes" "$(grep -qi '2FA' "$MODES_MD" && echo yes || echo no)"
check "modes.md refuses 'I picked (a), just accept it' by example" "yes" \
  "$(grep -qF 'just accept it' "$MODES_MD" && echo yes || echo no)"
check "modes.md says an irreversible step never proceeds while the human is away" "yes" \
  "$(grep -qF 'never proceeds while the human is away' "$MODES_MD" && echo yes || echo no)"
check "SKILL.md names the claude-in-chrome skill for the browser modes" "yes" \
  "$(grep -qF 'claude-in-chrome' "$SKILL_MD" && echo yes || echo no)"
check "SKILL.md warns that state.sh set's free-text note is not screened" "yes" \
  "$(grep -qF 'that text is not screened' "$SKILL_MD" && echo yes || echo no)"

# I5: allowed-tools is a comma-separated list of Bash(prefix:*) patterns -
# space-separated entries or `Bash(cmd *)` globs are not what Claude Code
# parses.
ALLOWED_TOOLS_LINE="$(grep -m1 '^allowed-tools:' "$SKILL_MD")"
check "SKILL.md's allowed-tools line is comma-separated" "yes" \
  "$(printf '%s' "$ALLOWED_TOOLS_LINE" | grep -qF ',' && echo yes || echo no)"
check "SKILL.md's allowed-tools line uses the :* prefix form" "yes" \
  "$(printf '%s' "$ALLOWED_TOOLS_LINE" | grep -qF ':*' && echo yes || echo no)"

echo
echo "-------------------------------------"
printf '%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1

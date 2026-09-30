#!/usr/bin/env bash
# OWASP MASTG checks over the release binaries: the universal APK and the IPA.
# This extracts the evidence with each platform's own tools; security-binaries.mjs
# decides what it means. Findings do not fail this script.
#
# Where the binaries come from:
#   CI      $SECURITY_BINARIES_DIR, which check-security.yml fills from the
#           release tag's assets (*.apk, *.aab, *.ipa)
#   laptop  APK=path/to/app.apk IPA=path/to/app.ipa (either or both), the same
#           variables the release verifiers read
#
# The AAB is the same bundle the universal APK was built from - verify-android
# asserts that - so the APK is the one read: aapt2 and apksigner understand it
# directly, and an AAB alone would need bundletool.
set -euo pipefail
# shellcheck source=scripts/security/lib/runner.sh
source "$(dirname "$0")/lib/runner.sh"

sec_enabled binaries

apk="${APK:-}"
ipa="${IPA:-}"
if [ -n "${SECURITY_BINARIES_DIR:-}" ]; then
  [ -n "$apk" ] || apk="$(find "$SECURITY_BINARIES_DIR" -maxdepth 1 -name '*.apk' | sort | head -1)"
  [ -n "$ipa" ] || ipa="$(find "$SECURITY_BINARIES_DIR" -maxdepth 1 -name '*.ipa' | sort | head -1)"
fi
if [ -z "$apk" ] && [ -z "$ipa" ]; then
  sec_skip binaries "no binaries to check (set APK and/or IPA, or SECURITY_BINARIES_DIR)"
  exit 0
fi
for file in "$apk" "$ipa"; do
  [ -z "$file" ] || [ -f "$file" ] || {
    echo "binaries: no such file: $file" >&2
    exit 1
  }
done

# A property list (XML or binary) on stdin as JSON on stdout, optionally one
# top-level key of it. plistlib reads both encodings, which is why this is
# python3 rather than a sed over XML: an IPA's Info.plist is usually binary.
# Read whole rather than streamed: plistlib seeks, and a pipe cannot. Dates
# and data become strings; nothing checked here is either.
plist_json() {
  python3 -c '
import json, plistlib, sys
value = plistlib.loads(sys.stdin.buffer.read())
if len(sys.argv) > 1:
    value = value.get(sys.argv[1], {})
json.dump(value, sys.stdout, default=str)
' "$@"
}

out="$(sec_out_dir)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
args=()

# A tool the checks need. Locally its absence becomes a note carried into the
# run - the platform's checks did not happen, and the summary says so - while
# under CI it fails, because a release gate that silently skips half itself is
# not a gate.
missing() {
  local what="$1"
  if [ -n "${CI:-}" ]; then
    echo "$what, and under CI that is a failure, not a skip" >&2
    exit 1
  fi
  args+=(--note "$what: those checks did not run")
}

if [ -n "$apk" ]; then
  aapt2="$(sec_android_build_tool aapt2 || true)"
  apksigner="$(sec_android_build_tool apksigner || true)"
  if [ -z "$aapt2" ]; then
    missing "aapt2 is not installed (Android SDK build-tools; set ANDROID_HOME)"
  else
    "$aapt2" dump xmltree --file AndroidManifest.xml "$apk" > "$work/manifest.txt"
    args+=(--android-manifest "$work/manifest.txt" --android-file "$(basename "$apk")")
    # The network security config is a resource, named by its identifier in
    # the manifest. Resource shrinking can rename the file, so the path comes
    # from the resource table rather than from a guess at res/xml/*.
    ref="$(sed -n 's/.*:networkSecurityConfig([^)]*)=@\(0x[0-9a-f]*\).*/\1/p' "$work/manifest.txt" | head -1)"
    if [ -n "$ref" ]; then
      path="$("$aapt2" dump resources "$apk" | awk -v id="$ref" '$1 == "resource" && $2 == id { found = 1; next } found && /\(file\)/ { print $3; exit }')"
      [ -n "$path" ] || {
        echo "binaries: the manifest names network security config $ref, but the resource table has no file for it" >&2
        exit 1
      }
      "$aapt2" dump xmltree --file "$path" "$apk" > "$work/nsc.txt"
      args+=(--android-nsc "$work/nsc.txt")
    fi
  fi
  if [ -z "$apksigner" ]; then
    missing "apksigner is not installed (Android SDK build-tools; set ANDROID_HOME)"
  else
    "$apksigner" verify --print-certs -v "$apk" > "$work/signer.txt" 2>&1 || {
      cat "$work/signer.txt" >&2
      echo "binaries: apksigner could not verify $apk" >&2
      exit 1
    }
    args+=(--android-signer "$work/signer.txt")
  fi
fi

if [ -n "$ipa" ]; then
  if ! command -v python3 >/dev/null 2>&1; then
    missing "python3 is not installed (it reads the IPA's property lists)"
  elif ! command -v openssl >/dev/null 2>&1; then
    missing "openssl is not installed (it unwraps the provisioning profile)"
  else
    mkdir -p "$work/ipa"
    unzip -q -o "$ipa" 'Payload/*.app/Info.plist' 'Payload/*.app/embedded.mobileprovision' -d "$work/ipa" 2>/dev/null || true
    # `|| true`: with no Payload/ at all, find fails, and under pipefail that
    # would end the script with no message instead of reaching the one below.
    info="$(find "$work/ipa/Payload" -maxdepth 2 -name Info.plist 2>/dev/null | head -1 || true)"
    [ -n "$info" ] || {
      echo "binaries: $ipa has no Payload/*.app/Info.plist - not an iOS app archive" >&2
      exit 1
    }
    plist_json < "$info" > "$work/info.json"
    args+=(--ios-info "$work/info.json" --ios-file "$(basename "$ipa")")
    profile="$(dirname "$info")/embedded.mobileprovision"
    if [ -f "$profile" ]; then
      openssl smime -inform der -verify -noverify -in "$profile" 2>/dev/null |
        plist_json Entitlements > "$work/entitlements.json"
      args+=(--ios-entitlements "$work/entitlements.json")
    else
      args+=(--note "$(basename "$ipa") carries no embedded.mobileprovision: the get-task-allow check did not run")
    fi
  fi
fi

node "$SECURITY_LIB/security-binaries.mjs" "${args[@]}" > "$out/binaries.sarif"
echo "binaries: wrote $out/binaries.sarif"

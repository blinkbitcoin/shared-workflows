#!/usr/bin/env bash
# Post-build verification gate for the Android release artifacts.
#
#   bash <scripts>/release/verify-android.sh <aab> <apk> [--cert-sha256 <fp>]
#     [--expect-debug-signing] [--strict]
#
# Run from the app repository: its root is where the repository-level inputs
# are read from (consumer_root: $GITHUB_WORKSPACE/$WORKING_DIRECTORY in CI, the
# current directory on a laptop), wherever this script itself lives - here, or
# the copy @blinkbitcoin/app-tooling ships. Each of those inputs is optional:
# without .env.example, fastlane/metadata, certs/expo-updates-cert.pem or
# build-info.json the check that reads it says so and skips.
#
# The AAB is what Play receives; the APK is the universal one built from that
# same bundle, and is the only one of the two whose contents can be read with
# ordinary tools. Both are checked, and they are checked against each other:
# an APK built from a different bundle than the one being uploaded is exactly
# the mistake this gate exists to catch.
#
# Prints one `status check: detail` line per check (ok | warn | skip | FAIL),
# mirrors the list into $GITHUB_STEP_SUMMARY when CI set it, and exits 1 if
# anything FAILed. A missing tool is a skip -- unless --strict (or CI, which
# turns it on by itself), where a check that could not run is a check that did
# not pass.
#
# Env read: APP_VERSION, APP_BUILD_NUMBER, ANDROID_PACKAGE, OTA_ENABLED,
#           BUILD_INFO_FILE (default: the build-info.json next to the APK,
#           else the one at the repository root), ANDROID_HOME,
#           ANDROID_SDK_ROOT, BUNDLETOOL_JAR, ANDROID_MIN_SDK,
#           ANDROID_MAPPING_TXT, ANDROID_UPLOAD_CERT_SHA256, OTA_CHANNEL,
#           EXPO_PUBLIC_*, GITHUB_WORKSPACE and WORKING_DIRECTORY (where the
#           repository root is).
set -euo pipefail

# shellcheck source=scripts/lib/common.sh
source "$(dirname "$0")/../lib/common.sh"
# shellcheck source=scripts/lib/verify-common.sh
source "$(dirname "$0")/../lib/verify-common.sh"

repo_root="$(consumer_root)" || {
  echo "verify-android.sh: the repository root ${GITHUB_WORKSPACE:-$PWD}/${WORKING_DIRECTORY:-.} does not exist" >&2
  exit 2
}

# Expo SDK 57's own floor. A release built below it would not install on the
# devices the store listing promises. Deliberately a constant rather than a read
# of the generated android/build.gradle -- a gate that takes its expectation
# from the thing it is checking checks nothing -- so ANDROID_MIN_SDK is the way
# to move it when the SDK bump moves it.
MIN_SDK_FLOOR="${ANDROID_MIN_SDK:-24}"

usage() {
  echo "usage: verify-android.sh <aab> <apk> [--cert-sha256 <fingerprint>] [--expect-debug-signing] [--strict]" >&2
  exit 2
}

aab=''
apk=''
cert_sha=''
expect_debug=''
strict=''
while [ $# -gt 0 ]; do
  case "$1" in
    --strict) strict=1 ;;
    # An unsigned build is still expected to be *debug*-signed, so this asserts
    # the identity rather than waiving the check. See the signing block below.
    --expect-debug-signing) expect_debug=1 ;;
    --cert-sha256)
      shift
      [ $# -gt 0 ] || usage
      cert_sha="$1"
      ;;
    -h | --help) usage ;;
    -*) usage ;;
    *)
      if [ -z "$aab" ]; then
        aab="$1"
      elif [ -z "$apk" ]; then
        apk="$1"
      else
        usage
      fi
      ;;
  esac
  shift
done
# The runbook documents ANDROID_UPLOAD_CERT_SHA256 as the variable this gate
# reads, so the flag is the override rather than the only way in.
[ -n "$cert_sha" ] || cert_sha="${ANDROID_UPLOAD_CERT_SHA256:-}"
[ -n "$aab" ] && [ -n "$apk" ] || usage
for f in "$aab" "$apk"; do
  [ -f "$f" ] || {
    echo "verify-android.sh: no such file: $f" >&2
    exit 2
  }
done

# build-info.json is the release's provenance record; the `android build` lane
# merges `artifacts.aabSha256` / `artifacts.apkSha256` into a copy of it next to
# the artifacts it just produced. That copy is therefore the default here, and
# $BUILD_INFO_FILE (which CI sets to the build-info artifact copy) overrides it.
build_info="${BUILD_INFO_FILE:-}"
if [ -z "$build_info" ]; then
  build_info="$(dirname "$apk")/build-info.json"
  [ -f "$build_info" ] || build_info="$repo_root/build-info.json"
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

vc_reset
vc_init_strict "$strict"
vc_ok artifacts "$(basename "$aab") + $(basename "$apk")"

aapt2="$(vc_android_build_tool aapt2 || true)"
apksigner="$(vc_android_build_tool apksigner || true)"

# --- APK manifest -----------------------------------------------------------
# One line per check whether or not aapt2 is there, so a reader of the summary
# can never mistake a check that was dropped for one that passed.
APK_CHECKS='apk-manifest apk-package apk-version-name apk-version-code debuggable min-sdk'
badging=''
if [ -z "$aapt2" ]; then
  # shellcheck disable=SC2086 # deliberate word splitting of the check-name list
  vc_require_cmd_for aapt2 $APK_CHECKS || true
else
  badging="$("$aapt2" dump badging "$apk" 2>/dev/null || true)"
  if [ -z "$badging" ]; then
    # shellcheck disable=SC2086 # deliberate word splitting of the check-name list
    vc_fail_group "aapt2 could not read $apk" $APK_CHECKS
  else
    apk_package="$(vc_badging_field "$badging" name)"
    apk_version_code="$(vc_badging_field "$badging" versionCode)"
    apk_version_name="$(vc_badging_field "$badging" versionName)"
    vc_ok apk-manifest "$apk_package $apk_version_name ($apk_version_code)"

    if [ -n "${ANDROID_PACKAGE:-}" ]; then
      vc_expect apk-package "$ANDROID_PACKAGE" "$apk_package"
    else
      vc_skip apk-package "ANDROID_PACKAGE not set; artifact says $apk_package"
    fi
    if [ -n "${APP_VERSION:-}" ]; then
      vc_expect apk-version-name "$APP_VERSION" "$apk_version_name"
    else
      vc_skip apk-version-name "APP_VERSION not set; artifact says $apk_version_name"
    fi
    if [ -n "${APP_BUILD_NUMBER:-}" ]; then
      vc_expect apk-version-code "$APP_BUILD_NUMBER" "$apk_version_code"
    else
      vc_skip apk-version-code "APP_BUILD_NUMBER not set; artifact says $apk_version_code"
    fi

    vc_verdict debuggable "$(vc_debuggable_verdict "$badging")"
    # aapt2 prints `minSdkVersion:'24'`; aapt1 printed `sdkVersion:'24'`.
    min_sdk="$(vc_badging_line_value "$badging" minSdkVersion)"
    [ -n "$min_sdk" ] || min_sdk="$(vc_badging_line_value "$badging" sdkVersion)"
    vc_verdict min-sdk "$(vc_min_sdk_verdict "$min_sdk" "$MIN_SDK_FLOOR")"
  fi
fi

# --- AAB manifest -----------------------------------------------------------
# bundletool is the only thing that can read the protobuf manifest inside an
# AAB, and the AAB -- not the APK -- is what Play actually publishes.
AAB_CHECKS='aab-manifest aab-version-code aab-version-name aab-matches-apk ota'
if ! vc_find_bundletool; then
  # shellcheck disable=SC2086 # deliberate word splitting of the check-name list
  vc_require_cmd_for bundletool $AAB_CHECKS || true
else
  aab_manifest="$("${VC_BUNDLETOOL[@]}" dump manifest --bundle "$aab" 2>/dev/null || true)"
  if [ -z "$aab_manifest" ]; then
    # shellcheck disable=SC2086 # deliberate word splitting of the check-name list
    vc_fail_group "bundletool could not read $aab" $AAB_CHECKS
  else
    attr() { # <attribute name>
      sed -n "/.*android:$1=\"\([^\"]*\)\".*/{s//\1/p;q;}" <<<"$aab_manifest"
    }
    aab_package="$(sed -n '/.*[^a-zA-Z]package="\([^"]*\)".*/{s//\1/p;q;}' <<<"$aab_manifest")"
    aab_version_code="$(attr versionCode)"
    aab_version_name="$(attr versionName)"
    vc_ok aab-manifest "$aab_package $aab_version_name ($aab_version_code)"

    if [ -n "${APP_BUILD_NUMBER:-}" ]; then
      vc_expect aab-version-code "$APP_BUILD_NUMBER" "$aab_version_code"
    else
      vc_skip aab-version-code "APP_BUILD_NUMBER not set; artifact says $aab_version_code"
    fi
    if [ -n "${APP_VERSION:-}" ]; then
      vc_expect aab-version-name "$APP_VERSION" "$aab_version_name"
    else
      vc_skip aab-version-name "APP_VERSION not set; artifact says $aab_version_name"
    fi
    if [ -n "$badging" ]; then
      vc_expect aab-matches-apk "$aab_package $aab_version_name $aab_version_code" \
        "$(vc_badging_field "$badging" name) $(vc_badging_field "$badging" versionName) $(vc_badging_field "$badging" versionCode)"
    else
      vc_skip aab-matches-apk 'the APK manifest could not be read'
    fi

    # The expo-updates meta-data the config plugin injects, read from the AAB
    # so this holds for the artifact Play publishes.
    ota_expected="$(vc_bool "${OTA_ENABLED:-}")"
    ota_actual='absent'
    if vc_contains "$aab_manifest" 'expo.modules.updates.ENABLED'; then
      ota_actual="$(printf '%s\n' "$aab_manifest" |
        grep -A2 'expo.modules.updates.ENABLED' |
        sed -n 's/.*android:value="\([^"]*\)".*/\1/p' | head -1)"
      case "$ota_actual" in true | false) ;; *) ota_actual='absent' ;; esac
    fi
    vc_verdict ota "$(vc_ota_verdict "$ota_expected" "$ota_actual")"

    if [ "$ota_actual" = 'true' ]; then
      # The value of a meta-data element, read from the two lines that follow
      # its name (the manifest dump wraps name and value onto separate lines).
      # Empty, not a failure, when the manifest has no such meta-data: grep's
      # "no match" would otherwise end the script under `set -e` at the
      # `declared_rv=` assignment below, with no checklist and no reason.
      updates_meta() { # <meta-data name>
        printf '%s\n' "$aab_manifest" | grep -A2 "$1" |
          sed -n 's/.*android:value="\([^"]*\)".*/\1/p' | head -1 || true
      }
      # A runtime version that does not match the fingerprint this build was
      # made from means the binary silently receives no updates for its life.
      #
      # Under the fingerprint policy the manifest holds
      # `@string/expo_runtime_version`, whose string resource is in turn the
      # `file:fingerprint` sentinel; the hash itself is an asset written into
      # the build by expo-updates' gradle task and read from `assets/fingerprint`
      # at runtime (UpdatesConfiguration.kt:270). It is in the APK flat and in
      # the AAB under `base/`.
      declared_rv="$(updates_meta 'expo.modules.updates.EXPO_RUNTIME_VERSION')"
      resolved_rv=''
      case "$declared_rv" in
        file:* | '@string/'*)
          if command -v unzip >/dev/null 2>&1; then
            resolved_rv="$(unzip -p "$apk" 'assets/fingerprint' 2>/dev/null | tr -d '[:space:]' || true)"
            [ -n "$resolved_rv" ] ||
              resolved_rv="$(unzip -p "$aab" 'base/assets/fingerprint' 2>/dev/null | tr -d '[:space:]' || true)"
          fi
          ;;
        *) ;;
      esac
      if [ -z "$resolved_rv" ] && [ "${declared_rv#@string/}" != "$declared_rv" ]; then
        # Deliberately a skip and not a FAIL. The asset path is established from
        # the client and the gradle plugin, not from a real AAB (no Android
        # toolchain is available where these gates were written), and a check
        # whose only evidence is source-reading is exactly what shipped the
        # `file:fingerprint` regression. The declared value below is proven
        # against real prebuild output; promote this to a FAIL once a real AAB
        # has been through it.
        vc_skip ota-runtime-version "manifest declares $declared_rv; no assets/fingerprint in the artifact to resolve it from"
      else
        vc_verdict ota-runtime-version \
          "$(vc_runtime_version_verdict "$declared_rv" "$resolved_rv" "$(vc_build_info_fingerprint "$build_info" android)")"
      fi
      # The request headers arrive as one JSON string in a single meta-data
      # value, and the manifest stores that JSON XML-escaped
      # (`{&quot;expo-channel-name&quot;:&quot;production&quot;}`). Unescaping
      # first is harmless when a dump has already done it.
      vc_verdict ota-channel \
        "$(vc_channel_verdict \
          "$(vc_json_string_field "$(vc_xml_unescape "$(updates_meta 'expo.modules.updates.UPDATES_CONFIGURATION_REQUEST_HEADERS_KEY')")" 'expo-channel-name')" \
          "${OTA_CHANNEL:-production}")"
      if vc_contains "$aab_manifest" 'expo.modules.updates.CODE_SIGNING_CERTIFICATE'; then
        cert="$repo_root/certs/expo-updates-cert.pem"
        if [ -f "$cert" ] && command -v shasum >/dev/null 2>&1; then
          vc_verdict ota-cert "$(vc_cert_placeholder_verdict "$(shasum -a 256 "$cert" | cut -d' ' -f1)")"
        else
          vc_skip ota-cert "no certs/expo-updates-cert.pem in $repo_root, or no shasum to hash it"
        fi
      else
        vc_fail ota-cert 'updates are enabled but the manifest carries no CODE_SIGNING_CERTIFICATE meta-data'
      fi
    fi
  fi
fi

# --- native ABIs ------------------------------------------------------------
if vc_require_cmd_for unzip apk-abis aab-abis; then
  vc_verdict apk-abis "$(vc_abi_verdict "$(unzip -Z1 "$apk" 2>/dev/null || true)")"
  vc_verdict aab-abis "$(vc_abi_verdict "$(unzip -Z1 "$aab" 2>/dev/null || true)")"
fi

# --- signing ----------------------------------------------------------------
SIGNING_CHECKS='signature signing-cert'
# --expect-debug-signing adds a row, and that row stays when apksigner is
# missing: under --strict it must fail, not vanish from the checklist.
[ -z "$expect_debug" ] || SIGNING_CHECKS="$SIGNING_CHECKS debug-signing"
if [ -z "$apksigner" ]; then
  # shellcheck disable=SC2086 # deliberate word splitting of the check-name list
  vc_require_cmd_for apksigner $SIGNING_CHECKS || true
elif ! "$apksigner" verify --print-certs "$apk" >"$work/certs.txt" 2>"$work/certs.err"; then
  vc_fail signature "apksigner verify failed: $(tr '\n' ' ' <"$work/certs.err")"
else
  actual_sha="$(sed -n 's/.*SHA-256 digest: *\([0-9a-fA-F]*\).*/\1/p' "$work/certs.txt" | head -1)"
  vc_ok signature "apksigner verified $(basename "$apk")"
  # `--expect-debug-signing` is the unsigned build asserting what it is, not
  # waiving a check: gradle debug-signs the bundle, bundletool signs the APK
  # from the same keystore, and both must be the SDK's debug certificate. The
  # iOS lane skips its signing checks in the equivalent case because an unsigned
  # archive has nothing to check; an APK always does. A regression that produces
  # an unsigned or release-signed APK fails here by name.
  if [ -n "$expect_debug" ]; then
    signer_dn="$(sed -n 's/.*certificate DN: *//p' "$work/certs.txt" | head -1)"
    vc_verdict debug-signing "$(vc_debug_signing_verdict "$signer_dn")"
  fi
  if [ -n "$cert_sha" ]; then
    vc_verdict signing-cert "$(vc_cert_verdict "$cert_sha" "$actual_sha")"
  else
    vc_skip signing-cert "no --cert-sha256 given; APK is signed by ${actual_sha:-unknown}"
  fi
fi

# --- JS bundle --------------------------------------------------------------
BUNDLE_CHECKS='hermes dev-server expo-public'
# shellcheck disable=SC2086 # deliberate word splitting of the check-name list
if vc_require_cmd_for unzip $BUNDLE_CHECKS; then
  if unzip -q -o -j "$apk" 'assets/index.android.bundle' -d "$work" 2>/dev/null; then
    bundle="$work/index.android.bundle"
    vc_verdict hermes "$(vc_hermes_verdict "$bundle")"
    # The dev-server rule depends on whether string boundaries are observable at
    # all, which they are not in Hermes bytecode.
    vc_verdict dev-server "$(vc_dev_server_verdict "$bundle" "$(vc_bundle_kind "$bundle")")"
    # .env.example is the list of EXPO_PUBLIC_* names to look for. An app
    # without one has declared nothing to check: a skip, not a failure.
    env_example="$repo_root/.env.example"
    if [ -f "$env_example" ]; then
      vc_verdict expo-public "$(vc_public_env_verdict "$bundle" "$(cat "$env_example")")"
    else
      vc_skip expo-public "no .env.example in $repo_root, so no EXPO_PUBLIC_* names to check"
    fi
  else
    # shellcheck disable=SC2086 # deliberate word splitting of the check-name list
    vc_fail_group 'no assets/index.android.bundle in the APK' $BUNDLE_CHECKS
  fi
fi

# --- ProGuard/R8 mapping ----------------------------------------------------
# `fastlane android build` copies mapping.txt next to the AAB when minification
# produced one. No mapping is not a failure (an app may ship with R8 off),
# but an empty one means a broken upload of unusable symbols.
mapping="${ANDROID_MAPPING_TXT:-$(dirname "$aab")/mapping.txt}"
if [ ! -f "$mapping" ]; then
  vc_skip mapping "no mapping.txt at $mapping (minification off?)"
elif [ -s "$mapping" ]; then
  vc_ok mapping "$(wc -l <"$mapping" | tr -d ' ') lines"
else
  vc_fail mapping "$mapping is empty"
fi

# --- provenance -------------------------------------------------------------
# Resolved next to the argument parsing above. Absent, there is nothing to
# compare against and the check is skipped rather than invented.
if [ ! -f "$build_info" ]; then
  vc_skip apk-sha "no build-info.json at $build_info"
elif ! vc_require_cmd apk-sha node shasum; then
  : # vc_require_cmd already recorded the skip
else
  expected_sha="$(BUILD_INFO_PATH="$build_info" node -e '
const info = require("node:fs").readFileSync(process.env.BUILD_INFO_PATH, "utf8");
process.stdout.write(String(JSON.parse(info)?.artifacts?.apkSha256 ?? ""));
' 2>/dev/null || true)"
  if [ -z "$expected_sha" ]; then
    vc_skip apk-sha 'build-info.json carries no artifacts.apkSha256'
  else
    vc_verdict apk-sha "$(vc_sha_verdict 'APK' "$expected_sha" "$(shasum -a 256 "$apk" | cut -d' ' -f1)")"
  fi
fi

# --- store metadata ---------------------------------------------------------
vc_verdict metadata "$(vc_metadata_placeholder_verdict "$repo_root")"

vc_summary 'Android artifact verification' || exit 1

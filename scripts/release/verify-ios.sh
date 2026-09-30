#!/usr/bin/env bash
# Post-build verification gate for an iOS release artifact.
#
#   bash <scripts>/release/verify-ios.sh <path> [--no-signing] [--dsym <path>] [--strict]
#
# Run from the app repository: its root is where the repository-level inputs
# are read from (consumer_root: $GITHUB_WORKSPACE/$WORKING_DIRECTORY in CI, the
# current directory on a laptop), wherever this script itself lives - here, or
# the copy @blinkbitcoin/app-tooling ships. Each of those inputs is optional:
# without .env.example, fastlane/metadata, certs/expo-updates-cert.pem or
# build-info.json the check that reads it says so and skips.
#
# <path> is an .ipa, an .xcarchive, or the .app inside one. Everything that can
# be wrong about a build *after* it succeeded is checked here: the wrong
# version, a simulator slice, a debug JS bundle pointing at a laptop's Metro,
# OTA silently off, a missing EXPO_PUBLIC_ value.
#
# Prints one `status check: detail` line per check (ok | warn | skip | FAIL),
# mirrors the list into $GITHUB_STEP_SUMMARY when CI set it, and exits 1 if
# anything FAILed. A missing tool is a skip -- unless --strict (or CI, which
# turns it on by itself), where a check that could not run is a check that did
# not pass.
#
# Env read: APP_VERSION, APP_BUILD_NUMBER, IOS_BUNDLE_ID, OTA_ENABLED,
#           OTA_CHANNEL (default production), BUILD_INFO_FILE (default
#           build-info.json at the repository root), EXPO_PUBLIC_* (values must
#           be inlined in the bundle), GITHUB_WORKSPACE and WORKING_DIRECTORY
#           (where the repository root is).
set -euo pipefail

# shellcheck source=scripts/lib/common.sh
source "$(dirname "$0")/../lib/common.sh"
# shellcheck source=scripts/lib/verify-common.sh
source "$(dirname "$0")/../lib/verify-common.sh"

repo_root="$(consumer_root)" || {
  echo "verify-ios.sh: the repository root ${GITHUB_WORKSPACE:-$PWD}/${WORKING_DIRECTORY:-.} does not exist" >&2
  exit 2
}

usage() {
  echo "usage: verify-ios.sh <path to .ipa|.xcarchive|.app> [--no-signing] [--dsym <path>] [--strict]" >&2
  exit 2
}

artifact=''
check_signing=1
dsym_path=''
strict=''
while [ $# -gt 0 ]; do
  case "$1" in
    --no-signing) check_signing=0 ;;
    --strict) strict=1 ;;
    --dsym)
      shift
      [ $# -gt 0 ] || usage
      dsym_path="$1"
      ;;
    -h | --help) usage ;;
    -*) usage ;;
    *)
      [ -z "$artifact" ] || usage
      artifact="$1"
      ;;
  esac
  shift
done
[ -n "$artifact" ] || usage
[ -e "$artifact" ] || {
  echo "verify-ios.sh: no such artifact: $artifact" >&2
  exit 2
}

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

vc_reset
vc_init_strict "$strict"

# --- resolve the .app -------------------------------------------------------
# An .ipa is a zip whose Payload/ holds the app; an .xcarchive keeps it under
# Products/Applications. Both reduce to "a directory called *.app".
app=''
no_app="no .app found in $artifact"
case "$artifact" in
  *.ipa)
    if vc_require_cmd artifact unzip; then
      # A corrupt or truncated .ipa is a failed check with unzip's reason, not
      # an exit with unzip's status and no checklist at all.
      if unzip -q -o "$artifact" -d "$work/ipa" >"$work/unzip.txt" 2>&1; then
        app="$(find "$work/ipa/Payload" -maxdepth 1 -name '*.app' -print -quit 2>/dev/null || true)"
      else
        no_app="unzip could not read $artifact: $(tr '\n' ' ' <"$work/unzip.txt")"
      fi
    fi
    ;;
  *.xcarchive)
    app="$(find "$artifact/Products/Applications" -maxdepth 1 -name '*.app' -print -quit 2>/dev/null || true)"
    ;;
  *.app)
    app="$artifact"
    ;;
  *)
    vc_fail artifact "unsupported artifact type: $artifact (want .ipa, .xcarchive or .app)"
    ;;
esac

if [ -z "$app" ] || [ ! -d "$app" ]; then
  vc_fail artifact "$no_app"
  vc_summary 'iOS artifact verification' || exit 1
  exit 1
fi
vc_ok artifact "$(basename "$app") from $(basename "$artifact")"

plist="$app/Info.plist"
[ -f "$plist" ] || vc_fail info-plist "no Info.plist in $app"

# `plutil -extract ... raw` reads binary and XML plists alike, which matters:
# the plist in a built .app is binary, the one in the generated project is XML.
plist_value() { # <key> [<plist>]
  plutil -extract "$1" raw -o - "${2:-$plist}" 2>/dev/null || true
}

# --- version, build number, bundle id ---------------------------------------
if vc_require_cmd_for plutil version build-number bundle-id; then
  version="$(plist_value CFBundleShortVersionString)"
  build_number="$(plist_value CFBundleVersion)"
  bundle_id="$(plist_value CFBundleIdentifier)"

  if [ -n "${APP_VERSION:-}" ]; then
    vc_expect version "$APP_VERSION" "$version"
  else
    vc_skip version "APP_VERSION not set; artifact says $version"
  fi
  if [ -n "${APP_BUILD_NUMBER:-}" ]; then
    vc_expect build-number "$APP_BUILD_NUMBER" "$build_number"
  else
    vc_skip build-number "APP_BUILD_NUMBER not set; artifact says $build_number"
  fi
  if [ -n "${IOS_BUNDLE_ID:-}" ]; then
    vc_expect bundle-id "$IOS_BUNDLE_ID" "$bundle_id"
  else
    vc_skip bundle-id "IOS_BUNDLE_ID not set; artifact says $bundle_id"
  fi
fi

# --- architecture -----------------------------------------------------------
executable="$(plist_value CFBundleExecutable)"
binary="$app/${executable:-$(basename "${app%.app}")}"
if [ ! -f "$binary" ]; then
  vc_fail arch "no executable at $binary"
elif vc_require_cmd arch lipo; then
  vc_verdict arch "$(vc_arch_verdict "$(lipo -archs "$binary" 2>/dev/null || true)")"
fi

# --- signing ----------------------------------------------------------------
# `--no-signing` is the local proof: `fastlane ios build skip_signing:true`
# produces an archive with no identity at all, and checking it would only ever
# fail.
if [ "$check_signing" -eq 0 ]; then
  vc_skip signing "--no-signing given (unsigned local build)"
  vc_skip provisioning "--no-signing given (unsigned local build)"
  vc_skip get-task-allow "--no-signing given (unsigned local build)"
else
  # One row per check whether or not codesign is there, so a missing codesign
  # cannot drop get-task-allow from the checklist; provisioning needs no tool
  # at all and runs either way.
  has_codesign=0
  command -v codesign >/dev/null 2>&1 && has_codesign=1

  if [ "$has_codesign" -eq 0 ]; then
    vc_tool_missing signing codesign
  elif codesign --verify --strict --verbose=2 "$app" >"$work/codesign.txt" 2>&1; then
    details="$(codesign -dv --verbose=4 "$app" 2>&1 || true)"
    team="$(printf '%s\n' "$details" | sed -n 's/^TeamIdentifier=\(.*\)$/\1/p' | head -1)"
    authority="$(printf '%s\n' "$details" | sed -n 's/^Authority=\(.*\)$/\1/p' | head -1)"
    if [ -z "$team" ] || [ "$team" = 'not set' ]; then
      vc_fail signing "signed without a team identifier (ad-hoc?): ${authority:-no authority}"
    else
      vc_ok signing "$authority (team $team)"
    fi
  else
    vc_fail signing "codesign --verify failed: $(tr '\n' ' ' <"$work/codesign.txt")"
  fi

  if [ -f "$app/embedded.mobileprovision" ]; then
    vc_ok provisioning 'embedded.mobileprovision present'
  else
    vc_fail provisioning 'no embedded.mobileprovision in the .app'
  fi

  # get-task-allow lets a debugger attach. App Store review rejects it, and it
  # is the single entitlement a wrongly signed release is most likely to carry.
  if [ "$has_codesign" -eq 0 ]; then
    vc_tool_missing get-task-allow codesign
  else
    entitlements="$(codesign -d --entitlements - --xml "$app" 2>/dev/null || true)"
    if ! vc_contains "$entitlements" 'get-task-allow'; then
      vc_ok get-task-allow 'no get-task-allow entitlement'
    # `<key>get-task-allow</key><true/>`, with any whitespace between them.
    elif vc_contains "$(printf '%s' "$entitlements" | tr -d ' \n\t')" 'get-task-allow</key><true/>'; then
      vc_fail get-task-allow 'get-task-allow is true (a debug entitlement in a release build)'
    else
      vc_ok get-task-allow 'get-task-allow is false'
    fi
  fi
fi

# --- OTA (expo-updates) -----------------------------------------------------
build_info="${BUILD_INFO_FILE:-$repo_root/build-info.json}"

expo_plist="$app/Expo.plist"
ota_expected="$(vc_bool "${OTA_ENABLED:-}")"
if [ ! -f "$expo_plist" ]; then
  vc_verdict ota "$(vc_ota_verdict "$ota_expected" 'absent')"
elif vc_require_cmd ota plutil; then
  ota_actual="$(plist_value EXUpdatesEnabled "$expo_plist")"
  case "$ota_actual" in true | false) ;; *) ota_actual='absent' ;; esac
  vc_verdict ota "$(vc_ota_verdict "$ota_expected" "$ota_actual")"

  if [ "$ota_actual" = 'true' ]; then
    url="$(plist_value EXUpdatesURL "$expo_plist")"
    if [ -n "$url" ]; then
      vc_ok ota-url "$url"
    else
      vc_fail ota-url 'updates are enabled but Expo.plist carries no EXUpdatesURL'
    fi
    # A runtime version that does not match the fingerprint this build was made
    # from means the binary silently receives no updates for its whole life.
    #
    # Under the fingerprint policy the plist holds the `file:fingerprint`
    # sentinel and the hash is a file inside the .app, written by the
    # expo-updates build phase. Found rather than assumed: with the pod's
    # resource bundle it is `EXUpdates.bundle/fingerprint`, and a
    # `use_frameworks!` build puts it under the framework instead.
    declared_rv="$(plist_value EXUpdatesRuntimeVersion "$expo_plist")"
    resolved_rv=''
    case "$declared_rv" in
      file:* | '@string/'*)
        fingerprint_file="$(find "$app" -maxdepth 3 -type f -name fingerprint -print -quit 2>/dev/null || true)"
        [ -z "$fingerprint_file" ] || resolved_rv="$(tr -d '[:space:]' <"$fingerprint_file")"
        ;;
      *) ;;
    esac
    vc_verdict ota-runtime-version \
      "$(vc_runtime_version_verdict "$declared_rv" "$resolved_rv" "$(vc_build_info_fingerprint "$build_info" ios)")"
    # `EXUpdatesRequestHeaders` is a dict; plutil reads into it by key path.
    vc_verdict ota-channel \
      "$(vc_channel_verdict "$(plist_value 'EXUpdatesRequestHeaders.expo-channel-name' "$expo_plist")" "${OTA_CHANNEL:-production}")"
    cert="$repo_root/certs/expo-updates-cert.pem"
    if [ -f "$cert" ] && command -v shasum >/dev/null 2>&1; then
      vc_verdict ota-cert "$(vc_cert_placeholder_verdict "$(shasum -a 256 "$cert" | cut -d' ' -f1)")"
    else
      vc_skip ota-cert "no certs/expo-updates-cert.pem in $repo_root, or no shasum to hash it"
    fi
  fi
fi

# --- JS bundle --------------------------------------------------------------
bundle="$app/main.jsbundle"
vc_verdict hermes "$(vc_hermes_verdict "$bundle")"
# The dev-server rule depends on whether string boundaries are observable at
# all, which they are not in Hermes bytecode.
vc_verdict dev-server "$(vc_dev_server_verdict "$bundle" "$(vc_bundle_kind "$bundle")")"

# .env.example is the list of EXPO_PUBLIC_* names to look for. An app without
# one has declared nothing to check, which is a skip and not a failure.
env_example="$repo_root/.env.example"
if [ ! -f "$bundle" ]; then
  vc_skip expo-public 'no JS bundle to scan (the hermes check has failed it)'
elif [ ! -f "$env_example" ]; then
  vc_skip expo-public "no .env.example in $repo_root, so no EXPO_PUBLIC_* names to check"
else
  vc_verdict expo-public "$(vc_public_env_verdict "$bundle" "$(cat "$env_example")")"
fi

# --- dSYM -------------------------------------------------------------------
# Symbolication is only useful if the dSYM belongs to *this* binary; a UUID
# mismatch is how a crash report ends up as a wall of hex addresses.
if [ -z "$dsym_path" ]; then
  vc_skip dsym-uuid 'no --dsym given'
elif [ ! -e "$dsym_path" ]; then
  vc_fail dsym-uuid "no such dSYM: $dsym_path"
elif vc_require_cmd dsym-uuid dwarfdump; then
  # One row either way: a zipped dSYM that cannot be opened is that row's
  # failure (or its skip, with no unzip), never a second verdict about an
  # empty directory, and never an exit with unzip's status.
  dsym_dir="$dsym_path"
  case "$dsym_path" in
    *.zip)
      dsym_dir=''
      if vc_require_cmd dsym-uuid unzip; then
        if unzip -q -o "$dsym_path" -d "$work/dsym" >"$work/unzip-dsym.txt" 2>&1; then
          dsym_dir="$work/dsym"
        else
          vc_fail dsym-uuid "unzip could not read $dsym_path: $(tr '\n' ' ' <"$work/unzip-dsym.txt")"
        fi
      fi
      ;;
    *) ;;
  esac
  if [ -n "$dsym_dir" ]; then
    dsym_out=''
    dsyms="$(find "$dsym_dir" -maxdepth 3 -name '*.dSYM' -print 2>/dev/null || true)"
    while IFS= read -r found; do
      [ -n "$found" ] || continue
      dsym_out="$dsym_out$(dwarfdump --uuid "$found" 2>/dev/null || true)"$'\n'
    done <<<"$dsyms"
    vc_verdict dsym-uuid "$(vc_dsym_verdict "$(dwarfdump --uuid "$binary" 2>/dev/null || true)" "$dsym_out")"
  fi
fi

# --- store metadata ---------------------------------------------------------
vc_verdict metadata "$(vc_metadata_placeholder_verdict "$repo_root")"

vc_summary 'iOS artifact verification' || exit 1

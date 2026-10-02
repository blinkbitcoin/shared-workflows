#!/bin/bash
# The identifiers gate: refuse to let store-setup proceed while the repo is
# still wired to the template's placeholder bundle id, package name or repo
# name. Google Play refuses `com.example.*` outright, and an App Store
# Connect app record is permanent once created — this must be right before
# either console is touched.
#
# Usage: identifiers.sh [--repo owner/name] [--quiet]
#
#   Reads IOS_BUNDLE_ID, ANDROID_PACKAGE, IOS_SCHEME from `gh variable list`,
#   and cross-checks them against the app's own configuration (app.config.* or
#   app.json, else the Xcode project and android/app/build.gradle) and
#   REPO_ROOT/package.json.
#
# Exit codes: 0 all assertions pass, 1 the check could not run (not inside a
# git repo, `gh variable list` failed, or app.config.ts/package.json is
# missing, or no app configuration to compare with), 2 one or more assertions failed (remedy printed), 64 usage.

set -uo pipefail

REPO_ARGS=()
QUIET=0
while [ $# -gt 0 ]; do
  case "$1" in
    --repo)
      [ $# -ge 2 ] || {
        echo "FATAL: --repo needs owner/name" >&2
        exit 64
      }
      REPO_ARGS=(--repo "$2")
      shift 2
      ;;
    --quiet)
      QUIET=1
      shift
      ;;
    *)
      echo "FATAL: unknown option '$1'" >&2
      exit 64
      ;;
  esac
done

REPO_ROOT="${REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null)}"
[ -n "$REPO_ROOT" ] || {
  echo "FATAL: not inside a git repo; set REPO_ROOT" >&2
  exit 1
}

FAIL=0
REMEDIES=()

say_pass() { [ "$QUIET" -eq 1 ] || echo "PASS: $1"; }
say_fail() {
  echo "FAIL: $1"
  FAIL=1
  [ $# -ge 2 ] && REMEDIES+=("$2")
}

VARS_JSON="$(gh variable list --json name,value "${REPO_ARGS[@]+"${REPO_ARGS[@]}"}")" || {
  echo "FATAL: gh variable list failed" >&2
  exit 1
}

# Bash 3.2 (macOS's /bin/bash) has no associative arrays, so variable lookups
# go through a NAME<TAB>value line list instead of a map.
# shellcheck disable=SC2016 # single quotes are deliberate: this is JS, and must reach node unexpanded.
VAR_LINES="$(printf '%s' "$VARS_JSON" | node -e '
const data = JSON.parse(require("fs").readFileSync(0, "utf8"));
for (const v of data) process.stdout.write(`${v.name}\t${v.value}\n`);
')"

var_is_set() {
  printf '%s\n' "$VAR_LINES" | awk -F'\t' -v n="$1" '$1==n{found=1} END{exit !found}'
}

var_value() {
  # `-F'\t'` would truncate at the first tab if a value itself contains one;
  # strip only the "name<TAB>" prefix instead so the rest of the line -
  # tabs and all - reaches the caller intact.
  printf '%s\n' "$VAR_LINES" | awk -F'\t' -v n="$1" '$1==n{sub(/^[^\t]*\t/, ""); print; exit}'
}

# --- 1. presence -------------------------------------------------------------
for v in IOS_BUNDLE_ID ANDROID_PACKAGE IOS_SCHEME; do
  if var_is_set "$v"; then
    say_pass "$v is set"
  else
    say_fail "$v is not set as a GitHub variable" "gh variable set $v --body '<value>'"
  fi
done

IOS_BUNDLE_ID="$(var_value IOS_BUNDLE_ID)"
ANDROID_PACKAGE="$(var_value ANDROID_PACKAGE)"

# --- 2. not a template placeholder / Google-reserved prefix -----------------
for entry in "IOS_BUNDLE_ID:$IOS_BUNDLE_ID" "ANDROID_PACKAGE:$ANDROID_PACKAGE"; do
  name="${entry%%:*}"
  val="${entry#*:}"
  [ -n "$val" ] || continue
  case "$val" in
    com.example.* | com.google.* | com.android.* | android.*)
      say_fail "$name '$val' is a template placeholder or a Google-reserved prefix" "rename the placeholder identifiers (make init in the template, or edit your app configuration and the gh variables)"
      ;;
    *)
      say_pass "$name is not a template placeholder or a reserved prefix"
      ;;
  esac
done

# --- 3. ANDROID_PACKAGE shape ------------------------------------------------
if [ -n "$ANDROID_PACKAGE" ]; then
  if [[ "$ANDROID_PACKAGE" =~ ^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)+$ ]]; then
    say_pass "ANDROID_PACKAGE is a valid Java package name"
  else
    say_fail "ANDROID_PACKAGE '$ANDROID_PACKAGE' is not a valid Java package name" \
      "gh variable set ANDROID_PACKAGE --body '<value>'"
  fi
fi

# --- 4. IOS_BUNDLE_ID shape ---------------------------------------------------
if [ -n "$IOS_BUNDLE_ID" ]; then
  if [[ "$IOS_BUNDLE_ID" =~ ^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$ ]]; then
    say_pass "IOS_BUNDLE_ID is reverse-DNS with at least two segments"
  else
    say_fail "IOS_BUNDLE_ID '$IOS_BUNDLE_ID' is not reverse-DNS with at least two segments" \
      "gh variable set IOS_BUNDLE_ID --body '<value>'"
  fi
fi

# --- 5. the repo agrees with the gh variables --------------------------------
# Where an app states its identifiers depends on its native stack: an Expo app in
# app.config.* / app.json, a bare React Native app in the committed Xcode project
# (PRODUCT_BUNDLE_IDENTIFIER) and android/app/build.gradle (applicationId). Every
# one of those the repository has is read; the value must appear in at least one.
CONFIG_FILES=()
for candidate in app.config.ts app.config.js app.config.mjs app.config.cjs app.json android/app/build.gradle android/app/build.gradle.kts; do
  [ -f "$REPO_ROOT/$candidate" ] && CONFIG_FILES+=("$REPO_ROOT/$candidate")
done
if [ -d "$REPO_ROOT/ios" ]; then
  while IFS= read -r pbxproj; do
    CONFIG_FILES+=("$pbxproj")
  done < <(find "$REPO_ROOT/ios" -name project.pbxproj -not -path '*/Pods/*' 2>/dev/null | sort)
fi
[ "${#CONFIG_FILES[@]}" -gt 0 ] || {
  echo "FATAL: none of app.config.ts, app.json, ios/**/project.pbxproj or android/app/build.gradle exists under $REPO_ROOT, so the gh variables cannot be checked against the app" >&2
  exit 1
}
CONFIG_CONTENT="$(cat "${CONFIG_FILES[@]}")"

for entry in "IOS_BUNDLE_ID:$IOS_BUNDLE_ID" "ANDROID_PACKAGE:$ANDROID_PACKAGE"; do
  name="${entry%%:*}"
  val="${entry#*:}"
  [ -n "$val" ] || continue
  if printf '%s' "$CONFIG_CONTENT" | grep -qF "$val"; then
    say_pass "$name value appears in the app's own configuration"
  else
    say_fail "$name variable ('$val') does not appear in the app's own configuration (app.config.ts, the Xcode project or build.gradle) - the gh variable and the repo disagree" \
      "update the app's configuration to match the gh variable (or vice versa)"
  fi
done

# --- 6. package.json has been renamed ---------------------------------------
PKG_JSON="$REPO_ROOT/package.json"
[ -f "$PKG_JSON" ] || {
  echo "FATAL: $PKG_JSON not found" >&2
  exit 1
}
PKG_NAME="$(node -e 'process.stdout.write(JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")).name || "")' "$PKG_JSON")"
# Matched as a suffix, not the literal template default name: `make init`'s
# token rename would otherwise rewrite the literal string here too, and this
# check would then compare PKG_NAME against the app's own new name.
case "$PKG_NAME" in
  *-mobile-template)
    say_fail "package.json name is still the template default ('$PKG_NAME')" "rename the package (make init in the template, or edit package.json)"
    ;;
  *)
    say_pass "package.json name has been renamed from the template default"
    ;;
esac

if [ "$FAIL" -eq 1 ]; then
  echo
  echo "Remedy:"
  printf '%s\n' "${REMEDIES[@]+"${REMEDIES[@]}"}" | sort -u
  exit 2
fi

exit 0

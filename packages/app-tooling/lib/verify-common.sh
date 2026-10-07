#!/usr/bin/env bash
# Shared helpers for the release verification gates (release/verify-ios.sh,
# release/verify-android.sh). Sourced, never executed. It lives in lib/ beside
# release/ both here and in the copy @blinkbitcoin/app-tooling ships, so the
# gates find it at the same relative path in either place. Nothing in it knows
# where the app repository is: a helper that reads one takes it as an argument.
#
# Two kinds of function live here:
#
#   1. Checklist plumbing -- `vc_ok`/`vc_warn`/`vc_skip`/`vc_fail` print one
#      `status check: detail` line each, count what happened, and `vc_summary`
#      replays the whole list into $GITHUB_STEP_SUMMARY when CI set it.
#   2. Pure verdict helpers -- they take text (a `lipo -archs` line, an aapt2
#      badging dump, a list of archive entries) and print `<status> <detail>`.
#      Nothing about them touches a real artifact, which is what makes
#      test/verify-common.bats able to test the decisions themselves instead
#      of only the happy path of a 90 MB build.
#
# A status is one of: ok | warn | skip | FAIL. Only FAIL fails the gate, and a
# verdict whose status is anything else is recorded as a FAIL (see vc_verdict).
# `skip` means "this check could not run" (a tool is missing, an input was not
# given) and is deliberately not a failure: the gates have to be usable on a
# laptop that has no bundletool.

# ---------------------------------------------------------------------------
# Checklist
# ---------------------------------------------------------------------------

VC_LINES=()
VC_FAILURES=0
VC_WARNINGS=0
VC_SKIPS=0

vc_reset() {
  VC_LINES=()
  VC_FAILURES=0
  VC_WARNINGS=0
  VC_SKIPS=0
}

vc_record() { # <status> <check> <detail...>
  local status="$1" check="$2"
  shift 2
  local line="$status $check: $*"
  VC_LINES+=("$line")
  printf '%s\n' "$line"
  case "$status" in
    FAIL) VC_FAILURES=$((VC_FAILURES + 1)) ;;
    warn) VC_WARNINGS=$((VC_WARNINGS + 1)) ;;
    skip) VC_SKIPS=$((VC_SKIPS + 1)) ;;
    *) ;;
  esac
}

vc_ok() { vc_record ok "$@"; }
vc_warn() { vc_record warn "$@"; }
vc_skip() { vc_record skip "$@"; }
vc_fail() { vc_record FAIL "$@"; }

# Turns `<status> <detail>` from a pure helper into a checklist line. Anything
# that is not a known status fails closed, because vc_record counts only the
# four statuses above and would otherwise record the line and let the gate pass:
#
# - An empty verdict. Every verdict is computed in `$(...)`; when that subshell
#   dies before it prints -- a crash, a signal -- the check never ran, and that
#   is not the same as a check that did not fail.
# - A status the checklist does not know -- a lowercase `fail`, a typo. That is
#   what let `debug-signing` pass a release-signed APK.
vc_verdict() { # <check> <verdict>
  local check="$1" verdict="$2" status
  if [ -z "$verdict" ]; then
    vc_fail "$check" 'the check produced no verdict (it exited or crashed before printing one)'
    return 0
  fi
  status="${verdict%% *}"
  case "$status" in
    ok | warn | skip | FAIL) vc_record "$status" "$check" "${verdict#* }" ;;
    *) vc_fail "$check" "unknown verdict status '$status' in: $verdict" ;;
  esac
}

vc_expect() { # <check> <expected> <actual>
  if [ "$2" = "$3" ]; then
    vc_ok "$1" "$3"
  else
    vc_fail "$1" "expected '$2', got '$3'"
  fi
}

# Strict mode. On a laptop a missing bundletool should not fail a release
# gate; in the release job it must, or a gate can exit 0 having verified
# nothing. `--strict` says so explicitly, and CI says so by being CI.
VC_STRICT=0

vc_init_strict() { # <1 when --strict was given, else empty>
  if [ "${1:-}" = '1' ]; then
    VC_STRICT=1
  elif [ "${CI:-}" = 'true' ] || [ "${GITHUB_ACTIONS:-}" = 'true' ]; then
    VC_STRICT=1
  else
    VC_STRICT=0
  fi
}

# A check that cannot run because its tool is absent. Only *tool* skips are
# strict-mode failures: a skip for an input nobody supplied (APP_VERSION unset,
# no --cert-sha256) stays a skip in every mode.
vc_tool_missing() { # <check> <cmd>
  if [ "$VC_STRICT" -eq 1 ]; then
    vc_fail "$1" "requires $2, which is not on PATH (--strict)"
  else
    vc_skip "$1" "requires $2, which is not on PATH"
  fi
}

# Every check names the tools it needs.
vc_require_cmd() { # <check> <cmd>...
  local check="$1"
  shift
  local cmd
  for cmd in "$@"; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      vc_tool_missing "$check" "$cmd"
      return 1
    fi
  done
  return 0
}

# The same, for one tool that guards several checks: one line per check name, so
# the checklist has the same rows whether or not the tool was there. A single
# `skip apk-manifest` that silently deletes `min-sdk` and `debuggable` from the
# summary is indistinguishable, to a reader, from those checks having passed.
vc_require_cmd_for() { # <cmd> <check>...
  local cmd="$1"
  shift
  command -v "$cmd" >/dev/null 2>&1 && return 0

  local check
  for check in "$@"; do
    vc_tool_missing "$check" "$cmd"
  done
  return 1
}

# Records the same missing-row skips for a tool that was found but could not
# read the artifact -- those are real failures, not absences.
vc_fail_group() { # <detail> <check>...
  local detail="$1"
  shift
  local check
  for check in "$@"; do
    vc_fail "$check" "$detail"
  done
}

# grep with its exit status kept. `grep ... || true` cannot tell "found
# nothing" (1) from "grep is not installed" (127) or "grep failed" (>=2), and
# the second reads as a clean bundle -- a green check produced by a tool that
# never ran. Callers get the matches in VC_GREP_OUTPUT, grep's stderr in
# VC_GREP_ERROR, and 0/1/>=2 as the return code.
#
# grep runs in the C locale (bytes, not characters: a bundle is not valid
# UTF-8), and that locale is handed to it by `env`, never as a `LC_ALL=C grep`
# prefix. With the prefix, bash itself switches locale for the one command and
# switches back afterwards, and on macOS a bash linked against gettext (the
# Homebrew one, first on PATH wherever Homebrew is installed) does that through
# libintl_setlocale, which asks CoreFoundation for the preferred languages.
# Inside `$(...)` that runs in a forked child, where CoreFoundation is not
# fork-safe: the child dies with SIGSEGV now and then, and the check reads
# `grep failed with status 139` -- a crash in bash, not in grep, and nothing to
# do with the bundle. `env` sets the variable only for grep's own process, so
# bash never changes locale. check-shell-locale (make check-ci) keeps the
# prefix out.
VC_GREP_OUTPUT=''
VC_GREP_ERROR=''

vc_grep() { # <extended regex> <file>
  local rc=0 err
  err="$(mktemp)"
  VC_GREP_OUTPUT="$(env LC_ALL=C grep -aoE -e "$1" -- "$2" 2>"$err")" || rc=$?
  VC_GREP_ERROR="$(tr '\n' ' ' <"$err" 2>/dev/null || true)"
  rm -f "$err"
  return "$rc"
}

# Substring and whole-line tests that need no external tool at all, so a
# missing grep cannot turn them into a silent pass.
vc_contains() { # <haystack> <needle>
  case "$1" in
    *"$2"*) return 0 ;;
    *) return 1 ;;
  esac
}

vc_has_line_starting() { # <haystack> <prefix>
  local nl='
'
  case "$nl$1" in
    *"$nl$2"*) return 0 ;;
    *) return 1 ;;
  esac
}

vc_icon() { # <status>
  case "$1" in
    ok) printf '✅' ;;
    warn) printf '⚠️' ;;
    skip) printf '⏭️' ;;
    *) printf '❌' ;;
  esac
}

# Prints the tally, mirrors the checklist into the job summary, and returns
# non-zero when anything failed -- the callers turn that into `exit 1`.
vc_summary() { # <title>
  local title="$1" total="${#VC_LINES[@]}" line status rest check detail
  printf '\n%s — %d checks, %d failed, %d warnings, %d skipped\n' \
    "$title" "$total" "$VC_FAILURES" "$VC_WARNINGS" "$VC_SKIPS"

  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    {
      printf '### %s\n\n' "$title"
      printf '| | Check | Detail |\n| --- | --- | --- |\n'
      if [ "$total" -gt 0 ]; then
        for line in "${VC_LINES[@]}"; do
          status="${line%% *}"
          rest="${line#* }"
          check="${rest%%:*}"
          detail="${rest#*: }"
          # A path or an apksigner error containing `|` would otherwise end the
          # table cell and shift every column after it.
          detail="${detail//|/\\|}"
          # shellcheck disable=SC2016 # the backticks are markdown code spans
          printf '| %s | `%s` | %s |\n' "$(vc_icon "$status")" "$check" "$detail"
        done
      fi
      printf '\n%d checks, %d failed, %d warnings, %d skipped\n\n' \
        "$total" "$VC_FAILURES" "$VC_WARNINGS" "$VC_SKIPS"
    } >>"$GITHUB_STEP_SUMMARY"
  fi

  [ "$VC_FAILURES" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Pure verdict helpers
# ---------------------------------------------------------------------------

# `lipo -archs` output. A store build is arm64-only: an x86_64 slice means the
# binary was archived for the simulator, which the store rejects and which no
# device can run.
vc_arch_verdict() { # <archs>
  local archs
  archs="$(printf '%s\n' "$1" | tr -s ' \t' '\n' | sed '/^$/d' | sort -u | paste -sd' ' - || true)"
  if [ -z "$archs" ]; then
    printf 'FAIL no architectures reported\n'
  elif [ "$archs" = "arm64" ]; then
    printf 'ok arm64 only\n'
  else
    printf 'FAIL expected arm64 only, got %s\n' "$archs"
  fi
}

# Native ABIs from a list of archive entry paths (`unzip -Z1` output for an
# APK or an AAB -- `lib/<abi>/x.so` and `base/lib/<abi>/x.so` both parse).
# The classification is a `case`, not a grep: a missing grep would otherwise
# report "no forbidden ABIs" for a bundle full of them.
vc_abi_verdict() { # <entry paths, newline separated>
  local abis all='' forbidden='' arm='' abi
  abis="$(printf '%s\n' "$1" | sed -n 's#^.*lib/\([A-Za-z0-9_-]*\)/[^/]*\.so$#\1#p' | sort -u || true)"
  if [ -z "$abis" ]; then
    printf 'FAIL no native libraries found\n'
    return 0
  fi
  while IFS= read -r abi; do
    [ -n "$abi" ] || continue
    all="${all:+$all }$abi"
    case "$abi" in
      # Play has not accepted these for phones in years; one would only ever be
      # in a release artifact by accident (a stray `reactNativeArchitectures`).
      x86 | x86_64 | mips | mips64) forbidden="${forbidden:+$forbidden }$abi" ;;
      arm64-v8a | armeabi-v7a) arm="${arm:+$arm }$abi" ;;
      *) ;;
    esac
  done <<EOF
$abis
EOF

  if [ -n "$forbidden" ]; then
    printf 'FAIL forbidden ABI present: %s (all: %s)\n' "$forbidden" "$all"
  elif [ -z "$arm" ]; then
    printf 'FAIL no arm ABI among: %s\n' "$all"
  else
    printf 'ok %s\n' "$all"
  fi
}

# A field off aapt2's `package:` line (`name`, `versionCode`, `versionName`).
# Scoped to that one line on purpose: `name='...'` also appears on every
# uses-permission and launchable-activity line.
#
# These helpers take a first match with sed's `{...;q;}` over a here-string,
# never `| head -1`: under pipefail, head exiting after one line can kill the
# stage still writing with SIGPIPE and fail the pipeline with 141.
vc_badging_field() { # <badging output> <field>
  sed -n '/^package:/{p;q;}' <<<"$1" |
    sed -n "s/.*[[:space:]]$2='\([^']*\)'.*/\1/p" || true
}

# A single-quoted value off a `<prefix>:'<value>'` badging line (sdkVersion,
# targetSdkVersion).
vc_badging_line_value() { # <badging output> <prefix>
  sed -n "/^$2:'\([^']*\)'.*/{s//\1/p;q;}" <<<"$1" || true
}

# A debuggable release build hands anyone with the APK a debugger session
# against production data.
vc_debuggable_verdict() { # <badging output>
  if vc_has_line_starting "$1" 'application-debuggable'; then
    printf 'FAIL application-debuggable is set\n'
  else
    printf 'ok not debuggable\n'
  fi
}

vc_min_sdk_verdict() { # <actual> <minimum>
  case "$1" in
    '' | *[!0-9]*)
      printf 'FAIL could not read minSdkVersion (got %s)\n' "${1:-<empty>}"
      return 0
      ;;
    *) ;;
  esac
  if [ "$1" -ge "$2" ]; then
    printf 'ok minSdk %s (>= %s)\n' "$1" "$2"
  else
    printf 'FAIL minSdk %s is below the supported minimum %s\n' "$1" "$2"
  fi
}

# Is this artifact talking to a Metro dev server?
#
# The naive answer -- grep the bundle for `localhost:8081` -- is wrong twice
# over, and the second way is release-blocking:
#
#   1. `http://localhost:8081/` is in *every* React Native bundle, dev or
#      release: it is the `FALLBACK` constant in
#      react-native/Libraries/Core/Devtools/getDevServer.js. It is inert in a
#      release build (scriptURL is a file:// URL) but the literal is always
#      there, so on its own it proves nothing.
#   2. Hermes packs its whole string table into one character buffer with no
#      terminators and overlaps common prefixes and suffixes. `FALLBACK` ends
#      in `/`, so any string starting with `/` that Hermes happens to pack next
#      to it -- `/index.bundle?platform=ios`, an asset's `/assets/...` path --
#      is read by `grep -ao` as one URL that does not exist in the program.
#      Which string lands there is not something a build controls.
#
# So the rule depends on what the bundle is. On **Hermes bytecode** no regex can
# see a string boundary, and only complete literals that adjacency cannot
# manufacture count: the dev-only query parameters and Metro's virtual dev
# entry. On a **plain-text** bundle boundaries are real, so any dev-server URL
# other than the bare RN fallback fails -- though a plain-text bundle in a
# release artifact is already a `FAIL hermes`.
VC_DEV_SERVER_HOST='(localhost|127\.0\.0\.1|10\.0\.2\.2):8081'
VC_DEV_SERVER_PATTERN="(https?://)?$VC_DEV_SERVER_HOST(/[A-Za-z0-9_./@+%~?=&-]*)?"

# react-native/Libraries/Core/Devtools/getDevServer.js: `const FALLBACK =
# 'http://localhost:8081/'`. Present in every bundle; benign on its own.
VC_RN_DEV_SERVER_FALLBACK='http://localhost:8081/'

# Complete literals that only a development bundle carries. None of these can be
# produced by two release strings ending up next to each other, because each one
# spans a `=`, a `?` or a directory name that no release string ends with.
VC_DEV_MARKERS='dev=true|hot=true|minify=false|/\.expo/\.virtual-metro-entry|index\.bundle\?platform='

vc_dev_server_verdict() { # <bundle path> <hermes|text>
  local kind="${2:-text}" rc=0 hits

  if [ ! -f "$1" ]; then
    printf 'FAIL no JS bundle at %s\n' "$1"
    return 0
  fi

  if [ "$kind" = 'hermes' ]; then
    vc_grep "$VC_DEV_MARKERS" "$1" || rc=$?
    if [ "$rc" -ge 2 ]; then
      printf 'FAIL could not scan the bundle: %s\n' "${VC_GREP_ERROR:-grep failed with status $rc}"
    elif [ "$rc" -eq 0 ]; then
      printf 'FAIL bundle carries development markers: %s\n' \
        "$(printf '%s\n' "$VC_GREP_OUTPUT" | sort -u | head -3 | paste -sd' ' - || true)"
    else
      printf 'ok no development markers in the Hermes bundle\n'
    fi
    return 0
  fi

  vc_grep "$VC_DEV_SERVER_PATTERN" "$1" || rc=$?
  if [ "$rc" -ge 2 ]; then
    printf 'FAIL could not scan the bundle: %s\n' "${VC_GREP_ERROR:-grep failed with status $rc}"
    return 0
  fi
  if [ "$rc" -eq 1 ]; then
    printf 'ok no dev-server URL in the bundle\n'
    return 0
  fi

  # The fallback is dropped in the shell rather than with a second grep, so a
  # grep that is not there cannot empty the list and read as clean.
  local hit
  hits=''
  while IFS= read -r hit; do
    [ -n "$hit" ] || continue
    [ "$hit" != "$VC_RN_DEV_SERVER_FALLBACK" ] || continue
    hits="${hits:+$hits }$(printf '%s' "$hit" | cut -c1-90)"
  done <<EOF
$(printf '%s\n' "$VC_GREP_OUTPUT" | sort -u || true)
EOF

  if [ -n "$hits" ]; then
    printf 'FAIL bundle references a Metro dev server: %s\n' "$hits"
  else
    printf "ok only React Native's inert getDevServer fallback\n"
  fi
}

# The first eight bytes of a Hermes bytecode file (`HermesBytecodeFileMagic`
# in hermes/BCGen/HBC/BytecodeFileFormat.h), little-endian.
VC_HERMES_MAGIC='c61fbc03c103191f'

# `hermes` or `text` -- what the dev-server check has to know before it can
# decide whether a regex over this file means anything.
vc_bundle_kind() { # <bundle path>
  local magic
  magic="$(od -An -tx1 -N8 -- "$1" 2>/dev/null | tr -d ' \n' || true)"
  if [ "$magic" = "$VC_HERMES_MAGIC" ]; then printf 'hermes'; else printf 'text'; fi
}

vc_hermes_verdict() { # <bundle path>
  local magic
  if [ ! -f "$1" ]; then
    printf 'FAIL no JS bundle at %s\n' "$1"
    return 0
  fi
  magic="$(od -An -tx1 -N8 -- "$1" 2>/dev/null | tr -d ' \n')"
  if [ "$magic" = "$VC_HERMES_MAGIC" ]; then
    printf 'ok Hermes bytecode\n'
  elif [ -z "$magic" ]; then
    printf 'FAIL %s is empty or unreadable\n' "$1"
  else
    printf 'FAIL not Hermes bytecode (magic %s, expected %s)\n' "$magic" "$VC_HERMES_MAGIC"
  fi
}

# The EXPO_PUBLIC_* names .env.example documents. Expo inlines the *values*, so
# these names are only the list of things to look for.
vc_public_env_names() { # <.env.example content>
  printf '%s\n' "$1" | sed -n 's/^[[:space:]]*\(EXPO_PUBLIC_[A-Za-z0-9_]*\)=.*/\1/p' | sort -u || true
}

# The shortest value worth searching for. This is a *substring* search, so
# `true`, `1` or a bare hostname would match text that has nothing to do with
# the variable -- and on Hermes bytecode it can match across a string boundary
# (see vc_dev_server_verdict for why that is not hypothetical). A short value
# is reported as unverifiable rather than as proof.
VC_MIN_PUBLIC_VALUE_LENGTH=12

# For every EXPO_PUBLIC_* name that is set and non-empty *here*, its value has
# to be inlined in the bundle. Unset names are listed as skipped and never
# fail: a verify run on a machine without the release env is still useful.
vc_public_env_verdict() { # <bundle path> <.env.example content>
  local names name value rc found=() missing=() skipped=() short=()
  names="$(vc_public_env_names "$2")"
  if [ -z "$names" ]; then
    printf 'skip no EXPO_PUBLIC_* names in .env.example\n'
    return 0
  fi
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    value="$(printenv "$name" || true)"
    if [ -z "$value" ]; then
      skipped+=("$name")
      continue
    fi
    if [ "${#value}" -lt "$VC_MIN_PUBLIC_VALUE_LENGTH" ]; then
      short+=("$name")
      continue
    fi
    rc=0
    # `env`, not a `LC_ALL=C` prefix: this runs inside the gates' `$(...)`, and
    # the prefix can crash bash there (see vc_grep).
    env LC_ALL=C grep -aqF -e "$value" -- "$1" || rc=$?
    if [ "$rc" -ge 2 ]; then
      printf 'FAIL could not scan the bundle for %s (grep status %s)\n' "$name" "$rc"
      return 0
    elif [ "$rc" -eq 0 ]; then
      found+=("$name")
    else
      missing+=("$name")
    fi
  done <<EOF
$names
EOF

  local unchecked
  unchecked="$(printf '%s %s' "${skipped[*]:-}" "${short[*]:-}" | tr -s ' ' | sed 's/^ //;s/ $//')"
  if [ "${#missing[@]}" -gt 0 ]; then
    printf 'FAIL value not inlined in the bundle: %s\n' "${missing[*]}"
  elif [ "${#found[@]}" -gt 0 ]; then
    printf 'ok inlined: %s (not checked: %s)\n' "${found[*]}" "${unchecked:-none}"
  else
    printf 'skip nothing checkable in this environment (not checked: %s)\n' "${unchecked:-none}"
  fi
}

# OTA has to be on in the artifact exactly when the build was told to turn it
# on. `expected` empty means OTA_ENABLED was not in the environment at verify
# time, which is reported rather than guessed at.
vc_ota_verdict() { # <expected true|false|''> <actual true|false|absent>
  if [ -z "$1" ]; then
    printf 'skip OTA_ENABLED not set; artifact says updates enabled=%s\n' "$2"
  elif [ "$2" = 'absent' ] && [ "$1" = 'false' ]; then
    # No updates configuration at all is the same thing as updates being off,
    # and it is what an OTA_ENABLED=false build of an app without expo-updates
    # looks like. Only a build that was *supposed* to have updates and has no
    # configuration is a failure.
    printf 'ok no updates configuration, matching OTA_ENABLED=false\n'
  elif [ "$1" = "$2" ]; then
    printf 'ok updates enabled=%s, matching OTA_ENABLED\n' "$2"
  else
    printf 'FAIL OTA_ENABLED=%s but the artifact says updates enabled=%s\n' "$1" "$2"
  fi
}

# The two settings that decide whether a published update is ever offered to a
# binary. Both are invisible failures: an update "publishes fine" and reaches
# nobody, and nothing surfaces it until someone notices.
#
# The runtime version is what the client sends as `expo-runtime-version`.
#
# Under `runtimeVersion: { policy: 'fingerprint' }` (the app's Expo config)
# `expo prebuild` does *not* write the hash. Verified against a real
# `expo prebuild --clean` of the template app with OTA_ENABLED=true; the
# fixtures under test/fixtures/verify/ota/ are that output:
#
#   Expo.plist:         EXUpdatesRuntimeVersion = file:fingerprint
#   AndroidManifest:    expo.modules.updates.EXPO_RUNTIME_VERSION
#                         = @string/expo_runtime_version
#   res/values/strings: expo_runtime_version = file:fingerprint
#
# `file:fingerprint` is a sentinel with a name in both clients
# (EXUpdatesConfigRuntimeVersionReadFingerprintFileSentinel,
# UpdatesConfiguration.kt:170). The hash is computed at *build* time by
# expo-updates' createFingerprintForBuildAsync and shipped inside the artifact
# as a file called `fingerprint`: `EXUpdates.bundle/fingerprint` in the .app
# (create-updates-resources-ios.sh) and `assets/fingerprint` in the APK (the
# gradle plugin registers the generated asset directory). Those are the bytes
# the client actually reads (UpdatesConfig.swift:179,
# UpdatesConfiguration.kt:270), so those are what this compares.
#
#   declared  what the plist or manifest says
#   resolved  the fingerprint read out of the artifact, '' when there is none
#   expected  build-info.json's fingerprint for the platform, '' when unknown
VC_RUNTIME_VERSION_SENTINEL='file:fingerprint'

vc_runtime_version_verdict() { # <declared> <resolved> <expected>
  case "$1" in
    '')
      printf 'FAIL updates are enabled but the artifact carries no runtime version (it would never be offered an update)\n'
      ;;
    "$VC_RUNTIME_VERSION_SENTINEL" | '@string/'*)
      if [ -z "$2" ]; then
        printf 'FAIL runtime version is %s but the artifact carries no fingerprint file to resolve it from\n' "$1"
      elif [ -z "$3" ]; then
        printf 'ok runtime version %s (from %s; no build-info fingerprint to compare against)\n' "$2" "$1"
      elif [ "$2" = "$3" ]; then
        printf 'ok runtime version %s matches the build fingerprint\n' "$2"
      else
        printf 'FAIL runtime version %s does not match the build fingerprint %s\n' "$2" "$3"
      fi
      ;;
    *)
      # A pinned literal `runtimeVersion`, which is a supported Expo config and
      # is deliberately *not* compared against build-info's fingerprint: under
      # any policy but `fingerprint` the two are different things, and failing
      # a correct build is worse than not checking.
      printf 'ok runtime version %s (pinned literal, not a fingerprint policy)\n' "$1"
      ;;
  esac
}

# XML attribute values arrive escaped from a manifest. `&amp;` is undone last so
# an escaped `&amp;quot;` does not become a quote.
vc_xml_unescape() { # <text>
  printf '%s' "$1" | sed 's/&quot;/"/g; s/&apos;/'"'"'/g; s/&lt;/</g; s/&gt;/>/g; s/&amp;/\&/g'
}

# The channel the binary asks for, sent as the `expo-channel-name` request
# header. A store build must ask for `production`: the internal and beta
# channels are published to from the same pipeline, and a binary pointed at one
# of those would take an update that was never meant for the public.
vc_channel_verdict() { # <actual> <expected>
  if [ -z "$1" ]; then
    printf 'FAIL updates are enabled but no expo-channel-name request header is set\n'
  elif [ "$1" = "$2" ]; then
    printf 'ok update channel %s\n' "$1"
  else
    printf 'FAIL update channel %s, expected %s\n' "$1" "$2"
  fi
}

# The fingerprint build-info.json records for a platform. Empty when there is no
# build-info.json (a local build), no node to read it with, or no fingerprint in
# it: that means "nothing to compare against", never "mismatch".
vc_build_info_fingerprint() { # <build-info.json path> <ios|android>
  [ -f "$1" ] || return 0
  command -v node >/dev/null 2>&1 || return 0
  VC_BUILD_INFO_PATH="$1" VC_BUILD_INFO_PLATFORM="$2" node -e '
const info = require("node:fs").readFileSync(process.env.VC_BUILD_INFO_PATH, "utf8");
process.stdout.write(String(JSON.parse(info)?.fingerprint?.[process.env.VC_BUILD_INFO_PLATFORM] ?? ""));
' 2>/dev/null || true
}

# One string field out of a flat JSON object. The Android manifest carries the
# whole request-header map as a single meta-data value, e.g.
# `{"expo-channel-name":"production"}`, and no JSON tool is guaranteed on a
# runner that can read an AAB.
vc_json_string_field() { # <json text> <field>
  sed -n "/.*\"$2\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/{s//\1/p;q;}" <<<"$1"
}

vc_bool() { # <value> -> true | false | '' (empty in, empty out)
  case "$1" in
    '') printf '' ;;
    true | TRUE | True | 1 | yes) printf 'true' ;;
    *) printf 'false' ;;
  esac
}

# sha256 of certs/expo-updates-cert.pem as the template app ships it. certs/README.md
# says it plainly: the matching private key was generated and then discarded, so
# the committed certificate can never verify a real manifest. Shipping OTA with
# it still in place is a warning, not a failure -- the wiring is correct, the
# trust chain is not.
#
# It is `shasum -a 256 certs/expo-updates-cert.pem` of the file as checked out --
# what the gates hash -- and .gitattributes (`* text=auto eol=lf`) is what makes
# that the same everywhere: the same certificate with CRLF endings hashes to
# something else entirely, which is how this constant first drifted from the
# file. Rotating the placeholder means updating this line and the copy in
# test/fixtures/verify/expo-updates-cert.pem; test/verify-common.bats recomputes
# it from that copy and fails until they match. An app that replaced the
# certificate, or has none, never matches it.
VC_PLACEHOLDER_CERT_SHA256='6480b2a40db40672e247e45812efa56116f6b3c0a19d024b09080c55c1fac334'

vc_cert_placeholder_verdict() { # <sha256 of the pem>
  if [ "$1" = "$VC_PLACEHOLDER_CERT_SHA256" ]; then
    printf 'warn certs/expo-updates-cert.pem is still the template placeholder (its private key was discarded; see certs/README.md)\n'
  else
    printf 'ok code-signing certificate is not the template placeholder\n'
  fi
}

# Store metadata still carrying the template's prose. The hard gate lives in
# the fastlane `release_production` lanes (`assert_metadata_ready!`); here it is
# a warning, so a beta build is not blocked by copy nobody has written yet.
# The metadata lives under the fastlane directory: WORKFLOWS_FASTLANE_DIRECTORY
# (the `fastlane-directory` input, which fastlane.sh exports to the lanes),
# `fastlane` when unset.
VC_METADATA_PLACEHOLDER='Replace this text'

vc_metadata_placeholder_verdict() { # <repo root>
  local metadata="${WORKFLOWS_FASTLANE_DIRECTORY:-fastlane}"
  metadata="${metadata%/}/metadata"
  local dir="$1/$metadata" offenders rc=0 err
  if [ ! -d "$dir" ]; then
    printf 'skip no %s tree at %s\n' "$metadata" "$dir"
    return 0
  fi
  err="$(mktemp)"
  offenders="$(grep -rl -e "$VC_METADATA_PLACEHOLDER" "$dir" 2>"$err")" || rc=$?
  if [ "$rc" -ge 2 ]; then
    printf 'FAIL could not scan %s: %s\n' "$metadata" "$(tr '\n' ' ' <"$err" 2>/dev/null || true)"
    rm -f "$err"
    return 0
  fi
  rm -f "$err"
  if [ "$rc" -eq 0 ] && [ -n "$offenders" ]; then
    printf 'warn store metadata still has template placeholder text: %s\n' \
      "$(printf '%s\n' "$offenders" | sed "s#^$1/##" | sort | paste -sd' ' - || true)"
  else
    printf 'ok no placeholder text in %s\n' "$metadata"
  fi
}

# apksigner prints `SHA-256: aa:bb:...`; a fingerprint pasted from the Play
# console has no colons and may be upper case. Compare the digits.
vc_normalize_sha() { # <fingerprint>
  printf '%s' "$1" | tr -d ': \n\t' | tr '[:upper:]' '[:lower:]'
}

vc_sha_verdict() { # <what> <expected> <actual>
  local want have
  want="$(vc_normalize_sha "$2")"
  have="$(vc_normalize_sha "$3")"
  if [ -z "$have" ]; then
    printf 'FAIL no %s SHA-256 to compare\n' "$1"
  elif [ "$want" = "$have" ]; then
    printf 'ok %s SHA-256 %s\n' "$1" "$have"
  else
    printf 'FAIL %s SHA-256 %s, expected %s\n' "$1" "$have" "$want"
  fi
}

vc_cert_verdict() { # <expected> <actual>
  vc_sha_verdict 'signing certificate' "$1" "$2"
}

# Whether an APK's signer is the Android SDK's debug certificate, given the
# `certificate DN:` line apksigner --print-certs prints. A pure function so the
# unsigned-build assertion is unit-testable without an APK or an SDK.
#
# CN is the only stable part: the rest of the DN varies between the keystore
# gradle ships and one keytool generates (OU/O/L/ST differ, C does not).
vc_debug_signing_verdict() { # <signer DN>
  case "$1" in
    *'CN=Android Debug'*) printf 'ok signed by the Android debug certificate (%s)' "$1" ;;
    '') printf 'FAIL expected the Android debug certificate (CN=Android Debug), got no signer' ;;
    *) printf 'FAIL expected the Android debug certificate (CN=Android Debug), got: %s' "$1" ;;
  esac
}

# dwarfdump --uuid output, one `UUID: <uuid> (<arch>) <path>` line per slice.
vc_uuids() { # <dwarfdump --uuid output>
  printf '%s\n' "$1" | sed -n 's/^UUID: \([0-9A-Fa-f-]*\) .*/\1/p' | tr '[:lower:]' '[:upper:]' | sort -u || true
}

vc_dsym_verdict() { # <binary dwarfdump output> <dsym dwarfdump output>
  local bin dsym missing
  bin="$(vc_uuids "$1")"
  dsym="$(vc_uuids "$2")"
  if [ -z "$bin" ]; then
    printf 'FAIL no UUID in the app binary\n'
    return 0
  fi
  if [ -z "$dsym" ]; then
    printf 'FAIL no UUID in the dSYM\n'
    return 0
  fi
  missing="$(comm -23 <(printf '%s\n' "$bin") <(printf '%s\n' "$dsym") | paste -sd' ' - || true)"
  if [ -n "$missing" ]; then
    printf 'FAIL dSYM does not cover binary UUID(s): %s\n' "$missing"
  else
    printf 'ok dSYM covers %s\n' "$(printf '%s\n' "$bin" | paste -sd' ' - || true)"
  fi
}

# ---------------------------------------------------------------------------
# Tool discovery
# ---------------------------------------------------------------------------

# aapt2 / apksigner / zipalign are not on PATH on a normal machine; they live
# in the newest build-tools directory of the installed SDK.
vc_android_build_tool() { # <tool> -> prints an absolute path, or fails
  local tool="$1" sdk newest candidate
  if command -v "$tool" >/dev/null 2>&1; then
    command -v "$tool"
    return 0
  fi
  sdk="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}"
  [ -n "$sdk" ] && [ -d "$sdk/build-tools" ] || return 1
  newest="$(find "$sdk/build-tools" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; | sort -V | tail -1 || true)"
  [ -n "$newest" ] || return 1
  candidate="$sdk/build-tools/$newest/$tool"
  [ -x "$candidate" ] || return 1
  printf '%s\n' "$candidate"
}

# bundletool is a jar on some machines and a wrapper script on others -- the
# same two shapes fastlane's `bundletool_command` accepts. Sets VC_BUNDLETOOL
# to the argv that runs it.
VC_BUNDLETOOL=()
vc_find_bundletool() {
  if command -v bundletool >/dev/null 2>&1; then
    VC_BUNDLETOOL=(bundletool)
    return 0
  fi
  if [ -n "${BUNDLETOOL_JAR:-}" ] && [ -f "$BUNDLETOOL_JAR" ] && command -v java >/dev/null 2>&1; then
    VC_BUNDLETOOL=(java -jar "$BUNDLETOOL_JAR")
    return 0
  fi
  # shellcheck disable=SC2034 # read by the scripts that source this file
  VC_BUNDLETOOL=()
  return 1
}

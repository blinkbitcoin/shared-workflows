#!/usr/bin/env bash
# Which native stack the consumer is, and the one place that dispatches to it.
#
#   expo  Continuous Native Generation: ios/ and android/ are `expo prebuild`
#         output, the identifiers come from `expo config`, Metro is
#         `expo start` and the fingerprint is @expo/fingerprint's.
#   bare  A React Native app whose ios/ and android/ are committed source:
#         nothing is generated, the identifiers are read out of the native
#         projects, Metro is `react-native start` and the fingerprint is a
#         sha256 over the tracked native files.
#
# Every step that differs between the two lives under scripts/native/<stack>/,
# with the same four entry points in each (prebuild.sh, app-config.sh,
# metro-start.sh, fingerprint.sh), and every caller reaches them through this
# file. Nothing else here decides the stack.
#
# The rule, in order - the first that applies decides:
#
#   1. the `native-stack` workflow input (WORKFLOWS_NATIVE_STACK_INPUT), when it
#      is not empty; any value but `expo` or `bare` fails;
#   2. `expo`, when the consumer's package.json has `expo` in dependencies or
#      devDependencies AND ios/ is not tracked by git (absent, or gitignored);
#   3. otherwise `bare`.
#
# It is implemented once, in packages/app-tooling/lib/native-stack.mjs, which
# the contract checker, check.yml's Expo health gate and the security scanners
# ask too; this file runs that module rather than keep a second copy that
# could drift from it. So resolving needs node (and git, when expo is a
# dependency). The module sits beside this file in the app-tooling package and
# at packages/app-tooling/lib/ in this repository.
#
# Usage:
#   source native-stack.sh                (after common.sh) resolves the stack,
#                                         exports WORKFLOWS_NATIVE_STACK and
#                                         defines workflows_native_script
#   bash native-stack.sh                  prints the stack
#   bash native-stack.sh ENTRY [ARG...]   runs scripts/native/<stack>/ENTRY.sh
#                                         with WORKFLOWS_NATIVE_STACK exported
# Every form logs, on stderr, which stack it found and why.
# shellcheck shell=bash

WORKFLOWS_NATIVE_ENTRIES="prebuild app-config metro-start fingerprint"
WORKFLOWS_NATIVE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# workflows_native_resolver -> the path of native-stack.mjs: beside this file in
# the package, under packages/app-tooling/lib/ in this repository.
workflows_native_resolver() {
  local candidate
  for candidate in "$WORKFLOWS_NATIVE_LIB_DIR/native-stack.mjs" \
    "$WORKFLOWS_NATIVE_LIB_DIR/../../packages/app-tooling/lib/native-stack.mjs"; do
    if [ -f "$candidate" ]; then printf '%s\n' "$candidate"; return 0; fi
  done
  die "no native-stack.mjs beside $WORKFLOWS_NATIVE_LIB_DIR or under packages/app-tooling/lib - the checkout is incomplete"
}

# workflows_native_stack_resolve -> expo|bare on stdout, the reason on stderr.
# Callers read it through `$(...)`, where `set -e` does not reach, so every step
# that can fail ends in `|| return` or dies.
workflows_native_stack_resolve() {
  local root resolver
  root="$(consumer_root)" ||
    die "the consumer's working directory does not exist: ${GITHUB_WORKSPACE:-$PWD}/${WORKING_DIRECTORY:-.}"
  resolver="$(workflows_native_resolver)" || return
  require_cmd node
  node "$resolver" --root "$root" --input "${WORKFLOWS_NATIVE_STACK_INPUT:-}" ||
    die_fix "could not resolve the native stack of $root (the error above says why)" \
      "pass native-stack: expo or native-stack: bare, or fix what the error names" "expo-or-bare"
}

# workflows_native_script ENTRY -> the path of ENTRY for the resolved stack.
# scripts/native sits beside scripts/lib here, and native/ beside lib/ in the
# app-tooling package, so the same relative path works in both.
workflows_native_script() {
  local entry="${1:-}"
  case " $WORKFLOWS_NATIVE_ENTRIES " in
    *" $entry "*) ;;
    *) die "unknown native entry point '$entry' (one of: $WORKFLOWS_NATIVE_ENTRIES)" ;;
  esac
  printf '%s/%s/%s.sh\n' "$(cd "$WORKFLOWS_NATIVE_LIB_DIR/../native" && pwd)" "$WORKFLOWS_NATIVE_STACK" "$entry"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  set -euo pipefail
  source "$(dirname "$0")/common.sh"
  WORKFLOWS_NATIVE_STACK="$(workflows_native_stack_resolve)" || exit 1
  export WORKFLOWS_NATIVE_STACK
  if [ "$#" -eq 0 ]; then
    printf '%s\n' "$WORKFLOWS_NATIVE_STACK"
    exit 0
  fi
  script="$(workflows_native_script "$1")" || exit 1
  shift
  exec bash "$script" "$@"
fi

WORKFLOWS_NATIVE_STACK="$(workflows_native_stack_resolve)" || exit 1
export WORKFLOWS_NATIVE_STACK

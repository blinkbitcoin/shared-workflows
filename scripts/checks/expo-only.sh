#!/usr/bin/env bash
# Run an Expo-only gate on the Expo stack, and skip it with a notice on a bare
# React Native app.
#
# Usage: expo-only.sh NAME FALLBACK   (the arguments run-consumer-or.sh takes)
#
# check.yml's expo-health gate is on by default, and a bare app has no Expo SDK
# to drift from and no Expo config for expo-doctor to read: run there, it fails
# on the stack rather than on the app. So the gate asks which stack the
# consumer is - packages/app-tooling/lib/native-stack.mjs, the rule the
# contract checker and the security scanners apply, with check.yml's
# native-stack input (NATIVE_STACK) first - and on bare says so and passes. The
# input stays on, so an Expo caller changes nothing.
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"
require_cmd node

name="${1:?usage: expo-only.sh NAME FALLBACK}"
fallback="${2:?usage: expo-only.sh NAME FALLBACK}"

resolver="$(cd "$(dirname "$0")/../.." && pwd)/packages/app-tooling/lib/native-stack.mjs"
[ -f "$resolver" ] || die "expo-only.sh: no stack resolver at $resolver"

root="$(consumer_root)"
# On a line of its own: a failing resolver (an invalid NATIVE_STACK) must stop
# the step, and inside a condition it would not.
stack="$(node "$resolver" --root "$root" --input "${NATIVE_STACK:-}")"

if [ "$stack" != "expo" ]; then
  printf '::notice title=%s skipped::%s is an Expo gate, and this repository is the %s stack, so it does not apply. Pass native-stack: expo if that is wrong.\n' \
    "$name" "$name" "$stack"
  exit 0
fi
exec bash "$(dirname "$0")/run-consumer-or.sh" "$name" "$fallback"

#!/usr/bin/env bash
# Make ios/ or android/ ready to build, the way the consumer's native stack
# does it: the Expo stack regenerates the tree with `expo prebuild`, the bare
# stack checks that the committed tree is there. scripts/lib/native-stack.sh
# decides which, and runs scripts/native/<stack>/prebuild.sh.
#
# Kept at this path, a thin dispatcher, rather than removed: the workflows, the
# docs and every consumer's local notes call `scripts/native/prebuild.sh`, and
# the stack is decided in one place either way.
# Usage: prebuild.sh <ios|android>
set -euo pipefail
exec bash "$(dirname "$0")/../lib/native-stack.sh" prebuild "$@"

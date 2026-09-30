#!/usr/bin/env bash
# A blank machine to one that passes the doctor and can build and run the app
# on Android and iOS, and run both E2E suites. Each part is idempotent, so this
# is also the answer to "something in my toolchain is off": run it again.
# Run from the app's root.
#
#   bash node_modules/@blinkbitcoin/app-tooling/setup/all.sh [--yes] [--boot]
#
# SETUP_DOCTOR: the doctor to finish with, instead of the one beside this
# script (bin/doctor.mjs in the package, packages/app-tooling/bin/doctor.mjs in
# the shared-workflows repository).
set -euo pipefail
here="$(dirname "$0")"
# shellcheck source=scripts/setup/lib.sh
. "$here/lib.sh"

# Found before anything installs: a missing doctor is a broken install of this
# package, and finding out after twenty minutes of downloads helps nobody.
doctor="${SETUP_DOCTOR:-}"
if [ -z "$doctor" ]; then
  for candidate in "$here/../bin/doctor.mjs" "$here/../../packages/app-tooling/bin/doctor.mjs"; do
    if [ -f "$candidate" ]; then
      doctor="$candidate"
      break
    fi
  done
fi
[ -n "$doctor" ] || die "no doctor.mjs beside $here (looked in ../bin and ../../packages/app-tooling/bin)"

bash "$here/toolchain.sh" "$@"
# toolchain.sh may have installed mise into ~/.local/bin, which it put on its
# own PATH only.
have mise || export PATH="$HOME/.local/bin:$PATH"

# Maestro is a JVM app, so its install check runs with mise's java. The same
# checksummed install CI uses; ci/ sits beside setup/ in the package too.
mise exec -- bash "$here/../ci/maestro-install.sh"
bash "$here/android.sh" "$@"
bash "$here/ios.sh" "$@"

# The doctor reads PATH, so it runs inside mise's environment, where
# .env.local's ANDROID_HOME puts adb and maestro on PATH.
mise exec -- node "$doctor"

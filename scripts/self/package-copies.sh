#!/usr/bin/env bash
# Keep the scripts the app-tooling package ships byte-identical to the ones the
# workflows run.
#
# build-prepare.yml runs scripts/release/resolve-version.sh and build-info.sh,
# check.yml runs scripts/checks/{generated,secrets}.sh and
# scripts/ci/check-ci.sh, and check-security.yml runs the scanners under
# scripts/security/; a consumer's verify lanes run scripts/release/verify-*.sh
# and its machine setup scripts/setup/. The E2E runners and build-info.sh ask the
# consumer's native stack for its identifiers and fingerprint, so
# lib/native-stack.sh and each stack's app-config and fingerprint entry points
# (native/expo/, native/bare/) ride along too. A consumer runs the same ones on a laptop (`make
# version`, `make check`), where it has the package and not this repository.
# The package therefore carries them, with the libraries they source and the
# Node programs they run (build-info.sh's build-info.mjs), at the
# same relative paths (release/, checks/, ci/, security/, setup/ and native/ beside lib/, as under
# scripts/), so each copy runs unchanged. check-ci.sh's default zizmor policy,
# .github/zizmor.yml here, rides along as zizmor.yml at the package root. Copies inside one repository,
# held identical on every commit by test/package-copies.bats, cannot drift the
# way a consumer's own copy did: that one was compared only in the consumer's
# CI, and only when a shared-workflows checkout was at hand.
#
# Usage: package-copies.sh           check: fail naming every stale copy
#        package-copies.sh --write   refresh every copy from its original
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"

root="$(cd "$(dirname "$0")/../.." && pwd)"
# ORIGINAL:COPY, the original relative to the repository root and the copy
# relative to packages/app-tooling.
copies=(
  scripts/release/resolve-version.sh:release/resolve-version.sh
  scripts/release/build-info.sh:release/build-info.sh
  scripts/release/build-info.mjs:release/build-info.mjs
  scripts/release/verify-ios.sh:release/verify-ios.sh
  scripts/release/verify-android.sh:release/verify-android.sh
  scripts/lib/verify-common.sh:lib/verify-common.sh
  scripts/setup/all.sh:setup/all.sh
  scripts/setup/toolchain.sh:setup/toolchain.sh
  scripts/setup/android.sh:setup/android.sh
  scripts/setup/ios.sh:setup/ios.sh
  scripts/setup/lib.sh:setup/lib.sh
  scripts/checks/generated.sh:checks/generated.sh
  scripts/checks/secrets.sh:checks/secrets.sh
  scripts/checks/run-script.sh:checks/run-script.sh
  scripts/ci/check-ci.sh:ci/check-ci.sh
  scripts/ci/maestro-install.sh:ci/maestro-install.sh
  scripts/checks/expo-health.sh:checks/expo-health.sh
  scripts/hooks/install-if-lockfile-changed.sh:hooks/install-if-lockfile-changed.sh
  scripts/lib/common.sh:lib/common.sh
  scripts/lib/release-env.sh:lib/release-env.sh
  scripts/lib/git-clean.sh:lib/git-clean.sh
  scripts/lib/versions.sh:lib/versions.sh
  scripts/security/scan.sh:security/scan.sh
  scripts/security/dependencies.sh:security/dependencies.sh
  scripts/security/code.sh:security/code.sh
  scripts/security/policy.sh:security/policy.sh
  scripts/security/sbom.sh:security/sbom.sh
  scripts/security/bundle.sh:security/bundle.sh
  scripts/security/mobile.sh:security/mobile.sh
  scripts/security/binaries.sh:security/binaries.sh
  scripts/security/review.sh:security/review.sh
  scripts/security/review-codebase.sh:security/review-codebase.sh
  scripts/security/lib/runner.sh:security/lib/runner.sh
  scripts/security/rules/react-native-secrets.yaml:security/rules/react-native-secrets.yaml
  scripts/security/semgrepignore:security/semgrepignore
  scripts/e2e/ios-maestro.sh:e2e/ios-maestro.sh
  scripts/e2e/android-maestro.sh:e2e/android-maestro.sh
  scripts/e2e/app-launch.sh:e2e/app-launch.sh
  scripts/e2e/ios-simulator.sh:e2e/ios-simulator.sh
  scripts/e2e/android-emulator.sh:e2e/android-emulator.sh
  scripts/e2e/collect-forensics.sh:e2e/collect-forensics.sh
  scripts/e2e/maestro-bound.sh:e2e/maestro-bound.sh
  scripts/e2e/maestro-suite.sh:e2e/maestro-suite.sh
  scripts/e2e/wait-for-http.sh:e2e/wait-for-http.sh
  scripts/lib/e2e-env.sh:lib/e2e-env.sh
  scripts/lib/expo-config.sh:lib/expo-config.sh
  scripts/lib/native-stack.sh:lib/native-stack.sh
  scripts/native/expo/app-config.sh:native/expo/app-config.sh
  scripts/native/expo/fingerprint.sh:native/expo/fingerprint.sh
  scripts/native/bare/app-config.sh:native/bare/app-config.sh
  scripts/native/bare/fingerprint.sh:native/bare/fingerprint.sh
  .github/zizmor.yml:zizmor.yml
)

write=false
case "${1:-}" in
  '') ;;
  --write) write=true ;;
  *) die "unknown argument: $1 (usage: package-copies.sh [--write])" ;;
esac

stale=()
for pair in "${copies[@]}"; do
  rel="${pair#*:}"
  original="$root/${pair%%:*}"
  copy="$root/packages/app-tooling/$rel"
  [ -f "$original" ] || die "no $original to copy into the package"
  if [ "$write" = true ]; then
    mkdir -p "$(dirname "$copy")"
    cp -p "$original" "$copy"
  elif ! cmp -s "$original" "$copy"; then
    stale+=("packages/app-tooling/$rel")
  fi
done

if [ "$write" = true ]; then
  log "copied ${#copies[@]} files into packages/app-tooling"
  exit 0
fi
[ "${#stale[@]}" -eq 0 ] || die "the package's copies differ from what the workflows run: ${stale[*]} - run: bash scripts/self/package-copies.sh --write"
log "package copies ok (${#copies[@]} files)"

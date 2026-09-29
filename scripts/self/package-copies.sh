#!/usr/bin/env bash
# Keep the scripts the dev-config package ships byte-identical to the ones the
# workflows run.
#
# build-prepare.yml runs scripts/release/resolve-version.sh and build-info.sh,
# and check-code.yml runs scripts/checks/{i18n,codegen,secrets}.sh and
# scripts/ci/lint-ci.sh. A consumer runs the same ones on a laptop (`make
# version`, `make check`), where it has the package and not this repository.
# The package therefore carries them, with the libraries they source, at the
# same relative paths (release/, checks/ and ci/ beside lib/, as under
# scripts/), so each copy runs unchanged. lint-ci.sh's default zizmor policy,
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
# relative to packages/dev-config.
copies=(
  scripts/release/resolve-version.sh:release/resolve-version.sh
  scripts/release/build-info.sh:release/build-info.sh
  scripts/checks/i18n.sh:checks/i18n.sh
  scripts/checks/codegen.sh:checks/codegen.sh
  scripts/checks/secrets.sh:checks/secrets.sh
  scripts/checks/run-script.sh:checks/run-script.sh
  scripts/ci/lint-ci.sh:ci/lint-ci.sh
  scripts/lib/common.sh:lib/common.sh
  scripts/lib/release-env.sh:lib/release-env.sh
  scripts/lib/git-clean.sh:lib/git-clean.sh
  scripts/lib/versions.sh:lib/versions.sh
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
  copy="$root/packages/dev-config/$rel"
  [ -f "$original" ] || die "no $original to copy into the package"
  if [ "$write" = true ]; then
    mkdir -p "$(dirname "$copy")"
    cp -p "$original" "$copy"
  elif ! cmp -s "$original" "$copy"; then
    stale+=("packages/dev-config/$rel")
  fi
done

if [ "$write" = true ]; then
  log "copied ${#copies[@]} files into packages/dev-config"
  exit 0
fi
[ "${#stale[@]}" -eq 0 ] || die "the package's copies differ from what the workflows run: ${stale[*]} - run: bash scripts/self/package-copies.sh --write"
log "package copies ok (${#copies[@]} files)"

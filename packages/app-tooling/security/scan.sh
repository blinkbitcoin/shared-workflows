#!/usr/bin/env bash
# Every enabled scanner, then the verdict - the same scripts and the same
# verdict CI runs, so a green laptop means a green pipeline. Locally a missing
# tool is a skip; under CI it is a failure.
#
#   bash scan.sh              every job
#   bash scan.sh bundle       one job, then its own verdict
#
# The package's `check-security [JOB...]` runs this copy, so a single scanner
# run on a laptop still ends in the same pass/fail answer CI gives.
set -euo pipefail
# The runners beside this one, found before runner.sh moves into the repository
# being scanned: $0 may be a relative path.
runners="$(cd "$(dirname "$0")" && pwd -P)"
# shellcheck source=scripts/security/lib/runner.sh
source "$runners/lib/runner.sh"

# Captured into a variable rather than compared inline: `[ "$(cmd)" != x ]`
# discards cmd's own exit status, so a malformed security-settings.json or an
# invalid SECURITY_* value - both of which the settings resolver is designed to throw
# on - would read as an empty string, never equal "true", and this would
# print "disabled" and exit 0 instead of failing the run.
if ! enabled="$(node "$SECURITY_LIB/security-settings.mjs" get enabled)"; then
  echo "security-settings.mjs failed resolving enabled - security-settings.json or a SECURITY_* value is invalid (see the error above); that fails the run, it does not disable it" >&2
  exit 1
fi
if [ "$enabled" != "true" ]; then
  echo "security scanning is disabled (SECURITY_ENABLED or security-settings.json)"
  exit 0
fi

all_jobs=(dependencies code policy sbom bundle mobile binaries review review-codebase)
if [ $# -eq 0 ]; then
  jobs=("${all_jobs[@]}")
else
  jobs=("$@")
  for job in "${jobs[@]}"; do
    case " ${all_jobs[*]} " in
      *" $job "*) ;;
      *)
        echo "unknown security job: $job (expected one of: ${all_jobs[*]})" >&2
        exit 2
        ;;
    esac
  done
fi

out="$(sec_out_dir)"
# Only this run's SARIF reaches the verdict: a stale file from an earlier run
# of another job would otherwise be judged as if it had just been produced.
rm -f "$out"/*.sarif
# A disabled job still runs its script: the script is what writes the skipped
# SARIF, so the verdict prints "skipped: disabled" rather than nothing at all.
for job in "${jobs[@]}"; do
  bash "$runners/$job.sh"
done

node "$SECURITY_LIB/security-verdict.mjs" "$out"

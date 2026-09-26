#!/usr/bin/env bash
# Name each scanner's SARIF run after the job that produced it.
#
# Usage: label-sarif.sh
#
# Code scanning files every SARIF run under its tool name: in the Security
# tab's tool filter, and as a check of its own on the commit. Left alone that
# name is whatever the scanner calls itself - "osv-scanner", "Semgrep OSS", or
# the consumer's lowercase job key - so one scan reads "Security / Dependencies"
# in the job list and "osv-scanner" next to it. This sets every run's
# tool.driver.name to the job's name in check-security.yml, just before the
# upload. The verdict has already read the files, so nothing it reports changes.
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"
require_cmd jq

# The job names in check-security.yml, keyed by the file each job leaves.
# test/workflow-shape.bats fails when the two disagree.
name_of() {
  case "$1" in
    deps) printf 'Dependencies' ;;
    code) printf 'Code' ;;
    policy) printf 'Policy' ;;
    sbom) printf 'Bill of Materials' ;;
    bundle) printf 'Bundle' ;;
    mobile) printf 'Mobile' ;;
    binaries) printf 'Binaries' ;;
    review) printf 'Review' ;;
    openant) printf 'OpenAnt' ;;
    *) return 1 ;;
  esac
}

root="$(consumer_root)"
cd "$root"

out="${SECURITY_DIR:-.security}"
count=0
for file in "$out"/*.sarif; do
  [ -e "$file" ] || continue
  job="$(basename "$file" .sarif)"
  name="$(name_of "$job")" \
    || die "$file: check-security.yml has no job named after $job, so its findings would upload under whatever the scanner calls itself"
  jq --arg name "$name" '.runs = ((.runs // []) | map(.tool.driver.name = $name))' "$file" > "$file.labelled"
  mv "$file.labelled" "$file"
  log "$job: labelled $name"
  count=$((count + 1))
done
[ "$count" -gt 0 ] || die "no SARIF files in $out to label"

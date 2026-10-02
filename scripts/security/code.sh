#!/usr/bin/env bash
# Semgrep CE over the app source: the community TypeScript, secrets and OWASP
# packs, this family's React Native rules (rules/, beside this script), plus the
# repository's own rules, named in jobs.code.rules of security-settings.json. A
# named path that does not exist fails the run: a typo must not quietly drop a
# rule set. Findings do not fail this script. Paths to leave alone: the
# family's list (semgrepignore, beside this script) and the repository's own
# .semgrepignore, both applied.
set -euo pipefail
# Found before anything changes directory: $0 may be a relative path.
here="$(cd "$(dirname "$0")" && pwd -P)"
# shellcheck source=scripts/security/lib/runner.sh
source "$here/lib/runner.sh"

sec_enabled code
sec_require semgrep code

rules="$(sec_setting options.code.rules)"
configs=(--config p/typescript --config p/secrets --config p/owasp-top-ten --config "$here/rules")
if [ -n "$rules" ]; then
  IFS=',' read -r -a paths <<<"$rules"
  for path in "${paths[@]}"; do
    [ -e "$path" ] || {
      echo "code: jobs.code.rules names $path, which does not exist" >&2
      exit 1
    }
    configs+=(--config "$path")
  done
fi

# The family's ignore list as --exclude flags: Semgrep reads .semgrepignore
# from the repository only, and a repository's own file replaces its defaults
# rather than adding to them, so the shared paths ride on the command line.
excludes=()
while IFS= read -r line; do
  case "$line" in '' | '#'*) continue ;; esac
  excludes+=(--exclude "$line")
done <"$here/semgrepignore"

out="$(sec_out_dir)"
# No --error: a finding is reported, not thrown. --metrics off is telemetry
# only - it stops Semgrep phoning home with scan statistics, it does not make
# the run offline: --config p/... fetches each registry pack over the
# network on every invocation.
semgrep scan "${configs[@]}" "${excludes[@]}" \
  --sarif --output "$out/code.sarif" --metrics off --quiet
echo "code: wrote $out/code.sarif"

#!/usr/bin/env bash
# Semgrep CE over the app source: the community TypeScript, secrets and OWASP
# packs, plus the repository's own rules, named in jobs.code.rules of
# security-settings.json (no React Native ruleset exists upstream, so an app
# writes its own). A named path that does not exist fails the run: a typo must
# not quietly drop a rule set. Findings do not fail this script. Paths to leave
# alone: .semgrepignore.
set -euo pipefail
# shellcheck source=scripts/security/lib/runner.sh
source "$(dirname "$0")/lib/runner.sh"

sec_enabled code
sec_require semgrep code

rules="$(sec_setting options.code.rules)"
configs=(--config p/typescript --config p/secrets --config p/owasp-top-ten)
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

out="$(sec_out_dir)"
# No --error: a finding is reported, not thrown. --metrics off is telemetry
# only - it stops Semgrep phoning home with scan statistics, it does not make
# the run offline: --config p/... fetches each registry pack over the
# network on every invocation.
semgrep scan "${configs[@]}" \
  --sarif --output "$out/code.sarif" --metrics off --quiet
echo "code: wrote $out/code.sarif"

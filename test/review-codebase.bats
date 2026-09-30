#!/usr/bin/env bats
# scripts/security/review-codebase.sh - runs knostic/OpenAnt over the
# consumer's codebase with a private configuration built from the llm
# settings, then turns its results into review-codebase.sarif. A fake openant
# stands in for the scanner; under CI, fake git and mise stand in for the
# build from the pinned commit. Nothing here touches the network.
#
# Exit paths covered: switched off (a skipped SARIF, 0); an invalid llm
# setting (1); each configuration skip - no provider, no OpenAI key, no
# Anthropic key, no model - and no openant locally (0); a scan (0) whose
# configuration, arguments, file mode and report are checked, for OpenAI with
# and without a base URL and for Anthropic; a scan that exits 1 (tolerated)
# and one that exits 2 (1); no results file (a skip, 0); results.json when
# there is no verified file; a report that breaks (1); and under CI, the
# build from the pinned commit - into OPENANT_HOME or the default cache,
# reused on the next run, rebuilt over a half-finished one, and a fetch that
# fails (nonzero).
#
# Every assertion ends in `|| fail "..."` - see test_helper.bash.
load test_helper

setup() {
  unset CI GITHUB_WORKSPACE WORKING_DIRECTORY ANDROID_HOME ANDROID_SDK_ROOT OPENANT_HOME OPENANT_CORE_PATH XDG_CONFIG_HOME \
    SCAN_STATUS RESULTS_FILE REPORT_STATUS FETCH_FAILS
  local var
  for var in $(compgen -e | grep -E '^(SECURITY_|OPENAI_|ANTHROPIC_)' || true); do unset "$var"; done
  export SECURITY_SETTINGS_FILE="$BATS_TEST_TMPDIR/no-security-settings.json"
  export SECURITY_DIR="$BATS_TEST_TMPDIR/out"
  # Switched on and configured: each case takes away what it is about.
  export SECURITY_REVIEW_CODEBASE=true SECURITY_LLM_PROVIDER=openai SECURITY_LLM_MODEL=kimi-k3
  export OPENAI_API_KEY=sk-test-openant OPENAI_BASE_URL=https://api.moonshot.ai/v1
  app="$BATS_TEST_TMPDIR/app"
  mkdir -p "$app"
  cd "$app" || return 1
  bin="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$bin"
  RECORD="$BATS_TEST_TMPDIR/record"
  mkdir -p "$RECORD"
  export RECORD
  COMMIT="$(sed -n 's/^OPENANT_COMMIT=//p' "$REPO_ROOT/scripts/security/review-codebase.sh")"
}

# A fake openant in $1 (default $bin). `scan` records its arguments, where it
# ran, OPENANT_CORE_PATH and a copy and the mode of the configuration it was
# given, writes $RESULTS_FILE under -o (none when it is empty) and exits with
# $SCAN_STATUS; `report` records its arguments and writes a SARIF where -o
# says, or fails with $REPORT_STATUS.
fake_openant() {
  local dir="${1:-$bin}"
  mkdir -p "$dir"
  cat > "$dir/openant" <<STUB
#!/usr/bin/env bash
if [ "\$1" = scan ]; then
  echo "\$*" > "$RECORD/scan-args"
  pwd > "$RECORD/scan-cwd"
  echo "\${OPENANT_CORE_PATH-unset}" > "$RECORD/core-path"
  cp "\$XDG_CONFIG_HOME/openant/config.json" "$RECORD/config.json"
  stat -f %Lp "\$XDG_CONFIG_HOME/openant/config.json" > "$RECORD/config-mode" 2>/dev/null \
    || stat -c %a "\$XDG_CONFIG_HOME/openant/config.json" > "$RECORD/config-mode"
  echo "scan log line"
  out=""; while [ \$# -gt 0 ]; do [ "\$1" = -o ] && out="\$2"; shift; done
  if [ -n "\${RESULTS_FILE-results_verified.json}" ]; then
    mkdir -p "\$out/x" && echo "{}" > "\$out/x/\${RESULTS_FILE-results_verified.json}"
  fi
  exit \${SCAN_STATUS:-1}
fi
if [ "\$1" = report ]; then
  echo "\$*" > "$RECORD/report-args"
  [ "\${REPORT_STATUS:-0}" = 0 ] || { echo "report broke" >&2; exit "\$REPORT_STATUS"; }
  while [ \$# -gt 0 ]; do
    [ "\$1" = -o ] && echo '{"version":"2.1.0","runs":[{"tool":{"driver":{"name":"OpenAnt"}},"results":[]}]}' > "\$2"
    shift
  done
fi
STUB
  chmod +x "$dir/openant"
}

# Fake git and mise for the CI build. git init makes the checkout's
# apps/openant-cli (unless $FETCH_FAILS, when fetch fails); mise's "go build"
# drops a fake openant into bin/. Both log to $RECORD/build-log.
build_fakes() {
  fake_openant "$BATS_TEST_TMPDIR/built"
  cat > "$bin/git" <<STUB
#!/usr/bin/env bash
echo "git \$*" >> "$RECORD/build-log"
[ "\$1" != init ] || mkdir -p "\$3/apps/openant-cli"
[ "\$3" != fetch ] || [ -z "\${FETCH_FAILS:-}" ] || { echo "fatal: unable to access" >&2; exit 128; }
STUB
  cat > "$bin/mise" <<STUB
#!/usr/bin/env bash
echo "mise \$* (in \$PWD)" >> "$RECORD/build-log"
mkdir -p bin
cp "$BATS_TEST_TMPDIR/built/openant" bin/openant
STUB
  chmod +x "$bin/git" "$bin/mise"
}

# A PATH with only what the runner needs, and no openant, git or mise.
bare_path() {
  local dir="$BATS_TEST_TMPDIR/bare" tool found
  mkdir -p "$dir"
  for tool in bash env node mkdir dirname find head mktemp rm cat cp stat pwd; do
    found="$(command -v "$tool" || true)"
    [ -z "$found" ] || ln -sf "$found" "$dir/$tool"
  done
  printf '%s' "$dir"
}

# The JSON at a dotted path in a file: json file llm_providers.security, runs.0.tool.
json() {
  node -e 'const d = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
process.stdout.write(JSON.stringify(process.argv[2].split(".").reduce((v, k) => v?.[k], d)))' "$@"
}
sarif_note() {
  node -e 'const d = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
process.stdout.write((d.runs[0].invocations?.[0]?.toolExecutionNotifications ?? []).map((n) => n.message.text).join("\n"))' "$1"
}

review_codebase() { run bash "$REPO_ROOT/scripts/security/review-codebase.sh"; }
review_codebase_on() { local path="$1"; shift; run env PATH="$path" "$@" "$BASH" "$REPO_ROOT/scripts/security/review-codebase.sh"; }

@test "switched off, it writes a skipped SARIF and exits 0" {
  export SECURITY_REVIEW_CODEBASE=false
  fake_openant
  PATH="$bin:$PATH" review_codebase
  [ "$status" -eq 0 ] || fail "status $status: $output"
  contains "$(sarif_note "$SECURITY_DIR/review-codebase.sarif")" 'disabled' || fail "the skip does not say it is disabled"
  [ ! -e "$RECORD/scan-args" ] || fail "openant ran for a disabled job"
}

@test "an llm provider it does not know fails the run" {
  export SECURITY_LLM_PROVIDER=mistral
  review_codebase
  [ "$status" -eq 1 ] || fail "an invalid provider passed with $status: $output"
  contains "$output" 'SECURITY_LLM_PROVIDER' || fail "the error does not name the setting: $output"
}

@test "no provider is a skip with its reason" {
  export SECURITY_LLM_PROVIDER=''
  review_codebase
  [ "$status" -eq 0 ] || fail "status $status: $output"
  contains "$(sarif_note "$SECURITY_DIR/review-codebase.sarif")" 'no LLM provider configured (llm.provider or SECURITY_LLM_PROVIDER)' \
    || fail "the skip gives no reason"
}

@test "no OpenAI key is a skip with its reason" {
  unset OPENAI_API_KEY
  review_codebase
  [ "$status" -eq 0 ] || fail "status $status: $output"
  contains "$(sarif_note "$SECURITY_DIR/review-codebase.sarif")" 'OPENAI_API_KEY is not set' || fail "the skip gives no reason"
}

@test "no Anthropic key is a skip with its reason" {
  export SECURITY_LLM_PROVIDER=anthropic ANTHROPIC_API_KEY=''
  review_codebase
  [ "$status" -eq 0 ] || fail "status $status: $output"
  contains "$(sarif_note "$SECURITY_DIR/review-codebase.sarif")" 'ANTHROPIC_API_KEY is not set' || fail "the skip gives no reason"
}

@test "no model is a skip with its reason" {
  export SECURITY_LLM_MODEL=''
  review_codebase
  [ "$status" -eq 0 ] || fail "status $status: $output"
  contains "$(sarif_note "$SECURITY_DIR/review-codebase.sarif")" 'no model configured' || fail "the skip gives no reason"
}

@test "no openant is a skip locally that says where to get it" {
  review_codebase_on "$(bare_path)"
  [ "$status" -eq 0 ] || fail "status $status: $output"
  contains "$(sarif_note "$SECURITY_DIR/review-codebase.sarif")" 'openant is not installed (https://github.com/knostic/OpenAnt, apps/openant-cli: make build)' \
    || fail "the skip gives no way forward: $(sarif_note "$SECURITY_DIR/review-codebase.sarif")"
}

@test "scans with a private configuration built from the llm settings, then reports SARIF" {
  fake_openant
  export SECURITY_REVIEW_CODEBASE_LIMIT=25 SECURITY_REVIEW_CODEBASE_VERIFY=true
  PATH="$bin:$PATH" review_codebase
  [ "$status" -eq 0 ] || fail "status $status: $output"
  contains "$output" "review-codebase: wrote $SECURITY_DIR/review-codebase.sarif" || fail "the log does not say where: $output"
  grep -Eqx 'scan \. -l javascript -o \S+/scan --llm-config security --skip-dynamic-test --no-report --limit 25 --verify' "$RECORD/scan-args" \
    || fail "scan args: $(cat "$RECORD/scan-args")"
  [ "$(cat "$RECORD/scan-cwd")" = "$(cd "$app" && pwd -P)" ] || fail "the scan ran in $(cat "$RECORD/scan-cwd"), not the consumer"
  [ "$(json "$RECORD/config.json" llm_providers.security)" = '{"type":"openai","api_key":"sk-test-openant","base_url":"https://api.moonshot.ai/v1"}' ] \
    || fail "provider: $(json "$RECORD/config.json" llm_providers.security)"
  [ "$(json "$RECORD/config.json" default_llm)" = '"security"' ] || fail "default_llm: $(json "$RECORD/config.json" default_llm)"
  [ "$(json "$RECORD/config.json" '$schema_version')" = '2' ] || fail "schema version: $(json "$RECORD/config.json" '$schema_version')"
  [ "$(json "$RECORD/config.json" llm_configs.security | node -e 'process.stdout.write(Object.keys(JSON.parse(require("fs").readFileSync(0,"utf8"))).join(" "))')" \
    = 'app_context llm_reach enhance analyze verify dynamic_test report' ] || fail "not every phase is configured"
  [ "$(json "$RECORD/config.json" llm_configs.security.analyze)" = '{"provider":"security","model":"kimi-k3"}' ] \
    || fail "phase: $(json "$RECORD/config.json" llm_configs.security.analyze)"
  [ "$(cat "$RECORD/config-mode")" = 600 ] || fail "the configuration holding the key is mode $(cat "$RECORD/config-mode")"
  grep -Eq '/results_verified\.json -f sarif -o .*/review-codebase\.sarif$' "$RECORD/report-args" \
    || fail "report args: $(cat "$RECORD/report-args")"
  [ "$(json "$SECURITY_DIR/review-codebase.sarif" runs.0.tool.driver.name)" = '"OpenAnt"' ] || fail "not OpenAnt's SARIF"
  not_contains "$output" 'sk-test-openant' || fail "the key reached the job log"
  not_contains "$output" 'scan log line' || fail "a successful scan's log was shown"
  [ "$(cat "$RECORD/core-path")" = unset ] || fail "a local openant was given a core path: $(cat "$RECORD/core-path")"
}

@test "an Anthropic provider gets no base URL, and default limits add no flags" {
  fake_openant
  export SECURITY_LLM_PROVIDER=anthropic ANTHROPIC_API_KEY=sk-ant-x SCAN_STATUS=0
  PATH="$bin:$PATH" review_codebase
  [ "$status" -eq 0 ] || fail "status $status: $output"
  [ "$(json "$RECORD/config.json" llm_providers.security)" = '{"type":"anthropic","api_key":"sk-ant-x"}' ] \
    || fail "provider: $(json "$RECORD/config.json" llm_providers.security)"
  ! grep -Eq -e '--limit|--verify' "$RECORD/scan-args" || fail "default settings added flags: $(cat "$RECORD/scan-args")"
}

@test "an OpenAI provider without OPENAI_BASE_URL gets no base URL" {
  fake_openant
  unset OPENAI_BASE_URL
  PATH="$bin:$PATH" review_codebase
  [ "$status" -eq 0 ] || fail "status $status: $output"
  [ "$(json "$RECORD/config.json" llm_providers.security)" = '{"type":"openai","api_key":"sk-test-openant"}' ] \
    || fail "provider: $(json "$RECORD/config.json" llm_providers.security)"
}

@test "a failed scan (exit 2 or more) fails the job and shows its log" {
  fake_openant
  export SCAN_STATUS=2
  PATH="$bin:$PATH" review_codebase
  [ "$status" -eq 1 ] || fail "a failed scan passed with $status: $output"
  contains "$output" 'scan log line' || fail "the scan's log is not shown: $output"
  contains "$output" 'openant scan failed (exit 2)' || fail "the error: $output"
  [ ! -e "$RECORD/report-args" ] || fail "a report ran after a failed scan"
}

@test "a scan with no results file is a skip" {
  fake_openant
  export SCAN_STATUS=0 RESULTS_FILE=''
  PATH="$bin:$PATH" review_codebase
  [ "$status" -eq 0 ] || fail "status $status: $output"
  contains "$(sarif_note "$SECURITY_DIR/review-codebase.sarif")" 'OpenAnt finished (exit 0) without a results file' \
    || fail "the skip gives no reason"
  [ ! -e "$RECORD/report-args" ] || fail "a report ran with no results"
}

@test "an unverified results.json is reported when there is no verified one" {
  fake_openant
  export RESULTS_FILE=results.json
  PATH="$bin:$PATH" review_codebase
  [ "$status" -eq 0 ] || fail "status $status: $output"
  grep -Eq '/results\.json -f sarif -o ' "$RECORD/report-args" || fail "report args: $(cat "$RECORD/report-args")"
}

@test "a broken report fails the job and shows why" {
  fake_openant
  export REPORT_STATUS=3
  PATH="$bin:$PATH" review_codebase
  [ "$status" -eq 1 ] || fail "a broken report passed with $status: $output"
  contains "$output" 'report broke' || fail "the report's log is not shown: $output"
  contains "$output" 'openant report failed to write SARIF' || fail "the error: $output"
}

@test "under CI a missing openant is built from the pinned commit, and reused after" {
  build_fakes
  local home="$BATS_TEST_TMPDIR/openant-home"
  review_codebase_on "$bin:$(bare_path)" CI=true OPENANT_HOME="$home"
  [ "$status" -eq 0 ] || fail "status $status: $output"
  grep -qx "git init -q $home/$COMMIT" "$RECORD/build-log" || fail "build log: $(cat "$RECORD/build-log")"
  grep -qx "git -C $home/$COMMIT fetch -q --depth 1 https://github.com/knostic/OpenAnt $COMMIT" "$RECORD/build-log" \
    || fail "not fetched at the pinned commit: $(cat "$RECORD/build-log")"
  grep -qx "git -C $home/$COMMIT checkout -q FETCH_HEAD" "$RECORD/build-log" || fail "build log: $(cat "$RECORD/build-log")"
  grep -q "^mise x go@1.26 -- go build -o bin/openant ./main.go (in .*/$COMMIT/apps/openant-cli)$" "$RECORD/build-log" \
    || fail "not built with the pinned Go: $(cat "$RECORD/build-log")"
  [ -x "$home/$COMMIT/apps/openant-cli/bin/openant" ] || fail "no build at $home/$COMMIT/apps/openant-cli/bin/openant"
  [ "$(cat "$RECORD/core-path")" = "$home/$COMMIT/libs/openant-core" ] || fail "core path: $(cat "$RECORD/core-path")"
  [ -s "$SECURITY_DIR/review-codebase.sarif" ] || fail "the built openant wrote no SARIF"
  # The second run finds the build in place and does not fetch again.
  rm "$RECORD/build-log"
  review_codebase_on "$bin:$(bare_path)" CI=true OPENANT_HOME="$home"
  [ "$status" -eq 0 ] || fail "the second run: status $status: $output"
  [ ! -e "$RECORD/build-log" ] || fail "the second run built again: $(cat "$RECORD/build-log")"
}

@test "under CI the build goes to the default cache under HOME" {
  build_fakes
  review_codebase_on "$bin:$(bare_path)" CI=true HOME="$BATS_TEST_TMPDIR/home"
  [ "$status" -eq 0 ] || fail "status $status: $output"
  [ -x "$BATS_TEST_TMPDIR/home/.cache/openant/$COMMIT/apps/openant-cli/bin/openant" ] || fail "no build in the default cache"
}

@test "under CI a half-finished build is thrown away and redone" {
  build_fakes
  local home="$BATS_TEST_TMPDIR/openant-home"
  mkdir -p "$home/$COMMIT/apps/openant-cli"
  printf 'left over\n' > "$home/$COMMIT/stale"
  review_codebase_on "$bin:$(bare_path)" CI=true OPENANT_HOME="$home"
  [ "$status" -eq 0 ] || fail "status $status: $output"
  [ ! -e "$home/$COMMIT/stale" ] || fail "the half-finished build was built over"
  grep -q ' fetch ' "$RECORD/build-log" || fail "no fetch: $(cat "$RECORD/build-log")"
}

@test "under CI a fetch that fails fails the job" {
  build_fakes
  review_codebase_on "$bin:$(bare_path)" CI=true OPENANT_HOME="$BATS_TEST_TMPDIR/openant-home" FETCH_FAILS=1
  [ "$status" -ne 0 ] || fail "a failed fetch passed: $output"
  contains "$output" 'fatal: unable to access' || fail "git's error is not shown: $output"
  ! grep -q '^mise ' "$RECORD/build-log" || fail "the build ran after a failed fetch"
  [ ! -e "$SECURITY_DIR/review-codebase.sarif" ] || fail "a failed fetch still wrote a SARIF"
}

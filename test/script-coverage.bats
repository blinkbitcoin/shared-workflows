#!/usr/bin/env bats
# Every assertion ends in `|| fail "..."` - see test_helper.bash.
#
# Nothing failed when a script arrived without a test.
#
# Add scripts/ci/new-thing.sh and push: shellcheck lints it, actionlint ignores
# it, `bats test/` runs several hundred cases none of which mention it, and
# `make check` goes green. That is how 16 scripts came to have no coverage of
# any kind - including three in the `setup` action, sitting beside one that does
# have tests, which is what made the gap look accidental rather than considered.
#
# This repo already knows how to write this kind of gate and has written three:
# assertions-enforced (every assertion ends in `|| fail`), docs-contract
# (Makefile <-> AGENTS.md) and no-legacy-prefix. One for make targets, one for
# assertion style, one for a variable prefix - and none for a script with no
# test. This is that one.
#
# "Covered" means a test *executes* it. Ten scripts are named by a test that
# only reads their source text - a grep for a pattern, an assertion about a
# comment - and that reads as coverage in a listing while asserting nothing
# about behaviour. The resolver below draws that line on purpose.

load test_helper

# Scripts that cannot be exercised from a bats suite, with the reason. An entry
# here is a debt someone chose, not a gap nobody noticed - and a stale entry is
# itself a failure, so the list cannot outlive what it excuses.
#
# The device and build scripts are covered end to end by self-smoke.yml, which
# runs the whole family against a real consumer on real runners.
ALLOWED="
scripts/native/prebuild.sh|runs expo prebuild against a real Expo app
scripts/native/pods.sh|needs CocoaPods and a prebuilt ios/ directory
scripts/native/ios-build.sh|needs Xcode and a simulator SDK
scripts/native/ios-pack.sh|needs a built .app bundle to pack
scripts/native/android-build.sh|needs a Gradle wrapper and an Android SDK
scripts/e2e/ios-maestro.sh|needs a booted simulator and the Maestro CLI
scripts/e2e/android-maestro.sh|needs a running emulator and the Maestro CLI
scripts/e2e/metro-start.sh|starts a long-lived Metro process in the background
"

# Prints every tracked script, one per line.
all_scripts() {
  git -C "$REPO_ROOT" ls-files 'scripts/**/*.sh' 'scripts/**/*.mjs' 'packages/dev-config/bin/*.mjs'
}

# Prints every script some test actually runs.
#
# Execution is not the same as mention, and the difference is the point. A path
# counts when a test invokes it (`bash "$REPO_ROOT/scripts/x.sh"`, `source`,
# `node`, `run`) - directly, or through a variable the file assigns it to and
# later invokes, which is how most files here are written.
executed_scripts() {
  mise exec -- python3 -c "
import os, re, subprocess, sys

root = os.environ['REPO_ROOT']
tests = subprocess.run(['git', '-C', root, 'ls-files', 'test/*.bats', 'packages/dev-config/*.test.mjs'],
                       capture_output=True, text=True).stdout.split()
scripts = subprocess.run(['git', '-C', root, 'ls-files', 'scripts/**/*.sh', 'scripts/**/*.mjs',
                          'packages/dev-config/bin/*.mjs'], capture_output=True, text=True).stdout.split()

RUNNERS = r'(?:bash|sh|source|\.|exec|node|run|execFileSync|spawnSync)'
covered = set()

for test in tests:
    text = open(os.path.join(root, test)).read()
    # Variables a test assigns a script path to, and whether it ever runs them.
    aliases = {}
    for name, path in re.findall(r'(\w+)=[\"\']?\\\$\{?REPO_ROOT\}?/([^\"\'\s\$]+)', text):
        aliases.setdefault(path, set()).add(name)
    for script in scripts:
        if script not in text:
            continue
        # Run directly on some line.
        if re.search(RUNNERS + r'[^\n]*' + re.escape(script), text):
            covered.add(script)
            continue
        # Or run through a variable this file assigned it to.
        for var in aliases.get(script, ()):
            if re.search(RUNNERS + r'\s+[\"\']?\\\$\{?' + var + r'\}?', text) or \
               re.search(r'\\\$\{?' + var + r'\}?[^\n]*\|\|', text):
                covered.add(script)
                break

print('\n'.join(sorted(covered)))
"
}

allowed_reason() {
  printf '%s\n' "$ALLOWED" | awk -F'|' -v s="$1" '$1 == s { print $2 }'
}

@test "every script is executed by a test, or allow-listed with a reason" {
  local uncovered="" script
  local executed
  executed="$(executed_scripts)"
  while read -r script; do
    [ -n "$script" ] || continue
    grep -qxF "$script" <<< "$executed" && continue
    [ -n "$(allowed_reason "$script")" ] && continue
    uncovered="$uncovered
  $script"
  done <<< "$(all_scripts)"
  [ -z "$uncovered" ] || fail "these scripts are executed by no test, and are not allow-listed:$uncovered

Add a test that runs it, or add it to ALLOWED in this file with the reason it
cannot be run from a bats suite."
}

@test "every allow-listed script still exists, and still has no test" {
  # A list of excuses outliving what it excuses is how an allowlist becomes a
  # place where coverage goes to be forgotten.
  local stale="" gone="" entry script
  local executed
  executed="$(executed_scripts)"
  while IFS='|' read -r script _; do
    [ -n "$script" ] || continue
    [ -f "$REPO_ROOT/$script" ] || gone="$gone $script"
    grep -qxF "$script" <<< "$executed" && stale="$stale $script"
  done <<< "$(printf '%s\n' "$ALLOWED" | grep '|')"
  [ -z "$gone" ] || fail "ALLOWED names scripts that no longer exist:$gone"
  [ -z "$stale" ] || fail "these are allow-listed but now have a test - remove them from ALLOWED:$stale"
}

@test "every allow-listed entry gives a reason" {
  local bad="" entry
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    case "$entry" in *'|'*) ;; *) bad="$bad $entry"; continue ;; esac
    [ -n "${entry#*|}" ] || bad="$bad ${entry%%|*}"
  done <<< "$(printf '%s\n' "$ALLOWED" | grep .)"
  [ -z "$bad" ] || fail "allow-listed without a reason:$bad"
}

@test "the resolver tells running a script from merely naming one" {
  # The distinction the whole file rests on. Ten scripts are named by tests that
  # only read their source; counting those would make this gate agree that the
  # repository is covered when it is not.
  local probe="$BATS_TEST_TMPDIR/probe.bats"
  cat > "$probe" <<'PROBE'
run bash "$REPO_ROOT/scripts/ci/tool-version.sh" ruby
grep -q something "$REPO_ROOT/scripts/ci/free-disk.sh"
PROBE
  run mise exec -- python3 -c "
import re
text = open('$probe').read()
RUNNERS = r'(?:bash|sh|source|\.|exec|node|run|execFileSync|spawnSync)'
for s in ['scripts/ci/tool-version.sh', 'scripts/ci/free-disk.sh']:
    print(s, bool(re.search(RUNNERS + r'[^\n]*' + re.escape(s), text)))
"
  contains "$output" "scripts/ci/tool-version.sh True" || fail "an executed script was not recognised: $output"
  contains "$output" "scripts/ci/free-disk.sh False" || fail "a grepped script was counted as executed: $output"
}

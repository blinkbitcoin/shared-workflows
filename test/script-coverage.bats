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
# It now asks for more than that: each script's *own* test file - named after
# it, `test/<name>.bats` - has to run it. A case in a shared suite is welcome on
# top, but a script whose only test lives in plumbing.bats loses its coverage
# the day that suite changes, and nobody reading plumbing.bats is looking for
# it. See "A new script needs a test file of its own" in CONTRIBUTING.md.
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

# Prints `SCRIPT<TAB>TEST` for every test file that actually runs a script.
#
# Execution is not the same as mention, and the difference is the point. A path
# counts when a test invokes it (`bash "$REPO_ROOT/scripts/x.sh"`, `source`,
# `node`, `run`) - directly, or through a variable the file assigns it to and
# later invokes, which is how most files here are written. The runner has to
# be a word of its own, at the start of a line or after a separator: a `.`
# inside `sed -i.bak` or a quoted `name.mjs` is not `. file`. A node:test file
# also runs what it imports (`from './bin/x.mjs'`, `from '../scripts/x.mjs'`).
executed_by() {
  mise exec -- python3 -c "
import os, re, subprocess

root = os.environ['REPO_ROOT']
ls = lambda *p: subprocess.run(['git', '-C', root, 'ls-files', *p], capture_output=True, text=True).stdout.split()
tests = ls('test/*.bats', 'test/*.test.mjs', 'packages/dev-config/*.test.mjs')
scripts = ls('scripts/**/*.sh', 'scripts/**/*.mjs', 'packages/dev-config/bin/*.mjs')

RUNNERS = r'(?m)(?:^|[\s;&|(])(?:bash|sh|source|\.|exec|node|run|execFileSync|spawnSync)(?=[\s(])'

for test in tests:
    text = open(os.path.join(root, test)).read()
    # Modules a node:test file imports, as paths from the repository root.
    imported = set()
    if test.endswith('.mjs'):
        for rel in re.findall(r'from\s+[\"\'](\.{1,2}/[^\"\']+)[\"\']', text):
            imported.add(os.path.normpath(os.path.join(os.path.dirname(test), rel)))
    # Variables a test assigns a script path to, and whether it ever runs them.
    aliases = {}
    for name, path in re.findall(r'(\w+)=[\"\']?\\\$\{?REPO_ROOT\}?/([^\"\'\s\$]+)', text):
        aliases.setdefault(path, set()).add(name)
    for script in scripts:
        if script in imported:
            print(script + '\t' + test)
            continue
        if script not in text:
            continue
        # Run directly on some line.
        if re.search(RUNNERS + r'[^\n]*' + re.escape(script), text):
            print(script + '\t' + test)
            continue
        # Or run through a variable this file assigned it to.
        for var in aliases.get(script, ()):
            if re.search(RUNNERS + r'\s+[\"\']?\\\$\{?' + var + r'\}?', text) or \
               re.search(r'\\\$\{?' + var + r'\}?[^\n]*\|\|', text):
                print(script + '\t' + test)
                break
"
}

allowed_reason() {
  printf '%s\n' "$ALLOWED" | awk -F'|' -v s="$1" '$1 == s { print $2 }'
}

# Prints the test files that may be SCRIPT's own, one per line: the file named
# after it, or after its area and name when two scripts share a name
# (scripts/ota/export.sh -> test/export.bats or test/ota-export.bats). A Node
# script's own test is a node:test file; a dev-config program's sits at the
# package root, because bin/ is what the package publishes.
own_tests() {
  local script="$1" file name area
  file="${script##*/}"
  name="${file%.*}"
  case "$script" in
    packages/dev-config/bin/*.mjs) printf '%s\n' "packages/dev-config/$name.test.mjs" ;;
    scripts/*)
      area="${script#scripts/}"
      area="${area%%/*}"
      case "$file" in
        *.mjs) printf '%s\n' "test/$name.test.mjs" "test/$area-$name.test.mjs" ;;
        *) printf '%s\n' "test/$name.bats" "test/$area-$name.bats" ;;
      esac
      ;;
  esac
}

# Prints every script with no own test file that runs it, less the allowlist.
# $1 is executed_by's output.
without_own_test() {
  local executed="$1" script own
  while read -r script; do
    [ -n "$script" ] || continue
    [ -n "$(allowed_reason "$script")" ] && continue
    while read -r own; do
      grep -qxF "$script	$own" <<< "$executed" && continue 2
    done <<< "$(own_tests "$script")"
    printf '%s\n' "$script"
  done <<< "$(all_scripts)"
}

@test "every script has its own test file, and that file runs it" {
  local missing
  missing="$(without_own_test "$(executed_by)")"
  [ -z "$missing" ] || fail "these scripts have no test file of their own that runs them:
$(sed 's/^/  /' <<< "$missing")

Give each one its own test file, named after it: scripts/ci/x.sh -> test/x.bats
(test/ci-x.bats when another script is also called x), scripts/lib/x.mjs ->
test/x.test.mjs. It has to run the script, not just read it; a case in a
shared suite does not count. If it truly cannot be run from a test, add it to
ALLOWED in this file with the reason."
}

@test "own_tests names the test file after the script, or its area and name" {
  local out
  out="$(own_tests scripts/ota/export.sh | tr '\n' ' ')"
  [ "$out" = "test/export.bats test/ota-export.bats " ] || fail "bash script: $out"
  out="$(own_tests scripts/lib/env-validate.mjs | tr '\n' ' ')"
  [ "$out" = "test/env-validate.test.mjs test/lib-env-validate.test.mjs " ] || fail "Node script: $out"
  out="$(own_tests packages/dev-config/bin/check-tool-versions.mjs)"
  [ "$out" = "packages/dev-config/check-tool-versions.test.mjs" ] || fail "dev-config program: $out"
}

@test "a script run only by a shared suite, or by no test, is named" {
  # all_scripts is replaced, so the rule is exercised on a fixed tree.
  all_scripts() { printf '%s\n' scripts/ci/a.sh scripts/ci/b.sh scripts/ci/c.sh scripts/ci/d.sh; }
  local executed missing
  executed="scripts/ci/a.sh	test/a.bats
scripts/ci/b.sh	test/plumbing.bats
scripts/ci/d.sh	test/ci-d.bats"
  missing="$(without_own_test "$executed" | tr '\n' ' ')"
  [ "$missing" = "scripts/ci/b.sh scripts/ci/c.sh " ] || fail "expected b (shared suite) and c (no test): $missing"
}

@test "an allow-listed script needs no test file of its own" {
  all_scripts() { printf '%s\n' scripts/native/pods.sh; }
  [ -z "$(without_own_test "")" ] || fail "an allow-listed script was reported"
}

@test "a node:test file runs what it imports" {
  local out
  out="$(executed_by | grep -F 'packages/dev-config/bin/check-tool-versions.mjs	packages/dev-config/check-tool-versions.test.mjs' || true)"
  [ -n "$out" ] || fail "an imported program was not counted as run by its test"
}

@test "every allow-listed script still exists, and still has no own test" {
  # A list of excuses outliving what it excuses is how an allowlist becomes a
  # place where coverage goes to be forgotten.
  local stale="" gone="" script own executed
  executed="$(executed_by)"
  while IFS='|' read -r script _; do
    [ -n "$script" ] || continue
    [ -f "$REPO_ROOT/$script" ] || gone="$gone $script"
    while read -r own; do
      grep -qxF "$script	$own" <<< "$executed" && stale="$stale $script"
    done <<< "$(own_tests "$script")"
  done <<< "$(printf '%s\n' "$ALLOWED" | grep '|')"
  [ -z "$gone" ] || fail "ALLOWED names scripts that no longer exist:$gone"
  [ -z "$stale" ] || fail "these are allow-listed but now have their own test - remove them from ALLOWED:$stale"
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
sed -i.bak 's/a/b/' "$REPO_ROOT/scripts/lib/versions.sh"
grep -q 'env-validate.mjs' "$REPO_ROOT/scripts/lib/build-env.sh"
. "$REPO_ROOT/scripts/lib/common.sh"
PROBE
  run mise exec -- python3 -c "
import re
text = open('$probe').read()
RUNNERS = r'(?m)(?:^|[\s;&|(])(?:bash|sh|source|\.|exec|node|run|execFileSync|spawnSync)(?=[\s(])'
for s in ['scripts/ci/tool-version.sh', 'scripts/ci/free-disk.sh', 'scripts/lib/versions.sh', 'scripts/lib/build-env.sh', 'scripts/lib/common.sh']:
    print(s, bool(re.search(RUNNERS + r'[^\n]*' + re.escape(s), text)))
"
  contains "$output" "scripts/ci/tool-version.sh True" || fail "an executed script was not recognised: $output"
  contains "$output" "scripts/ci/free-disk.sh False" || fail "a grepped script was counted as executed: $output"
  contains "$output" "scripts/lib/versions.sh False" || fail "a dot inside sed -i.bak was counted as sourcing: $output"
  contains "$output" "scripts/lib/build-env.sh False" || fail "a dot inside a quoted file name was counted as sourcing: $output"
  contains "$output" "scripts/lib/common.sh True" || fail "a script sourced with . was not recognised: $output"
}

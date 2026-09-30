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

# There is no allowlist. It used to hold eight scripts "that cannot run from a
# bats suite" - the native builds, the Maestro runners, Metro - and every one of
# them could: each now runs against fake xcodebuild, pod, gradlew, maestro and
# adb on PATH, the way test/app-launch.bats always did. An allowlist is where
# coverage goes to be forgotten, so the last case below fails if one returns.

# Prints every tracked script, one per line.
all_scripts() {
  git -C "$REPO_ROOT" ls-files 'scripts/**/*.sh' 'scripts/**/*.mjs' 'packages/*/bin/*.mjs' 'packages/*/lib/*.mjs' \
    'packages/*/jest/**/*.cjs' 'packages/*/**/*.sh' | grep -v '\.test\.mjs$'
}

# Prints `SCRIPT<TAB>TEST` for every test file that actually runs a script.
#
# Execution is not the same as mention, and the difference is the point. A path
# counts when a test invokes it (`bash "$REPO_ROOT/scripts/x.sh"`, `source`,
# `node`, `run`) - directly, or through a variable the file assigns it to and
# later invokes, which is how most files here are written. The runner has to
# be a word of its own, at the start of a line or after a separator: a `.`
# inside `sed -i.bak` or a quoted `name.mjs` is not `. file`. A node:test file
# also runs what it imports (`from './bin/x.mjs'`, `from '../scripts/x.mjs'`),
# statically or with `import('./lib/x.mjs')` - a preset test has to register
# its stand-ins before the preset loads, so it imports it dynamically, at times
# with a query string for a second instance (`import('./lib/x.mjs?variant')`).
executed_by() {
  mise exec -- python3 -c "
import os, re, subprocess

root = os.environ['REPO_ROOT']
ls = lambda *p: subprocess.run(['git', '-C', root, 'ls-files', *p], capture_output=True, text=True).stdout.split()
tests = ls('test/*.bats', 'test/*.test.mjs', 'packages/*/*.test.mjs')
scripts = ls('scripts/**/*.sh', 'scripts/**/*.mjs', 'packages/*/bin/*.mjs', 'packages/*/lib/*.mjs', 'packages/*/jest/**/*.cjs')

RUNNERS = r'(?m)(?:^|[\s;&|(])(?:bash|sh|source|\.|exec|node|run|execFileSync|spawnSync)(?=[\s(])'

for test in tests:
    text = open(os.path.join(root, test)).read()
    # Modules a node:test file imports, as paths from the repository root.
    imported = set()
    if test.endswith('.mjs'):
        for rel in re.findall(r'(?:from\s+|import\(\s*)[\"\'](\.{1,2}/[^\"\'?]+)(?:\?[^\"\']*)?[\"\']', text):
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


# Prints the test files that may be SCRIPT's own, one per line: the file named
# after it, or after its area and name when two scripts share a name
# (scripts/ota/export.sh -> test/export.bats or test/ota-export.bats). A Node
# script's own test is a node:test file; a package's program or module sits at
# the package root, because bin/, lib/ and jest/ are what the package publishes
# (packages/expo-tooling/jest/mocks/expo-updates.cjs ->
# packages/expo-tooling/expo-updates.test.mjs).
own_tests() {
  local script="$1" file name area
  file="${script##*/}"
  name="${file%.*}"
  case "$script" in
    packages/*/bin/*.mjs | packages/*/lib/*.mjs | packages/*/jest/*.cjs)
      area="${script#packages/}"
      printf '%s\n' "packages/${area%%/*}/$name.test.mjs"
      ;;
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

# The original a package's shell script is a byte-identical copy of, from
# scripts/self/package-copies.sh's ORIGINAL:COPY list; nothing when it is none.
# A copy is tested through its original's own test, and test/package-copies.bats
# holds the two identical.
copy_original() {
  local script="$1" rel
  case "$script" in packages/dev-config/*.sh) ;; *) return 0 ;; esac
  rel="${script#packages/dev-config/}"
  sed -n "s|^  \(scripts/[^:]*\):$rel\$|\1|p" "$REPO_ROOT/scripts/self/package-copies.sh"
}

# Prints every script with no own test file that runs it. A package's copy
# stands for its original. $1 is executed_by's output.
without_own_test() {
  local executed="$1" script own original
  while read -r script; do
    [ -n "$script" ] || continue
    original="$(copy_original "$script")"
    [ -n "$original" ] && script="$original"
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
test/x.test.mjs, packages/<package>/lib/x.mjs -> packages/<package>/x.test.mjs.
It has to run the script, not just read it; a case in a shared suite does not
count. There are no exceptions: a script that needs Xcode, a simulator, Gradle
or a device runs against fakes of them on PATH (see test/app-launch.bats)."
}

@test "own_tests names the test file after the script, or its area and name" {
  local out
  out="$(own_tests scripts/ota/export.sh | tr '\n' ' ')"
  [ "$out" = "test/export.bats test/ota-export.bats " ] || fail "bash script: $out"
  out="$(own_tests scripts/lib/env-validate.mjs | tr '\n' ' ')"
  [ "$out" = "test/env-validate.test.mjs test/lib-env-validate.test.mjs " ] || fail "Node script: $out"
  out="$(own_tests packages/dev-config/bin/check-tool-versions.mjs)"
  [ "$out" = "packages/dev-config/check-tool-versions.test.mjs" ] || fail "dev-config program: $out"
  out="$(own_tests packages/dev-config/lib/pin.mjs)"
  [ "$out" = "packages/dev-config/pin.test.mjs" ] || fail "package module: $out"
  out="$(own_tests packages/expo-tooling/bin/x.mjs)"
  [ "$out" = "packages/expo-tooling/x.test.mjs" ] || fail "another package's program: $out"
  out="$(own_tests packages/expo-tooling/jest/console.cjs)"
  [ "$out" = "packages/expo-tooling/console.test.mjs" ] || fail "a Jest runtime file: $out"
  out="$(own_tests packages/expo-tooling/jest/mocks/expo-updates.cjs)"
  [ "$out" = "packages/expo-tooling/expo-updates.test.mjs" ] || fail "a Jest stand-in one directory deeper: $out"
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

@test "a node:test file runs what it imports" {
  local out
  out="$(executed_by | grep -F 'packages/dev-config/bin/check-tool-versions.mjs	packages/dev-config/check-tool-versions.test.mjs' || true)"
  [ -n "$out" ] || fail "an imported program was not counted as run by its test"
}

@test "a node:test file runs what it imports dynamically, query string or not" {
  local executed
  executed="$(executed_by)"
  grep -qxF 'packages/expo-tooling/lib/eslint.mjs	packages/expo-tooling/eslint.test.mjs' <<< "$executed" \
    || fail "a module imported with import('./lib/x.mjs') was not counted as run by its test"
  grep -qxF 'packages/expo-tooling/jest/mocks/expo-updates.cjs	packages/expo-tooling/expo-updates.test.mjs' <<< "$executed" \
    || fail "a CommonJS Jest stand-in imported by its test was not counted as run"
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

@test "a package's copy of a script stands for its original, and a stray one is named" {
  [ "$(copy_original packages/dev-config/checks/i18n.sh)" = "scripts/checks/i18n.sh" ] || fail "the copy's original was not found"
  [ "$(copy_original packages/dev-config/zizmor.yml)" = "" ] || fail "a non-script was mapped"
  all_scripts() { printf '%s\n' packages/dev-config/checks/i18n.sh packages/dev-config/checks/stray.sh; }
  local missing
  missing="$(without_own_test "scripts/checks/i18n.sh	test/i18n.bats" | tr '\n' ' ')"
  [ "$missing" = "packages/dev-config/checks/stray.sh " ] || fail "expected only the stray copy: $missing"
}

@test "no script is excused: this gate has no allowlist" {
  # The eight scripts an allowlist here once excused all turned out to be
  # testable. Bringing one back is a decision for AGENTS.md, not this file.
  ! grep -qE '^[[:space:]]*[A-Z_]*ALLOW[A-Z_]*=' "$BATS_TEST_FILENAME" || fail "an allowlist is back in $BATS_TEST_FILENAME"
}

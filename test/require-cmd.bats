#!/usr/bin/env bats
# require_cmd (test_helper.bash), and the guard that keeps it the only way a
# test asks for a tool .mise.toml pins.
#
# The suite used to open each yq-reading test with
#
#   command -v yq >/dev/null || skip "yq not installed"
#
# so a shell without the pinned tools reported green with every workflow shape
# and contract assertion skipped. yq, pnpm and semgrep are pinned, so a missing
# one is a broken setup: require_cmd fails the test and names the fix. A tool
# .mise.toml does not pin (python3, curl, the claude CLI, mise itself) may
# still skip; the guard below only reads the pinned ones.
#
# Every assertion ends in `|| fail "..."` - see test_helper.bash.
load test_helper

# The tools .mise.toml pins, one per line: each key of its [tools] table, with
# quotes and a backend prefix ("pipx:semgrep", "aqua:owner/tool") taken off.
pinned_tools() {
  awk '
    /^\[/ { in_tools = ($0 ~ /^\[tools\][[:space:]]*$/); next }
    in_tools && /^[[:space:]]*[^#[:space:]][^=]*=/ {
      key = $0
      sub(/[[:space:]]*=.*/, "", key)
      sub(/^[[:space:]]+/, "", key)
      gsub(/"/, "", key)
      sub(/.*:/, "", key)
      sub(/.*\//, "", key)
      print key
    }
  ' "$1"
}

# skip_guards MISE_TOML FILE... - print `file:line:text` for every probe of a
# pinned tool (command -v, type -P, which, hash) that skips: on the same line,
# or on the line after it, which covers both `if ! command -v yq; then` / `skip`
# and a guard wrapped with a trailing backslash. Comment lines never count.
skip_guards() {
  local toml="$1" tools file
  shift
  # Space-separated: the macOS awk rejects a newline in a -v value.
  tools="$(pinned_tools "$toml" | tr '\n' ' ')"
  for file in "$@"; do
    awk -v tools="$tools" -v name="$(basename "$file")" '
      BEGIN { count = split(tools, list, " ") }
      function probes(line,   i) {
        for (i = 1; i <= count; i++)
          if (match(line, "(command -v|type -[pP]|which|hash)[[:space:]]+" list[i] "([^A-Za-z0-9_.-]|$)")) return 1
        return 0
      }
      function skips(line) { return line ~ /(^|[^A-Za-z0-9_-])skip([^A-Za-z0-9_-]|$)/ }
      /^[[:space:]]*#/ { pending = 0; next }
      {
        if (pending && skips($0)) print name ":" pending_line ":" pending_text
        pending = 0
        if (probes($0)) {
          if (skips($0)) print name ":" NR ":" $0
          else { pending = 1; pending_line = NR; pending_text = $0 }
        }
      }
    ' "$file"
  done
}

@test "require_cmd passes, silently, when every tool is on PATH" {
  run require_cmd bash sh
  [ "$status" -eq 0 ] || fail "require_cmd failed for tools on PATH: $output"
  [ -z "$output" ] || fail "require_cmd printed for tools on PATH: $output"
}

@test "require_cmd fails naming the missing tool and the fix" {
  run require_cmd definitely-not-a-real-command
  [ "$status" -eq 1 ] || fail "require_cmd did not fail for a missing tool (status $status): $output"
  contains "$output" "missing command: definitely-not-a-real-command" || fail "the message does not name the tool: $output"
  contains "$output" "mise install" || fail "the message does not give the fix: $output"
}

@test "require_cmd names every missing tool, and only the missing ones" {
  run require_cmd bash missing-tool-one missing-tool-two
  [ "$status" -eq 1 ] || fail "require_cmd did not fail with two tools missing (status $status): $output"
  contains "$output" "missing command: missing-tool-one missing-tool-two -" || fail "the message does not name both tools: $output"
  not_contains "$output" "bash" || fail "the message names a tool that is on PATH: $output"
}

# The point of the helper, end to end: in a real bats run, a missing tool is a
# failed test, not a skipped one.
@test "a test that requires a missing tool fails in a bats run, it is not skipped" {
  file="$BATS_TEST_TMPDIR/needs-tools.bats"
  cat > "$file" <<EOF
load '$REPO_ROOT/test/test_helper'

@test "needs a missing tool" {
  require_cmd definitely-not-a-real-command
  echo "REACHED"
}

@test "needs a tool on PATH" {
  require_cmd bash
}
EOF
  run bats --tap "$file"
  [ "$status" -ne 0 ] || fail "the bats run passed with a tool missing: $output"
  contains "$output" "not ok 1 needs a missing tool" || fail "the test with a missing tool did not fail: $output"
  contains "$output" "ok 2 needs a tool on PATH" || fail "the test with its tool on PATH did not pass: $output"
  contains "$output" "missing command: definitely-not-a-real-command" || fail "the failure does not name the tool: $output"
  not_contains "$output" "# skip" || fail "a test was skipped instead of failed: $output"
  not_contains "$output" "REACHED" || fail "the test carried on past the missing tool: $output"
}

@test "the pinned tools are read from .mise.toml" {
  tools="$(pinned_tools "$REPO_ROOT/.mise.toml")"
  for tool in yq pnpm semgrep; do
    printf '%s\n' "$tools" | grep -qxF "$tool" || fail "$tool is pinned in .mise.toml but not read from it: $tools"
  done
}

@test "no bats file skips a test for want of a tool .mise.toml pins" {
  files=""
  for file in "$REPO_ROOT"/test/*.bats; do
    # This file is exempt: its last test writes skipping guards as fixtures.
    [ "$(basename "$file")" = "require-cmd.bats" ] || files="$files $file"
  done
  # shellcheck disable=SC2086  # one path per word; no path here has a space
  offenders="$(skip_guards "$REPO_ROOT/.mise.toml" $files)"
  [ -z "$offenders" ] || fail "a pinned tool is missing only in a broken setup, so the test must fail, not skip - replace each guard with \`require_cmd <tool>\` (test_helper.bash):
$offenders"
}

# The guard is only worth having if it can fire, so its patterns are exercised
# against synthetic files rather than trusted.
@test "the guard catches a skip for a pinned tool in every shape and spares the rest" {
  toml="$BATS_TEST_TMPDIR/mise.toml"
  bad="$BATS_TEST_TMPDIR/bad.bats"
  good="$BATS_TEST_TMPDIR/good.bats"
  cat > "$toml" <<'EOF'
[tools]
yq = "4"
"pipx:semgrep" = "1"
# curl = "8"

[env]
unpinned = "x"
EOF
  cat > "$bad" <<'EOF'
@test "x" {
  command -v yq >/dev/null || skip "yq not installed"
  command -v semgrep >/dev/null 2>&1 || skip "semgrep is not installed"
  if ! command -v yq >/dev/null; then
    skip "no yq"
  fi
  command -v yq >/dev/null \
    || skip "wrapped"
  type -P yq >/dev/null || skip
}
EOF
  cat > "$good" <<'EOF'
@test "x" {
  require_cmd yq semgrep
  command -v curl >/dev/null || skip "curl is not pinned"
  command -v unpinned >/dev/null || skip "an [env] key is not a tool"
  # command -v yq >/dev/null || skip "commented out"
  command -v yqx >/dev/null || skip "another tool whose name starts with yq"
  command -v yq >/dev/null || fail "yq is missing"
  command -v yq >/dev/null && echo skip_output
}
EOF
  tools="$(pinned_tools "$toml")"
  [ "$tools" = "yq
semgrep" ] || fail "the [tools] table read as: $tools"
  bad_hits="$(skip_guards "$toml" "$bad" | grep -c .)"
  [ "$bad_hits" -eq 5 ] || fail "the guard caught $bad_hits of the 5 skipping guards: $(skip_guards "$toml" "$bad")"
  good_hits="$(skip_guards "$toml" "$good")"
  [ -z "$good_hits" ] || fail "the guard flagged a line that is not a skip for a pinned tool: $good_hits"
}

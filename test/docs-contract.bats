#!/usr/bin/env bats
# AGENTS.md's command table and the Makefile must agree in BOTH directions.
#
# AGENTS.md is the file a coding agent reads before touching this repo, so a
# command table that lies is worse than no table: an agent will run a target
# that does not exist, or miss the one gate that would have caught its change.
# The Makefile is read at run time, so a target added by a later change fails
# this file until AGENTS.md gains a row for it, and vice versa.
#
# A bats port of the template's scripts/check-docs.sh strict half.
load test_helper

MAKEFILE="$REPO_ROOT/Makefile"
AGENTS="$REPO_ROOT/AGENTS.md"

# `name: [deps] ## description` - the shape `make help` itself greps for,
# widened to digits so a target like `e2e-ios` would match.
documented_targets() {
  grep -oE '^[a-zA-Z0-9_-]+:[^#]*## ' "$MAKEFILE" | cut -d: -f1 | sort -u
}

# Every command-table row is a `make <target>` literal, so one grep covers the
# table and any `make x` named in prose.
# shellcheck disable=SC2016 # the backticked `make x` literals are markdown.
listed_targets() {
  grep -oE '`make [a-z0-9-]+`' "$AGENTS" | sed -E 's/`make ([a-z0-9-]+)`/\1/' | sort -u
}

@test "AGENTS.md exists - the command table is the agent-facing contract" {
  [ -f "$AGENTS" ] || fail "AGENTS.md is missing"
  [ -f "$REPO_ROOT/CLAUDE.md" ] || fail "CLAUDE.md is missing (it should just be @AGENTS.md)"
  grep -qxF '@AGENTS.md' "$REPO_ROOT/CLAUDE.md" ||
    fail "CLAUDE.md must include AGENTS.md rather than duplicate it"
}

@test "the Makefile documents at least the gates make check depends on" {
  count="$(documented_targets | grep -c .)"
  [ "$count" -ge 5 ] || fail "only $count documented make targets found - has the ## convention changed?"
}

@test "every ##-documented make target has a row in AGENTS.md" {
  listed="$(listed_targets)"
  missing=""
  while read -r target; do
    [ -n "$target" ] || continue
    printf '%s\n' "$listed" | grep -qxF "$target" || missing="$missing $target"
  done <<<"$(documented_targets)"
  [ -z "$missing" ] || fail "AGENTS.md is missing a command-table row for:$missing"
}

@test "every make target named in AGENTS.md exists in the Makefile" {
  missing=""
  while read -r target; do
    [ -n "$target" ] || continue
    grep -qE "^$target:" "$MAKEFILE" || missing="$missing $target"
  done <<<"$(listed_targets)"
  [ -z "$missing" ] || fail "AGENTS.md references make targets that do not exist:$missing"
}

# Both directions are only trustworthy if the extractors themselves work, and
# a regex is the part most likely to rot, so they are exercised against a
# synthetic pair rather than trusted.
@test "the extractors find a target and ignore an undocumented one" {
  mk="$BATS_TEST_TMPDIR/Makefile"
  md="$BATS_TEST_TMPDIR/AGENTS.md"
  cat > "$mk" <<'EOF'
e2e-ios: deps ## Run the iOS suite
	true
internal-helper:
	true
EOF
  cat > "$md" <<'EOF'
| `make e2e-ios` | Run the iOS suite |
Prose mentioning `make ghost` that does not exist.
EOF
  MAKEFILE="$mk" AGENTS="$md" run documented_targets
  [ "$output" = "e2e-ios" ] || fail "documented_targets returned '$output', expected only 'e2e-ios'"
  MAKEFILE="$mk" AGENTS="$md" run listed_targets
  [ "$output" = "e2e-ios
ghost" ] || fail "listed_targets returned '$output', expected 'e2e-ios' and 'ghost'"
}

# The tools `.mise.toml` pins, one per line: the keys of its [tools] table,
# without a backend prefix (`npm:foo` is foo).
mise_tools() {
  awk '/^\[tools\]/ { on = 1; next } /^\[/ { on = 0 } on && /^[a-zA-Z"]/ { print $1 }' "$REPO_ROOT/.mise.toml" |
    tr -d '"' | sed -E 's/^[a-z]+://; s#.*/##' | sort -u
}

# Prints each documented target with a dash-separated word that is a tool's name.
targets_named_after_tools() {
  local target word
  while read -r target; do
    for word in ${target//-/ }; do
      if mise_tools | grep -qxF "$word"; then
        printf '%s (%s)\n' "$target" "$word"
        break
      fi
    done
  done
  return 0
}

@test "no make target is named after the tool it runs" {
  local named
  named="$(documented_targets | targets_named_after_tools)"
  [ -z "$named" ] || fail "name these targets for what they check, not the tool (the tool goes in the ## description):
$named"
}

@test "the tool-name check reads .mise.toml and catches a target named after a tool" {
  mise_tools | grep -qxF zizmor || fail "zizmor is pinned in .mise.toml but was not read: $(mise_tools | tr '\n' ' ')"
  local named
  named="$(printf '%s\n' zizmor check-shellcheck workflow-security | targets_named_after_tools)"
  [ "$named" = "zizmor (zizmor)
check-shellcheck (shellcheck)" ] || fail "expected zizmor and check-shellcheck, got: $named"
}

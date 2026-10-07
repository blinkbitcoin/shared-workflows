#!/usr/bin/env bats
# Every assertion ends in `|| fail "..."` - see test_helper.bash.
#
# A required environment variable is checked with common.sh's require_env (or
# require_uint for a count), never with a bare `${NAME:?message}`. When the bare
# form fires, bash prints its own "NAME: message" line and exits: no ::error::
# annotation on the run, so the failure is buried in the step log, and nothing
# that says where the value was meant to come from. require_env names every
# missing variable at once, in one annotation, with its hint.
#
# Two forms are left alone on purpose, so the search matches neither:
#   - a positional parameter, `${1:?usage: ...}`: a usage error for whoever
#     typed the command, not a variable a workflow failed to pass;
#   - a lower-case local, `${home:?}` before `rm -rf "${home:?}/bin"`: the
#     guard that keeps an empty variable from turning the path into `/bin`.
load test_helper


bare_checks() {
  cd "$REPO_ROOT" || return 1
  local listed
  # `git ls-files`, not a directory walk: tracked files are exactly this
  # repository, whatever else a smoke run left in the workspace.
  listed="$(git ls-files -- scripts)" || return 1
  local file
  while IFS= read -r file; do
    [ -n "$file" ] || continue
    grep -nHE '\$\{[A-Z_][A-Z0-9_]*:\?' "$file" || true
  done <<<"$listed"
}

@test "no script under scripts/ checks a required variable with a bare \${NAME:?}" {
  hits="$(bare_checks)"
  [ -z "$hits" ] || fail "use require_env (common.sh) so the failure is an ::error:: annotation naming every missing variable:
$hits"
}

@test "the search catches a bare check and lets the two deliberate forms through" {
  local bad
  # E2E_SCRIPT: a digit in the name once hid a bare check from a letters-only search.
  for bad in ': "${GH_REPO:?GH_REPO not set}"' ': "${E2E_SCRIPT:?}"' 'x="${TAG:?needs TAG}"'; do
    printf '%s\n' "$bad" > "$BATS_TEST_TMPDIR/bad.sh"
    grep -qE '\$\{[A-Z_][A-Z0-9_]*:\?' "$BATS_TEST_TMPDIR/bad.sh" || fail "a bare check was not matched: $bad"
  done
  printf '%s\n' 'tag="${1:?usage: x TAG}"' 'rm -rf "${home:?}/bin"' > "$BATS_TEST_TMPDIR/good.sh"
  ! grep -qE '\$\{[A-Z_][A-Z0-9_]*:\?' "$BATS_TEST_TMPDIR/good.sh" || fail "a deliberate form was matched"
}

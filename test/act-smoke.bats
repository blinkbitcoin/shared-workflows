#!/usr/bin/env bats
load test_helper

# self-act-smoke.yml is excluded from workflow-shape.bats with the other
# self-* workflows, so its own invariants live here: it is act's entry point
# into the release workflows and must never reach GitHub or create anything.

WF="$REPO_ROOT/.github/workflows/self-act-smoke.yml"
SCRIPT="$REPO_ROOT/scripts/self/act-smoke.sh"

@test "the smoke workflow is workflow_dispatch only, so GitHub never runs it" {
  [ "$(yq -r '.on | keys | join(",")' "$WF")" = "workflow_dispatch" ] \
    || fail "self-act-smoke.yml has triggers other than workflow_dispatch: $(yq -r '.on | keys' "$WF")"
}

@test "every job calls a workflow from this checkout, never @v0" {
  bad=$(yq -r '[.jobs[].uses | select(test("^\\./\\.github/workflows/") | not)] | join(", ")' "$WF")
  [ -z "$bad" ] || fail "self-act-smoke.yml calls a workflow outside this checkout: $bad"
}

@test "the smoke never reserves a tag and never waits on a green gate" {
  [ "$(yq -r '.jobs.prepare.with."reserve-tag"' "$WF")" = "false" ] \
    || fail "reserve-tag must be false: the token act runs with is the developer's own"
  [ "$(yq -r '.jobs.prepare.with."require-green-workflow"' "$WF")" = "" ] \
    || fail "require-green-workflow must be empty: nothing has run for a local commit"
}

@test "the Android build is opt-in and unsigned" {
  [ "$(yq -r '.jobs."build-android".if' "$WF")" = '${{ inputs.android }}' ] \
    || fail "build-android is not gated on inputs.android"
  [ "$(yq -r '.jobs."build-android".with."android-signing"' "$WF")" = "false" ] \
    || fail "build-android must run unsigned"
}

@test "no job sets a macOS runner: the smoke is the Linux half only" {
  ! grep -qE 'macos' "$WF" || fail "self-act-smoke.yml mentions a macOS runner"
}

# --- the entry script -------------------------------------------------------

setup() {
  # A scratch clone with a bare origin, and fake act/docker/gh on PATH that
  # record what they were asked, so the script's guards and the arguments it
  # hands act can be checked without Docker.
  origin="$BATS_TEST_TMPDIR/origin.git"
  work="$BATS_TEST_TMPDIR/work"
  git init -q --bare "$origin"
  git clone -q "$origin" "$work" 2>/dev/null || git init -q "$work"
  git -C "$work" remote get-url origin >/dev/null 2>&1 || git -C "$work" remote add origin "$origin"
  git -C "$work" config user.email test@example.com
  git -C "$work" config user.name test
  git -C "$work" switch -qc feature 2>/dev/null || git -C "$work" checkout -qb feature
  git -C "$work" commit -q --allow-empty -m "feat: one"
  mkdir -p "$work/.github/workflows"
  cp "$WF" "$work/.github/workflows/"
  bin="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$bin"
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$@" > "%s/act.args"\n' "$BATS_TEST_TMPDIR" > "$bin/act"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$bin/docker"
  printf '#!/usr/bin/env bash\necho fake-token\n' > "$bin/gh"
  chmod +x "$bin/act" "$bin/docker" "$bin/gh"
  export PATH="$bin:$PATH"
  # The substitute artifact actions are "already fetched", so no clone runs.
  export WORKFLOWS_ACT_CACHE="$BATS_TEST_TMPDIR/cache"
  mkdir -p "$WORKFLOWS_ACT_CACHE/upload-artifact-v4.6.2" "$WORKFLOWS_ACT_CACHE/download-artifact-v4.3.0"
}

@test "refuses a branch that is not on origin, and says to push" {
  cd "$work"
  run bash "$SCRIPT"
  [ "$status" -ne 0 ]
  contains "$output" "push it first" || fail "output: $output"
  [ ! -f "$BATS_TEST_TMPDIR/act.args" ] || fail "act was run anyway"
}

@test "refuses when origin is behind the local HEAD" {
  cd "$work"
  git push -q origin feature
  git commit -q --allow-empty -m "feat: two"
  run bash "$SCRIPT"
  [ "$status" -ne 0 ]
  contains "$output" "push first" || fail "output: $output"
}

@test "refuses a detached HEAD" {
  cd "$work"
  git push -q origin feature
  git checkout -q --detach
  run bash "$SCRIPT"
  [ "$status" -ne 0 ]
  contains "$output" "detached HEAD" || fail "output: $output"
}

@test "runs act on the smoke workflow with the pinned image, an artifact server and the token" {
  cd "$work"
  git push -q origin feature
  run bash "$SCRIPT"
  [ "$status" -eq 0 ] || fail "output: $output"
  args="$(cat "$BATS_TEST_TMPDIR/act.args")"
  contains "$args" "workflow_dispatch" || fail "args: $args"
  contains "$args" ".github/workflows/self-act-smoke.yml" || fail "args: $args"
  contains "$args" "ubuntu-latest=catthehacker/ubuntu:act-latest" || fail "args: $args"
  contains "$args" "--artifact-server-path" || fail "args: $args"
  contains "$args" "GITHUB_TOKEN=fake-token" || fail "args: $args"
  contains "$args" "android=false" || fail "args: $args"
  # act's artifact server cannot take upload-artifact@v7 / download-artifact@v8
  # (nektos/act #6022): both are run as their last v4 from the cache.
  contains "$args" "actions/upload-artifact@v7=$WORKFLOWS_ACT_CACHE/upload-artifact-v4.6.2" || fail "args: $args"
  contains "$args" "actions/download-artifact@v8=$WORKFLOWS_ACT_CACHE/download-artifact-v4.3.0" || fail "args: $args"
  contains "$args" "repository=blinkbitcoin/react-native-mobile-template" || fail "args: $args"
}

@test "a failed fetch of a substitute action stops the smoke, and leaves no half-cloned cache" {
  cd "$work"
  git push -q origin feature
  rm -rf "$WORKFLOWS_ACT_CACHE/upload-artifact-v4.6.2"
  # git that fails a clone from GitHub part-way, after creating the directory,
  # and is the real git for everything else.
  local real_git
  real_git="$(command -v git)"
  cat > "$bin/git" <<STUB
#!/usr/bin/env bash
case "\$*" in
  *clone*https://github.com/actions/*) mkdir -p "\${@: -1}/.git"; echo "fatal: unable to access" >&2; exit 128 ;;
esac
exec "$real_git" "\$@"
STUB
  chmod +x "$bin/git"
  run bash "$SCRIPT"
  [ "$status" -ne 0 ] || fail "the smoke carried on without its action: $output"
  [ ! -f "$BATS_TEST_TMPDIR/act.args" ] || fail "act was run anyway"
  [ ! -e "$WORKFLOWS_ACT_CACHE/upload-artifact-v4.6.2" ] ||
    fail "a half-cloned action was left in the cache, so the next run would skip the fetch"
}

@test "--android turns the Android build on; an unknown flag is refused" {
  cd "$work"
  git push -q origin feature
  bash "$SCRIPT" --android
  contains "$(cat "$BATS_TEST_TMPDIR/act.args")" "android=true" || fail "args: $(cat "$BATS_TEST_TMPDIR/act.args")"
  run bash "$SCRIPT" --ios
  [ "$status" -ne 0 ]
  contains "$output" "unknown argument" || fail "output: $output"
}

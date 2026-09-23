#!/usr/bin/env bats
# The boundary where a consumer's repository does not provide something this
# family needs, and what the reader is told about it.
#
# `die` is right for a failure whose fix is obvious from the message, and most
# of the ~140 in this repo are exactly that. The scripts below are the other
# kind: every one of them can only fail because the calling repository is
# missing a file or a script, the reader is often adopting these workflows and
# has never seen this repo, and the fix is something they have to write. Those
# get `die_fix`, which carries the remediation and a link to the contract.

load test_helper

# Scripts whose failures are all contract failures. A `die` here would be a
# message that says what is wrong and leaves the reader to guess the rest.
CONTRACT_BOUNDARY=(
  scripts/checks/run-script.sh
  scripts/ci/toolchain-preflight.sh
  scripts/ci/pnpm-install.sh
  scripts/release/require-inputs.sh
)
# The same list, for the node cases below: they read it from process.env.
BOUNDARY="${CONTRACT_BOUNDARY[*]}"
export BOUNDARY

@test "every failure at a contract boundary carries a fix" {
  local offenders=""
  for rel in "${CONTRACT_BOUNDARY[@]}"; do
    local f="$REPO_ROOT/$rel"
    [ -f "$f" ] || fail "the boundary list names a script that does not exist: $rel"
    # A bare `die` in one of these is the thing this case exists to catch.
    if grep -qE '(^|[^_[:alnum:]])die[[:space:]]+"' "$f"; then
      offenders="$offenders $rel"
    fi
  done
  [ -z "$offenders" ] || fail "these contract-boundary scripts still use bare die:$offenders"
}

@test "the boundary scripts point at a real anchor in the consumer guide" {
  # A link to an anchor that does not exist is worse than no link: it reads as
  # an answer and lands on the top of a 1700-line document.
  run node -e '
    const fs = require("fs");
    const root = process.env.REPO_ROOT;
    const guide = fs.readFileSync(`${root}/docs/consumer-guide.md`, "utf8");
    const anchors = new Set(
      [...guide.matchAll(/^#+ (.+)$/gm)].map(([, h]) =>
        h.toLowerCase().replace(/[^\w\s-]/g, "").trim().replace(/\s/g, "-"),
      ),
    );
    const bad = [];
    for (const rel of process.env.BOUNDARY.trim().split(/\s+/)) {
      const text = fs.readFileSync(`${root}/${rel}`, "utf8");
      for (const [, anchor] of text.matchAll(/die_fix[\s\S]*?"([a-z0-9-]+)"\s*$/gm)) {
        if (!anchors.has(anchor)) bad.push(`${rel} -> #${anchor}`);
      }
    }
    if (bad.length > 0) throw new Error(`die_fix anchors the guide does not have: ${bad.join(", ")}`);
  '
  [ "$status" -eq 0 ] || fail "$output"
}

@test "a repo with no mise config is told which file is missing, not which command" {
  local root="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$root"
  GITHUB_WORKSPACE="$root" WORKING_DIRECTORY="." run bash "$REPO_ROOT/scripts/ci/toolchain-preflight.sh"
  [ "$status" -eq 1 ] || fail "expected exit 1, got $status"
  contains "$output" "no mise config" || fail "$output"
  contains "$output" ".mise.toml" || fail "the message does not name the file: $output"
  not_contains "$output" "missing command: pnpm" || fail "this is the message it exists to replace: $output"
}

@test "the preflight names each missing piece in turn, and passes on a complete repo" {
  local root="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$root"
  printf '[tools]\nnode = "24"\npnpm = "12"\n' > "$root/.mise.toml"
  GITHUB_WORKSPACE="$root" WORKING_DIRECTORY="." run bash "$REPO_ROOT/scripts/ci/toolchain-preflight.sh"
  contains "$output" "no package.json" || fail "$output"

  printf '{"name":"app"}\n' > "$root/package.json"
  GITHUB_WORKSPACE="$root" WORKING_DIRECTORY="." run bash "$REPO_ROOT/scripts/ci/toolchain-preflight.sh"
  contains "$output" "no pnpm-lock.yaml" || fail "$output"

  : > "$root/pnpm-lock.yaml"
  GITHUB_WORKSPACE="$root" WORKING_DIRECTORY="." run bash "$REPO_ROOT/scripts/ci/toolchain-preflight.sh"
  [ "$status" -eq 0 ] || fail "a complete repo must pass: $output"
}

@test "the setup action checks the toolchain before mise-action, not after" {
  # After mise-action is too late to be useful: with no config it installs
  # nothing and succeeds, so the first symptom is two steps further on.
  run node -e '
    const text = require("fs").readFileSync(`${process.env.REPO_ROOT}/.github/actions/setup/action.yml`, "utf8");
    const preflight = text.indexOf("toolchain-preflight.sh");
    const mise = text.indexOf("jdx/mise-action");
    if (preflight === -1) throw new Error("the setup action does not run the toolchain preflight");
    if (preflight > mise) throw new Error("the preflight runs after mise-action, which is too late to explain anything");
  '
  [ "$status" -eq 0 ] || fail "$output"
}

@test "an unrecognised lockfile shape is fatal, not a silently wrong cache key" {
  # Every query in native-hash.sh is .importers["."], which is lockfile v9. On
  # an older one those return nothing and `// {}` makes that an empty list with
  # no error: the key stops tracking dependency versions and a native bump
  # silently restores a stale build.
  local root="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$root"
  printf 'lockfileVersion: "5.4"\ndependencies:\n  expo:\n    version: 54.0.0\n' > "$root/pnpm-lock.yaml"
  run bash "$REPO_ROOT/scripts/ci/native-hash.sh" "$root"
  [ "$status" -eq 1 ] || fail "a lockfile this cannot read must fail, not hash nothing: $output"
  contains "$output" 'importers' || fail "the message does not name the shape it wanted: $output"
}

@test "an empty lane input is refused up front, naming the variable" {
  # `required: true` does not reject "", and `vars.X` for an unset X is "".
  APP_VERSION=1.2.3 APP_BUILD_NUMBER=1042 IOS_BUNDLE_ID="" IOS_SCHEME=App ANDROID_PACKAGE=com.example.app \
    run bash "$REPO_ROOT/scripts/release/require-inputs.sh"
  [ "$status" -eq 1 ] || fail "an empty contract variable must be refused: $output"
  contains "$output" "IOS_BUNDLE_ID" || fail "the message does not name the empty one: $output"
  not_contains "$output" "ANDROID_PACKAGE," || fail "it named a variable that was set: $output"
}

@test "a whitespace-only lane input counts as empty" {
  APP_VERSION="  " APP_BUILD_NUMBER=1042 IOS_BUNDLE_ID=com.example.app IOS_SCHEME=App ANDROID_PACKAGE=com.example.app \
    run bash "$REPO_ROOT/scripts/release/require-inputs.sh"
  [ "$status" -eq 1 ] || fail "whitespace is not a version: $output"
  contains "$output" "APP_VERSION" || fail "$output"
}

@test "every lane workflow checks its inputs before it installs or builds anything" {
  run node -e '
    const fs = require("fs");
    const root = process.env.REPO_ROOT;
    const bad = [];
    for (const name of ["build-ios", "build-android", "publish-store"]) {
      const text = fs.readFileSync(`${root}/.github/workflows/${name}.yml`, "utf8");
      const check = text.indexOf("require-inputs.sh");
      if (check === -1) { bad.push(`${name}: no lane-input check`); continue; }
      // Every expensive thing in these jobs comes through the setup action or a
      // prebuild; both must be downstream of the check.
      for (const marker of ["actions/setup", "prebuild.sh", "pods.sh"]) {
        const at = text.indexOf(marker);
        if (at !== -1 && at < check) bad.push(`${name}: ${marker} runs before the lane-input check`);
      }
    }
    if (bad.length > 0) throw new Error(bad.join("; "));
  '
  [ "$status" -eq 0 ] || fail "$output"
}

@test "check-codeql.yml passes a config file only when the consumer has one" {
  # codeql-action/init fails outright on a path it cannot read, and this
  # workflow is informational by design - a caller must not make it required.
  run node -e '
    const text = require("fs").readFileSync(`${process.env.REPO_ROOT}/.github/workflows/check-codeql.yml`, "utf8");
    if (!/config-file: \$\{\{ hashFiles\(inputs\.config-file\) != .. && inputs\.config-file \|\| .. \}\}/.test(text)) {
      throw new Error("check-codeql.yml passes config-file unconditionally again");
    }
  '
  [ "$status" -eq 0 ] || fail "$output"
}

@test "a build-info record that is not JSON names the file instead of a stack trace" {
  local dir="$BATS_TEST_TMPDIR/assets"
  mkdir -p "$dir"
  printf 'not json{' > "$dir/build-info.json"
  printf '{"artifacts":{"apkSha256":"aa"}}' > "$dir/build-info.android.json"
  run bash "$REPO_ROOT/scripts/release/merge-build-info.sh" "$dir"
  [ "$status" -ne 0 ] || fail "a malformed record must fail: $output"
  contains "$output" "is not readable as JSON" || fail "$output"
  not_contains "$output" "node:internal" || fail "a stack trace leaked: $output"
}

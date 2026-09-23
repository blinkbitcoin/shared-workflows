#!/usr/bin/env bats
# Every assertion ends in `|| fail "..."`: under bash 3.2 (macOS's /bin/bash,
# which bats runs under here) a bare mid-body `[[ ]]` does not honour errexit,
# so only the last command of a test body would be observed. The root cause and
# the reproduction are documented in test_helper.bash.
load test_helper

# `gh` is one of resolve-version.sh's optional version sources. On a developer
# machine it exists and would talk to whatever remote the temp repo appears to
# have, so every test runs with a stub that reports "no open release PR" - the
# gh path itself is not what these tests are about.
setup() {
  STUB="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$STUB"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$STUB/gh"
  chmod +x "$STUB/gh"
  PATH="$STUB:$PATH"
  REPO="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$REPO"
  git -C "$REPO" init -q -b main
  git -C "$REPO" config user.email t@example.com
  git -C "$REPO" config user.name t
  # GITHUB_REF_NAME is unset for a sharper reason than the others: it is always
  # set inside GitHub Actions, it seeds the release scope, and left ambient it
  # would make every `chore(main)` fixture below pass on a laptop and fail in CI.
  unset GITHUB_OUTPUT GITHUB_ENV RELEASE_PR_TITLE BUILD_NUMBER_OFFSET GH_TOKEN
  unset GITHUB_REF_NAME WORKFLOWS_RELEASE_SCOPE
}

commit() { git -C "$REPO" commit -q --allow-empty -m "${1:-c}"; }
resolve() { run bash "$REPO_ROOT/scripts/release/resolve-version.sh" "$REPO"; }

@test "a vX.Y.Z tag on HEAD wins over everything else" {
  commit
  git -C "$REPO" tag v1.2.3
  RELEASE_PR_TITLE='chore(main): release 9.9.9' resolve
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  contains "$output" "APP_VERSION=1.2.3" || fail "no APP_VERSION=1.2.3 in: $output"
}

@test "RELEASE_PR_TITLE supplies the version when HEAD has no tag" {
  commit
  RELEASE_PR_TITLE='chore(main): release 2.5.0' resolve
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  contains "$output" "APP_VERSION=2.5.0" || fail "no APP_VERSION=2.5.0 in: $output"
}

# The gap this closes: on release-please's merge commit the tag does not exist
# yet (it is created from that very push), a `push` event carries no
# RELEASE_PR_TITLE, and the PR is closed so `autorelease: pending` finds
# nothing - so the release build of 1.2.0 used to resolve as a patch bump of the
# previous tag and shipped a store build labelled with a version nothing else
# knew.
@test "release-please's release commit supplies the version" {
  commit
  git -C "$REPO" tag v1.1.1
  commit 'chore(main): release 1.2.0'
  resolve
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  contains "$output" "APP_VERSION=1.2.0" || fail "no APP_VERSION=1.2.0 in: $output"
  contains "$output" "release-please release commit" || fail "unexpected origin: $output"
}

# The merge-commit shape: with the merge button set to "Create a merge commit",
# HEAD's subject is `Merge pull request #N from …` and the release commit is its
# *second parent*. Without the HEAD^2 lookup this falls back to the patch bump -
# the original bug, harder to spot because the fix looks present.
merge_release_fixture() {
  commit
  git -C "$REPO" tag v1.1.1
  git -C "$REPO" checkout -q -b release-please--branches--main
  commit 'chore(main): release 1.2.0'
  git -C "$REPO" checkout -q main
  git -C "$REPO" merge -q --no-ff \
    -m 'Merge pull request #12 from release-please--branches--main' release-please--branches--main
}

@test "release-please's release commit is found through a merge commit" {
  merge_release_fixture
  [ -n "$(git -C "$REPO" rev-list --merges -1 HEAD)" ] || fail "the fixture is not a merge commit"
  resolve
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  contains "$output" "APP_VERSION=1.2.0" || fail "the merge commit's release version was missed: $output"
}

# Anchored on both revisions: a merge whose own subject merely quotes the
# release subject is not a release commit.
@test "a merge commit that only quotes the release subject is not a source" {
  commit
  git -C "$REPO" tag v0.4.9
  git -C "$REPO" checkout -q -b feature
  commit 'feat: something'
  git -C "$REPO" checkout -q main
  git -C "$REPO" merge -q --no-ff -m 'Merge pull request #12 from chore(main): release 9.9.9' feature
  resolve
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  contains "$output" "APP_VERSION=0.4.10" || fail "a quoted subject was used as a source: $output"
}

@test "a tag on HEAD still wins over the release commit subject" {
  commit 'chore(main): release 1.2.0'
  git -C "$REPO" tag v1.2.1
  resolve
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  contains "$output" "APP_VERSION=1.2.1" || fail "the subject beat the tag: $output"
}

@test "the release commit subject wins over RELEASE_PR_TITLE" {
  commit 'chore(main): release 1.2.0'
  RELEASE_PR_TITLE='chore(main): release 9.9.9' resolve
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  contains "$output" "APP_VERSION=1.2.0" || fail "wrong precedence: $output"
}

# Matched on the exact subject shape, not on "a commit mentioning a version":
# an ordinary commit that talks about a release must not set the version.
@test "an ordinary commit subject carrying a version is not a version source" {
  commit
  git -C "$REPO" tag v0.4.9
  commit 'fix: release 9.9.9 was wrong'
  resolve
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  contains "$output" "APP_VERSION=0.4.10" || fail "an ordinary subject was used as a source: $output"
  commit 'chore(deps): release tooling bump'
  resolve
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  contains "$output" "APP_VERSION=0.4.10" || fail "a versionless chore subject changed the version: $output"
}

@test "falls back to a patch bump of the newest stable tag" {
  commit
  git -C "$REPO" tag v0.4.9
  commit second
  resolve
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  contains "$output" "APP_VERSION=0.4.10" || fail "no APP_VERSION=0.4.10 in: $output"
}

# The three prerelease cases below pin the agreed contract with the template's
# own copy: a prerelease tag is not a version source at all, at any step.
@test "a prerelease tag on HEAD does not win" {
  commit
  git -C "$REPO" tag v1.2.3-rc.1
  resolve
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  contains "$output" "APP_VERSION=0.0.1" || fail "expected the no-stable-tag default, got: $output"
}

@test "a repository whose only tags are prereleases starts at 0.0.1, not at a bump of the rc" {
  commit
  git -C "$REPO" tag v1.2.3-rc.1
  commit second
  git -C "$REPO" tag v1.2.3-rc.2
  commit third
  resolve
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  contains "$output" "APP_VERSION=0.0.1" || fail "expected 0.0.1, got: $output"
  not_contains "$output" "APP_VERSION=1.2" || fail "a prerelease tag seeded the bump: $output"
}

@test "a stable tag still wins over the prereleases beside it" {
  commit
  git -C "$REPO" tag v1.2.3-rc.1
  git -C "$REPO" tag v1.2.3
  resolve
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  contains "$output" "APP_VERSION=1.2.3" || fail "expected 1.2.3, got: $output"
}

@test "an untagged repository resolves to 0.0.1 (0.0.0 bumped), matching the template" {
  commit
  resolve
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  contains "$output" "APP_VERSION=0.0.1" || fail "expected 0.0.1, got: $output"
}

@test "build number is the first-parent commit count plus the default offset" {
  commit one
  commit two
  commit three
  resolve
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  contains "$output" "APP_BUILD_NUMBER=1003" || fail "expected 1003, got: $output"
}

@test "BUILD_NUMBER_OFFSET shifts the build number" {
  commit one
  BUILD_NUMBER_OFFSET=42 resolve
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  contains "$output" "APP_BUILD_NUMBER=43" || fail "expected 43, got: $output"
}

@test "a merge does not inflate the build number (first-parent only)" {
  commit base
  git -C "$REPO" checkout -q -b side
  commit side1
  commit side2
  git -C "$REPO" checkout -q main
  commit main1
  git -C "$REPO" merge -q --no-ff -m merge side
  resolve
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  # base + main1 + the merge itself = 3 first-parent commits, not 5.
  contains "$output" "APP_BUILD_NUMBER=1003" || fail "expected 1003, got: $output"
}

@test "writes version and build-number to GITHUB_OUTPUT and nothing to GITHUB_ENV" {
  commit
  git -C "$REPO" tag v3.1.4
  out="$BATS_TEST_TMPDIR/gh_output"
  env_file="$BATS_TEST_TMPDIR/gh_env"
  : > "$out"
  : > "$env_file"
  GITHUB_OUTPUT="$out" GITHUB_ENV="$env_file" resolve
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  grep -q '^version=3.1.4$' "$out" || fail "no version=3.1.4 in: $(cat "$out")"
  grep -q '^build-number=1001$' "$out" || fail "no build-number=1001 in: $(cat "$out")"
  # $GITHUB_ENV is deliberately untouched. The consumer's copy never wrote it and
  # cannot (it also runs under `make version` on a laptop), so a write from this
  # copy alone was drift the parity test could not see - it compares stdout and
  # $GITHUB_OUTPUT. build-prepare.yml now passes the two values to the steps that
  # need them from this step's outputs, explicitly.
  [ ! -s "$env_file" ] || fail "resolve-version.sh wrote \$GITHUB_ENV: $(cat "$env_file")"
}

@test "the release scope follows the branch, so releasing from master works" {
  commit
  git -C "$REPO" tag v0.4.9
  commit 'chore(master): release 1.2.0'
  GITHUB_REF_NAME=master resolve
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  contains "$output" "APP_VERSION=1.2.0" || fail "the master-scoped release was missed: $output"
}

@test "WORKFLOWS_RELEASE_SCOPE overrides the branch name" {
  commit
  git -C "$REPO" tag v0.4.9
  commit 'chore(app): release 1.2.0'
  GITHUB_REF_NAME=main WORKFLOWS_RELEASE_SCOPE=app resolve
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  contains "$output" "APP_VERSION=1.2.0" || fail "WORKFLOWS_RELEASE_SCOPE was ignored: $output"
}

@test "a release commit scoped to another branch is not this branch's release" {
  commit
  git -C "$REPO" tag v0.4.9
  commit 'chore(master): release 1.2.0'
  GITHUB_REF_NAME=main resolve
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  contains "$output" "APP_VERSION=0.4.10" || fail "another branch's release was used: $output"
}

@test "a scope containing a slash is matched literally, not as a regex" {
  # A branch name is not an ERE. `release/v1` must match `chore(release/v1)`,
  # and the `.` in a name like `v1.x` must not match any character.
  commit
  git -C "$REPO" tag v0.4.9
  commit 'chore(release/v1): release 1.2.0'
  GITHUB_REF_NAME='release/v1' resolve
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  contains "$output" "APP_VERSION=1.2.0" || fail "a slashed scope was not matched: $output"
}

@test "a non-numeric BUILD_NUMBER_OFFSET is fatal" {
  commit
  BUILD_NUMBER_OFFSET=abc resolve
  [ "$status" -ne 0 ] || fail "exited 0 on a bad offset: $output"
  contains "$output" "::error::" || fail "no ::error:: annotation in: $output"
}

#!/usr/bin/env bats
# Every assertion ends in `|| fail "..."` - see test_helper.bash.
#
# scripts/release/require-inputs.sh: the lane-input check every lane workflow
# runs before it installs or builds anything. It refuses an empty, unset or
# whitespace-only value for any of the five contract variables, names every
# one that is missing in a single message, carries the fix and the link to the
# consumer guide's section, and passes quietly when all five are set.
# Which workflows run it, and in what order, is contract-errors.bats' question.

load test_helper

SCRIPT="$REPO_ROOT/scripts/release/require-inputs.sh"

setup() {
  # A runner may export any of these; each case sets exactly what it tests.
  unset APP_VERSION APP_BUILD_NUMBER IOS_BUNDLE_ID IOS_SCHEME ANDROID_PACKAGE
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

@test "all five set passes, and says so" {
  APP_VERSION=1.2.3 APP_BUILD_NUMBER=1042 IOS_BUNDLE_ID=com.example.app IOS_SCHEME=App ANDROID_PACKAGE=com.example.app \
    run bash "$SCRIPT"
  [ "$status" -eq 0 ] || fail "a complete set was refused: $output"
  contains "$output" "lane inputs: all five contract variables are set" || fail "no confirmation: $output"
  not_contains "$output" "::error::" || fail "a passing check printed an error: $output"
}

@test "an unset variable is refused like an empty one" {
  # Not set at all, rather than set to "": the caller never passed it.
  APP_VERSION=1.2.3 APP_BUILD_NUMBER=1042 IOS_BUNDLE_ID=com.example.app IOS_SCHEME=App \
    run bash "$SCRIPT"
  [ "$status" -eq 1 ] || fail "an unset contract variable must be refused: $output"
  contains "$output" "these lane inputs are empty: ANDROID_PACKAGE -" || fail "does not name the unset one: $output"
}

@test "every missing variable is named in one message, in order" {
  # One run names them all: fixing one, pushing and learning of the next is the
  # loop this avoids.
  run bash "$SCRIPT"
  [ "$status" -eq 1 ] || fail "nothing set must be refused: $output"
  contains "$output" "these lane inputs are empty: APP_VERSION APP_BUILD_NUMBER IOS_BUNDLE_ID IOS_SCHEME ANDROID_PACKAGE -" ||
    fail "does not name all five: $output"
  [ "$(grep -c '::error::' <<< "$output")" -eq 1 ] || fail "expected one annotation, not one per variable: $output"
}

@test "the refusal carries the fix and links the consumer guide's section" {
  APP_VERSION=1.2.3 APP_BUILD_NUMBER="" IOS_BUNDLE_ID=com.example.app IOS_SCHEME=App ANDROID_PACKAGE=com.example.app \
    run bash "$SCRIPT"
  [ "$status" -eq 1 ] || fail "expected exit 1, got $status: $output"
  contains "$output" "Fix: APP_VERSION and APP_BUILD_NUMBER come from build-prepare's outputs" ||
    fail "the message carries no fix: $output"
  contains "$output" "consumer-guide.md#the-five-fastfile-contract-variables" ||
    fail "the message does not link the contract section: $output"
}

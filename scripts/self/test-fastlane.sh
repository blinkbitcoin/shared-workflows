#!/usr/bin/env bash
# The unit tests of the fastlane lanes this repository ships
# (packages/app-tooling/fastlane/test): the helpers, the promotion logic, the
# recorded arguments replayed against the real fastlane actions, and the
# package Fastfile loaded by real fastlane the way an app imports it.
#
#   test-fastlane.sh [minitest options]     e.g. -n /real_fastlane/
#
# They run under Bundler against test/Gemfile (fastlane, the Huawei plugin and
# minitest), installed into .gems/ at the repository root, which is gitignored.
# `bundle install` is idempotent, so a second run only checks.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd -P)"
root="$(cd "$here/../.." && pwd -P)"
package="$root/packages/app-tooling"

export BUNDLE_GEMFILE="$package/fastlane/test/Gemfile"
export BUNDLE_PATH="$root/.gems"
bundle install --quiet
cd "$package"
exec bundle exec ruby -Ifastlane/test fastlane/test/lanes_test.rb "$@"

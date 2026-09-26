#!/usr/bin/env bats
# Every assertion ends in `|| fail "..."` - see test_helper.bash.
#
# What is left of the suite that first ran the five fallback gates, the two
# libraries and the dev-config binary that nothing ran.
#
# Those scripts had been the softest corner of the coverage map: a test named
# each of them, but only to assert that check-code.yml still routes through the
# seam - it read their source and never ran them. That reads as coverage in a
# listing while asserting nothing about what they do, which is the distinction
# test/script-coverage.bats draws.
#
# Each gate and library now has a test file of its own, named after it, that
# covers every exit path: test/audit.bats, test/codegen.bats, test/i18n.bats,
# test/expo-doctor.bats, test/pnpm-install.bats, test/release-env.bats and
# test/env-validate.test.mjs. The cases that started here moved there unchanged
# (env-validate's as a node:test case). The binary's case stays below.

load test_helper

@test "check-tool-versions runs as a program and reports a mismatch" {
  # Twelve unit tests exercise its exported functions; nothing ran the binary,
  # which is how the advertised `pnpm exec check-tool-versions` could have been
  # broken without a test noticing.
  run mise exec -- node "$REPO_ROOT/packages/dev-config/bin/check-tool-versions.mjs" node
  [ "$status" -eq 0 ] || fail "the pinned node must satisfy its own baseline: $output"
  contains "$output" "node" || fail "it printed nothing about node: $output"

  run mise exec -- node "$REPO_ROOT/packages/dev-config/bin/check-tool-versions.mjs" not-a-tool
  contains "$output" "not in versions.json" || fail "an unknown tool must be reported: $output"
}

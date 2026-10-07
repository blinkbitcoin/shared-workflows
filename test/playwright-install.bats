#!/usr/bin/env bats
load test_helper

# A fake `pnpm` double records the exact argv `playwright install` was
# invoked with, so we can assert PLAYWRIGHT_BROWSERS is word-split into
# separate CLI arguments rather than passed as one quoted blob.
setup() {
  consumer="$BATS_TEST_TMPDIR/consumer"
  mkdir -p "$consumer"
  : > "$consumer/package.json"
  stub_cmd pnpm - <<'EOF'
if [ "$1" = "exec" ] && [ "$2" = "playwright" ] && [ "$3" = "install" ]; then
  shift 3
  printf '%s\n' "$@"
  exit 0
fi
echo "unexpected pnpm invocation: $*" >&2
exit 2
EOF
  export GITHUB_WORKSPACE="$consumer"
}

@test "defaults to chromium when PLAYWRIGHT_BROWSERS is unset" {
  unset PLAYWRIGHT_BROWSERS
  run bash "$REPO_ROOT/scripts/web/playwright-install.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *$'chromium\n--with-deps'* ]] || fail "assertion failed; output: $output"
}

@test "word-splits a multi-browser PLAYWRIGHT_BROWSERS into separate args" {
  PLAYWRIGHT_BROWSERS='chromium firefox' \
    run bash "$REPO_ROOT/scripts/web/playwright-install.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *$'chromium\nfirefox\n--with-deps'* ]] || fail "assertion failed; output: $output"
  traced "$output" "Install Playwright browsers (chromium firefox)" || fail "the install was not timed: $output"
}

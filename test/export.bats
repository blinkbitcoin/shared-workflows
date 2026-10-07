#!/usr/bin/env bats
load test_helper

setup() {
  consumer="$BATS_TEST_TMPDIR/consumer"
  mkdir -p "$consumer/node_modules/.bin"
  cat > "$consumer/package.json" <<'EOF'
{
  "name": "fixture-consumer",
  "version": "0.0.0",
  "private": true,
  "scripts": {
    "build:web": "mkdir -p dist && printf '<html>%s</html>' \"$EXPO_PUBLIC_BASE_URL$1\" > dist/index.html"
  }
}
EOF
  export GITHUB_WORKSPACE="$consumer"
}

@test "exports the web build and asserts index.html landed" {
  EXPORT_SCRIPT='build:web' OUTPUT_DIR=dist \
    run bash "$REPO_ROOT/scripts/web/export.sh"
  [ "$status" -eq 0 ]
  [ -f "$consumer/dist/index.html" ]
}

@test "passes EXPORT_ARGS through word-split to the export script" {
  EXPORT_SCRIPT='build:web' OUTPUT_DIR=dist EXPORT_ARGS='--dev' \
    run bash "$REPO_ROOT/scripts/web/export.sh"
  [ "$status" -eq 0 ]
  [ -f "$consumer/dist/index.html" ]
}

@test "dies when the export script does not produce index.html" {
  cat > "$consumer/package.json" <<'EOF'
{
  "name": "fixture-consumer",
  "version": "0.0.0",
  "private": true,
  "scripts": {
    "build:web": "mkdir -p dist"
  }
}
EOF
  EXPORT_SCRIPT='build:web' OUTPUT_DIR=dist \
    run bash "$REPO_ROOT/scripts/web/export.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"::error::"* ]] || fail "assertion failed; output: $output"
  [[ "$output" == *"dist/index.html"* ]] || fail "assertion failed; output: $output"
}

@test "dies when EXPORT_SCRIPT is not set" {
  OUTPUT_DIR=dist run env -u EXPORT_SCRIPT bash "$REPO_ROOT/scripts/web/export.sh"
  [ "$status" -eq 1 ] || fail "ran without EXPORT_SCRIPT: $output"
  contains "$output" "::error::missing required environment variable: EXPORT_SCRIPT" || fail "EXPORT_SCRIPT was not named: $output"
}

@test "dies when OUTPUT_DIR is empty" {
  EXPORT_SCRIPT='build:web' OUTPUT_DIR='' run bash "$REPO_ROOT/scripts/web/export.sh"
  [ "$status" -eq 1 ] || fail "ran with an empty OUTPUT_DIR: $output"
  contains "$output" "::error::missing required environment variable: OUTPUT_DIR" || fail "OUTPUT_DIR was not named: $output"
  [ ! -e "$consumer/dist" ] || fail "the export ran without OUTPUT_DIR"
}

@test "names both when neither EXPORT_SCRIPT nor OUTPUT_DIR is set" {
  run env -u EXPORT_SCRIPT -u OUTPUT_DIR bash "$REPO_ROOT/scripts/web/export.sh"
  [ "$status" -eq 1 ] || fail "ran with neither: $output"
  contains "$output" "::error::missing required environment variables: EXPORT_SCRIPT, OUTPUT_DIR" || fail "both were not named: $output"
}

#!/usr/bin/env bats
load test_helper

setup() {
  WORKFLOWS=()
  for f in "$REPO_ROOT"/.github/workflows/*.yml; do
    base="$(basename "$f")"
    case "$base" in
      self-*) continue ;;
    esac
    WORKFLOWS+=("$f")
  done
}

@test "at least two reusable workflows exist" {
  [ "${#WORKFLOWS[@]}" -ge 2 ]
}

# Named explicitly rather than left to the glob: a workflow accidentally
# deleted or renamed would otherwise just shrink WORKFLOWS and every other
# assertion here would still pass.
@test "every reusable workflow this family publishes is present" {
  for w in check-code check-unit check-e2e build-web publish-badges pr-closed pr-title check-codeql \
    check-security build-prepare build-ios build-android \
    publish-store publish-github-release publish-ota pr-release-notes; do
    [ -f "$REPO_ROOT/.github/workflows/$w.yml" ] || {
      echo "missing .github/workflows/$w.yml" >&2
      return 1
    }
  done
}

# GitHub reads only the top level of .github/workflows, so the filename prefix
# is the only grouping there is: check- (gates on every change), build-
# (artifacts), publish- (stores, releases, OTA, badges), pr- (pull request
# hooks) and self- (this repository's own CI). A new workflow outside them is
# a naming decision nobody made on purpose.
@test "every workflow file carries a stage prefix" {
  bad=()
  for f in "$REPO_ROOT"/.github/workflows/*; do
    base="$(basename "$f")"
    case "$base" in
      check-*.yml | build-*.yml | publish-*.yml | pr-*.yml | self-*.yml) ;;
      *) bad+=("$base") ;;
    esac
  done
  [ "${#bad[@]}" -eq 0 ] || fail "workflow files without a stage prefix: ${bad[*]}"
}

@test "every declared secret is optional (required: false)" {
  for w in "${WORKFLOWS[@]}"; do
    # A required secret in a reusable workflow makes every caller declare it,
    # even the ones that never reach the job needing it.
    bad=$(yq -r '[(.on.workflow_call.secrets // {}) | to_entries[] | select(.value.required != false)] | length' "$w")
    [ "$bad" -eq 0 ]
  done
}

@test "no workflow puts an empty string in the AND slot of the ternary idiom" {
  for w in "${WORKFLOWS[@]}"; do
    # GitHub's && yields its first falsy operand, so `cond && '' || X` is X on
    # both branches. The non-empty value must sit in the && slot.
    #
    # YAML comments are stripped first: the workflows explain this very pitfall
    # in prose, and matching that prose is a false positive. It *was* one - and
    # invisible, because a bare `! cmd` is exempt from errexit too, so this
    # assertion could not fail anything until it was given a `|| fail`.
    ! grep -vE '^[[:space:]]*#' "$w" | grep -qE "&&[[:space:]]*''[[:space:]]*\|\|" \
      || fail "$(basename "$w") puts an empty string in the && slot of the ternary idiom"
  done
}

# The single-source rule has exactly one line of code behind it: the BASE_SHA
# expression. Reverting it to a bare `github.event.pull_request.base.sha` leaves
# the classifier blind on a push, which is the defect this family fixed - and
# the caller's `paths-ignore`, which used to mask it, has been removed on
# purpose, so the regression would now be silent AND unmasked.
@test "check-code.yml classifies pushes too: BASE_SHA names both base.sha and event.before" {
  command -v yq >/dev/null || skip "yq not installed"
  expr=$(yq -r '.jobs.changes.steps[] | select(.id == "classify") | .env.BASE_SHA // ""' \
    "$REPO_ROOT/.github/workflows/check-code.yml")
  [ -n "$expr" ] || fail "no BASE_SHA env on check-code.yml's classify step"
  grep -qF 'github.event.pull_request.base.sha' <<<"$expr" \
    || fail "BASE_SHA must use the PR base on a pull_request: $expr"
  grep -qF 'github.event.before' <<<"$expr" \
    || fail "BASE_SHA must fall back to github.event.before so a push is classified too: $expr"
  # The fallback has to be reached by branching on the event, not by relying on
  # base.sha being empty - relying on that is exactly what the pre-fix
  # expression did, and it classified nothing on a push.
  grep -qF "github.event_name == 'pull_request'" <<<"$expr" \
    || fail "BASE_SHA must branch on github.event_name: $expr"
}

# check-codeql.yml asks the same question check-code.yml does, and "the same" has to mean
# character-for-character: two spellings of the base sha are two rules, and the
# second one drifts. Comparing the two expressions is cheaper than restating the
# right answer twice.
@test "check-codeql.yml's BASE_SHA expression is byte-identical to check-code.yml's" {
  command -v yq >/dev/null || skip "yq not installed"
  read_base_sha() {
    yq -r '.jobs.changes.steps[] | select(.id == "classify") | .env.BASE_SHA // ""' \
      "$REPO_ROOT/.github/workflows/$1.yml"
  }
  checks=$(read_base_sha check-code)
  codeql=$(read_base_sha check-codeql)
  [ -n "$codeql" ] || fail "no BASE_SHA env on check-codeql.yml's classify step"
  [ "$codeql" = "$checks" ] \
    || fail "check-codeql.yml classifies with '$codeql' but check-code.yml uses '$checks'"
}

# The whole point of the changes job: a docs-only change analyses nothing, and
# a scheduled run (no base at all) analyses everything.
@test "check-codeql.yml's analyze job is gated on the classifier" {
  command -v yq >/dev/null || skip "yq not installed"
  f="$REPO_ROOT/.github/workflows/check-codeql.yml"
  cond=$(yq -r '.jobs.analyze.if' "$f")
  [[ "$cond" == *"needs.changes.outputs.docs-only != 'true'"* ]] \
    || fail "analyze's if does not gate on the classifier: $cond"
  needs=$(yq -r '.jobs.analyze.needs | join(",")' "$f")
  [ "$needs" = "changes" ] || fail "analyze needs '$needs', expected changes"
}

# build-web.yml runs the same classifier for the web class, and the same rule
# holds: one spelling of the base sha.
@test "build-web.yml's BASE_SHA expression is byte-identical to check-code.yml's" {
  command -v yq >/dev/null || skip "yq not installed"
  read_base_sha() {
    yq -r '.jobs.changes.steps[] | select(.id == "classify") | .env.BASE_SHA // ""' \
      "$REPO_ROOT/.github/workflows/$1.yml"
  }
  checks=$(read_base_sha check-code)
  web=$(read_base_sha build-web)
  [ -n "$web" ] || fail "no BASE_SHA env on build-web.yml's classify step"
  [ "$web" = "$checks" ] \
    || fail "build-web.yml classifies with '$web' but check-code.yml uses '$checks'"
}

# A web-irrelevant change builds nothing; `playwright` and `deploy` need `build`,
# so they follow it. `!= 'false'`, so an output that never arrived builds.
@test "build-web.yml's build job is gated on the web class, and the rest follow it" {
  command -v yq >/dev/null || skip "yq not installed"
  f="$REPO_ROOT/.github/workflows/build-web.yml"
  [ "$(yq -r '.jobs.build.needs' "$f")" = "changes" ] || fail "build does not need changes"
  cond=$(yq -r '.jobs.build.if' "$f")
  [[ "$cond" == *"needs.changes.outputs.web-changed != 'false'"* ]] \
    || fail "build's if does not gate on web-changed != 'false': $cond"
  [ "$(yq -r '.jobs.playwright.needs' "$f")" = "build" ] || fail "playwright no longer needs build"
  contains "$(yq -r '.jobs.deploy.if' "$f")" "needs.build.result == 'success'" \
    || fail "deploy no longer requires a successful build"
  env=$(yq -r '.jobs.changes.steps[] | select(.id == "classify") | .env' "$f")
  contains "$env" 'DOCS_GLOBS_EXTRA: ${{ inputs.docs-globs }}' || fail "docs-globs is not wired: $env"
  contains "$env" 'WEB_IGNORE_GLOBS_EXTRA: ${{ inputs.web-ignore-globs }}' \
    || fail "web-ignore-globs is not wired: $env"
  [ "$(yq -r '.on.workflow_call.outputs."web-changed".value' "$f")" = '${{ jobs.changes.outputs.web-changed }}' ] \
    || fail "the web-changed output is not wired from the changes job"
  [ "$(yq -r '.jobs.changes | has("permissions")' "$f")" = "false" ] \
    || fail "the changes job escalates permissions"
}

# Each suite class check-code.yml advertises is wired end to end: the input
# reaches the script, the step output reaches the job output, and the job output
# reaches the workflow output.
@test "check-code.yml wires every suite class from input to workflow output" {
  command -v yq >/dev/null || skip "yq not installed"
  f="$REPO_ROOT/.github/workflows/check-code.yml"
  env=$(yq -r '.jobs.changes.steps[] | select(.id == "classify") | .env' "$f")
  for pair in "unit:UNIT" "e2e:E2E"; do
    class="${pair%%:*}" var="${pair##*:}"
    contains "$env" "${var}_IGNORE_GLOBS_EXTRA: \${{ inputs.${class}-ignore-globs }}" \
      || fail "${class}-ignore-globs is not wired to ${var}_IGNORE_GLOBS_EXTRA: $env"
    [ "$(yq -r ".jobs.changes.outputs.\"${class}-changed\"" "$f")" = "\${{ steps.classify.outputs.${class}-changed }}" ] \
      || fail "the changes job does not expose ${class}-changed"
    [ "$(yq -r ".on.workflow_call.outputs.\"${class}-changed\".value" "$f")" = "\${{ jobs.changes.outputs.${class}-changed }}" ] \
      || fail "the workflow does not expose ${class}-changed"
  done
}

# The caller half. A skipped `unit` (a flows-only change) must not take `e2e`
# down with it, and neither gate may read an empty output as "skip".
@test "the fixture caller gates unit and e2e on their classes, and e2e survives a skipped unit" {
  command -v yq >/dev/null || skip "yq not installed"
  f="$FIXTURES/consumer-min/.github/workflows/ci.yml"
  unit=$(yq -r '.jobs.unit.if' "$f")
  contains "$unit" "needs.checks.outputs.unit-changed != 'false'" || fail "unit's gate: $unit"
  e2e=$(yq -r '.jobs.e2e.if' "$f")
  for needle in \
    "!cancelled()" \
    "needs.checks.result == 'success'" \
    "contains(fromJSON('[\"success\", \"skipped\"]'), needs.unit.result)" \
    "needs.checks.outputs.e2e-changed != 'false'"; do
    contains "$e2e" "$needle" || fail "e2e's gate no longer contains [$needle]: $e2e"
  done
}

# The escalation is on the analyze job alone, and naming `permissions:` resets
# the unnamed scopes to none - so dropping contents: read would break the
# checkout rather than the upload. All three are asserted, and nothing more.
@test "check-codeql.yml escalates permissions only on the analyze job" {
  command -v yq >/dev/null || skip "yq not installed"
  f="$REPO_ROOT/.github/workflows/check-codeql.yml"
  [ "$(yq -r '.jobs.analyze.permissions.contents' "$f")" = "read" ] \
    || fail "analyze does not re-declare contents: read"
  [ "$(yq -r '.jobs.analyze.permissions.actions' "$f")" = "read" ] \
    || fail "analyze does not declare actions: read"
  [ "$(yq -r '.jobs.analyze.permissions."security-events"' "$f")" = "write" ] \
    || fail "analyze does not declare security-events: write"
  [ "$(yq -r '.jobs.analyze.permissions | keys | length' "$f")" -eq 3 ] \
    || fail "analyze asks for more than three scopes: $(yq -r '.jobs.analyze.permissions' "$f")"
  [ "$(yq -r '.jobs.changes | has("permissions")' "$f")" = "false" ] \
    || fail "the changes job escalates permissions; only analyze may"
}

# The head half of the same range. changed-class.bats covers what the script
# does when either end is absent from the consumer's checkout.
@test "check-code.yml's classify step passes both ends of the range to the script" {
  command -v yq >/dev/null || skip "yq not installed"
  run yq -r '.jobs.changes.steps[] | select(.id == "classify") | .run' \
    "$REPO_ROOT/.github/workflows/check-code.yml"
  [ "$status" -eq 0 ]
  grep -qF '"$BASE_SHA" "$HEAD_SHA"' <<<"$output" \
    || fail "classify must call changed-class.sh with BASE_SHA and HEAD_SHA: $output"
}

lane_step_count() {
  yq -r '[.jobs[].steps[]? | select((.run? // "") | test("release/fastlane.sh"))] | length' "$1"
}

@test "every step that runs fastlane.sh receives the five Fastfile contract variables" {
  # The consumer's Fastfile runs require_env! over these in before_all, for
  # every lane on both platforms, and rejects values that are empty after
  # strip - so the iOS build must still pass ANDROID_PACKAGE, and vice versa.
  for w in "${WORKFLOWS[@]}"; do
    job_names=$(yq -r '.jobs | keys | .[]' "$w")
    for j in $job_names; do
      n=$(yq -r "[.jobs.\"$j\".steps[]? | select((.run? // \"\") | test(\"release/fastlane.sh\"))] | length" "$w")
      if [ "$n" -gt 0 ]; then
        job_env=$(yq -r "(.jobs.\"$j\".env // {}) | keys | .[]" "$w")
        i=0
        while [ "$i" -lt "$n" ]; do
          step_env=$(yq -r "[.jobs.\"$j\".steps[]? | select((.run? // \"\") | test(\"release/fastlane.sh\"))][$i] | (.env // {}) | keys | .[]" "$w")
          for v in APP_VERSION APP_BUILD_NUMBER IOS_BUNDLE_ID IOS_SCHEME ANDROID_PACKAGE; do
            printf '%s\n%s\n' "$job_env" "$step_env" | grep -qxF "$v" \
              || fail "$(basename "$w"): job '$j' fastlane step #$i receives neither a job-level nor a step-level $v"
          done
          i=$((i + 1))
        done
      fi
    done
  done
}

@test "every credential secret a lane workflow declares reaches EVERY fastlane step's env" {
  # This is exactly what C1 was: ASC_KEY_P8_BASE64 was decoded to a 0600 file
  # but never put in the lane's environment, and the lane reads the base64
  # itself with ENV.fetch - so every store lane would have raised KeyError.
  #
  # Per step, not per workflow: a union across all fastlane steps would pass
  # when the secret is on `verify` but missing from `build`, which is the same
  # bug made half as often. If a secret ever legitimately belongs to only one
  # step, add it to an explicit allowlist here rather than flattening again.
  for w in "${WORKFLOWS[@]}"; do
    job_names=$(yq -r '.jobs | keys | .[]' "$w")
    for j in $job_names; do
      n=$(yq -r "[.jobs.\"$j\".steps[]? | select((.run? // \"\") | test(\"release/fastlane.sh\"))] | length" "$w")
      if [ "$n" -gt 0 ]; then
        declared=$(yq -r '(.on.workflow_call.secrets // {}) | keys | .[]' "$w")
        job_env=$(yq -r "(.jobs.\"$j\".env // {}) | keys | .[]" "$w")
        i=0
        while [ "$i" -lt "$n" ]; do
          step_name=$(yq -r "[.jobs.\"$j\".steps[]? | select((.run? // \"\") | test(\"release/fastlane.sh\"))][$i].name // \"step $i\"" "$w")
          step_env=$(yq -r "[.jobs.\"$j\".steps[]? | select((.run? // \"\") | test(\"release/fastlane.sh\"))][$i] | (.env // {}) | keys | .[]" "$w")
          for s in $declared; do
            case "$s" in
              consumer-token) continue ;;
            esac
            printf '%s\n%s\n' "$job_env" "$step_env" | grep -qxF "$s" \
              || fail "$(basename "$w"): secret $s is declared but never reaches the [$step_name] step env"
          done
          i=$((i + 1))
        done
      fi
    done
  done
}

# The App Review contact and demo-account names are a cross-repo contract: the
# consumer's Fastfile reads them straight out of ENV, so a rename on either side
# silently stops populating the App Store review form - deliver and pilot simply
# receive fewer keys, with no error. The names are therefore not hard-coded here
# but read out of a committed copy of the template's shared.rb, and the two sets
# are compared in both directions.
#
# They are secrets rather than build-env/env-json values because a reviewer demo
# login is a real credential and both of those inputs are printed to the log.
#
# Read from the fixture consumer's lanes, which is what the guide's examples are
# built from. A real consumer's lanes are held to the same names by its own
# Contract job (lane.app-review-env in contract.json).
@test "publish-store's App Review secrets are exactly the names the fixture's lanes read" {
  TEMPLATE_LANES="$FIXTURES/consumer-min/fastlane/lanes/shared.rb"
  [ -f "$TEMPLATE_LANES" ] || fail "no fixture lanes at $TEMPLATE_LANES"
  wanted="$(grep -oE "ENV\['APP_REVIEW_[A-Z0-9_]*'\]" "$TEMPLATE_LANES" |
    sed "s/ENV\['//; s/'\]//" | sort -u)"
  [ "$(grep -c . <<<"$wanted")" -ge 7 ] \
    || fail "read only '$wanted' from $TEMPLATE_LANES - has the fixture changed shape?"
  declared="$(yq -r '.on.workflow_call.secrets | keys | .[]' "$REPO_ROOT/.github/workflows/publish-store.yml" |
    grep '^APP_REVIEW_' | sort -u)"
  while read -r name; do
    [ -n "$name" ] || continue
    grep -qxF "$name" <<<"$declared" \
      || fail "the fixture's lanes read $name but publish-store.yml does not declare it"
  done <<<"$wanted"
  while read -r name; do
    [ -n "$name" ] || continue
    grep -qxF "$name" <<<"$wanted" \
      || fail "publish-store.yml declares $name but no lane in the fixture reads it"
  done <<<"$declared"
}

# The template's upload_huawei lane reads these straight out of the
# environment, and a caller cannot pass a secret this reusable workflow has
# not declared - so both halves of the AppGallery client have to be here.
@test "publish-store declares the Huawei AppGallery client pair" {
  declared="$(yq -r '.on.workflow_call.secrets | keys | .[]' "$REPO_ROOT/.github/workflows/publish-store.yml")"
  for name in HUAWEI_CLIENT_ID HUAWEI_CLIENT_SECRET; do
    grep -qxF "$name" <<<"$declared" \
      || fail "publish-store.yml does not declare $name"
  done
}

@test "every workflow that runs prebuild, a lane or the notes generator accepts build-env" {
  for w in build-prepare build-ios build-android publish-store pr-release-notes check-security; do
    f="$REPO_ROOT/.github/workflows/$w.yml"
    have=$(yq -r '.on.workflow_call.inputs | has("build-env")' "$f")
    [ "$have" = "true" ] || fail "$w.yml does not declare a build-env input"
    default=$(yq -r '.on.workflow_call.inputs."build-env".default' "$f")
    [ "$default" = "{}" ] || fail "$w.yml's build-env default is '$default', expected {}"
    steps=$(yq -r '[.jobs[].steps[]? | select((.run? // "") | test("release/build-env.sh"))] | length' "$f")
    [ "$steps" -ge 1 ] || fail "$w.yml declares build-env but never publishes it"
  done
}

@test "every workflow declares on.workflow_call" {
  for w in "${WORKFLOWS[@]}"; do
    has=$(yq -r 'has("on") and (.on | has("workflow_call"))' "$w")
    [ "$has" = "true" ]
  done
}

# build-prepare is the one exception: its prepare job must take the caller's
# grant as-is (contents: write for reserve-tag, actions: read or write for the
# green gate), and any `permissions` block in a called workflow - top-level
# included - replaces the caller's grant with its own. v0.6.0 shipped with
# `contents: read` here and the job's token was `Contents: read, Metadata:
# read` whatever the caller granted (react-native-mobile-template run
# 35429556846, attempt 2). See the comment in the workflow.
@test "every workflow has top-level permissions.contents == read, except build-prepare which has no block at all" {
  for w in "${WORKFLOWS[@]}"; do
    if [ "$(basename "$w")" = "build-prepare.yml" ]; then
      [ "$(yq -r '.permissions // "absent"' "$w")" = "absent" ] \
        || fail "build-prepare.yml has a top-level permissions block; it would replace the caller's grant: $(yq -r '.permissions' "$w")"
      continue
    fi
    perms=$(yq -r '.permissions.contents' "$w")
    [ "$perms" = "read" ] || fail "$(basename "$w") top-level permissions.contents is '$perms', not read"
  done
}

# A store listing is keyed on the full metadata locale name (en-US, de-DE,
# pt-BR); a bare language code matches no listing, so the default cannot be
# `en` however natural that reads.
@test "build-prepare's notes-locales default is a store metadata locale" {
  f="$REPO_ROOT/.github/workflows/build-prepare.yml"
  got=$(yq -r '.on.workflow_call.inputs."notes-locales".default' "$f")
  [ "$got" = "en-US" ] || fail "notes-locales defaults to '$got', expected en-US"
  grep -q '| `notes-locales` | `en-US` |' "$REPO_ROOT/docs/consumer-guide.md" \
    || fail "the consumer guide still documents a different notes-locales default"
}

# The digest step writes an enriched build-info.json into $WORKFLOWS_OUTPUT_DIR; the
# in-job verify has to read *that* one, or artifacts.apkSha256 is never there
# and the lane's apk-sha check silently skips.
@test "build-android's verify reads the build-info carrying the digests" {
  f="$REPO_ROOT/.github/workflows/build-android.yml"
  got=$(yq -r '[.jobs[].steps[] | select(.name == "Fastlane android verify")][0].env.BUILD_INFO_FILE' "$f")
  [ "$got" = '${{ env.WORKFLOWS_OUTPUT_DIR }}/build-info.json' ] \
    || fail "the android verify step reads BUILD_INFO_FILE '$got'"
  n=$(yq -r '[.jobs[].steps[]? | select((.run? // "") | test("release/artifact-hashes.sh"))] | length' "$f")
  [ "$n" -eq 1 ] || fail "build-android does not run artifact-hashes.sh exactly once"
}

# $WORKFLOWS_DIR is published by the setup composite action, so it exists only
# in the steps after Setup. A step before it - or in a job that never runs
# setup - expands `$WORKFLOWS_DIR/scripts/…` to `/scripts/…` and exits 127 on
# every call, a workflow that cannot work at all, and one no unit test would
# ever reach. v0.6.0 shipped exactly that: four steps moved ahead of Setup kept
# the `$WORKFLOWS_DIR` form and broke every consumer's internal release on its
# next push. Steps before Setup use the literal `.workflows/` prefix.
@test "no run: step uses \$WORKFLOWS_DIR before the setup action has published it" {
  for w in "${WORKFLOWS[@]}"; do
    while read -r j; do
      [ -n "$j" ] || continue
      seen_setup=0
      # One line per step, in order: is-setup|uses-dir|name. This family's own
      # composite action specifically - not actions/setup-node or
      # gradle/actions/setup-gradle, neither of which publishes $WORKFLOWS_DIR.
      while IFS='|' read -r is_setup uses_dir name; do
        [ -n "$is_setup" ] || continue
        # `if`, not `[ ] && …`: a false test as the loop body's last command
        # would make the loop itself fail under bats.
        if [ "$is_setup" = "true" ]; then seen_setup=1; fi
        if [ "$uses_dir" = "true" ] && [ "$seen_setup" -eq 0 ]; then
          fail "$(basename "$w") job '$j' uses \$WORKFLOWS_DIR before the setup action publishes it, in: $name"
        fi
      done <<<"$(yq -r ".jobs.\"$j\".steps[]? | [((.uses // \"\") | test(\"workflows/.github/actions/setup\")), ((.run // \"\") | test(\"WORKFLOWS_DIR/\")), (.name // .uses // \"\")] | join(\"|\")" "$w")"
    done <<<"$(yq -r '.jobs | keys | .[]' "$w")"
  done
}

# `merge-multiple: true` has no defined order, so two artifacts carrying
# `build-info.json` would make the release's record a coin toss. The per-platform
# record therefore ships under its own name and publish-github-release folds it in
# explicitly, after both downloads and before the upload.
@test "the release's build-info precedence is explicit, not a merge-multiple race" {
  a="$REPO_ROOT/.github/workflows/build-android.yml"
  paths=$(yq -r '[.jobs[].steps[]? | select(.uses? // "" | test("upload-artifact")) | .with.path] | join("\n")' "$a")
  not_contains "$paths" "/build-info.json" \
    || fail "build-android uploads a bare build-info.json, which can collide: $paths"
  contains "$paths" "/build-info.android.json" \
    || fail "build-android never uploads its per-platform build-info: $paths"
  g="$REPO_ROOT/.github/workflows/publish-github-release.yml"
  names=$(yq -r '.jobs.release.steps[].name' "$g")
  # `yq` here is the Go implementation, whose jq subset has no index(); the step
  # order is read out of the numbered list instead.
  step_index() { printf '%s\n' "$names" | grep -nxF "$1" | head -1 | cut -d: -f1; }
  merge_i=$(step_index "Merge platform build-info")
  notes_i=$(step_index "Download notes")
  assets_i=$(step_index "Download assets")
  upload_i=$(step_index "Release assets")
  [ -n "$merge_i" ] || fail "publish-github-release never merges the platform build-info: $names"
  [ "$notes_i" -lt "$assets_i" ] || fail "publish-github-release stages assets before notes: $names"
  [ "$assets_i" -lt "$merge_i" ] || fail "the merge runs before the assets are staged: $names"
  [ "$merge_i" -lt "$upload_i" ] || fail "the merge runs after the upload: $names"
}

# publish-store builds nothing: the binaries its lanes upload were downloaded
# into $WORKFLOWS_ASSETS_DIR. The lanes read $WORKFLOWS_OUTPUT_DIR, so the two have to be
# the same directory here - and only here; the build workflows keep
# WORKFLOWS_OUTPUT_DIR as the directory the lane *writes* to.
@test "publish-store points WORKFLOWS_OUTPUT_DIR at the downloaded artifacts" {
  f="$REPO_ROOT/.github/workflows/publish-store.yml"
  got=$(yq -r '[.jobs.lane.steps[] | select(.name == "Fastlane lane")][0].env.WORKFLOWS_OUTPUT_DIR' "$f")
  [ "$got" = '${{ env.WORKFLOWS_ASSETS_DIR }}' ] \
    || fail "publish-store's lane step sets WORKFLOWS_OUTPUT_DIR to '$got'"
  for w in build-ios build-android; do
    b="$REPO_ROOT/.github/workflows/$w.yml"
    n=$(yq -r '[.jobs[].steps[]? | select((.env.WORKFLOWS_OUTPUT_DIR? // "") != "")] | length' "$b")
    [ "$n" -eq 0 ] || fail "$w.yml overrides WORKFLOWS_OUTPUT_DIR, which is where its lane writes"
  done
}

# Issue #70: a rehearsal path for the store lane. `default: false` is what
# keeps every existing caller unaffected; the Fastlane lane step's DRY_RUN must
# still read `env.DRY_RUN`, not just the new input, or this ships silently
# disarming the template's cd-store-listing.yml - it forwards its own
# `dry_run` dispatch input (default true) through env-json's DRY_RUN key
# rather than through this input, and a step's own `env:` block wins over a
# same-named value inherited from an earlier step's $GITHUB_ENV write.
@test "publish-store declares dry-run (boolean, default false) and ORs it into the Fastlane lane step's DRY_RUN" {
  command -v yq >/dev/null || skip "yq not installed"
  f="$REPO_ROOT/.github/workflows/publish-store.yml"
  [ "$(yq -r '.on.workflow_call.inputs."dry-run".type' "$f")" = "boolean" ] \
    || fail "dry-run is not declared as a boolean input"
  [ "$(yq -r '.on.workflow_call.inputs."dry-run".default' "$f")" = "false" ] \
    || fail "dry-run does not default to false, which would change behaviour for every existing caller"
  expr=$(yq -r '[.jobs.lane.steps[] | select(.name == "Fastlane lane")][0].env.DRY_RUN' "$f")
  grep -qF 'inputs.dry-run' <<<"$expr" \
    || fail "the Fastlane lane step's DRY_RUN does not read the dry-run input: $expr"
  grep -qF 'env.DRY_RUN' <<<"$expr" \
    || fail "the Fastlane lane step's DRY_RUN ignores an env-json-supplied value, which would disarm cd-store-listing.yml's dry_run forwarding: $expr"
}

# build-prepare's green gate needs `actions: read`, and `actions: write` when
# `require-green-dispatch` is on. A static job-level block cannot express
# "read, or write when asked", and a called job may never request more than
# the caller granted - so the job declares no permissions and inherits the
# caller's. A block reappearing here would either reject every caller that
# grants `read` (if it said `write`) or make the self-heal impossible (if it
# said `read`).
# The build tag is reserved seconds after the push, while the commit is still
# the default branch tip, because GitHub refuses GITHUB_TOKEN a new tag on a
# commit whose workflow files differ from the tip (scripts/release/reserve-tag.sh).
# After a 35-minute green gate the tip has often moved. So the reservation, and
# the version it needs, come before the gate - and before Setup, which they do
# not need.
@test "build-prepare reserves the build tag before the green gate and before Setup" {
  command -v yq >/dev/null || skip "yq not installed"
  f="$REPO_ROOT/.github/workflows/build-prepare.yml"
  names="$(yq -r '.jobs.prepare.steps[].name' "$f")"
  order() { printf '%s\n' "$names" | grep -n -x "$1" | cut -d: -f1; }
  v=$(order "Resolve version"); r=$(order "Reserve build tag"); g=$(order "Require a green upstream run"); s=$(order "Setup")
  [ -n "$v" ] && [ -n "$r" ] && [ -n "$g" ] && [ -n "$s" ] || fail "a step is missing: version=$v reserve=$r gate=$g setup=$s"
  [ "$v" -lt "$r" ] || fail "the tag is reserved before the version is known"
  [ "$r" -lt "$g" ] || fail "the tag is reserved after the green gate: order $r vs $g"
  [ "$g" -lt "$s" ] || fail "the green gate runs after Setup"
}

@test "build-prepare's prepare job inherits the caller's permissions" {
  f="$REPO_ROOT/.github/workflows/build-prepare.yml"
  [ "$(yq -r '.jobs.prepare.permissions // "inherit"' "$f")" = "inherit" ] \
    || fail "build-prepare's prepare job declares permissions, so it cannot take actions: write from a caller that grants it: $(yq -r '.jobs.prepare.permissions' "$f")"
  # A top-level block is the same defect one level up: it applies to every job
  # without its own, and replaced the caller's grant in v0.6.0.
  [ "$(yq -r '.permissions // "absent"' "$f")" = "absent" ] \
    || fail "build-prepare has a top-level permissions block, which replaces the caller's grant: $(yq -r '.permissions' "$f")"
  grep -q 'REQUIRE_GREEN_DISPATCH_REF' "$f" \
    || fail "build-prepare does not wire require-green-dispatch into the gate"
  # The consumer guide is where a caller learns what to grant.
  grep -q 'Every caller of `build-prepare.yml` must grant `actions: read`' "$REPO_ROOT/docs/consumer-guide.md" \
    || fail "the consumer guide does not tell callers to grant actions: read"
  grep -q 'actions: write' "$REPO_ROOT/docs/consumer-guide.md" \
    || fail "the consumer guide does not tell callers dispatch needs actions: write"
}

@test "no workflow sets a top-level concurrency" {
  for w in "${WORKFLOWS[@]}"; do
    has=$(yq -r 'has("concurrency")' "$w")
    [ "$has" = "false" ]
  done
}

@test "every job has timeout-minutes" {
  for w in "${WORKFLOWS[@]}"; do
    missing=$(yq -r '[.jobs[] | select(has("timeout-minutes") | not)] | length' "$w")
    [ "$missing" -eq 0 ]
  done
}

# A job-level cap is a bound, not a diagnosis: when the 60-minute `android` job
# dies there is nothing in the log saying *which* of its steps hung. These are
# the steps that can hang on something outside our control (a CDN, a pod
# resolve, an emulator boot), so each carries its own bound. The list is named
# rather than derived: renaming a step would otherwise silently drop its
# timeout and this test would still pass.
#
# Deliberately absent: the Maestro suite steps (theirs comes from
# `suite-timeout-minutes` via step-timeout.sh) and download-artifact (it
# retries internally, and a step timeout would cut a legitimate retry short).
@test "check-e2e.yml's hang-prone steps each carry a step-level timeout-minutes" {
  f="$REPO_ROOT/.github/workflows/check-e2e.yml"
  for spec in \
    "Pod install:20" \
    "Build iOS app:45" \
    "Install Maestro:10" \
    "Wait for Metro:10" \
    "Bake AVD snapshot:20" \
    "Install Android emulator package:15"; do
    name="${spec%:*}"
    want="${spec##*:}"
    found=$(yq -r "[.jobs[].steps[]? | select(.name == \"$name\")] | length" "$f")
    [ "$found" -gt 0 ] || fail "check-e2e.yml has no step named '$name' - was it renamed?"
    # Every occurrence: 'Install Maestro' and 'Wait for Metro' appear in both
    # the ios and the android job.
    bad=$(yq -r "[.jobs[].steps[]? | select(.name == \"$name\") | select(.\"timeout-minutes\" != $want)] | length" "$f")
    [ "$bad" -eq 0 ] || fail "$bad of the $found '$name' steps lack timeout-minutes: $want"
  done
}

# The audit step's three-part policy, pinned because each part has already
# failed somewhere in the family:
#
#   * `timeout-minutes` is the bound on a stalling advisories/bulk request;
#   * `continue-on-error` is what makes the audit advisory on a PR and blocking
#     on a push, and it must read the toggle, not just the event;
#   * the fetch timeout must live on the *step*. esign aebdd28: a 60s
#     NPM_CONFIG_FETCH_TIMEOUT set at workflow level for an installer's cold
#     path was inherited by the audit step, silently overrode its 5-minute
#     budget, and turned main red at 61s. Hoisting these two variables up to
#     `env:` at workflow or job level is therefore the exact regression to
#     catch: it looks like tidying and it re-arms that bug for any caller that
#     sets a smaller value upstream.
@test "check-code.yml's audit step keeps its timeout, its soft-on-PR expression and a step-level fetch timeout" {
  command -v yq >/dev/null || skip "yq not installed"
  f="$REPO_ROOT/.github/workflows/check-code.yml"
  # Across all jobs, not one named job: the gates are grouped by who acts on a
  # failure, and which group a step sits in is allowed to change.
  step='.jobs[].steps[]? | select(.name == "Audit")'

  found=$(yq -r "[$step] | length" "$f")
  [ "$found" -eq 1 ] || fail "expected exactly one 'Audit' step in check-code.yml, found $found"

  t=$(yq -r "$step | .\"timeout-minutes\" // \"\"" "$f")
  [ "$t" = "5" ] || fail "the Audit step must carry timeout-minutes: 5, got '$t'"

  coe=$(yq -r "$step | .\"continue-on-error\" // \"\"" "$f")
  grep -qF 'inputs.audit-soft-on-pr' <<<"$coe" \
    || fail "continue-on-error must read the audit-soft-on-pr input: $coe"
  grep -qF "github.event_name == 'pull_request'" <<<"$coe" \
    || fail "continue-on-error must stay hard off a pull_request: $coe"

  # PNPM_CONFIG_ is the one that does the work (audit.sh runs `pnpm audit`, and
  # pnpm 11/12 read PNPM_CONFIG_*, not npm_config_*); NPM_CONFIG_ covers any
  # npm/npx call in the same step. Both must exceed the 5-minute bound above,
  # or the request dies inside the step budget instead of using it.
  for v in PNPM_CONFIG_FETCH_TIMEOUT NPM_CONFIG_FETCH_TIMEOUT; do
    got=$(yq -r "$step | .env.\"$v\" // \"\"" "$f")
    [ -n "$got" ] || fail "the Audit step must set $v in its own env: block"
    # Between "larger than the bound is useless" and "smaller than the bound
    # re-creates the 61s failure": it has to sit just under the step's 300s.
    if ! [ "$got" -ge 240000 ] || ! [ "$got" -le 300000 ]; then
      fail "$v ($got) must sit just under the step's 5-minute timeout-minutes budget"
    fi

    # Workflow- and job-level are where the override bug lives.
    wf=$(yq -r ".env.\"$v\" // \"\"" "$f")
    [ -z "$wf" ] || fail "$v is set at workflow level in check-code.yml ('$wf') - it must be step-level only (esign aebdd28)"
    jobs=$(yq -r "[.jobs | to_entries[] | select(.value.env.\"$v\") | .key] | join(\", \")" "$f")
    [ -z "$jobs" ] || fail "$v is set at job level in check-code.yml (job(s): $jobs) - it must be step-level only (esign aebdd28)"
  done
}

# Forensics on a *green* run are what later turns "it passed that time" into a
# diagnosis, and they cost ~50-100 MB per platform per run at the default
# 7-day retention. The lever for that cost is `retention-days`, not `if:` - an
# edit to `failure()` "to save storage" is the regression this pins.
@test "every forensics step runs under always(), not failure()" {
  select='[.jobs[].steps[]? | select(((.uses // "") | test("actions/forensics$")) or ((.run // "") | test("collect-forensics.sh")))]'
  total=0
  for w in "${WORKFLOWS[@]}"; do
    found=$(yq -r "$select | length" "$w")
    total=$((total + found))
    bad=$(yq -r "$select | map(select(.if != \"always()\")) | length" "$w")
    [ "$bad" -eq 0 ] || fail "$(basename "$w") has $bad forensics step(s) that are not 'if: always()'"
  done
  # check-e2e.yml: collect + upload on iOS, upload on Android. build-web.yml: one upload.
  # Without this the selector could stop matching and the loop would pass by
  # examining nothing.
  [ "$total" -ge 4 ] || fail "the forensics selector matched only $total steps - has the action moved?"
}

@test "every run: step is a single 'bash ...' line" {
  for w in "${WORKFLOWS[@]}"; do
    bad=$(yq -r '[.jobs[].steps[]? | select(has("run")) | .run | select(test("^bash ") | not)] | length' "$w")
    [ "$bad" -eq 0 ]
  done
}

@test "every android-emulator-runner script: is a single 'bash ...' line" {
  for w in "${WORKFLOWS[@]}"; do
    bad=$(yq -r '[.jobs[].steps[]? | select((.uses? // "") | test("android-emulator-runner")) | (.with.script // "") | select((test("^bash ") | not) or ((split("\n") | length) > 1))] | length' "$w")
    [ "$bad" -eq 0 ]
  done
}

@test "every job with a run: step checks out .workflows from the workflow's own repo/sha" {
  for w in "${WORKFLOWS[@]}"; do
    job_names=$(yq -r '.jobs | keys | .[]' "$w")
    for j in $job_names; do
      has_run=$(yq -r "[.jobs.\"$j\".steps[]? | select(has(\"run\"))] | length" "$w")
      if [ "$has_run" -gt 0 ]; then
        workflows_checkout=$(yq -r "[.jobs.\"$j\".steps[]? | select(.uses? == \"actions/checkout@v7\") | select(.with.path? == \".workflows\")] | length" "$w")
        [ "$workflows_checkout" -gt 0 ]
      fi
    done
  done
}

@test "the .workflows checkout uses job.workflow_repository and job.workflow_sha (not github.* or any other form) and sets persist-credentials: false" {
  for w in "${WORKFLOWS[@]}"; do
    job_names=$(yq -r '.jobs | keys | .[]' "$w")
    for j in $job_names; do
      workflows_step_count=$(yq -r "[.jobs.\"$j\".steps[]? | select(.uses? == \"actions/checkout@v7\") | select(.with.path? == \".workflows\")] | length" "$w")
      if [ "$workflows_step_count" -gt 0 ]; then
        repo=$(yq -r "[.jobs.\"$j\".steps[]? | select(.uses? == \"actions/checkout@v7\") | select(.with.path? == \".workflows\")][0].with.repository" "$w")
        ref=$(yq -r "[.jobs.\"$j\".steps[]? | select(.uses? == \"actions/checkout@v7\") | select(.with.path? == \".workflows\")][0].with.ref" "$w")
        # persist-credentials: false is what keeps this repo's checkout token out
        # of the consumer workspace; it is as load-bearing as the ref pinning.
        persist=$(yq -r "[.jobs.\"$j\".steps[]? | select(.uses? == \"actions/checkout@v7\") | select(.with.path? == \".workflows\")][0].with.\"persist-credentials\"" "$w")
        [ "$repo" = '${{ job.workflow_repository }}' ]
        [ "$ref" = '${{ job.workflow_sha }}' ]
        [ "$persist" = "false" ]
      fi
    done
  done
}

# The self-* workflows are excluded from WORKFLOWS above (they are not reusable),
# but two of their expressions are subtle enough to deserve pinning down.

@test "self-smoke's e2e toggles branch on github.event_name so the schedule run is not a no-op" {
  f="$REPO_ROOT/.github/workflows/self-smoke.yml"
  ios=$(yq -r '.jobs.e2e.with.ios' "$f")
  android=$(yq -r '.jobs.e2e.with.android' "$f")
  # `inputs` is null on a schedule trigger, so a bare inputs.* comparison
  # evaluates false for both platforms and the weekly smoke runs no E2E at all.
  [[ "$ios" == *"github.event_name"* ]] || fail "ios toggle does not branch on github.event_name: $ios"
  [[ "$android" == *"github.event_name"* ]] || fail "android toggle does not branch on github.event_name: $android"
  [[ "$ios" != *"inputs.ios == true"* ]] || fail "ios toggle is a bare inputs comparison again: $ios"
  [[ "$android" != *"inputs.android != false"* ]] || fail "android toggle is a bare inputs comparison again: $android"
}

@test "self-release's major-tag job compares release_created to the string 'true'" {
  f="$REPO_ROOT/.github/workflows/self-release.yml"
  cond=$(yq -r '.jobs."major-tag".if' "$f")
  # Job outputs are strings; the literal "false" is truthy in a bare expression.
  [[ "$cond" == *"release_created == 'true'"* ]] || fail "major-tag if does not compare to the string true: $cond"
}

# ---------------------------------------------------------------------------
# publish-badges.yml — the only write path in the family.
# ---------------------------------------------------------------------------

# A badge publish pushes a branch. Nearly every job in this repo is read-only,
# so the write scope is pinned to the exact three jobs that need it - the two
# gh-pages publishers and the one that cuts a GitHub release. Any new one has to
# be added here deliberately.
@test "contents: write is asked for by exactly the three jobs that write" {
  got=""
  for w in "${WORKFLOWS[@]}"; do
    while read -r j; do
      [ -n "$j" ] || continue
      perm=$(yq -r ".jobs.\"$j\".permissions.contents // \"\"" "$w")
      [ "$perm" = "write" ] && got="$got$(basename "$w"):$j "
    done <<<"$(yq -r '.jobs | keys | .[]' "$w")"
  done
  [ "$got" = "pr-closed.yml:badges-cleanup publish-badges.yml:badges publish-github-release.yml:release " ] \
    || fail "jobs asking for contents: write are now: $got"
}

@test "publish-badges.yml keeps contents: read at the top and escalates only on its job" {
  f="$REPO_ROOT/.github/workflows/publish-badges.yml"
  [ "$(yq -r '.permissions.contents' "$f")" = "read" ]
  [ "$(yq -r '.jobs.badges.permissions | keys | join(",")' "$f")" = "contents" ] \
    || fail "the badges job asks for more than contents: $(yq -r '.jobs.badges.permissions' "$f")"
}

# The five exclusions are the whole safety story of a job that runs under
# always(): each one is a case where publishing would be wrong (a cancelled or
# never-run upstream, both suites skipped by their classes) or impossible (a
# fork's token). Two are re-asserted here because the caller cannot be trusted
# to have copied them.
@test "the badges job skips cancelled upstreams, docs-only and both-skipped changes, releases and fork PRs" {
  cond=$(yq -r '.jobs.badges.if' "$REPO_ROOT/.github/workflows/publish-badges.yml")
  for needle in \
    "inputs.unit-result != 'cancelled'" \
    "inputs.e2e-result != 'cancelled'" \
    "inputs.docs-only != 'true'" \
    "!(inputs.unit-result == 'skipped' && inputs.e2e-result == 'skipped')" \
    "github.event_name != 'release'" \
    "github.event.pull_request.head.repo.full_name == github.repository"; do
    grep -qF "$needle" <<<"$cond" || fail "publish-badges.yml's guard no longer contains [$needle]: $cond"
  done
}

# The rule that makes a docs-only or cancelled run harmless: the coverage
# artifact is fetched only for a green Unit. A failed Unit renders the red
# placeholder from no input at all, and a skipped one renders no coverage badge,
# so the published one survives.
@test "publish-badges.yml downloads coverage only when the unit job succeeded" {
  f="$REPO_ROOT/.github/workflows/publish-badges.yml"
  cond=$(yq -r '[.jobs.badges.steps[] | select((.uses // "") | test("download-artifact"))][0].if' "$f")
  [ "$cond" = '${{ inputs.unit-result == '"'"'success'"'"' }}' ] \
    || fail "the coverage download is gated on '$cond'"
}

@test "the badges job delegates rendering to the consumer, and only publishing is ours" {
  f="$REPO_ROOT/.github/workflows/publish-badges.yml"
  render=$(yq -r '[.jobs.badges.steps[] | select(.name == "Render badges")][0]' "$f")
  contains "$render" 'run-script.sh' \
    || fail "the render step no longer goes through run-script.sh: $render"
  [ "$(yq -r '.on.workflow_call.inputs."render-script".default' "$f")" = "badges:render" ]
  n=$(yq -r '[.jobs.badges.steps[] | select((.run // "") | test("publish-badges.sh"))] | length' "$f")
  [ "$n" -eq 1 ] || fail "publish-badges.yml runs publish-badges.sh $n times"
}

# A suite skipped by its class must not overwrite its published status badge,
# and publish-badges.sh can only tell if it is handed both results.
@test "publish-badges.yml hands publish-badges.sh both suite results" {
  f="$REPO_ROOT/.github/workflows/publish-badges.yml"
  env=$(yq -r '[.jobs.badges.steps[] | select(.name == "Publish to gh-pages")][0].env' "$f")
  contains "$env" 'BADGE_UNIT: ${{ inputs.unit-result }}' || fail "no BADGE_UNIT on the publish step: $env"
  contains "$env" 'BADGE_E2E: ${{ inputs.e2e-result }}' || fail "no BADGE_E2E on the publish step: $env"
}

# The caller half: without always() the job never runs on a red Unit, which is
# precisely the run whose badge matters most.
@test "the fixture caller runs badges under always() and passes both job results" {
  f="$FIXTURES/consumer-min/.github/workflows/ci.yml"
  cond=$(yq -r '.jobs.badges.if' "$f")
  contains "$cond" "always()" || fail "the fixture's badges job is not under always(): $cond"
  contains "$cond" "docs-only != 'true'" || fail "no docs-only guard on the caller: $cond"
  [ "$(yq -r '.jobs.badges.with."unit-result"' "$f")" = '${{ needs.unit.result }}' ]
  [ "$(yq -r '.jobs.badges.with."e2e-result"' "$f")" = '${{ needs.e2e.result }}' ]
  [ "$(yq -r '.jobs.badges.permissions.contents' "$f")" = "write" ]
}

# --- values a workflow advertises as configurable must not be baked in --------

@test "every native cache key interpolates native-cache-version, none bakes in a literal" {
  command -v yq >/dev/null || skip "yq not installed"
  # The input's own description, build-ios.yml's, and docs/cache-keys.md all
  # promise that bumping this invalidates *every* native cache. The Android
  # system-image and AVD keys baked in `v1`, so someone chasing a stale-AVD
  # failure bumped the input, those two caches stayed warm, and the failure
  # outlived the fix.
  for w in "${WORKFLOWS[@]}"; do
    keys=$(yq -r '[.jobs[].steps[]? | select((.uses? // "") | test("actions/cache")) | .with.key // ""] | .[]' "$w")
    while read -r k; do
      [ -n "$k" ] || continue
      case "$k" in
        *'-v'[0-9]*)
          contains "$k" 'inputs.native-cache-version' \
            || fail "$(basename "$w") bakes a cache version into a key instead of using the input: $k"
          ;;
      esac
    done <<<"$keys"
  done
}

@test "the Gradle cache write branch comes from an input, not a hardcoded main" {
  command -v yq >/dev/null || skip "yq not installed"
  # A consumer whose default branch is `master` never wrote the cache at all and
  # paid a cold Gradle on every run, including on its own default branch.
  for w in check-e2e build-android; do
    f="$REPO_ROOT/.github/workflows/$w.yml"
    [ "$(yq -r '.on.workflow_call.inputs | has("default-branch")' "$f")" = "true" ] \
      || fail "$w.yml does not declare a default-branch input"
    [ "$(yq -r '.on.workflow_call.inputs."default-branch".default' "$f")" = "refs/heads/main" ] \
      || fail "$w.yml's default-branch default changed"
    ! grep -qF "github.ref != 'refs/heads/main'" "$f" \
      || fail "$w.yml still compares github.ref against a hardcoded refs/heads/main"
    grep -qF 'github.ref != inputs.default-branch' "$f" \
      || fail "$w.yml does not compare github.ref against the input"
  done
}

@test "the iOS and Android artifact uploads in check-e2e.yml guard on the build the same way" {
  command -v yq >/dev/null || skip "yq not installed"
  # The Android upload ran under always() with if-no-files-found: error, so a
  # failed build produced a second red step - a missing APK - stacked on top of
  # the real error. The iOS twin already had the right condition.
  f="$REPO_ROOT/.github/workflows/check-e2e.yml"
  expected="\${{ !cancelled() && steps.build.conclusion != 'failure' }}"
  for name in "Upload iOS app" "Upload APK"; do
    cond=$(yq -r ".jobs[].steps[]? | select(.name == \"$name\") | .if // \"\"" "$f")
    [ "$cond" = "$expected" ] \
      || fail "'$name' guards on '$cond', expected '$expected'"
  done
  # The condition is meaningless without the id it names.
  ids=$(yq -r '[.jobs[].steps[]? | select(.id == "build")] | length' "$f")
  [ "$ids" -ge 2 ] || fail "check-e2e.yml has $ids steps with id: build, expected one per platform"
}

# Two gates in check-code.yml cost minutes rather than seconds: check-prebuild
# prebuilds both platforms, and check:bundle-secrets runs a web export. They are
# opt-in so a consumer decides where that wall clock is worth paying. Flipping
# either default to true silently adds those minutes to every PR of every
# consumer of this family, which is the kind of change nobody notices in review.
@test "the expensive checks stay opt-in" {
  command -v yq >/dev/null || skip "yq not installed"
  f="$REPO_ROOT/.github/workflows/check-code.yml"
  for i in prebuild-check bundle-secrets; do
    [ "$(yq -r ".on.workflow_call.inputs.\"$i\" | has(\"default\")" "$f")" = "true" ] \
      || fail "check-code.yml has no $i input"
    [ "$(yq -r ".on.workflow_call.inputs.\"$i\".default" "$f")" = "false" ] \
      || fail "$i defaults to $(yq -r ".on.workflow_call.inputs.\"$i\".default" "$f"), which adds minutes to every consumer's PR"
  done
  # The cheap one is on by default: it ran in no CI job at all before, while
  # `make check-deps` ran it locally.
  [ "$(yq -r '.on.workflow_call.inputs.licenses.default' "$f")" = "true" ] \
    || fail "the licenses check is not on by default"
}

# A gate whose step can hang without the job cap being a useful diagnosis.
@test "the two expensive checks carry their own step timeout" {
  command -v yq >/dev/null || skip "yq not installed"
  f="$REPO_ROOT/.github/workflows/check-code.yml"
  for name in "Prebuild check" "Bundle secrets"; do
    t=$(yq -r ".jobs[].steps[]? | select(.name == \"$name\") | .\"timeout-minutes\" // \"\"" "$f")
    [ -n "$t" ] || fail "the '$name' step has no timeout-minutes"
  done
}

# --- a build that does not need a store account ------------------------------
#
# Both build lanes used to require store credentials before they compiled
# anything, so a consumer with none had a red pipeline from its first push -
# on a template, that lands on every app created from it. The lanes already
# supported an unsigned mode; no workflow could reach it.

@test "the platform builds can run without signing credentials" {
  command -v yq >/dev/null || skip "yq not installed"
  for pair in "build-ios|ios-signing" "build-android|android-signing"; do
    w="${pair%%|*}"
    input="${pair##*|}"
    f="$REPO_ROOT/.github/workflows/$w.yml"
    [ -f "$f" ] || continue
    [ "$(yq -r ".on.workflow_call.inputs.\"$input\" | has(\"default\")" "$f")" = "true" ] \
      || fail "$w.yml has no $input input"
    # Default true: an existing consumer that says nothing keeps signing.
    [ "$(yq -r ".on.workflow_call.inputs.\"$input\".default" "$f")" = "true" ] \
      || fail "$w.yml's $input does not default to true, which changes behaviour for consumers that never asked"
    grep -qF "skip_signing:true" "$f" \
      || fail "$w.yml declares $input but never passes skip_signing to the lane"
  done
}

@test "an unsigned iOS build does not try to upload an .ipa it never packaged" {
  command -v yq >/dev/null || skip "yq not installed"
  f="$REPO_ROOT/.github/workflows/build-ios.yml"
  cond=$(yq -r '.jobs[].steps[] | select(.name == "Upload ios-ipa") | .if // ""' "$f")
  contains "$cond" "inputs.ios-signing" \
    || fail "the ios-ipa upload is not gated on ios-signing, and its if-no-files-found is error: $cond"
}

# --- a run should read as sentences, not job ids ------------------------------
#
# GitHub falls back to the job *id* when a job has no `name:`, and a reusable
# call renders as `<caller job> / <called job>`. With neither side named, a
# consumer's run graph read `checks / code` where esign reads `Checks / Code` -
# the machinery leaking into the UI. The called half is this repo's to fix.
#
# The companion rule for steps ("every step has a name") has existed since the
# beginning; jobs were simply never covered.
@test "every job in every workflow has a name" {
  command -v yq >/dev/null || skip "yq not installed"
  for w in "$REPO_ROOT"/.github/workflows/*.yml; do
    unnamed=$(yq -r '.jobs | to_entries[] | select((.value.name // "") == "") | .key' "$w")
    [ -z "$unnamed" ] \
      || fail "$(basename "$w") has jobs with no name, so they show as raw ids: $(tr '\n' ' ' <<<"$unnamed")"
  done
}

# One workflow serves upload, promote, rollout and halt, and the *caller's* job
# name says which ("Upload iOS", "Halt Android"). This job's name is therefore
# fixed, and fastlane's own vocabulary stays out of every display name: a
# reader of a run graph should not need to know what a lane is.
@test "the store job has a fixed name and no display name says lane" {
  command -v yq >/dev/null || skip "yq not installed"
  n=$(yq -r '.jobs.lane.name' "$REPO_ROOT/.github/workflows/publish-store.yml")
  [ "$n" = "Store" ] || fail "publish-store's job is named '$n', expected 'Store'"
  for w in "$REPO_ROOT"/.github/workflows/*.yml; do
    names=$(yq -r '[.name] + [.jobs[].name] | .[] | select(. != null)' "$w")
    if grep -qi 'lane' <<<"$names"; then
      fail "$(basename "$w") puts fastlane vocabulary in a display name: $(grep -i lane <<<"$names" | tr '\n' ' ')"
    fi
  done
}

# ---------------------------------------------------------------------------
# check-security.yml - the second workflow in the family that writes to code
# scanning, and the first whose job graph is decided by a file in the consumer.
# ---------------------------------------------------------------------------

# security-events: write is the whole reason a caller has to grant anything at
# all here, and a called workflow can only ever narrow the caller's token - so
# an escalation that spreads to a scanner job would make every caller grant more
# than the one job that needs it. Naming `permissions:` also resets the unnamed
# scopes to none, which is why contents: read is re-declared rather than assumed.
@test "check-security.yml escalates permissions only on its verdict job" {
  command -v yq >/dev/null || skip "yq not installed"
  f="$REPO_ROOT/.github/workflows/check-security.yml"
  [ "$(yq -r '.jobs.verdict.permissions.contents' "$f")" = "read" ] \
    || fail "verdict does not re-declare contents: read, so its own checkouts would lose it"
  [ "$(yq -r '.jobs.verdict.permissions.actions' "$f")" = "read" ] \
    || fail "verdict does not declare actions: read, which the SARIF upload needs"
  [ "$(yq -r '.jobs.verdict.permissions."security-events"' "$f")" = "write" ] \
    || fail "verdict does not declare security-events: write"
  [ "$(yq -r '.jobs.verdict.permissions | keys | length' "$f")" -eq 3 ] \
    || fail "verdict asks for more than three scopes: $(yq -r '.jobs.verdict.permissions' "$f")"
  escalating="$(yq -r '[.jobs | to_entries[] | select(.value.permissions) | .key] | join(",")' "$f")"
  [ "$escalating" = "verdict" ] \
    || fail "jobs declaring their own permissions in check-security.yml: $escalating - only verdict may"
}

# A job-level `if:` cannot read a file, so the consumer's security-policy.json
# reaches the graph only through the config job's outputs. The effective setting
# is the AND of the caller's input and the consumer's policy: a caller may
# narrow (a pull request has no binaries to scan) and may never widen.
SECURITY_JOBS="deps code policy sbom bundle mobile binaries review openant"

@test "check-security.yml's scanner jobs are the AND of the caller's input and the consumer's policy" {
  command -v yq >/dev/null || skip "yq not installed"
  f="$REPO_ROOT/.github/workflows/check-security.yml"
  for job in $SECURITY_JOBS; do
    out="$(yq -r ".jobs.config.outputs.\"$job\"" "$f")"
    [ "$out" = "\${{ steps.resolve.outputs.$job }}" ] \
      || fail "the config job does not publish the consumer's setting for $job: $out"
    cond="$(yq -r ".jobs.\"$job\".if" "$f")"
    contains "$cond" "inputs.$job" || fail "the $job job ignores its own input: $cond"
    contains "$cond" "needs.config.outputs.$job == 'true'" \
      || fail "the $job job ignores the consumer's policy: $cond"
    contains "$cond" "needs.config.outputs.enabled == 'true'" \
      || fail "the $job job ignores the master switch: $cond"
    needs="$(yq -r ".jobs.\"$job\".needs" "$f")"
    [ "$needs" = "config" ] || fail "the $job job needs '$needs', expected config"
  done
  # !cancelled(), not success(): a scanner that was switched off, or one that
  # crashed, must still reach the verdict. A crash keeps the run red on its own
  # job; the verdict's business is to say what was and was not scanned.
  vcond="$(yq -r '.jobs.verdict.if' "$f")"
  contains "$vcond" '!cancelled()' || fail "the verdict never runs after a skipped or failed scanner: $vcond"
  contains "$vcond" "needs.config.outputs.enabled == 'true'" \
    || fail "the verdict ignores the master switch: $vcond"
  vneeds="$(yq -r '.jobs.verdict.needs | join(",")' "$f")"
  [ "$vneeds" = "config,$(tr ' ' ',' <<<"$SECURITY_JOBS")" ] || fail "verdict needs '$vneeds'"
  # The download is guarded on any scanner having succeeded: download-artifact
  # fails when its pattern matches nothing. A job missing from the guard would
  # leave a run where only that job reported with nothing downloaded.
  guard="$(yq -r '.jobs.verdict.steps[] | select(.name == "Download scanner SARIF") | .if' "$f")"
  for job in $SECURITY_JOBS; do
    contains "$guard" "needs.$job.result == 'success'" || fail "the download guard forgets $job: $guard"
  done
}

# The consumer owns every scanner, the merge and the verdict. Shared owns the
# job graph and nothing else. A fallback runner here would serve only a consumer
# not generated from the template, and no such consumer exists - "a baseline
# with one consumer is not a baseline".
@test "check-security.yml runs the consumer's scripts and shares no runner of its own" {
  command -v yq >/dev/null || skip "yq not installed"
  f="$REPO_ROOT/.github/workflows/check-security.yml"
  for job in $SECURITY_JOBS; do
    line="$(yq -r ".jobs.\"$job\".steps[] | select(.id == \"scan\") | .run" "$f")"
    contains "$line" 'scripts/security/run-job.sh' \
      || fail "the $job job does not go through run-job.sh, which is what fails loudly on a missing runner: $line"
  done
  ! ls "$REPO_ROOT"/scripts/security/*.mjs >/dev/null 2>&1 \
    || fail "shared-workflows has grown its own security modules; the resolver, the scanners and the merge live in the consumer"
  vline="$(yq -r '.jobs.verdict.steps[] | select(.id == "verdict") | .run' "$f")"
  contains "$vline" 'scripts/security/verdict.sh' || fail "the verdict step does not go through verdict.sh: $vline"
}

# A fork's GITHUB_TOKEN is read-only whatever a permissions block asks for, so
# upload-sarif cannot work there. The gate is not weaker on a fork - the verdict
# still applies the threshold - but the reporting destination is missing, and
# that has to be said rather than left as an empty Security tab.
@test "check-security.yml uploads SARIF only when it can, and says so when it cannot" {
  command -v yq >/dev/null || skip "yq not installed"
  f="$REPO_ROOT/.github/workflows/check-security.yml"
  upload="$(yq -r '.jobs.verdict.steps[] | select((.uses // "") | test("upload-sarif")) | .if' "$f")"
  [ -n "$upload" ] || fail "check-security.yml has no upload-sarif step"
  contains "$upload" "github.event.pull_request.head.repo.full_name == github.repository" \
    || fail "the upload is not guarded against a fork pull request: $upload"
  contains "$upload" "github.event_name != 'pull_request'" \
    || fail "the fork guard would also block a push and a dispatch, where both operands are empty: $upload"
  contains "$upload" 'hashFiles' \
    || fail "the upload is not guarded on a SARIF actually existing, and upload-sarif dies on an empty directory: $upload"
  notes="$(yq -r '[.jobs.verdict.steps[] | select((.run // "") | test("sarif-upload-skipped.sh"))] | length' "$f")"
  [ "$notes" -eq 2 ] \
    || fail "expected two steps explaining a missing upload (a fork, and sarif-upload: false), found $notes"
}

# One artifact per scanner, each carrying a file named after its own job. The
# release's build-info taught this family what merge-multiple does to two
# artifacts carrying the same filename: the winner is a coin toss. Here the
# filenames differ by construction, which is the only reason merge-multiple is
# safe - so both halves are pinned.
@test "each scanner's SARIF travels under its own artifact name and its own filename" {
  command -v yq >/dev/null || skip "yq not installed"
  f="$REPO_ROOT/.github/workflows/check-security.yml"
  names="$(yq -r '[.jobs[].steps[]? | select((.uses // "") | test("upload-artifact")) | .with.name | select(test("^security-sarif-"))] | join("\n")' "$f")"
  [ "$(grep -c . <<<"$names")" -eq 9 ] || fail "expected nine SARIF uploads, got: $names"
  [ "$(sort -u <<<"$names" | grep -c .)" -eq 9 ] || fail "two scanner jobs upload under one artifact name: $names"
  paths="$(yq -r '[.jobs[].steps[]? | select((.uses // "") | test("upload-artifact")) | .with.path] | join("\n")' "$f")"
  for job in $SECURITY_JOBS; do
    contains "$paths" "/.security/$job.sarif" || fail "no upload of $job.sarif: $paths"
  done
  # The bill of materials is for people, not for the verdict: its own artifact,
  # kept long enough to answer a later advisory, and outside the security-sarif-*
  # pattern the verdict downloads.
  [ "$(yq -r '.jobs.sbom.steps[] | select(.with.name == "security-sbom") | .with.path' "$f")" \
    = '${{ inputs.working-directory }}/.security/sbom.cdx.json' ] || fail "the sbom job does not keep sbom.cdx.json"
  [ "$(yq -r '.jobs.sbom.steps[] | select(.with.name == "security-sbom") | .with."retention-days"' "$f")" -ge 90 ] \
    || fail "the bill of materials is not kept for at least 90 days"
  pattern="$(yq -r '.jobs.verdict.steps[] | select(.name == "Download scanner SARIF") | .with.pattern' "$f")"
  [ "$pattern" = 'security-sarif-*' ] || fail "the verdict downloads '$pattern', which would pull in the bill of materials" 
  merge="$(yq -r '[.jobs.verdict.steps[] | select((.uses // "") | test("download-artifact"))][0].with."merge-multiple"' "$f")"
  [ "$merge" = "true" ] || fail "the verdict does not merge the scanner artifacts into one directory: $merge"
  # These jobs read source, a lockfile and a workspace file. None of them reads
  # node_modules, and a pnpm install in each is minutes added to every consumer's
  # pull request for nothing. Quoted 'false' on purpose: unquoted, yq returns a
  # boolean and this assertion fails on correct YAML.
  setups="$(yq -r '[.jobs[].steps[]? | select((.uses // "") | test("workflows/.github/actions/setup"))] | length' "$f")"
  [ "$setups" -eq 11 ] || fail "expected one Setup step per job, found $setups"
  # Only an expo export (bundle) and an expo prebuild (mobile) need the install.
  installing=""
  for job in $(yq -r '.jobs | keys | .[]' "$f"); do
    n="$(yq -r "[.jobs.\"$job\".steps[]? | select((.uses // \"\") | test(\"workflows/.github/actions/setup\")) | select(.with.install != \"false\")] | length" "$f")"
    [ "$n" -eq 0 ] || installing="$installing${installing:+,}$job"
  done
  [ "$installing" = "bundle,mobile" ] || fail "jobs running pnpm install: '$installing', expected bundle,mobile"
}

# The provider keys are the only secrets here besides the consumer token, and
# they reach exactly the two steps that call a model. A key on a job's env, or on
# any other step, is a key every script in that job - the setup action, the
# artifact upload - can read.
@test "check-security.yml hands the LLM keys to the review and OpenAnt scan steps and nowhere else" {
  command -v yq >/dev/null || skip "yq not installed"
  f="$REPO_ROOT/.github/workflows/check-security.yml"
  for key in OPENAI_API_KEY ANTHROPIC_API_KEY; do
    [ "$(yq -r ".on.workflow_call.secrets.$key.required" "$f")" = "false" ] || fail "$key is not an optional secret"
    where="$(yq -r "[.jobs | to_entries[] | .key as \$job | .value.steps[]? | select(.env.$key) | \$job + \":\" + (.id // .name)] | join(\",\")" "$f")"
    [ "$where" = "review:scan,openant:scan" ] || fail "$key reaches '$where', expected review:scan,openant:scan"
    jobwide="$(yq -r "[.jobs[] | select(.env.$key)] | length" "$f")"
    [ "$jobwide" -eq 0 ] || fail "$key is set on a whole job's env"
  done
}

# The binaries are the release's own assets, fetched before the consumer's
# runner looks for them. Order matters: a scan before the download would find
# no binaries and report skipped on every production dispatch.
@test "check-security.yml fetches the release binaries, by tag, before the binaries scan" {
  command -v yq >/dev/null || skip "yq not installed"
  f="$REPO_ROOT/.github/workflows/check-security.yml"
  names="$(yq -r '.jobs.binaries.steps[].name' "$f")"
  fetch_at="$(grep -n 'Download the release binaries' <<<"$names" | cut -d: -f1)"
  scan_at="$(grep -n 'Check the release binaries' <<<"$names" | cut -d: -f1)"
  [ -n "$fetch_at" ] && [ -n "$scan_at" ] || fail "binaries job steps: $names"
  [ "$fetch_at" -lt "$scan_at" ] || fail "the scan runs before the download"
  run_line="$(yq -r '.jobs.binaries.steps[] | select(.name == "Download the release binaries") | .run' "$f")"
  contains "$run_line" 'scripts/security/binaries-fetch.sh' || fail "the download does not go through binaries-fetch.sh: $run_line"
  tag="$(yq -r '.jobs.binaries.steps[] | select(.name == "Download the release binaries") | .env.RELEASE_TAG' "$f")"
  [ "$tag" = '${{ inputs.release-tag }}' ] || fail "the download is not keyed on the release-tag input: $tag"
  [ "$(yq -r '.on.workflow_call.inputs."release-tag".default' "$f")" = "" ] || fail "release-tag has a default"
}

# The review diffs against a base commit or the last release tag, and neither
# exists in a shallow clone.
@test "check-security.yml's review checks out full history and knows its range" {
  command -v yq >/dev/null || skip "yq not installed"
  f="$REPO_ROOT/.github/workflows/check-security.yml"
  depth="$(yq -r '.jobs.review.steps[] | select(.name == "Checkout consumer") | .with."fetch-depth"' "$f")"
  [ "$depth" = "0" ] || fail "the review's checkout is shallow (fetch-depth: $depth)"
  base="$(yq -r '.jobs.review.steps[] | select(.id == "scan") | .env.SECURITY_REVIEW_BASE' "$f")"
  [ "$base" = '${{ github.event.pull_request.base.sha }}' ] || fail "SECURITY_REVIEW_BASE is '$base'"
  full="$(yq -r '.jobs.review.steps[] | select(.id == "scan") | .env.SECURITY_REVIEW_FULL_RANGE' "$f")"
  [ "$full" = '${{ inputs.review-full-range }}' ] || fail "SECURITY_REVIEW_FULL_RANGE is '$full'"
}

# A SECURITY_* twin passed through build-env changes what config.mjs resolves,
# what a runner does and what the verdict applies - so every job publishes it,
# and before the setup action and any consumer script run.
@test "every check-security.yml job publishes build-env before its Setup step" {
  command -v yq >/dev/null || skip "yq not installed"
  f="$REPO_ROOT/.github/workflows/check-security.yml"
  for job in config $SECURITY_JOBS verdict; do
    names="$(yq -r ".jobs.\"$job\".steps[].name" "$f")"
    publish_at="$(grep -n '^Publish build-env$' <<<"$names" | cut -d: -f1)"
    setup_at="$(grep -n '^Setup$' <<<"$names" | cut -d: -f1)"
    [ -n "$publish_at" ] || fail "the $job job never publishes build-env"
    [ "$publish_at" -lt "$setup_at" ] || fail "the $job job publishes build-env after Setup"
  done
}

# Each scanner input is off unless a tier turns it on - except the three that
# existed before the release tier did, whose default stays what callers have
# relied on since.
@test "check-security.yml's release-tier inputs default to off" {
  command -v yq >/dev/null || skip "yq not installed"
  f="$REPO_ROOT/.github/workflows/check-security.yml"
  for input in deps code policy; do
    [ "$(yq -r ".on.workflow_call.inputs.$input.default" "$f")" = "true" ] || fail "$input no longer defaults to true"
  done
  for input in sbom bundle mobile binaries review openant review-full-range; do
    [ "$(yq -r ".on.workflow_call.inputs.\"$input\".default" "$f")" = "false" ] || fail "$input does not default to false"
    [ "$(yq -r ".on.workflow_call.inputs.\"$input\".type" "$f")" = "boolean" ] || fail "$input is not a boolean switch"
  done
}

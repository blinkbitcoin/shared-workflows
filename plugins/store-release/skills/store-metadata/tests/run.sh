#!/bin/bash
set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$TESTS_DIR/.." && pwd)"
FIXTURES_DIR="$TESTS_DIR/fixtures"

SCAFFOLD="$SKILL_DIR/scripts/scaffold.sh"
CHECK_METADATA="$SKILL_DIR/scripts/check-metadata.sh"
PLACE_IMAGES="$SKILL_DIR/scripts/place-images.sh"
AGE_RATING="$SKILL_DIR/scripts/age-rating.sh"
SYNC="$SKILL_DIR/scripts/sync.sh"
SKILL_MD="$SKILL_DIR/SKILL.md"

# Some checks compare the skill's lists with what they are copied from: an app's
# lanes and shipped age-rating file, and the fastlane gem. They run when those are
# found and are skipped, by name, when not, so the suite is the same one wherever
# the skill sits:
#   APP_REPO_ROOT    an app checkout: its fastlane/lanes/shared.rb and
#                    fastlane/metadata/ios/app_rating_config.json, and its
#                    vendor/bundle fastlane gem
#   FASTLANE_GEM_DIR the fastlane gem's directory, if it is somewhere else
# Inside shared-workflows the shipped lanes and the gems `make test-fastlane`
# installs are found without either.
APP_REPO_ROOT="${APP_REPO_ROOT:-}"
HOME_REPO="$(cd "$SKILL_DIR/../../../.." 2>/dev/null && pwd)"
first_existing() {
  local candidate
  for candidate in "$@"; do
    if [ -e "$candidate" ]; then
      printf '%s' "$candidate"
      return 0
    fi
  done
  return 0
}
SHARED_RB="$(first_existing ${APP_REPO_ROOT:+"$APP_REPO_ROOT/fastlane/lanes/shared.rb"} "$HOME_REPO/packages/app-tooling/fastlane/lanes/shared.rb")"
if [ -z "${FASTLANE_GEM_DIR:-}" ]; then
  # shellcheck disable=SC2086 # the globs are meant to expand
  FASTLANE_GEM_DIR="$(first_existing ${APP_REPO_ROOT:+$APP_REPO_ROOT/vendor/bundle/ruby/*/gems/fastlane-*} $HOME_REPO/.gems/ruby/*/gems/fastlane-*)"
fi
AGE_RATING_GEM="$FASTLANE_GEM_DIR/spaceship/lib/spaceship/connect_api/models/age_rating_declaration.rb"
APP_CATEGORY_GEM="$FASTLANE_GEM_DIR/spaceship/lib/spaceship/connect_api/models/app_category.rb"
APP_SCREENSHOT_GEM="$FASTLANE_GEM_DIR/deliver/lib/deliver/app_screenshot.rb"
SHIPPED_RATING="${APP_REPO_ROOT:+$APP_REPO_ROOT/fastlane/metadata/ios/app_rating_config.json}"

HAVE_RUBY=0
command -v ruby >/dev/null 2>&1 && HAVE_RUBY=1

WORK="$(mktemp -d "${TMPDIR:-/tmp}/store-metadata-tests.XXXXXX")"
PASS=0
FAIL=0
SKIP=0
trap 'rm -rf "$WORK"' EXIT

ok() {
  PASS=$((PASS + 1))
  printf '  \033[32mPASS\033[0m %s\n' "$1"
}
bad() {
  FAIL=$((FAIL + 1))
  printf '  \033[31mFAIL\033[0m %s\n       %s\n' "$1" "$2"
}
skip() {
  SKIP=$((SKIP + 1))
  printf '  \033[33mSKIP\033[0m %s\n' "$1"
}
check() {
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected '$2', got '$3'"; fi
}
check_contains() {
  if printf '%s' "$3" | grep -qF -- "$2"; then ok "$1"; else bad "$1" "expected output to contain '$2', got: $3"; fi
}
check_not_contains() {
  if printf '%s' "$3" | grep -qF -- "$2"; then bad "$1" "expected output NOT to contain '$2', got: $3"; else ok "$1"; fi
}

FAKEBIN="$WORK/fakebin"
mkdir -p "$FAKEBIN"

# A fake `bundle` that records its argv and the two env vars sync.sh/scaffold.sh
# care about, and honours FAKE_FASTLANE_EXIT.
cat >"$FAKEBIN/bundle" <<'FAKE_BUNDLE'
{
  printf 'ARGV: %s\n' "$*"
  printf 'DRY_RUN=%s\n' "${DRY_RUN:-}"
  printf 'STORE_METADATA_SYNC_ENABLED=%s\n' "${STORE_METADATA_SYNC_ENABLED:-}"
  printf 'CWD=%s\n' "$(pwd -P)"
} >>"${BUNDLE_LOG:?BUNDLE_LOG not set}"
exit "${FAKE_FASTLANE_EXIT:-0}"
FAKE_BUNDLE
chmod +x "$FAKEBIN/bundle"
export PATH="$FAKEBIN:$PATH"

BUNDLE_LOG="$WORK/bundle.log"
: >"$BUNDLE_LOG"
export BUNDLE_LOG

# --- image fixtures ----------------------------------------------------------
HAVE_IMAGE_TOOL=0
if command -v sips >/dev/null 2>&1 || command -v magick >/dev/null 2>&1 || command -v identify >/dev/null 2>&1; then
  HAVE_IMAGE_TOOL=1
fi

make_png() {
  # make_png <out> <width> <height>
  local out="$1" w="$2" h="$3"
  if command -v sips >/dev/null 2>&1; then
    # Start from a 1x1 PNG (smallest valid seed) and resize/pad with sips.
    local seed="$WORK/seed.png"
    if [ ! -f "$seed" ]; then
      node -e '
        const fs = require("fs");
        const b64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=";
        fs.writeFileSync(process.argv[1], Buffer.from(b64, "base64"));
      ' "$seed"
    fi
    cp "$seed" "$out"
    sips -z "$h" "$w" "$out" >/dev/null 2>&1
  elif command -v magick >/dev/null 2>&1; then
    magick -size "${w}x${h}" xc:white "$out" >/dev/null 2>&1
  fi
}

# --- scaffold.sh ---------------------------------------------------------
echo "== scaffold.sh"

SCAFFOLD_WORK="$WORK/scaffold-empty"
mkdir -p "$SCAFFOLD_WORK/fastlane"
AFTER_LIST="$WORK/after.list"

out=$(REPO_ROOT="$SCAFFOLD_WORK" "$SCAFFOLD" 2>&1)
rc=$?
check "scaffold.sh on an empty fastlane/ exits 0" "0" "$rc"

EXPECTED_PATHS="$WORK/expected-scaffold-paths.txt"
cat >"$EXPECTED_PATHS" <<'EOF'
fastlane/metadata/ios/copyright.txt
fastlane/metadata/ios/en-US/name.txt
fastlane/metadata/ios/en-US/subtitle.txt
fastlane/metadata/ios/en-US/description.txt
fastlane/metadata/ios/en-US/keywords.txt
fastlane/metadata/ios/en-US/promotional_text.txt
fastlane/metadata/ios/en-US/release_notes.txt
fastlane/metadata/ios/en-US/support_url.txt
fastlane/metadata/ios/en-US/marketing_url.txt
fastlane/metadata/ios/en-US/privacy_url.txt
fastlane/metadata/ios/review_information/first_name.txt
fastlane/metadata/ios/review_information/last_name.txt
fastlane/metadata/ios/review_information/phone_number.txt
fastlane/metadata/ios/review_information/email_address.txt
fastlane/metadata/ios/review_information/demo_user.txt
fastlane/metadata/ios/review_information/demo_password.txt
fastlane/metadata/ios/review_information/notes.txt
fastlane/screenshots/en-US/.gitkeep
fastlane/metadata/android/en-US/title.txt
fastlane/metadata/android/en-US/short_description.txt
fastlane/metadata/android/en-US/full_description.txt
fastlane/metadata/android/en-US/video.txt
fastlane/metadata/android/en-US/changelogs/default.txt
fastlane/metadata/android/en-US/images/.gitkeep
fastlane/metadata/android/en-US/images/phoneScreenshots/.gitkeep
fastlane/metadata/android/en-US/images/sevenInchScreenshots/.gitkeep
fastlane/metadata/android/en-US/images/tenInchScreenshots/.gitkeep
EOF
sort "$EXPECTED_PATHS" >"$EXPECTED_PATHS.sorted"

(cd "$SCAFFOLD_WORK" && find fastlane -type f | sort) >"$AFTER_LIST"
check "scaffold.sh creates exactly the expected path set and nothing else" "" "$(diff "$EXPECTED_PATHS.sorted" "$AFTER_LIST")"

# re-running changes nothing
REPO_ROOT="$SCAFFOLD_WORK" "$SCAFFOLD" >/dev/null 2>&1
(cd "$SCAFFOLD_WORK" && find fastlane -type f | sort) >"$AFTER_LIST"
check "re-running scaffold.sh creates no new/removed files" "" "$(diff "$EXPECTED_PATHS.sorted" "$AFTER_LIST")"

# --from-console does not clobber a hand-written description
FROM_CONSOLE_WORK="$WORK/scaffold-from-console"
mkdir -p "$FROM_CONSOLE_WORK/fastlane"
REPO_ROOT="$FROM_CONSOLE_WORK" "$SCAFFOLD" >/dev/null 2>&1
printf 'My hand-written description.\n' >"$FROM_CONSOLE_WORK/fastlane/metadata/ios/en-US/description.txt"
: >"$BUNDLE_LOG"
out=$(REPO_ROOT="$FROM_CONSOLE_WORK" "$SCAFFOLD" --from-console 2>&1)
rc=$?
check "scaffold.sh --from-console exits 0" "0" "$rc"
check "scaffold.sh --from-console does not clobber a hand-written file" "My hand-written description." "$(cat "$FROM_CONSOLE_WORK/fastlane/metadata/ios/en-US/description.txt")"
check_contains "scaffold.sh --from-console runs the pull_metadata lanes" "pull_metadata" "$(cat "$BUNDLE_LOG")"

# exit 2 with no fastlane/
NOT_A_REPO="$WORK/not-a-repo"
mkdir -p "$NOT_A_REPO"
REPO_ROOT="$NOT_A_REPO" "$SCAFFOLD" >/dev/null 2>&1
check "scaffold.sh exits 2 with no fastlane/ directory" "2" "$?"

# category files are not scaffolded
check "scaffold.sh never creates primary_category.txt" "no" "$([ -f "$SCAFFOLD_WORK/fastlane/metadata/ios/primary_category.txt" ] && echo yes || echo no)"

# C1: Android images are scaffolded per-locale, never as a top-level images/
check "scaffold.sh's Android image paths sit under the locale directory" "yes" \
  "$([ -d "$SCAFFOLD_WORK/fastlane/metadata/android/en-US/images/phoneScreenshots" ] && echo yes || echo no)"
check "scaffold.sh never creates a top-level metadata/android/images/" "no" \
  "$([ -d "$SCAFFOLD_WORK/fastlane/metadata/android/images" ] && echo yes || echo no)"

# I4: --force never blanks a file; it only permits scaffolding onto a tree
# that already has content.
FORCE_SCAFFOLD_WORK="$WORK/scaffold-force"
mkdir -p "$FORCE_SCAFFOLD_WORK/fastlane"
REPO_ROOT="$FORCE_SCAFFOLD_WORK" "$SCAFFOLD" >/dev/null 2>&1
printf 'My hand-written description.\n' >"$FORCE_SCAFFOLD_WORK/fastlane/metadata/ios/en-US/description.txt"
REPO_ROOT="$FORCE_SCAFFOLD_WORK" "$SCAFFOLD" >/dev/null 2>&1
check "scaffold.sh without --force refuses a tree that already has content" "2" "$?"
out=$(REPO_ROOT="$FORCE_SCAFFOLD_WORK" "$SCAFFOLD" --force 2>&1)
check "scaffold.sh --force exits 0 on a tree that already has content" "0" "$?"
check "a filled description.txt survives scaffold.sh --force" "My hand-written description." \
  "$(cat "$FORCE_SCAFFOLD_WORK/fastlane/metadata/ios/en-US/description.txt")"

REPO_ROOT="$FORCE_SCAFFOLD_WORK" "$SCAFFOLD" --force --from-console >/dev/null 2>&1
check "scaffold.sh --force with --from-console exits 64" "64" "$?"

echo
echo "== check-metadata.sh"

setup_metadata_tree() {
  local dest="$1"
  mkdir -p "$dest/fastlane/metadata"
  cp -R "$FIXTURES_DIR/metadata-tree/ios" "$dest/fastlane/metadata/ios"
  cp -R "$FIXTURES_DIR/metadata-tree/android" "$dest/fastlane/metadata/android"
}

FIXTURE_TREE="$WORK/fixture-tree"
setup_metadata_tree "$FIXTURE_TREE"
out=$(REPO_ROOT="$FIXTURE_TREE" "$CHECK_METADATA" --platform both 2>&1)
rc=$?
check "check-metadata.sh on the fixture exits 1" "1" "$rc"
check_contains "it reports the placeholder fault by path" "android/en-US/full_description.txt: contains the template placeholder text" "$out"
check_contains "it reports the over-limit name fault by path" "ios/en-US/name.txt: name is 41 characters" "$out"
check_contains "it reports the example.com privacy_url fault by path" "ios/en-US/privacy_url.txt: must not point at example.com" "$out"
check "check-metadata.sh reports exactly three faults" "3" "$(printf '%s\n' "$out" | grep -c ': ')"

CLEAN_TREE="$WORK/clean-tree"
setup_metadata_tree "$CLEAN_TREE"
printf 'Acme App\n' >"$CLEAN_TREE/fastlane/metadata/ios/en-US/name.txt"
printf 'https://acme.example/privacy\n' >"$CLEAN_TREE/fastlane/metadata/ios/en-US/privacy_url.txt"
printf 'A full description without placeholder text.\n' >"$CLEAN_TREE/fastlane/metadata/android/en-US/full_description.txt"
out=$(REPO_ROOT="$CLEAN_TREE" "$CHECK_METADATA" --platform both 2>&1)
rc=$?
check "check-metadata.sh on the fixed-up clean copy exits 0" "0" "$rc"

# length limits: at-limit pass, over-limit fail
LIMIT_TREE="$WORK/limit-tree"
setup_metadata_tree "$LIMIT_TREE"
printf 'https://acme.example/privacy\n' >"$LIMIT_TREE/fastlane/metadata/ios/en-US/privacy_url.txt"
printf 'A full description without placeholder text.\n' >"$LIMIT_TREE/fastlane/metadata/android/en-US/full_description.txt"
node -e "process.stdout.write('A'.repeat(30))" >"$LIMIT_TREE/fastlane/metadata/ios/en-US/name.txt"
out=$(REPO_ROOT="$LIMIT_TREE" "$CHECK_METADATA" --platform ios 2>&1)
check_not_contains "a 30-character name (at the limit) passes" "name.txt" "$out"
node -e "process.stdout.write('A'.repeat(31))" >"$LIMIT_TREE/fastlane/metadata/ios/en-US/name.txt"
out=$(REPO_ROOT="$LIMIT_TREE" "$CHECK_METADATA" --platform ios 2>&1)
check_contains "a 31-character name (over the limit) fails" "name.txt" "$out"

# I1: length counts include exactly one stripped trailing newline - a field
# saved by an editor (which appends a final newline) must not read as one
# character over.
node -e "process.stdout.write('A'.repeat(30) + '\n')" >"$LIMIT_TREE/fastlane/metadata/ios/en-US/name.txt"
out=$(REPO_ROOT="$LIMIT_TREE" "$CHECK_METADATA" --platform ios 2>&1)
check_not_contains "a 30-character name written with a trailing newline still passes" "name.txt" "$out"
node -e "process.stdout.write('A'.repeat(31) + '\n')" >"$LIMIT_TREE/fastlane/metadata/ios/en-US/name.txt"
out=$(REPO_ROOT="$LIMIT_TREE" "$CHECK_METADATA" --platform ios 2>&1)
check_contains "a 31-character name written with a trailing newline still fails" "name.txt" "$out"

# I2: code points are counted, not bytes - under a "C" locale a 30-character
# name using a multi-byte character must still pass.
node -e "process.stdout.write('é'.repeat(30) + '\n')" >"$LIMIT_TREE/fastlane/metadata/ios/en-US/name.txt"
out=$(env LC_ALL=C REPO_ROOT="$LIMIT_TREE" "$CHECK_METADATA" --platform ios 2>&1)
check_not_contains "a 30-character 'e-acute' name passes under LC_ALL=C" "name.txt" "$out"
node -e "process.stdout.write('A'.repeat(30))" >"$LIMIT_TREE/fastlane/metadata/ios/en-US/name.txt"

# I3: a missing required file is an offender, not silently skipped.
MISSING_TREE="$WORK/missing-tree"
setup_metadata_tree "$MISSING_TREE"
printf 'https://acme.example/privacy\n' >"$MISSING_TREE/fastlane/metadata/ios/en-US/privacy_url.txt"
printf 'A full description without placeholder text.\n' >"$MISSING_TREE/fastlane/metadata/android/en-US/full_description.txt"
rm -f "$MISSING_TREE/fastlane/metadata/ios/en-US/description.txt"
out=$(REPO_ROOT="$MISSING_TREE" "$CHECK_METADATA" --platform ios 2>&1)
check_contains "a deleted description.txt is reported missing" "ios/en-US/description.txt: missing" "$out"

# Minors: a whitespace-only file counts as empty.
WHITESPACE_TREE="$WORK/whitespace-tree"
setup_metadata_tree "$WHITESPACE_TREE"
printf 'https://acme.example/privacy\n' >"$WHITESPACE_TREE/fastlane/metadata/ios/en-US/privacy_url.txt"
printf 'A full description without placeholder text.\n' >"$WHITESPACE_TREE/fastlane/metadata/android/en-US/full_description.txt"
printf '   \n\t\n' >"$WHITESPACE_TREE/fastlane/metadata/ios/en-US/subtitle.txt"
out=$(REPO_ROOT="$WHITESPACE_TREE" "$CHECK_METADATA" --platform ios 2>&1)
check_contains "a whitespace-only subtitle.txt is reported empty" "ios/en-US/subtitle.txt: is empty" "$out"

# --fix-safe: strips trailing whitespace and normalises the final newline,
# and nothing else - a whitespace-only field stays whitespace-only (and so
# still reads as empty) rather than being invented content.
FIXSAFE_TREE="$WORK/fixsafe-tree"
setup_metadata_tree "$FIXSAFE_TREE"
printf 'https://acme.example/privacy\n' >"$FIXSAFE_TREE/fastlane/metadata/ios/en-US/privacy_url.txt"
printf 'A full description without placeholder text.\n' >"$FIXSAFE_TREE/fastlane/metadata/android/en-US/full_description.txt"
printf 'Acme App   \t\n\n\n' >"$FIXSAFE_TREE/fastlane/metadata/ios/en-US/name.txt"
printf '   \n' >"$FIXSAFE_TREE/fastlane/metadata/ios/en-US/subtitle.txt"
REPO_ROOT="$FIXSAFE_TREE" "$CHECK_METADATA" --platform ios --fix-safe >/dev/null 2>&1
check "--fix-safe strips trailing whitespace from a field's content line" "Acme App" \
  "$(node -e "process.stdout.write(require('fs').readFileSync(process.argv[1],'utf8').replace(/\n+$/,''))" "$FIXSAFE_TREE/fastlane/metadata/ios/en-US/name.txt")"
FIXSAFE_NAME_FILE="$FIXSAFE_TREE/fastlane/metadata/ios/en-US/name.txt"
check "--fix-safe normalises to exactly one trailing newline" "yes" \
  "$(node -e "
    const s = require('fs').readFileSync(process.argv[1], 'utf8');
    console.log(s === 'Acme App\n' ? 'yes' : 'no');
  " "$FIXSAFE_NAME_FILE")"
out=$(REPO_ROOT="$FIXSAFE_TREE" "$CHECK_METADATA" --platform ios 2>&1)
check_contains "--fix-safe leaves a whitespace-only field reading as empty" "ios/en-US/subtitle.txt: is empty" "$out"

# keywords with ", " fails
KEYWORDS_TREE="$WORK/keywords-tree"
setup_metadata_tree "$KEYWORDS_TREE"
printf 'https://acme.example/privacy\n' >"$KEYWORDS_TREE/fastlane/metadata/ios/en-US/privacy_url.txt"
printf 'travel, food, fitness\n' >"$KEYWORDS_TREE/fastlane/metadata/ios/en-US/keywords.txt"
out=$(REPO_ROOT="$KEYWORDS_TREE" "$CHECK_METADATA" --platform ios 2>&1)
check_contains "keywords with ', ' fails" "keywords.txt" "$out"

# review_information partial/empty/full
REVIEW_TREE="$WORK/review-tree"
setup_metadata_tree "$REVIEW_TREE"
printf 'https://acme.example/privacy\n' >"$REVIEW_TREE/fastlane/metadata/ios/en-US/privacy_url.txt"
: >"$REVIEW_TREE/fastlane/metadata/ios/review_information/notes.txt"
out=$(REPO_ROOT="$REVIEW_TREE" "$CHECK_METADATA" --platform ios 2>&1)
check_contains "a partially-filled review_information fails" "review_information is partially filled" "$out"
for f in first_name last_name phone_number email_address demo_user demo_password notes; do
  : >"$REVIEW_TREE/fastlane/metadata/ios/review_information/$f.txt"
done
out=$(REPO_ROOT="$REVIEW_TREE" "$CHECK_METADATA" --platform ios 2>&1)
check_not_contains "an entirely-empty review_information passes" "review_information is partially filled" "$out"
for f in first_name last_name phone_number email_address demo_user demo_password notes; do
  printf 'value\n' >"$REVIEW_TREE/fastlane/metadata/ios/review_information/$f.txt"
done
out=$(REPO_ROOT="$REVIEW_TREE" "$CHECK_METADATA" --platform ios 2>&1)
check_not_contains "an entirely-full review_information passes" "review_information is partially filled" "$out"

# Minors: all-or-nothing counts against the fixed seven names, so a deleted
# file is a missing field, not one fewer field to count.
rm -f "$REVIEW_TREE/fastlane/metadata/ios/review_information/demo_password.txt"
out=$(REPO_ROOT="$REVIEW_TREE" "$CHECK_METADATA" --platform ios 2>&1)
check_contains "six filled fields with demo_password.txt deleted is still partially filled" \
  "review_information is partially filled" "$out"

# category ids
CATEGORY_TREE="$WORK/category-tree"
setup_metadata_tree "$CATEGORY_TREE"
printf 'https://acme.example/privacy\n' >"$CATEGORY_TREE/fastlane/metadata/ios/en-US/privacy_url.txt"
printf 'UTILITIES' >"$CATEGORY_TREE/fastlane/metadata/ios/primary_category.txt"
for sub in primary_first_sub_category primary_second_sub_category secondary_first_sub_category secondary_second_sub_category; do
  : >"$CATEGORY_TREE/fastlane/metadata/ios/$sub.txt"
done
out=$(REPO_ROOT="$CATEGORY_TREE" "$CHECK_METADATA" --platform ios 2>&1)
check_not_contains "category id UTILITIES passes" "primary_category.txt" "$out"
printf 'MZGenre.Utilities' >"$CATEGORY_TREE/fastlane/metadata/ios/primary_category.txt"
out=$(REPO_ROOT="$CATEGORY_TREE" "$CHECK_METADATA" --platform ios 2>&1)
check_contains "legacy id MZGenre.Utilities fails, suggesting the modern id" "UTILITIES" "$out"
printf 'Utilities' >"$CATEGORY_TREE/fastlane/metadata/ios/primary_category.txt"
out=$(REPO_ROOT="$CATEGORY_TREE" "$CHECK_METADATA" --platform ios 2>&1)
check_contains "legacy id Utilities fails too" "primary_category.txt" "$out"

# C1: a stray top-level metadata/android/images/ directory fails the gate,
# naming it.
STRAY_IMAGES_TREE="$WORK/stray-images-tree"
setup_metadata_tree "$STRAY_IMAGES_TREE"
printf 'https://acme.example/privacy\n' >"$STRAY_IMAGES_TREE/fastlane/metadata/ios/en-US/privacy_url.txt"
printf 'A full description without placeholder text.\n' >"$STRAY_IMAGES_TREE/fastlane/metadata/android/en-US/full_description.txt"
mkdir -p "$STRAY_IMAGES_TREE/fastlane/metadata/android/images"
: >"$STRAY_IMAGES_TREE/fastlane/metadata/android/images/.gitkeep"
out=$(REPO_ROOT="$STRAY_IMAGES_TREE" "$CHECK_METADATA" --platform android 2>&1)
rc=$?
check "check-metadata.sh fails on a stray top-level android/images/ dir" "1" "$rc"
check_contains "...naming it" "android/images: must not exist" "$out"

if [ "$HAVE_IMAGE_TOOL" -eq 1 ]; then
  # Minors: icon/featureGraphic wrong-size violations.
  WRONGSIZE_TREE="$WORK/wrongsize-tree"
  setup_metadata_tree "$WRONGSIZE_TREE"
  printf 'https://acme.example/privacy\n' >"$WRONGSIZE_TREE/fastlane/metadata/ios/en-US/privacy_url.txt"
  printf 'A full description without placeholder text.\n' >"$WRONGSIZE_TREE/fastlane/metadata/android/en-US/full_description.txt"
  mkdir -p "$WRONGSIZE_TREE/fastlane/metadata/android/en-US/images"
  make_png "$WRONGSIZE_TREE/fastlane/metadata/android/en-US/images/icon.png" 256 256
  make_png "$WRONGSIZE_TREE/fastlane/metadata/android/en-US/images/featureGraphic.png" 800 400
  out=$(REPO_ROOT="$WRONGSIZE_TREE" "$CHECK_METADATA" --platform android 2>&1)
  check_contains "a 256x256 icon.png is a violation naming the required size" "images/icon.png: must be 512x512" "$out"
  check_contains "an 800x400 featureGraphic.png is a violation naming the required size" "images/featureGraphic.png: must be 1024x500" "$out"
fi

echo
echo "== place-images.sh"

# C2: the embedded iOS screenshot size list equals the set of WxH pairs
# grepped from the vendored deliver/lib/deliver/app_screenshot.rb, the same
# way CATEGORY_IDS is checked against app_category.rb.
CHECK_METADATA_IOS_SIZES="$(sed -nE 's/^IOS_SCREENSHOT_SIZES="(.*)"$/\1/p' "$CHECK_METADATA" | tr ' ' '\n' | sort -u)"
PLACE_IMAGES_IOS_SIZES="$(sed -nE 's/^IOS_SCREENSHOT_SIZES="(.*)"$/\1/p' "$PLACE_IMAGES" | tr ' ' '\n' | sort -u)"
if [ -f "$APP_SCREENSHOT_GEM" ]; then
  GEM_IOS_SCREENSHOT_SIZES="$(grep -oE '\[[0-9]+, *[0-9]+\]' "$APP_SCREENSHOT_GEM" | sed -E 's/\[([0-9]+), *([0-9]+)\]/\1x\2/' | sort -u)"
  check "check-metadata.sh's iOS screenshot size list equals the vendored app_screenshot.rb sizes" "" \
    "$(diff <(printf '%s\n' "$GEM_IOS_SCREENSHOT_SIZES") <(printf '%s\n' "$CHECK_METADATA_IOS_SIZES"))"
else
  skip "check-metadata.sh's iOS screenshot sizes vs app_screenshot.rb (no fastlane gem found: set APP_REPO_ROOT or FASTLANE_GEM_DIR)"
fi
check "place-images.sh's iOS screenshot size list equals check-metadata.sh's" "" \
  "$(diff <(printf '%s\n' "$CHECK_METADATA_IOS_SIZES") <(printf '%s\n' "$PLACE_IMAGES_IOS_SIZES"))"

if [ "$HAVE_IMAGE_TOOL" -eq 1 ]; then
  IMG_1290x2796="$WORK/shot-1290x2796.png"
  IMG_1024x500="$WORK/feature-1024x500.png"
  IMG_512x512="$WORK/icon-512x512.png"
  IMG_2868x1320="$WORK/shot-2868x1320.png"
  IMG_1080x2340="$WORK/shot-1080x2340.png"
  IMG_2560x1600="$WORK/shot-2560x1600.png"
  IMG_TOO_SMALL="$WORK/shot-100x100.png"
  make_png "$IMG_1290x2796" 1290 2796
  make_png "$IMG_1024x500" 1024 500
  make_png "$IMG_512x512" 512 512
  make_png "$IMG_2868x1320" 2868 1320
  make_png "$IMG_1080x2340" 1080 2340
  make_png "$IMG_2560x1600" 2560 1600
  make_png "$IMG_TOO_SMALL" 100 100

  PLACE_WORK="$WORK/place-images"
  mkdir -p "$PLACE_WORK/fastlane"

  out=$(REPO_ROOT="$PLACE_WORK" "$PLACE_IMAGES" --platform ios "$IMG_1290x2796" 2>&1)
  check "place-images.sh routes a 1290x2796 iOS shot to fastlane/screenshots/en-US/01_...png" "yes" \
    "$([ -f "$PLACE_WORK/fastlane/screenshots/en-US/01_shot-1290x2796.png" ] && echo yes || echo no)"

  # C2: 2868x1320 (the current 6.9-inch landscape size) is accepted.
  out=$(REPO_ROOT="$PLACE_WORK" "$PLACE_IMAGES" --platform ios "$IMG_2868x1320" 2>&1)
  rc=$?
  check "place-images.sh accepts an iOS 2868x1320 shot" "0" "$rc"

  out=$(REPO_ROOT="$PLACE_WORK" "$PLACE_IMAGES" --platform android "$IMG_1024x500" 2>&1)
  check "place-images.sh routes a 1024x500 image to <locale>/images/featureGraphic.png" "yes" \
    "$([ -f "$PLACE_WORK/fastlane/metadata/android/en-US/images/featureGraphic.png" ] && echo yes || echo no)"

  out=$(REPO_ROOT="$PLACE_WORK" "$PLACE_IMAGES" --platform android "$IMG_512x512" 2>&1)
  check "place-images.sh routes a 512x512 image to <locale>/images/icon.png" "yes" \
    "$([ -f "$PLACE_WORK/fastlane/metadata/android/en-US/images/icon.png" ] && echo yes || echo no)"

  # C3: default kind for anything that isn't icon/feature-sized is "phone",
  # no pixel heuristic - and landscape is accepted.
  out=$(REPO_ROOT="$PLACE_WORK" "$PLACE_IMAGES" --platform android "$IMG_1080x2340" 2>&1)
  check "place-images.sh routes a 1080x2340 Android shot to phoneScreenshots by default" "yes" \
    "$([ -f "$PLACE_WORK/fastlane/metadata/android/en-US/images/phoneScreenshots/01_shot-1080x2340.png" ] && echo yes || echo no)"

  out=$(REPO_ROOT="$PLACE_WORK" "$PLACE_IMAGES" --platform android --kind ten-inch "$IMG_2560x1600" 2>&1)
  check "place-images.sh --kind ten-inch routes 2560x1600 to tenInchScreenshots" "yes" \
    "$([ -f "$PLACE_WORK/fastlane/metadata/android/en-US/images/tenInchScreenshots/01_shot-2560x1600.png" ] && echo yes || echo no)"

  out=$(REPO_ROOT="$PLACE_WORK" "$PLACE_IMAGES" --platform android "$IMG_TOO_SMALL" 2>&1)
  rc=$?
  check "place-images.sh refuses a too-small 100x100 image" "1" "$rc"
  check_contains "...naming the nearest legal size" "nearest legal size" "$out"

  DRYRUN_WORK="$WORK/place-images-dryrun"
  mkdir -p "$DRYRUN_WORK/fastlane"
  out=$(REPO_ROOT="$DRYRUN_WORK" "$PLACE_IMAGES" --platform ios --dry-run "$IMG_1290x2796" 2>&1)
  check "place-images.sh --dry-run copies nothing" "no" \
    "$([ -d "$DRYRUN_WORK/fastlane/screenshots" ] && echo yes || echo no)"

  FORCE_WORK="$WORK/place-images-force"
  mkdir -p "$FORCE_WORK/fastlane"
  REPO_ROOT="$FORCE_WORK" "$PLACE_IMAGES" --platform android "$IMG_512x512" >/dev/null 2>&1
  REPO_ROOT="$FORCE_WORK" "$PLACE_IMAGES" --platform android "$IMG_512x512" >/dev/null 2>&1
  rc=$?
  check "place-images.sh refuses an existing destination without --force" "2" "$rc"
  REPO_ROOT="$FORCE_WORK" "$PLACE_IMAGES" --platform android --force "$IMG_512x512" >/dev/null 2>&1
  check "place-images.sh --force overwrites an existing destination" "0" "$?"
else
  skip "place-images.sh image-dimension cases (no sips/magick/identify on PATH)"
fi

echo
echo "== age-rating.sh"

# The keys age-rating.sh itself claims to support - used below to build a
# full answer set regardless of whether ruby is available to independently
# re-derive them from the gem.
EXPECTED_AGE_KEYS="$WORK/expected-age-keys.txt"
"$AGE_RATING" --list-keys >"$EXPECTED_AGE_KEYS" 2>&1

if [ "$HAVE_RUBY" -eq 1 ] && [ -f "$AGE_RATING_GEM" ]; then
  GEM_AGE_KEYS="$WORK/gem-age-keys.txt"
  ruby -e '
attrs = []
File.readlines(ARGV[0]).each do |line|
  m = line.match(/attr_accessor :(\w+)/)
  attrs << m[1] if m
end
omit = %w[developer_age_rating_info_url gambling_and_contests]
attrs.reject! { |a| omit.include?(a) }
attrs.each do |a|
  camel = a.split("_").each_with_index.map { |w, i| i == 0 ? w : w.capitalize }.join
  puts camel
end
' "$AGE_RATING_GEM" >"$GEM_AGE_KEYS"
  check "age-rating.sh --list-keys matches the gem-derived key list" "" "$(diff <(sort "$GEM_AGE_KEYS") <(sort "$EXPECTED_AGE_KEYS"))"
else
  skip "age-rating.sh --list-keys vs. the gem-derived key list (needs ruby and the fastlane gem: set APP_REPO_ROOT or FASTLANE_GEM_DIR)"
fi

AGE_WORK="$WORK/age-rating"
mkdir -p "$AGE_WORK"
out=$("$AGE_RATING" --out "$AGE_WORK/config.json" --set unknownKey=NONE 2>&1)
check "age-rating.sh --set with an unknown key exits 64" "64" "$?"

out=$("$AGE_RATING" --out "$AGE_WORK/config.json" --set advertising=maybe 2>&1)
check "age-rating.sh --set with a bad value exits 64" "64" "$?"

out=$("$AGE_RATING" --out "$AGE_WORK/config.json" --set advertising=true 2>&1)
rc=$?
check "age-rating.sh --set with an incomplete set exits 1" "1" "$rc"

FULL_ANSWERS="$AGE_WORK/answers.txt"
: >"$FULL_ANSWERS"
while IFS= read -r key; do
  case "$key" in
    ageRatingOverrideV2) value="NONE" ;;
    koreaAgeRatingOverride) value="NONE" ;;
    kidsAgeBand) value="null" ;;
    advertising | ageAssurance | gambling | healthOrWellnessTopics | lootBox | messagingAndChat | parentalControls | socialMedia | socialMediaAgeRestricted | unrestrictedWebAccess | userGeneratedContent) value="false" ;;
    *) value="NONE" ;;
  esac
  echo "$key=$value" >>"$FULL_ANSWERS"
done <"$EXPECTED_AGE_KEYS"

out=$("$AGE_RATING" --out "$AGE_WORK/config.json" --from-answers "$FULL_ANSWERS" 2>&1)
rc=$?
check "age-rating.sh --from-answers with a complete set exits 0" "0" "$rc"
check "the written JSON is valid" "0" "$(node -e "JSON.parse(require('fs').readFileSync(process.argv[1],'utf8'))" "$AGE_WORK/config.json" >/dev/null 2>&1; echo $?)"
WRITTEN_KEYS="$(node -e "console.log(Object.keys(JSON.parse(require('fs').readFileSync(process.argv[1],'utf8'))).sort().join('\n'))" "$AGE_WORK/config.json")"
if [ -f "$SHIPPED_RATING" ]; then
  SHIPPED_KEYS="$(node -e "console.log(Object.keys(JSON.parse(require('fs').readFileSync(process.argv[1],'utf8'))).sort().join('\n'))" "$SHIPPED_RATING")"
  check "the written key set equals the shipped file's key set" "$SHIPPED_KEYS" "$WRITTEN_KEYS"
else
  skip "the written age-rating keys vs an app's shipped app_rating_config.json (set APP_REPO_ROOT)"
fi

echo
echo "== the placeholder literal and category/age lists match the repo"

CHECK_METADATA_LITERAL="$(sed -nE "s/^PLACEHOLDER='(.*)'$/\1/p" "$CHECK_METADATA")"
if [ -f "$SHARED_RB" ]; then
  SHARED_RB_LITERAL="$(sed -nE "s/^METADATA_PLACEHOLDER = '(.*)'$/\1/p" "$SHARED_RB")"
  check "check-metadata.sh's placeholder literal equals shared.rb's METADATA_PLACEHOLDER" "$SHARED_RB_LITERAL" "$CHECK_METADATA_LITERAL"
else
  skip "check-metadata.sh's placeholder literal vs shared.rb (no lanes found: set APP_REPO_ROOT)"
fi

SCRIPT_CATEGORY_IDS="$(sed -nE 's/^CATEGORY_IDS="(.*)"$/\1/p' "$CHECK_METADATA" | tr ' ' '\n' | sort -u)"
if [ -f "$APP_CATEGORY_GEM" ]; then
  GEM_CATEGORY_IDS="$(grep -oE '"[A-Z_]+"' "$APP_CATEGORY_GEM" | tr -d '"' | sort -u)"
  check "check-metadata.sh's category id list equals the vendored app_category.rb ids" "" "$(diff <(printf '%s\n' "$GEM_CATEGORY_IDS") <(printf '%s\n' "$SCRIPT_CATEGORY_IDS"))"
else
  skip "check-metadata.sh's category ids vs app_category.rb (no fastlane gem found: set APP_REPO_ROOT or FASTLANE_GEM_DIR)"
fi

echo
echo "== sync.sh"

SYNC_WORK="$WORK/sync"
setup_metadata_tree "$SYNC_WORK"
printf 'Acme App\n' >"$SYNC_WORK/fastlane/metadata/ios/en-US/name.txt"
printf 'https://acme.example/privacy\n' >"$SYNC_WORK/fastlane/metadata/ios/en-US/privacy_url.txt"
printf 'A full description without placeholder text.\n' >"$SYNC_WORK/fastlane/metadata/android/en-US/full_description.txt"

env -u STORE_METADATA_SYNC_ENABLED REPO_ROOT="$SYNC_WORK" "$SYNC" both --dry-run >/dev/null 2>&1
check "sync.sh exits 2 without STORE_METADATA_SYNC_ENABLED" "2" "$?"

BROKEN_SYNC_WORK="$WORK/sync-broken"
setup_metadata_tree "$BROKEN_SYNC_WORK"
out=$(STORE_METADATA_SYNC_ENABLED=true REPO_ROOT="$BROKEN_SYNC_WORK" "$SYNC" both --dry-run 2>&1)
rc=$?
check "sync.sh refuses when check-metadata.sh fails" "2" "$rc"
check_contains "...naming check-metadata.sh" "check-metadata.sh" "$out"

: >"$BUNDLE_LOG"
out=$(STORE_METADATA_SYNC_ENABLED=true REPO_ROOT="$SYNC_WORK" "$SYNC" both --dry-run 2>&1)
rc=$?
check "sync.sh --dry-run exits 0 against a clean tree" "0" "$rc"
check_contains "the fake bundle saw DRY_RUN=1" "DRY_RUN=1" "$(cat "$BUNDLE_LOG")"
check_contains "the fake bundle saw sync_metadata in argv" "sync_metadata" "$(cat "$BUNDLE_LOG")"

STORE_METADATA_SYNC_ENABLED=true REPO_ROOT="$SYNC_WORK" "$SYNC" both >/dev/null 2>&1
check "sync.sh without --yes on a real run exits 64" "64" "$?"

echo
echo "== a fastlane directory that is not ./fastlane (FASTLANE_DIRECTORY)"

# An app whose fastlane/ sits in a subdirectory (the `fastlane-directory` input of
# the release workflows). Every script that names the metadata tree takes it from
# FASTLANE_DIRECTORY, relative to the repository root, and fastlane itself runs
# from the directory that contains it.
MONO_WORK="$WORK/mono"
mkdir -p "$MONO_WORK/mobile/fastlane"
out=$(FASTLANE_DIRECTORY=mobile/fastlane REPO_ROOT="$MONO_WORK" "$SCAFFOLD" 2>&1)
rc=$?
check "scaffold.sh scaffolds under mobile/fastlane" "0" "$rc"
check "...the iOS tree is there" "yes" "$([ -d "$MONO_WORK/mobile/fastlane/metadata/ios/en-US" ] && echo yes || echo no)"
check "...and nothing was made under ./fastlane" "no" "$([ -e "$MONO_WORK/fastlane" ] && echo yes || echo no)"

out=$(FASTLANE_DIRECTORY=elsewhere REPO_ROOT="$MONO_WORK" "$SCAFFOLD" 2>&1)
rc=$?
check "scaffold.sh exits 2 when the named directory is not there" "2" "$rc"
check_contains "...naming it" "no elsewhere/ directory" "$out"

: >"$BUNDLE_LOG"
FASTLANE_DIRECTORY=mobile/fastlane REPO_ROOT="$MONO_WORK" "$SCAFFOLD" --from-console >/dev/null 2>&1
check "scaffold.sh --from-console runs fastlane from the directory that contains mobile/fastlane" "yes" \
  "$(grep -qxF "CWD=$(cd "$MONO_WORK/mobile" && pwd -P)" "$BUNDLE_LOG" && echo yes || echo no)"

out=$(REPO_ROOT="$MONO_WORK" "$CHECK_METADATA" --platform ios 2>&1)
rc=$?
check "check-metadata.sh finds no tree at the default ./fastlane (usage error)" "64" "$rc"
check_contains "...and names the default directory" "no fastlane/metadata directory" "$out"
out=$(FASTLANE_DIRECTORY=mobile/fastlane REPO_ROOT="$MONO_WORK" "$CHECK_METADATA" --platform ios 2>&1)
check_not_contains "check-metadata.sh reads the tree under mobile/fastlane" "no mobile/fastlane/metadata directory" "$out"

SYNC_MONO="$WORK/sync-mono"
mkdir -p "$SYNC_MONO/mobile"
setup_metadata_tree "$SYNC_MONO/mobile"
printf 'Acme App\n' >"$SYNC_MONO/mobile/fastlane/metadata/ios/en-US/name.txt"
printf 'https://acme.example/privacy\n' >"$SYNC_MONO/mobile/fastlane/metadata/ios/en-US/privacy_url.txt"
printf 'A full description without placeholder text.\n' >"$SYNC_MONO/mobile/fastlane/metadata/android/en-US/full_description.txt"
: >"$BUNDLE_LOG"
STORE_METADATA_SYNC_ENABLED=true FASTLANE_DIRECTORY=mobile/fastlane REPO_ROOT="$SYNC_MONO" "$SYNC" both --dry-run >/dev/null 2>&1
check "sync.sh --dry-run passes against mobile/fastlane" "0" "$?"
check "...and runs the lane from the directory that contains it" "yes" \
  "$(grep -qxF "CWD=$(cd "$SYNC_MONO/mobile" && pwd -P)" "$BUNDLE_LOG" && echo yes || echo no)"

if [ -f "$FULL_ANSWERS" ]; then
  (cd "$MONO_WORK" && FASTLANE_DIRECTORY=mobile/fastlane "$AGE_RATING" --from-answers "$FULL_ANSWERS" >/dev/null 2>&1)
  check "age-rating.sh writes its file under mobile/fastlane by default" "yes" \
    "$([ -f "$MONO_WORK/mobile/fastlane/metadata/ios/app_rating_config.json" ] && echo yes || echo no)"
else
  skip "age-rating.sh's default output under mobile/fastlane (no complete answers file was built above)"
fi

if [ "$HAVE_IMAGE_TOOL" -eq 1 ]; then
  make_png "$WORK/mono-shot.png" 1290 2796
  FASTLANE_DIRECTORY=mobile/fastlane REPO_ROOT="$MONO_WORK" "$PLACE_IMAGES" --platform ios --locale en-US "$WORK/mono-shot.png" >/dev/null 2>&1
  check "place-images.sh puts an iOS screenshot under mobile/fastlane/screenshots" "yes" \
    "$(ls "$MONO_WORK"/mobile/fastlane/screenshots/en-US/*mono-shot.png >/dev/null 2>&1 && echo yes || echo no)"
else
  skip "place-images.sh under mobile/fastlane (no image tool on PATH)"
fi

echo
echo "== SKILL.md"

check "SKILL.md names scaffold.sh" "yes" "$(grep -qF 'scaffold.sh' "$SKILL_MD" && echo yes || echo no)"
check "SKILL.md names check-metadata.sh" "yes" "$(grep -qF 'check-metadata.sh' "$SKILL_MD" && echo yes || echo no)"
check "SKILL.md names place-images.sh" "yes" "$(grep -qF 'place-images.sh' "$SKILL_MD" && echo yes || echo no)"
check "SKILL.md names age-rating.sh" "yes" "$(grep -qF 'age-rating.sh' "$SKILL_MD" && echo yes || echo no)"
check "SKILL.md names sync.sh" "yes" "$(grep -qF 'sync.sh' "$SKILL_MD" && echo yes || echo no)"
check "SKILL.md mentions the METADATA_PLACEHOLDER literal" "yes" "$(grep -qF 'Replace this text' "$SKILL_MD" && echo yes || echo no)"
check "SKILL.md mentions overwrite_screenshots" "yes" "$(grep -qF 'overwrite_screenshots' "$SKILL_MD" && echo yes || echo no)"
check "SKILL.md mentions STORE_METADATA_SYNC_ENABLED" "yes" "$(grep -qF 'STORE_METADATA_SYNC_ENABLED' "$SKILL_MD" && echo yes || echo no)"
check "SKILL.md explains why bypassing sync.sh does not bypass the gate" "yes" \
  "$(grep -qF 'does not bypass the gate' "$SKILL_MD" && echo yes || echo no)"
check "SKILL.md says release_notes.txt must be non-empty for the gate" "yes" \
  "$(grep -qF 'release_notes.txt' "$SKILL_MD" && echo yes || echo no)"
check "SKILL.md uses the shared section headings" "yes" \
  "$(grep -qF '## After Editing the Scripts' "$SKILL_MD" &&
    grep -qF '## Common Mistakes' "$SKILL_MD" &&
    grep -qF '## Red Flags — Stop' "$SKILL_MD" && echo yes || echo no)"

# I2: the meta-* ids this skill names and the meta-* ids in the checklist
# vocabulary are the same set, in both directions.
STATE_SH="$(cd "$SKILL_DIR/../store-setup/scripts" && pwd)/state.sh"
VOCABULARY_META_IDS="$("$STATE_SH" --list-steps | grep -E '^meta-' | sort -u)"
SKILL_MD_META_IDS="$(grep -ohE 'meta-[a-z0-9-]+' "$SKILL_MD" | sort -u)"
check "every meta-* id in SKILL.md is in state.sh --list-steps, and every one of those is in SKILL.md" "" \
  "$(diff <(printf '%s\n' "$VOCABULARY_META_IDS") <(printf '%s\n' "$SKILL_MD_META_IDS"))"

# I5: allowed-tools is a comma-separated list of Bash(prefix:*) patterns -
# space-separated entries or `Bash(cmd *)` globs are not what Claude Code
# parses.
ALLOWED_TOOLS_LINE="$(grep -m1 '^allowed-tools:' "$SKILL_MD")"
check "SKILL.md's allowed-tools line is comma-separated" "yes" \
  "$(printf '%s' "$ALLOWED_TOOLS_LINE" | grep -qF ',' && echo yes || echo no)"
check "SKILL.md's allowed-tools line uses the :* prefix form" "yes" \
  "$(printf '%s' "$ALLOWED_TOOLS_LINE" | grep -qF ':*' && echo yes || echo no)"

echo
echo "-------------------------------------"
printf '%d passed, %d failed, %d skipped\n' "$PASS" "$FAIL" "$SKIP"
[ "$FAIL" -eq 0 ] || exit 1

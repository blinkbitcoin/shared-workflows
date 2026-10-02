# Store Listing Sync Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Push the baseline store listing from `fastlane/metadata/**` to App Store Connect and Google Play at any time, independent of a release, behind a feature flag; pull the consoles' copy back into the tree; and fix a latent deliver bug that would fail the first real production release.

**Architecture:** Four additive fastlane lanes (`ios|android sync_metadata`, `ios|android pull_metadata`) built on new helpers in `fastlane/lanes/shared.rb`. Push lanes run against a *staged copy* of the metadata tree with the per-version paths (`release_notes.txt`, `changelogs/`) removed, so CD keeps owning "What's new"; they upload no binary, submit nothing for review, move no track. The repository variable `STORE_METADATA_SYNC_ENABLED` (default unset = off) gates both the lanes (`assert_metadata_sync_enabled!`) and a new `workflow_dispatch` workflow `store-metadata.yml` that runs them through shared-workflows' `fastlane-lane.yml`. `release_production` is unchanged.

**Tech Stack:** fastlane 2.239.0 (vendored at `vendor/bundle/ruby/3.3.0/gems/fastlane-2.239.0/`), Ruby lanes under `fastlane/lanes/`, Minitest under `fastlane/test/`, GitHub Actions, shared-workflows `fastlane-lane.yml@v0`.

**Spec:** `/Users/jonas/.claude/plans/draft-browser-based-skills-dreamy-lampson.md`, section "PR 1". Design rationale and the vendored-source citations are in that file's Context; this plan is its argument.

## Global Constraints

- Work in `/Users/jonas/Dev/blink/react-native-mobile-template-store-listing-sync` (worktree, branch `feat/store-listing-sync`). Never switch branches.
- `make check` (`check-code check-gen check-deps check-ci check-docs check-release`) must pass before every push; `make check-release` (Ruby syntax + lane parse + `fastlane/test/lanes_test.rb`) after every Ruby change; run tests in isolation with `bundle exec ruby -Ifastlane/test fastlane/test/lanes_test.rb`.
- Commit scopes from `commitlint.config.mjs`: `release` for fastlane lanes/tests/metadata, `ci` for workflows, `docs` for docs. Types `fix`/`feat`/`docs`. Every commit ends with the trailer `Claude-Session: https://claude.ai/code/session_01SpyYZEnJaLFih75JB4EQAW`.
- Follow the existing lane style: `store_action(:name, **args)` for every store call (it is the `DRY_RUN=1` seam), `require_env!`, `UI.user_error!` with a remedy naming the doc, comments that state *why*.
- `release_production` on both platforms keeps its current behaviour: still `submit_for_review: true`, still `skip_screenshots: true` on iOS, still the full Play listing on Android. Existing assertions in `fastlane/test/lanes_test.rb` must keep passing unchanged.
- Never place a credential in an argv: temp key files are 0600 under `Dir.mktmpdir`, removed by the block.
- No new `make` target (it would require an `AGENTS.md` row and none is needed).
- Docs table cells must satisfy `scripts/check-docs-tables.mjs` (run `make check-docs`).

---

### Task 1: Fix the deliver directory bug

**Files:**
- Delete: `fastlane/metadata/ios/screenshots/.gitkeep` (and the directory)
- Create: `fastlane/screenshots/en-US/.gitkeep`
- Modify: `fastlane/lanes/shared.rb` (after `assert_metadata_ready!`, ~line 457)
- Modify: `fastlane/lanes/ios.rb` `lane :release_production` (~line 194)
- Test: `fastlane/test/lanes_test.rb`

**Interfaces:**
- Produces: `IOS_METADATA_ALLOWED_DIRS`, `assert_ios_metadata_dirs!(metadata_path)`, used by Task 3.

- [ ] **Step 1: Write the failing tests** in `LanesTest` (helper level), next to the existing `assert_metadata_ready!` tests:

```ruby
def test_assert_ios_metadata_dirs_accepts_locales_and_deliver_folders
  Dir.mktmpdir do |dir|
    FileUtils.mkdir_p(File.join(dir, 'en-US'))
    FileUtils.mkdir_p(File.join(dir, 'review_information'))
    assert_nil assert_ios_metadata_dirs!(dir)
  end
end

def test_assert_ios_metadata_dirs_rejects_a_screenshots_directory
  Dir.mktmpdir do |dir|
    FileUtils.mkdir_p(File.join(dir, 'en-US'))
    FileUtils.mkdir_p(File.join(dir, 'screenshots'))
    err = assert_raises(FastlaneCore::Interface::FastlaneError) { assert_ios_metadata_dirs!(dir) }
    assert_includes err.message, 'screenshots'
    assert_includes err.message, 'fastlane/screenshots/'
  end
end
```
And in `LaneBehaviourTest`, a case that builds a metadata tree with a `screenshots/` directory, runs `ios release_production`, and asserts the error mentions `screenshots` and `refute called?(:upload_to_app_store)`. Follow the existing helpers in that class for creating a scratch metadata tree (read how the placeholder tests do it).

- [ ] **Step 2: Run** `bundle exec ruby -Ifastlane/test fastlane/test/lanes_test.rb` — expect the new cases to fail with `NoMethodError: assert_ios_metadata_dirs!`.

- [ ] **Step 3: Implement** in `fastlane/lanes/shared.rb`, after `assert_metadata_ready!`:

```ruby
# deliver rejects a directory under metadata_path that is neither an Apple
# locale nor one of its own special folders, *before* it uploads anything
# (deliver/lib/deliver/loader.rb:167) - and its error lists every locale Apple
# supports, which buries the one useful fact. Say it here instead. This is why
# iOS screenshots live in fastlane/screenshots/<locale>/, deliver's own
# default: `screenshots` is exactly the directory name that trips it.
IOS_METADATA_ALLOWED_DIRS = %w[
  review_information trade_representative_contact_information
  app_clip_review_information default appleTV iMessage
].freeze

def assert_ios_metadata_dirs!(metadata_path)
  offenders = Dir.children(metadata_path).select do |name|
    File.directory?(File.join(metadata_path, name)) &&
      !LOCALE_DIR_PATTERN.match?(name) && !IOS_METADATA_ALLOWED_DIRS.include?(name)
  end
  return if offenders.empty?

  UI.user_error!(
    "#{metadata_path} holds directories deliver will reject: #{offenders.sort.join(', ')} - " \
    'screenshots belong in fastlane/screenshots/<locale>/ (see docs/release-runbook.md)'
  )
end
```
In `ios.rb` `release_production`, call `assert_ios_metadata_dirs!(ios_metadata_path)` immediately before `assert_metadata_ready!(ios_metadata_path)`. Delete `fastlane/metadata/ios/screenshots/` (`git rm -r`), create `fastlane/screenshots/en-US/.gitkeep`.

- [ ] **Step 4: Run** the tests again, then `make check-release`. Expect all green.

- [ ] **Step 5: Commit**

```
fix(release): stop shipping a screenshots directory deliver rejects

deliver validates every directory under metadata_path before it uploads
anything and refuses any name that is not a locale or one of its own
folders (deliver/lib/deliver/loader.rb:167). fastlane/metadata/ios/
screenshots/ is exactly such a name, so the first real release_production
would have failed with "Unsupported directory name(s)". iOS screenshots
now live in fastlane/screenshots/<locale>/, deliver's own default, and the
lane says so before it starts.

Claude-Session: https://claude.ai/code/session_01SpyYZEnJaLFih75JB4EQAW
```

---

### Task 2: Shared helpers for listing sync

**Files:**
- Modify: `fastlane/lanes/shared.rb` (append after Task 1's helper)
- Test: `fastlane/test/lanes_test.rb` (`LanesTest`)

**Interfaces:**
- Consumes: `truthy?` (~197), `store_action` (~50), `require_env!` (~25), `play_json_key_args` (~331), `root_path` (~213), `LOCALE_DIR_PATTERN` (~368), `DRY_RUN_RESULTS` (~38).
- Produces, for Tasks 3 and 4: `assert_metadata_sync_enabled!`, `SYNC_EXCLUDED_FILES`, `SYNC_EXCLUDED_DIRS`, `with_baseline_metadata(source, exclude_files:, exclude_dirs:) { |staged| }`, `ios_screenshots_path`, `ios_screenshots?`, `ios_app_rating_config_path(metadata_path)`, `PLAY_METADATA_TRACKS`, `play_metadata_target -> [track, version_code]`, `with_asc_api_key_file { |path| }`, `with_play_json_key_file { |path| }`, `warn_metadata_overwrite!(relative_path)`, `report_metadata_diff!(*relative_paths)`.

- [ ] **Step 1: Write the failing tests** (one per helper; use `Dir.mktmpdir`, set/clear env with the class's existing pattern):
  1. `assert_metadata_sync_enabled!` passes for `STORE_METADATA_SYNC_ENABLED` in `true`, `1`, `yes`; raises for unset, `false`, `0`; the message includes `STORE_METADATA_SYNC_ENABLED` and `docs/release-runbook.md`.
  2. `with_baseline_metadata`: given a tree with `en-US/description.txt`, `en-US/release_notes.txt`, `en-US/changelogs/100.txt`, the staged copy has the description, lacks `release_notes.txt` and lacks `changelogs/`; the source is byte-identical after; the staged path no longer exists after the block.
  3. `ios_screenshots?` is false for an empty dir or one holding only `.gitkeep`, true for `en-US/01.png` and for `en-US/01.PNG` (override `ios_screenshots_path` via a stub or pass through a `root` the way other path helpers are tested; if none exists, test via `ENV`-free `Dir.chdir` into a scratch root and `root_path`).
  4. `ios_app_rating_config_path` returns nil when the file is absent and the path when present.
  5. `play_metadata_target`: with `store_action` stubbed (`google_play_track_version_codes`) to return `[3, 7]` for `production` → `['production', 7]`; `[]` for production and `[5]` for beta → `['beta', 5]`; `PLAY_METADATA_TRACK=internal` only asks internal; all empty → error naming `production, beta, internal` and `upload_internal`; under `DRY_RUN=1` with all empty → `['production', APP_BUILD_NUMBER.to_i]`.
  6. `with_asc_api_key_file`: the yielded file has mode `0600`, parses as JSON with `key_id`, `issuer_id`, `key`, `is_key_content_base64 == true`, `in_house == false`; it no longer exists after the block. `with_play_json_key_file`: yields `play_json_key_args[:json_key]` unchanged when that is set, else a 0600 file whose content equals `json_key_data`.

- [ ] **Step 2: Run** the test file — expect `NoMethodError` for each new helper.

- [ ] **Step 3: Implement** in `fastlane/lanes/shared.rb`:

```ruby
# ---------- store listing sync (fastlane/metadata/** -> the consoles) -------
#
# The sync lanes push the *baseline* listing at any time, independent of a
# release. What a release owns and this must never touch: the per-version
# release notes (write_release_notes!), the binary, the review submission, the
# Play track. Both consoles are told only what the repository holds, and the
# repository holds only what a diff has been reviewed for.

# The repository variable that arms the push lanes, checked before anything
# else in them. Off by default and refused loudly: every other tier in this
# repo works that way (STORE_UPLOADS_ENABLED, IOS_SIGNING_ENABLED), and a
# consumer who has not opted in must not be able to overwrite a live store
# page by running a lane whose name looks harmless.
def assert_metadata_sync_enabled!
  return if truthy?(ENV['STORE_METADATA_SYNC_ENABLED'])

  UI.user_error!(
    'Store listing sync is off: set the repository variable ' \
    'STORE_METADATA_SYNC_ENABLED=true (or export it locally) before a lane may ' \
    'write the public store page (see docs/release-runbook.md)'
  )
end

# deliver and supply upload whatever is on disk under metadata_path, so the
# only way to withhold a file from them is not to show it to them: the push
# lanes run against a staged copy of the tree with the per-version paths
# removed. Copying rather than deleting also means a lane can never damage the
# working tree of the checkout it runs in.
SYNC_EXCLUDED_FILES = %w[release_notes.txt].freeze
SYNC_EXCLUDED_DIRS = %w[changelogs].freeze

def with_baseline_metadata(source, exclude_files: SYNC_EXCLUDED_FILES, exclude_dirs: SYNC_EXCLUDED_DIRS)
  require 'tmpdir'
  require 'fileutils'
  Dir.mktmpdir('store-metadata-sync') do |tmp|
    staged = File.join(tmp, File.basename(source))
    FileUtils.cp_r(source, staged)
    exclude_dirs.each { |name| Dir.glob(File.join(staged, '**', name)).each { |dir| FileUtils.rm_rf(dir) } }
    exclude_files.each { |name| Dir.glob(File.join(staged, '**', name)).each { |file| FileUtils.rm_f(file) } }
    UI.message("Staged baseline metadata at #{staged} (excluded: #{(exclude_files + exclude_dirs).join(', ')})")
    yield staged
  end
end

def ios_screenshots_path
  root_path('fastlane', 'screenshots')
end

# Whether there is anything to upload. Asked before skip_screenshots is
# cleared, because deliver's screenshot upload demands an edit version even
# when it would find no files (deliver/lib/deliver/upload_screenshots.rb:22).
def ios_screenshots?
  !Dir.glob(File.join(ios_screenshots_path, '*', '*.{png,jpg,jpeg}'), File::FNM_CASEFOLD).empty?
end

def ios_app_rating_config_path(metadata_path)
  path = File.join(metadata_path, 'app_rating_config.json')
  File.exist?(path) ? path : nil
end

# supply attaches a listing edit to a release: perform_upload_meta looks up a
# track and a release for a version code before it writes a single listing
# field, and errors out if it finds neither (supply/lib/supply/uploader.rb:84).
# So a listing-only sync still has to name the release it rides on. It changes
# nothing about it - no binary, no rollout, no promotion.
PLAY_METADATA_TRACKS = %w[production beta internal].freeze

def play_metadata_target
  package = ENV.fetch('ANDROID_PACKAGE')
  configured = ENV['PLAY_METADATA_TRACK'].to_s.strip
  tracks = configured.empty? ? PLAY_METADATA_TRACKS : [configured]

  tracks.each do |track|
    codes = Array(store_action(:google_play_track_version_codes,
                               package_name: package, track: track, **play_json_key_args))
    next if codes.empty?

    return [track, codes.map(&:to_i).max]
  end

  # DRY_RUN returns [] for every track, so a rehearsal would otherwise stop
  # with a store-shaped error it cannot answer.
  return ['production', ENV.fetch('APP_BUILD_NUMBER').to_i] if ENV['DRY_RUN'] == '1'

  UI.user_error!(
    "Play has no release on #{tracks.join(', ')} for #{package}: upload a build first " \
    '(`fastlane android upload_internal`), or set PLAY_METADATA_TRACK (see docs/release-runbook.md)'
  )
end

# The App Store Connect key as deliver's *command line* wants it: a JSON file.
# The lanes hand the key to actions as a hash, but `deliver download_metadata`
# is a fastlane command, not an action, so it runs in its own process with its
# own configuration. 0600 in a temp dir, and never an argument: an argv is
# world-readable (same reason as with_password_files in android.rb).
def with_asc_api_key_file
  require 'tmpdir'
  require 'json'
  require_env!(%w[ASC_KEY_ID ASC_ISSUER_ID ASC_KEY_P8_BASE64])
  Dir.mktmpdir('asc-api-key') do |dir|
    path = File.join(dir, 'key.json')
    File.open(path, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
      file.write(JSON.generate(
                   key_id: ENV.fetch('ASC_KEY_ID'),
                   issuer_id: ENV.fetch('ASC_ISSUER_ID'),
                   key: ENV.fetch('ASC_KEY_P8_BASE64'),
                   is_key_content_base64: true,
                   in_house: false
                 ))
    end
    yield path
  end
end

# The same, for supply's command line: `--json_key <path>`.
def with_play_json_key_file
  args = play_json_key_args
  return yield(args[:json_key]) if args[:json_key]

  require 'tmpdir'
  Dir.mktmpdir('play-json-key') do |dir|
    path = File.join(dir, 'key.json')
    File.open(path, File::WRONLY | File::CREAT | File::EXCL, 0o600) { |f| f.write(args.fetch(:json_key_data)) }
    yield path
  end
end

# A pull overwrites files a human wrote. Say so before, and show the damage
# after: `git diff` in the run log is the whole review surface when the pull
# ran in CI, where nothing can be committed.
def warn_metadata_overwrite!(relative_path)
  UI.important("This overwrites #{relative_path}/** with what the console holds. " \
               'Review `git diff` before committing: the console, not this tree, wrote these files.')
end

def report_metadata_diff!(*relative_paths)
  sh('git', 'status', '--porcelain', '--', *relative_paths)
  sh('git', '--no-pager', 'diff', '--stat', '--', *relative_paths)
end
```
Check `play_json_key_args`' actual return shape (`:json_key` vs `:json_key_data`) before relying on it and adapt `with_play_json_key_file` to it. If `google_play_track_version_codes` is not in `DRY_RUN_RESULTS`, add it with `[]`.

- [ ] **Step 4: Run** the tests, then `make check-release`.

- [ ] **Step 5: Commit** `feat(release): add store listing sync helpers` with a body summarising the staging rule and the flag, plus the session trailer.

---

### Task 3: Push lanes and metadata tree

**Files:**
- Modify: `fastlane/lanes/ios.rb` (after `release_production`, before `phased`)
- Modify: `fastlane/lanes/android.rb` (after `release_production`, before `rollout`)
- Create: `fastlane/metadata/ios/primary_category.txt` (`MZGenre.Utilities`), `fastlane/metadata/ios/secondary_category.txt` (`MZGenre.Productivity`), `fastlane/metadata/ios/app_rating_config.json`, `fastlane/metadata/android/en-US/video.txt` (empty), `fastlane/metadata/android/en-US/images/phoneScreenshots/.gitkeep`
- Modify: `fastlane/test/stubs.rb` (snapshot hook), `fastlane/test/lanes_test.rb` (`LaneBehaviourTest`), `fastlane/README.md` (regenerate with `bundle exec fastlane docs`)

**Interfaces:**
- Consumes: every Task 2 helper; `review_information` (~153); `api_key` (~90); `assert_metadata_locales!`, `assert_metadata_ready!`, `assert_ios_metadata_dirs!`.
- Produces: lanes `ios sync_metadata [live:true]` and `android sync_metadata`, called by Task 5's workflow and by PR 2's `store-metadata/scripts/sync.sh`.

- [ ] **Step 1: Test hook.** In `fastlane/test/stubs.rb` add a global `$metadata_snapshots = []` and

```ruby
# Recorded next to the arguments: a lane that stages a copy of the metadata
# tree deletes it the moment the action returns, so the tree's *contents* at
# call time are observable only from inside the stub.
def snapshot_metadata!(args)
  path = args[:metadata_path]
  return if path.nil? || !Dir.exist?(path.to_s)

  $metadata_snapshots << Dir.glob(File.join(path, '**', '*'))
                            .map { |f| f.delete_prefix("#{path}/") }.sort
end
```
called from the generated action stubs' body and cleared in `reset_calls!`. Add `STORE_METADATA_SYNC_ENABLED`, `IOS_METADATA_EDIT_LIVE`, `PLAY_METADATA_TRACK` to `CLEARED_ENV`.

- [ ] **Step 2: Write the failing lane tests** in `LaneBehaviourTest`:
  1. both `sync_metadata` lanes with the flag unset: error names `STORE_METADATA_SYNC_ENABLED`; `refute called?(:upload_to_app_store)` / `:upload_to_play_store`.
  2. iOS push (flag on, ASC env set, clean metadata tree): args have `skip_binary_upload: true`, `skip_app_version_update: true`, `submit_for_review: false`, `run_precheck_before_submit: false`, `edit_live: false`, `force: true`, `skip_metadata: false`; keys `:app_version`, `:automatic_release`, `:phased_release`, `:submission_information` are absent; `metadata_path` differs from `ios_metadata_path`.
  3. iOS snapshot contains `en-US/description.txt` and not `en-US/release_notes.txt`; the working tree's `release_notes.txt` still exists after the lane.
  4. iOS without `APP_REVIEW_*`: no `app_review_information` key and no `review_information/` in the snapshot; with `APP_REVIEW_EMAIL` set: both present.
  5. iOS `live: true` (and separately `IOS_METADATA_EDIT_LIVE=true`): `edit_live: true`, `skip_screenshots: true`, no `app_review_information`.
  6. iOS with a PNG under `fastlane/screenshots/en-US/`: `skip_screenshots: false`, `overwrite_screenshots: true`, `screenshots_path` set and **not** inside `metadata_path`; without: `skip_screenshots: true`, no `screenshots_path`.
  7. iOS passes `app_rating_config_path` only when `app_rating_config.json` exists, and it is inside the staged tree.
  8. iOS refuses placeholder prose, a tree with no locales, and a `screenshots/` directory inside `metadata/ios`, each before any upload.
  9. Android push: `skip_upload_aab: true`, `skip_upload_apk: true`, `skip_upload_changelogs: true`, `skip_upload_metadata/images/screenshots: false`, no `track_promote_to`, `rollout`, `in_app_update_priority`; `track`/`version_code` from the stubbed codes; snapshot has `en-US/title.txt` and no `en-US/changelogs/`.
  10. both under `DRY_RUN=1`: no upload action called, the `[dry-run]` line logged, working tree unchanged.
  11. `release_production` regression: existing assertions untouched and green.
  12. extend `test_every_lane_argument_hash_is_accepted_by_the_real_fastlane_action` with `[:ios, :sync_metadata, {}]`, `[:ios, :sync_metadata, { live: 'true' }]`, `[:android, :sync_metadata, {}]` (that test's env must include the flag). This proves every option name exists in deliver/supply 2.239.0.

- [ ] **Step 3: Run** — expect failures on the missing lanes.

- [ ] **Step 4: Implement.** `fastlane/lanes/ios.rb`:

```ruby
  desc 'Push the baseline store listing from fastlane/metadata/ios to App Store Connect (no binary, no review submission, no release notes)'
  lane :sync_metadata do |options|
    assert_metadata_sync_enabled!
    require_env!(%w[ASC_KEY_ID ASC_ISSUER_ID ASC_KEY_P8_BASE64])
    source = ios_metadata_path
    assert_metadata_locales!(source)
    assert_ios_metadata_dirs!(source)
    assert_metadata_ready!(source)

    # Apple's constraint, not ours: name, subtitle, keywords, categories and
    # screenshots only exist on a version that is being prepared. `live:true`
    # (or IOS_METADATA_EDIT_LIVE) edits the live version instead, which Apple
    # allows for description, promotional text, the URLs and the copyright and
    # nothing else (deliver/lib/deliver/upload_metadata.rb:67).
    live = truthy?(options[:live] || ENV['IOS_METADATA_EDIT_LIVE'])
    # deliver PATCHes every review-detail field it is handed, so the *empty*
    # review_information/*.txt this template ships would clear the contact
    # already configured in App Store Connect. The staged tree keeps that
    # directory only when the APP_REVIEW_* environment has something to put in
    # it - and never in live mode, where review detail is not editable.
    review = live ? {} : review_information
    excluded_dirs = SYNC_EXCLUDED_DIRS + (review.empty? ? %w[review_information] : [])
    screenshots = !live && ios_screenshots?

    with_baseline_metadata(source, exclude_dirs: excluded_dirs) do |staged|
      args = {
        api_key: api_key,
        app_identifier: ENV.fetch('IOS_BUNDLE_ID'),
        metadata_path: staged,
        # No app_version, and skip_app_version_update on top of it: deliver
        # creates or renames a version only when it is given one
        # (deliver/lib/deliver/runner.rb:58). This lane must never move the
        # version App Store Connect is holding, and must never be the thing
        # that opens one.
        skip_app_version_update: true,
        skip_binary_upload: true,
        skip_metadata: false,
        # The three that make this a listing edit rather than a release:
        submit_for_review: false,
        run_precheck_before_submit: false,
        edit_live: live,
        # Neither automatic_release nor auto_release_date: both write the
        # version's releaseType, which belongs to release_production.
        force: true, # no HTML preview to confirm on a runner
        skip_screenshots: !screenshots,
        overwrite_screenshots: screenshots
      }
      if screenshots
        # A sibling of the staged metadata, never inside it: `screenshots` is
        # the one directory name deliver rejects under metadata_path.
        staged_shots = File.join(File.dirname(staged), 'screenshots')
        FileUtils.cp_r(ios_screenshots_path, staged_shots)
        args[:screenshots_path] = staged_shots
      end
      rating = ios_app_rating_config_path(staged)
      args[:app_rating_config_path] = rating if rating
      args[:app_review_information] = review unless review.empty?

      store_action(:upload_to_app_store, **args)
    end
  end
```
`fastlane/lanes/android.rb`:

```ruby
  desc 'Push the baseline store listing from fastlane/metadata/android to Google Play (no binary, no track change, no changelogs)'
  lane :sync_metadata do
    assert_metadata_sync_enabled!
    source = android_metadata_path
    assert_metadata_locales!(source)
    assert_metadata_ready!(source)
    package = ENV.fetch('ANDROID_PACKAGE')
    track, version_code = play_metadata_target
    UI.message("Syncing the Play listing against #{track} version code #{version_code}")

    with_baseline_metadata(source) do |staged|
      store_action(
        :upload_to_play_store,
        package_name: package,
        # The track and version code that are already there, so supply can
        # find the release its listing edit hangs off. Nothing moves: no
        # binary is uploaded, and with no track_promote_to and no rollout
        # supply never touches the track itself (uploader.rb:29-42).
        track: track,
        version_code: version_code,
        skip_upload_aab: true,
        skip_upload_apk: true,
        metadata_path: staged,
        skip_upload_metadata: false,
        skip_upload_images: false,
        skip_upload_screenshots: false,
        # "What's new" is per version and belongs to release_production's
        # write_release_notes!; the staged tree has no changelogs/ either, so
        # this is belt and braces on purpose.
        skip_upload_changelogs: true,
        **play_json_key_args
      )
    end
  end
```
Metadata files: `primary_category.txt` = `MZGenre.Utilities`, `secondary_category.txt` = `MZGenre.Productivity` (no trailing newline issues: match how the other `.txt` files end). `app_rating_config.json`: every `attr_accessor` key of `vendor/.../spaceship/lib/spaceship/connect_api/models/age_rating_declaration.rb` (read it), rating keys `"NONE"`, boolean keys `false`, with a top comment impossible in JSON so instead document it in the runbook (Task 6). `video.txt` empty; the `.gitkeep`. Then `bundle exec fastlane docs` to regenerate `fastlane/README.md`.

- [ ] **Step 5: Run** the tests, `make check-release`, `make check-docs`.

- [ ] **Step 6: Commit** `feat(release): add ios and android sync_metadata lanes` with the session trailer.

---

### Task 4: Pull lanes

**Files:**
- Modify: `fastlane/lanes/ios.rb`, `fastlane/lanes/android.rb` (after each `sync_metadata`), `fastlane/README.md` (regenerate)
- Test: `fastlane/test/lanes_test.rb`

**Interfaces:**
- Consumes: `with_asc_api_key_file`, `with_play_json_key_file`, `warn_metadata_overwrite!`, `report_metadata_diff!`, `ios_screenshots_path`.
- Produces: lanes `ios pull_metadata [live:true]`, `android pull_metadata`.

- [ ] **Step 1: Failing tests:** under `DRY_RUN=1` each pull lane logs a `[dry-run]` line and makes **no** `sh` call (stub `sh` the way the class stubs other Fastlane helpers, or assert via the recorded calls if `sh` is already captured).

- [ ] **Step 2: Implement.** iOS:

```ruby
  desc 'Pull the App Store listing and screenshots into the repo (overwrites local files - review the diff)'
  lane :pull_metadata do |options|
    require_env!(%w[ASC_KEY_ID ASC_ISSUER_ID ASC_KEY_P8_BASE64])
    warn_metadata_overwrite!('fastlane/metadata/ios and fastlane/screenshots')
    bundle_id = ENV.fetch('IOS_BUNDLE_ID')
    live = truthy?(options[:live] || ENV['IOS_METADATA_EDIT_LIVE'])

    if ENV['DRY_RUN'] == '1'
      UI.important("[dry-run] deliver download_metadata + download_screenshots for #{bundle_id} " \
                   "into #{ios_metadata_path} and #{ios_screenshots_path}")
      next
    end

    # Commands, not actions - so they are a subprocess with its own key file.
    with_asc_api_key_file do |key_path|
      common = ['--api_key_path', key_path, '--app_identifier', bundle_id,
                '--use_live_version', live ? 'true' : 'false']
      sh('bundle', 'exec', 'fastlane', 'deliver', 'download_metadata',
         *common, '--metadata_path', ios_metadata_path, '--force')
      sh('bundle', 'exec', 'fastlane', 'deliver', 'download_screenshots',
         *common, '--screenshots_path', ios_screenshots_path)
    end

    report_metadata_diff!('fastlane/metadata/ios', 'fastlane/screenshots')
  end
```
Android:

```ruby
  desc 'Pull the Play listing, images and screenshots into the repo (overwrites local files - review the diff)'
  lane :pull_metadata do
    warn_metadata_overwrite!('fastlane/metadata/android')
    package = ENV.fetch('ANDROID_PACKAGE')
    track = ENV['PLAY_METADATA_TRACK'].to_s.strip
    track = 'production' if track.empty?

    if ENV['DRY_RUN'] == '1'
      UI.important("[dry-run] supply init for #{package} (#{track}) into #{android_metadata_path}")
      next
    end

    require 'tmpdir'
    require 'fileutils'
    # `supply init` refuses to write into a metadata_path that already exists
    # (supply/lib/supply/setup.rb:7), which is every checkout of this
    # template. So it downloads into a staging directory and the tree is
    # updated from it, file by file - a local file supply does not know about
    # (a locale it has never seen) is left where it is.
    Dir.mktmpdir('play-metadata-pull') do |dir|
      staged = File.join(dir, 'android')
      with_play_json_key_file do |key_path|
        sh('bundle', 'exec', 'fastlane', 'supply', 'init',
           '--package_name', package, '--track', track,
           '--metadata_path', staged, '--json_key', key_path)
      end
      FileUtils.cp_r(Dir.glob(File.join(staged, '*')), android_metadata_path)
    end

    report_metadata_diff!('fastlane/metadata/android')
  end
```
Regenerate `fastlane/README.md`.

- [ ] **Step 3: Run** tests, `make check-release`, `make check-docs`.

- [ ] **Step 4: Commit** `feat(release): add pull_metadata lanes for seeding the metadata tree` with the trailer.

---

### Task 5: The dispatch workflow

**Files:**
- Create: `.github/workflows/store-metadata.yml` (model the job shape on `.github/workflows/release-production.yml`)

**Interfaces:**
- Consumes: Task 3/4 lane names; shared-workflows `fastlane-lane.yml@v0` inputs `platform`, `lane`, `runner`, `environment`, `env-json`, `build-env`, `version`, `build-number`, `ios-bundle-id`, `ios-scheme`, `android-package`, `timeout-minutes`, and its declared secrets (check the template's `release-internal.yml` for the exact secret names it forwards).

- [ ] **Step 1: Write the workflow:**

```yaml
name: Store listing
# The store page, not a release. It pushes fastlane/metadata/** to App Store
# Connect and Google Play at any time, independent of a version, and pulls the
# consoles' copy back so the tree can be seeded from what they already hold.
# Per-version release notes stay with CD (release-production.yml): this
# workflow uploads no binary, moves no track, submits nothing for review and
# never writes a version's "What's new".
#
# A pull here can only *report*: this job has `contents: read` and the shared
# lane workflow uploads no artifacts, so the lane ends in `git diff --stat` and
# a real seeding run happens locally (docs/release-runbook.md).
on:
  workflow_dispatch:
    inputs:
      direction:
        description: push writes the consoles from this repo; pull reports what they hold
        type: choice
        required: true
        default: push
        options: [push, pull]
      platforms:
        description: Which stores to act on
        type: choice
        required: false
        default: both
        options: [both, ios, android]
      dry_run:
        description: Rehearse - log every store call and change nothing
        type: boolean
        required: false
        default: true
permissions:
  contents: read
concurrency:
  # The one queue every store-touching job in this repo shares (see the top of
  # release-production.yml): a listing edit and a release submission must not
  # be open against the same app at the same time.
  group: release
  cancel-in-progress: false
jobs:
  ios:
    name: ${{ inputs.direction == 'pull' && 'Pull iOS listing' || 'Push iOS listing' }}
    # Off unless the repository says otherwise, so a fresh checkout of this
    # template cannot overwrite a live store page from a mistaken dispatch.
    # The lane asserts the same variable itself - this only saves the runner.
    if: ${{ vars.STORE_METADATA_SYNC_ENABLED == 'true' && inputs.platforms != 'android' }}
    uses: blinkbitcoin/shared-workflows/.github/workflows/fastlane-lane.yml@v0
    permissions:
      contents: read
    with:
      platform: ios
      lane: ${{ inputs.direction == 'pull' && 'pull_metadata' || 'sync_metadata' }}
      # No Xcode, no binary: the listing is pure App Store Connect API.
      runner: ubuntu-latest
      # Required reviewers live on this environment; a listing edit is as
      # public as a release, so it is gated the same way.
      environment: production
      env-json: >-
        {"STORE_METADATA_SYNC_ENABLED":"${{ vars.STORE_METADATA_SYNC_ENABLED }}",
        "IOS_METADATA_EDIT_LIVE":"${{ vars.IOS_METADATA_EDIT_LIVE }}",
        "DRY_RUN":"${{ inputs.dry_run && '1' || '0' }}"}
      build-env: '{"APP_VARIANT":"production"}'
      # The Fastfile's before_all asserts all five contract variables for every
      # lane, and this one acts on no version at all - so they are filled with
      # the identifiers plus a version of 0.0.0 that nothing reads.
      version: 0.0.0
      build-number: "0"
      ios-bundle-id: ${{ vars.IOS_BUNDLE_ID }}
      ios-scheme: ${{ vars.IOS_SCHEME }}
      android-package: ${{ vars.ANDROID_PACKAGE }}
      timeout-minutes: 60
    secrets:
      ASC_KEY_ID: ${{ secrets.ASC_KEY_ID }}
      ASC_ISSUER_ID: ${{ secrets.ASC_ISSUER_ID }}
      ASC_KEY_P8_BASE64: ${{ secrets.ASC_KEY_P8_BASE64 }}
      # Secrets, not env-json: a reviewer demo login is a real credential and
      # both of those inputs are printed to the log.
      APP_REVIEW_EMAIL: ${{ secrets.APP_REVIEW_EMAIL }}
      APP_REVIEW_FIRST_NAME: ${{ secrets.APP_REVIEW_FIRST_NAME }}
      APP_REVIEW_LAST_NAME: ${{ secrets.APP_REVIEW_LAST_NAME }}
      APP_REVIEW_PHONE: ${{ secrets.APP_REVIEW_PHONE }}
      APP_REVIEW_DEMO_USER: ${{ secrets.APP_REVIEW_DEMO_USER }}
      APP_REVIEW_DEMO_PASSWORD: ${{ secrets.APP_REVIEW_DEMO_PASSWORD }}
      APP_REVIEW_NOTES: ${{ secrets.APP_REVIEW_NOTES }}

  android:
    name: ${{ inputs.direction == 'pull' && 'Pull Android listing' || 'Push Android listing' }}
    if: ${{ vars.STORE_METADATA_SYNC_ENABLED == 'true' && inputs.platforms != 'ios' }}
    uses: blinkbitcoin/shared-workflows/.github/workflows/fastlane-lane.yml@v0
    permissions:
      contents: read
    with:
      platform: android
      lane: ${{ inputs.direction == 'pull' && 'pull_metadata' || 'sync_metadata' }}
      runner: ubuntu-latest
      environment: production
      env-json: >-
        {"STORE_METADATA_SYNC_ENABLED":"${{ vars.STORE_METADATA_SYNC_ENABLED }}",
        "PLAY_METADATA_TRACK":"${{ vars.PLAY_METADATA_TRACK }}",
        "DRY_RUN":"${{ inputs.dry_run && '1' || '0' }}"}
      build-env: '{"APP_VARIANT":"production"}'
      version: 0.0.0
      build-number: "0"
      ios-bundle-id: ${{ vars.IOS_BUNDLE_ID }}
      ios-scheme: ${{ vars.IOS_SCHEME }}
      android-package: ${{ vars.ANDROID_PACKAGE }}
      timeout-minutes: 60
    secrets:
      PLAY_SERVICE_ACCOUNT_JSON: ${{ secrets.PLAY_SERVICE_ACCOUNT_JSON }}
```
Verify each `with:` and `secrets:` key against `fastlane-lane.yml@v0`'s declared inputs/secrets (read it at `/Users/jonas/Dev/blink/shared-workflows/.github/workflows/fastlane-lane.yml`; an undeclared secret is a workflow error). Drop any `APP_REVIEW_*` secret the reusable workflow does not declare, and note it in the report.

- [ ] **Step 2: Run** `make check-ci` (actionlint) and `make check-docs`.

- [ ] **Step 3: Commit** `feat(ci): add the store listing dispatch workflow` with the trailer.

---

### Task 6: Docs and ADR

**Files:**
- Modify: `docs/release-runbook.md` (Variables and secrets table ~289-361; new `## Store listing metadata` after `## Store notes` ~177-234; `## Before you have store accounts` ~235; `## Rehearsing lanes locally (DRY_RUN=1)` ~597)
- Modify: `docs/store-accounts.md` ("Where these values go"), `docs/template-usage.md` (step 3 of "What to do next"), `.env.example`
- Create: `docs/decisions/0018-store-listing-sync-lane.md`; modify `docs/decisions/README.md`

- [ ] **Step 1: Runbook.** Three rows in the variables table (keep each cell within the width `scripts/check-docs-tables.mjs` enforces; use `<br>` like neighbouring rows):
  - `STORE_METADATA_SYNC_ENABLED` | repo variable; both jobs in `store-metadata.yml` and the `sync_metadata` lanes | `true` lets a lane write the public store page. Unset means off and the lane refuses.
  - `IOS_METADATA_EDIT_LIVE` | `ios sync_metadata` / `pull_metadata` via `env-json` | `true` edits the live version's editable subset when no version is in preparation.
  - `PLAY_METADATA_TRACK` | `android sync_metadata` / `pull_metadata` via `env-json` | track whose release the listing edit rides on; default first of `production`, `beta`, `internal` with one.

  New section `## Store listing metadata` after `## Store notes`: `fastlane/metadata/**` is the source of truth; three-column table: *CD owns per version* (release notes / What's new, the binary, the review submission, track and rollout) / *sync owns* (name, subtitle, description, keywords, promotional text, URLs, copyright, categories, age rating, review contact, iOS screenshots under `fastlane/screenshots/<locale>/`, Play icon, feature graphic and screenshots) / *console-only* (Apple: App Privacy labels, pricing and availability, agreements, TestFlight groups, bundle id; Play: content rating, data safety, target audience, app access, countries, tracks and testers). State Apple's constraint (name, subtitle, keywords, categories, screenshots need a version in preparation) and what `IOS_METADATA_EDIT_LIVE` does; that Play reviews listing edits; that a brand-new Play app needs one internal upload first; how to seed with `pull_metadata` and review the diff before committing; that a CI pull only reports; that a `screenshots` directory inside `metadata/ios` is refused and why; that `app_rating_config.json` and the category files are outside the placeholder gate so a wrong value reaches Apple. Add to the `DRY_RUN=1` section:

```bash
export DRY_RUN=1 STORE_METADATA_SYNC_ENABLED=true
export APP_VERSION=0.0.0 APP_BUILD_NUMBER=0
export IOS_BUNDLE_ID=com.example.app IOS_SCHEME=App ANDROID_PACKAGE=com.example.app
export ASC_KEY_ID=DUMMY ASC_ISSUER_ID=DUMMY ASC_KEY_P8_BASE64=DUMMY
export PLAY_SERVICE_ACCOUNT_JSON='{"type":"service_account"}'
bundle exec fastlane ios sync_metadata
bundle exec fastlane android sync_metadata
bundle exec fastlane ios pull_metadata     # logs, downloads nothing
```
  with the note that on the template itself the push lanes stop on `Replace this text`, by design. One line in "Before you have store accounts": the listing tier is independent of `STORE_UPLOADS_ENABLED` and needs the same accounts.

- [ ] **Step 2: Other docs.** `docs/store-accounts.md`, "Where these values go": a pointer to the new section and the note that the Play service account needs "Manage store presence" for a listing edit. `docs/template-usage.md` step 3: after replacing the copy, set `STORE_METADATA_SYNC_ENABLED=true` and run the **Store listing** workflow with `direction: push`, `dry_run: true` first, or seed from an existing app with `direction: pull`. `.env.example`: the three variables, commented, next to `IOS_PHASED_RELEASE`.

- [ ] **Step 3: ADR** `docs/decisions/0018-store-listing-sync-lane.md` in `docs/decisions/template.md`'s shape (read it and ADR 0008 for tone), under 40 lines: Context (the listing was reachable only through a tagged production release, while that lane must remain the only path that touches a version); Decision (additive `sync_metadata`/`pull_metadata` behind `STORE_METADATA_SYNC_ENABLED`, staged-tree exclusion of per-version paths, `release_production` unchanged, iOS screenshots pushed by sync only); Consequences (two writers of one listing so the tree must be the source of truth; a pull overwrites local prose; Apple's edit-version constraint is visible, not hidden); Alternatives rejected (flag-gating `release_production`: regresses ADR 0008's guarantee; bot PR from a CI pull: needs `contents: write` on a credentialed job; console-only edits: no diff, no review trail). Register the row in `docs/decisions/README.md`.

- [ ] **Step 4: Run** `make check-docs` and `make check`.

- [ ] **Step 5: Commit** as two commits: `docs(release): document the store listing sync` (runbook, store-accounts, template-usage, .env.example) and `docs(docs): record the store listing sync decision` (ADR + index), each with the trailer.

---

### Task 7: Full gate, rehearsal, push, PR

- [ ] **Step 1:** `make check` on the final tree. Then `FASTLANE_SKIP_ENV_ASSERT=1 bundle exec fastlane lanes | grep -E 'sync_metadata|pull_metadata'` shows four lanes (if that env var does not exist, use whatever the runbook's "Local builds" section says for listing lanes).
- [ ] **Step 2:** The `DRY_RUN=1` rehearsal block from Task 6 against a scratch copy of the metadata tree with the placeholder replaced (`sed -i '' 's/Replace this text/Real text/'` in a `cp -r` under `mktemp -d`, pointed at via whatever mechanism `ios_metadata_path` honours, or simply run on the template and confirm the lanes stop at `assert_metadata_ready!` with the placeholder message). Confirm `git status --porcelain` is empty afterwards.
- [ ] **Step 3:** Do **not** push and do **not** open a PR: Jonas asked for the branch to stay local. Record the gate and rehearsal results in the SDD report so the handover message can state them. The push and the PR are a separate, later decision.

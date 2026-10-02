# Huawei AppGallery support: lane, secrets, documentation, skills, visual guide

> Superseded in four places during implementation: the optional
> `HUAWEI_SUBMIT_DELAY_SECONDS` variable is also passed through `env-json` and
> listed in `push-to-github.sh` (31 variables, 23 secrets, not 30/23); the
> plugin's app-info helper can return `false` as well as `nil`, so the blank
> check covers both; the submit delay is validated before the credential
> pre-flight; and the lane's comments spell out "Android App Bundle".

## Context

The template family releases to Apple and Google. Huawei AppGallery is today a stub: `fastlane/lanes/future.rb` has an `upload_huawei` lane that raises "Not implemented", `docs/store-accounts.md` has a "Not implemented" Huawei section, and the runbook lists Huawei under "Future stores". Jonas asked to "add huwei appstore support as well + documentation + add to the visual guide". Decisions made:

- **Scope: upload and release only.** The signed Android `.aab` from the existing Android build is uploaded to AppGallery Connect and submitted for review. No Huawei Mobile Services work, no Huawei listing sync (listing fields stay console-only for Huawei).
- **Release tier only.** One job in `release-production.yml`, no internal or beta Huawei jobs.
- **The two credential secrets are declared in shared-workflows too**, because `fastlane-lane.yml` has no pass-through: a secret a caller passes must be declared on the reusable workflow, and `env-json`/`build-env` refuse secret-shaped names (`env-validate.mjs` `SECRETISH` regex).

Credential shape (from AppGallery Connect research, plugin 1.1.3): AppGallery Connect → Users and permissions → API key → Connect API → Create yields a **Client ID** and a **Client Secret** (two strings, no file). The **App ID** is a numeric identifier shown under App information. The app record is created by hand (the Publishing API cannot create apps). App Signing is optional and permanent once enabled. The plugin `fastlane-plugin-huawei_appgallery_connect` 1.1.3 exposes action `huawei_appgallery_connect` with required `client_id`, `client_secret`, `app_id`, `apk_path` and optionals `is_aab`, `submit_for_review`, `delay_before_submit_for_review` (seconds), `changelog_path`, `release_time`, `phase_wise_release`. There is no official Huawei CLI or action; the community plugin is the dependency and its risk.

Names (all spelled out, no invented abbreviations):

| Name | Kind | Where |
| --- | --- | --- |
| `HUAWEI_UPLOADS_ENABLED` | repository variable, toggle | template workflow gate, `TOGGLES_TABLE` |
| `HUAWEI_APP_ID` | repository variable | `env-json` to the lane (not secret-shaped, ends in `_ID`) |
| `HUAWEI_CLIENT_ID` | secret | shared-workflows `fastlane-lane.yml` + template `secrets:` |
| `HUAWEI_CLIENT_SECRET` | secret | shared-workflows `fastlane-lane.yml` + template `secrets:` |

Nothing is pushed. Three local branches: shared-workflows `feat/huawei-secrets` (worktree), template `feat/huawei-appgallery` based on `feat/store-setup-skills` (worktree), and the artifact republished at the same path. Merge order when Jonas pushes: shared-workflows first and released (`feat(release)` → minor bump), because a caller that passes an undeclared secret to a reusable workflow fails validation; then template PR 1, PR 2, then this branch.

---

## Part A: shared-workflows (`feat(release): add Huawei AppGallery secrets to fastlane-lane.yml`)

Worktree `/Users/jonas/Dev/blink/shared-workflows-huawei-secrets`, branch `feat/huawei-secrets` off `main` (211d367).

1. `.github/workflows/fastlane-lane.yml`
   - In `on.workflow_call.secrets`, after `PLAY_SERVICE_ACCOUNT_JSON` (line 127-129) and before the App Review comment block, add:
     ```yaml
           # Huawei AppGallery Connect API client. Both halves are secrets: the
           # client id is one half of the credential pair, and env-json is printed.
           HUAWEI_CLIENT_ID:
             description: AppGallery Connect API client id
             required: false
           HUAWEI_CLIENT_SECRET:
             description: AppGallery Connect API client secret
             required: false
     ```
   - In the `Fastlane lane` step env (line 217 onward, after `PLAY_SERVICE_ACCOUNT_JSON: ${{ secrets.PLAY_SERVICE_ACCOUNT_JSON }}` at 245), add `HUAWEI_CLIENT_ID: ${{ secrets.HUAWEI_CLIENT_ID }}` and `HUAWEI_CLIENT_SECRET: ${{ secrets.HUAWEI_CLIENT_SECRET }}`. The existing test `every credential secret a lane workflow declares reaches EVERY fastlane step's env` (`test/workflow-shape.bats:163`) enforces this; no new test needed for the wiring. `decode-secrets.sh` is untouched (the strings need no decoding).
2. `docs/consumer-guide.md` `fastlane-lane.yml` section (~line 793): extend the "Secrets (all optional)" sentence with the Huawei pair and one sentence: "`HUAWEI_CLIENT_ID` and `HUAWEI_CLIENT_SECRET` are the AppGallery Connect API client the template's `android upload_huawei` lane reads; the numeric `HUAWEI_APP_ID` is configuration and travels in `env-json`." Also add `upload_huawei` to the `lane` input row's Android list.
3. `test/fixtures/consumer-min/fastlane/lanes/` holds only `shared.rb` (a snapshot used by the App Review name-contract test), so no fixture change. A new bats assertion in `test/workflow-shape.bats`: "fastlane-lane declares the Huawei pair" (`yq '.on.workflow_call.secrets | has("HUAWEI_CLIENT_ID") and has("HUAWEI_CLIENT_SECRET")'`), next to the App Review contract test, so a later cleanup cannot drop them silently.
4. `README.md`/`AGENTS.md`: no change unless a secrets list is enumerated there (grep `APP_REVIEW_EMAIL` found only the consumer guide and the fixture).
5. Gate: `make check` + `make unit` + `make test-scripts` (memory: full local gate before push). Commit as above with the session trailer. Do not push.

---

## Part B: template lane, workflow, tests

Worktree `/Users/jonas/Dev/blink/react-native-mobile-template-huawei`, branch `feat/huawei-appgallery` off `feat/store-setup-skills` (dcced5e + 34796c7). `vendor` symlinked like the other worktrees. Commit scopes: `release`, `ci`, `tooling`, `docs` (no `skills` scope; skill commits use `tooling` as on the base branch).

Three facts that shape it (verified):
- **The lane must live under `platform :android`.** shared-workflows `scripts/lib/release-env.sh:29-35` accepts only `ios|android`, and `fastlane.sh:41` runs `bundle exec fastlane "$platform" "$lane"`. A top-level lane is unreachable from CI. New file `fastlane/lanes/huawei.rb`; `future.rb` keeps only Samsung and F-Droid stubs.
- **The production dispatch has no binary in the run.** Every job in `release-production.yml` downloads `artifacts: release-meta` (build-info and store notes only); Apple and Play promote a binary they already hold. Huawei's production dispatch is its *first* upload, and the `.aab` exists only as a **release asset** on the tag (`release-assets.sh` `'*.aab'`, promoted by `release-beta`). So this needs **two jobs**: a small `huawei-binary` staging job (`gh release download --pattern '*.aab'` → `upload-artifact huawei-binary`) plus the `huawei-release` reusable-workflow job with `artifacts: "*"` (merges `release-meta` and `huawei-binary` into `$WORKFLOWS_ASSETS_DIR`, precedent `release-internal.yml:192`). This is a deliberate deviation from "one new job"; the alternative (a release-asset download input on `fastlane-lane.yml`) would widen the shared-workflows change beyond two secret declarations.
- **The plugin fails silently on bad credentials.** Its `get_token` returns `nil` on an authentication error and the upload action then prints "Cannot retrieve token" and returns: a green job that uploaded nothing. The lane pre-flights with `huawei_appgallery_connect_get_app_info` and raises on a blank answer.

### Files
- Create `fastlane/lanes/huawei.rb`; modify `fastlane/Fastfile` (`import 'lanes/huawei.rb'` after android), `fastlane/lanes/future.rb` (drop the Huawei stub), `fastlane/lanes/shared.rb` (`client_id` into `REDACTED_ARG_KEYS` lines 3-7 since it arrives as a GitHub secret; `DRY_RUN_RESULTS` lines 15-21 gain `huawei_appgallery_connect_get_app_info: { 'appName' => '[dry-run]' }` and `huawei_appgallery_connect: nil`; `assert_huawei_uploads_enabled!` beside `assert_metadata_sync_enabled!` ~line 326, same wording pattern naming the variable and the runbook), `fastlane/Pluginfile` (replace the "No plugins" comment; `gem 'fastlane-plugin-huawei_appgallery_connect', '1.1.3'` pinned exactly), `Gemfile.lock` via `bundle install` (the only non-read-only setup step; the vendored bundle gains the gem), `fastlane/release-notes-context.md` limits table row `Huawei AppGallery | changelog | 300 characters, 10 minimum`.

### `fastlane/lanes/huawei.rb`
```ruby
# Huawei AppGallery Connect: upload the signed .aab and submit it for release.
# Binary only: AppGallery's listing fields stay console-only (ADR 0019), so
# there is no sync_metadata counterpart. Lives under `platform :android`
# because shared-workflows' fastlane.sh runs `fastlane <platform> <lane>` and
# accepts only ios or android.
HUAWEI_ENV = %w[HUAWEI_CLIENT_ID HUAWEI_CLIENT_SECRET HUAWEI_APP_ID].freeze
HUAWEI_NOTES_LIMIT = 300      # AppGallery changelog: 10-300 characters
HUAWEI_NOTES_MINIMUM = 10
HUAWEI_SUBMIT_DELAY_SECONDS = 60 # plugin default 10s lands while the bundle is still compiling

def huawei_credentials
  { client_id: ENV.fetch('HUAWEI_CLIENT_ID'), client_secret: ENV.fetch('HUAWEI_CLIENT_SECRET'),
    app_id: ENV.fetch('HUAWEI_APP_ID') }
end

def huawei_submit_delay_seconds
  configured = ENV['HUAWEI_SUBMIT_DELAY_SECONDS'].to_s.strip
  return HUAWEI_SUBMIT_DELAY_SECONDS if configured.empty?
  UI.user_error!("HUAWEI_SUBMIT_DELAY_SECONDS must be a whole number of seconds, got #{configured.inspect}") unless /\A\d+\z/.match?(configured)
  configured.to_i
end

# The plugin's get_token returns nil on an authentication failure and the upload
# action then only prints a message: a wrong secret would be a green job that
# uploaded nothing. Asking for the app record first makes it red before any
# binary moves.
def assert_huawei_credentials!(credentials)
  info = store_action(:huawei_appgallery_connect_get_app_info, **credentials)
  return unless info.nil? || (info.respond_to?(:empty?) && info.empty?)
  UI.user_error!("AppGallery Connect returned no app record for HUAWEI_APP_ID #{ENV.fetch('HUAWEI_APP_ID')}: " \
                 'the client id/secret pair is wrong or revoked, or the app id belongs to another team (see docs/release-runbook.md)')
end

def with_huawei_changelog
  require_env!(%w[RELEASE_NOTES_STORE_FILE])
  text = store_notes(HUAWEI_NOTES_LIMIT)
  if text.length < HUAWEI_NOTES_MINIMUM
    UI.important("Release notes are #{text.length} characters, below AppGallery's #{HUAWEI_NOTES_MINIMUM}-character floor - uploading without a changelog")
    return yield(nil)
  end
  if ENV['DRY_RUN'] == '1'
    UI.important("[dry-run] would write an AppGallery changelog (#{text.length} chars)")
    return yield('[dry-run]/changelog.txt')
  end
  require 'tmpdir'
  Dir.mktmpdir('huawei-changelog') do |dir|
    path = File.join(dir, 'changelog.txt')
    File.write(path, "#{text}\n")
    yield(path)
  end
end

platform :android do
  desc 'Upload the AAB to Huawei AppGallery Connect and submit it for release'
  lane :upload_huawei do |options|
    assert_huawei_uploads_enabled!   # per-store gate on top of STORE_UPLOADS_ENABLED
    require_env!(HUAWEI_ENV)
    build_info                       # artifact belongs to this version/build number
    aab = options[:aab] || File.join(artifact_dir('android'), 'app-release.aab')
    UI.user_error!("No AAB at #{aab} - the huawei-binary job stages it from the release tag") unless File.exist?(aab) || ENV['DRY_RUN'] == '1'
    credentials = huawei_credentials
    assert_huawei_credentials!(credentials)
    # No idempotency query: get_app_info returns app-level fields, no package
    # version. A re-run re-uploads and Huawei rejects a duplicate version code.
    args = credentials.merge(apk_path: aab, is_aab: true, submit_for_review: true,
                             delay_before_submit_for_review: huawei_submit_delay_seconds)
    with_huawei_changelog do |path|
      args[:changelog_path] = path if path
      store_action(:huawei_appgallery_connect, **args)
    end
  end
end
```
(`store_notes(limit)` and `build_info` are the existing helpers `write_release_notes!` uses in `shared.rb`; confirm the exact name of the notes reader at implementation time and reuse it rather than re-reading `RELEASE_NOTES_STORE_FILE`.)

### Tests
- `fastlane/test/stubs.rb`: `huawei_appgallery_connect` and `huawei_appgallery_connect_get_app_info` into `STUBBED_FASTLANE_ACTIONS` (55-60) and the stub hash (62-82; get_app_info stub returns `{ 'appName' => 'Stub' }`).
- `fastlane/test/validate_options.rb`: after `Fastlane.load_actions` add `Fastlane.plugin_manager.load_plugins(print_table: false)` with a comment (core loader never loads plugins). Chosen over a skip-when-absent guard: the Huawei action is the one action whose option names nobody has typed before and has `conflicting_options`; `bundle check` is already a hard precondition of `make check-release`, so "gem absent" is a state the suite need not tolerate.
- `fastlane/test/lanes_test.rb`: `require_relative '../lanes/huawei'`; `ENV_DEFAULTS` gains `HUAWEI_CLIENT_ID => 'huawei-client'`, `HUAWEI_CLIENT_SECRET => 'huawei-secret'`, `HUAWEI_APP_ID => '123456789'`; `CLEARED_ENV` gains `HUAWEI_UPLOADS_ENABLED HUAWEI_SUBMIT_DELAY_SECONDS` (toggle off by default like `STORE_METADATA_SYNC_ENABLED`). Rewrite line 1858 to iterate `%i[upload_samsung fdroid_metadata]` plus `test_upload_huawei_is_no_longer_a_top_level_future_stub` (`run_lane(nil, :upload_huawei)` raises). New "Huawei AppGallery" section: argument hash (apk_path under `artifacts/android/app-release.aab`, the three credentials, `is_aab: true`, `submit_for_review: true`, delay 60, `changelog_path` present and not under `fastlane/metadata`, no `phase_wise_release`/`release_time`); pre-flight ordering (`$calls` index of get_app_info < upload); refusal when get_app_info stubbed to `nil` (message names `HUAWEI_APP_ID`, no upload call); refusal with the toggle off (names `HUAWEI_UPLOADS_ENABLED`, neither action called); refusal when `HUAWEI_CLIENT_SECRET` deleted and `HUAWEI_APP_ID` blank (both named, `HUAWEI_CLIENT_ID` not); delay override `180` honoured and `soon` rejected; notes below the floor omit `changelog_path`. Redaction test beside line 229: dry-run log for `huawei_appgallery_connect` contains neither credential value and does contain `"app_id":"123456789"`. Replay list (1918-1932) gains `[:android, :upload_huawei, {}]` with `ENV['HUAWEI_UPLOADS_ENABLED'] = 'true'` beside the metadata flag at 1901; `changelog_path` is a plain String option with no verify block, so no substitution is needed (one-line comment).

### `release-production.yml` (insert after `android-release`, ~line 147)
```yaml
  # ---- action=release: Huawei AppGallery (opt-in, additional store) ---------
  # The one store whose production dispatch is a first upload: the .aab is a
  # release asset on the tag, not an artifact of this run, so stage it back.
  huawei-binary:
    name: Stage Huawei binary
    needs: prepare
    if: ${{ vars.STORE_UPLOADS_ENABLED == 'true' && vars.HUAWEI_UPLOADS_ENABLED == 'true' && inputs.action == 'release' && inputs.platforms != 'ios' }}
    runs-on: ubuntu-latest
    timeout-minutes: 10
    permissions:
      contents: read
    steps:
      - name: Download the AAB from the release tag
        env:
          GH_TOKEN: ${{ github.token }}
          GH_REPO: ${{ github.repository }}
          TAG: ${{ inputs.tag }}
        run: |
          set -euo pipefail
          mkdir -p staged
          gh release download "$TAG" --pattern '*.aab' --dir staged
          ls -l staged
      - uses: actions/upload-artifact@v7
        with:
          name: huawei-binary
          path: staged/*.aab
          compression-level: 0
          if-no-files-found: error

  huawei-release:
    name: Release Huawei
    # android-release too: AppGallery should not receive a release Play refused.
    needs: [prepare, android-release, huawei-binary]
    if: ${{ vars.STORE_UPLOADS_ENABLED == 'true' && vars.HUAWEI_UPLOADS_ENABLED == 'true' && inputs.action == 'release' && inputs.platforms != 'ios' }}
    uses: blinkbitcoin/shared-workflows/.github/workflows/fastlane-lane.yml@v0
    permissions:
      contents: read
    with:
      platform: android
      lane: upload_huawei
      runner: ubuntu-latest
      environment: production
      artifacts: "*"           # release-meta (build-info, notes) + huawei-binary (.aab)
      env-json: '{"HUAWEI_APP_ID": "${{ vars.HUAWEI_APP_ID }}", "HUAWEI_UPLOADS_ENABLED": "${{ vars.HUAWEI_UPLOADS_ENABLED }}"}'
      build-env: '{"APP_VARIANT":"production"}'
      version: ${{ needs.prepare.outputs.version }}
      build-number: ${{ needs.prepare.outputs.build-number }}
      ios-bundle-id: ${{ vars.IOS_BUNDLE_ID }}
      ios-scheme: ${{ vars.IOS_SCHEME }}
      android-package: ${{ vars.ANDROID_PACKAGE }}
      timeout-minutes: 90      # the plugin polls AppGallery's bundle compilation before submitting
    secrets:
      HUAWEI_CLIENT_ID: ${{ secrets.HUAWEI_CLIENT_ID }}
      HUAWEI_CLIENT_SECRET: ${{ secrets.HUAWEI_CLIENT_SECRET }}
```
Copy the `env-json`/`build-env`/`tag` input names from the existing `android-release` job verbatim. `github-release` and `stage-note` `needs` stay unchanged: Huawei is additive and a slow third-party store must not block marking the release latest, the update publish or the web deploy. The toggle is passed through `env-json` on purpose so the lane's own assert is a real gate on a laptop too. `.env.example` gains four commented lines after the Play block.

### Commits (template)
1. `feat(release): upload the signed bundle to Huawei AppGallery and submit it` (lane, Fastfile, future.rb, shared.rb, Pluginfile, Gemfile.lock, stubs, validate_options, lanes_test, release-notes-context).
2. `feat(ci): add the Huawei AppGallery release jobs to the production dispatch` (release-production.yml only; the commit that cannot merge before shared-workflows ships).
3. `feat(tooling): add the Huawei console, credential and toggle steps to the store skills` (all of `.claude/skills/**` plus the four new names in the runbook tables, because `store-credentials/tests/run.sh:666-691` diffs the class table against that document).
4. `docs(docs): document the Huawei AppGallery release path` (store-accounts, template-usage, docs/README, .env.example, runbook subsection and future-stores rewrite).
5. `docs(docs): record ADR 0019, the Huawei AppGallery release lane`.
Every commit with the session trailer; nothing pushed.

---

## Part C: documentation (template)

- `docs/store-accounts.md` "Huawei AppGallery" section (lines 167-188): replace "Not implemented" with the implemented flow, in the same shape as the Apple and Google sections: account (free, identity verification takes days, the country cannot be changed later), console entry, numbered steps carrying the new step ids (`huawei-account`, `huawei-app-record`, `huawei-api-client`, `huawei-app-signing`, `huawei-listing`), what each credential can reach, "Where these values go" rows. Keep the Google Play Services caveat (runtime dependencies need a Huawei Mobile Services equivalent) as a warning, now scoped as "out of scope for the lane". Samsung section unchanged.
- `docs/release-runbook.md`: variables table gains `HUAWEI_UPLOADS_ENABLED` and `HUAWEI_APP_ID`; secrets table gains `HUAWEI_CLIENT_ID`, `HUAWEI_CLIENT_SECRET` (`Used by` = `Release / Huawei`), cells inside the width `scripts/check-docs-tables.mjs` enforces. New subsection under the production release steps: "Huawei AppGallery" (release tier only, same `.aab`, submit for review after upload, review takes days, no listing sync, listing edited in the console). "Future stores" table loses the Huawei row and its intro sentence changes to two stubs. `DRY_RUN=1` rehearsal section gains `DRY_RUN=1 bundle exec fastlane android upload_huawei`.
- `docs/template-usage.md` step 3: one sentence that Huawei is optional and turned on with `HUAWEI_UPLOADS_ENABLED` after the Huawei steps of the skill.
- `docs/README.md`: row 36 already says "Apple, Google, Huawei and Samsung"; no change. `.env.example`: four commented variables.
- ADR `docs/decisions/0019-huawei-appgallery-release-lane.md` plus its row in `docs/decisions/README.md`: decision (community plugin, release tier only, toggle separate from `STORE_UPLOADS_ENABLED`, listing console-only), alternatives rejected (raw Publishing API calls in Ruby: more code to own; a community GitHub Action: a second upload path outside fastlane and outside `DRY_RUN`; internal-testing tier: out of scope until someone needs it), consequences (first plugin in `Pluginfile`, validate_options must load it).
- No invented abbreviations anywhere (AGENTS.md rule).

---

## Part D: skills (template `.claude/skills/`)

### Step ids: appended, never inserted
`state.sh`'s `STEPS_TABLE` order is an interface (two suites diff `--list-steps` positionally), so the Huawei block is appended after `store-ready`:
```
huawei-account|consoles|toggle-uploads
huawei-app-record|consoles|huawei-account
huawei-api-client|consoles|huawei-account
cred-huawei|credentials|huawei-api-client,huawei-app-record
huawei-app-signing|consoles|huawei-app-record
huawei-listing|consoles|huawei-app-record
toggle-huawei|setup|cred-huawei,huawei-listing,huawei-app-signing
```
`huawei-account` needing `toggle-uploads` is the load-bearing edge: the Huawei block stays out of `state.sh next` until the Apple and Play path works, `cred-huawei` stays out of `cred-push`'s needs, and `store-ready` is reached exactly as before by a repository that never ships on AppGallery. 41 → **48** steps, 21 → **26** console ids. `state.sh note huawei_app_id <numeric>` is accepted by the credential-key refusal (not credential-shaped).

### `store-consoles`
- New `references/huawei.md`, same eight fields in the same order as `apple.md`/`google.md`, `Console:` carrying `Name — https://url`:
  - `huawei-account` (Huawei Developer account and identity verification; `binding`: agreement accepted in the human's or organisation's name, identity documents submitted, the account country cannot be changed later; days, not hours).
  - `huawei-app-record` (AppGallery Connect → My apps → New; `irreversible`: the package name is entered here and fixes what the record can publish; the API cannot create apps; the numeric App ID appears under App information → `HUAWEI_APP_ID`, a repository variable).
  - `huawei-api-client` (Users and permissions → API key → Connect API → Create; name, Project = N/A for team level, roles limited to app administration; `irreversible`: the Client Secret is shown once; browser mode stops before Create, the human clicks and pastes both strings into the validator; take away `HUAWEI_CLIENT_ID`, `HUAWEI_CLIENT_SECRET`).
  - `huawei-app-signing` (optional; `permanent`: once enabled Huawei re-signs every bundle; manual signing with the repository's upload key is accepted and is the template's default, so the block says plainly the reversible path is the default).
  - `huawei-listing` (icon 216×216 PNG, at least three screenshots 16:9 or 9:16 at most 2 MB, privacy policy URL, category, age rating questionnaire 3+/7+/12+/15+/18+, release countries, pricing; `safe`: a draft listing publishes nothing, the lane's submit is the public step; questionnaire answered only in mode (c) from answers given in that turn; note `targetSdkVersion` 30 or higher and 64-bit are required and already true of this template; items research could not verify (exact menu wording, review time "days") are marked "verify on screen").
- `scripts/console-step.sh`: `HUAWEI_REF` beside the Apple and Google reference variables; five ids appended to `STEP_IDS` in table order; `huawei-*)` case in `reference_file_for`; `huawei-api-client` added to `CREDENTIAL_IDS` (its take-away is a pasted secret string, so `--format json` exits 2); header comment "21" → 26.
- `tests/run.sh`: regex `^(apple|google)-` → `^(apple|google|huawei)-` (line 71); `$HUAWEI_MD` added to both heading round-trip `grep -ohE` calls (lines 98 and 107); the non-safe id list gains `huawei-account`, `huawei-app-record`, `huawei-api-client`, `huawei-app-signing`; one assertion that `huawei-listing` is safe and its block says why (mentions submit).
- `SKILL.md`: "21 console ids" → 26; a Huawei paragraph.

### `store-credentials`
- New `scripts/validate-huawei-credentials.sh`, shaped on `validate-play-json.sh` (`FAILURES` array, `OK:`/`FAIL:` lines, exit 0/1/2/64). Values from `HUAWEI_CLIENT_ID` and `HUAWEI_CLIENT_SECRET` in the environment, never argv. Offline: client id present, digits only, no whitespace, warn under 15 digits; secret present, hexadecimal, at least 32 characters, no whitespace; neither equal to a placeholder or to the other; `--app-id` digits only with no leading zero (catches a package name pasted as the app id). Never echoes a value (lengths and character classes only). `--check-access` (network, asks `y/N` unless `--yes`): POST `https://connect-api.cloud.huawei.com/api/oauth2/v1/token` with a request body written by `node` from the environment into a `umask 077` temp file (`--data-binary @file`); success is a non-empty `access_token`, and a 200 with `ret.code != 0` is a failure (the shape the plugin swallows); with `--app-id`, GET `/api/publish/v2/app-info?appId=…` and print the app name.
- `scripts/push-to-github.sh`: `VARIABLE_NAMES` += `HUAWEI_APP_ID HUAWEI_UPLOADS_ENABLED` (30); `SECRET_NAMES` += `HUAWEI_CLIENT_ID HUAWEI_CLIENT_SECRET` (23); `TOGGLES_TABLE` row `HUAWEI_UPLOADS_ENABLED|HUAWEI_CLIENT_ID HUAWEI_CLIENT_SECRET HUAWEI_APP_ID`. Not added to `STORE_UPLOADS_ENABLED`'s set (opt-in store). No `WARN_TOGGLES_TABLE` row.
- `SKILL.md`: `allowed-tools` entry for the new script; `### cred-huawei` section with the two invocations; `--check-access` listed under Ask First; counts 28/21 → 30/23.
- `tests/run.sh`: `EXPECTED_SCRIPTS` gains the script ("all six" → "all seven"); new offline cases: missing variable → 1, non-numeric client id → 1, secret with an embedded newline → 1, well-formed pair → 0 with neither fixture value in the output, `--check-access` without `--yes` and stdin closed → 2 and no network call (fake `curl` on PATH that fails the test if invoked). The runbook class-table diff (666-691) passes only once the four names are in the runbook tables, which is why commit 3 carries those rows.

### `store-setup`
- `SKILL.md` checklist: seven rows appended in table order; a paragraph that the Huawei block is an optional extra store gated on `toggle-uploads`, and `state.sh set <id> skipped` is the right answer for a repository that does not ship on AppGallery. Do **not** touch the mode prompt wording (asserted verbatim by tests at 342 and 356); "roughly forty" stays correct for the non-optional path.
- Always-confirm table in both `SKILL.md` (38-47) and `references/modes.md` (17-26), kept in step by a test: two rows, "Enrolling the app in AppGallery App Signing | permanent for that app" and "Entering the package name on a new AppGallery app record | fixes what that record can ever publish".
- `tests/run.sh`: `EXPECTED_STEPS` gains the seven ids; the three hardcoded `41`s (lines 192, 270, 348) and the comment at 118 → 48.
- `scripts/state.sh` header comment gains a clause about optional stores.
- `store-metadata`: no change (AppGallery listing is console-only; say so in its SKILL.md in one sentence).
- `scripts/init.manifest.json`: no change; existing globs already cover `store-consoles/references/*.md` and `store-credentials/scripts/*.sh`.

---

## Part E: visual guide artifact

File `/private/tmp/claude-501/-Users-jonas-Dev-blink-app-boilerplate/a561bf43-df62-4e4a-9d76-77514cacbf95/scratchpad/store-flows.html`, republished at the same path (URL https://claude.ai/code/artifact/61cee2cf-28df-4603-aec0-4b2bb33a36d5, title and favicon unchanged).

1. **Tokens**: add `--huawei` / `--huawei-fill` (a red-leaning hue distinct from the Apple and Google tokens, defined on bare `:root`, redefined in both dark blocks).
2. **New swimlane section** "Huawei: AppGallery Connect" after the Google section, same four lanes (Human / Agent in Chrome / Local scripts / GitHub repository), viewBox `0 0 1160 430`, marker id `ah`. Boxes: Human "Register developer account, identity verification, days" (gate, dashed); Agent "Create application record, package name entered here" → gate "Enable App Signing, permanent, optional" → "Create API client, Connect API, team level" → "Listing, age rating, privacy policy (console only)"; Local "validate-huawei-credentials.sh, shape offline, token check asks"; GitHub "gh secret set HUAWEI_CLIENT_ID, HUAWEI_CLIENT_SECRET" and "gh variable set HUAWEI_APP_ID, HUAWEI_UPLOADS_ENABLED". Muted labels: "client id + secret, two strings", "stdin only", "mode (c) only, read back" on the questionnaire box. Caption: App Signing is the permanent gate; the API client is team-level so it must be scoped by role, not by project; nothing in the listing is synced by the pipeline.
3. **Delivery pipeline**: viewBox height 300 → 380; add a Huawei box at the release column: "AppGallery release, review, days" (`--huawei-fill`) fed from the Android build's `.aab` by a path from the Pre-release node with muted label "release tier only, HUAWEI_UPLOADS_ENABLED", and move the production gate box down to keep clearances. Update the aria-label and caption ("Huawei receives the same signed Android bundle on a release and goes straight to review").
4. **Conceptual screens**: new `<h3>AppGallery Connect</h3>` group with four `screen()`-generated figures in the existing wireframe style (ochre button last in draw order): "Create the application record" (name, default language, category, package name, App ID shown after create); "Create the API client" (Users and permissions → API key → Connect API; name, Project = N/A, roles; the human clicks Create; Client ID and Client Secret shown once); "Enable App Signing" (upload key certificate, permanent, waits for a yes); "Submit for release" (the version the lane uploaded, release countries, review notice). The Python generator used for the existing screens is regenerated the same way.
5. **Mode matrix**: rename the Play row to "Play App Signing, Huawei App Signing, first Play upload"; add row "Huawei API client creation" (agent after a yes / human / agent after a yes, the secret is shown once and pasted to the validator, never stored).
6. **Where each part lives**: step count 41 → N (from Part D), console steps 21 → N+5, add "Huawei listing is console-only; `store-metadata` does not cover AppGallery".
7. Publish once with the Artifact tool (same file path; omit favicon).

---

## Verification

- shared-workflows: `make check && make unit && make test-scripts` green; `yq '.on.workflow_call.secrets | keys' .github/workflows/fastlane-lane.yml` lists the pair; the env-parity bats test passes.
- Template, in order:
  1. `bundle install` (adds the plugin to the vendored bundle and `Gemfile.lock`), then `ruby -e 'require "fastlane"; Fastlane.load_actions; Fastlane.plugin_manager.load_plugins(print_table: true)'` lists the plugin.
  2. `FASTLANE_SKIP_ENV_ASSERT=1 bundle exec fastlane lanes` shows `android upload_huawei` and no top-level `upload_huawei`; `bundle exec ruby -Ifastlane/test fastlane/test/lanes_test.rb` green (the replay test now validates the plugin's option names).
  3. `DRY_RUN=1` rehearsal with dummy values (`HUAWEI_UPLOADS_ENABLED=true`, the three `HUAWEI_*`, an empty `artifacts/android/app-release.aab`, a notes file, a build-info file): the log shows `[dry-run] huawei_appgallery_connect_get_app_info {"client_id":"[redacted]","client_secret":"[redacted]","app_id":"987654321"}` followed by the upload line with `"is_aab":true,"submit_for_review":true,"delay_before_submit_for_review":60,"changelog_path":"[dry-run]/changelog.txt"`. Then the negatives: toggle unset names `HUAWEI_UPLOADS_ENABLED`; `HUAWEI_CLIENT_SECRET=` names the missing variable; neither reaches a `[dry-run]` line.
  4. Skills: the four `tests/run.sh` suites; `state.sh --list-steps | wc -l` = 48; `console-step.sh huawei-api-client` prints the block and `--format json` on it exits 2; `validate-huawei-credentials.sh` with fake values exits 0 and echoes no value.
  5. `make check` (actionlint, shellcheck over the skills, table widths, `check-skills`) and `make init --dry-run`.
- Artifact: one look at the rendered page, then publish.

## Risks

- Community plugin (`shr3jn`) is the only upload path; pinned exactly at `1.1.3` (single maintainer, undocumented API stability); the fallback (Publishing API by hand) is noted in the ADR. It is the first `Pluginfile` entry, so `bundle install` becomes load-bearing for `make check-release` and its absence fails the replay test with "no such fastlane action".
- Silent success remains possible after the pre-flight: the plugin submits only `if upload_app["success"]`, so a mid-flight upload failure is still a green lane. Accepted for now and recorded in the ADR consequences; the follow-up is a post-upload `get_app_info` asserting the release state moved.
- Submit-for-review immediately after upload can fail on Huawei's side; the lane passes a 60-second delay (`HUAWEI_SUBMIT_DELAY_SECONDS` overrides) on top of the plugin's compilation polling, and the job timeout is 90 minutes. If it stays flaky, the next move is `submit_for_review: false` plus a separate submit lane, which the plugin also exposes.
- `huawei-binary` fails loudly when the tag has no `.aab` (release created by hand, beta promote skipped or its pre-release deleted first); the failure is contained to the two Huawei jobs, and the runbook says re-running the beta promote is the fix.
- `HUAWEI_UPLOADS_ENABLED` is checked in three places (two job `if`s, the lane assert, the `TOGGLES_TABLE` row); deliberate, but the `TOGGLES_TABLE` row has no test that would catch its absence.
- `HUAWEI_APP_ID` is printed to the log via `env-json`; it is an identifier, not a credential, and the store-accounts page says so.
- Console labels drift; the reference blocks use entry-point-plus-path and the "unverified" items from research (exact menu wording, review time) are marked as such in `references/huawei.md`.
- Merge-order dependency on shared-workflows (see Context).

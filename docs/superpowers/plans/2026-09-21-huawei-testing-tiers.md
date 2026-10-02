# Huawei AppGallery on every tier: internal test on push, open test on release

## Context

Huawei AppGallery joined the template at the release tier only (PR #44, ADR 0019), because that was the option chosen at the time. Jonas now wants parity with Apple and Google: a Huawei job on the internal tier (every push to main) and on the beta tier (every release), alongside the existing production job. Everything stays behind `HUAWEI_UPLOADS_ENABLED` on top of `STORE_UPLOADS_ENABLED`, and a Huawei failure must never block a pre-release, the GitHub release, the update publish or the web deploy.

What AppGallery actually offers, and why the design is not a copy of the Play tracks:

- **One version slot per app.** There are no separate tracks. "Internal" testing is the open-testing feature with the "free of manual review" flag (up to 100 testers, automated review, hours, 90-day window). "Open" testing is the same submission with manual review (up to 5,000 testers, 1 to 3 working days). The formal release is that same version with the testing flag turned off. A testing version under review blocks another testing submission on the same app.
- **Testers are console user lists**, invited by email, installing through the AppGallery app. Nothing in the API manages them.
- **The plugin** (`fastlane-plugin-huawei_appgallery_connect` 1.1.3) drives testing through `use_testing_version: true` plus `skip_manual_review` (true = internal-style, false = open testing with review), `test_start_time`/`test_end_time` (defaults now+1h and +80 days), and `feedback_email`. Those fields are not in Huawei's published `app-submit` reference; the plugin reverse-engineered them from the console. Same-versionCode re-upload behaviour is undocumented.
- **The binary**: the internal tier has the fresh `.aab` as a run artifact (`artifacts: "*"` after `build-android`); the beta tier does not, so it needs the same `huawei-binary` staging job as production, running after `github-release` moves the assets onto `v<version>`.

Consequences for the pipeline: one lane helper with three submit flavours (skip review, manual review, release), a pre-submit check of the app record's release state so a review in flight makes the push job skip rather than fail, and the Huawei jobs kept outside every downstream `needs`.

Names added (all spelled out): repository variables `HUAWEI_FEEDBACK_EMAIL` (tester feedback address, optional) and `HUAWEI_TEST_DAYS` (test window length, default 80, at most 89). New lanes `android upload_huawei_internal` and `android promote_huawei_beta`; `android upload_huawei` unchanged. New skill step `huawei-testers`. ADR 0020 supersedes the "beta tier as well: rejected" bullet of ADR 0019.

Delivery: one branch `feat/huawei-testing-tiers` off main in a worktree, sequential commits, one pull request (a single branch, so no stack tooling needed). Nothing pushed until Jonas says so.

Two facts found while designing that shape the code:
- The plugin's default test window formats a **local** time with a hardcoded `+0000` suffix, so it is wrong off a non-UTC machine. The lane always passes both `test_start_time` and `test_end_time`, computed in UTC; `Time.parse` keeps the offset, so the values round-trip byte-exact.
- The app-info query returns `releaseState` (official reference): 0 released, 3 releasing, 4 reviewing, 5 pending update review, 7 draft, 12 under pre-review, and others. Whether a *testing* submission moves it into 3/4/5/12 is unverified, so the under-review skip is **fail-open**: a missing or unknown state takes the upload path. It can withhold an upload, never fail a job.

Setup: `git -C /Users/jonas/Dev/blink/react-native-mobile-template fetch origin`, worktree `/Users/jonas/Dev/blink/react-native-mobile-template-huawei-tiers` on `feat/huawei-testing-tiers` off `origin/main` (8c2c057; the old `feat/huawei-appgallery` worktree is stale and must not be the base). `vendor` symlink as before; `pnpm install --frozen-lockfile`.

---

## Part A: lanes, `fastlane/lanes/huawei.rb` (commit 1, `feat(release)`)

Constants: `HUAWEI_TEST_DAYS = 80`, `HUAWEI_TEST_DAYS_MAX = 89` (AppGallery caps at 90), `HUAWEI_BUSY_RELEASE_STATES = [3, 4, 5, 12]` with a names hash for the message.

`assert_huawei_credentials!` returns `info` on success (one line change) so the caller reads the state without a second call.

New helpers:
- `huawei_test_days`: `HUAWEI_TEST_DAYS` env, whole positive number else `UI.user_error!`; above the ceiling → `UI.important` and 89.
- `huawei_test_window(days)`: `start = Time.now.utc + 3600`, both ends `strftime('%Y-%m-%dT%H:%M:%S+0000')`.
- `huawei_version_busy(info)`: reads `releaseState` (string or symbol key, digits only), returns the state name when in the busy list, else nil.
- `huawei_testing_submit(skip_manual_review:)`: `{ use_testing_version: true, skip_manual_review: }` plus `feedback_email` **only when** `HUAWEI_FEEDBACK_EMAIL` is non-blank (the plugin puts the key in the body unconditionally).
- `huawei_upload!(aab: nil, submit: {})`: the whole current lane body (toggle assert, `require_env!`, `build_info`, AAB path check, delay validated first, window merged when `submit[:use_testing_version]`, credential pre-flight returning `info`), then the busy check with `UI.important("AppGallery already has a version <state> for app <id> - skipping the upload. A version under review blocks the next submission; re-run this job once the console shows it cleared")` and `return`, then `args = credentials.merge(apk_path:, is_aab: true, submit_for_review: true, delay_before_submit_for_review:).merge(submit)` inside `with_huawei_changelog` → `store_action(:huawei_appgallery_connect, **args)`.

Lanes under `platform :android`:
- `upload_huawei_internal` → `huawei_upload!(aab: options[:aab], submit: huawei_testing_submit(skip_manual_review: true))`
- `promote_huawei_beta` → same with `skip_manual_review: false`
- `upload_huawei` → `huawei_upload!(aab: options[:aab])` (no testing body; the release tier's only change is the shared helper and the busy skip).

**Beta re-uploads from the tag rather than submitting the internal package**: the internal submission may have been skipped (busy slot) or superseded by later pushes, the release tier already re-uploads, and `build_info` on the staged bundle gives the same bytes-from-the-tag guarantee Play and TestFlight promotions have. Same-versionCode re-upload is unverified; if AppGallery rejects it the fallback is `huawei_appgallery_connect_submit_for_review` guarded by `info['versionCode'] == APP_BUILD_NUMBER`, recorded in ADR 0020.

### Tests (`fastlane/test/lanes_test.rb`, same commit)
- `CLEARED_ENV` += `HUAWEI_FEEDBACK_EMAIL HUAWEI_TEST_DAYS`; `ENV_DEFAULTS` unchanged (both optional, so absent by default). No stubs or `DRY_RUN_RESULTS` changes (no new action).
- New tests: internal argument hash (`use_testing_version` true, `skip_manual_review` true, credentials, `apk_path`, `is_aab`, `submit_for_review`, delay 60, changelog, no `phase_wise_release`/`release_time`); beta hash with `skip_manual_review` false; `feedback_email` absent when unset and equal to the variable when set; window from `HUAWEI_TEST_DAYS=7` (`+0000` format, end minus start = 7 days, start within 120 s of `Time.now.utc + 3600`); ceiling at 365 → 89 days and a message naming 89; non-numeric days refused; busy skip per lane over states `[3, 4, 5, 12, '4']` (no upload, message contains "skipping the upload"); fail-open over `[nil, 0, 7, 99, 'unknown']` (upload called); release lane still has neither testing key; toggle-off and missing-env refusals for the new lanes via two extracted helpers called for all three lanes.
- Replay list gains `[:android, :upload_huawei_internal, {}]` and `[:android, :promote_huawei_beta, {}]` with `HUAWEI_FEEDBACK_EMAIL` set, so `validate_options.rb` checks the five new option names against the real plugin.
- Redaction test: assert `"feedback_email"` appears in the clear in the dry-run log.

---

## Part B: workflows (commit 2, `feat(ci)`)

`release-internal.yml`, after `upload-android`: job `upload-huawei` ("Upload Huawei"), job-level `concurrency: group: release, cancel-in-progress: false`, `if: vars.STORE_UPLOADS_ENABLED == 'true' && vars.HUAWEI_UPLOADS_ENABLED == 'true'`, `needs: [prepare, build-android]`, `fastlane-lane.yml@v0`, `platform: android`, `lane: upload_huawei_internal`, `environment: internal`, `artifacts: "*"`, `env-json` with `HUAWEI_APP_ID`, `HUAWEI_UPLOADS_ENABLED`, `HUAWEI_SUBMIT_DELAY_SECONDS`, `HUAWEI_FEEDBACK_EMAIL`, `HUAWEI_TEST_DAYS`, the usual version/build-number/identifier inputs copied from `upload-android`, `timeout-minutes: 90`, `secrets:` the client pair. `github-prerelease` `needs` unchanged; add one sentence to its comment saying the Huawei job is deliberately outside it.

`release-beta.yml`, after `github-release`: `huawei-binary` (`needs: [prepare, github-release]`, same gate, `gh release download "$TAG" --pattern '*.aab'` into `staged/`, `upload-artifact@v7` named `huawei-binary`, `if-no-files-found: error`, copied from `release-production.yml`) and `promote-huawei` ("Promote Huawei", `needs: [prepare, promote-android, huawei-binary]`, `lane: promote_huawei_beta`, `environment: beta`, `artifacts: "*"`, same `env-json`/secrets/timeout). `store-notes-section`, `store-notes`, `ota-beta` `needs` unchanged. The workflow-level `concurrency: group: release` already covers the beta jobs.

`env-validate.mjs` (shared-workflows) accepts both new names (regex anchored on `KEY|TOKEN|PASSWORD|PASSPHRASE|SECRET|CREDENTIALS?` at the end; `EMAIL` and `DAYS` do not match). No shared-workflows change; the two secrets are already declared on `fastlane-lane.yml` since 0.8.0.

---

## Part C: skills (commit 3, `feat(tooling)`)

- `store-setup/scripts/state.sh`: append `huawei-testers|consoles|huawei-app-record` at the very end of `STEPS_TABLE` (order is an interface; `toggle-huawei` unchanged). 48 → 49 in `store-setup/tests/run.sh` (comment at 118, `EXPECTED_STEPS`, the three counts), `store-setup/SKILL.md` (table row, "48 steps", "seven" → eight), `.claude/skills/README.md` ("48-step", "last seven").
- `store-consoles`: `huawei-testers` appended to `STEP_IDS`; 26 → 27 in `console-step.sh` header and `SKILL.md`; new block at the end of `references/huawei.md`, eight fields, `Confirm: safe` (the non-safe list in the tests stays unchanged): Console AppGallery Connect; click-path Users and permissions → List management → User list → New, then the version's open testing page → select the list (both "verify on screen"); Enter: list name and testers' Huawei IDs from the human only; Take away: a saved list selected for the release, no secret or variable, limits 100 / 5,000 / 30 lists; Browser mode: create, add the IDs given this turn, read back before Save; Guided mode: print both paths; Then: `state.sh set huawei-testers done`, testers are invited per release and install through the AppGallery app.
- `store-credentials/scripts/push-to-github.sh`: `VARIABLE_NAMES` += `HUAWEI_FEEDBACK_EMAIL HUAWEI_TEST_DAYS` (the test diffs the set against the runbook variables table, so commit 3 carries those two runbook rows, as before).
- No `init.manifest.json` change; check `scripts/init.test.mjs` for a hardcoded step count.

---

## Part D: documentation (commits 4 and 5, `docs(docs)`)

- `docs/release-runbook.md`: §1 gains one sentence (internal Huawei test version, free of manual review, up to 100 testers, hours); §3 gains one (re-uploaded from the tag and submitted to open testing with manual review, up to 5,000 testers, 1 to 3 working days, nothing downstream waits). The "Huawei AppGallery" subsection is rewritten for three tiers: a tier table (workflow, jobs, lane, what AppGallery does, review time); "One version slot" (a tier is a flavour of the submit, not a destination; no promote endpoint, each tier re-uploads); "A version under review blocks the next push" (the lane reads `releaseState` and skips with a message; during a beta review `Upload Huawei` is green and does nothing); "Testers are console user lists" (Users and permissions → List management → User list, verify on screen; invited per release; install through the AppGallery app); the existing bullets generalised. Variables rows `HUAWEI_FEEDBACK_EMAIL` (optional; unmasked workflow input, acceptable because AppGallery shows it to testers; move to `secrets:` if preferred) and `HUAWEI_TEST_DAYS` (default 80, capped at 89); the `HUAWEI_UPLOADS_ENABLED`/`HUAWEI_APP_ID` "Used by" cells now say every Huawei job in all three workflows. Rehearsal block gains the two new `DRY_RUN=1` commands with the expected keys, and a note that the canned app record has no `releaseState` so a rehearsal always uploads.
- `docs/store-accounts.md`: step 6 `huawei-testers` in the Huawei list; opening paragraph names the three lanes.
- `.env.example`: two commented lines after `HUAWEI_SUBMIT_DELAY_SECONDS`.
- ADR `docs/decisions/0020-huawei-joins-every-tier.md` (under 40 lines): context (0019 rejected a beta tier; parity requested; the single-slot model makes a tier a submit flag, not a track), decision (all three tiers behind the toggle; internal = testing version free of manual review; beta = with manual review; production unchanged; every tier re-uploads; busy slot skips rather than fails), consequences (undocumented submit fields now on the every-push path; same-versionCode re-upload unverified; testers console-only and per release; `huawei_appgallery_connect_submit_for_review` is the beta fallback), alternatives (submit-only beta: wrong-bytes risk; a slot per tier: AppGallery has none; failing on a busy slot: a third-party review queue must not gate main). Row in `docs/decisions/README.md`. ADR 0019 keeps its text; its beta bullet gains an inline "Revisited by 0020" pointer (accepted records are not rewritten).
- Check `README.md` and `docs/README.md` for "release tier only" phrasing.

---

## Part E: visual guide

Same file and URL as before, republished once. Delivery pipeline: viewBox height to ~440; a third store band under the Android row with three Huawei boxes (`--huawei-fill`, dashed to mark opt-in): internal column "AppGallery test version / no manual review, hours" fed from the Android build; beta column "AppGallery open testing / manual review, 1 to 3 days" fed from the pre-release with a dashed curve labelled "re-uploaded from the tag"; the existing production box moved below the gate; a dashed vertical linking the three labelled "one version slot: each tier replaces the last"; one "never blocking the rows above" label; aria-label and caption rewritten (drop "joins only at that last step"). Huawei swimlane: a "Test user list / testers by Huawei ID" box in the Agent lane after the listing box, muted label "invited per release", aria-label and intro note updated. Mode matrix: one row "Test user list and invitations" (agent fills, human confirms / human / agent fills, human confirms). "Where each part lives": 48 → 49, 26 → 27.

---

## Commits

1. `feat(release): submit AppGallery test versions for the internal and beta tiers` (lane + tests; green on its own, nothing calls the lanes yet).
2. `feat(ci): run the AppGallery test-version jobs on every push and on release` (the switch-on; keep it separate so a bisect lands here).
3. `feat(tooling): add the AppGallery test user list step to the store skills` (skills + the two runbook variable rows).
4. `docs(docs): document the three AppGallery tiers and the single version slot`.
5. `docs(docs): record ADR 0020, Huawei on every tier`.
Each body in words with the session trailer. One pull request against main; push only when Jonas says so.

## Verification

1. `bundle exec ruby -Ifastlane/test fastlane/test/lanes_test.rb` green (replay validates the five new option names against the real plugin).
2. `FASTLANE_SKIP_ENV_ASSERT=1 bundle exec fastlane lanes` lists the three Huawei lanes under `android`, none at top level.
3. `DRY_RUN=1` rehearsals: internal shows `"use_testing_version":true,"skip_manual_review":true` and a window 80 days apart in `+0000`, `feedback_email` only when exported; beta shows `"skip_manual_review":false`; release shows neither key; `HUAWEI_TEST_DAYS=365` gives 89 days and a message.
4. The four skill suites (credentials last, after the runbook rows); `state.sh --list-steps | wc -l` = 49; `console-step.sh huawei-testers` prints the block.
5. `mise exec -- make check`, `make unit`, `make test-scripts`; actionlint covers the two workflows.
6. Later, with a real AppGallery record: one dispatch of the internal workflow reading the plugin's `Request Body:` log lines to see what AppGallery accepted, and what `releaseState` reports during a testing review (the one thing most likely to need the busy-state list widened).

## Risks

- The testing submit fields are reverse-engineered from the console and now sit on the every-push path; the plugin is pinned exactly and the submit is logged verbatim.
- Same-versionCode re-upload unverified; degrades to a red Huawei job that blocks nothing; fallback documented.
- If `releaseState` does not change during a testing review, pushes go red for 1 to 3 days per beta review; the fix is widening the busy list after one real observation.
- The plugin's two `sleep(120)` retry loops are unbounded; the 90-minute job timeout is the only limit. If it bites on the internal tier, lower that tier's timeout rather than raise it.
- Testers are invited per release and the API cannot check it; hence the checklist step and the runbook saying it twice.
- The client pair must be readable from the `internal` and `beta` environments too; a miss fails the pre-flight loudly. Say so in the pull request.
- `HUAWEI_FEEDBACK_EMAIL` is an unmasked workflow input; justified and documented, with the `secrets:` alternative named.

---
name: store-setup
description: Use when an app on the family's shared release workflows (or one generated from the React Native template that calls them) needs real store accounts - taking the release pipeline from unsigned builds to a submittable App Store Connect and Google Play listing, wiring the signing and store secrets, or resuming a half-finished store setup. Also when asked to turn on IOS_SIGNING_ENABLED, ANDROID_SIGNING_ENABLED or STORE_UPLOADS_ENABLED.
allowed-tools: Bash(gh variable:*), Bash(gh secret:*), Bash(gh repo view:*), Bash(gh auth status), Bash(bundle exec fastlane:*), Bash(${CLAUDE_PLUGIN_ROOT}/skills/store-setup/scripts/preflight.sh:*), Bash(${CLAUDE_PLUGIN_ROOT}/skills/store-setup/scripts/identifiers.sh:*), Bash(${CLAUDE_PLUGIN_ROOT}/skills/store-setup/scripts/state.sh:*), Bash(${CLAUDE_PLUGIN_ROOT}/skills/store-setup/tests/run.sh:*)
---

# Store Setup

## Overview

An app that calls the shared release workflows already builds, verifies and
pre-releases **unsigned** — nothing here is required to keep CI green. This skill covers
only what the three toggles unlock: `IOS_SIGNING_ENABLED`,
`ANDROID_SIGNING_ENABLED`, and `STORE_UPLOADS_ENABLED`, and the roughly forty
console steps across Apple and Google that have to happen first.

**Core principle:** every step lands in a repo file, a GitHub variable, or a
GitHub secret; a step whose result lives only in a console is redone in six
months by someone with no memory of it, so `${CLAUDE_PLUGIN_ROOT}/skills/store-setup/scripts/state.sh note` the fact the
moment you learn it.

## Before Anything: Pick a Mode

> Store setup is roughly forty console steps across two consoles, some irreversible. How much of it should I drive?
>
> **(a) Browser, pausing at credentials** *(recommended)* — I drive Chrome through the extension and fill the forms. I stop and hand the keyboard back for: signing in, any 2FA prompt, the one-time `.p8` download, accepting agreements, and anything that charges money. You get a "your turn" message naming exactly what to do, and I continue when you say so. *Expect:* most of the typing done for you, a visible trail, 5-10 handovers. *Risk:* I can misread a reorganised console and fill the wrong field; every form is read back to you before submit, and I stop and ask after two failed attempts on the same element.
>
> **(b) Guided, you click** — I never touch the browser. For each step I give you the exact click-path, the exact value to paste, and where in the repo it came from; you tell me what happened and I record it. *Expect:* slowest, about forty paste-and-confirm rounds, and the only mode where nothing can go wrong that you did not do yourself. *Risk:* transcription errors on long values (an issuer UUID, a base64 keystore); paste, don't retype, and let `store-credentials` validate afterwards.
>
> **(c) Browser, end to end including agreements** — As (a), plus I accept the agreements and submit the forms, including the content-rating, data-safety, target-audience and App Privacy questionnaires from answers you give me in that turn, each read back before submit. I still stop for sign-in and 2FA (I cannot receive your code) and for the `.p8` download. *Expect:* fastest. *Risk:* **you are asking me to accept legal terms and declarations on your behalf.** Those declarations are legally yours and are what Google suspends apps over when they are wrong. I never pay anything, and I still ask before every irreversible step.
>
> Reply `a`, `b` or `c`. If you would rather not choose now, `b` is the safe default and you can switch at any step. I record it with `${CLAUDE_PLUGIN_ROOT}/skills/store-setup/scripts/state.sh mode`.

Modes are recorded as `${CLAUDE_PLUGIN_ROOT}/skills/store-setup/scripts/state.sh mode <guided|browser-pause|browser-full>` —
(a) is `browser-pause`, (b) is `guided`, (c) is `browser-full`.

**These stop for an explicit yes every time, in every mode, including (c). "Yes" means the word in this turn, not a mode chosen earlier and not a yes to a different step:**

| Step | Why |
|---|---|
| Paying the Apple Developer Program fee (99 USD/yr) or the Play registration fee (25 USD) | Money |
| Accepting any agreement, or submitting tax or banking details | Legally binding, in your name |
| Enrolling the app in Play App Signing | Permanent for that app |
| The first Play upload of any artifact | Fixes `ANDROID_PACKAGE` forever |
| Registering an Apple bundle identifier | Cannot be deleted once an app record uses it |
| Creating an App Store Connect API key | The `.p8` downloads exactly once |
| Submitting for App Review, or starting a Play production rollout | Public |
| Enrolling the app in AppGallery App Signing | Permanent for that app |
| Entering the package name on a new AppGallery app record | Fixes what that record can ever publish |
| `fastlane match nuke` | Never. Not with a yes. It revokes team-wide certificates. |

A yes to one row is not a yes to the next.

## Never Do These

| Forbidden | Why |
|---|---|
| `match nuke` in any form | Revokes every signing certificate for the whole team, irrecoverably |
| Typing a password, PIN or 2FA code the human did not give you in this turn | Not yours to enter, ever |
| Writing any credential into `state.json` | `${CLAUDE_PLUGIN_ROOT}/skills/store-setup/scripts/state.sh note` refuses credential-shaped keys — it is a progress file, not a secret store |
| A first Play upload before the identifiers gate passes | Google Play refuses `com.example.*`, and the package name is permanent once uploaded |
| Enrolling in Play App Signing "to see what it does" | It is permanent for that app |
| `gh secret set` with the value on the command line | Lands in shell history and process listings |
| Turning on `STORE_UPLOADS_ENABLED` before a `DRY_RUN=1` rehearsal passes | The first real upload fixes `ANDROID_PACKAGE` forever |

## Workflow

1. **Preflight and state.** Run `preflight.sh` to confirm the local tooling
   and `gh`/fastlane auth are in place, then `${CLAUDE_PLUGIN_ROOT}/skills/store-setup/scripts/state.sh init` and
   `${CLAUDE_PLUGIN_ROOT}/skills/store-setup/scripts/state.sh mode <guided|browser-pause|browser-full>` to record how much of
   the browser work you are driving. In modes (a) and (c), load the
   `claude-in-chrome` skill via the Skill tool before any browser tool.
2. **The identifiers gate.** `identifiers.sh` must pass before any console
   work starts. Google Play refuses `com.example.*` outright, and an App
   Store Connect app record is permanent once created. The remedy for a
   failing gate is to rename the placeholders where the app keeps them (in the
   template, `make init`) and to set the same values as `gh` variables — never
   to hand-edit one side to make the gate pass.
3. **Work the checklist.** `${CLAUDE_PLUGIN_ROOT}/skills/store-setup/scripts/state.sh next` returns the next unblocked step.
   The id prefix tells you who owns it: `apple-*` and `google-*` go to the
   `store-consoles` skill, `cred-*` to `store-credentials`, `meta-*` to
   `store-metadata`. Apple and Google are independent tracks — start Apple's
   enrolment first, since it is the long pole (it can take weeks for an
   organisation account), and work the Google steps while it waits.
4. **Signing on, then rehearse.** Flip `IOS_SIGNING_ENABLED` and
   `ANDROID_SIGNING_ENABLED` once every `cred-*` step is done, then rehearse
   with `DRY_RUN=1 bundle exec fastlane ios upload_internal` and
   `DRY_RUN=1 bundle exec fastlane android upload_internal` before touching
   `STORE_UPLOADS_ENABLED`.
5. **Handover.** `${CLAUDE_PLUGIN_ROOT}/skills/store-setup/scripts/state.sh render --markdown` produces the checklist to paste
   into a PR description or hand to whoever picks this up next.

## Worked Example

[`references/walkthrough.md`](references/walkthrough.md) is a conceptual
transcript of one full run in mode (a) — every script call in order, every
handover, and every read-back before an irreversible step.

## The Checklist

The 49 steps, in the order `${CLAUDE_PLUGIN_ROOT}/skills/store-setup/scripts/state.sh --list-steps` prints them:

| id | owner | needs | what |
|---|---|---|---|
| `preflight` | setup | — | Verify local tooling and `gh`/fastlane auth before starting |
| `identifiers` | setup | `preflight` | Gate: `IOS_BUNDLE_ID`, `ANDROID_PACKAGE`, `IOS_SCHEME` set, real, and consistent with the repo |
| `apple-enrolment` | consoles | `identifiers` | Enrol the individual or organisation in the Apple Developer Program |
| `apple-agreements` | consoles | `apple-enrolment` | Accept the Apple Developer Program License Agreement |
| `apple-bundle-id` | consoles | `apple-agreements` | Register the iOS bundle identifier in the Apple Developer portal |
| `apple-app-record` | consoles | `apple-bundle-id` | Create the app record in App Store Connect |
| `apple-asc-key` | consoles | `apple-agreements` | Create an App Store Connect API key (the `.p8` downloads once) |
| `cred-asc-key` | credentials | `apple-asc-key` | Validate and push the ASC API key as GitHub secrets |
| `apple-match-repo` | consoles | `apple-agreements` | Create or confirm the private repo `fastlane match` uses for certificates |
| `cred-match` | credentials | `apple-match-repo` | Validate and push the match repo access and passphrase as GitHub secrets |
| `apple-testflight-groups` | consoles | `apple-app-record` | Create TestFlight internal/external tester groups |
| `apple-privacy-labels` | consoles | `apple-app-record` | Fill in the App Privacy ("nutrition label") answers |
| `apple-pricing` | consoles | `apple-app-record` | Set App Store pricing and availability |
| `google-account` | consoles | `identifiers` | Create or confirm the Google Play Console developer account |
| `google-app-record` | consoles | `google-account` | Create the app entry in Google Play Console |
| `cred-upload-keystore` | credentials | `identifiers` | Generate the Android upload keystore and push it as a GitHub secret |
| `google-play-app-signing` | consoles | `google-app-record`, `cred-upload-keystore` | Enrol the app in Play App Signing (permanent) |
| `google-service-account` | consoles | `google-account` | Create the Play API service account used for automated uploads |
| `google-play-grant` | consoles | `google-app-record`, `google-service-account` | Grant the service account access to the app in Play Console |
| `cred-play-json` | credentials | `google-play-grant` | Validate and push the Play service account JSON as a GitHub secret |
| `google-tracks` | consoles | `google-app-record` | Configure the internal/closed/open testing tracks |
| `google-store-listing-fields` | consoles | `google-app-record` | Fill in the Play Store listing fields (title, description, category) |
| `google-content-rating` | consoles | `google-app-record` | Complete the Play content rating questionnaire |
| `google-data-safety` | consoles | `google-app-record` | Complete the Play Data Safety form |
| `google-target-audience` | consoles | `google-app-record` | Set the Play target audience and content settings |
| `google-app-access` | consoles | `google-app-record` | Provide Play App Access instructions or test credentials |
| `google-pricing` | consoles | `google-app-record` | Set Play pricing and country availability |
| `meta-scaffold` | metadata | `identifiers` | Scaffold `fastlane/metadata/**` for both platforms |
| `meta-ios-copy` | metadata | `meta-scaffold` | Write App Store copy (name, subtitle, description, keywords) |
| `meta-android-copy` | metadata | `meta-scaffold` | Write Play Store copy (title, short and full description) |
| `meta-images` | metadata | `meta-scaffold` | Produce screenshots, icon and feature graphic |
| `meta-age-rating` | metadata | `meta-scaffold` | Fill in age-rating metadata fields |
| `meta-review-info` | metadata | `meta-scaffold` | Fill in App Review contact and demo-account info |
| `cred-push` | credentials | `cred-asc-key`, `cred-match`, `cred-upload-keystore`, `cred-play-json` | Confirm every signing credential has been pushed as a GitHub secret |
| `gh-environments` | setup | `cred-push` | Wire the GitHub Environments the release workflow deploys through |
| `toggle-signing` | setup | `cred-push` | Turn on `IOS_SIGNING_ENABLED` and `ANDROID_SIGNING_ENABLED` |
| `rehearse-dry-run` | setup | `toggle-signing` | Run `DRY_RUN=1` fastlane uploads for both platforms |
| `meta-sync` | metadata | `meta-ios-copy`, `meta-android-copy`, `meta-images`, `meta-age-rating`, `meta-review-info`, `cred-push` | Sync fastlane metadata to both consoles |
| `first-play-upload` | setup | `google-play-app-signing`, `google-tracks`, `rehearse-dry-run` | Do the first real Play upload (fixes `ANDROID_PACKAGE` forever) |
| `toggle-uploads` | setup | `rehearse-dry-run`, `first-play-upload` | Turn on `STORE_UPLOADS_ENABLED` |
| `store-ready` | setup | `toggle-uploads`, `meta-sync`, `apple-testflight-groups`, `apple-privacy-labels`, `apple-pricing`, `google-content-rating`, `google-data-safety`, `google-target-audience`, `google-app-access`, `google-pricing`, `google-store-listing-fields`, `gh-environments` | Everything needed to submit for review is in place |
| `huawei-account` | consoles | `toggle-uploads` | Register the Huawei Developer account and pass identity verification |
| `huawei-app-record` | consoles | `huawei-account` | Create the app record in AppGallery Connect (the package name is entered here) |
| `huawei-api-client` | consoles | `huawei-account` | Create the AppGallery Connect API client (the client secret is shown once) |
| `cred-huawei` | credentials | `huawei-api-client`, `huawei-app-record` | Validate and push the AppGallery client id, client secret and app id |
| `huawei-app-signing` | consoles | `huawei-app-record` | Decide about AppGallery App Signing (optional, permanent once enabled) |
| `huawei-listing` | consoles | `huawei-app-record` | Fill in the AppGallery listing, age rating and release countries |
| `toggle-huawei` | setup | `cred-huawei`, `huawei-listing`, `huawei-app-signing` | Turn on `HUAWEI_UPLOADS_ENABLED`; a test version reaches nobody until `huawei-testers` is done too |
| `huawei-testers` | consoles | `huawei-app-record` | Create the AppGallery test user list and select it on the version |

The eight `huawei-*`/`cred-huawei`/`toggle-huawei` steps are an **optional
extra store**, and that is why `huawei-account` needs `toggle-uploads`: the
AppGallery block stays out of `${CLAUDE_PLUGIN_ROOT}/skills/store-setup/scripts/state.sh next` until the Apple and Play path
actually ships, and `store-ready` is reached exactly as before by a repository
that never publishes on AppGallery. For such a repository,
`${CLAUDE_PLUGIN_ROOT}/skills/store-setup/scripts/state.sh set <id> skipped` is the right answer for each of the eight — not
`done`, and not leaving them `todo` forever. `huawei-testers` is the one that
comes back: an AppGallery test user list has to be selected **per testing
version**, so every internal or open test build needs its testers invited
again.

## State

`.store-setup/state.json` is gitignored — it holds progress (`todo` /
`doing` / `done` / `skipped` per step) plus a handful of account-identifying
facts (a team id, an issuer UUID), never credentials. The three authoritative
homes for repo-level truth stay GitHub variables/secrets, `fastlane/metadata/**`,
and the consoles themselves — `state.json` is a worklist, not a source of
truth, and losing it costs re-running `${CLAUDE_PLUGIN_ROOT}/skills/store-setup/scripts/state.sh next` a few times, not data.

`${CLAUDE_PLUGIN_ROOT}/skills/store-setup/scripts/state.sh render --markdown` marks each status distinctly: `- [x]` done,
`- [~]` doing, `- [-]` skipped, `- [ ]` todo. Every subcommand but `init` and
`--list-steps` requires `state.json` to already exist — run `${CLAUDE_PLUGIN_ROOT}/skills/store-setup/scripts/state.sh init`
first, or you get a gated exit (2) naming the missing file instead of a
crash.

## After Editing the Scripts

```bash
${CLAUDE_PLUGIN_ROOT}/skills/store-setup/tests/run.sh
```

Every check runs offline against fakes (`gh`, `bundle`) and scratch repos —
no network, no real console, no real credential. Run it after touching
anything in `scripts/`.

## Common Mistakes

| Mistake | Consequence |
|---|---|
| Hand-editing the app configuration to pass the identifiers gate | The gate re-checks the `gh` variables too; change both together (in the template, `make init` does) |
| Treating a mode choice as a standing yes | The always-confirm table asks again every time, on purpose |
| Enrolling in Play App Signing before the upload keystore is pushed | `google-play-app-signing` needs `cred-upload-keystore` — the checklist order exists for this |
| Skipping the `DRY_RUN=1` rehearsal | The first real Play upload is irreversible; the rehearsal is the only free retry |
| Putting a fact in `state.json` that is actually a secret | `${CLAUDE_PLUGIN_ROOT}/skills/store-setup/scripts/state.sh note` refuses it — the message tells you to `gh secret set` instead |

## Red Flags — Stop

- About to type `match nuke` in any form, dry-run or not
- About to type a password, PIN or 2FA code the human did not just give you
- About to run `${CLAUDE_PLUGIN_ROOT}/skills/store-setup/scripts/state.sh note` with a value that looks like a secret
- About to put a value in `${CLAUDE_PLUGIN_ROOT}/skills/store-setup/scripts/state.sh set <id> <status> [note]`'s free-text
  note: that text is not screened at all (only `note`'s *key* is), so never
  put a value there — a fact goes to `${CLAUDE_PLUGIN_ROOT}/skills/store-setup/scripts/state.sh note`, a credential to
  `gh secret set`
- About to do the first Play upload and `identifiers.sh` has not passed
- You are about to click Accept on an agreement, pay a fee, or enrol in Play App Signing and you have not had an explicit yes in this turn

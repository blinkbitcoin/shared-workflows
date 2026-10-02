# Apple console steps

One block per `apple-*` id from `${CLAUDE_PLUGIN_ROOT}/skills/store-setup/scripts/state.sh --list-steps`. Every block has
exactly these fields, in this order: `Console:`, `Click-path:`, `Enter:`,
`Take away:`, `Confirm:`, `Browser mode:`, `Guided mode:`, `Then:`.
`Confirm:` starts with one of `safe`, `paid`, `binding`, `irreversible` or
`permanent`, followed by why.

### `apple-enrolment` — Apple Developer Program enrolment
**Console:** Apple Developer — https://developer.apple.com/programs/
**Click-path:** developer.apple.com/programs → Enroll → choose Individual or Organization → for an organisation, provide the D-U-N-S number → complete identity verification → pay the annual fee
**Enter:** the organisation's legal name and D-U-N-S number (individual: the human's own legal name), from the human
**Take away:** enrolment status (review can take days to weeks); once approved, the Apple Team ID
**Confirm:** paid — 99 USD/year, charged immediately on submission
**Browser mode:** fill the enrolment form up to but not including payment, then stop and hand over: the human enters payment details and confirms
**Guided mode:** print the URL and the D-U-N-S requirement, then wait for the human to report enrolment approved
**Then:** `${CLAUDE_PLUGIN_ROOT}/skills/store-setup/scripts/state.sh note apple_team_id <team-id>` once approved; next `apple-agreements`

### `apple-agreements` — Apple Developer Program License Agreement
**Console:** App Store Connect — https://appstoreconnect.apple.com
**Click-path:** App Store Connect → Business → Agreements, Tax, and Banking → review the Program License Agreement (and any other agreement Apple is prompting for)
**Enter:** tax and banking details only if the human gives them in this turn; never invented, never carried over from an earlier turn
**Take away:** agreement status (active); banking status if entered. `console-step.sh` refuses `--format json` for this id because the entered values may include tax or banking details
**Confirm:** binding — accepting this agreement, or submitting tax or banking details, is legally binding in the human's or organisation's name
**Browser mode:** navigate to the page and read back exactly what would be accepted or submitted; this is mode (c) only, and only after an explicit yes in this turn — modes (a) and (b) get the human to the page and wait
**Guided mode:** print the click-path; the human accepts and reports back
**Then:** `${CLAUDE_PLUGIN_ROOT}/skills/store-setup/scripts/state.sh set apple-agreements done`; next `apple-bundle-id`, `apple-asc-key`, `apple-match-repo` (independent, any order)

### `apple-bundle-id` — iOS bundle identifier
**Console:** Apple Developer — https://developer.apple.com/account
**Click-path:** developer.apple.com/account → Certificates, Identifiers & Profiles → Identifiers → **+** → App IDs → App → description the app name → Bundle ID: Explicit → paste the value → Continue → Register
**Enter:** the value of `IOS_BUNDLE_ID` from `gh variable`
**Take away:** confirmation the identifier is registered; no new secret or variable — `IOS_BUNDLE_ID` already exists
**Confirm:** irreversible — an identifier cannot be deleted once an app record uses it
**Browser mode:** fill the description and bundle id, read the pasted value back before Register, then stop and hand over: Register cannot be undone
**Guided mode:** print the exact value to paste and the click-path; the human registers and reports back
**Then:** `${CLAUDE_PLUGIN_ROOT}/skills/store-setup/scripts/state.sh set apple-bundle-id done`; next `apple-app-record`

### `apple-app-record` — App Store Connect app record
**Console:** App Store Connect — https://appstoreconnect.apple.com
**Click-path:** App Store Connect → Apps → **+** → New App → Platforms: iOS → Name → Primary Language: `en-US` → Bundle ID: select the one from `apple-bundle-id` → SKU → Create
**Enter:** name from `fastlane/metadata/ios/en-US/name.txt`; primary language `en-US`; the bundle id from `apple-bundle-id`; SKU = the `package.json` name
**Take away:** confirmation the app record exists; no new secret or variable
**Confirm:** safe — creating the record spends no money and binds nothing; the bundle id was the irreversible part
**Browser mode:** fill the form, read back name, bundle id and SKU before Create
**Guided mode:** print the four values and the click-path; the human creates it and reports back
**Then:** `${CLAUDE_PLUGIN_ROOT}/skills/store-setup/scripts/state.sh set apple-app-record done`; next `apple-testflight-groups`, `apple-privacy-labels`, `apple-pricing` (independent, any order)

### `apple-asc-key` — App Store Connect API key
**Console:** App Store Connect — https://appstoreconnect.apple.com
**Click-path:** Users and Access → Integrations → App Store Connect API → **+** → name `<slug>-ci`, Access: App Manager, Apps: this app only → Generate
**Enter:** the key name: `<package.json name>-ci`
**Take away:** Key ID → `ASC_KEY_ID` (secret); Issuer ID → `ASC_ISSUER_ID` (secret); the `.p8` → `base64 -i AuthKey_XXXX.p8 | tr -d '\n'` → `ASC_KEY_P8_BASE64` (secret)
**Confirm:** irreversible — the `.p8` downloads once
**Browser mode:** fill the name and scope, stop before Generate and hand over: the download must land in the human's Downloads folder
**Guided mode:** print the path, the name to type, and the three values to bring back
**Then:** `${CLAUDE_PLUGIN_ROOT}/skills/store-setup/scripts/state.sh note asc_issuer_id <uuid>`; next `cred-asc-key`

### `apple-match-repo` — fastlane match certificates repository
**Console:** GitHub — https://github.com/organizations/<owner>/repositories/new
**Click-path:** github.com/organizations/`<owner>`/repositories/new → name `<slug>-certificates` → Private → no README, no `.gitignore`, no license (leave it empty) → Create repository
**Enter:** repository name: `<package.json name>-certificates`
**Take away:** repo URL, for `MATCH_GIT_URL` (secret, pushed by `cred-match`); this must not be the repository production's certificates already live in
**Confirm:** safe — an empty private repo carries no certificates yet; `fastlane match` is what makes it sensitive, and that runs under `cred-match`
**Browser mode:** after an explicit yes, create the repository (private, empty) and report the URL
**Guided mode:** print the exact `gh repo create <owner>/<slug>-certificates --private` line for the human to run
**Then:** `${CLAUDE_PLUGIN_ROOT}/skills/store-setup/scripts/state.sh note production_match_git_url <url of the PRODUCTION app's match repo, if this team has one>`; `${CLAUDE_PLUGIN_ROOT}/skills/store-setup/scripts/state.sh set apple-match-repo done`; next `cred-match`

### `apple-testflight-groups` — TestFlight tester groups
**Console:** App Store Connect — https://appstoreconnect.apple.com
**Click-path:** App Store Connect → app → TestFlight → Internal Testing → **+** → name the group, add testers → External Testing → **+** → name the group, add testers, submit for Beta App Review
**Enter:** internal group name and external group name, from the human
**Take away:** internal group name → `TESTFLIGHT_INTERNAL_GROUP` (variable); external group name → `TESTFLIGHT_EXTERNAL_GROUP` (variable); the external group must exist and be approved before `cd-beta` runs
**Confirm:** safe — naming a tester group commits nothing; only submitting a build for external review does, and that happens later, in `cd-beta`
**Browser mode:** create both groups, read the two names back before submitting external for Beta App Review
**Guided mode:** print the click-path and the two names to create; the human creates them and reports back
**Then:** `gh variable set TESTFLIGHT_INTERNAL_GROUP --body '<name>'`; `gh variable set TESTFLIGHT_EXTERNAL_GROUP --body '<name>'`; next `apple-privacy-labels`, `apple-pricing`

### `apple-privacy-labels` — App Privacy ("nutrition label")
**Console:** App Store Connect — https://appstoreconnect.apple.com
**Click-path:** App Store Connect → app → App Privacy → Get Started → answer each data-collection question → Publish
**Enter:** answers from the human only — the skill never guesses a privacy answer; a clean template app collects nothing, so start from "does not collect data" and add back whatever `EXPO_PUBLIC_API_URL` and any crash reporter actually send
**Take away:** the published App Privacy answers; no secret or variable
**Confirm:** safe — the form spends no money and binds nothing by itself, but publishing wrong answers is a rejection risk
**Browser mode:** navigate to the questionnaire and stop — this is mode (c) only: modes (a) and (b) get the human to the form and wait
**Guided mode:** print the click-path and wait for the human to complete it
**Then:** mode (c) fills only the answers given in this turn, reads every answer back, and waits for an explicit yes before Publish; `${CLAUDE_PLUGIN_ROOT}/skills/store-setup/scripts/state.sh set apple-privacy-labels done`

### `apple-pricing` — App Store pricing and availability
**Console:** App Store Connect — https://appstoreconnect.apple.com
**Click-path:** App Store Connect → app → Pricing and Availability → Price Schedule → choose tier → Availability → choose territories → Save
**Enter:** price tier and territory list, from the human
**Take away:** the saved tier and territories; no secret or variable
**Confirm:** safe — changing this again later costs nothing; it only takes effect once the app is live
**Browser mode:** fill the tier and territories, read them back, then an explicit yes before Save
**Guided mode:** print the click-path; the human sets it and reports back
**Then:** `${CLAUDE_PLUGIN_ROOT}/skills/store-setup/scripts/state.sh set apple-pricing done`

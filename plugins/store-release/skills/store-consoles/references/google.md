# Google console steps

One block per `google-*` id from `${CLAUDE_PLUGIN_ROOT}/skills/store-setup/scripts/state.sh --list-steps`. Every block has
exactly these fields, in this order: `Console:`, `Click-path:`, `Enter:`,
`Take away:`, `Confirm:`, `Browser mode:`, `Guided mode:`, `Then:`.
`Confirm:` starts with one of `safe`, `paid`, `binding`, `irreversible` or
`permanent`, followed by why.

### `google-account` — Google Play Console developer account
**Console:** Google Play Console — https://play.google.com/console
**Click-path:** play.google.com/console → Create account → choose Personal or Organization → complete identity verification → pay the registration fee
**Enter:** legal name and identity details, from the human
**Take away:** account status; once approved, the account is ready for `google-app-record`
**Confirm:** paid — 25 USD once, not annually, charged immediately on submission
**Browser mode:** fill the account form up to but not including payment, then stop and hand over: the human enters payment details and confirms
**Guided mode:** print the URL and the identity requirement, then wait for the human to report the account approved
**Then:** `${CLAUDE_PLUGIN_ROOT}/skills/store-setup/scripts/state.sh set google-account done`; next `google-app-record`, `google-service-account` (independent, any order)

### `google-app-record` — Play Console app entry
**Console:** Google Play Console — https://play.google.com/console
**Click-path:** Play Console → All apps → Create app → App name → Default language → App or game → Free or paid → confirm declarations → Create app
**Enter:** name from `fastlane/metadata/android/en-US/title.txt`; default language; app/game; free/paid, from the human
**Take away:** confirmation the app entry exists; no new secret or variable
**Confirm:** safe — this step does not fix the package name; the package name (`ANDROID_PACKAGE`) is set by the first upload, in `first-play-upload`, not here
**Browser mode:** fill the form, read back name, language and type before Create app
**Guided mode:** print the values and the click-path; the human creates it and reports back
**Then:** `${CLAUDE_PLUGIN_ROOT}/skills/store-setup/scripts/state.sh set google-app-record done`; next `google-play-app-signing`, `google-play-grant`, `google-tracks`, `google-store-listing-fields`, `google-content-rating`, `google-data-safety`, `google-target-audience`, `google-app-access`, `google-pricing` (independent, any order)

### `google-play-app-signing` — Play App Signing
**Console:** Google Play Console — https://play.google.com/console
**Click-path:** Play Console → app → Test and release → Setup → App integrity → App signing → Use Google-generated key → upload the certificate produced by `cred-upload-keystore` → Confirm
**Enter:** the upload certificate exported by `cred-upload-keystore`
**Take away:** confirmation Play holds the app signing key; no new secret or variable
**Confirm:** permanent — this cannot be undone for this app once confirmed
**Browser mode:** upload the certificate, read back which file was uploaded, then an explicit yes before Confirm
**Guided mode:** print the click-path and which certificate file to upload; the human uploads it and reports back
**Then:** `${CLAUDE_PLUGIN_ROOT}/skills/store-setup/scripts/state.sh set google-play-app-signing done`; next `first-play-upload` (later, once `google-tracks` and the rehearsal are also done)

### `google-service-account` — Play API service account
**Console:** Google Cloud Console — https://console.cloud.google.com
**Click-path:** console.cloud.google.com → IAM & Admin → Service Accounts → Create → name `<slug>-publisher` → Keys → Add key → Create new key → JSON → Create
**Enter:** the service account name: `<package.json name>-publisher`
**Take away:** the downloaded JSON key, for `PLAY_SERVICE_ACCOUNT_JSON` (secret); the service account's email, for `google-play-grant`
**Confirm:** safe — creating the account and key spends nothing and grants it no access yet; `google-play-grant` is what makes it powerful
**Browser mode:** fill the name, create the key, and hand over: the JSON download must land in the human's Downloads folder
**Guided mode:** print the name to type and the click-path; the human creates it and brings back the JSON path and the email
**Then:** `${CLAUDE_PLUGIN_ROOT}/skills/store-setup/scripts/state.sh note play_service_account_email <email>`; next `google-play-grant`

### `google-play-grant` — grant the service account access
**Console:** Google Play Console — https://play.google.com/console
**Click-path:** Play Console → Users and permissions → Invite new users → paste the service account email → select **this app** rather than account-wide access → grant Release apps to testing tracks, Release to production, Manage store presence → Invite
**Enter:** the service account email, from `state.facts.play_service_account_email`
**Take away:** confirmation the grant is app-scoped, not account-wide; no new secret or variable
**Confirm:** safe — an app-scoped grant is what makes this credential safe to hold in a template repository; it commits no money and is revocable
**Browser mode:** paste the email, select the app-scope radio, and read it back before Invite
**Guided mode:** print the email and the click-path, including the app-scope radio to select; the human invites and reports back
**Then:** `${CLAUDE_PLUGIN_ROOT}/skills/store-setup/scripts/state.sh set google-play-grant done`; next `cred-play-json`

### `google-tracks` — testing tracks and testers
**Console:** Google Play Console — https://play.google.com/console
**Click-path:** Play Console → app → Test and release → Testing → Internal testing → Testers → Create email list → name the list → paste tester emails → Save
**Enter:** tester email addresses, from the human
**Take away:** the tester list; no secret or variable
**Confirm:** safe — adding testers to a list commits nothing; only a real release to the track does
**Browser mode:** create the list, paste the emails, read the list back before Save
**Guided mode:** print the click-path; the human creates the list and reports back
**Then:** `${CLAUDE_PLUGIN_ROOT}/skills/store-setup/scripts/state.sh set google-tracks done`; next `first-play-upload` (later, once app signing and the rehearsal are also done)

### `google-store-listing-fields` — Play Store listing fields
**Console:** Google Play Console — https://play.google.com/console
**Click-path:** Play Console → app → Grow → Store presence → Main store listing → Store settings: category and tags; then Store presence → Contact details: email, phone, website → Save
**Enter:** category and tags, plus contact details, from the human
**Take away:** the saved category, tags and contact details; no secret or variable
**Confirm:** safe — the category is console-only (there is no repo file for it) and can be changed again later at no cost
**Browser mode:** fill category, tags and contact details, read them back before Save
**Guided mode:** print the click-path and the fields to fill; the human fills them and reports back
**Then:** `${CLAUDE_PLUGIN_ROOT}/skills/store-setup/scripts/state.sh set google-store-listing-fields done`

### `google-content-rating` — Play content rating questionnaire
**Console:** Google Play Console — https://play.google.com/console
**Click-path:** Play Console → app → Monetise and policy → Policy → App content → Content rating → Start questionnaire → answer each question → Save and submit
**Enter:** answers from the human only, each read back before it is entered
**Take away:** the assigned content rating; no secret or variable
**Confirm:** safe — this is a declaration, not a payment, but a wrong answer is a policy violation, so nothing is guessed
**Browser mode:** navigate to the questionnaire and stop — this is mode (c) only: modes (a) and (b) get the human to the form and wait
**Guided mode:** print the click-path and wait for the human to complete it
**Then:** mode (c) answers only what the human gives in this turn, reads each answer back, and waits for an explicit yes before Save and submit; `${CLAUDE_PLUGIN_ROOT}/skills/store-setup/scripts/state.sh set google-content-rating done`

### `google-data-safety` — Play Data Safety form
**Console:** Google Play Console — https://play.google.com/console
**Click-path:** Play Console → app → App content → Data safety → Manage → answer each data-collection and data-sharing question → Save
**Enter:** answers from the human only; the skill proposes a starting answer from a clean template app's known data flows and never asserts one on its own
**Take away:** the saved Data Safety answers; no secret or variable
**Confirm:** safe — this is a declaration; a wrong one is what Google suspends apps over, so nothing is asserted without the human's word
**Browser mode:** navigate to the form and stop — this is mode (c) only: modes (a) and (b) get the human to the form and wait
**Guided mode:** print the click-path and wait for the human to complete it
**Then:** mode (c) proposes answers, waits for the human to confirm or correct each one, reads the final set back, and waits for an explicit yes before Save; `${CLAUDE_PLUGIN_ROOT}/skills/store-setup/scripts/state.sh set google-data-safety done`

### `google-target-audience` — target audience, content and ads
**Console:** Google Play Console — https://play.google.com/console
**Click-path:** Play Console → app → App content → Target audience and content → answer the age-group questions → Save; then App content → Ads → declare whether the app shows ads → Save
**Enter:** answers from the human only, each read back before it is entered
**Take away:** the saved target audience and ads declaration; no secret or variable
**Confirm:** safe — a wrong ads declaration is a policy issue, not a payment, but nothing here is guessed
**Browser mode:** navigate to both forms and stop — this is mode (c) only: modes (a) and (b) get the human to the forms and wait
**Guided mode:** print both click-paths and wait for the human to complete them
**Then:** mode (c) fills only what the human gives in this turn, reads it back, and waits for an explicit yes before each Save; `${CLAUDE_PLUGIN_ROOT}/skills/store-setup/scripts/state.sh set google-target-audience done`

### `google-app-access` — App Access instructions
**Console:** Google Play Console — https://play.google.com/console
**Click-path:** Play Console → app → App content → App access → All or some functionality is restricted → Add new instructions → describe how to reach the restricted parts, including a demo login if one exists → Save
**Enter:** demo login, from `APP_REVIEW_DEMO_USER`/`APP_REVIEW_DEMO_PASSWORD`, from the human — never invented, never typed from a value the human did not give in this turn
**Take away:** the saved instructions; no secret or variable. `console-step.sh` refuses `--format json` for this id because the resolved values include a demo credential
**Confirm:** safe — the instructions text commits nothing, but it carries a live credential, hence the JSON refusal above
**Browser mode:** fill the instructions, read the demo login back without echoing the password outside this turn, then Save
**Guided mode:** print the click-path; the human fills it in directly rather than pasting the password through chat where it is not needed
**Then:** `${CLAUDE_PLUGIN_ROOT}/skills/store-setup/scripts/state.sh set google-app-access done`

### `google-pricing` — Play pricing and country availability
**Console:** Google Play Console — https://play.google.com/console
**Click-path:** Play Console → app → Monetise → Monetisation setup → choose Free or Paid → Countries and regions → select availability → Save
**Enter:** free/paid choice and country list, from the human
**Take away:** the saved pricing and availability; no secret or variable
**Confirm:** irreversible — an app switched from free to paid can never be made free again
**Browser mode:** fill the choice and countries, read them back, then an explicit yes before Save
**Guided mode:** print the click-path; the human sets it and reports back
**Then:** `${CLAUDE_PLUGIN_ROOT}/skills/store-setup/scripts/state.sh set google-pricing done`

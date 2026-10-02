# Huawei console steps

One block per `huawei-*` id from `${CLAUDE_PLUGIN_ROOT}/skills/store-setup/scripts/state.sh --list-steps`. Every block has
exactly these fields, in this order: `Console:`, `Click-path:`, `Enter:`,
`Take away:`, `Confirm:`, `Browser mode:`, `Guided mode:`, `Then:`.
`Confirm:` starts with one of `safe`, `paid`, `binding`, `irreversible` or
`permanent`, followed by why.

AppGallery is an **optional extra store**: every id here hangs off
`toggle-uploads`, so none of it is reached until the Apple and Google path
ships. Huawei reorganises these menus more often than Apple or Google do, so
the click-paths below name the entry point and the path from it, and anything
research could not confirm is marked "verify on screen" — read the label in
front of you rather than insisting on the wording here.

### `huawei-account` — Huawei Developer account and identity verification
**Console:** Huawei Developer — https://developer.huawei.com/consumer/en/
**Click-path:** developer.huawei.com/consumer/en → Sign up → choose Individual or Enterprise → accept the developer agreement → submit identity documents (an enterprise account also submits business documents) → wait for verification
**Enter:** the legal name and identity details, and for an enterprise account the business details, from the human; the account country
**Take away:** the verified developer account; no secret or variable yet
**Confirm:** binding — the developer agreement is accepted in the human's or the organisation's name, identity documents are submitted, and the account country is fixed at registration and cannot be changed later
**Browser mode:** fill the sign-up form up to but not including the agreement checkbox and the document upload, then stop and hand over: the human accepts the agreement and uploads their own documents
**Guided mode:** print the URL, the country decision and the document requirement, then wait for the human to report the account verified
**Then:** `${CLAUDE_PLUGIN_ROOT}/skills/store-setup/scripts/state.sh set huawei-account done` once verification comes back (allow days, not hours — verify the current estimate on screen); next `huawei-app-record`, `huawei-api-client` (independent, any order)

### `huawei-app-record` — AppGallery Connect app record
**Console:** AppGallery Connect — https://developer.huawei.com/consumer/en/service/josp/agc/index.html
**Click-path:** AppGallery Connect → My apps → New → app name → default language → app or game → category → package name → OK (verify the button wording on screen)
**Enter:** app name from `fastlane/metadata/android/en-US/title.txt`; default language, app/game and category from the human; the package name — the same value as the `ANDROID_PACKAGE` repository variable, never a fresh one
**Take away:** the numeric **App ID**, shown on the app's information page after the record exists — that is `HUAWEI_APP_ID`, a repository variable rather than a secret, because it identifies the app and unlocks nothing on its own
**Confirm:** irreversible — the package name is entered here and fixes what this record can ever publish; the Publishing API cannot create apps, so a wrong one has to be abandoned and replaced by hand
**Browser mode:** fill the form, read back the app name, language, category and especially the package name, then an explicit yes before creating the record
**Guided mode:** print the click-path and every value including the package name; the human creates the record and brings back the numeric App ID
**Then:** `${CLAUDE_PLUGIN_ROOT}/skills/store-setup/scripts/state.sh note huawei_app_id <numeric>` with the App ID from the information page, then `${CLAUDE_PLUGIN_ROOT}/skills/store-setup/scripts/state.sh set huawei-app-record done`; next `huawei-app-signing`, `huawei-listing` (independent, any order), and `cred-huawei` once `huawei-api-client` is also done

### `huawei-api-client` — AppGallery Connect API client
**Console:** AppGallery Connect — https://developer.huawei.com/consumer/en/service/josp/agc/index.html
**Click-path:** AppGallery Connect → Users and permissions → API key → Connect API → Create → name the client → Project = N/A (this is a team-level client, not a project one) → limit its roles to app administration → Create (verify the menu wording on screen; this page has moved before)
**Enter:** a name for the API client, from the human; the roles to grant, kept to app administration rather than account-wide
**Take away:** the **Client ID** and the **Client Secret**, two strings and no file, for `HUAWEI_CLIENT_ID` and `HUAWEI_CLIENT_SECRET` (both secrets). `console-step.sh` refuses `--format json` for this id because the take-away is a pasted secret
**Confirm:** irreversible — the Client Secret is shown exactly once and cannot be read again; losing it means deleting this client and creating another
**Browser mode:** fill the name and the roles, read them back, then stop **before** Create and hand over: the human clicks Create and pastes both strings into `validate-huawei-credentials.sh` (through the environment, not into chat)
**Guided mode:** print the click-path, the name and the roles; the human creates the client and keeps both strings, then runs the validator themselves
**Then:** `${CLAUDE_PLUGIN_ROOT}/skills/store-setup/scripts/state.sh set huawei-api-client done`; next `cred-huawei` once `huawei-app-record` is also done. The pair is team-level: it authenticates for the whole developer account and what it can reach is decided by the roles granted here, not by which app it belongs to

### `huawei-app-signing` — AppGallery App Signing
**Console:** AppGallery Connect — https://developer.huawei.com/consumer/en/service/josp/agc/index.html
**Click-path:** AppGallery Connect → app → Build → App signing → read the page, then leave it off (verify the menu wording on screen)
**Enter:** nothing, unless the human explicitly asks to enable it; enabling asks for the upload key certificate
**Take away:** the decision, recorded on the checklist; no secret or variable
**Confirm:** permanent — once App Signing is enabled Huawei holds the release key and re-signs every bundle uploaded for this app, and there is no way back. **Manual signing with the repository's own upload key is the template's default**, it is the reversible path, and leaving App Signing off is a complete and correct answer to this step
**Browser mode:** open the page, read it back, and stop — do not enable it; if the human asks to enable it, read the permanence back and wait for an explicit yes in that turn before uploading any certificate
**Guided mode:** print the click-path and say plainly that the template's default is to leave it off; the human decides and reports back
**Then:** `${CLAUDE_PLUGIN_ROOT}/skills/store-setup/scripts/state.sh set huawei-app-signing done` (or `skipped`, if the human prefers to record it as not taken up); next `toggle-huawei` once `cred-huawei` and `huawei-listing` are also done

### `huawei-listing` — AppGallery listing, age rating and availability
**Console:** AppGallery Connect — https://developer.huawei.com/consumer/en/service/josp/agc/index.html
**Click-path:** AppGallery Connect → app → App information / Distribute → icon (216 by 216 pixels, PNG) → at least three screenshots (16:9 or 9:16, at most 2 MB each) → privacy policy URL → category → age rating questionnaire (bands 3+, 7+, 12+, 15+, 18+) → release countries → pricing → Save (verify the section names on screen)
**Enter:** icon and screenshots from `fastlane/metadata/android/en-US/images/`; the privacy policy URL, category, release countries and pricing from the human; every age-rating answer from the human only, each read back before it is entered
**Take away:** the saved draft listing; no secret or variable. Nothing here is synced by the pipeline — AppGallery listing fields are console-only, and `store-metadata` does not cover them
**Confirm:** safe — a draft listing publishes nothing and can be edited again at no cost; the lane's submit for review is the step that makes a version public, so saving here commits nothing
**Browser mode:** upload the images and fill the fields, read them back before Save; the age-rating questionnaire is mode (c) only — modes (a) and (b) get the human to the form and stop
**Guided mode:** print the click-path, the asset sizes and the fields to fill; the human fills them and reports back
**Then:** mode (c) answers the questionnaire only from what the human gives in this turn, reads each answer back, and waits for an explicit yes before Save; `${CLAUDE_PLUGIN_ROOT}/skills/store-setup/scripts/state.sh set huawei-listing done`; next `toggle-huawei` once `cred-huawei` and `huawei-app-signing` are also done. The bundle must target Android API level 30 or higher and ship 64-bit code — the template's Android build already does both. Review takes days rather than hours; verify the current estimate on screen

### `huawei-testers` — AppGallery test user list
**Console:** AppGallery Connect — https://developer.huawei.com/consumer/en/service/josp/agc/index.html
**Click-path:** AppGallery Connect → Users and permissions → List management → User list → New → name the list → add the testers' Huawei IDs → Save (verify the wording on screen; this menu has moved before), then AppGallery Connect → app → the version's open testing page → select the list there → Save (verify on screen)
**Enter:** a name for the list, and the testers' Huawei IDs — from the human only, never guessed and never taken from any file in this repository
**Take away:** a saved user list, selected for the release; no secret or variable. The internal tier uses the same open testing page with manual review skipped; there is no separate internal testing page. The limits are 100 testers on an internal test version, 5,000 on an open one, and 30 lists per developer account
**Confirm:** safe — a user list invites testers and publishes nothing; it can be renamed, edited or deleted again at no cost, and selecting it on a version only decides who may install that test build
**Browser mode:** create the list, add exactly the Huawei IDs the human gave in this turn, read the name and every ID back before Save, then select the list on the version's open testing page and read that selection back too
**Guided mode:** print both click-paths — the list one and the version-selection one — with the list name and the IDs the human gave; the human creates the list, selects it, and reports back
**Then:** `${CLAUDE_PLUGIN_ROOT}/skills/store-setup/scripts/state.sh set huawei-testers done`. Nothing in the Publishing API manages testers, so this is console-only work: testers are invited **per release** and install through the AppGallery app, which means every new test version needs the list selected again on its testing page

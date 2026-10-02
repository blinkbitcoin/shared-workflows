# A store setup session, end to end

A conceptual transcript of the `store-setup` skill taking a freshly generated
app, "Hello World" (`com.blinkbitcoin.helloworld`, repository
`blinkbitcoin/hello-world`), from unsigned builds to a submittable listing in
mode (a), `browser-pause`. Lines starting with `>` are the developer; indented
lines are the commands the agent runs and what they print. Values shown as
`...` are elided, output is trimmed to the lines that matter, and nothing here
is a real credential.

```
> Set up the store accounts for this app.

Using the store-setup skill.

Before anything: pick a mode (the prompt in SKILL.md and
references/modes.md is read out in full).
  (a) Browser, pausing at credentials (recommended). I drive Chrome and
      hand the keyboard back for sign-in, any 2FA prompt, the one-time
      .p8 download, agreements and anything that charges money. Expect
      5-10 handovers.
  (b) Guided, you click. I print the exact click-path and value for each
      step; you do it and report back. Slowest, about forty rounds.
  (c) Browser, end to end including agreements. As (a), and I also accept
      agreements and submit the questionnaires from answers you give me
      in that turn, each read back first. I never pay.
In every mode these wait for the word "yes" in the current turn, each
time: paying a fee, accepting an agreement or submitting tax or banking
details, Play App Signing, the first Play upload, registering an Apple
bundle identifier, creating an App Store Connect key, submitting for
review. Reply a, b or c.

> a

    ${CLAUDE_PLUGIN_ROOT}/skills/store-setup/scripts/preflight.sh
    tool             found  why
    git              yes    version control
    node             yes    runs the state.sh JSON helper
    gh               yes    GitHub CLI: variables, secrets, environments
    ...
    gh-auth          yes    gh must be logged in
    gh-repo          yes    the repo must resolve on GitHub
    fastlane         yes    runs the release lanes
    keytool          no     Android keystore inspection (warn only)
    (exit 0: keytool and sips-or-magick are warn-only rows)

    ${CLAUDE_PLUGIN_ROOT}/skills/store-setup/scripts/state.sh init
    ${CLAUDE_PLUGIN_ROOT}/skills/store-setup/scripts/state.sh mode browser-pause
    ${CLAUDE_PLUGIN_ROOT}/skills/store-setup/scripts/identifiers.sh \
      --repo blinkbitcoin/hello-world
    FAIL: IOS_BUNDLE_ID is not set as a GitHub variable
    FAIL: ANDROID_PACKAGE is not set as a GitHub variable
    FAIL: package.json name is still the template default (...)
    Remedy:
    gh variable set ANDROID_PACKAGE --body '<value>'
    gh variable set IOS_BUNDLE_ID --body '<value>'
    make init
    (exit 2)

The identifiers gate reads IOS_BUNDLE_ID, ANDROID_PACKAGE and IOS_SCHEME
from `gh variable list` and cross-checks them against app.config.ts and
package.json. It also refuses the template placeholder and Google's
reserved prefixes (`com.example.*`, `com.google.*`, `com.android.*`),
because the first Play upload fixes the package name forever. The remedy
is `make init`, never a hand edit of app.config.ts. Shall I run it?

> yes, com.blinkbitcoin.helloworld for both

    make init
      (answers: name "Hello World", slug hello-world, scheme helloworld,
       --ios-bundle-id com.blinkbitcoin.helloworld
       --android-package com.blinkbitcoin.helloworld
       --owners blinkbitcoin)
    gh variable set IOS_BUNDLE_ID   (com.blinkbitcoin.helloworld)
    gh variable set ANDROID_PACKAGE (com.blinkbitcoin.helloworld)
    gh variable set IOS_SCHEME      (helloworld)
    identifiers.sh --repo blinkbitcoin/hello-world
    PASS: ... (every assertion; app.config.ts, package.json and the
    repository variables agree)

    ${CLAUDE_PLUGIN_ROOT}/skills/store-setup/scripts/state.sh set preflight done; ${CLAUDE_PLUGIN_ROOT}/skills/store-setup/scripts/state.sh set identifiers done
    ${CLAUDE_PLUGIN_ROOT}/skills/store-setup/scripts/state.sh next --all
    apple-enrolment
    google-account

`${CLAUDE_PLUGIN_ROOT}/skills/store-setup/scripts/state.sh next` prints ids only; the owner and the one-line description
come from the checklist table in SKILL.md. Both of these are yours:
money and a legal identity — the Apple Developer Program is 99 USD a
year, Play registration 25 USD once. Apple's enrolment review takes
days; the Google steps do not wait for it. Tell me when either is done.

> apple enrolled, google registered

    ${CLAUDE_PLUGIN_ROOT}/skills/store-setup/scripts/state.sh set apple-enrolment done
    ${CLAUDE_PLUGIN_ROOT}/skills/store-setup/scripts/state.sh set google-account done
    ${CLAUDE_PLUGIN_ROOT}/skills/store-setup/scripts/state.sh next --all
    apple-agreements
    google-app-record
    google-service-account
    cred-upload-keystore
    ...

Opening the developer portal. Sign in yourself; I stop at the login wall
and at the two-factor prompt.

    [tab: developer.apple.com/account]  login wall → handing over

> signed in

    (agreements accepted by you; ${CLAUDE_PLUGIN_ROOT}/skills/store-setup/scripts/state.sh set apple-agreements done)

    Certificates, Identifiers & Profiles → Identifiers → + → App IDs
    Description: Hello World
    Bundle ID (explicit): com.blinkbitcoin.helloworld
    Capabilities: none ticked

Form read back as above. A bundle identifier cannot be deleted once an
app record uses it. Yes to register?

> yes

    Register → done. ${CLAUDE_PLUGIN_ROOT}/skills/store-setup/scripts/state.sh set apple-bundle-id done
    App Store Connect → Apps → New App: iOS, "Hello World",
    English (U.S.), com.blinkbitcoin.helloworld, SKU hello-world
    → Create (additive)
    ${CLAUDE_PLUGIN_ROOT}/skills/store-setup/scripts/state.sh set apple-app-record done

Next is the API key. I fill the form; you click Generate, because the
.p8 downloads exactly once and must land in your Downloads.

    Users and Access → Integrations → App Store Connect API → +
    Name: hello-world release   Access: App Manager, this app only
    → stopping before Generate

> generated, file is in Downloads

    store-credentials/scripts/validate-asc-key.sh \
      --p8 ~/Downloads/AuthKey_ABCD123456.p8 --key-id ABCD123456 \
      --issuer-id 00000000-0000-0000-0000-000000000000
    ok: PKCS#8 EC prime256v1 key, key id shape, issuer id shape
    ${CLAUDE_PLUGIN_ROOT}/skills/store-setup/scripts/state.sh note asc_key_id ABCD123456
      (an identifying fact, not the key; `note` refuses a
       credential-shaped key outright)

    (Google, in parallel while Apple's enrolment review runs)
    Play Console → Create app: "Hello World", English, App, Free,
    declarations ticked → Create. The package name is not entered here;
    the first upload fixes it.
    ${CLAUDE_PLUGIN_ROOT}/skills/store-setup/scripts/state.sh set google-app-record done

    ... service account created, per-app grant read back ("this app
    only"), testing tracks, then the upload keystore:
    store-credentials/scripts/new-upload-keystore.sh \
      --out ~/keys/hello-world.jks --alias upload > ~/keys/store.env
      (passwords come from the environment or `openssl rand`, reach
       keytool through -storepass:env, and are written next to the
       keystore with mode 600 — never onto a command line; the script's
       stdout is the push-to-github.sh env-file lines)
    ANDROID_UPLOAD_KEYSTORE_PASSWORD=... \
    ANDROID_UPLOAD_KEY_PASSWORD=... \
      store-credentials/scripts/validate-keystore.sh \
        --keystore ~/keys/hello-world.jks --alias upload
    ok: alias opens, RSA 2048, valid 10950 days (30 years)
    store-credentials/scripts/validate-play-json.sh --file ~/keys/play.json
    ok: valid JSON, type service_account, every field supply needs
    --check-access is a network call; run it?

> yes

    validate-play-json.sh --file ~/keys/play.json --check-access --yes
    ok: validate_play_store_json_key accepted the key

    Test and release → Setup → App integrity → App signing
    Choice read back: Google-generated signing key, upload certificate
    from the keystore above.

This is permanent for the app. Yes to enrol?

> yes

    ${CLAUDE_PLUGIN_ROOT}/skills/store-setup/scripts/state.sh set google-play-app-signing done

    store-credentials/scripts/push-to-github.sh --plan \
      --from-env-file ~/keys/store.env
    IOS_BUNDLE_ID (variable): unchanged
    TESTFLIGHT_EXTERNAL_GROUP (variable): set
    ANDROID_UPLOAD_CERT_SHA256 (variable): set
    ASC_KEY_ID (secret): set
    ASC_ISSUER_ID (secret): set
    ASC_KEY_P8_BASE64 (secret): set
    PLAY_SERVICE_ACCOUNT_JSON (secret): set
    ANDROID_UPLOAD_KEYSTORE_BASE64 (secret): set
    ...
    HUAWEI_CLIENT_ID (secret): missing
    ...
    (no value is ever printed)

That covers the eleven names STORE_UPLOADS_ENABLED hard-requires — ten
secrets plus TESTFLIGHT_EXTERNAL_GROUP — on blinkbitcoin/hello-world.
The Huawei names stay missing: AppGallery is an optional extra store.
Values reach `gh` on stdin, never on a command line. Apply?

> yes

    push-to-github.sh --apply --yes --from-env-file ~/keys/store.env
    push-to-github.sh --verify
    ok: every toggle that is on has everything it requires
    ${CLAUDE_PLUGIN_ROOT}/skills/store-setup/scripts/state.sh set cred-asc-key done; ... ; ${CLAUDE_PLUGIN_ROOT}/skills/store-setup/scripts/state.sh set cred-push done
    ${CLAUDE_PLUGIN_ROOT}/skills/store-setup/scripts/state.sh set gh-environments done

    Signing on first, then the rehearsal (rehearse-dry-run needs
    toggle-signing — the lanes read the toggles):
    gh variable set IOS_SIGNING_ENABLED --body true
    gh variable set ANDROID_SIGNING_ENABLED --body true
    ${CLAUDE_PLUGIN_ROOT}/skills/store-setup/scripts/state.sh set toggle-signing done

    DRY_RUN=1 bundle exec fastlane ios upload_internal
    DRY_RUN=1 bundle exec fastlane android upload_internal
    [dry-run] upload_to_testflight {... api_key: "[redacted]" ...}
    [dry-run] upload_to_play_store {... json_key_data: "[redacted]" ...}
    ${CLAUDE_PLUGIN_ROOT}/skills/store-setup/scripts/state.sh set rehearse-dry-run done

The next push builds signed. STORE_UPLOADS_ENABLED stays off until you
have watched one signed build go green, and the first Play upload is
gated on its own because it fixes the package name forever.

> next push was green

    The first Play upload of any artifact fixes ANDROID_PACKAGE for the
    life of the app, and it is `com.blinkbitcoin.helloworld`. Yes to
    upload the internal build?

> yes

    bundle exec fastlane android upload_internal
    ok: internal track, one artifact
    ${CLAUDE_PLUGIN_ROOT}/skills/store-setup/scripts/state.sh set first-play-upload done
    gh variable set STORE_UPLOADS_ENABLED --body true
    ${CLAUDE_PLUGIN_ROOT}/skills/store-setup/scripts/state.sh set toggle-uploads done
    ${CLAUDE_PLUGIN_ROOT}/skills/store-setup/scripts/state.sh next --all
    apple-testflight-groups
    apple-privacy-labels
    google-content-rating
    google-data-safety
    google-target-audience
    meta-scaffold
    ...

The content rating, Data Safety and target audience forms are legal
declarations. In mode (a) I navigate there and stop; you answer them.
Continue in (a)?

> yes, I'll answer them myself

    ... later, the metadata track:
    store-metadata/scripts/scaffold.sh --platform both
    store-metadata/scripts/check-metadata.sh --platform both
    fastlane/metadata/ios/en-US/description.txt: template placeholder
    fastlane/metadata/android/en-US/full_description.txt: template
      placeholder
    ... (exit 1)

> here are the texts: ...

    store-metadata/scripts/place-images.sh --platform ios ~/shots/*.png
    store-metadata/scripts/place-images.sh --platform android \
      --kind phone ~/shots/android/*.png
    store-metadata/scripts/age-rating.sh --set ...
    check-metadata.sh --platform both → ok
    store-metadata/scripts/sync.sh both --dry-run → ok
    store-metadata/scripts/sync.sh both --yes
    App Store Connect: description and keywords updated, the version
    still "Prepare for Submission"; Play listing updated, rollout
    unchanged.
    ${CLAUDE_PLUGIN_ROOT}/skills/store-setup/scripts/state.sh set meta-sync done

    ${CLAUDE_PLUGIN_ROOT}/skills/store-setup/scripts/state.sh render --markdown
    - [x] preflight
    - [x] identifiers
    ...
    - [-] huawei-account
    ...
    41 lines done, the 8 AppGallery steps skipped, store-ready reached.
    The rendered checklist goes in the handover; nothing in it is a
    credential.

Hello World is set up to "submittable, before review". Submitting for
App Review and starting a Play production rollout stay manual dispatches
with reviewers.
```

Three things to notice: every handover names the tab and the one action the
human takes; every irreversible step is read back and waits for a yes in that
turn; and nothing typed as a credential is repeated, written into
`.store-setup/state.json`, or placed on a command line.

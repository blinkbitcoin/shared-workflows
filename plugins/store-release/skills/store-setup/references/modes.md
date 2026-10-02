# Store Setup Modes

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

A mode chosen earlier is not a yes to this step: if the human says "I picked
(a), just accept it", refuse and ask for the word now.

## Login Walls and 2FA

**Recognise them:** a sign-in form, Apple's six-digit prompt, Google's "verify it's you", a re-auth interstitial, or any page you cannot read.

- Stop. Do not type into it, and do not click Continue "to see what happens."
- Hand over by naming the tab and the action: "Apple wants your 2FA code, the prompt is in tab N; enter it there and say `done` or `stop`."
- Resume only on their word, then re-run `tabs_context_mcp` before touching anything — element references from before the handover are stale.
- Never store or repeat a credential. If one is pasted into chat, use it for that one field in that turn and say plainly that you are not keeping it.
- Password-manager autofill counts as the human doing it — you are not typing the credential.
- An irreversible step — accepting an agreement, paying a fee, enrolling in Play App Signing, the first Play upload, creating the App Store Connect API key — never proceeds while the human is away, even with a prior yes: stop at the step and wait for them to come back.
- Load the `claude-in-chrome` skill via the Skill tool before any browser tool, and its rules still apply on top of the above: `tabs_context_mcp` first, never reuse a tab id, never trigger a JS alert, stop after two or three failed attempts on the same element, and use `gif_creator` for anything worth reviewing later.

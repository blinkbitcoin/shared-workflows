---
name: store-consoles
description: Use when a store setup step has to happen inside App Store Connect, the Apple Developer portal, Google Play Console, Google Cloud or Huawei AppGallery Connect - registering identifiers, app records, API keys, service accounts, TestFlight groups, testing tracks, privacy labels, content rating, data safety or pricing - by driving Chrome or by handing the human an exact click-path.
allowed-tools: Bash(gh variable:*), Bash(${CLAUDE_PLUGIN_ROOT}/skills/store-consoles/scripts/console-step.sh:*), Bash(${CLAUDE_PLUGIN_ROOT}/skills/store-consoles/tests/run.sh:*), Bash(${CLAUDE_PLUGIN_ROOT}/skills/store-setup/scripts/state.sh:*)
---

# Store Consoles

## Overview

This skill covers the 27 `apple-*`, `google-*` and `huawei-*` ids in the
`store-setup` checklist — everything that happens inside App Store Connect,
the Apple Developer portal, Google Play Console, Google Cloud or AppGallery
Connect, rather than in this repository or in GitHub.

**Core principle:** the reference block (`references/apple.md`,
`references/google.md`, `references/huawei.md`) is the contract.
`console-step.sh <id>` prints it,
with `Enter:`/`Take away:` values resolved from a `gh variable`, a
`fastlane/metadata/**` file, `state.facts.<key>`, or `package.json`'s `name`
where a source exists. The mode picked in `store-setup` decides **who
clicks** — the browser, or the human — never **what is entered**: that comes
from the block, resolved values, and the human's own words in this turn.

## Modes

`store-setup/references/modes.md` is the single source for the three modes
and the always-confirm table; this skill does not repeat or fork them.

- **(a) Browser, pausing at credentials** — drive Chrome for everything
  except sign-in, 2FA, the `.p8` download, agreements, and anything that
  charges money.
- **(b) Guided, you click** — never touch the browser; hand over the
  click-path and the resolved value, then record what the human reports.
- **(c) Browser, end to end including agreements** — as (a), plus submitting
  agreements and the four questionnaires below, from answers given in this
  turn, each read back before submit.

**The four questionnaires — content rating, data safety, target audience,
and App Privacy labels — are mode (c) only, with every answer read back and
an explicit yes before submit.** Modes (a) and (b) navigate to the form and
stop; they never fill or submit it. This is called out again in each of
those four blocks in `references/apple.md` and `references/google.md`.

## Huawei AppGallery

The six `huawei-*` ids are an **optional extra store** and every one of them
hangs off `toggle-uploads`, so they are only reached once the Apple and Play
path actually ships; a repository that does not publish on AppGallery answers
each with `${CLAUDE_PLUGIN_ROOT}/skills/store-setup/scripts/state.sh set <id> skipped`. Two of them carry the weight:
`huawei-app-record` is where the package name is entered, which fixes what
that record can ever publish, and `huawei-app-signing` is permanent once
enabled — manual signing with the repository's own upload key is the
family's default, so leaving App Signing off is the whole of that step.
`huawei-api-client` yields a client id and client secret, the secret shown
exactly once, so browser mode stops before Create and the human clicks it and
pastes both into `store-credentials`' `validate-huawei-credentials.sh`;
`--format json` is refused for that id for the same reason. The AppGallery
listing is console-only — `store-metadata` does not cover it — and its
age-rating questionnaire is mode (c) only, like the other four.
`huawei-testers` is the AppGallery test user list — console-only, because
nothing in the Publishing API manages testers, and re-selected per release
because that is how AppGallery invites them. Huawei
reorganises these menus more often than Apple or Google do, so anything
`references/huawei.md` could not confirm is marked "verify on screen": read
the label in front of you rather than insisting on the wording in the block.

## Procedure

1. `console-step.sh <id>` — read the block: `Console:`, `Click-path:`,
   `Enter:`, `Take away:`, `Confirm:`, `Browser mode:`, `Guided mode:`,
   `Then:`, plus a `Resolved:` line when a value could be looked up and a
   `WARNING:` line when a resolved value looks like a template placeholder.
   The reference files carry the url inside the `**Console:**` field (`name
   — url`); `console-step.sh` splits it out and prints it as its own `URL:`
   line, so there is no `URL:` field to edit in `references/*.md`.
2. Do the step per the current mode, honouring `Confirm:` — `paid`,
   `binding`, `irreversible` and `permanent` steps always get an explicit
   yes in this turn, in every mode, per the always-confirm table in
   `modes.md`.
3. `${CLAUDE_PLUGIN_ROOT}/skills/store-setup/scripts/state.sh note <key> <value>` for whatever the `Then:` line says to
   remember (never a credential — `${CLAUDE_PLUGIN_ROOT}/skills/store-setup/scripts/state.sh note` refuses those; they go to
   `gh secret set` instead, under `store-credentials`).
4. `${CLAUDE_PLUGIN_ROOT}/skills/store-setup/scripts/state.sh set <id> done`, then move to the id `${CLAUDE_PLUGIN_ROOT}/skills/store-setup/scripts/state.sh next` returns.

## Login Walls

See `store-setup/references/modes.md` → Login Walls and 2FA for the full
rules. Before touching any `mcp__claude-in-chrome__*` tool for any step in
this skill, **load the `claude-in-chrome` skill via the Skill tool** — its
rules (fresh `tabs_context_mcp` after any handover, never reuse a stale
element reference, stop after two or three failed attempts) apply on top of
the login-wall rules above.

## After Editing the Scripts

```bash
${CLAUDE_PLUGIN_ROOT}/skills/store-consoles/tests/run.sh
```

Offline against a fake `gh` and scratch `REPO_ROOT`/`STORE_SETUP_DIR`
directories — no network, no real console. Run it after touching
`scripts/console-step.sh` or either reference file, and again as part of
before committing.

## Common Mistakes

| Mistake | Consequence |
|---|---|
| Filling a questionnaire (content rating, data safety, target audience, App Privacy) in mode (a) or (b) | Those four are mode (c) only — navigate and stop instead |
| Treating a resolved `IOS_BUNDLE_ID`/`ANDROID_PACKAGE` value as pre-approved | `console-step.sh` only warns on an obvious placeholder; `identifiers.sh` is the real gate, and it runs before any console work starts |
| Typing a value `console-step.sh` printed as `<ask the human>` | That means no repo-local source exists — ask, do not guess |
| Running `--format json` on `google-app-access`, `apple-agreements` or `huawei-api-client` | Refused (exit 2): their resolved values can include a demo credential, tax/banking details, or the AppGallery client secret; use `--format text` |
| Skipping `${CLAUDE_PLUGIN_ROOT}/skills/store-setup/scripts/state.sh note`/`${CLAUDE_PLUGIN_ROOT}/skills/store-setup/scripts/state.sh set` after a step | The console has no memory of the mode or the human's earlier answers; the checklist state is the only record |

## Red Flags — Stop

- About to fill in or submit a questionnaire (content rating, data safety, target audience, App Privacy) outside mode (c)
- About to click Accept, Generate, Register, Confirm or Save on a `paid`, `binding`, `irreversible` or `permanent` step without an explicit yes in this turn
- About to type a password, PIN, 2FA code, or demo credential the human did not give you in this turn
- A browser tool is about to run and the `claude-in-chrome` skill has not been loaded yet in this turn

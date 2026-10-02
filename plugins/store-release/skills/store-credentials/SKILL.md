---
name: store-credentials
description: Use when creating, checking or wiring store credentials for an app on the family's release workflows - an App Store Connect API key, a fastlane match repository, an Android upload keystore, a Google Play service account, a Huawei AppGallery Connect API client, the App Review contact - or when deciding which of them go to GitHub as variables versus secrets.
allowed-tools: Bash(gh variable:*), Bash(gh secret:*), Bash(${CLAUDE_PLUGIN_ROOT}/skills/store-credentials/scripts/validate-asc-key.sh:*), Bash(${CLAUDE_PLUGIN_ROOT}/skills/store-credentials/scripts/validate-keystore.sh:*), Bash(${CLAUDE_PLUGIN_ROOT}/skills/store-credentials/scripts/validate-play-json.sh:*), Bash(${CLAUDE_PLUGIN_ROOT}/skills/store-credentials/scripts/validate-match-repo.sh:*), Bash(${CLAUDE_PLUGIN_ROOT}/skills/store-credentials/scripts/validate-huawei-credentials.sh:*), Bash(${CLAUDE_PLUGIN_ROOT}/skills/store-credentials/scripts/new-upload-keystore.sh:*), Bash(${CLAUDE_PLUGIN_ROOT}/skills/store-credentials/scripts/push-to-github.sh:*), Bash(${CLAUDE_PLUGIN_ROOT}/skills/store-credentials/tests/run.sh:*), Bash(${CLAUDE_PLUGIN_ROOT}/skills/store-setup/scripts/state.sh:*)
---

# Store Credentials

## Overview

This skill covers the `cred-*` ids in the `store-setup` checklist:
`cred-asc-key`, `cred-match`, `cred-upload-keystore`, `cred-play-json`,
`cred-huawei`, and `cred-push`, the step that wires everything into GitHub.

**Core principle:** every credential is validated for shape on this machine
before a macOS minute is spent, and reaches GitHub only through stdin.
`gh variable set NAME --body-file -` and `gh secret set NAME --body-file -`
both read the value from standard input; nothing here ever puts a value on
a command line, in an argv a process list can see, or in this skill's own
stdout.

## Ask First

- `validate-play-json.sh --check-access` makes a real network call (fastlane
  asks Google to validate the service account) — confirm before running it,
  or pass `--yes`.
- `validate-huawei-credentials.sh --check-access` makes a real network call
  (it exchanges the client id and secret for an AppGallery Connect access
  token, and with `--app-id` also looks the app record up) — confirm before
  running it, or pass `--yes`. Its offline checks need no confirmation and no
  network.
- `push-to-github.sh --apply` changes the target repository's GitHub
  variables/secrets — confirm before running it; the script itself also
  refuses to run without `--yes`.
- Never run `fastlane match nuke` from this skill or suggest it as a fix —
  see Red Flags.

## Procedure per Credential

### `cred-asc-key` — App Store Connect API key

```bash
${CLAUDE_PLUGIN_ROOT}/skills/store-credentials/scripts/validate-asc-key.sh \
  --p8 AuthKey_XXXXXXXXXX.p8 --key-id XXXXXXXXXX --issuer-id <uuid>
```

Or, once it is already base64'd for the GitHub secret:

```bash
${CLAUDE_PLUGIN_ROOT}/skills/store-credentials/scripts/validate-asc-key.sh \
  --base64 asc_key.b64 --key-id XXXXXXXXXX --issuer-id <uuid>
```

Checks the key is a PKCS#8 EC key on the `prime256v1` (P-256) curve — not
the PKCS#1 RSA shape a stray re-export sometimes produces — and that the
key id / issuer id look like what Apple actually issues.

### `cred-match` — fastlane match certificates repository

```bash
MATCH_GIT_BASIC_AUTHORIZATION=<base64 of user:token> \
  ${CLAUDE_PLUGIN_ROOT}/skills/store-credentials/scripts/validate-match-repo.sh --git-url <url>
```

The basic-auth header value is read from the environment
(`MATCH_GIT_BASIC_AUTHORIZATION`, the same name the lanes use) and handed to
git through `GIT_CONFIG_COUNT`/`GIT_CONFIG_KEY_0`/`GIT_CONFIG_VALUE_0`, so it
never lands in git's argv or a process listing; there is no `--basic-auth`
option (passing one is a usage error naming the environment variable
instead). Omit it for an SSH url.

Refuses (exit 2) a `--git-url` equal to `state.facts.production_match_git_url`
— that repo is not for rehearsing against. That fact is written by the
`apple-match-repo` console step (its `Then:` line runs `${CLAUDE_PLUGIN_ROOT}/skills/store-setup/scripts/state.sh note
production_match_git_url <url>`), so it is only set when the team already has
a production match repository. Warns, without failing, if `REPO_ROOT/certs`
already exists on disk from an earlier `fastlane match` run.

### `cred-upload-keystore` — Android upload keystore

```bash
${CLAUDE_PLUGIN_ROOT}/skills/store-credentials/scripts/new-upload-keystore.sh \
  --out certs/upload.keystore --alias upload
```

`certs/` must already be in `.gitignore` (it is, in the React Native template) — the
script checks `git check-ignore` on every file it is about to write
(`<out>`, `<out>.storepass`, `<out>.keypass`, `<out>.b64`) before writing
any of them, and refuses (exit 2) naming the first one not covered.
Refuses an existing `<out>` without `--force`. Passwords never touch argv
(`keytool ... -storepass:env ANDROID_UPLOAD_KEYSTORE_PASSWORD -keypass:env
ANDROID_UPLOAD_KEY_PASSWORD`) or any output stream — a generated password
is written straight to `<out>.storepass` / `<out>.keypass`.

Its stdout is five lines in `push-to-github.sh --from-env-file` format —
pipe them straight through:

```bash
${CLAUDE_PLUGIN_ROOT}/skills/store-credentials/scripts/new-upload-keystore.sh \
  --out certs/upload.keystore --alias upload > "$TMPDIR/creds.env" &&
  ${CLAUDE_PLUGIN_ROOT}/skills/store-credentials/scripts/push-to-github.sh \
    --apply --yes --from-env-file "$TMPDIR/creds.env"
rm -f "$TMPDIR/creds.env"
```

Already have a keystore? Validate it instead:

```bash
ANDROID_UPLOAD_KEYSTORE_PASSWORD=... ANDROID_UPLOAD_KEY_PASSWORD=... \
  ${CLAUDE_PLUGIN_ROOT}/skills/store-credentials/scripts/validate-keystore.sh \
  --keystore certs/upload.keystore --alias upload
```

### `cred-play-json` — Google Play service account key

```bash
${CLAUDE_PLUGIN_ROOT}/skills/store-credentials/scripts/validate-play-json.sh \
  --file play-service-account.json
```

Add `--check-access` (network — see Ask First) to also run fastlane's
`validate_play_store_json_key` against it.

### `cred-huawei` — Huawei AppGallery Connect API client

With the numeric app id the `huawei-app-record` console step recorded as
`state.facts.huawei_app_id`:

```bash
HUAWEI_CLIENT_ID=... HUAWEI_CLIENT_SECRET=... \
  ${CLAUDE_PLUGIN_ROOT}/skills/store-credentials/scripts/validate-huawei-credentials.sh \
  --app-id <numeric app id>
```

Both halves of the pair are read from the environment only — there is no
`--client-id` or `--client-secret` option, and passing one is a usage error
naming the environment variables instead. Offline it checks that the client
id is all digits (warning under 15), that the secret is hexadecimal and at
least 32 characters, that neither is a placeholder or a copy of the other,
that neither carries whitespace a paste picked up, and that `--app-id` is a
numeric app id with no leading zero — which is what catches a package name
pasted into `HUAWEI_APP_ID`. No value is ever echoed: failures report lengths
and character classes only.

Add `--check-access` (network — see Ask First) to exchange the pair for an
access token. That call is worth making: the fastlane plugin's own
`get_token` returns nothing on an authentication error and the upload action
then only prints "Cannot retrieve token", so a wrong secret in CI is a green
job that uploaded nothing. A 200 response whose body carries `ret.code != 0`
counts as a failure here for the same reason.

Then push all three names — the two secrets and the variable:

```bash
cat > "$TMPDIR/creds.env" <<'ENTRIES'
secret HUAWEI_CLIENT_ID=<client id>
secret HUAWEI_CLIENT_SECRET=<client secret>
variable HUAWEI_APP_ID=<numeric app id>
ENTRIES
${CLAUDE_PLUGIN_ROOT}/skills/store-credentials/scripts/push-to-github.sh \
  --apply --yes --from-env-file "$TMPDIR/creds.env"
rm -f "$TMPDIR/creds.env"
```

`HUAWEI_UPLOADS_ENABLED` is not pushed here — it is the `toggle-huawei`
step's job, after the listing and the App Signing decision are settled, and
`push-to-github.sh --verify` is what then checks the pair and the app id are
all present.

### `cred-push` — wire everything into GitHub

```bash
# Preview only — reads gh variable/secret list, writes nothing:
${CLAUDE_PLUGIN_ROOT}/skills/store-credentials/scripts/push-to-github.sh --plan

# Apply from a local env file — one entry per line, in one of two forms:
#   <variable|secret> NAME=value
#   <variable|secret> NAME@file=<path>
# The @file form reads the whole file as the value, unmodified and never
# echoed — it's the only way to carry a multi-line value (a JSON service
# account key, a PEM), and it's what new-upload-keystore.sh's stdout is
# shaped for (see cred-upload-keystore above).
${CLAUDE_PLUGIN_ROOT}/skills/store-credentials/scripts/push-to-github.sh \
  --apply --yes --from-env-file /path/outside/the/repo/creds.env \
  --env production

# After a toggle flips true, check nothing it needs is still missing
# (exit 0 nothing missing, 1 something missing, 3 no toggle is on):
${CLAUDE_PLUGIN_ROOT}/skills/store-credentials/scripts/push-to-github.sh --verify
```

Keep the env file, and every path one of its `@file=` entries points at,
outside the repository (`$TMPDIR` is the obvious home) or somewhere already
`.gitignore`d — `push-to-github.sh` refuses (exit 2) any such path that sits
inside a git repository without an ignore rule covering it, the same rule
`new-upload-keystore.sh` applies to the files it writes. Delete the env file
once `--apply` finishes.

## Variables versus Secrets

`push-to-github.sh`'s own class table is authoritative (tests assert it
matches an app's runbook "Variables and secrets" tables and every
`vars.*`/`secrets.*` name its workflows read, exactly, when the tests are run
against an app checkout with `APP_REPO_ROOT`; a new workflow variable needs
its name in the script and a runbook row). In short: variables are non-sensitive — visible in every log —
and everything else is a secret, including all seven `APP_REVIEW_*` values
(a reviewer demo login is a real credential, even though the lanes also
accept it through an `environment-variables`-style input elsewhere).

| | Variables (33) | Secrets (23) |
|---|---|---|
| Visible in logs | Yes | No (masked) |
| Set with | `gh variable set NAME --body-file -` | `gh secret set NAME --body-file -` |
| Can scope to an environment | Rarely needed | Yes — `internal`/`beta`/`production`, via `--env` |
| Examples | `IOS_BUNDLE_ID`, `STORE_UPLOADS_ENABLED`, `E2E_IOS` | `ASC_KEY_P8_BASE64`, `MATCH_PASSWORD`, `APP_REVIEW_EMAIL` |

## After Editing the Scripts

```bash
${CLAUDE_PLUGIN_ROOT}/skills/store-credentials/tests/run.sh
```

Uses real `openssl` and, when present, real `keytool` — no network, no real
`gh`, no real GitHub repository. Run it after touching any script here, and
again against an app checkout (`APP_REPO_ROOT=<path>`) before committing.

## Common Mistakes

| Mistake | Consequence |
|---|---|
| Pasting a base64 secret with embedded newlines straight into `--base64` | `validate-asc-key.sh` strips newlines before decoding, so this is fine — but a hand-typed `gh secret set` without that stripping is not |
| Downloading the OAuth-client JSON instead of the service-account key from Play Console | `validate-play-json.sh` catches it: "that is an OAuth client, not a service account key" |
| Putting a new keystore anywhere outside `.gitignore`'s `certs/` | `new-upload-keystore.sh` refuses (exit 2) rather than risk a committed keystore |
| Running `gh secret set NAME "$VALUE"` by hand | The value lands in shell history and the process list; use `--body-file -` and pipe the value in, as every script here does |

## Red Flags — Stop

- About to run `fastlane match nuke` (or suggest it) — it revokes every
  certificate on the team, breaking every other developer and CI job that
  match serves; there is never a good reason to reach for it from this
  skill
- About to echo, `cat`, or otherwise print a password, `.p8` key, or
  service-account JSON to the terminal
- About to run `push-to-github.sh --apply` without having shown the human
  the `--plan` output first

# Security scanning

`check-security` runs every enabled scanner and prints one verdict. `check-security
<job>` runs one scanner and the same verdict, so a single scanner on a laptop still
ends in the pass/fail answer CI would give.

The scanners are not in an app's repository. They are shared-workflows' own,
shipped in `@blinkbitcoin/app-tooling` and run as `pnpm exec check-security [job]`,
and in CI through the reusable `check-security.yml`, at the same commit as the
package. What an app keeps is its settings, `security-settings.json` (every key,
its default and its environment twin are in the package's own
`security-settings.json`), and the files those settings name: its Semgrep rules
(`jobs.code.rules`, added to the package's own React Native rules) and a `.mobsf`
with reasoned mobsfscan suppressions. The package README's "Security scanning"
section is the short version; this page is the reference. What a repository has
accepted, and what it cannot scan, is that repository's own `docs/security.md`.

`SECURITY_ENABLED=false` as a repository variable turns every scanner off, in CI
and locally.

## What runs, and where

Nine scanners, placed by what each reads: source is there on every pull
request, the built binaries only once a release is built. The last column is
where the template's callers run each one; an app places them by its own callers.

| Job | Reads | Runs in CI |
| --- | --- | --- |
| `dependencies` | the lockfile (osv-scanner) | every pull request, every push to `main` |
| `code` | app source, the package's and the app's own rules (Semgrep CE) | every pull request, every push to `main` |
| `policy` | the pnpm install policy (`pnpm-workspace.yaml`) | every pull request, every push to `main` |
| `review` | the diff (an LLM, off by default) | pull requests; the release pull request reviews everything since the last release tag |
| `bundle` | the exported JavaScript bundle | the release pull request, and the production dispatch |
| `review-codebase` | the codebase (knostic/OpenAnt, an LLM, off by default) | the release pull request |
| `mobile` | a fresh prebuild of `android/` and `ios/` (mobsfscan) | the production dispatch |
| `binaries` | the release's `.apk` and `.ipa` (OWASP MASTG checks) | the production dispatch, before any store job |
| `sbom` | the lockfile; writes `.security/sbom.cdx.json` | the production dispatch |

The release pull request is the one `pr-release.yml` keeps open; its CI is a
`workflow_dispatch` on the `release-please--` branch, so the caller recognises it
by `github.ref_name`. On the production dispatch the store jobs wait for the
`security` job and do not start if it fails.

## Where the findings show up

On a pull request, in the `Security / *` jobs and nowhere else. The `Verdict`
job's summary carries the report, and every reportable finding is an
annotation on the diff: an error when it blocks, a warning when it is only
reported. The verdict (`security-verdict.mjs`) prints those annotations only under
`GITHUB_ACTIONS=true`, so a laptop run stays plain text.

The SARIF goes to code scanning (Security → Code scanning) from `main` only.
Every upload makes code scanning add a check per tool under GitHub's own "Code
scanning results" heading, which cannot be renamed, and on a pull request
those checks only repeated the `Security / *` jobs. Before the upload each run
is named after its job, so the tool filter reads `Dependencies`, `Code`,
`Policy` and so on rather than `osv-scanner` and `Semgrep OSS`. CodeQL's own
`Code scanning results / CodeQL` check still appears on pull requests; see the
consumer guide's `check-code-scanning.yml` section.

The deterministic scanners can block a run; the two LLM jobs annotate unless
`failOn` names them (see "Turning things off" below). An LLM that refuses a
prompt, or answers differently twice, must not be able to hold a release.

gitleaks and zizmor are security gates too, and unlike the scanners above they
already run with the fast checks (`check-secrets` and `check-ci`). The line: the
checks own fast, reproducible pass/fail gates; `check-security` owns the
SARIF-producing scanners that cost minutes.

### Where the verdict goes

One verdict, several destinations, each written by the file named:

| Destination | Written by | When |
| --- | --- | --- |
| the step log and the run summary | `verdict.sh` in shared-workflows | every run |
| annotations on the diff | `security-verdict.mjs` in the package | on a runner only (`GITHUB_ACTIONS=true`) |
| code scanning | `check-security.yml` | from `main` only |
| `.security/verdict.json` | `security-verdict.mjs` in the package | every run that reaches a verdict, laptop included (not when a SARIF file cannot be read) |

`verdict.json` is one line of JSON, for the Security badge:

```json
{"verdict":"informational","highest":"medium","canBlock":true}
```

`verdict` is the word on the summary line, `highest` its highest severity
(`none` when nothing was found), and `canBlock` says whether anything in the
run could have failed it: `false` when `severity` is `none` or `failOn` is
empty, and the badge then adds `(advisory)`. In CI, `check-security.yml` turns
the file into its `verdict` output, which the caller hands to `publish-badges.yml`.
Locally, `gen-badges --local` reads the file from the last `check-security`.

### What each new scanner looks for

- **`bundle`** exports the bundle for each platform in `bundle.platforms` and
  reads its strings. A build-time or release variable's name (anything
  `.env.example` names that is not `EXPO_PUBLIC_*`) is high; a
  credential-shaped string (private key, Stripe, Google, AWS, GitHub, Slack,
  Anthropic, OpenAI) is critical; an `http://` URL is medium
  (MASTG-TEST-0233/0321) unless its host is in `bundle.cleartextHosts`; with
  `bundle.hosts` set, any other https host is low, so a new endpoint is seen.
- **`binaries`** reads the universal APK with `aapt2` and `apksigner` and the
  IPA with `plistlib` and `openssl`, and names every rule by its MASTG test:
  debuggable (0226, critical), cleartext traffic in the manifest or the network
  security config (0235), user-installed certificate authorities trusted (0286),
  v1-only signing (0224), a signing key under 2048 bits (0225), backups with no
  rules (0262), a dangerous permission not in `binaries.androidPermissions`
  (0254), an exported component with no permission not in
  `binaries.exportedComponents` (0364-0366), `get-task-allow` (0261, critical),
  App Transport Security allowing arbitrary loads or cleartext to a domain not
  in `binaries.atsExceptionDomains` (0322), and an exception below TLS 1.2
  (0342). Locally: `APK=... IPA=... check-security binaries`, either or
  both.
- **`mobile`** prebuilds both platforms into a temporary copy, the way
  `check-prebuild` does, and runs mobsfscan over it. Reasoned
  suppressions live in `.mobsf`.
- **`sbom`** is a record rather than a scan: a CycloneDX bill of every
  component the lockfile pins, kept as a workflow artifact of the production
  run so a later advisory can be checked against exactly what shipped.
- **`review`** sends the diff, with `security-review.prompt.md` as the
  instructions, to the configured provider and validates the answer before it
  becomes a finding: every finding must name a file in the diff, a line and a
  known severity, or the whole answer is dropped. Generated files and the
  lockfile are left out; files beyond `review.maxDiffBytes` are named as
  unreviewed rather than silently cut.
- **`review-codebase`** runs [OpenAnt](https://github.com/knostic/OpenAnt), pinned by
  commit in shared-workflows' `scripts/security/review-codebase.sh`, with dynamic (Docker) testing off.
  CI builds it from that commit; on a laptop, build it yourself and put
  `openant` on `PATH`.

## Turning the LLM jobs on

Both LLM jobs use one provider, set in the `llm` block of
`security-settings.json` or through its environment twins, and both are off
until a repository turns them on:

1. `"review": { "enabled": true }` and/or `"review-codebase": { "enabled": true }`
   under `jobs`.
2. `llm.provider`: `openai` for OpenAI or any OpenAI-compatible endpoint
   (OpenRouter, Gemini, Groq, Mistral, DeepSeek, Kimi, Qwen, GitHub Models -
   set `OPENAI_BASE_URL`), or `anthropic`. `llm.model` names the model; OpenAnt
   requires one. The [provider recipes](release-runbook.md#provider-recipes)
   give the base URL, a model and the effort for each.
3. The key as a secret: `OPENAI_API_KEY` or `ANTHROPIC_API_KEY`.

In CI, step 2 is the repository variables `SECURITY_LLM_PROVIDER`,
`SECURITY_LLM_MODEL`, `SECURITY_LLM_EFFORT`, `SECURITY_LLM_EXTRA_PARAMS` and
`OPENAI_BASE_URL`, which the caller passes through `environment-variables`, and
step 3 is a repository secret. The production dispatch carries none of them: model calls
stay out of the CD lanes, and the release pull request is where they run.

`llm.effort` (`none`, `low`, `medium`, `high`, `max`; `max` by default) is
sent to the reviewer apart from the model: Anthropic's `output_config.effort`
with adaptive thinking, or an OpenAI-compatible `reasoning_effort` (where `max`
asks for `high`, the most that schema has). `none` sends no effort field at
all, for a model with no reasoning switch, which would answer HTTP 400 to one.
Vendor-specific switches go in `SECURITY_LLM_EXTRA_PARAMS`, a JSON object
merged into the request (it may not set `model`, `messages` or `system`); a key
set to `null` removes that field, for an endpoint that rejects one of the
defaults. OpenAnt takes no effort setting.

A missing provider, key, model or prompt makes the job write "skipped" with
the reason, never "clean", and a model that does not answer, refuses, or
answers with something that does not validate does the same: a model being
down must never fail a pull request. The store-notes rewrite shares the same
adapters (`@blinkbitcoin/app-tooling/llm`, which the package's
`security-review.mjs` imports), with `STORE_NOTES_LLM_EFFORT` and
`STORE_NOTES_LLM_EXTRA_PARAMS` as its own two settings.

## Turning things off

Three layers, resolved in one order: an environment variable wins over
`security-settings.json`, which wins over the built-in default.

| To do this | Do it like this |
| --- | --- |
| Turn everything off for a repository | `SECURITY_ENABLED=false`, or `"enabled": false` in `security-settings.json` |
| Turn one scanner off | `SECURITY_CODE=false`, or `"jobs": { "code": { "enabled": false } }` |
| Change what fails a run | `"severity": "critical"`, or `SECURITY_SEVERITY=critical` |
| Give an engine class teeth | `"failOn": ["deterministic", "review"]` |
| Change one scanner's option | `"jobs": { "bundle": { "hosts": ["api.example.com"] } }`, or `SECURITY_BUNDLE_HOSTS=api.example.com` |
| Pick the LLM provider | `"llm": { "provider": "openai", "model": "kimi-k3" }`, or `SECURITY_LLM_PROVIDER` and `SECURITY_LLM_MODEL` |

Every option has an environment twin named `SECURITY_<JOB>_<KEY>`, the key in
upper snake case (`review-codebase` becomes `REVIEW_CODEBASE`):

| Option | Type | Default | Environment twin |
| --- | --- | --- | --- |
| `jobs.bundle.platforms` | list of `ios`, `android` | both | `SECURITY_BUNDLE_PLATFORMS` |
| `jobs.bundle.hosts` | list | empty (check off) | `SECURITY_BUNDLE_HOSTS` |
| `jobs.bundle.cleartextHosts` | list | `localhost`, `127.0.0.1` | `SECURITY_BUNDLE_CLEARTEXT_HOSTS` |
| `jobs.binaries.androidPermissions` | list | empty | `SECURITY_BINARIES_ANDROID_PERMISSIONS` |
| `jobs.binaries.exportedComponents` | list | empty | `SECURITY_BINARIES_EXPORTED_COMPONENTS` |
| `jobs.binaries.atsExceptionDomains` | list | empty | `SECURITY_BINARIES_ATS_EXCEPTION_DOMAINS` |
| `jobs.review.maxDiffBytes` | whole number | `200000` | `SECURITY_REVIEW_MAX_DIFF_BYTES` |
| `jobs.review-codebase.limit` | whole number, `0` for none | `0` | `SECURITY_REVIEW_CODEBASE_LIMIT` |
| `jobs.review-codebase.verify` | boolean | `false` | `SECURITY_REVIEW_CODEBASE_VERIFY` |
| `llm.provider` | `openai`, `anthropic` or empty | empty | `SECURITY_LLM_PROVIDER` |
| `llm.model` | string | empty | `SECURITY_LLM_MODEL` |
| `llm.effort` | `none`, `low`, `medium`, `high`, `max` | `max` | `SECURITY_LLM_EFFORT` |

In the environment a list is comma-separated, and an **empty** option or
`llm` twin counts as unset, so the file or the default applies: a caller passes every
twin through `environment-variables`, where a repository variable nobody set arrives as an
empty string. To empty a list, set it to `[]` in the file. A value that does not parse -
not `true` or `false`, not a whole number, a list entry outside its set, an
effort or provider outside the vocabulary - fails the run rather than reading
as off, so a typo cannot silently disable a scanner. So does a key the schema
does not know (`androidPermission` for `androidPermissions`), which would
otherwise leave the real key at its default with no sign anything was wrong.
Keys starting with `$` are comments. The same is true of `severity` (must be
one of `none`, `low`, `medium`, `high`, `critical`) and of every entry in
`failOn` (must be a known engine class): a dropped letter in
`SECURITY_FAIL_ON=deterministc` fails the run, it does not quietly leave
nothing able to block.

An **empty** `failOn` (`SECURITY_FAIL_ON=`, or `"failOn": []`) is different -
it is a legitimate choice for a consumer who wants every scanner advisory
only, so it is allowed. But nothing can block with an empty `failOn`,
whatever severity turns up, so the summary line says so explicitly
(`failOn is empty: nothing can block`) rather than letting the run read as an
ordinary pass.

## Reading the summary line

The last line of every run is one of four words, in order of how bad the
news is:

| Headline | Meaning |
| --- | --- |
| `security: fail` | A finding at or above the threshold came from an engine class in `failOn`. Exit code 1. |
| `security: informational` | Findings exist, none of them blocking (below the threshold, or from an engine class not in `failOn`). Exit code 0. |
| `security: skipped` | No blocking or reportable findings, but at least one job did not run (a missing tool, a disabled job).<br>Exit code 0, as nothing ran that could have blocked, but not the same claim as `pass`. |
| `security: pass` | Every job ran, and found nothing reportable. Exit code 0. |

`pass` is a claim that the whole gate ran and found nothing; `skipped` is a
claim that most or all of it did not run at all. Turning a scanner off -
`SECURITY_CODE=false`, a missing tool on a laptop with no `mise install`,
`SECURITY_ENABLED` left set from a previous run - trades `pass` for
`skipped` for as long as that job stays off, and the two must never be
confused for each other, which is why the verdict prints a different word
for each rather than folding `skipped` into `pass` once nothing is left to
report.

The line also carries a suppressed count: `N suppressed` names how many
results a scanner's own config already dropped (`osv-scanner.toml`,
`.semgrepignore`, an inline marker) - dropped from blocking correctly, but
counted rather than vanishing without a trace, so a suppression stays
distinguishable from a vulnerability nobody ever found.

## Skipped is not clean

A scanner with nothing to scan - no tool installed, no binary, no key - writes
a SARIF whose run says `executionSuccessful: false` and carries the reason.
The verdict prints `skipped: <reason>` for it and never counts it as clean.
A missing tool is a skip on a laptop but a failure under `CI=true`, because a
pipeline that quietly scans nothing is worse than one that is red. The same
goes for a partial run: `binaries` without `aapt2`, or a review whose diff
outgrew `review.maxDiffBytes`, reports the part that did not run as skipped
even when the rest found nothing.

A job switched off in `security-settings.json` behaves differently in the two
places. Locally, `check-security` still runs its script, which writes
"skipped: disabled", so with `review` and `review-codebase` off by default the local
headline reads `skipped`. In CI the job is not started at all, so it is
absent from the verdict and the headline can read `pass`.


## Suppressing a finding, correctly

Each scanner reads its own config, and every suppression carries a reason:
`osv-scanner.toml` for advisories, `.semgrepignore` and the app's own rules for
source patterns, `.mobsf` for mobsfscan, `.gitleaks.toml` for secrets,
`.github/zizmor.yml` for workflows, and the allowlists under `jobs.bundle` and
`jobs.binaries` in `security-settings.json` for the bundle and binary checks.
Never raise the severity threshold to hide one finding: that hides the next one too.

## Known limitations

**The Semgrep registry packs are not content-pinned.** `code.sh` pulls
`p/typescript`, `p/secrets` and `p/owasp-top-ten` from the Semgrep registry by
name; only the `semgrep` binary version is pinned. Registry rule content can
therefore drift between a laptop and a CI run over time, even with the same
binary version, because the registry packs update independently upstream. The
package's own rules and an app's `jobs.code.rules` are versioned in a
repository, so they do not drift. Treat a new Semgrep finding with no matching
source change as a possible pack update, not necessarily a regression. It also
means `code.sh` needs network access every run: fetching the packs is what
`--config p/...` does. `--metrics off` only stops telemetry; it does not make
the run offline.

**An osv-scanner ignore leaves no trace in run output.** Unlike a Semgrep or
gitleaks suppression, `osv-scanner` drops an `IgnoredVulns` match from its SARIF
entirely rather than emitting it with a suppression marker, so the verdict has
nothing to count and `dependencies` simply reports clean; the summary line's
suppressed count stays `0` regardless. `osv-scanner.toml` and the repository's
own record of accepted advisories are therefore the only places an accepted risk
is visible: do not read a clean `dependencies` run, on its own, as nothing being
carried.

### The shipped Semgrep rules

The package's rules (`security/rules/react-native-secrets.yaml`, run by `code`
before an app's own) report a plaintext secret written to `AsyncStorage` or
`expo-sqlite/kv-store`, a cleartext `http://` network endpoint, and an
interpolated WebView `injectedJavaScript`. `rn-secret-in-plain-storage` has two
deliberate gaps. It does not match an unqualified `key` identifier, so
`keyExtractor` and `sortKey` are not reported: only identifiers that read as a
credential, such as `apiKey` or `authToken`, trigger the rule. It also does not
match a fused-lowercase identifier such as `authtoken`: the rule looks for a word
boundary between the credential word and the rest of the name, so `authToken` and
`auth_token` match but `authtoken` does not. Both are precision trade-offs
against false positives on ordinary React Native code, not coverage gaps to be
closed by loosening the pattern. A wrapper an app puts in front of its storage is
the app's own rule to write; each rule has a fixture, run by `semgrep --test`.

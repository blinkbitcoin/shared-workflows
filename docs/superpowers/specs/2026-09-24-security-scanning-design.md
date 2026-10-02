# Security scanning: design

Date: 2026-09-24
Status: approved; every scanner implemented (template: scripts/security/),
shared workflow and call sites delivered separately
Supersedes the placement and packaging decisions in
blinkbitcoin/shared-workflows#49 and
blinkbitcoin/react-native-mobile-template#59, which stay the record for the
research, the tool evaluation and the provider-portability findings.

## What changed since the plan was written

The 2026-09-22 plan was exported to issues and never implemented. Four things
have moved since, and each changes the design:

1. **gitleaks and zizmor already ship.** `check-code.yml` gained `secrets`
   and `zizmor` inputs (shared #62, template #61, merged 2026-09-23) and they
   run on every pull request. The plan had both as scanners inside a
   release-only gate, which would run them twice, later, for no gain.
2. **Workflow files are grouped by prefix** (shared #64, template #63). The
   name `security-smoke.yml` no longer fits, and the call sites the plan
   named are gone: `checks.yml` is `check-code.yml` and
   `release-production.yml` is `cd-production.yml`.
3. **Measured gates run at 100% coverage and are never lowered.** Every new
   `.mjs` in this design carries that obligation, which is a reason to have
   fewer of them.
4. **`docs/quality.md` exists** with a tool-ownership table that any new
   scanner joins.

## Principles

These decide the open questions; the rest of the document applies them.

- **Place a check by what it reads.** Source is available on every pull
  request, so source scanning belongs there. Built binaries only exist after
  a release build, so binary scanning belongs at the production dispatch.
- **Block on reproducible, annotate on probabilistic.** The deterministic
  scanners gate, because the same commit yields the same answer. An LLM
  reviewer runs on whichever endpoint a consumer configures, and per the
  research some models refuse security prompts outright; a gate that flakes
  gets disabled, or teaches people to merge past red, which costs the
  deterministic gates their credibility too.
- **Anything a developer can run, runs locally.** `make check-security-*`
  and CI execute the same scripts, including the merge and the verdict, so
  the local answer is the CI answer.
- **One name per scanner** across the make target, the CI job and the policy
  key, so a red check names the command that reproduces it.
- **Environment beats file beats default.** One resolution order everywhere.

## Architecture

### The workflow

`shared-workflows/.github/workflows/check-security.yml`, display name
`Security`, following the `check-` prefix and the bare-noun display names of
`check-code.yml` ("Checks") and `check-codeql.yml` ("CodeQL").

One job per scanner rather than the plan's single `deterministic` job that
ran six scanners internally — the same reasoning as shared #69, "split
self-CI into a job per gate, so a run names what failed":

| Job | Make target | Reads |
| --- | --- | --- |
| `config` | — | `security-policy.json`, emits booleans as outputs |
| `deps` | `check-security-deps` | `pnpm-lock.yaml` (osv-scanner) |
| `code` | `check-security-code` | source (semgrep CE + `rules/`) |
| `policy` | `check-security-policy` | `pnpm-workspace.yaml`, audit signatures |
| `sbom` | `check-security-sbom` | lockfile (CycloneDX) |
| `bundle` | `check-security-bundle` | the exported bundle |
| `mobile` | `check-security-mobile` | prebuilt `android/`, `ios/` (mobsfscan) |
| `binaries` | `check-security-binaries` | `.aab`, `.apk`, `.ipa` (MASTG) |
| `review` | `check-security-review` | the diff or the release range |
| `openant` | `check-security-openant` | the codebase |
| `verdict` | — | every SARIF above |

`deterministic`, `review` and `openant` survive as the **`failOn`
vocabulary**, not as job boundaries: `failOn: ["deterministic"]` means the
scanner jobs have teeth and the two LLM jobs do not.

### The adapter contract

Unchanged from the approved design, and it is what keeps the jobs
interchangeable. Every job ends with one SARIF file:

- SARIF 2.1.0, `runs[].tool.driver.name` set, `results[].level` in
  error/warning/note, `properties.security-severity` on the GitHub scale
  where the tool knows it; otherwise the merge maps error to high, warning to
  medium, note to low with a per-tool default.
- **A finding never fails its own job.** Exit 0 with findings. A scanner
  crash — missing binary, bad config, output that is not SARIF — is a job
  failure.
- **Nothing to scan is never silence.** No binaries, no key, no prompt file:
  an empty run carrying a `toolExecutionNotifications` note with
  `executionSuccessful: false`, plus a `::notice::`, so the summary reads
  "skipped: reason" and never "clean".
- `verdict` is the only job that fails on findings. It merges the SARIFs,
  uploads each under category `security/<job>`, writes the step summary and
  annotations, and exits non-zero when a finding at or above the configured
  severity comes from a job whose engine class is in `failOn`.

### Where it runs

| Tier | Jobs | Teeth |
| --- | --- | --- |
| Every pull request (`ci.yml`, `needs: checks`, skipped when `checks.outputs.docs-only == 'true'`) | `deps`, `code`, `policy`, `review` (diff-scoped) | scanners block; `review` annotates |
| The release-please pull request (same job, widened by `startsWith(github.head_ref, 'release-please--')`) | the above plus `bundle`, `openant`, and `review` switches to the full `tag..HEAD` range | scanners block; LLM blocks only if a consumer adds it to `failOn` |
| Production dispatch (`cd-production.yml`, `action == 'release'`, `needs: prepare`) | `binaries`, `mobile`, `bundle`, `sbom` | blocks: `ios-release`, `android-release` and `huawei-binary` gain `needs: security` with `!failure() && !cancelled()` |

`bundle` exports the JavaScript bundle and reads its strings, which costs
minutes, so it runs at release time rather than on every pull request. It
replaces the off-by-default `bundle-secrets` input of `check-code.yml`, which
stays off: one home per check.

The release-please pull request is genuinely pre-release: the tag does not
exist until it merges. That is how "a review before creating a release" is
satisfied without putting LLM credentials in a CD lane, which ADR 0021 and an
existing structural test both forbid.

## Configuration

Four layers, resolved as **environment variable → `security-policy.json` →
built-in default**. A value that is not a boolean fails the run rather than
reading as off.

1. **`SECURITY_ENABLED`** — the per-repo master switch, and simply the top of
   that chain rather than a separate mechanism. In CI it is a repository
   variable on the call-site `if:`, matching `OTA_ENABLED`,
   `STORE_UPLOADS_ENABLED` and `HUAWEI_UPLOADS_ENABLED`. A skipped job is
   green, so `require-green-workflow: ci.yml` never waits on it.
2. **`security-policy.json`** at the repository root — every tunable: which
   jobs are enabled, `severity.failOn`, which engine classes have teeth,
   review scope and limits, the Android permission allowlist, iOS ATS
   exceptions, the bundle host allowlist, path excludes. Each block carries
   `"enabled": false` so a layer goes dark without touching CI. Every key has
   an environment-variable twin (`SECURITY_CODE`, `SECURITY_SEVERITY`, …).

   JSON, not the YAML the original plan specified. That deletes `config.mjs`,
   a hand-rolled YAML-subset parser written only because the shared LLM jobs
   run consumer scripts with no `pnpm install`, along with the 100%-coverage
   tests it would have needed. It also matches the `test-policy.json`
   decision of 2026-09-22: tunable numbers live in one repo file, and a
   reusable-workflow input may switch a layer on or off but never carry a
   value. The original plan broke that rule by having `severity-threshold` as
   a workflow input *and* `severity.failOn` in the config file.
3. **Native scanner files** — `.gitleaks.toml`, `osv-scanner.toml`,
   `.semgrepignore` with `rules/`, `.mobsf`, `.github/zizmor.yml`. Per-rule
   suppressions stay in each scanner's own format, each with a reason. A
   first-run baseline gets reasoned ignores here, never a threshold bump.
4. **Workflow inputs — booleans only.** They express what a *tier* can do,
   not what the repo wants; binaries do not exist at pull-request time. The
   effective setting is the AND of tier and policy, so a call site may narrow
   and never widen.

Missing API keys are a fifth, implicit disable: the LLM jobs write a skipped
SARIF with a reason.

## Where the code lives

**Everything a developer can run lives in the template**
(`scripts/security/`): policy resolution, every scanner runner, the SARIF
merge and the verdict. **`check-security.yml` owns only what exists in CI**:
the job graph, permissions, mise installs, artifact passing, the upload to
code scanning, and the step summary.

This moves `sarif-merge.mjs` and `verdict.sh` out of shared-workflows, where
the original plan put them. The reason is the local-first principle: the
alternative is two implementations of the only subtle logic in the design,
one for CI and one for `make`, and they will drift.

Shared carries **no fallback runners**. Duplicates there would serve only a
consumer not generated from this template, and no such consumer exists — "a
baseline with one consumer is not a baseline". Instead the workflow declares
a contract: a job that is enabled but whose `scripts/security/<job>.sh` is
missing **fails loudly**, never skips quietly. When a second, non-template
consumer appears, the shared subset moves into `@blinkbitcoin/dev-config`,
the same escape hatch the coverage baseline already plans to use.

This keeps both standing rules intact: reusable *mechanics* — the workflow,
the job graph, the upload — live in shared; app content and anything with a
local meaning lives in the template.

## The LLM jobs

Unchanged from the approved plan, which the research settled:

- **Provider portability is a hard requirement.** `SECURITY_LLM_PROVIDER`
  (`openai|anthropic`), `SECURITY_LLM_MODEL` and `OPENAI_BASE_URL` travel in
  `build-env`; keys are secrets. `openai` plus a base URL covers Kimi K3,
  Grok, Qwen, GLM, DeepSeek and OpenRouter, which matters because frontier US
  models refuse security-scan prompts. No vendor-locked action is the engine.
- **Effort is configurable apart from the model and defaults to the
  highest level.** One vocabulary, `low|medium|high|max`, mapped per provider
  in `scripts/lib/llm/`: Anthropic `output_config: { effort }` with thinking
  left adaptive; OpenAI-compatible `reasoning_effort`, where `max` sends
  `high`, the highest the schema accepts. Vendor-specific switches go through
  `SECURITY_LLM_EXTRA_PARAMS`, a flat JSON object merged into the request
  body, validated and never logged. `RELEASE_NOTES_LLM_EFFORT` gets the same
  treatment, so the store-notes rewrite and the reviewer share one adapter.
- The adapters move from `scripts/release/llm/` to `scripts/lib/llm/` with
  one fix: send `max_completion_tokens` only to `api.openai.com`,
  `max_tokens` elsewhere.
- The reviewer reads `security-review.prompt.md` at the repository root,
  defensively framed (report defects, never write exploit code), and returns
  strict JSON that is validated before it becomes SARIF: the file must be in
  the diff set, the line an integer, the severity in the enum. A rejected
  chunk is dropped whole. Every failure path writes a skipped SARIF and exits
  0.

## Local use

`make check-security` runs every enabled layer whose tool is installed and
prints a skip line for the rest; under CI a missing tool is a failure, so
"skipped" can never pass for "clean". Tools install through mise. SARIF lands
in `.security/`, summarised through the existing `codeql-findings.mjs`.

`check-security` is **not** part of `make check` or `make ci` — external CLIs
and minutes, the same reasoning that keeps `check-codeql` out. The pre-push
gate stays `make check && make test-unit && make test-scripts`.

`check-secrets` (gitleaks) and `check-ci` (zizmor) stay exactly where they
are, inside `make check`. That is the same line drawn in the Makefile as in
the workflows: `check` owns fast, reproducible pass/fail gates;
`check-security*` owns the SARIF-producing scanners that cost minutes.

## Default posture

Deterministic scanners are **on by default** in a generated app; the LLM jobs
stay dark until a provider and key exist. A repository that finds the whole
thing overkill sets `SECURITY_ENABLED=false` once. `failOn` defaults to
`deterministic` and the severity threshold to `high`, so the common case is
annotations rather than red builds.

## Testing obligations

- One test file per new `.mjs`, at 100% lines, branches and functions — the
  measured-gate rule. Pure helpers are exercised through `bash -c` the way
  `verify.test.mjs` already does.
- `release-workflows.test.mjs` gains the structural assertions: the `ci.yml`
  job shape and its gate expression, the release-please widening, the
  production job carrying `release-tag` and no LLM environment, the store
  jobs' `needs` and status guard. The existing "no LLM env in CD lanes" test
  must stay green.
- shared-workflows: `workflow-shape.bats` for the published list, the
  `build-env` loop, verdict-only permission escalation, the SARIF category
  and the fork guard; `consumer-contract.bats` gains a `check-security`
  guide section.
- SARIF fixtures cover threshold boundaries, `none`, `failOn` filtering,
  suppressions, the run cap, a skipped engine and a crashed engine.

## Delivery

Depends on `2026-09-24-make-target-naming-design.md`, which lands first so
every target name here is final.

1. **Template, part 1** — policy file and loader, scanner configs, the
   scanner runners, merge and verdict, `make check-security*`, docs. Inert:
   nothing calls the shared workflow yet, so it can merge before
   shared-workflows releases.
2. **shared-workflows** — `check-security.yml`, its tests and guide section;
   `feat` release; `v0` moves. Watch the template's next CD / Internal run
   afterwards, because the gate cannot execute its own reusable workflows.
3. **Template, part 2** — the two call sites and their structural tests.
   This must wait until `v0` carries `check-security.yml`: a `uses:` of a
   missing workflow file is a `startup_failure` for the whole run, on `main`
   too, which would also red the internal build gate.

Stacked with `gh stack`.

## Verification

1. `make check-security` locally with the scanners installed through mise,
   and with `ARTIFACT`/`AAB`/`APK` pointing at a downloaded pre-release.
   A deliberately debuggable fixture APK must yield `MASTG-TEST-0226`, and a
   missing `python3` must yield a skip line rather than a pass.
2. shared-workflows `make check`, then a `scratch/*` branch of the template
   calling `check-security.yml@<sha>` on a pull request — no gate in shared
   executes its reusable workflows, so this is the only real proof.
3. Live: the next pull request shows the scanner jobs; the release-please
   pull request additionally shows `OpenAnt` and a full-range `Review`; a
   production dispatch shows `Binaries` before `Release iOS` and
   `Release Android`. Force one failure by lowering the threshold on a
   scratch dispatch and confirm the store jobs skip.
4. First-run baseline, expected and each given a reasoned ignore in its
   native config: zizmor `unpinned-uses` on the `@v0` callers, the two lapsed
   OSV ignores, gitleaks on the credential-skill fixtures, semgrep on
   `localhost` URLs in tests.

## Out of scope

- Reproducible-build verification against the Play-served APK, and adding
  `sbom.cdx.json` to the fixed release asset set: separate `feat(release)`
  work.
- Full MobSF server scorecard, TruffleHog, Trivy, Scorecard: documented
  extras, not built.
- Jev: excluded. ADR 0022 records why — a closed, waitlisted decision model
  whose own documentation says adversarial input moves its verdicts, with no
  detection an LLM reviewer or gitleaks lacks.
- An optional LLM pull-request reviewer for other consumers
  (shared-workflows#50) stays a separate idea; the per-pull-request `review`
  job here covers this repository's need.

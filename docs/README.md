# Documentation index

Start here. [`docs/consumer-guide.md`](consumer-guide.md) is the contract; the
rest explain the parts of it that surprise people.

## Which doc when

| You want to... | Read |
| --- | --- |
| Add these workflows to an app that was **not** generated from the template | [adopting-an-existing-repo.md](adopting-an-existing-repo.md) |
| Call a workflow from your app repo, or look up an input, output or secret | [consumer-guide.md](consumer-guide.md) |
| Cut a release, promote a build, halt a rollout, or rehearse a lane | [release-runbook.md](release-runbook.md) |
| Turn OTA updates on, publish a hotfix, roll one back, or deploy the update server | [ota.md](ota.md) |
| Run the security scanners, read their verdict, or turn one off | [security.md](security.md) |
| Know why a CI, release or tooling choice was made | [decisions/README.md](decisions/README.md) |
| Work out why a cache missed, or what invalidates one | [cache-keys.md](cache-keys.md) |
| Read what a failed (or passing) E2E run left behind | [forensics.md](forensics.md) |
| Choose a runner label, or understand the macOS bill | [runners.md](runners.md) |
| Find where a CI run spent its time: queues, slow steps, the critical path | [consumer-guide.md](consumer-guide.md#where-a-run-spends-its-time) |

## One line each

| Doc | Contents |
| --- | --- |
| [adopting-an-existing-repo.md](adopting-an-existing-repo.md) | What an existing app has to provide, per workflow it calls, and the two ways to satisfy each gate. The table is generated from `packages/app-tooling/contract.json` |
| [consumer-guide.md](consumer-guide.md) | Every workflow's inputs, outputs and secrets; the full caller examples; versioning and the `@v0` pin; the `.workflows/` self-checkout; what each app configuration file becomes on the Expo presets; where a run spends its time (`trace-run`) |
| [release-runbook.md](release-runbook.md) | The six steps of a release across the callers, versions and build numbers, store notes and their LLM pass, the listing sync, store toggles, every variable and secret, environments, rollback, hotfix, the verification gates, `DRY_RUN=1` |
| [ota.md](ota.md) | The `OTA_ENABLED` toggle, code signing, the channel model, the fingerprint gate, hotfix and rollback; the update server is in `deploy/ota/` |
| [security.md](security.md) | What `check-security` runs, the nine scanners, where findings and the verdict go, every setting and its environment twin, the LLM jobs, suppression, known limits |
| [decisions/README.md](decisions/README.md) | The architecture decisions behind the CI, release and tooling half of the template, kept under their original numbers |
| [cache-keys.md](cache-keys.md) | Each cache's key shape, what invalidates it, and the restore/save split |
| [forensics.md](forensics.md) | The artifacts an E2E job uploads on iOS and Android, what is in each, and retention |
| [runners.md](runners.md) | Runner labels, macOS billing at 10x, self-hosted notes, KVM and disk pressure |

## Elsewhere in the repo

| Path | Contents |
| --- | --- |
| `AGENTS.md` | The canonical rules-of-the-road file for humans and coding agents. `CLAUDE.md` includes it |
| `CONTRIBUTING.md` | Setup, worktrees, commit conventions, and what a change has to carry |
| `SECURITY.md` | Private reporting, the threat model and the secrets policy |
| `README.md` | What this repo is, the caller to copy, the workflow table, pinning, and what it needs from you |
| `packages/app-tooling/README.md` | `@blinkbitcoin/app-tooling` — the pinned tool table, `check-tool-versions`, `check-contract`, the repository guards, `gen-store-notes`, the security scanners, the store lanes, the shared app suites, the programs an app's Makefile calls, and under `expo/` the Jest, ESLint, Biome, Metro, Playwright, lefthook, fingerprint, TypeScript and commitlint presets with their peer dependencies |
| `scripts/e2e/README.md` | How the E2E scripts fit together on a runner |
| `docs/superpowers/` | The specs and plans this repo and the app template were built from. History, not a guide |
| `plugins/store-release/` | The Claude Code plugin an app installs for store setup: the store-consoles, store-credentials, store-metadata and store-setup skills |
| `deploy/ota/` | A Docker Compose deployment of the self-hosted OTA update server, with reverse-proxy, storage and backup notes |

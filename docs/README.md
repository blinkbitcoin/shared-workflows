# Documentation index

Start here. [`docs/consumer-guide.md`](consumer-guide.md) is the contract; the
rest explain the parts of it that surprise people.

## Which doc when

| You want to... | Read |
| --- | --- |
| Add these workflows to an app that was **not** generated from the template | [adopting-an-existing-repo.md](adopting-an-existing-repo.md) |
| Call a workflow from your app repo, or look up an input, output or secret | [consumer-guide.md](consumer-guide.md) |
| Work out why a cache missed, or what invalidates one | [cache-keys.md](cache-keys.md) |
| Read what a failed (or passing) E2E run left behind | [forensics.md](forensics.md) |
| Choose a runner label, or understand the macOS bill | [runners.md](runners.md) |

## One line each

| Doc | Contents |
| --- | --- |
| [adopting-an-existing-repo.md](adopting-an-existing-repo.md) | What an existing app has to provide, per workflow it calls, and the two ways to satisfy each gate. The table is generated from `packages/dev-config/contract.json` |
| [consumer-guide.md](consumer-guide.md) | Every workflow's inputs, outputs and secrets; the full caller examples; versioning and the `@v0` pin; the `.workflows/` self-checkout |
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
| `packages/dev-config/README.md` | `@blinkbitcoin/dev-config` — the pinned tool table, `check-tool-versions`, and `check-consumer-contract` |
| `scripts/e2e/README.md` | How the E2E scripts fit together on a runner |
| `docs/superpowers/` | The specs and plans this repo was built from. History, not a guide |

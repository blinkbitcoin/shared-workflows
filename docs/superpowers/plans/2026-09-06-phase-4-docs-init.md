# Phase 4: Docs, ADRs, Agent Ergonomics, `make init` Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the template consumable without confusion by experienced developers, juniors and coding agents: complete docs with a "which doc when" index, seven ADRs recording the real decisions (including execution rulings), a canonical `AGENTS.md` (with `CLAUDE.md` as a one-line include) whose command table is kept in sync with the Makefile by `check-docs`, repo hygiene files (`CONTRIBUTING`, `SECURITY`, `LICENSE`, PR/issue templates, `CODEOWNERS`, `dependabot.yml`), a tested, self-deleting `make init` that renames identifiers and can strip the web target cleanly, and a polish pass over the minors parked in Phases 1–3.

**Architecture:** Docs are hand-maintained next to code with drift checks (`check-docs.sh` verifies `AGENTS.md` make targets; typos runs on all Markdown). `init.mjs` is a zero-dependency Node script driven by a declarative touch list (`scripts/init.manifest.json`) so the web-removal list has one source shared with `docs/web-files.txt`. ADRs follow the short MADR-style template.

**Tech Stack:** Markdown, Node 24 (`node:test`, `node:readline`), the existing Makefile/typos/knip gates.

**Spec:** `docs/superpowers/specs/2026-09-06-react-native-template-family-design.md` — Part C "Tree", "Docs outline", "`make init`", "Confusion audit", and the Phase 4 section. Inputs from execution: the parked minors and carry-forwards listed at the end of `docs/superpowers/plans/2026-09-06-phase-1-template-scaffold.md` ("Rulings recorded during execution") and Phase 2/3 rulings (knip default mode, Lingui compiled catalogs, ESLint 9, release-please manifest mode, deep-link launch, `.rnw` ignores, `PLAYWRIGHT_SKIP_EXPORT`, `@v0` pin, no `knip` package script because expo-doctor rejects bin-named scripts).

## Global Constraints

- Repo `/Users/jonas/Dev/blink/react-native-mobile-template`, branch `phase-4-docs` from `main` (after Phase 3 merges). Same commit conventions (scope enum incl. `docs`, `tooling`, `app`; trailer `Claude-Session: https://claude.ai/code/session_01SpyYZEnJaLFih75JB4EQAW`; lowercase subject first word; hooks enabled).
- Every doc statement about a command, file or flag must be verified against the repo at the time of writing (read the file; run the command where cheap). No aspirational docs.
- `make check` (incl. `check-docs`, `spell`) stays green after every task; `pnpm test:scripts` covers `init.mjs`.
- `AGENTS.md` is canonical; `CLAUDE.md` contains exactly `@AGENTS.md`. Command references in `AGENTS.md` use the `` `make <target>` `` form so `check-docs.sh` can verify them.
- `init.mjs`: no npm dependencies; `--dry-run` prints the full touch list and exits 0 without changes; `--yes` with flags (`--name`, `--slug`, `--ios-bundle-id`, `--android-package`, `--scheme`, `--web` / `--no-web`, `--owners`) runs non-interactively; self-deletes (`scripts/init.mjs`, `scripts/init.test.mjs`, `scripts/init.manifest.json`, `docs/template-usage.md`, Makefile `init` target) and commits `chore(app): initialize <slug> from react-native-mobile-template` with hooks enabled; never deletes `minimumReleaseAgeExclude` entries.
- Web removal = every path in `docs/web-files.txt` PLUS the non-file removals: package scripts `web`, `build:web`, `test:e2e:web`; Makefile targets `web`, `build-web`, `e2e-web`; devDependencies `react-dom`, `react-native-web`, `@expo/metro-runtime`, `@playwright/test`; `scripts/e2e/web.sh`; `playwright.config.ts`; `.github/workflows/web.yml`; the `web:` block + `platforms` in `app.config.ts`; the web branch in `metro.config.js`; commitlint scope `web`; the web rows in docs; `knip.json`'s playwright plugin key. After removal `make check`, `make unit`, `pnpm knip` must be green.

---

## File Structure

```
README.md (real)  AGENTS.md  CLAUDE.md  CONTRIBUTING.md  SECURITY.md  LICENSE
.github/{PULL_REQUEST_TEMPLATE.md,CODEOWNERS,dependabot.yml,release.yml}  .github/ISSUE_TEMPLATE/{bug_report.yml,feature_request.yml,config.yml}
docs/README.md  docs/architecture.md  docs/local-dev.md  docs/quality.md  docs/testing.md  docs/native-extensions.md  docs/ota-and-crash-reporting.md  docs/template-usage.md
docs/decisions/{template.md,0001-expo-cng-no-native-dirs.md,0002-biome-plus-minimal-eslint.md,0003-plain-stylesheet-theme.md,0004-lingui-i18n.md,0005-apollo4-client-preset.md,0006-web-opt-in.md,0007-mise-not-nix.md,0008-release-please-and-store-notes.md,0009-e2e-launch-by-deep-link.md}
scripts/init.mjs  scripts/init.test.mjs  scripts/init.manifest.json  scripts/check-docs.sh (extended)
(existing docs kept: docs/ci.md, docs/release-runbook.md, docs/ota.md, docs/web-files.txt)
```

---

### Task 1: Docs index, architecture, local-dev, quality, testing

- [ ] `docs/README.md`: "which doc when" table (task → doc), one line each for every doc incl. Phase 2/3 ones.
- [ ] `docs/architecture.md`: folder map (`src/app` routes-only rule as narrowed: only `_layout.tsx`/`+native-intent.tsx` may import graphql/services/lib; enforced by Biome), data flow (Router → features → Apollo → mock/real API), config/env flow (`app.config.ts` variants, `EXPO_PUBLIC_*` only, zod), providers order (Theme > I18n > ErrorBoundary > Apollo), error handling, storage split (secure vs kv), updates channel model, one mermaid diagram inline.
- [ ] `docs/local-dev.md`: mise + `make doctor`, first run (`make install`, `make mock-api`, `make start`, `make ios`/`android`), dev client + deep-link launch, Android `10.0.2.2`, prebuild debugging (`make prebuild`, never commit `ios/`/`android/`), troubleshooting table (Metro cache, watchman, pod repo, `expo-doctor`, lockfile `minimumReleaseAge` exclusions, the hand-patched lockfile line for `@graphql-typed-document-node/core`), Cursor/VS Code hints.
- [ ] `docs/quality.md`: tool ownership matrix (Biome vs ESLint — lift the overlap table from `eslint.config.mjs`), every gate in `make check` with what it owns and how to run one, how to suppress correctly (Biome ignore comments, `pnpm.auditConfig`, `expo.install.exclude`, `minimumReleaseAgeExclude`), knip default mode rationale, why there is no `knip` package script, commit conventions + scope enum, hooks and escape hatches.
- [ ] `docs/testing.md`: layers table (unit/RNTL/router/Apollo-with-MSW/native mocks/plugins/Maestro/Playwright), coverage rules and the per-path 100% zones, RNTL 14 async render note, `press()` helper, how to add a Maestro flow (register in `flowsOrder`, tags, testIDs list), Playwright + `PLAYWRIGHT_SKIP_EXPORT`, forensics artifact names.
- [ ] Verify every command quoted exists (`make help` diff); `make spell`; commit `docs(docs): index, architecture, local-dev, quality and testing guides`.

### Task 2: Native extensions and OTA/crash docs

- [ ] `docs/native-extensions.md`: when to use a config plugin vs a local Expo Module vs `expo-build-properties`; walkthrough of `modules/hello-native` (Swift/Kotlin, TS wrapper contract incl. the `getBuildStamp` rejection behaviour) and `plugins/with-build-stamp.ts` (+ release signing and ABI plugins), `make check-prebuild` and the prebuild-diff workflow, testing (module mock, plugin mod tests), the capability recipes table from the spec (biometrics, camera/QR, push, share/clipboard/haptics, permissions, web browser/webview, files, screenshot guard).
- [ ] `docs/ota-and-crash-reporting.md`: link to `docs/ota.md` (Phase 3) for the toggle and server; crash-reporting slot: the `CrashReporter` adapter, Sentry recipe (`@sentry/react-native` + config plugin + sourcemap/dSYM upload hooks where Phase 3 keeps sourcemaps), Crashlytics recipe (static frameworks note), what to wire in `_layout.tsx`.
- [ ] Commit `docs(docs): native extensions and crash-reporting guides`.

### Task 3: ADRs

- [ ] `docs/decisions/template.md` (Title, Status, Date, Context, Decision, Consequences, Alternatives) and nine ADRs (0001–0009 as listed in File Structure), each ≤ 40 lines, each citing the file(s) that embody it; 0002 records ESLint 9 + overlap policy; 0004 records compiled catalogs (not the metro transformer); 0008 records release-please manifest mode, build-number scheme, store-notes/LLM; 0009 records the deep-link launch + Bonjour finding.
- [ ] `docs/README.md` links the ADR index; commit `docs(docs): architecture decision records`.

### Task 4: AGENTS.md, CLAUDE.md, CONTRIBUTING, SECURITY, LICENSE, .github hygiene

- [ ] `AGENTS.md` (≤ 180 lines): overview + tree, command table (every row a `` `make x` ``), rules of the road (generated dirs; strings via Lingui; secrets via `lib/secure-store`; env via `config/env`; console via `lib/logger`; native change = module/plugin + docs + prebuild check; routes-only rule; worktree rule; scope enum; never `cp -R generated/. .`), testing map, CI/release pointers, troubleshooting pointers. `CLAUDE.md` = `@AGENTS.md`.
- [ ] `scripts/check-docs.sh`: extend to fail when `AGENTS.md`'s command table lacks a target that the Makefile `##`-documents (both directions), keep the warn-only diff heuristic; node:test-free (bash), shellcheck-clean.
- [ ] `CONTRIBUTING.md` (branching, conventional commits, PR title = squash commit, hooks, `make check` before push, docs-with-code rule), `SECURITY.md` (report channel, supported versions, secrets policy), `LICENSE` (MIT, Blink Bitcoin 2026).
- [ ] `.github/PULL_REQUEST_TEMPLATE.md` (checklist: conventional title, tests, docs, screenshots, native? → `make check-prebuild`), `ISSUE_TEMPLATE/bug_report.yml` + `feature_request.yml` + `config.yml`, `CODEOWNERS` (`* @blinkbitcoin/mobile`; `plugins/ modules/ fastlane/` → `@blinkbitcoin/mobile-native`), `dependabot.yml` (npm weekly grouped minor/patch; `github-actions` weekly; ignores with reasons: `react-native`/`expo*`/`react` majors+minors, `typescript` major (typescript-eslint peer), `eslint` major (expo preset plugins), `jest` major pinned to expo table), `release.yml` (release-please owns notes; this file only categorises PR labels for the GitHub UI).
- [ ] `make check` green (check-docs now strict); commit `docs(docs): agents guide, contributing, security, github templates and dependabot`.

### Task 5: `make init`

- [ ] `scripts/init.manifest.json`: `{ "rename": [files + placeholder tokens], "webFiles": "docs/web-files.txt", "webRemovals": { "packageScripts": [...], "makeTargets": [...], "devDependencies": [...], "files": [...], "commitlintScopes": ["web"], "knipPlugins": ["playwright"] }, "selfDelete": [...] }` — the one source for the Global Constraints' removal list.
- [ ] `scripts/init.mjs`: prompts (name, slug, iOS bundle id, Android package, scheme, include web?, owners team) with validation regexes; `--dry-run`, `--yes` + flags; rewrite functions per file type (JSON via parse/stringify preserving key order; TS/YAML/MD via token replace; Makefile target block removal; `app.config.ts` web block removal by marker comments `// init:web-start`/`// init:web-end` — add those markers in `app.config.ts` and `metro.config.js` in this task); web removal applies the manifest; then `pnpm install` (lockfile updates), `pnpm codegen` + `make i18n` no-op check, `make check-code`, self-delete, `git add -A && git commit` with hooks.
- [ ] `scripts/init.test.mjs` (node:test): pure functions (`rewriteJson`, `removeMakeTargets`, `removeMarkedBlock`, `validate*`) + an integration test that copies the repo tree (excluding node_modules/.git) to a temp dir, symlinks `node_modules`, runs `node scripts/init.mjs --yes --no-web ...` with `INIT_SKIP_INSTALL=1 INIT_SKIP_COMMIT=1`, then asserts no path from the manifest remains, no `--dev`/playwright references remain (`grep`), placeholders replaced.
- [ ] `docs/template-usage.md` (Use this template → `make init` → what changed), Makefile `init` target, `README.md` "Using this template" section.
- [ ] Commit `feat(tooling): make init renames the project and can strip the web target`.

### Task 6: Polish pass (parked minors) and real README

- [ ] Parked minors: `src/components/Providers.tsx` drop unused `apolloUri` or wire it into `renderWithProviders`; `Screen` merges caller `style` (`[styles.body, rest.style]`); Biome exemption for `_layout.tsx`/`+native-intent.tsx` narrowed (keep base `paths` there); `useUpdateInfo` mounted guard; lefthook `post-merge`/`post-checkout` `HEAD@{1}` bug → `scripts/hooks/install-if-lockfile-changed.sh`; `knip.json` stale entries cleaned; `NativeDemoCard` unreachable `'error'` branch removed; podspec `.git` suffix; `metro.config.js` comment placement; typos on all.
- [ ] `README.md`: purpose, badges slots, 60-second start, "Using this template", what's inside (table), docs index link, CI/release one-liners, licence.
- [ ] Commit `fix(app): polish parked review items` + `docs(docs): real README`.

### Task 7: Phase 4 acceptance

- [ ] Fresh clone to `/tmp/rnmt-p4`: `mise trust && mise install && make doctor && make install && make check && make unit && make coverage && make check-prebuild` all exit 0.
- [ ] Init both ways in scratch copies: `--no-web` → `make check`, `make unit`, `pnpm knip` green, `grep -r "react-native-web\|playwright\|build:web" --exclude-dir=node_modules` empty; `--web` → same gates green and `make e2e-web` passes.
- [ ] `check-docs` strict passes; `typos` passes; ADR index complete; `AGENTS.md` command table == Makefile targets.
- [ ] Merge to `main` after review; tag `phase-4-complete`; update the plan file with rulings.

## Self-review notes
- Spec Part C docs outline fully covered (T1–T4), init spec (T5), confusion audit items each mapped to a doc or check (T1/T4), parked minors (T6). Dependencies on Phase 3: links to `docs/release-runbook.md` and `docs/ota.md`, `fastlane/` in CODEOWNERS, `Appfile` env defaults in the init rename list — T5 must read Phase 3's actual files before writing the manifest.

## Rulings recorded during execution (2026-09-07)

- Merged fast-forward to `main` at f527638 (tag `phase-4-complete`); workflows repo main at 63733b3 (tag `phase-4-complete`). All local, no remotes.
- Tasks 1–6 ran in parallel on disjoint file sets in one shared checkout; commits must be made with `git commit -- <paths>` (a plain `git add <paths>` + `git commit` sweeps in other tasks' staged files).
- `docs/README.md` links `docs/decisions/README.md` (ADR index, Task 3) and `docs/template-usage.md` (Task 5); README's "Using this template" block sits between `<!-- init:usage-start/end -->` markers and is stripped by `make init`.
- Generated GraphQL code and compiled Lingui catalogs are tracked (guarded by `make check-gen`); only `ios/` and `android/` are ignored.
- `make init`: plan → validate every anchor/marker/path (exit 2, tree untouched, when stale) → mutate; `--yes` requires `--web` or `--no-web`; `--owners` is the GitHub owner login; `docs/superpowers/**` ships with the template and is excluded from the rename sweep; byte-exact snapshots of the lines `--no-web` removes from docs/testing.md, docs/README.md and AGENTS.md guard against over-deletion; the web strip also removes the release-production web job and the `web` commitlint scope from every doc.
- `scripts/check-docs.sh` is strict in both directions between AGENTS.md's command table and the Makefile's `##` targets; `make help` lists targets with digits.
- `make install` also installs Ruby gems (`NO_BUNDLE=1` skips); `make doctor` checks the gem set; jest `testTimeout` 15 s in both projects.
- The placeholder-cert hash constant had been computed from a CRLF copy, so the "still the template placeholder" warning never fired; fixed with a guard test that recomputes the hash from the committed `.pem` (LF-only asserted).
- lefthook post-merge/post-checkout use `scripts/hooks/install-if-lockfile-changed.sh` (hook args + `ORIG_HEAD`), replacing the broken `HEAD@{1}` form.
- Spec text corrected: `APP_REVIEW_*` (not `APP_REVIEW_CONTACT_*`); ADRs record ESLint 9 and compiled Lingui catalogs where the spec's sketches were stale.

### Deferred minors / follow-ups

- `renderWithProviders` duplicates the provider wrapper instead of parameterising `Providers`.
- `ios_info_plist`'s glob fallback picks silently when the scheme directory has no plist.
- docs/ci.md's workflow counts are manifest-rewritten but not asserted against `.github/workflows/`; nothing enforces prose agreement between docs beyond the strict command table.
- Android `ota-runtime-version` stays a `skip` until a real OTA-on AAB proves the `assets/fingerprint` path.
- Android `mapping.txt` is a permanent verify `skip` until minification is enabled; JS source-map retention for crash reporting is an open decision.
- `RNW_TEMPLATE_DIR` in the workflows repo's parity test defaults to a machine-local path.

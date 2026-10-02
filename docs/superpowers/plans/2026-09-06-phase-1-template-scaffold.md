# Phase 1: Template Scaffold and Quality Tooling Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Produce the `react-native-mobile-template` repo as a runnable Expo SDK 57 app with the full fail-fast quality layer, the app scaffold (router, theme, i18n, GraphQL, config, storage, error handling), one local Expo Module and three config plugins proving the native-extension path, and unit + Maestro + Playwright test scaffolding, all green under `make check` and `make unit`.

**Architecture:** Flat single-package Expo app using prebuild (CNG): `ios/` and `android/` are never committed. Routing lives only in `src/app/`; screens in `src/features/`; horizontal layers (`theme`, `i18n`, `graphql`, `config`, `lib`, `services`) are independently testable. Biome owns formatting and generic lint; ESLint (expo preset) owns React/Expo semantic rules only. A single executable GraphQL schema in `mocks/` serves both the local yoga server (simulators, Maestro) and MSW (Jest, Playwright). Native code enters only through `modules/*` (Expo Modules) and `plugins/*` (config plugins).

**Tech Stack:** Expo SDK 57 (React Native 0.86, React 19.2), TypeScript 6.0, pnpm 12, mise (node 24, ruby 3.3, java temurin-17), Expo Router, Lingui 6, Apollo Client 4 + graphql-codegen client-preset 6, zod 4, expo-secure-store, expo-sqlite/kv-store, expo-updates, react-error-boundary, Biome 2.5, ESLint 10 + eslint-config-expo 57, knip 6, lefthook 2, commitlint 21, typos, jest-expo 57 + RNTL 14, MSW 2, graphql-yoga, Maestro CLI 2.10, Playwright 1.63.

**Spec:** `docs/superpowers/specs/2026-09-06-react-native-template-family-design.md` (this plan implements "Part C" and "Phase 1"; Phases 2 to 4 get their own plans).

## Global Constraints

- Node 24 LTS, pnpm 12.x pinned via `packageManager`; `.mise.toml` is the single source of tool versions (node `24`, ruby `3.3`, java `temurin-17`, `actionlint`, `shellcheck`, `typos`).
- Expo SDK `~57.0.20`, `react-native 0.86.3`, `react 19.2.3` (exact pins from `expo-template-blank-typescript@sdk-57`). TypeScript `~6.0`. Never bump `react-native`, `react`, `expo` or `typescript` majors in this plan.
- No committed `ios/` or `android/` directories. Native settings only via `app.config.ts`, `expo-build-properties`, `plugins/*`, `modules/*`.
- Only `EXPO_PUBLIC_*` environment variables reach JS, and only via static `process.env.EXPO_PUBLIC_X` references.
- Zero overlapping lint rules between Biome and ESLint. Biome: formatting, import sorting, generic + react domain rules. ESLint: `eslint-config-expo/flat` semantic rules with stylistic/import-order rules disabled.
- `console.*` allowed only in `src/lib/logger.ts`. `expo-secure-store` imported only in `src/lib/secure-store.ts`. Files under `src/app/` import only from `src/features/` and `src/components/`.
- Every shell script starts with `#!/usr/bin/env bash` and `set -euo pipefail`, passes shellcheck, and is runnable from the repo root.
- Conventional Commits with scope enum: `app, ui, i18n, graphql, native, plugins, config, tooling, ci, release, deps, deps-dev, docs, e2e, web`. Commit messages end with the line `Claude-Session: https://claude.ai/code/session_01SpyYZEnJaLFih75JB4EQAW`.
- Coverage thresholds: global 80% lines/branches; 100% for `src/config/**`, `src/lib/**`, `modules/*/index.ts`, `plugins/**`.
- Repo root: `/Users/jonas/Dev/blink/react-native-mobile-template` (already `git init`-ed on `main`, contains `docs/superpowers/`). Every `Run:` line below assumes this cwd.
- Web is a target in this phase (removed later by `make init` in Phase 4), so web-only files are created and marked with a `// WEB ONLY` first-line comment where they are TS, or listed in `docs/web-files.txt` otherwise, so Phase 4's init script has an exhaustive list.

---

## File Structure (what Phase 1 creates)

```
.mise.toml .npmrc pnpm-workspace.yaml package.json pnpm-lock.yaml
.gitignore .editorconfig .gitattributes .env.example .env.development .env.production
app.config.ts babel.config.js metro.config.js tsconfig.json
biome.json eslint.config.mjs knip.json lefthook.yml commitlint.config.mjs typos.toml
jest.config.ts codegen.ts lingui.config.ts playwright.config.ts
Makefile
assets/{icon.png,adaptive-icon.png,splash-icon.png,favicon.png}   (from the Expo template)
docs/web-files.txt
mocks/{schema.graphql,resolvers.ts,executable-schema.ts,server.ts,msw.ts}
modules/hello-native/{expo-module.config.json,index.ts,src/HelloNativeModule.ts,src/HelloNative.types.ts,src/__mocks__/HelloNativeModule.ts,__tests__/index.test.ts,ios/HelloNative.podspec,ios/HelloNativeModule.swift,android/build.gradle,android/src/main/java/expo/modules/hellonative/HelloNativeModule.kt}
plugins/{tsconfig.json,with-build-stamp.ts,with-build-stamp.test.ts,with-android-release-signing.ts,with-android-release-signing.test.ts,with-android-release-abis.ts,with-android-release-abis.test.ts}
scripts/{doctor.mjs,doctor.requirements.json,doctor.test.mjs,check-i18n.sh,check-codegen.sh,check-lockfile.sh,check-licenses.mjs,check-bundle-secrets.sh,check-prebuild.sh,shellcheck.sh}
scripts/e2e/{maestro-ios.sh,maestro-android.sh,wait-for-mock-api.sh}
src/app/{_layout.tsx,+not-found.tsx,+native-intent.tsx,+html.tsx}
src/app/(tabs)/{_layout.tsx,index.tsx,settings.tsx}
src/app/details/[id].tsx
src/features/home/{HomeScreen.tsx,HomeScreen.test.tsx,hello.graphql}
src/features/details/{DetailsScreen.tsx,DetailsScreen.test.tsx}
src/features/settings/{SettingsScreen.tsx,SettingsScreen.test.tsx,NativeDemoCard.tsx,NativeDemoCard.web.tsx,DevMenu.tsx}
src/components/{Screen.tsx,AppText.tsx,Button.tsx,Card.tsx,ErrorFallback.tsx,ErrorFallback.test.tsx}
src/theme/{tokens.ts,ThemeProvider.tsx,useTheme.ts,createStyles.ts,theme.test.tsx}
src/i18n/{i18n.ts,I18nProvider.tsx,i18n.test.tsx,locales/en/messages.po,locales/en/messages.ts,locales/es/messages.po,locales/es/messages.ts}
src/graphql/{client.ts,cache.ts,ApolloProvider.tsx,links/auth.ts,links/error.ts,links/links.test.ts,generated/}
src/config/{env.ts,env.test.ts,constants.ts}
src/lib/{logger.ts,logger.test.ts,errors.ts,errors.test.ts,storage.ts,storage.test.ts,secure-store.ts,secure-store.test.ts,crash-reporting.ts,crash-reporting.test.ts}
src/services/{auth.ts,auth.test.ts,updates.ts,updates.test.ts}
src/test/{setup.ts,render.tsx,mocks/expo-secure-store.ts,mocks/expo-sqlite-kv-store.ts,mocks/expo-updates.ts}
src/global.d.ts
.maestro/{config.yaml,flows/00-launch.yaml,flows/home.yaml,flows/details.yaml,flows/settings.yaml,flows/error-screen.yaml,flows/deep-link.yaml}
e2e/web/smoke.spec.ts
```

Responsibilities: `src/app/*` = routing/composition only. `src/features/<x>/` = one screen + its tests + its GraphQL operations. `src/components/` = dumb, theme-aware UI. `mocks/` = the one executable schema and its two servers. `scripts/` = every check the Makefile and CI call. `plugins/` and `modules/` = the only native code.

---

### Task 1: Bootstrap the Expo app with pnpm and mise

**Files:**
- Create: `.mise.toml`, `.npmrc`, `pnpm-workspace.yaml`, `.gitignore`, `package.json` (from template, then edited), `app.json` → replaced by `app.config.ts` in Task 9 (keep `app.json` until then), `tsconfig.json`, `index.ts`, `App.tsx` (template, deleted in Task 6), `assets/*`
- Test: manual `pnpm install` + `pnpm expo config`

**Interfaces:**
- Produces: repo root layout; `pnpm` as the only package manager; `mise` tool versions read by every later task and by CI.

- [ ] **Step 1: Check the toolchain on this machine**

Run: `mise --version && node --version && pnpm --version && xcodebuild -version | head -1`
Expected: mise prints a version. If `mise` is missing: `brew install mise` and add `eval "$(mise activate zsh)"` to `~/.zshrc`, then reopen the shell. Node/pnpm versions are irrelevant yet (mise pins them in Step 2).

- [ ] **Step 2: Write `.mise.toml`**

```toml
# Tool versions for humans and CI (jdx/mise-action reads this file).
# Node/pnpm/java/ruby are what the app, Metro, Gradle and fastlane need;
# the rest are linters used by `make check`.
[tools]
node = "24"
pnpm = "12"
java = "temurin-17"
ruby = "3.3"
actionlint = "1.7.12"
shellcheck = "0.11.0"
typos = "latest"

[env]
# Expo telemetry off everywhere; Android SDK path for `expo run:android`
EXPO_NO_TELEMETRY = "1"
```

Run: `mise trust && mise install && mise exec -- node --version && mise exec -- pnpm --version`
Expected: `v24.x.x` and `12.x.x`.

- [ ] **Step 3: Generate the Expo template into a temp dir and move it in**

Run:
```bash
cd /tmp && rm -rf rnmt-bootstrap && mise exec -- pnpm create expo-app@latest rnmt-bootstrap --template blank-typescript --no-install
cd /Users/jonas/Dev/blink/react-native-mobile-template
cp -R /tmp/rnmt-bootstrap/. . && rm -rf /tmp/rnmt-bootstrap
ls
```
Expected: `App.tsx app.json assets index.ts package.json tsconfig.json .gitignore` appear next to `docs/`. `cat package.json` shows `"expo": "~57.0.x"`, `"react-native": "0.86.x"`. If the template pinned a different SDK, stop and reconcile with the Global Constraints before continuing.

- [ ] **Step 4: Pin the package manager and pnpm settings**

Edit `package.json`: set `"name": "react-native-mobile-template"`, `"private": true`, `"version": "0.0.0"`, add
```json
"packageManager": "pnpm@12.3.4",
"engines": { "node": ">=24" },
"scripts": { "preinstall": "npx only-allow pnpm", "start": "expo start --dev-client", "ios": "expo run:ios", "android": "expo run:android", "web": "expo start --web", "prebuild": "expo prebuild --clean" }
```
(replace the template's `scripts` block; keep its `main`, `dependencies`, `devDependencies`).

Write `.npmrc`:
```ini
engine-strict=true
auto-install-peers=true
```

Write `pnpm-workspace.yaml` (pnpm settings only, this is NOT a workspace):
```yaml
# pnpm 10+ reads settings from here. No `packages:` key on purpose: flat repo.
minimumReleaseAge: 4320   # 3 days in minutes; supply-chain guard
strictDepBuilds: true
onlyBuiltDependencies:
  - '@biomejs/biome'
  - esbuild
  - sharp
```

- [ ] **Step 5: Install and prove Expo resolves**

Run: `mise exec -- pnpm install && mise exec -- pnpm expo config --type public | head -20`
Expected: install completes; `expo config` prints the JSON with `"sdkVersion": "57.0.0"`. If pnpm's isolated `node_modules` makes Metro or Expo fail to resolve packages later (symptom: "Unable to resolve module"), add `nodeLinker: hoisted` to `pnpm-workspace.yaml`, delete `node_modules`, reinstall, and note the change in the commit message.

- [ ] **Step 6: Extend `.gitignore` for CNG and tooling**

Append to `.gitignore`:
```gitignore
# Continuous Native Generation: never commit generated native projects
/ios
/android
# Playwright / Maestro / coverage / build output
/coverage
/dist
/playwright-report
/test-results
/.maestro/output
# env with secrets (the committed .env.development/.env.production carry no secrets)
.env.local
.env.*.local
```

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "chore(app): bootstrap Expo SDK 57 app with pnpm and mise

Claude-Session: https://claude.ai/code/session_01SpyYZEnJaLFih75JB4EQAW"
```

---

### Task 2: Makefile and `doctor` script

**Files:**
- Create: `Makefile`, `scripts/doctor.mjs`, `scripts/doctor.requirements.json`, `scripts/doctor.test.mjs`
- Modify: `package.json` scripts

**Interfaces:**
- Produces: `make help`, `make doctor`, `make install`; `scripts/doctor.mjs` exports `compareVersions(a, b): -1|0|1` and `checkTool({ name, command, minimum, hint })` for tests; later tasks add Makefile targets following the `target: ## description` pattern.

- [ ] **Step 1: Write the failing test for version comparison**

`scripts/doctor.test.mjs`:
```js
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { compareVersions, parseVersion } from './doctor.mjs';

test('parseVersion extracts the first semver-ish token', () => {
  assert.deepEqual(parseVersion('Xcode 26.6\nBuild version 17F45'), [26, 6, 0]);
  assert.deepEqual(parseVersion('v24.13.0'), [24, 13, 0]);
  assert.equal(parseVersion('no version here'), null);
});

test('compareVersions orders numerically', () => {
  assert.equal(compareVersions([26, 6, 0], [26, 4, 0]), 1);
  assert.equal(compareVersions([1, 2, 3], [1, 2, 3]), 0);
  assert.equal(compareVersions([0, 9, 0], [1, 0, 0]), -1);
});
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mise exec -- node --test scripts/doctor.test.mjs`
Expected: FAIL, "Cannot find module './doctor.mjs'".

- [ ] **Step 3: Write `scripts/doctor.requirements.json` and `scripts/doctor.mjs`**

`scripts/doctor.requirements.json`:
```json
{
  "tools": [
    { "name": "node", "command": "node --version", "minimum": "24.0.0", "hint": "mise install" },
    { "name": "pnpm", "command": "pnpm --version", "minimum": "12.0.0", "hint": "mise install" },
    { "name": "java", "command": "java -version 2>&1", "minimum": "17.0.0", "hint": "mise install (temurin-17)" },
    { "name": "ruby", "command": "ruby --version", "minimum": "3.3.0", "hint": "mise install" },
    { "name": "watchman", "command": "watchman --version", "minimum": "2024.0.0", "hint": "brew install watchman" },
    { "name": "xcodebuild", "command": "xcodebuild -version", "minimum": "26.4.0", "hint": "Install Xcode 26.4+ from the App Store, then: sudo xcode-select -s /Applications/Xcode.app", "platform": "darwin" },
    { "name": "pod", "command": "pod --version", "minimum": "1.16.0", "hint": "gem install cocoapods (inside mise's ruby)", "platform": "darwin" },
    { "name": "adb", "command": "adb --version", "minimum": "1.0.41", "hint": "Install Android Studio > SDK Manager > Android SDK Platform-Tools; export ANDROID_HOME=$HOME/Library/Android/sdk and add $ANDROID_HOME/platform-tools to PATH" },
    { "name": "maestro", "command": "maestro --version", "minimum": "2.10.0", "hint": "curl -fsSL https://get.maestro.mobile.dev | bash", "optional": true }
  ],
  "env": [
    { "name": "ANDROID_HOME", "hint": "export ANDROID_HOME=$HOME/Library/Android/sdk" }
  ]
}
```

`scripts/doctor.mjs`:
```js
#!/usr/bin/env node
// Asserts the local toolchain matches scripts/doctor.requirements.json and
// prints a fix hint per failure. Exit 1 if any required tool is missing.
import { execSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

export function parseVersion(output) {
  const m = /(\d+)\.(\d+)(?:\.(\d+))?/.exec(output);
  if (!m) return null;
  return [Number(m[1]), Number(m[2]), Number(m[3] ?? 0)];
}

export function compareVersions(a, b) {
  for (let i = 0; i < 3; i++) {
    if (a[i] > b[i]) return 1;
    if (a[i] < b[i]) return -1;
  }
  return 0;
}

export function checkTool(tool) {
  let output;
  try {
    output = execSync(tool.command, { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] });
  } catch (error) {
    output = error.stdout ?? '';
    if (!output) return { ok: false, reason: 'not found' };
  }
  const found = parseVersion(output);
  if (!found) return { ok: false, reason: `unparseable version output: ${output.trim()}` };
  const minimum = parseVersion(tool.minimum);
  if (compareVersions(found, minimum) < 0) {
    return { ok: false, reason: `found ${found.join('.')}, need >= ${tool.minimum}` };
  }
  return { ok: true, version: found.join('.') };
}

function main() {
  const here = path.dirname(fileURLToPath(import.meta.url));
  const req = JSON.parse(readFileSync(path.join(here, 'doctor.requirements.json'), 'utf8'));
  let failures = 0;
  for (const tool of req.tools) {
    if (tool.platform && tool.platform !== process.platform) continue;
    const result = checkTool(tool);
    if (result.ok) {
      process.stdout.write(`ok    ${tool.name} ${result.version}\n`);
    } else if (tool.optional) {
      process.stdout.write(`warn  ${tool.name}: ${result.reason}. Fix: ${tool.hint}\n`);
    } else {
      failures++;
      process.stdout.write(`FAIL  ${tool.name}: ${result.reason}. Fix: ${tool.hint}\n`);
    }
  }
  for (const v of req.env) {
    if (process.env[v.name]) process.stdout.write(`ok    $${v.name}=${process.env[v.name]}\n`);
    else {
      failures++;
      process.stdout.write(`FAIL  $${v.name} is not set. Fix: ${v.hint}\n`);
    }
  }
  if (failures > 0) {
    process.stdout.write(`\n${failures} problem(s). Fix them and re-run: make doctor\n`);
    process.exit(1);
  }
  process.stdout.write('\nAll good.\n');
}

if (process.argv[1] && fileURLToPath(import.meta.url) === path.resolve(process.argv[1])) main();
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `mise exec -- node --test scripts/doctor.test.mjs`
Expected: 2 tests pass.

- [ ] **Step 5: Write the Makefile**

```makefile
# Human/agent command surface. Thin wrappers over pnpm scripts and scripts/.
# `make` or `make help` lists targets; every target has a `##` description.
.DEFAULT_GOAL := help
SHELL := /bin/bash

# ---------- Setup ----------
doctor: ## Check the local toolchain (run this first)
	node scripts/doctor.mjs

install: ## Install dependencies (frozen lockfile) and git hooks
	pnpm install --frozen-lockfile

# ---------- Run ----------
start: ## Metro for the dev client
	pnpm start

ios: ## Prebuild if needed, build and launch on the iOS simulator
	pnpm ios

android: ## Prebuild if needed, build and launch on an Android emulator
	pnpm android

web: ## Expo web dev server (web target)
	pnpm web

prebuild: ## Regenerate ios/ and android/ locally (debugging plugins only; never commit them)
	pnpm prebuild

# ---------- Quality gates (each is what CI runs) ----------
typecheck: ## tsc --noEmit
	pnpm typecheck

lint: ## Biome lint + ESLint (React/Expo rules)
	pnpm lint

format: ## Format everything with Biome (writes)
	pnpm format

format-check: ## Check formatting without writing
	pnpm format:check

check-code: typecheck lint format-check ## Fast local gate: types + lint + format

clean: ## Remove generated native projects, caches and build output
	rm -rf ios android .expo dist coverage node_modules/.cache

reset: clean ## clean + reinstall
	rm -rf node_modules && pnpm install --frozen-lockfile

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-22s\033[0m %s\n", $$1, $$2}'

.PHONY: doctor install start ios android web prebuild typecheck lint format format-check check-code clean reset help
```

Add to `package.json` scripts: `"doctor": "node scripts/doctor.mjs"`, `"test:scripts": "node --test scripts/*.test.mjs"`.

- [ ] **Step 6: Run doctor and help**

Run: `make help && make doctor; echo "exit=$?"`
Expected: help lists targets; doctor prints `ok`/`FAIL` lines. Fix any FAIL that is your machine's (e.g. `ANDROID_HOME`), the script itself must not error.

- [ ] **Step 7: Commit**

```bash
git add Makefile scripts/doctor.mjs scripts/doctor.requirements.json scripts/doctor.test.mjs package.json
git commit -m "chore(tooling): add Makefile and doctor script

Claude-Session: https://claude.ai/code/session_01SpyYZEnJaLFih75JB4EQAW"
```

---

### Task 3: Biome, ESLint, TypeScript strict

**Files:**
- Create: `biome.json`, `eslint.config.mjs`, `.editorconfig`
- Modify: `tsconfig.json`, `package.json`

**Interfaces:**
- Produces: `pnpm typecheck`, `pnpm lint`, `pnpm lint:fix`, `pnpm format`, `pnpm format:check`; the Biome overrides that later tasks rely on (`noConsole` exemption for `src/lib/logger.ts`, `noRestrictedImports` for `expo-secure-store` and for `src/app/**`).

- [ ] **Step 1: Install**

Run: `mise exec -- pnpm add -D @biomejs/biome@^2.5 eslint@^10 eslint-config-expo@^57 globals && mise exec -- pnpm add -D typescript@~6.0`
Expected: installs without peer errors. If `eslint-config-expo@57` is not published yet, use the latest `eslint-config-expo` tag and note it in the commit.

- [ ] **Step 2: Write `.editorconfig`**

```ini
root = true
[*]
charset = utf-8
end_of_line = lf
indent_style = space
indent_size = 2
insert_final_newline = true
trim_trailing_whitespace = true
[Makefile]
indent_style = tab
[*.{swift,kt,gradle}]
indent_size = 4
```

- [ ] **Step 3: Write `biome.json`**

```json
{
  "$schema": "https://biomejs.dev/schemas/2.5.0/schema.json",
  "vcs": { "enabled": true, "clientKind": "git", "useIgnoreFile": true },
  "files": {
    "includes": ["**", "!**/ios", "!**/android", "!**/.expo", "!**/dist", "!**/coverage", "!**/.rnw", "!src/graphql/generated", "!src/i18n/locales/**/messages.ts", "!**/*.po"]
  },
  "formatter": { "enabled": true, "indentStyle": "space", "indentWidth": 2, "lineWidth": 100, "useEditorconfig": true },
  "javascript": { "formatter": { "quoteStyle": "single", "semicolons": "always", "trailingCommas": "all" } },
  "assist": {
    "enabled": true,
    "actions": { "source": { "organizeImports": "on" } }
  },
  "linter": {
    "enabled": true,
    "domains": { "react": "recommended", "test": "recommended" },
    "rules": {
      "recommended": true,
      "suspicious": { "noConsole": "error" },
      "style": {
        "noRestrictedImports": {
          "level": "error",
          "options": {
            "paths": {
              "expo-secure-store": "Use the typed wrapper in src/lib/secure-store.ts",
              "expo-sqlite/kv-store": "Use src/lib/storage.ts"
            }
          }
        },
        "useImportType": "error",
        "noNonNullAssertion": "error"
      },
      "correctness": { "noUnusedImports": "error", "noUnusedVariables": "error" }
    }
  },
  "overrides": [
    {
      "includes": ["src/lib/logger.ts"],
      "linter": { "rules": { "suspicious": { "noConsole": "off" } } }
    },
    {
      "includes": ["src/lib/secure-store.ts", "src/lib/storage.ts", "src/test/mocks/**"],
      "linter": { "rules": { "style": { "noRestrictedImports": "off" } } }
    },
    {
      "includes": ["src/app/**"],
      "linter": {
        "rules": {
          "style": {
            "noRestrictedImports": {
              "level": "error",
              "options": {
                "paths": {
                  "@/graphql/client": "Route files only compose screens from src/features; data access belongs in features.",
                  "@apollo/client": "Route files only compose screens from src/features."
                }
              }
            }
          }
        }
      }
    },
    {
      "includes": ["scripts/**", "plugins/**", "mocks/**", "*.config.*", "codegen.ts"],
      "linter": { "rules": { "suspicious": { "noConsole": "off" } } }
    }
  ]
}
```

- [ ] **Step 4: Write `eslint.config.mjs`**

```js
// ESLint owns ONLY React/Expo semantic rules (react-hooks incl. React Compiler
// rules, expo env-var rules). Biome owns formatting, import order and generic
// lint. Nothing is enabled in both. See docs/quality.md.
import { defineConfig, globalIgnores } from 'eslint/config';
import expoConfig from 'eslint-config-expo/flat';
import globals from 'globals';

export default defineConfig([
  globalIgnores(['ios/**', 'android/**', '.expo/**', 'dist/**', 'coverage/**', '.rnw/**', 'src/graphql/generated/**', 'src/i18n/locales/**/messages.ts']),
  ...(Array.isArray(expoConfig) ? expoConfig : [expoConfig]),
  {
    rules: {
      // Biome-owned: turn off anything stylistic or ordering-related from the preset
      'import/order': 'off',
      'import/first': 'off',
      'import/no-duplicates': 'off',
      'prettier/prettier': 'off',
    },
  },
  {
    files: ['babel.config.js', 'metro.config.js', 'scripts/**/*.mjs', 'mocks/server.ts'],
    languageOptions: { globals: globals.node },
  },
]);
```

- [ ] **Step 5: Tighten `tsconfig.json`**

```json
{
  "extends": "expo/tsconfig.base",
  "compilerOptions": {
    "strict": true,
    "noUncheckedIndexedAccess": true,
    "exactOptionalPropertyTypes": true,
    "verbatimModuleSyntax": true,
    "noFallthroughCasesInSwitch": true,
    "noImplicitOverride": true,
    "baseUrl": ".",
    "paths": { "@/*": ["src/*"] },
    "types": ["jest", "node"]
  },
  "include": ["**/*.ts", "**/*.tsx", ".expo/types/**/*.ts", "expo-env.d.ts", "src/global.d.ts"],
  "exclude": ["node_modules", "ios", "android", "dist", ".rnw", "plugins/**/*.test.ts"]
}
```
(`plugins/` has its own node-target tsconfig in Task 14; the test exclusion is lifted there.)

- [ ] **Step 6: Add scripts**

In `package.json` scripts:
```json
"typecheck": "tsc --noEmit",
"lint": "biome lint . && eslint . --max-warnings=0",
"lint:fix": "biome check --write . && eslint . --fix",
"format": "biome format --write .",
"format:check": "biome format ."
```

- [ ] **Step 7: Run the gate; fix the template's own files until clean**

Run: `make check-code`
Expected: `typecheck` passes; Biome and ESLint report violations in the template's `App.tsx`/`index.ts` (quotes, imports). Run `pnpm lint:fix && pnpm format`, then `make check-code` again.
Expected: exit 0. If ESLint complains that `@types/node` types are missing for `types: ["node"]`, run `pnpm add -D @types/node @types/jest`.

- [ ] **Step 8: Commit**

```bash
git add biome.json eslint.config.mjs .editorconfig tsconfig.json package.json pnpm-lock.yaml App.tsx index.ts
git commit -m "chore(tooling): Biome + minimal ESLint + strict TypeScript

Claude-Session: https://claude.ai/code/session_01SpyYZEnJaLFih75JB4EQAW"
```

---

### Task 4: knip, typos, commitlint, lefthook, git attributes

**Files:**
- Create: `knip.json`, `typos.toml`, `commitlint.config.mjs`, `lefthook.yml`, `.gitattributes`
- Modify: `package.json`, `Makefile`

**Interfaces:**
- Produces: `pnpm knip`, `pnpm spell`, git hooks (pre-commit, commit-msg, pre-push, post-merge); `make check-code` now includes knip + spell.

- [ ] **Step 1: Install**

Run: `mise exec -- pnpm add -D knip@^6 lefthook@^2 @commitlint/cli@^21 @commitlint/config-conventional@^21`

- [ ] **Step 2: Write `commitlint.config.mjs`**

```js
// Conventional Commits with a closed scope list. PR titles are linted with
// the same config in CI because squash merges take the title as the message.
export default {
  extends: ['@commitlint/config-conventional'],
  rules: {
    'scope-enum': [
      2,
      'always',
      ['app', 'ui', 'i18n', 'graphql', 'native', 'plugins', 'config', 'tooling', 'ci', 'release', 'deps', 'deps-dev', 'docs', 'e2e', 'web'],
    ],
    'body-max-line-length': [0],
    'footer-max-line-length': [0],
  },
};
```

- [ ] **Step 3: Write a failing commitlint check**

Run: `echo "update stuff" | mise exec -- pnpm exec commitlint; echo "exit=$?"`
Expected: exit 1 with "subject may not be empty" / "type may not be empty".
Run: `echo "feat(app): add thing" | mise exec -- pnpm exec commitlint; echo "exit=$?"`
Expected: exit 0.

- [ ] **Step 4: Write `lefthook.yml`**

```yaml
# Git hooks. Installed by `pnpm install` (prepare script). Escape hatches:
# `git commit --no-verify`, `LEFTHOOK=0 git push`.
pre-commit:
  parallel: true
  commands:
    biome:
      glob: '*.{ts,tsx,js,mjs,json,graphql}'
      run: pnpm exec biome check --write --no-errors-on-unmatched {staged_files} && git add {staged_files}
    eslint:
      glob: 'src/**/*.{ts,tsx}'
      run: pnpm exec eslint --max-warnings=0 {staged_files}
    typos:
      run: typos {staged_files}
commit-msg:
  commands:
    commitlint:
      run: pnpm exec commitlint --edit {1}
pre-push:
  commands:
    typecheck:
      run: pnpm typecheck
    knip:
      run: pnpm knip
    unit:
      run: pnpm test -- --changedSince=origin/main --passWithNoTests
post-merge:
  commands:
    install:
      run: git diff --name-only HEAD@{1} HEAD | grep -q pnpm-lock.yaml && pnpm install --frozen-lockfile || true
post-checkout:
  commands:
    install:
      run: git diff --name-only {1} {2} | grep -q pnpm-lock.yaml && pnpm install --frozen-lockfile || true
```

- [ ] **Step 5: Write `knip.json`**

```json
{
  "$schema": "https://unpkg.com/knip@6/schema.json",
  "entry": ["index.ts", "app.config.ts", "src/app/**/*.tsx", "plugins/*.ts", "modules/*/index.ts", "mocks/server.ts", "scripts/*.mjs", "scripts/*.ts"],
  "project": ["src/**/*.{ts,tsx}", "plugins/**/*.ts", "modules/**/*.ts", "mocks/**/*.ts", "scripts/**/*.{mjs,ts}"],
  "ignore": ["src/graphql/generated/**", "src/i18n/locales/**/messages.ts", "modules/**/ios/**", "modules/**/android/**"],
  "ignoreDependencies": ["expo-dev-client", "@expo/metro-runtime", "react-native-web", "react-dom"],
  "ignoreBinaries": ["typos", "maestro", "xcrun", "adb"],
  "jest": { "config": "jest.config.ts" },
  "expo": true,
  "lingui": true,
  "graphql-codegen": true,
  "playwright": true
}
```
(`ignoreDependencies` lists packages Expo loads by convention. If knip's `expo` plugin key is not recognised by the installed version, remove it and re-run; keep whichever of `lingui`/`graphql-codegen`/`playwright` plugin keys knip 6 accepts, checking `pnpm exec knip --help` and the knip plugins list.)

- [ ] **Step 6: Write `typos.toml`**

```toml
[files]
extend-exclude = ["pnpm-lock.yaml", "*.po", "src/i18n/locales/**", "src/graphql/generated/**", "ios/", "android/", "assets/", "*.svg"]

[default.extend-words]
# add false positives here, one per line, e.g. `ba = "ba"`
```

- [ ] **Step 7: Write `.gitattributes`**

```gitattributes
* text=auto eol=lf
*.png binary
*.jpg binary
*.ttf binary
*.p12 binary
*.jks binary
src/graphql/generated/** linguist-generated=true
src/i18n/locales/**/messages.ts linguist-generated=true
pnpm-lock.yaml linguist-generated=true
CHANGELOG.md merge=union
```

- [ ] **Step 8: Wire scripts and Makefile**

`package.json` scripts: `"prepare": "lefthook install"`, `"knip": "knip --strict"`, `"spell": "typos"`.
Makefile: add
```makefile
knip: ## Unused files, exports and dependencies
	pnpm knip

spell: ## Spell-check with typos
	pnpm spell
```
and change `check-code: typecheck lint format-check knip spell`. Add `knip spell` to `.PHONY`.

- [ ] **Step 9: Run hooks install and the gate**

Run: `mise exec -- pnpm install && ls .git/hooks | grep -c lefthook; make check-code`
Expected: lefthook hooks present (count > 0); `make check-code` exits 0. knip may flag `App.tsx`-era leftovers; fix by deleting unused files rather than adding ignores.

- [ ] **Step 10: Commit (this commit exercises the hooks)**

```bash
git add -A
git commit -m "chore(tooling): knip, typos, commitlint and lefthook hooks

Claude-Session: https://claude.ai/code/session_01SpyYZEnJaLFih75JB4EQAW"
```
Expected: pre-commit hooks run (biome/eslint/typos output visible) and the commit lands.

---

### Task 5: Jest + React Native Testing Library baseline

**Files:**
- Create: `jest.config.ts`, `src/test/setup.ts`, `src/test/render.tsx`, `src/components/AppText.tsx`, `src/components/AppText.test.tsx`, `src/global.d.ts`
- Modify: `package.json`, `Makefile`

**Interfaces:**
- Produces: `pnpm test`, `pnpm test:coverage`; `renderWithProviders(ui, options?)` from `src/test/render.tsx` (wraps Theme + I18n + Apollo providers; providers are added in Tasks 7, 8, 11 and the file is updated then); `AppText` component (`{ variant?: 'title' | 'body' | 'caption' } & TextProps`).

- [ ] **Step 1: Install**

Run: `mise exec -- pnpm add -D jest@^30 jest-expo@~57 @testing-library/react-native@^14 @types/jest ts-node`
Expected: OK. (`jest-expo` 57 pins the Jest major it supports; if it wants Jest 29, install that instead.)

- [ ] **Step 2: Write the failing component test**

`src/components/AppText.test.tsx`:
```tsx
import { render, screen } from '@testing-library/react-native';
import { AppText } from './AppText';

test('renders children with the body variant by default', () => {
  render(<AppText>hello</AppText>);
  expect(screen.getByText('hello')).toBeOnTheScreen();
});
```

- [ ] **Step 3: Write `jest.config.ts`, setup, and run to see it fail**

`jest.config.ts`:
```ts
import type { Config } from 'jest';

const config: Config = {
  preset: 'jest-expo',
  setupFilesAfterEnv: ['<rootDir>/src/test/setup.ts'],
  moduleNameMapper: {
    '^@/(.*)$': '<rootDir>/src/$1',
    '^expo-secure-store$': '<rootDir>/src/test/mocks/expo-secure-store.ts',
    '^expo-sqlite/kv-store$': '<rootDir>/src/test/mocks/expo-sqlite-kv-store.ts',
    '^expo-updates$': '<rootDir>/src/test/mocks/expo-updates.ts',
  },
  transformIgnorePatterns: [
    'node_modules/(?!((jest-)?react-native|@react-native(-community)?)|expo(nent)?|@expo(nent)?/.*|@expo-google-fonts/.*|react-navigation|@react-navigation/.*|@sentry/react-native|native-base|react-native-svg|@lingui/.*|msw|@mswjs/.*|until-async)',
  ],
  testPathIgnorePatterns: ['/node_modules/', '/e2e/', '/plugins/', '/scripts/'],
  collectCoverageFrom: ['src/**/*.{ts,tsx}', 'modules/*/index.ts', '!src/**/*.test.*', '!src/test/**', '!src/graphql/generated/**', '!src/i18n/locales/**', '!src/app/**'],
  coverageThreshold: {
    global: { lines: 80, branches: 80 },
    'src/config/**': { lines: 100, branches: 100 },
    'src/lib/**': { lines: 100, branches: 100 },
    'modules/*/index.ts': { lines: 100, branches: 100 },
  },
};

export default config;
```

`src/test/setup.ts`:
```ts
import '@testing-library/react-native/extend-expect';
```

`src/global.d.ts`:
```ts
declare module '*.png' {
  const value: number;
  export default value;
}
```

Add scripts: `"test": "jest"`, `"test:coverage": "jest --coverage"`, `"test:watch": "jest --watch"`.

Run: `mise exec -- pnpm test`
Expected: FAIL, cannot find `./AppText`. (The three mock files under `src/test/mocks` do not exist yet; Jest only resolves mappers on import, so this is fine until Task 10 and 12 create them.)

- [ ] **Step 4: Implement `AppText`**

```tsx
import { Text, type TextProps } from 'react-native';

type Variant = 'title' | 'body' | 'caption';

const sizes: Record<Variant, number> = { title: 24, body: 16, caption: 12 };

export function AppText({ variant = 'body', style, ...props }: TextProps & { variant?: Variant }) {
  return <Text {...props} style={[{ fontSize: sizes[variant] }, style]} />;
}
```
(Theme colours are wired into this component in Task 7.)

- [ ] **Step 5: Run tests**

Run: `mise exec -- pnpm test`
Expected: 1 passed.

- [ ] **Step 6: `renderWithProviders` scaffold and Makefile**

`src/test/render.tsx`:
```tsx
import { render, type RenderOptions } from '@testing-library/react-native';
import type { PropsWithChildren, ReactElement } from 'react';

// Providers are appended here as the layers land (theme, i18n, apollo).
function Providers({ children }: PropsWithChildren) {
  return <>{children}</>;
}

export function renderWithProviders(ui: ReactElement, options?: RenderOptions) {
  return render(ui, { wrapper: Providers, ...options });
}

export * from '@testing-library/react-native';
```

Makefile additions:
```makefile
unit: ## Unit + component tests
	pnpm test

coverage: ## Tests with coverage thresholds (what CI enforces)
	pnpm test:coverage

test: unit check-code ## Unit tests + code checks
```
Add to `.PHONY`.

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "test(app): jest-expo + RNTL baseline with coverage thresholds

Claude-Session: https://claude.ai/code/session_01SpyYZEnJaLFih75JB4EQAW"
```

---

### Task 6: Expo Router skeleton (stack + tabs + details route)

**Files:**
- Create: `src/app/_layout.tsx`, `src/app/+not-found.tsx`, `src/app/(tabs)/_layout.tsx`, `src/app/(tabs)/index.tsx`, `src/app/(tabs)/settings.tsx`, `src/app/details/[id].tsx`, `src/features/home/HomeScreen.tsx`, `src/features/home/HomeScreen.test.tsx`, `src/features/details/DetailsScreen.tsx`, `src/features/details/DetailsScreen.test.tsx`, `src/features/settings/SettingsScreen.tsx`, `src/components/Screen.tsx`, `src/components/Button.tsx`, `src/app/+html.tsx`, `docs/web-files.txt`
- Delete: `App.tsx`
- Modify: `index.ts`, `package.json` (`main`), `app.json`

**Interfaces:**
- Produces: routes `/` (home tab), `/settings` (settings tab), `/details/[id]`; `HomeScreen`, `DetailsScreen({ id: string })`, `SettingsScreen`; `Screen` (safe-area wrapper with `testID`), `Button({ title, onPress, testID })`.

- [ ] **Step 1: Install router deps**

Run: `mise exec -- pnpm expo install expo-router react-native-safe-area-context react-native-screens expo-linking expo-constants expo-status-bar react-native-gesture-handler react-native-reanimated expo-dev-client`
Then: `mise exec -- pnpm add -D expo-router@~57` is unnecessary (expo install pins it). Set `"main": "expo-router/entry"` in `package.json` and delete `index.ts` and `App.tsx`.

Edit `app.json` `expo` block: add `"scheme": "rnmt"`, `"plugins": ["expo-router"]`, `"experiments": { "typedRoutes": true }`, `"newArchEnabled": true`, and `"web": { "bundler": "metro", "output": "static" }`.

- [ ] **Step 2: Write the failing router tests**

`src/features/home/HomeScreen.test.tsx`:
```tsx
import { renderRouter, screen } from 'expo-router/testing-library';
import { HomeScreen } from './HomeScreen';

test('home screen shows the title and links to details', () => {
  renderRouter({ index: HomeScreen, 'details/[id]': () => null }, { initialUrl: '/' });
  expect(screen.getByTestId('home-title')).toBeOnTheScreen();
  expect(screen.getByTestId('home-open-details')).toBeOnTheScreen();
});
```

`src/features/details/DetailsScreen.test.tsx`:
```tsx
import { renderRouter, screen } from 'expo-router/testing-library';
import DetailsRoute from '@/app/details/[id]';

test('details route reads the id param', () => {
  renderRouter({ 'details/[id]': DetailsRoute }, { initialUrl: '/details/42' });
  expect(screen.getByTestId('details-id')).toHaveTextContent('42');
});
```

Run: `mise exec -- pnpm test`
Expected: FAIL (modules not found).

- [ ] **Step 3: Components**

`src/components/Screen.tsx`:
```tsx
import type { PropsWithChildren } from 'react';
import { ScrollView, StyleSheet, View, type ViewProps } from 'react-native';
import { SafeAreaView } from 'react-native-safe-area-context';

export function Screen({ children, testID, scroll = false }: PropsWithChildren<{ testID: string; scroll?: boolean }> & ViewProps) {
  const Body = scroll ? ScrollView : View;
  return (
    <SafeAreaView style={styles.safe} testID={testID}>
      <Body style={styles.body} contentContainerStyle={scroll ? styles.body : undefined}>
        {children}
      </Body>
    </SafeAreaView>
  );
}

const styles = StyleSheet.create({
  safe: { flex: 1 },
  body: { flex: 1, padding: 16, gap: 12 },
});
```

`src/components/Button.tsx`:
```tsx
import { Pressable, StyleSheet } from 'react-native';
import { AppText } from './AppText';

export function Button({ title, onPress, testID }: { title: string; onPress: () => void; testID: string }) {
  return (
    <Pressable accessibilityRole="button" onPress={onPress} testID={testID} style={({ pressed }) => [styles.base, pressed && styles.pressed]}>
      <AppText>{title}</AppText>
    </Pressable>
  );
}

const styles = StyleSheet.create({
  base: { paddingVertical: 12, paddingHorizontal: 16, borderRadius: 8, borderWidth: 1, alignItems: 'center' },
  pressed: { opacity: 0.6 },
});
```

- [ ] **Step 4: Screens**

`src/features/home/HomeScreen.tsx`:
```tsx
import { router } from 'expo-router';
import { AppText } from '@/components/AppText';
import { Button } from '@/components/Button';
import { Screen } from '@/components/Screen';

export function HomeScreen() {
  return (
    <Screen testID="home-screen">
      <AppText variant="title" testID="home-title">
        Home
      </AppText>
      <Button title="Open details" testID="home-open-details" onPress={() => router.push('/details/42')} />
    </Screen>
  );
}
```

`src/features/details/DetailsScreen.tsx`:
```tsx
import { AppText } from '@/components/AppText';
import { Screen } from '@/components/Screen';

export function DetailsScreen({ id }: { id: string }) {
  return (
    <Screen testID="details-screen">
      <AppText variant="title">Details</AppText>
      <AppText testID="details-id">{id}</AppText>
    </Screen>
  );
}
```

`src/features/settings/SettingsScreen.tsx`:
```tsx
import { AppText } from '@/components/AppText';
import { Screen } from '@/components/Screen';

export function SettingsScreen() {
  return (
    <Screen testID="settings-screen" scroll>
      <AppText variant="title" testID="settings-title">
        Settings
      </AppText>
    </Screen>
  );
}
```

- [ ] **Step 5: Routes**

`src/app/_layout.tsx`:
```tsx
import { Stack } from 'expo-router';
import { StatusBar } from 'expo-status-bar';

export default function RootLayout() {
  return (
    <>
      <StatusBar style="auto" />
      <Stack>
        <Stack.Screen name="(tabs)" options={{ headerShown: false }} />
        <Stack.Screen name="details/[id]" options={{ title: 'Details' }} />
      </Stack>
    </>
  );
}
```

`src/app/(tabs)/_layout.tsx`:
```tsx
import { Tabs } from 'expo-router';

export default function TabsLayout() {
  return (
    <Tabs>
      <Tabs.Screen name="index" options={{ title: 'Home', tabBarTestID: 'tab-home' }} />
      <Tabs.Screen name="settings" options={{ title: 'Settings', tabBarTestID: 'tab-settings' }} />
    </Tabs>
  );
}
```
(If `tabBarTestID` is not in the current Tabs options type, use `tabBarButtonTestID`; check `pnpm typecheck`.)

`src/app/(tabs)/index.tsx`:
```tsx
import { HomeScreen } from '@/features/home/HomeScreen';
export default HomeScreen;
```

`src/app/(tabs)/settings.tsx`:
```tsx
import { SettingsScreen } from '@/features/settings/SettingsScreen';
export default SettingsScreen;
```

`src/app/details/[id].tsx`:
```tsx
import { useLocalSearchParams } from 'expo-router';
import { DetailsScreen } from '@/features/details/DetailsScreen';

export default function DetailsRoute() {
  const { id } = useLocalSearchParams<{ id: string }>();
  return <DetailsScreen id={id ?? ''} />;
}
```

`src/app/+not-found.tsx`:
```tsx
import { Link } from 'expo-router';
import { AppText } from '@/components/AppText';
import { Screen } from '@/components/Screen';

export default function NotFound() {
  return (
    <Screen testID="not-found-screen">
      <AppText variant="title">Not found</AppText>
      <Link href="/">
        <AppText>Go home</AppText>
      </Link>
    </Screen>
  );
}
```

`src/app/+html.tsx` (first line comment `// WEB ONLY`):
```tsx
// WEB ONLY
import { ScrollViewStyleReset } from 'expo-router/html';
import type { PropsWithChildren } from 'react';

export default function Root({ children }: PropsWithChildren) {
  return (
    <html lang="en">
      <head>
        <meta charSet="utf-8" />
        <meta httpEquiv="X-UA-Compatible" content="IE=edge" />
        <meta name="viewport" content="width=device-width, initial-scale=1, shrink-to-fit=no" />
        <ScrollViewStyleReset />
      </head>
      <body>{children}</body>
    </html>
  );
}
```

`docs/web-files.txt`:
```
src/app/+html.tsx
```

Expo Router must know routes live in `src/app`: with SDK 50+ it auto-detects `src/app`. Confirm with `pnpm expo config --type public | grep -i root` if in doubt.

- [ ] **Step 6: Run tests and typecheck**

Run: `mise exec -- pnpm test && make check-code`
Expected: 3 passed; gate green. Common fixes: `expo-router/testing-library` requires `EXPO_ROUTER_APP_ROOT` in tests — jest-expo sets it when `main` is `expo-router/entry`; if tests cannot find routes, add `process.env.EXPO_ROUTER_APP_ROOT = '../../src/app'` at the top of `src/test/setup.ts`.

- [ ] **Step 7: Smoke on the simulator**

Run: `make ios` (first run does prebuild + Xcode build, ~10 min).
Expected: app launches with Home/Settings tabs; "Open details" navigates. Then `git status` must show no `ios/` (ignored).

- [ ] **Step 8: Commit**

```bash
git add -A
git commit -m "feat(app): Expo Router skeleton with tabs and details route

Claude-Session: https://claude.ai/code/session_01SpyYZEnJaLFih75JB4EQAW"
```

---

### Task 7: Theme tokens, ThemeProvider, createStyles

**Files:**
- Create: `src/theme/tokens.ts`, `src/theme/ThemeProvider.tsx`, `src/theme/useTheme.ts`, `src/theme/createStyles.ts`, `src/theme/theme.test.tsx`
- Modify: `src/components/AppText.tsx`, `src/components/Button.tsx`, `src/components/Screen.tsx`, `src/app/_layout.tsx`, `src/test/render.tsx`

**Interfaces:**
- Produces: `type Theme = { scheme: 'light'|'dark'; colors: {...}; spacing; radii; typography }`, `ThemeProvider({ children, preference? })`, `useTheme(): Theme`, `useThemePreference(): { preference: 'system'|'light'|'dark'; setPreference }`, `createStyles(factory)` returning a `useStyles()` hook.

- [ ] **Step 1: Failing tests**

`src/theme/theme.test.tsx`:
```tsx
import { act, renderHook } from '@testing-library/react-native';
import type { PropsWithChildren } from 'react';
import { ThemeProvider } from './ThemeProvider';
import { createStyles } from './createStyles';
import { useTheme, useThemePreference } from './useTheme';

const wrapper = ({ children }: PropsWithChildren) => <ThemeProvider>{children}</ThemeProvider>;

test('defaults to the system scheme (light in jest) and can be forced to dark', () => {
  const { result } = renderHook(() => ({ theme: useTheme(), pref: useThemePreference() }), { wrapper });
  expect(result.current.theme.scheme).toBe('light');
  act(() => result.current.pref.setPreference('dark'));
  expect(result.current.theme.scheme).toBe('dark');
  expect(result.current.theme.colors.background).not.toBe('#ffffff');
});

test('createStyles produces a hook bound to the current theme', () => {
  const useStyles = createStyles((t) => ({ box: { backgroundColor: t.colors.background } }));
  const { result } = renderHook(() => useStyles(), { wrapper });
  expect(result.current.box.backgroundColor).toBe('#ffffff');
});
```

Run: `mise exec -- pnpm test src/theme`
Expected: FAIL.

- [ ] **Step 2: Implement**

`src/theme/tokens.ts`:
```ts
export const palette = {
  white: '#ffffff',
  black: '#0b0b0f',
  gray100: '#f3f4f6',
  gray700: '#374151',
  gray900: '#111827',
  blue600: '#2563eb',
  red600: '#dc2626',
} as const;

export const spacing = { xs: 4, sm: 8, md: 16, lg: 24, xl: 32 } as const;
export const radii = { sm: 4, md: 8, lg: 16 } as const;
export const typography = { title: 24, body: 16, caption: 12 } as const;

export type Scheme = 'light' | 'dark';

export const colorsByScheme = {
  light: { background: palette.white, surface: palette.gray100, text: palette.gray900, muted: palette.gray700, primary: palette.blue600, danger: palette.red600, border: palette.gray700 },
  dark: { background: palette.black, surface: palette.gray900, text: palette.white, muted: palette.gray100, primary: palette.blue600, danger: palette.red600, border: palette.gray100 },
} as const;

export type Theme = { scheme: Scheme; colors: (typeof colorsByScheme)[Scheme]; spacing: typeof spacing; radii: typeof radii; typography: typeof typography };

export function buildTheme(scheme: Scheme): Theme {
  return { scheme, colors: colorsByScheme[scheme], spacing, radii, typography };
}
```

`src/theme/ThemeProvider.tsx`:
```tsx
import { createContext, type PropsWithChildren, useMemo, useState } from 'react';
import { useColorScheme } from 'react-native';
import { buildTheme, type Scheme, type Theme } from './tokens';

export type ThemePreference = 'system' | Scheme;

export const ThemeContext = createContext<Theme>(buildTheme('light'));
export const ThemePreferenceContext = createContext<{ preference: ThemePreference; setPreference: (p: ThemePreference) => void }>({ preference: 'system', setPreference: () => {} });

export function ThemeProvider({ children, preference: initial = 'system' }: PropsWithChildren<{ preference?: ThemePreference }>) {
  const system = useColorScheme();
  const [preference, setPreference] = useState<ThemePreference>(initial);
  const scheme: Scheme = preference === 'system' ? (system === 'dark' ? 'dark' : 'light') : preference;
  const theme = useMemo(() => buildTheme(scheme), [scheme]);
  const prefValue = useMemo(() => ({ preference, setPreference }), [preference]);
  return (
    <ThemePreferenceContext.Provider value={prefValue}>
      <ThemeContext.Provider value={theme}>{children}</ThemeContext.Provider>
    </ThemePreferenceContext.Provider>
  );
}
```

`src/theme/useTheme.ts`:
```ts
import { useContext } from 'react';
import { ThemeContext, ThemePreferenceContext } from './ThemeProvider';

export function useTheme() {
  return useContext(ThemeContext);
}
export function useThemePreference() {
  return useContext(ThemePreferenceContext);
}
```

`src/theme/createStyles.ts`:
```ts
import { useMemo } from 'react';
import { StyleSheet } from 'react-native';
import type { Theme } from './tokens';
import { useTheme } from './useTheme';

export function createStyles<T extends StyleSheet.NamedStyles<T>>(factory: (theme: Theme) => T) {
  return function useStyles(): T {
    const theme = useTheme();
    return useMemo(() => StyleSheet.create(factory(theme)), [theme]);
  };
}
```

Update `AppText` to use `useTheme().colors.text` and `typography`, `Button` to use `colors.border`/`colors.text`, `Screen` to set `backgroundColor: colors.background`. Wrap the `Stack` in `src/app/_layout.tsx` with `<ThemeProvider>`. Add `ThemeProvider` to `src/test/render.tsx`'s `Providers`.

- [ ] **Step 3: Run tests**

Run: `mise exec -- pnpm test && make check-code`
Expected: all green.

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "feat(ui): theme tokens, ThemeProvider and createStyles

Claude-Session: https://claude.ai/code/session_01SpyYZEnJaLFih75JB4EQAW"
```

---

### Task 8: Lingui i18n (compiled catalogs)

**Files:**
- Create: `lingui.config.ts`, `babel.config.js`, `src/i18n/i18n.ts`, `src/i18n/I18nProvider.tsx`, `src/i18n/i18n.test.tsx`, `src/i18n/locales/{en,es}/messages.po`, `src/i18n/locales/{en,es}/messages.ts` (generated), `scripts/check-i18n.sh`
- Modify: `src/features/home/HomeScreen.tsx`, `src/features/settings/SettingsScreen.tsx`, `src/app/_layout.tsx`, `src/test/render.tsx`, `package.json`, `Makefile`

**Interfaces:**
- Produces: `I18nProvider`, `activateLocale(locale: 'en'|'es')`, `useLocale(): { locale; setLocale }`; the `Trans`/`t` macros from `@lingui/react/macro` and `@lingui/core/macro` used in screens; `pnpm i18n:extract`, `pnpm i18n:check`.

- [ ] **Step 1: Install and configure**

Run: `mise exec -- pnpm add @lingui/core@^6 @lingui/react@^6 && mise exec -- pnpm add -D @lingui/cli@^6 @lingui/babel-plugin-lingui-macro@^6 && mise exec -- pnpm expo install expo-localization`

`lingui.config.ts`:
```ts
import { defineConfig } from '@lingui/cli';

export default defineConfig({
  sourceLocale: 'en',
  locales: ['en', 'es'],
  catalogs: [{ path: '<rootDir>/src/i18n/locales/{locale}/messages', include: ['<rootDir>/src'] }],
  format: 'po',
  compileNamespace: 'ts',
});
```

`babel.config.js`:
```js
module.exports = (api) => {
  api.cache(true);
  return {
    presets: ['babel-preset-expo'],
    plugins: ['@lingui/babel-plugin-lingui-macro'],
  };
};
```

- [ ] **Step 2: Failing test**

`src/i18n/i18n.test.tsx`:
```tsx
import { Trans } from '@lingui/react/macro';
import { act, screen } from '@testing-library/react-native';
import { Text } from 'react-native';
import { renderWithProviders } from '@/test/render';
import { activateLocale } from './i18n';

test('switching locale re-renders translated text', () => {
  renderWithProviders(
    <Text>
      <Trans>Home</Trans>
    </Text>,
  );
  expect(screen.getByText('Home')).toBeOnTheScreen();
  act(() => activateLocale('es'));
  expect(screen.getByText('Inicio')).toBeOnTheScreen();
});
```

Run: `mise exec -- pnpm test src/i18n`
Expected: FAIL.

- [ ] **Step 3: Implement**

`src/i18n/i18n.ts`:
```ts
import { i18n } from '@lingui/core';
import { getLocales } from 'expo-localization';
import { messages as en } from './locales/en/messages';
import { messages as es } from './locales/es/messages';

export const locales = ['en', 'es'] as const;
export type Locale = (typeof locales)[number];

i18n.load({ en, es });

export function detectLocale(): Locale {
  const code = getLocales()[0]?.languageCode ?? 'en';
  return (locales as readonly string[]).includes(code) ? (code as Locale) : 'en';
}

export function activateLocale(locale: Locale) {
  i18n.activate(locale);
}

activateLocale(detectLocale());

export { i18n };
```

`src/i18n/I18nProvider.tsx`:
```tsx
import { I18nProvider as LinguiProvider, type TransRenderProps } from '@lingui/react';
import type { PropsWithChildren } from 'react';
import { Text } from 'react-native';
import { i18n } from './i18n';

function DefaultComponent(props: TransRenderProps) {
  return <Text>{props.children}</Text>;
}

export function I18nProvider({ children }: PropsWithChildren) {
  return (
    <LinguiProvider i18n={i18n} defaultComponent={DefaultComponent}>
      {children}
    </LinguiProvider>
  );
}
```

Replace the literal `Home`, `Details`, `Settings`, `Open details`, `Not found`, `Go home` strings in screens with `<Trans>…</Trans>` (inside `AppText`) or `t\`…\`` from `@lingui/core/macro` for props like `title`. Wrap `_layout.tsx` and `src/test/render.tsx` Providers with `<I18nProvider>`.

Run: `mise exec -- pnpm exec lingui extract && mise exec -- pnpm exec lingui compile`
Then edit `src/i18n/locales/es/messages.po`: set `msgstr "Inicio"` for `msgid "Home"`, `"Detalles"` for `"Details"`, `"Ajustes"` for `"Settings"`, `"Abrir detalles"` for `"Open details"`, `"No encontrado"`, `"Ir al inicio"`. Run `lingui compile` again.

- [ ] **Step 4: Tests and drift script**

Run: `mise exec -- pnpm test && make check-code`
Expected: green. If Jest fails to parse the macro, confirm `babel.config.js` is picked up (jest-expo uses babel-jest) and that `@lingui/react/macro` resolves; if `messages.ts` triggers Biome, it is excluded by `biome.json` `files.includes`.

`scripts/check-i18n.sh`:
```bash
#!/usr/bin/env bash
# Fails when message catalogs are stale relative to source (what CI runs).
set -euo pipefail
cd "$(dirname "$0")/.."
pnpm exec lingui extract --clean >/dev/null
pnpm exec lingui compile >/dev/null
if ! git diff --exit-code --quiet -- src/i18n/locales; then
  echo "i18n catalogs are out of date. Run: make i18n" >&2
  git --no-pager diff --stat -- src/i18n/locales >&2
  exit 1
fi
echo "i18n catalogs are current"
```

`package.json`: `"i18n:extract": "lingui extract --clean && lingui compile"`, `"i18n:check": "bash scripts/check-i18n.sh"`. Makefile: `i18n: ## Extract + compile message catalogs` → `pnpm i18n:extract`; `check-gen: ## Generated-file drift (i18n, codegen)` → `pnpm i18n:check` (codegen added in Task 11).

Run: `chmod +x scripts/*.sh && make check-gen`
Expected: "i18n catalogs are current".

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat(i18n): Lingui with compiled en/es catalogs and drift check

Claude-Session: https://claude.ai/code/session_01SpyYZEnJaLFih75JB4EQAW"
```

---

### Task 9: `app.config.ts`, env validation, constants

**Files:**
- Create: `app.config.ts`, `.env.example`, `.env.development`, `.env.production`, `src/config/env.ts`, `src/config/env.test.ts`, `src/config/constants.ts`
- Delete: `app.json`
- Modify: `jest.config.ts` (env for tests), `package.json`

**Interfaces:**
- Produces: `env` object `{ API_URL: string; APP_NAME: string; WEB_DOMAIN?: string; ALLOW_INSECURE_WEB_STORAGE: boolean }` from `src/config/env.ts`; `parseEnv(raw)` for tests; `constants` `{ version, buildNumber, variant, otaEnabled, updatesChannel }` from `src/config/constants.ts`; `app.config.ts` reading `APP_VARIANT`, `APP_VERSION`, `APP_BUILD_NUMBER`, `OTA_ENABLED`, `EXPO_UPDATES_URL`, `IOS_BUNDLE_ID`, `ANDROID_PACKAGE`.

- [ ] **Step 1: Install zod and env test**

Run: `mise exec -- pnpm add zod@^4`

`src/config/env.test.ts`:
```ts
import { parseEnv } from './env';

test('accepts a valid public env', () => {
  const env = parseEnv({ EXPO_PUBLIC_API_URL: 'http://localhost:4000/graphql', EXPO_PUBLIC_APP_NAME: 'X', EXPO_PUBLIC_ALLOW_INSECURE_WEB_STORAGE: 'false' });
  expect(env.API_URL).toBe('http://localhost:4000/graphql');
  expect(env.ALLOW_INSECURE_WEB_STORAGE).toBe(false);
});

test('rejects a missing API url with a readable message', () => {
  expect(() => parseEnv({ EXPO_PUBLIC_APP_NAME: 'X' })).toThrow(/EXPO_PUBLIC_API_URL/);
});

test('rewrites localhost for the Android emulator in development', () => {
  const env = parseEnv({ EXPO_PUBLIC_API_URL: 'http://localhost:4000/graphql', EXPO_PUBLIC_APP_NAME: 'X' }, { platform: 'android', dev: true });
  expect(env.API_URL).toBe('http://10.0.2.2:4000/graphql');
});
```

Run: `mise exec -- pnpm test src/config`
Expected: FAIL.

- [ ] **Step 2: Implement `env.ts`**

```ts
import { z } from 'zod';

const schema = z.object({
  EXPO_PUBLIC_API_URL: z.string().url(),
  EXPO_PUBLIC_APP_NAME: z.string().min(1),
  EXPO_PUBLIC_WEB_DOMAIN: z.string().optional(),
  EXPO_PUBLIC_ALLOW_INSECURE_WEB_STORAGE: z.enum(['true', 'false']).default('false'),
});

type Raw = Partial<Record<keyof z.infer<typeof schema>, string | undefined>>;

export function parseEnv(raw: Raw, ctx: { platform?: string; dev?: boolean } = {}) {
  const result = schema.safeParse(raw);
  if (!result.success) {
    const lines = result.error.issues.map((i) => `  ${i.path.join('.')}: ${i.message}`);
    throw new Error(`Invalid environment. Check .env.development / .env.production:\n${lines.join('\n')}`);
  }
  const v = result.data;
  let apiUrl = v.EXPO_PUBLIC_API_URL;
  if (ctx.dev && ctx.platform === 'android') apiUrl = apiUrl.replace('://localhost', '://10.0.2.2');
  return Object.freeze({
    API_URL: apiUrl,
    APP_NAME: v.EXPO_PUBLIC_APP_NAME,
    WEB_DOMAIN: v.EXPO_PUBLIC_WEB_DOMAIN,
    ALLOW_INSECURE_WEB_STORAGE: v.EXPO_PUBLIC_ALLOW_INSECURE_WEB_STORAGE === 'true',
  });
}

// Static property access is REQUIRED for Expo to inline EXPO_PUBLIC_* at build time.
export const env = parseEnv(
  {
    EXPO_PUBLIC_API_URL: process.env.EXPO_PUBLIC_API_URL,
    EXPO_PUBLIC_APP_NAME: process.env.EXPO_PUBLIC_APP_NAME,
    EXPO_PUBLIC_WEB_DOMAIN: process.env.EXPO_PUBLIC_WEB_DOMAIN,
    EXPO_PUBLIC_ALLOW_INSECURE_WEB_STORAGE: process.env.EXPO_PUBLIC_ALLOW_INSECURE_WEB_STORAGE,
  },
  { platform: require('react-native').Platform.OS, dev: __DEV__ },
);
```
(If Biome's `useImportType`/require rule complains about the inline `require`, import `Platform` at the top instead and pass `Platform.OS`.)

- [ ] **Step 3: Env files**

`.env.example`:
```dotenv
# Public (inlined into the JS bundle, visible to users). Only EXPO_PUBLIC_* reach app code.
EXPO_PUBLIC_API_URL=http://localhost:4000/graphql
EXPO_PUBLIC_APP_NAME=RN Mobile Template
EXPO_PUBLIC_WEB_DOMAIN=
EXPO_PUBLIC_ALLOW_INSECURE_WEB_STORAGE=false

# Build-time only (read by app.config.ts and CI; NEVER prefixed EXPO_PUBLIC_):
# APP_VARIANT=development|production   OTA_ENABLED=false   EXPO_UPDATES_URL=
# APP_VERSION / APP_BUILD_NUMBER are set by CI.
```
`.env.development`: same public values with `EXPO_PUBLIC_APP_NAME=RN Mobile Template (dev)`. `.env.production`: `EXPO_PUBLIC_API_URL=https://api.example.com/graphql`, `EXPO_PUBLIC_APP_NAME=RN Mobile Template`, others empty/false. No secrets in any of them.

Add to `jest.config.ts` a `setupFiles: ['<rootDir>/src/test/env.ts']` where `src/test/env.ts` sets `process.env.EXPO_PUBLIC_API_URL = 'http://localhost:4000/graphql'; process.env.EXPO_PUBLIC_APP_NAME = 'Test';`.

- [ ] **Step 4: `app.config.ts` and constants**

`app.config.ts`:
```ts
import type { ConfigContext, ExpoConfig } from 'expo/config';

const variant = process.env.APP_VARIANT === 'production' ? 'production' : 'development';
const isDev = variant === 'development';
const iosBundleId = process.env.IOS_BUNDLE_ID ?? 'com.example.rnmt';
const androidPackage = process.env.ANDROID_PACKAGE ?? 'com.example.rnmt';
const otaEnabled = process.env.OTA_ENABLED === 'true';
const buildStamp = `${variant}-${process.env.GITHUB_SHA?.slice(0, 7) ?? 'local'}-${new Date().toISOString().slice(0, 10)}`;

export default ({ config }: ConfigContext): ExpoConfig => ({
  ...config,
  name: isDev ? 'RN Mobile Template (dev)' : 'RN Mobile Template',
  slug: 'react-native-mobile-template',
  scheme: 'rnmt',
  version: process.env.APP_VERSION ?? '0.0.0',
  orientation: 'portrait',
  userInterfaceStyle: 'automatic',
  newArchEnabled: true,
  icon: './assets/icon.png',
  splash: { image: './assets/splash-icon.png', resizeMode: 'contain', backgroundColor: '#ffffff' },
  ios: { bundleIdentifier: isDev ? `${iosBundleId}.dev` : iosBundleId, buildNumber: process.env.APP_BUILD_NUMBER ?? '1', supportsTablet: false },
  android: { package: isDev ? `${androidPackage}.dev` : androidPackage, versionCode: Number(process.env.APP_BUILD_NUMBER ?? 1), adaptiveIcon: { foregroundImage: './assets/adaptive-icon.png', backgroundColor: '#ffffff' } },
  web: { bundler: 'metro', output: 'static', favicon: './assets/favicon.png' },
  runtimeVersion: { policy: 'fingerprint' },
  updates: otaEnabled
    ? { enabled: true, url: process.env.EXPO_UPDATES_URL, checkAutomatically: 'ON_LOAD', fallbackToCacheTimeout: 0, requestHeaders: { 'expo-channel-name': 'production' } }
    : { enabled: false },
  experiments: { typedRoutes: true },
  extra: { variant, otaEnabled, buildStamp },
  plugins: ['expo-router', 'expo-localization', 'expo-secure-store', 'expo-sqlite', 'expo-updates', ['./plugins/with-build-stamp', { stamp: buildStamp }]],
});
```
Delete `app.json`. (The plugin listed last does not exist until Task 14; until then, leave the `plugins` array without it and add it in Task 14. Do NOT reference a missing plugin, `expo config` will fail.) Install the plugins referenced now: `pnpm expo install expo-secure-store expo-sqlite expo-updates`.

`src/config/constants.ts`:
```ts
import Constants from 'expo-constants';

const extra = (Constants.expoConfig?.extra ?? {}) as { variant?: string; otaEnabled?: boolean; buildStamp?: string };

export const constants = Object.freeze({
  version: Constants.expoConfig?.version ?? '0.0.0',
  buildNumber: String(Constants.expoConfig?.ios?.buildNumber ?? Constants.expoConfig?.android?.versionCode ?? '0'),
  variant: extra.variant === 'production' ? 'production' : 'development',
  otaEnabled: extra.otaEnabled === true,
  buildStamp: extra.buildStamp ?? 'unknown',
});
```

- [ ] **Step 5: Verify**

Run: `mise exec -- pnpm test && mise exec -- pnpm expo config --type public | grep -E '"name"|"version"|bundleIdentifier' && make check-code`
Expected: tests green (env tests 100% coverage), config prints dev name and `.dev` bundle id.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "feat(config): app.config.ts with variants, zod-validated public env

Claude-Session: https://claude.ai/code/session_01SpyYZEnJaLFih75JB4EQAW"
```

---

### Task 10: `src/lib`: logger, errors, storage, secure-store, crash-reporting

**Files:**
- Create: `src/lib/logger.ts`, `src/lib/logger.test.ts`, `src/lib/errors.ts`, `src/lib/errors.test.ts`, `src/lib/storage.ts`, `src/lib/storage.test.ts`, `src/lib/secure-store.ts`, `src/lib/secure-store.test.ts`, `src/lib/crash-reporting.ts`, `src/lib/crash-reporting.test.ts`, `src/test/mocks/expo-secure-store.ts`, `src/test/mocks/expo-sqlite-kv-store.ts`

**Interfaces:**
- Produces: `logger.{debug,info,warn,error}(message, meta?)`; `AppError(code, message, cause?)`, `toUserMessage(error): string`; `storage.{get<T>(key), set(key, value), remove(key)}` (JSON, non-secret); `secureStore.{get(key), set(key, value), remove(key)}` with `SecureKey` enum `{ AUTH_TOKEN }`, `UnsupportedPlatformError`; `crashReporting.{captureException(error, context?), setUser(id|null)}` no-op adapter with `CrashReporter` interface.

- [ ] **Step 1: Jest mocks for native modules**

`src/test/mocks/expo-secure-store.ts`:
```ts
const store = new Map<string, string>();
export async function getItemAsync(key: string) {
  return store.get(key) ?? null;
}
export async function setItemAsync(key: string, value: string) {
  store.set(key, value);
}
export async function deleteItemAsync(key: string) {
  store.delete(key);
}
export function __reset() {
  store.clear();
}
```

`src/test/mocks/expo-sqlite-kv-store.ts`:
```ts
const store = new Map<string, string>();
const Storage = {
  async getItem(key: string) {
    return store.get(key) ?? null;
  },
  async setItem(key: string, value: string) {
    store.set(key, value);
  },
  async removeItem(key: string) {
    store.delete(key);
  },
  __reset() {
    store.clear();
  },
};
export default Storage;
```

- [ ] **Step 2: Failing tests**

`src/lib/logger.test.ts`:
```ts
import { logger } from './logger';

test('logger forwards to console with a level prefix', () => {
  const spy = jest.spyOn(console, 'info').mockImplementation(() => {});
  logger.info('hello', { a: 1 });
  expect(spy).toHaveBeenCalledWith('[info] hello', { a: 1 });
  spy.mockRestore();
});

test('debug is silent outside __DEV__', () => {
  const spy = jest.spyOn(console, 'debug').mockImplementation(() => {});
  const original = (globalThis as { __DEV__?: boolean }).__DEV__;
  (globalThis as { __DEV__?: boolean }).__DEV__ = false;
  logger.debug('x');
  expect(spy).not.toHaveBeenCalled();
  (globalThis as { __DEV__?: boolean }).__DEV__ = original;
  spy.mockRestore();
});
```

`src/lib/errors.test.ts`:
```ts
import { AppError, toUserMessage } from './errors';

test('AppError carries a code and cause', () => {
  const cause = new Error('boom');
  const e = new AppError('NETWORK', 'Network down', cause);
  expect(e.code).toBe('NETWORK');
  expect(e.cause).toBe(cause);
  expect(e).toBeInstanceOf(Error);
});

test('toUserMessage maps known codes and falls back generically', () => {
  expect(toUserMessage(new AppError('NETWORK', 'x'))).toMatch(/connection/i);
  expect(toUserMessage(new AppError('UNAUTHENTICATED', 'x'))).toMatch(/sign in/i);
  expect(toUserMessage(new Error('raw'))).toMatch(/something went wrong/i);
  expect(toUserMessage('not an error')).toMatch(/something went wrong/i);
});
```

`src/lib/storage.test.ts`:
```ts
import { storage } from './storage';

test('round-trips JSON values and removes them', async () => {
  await storage.set('k', { n: 1 });
  expect(await storage.get<{ n: number }>('k')).toEqual({ n: 1 });
  await storage.remove('k');
  expect(await storage.get('k')).toBeNull();
});

test('returns null for corrupt JSON', async () => {
  const raw = (await import('expo-sqlite/kv-store')).default;
  await raw.setItem('bad', '{not json');
  expect(await storage.get('bad')).toBeNull();
});
```

`src/lib/secure-store.test.ts`:
```ts
import { Platform } from 'react-native';
import { SecureKey, secureStore, UnsupportedPlatformError } from './secure-store';

test('stores and reads a secret', async () => {
  await secureStore.set(SecureKey.AUTH_TOKEN, 'abc');
  expect(await secureStore.get(SecureKey.AUTH_TOKEN)).toBe('abc');
  await secureStore.remove(SecureKey.AUTH_TOKEN);
  expect(await secureStore.get(SecureKey.AUTH_TOKEN)).toBeNull();
});

test('rejects values over 2 KB', async () => {
  await expect(secureStore.set(SecureKey.AUTH_TOKEN, 'x'.repeat(2049))).rejects.toThrow(/2048/);
});

test('throws on web unless insecure storage is explicitly allowed', async () => {
  const os = Platform.OS;
  Object.defineProperty(Platform, 'OS', { value: 'web', configurable: true });
  await expect(secureStore.set(SecureKey.AUTH_TOKEN, 'x')).rejects.toBeInstanceOf(UnsupportedPlatformError);
  Object.defineProperty(Platform, 'OS', { value: os, configurable: true });
});
```

`src/lib/crash-reporting.test.ts`:
```ts
import { crashReporting, setCrashReporter } from './crash-reporting';

test('default reporter is a no-op and can be swapped', () => {
  expect(() => crashReporting.captureException(new Error('x'))).not.toThrow();
  const fake = { captureException: jest.fn(), setUser: jest.fn() };
  setCrashReporter(fake);
  crashReporting.captureException(new Error('y'), { where: 'test' });
  crashReporting.setUser('u1');
  expect(fake.captureException).toHaveBeenCalledWith(expect.any(Error), { where: 'test' });
  expect(fake.setUser).toHaveBeenCalledWith('u1');
});
```

Run: `mise exec -- pnpm test src/lib`
Expected: FAIL.

- [ ] **Step 3: Implement**

`src/lib/logger.ts`:
```ts
// The only file allowed to use console.* (Biome override). Swap the sink here
// when adding a crash reporter or remote logging.
type Meta = Record<string, unknown>;

function emit(level: 'debug' | 'info' | 'warn' | 'error', message: string, meta?: Meta) {
  if (level === 'debug' && !__DEV__) return;
  const line = `[${level}] ${message}`;
  if (meta === undefined) console[level](line);
  else console[level](line, meta);
}

export const logger = {
  debug: (m: string, meta?: Meta) => emit('debug', m, meta),
  info: (m: string, meta?: Meta) => emit('info', m, meta),
  warn: (m: string, meta?: Meta) => emit('warn', m, meta),
  error: (m: string, meta?: Meta) => emit('error', m, meta),
};
```

`src/lib/errors.ts`:
```ts
export type ErrorCode = 'NETWORK' | 'UNAUTHENTICATED' | 'UNKNOWN';

export class AppError extends Error {
  readonly code: ErrorCode;
  constructor(code: ErrorCode, message: string, cause?: unknown) {
    super(message, cause === undefined ? undefined : { cause });
    this.name = 'AppError';
    this.code = code;
  }
}

const userMessages: Record<ErrorCode, string> = {
  NETWORK: 'Check your connection and try again.',
  UNAUTHENTICATED: 'Please sign in again.',
  UNKNOWN: 'Something went wrong. Please try again.',
};

export function toUserMessage(error: unknown): string {
  if (error instanceof AppError) return userMessages[error.code];
  return userMessages.UNKNOWN;
}
```

`src/lib/storage.ts`:
```ts
import Storage from 'expo-sqlite/kv-store';

// Non-secret key/value persistence. Secrets go through secure-store.ts.
export const storage = {
  async get<T>(key: string): Promise<T | null> {
    const raw = await Storage.getItem(key);
    if (raw === null) return null;
    try {
      return JSON.parse(raw) as T;
    } catch {
      return null;
    }
  },
  async set(key: string, value: unknown) {
    await Storage.setItem(key, JSON.stringify(value));
  },
  async remove(key: string) {
    await Storage.removeItem(key);
  },
};
```

`src/lib/secure-store.ts`:
```ts
import * as SecureStore from 'expo-secure-store';
import { Platform } from 'react-native';
import { env } from '@/config/env';

export enum SecureKey {
  AUTH_TOKEN = 'auth.token',
}

const MAX_BYTES = 2048; // expo-secure-store documented limit

export class UnsupportedPlatformError extends Error {
  constructor() {
    super('Secure storage is not available on web. Set EXPO_PUBLIC_ALLOW_INSECURE_WEB_STORAGE=true for local development only.');
    this.name = 'UnsupportedPlatformError';
  }
}

const memoryFallback = new Map<string, string>();

function assertPlatform() {
  if (Platform.OS === 'web' && !env.ALLOW_INSECURE_WEB_STORAGE) throw new UnsupportedPlatformError();
}

export const secureStore = {
  async get(key: SecureKey): Promise<string | null> {
    assertPlatform();
    if (Platform.OS === 'web') return memoryFallback.get(key) ?? null;
    return SecureStore.getItemAsync(key);
  },
  async set(key: SecureKey, value: string) {
    assertPlatform();
    if (new TextEncoder().encode(value).byteLength > MAX_BYTES) throw new Error(`Secure values must be <= ${MAX_BYTES} bytes`);
    if (Platform.OS === 'web') {
      memoryFallback.set(key, value);
      return;
    }
    await SecureStore.setItemAsync(key, value);
  },
  async remove(key: SecureKey) {
    assertPlatform();
    if (Platform.OS === 'web') {
      memoryFallback.delete(key);
      return;
    }
    await SecureStore.deleteItemAsync(key);
  },
};
```
(Add a fourth test covering the web-allowed branch: set `env` via `jest.mock('@/config/env', ...)` returning `ALLOW_INSECURE_WEB_STORAGE: true` in a separate test file `secure-store.web.test.ts`, so `src/lib` reaches 100% branches.)

`src/lib/crash-reporting.ts`:
```ts
// Slot for Sentry/Crashlytics. Ship-time default is a no-op; see
// docs/ota-and-crash-reporting.md for the Sentry recipe.
export interface CrashReporter {
  captureException(error: unknown, context?: Record<string, unknown>): void;
  setUser(id: string | null): void;
}

const noop: CrashReporter = { captureException: () => {}, setUser: () => {} };
let current: CrashReporter = noop;

export function setCrashReporter(reporter: CrashReporter) {
  current = reporter;
}

export const crashReporting: CrashReporter = {
  captureException: (e, c) => current.captureException(e, c),
  setUser: (id) => current.setUser(id),
};
```

- [ ] **Step 4: Run tests with coverage**

Run: `mise exec -- pnpm test:coverage -- src/lib`
Expected: green and `src/lib/**` at 100% lines/branches (the threshold fails the run otherwise; add the missing branch tests rather than lowering thresholds).

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat(app): logger, errors, storage, secure-store and crash-reporting slot

Claude-Session: https://claude.ai/code/session_01SpyYZEnJaLFih75JB4EQAW"
```

---

### Task 11: Mock GraphQL API, Apollo Client 4, codegen, Home query

**Files:**
- Create: `mocks/schema.graphql`, `mocks/resolvers.ts`, `mocks/executable-schema.ts`, `mocks/server.ts`, `mocks/msw.ts`, `mocks/README.md`, `codegen.ts`, `src/graphql/client.ts`, `src/graphql/cache.ts`, `src/graphql/ApolloProvider.tsx`, `src/graphql/links/auth.ts`, `src/graphql/links/error.ts`, `src/graphql/links/links.test.ts`, `src/features/home/hello.graphql`, `src/graphql/generated/*` (generated), `scripts/check-codegen.sh`
- Modify: `src/features/home/HomeScreen.tsx`, `src/features/home/HomeScreen.test.tsx`, `src/test/setup.ts`, `src/test/render.tsx`, `src/app/_layout.tsx`, `package.json`, `Makefile`

**Interfaces:**
- Consumes: `secureStore`/`SecureKey` (Task 10), `env.API_URL` (Task 9), `logger`, `crashReporting`, `AppError`.
- Produces: `createApolloClient(): ApolloClient`, `ApolloProvider` wrapper, `HelloDocument`/`HelloQuery` from `@/graphql/generated/graphql`, `authEvents` emitter with `onUnauthenticated(cb)`, `mocks/executable-schema.ts` `schema`, `pnpm mock-api`, `pnpm codegen`, `pnpm codegen:check`.

- [ ] **Step 1: Install**

Run: `mise exec -- pnpm add @apollo/client@^4 graphql@^16 rxjs && mise exec -- pnpm add -D @graphql-codegen/cli@^7 @graphql-codegen/client-preset@^6 @graphql-tools/schema graphql-yoga msw@^2 tsx`

- [ ] **Step 2: Schema and mock servers**

`mocks/schema.graphql`:
```graphql
"""Hello-world schema. Replace with your API's schema (or point codegen.ts at the real endpoint)."""
type Query {
  hello(name: String): String!
  viewer: Viewer
}

type Mutation {
  updateDisplayName(name: String!): Viewer!
}

type Viewer {
  id: ID!
  displayName: String!
}
```

`mocks/resolvers.ts`:
```ts
export type Viewer = { id: string; displayName: string };

export function createResolvers(initial: Viewer = { id: 'u1', displayName: 'Ada' }) {
  let viewer = { ...initial };
  return {
    Query: {
      hello: (_: unknown, args: { name?: string | null }) => `Hello, ${args.name ?? 'world'}!`,
      viewer: (_: unknown, __: unknown, ctx: { token?: string | null }) => (ctx.token ? viewer : null),
    },
    Mutation: {
      updateDisplayName: (_: unknown, args: { name: string }) => {
        viewer = { ...viewer, displayName: args.name };
        return viewer;
      },
    },
  };
}
```

`mocks/executable-schema.ts`:
```ts
import { readFileSync } from 'node:fs';
import path from 'node:path';
import { makeExecutableSchema } from '@graphql-tools/schema';
import { createResolvers } from './resolvers';

const typeDefs = readFileSync(path.join(__dirname, 'schema.graphql'), 'utf8');

export function createSchema() {
  return makeExecutableSchema({ typeDefs, resolvers: createResolvers() });
}

export function contextFromHeaders(headers: { get(name: string): string | null }) {
  const auth = headers.get('authorization');
  return { token: auth?.startsWith('Bearer ') ? auth.slice(7) : null };
}
```

`mocks/server.ts` (run with `tsx`):
```ts
import { createServer } from 'node:http';
import { createYoga } from 'graphql-yoga';
import { contextFromHeaders, createSchema } from './executable-schema';

const yoga = createYoga({ schema: createSchema(), context: ({ request }) => contextFromHeaders(request.headers), graphqlEndpoint: '/graphql' });
const port = Number(process.env.MOCK_API_PORT ?? 4000);
createServer(yoga).listen(port, () => {
  console.log(`mock GraphQL API on http://localhost:${port}/graphql`);
});
```

`mocks/msw.ts`:
```ts
import { execute, parse } from 'graphql';
import { HttpResponse, http } from 'msw';
import { contextFromHeaders, createSchema } from './executable-schema';

export function createHandlers(url = 'http://localhost:4000/graphql') {
  const schema = createSchema();
  return [
    http.post(url, async ({ request }) => {
      const body = (await request.json()) as { query: string; variables?: Record<string, unknown> };
      const result = await execute({ schema, document: parse(body.query), variableValues: body.variables, contextValue: contextFromHeaders(request.headers) });
      return HttpResponse.json(result);
    }),
  ];
}
```

`mocks/README.md`: three paragraphs: (1) `schema.graphql` is the single source; (2) `pnpm mock-api` for simulators, MSW for Jest/Playwright, both execute the same resolvers; (3) to move to a real API: point `codegen.ts` `schema` at the endpoint or a downloaded SDL, keep `mocks/` for tests.

- [ ] **Step 3: Codegen**

`codegen.ts`:
```ts
import type { CodegenConfig } from '@graphql-codegen/cli';

const config: CodegenConfig = {
  schema: 'mocks/schema.graphql',
  documents: ['src/**/*.graphql'],
  ignoreNoDocuments: true,
  generates: {
    'src/graphql/generated/': {
      preset: 'client',
      presetConfig: { fragmentMasking: false },
      config: { enumsAsTypes: true, skipTypename: false },
    },
  },
};

export default config;
```

`src/features/home/hello.graphql`:
```graphql
query Hello($name: String) {
  hello(name: $name)
}
```

`package.json`: `"codegen": "graphql-codegen --config codegen.ts"`, `"codegen:check": "bash scripts/check-codegen.sh"`, `"mock-api": "tsx mocks/server.ts"`.

Run: `mise exec -- pnpm codegen && ls src/graphql/generated`
Expected: `graphql.ts`, `gql.ts`, `index.ts`, `fragment-masking.ts` (or without the last one). `grep HelloDocument src/graphql/generated/graphql.ts` finds the export.

`scripts/check-codegen.sh`:
```bash
#!/usr/bin/env bash
# Fails when src/graphql/generated is stale relative to schema/documents.
set -euo pipefail
cd "$(dirname "$0")/.."
pnpm codegen >/dev/null
if ! git diff --exit-code --quiet -- src/graphql/generated; then
  echo "GraphQL generated code is out of date. Run: make codegen" >&2
  exit 1
fi
echo "GraphQL generated code is current"
```
Makefile: `codegen: ## Regenerate typed GraphQL documents` → `pnpm codegen`; add `pnpm codegen:check` to `check-gen`; `mock-api: ## Local GraphQL mock API on :4000` → `pnpm mock-api`.

- [ ] **Step 4: Failing link tests and Home test**

`src/graphql/links/links.test.ts`:
```ts
import { ApolloLink, execute, gql, Observable } from '@apollo/client';
import { SecureKey, secureStore } from '@/lib/secure-store';
import { createAuthLink } from './auth';
import { createErrorLink, onUnauthenticated } from './error';

const QUERY = gql`
  query X {
    hello
  }
`;

function terminating(handler: (op: { getContext(): { headers?: Record<string, string> } }) => unknown) {
  return new ApolloLink((operation) => new Observable((obs) => {
    obs.next(handler(operation) as never);
    obs.complete();
  }));
}

test('auth link adds a bearer header when a token exists', async () => {
  await secureStore.set(SecureKey.AUTH_TOKEN, 'tok');
  let headers: Record<string, string> | undefined;
  const link = ApolloLink.from([createAuthLink(), terminating((op) => { headers = op.getContext().headers; return { data: { hello: 'x' } }; })]);
  await new Promise<void>((resolve) => execute(link, { query: QUERY }).subscribe({ complete: resolve }));
  expect(headers?.authorization).toBe('Bearer tok');
});

test('error link emits onUnauthenticated for UNAUTHENTICATED codes', async () => {
  const cb = jest.fn();
  onUnauthenticated(cb);
  const link = ApolloLink.from([createErrorLink(), terminating(() => ({ errors: [{ message: 'nope', extensions: { code: 'UNAUTHENTICATED' } }] }))]);
  await new Promise<void>((resolve) => execute(link, { query: QUERY }).subscribe({ next: () => {}, error: () => resolve(), complete: resolve }));
  expect(cb).toHaveBeenCalled();
});
```

Update `src/features/home/HomeScreen.test.tsx`:
```tsx
import { renderRouter, screen, waitFor } from 'expo-router/testing-library';
import { HomeScreen } from './HomeScreen';
import { Providers } from '@/test/render';

test('home shows the hello greeting from the (mock) API', async () => {
  renderRouter({ index: HomeScreen, 'details/[id]': () => null }, { initialUrl: '/', wrapper: Providers });
  await waitFor(() => expect(screen.getByTestId('home-hello')).toHaveTextContent('Hello, world!'));
});
```

Run: `mise exec -- pnpm test src/graphql src/features/home`
Expected: FAIL.

- [ ] **Step 5: Implement links, cache, client, provider, screen**

`src/graphql/links/auth.ts`:
```ts
import { SetContextLink } from '@apollo/client/link/context';
import { SecureKey, secureStore } from '@/lib/secure-store';

export function createAuthLink() {
  return new SetContextLink(async (prev) => {
    const token = await secureStore.get(SecureKey.AUTH_TOKEN).catch(() => null);
    const headers = (prev.headers ?? {}) as Record<string, string>;
    return { headers: token ? { ...headers, authorization: `Bearer ${token}` } : headers };
  });
}
```

`src/graphql/links/error.ts`:
```ts
import { CombinedGraphQLErrors } from '@apollo/client/errors';
import { ErrorLink } from '@apollo/client/link/error';
import { crashReporting } from '@/lib/crash-reporting';
import { logger } from '@/lib/logger';

const listeners = new Set<() => void>();
export function onUnauthenticated(cb: () => void) {
  listeners.add(cb);
  return () => listeners.delete(cb);
}

export function createErrorLink() {
  return new ErrorLink(({ error, operation }) => {
    if (CombinedGraphQLErrors.is(error)) {
      if (error.errors.some((e) => e.extensions?.code === 'UNAUTHENTICATED')) {
        for (const cb of listeners) cb();
      }
      logger.warn(`GraphQL error in ${operation.operationName}`, { messages: error.errors.map((e) => e.message) });
      return;
    }
    logger.error(`Network error in ${operation.operationName}`, { message: String(error) });
    crashReporting.captureException(error, { operation: operation.operationName });
  });
}
```
(If `ErrorLink` in the installed Apollo 4 version does not surface `errors` with `extensions`, read `error.errors[i].extensions`; check with `pnpm typecheck` and the test.)

`src/graphql/cache.ts` (dependency-free persistence):
```ts
import { InMemoryCache } from '@apollo/client';
import { AppState } from 'react-native';
import { storage } from '@/lib/storage';

const KEY = 'apollo.cache.v1';

export function createCache() {
  return new InMemoryCache();
}

export async function restoreCache(cache: InMemoryCache) {
  const snapshot = await storage.get<Record<string, unknown>>(KEY);
  if (snapshot) cache.restore(snapshot as never);
}

export function persistCacheOnBackground(cache: InMemoryCache) {
  const sub = AppState.addEventListener('change', (state) => {
    if (state === 'background' || state === 'inactive') void storage.set(KEY, cache.extract());
  });
  return () => sub.remove();
}
```

`src/graphql/client.ts`:
```ts
import { ApolloClient, ApolloLink, HttpLink } from '@apollo/client';
import { RetryLink } from '@apollo/client/link/retry';
import { env } from '@/config/env';
import { createCache } from './cache';
import { createAuthLink } from './links/auth';
import { createErrorLink } from './links/error';

export function createApolloClient(uri = env.API_URL) {
  const cache = createCache();
  return new ApolloClient({
    cache,
    link: ApolloLink.from([createErrorLink(), new RetryLink({ attempts: { max: 3 } }), createAuthLink(), new HttpLink({ uri })]),
  });
}
```

`src/graphql/ApolloProvider.tsx`:
```tsx
import { ApolloProvider as Provider } from '@apollo/client/react';
import { type PropsWithChildren, useEffect, useMemo } from 'react';
import { persistCacheOnBackground, restoreCache } from './cache';
import { createApolloClient } from './client';

export function ApolloProvider({ children, uri }: PropsWithChildren<{ uri?: string }>) {
  const client = useMemo(() => createApolloClient(uri), [uri]);
  useEffect(() => {
    void restoreCache(client.cache as never);
    return persistCacheOnBackground(client.cache as never);
  }, [client]);
  return <Provider client={client}>{children}</Provider>;
}
```

`src/features/home/HomeScreen.tsx` gets:
```tsx
import { useQuery } from '@apollo/client/react';
import { HelloDocument } from '@/graphql/generated/graphql';
// inside component:
const { data, error } = useQuery(HelloDocument, { variables: { name: null } });
// render:
<AppText testID="home-hello">{error ? toUserMessage(error) : (data?.hello ?? '…')}</AppText>
```

`src/test/setup.ts` adds MSW:
```ts
import { setupServer } from 'msw/node';
import { createHandlers } from '../../mocks/msw';

export const server = setupServer(...createHandlers());
beforeAll(() => server.listen({ onUnhandledRequest: 'error' }));
afterEach(() => server.resetHandlers());
afterAll(() => server.close());
```
Export `Providers` from `src/test/render.tsx` and add `<ApolloProvider>` inside it (Theme > I18n > Apollo). Wrap `_layout.tsx` the same way.

React Native's `fetch` in Jest: MSW needs Node's `fetch`. If the test hangs, add `global.fetch = require('node-fetch')`-style polyfill or, simpler, `import 'whatwg-fetch'` is NOT needed on Node 24; instead ensure `jest-expo` does not replace `fetch`: set `testEnvironmentOptions: { customExportConditions: ['react-native', 'node'] }` or map `fetch` to `globalThis.fetch` in `src/test/setup.ts` before `server.listen()`.

- [ ] **Step 6: Run tests and gates**

Run: `mise exec -- pnpm test && make check-gen && make check-code`
Expected: all green. `HomeScreen.test` gets `Hello, world!` through MSW executing the real schema.

- [ ] **Step 7: Smoke against the yoga server**

Run in one terminal: `make mock-api`; in another: `curl -s http://localhost:4000/graphql -H 'content-type: application/json' -d '{"query":"{ hello }"}'`
Expected: `{"data":{"hello":"Hello, world!"}}`. Stop the server.

- [ ] **Step 8: Commit**

```bash
git add -A
git commit -m "feat(graphql): Apollo Client 4 with typed documents and a mock schema server

Claude-Session: https://claude.ai/code/session_01SpyYZEnJaLFih75JB4EQAW"
```

---

### Task 12: Auth service, updates service with dev menu, error boundary

**Files:**
- Create: `src/services/auth.ts`, `src/services/auth.test.ts`, `src/services/updates.ts`, `src/services/updates.test.ts`, `src/test/mocks/expo-updates.ts`, `src/components/ErrorFallback.tsx`, `src/components/ErrorFallback.test.tsx`, `src/features/settings/DevMenu.tsx`, `src/features/settings/SettingsScreen.test.tsx`
- Modify: `src/features/settings/SettingsScreen.tsx`, `src/app/_layout.tsx`

**Interfaces:**
- Consumes: `secureStore`, `onUnauthenticated`, `constants`, `storage`, `useThemePreference`, `useLocale`/`activateLocale`.
- Produces: `auth.{getToken, signInMock, signOut}` + `useAuth()`; `updates.{check, applyIfAvailable, switchChannel(channel), info()}` and `useUpdateInfo()`; `ErrorFallback({ error, resetErrorBoundary })`; `DevMenu` (hidden in production variant; shows build stamp, version, channel controls when `constants.otaEnabled`, theme and language pickers, "Trigger error" button).

- [ ] **Step 1: Install and mock**

Run: `mise exec -- pnpm add react-error-boundary`

`src/test/mocks/expo-updates.ts`:
```ts
export const channel: string | null = null;
export const runtimeVersion: string | null = 'test-runtime';
export const updateId: string | null = null;
export const isEnabled = false;
export const checkForUpdateAsync = jest.fn(async () => ({ isAvailable: false }));
export const fetchUpdateAsync = jest.fn(async () => ({ isNew: false }));
export const reloadAsync = jest.fn(async () => {});
export const setUpdateRequestHeadersOverride = jest.fn();
```

- [ ] **Step 2: Failing tests**

`src/services/auth.test.ts`:
```ts
import { auth } from './auth';

test('mock sign-in stores a token and sign-out clears it', async () => {
  expect(await auth.getToken()).toBeNull();
  await auth.signInMock();
  expect(await auth.getToken()).toMatch(/^mock-/);
  await auth.signOut();
  expect(await auth.getToken()).toBeNull();
});
```

`src/services/updates.test.ts`:
```ts
import * as Updates from 'expo-updates';
import { updates } from './updates';

test('switchChannel overrides the header and checks for updates', async () => {
  await updates.switchChannel('beta');
  expect(Updates.setUpdateRequestHeadersOverride).toHaveBeenCalledWith({ 'expo-channel-name': 'beta' });
  expect(Updates.checkForUpdateAsync).toHaveBeenCalled();
});

test('applyIfAvailable is a no-op when nothing is available', async () => {
  await expect(updates.applyIfAvailable()).resolves.toBe(false);
  expect(Updates.reloadAsync).not.toHaveBeenCalled();
});

test('info exposes runtime metadata', () => {
  expect(updates.info()).toEqual({ channel: null, runtimeVersion: 'test-runtime', updateId: null, enabled: false });
});
```

`src/components/ErrorFallback.test.tsx`:
```tsx
import { fireEvent, screen } from '@testing-library/react-native';
import { renderWithProviders } from '@/test/render';
import { ErrorFallback } from './ErrorFallback';

test('shows a friendly message and retries', () => {
  const reset = jest.fn();
  renderWithProviders(<ErrorFallback error={new Error('boom')} resetErrorBoundary={reset} />);
  expect(screen.getByTestId('error-screen')).toBeOnTheScreen();
  fireEvent.press(screen.getByTestId('error-retry'));
  expect(reset).toHaveBeenCalled();
});
```

`src/features/settings/SettingsScreen.test.tsx`:
```tsx
import { fireEvent, screen } from '@testing-library/react-native';
import { renderWithProviders } from '@/test/render';
import { SettingsScreen } from './SettingsScreen';

test('dev menu toggles theme and language', () => {
  renderWithProviders(<SettingsScreen />);
  fireEvent.press(screen.getByTestId('settings-theme-dark'));
  fireEvent.press(screen.getByTestId('settings-lang-es'));
  expect(screen.getByTestId('settings-title')).toHaveTextContent('Ajustes');
});
```

Run: `mise exec -- pnpm test src/services src/components src/features/settings`
Expected: FAIL.

- [ ] **Step 3: Implement**

`src/services/auth.ts`:
```ts
import { useEffect, useState } from 'react';
import { onUnauthenticated } from '@/graphql/links/error';
import { SecureKey, secureStore } from '@/lib/secure-store';

const listeners = new Set<() => void>();
function notify() {
  for (const l of listeners) l();
}

export const auth = {
  getToken: () => secureStore.get(SecureKey.AUTH_TOKEN),
  async signInMock() {
    await secureStore.set(SecureKey.AUTH_TOKEN, `mock-${Date.now()}`);
    notify();
  },
  async signOut() {
    await secureStore.remove(SecureKey.AUTH_TOKEN);
    notify();
  },
};

onUnauthenticated(() => void auth.signOut());

export function useAuth() {
  const [signedIn, setSignedIn] = useState(false);
  useEffect(() => {
    const refresh = () => void auth.getToken().then((t) => setSignedIn(t !== null));
    refresh();
    listeners.add(refresh);
    return () => void listeners.delete(refresh);
  }, []);
  return { signedIn, signIn: auth.signInMock, signOut: auth.signOut };
}
```

`src/services/updates.ts`:
```ts
import * as Updates from 'expo-updates';
import { useEffect, useState } from 'react';
import { logger } from '@/lib/logger';

export type Channel = 'internal' | 'beta' | 'production';

export const updates = {
  info: () => ({ channel: Updates.channel, runtimeVersion: Updates.runtimeVersion, updateId: Updates.updateId, enabled: Updates.isEnabled }),
  async applyIfAvailable(): Promise<boolean> {
    if (!Updates.isEnabled) return false;
    const check = await Updates.checkForUpdateAsync();
    if (!check.isAvailable) return false;
    await Updates.fetchUpdateAsync();
    await Updates.reloadAsync();
    return true;
  },
  async switchChannel(channel: Channel) {
    Updates.setUpdateRequestHeadersOverride({ 'expo-channel-name': channel });
    const check = await Updates.checkForUpdateAsync().catch((e: unknown) => {
      logger.warn('update check failed', { e: String(e) });
      return { isAvailable: false };
    });
    if (check.isAvailable) {
      await Updates.fetchUpdateAsync();
      await Updates.reloadAsync();
    }
  },
};

const ONE_HOUR = 60 * 60 * 1000;
let lastCheck = 0;

export function useUpdateInfo() {
  const [info, setInfo] = useState(updates.info());
  useEffect(() => {
    if (Date.now() - lastCheck < ONE_HOUR) return;
    lastCheck = Date.now();
    void updates.applyIfAvailable().finally(() => setInfo(updates.info()));
  }, []);
  return info;
}
```
(Fix the `switchChannel` test's first assertion if `checkForUpdateAsync` mock rejects: it resolves by default.)

`src/components/ErrorFallback.tsx`:
```tsx
import { Trans } from '@lingui/react/macro';
import { useLingui } from '@lingui/react/macro';
import type { FallbackProps } from 'react-error-boundary';
import { toUserMessage } from '@/lib/errors';
import { AppText } from './AppText';
import { Button } from './Button';
import { Screen } from './Screen';

export function ErrorFallback({ error, resetErrorBoundary }: FallbackProps) {
  const { t } = useLingui();
  return (
    <Screen testID="error-screen">
      <AppText variant="title">
        <Trans>Something went wrong</Trans>
      </AppText>
      <AppText>{toUserMessage(error)}</AppText>
      <Button title={t`Try again`} testID="error-retry" onPress={resetErrorBoundary} />
    </Screen>
  );
}
```

`src/features/settings/DevMenu.tsx`: renders (all with `testID`s) `settings-build-stamp` (`constants.buildStamp`), `settings-version` (`${constants.version} (${constants.buildNumber})`), buttons `settings-theme-light|dark|system` calling `setPreference`, `settings-lang-en|es` calling `activateLocale` + `setLocale` state, and, when `constants.otaEnabled`, buttons `settings-channel-internal|beta|production` calling `updates.switchChannel` plus a line showing `updates.info()`; and `settings-trigger-error` which sets state that throws during render (`if (boom) throw new Error('Manual test error')`). It is rendered by `SettingsScreen` only when `constants.variant === 'development'` OR a hidden gesture (7 taps on the title, counter in state) has been performed.

`src/app/_layout.tsx`: wrap providers in `<ErrorBoundary FallbackComponent={ErrorFallback} onError={(e) => crashReporting.captureException(e)}>`; also register `ErrorUtils.getGlobalHandler` chaining to `crashReporting.captureException` once at module scope (guarded by `typeof ErrorUtils !== 'undefined'`).

- [ ] **Step 4: Tests, i18n extraction, gates**

Run: `make i18n && mise exec -- pnpm test && make check`
(`make check` does not exist until Task 17; use `make check-code check-gen` now.)
Expected: green; new `es` strings translated in `messages.po` (`Algo salió mal`, `Intentar de nuevo`, etc.) before `make check-gen` passes.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat(app): auth + updates services, dev menu and error boundary

Claude-Session: https://claude.ai/code/session_01SpyYZEnJaLFih75JB4EQAW"
```

---

### Task 13: Local Expo Module `hello-native` (Swift + Kotlin)

**Files:**
- Create: `modules/hello-native/expo-module.config.json`, `modules/hello-native/index.ts`, `modules/hello-native/src/HelloNativeModule.ts`, `modules/hello-native/src/HelloNative.types.ts`, `modules/hello-native/src/__mocks__/HelloNativeModule.ts`, `modules/hello-native/__tests__/index.test.ts`, `modules/hello-native/ios/HelloNative.podspec`, `modules/hello-native/ios/HelloNativeModule.swift`, `modules/hello-native/android/build.gradle`, `modules/hello-native/android/src/main/java/expo/modules/hellonative/HelloNativeModule.kt`, `src/features/settings/NativeDemoCard.tsx`, `src/features/settings/NativeDemoCard.web.tsx`
- Modify: `src/features/settings/SettingsScreen.tsx`, `jest.config.ts` (`collectCoverageFrom` already includes `modules/*/index.ts`), `tsconfig.json` (`include` gets `modules/**/*.ts`)

**Interfaces:**
- Produces: `hello(name: string): string`, `getBuildStamp(): Promise<string>`, `platformName: string`, `HelloNativeError` from `modules/hello-native`; `NativeDemoCard` rendering `hello('Maestro')` under `testID="native-hello"` and the stamp under `testID="native-build-stamp"`.

- [ ] **Step 1: Generate the module skeleton**

Run: `mise exec -- pnpm create expo-module --local hello-native`
Answer prompts: name `hello-native`, native module name `HelloNative`, Android package `expo.modules.hellonative`. Then: `ls -R modules/hello-native` and delete the generated `src/HelloNativeView*.tsx`, `ios/HelloNativeView.swift`, `android/.../HelloNativeView.kt` (no native view is needed) and their references in the module files. Keep `expo-module.config.json`, `ios/HelloNative.podspec`, `android/build.gradle`.

- [ ] **Step 2: Failing tests**

`modules/hello-native/src/__mocks__/HelloNativeModule.ts`:
```ts
export default {
  hello: (name: string) => `Hello, ${name} from mock`,
  getBuildStamp: async () => 'mock-stamp',
  platformName: 'mock',
};
```

`modules/hello-native/__tests__/index.test.ts`:
```ts
jest.mock('../src/HelloNativeModule');
import { hello, getBuildStamp, HelloNativeError, platformName } from '..';

test('hello validates input and proxies to native', () => {
  expect(hello('Ada')).toBe('Hello, Ada from mock');
  expect(() => hello('')).toThrow(HelloNativeError);
});

test('getBuildStamp resolves', async () => {
  await expect(getBuildStamp()).resolves.toBe('mock-stamp');
});

test('platformName is exposed', () => {
  expect(platformName).toBe('mock');
});

test('missing native module produces a helpful error', () => {
  jest.isolateModules(() => {
    jest.doMock('../src/HelloNativeModule', () => { throw new Error("Cannot find native module 'HelloNative'"); });
    expect(() => require('..').hello('x')).toThrow(/make ios/);
  });
});
```

Run: `mise exec -- pnpm test modules`
Expected: FAIL.

- [ ] **Step 3: Implement TS side**

`modules/hello-native/src/HelloNative.types.ts`:
```ts
export type HelloNativeModuleType = {
  hello(name: string): string;
  getBuildStamp(): Promise<string>;
  platformName: string;
};
```

`modules/hello-native/src/HelloNativeModule.ts`:
```ts
import { requireNativeModule } from 'expo';
import type { HelloNativeModuleType } from './HelloNative.types';

export default requireNativeModule<HelloNativeModuleType>('HelloNative');
```

`modules/hello-native/index.ts`:
```ts
import type { HelloNativeModuleType } from './src/HelloNative.types';

export class HelloNativeError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'HelloNativeError';
  }
}

let native: HelloNativeModuleType | null = null;
function module_(): HelloNativeModuleType {
  if (native) return native;
  try {
    native = require('./src/HelloNativeModule').default as HelloNativeModuleType;
    return native;
  } catch (cause) {
    throw new HelloNativeError('HelloNative is not available in this runtime (Expo Go or web). Build a dev client: make ios / make android.');
  }
}

export function hello(name: string): string {
  if (name.length === 0) throw new HelloNativeError('name must not be empty');
  return module_().hello(name);
}

export function getBuildStamp(): Promise<string> {
  return module_().getBuildStamp();
}

export const platformName: string = (() => {
  try {
    return module_().platformName;
  } catch {
    return 'unavailable';
  }
})();
```
(If Biome flags the `require`, add an override for `modules/**/index.ts` allowing it; the lazy require is deliberate so importing the wrapper on web does not throw.)

- [ ] **Step 4: Native implementations**

`modules/hello-native/ios/HelloNativeModule.swift`:
```swift
import ExpoModulesCore

public class HelloNativeModule: Module {
  public func definition() -> ModuleDefinition {
    Name("HelloNative")

    Constant("platformName") { "ios" }

    Function("hello") { (name: String) -> String in
      return "Hello, \(name) from Swift"
    }

    AsyncFunction("getBuildStamp") { () -> String in
      return Bundle.main.object(forInfoDictionaryKey: "AppBuildStamp") as? String ?? "missing"
    }
  }
}
```

`modules/hello-native/android/src/main/java/expo/modules/hellonative/HelloNativeModule.kt`:
```kotlin
package expo.modules.hellonative

import expo.modules.kotlin.modules.Module
import expo.modules.kotlin.modules.ModuleDefinition

class HelloNativeModule : Module() {
  override fun definition() = ModuleDefinition {
    Name("HelloNative")

    Constant("platformName") { "android" }

    Function("hello") { name: String ->
      "Hello, $name from Kotlin"
    }

    AsyncFunction("getBuildStamp") {
      val ctx = appContext.reactContext ?: return@AsyncFunction "missing"
      val info = ctx.packageManager.getApplicationInfo(ctx.packageName, android.content.pm.PackageManager.GET_META_DATA)
      info.metaData?.getString("AppBuildStamp") ?: "missing"
    }
  }
}
```
(The Android stamp is read from `<meta-data android:name="AppBuildStamp">` which Task 14's plugin adds to `AndroidManifest.xml`; this avoids a `BuildConfig` import from the app package in the module.)

`expo-module.config.json`:
```json
{ "platforms": ["apple", "android"], "apple": { "modules": ["HelloNativeModule"] }, "android": { "modules": ["expo.modules.hellonative.HelloNativeModule"] } }
```

- [ ] **Step 5: UI card**

`src/features/settings/NativeDemoCard.tsx`:
```tsx
import { useEffect, useState } from 'react';
import { getBuildStamp, hello, HelloNativeError } from '../../../modules/hello-native';
import { AppText } from '@/components/AppText';
import { Card } from '@/components/Card';

export function NativeDemoCard() {
  const [stamp, setStamp] = useState('…');
  let greeting: string;
  try {
    greeting = hello('Maestro');
  } catch (e) {
    greeting = e instanceof HelloNativeError ? e.message : 'error';
  }
  useEffect(() => {
    getBuildStamp().then(setStamp).catch(() => setStamp('unavailable'));
  }, []);
  return (
    <Card>
      <AppText testID="native-hello">{greeting}</AppText>
      <AppText testID="native-build-stamp">build-stamp:{stamp}</AppText>
    </Card>
  );
}
```
`NativeDemoCard.web.tsx` (first line `// WEB ONLY`, add to `docs/web-files.txt`): renders `<Card><AppText testID="native-hello">Native demo unavailable on web</AppText></Card>`.
`src/components/Card.tsx`: a `View` with `surface` background, `radii.md`, padding `spacing.md`. Add `<NativeDemoCard />` to `SettingsScreen`.

- [ ] **Step 6: Run tests, then prove the native path on the simulator**

Run: `mise exec -- pnpm test && make check-code && make ios`
Expected: tests green; the app rebuilds (module autolinked by prebuild) and Settings shows "Hello, Maestro from Swift" and `build-stamp:missing` (plugin comes next).

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "feat(native): local Expo Module hello-native with Swift and Kotlin

Claude-Session: https://claude.ai/code/session_01SpyYZEnJaLFih75JB4EQAW"
```

---

### Task 14: Config plugins (build stamp, Android release signing, Android ABIs) + prebuild check

**Files:**
- Create: `plugins/tsconfig.json`, `plugins/with-build-stamp.ts`, `plugins/with-build-stamp.test.ts`, `plugins/with-android-release-signing.ts`, `plugins/with-android-release-signing.test.ts`, `plugins/with-android-release-abis.ts`, `plugins/with-android-release-abis.test.ts`, `scripts/check-prebuild.sh`
- Modify: `app.config.ts`, `jest.config.ts` (`testPathIgnorePatterns` drop `/plugins/`; add a `projects` entry or `testMatch` covering `plugins/**/*.test.ts` under `testEnvironment: node`), `Makefile`, `package.json`

**Interfaces:**
- Consumes: `app.config.ts` `plugins` array.
- Produces: `withBuildStamp(config, { stamp })`, `withAndroidReleaseSigning(config)`, `withAndroidReleaseAbis(config, { abis? })`; `pnpm check-prebuild`.

- [ ] **Step 1: Jest project for plugins**

`plugins/tsconfig.json`:
```json
{ "extends": "../tsconfig.json", "compilerOptions": { "module": "commonjs", "types": ["node", "jest"] }, "include": ["./**/*.ts"] }
```
In `jest.config.ts`, convert to two projects:
```ts
projects: [
  { displayName: 'app', preset: 'jest-expo', /* everything from before */ },
  { displayName: 'plugins', testEnvironment: 'node', testMatch: ['<rootDir>/plugins/**/*.test.ts'], transform: { '^.+\\.ts$': ['babel-jest', { presets: ['babel-preset-expo'] }] } },
],
```
Keep `coverageThreshold` at the top level and add `'plugins/**': { lines: 100, branches: 100 }`.

- [ ] **Step 2: Failing tests**

`plugins/with-build-stamp.test.ts`:
```ts
import type { ExpoConfig } from 'expo/config';
import { withBuildStamp } from './with-build-stamp';

type Mods = { mods?: { ios?: { infoPlist?: (c: unknown) => Promise<unknown> }; android?: { manifest?: (c: unknown) => Promise<unknown> } } };

const base = (): ExpoConfig => ({ name: 'x', slug: 'x' });

async function runIos(config: ExpoConfig & Mods, plist: Record<string, unknown>) {
  const r = (await config.mods?.ios?.infoPlist?.({ ...config, modResults: plist, modRequest: {}, modRawConfig: config })) as { modResults: Record<string, unknown> };
  return r.modResults;
}

test('sets AppBuildStamp and the encryption key on iOS, without clobbering an existing encryption value', async () => {
  const c = withBuildStamp(base(), { stamp: 's1' }) as ExpoConfig & Mods;
  const out = await runIos(c, { ITSAppUsesNonExemptEncryption: true });
  expect(out.AppBuildStamp).toBe('s1');
  expect(out.ITSAppUsesNonExemptEncryption).toBe(true);
  const fresh = await runIos(withBuildStamp(base(), { stamp: 's2' }) as ExpoConfig & Mods, {});
  expect(fresh.ITSAppUsesNonExemptEncryption).toBe(false);
});

test('adds one AppBuildStamp meta-data entry to the Android manifest, idempotently', async () => {
  const c = withBuildStamp(base(), { stamp: 's1' }) as ExpoConfig & Mods;
  const manifest = { manifest: { application: [{ $: { 'android:name': '.MainApplication' }, 'meta-data': [] as unknown[] }] } };
  const run = async () => ((await c.mods?.android?.manifest?.({ ...c, modResults: manifest, modRequest: {}, modRawConfig: c })) as { modResults: typeof manifest }).modResults;
  const once = await run();
  const twice = await run();
  const meta = twice.manifest.application[0]?.['meta-data'] as { $: Record<string, string> }[];
  expect(meta.filter((m) => m.$['android:name'] === 'AppBuildStamp')).toHaveLength(1);
  expect(meta[0]?.$['android:value']).toBe('s1');
  expect(once).toBe(twice);
});
```

`plugins/with-android-release-signing.test.ts`:
```ts
import type { ExpoConfig } from 'expo/config';
import { withAndroidReleaseSigning } from './with-android-release-signing';

type Mods = { mods?: { android?: { appBuildGradle?: (c: unknown) => Promise<unknown> } } };
const gradle = `android {\n  signingConfigs {\n    debug {\n      storeFile file('debug.keystore')\n    }\n  }\n  buildTypes {\n    release {\n      signingConfig signingConfigs.debug\n    }\n  }\n}\n`;

test('injects a release signingConfig fed by gradle properties, idempotently', async () => {
  const c = withAndroidReleaseSigning({ name: 'x', slug: 'x' }) as ExpoConfig & Mods;
  const run = async (contents: string) => ((await c.mods?.android?.appBuildGradle?.({ ...c, modResults: { contents, language: 'groovy', path: 'x' }, modRequest: {}, modRawConfig: c })) as { modResults: { contents: string } }).modResults.contents;
  const once = await run(gradle);
  expect(once).toContain("storeFile file(project.findProperty('ANDROID_UPLOAD_STORE_FILE')");
  expect(once).toContain('signingConfig signingConfigs.release');
  expect(once).not.toContain('signingConfig signingConfigs.debug\n    }\n  }\n}\n');
  const twice = await run(once);
  expect(twice).toBe(once);
});
```

`plugins/with-android-release-abis.test.ts`:
```ts
import type { ExpoConfig } from 'expo/config';
import { withAndroidReleaseAbis } from './with-android-release-abis';

type Mods = { mods?: { android?: { gradleProperties?: (c: unknown) => Promise<unknown> } } };

test('sets reactNativeArchitectures to arm ABIs by default, idempotently', async () => {
  const c = withAndroidReleaseAbis({ name: 'x', slug: 'x' }) as ExpoConfig & Mods;
  const run = async (props: { type: string; key: string; value: string }[]) => ((await c.mods?.android?.gradleProperties?.({ ...c, modResults: props, modRequest: {}, modRawConfig: c })) as { modResults: { type: string; key: string; value: string }[] }).modResults;
  const once = await run([{ type: 'property', key: 'reactNativeArchitectures', value: 'armeabi-v7a,arm64-v8a,x86,x86_64' }]);
  expect(once).toEqual([{ type: 'property', key: 'reactNativeArchitectures', value: 'armeabi-v7a,arm64-v8a' }]);
  expect(await run(once)).toEqual(once);
});
```

Run: `mise exec -- pnpm test --selectProjects plugins`
Expected: FAIL.

- [ ] **Step 3: Implement**

`plugins/with-build-stamp.ts`:
```ts
import { AndroidConfig, type ConfigPlugin, withAndroidManifest, withInfoPlist } from 'expo/config-plugins';

export const withBuildStamp: ConfigPlugin<{ stamp: string }> = (config, { stamp }) => {
  config = withInfoPlist(config, (c) => {
    c.modResults.AppBuildStamp = stamp;
    if (c.modResults.ITSAppUsesNonExemptEncryption === undefined) c.modResults.ITSAppUsesNonExemptEncryption = false;
    return c;
  });
  config = withAndroidManifest(config, (c) => {
    const app = AndroidConfig.Manifest.getMainApplicationOrThrow(c.modResults);
    AndroidConfig.Manifest.addMetaDataItemToMainApplication(app, 'AppBuildStamp', stamp);
    return c;
  });
  return config;
};

export default withBuildStamp;
```
(`addMetaDataItemToMainApplication` replaces an existing item of the same name, which gives idempotency. `getMainApplicationOrThrow` requires `android:name=".MainApplication"`; the test fixture sets it.)

`plugins/with-android-release-signing.ts`:
```ts
import { type ConfigPlugin, withAppBuildGradle } from 'expo/config-plugins';
import { mergeContents } from '@expo/config-plugins/build/utils/generateCode';

const SIGNING = `    release {
      storeFile file(project.findProperty('ANDROID_UPLOAD_STORE_FILE') ?: 'debug.keystore')
      storePassword project.findProperty('ANDROID_UPLOAD_STORE_PASSWORD') ?: 'android'
      keyAlias project.findProperty('ANDROID_UPLOAD_KEY_ALIAS') ?: 'androiddebugkey'
      keyPassword project.findProperty('ANDROID_UPLOAD_KEY_PASSWORD') ?: 'android'
    }`;

export const withAndroidReleaseSigning: ConfigPlugin = (config) =>
  withAppBuildGradle(config, (c) => {
    let contents = c.modResults.contents;
    contents = mergeContents({ src: contents, newSrc: SIGNING, tag: 'rnmt-release-signing', anchor: /signingConfigs\s*\{/, offset: 1, comment: '//' }).contents;
    contents = contents.replace(/(release\s*\{[^}]*?)signingConfig signingConfigs\.debug/, '$1signingConfig signingConfigs.release');
    c.modResults.contents = contents;
    return c;
  });

export default withAndroidReleaseSigning;
```
(Credentials come from `gradle.properties`/`-P` flags set by CI from secrets; the debug fallbacks keep local `expo run:android --variant release` working without secrets. `mergeContents` is idempotent via its tag comments. If the `@expo/config-plugins/build/utils/generateCode` import path differs in the installed version, use `require.resolve` to locate `generateCode` and adjust.)

`plugins/with-android-release-abis.ts`:
```ts
import { type ConfigPlugin, withGradleProperties } from 'expo/config-plugins';

export const withAndroidReleaseAbis: ConfigPlugin<{ abis?: string[] } | void> = (config, props) => {
  const abis = (props && props.abis) ?? ['armeabi-v7a', 'arm64-v8a'];
  return withGradleProperties(config, (c) => {
    const key = 'reactNativeArchitectures';
    const value = abis.join(',');
    const existing = c.modResults.find((p) => p.type === 'property' && p.key === key);
    if (existing && existing.type === 'property') existing.value = value;
    else c.modResults.push({ type: 'property', key, value });
    return c;
  });
};

export default withAndroidReleaseAbis;
```
Note: E2E debug builds on CI override this with `-PreactNativeArchitectures=x86_64` (Phase 2), which wins over `gradle.properties`.

Add to `app.config.ts` `plugins`: `['./plugins/with-build-stamp', { stamp: buildStamp }]`, `'./plugins/with-android-release-signing'`, `'./plugins/with-android-release-abis'`.

- [ ] **Step 4: Prebuild check script**

`scripts/check-prebuild.sh`:
```bash
#!/usr/bin/env bash
# Proves CNG works from a clean checkout and that config plugins produced
# their native output. Never touches ./ios or ./android.
set -euo pipefail
cd "$(dirname "$0")/.."
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
cp -R . "$tmp/app" 2>/dev/null || rsync -a --exclude node_modules --exclude ios --exclude android . "$tmp/app"
ln -s "$PWD/node_modules" "$tmp/app/node_modules"
(
  cd "$tmp/app"
  APP_VARIANT=production APP_VERSION=1.2.3 APP_BUILD_NUMBER=42 EXPO_NO_GIT_STATUS=1 pnpm exec expo prebuild --platform all --clean --no-install >/dev/null
  grep -q '<key>AppBuildStamp</key>' ios/*/Info.plist || { echo "iOS Info.plist lacks AppBuildStamp" >&2; exit 1; }
  grep -q 'ITSAppUsesNonExemptEncryption' ios/*/Info.plist || { echo "iOS Info.plist lacks ITSAppUsesNonExemptEncryption" >&2; exit 1; }
  grep -q 'android:name="AppBuildStamp"' android/app/src/main/AndroidManifest.xml || { echo "AndroidManifest lacks AppBuildStamp" >&2; exit 1; }
  grep -q 'ANDROID_UPLOAD_STORE_FILE' android/app/build.gradle || { echo "build.gradle lacks release signing config" >&2; exit 1; }
  grep -q '^reactNativeArchitectures=armeabi-v7a,arm64-v8a' android/gradle.properties || { echo "gradle.properties lacks arm-only ABIs" >&2; exit 1; }
  grep -q 'versionCode 42' android/app/build.gradle || { echo "versionCode not injected" >&2; exit 1; }
  grep -q '<string>1.2.3</string>' ios/*/Info.plist || { echo "CFBundleShortVersionString not injected" >&2; exit 1; }
)
echo "prebuild check passed"
```
`package.json`: `"check-prebuild": "bash scripts/check-prebuild.sh"`. Makefile: `check-prebuild: ## Prebuild both platforms into a temp dir and assert plugin output`.

- [ ] **Step 5: Run everything, then the simulator**

Run: `mise exec -- pnpm test && make check-code && make check-prebuild && make ios`
Expected: plugin tests 100%; prebuild check passes; on the simulator Settings shows `build-stamp:development-local-2026-09-06` (today's date), closing the plugin → native → JS → UI loop.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "feat(plugins): build-stamp, Android release signing and ABI config plugins with prebuild check

Claude-Session: https://claude.ai/code/session_01SpyYZEnJaLFih75JB4EQAW"
```

---

### Task 15: Splash, icons, font, deep links

**Files:**
- Create: `src/app/+native-intent.tsx`, `assets/fonts/Inter-Variable.ttf` (download from https://github.com/rsms/inter/releases, `Inter-Variable.ttf`, OFL licence noted in `assets/fonts/LICENSE.txt`)
- Modify: `app.config.ts`, `src/app/_layout.tsx`, `src/components/AppText.tsx`

**Interfaces:**
- Produces: `rnmt://details/42` and `https://<WEB_DOMAIN>/details/42` open the details route; legacy `/d/42` is rewritten by `+native-intent.tsx`; font loaded via `expo-font` config plugin.

- [ ] **Step 1: Install**

Run: `mise exec -- pnpm expo install expo-font expo-splash-screen`

- [ ] **Step 2: Configure**

`app.config.ts` additions: plugin `['expo-splash-screen', { image: './assets/splash-icon.png', imageWidth: 200, resizeMode: 'contain', backgroundColor: '#ffffff', dark: { backgroundColor: '#0b0b0f' } }]`, plugin `['expo-font', { fonts: ['./assets/fonts/Inter-Variable.ttf'] }]`; `ios.associatedDomains: webDomain ? [`applinks:${webDomain}`] : []` and `android.intentFilters` with `autoVerify: true` for `https://<webDomain>` when `EXPO_PUBLIC_WEB_DOMAIN` is set (read via `process.env.EXPO_PUBLIC_WEB_DOMAIN` in `app.config.ts`, it is public). Remove the top-level `splash` key (the plugin replaces it).

`src/app/+native-intent.tsx`:
```tsx
export function redirectSystemPath({ path }: { path: string; initial: boolean }) {
  const legacy = /^\/d\/(\w+)$/.exec(path);
  return legacy ? `/details/${legacy[1]}` : path;
}
```

`AppText`: `fontFamily: 'Inter-Variable'` in the base style.

- [ ] **Step 3: Verify**

Run: `make check-prebuild && make ios`, then `xcrun simctl openurl booted "rnmt://d/7"`
Expected: app opens Details with id `7`. `mise exec -- pnpm test` still green.

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "feat(app): splash, icon, bundled font and deep link handling

Claude-Session: https://claude.ai/code/session_01SpyYZEnJaLFih75JB4EQAW"
```

---

### Task 16: Maestro flows, local E2E scripts, Playwright web smoke

**Files:**
- Create: `.maestro/config.yaml`, `.maestro/flows/00-launch.yaml`, `.maestro/flows/home.yaml`, `.maestro/flows/details.yaml`, `.maestro/flows/settings.yaml`, `.maestro/flows/error-screen.yaml`, `.maestro/flows/deep-link.yaml`, `scripts/e2e/maestro-ios.sh`, `scripts/e2e/maestro-android.sh`, `scripts/e2e/wait-for-mock-api.sh`, `playwright.config.ts`, `e2e/web/smoke.spec.ts`
- Modify: `package.json`, `Makefile`, `docs/web-files.txt`, `.gitignore`

**Interfaces:**
- Produces: `make e2e-ios`, `make e2e-android`, `make e2e-web`; flows tagged `smoke`; every flow assumes the app is already launched once per run (`launchApp` only in `00-launch.yaml`, others use `stopApp: false` semantics via not relaunching).

- [ ] **Step 1: Maestro config and flows**

`.maestro/config.yaml`:
```yaml
flows:
  - flows/*.yaml
includeTags:
  - smoke
```

`.maestro/flows/00-launch.yaml`:
```yaml
appId: ${APP_ID}
tags: [smoke]
---
- launchApp:
    clearState: true
- assertVisible:
    id: home-screen
    timeout: 60000
```

`.maestro/flows/home.yaml`:
```yaml
appId: ${APP_ID}
tags: [smoke]
---
- tapOn:
    id: tab-home
- assertVisible:
    id: home-title
- assertVisible:
    text: 'Hello, world!'
    timeout: 20000
```

`.maestro/flows/details.yaml`:
```yaml
appId: ${APP_ID}
tags: [smoke]
---
- tapOn:
    id: home-open-details
- assertVisible:
    id: details-id
- assertVisible:
    text: '42'
- back
- assertVisible:
    id: home-screen
```

`.maestro/flows/settings.yaml`:
```yaml
appId: ${APP_ID}
tags: [smoke]
---
- tapOn:
    id: tab-settings
- assertVisible:
    id: settings-title
- assertVisible:
    text: 'Hello, Maestro from (Swift|Kotlin)'
- assertVisible:
    text: 'build-stamp:(development|production)-.*'
- tapOn:
    id: settings-lang-es
- assertVisible:
    text: 'Ajustes'
- tapOn:
    id: settings-lang-en
- tapOn:
    id: settings-theme-dark
- tapOn:
    id: settings-theme-system
```

`.maestro/flows/error-screen.yaml`:
```yaml
appId: ${APP_ID}
tags: [smoke]
---
- tapOn:
    id: tab-settings
- tapOn:
    id: settings-trigger-error
- assertVisible:
    id: error-screen
- tapOn:
    id: error-retry
- assertVisible:
    id: settings-screen
```

`.maestro/flows/deep-link.yaml`:
```yaml
appId: ${APP_ID}
tags: [smoke]
---
- openLink: rnmt://details/99
- assertVisible:
    text: '99'
- back
```

- [ ] **Step 2: Local scripts**

`scripts/e2e/wait-for-mock-api.sh`:
```bash
#!/usr/bin/env bash
set -euo pipefail
url="${1:-http://localhost:4000/graphql}"
for _ in $(seq 1 60); do
  if curl -fsS -H 'content-type: application/json' -d '{"query":"{ hello }"}' "$url" >/dev/null 2>&1; then exit 0; fi
  sleep 1
done
echo "mock API not reachable at $url (run: make mock-api)" >&2
exit 1
```

`scripts/e2e/maestro-ios.sh`:
```bash
#!/usr/bin/env bash
# Local iOS E2E: assumes `make ios` already installed the dev build on a booted
# simulator and Metro is running (make start). CI uses react-native-workflows.
set -euo pipefail
cd "$(dirname "$0")/../.."
bash scripts/e2e/wait-for-mock-api.sh
APP_ID="${APP_ID:-com.example.rnmt.dev}"
export MAESTRO_DRIVER_STARTUP_TIMEOUT="${MAESTRO_DRIVER_STARTUP_TIMEOUT:-120000}"
maestro test .maestro --config .maestro/config.yaml -e APP_ID="$APP_ID" --debug-output .maestro/output --flatten-debug-output "$@"
```
`scripts/e2e/maestro-android.sh`: identical except a preceding `adb reverse tcp:8081 tcp:8081 && adb reverse tcp:4000 tcp:4000`.

`package.json`: `"test:e2e:ios": "bash scripts/e2e/maestro-ios.sh"`, `"test:e2e:android": "bash scripts/e2e/maestro-android.sh"`. Makefile: `e2e-ios`, `e2e-android` targets with `## Maestro flows (needs: make mock-api, make ios/android, make start)`.

- [ ] **Step 3: Run the flows locally**

Run (three terminals): `make mock-api`; `make start`; then `make ios` once, then `make e2e-ios`.
Expected: 6 flows pass. If `tapOn id: tab-home` fails, inspect `maestro hierarchy` and align the tab `testID` prop name (Task 6 note).

- [ ] **Step 4: Playwright web smoke**

Run: `mise exec -- pnpm add -D @playwright/test@^1.63 && mise exec -- pnpm expo install react-dom react-native-web @expo/metro-runtime && mise exec -- pnpm exec playwright install chromium`

`playwright.config.ts` (first line `// WEB ONLY`):
```ts
// WEB ONLY
import { defineConfig } from '@playwright/test';

export default defineConfig({
  testDir: 'e2e/web',
  timeout: 30_000,
  use: { baseURL: 'http://localhost:8089' },
  webServer: [
    { command: 'pnpm mock-api', url: 'http://localhost:4000/graphql', reuseExistingServer: true, timeout: 30_000, stdout: 'ignore' },
    { command: 'pnpm exec expo serve dist --port 8089', url: 'http://localhost:8089', reuseExistingServer: false, timeout: 60_000 },
  ],
});
```
(`expo serve` serves a static export; the `webServer` list means `pnpm build:web` must run first: `"build:web": "expo export --platform web"`, and `"test:e2e:web": "pnpm build:web && playwright test"`. If the mock API's `POST` with `url` health-check fails for Playwright, use `scripts/e2e/wait-for-mock-api.sh` in a `globalSetup` instead.)

`e2e/web/smoke.spec.ts`:
```ts
import { expect, test } from '@playwright/test';

test('home renders and navigates to details', async ({ page }) => {
  await page.goto('/');
  await expect(page.getByTestId('home-title')).toBeVisible();
  await expect(page.getByTestId('home-hello')).toHaveText('Hello, world!');
  await page.getByTestId('home-open-details').click();
  await expect(page.getByTestId('details-id')).toHaveText('42');
});
```
Add `playwright.config.ts`, `e2e/web/`, `assets/favicon.png`, `src/features/settings/NativeDemoCard.web.tsx` to `docs/web-files.txt`. Makefile: `e2e-web: ## Export web + Playwright smoke` → `pnpm test:e2e:web`; `web` target already exists.

Run: `make e2e-web`
Expected: 1 passed. `testID` maps to `data-testid` on react-native-web, which is what `getByTestId` reads.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "test(e2e): Maestro smoke flows, local runners and Playwright web smoke

Claude-Session: https://claude.ai/code/session_01SpyYZEnJaLFih75JB4EQAW"
```

---

### Task 17: Remaining checks and the `make check` aggregate

**Files:**
- Create: `scripts/check-lockfile.sh`, `scripts/check-licenses.mjs`, `scripts/check-licenses.test.mjs`, `scripts/check-bundle-secrets.sh`, `scripts/check-docs.sh`, `scripts/shellcheck.sh`
- Modify: `package.json`, `Makefile`

**Interfaces:**
- Produces: `make check` = `check-code check-gen check-deps check-ci check-docs`; `make check-ci` = actionlint (no workflows yet, must not fail on an absent `.github/workflows`) + shellcheck.

- [ ] **Step 1: Failing test for the licence allowlist**

`scripts/check-licenses.test.mjs`:
```js
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { findViolations } from './check-licenses.mjs';

test('flags packages outside the allowlist and ignores allowed ones', () => {
  const report = { MIT: [{ name: 'a' }], 'GPL-3.0': [{ name: 'b' }], '(MIT OR Apache-2.0)': [{ name: 'c' }] };
  assert.deepEqual(findViolations(report), [{ name: 'b', license: 'GPL-3.0' }]);
});
```

- [ ] **Step 2: Implement the scripts**

`scripts/check-licenses.mjs`:
```js
#!/usr/bin/env node
// Allowlist check over `pnpm licenses list --json --prod`.
import { execSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const ALLOWED = ['MIT', 'Apache-2.0', 'BSD-2-Clause', 'BSD-3-Clause', 'ISC', '0BSD', 'CC0-1.0', 'Unlicense', 'MPL-2.0', 'CC-BY-4.0', 'Python-2.0', 'BlueOak-1.0.0'];

function licenseAllowed(expr) {
  return expr.replace(/[()]/g, '').split(/\s+(?:OR|AND)\s+/i).some((l) => ALLOWED.includes(l.trim()));
}

export function findViolations(report) {
  const out = [];
  for (const [license, pkgs] of Object.entries(report)) {
    if (licenseAllowed(license)) continue;
    for (const p of pkgs) out.push({ name: p.name, license });
  }
  return out;
}

if (process.argv[1] && fileURLToPath(import.meta.url) === path.resolve(process.argv[1])) {
  const report = JSON.parse(execSync('pnpm licenses list --json --prod', { encoding: 'utf8' }));
  const violations = findViolations(report);
  if (violations.length) {
    for (const v of violations) console.error(`disallowed license ${v.license}: ${v.name}`);
    process.exit(1);
  }
  console.log('licenses ok');
}
```

`scripts/check-lockfile.sh`:
```bash
#!/usr/bin/env bash
# Every resolved package must come from the npm registry with an integrity hash.
set -euo pipefail
cd "$(dirname "$0")/.."
if grep -nE '^\s+(tarball|resolution): .*(git\+|github:|http://)' pnpm-lock.yaml; then
  echo "pnpm-lock.yaml contains non-registry sources" >&2; exit 1
fi
if grep -nE "resolution: \{tarball: " pnpm-lock.yaml | grep -v 'registry.npmjs.org'; then
  echo "pnpm-lock.yaml contains tarballs outside registry.npmjs.org" >&2; exit 1
fi
echo "lockfile ok"
```

`scripts/check-bundle-secrets.sh`:
```bash
#!/usr/bin/env bash
# Exports the iOS bundle and greps it for names of non-public env keys and
# common secret shapes. Fails on any hit.
set -euo pipefail
cd "$(dirname "$0")/.."
out="$(mktemp -d)"; trap 'rm -rf "$out"' EXIT
pnpm exec expo export --platform ios --output-dir "$out" >/dev/null
bundle="$(find "$out" -name '*.hbc' -o -name '*.js' | head -1)"
keys="$(grep -oE '^[A-Z_]+=' .env.example | tr -d '=' | grep -vE '^EXPO_PUBLIC_' || true)"
status=0
for k in $keys; do
  if strings "$bundle" | grep -q "$k"; then echo "non-public key name '$k' found in bundle" >&2; status=1; fi
done
if strings "$bundle" | grep -qE 'sk_live_|-----BEGIN (RSA |EC )?PRIVATE KEY|AIza[0-9A-Za-z_-]{30,}'; then
  echo "secret-shaped string found in bundle" >&2; status=1
fi
[ $status -eq 0 ] && echo "bundle secrets check ok"
exit $status
```

`scripts/check-docs.sh`:
```bash
#!/usr/bin/env bash
# Warns (exit 0) when architecture-relevant paths changed vs origin/main
# without a docs/ change; fails when AGENTS.md's command table lists a make
# target that does not exist.
set -euo pipefail
cd "$(dirname "$0")/.."
if git rev-parse --verify origin/main >/dev/null 2>&1; then
  changed="$(git diff --name-only origin/main...HEAD || true)"
  if echo "$changed" | grep -qE '^(app\.config\.ts|plugins/|modules/|src/graphql/|scripts/|Makefile)' && ! echo "$changed" | grep -q '^docs/'; then
    echo "warning: architecture-relevant changes without a docs/ update" >&2
  fi
fi
if [ -f AGENTS.md ]; then
  for t in $(grep -oE '`make [a-z-]+`' AGENTS.md | sed -E 's/`make ([a-z-]+)`/\1/' | sort -u); do
    grep -qE "^$t:" Makefile || { echo "AGENTS.md references missing make target: $t" >&2; exit 1; }
  done
fi
echo "docs check ok"
```

`scripts/shellcheck.sh`:
```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
shellcheck -x scripts/*.sh scripts/*/*.sh
```

- [ ] **Step 3: Wire scripts and Makefile**

`package.json`: `"deps:check": "expo install --check && expo-doctor"`, `"deps:audit": "pnpm audit --audit-level=high --prod && bash scripts/check-lockfile.sh"`, `"deps:licenses": "node scripts/check-licenses.mjs"`, `"check-bundle-secrets": "bash scripts/check-bundle-secrets.sh"`. Install `expo-doctor` as a devDependency: `pnpm add -D expo-doctor`.

Makefile:
```makefile
check-deps: ## SDK drift, vulnerability audit, lockfile provenance, licenses
	pnpm deps:check
	pnpm deps:audit
	pnpm deps:licenses

check-ci: ## Lint the CI itself: actionlint (workflows) + shellcheck (scripts)
	bash scripts/shellcheck.sh
	@if [ -d .github/workflows ]; then actionlint; else echo "no workflows yet"; fi

check-docs: ## Docs freshness + AGENTS.md command table
	bash scripts/check-docs.sh

bundle-secrets-check: ## Export the bundle and assert no non-public keys leaked
	pnpm check-bundle-secrets

check: check-code check-gen check-deps check-ci check-docs ## Every static gate CI runs (no tests/builds)
```
Add all to `.PHONY`. Also `test-scripts: ## node:test for scripts/*.test.mjs` → `pnpm test:scripts`, included in `unit` (`unit: ## ...` runs `pnpm test && pnpm test:scripts`).

- [ ] **Step 4: Run the whole gate**

Run: `chmod +x scripts/*.sh scripts/e2e/*.sh && make check && make unit && make bundle-secrets-check`
Expected: every gate green. `expo-doctor` may flag `minimumReleaseAge`-blocked versions or missing `expo-dev-client` config; resolve by the tool's own advice, not by disabling the check. `pnpm audit` failures on transitive advisories: add an entry under `pnpm.auditConfig.ignoreCves` in `package.json` with a `//` comment key explaining why.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "chore(tooling): lockfile, license, bundle-secret and docs checks; make check aggregate

Claude-Session: https://claude.ai/code/session_01SpyYZEnJaLFih75JB4EQAW"
```

---

### Task 18: Phase 1 acceptance run

**Files:** none new. Modify: `docs/superpowers/plans/2026-09-06-phase-1-template-scaffold.md` (tick boxes), `README.md` (minimal placeholder so the repo is not headless; the real README is Phase 4).

- [x] **Step 1: Minimal README**

```markdown
# react-native-mobile-template

Expo SDK 57 store-app template (work in progress; see docs/superpowers/).

    mise install && make doctor && make install
    make mock-api &     # terminal 1
    make start &        # terminal 2
    make ios            # or: make android
    make check && make unit
```

- [x] **Step 2: Fresh-clone verification**

Run:
```bash
rm -rf /tmp/rnmt-verify && git clone -q /Users/jonas/Dev/blink/react-native-mobile-template /tmp/rnmt-verify && cd /tmp/rnmt-verify
mise trust && mise install && make doctor && make install && make check && make unit && make check-prebuild
```
Expected: every command exits 0 on a clean clone (no reliance on files ignored by git). Record the exact output tail of each gate in the task summary.

- [x] **Step 3: Simulator and E2E verification (from the main checkout)**

Run: `make mock-api` and `make start` in the background, `make ios`, then `make e2e-ios`, then `make e2e-web`. If an Android emulator is available (`emulator -list-avds`), also `make android` and `make e2e-android`.
Expected: all Maestro flows pass on iOS (Android too when available); Playwright smoke passes. Note any skipped platform explicitly.

- [x] **Step 4: Coverage check**

Run: `make coverage`
Expected: thresholds met (global 80/80, 100/100 for config, lib, modules index, plugins). The `coverage/` directory is git-ignored.

- [x] **Step 5: Commit and tag the phase**

```bash
git add -A
git commit -m "docs(app): placeholder README and phase 1 acceptance

Claude-Session: https://claude.ai/code/session_01SpyYZEnJaLFih75JB4EQAW"
git tag phase-1-scaffold
```

---

## Self-review notes (done while writing)

- Spec coverage (Part C + Phase 1): dev env (T1, T2), quality tooling (T3, T4, T17), router (T6), theme (T7), i18n (T8; compiled catalogs instead of metro transformer, recorded deviation), env/config (T9), lib layer (T10), GraphQL + mock API + codegen (T11), auth/updates/dev menu/error boundary (T12), native module (T13), plugins incl. Android release signing/ABIs (T14), assets + deep links (T15), Maestro + local scripts + Playwright (T16), `make check` aggregate + remaining scripts (T17), acceptance (T18). Not in this phase by design: `.github/`, `AGENTS.md`, `CONTRIBUTING.md`, ADRs, `make init`, fastlane, release scripts, OTA server (Phases 2 to 4).
- Type consistency: `renderWithProviders`/`Providers` (T5, used T8, T11, T12); `secureStore`/`SecureKey` (T10, used T11, T12); `constants` (T9, used T12, T13); `updates.switchChannel(channel)` (T12); `hello`/`getBuildStamp`/`HelloNativeError` (T13, used T13 card); `withBuildStamp({ stamp })` (T14, wired T9's `app.config.ts`); `testID`s used by Maestro (T16) are exactly the ones defined in T6, T12, T13.
- Known judgement calls the implementer may need to adjust against installed versions: Apollo 4 `ErrorLink` payload shape, `@expo/config-plugins` `generateCode` import path, knip plugin keys, `tabBarTestID` vs `tabBarButtonTestID`, jest-expo's Jest major, Node `fetch` under jest-expo for MSW. Each is called out inline where it occurs.

## Rulings recorded during execution (2026-09-06)

- **`src/app` import rule narrowed.** The Global Constraint "files under `src/app/` import only from `src/features/` and `src/components/`" is unachievable for the root layout, which must compose providers. Binding rule: route files other than `src/app/_layout.tsx` and `src/app/+native-intent.tsx` may not import `src/graphql`, `src/services`, `src/lib` or `@apollo/client` (alias or relative). Biome enforces it (`biome.json` `src/app/**` override).
- **knip runs in default mode**, not `--strict`: production mode needs `!`-marked patterns and then flags test-only exports.
- **Lingui catalogs are compiled to TypeScript** (`lingui compile`) and committed; no Metro transformer.
- **Coverage thresholds unchanged**; the global figure excludes per-path-threshold files (Jest semantics).
- **Tag** for the phase is `phase-1-complete` (a tag named like the branch made refs ambiguous).
- **Bootstrap lesson:** never `cp -R generated/. .` into a repo; it copies the generator's `.git`. Use `rsync -a --exclude .git`.
- **Post-merge finding (2026-09-06):** the lefthook `post-merge`/`post-checkout` install commands use `HEAD@{1}`; lefthook strips the braces and git reports `fatal: ambiguous argument 'HEAD@0'` (the hook still exits 0). Fix in Phase 4: use `ORIG_HEAD`/`{1}` via a script instead of inline shell.

# Security Verdict Badge Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Publish the security verdict as a fourth per-branch badge, through the same render-then-publish path as Unit, E2E and Coverage, so the badge shows the verdict's own word rather than the Security job's pass/fail.

**Architecture:** The template's `verdict.mjs` writes `.security/verdict.json`, one line of JSON: `{"verdict","highest","canBlock"}`. In shared-workflows, a new step in `check-security.yml`'s Verdict job turns that file into a job output, and the workflow exposes it as the `verdict` output. The template's `ci.yml` passes it to `publish-badges.yml` as `security-verdict`, which hands it to the template's render script as `BADGE_SECURITY`. When there is no verdict, no `security.svg` is rendered, and `publish-badges.sh` already copies only what was rendered, so the published badge stays.

**Tech Stack:** Node `node:test` (template `scripts/`), bats (shared-workflows `test/`), GitHub Actions reusable workflows.

**Spec:** No separate spec file. The design was agreed in conversation on 2026-09-28 and is written down in "Design" below. Executors read that section first.

**Repositories:**
- Template: `blinkbitcoin/react-native-mobile-template` (this checkout).
- Workflows: `blinkbitcoin/shared-workflows`. Local clone at `~/Dev/blink/shared-workflows`; make a fresh worktree off `origin/main` for this work.

---

## Design

Why each piece exists, so an executor can judge edge cases:

1. **The badge uses the verdict's word, never `needs.security.result`.** The job exits 0 for `pass`, `informational` and `skipped` alike. A badge built from the job result would show green for a run where every scanner skipped. `verdict.mjs` exists to prevent exactly that.
2. **`publish-badges.yml` is the only publisher.** It is the only job in the family with `contents: write` on `gh-pages`. The Verdict job does not publish its own badge.
3. **The file comes first, the output second.** `verdict.mjs` writes `verdict.json` on a laptop too, so `make check-security && make gen-badges` renders the same badge CI would.
4. **The output is set in its own step, after the Verdict step.** The Verdict step exits 1 when findings block. A separate step (`if: !cancelled()`) that reads the file avoids depending on whether GitHub keeps outputs written by a step that failed.
5. **Badge words:**

   | verdict.json / input | Message | Colour |
   |---|---|---|
   | `pass` | `passing` | brightgreen |
   | `informational`, highest low/medium | `<highest> findings` | yellow |
   | `informational`, highest high/critical | `<highest> findings` | orange |
   | `skipped` | `skipped` | lightgrey |
   | `fail` | `failing` | red |
   | `disabled` | `disabled` | lightgrey |
   | `canBlock: false` on `pass` or `informational` | the message plus ` (advisory)` | as above |
   | empty | no badge rendered; the published one stays | — |

6. **Where each case comes from:**

   | Case | Value `ci.yml` passes |
   |---|---|
   | Verdict ran | the file's JSON |
   | a scanner job failed (crashed) | `{"verdict":"fail"}`, even if the file says pass |
   | the Verdict step failed with no file (no SARIF, no node, merge crashed) | `{"verdict":"fail"}` |
   | the Verdict step succeeded with no file (a consumer older than this change) | nothing |
   | `security-policy.json` has `"enabled": false` | `{"verdict":"disabled"}` (from `check-security.yml`) |
   | the configuration job failed | `{"verdict":"fail"}` (from `check-security.yml`) |
   | `SECURITY_ENABLED=false` on the repository | `{"verdict":"disabled"}` (from `ci.yml`) |
   | docs-only change (Security skipped) | nothing: the published badge stays |
   | Security cancelled | the badges job skips, like any cancelled upstream job |

7. **`canBlock`** is `severity != 'none' && failOn.length > 0`. Either setting alone makes the gate advisory.

## Global Constraints

- No vague abbreviations in identifiers, comments, commit messages or docs (template `AGENTS.md`).
- Conventional commits. Template scopes: `app ui i18n graphql native plugins config tooling ci release deps deps-dev docs e2e web`. Shared-workflows: read its `commitlint.config.*` for its scope list.
- Template: every `scripts/**/*.mjs` has its own sibling test covering it at 100% alone (`node --test --experimental-test-coverage --test-coverage-include=<file>.mjs <file>.test.mjs`).
- Template: docs and diagrams change in the same PR as the code (`docs/ci.md`, `docs/security.md`, `README.md`, `AGENTS.md`).
- Template: shell code writes `env LC_ALL=C cmd`, never `LC_ALL=C cmd`.
- Shared-workflows: every bats assertion ends in `|| fail "..."` (`test/test_helper.bash`).
- Shared-workflows: after changing a workflow's `workflow_call` interface, re-render `packages/dev-config/interfaces.json` with `bash scripts/self/render-interfaces.sh`.
- Every template workflow call stays pinned to one shared-workflows commit SHA, and `@blinkbitcoin/dev-config` sits at that same commit (`make fix-tooling-pin`).

## Review Focus

1. **Unrecognised verdict JSON**, for example a newer workflows repository sending a word this template does not know: the render fails loudly with `BadgeError` and the Badges job goes red. Never a silently green badge. Pinned in Task 2.
2. **`severity: "none"` with a non-empty `failOn`:** nothing can block, so the badge must say `(advisory)`. Pinned in Task 1 (`canBlock`) and Task 2.
3. **A docs-only change while Unit publishes:** the security badge must stay as it was, not turn grey. Pinned in Task 2 (no input, no file) and Task 5 (gate evaluation).
4. **A scanner job crashed while the merged verdict says pass:** the badge must read `failing`. Pinned in Task 3.
5. **An older consumer (no `verdict.json`) on the new workflows:** no output at all, never a false `failing`. Pinned in Task 3.

---

## Part A: template, safe to merge on its own (nothing reads the file yet)

### Task 1: `verdict.mjs` writes `.security/verdict.json`

**Files:**
- Modify: `scripts/security/verdict.mjs` (`verdict()` return value, `main()`)
- Test: `scripts/security/verdict.test.mjs`
- Modify: `docs/security.md` (new subsection "Where the verdict goes")

**Interfaces:**
- Produces: `verdict()` also returns `canBlock: boolean`. `export const VERDICT_FILE = 'verdict.json'`. `main(argv, { log, error, env, readEntries, writeVerdict })`, where `writeVerdict(dir, outcome)` defaults to writing `<dir>/verdict.json` as `{"verdict":string,"highest":string,"canBlock":boolean}\n`. A write failure returns exit code 2.

- [ ] **Step 1: Write the failing tests** (append to `verdict.test.mjs`; add `readFileSync` to the `node:fs` import)

```js
test('canBlock says whether anything in this run could have failed it', () => {
  const entries = [entry('deps', doc('osv-scanner', []))];
  assert.equal(verdict({ entries, severity: 'high', failOn: ['deterministic'] }).canBlock, true);
  assert.equal(verdict({ entries, severity: 'high', failOn: [] }).canBlock, false);
  assert.equal(verdict({ entries, severity: 'none', failOn: ['deterministic'] }).canBlock, false);
});

test('the CLI hands the verdict file its word, highest severity and canBlock', () => {
  const written = [];
  const code = main(['.security'], {
    log: () => {},
    error: () => {},
    env: { SECURITY_SEVERITY: 'high', SECURITY_FAIL_ON: 'deterministic' },
    readEntries: () => [entry('deps', doc('osv-scanner', [result('critical')]))],
    writeVerdict: (dir, outcome) => written.push({ dir, outcome }),
  });
  assert.equal(code, 1);
  assert.equal(written.length, 1);
  assert.equal(written[0].dir, '.security');
  assert.equal(written[0].outcome.verdict, 'fail');
  assert.equal(written[0].outcome.highest, 'critical');
  assert.equal(written[0].outcome.canBlock, true);
});

test('a verdict file that cannot be written exits 2 and names the file', () => {
  const out = [];
  const code = main(['.security'], {
    log: () => {},
    error: (l) => out.push(l),
    env: {},
    readEntries: () => [entry('deps', doc('osv-scanner', []))],
    writeVerdict: () => {
      throw new Error('EROFS');
    },
  });
  assert.equal(code, 2);
  assert.match(out[0], /verdict\.json: could not be written \(EROFS\)/);
});
```

In the existing test `'the real directory reader lists *.sarif files and parses them'`, add this after the `security: fail` assertion. It covers the default writer through the real path:

```js
    assert.deepEqual(JSON.parse(readFileSync(path.join(dir, 'verdict.json'), 'utf8')), {
      verdict: 'fail',
      highest: 'critical',
      canBlock: true,
    });
```

Pass `writeVerdict: () => {}` to every existing `main()` call that injects `readEntries` and reaches the verdict: `'the CLI prints the summary and returns the exit code'` and `'the CLI prints annotations on a runner only'`. Otherwise they write into the checkout's `.security/`.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `node --test scripts/security/verdict.test.mjs`
Expected: FAIL. `canBlock` is `undefined`, `writeVerdict` is never called, and `verdict.json` does not exist.

- [ ] **Step 3: Implement**

In `verdict()`, before the `return`:

```js
  // Whether anything in this run could have failed it. The badge says
  // "(advisory)" when not, so a clean advisory run never reads as a pass that
  // was checked against a threshold.
  const canBlock = floor >= 0 && failOn.length > 0;
```

and add `canBlock,` to the returned object after `suppressed,`.

Above `read`, add (and import `writeFileSync` from `node:fs`):

```js
/** The file the badge reads, next to the SARIF it summarises. */
export const VERDICT_FILE = 'verdict.json';

// One line: shared-workflows' verdict-output.sh copies it into a step output
// as it is, and a step output is one line.
const writeVerdictFile = (dir, outcome) =>
  writeFileSync(
    path.join(dir, VERDICT_FILE),
    `${JSON.stringify({ verdict: outcome.verdict, highest: outcome.highest, canBlock: outcome.canBlock })}\n`,
  );
```

In `main`, add `writeVerdict = writeVerdictFile` to the injected options, and replace `return outcome.exitCode;` with:

```js
  // A verdict nobody can read is not a pass: CI would publish nothing, or a
  // stale badge. Exit 2, the same code as a SARIF file that cannot be read.
  try {
    writeVerdict(dir, outcome);
  } catch (err) {
    error(`${path.join(dir, VERDICT_FILE)}: could not be written (${err.message})`);
    return 2;
  }
  return outcome.exitCode;
```

- [ ] **Step 4: Run the tests to verify they pass, alone and at 100%**

Run: `node --test --experimental-test-coverage --test-coverage-include=scripts/security/verdict.mjs scripts/security/verdict.test.mjs`
Expected: PASS, and 100% lines, branches and functions for `verdict.mjs`. If an existing test `deepEqual`s a whole `verdict()` result, add `canBlock` to its expectation.

- [ ] **Step 5: Document it.** In `docs/security.md`, near the paragraph about `verdict.mjs` printing annotations, add a subsection "Where the verdict goes" listing each destination: the step log and run summary (`verdict.sh`), pull-request annotations (runner only), code scanning (default branch only), and `.security/verdict.json` (the Security badge, via `check-security.yml`'s `verdict` output; see `docs/ci.md#badges`). Show the file's shape and what `canBlock` means.

- [ ] **Step 6: Commit**

```bash
git add scripts/security/verdict.mjs scripts/security/verdict.test.mjs docs/security.md
git commit -m "feat(tooling): write the security verdict to .security/verdict.json"
```

### Task 2: render the Security badge

**Files:**
- Modify: `scripts/badges/badge.mjs` (add `SECURITY_VERDICTS`, `securityBadgeFor`)
- Test: `scripts/badges/badge.test.mjs`
- Create: `scripts/badges/security-badge.mjs`
- Create: `scripts/badges/security-badge.test.mjs`
- Modify: `scripts/badges/render.mjs`, `scripts/badges/render.test.mjs`
- Modify: `Makefile` (`gen-badges`), `AGENTS.md` (the `gen-badges` row, if its description changes)

**Interfaces:**
- Consumes: the `verdict.json` shape from Task 1.
- Produces: `securityBadgeFor(raw: string, label = 'Security') -> { label, message, color }`, which throws `BadgeError` on anything unrecognised. `writeSecurityBadge({ outDir = BADGE_DIR, label = 'Security', verdict: string }) -> badge`, which writes `security.svg` and `security.json`. `renderBadges(env)` reads `BADGE_SECURITY` and `BADGE_SECURITY_LABEL`.

- [ ] **Step 1: Write the failing tests for the pure mapping** (`badge.test.mjs`; add `securityBadgeFor` to its import)

```js
describe('securityBadgeFor', () => {
  const badge = (value) => securityBadgeFor(JSON.stringify(value));

  test('each verdict word has its own message and colour', () => {
    assert.deepEqual(badge({ verdict: 'pass', highest: 'none', canBlock: true }), {
      label: 'Security',
      message: 'passing',
      color: 'brightgreen',
    });
    assert.equal(badge({ verdict: 'fail', highest: 'high', canBlock: true }).color, 'red');
    assert.equal(badge({ verdict: 'fail', highest: 'high', canBlock: true }).message, 'failing');
    assert.equal(badge({ verdict: 'skipped', highest: 'none', canBlock: true }).message, 'skipped');
    assert.equal(badge({ verdict: 'disabled' }).message, 'disabled');
    assert.equal(badge({ verdict: 'disabled' }).color, 'lightgrey');
  });

  test('informational names its highest severity, orange from high up', () => {
    assert.deepEqual(badge({ verdict: 'informational', highest: 'medium', canBlock: true }), {
      label: 'Security',
      message: 'medium findings',
      color: 'yellow',
    });
    assert.equal(badge({ verdict: 'informational', highest: 'low', canBlock: true }).color, 'yellow');
    assert.equal(badge({ verdict: 'informational', highest: 'high', canBlock: true }).color, 'orange');
    assert.equal(
      badge({ verdict: 'informational', highest: 'critical', canBlock: true }).color,
      'orange',
    );
  });

  test('a run where nothing could block says so', () => {
    assert.equal(
      badge({ verdict: 'pass', highest: 'none', canBlock: false }).message,
      'passing (advisory)',
    );
    assert.equal(
      badge({ verdict: 'informational', highest: 'medium', canBlock: false }).message,
      'medium findings (advisory)',
    );
    assert.equal(badge({ verdict: 'skipped', highest: 'none', canBlock: false }).message, 'skipped');
  });

  test('the label can be changed', () => {
    assert.equal(securityBadgeFor('{"verdict":"pass"}', 'Scan').label, 'Scan');
  });

  test('anything it does not recognise throws rather than render green', () => {
    for (const raw of [
      'not json',
      '"pass"',
      'null',
      '{"verdict":"passed"}',
      '{"verdict":"informational","highest":"none"}',
      '{"verdict":"informational"}',
    ]) {
      assert.throws(() => securityBadgeFor(raw), BadgeError, raw);
    }
  });
});
```

- [ ] **Step 2: Run to verify it fails**

Run: `node --test scripts/badges/badge.test.mjs`
Expected: FAIL. `securityBadgeFor` is not exported.

- [ ] **Step 3: Implement in `badge.mjs`** (after `STATUS_RESULTS`)

```js
// The security verdict's words (scripts/security/verdict.mjs) -> badge
// text/colour, plus `disabled`, which check-security.yml and ci.yml send when
// the gate is switched off. `informational` takes its message from the highest
// severity instead. Anything else throws, like STATUS_RESULTS.
export const SECURITY_VERDICTS = {
  pass: { message: 'passing', color: 'brightgreen' },
  informational: { message: null, color: 'yellow' },
  skipped: { message: 'skipped', color: 'lightgrey' },
  fail: { message: 'failing', color: 'red' },
  disabled: { message: 'disabled', color: 'lightgrey' },
};

const FINDING_SEVERITIES = ['low', 'medium', 'high', 'critical'];

/** check-security.yml's verdict output (one line of JSON) -> the badge. */
export function securityBadgeFor(raw, label = 'Security') {
  let value;
  try {
    value = JSON.parse(raw);
  } catch {
    throw new BadgeError(`security badge: the verdict is not JSON: ${raw}`);
  }
  const known = SECURITY_VERDICTS[value?.verdict];
  if (!known) {
    throw new BadgeError(
      `security badge: unknown verdict in ${raw} — expected one of ${Object.keys(SECURITY_VERDICTS).join(', ')}`,
    );
  }
  let { message, color } = known;
  if (value.verdict === 'informational') {
    if (!FINDING_SEVERITIES.includes(value.highest)) {
      throw new BadgeError(`security badge: informational needs a finding severity, got ${raw}`);
    }
    message = `${value.highest} findings`;
    if (value.highest === 'high' || value.highest === 'critical') color = 'orange';
  }
  // Only a result that reads as fine gets the note: a skipped run already
  // says it checked nothing, and `fail` cannot happen when nothing can block.
  if (value.canBlock === false && (value.verdict === 'pass' || value.verdict === 'informational')) {
    message += ' (advisory)';
  }
  return { label, message, color };
}
```

- [ ] **Step 4: Run to verify it passes at 100% alone**

Run: `node --test --experimental-test-coverage --test-coverage-include=scripts/badges/badge.mjs scripts/badges/badge.test.mjs`
Expected: PASS, 100%.

- [ ] **Step 5: Write the failing test for the writer** (`scripts/badges/security-badge.test.mjs`)

```js
import assert from 'node:assert/strict';
import { mkdtempSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { after, test } from 'node:test';
import { BadgeError, COLORS } from './badge.mjs';
import { writeSecurityBadge } from './security-badge.mjs';

const tmp = mkdtempSync(path.join(tmpdir(), 'security-badge-'));
after(() => rmSync(tmp, { recursive: true, force: true }));

test('writes security.svg and security.json from the verdict', () => {
  const outDir = path.join(tmp, 'a');
  const badge = writeSecurityBadge({ outDir, verdict: '{"verdict":"fail","highest":"high","canBlock":true}' });
  assert.deepEqual(badge, { label: 'Security', message: 'failing', color: 'red' });
  assert.ok(readFileSync(path.join(outDir, 'security.svg'), 'utf8').includes(COLORS.red));
  assert.equal(JSON.parse(readFileSync(path.join(outDir, 'security.json'), 'utf8')).message, 'failing');
});

test('takes a label', () => {
  const badge = writeSecurityBadge({ outDir: path.join(tmp, 'b'), label: 'Scan', verdict: '{"verdict":"pass"}' });
  assert.equal(badge.label, 'Scan');
});

test('an unrecognised verdict writes nothing', () => {
  const outDir = path.join(tmp, 'c');
  assert.throws(() => writeSecurityBadge({ outDir, verdict: '{"verdict":"nope"}' }), BadgeError);
  assert.throws(() => readFileSync(path.join(outDir, 'security.svg')));
});
```

- [ ] **Step 6: Run to verify it fails**

Run: `node --test scripts/badges/security-badge.test.mjs`
Expected: FAIL. The module does not exist.

- [ ] **Step 7: Implement `scripts/badges/security-badge.mjs`**

```js
import { mkdirSync, writeFileSync } from 'node:fs';
import path from 'node:path';
import { renderBadgeJson, renderBadgeSvg, securityBadgeFor } from './badge.mjs';
import { BADGE_DIR } from './coverage-badge.mjs';

/** Write `security.svg` + `security.json` into `outDir`; returns the badge. */
export function writeSecurityBadge({ outDir = BADGE_DIR, label = 'Security', verdict }) {
  // Parsed before anything touches the disk, so a bad verdict leaves no file.
  const badge = securityBadgeFor(verdict, label);
  mkdirSync(outDir, { recursive: true });
  writeFileSync(path.join(outDir, 'security.svg'), renderBadgeSvg(badge));
  writeFileSync(path.join(outDir, 'security.json'), renderBadgeJson(badge));
  return badge;
}
```

- [ ] **Step 8: Run to verify it passes at 100% alone**

Run: `node --test --experimental-test-coverage --test-coverage-include=scripts/badges/security-badge.mjs scripts/badges/security-badge.test.mjs`
Expected: PASS, 100%. The `outDir` default is a branch: if coverage flags it, add a test that runs with `process.chdir` into a temporary directory and no `outDir`, then checks `coverage/badge/security.svg`.

- [ ] **Step 9: Write the failing render tests** (append inside `describe('renderBadges', ...)` in `render.test.mjs`)

```js
  test('a security verdict renders security.svg after the suites', () => {
    const dir = outDir();
    const written = renderBadges({
      BADGE_OUT_DIR: dir,
      BADGE_UNIT: 'skipped',
      BADGE_E2E: 'skipped',
      BADGE_SECURITY: '{"verdict":"informational","highest":"medium","canBlock":true}',
    });
    assert.deepEqual(written, ['unit.svg', 'e2e.svg', 'security.svg']);
    assert.ok(readFileSync(path.join(dir, 'security.svg'), 'utf8').includes('medium findings'));
  });

  test('BADGE_SECURITY_LABEL renames the security badge', () => {
    const dir = outDir();
    renderBadges({
      BADGE_OUT_DIR: dir,
      BADGE_UNIT: 'skipped',
      BADGE_E2E: 'skipped',
      BADGE_SECURITY: '{"verdict":"pass","highest":"none","canBlock":true}',
      BADGE_SECURITY_LABEL: 'Scan',
    });
    assert.ok(readFileSync(path.join(dir, 'security.svg'), 'utf8').includes('Scan'));
  });

  test('no security verdict writes no security badge, so publishing leaves it alone', () => {
    const dir = outDir();
    const written = renderBadges({ BADGE_OUT_DIR: dir, BADGE_UNIT: 'skipped', BADGE_E2E: 'skipped' });
    assert.ok(!written.includes('security.svg'));
    assert.throws(() => readFileSync(path.join(dir, 'security.svg')));
  });
```

And in the `main` tests, one case where `BADGE_SECURITY: '{"verdict":"nope"}'` makes `renderMain` return 1 and print the `BadgeError` message (mirror the existing `main` error test).

- [ ] **Step 10: Run to verify it fails**

Run: `node --test scripts/badges/render.test.mjs`
Expected: FAIL. `security.svg` is never written.

- [ ] **Step 11: Implement in `render.mjs`** (import `writeSecurityBadge` from `./security-badge.mjs`; add after the status loop, before `return written;`)

```js
  // check-security.yml's verdict output, passed on by publish-badges.yml. No
  // verdict (a docs-only change skipped Security) renders nothing, and
  // publish-badges.sh copies only what was rendered, so the published badge stays.
  const security = env.BADGE_SECURITY || '';
  if (security) {
    const badge = writeSecurityBadge({
      outDir,
      label: env.BADGE_SECURITY_LABEL || 'Security',
      verdict: security,
    });
    console.log(`badges: ${badge.label} ${badge.message}`);
    written.push('security.svg');
  } else {
    console.log('badges: no security verdict — leaving the published one');
  }
```

- [ ] **Step 12: Run to verify it passes at 100% alone**

Run: `node --test --experimental-test-coverage --test-coverage-include=scripts/badges/render.mjs scripts/badges/render.test.mjs`
Expected: PASS, 100%.

- [ ] **Step 13: Let `make gen-badges` pick up a local verdict.** In the `Makefile`, change the recipe and its comment:

```make
# Same entry point CI calls, so what you see locally is what gh-pages gets.
# The job results default to success here; set BADGE_UNIT/BADGE_E2E to any of
# success|failure|cancelled|skipped to see the other colours. The Security
# badge reads .security/verdict.json from the last make check-security; set
# BADGE_SECURITY to a verdict line to try another, or to empty for none.
gen-badges: ## Render the CI badges into coverage/badge/ (run make test-coverage first, make check-security for Security)
	@BADGE_UNIT="$${BADGE_UNIT:-success}" BADGE_E2E="$${BADGE_E2E:-success}" \
		BADGE_SECURITY="$${BADGE_SECURITY-$$(cat .security/verdict.json 2>/dev/null)}" pnpm badges:render
```

Update the `gen-badges` row in `AGENTS.md` to: ``Render the CI badges into `coverage/badge/` (after `make test-coverage`; Security after `make check-security`)``.

- [ ] **Step 14: Verify**

Run: `make test-scripts && make check-docs`
Expected: both pass. `scripts/test-siblings.test.mjs` accepts the new `security-badge.mjs` because its sibling test exists.

Then: `make check-security-policy && make gen-badges` and open `coverage/badge/security.svg`.
Expected: a badge matching the printed `security:` line.

- [ ] **Step 15: Commit**

```bash
git add scripts/badges Makefile AGENTS.md
git commit -m "feat(tooling): render a Security badge from the verdict"
```

**Open the Part A PR here.** It is independent: nothing in CI sets `BADGE_SECURITY` yet. The PR description names the tests from Tasks 1 and 2 and the docs updated (`docs/security.md`, `AGENTS.md`).

---

## Part B: shared-workflows

Work in a fresh worktree of `~/Dev/blink/shared-workflows` off `origin/main`, on a branch such as `feat/security-verdict-output`.

### Task 3: the Verdict job exposes the verdict as an output

**Files:**
- Create: `scripts/security/verdict-output.sh`
- Create: `test/verdict-output.bats`
- Modify: `.github/workflows/check-security.yml` (the `verdict` job: `outputs:`, a step after `Verdict`; `on.workflow_call.outputs`)
- Modify: `packages/dev-config/interfaces.json` (re-rendered)
- Modify: `docs/consumer-guide.md` (the `check-security.yml` section: an Outputs paragraph)

**Interfaces:**
- Consumes: `<consumer>/${SECURITY_DIR:-.security}/verdict.json` (Task 1). Environment: `SCANNER_FAILED` (`true`/`false`) and `VERDICT_OUTCOME` (the Verdict step's `outcome`: `success`/`failure`).
- Produces: step output `verdict=<one line of JSON>`, or no line at all. Job output `verdict`. Workflow output `verdict`.

- [ ] **Step 1: Write the failing bats tests** (`test/verdict-output.bats`)

```bash
#!/usr/bin/env bats
# scripts/security/verdict-output.sh - turns the consumer's
# .security/verdict.json into the Verdict job's `verdict` output, the value
# publish-badges.yml renders the Security badge from. Covers each rule: the
# file as written, a crashed scanner overriding it, a Verdict step that failed
# without a file, a consumer that writes no file, SECURITY_DIR, and no
# GITHUB_OUTPUT.
#
# Every assertion ends in `|| fail "..."` - see test_helper.bash.
load test_helper

setup() {
  export GITHUB_WORKSPACE="$BATS_TEST_TMPDIR/consumer"
  export GITHUB_OUTPUT="$BATS_TEST_TMPDIR/output"
  mkdir -p "$GITHUB_WORKSPACE/.security"
  : > "$GITHUB_OUTPUT"
}

verdict_file() { printf '%s\n' "$1" > "$GITHUB_WORKSPACE/.security/verdict.json"; }

@test "the verdict file becomes the output as it is" {
  verdict_file '{"verdict":"informational","highest":"medium","canBlock":true}'
  SCANNER_FAILED=false VERDICT_OUTCOME=success run bash "$REPO_ROOT/scripts/security/verdict-output.sh"
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  [ "$(cat "$GITHUB_OUTPUT")" = 'verdict={"verdict":"informational","highest":"medium","canBlock":true}' ] \
    || fail "wrong output: $(cat "$GITHUB_OUTPUT")"
}

@test "a verdict that failed on findings still reaches the output" {
  verdict_file '{"verdict":"fail","highest":"high","canBlock":true}'
  SCANNER_FAILED=false VERDICT_OUTCOME=failure run bash "$REPO_ROOT/scripts/security/verdict-output.sh"
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  contains "$(cat "$GITHUB_OUTPUT")" '"verdict":"fail"' || fail "wrong output: $(cat "$GITHUB_OUTPUT")"
}

@test "a crashed scanner reads as fail even when the merged verdict passed" {
  verdict_file '{"verdict":"pass","highest":"none","canBlock":true}'
  SCANNER_FAILED=true VERDICT_OUTCOME=success run bash "$REPO_ROOT/scripts/security/verdict-output.sh"
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  [ "$(cat "$GITHUB_OUTPUT")" = 'verdict={"verdict":"fail"}' ] || fail "wrong output: $(cat "$GITHUB_OUTPUT")"
  contains "$output" 'scanner job failed' || fail "the override was not explained: $output"
}

@test "a Verdict step that failed without a file reads as fail" {
  SCANNER_FAILED=false VERDICT_OUTCOME=failure run bash "$REPO_ROOT/scripts/security/verdict-output.sh"
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  [ "$(cat "$GITHUB_OUTPUT")" = 'verdict={"verdict":"fail"}' ] || fail "wrong output: $(cat "$GITHUB_OUTPUT")"
}

@test "a consumer that writes no verdict file gets no output, not a false fail" {
  SCANNER_FAILED=false VERDICT_OUTCOME=success run bash "$REPO_ROOT/scripts/security/verdict-output.sh"
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  [ ! -s "$GITHUB_OUTPUT" ] || fail "an output was invented: $(cat "$GITHUB_OUTPUT")"
  contains "$output" 'verdict.json' || fail "the missing file was not named: $output"
}

@test "SECURITY_DIR moves where the file is read from" {
  mkdir -p "$GITHUB_WORKSPACE/build/security"
  printf '{"verdict":"pass"}\n' > "$GITHUB_WORKSPACE/build/security/verdict.json"
  SECURITY_DIR=build/security SCANNER_FAILED=false VERDICT_OUTCOME=success \
    run bash "$REPO_ROOT/scripts/security/verdict-output.sh"
  [ "$(cat "$GITHUB_OUTPUT")" = 'verdict={"verdict":"pass"}' ] || fail "wrong output: $(cat "$GITHUB_OUTPUT")"
}

@test "without GITHUB_OUTPUT the value goes to stdout" {
  unset GITHUB_OUTPUT
  verdict_file '{"verdict":"pass"}'
  SCANNER_FAILED=false VERDICT_OUTCOME=success run bash "$REPO_ROOT/scripts/security/verdict-output.sh"
  [ "$status" -eq 0 ] || fail "exited $status: $output"
  contains "$output" 'verdict={"verdict":"pass"}' || fail "nothing on stdout: $output"
}
```

`test_helper.bash` sets `REPO_ROOT`, defines `contains`, and unsets `GITHUB_OUTPUT` before every test, which is why `setup` exports it again. `consumer_root` resolves `$GITHUB_WORKSPACE/${WORKING_DIRECTORY:-.}`. `log` writes to stderr, which `run` captures in `$output`.

- [ ] **Step 2: Run to verify it fails**

Run: `bats test/verdict-output.bats`
Expected: FAIL. The script does not exist.

- [ ] **Step 3: Implement `scripts/security/verdict-output.sh`**

```bash
#!/usr/bin/env bash
# Turn the consumer's verdict file into the Verdict job's `verdict` output: the
# value check-security.yml exposes and publish-badges.yml renders the Security
# badge from.
#
# Its own step, after verdict.sh and under !cancelled(), because verdict.sh
# exits 1 when findings block, and the badge needs the verdict most in exactly
# that run.
#
# The rules, in order:
#   a scanner job failed          -> {"verdict":"fail"}: a crashed scanner
#                                    reported nothing, so the merge could read pass
#   the verdict file exists       -> its one line, as it is
#   the Verdict step failed       -> {"verdict":"fail"}: no SARIF, no node, or the
#                                    merge crashed; not a clean run
#   otherwise                     -> no output: this consumer's verdict.mjs
#                                    predates verdict.json, and saying "fail" would lie
#
# Env: SCANNER_FAILED (true|false), VERDICT_OUTCOME (the Verdict step's
# outcome), SECURITY_DIR (default .security).
# CI: the "Verdict output" step of check-security.yml's verdict job.
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"

root="$(consumer_root)"
file="$root/${SECURITY_DIR:-.security}/verdict.json"
sink="${GITHUB_OUTPUT:-/dev/stdout}"

if [ "${SCANNER_FAILED:-false}" = true ]; then
  log "a scanner job failed, so the verdict output is fail whatever the merge said"
  printf 'verdict={"verdict":"fail"}\n' >> "$sink"
elif [ -f "$file" ]; then
  # One line by construction (verdict.mjs); tr makes sure of it, because a
  # second line would end the output early.
  printf 'verdict=%s\n' "$(tr -d '\r\n' < "$file")" >> "$sink"
elif [ "${VERDICT_OUTCOME:-}" = failure ]; then
  printf 'verdict={"verdict":"fail"}\n' >> "$sink"
else
  log "no $file: this repository's verdict.mjs writes none, so there is no verdict output"
fi
```

- [ ] **Step 4: Run to verify it passes**

Run: `bats test/verdict-output.bats`
Expected: PASS. Then run `bats test/script-coverage.bats` (or whatever enforces one bats file per script) to confirm the new script is accounted for.

- [ ] **Step 5: Wire it into `check-security.yml`.** On the `verdict` job, add after `permissions:`:

```yaml
    outputs:
      verdict: ${{ steps.output.outputs.verdict }}
```

After the `Verdict` step (`id: verdict`), add:

```yaml
      # The badge's input. Its own step, so the output exists even when the
      # Verdict step above failed on findings - that run is exactly the one the
      # badge must show. contains(needs.*.result, 'failure') catches a scanner
      # that crashed and so reported nothing to the merge.
      - name: Verdict output
        id: output
        if: ${{ !cancelled() }}
        env:
          SCANNER_FAILED: ${{ contains(needs.*.result, 'failure') }}
          VERDICT_OUTCOME: ${{ steps.verdict.outcome }}
        run: bash "$WORKFLOWS_DIR/scripts/security/verdict-output.sh"
```

Under `on.workflow_call`, add, after `inputs:` and `secrets:` (match the order other workflows in this repository use):

```yaml
    outputs:
      verdict:
        description: >-
          The security verdict as one line of JSON, {"verdict","highest","canBlock"}, for a badge.
          {"verdict":"disabled"} when security-policy.json switches the gate off, {"verdict":"fail"}
          when the configuration job failed or a scanner crashed, empty when the verdict job did not run
        value: >-
          ${{ jobs.verdict.outputs.verdict
          || (jobs.config.outputs.enabled == 'false' && '{"verdict":"disabled"}')
          || (jobs.config.result == 'failure' && '{"verdict":"fail"}')
          || '' }}
```

- [ ] **Step 6: Re-render the interfaces and run the workflow checks**

Run: `bash scripts/self/render-interfaces.sh && bats test/render-interfaces.bats test/workflow-shape.bats test/self-workflows.bats && actionlint .github/workflows/check-security.yml`
Expected: PASS. If `workflow-shape.bats` pins the verdict job's step list, add the new step there.

- [ ] **Step 7: Document.** In `docs/consumer-guide.md` under `### check-security.yml`, add an **Outputs** paragraph: `verdict`, its shape, the `disabled` and `fail` cases, empty when the job did not run, and that `publish-badges.yml`'s `security-verdict` input takes it as it is.

- [ ] **Step 8: Commit**

```bash
git add scripts/security/verdict-output.sh test/verdict-output.bats .github/workflows/check-security.yml packages/dev-config/interfaces.json docs/consumer-guide.md
git commit -m "feat(security): expose the verdict as a check-security.yml output"
```

(Use a scope from shared-workflows' own commitlint configuration.)

### Task 4: `publish-badges.yml` takes the verdict

**Files:**
- Modify: `.github/workflows/publish-badges.yml` (inputs, the Render step's `env`)
- Modify: `scripts/ci/publish-badges.sh` (header comment and the gh-pages README text only)
- Modify: `test/publish-badges.bats`
- Modify: `packages/dev-config/interfaces.json` (re-rendered)
- Modify: `docs/consumer-guide.md` (the `publish-badges.yml` inputs table, the render-script environment list)

**Interfaces:**
- Consumes: `check-security.yml`'s `verdict` output (Task 3), passed by the caller.
- Produces: inputs `security-verdict` (default `''`) and `security-label` (default `Security`). The render script gets `BADGE_SECURITY` and `BADGE_SECURITY_LABEL`.

- [ ] **Step 1: Write the failing bats tests** (append to `test/publish-badges.bats`. `setup` already renders unit, e2e and coverage into `$CONSUMER/coverage/badge`, and `gh_pages_checkout` clones what the remote has.)

```bash
@test "a rendered security badge is published beside the others" {
  printf '<svg>security passing</svg>\n' > "$CONSUMER/coverage/badge/security.svg"
  printf '{"label":"Security"}\n' > "$CONSUMER/coverage/badge/security.json"
  BRANCH=main run bash "$PUBLISH"
  [ "$status" -eq 0 ] || fail "publish failed: $output"
  out="$(gh_pages_checkout)" || fail "no gh-pages branch on the remote after publishing"
  contains "$(cat "$out/badges/main/security.svg")" "security passing" || fail "security.svg did not land"
  [ -f "$out/badges/main/security.json" ] || fail "security.json did not land"
}

@test "a run that rendered no security badge leaves the published one alone" {
  printf '<svg>security passing</svg>\n' > "$CONSUMER/coverage/badge/security.svg"
  BRANCH=main bash "$PUBLISH"
  # The render script writes no security.svg when it was handed no verdict
  # (a docs-only change skipped Security).
  rm "$CONSUMER/coverage/badge/security.svg"
  echo '<svg>unit2</svg>' > "$CONSUMER/coverage/badge/unit.svg"
  BRANCH=main run bash "$PUBLISH"
  [ "$status" -eq 0 ] || fail "publish failed: $output"
  out="$(gh_pages_checkout)"
  contains "$(cat "$out/badges/main/security.svg")" "security passing" \
    || fail "the published security badge was removed by a run that rendered none"
  contains "$(cat "$out/badges/main/unit.svg")" "unit2" || fail "the new unit badge did not land"
}

@test "the gh-pages README lists the security badge" {
  BRANCH=main run bash "$PUBLISH"
  [ "$status" -eq 0 ] || fail "publish failed: $output"
  out="$(gh_pages_checkout)"
  contains "$(cat "$out/README.md")" "{coverage,unit,e2e,security}.svg" \
    || fail "the README does not list the security badge: $(cat "$out/README.md")"
}
```

- [ ] **Step 2: Run to verify the README test fails**

Run: `bats test/publish-badges.bats`
Expected: the README test fails. The first two may already pass, because `publish-badges.sh` copies whatever was rendered. That is the point: they pin the behaviour the design relies on.

- [ ] **Step 3: Implement.** In `publish-badges.sh`, change the README lines in `apply_badges` from `{coverage,unit,e2e}.svg` to `{coverage,unit,e2e,security}.svg`, and extend the header comment: "The Security badge follows the same rule: the render script writes it only when handed a verdict, so a run without one leaves the published badge." In `publish-badges.yml`, add after `e2e-label`:

```yaml
      security-verdict:
        description: check-security.yml's verdict output, handed to the render script as BADGE_SECURITY; empty renders no security badge and leaves the published one
        type: string
        default: ''
      security-label:
        description: Label on the security badge
        type: string
        default: 'Security'
```

and in the `Render badges` step's `env`:

```yaml
          BADGE_SECURITY: ${{ inputs.security-verdict }}
          BADGE_SECURITY_LABEL: ${{ inputs.security-label }}
```

Update the workflow's header comment from `{unit,e2e,coverage}.svg` to include `security`.

- [ ] **Step 4: Re-render and run**

Run: `bash scripts/self/render-interfaces.sh && bats test/publish-badges.bats test/render-interfaces.bats test/docs-contract.bats test/docs-facts.bats && actionlint .github/workflows/publish-badges.yml`
Expected: PASS.

- [ ] **Step 5: Document.** In `docs/consumer-guide.md`'s `publish-badges.yml` section, add both inputs to the inputs table, add `BADGE_SECURITY` and `BADGE_SECURITY_LABEL` to "The environment the render script is handed", and add a line to the rules: an empty `security-verdict` renders nothing, so the published security badge stays. Grep the guide for `{unit,e2e,coverage}` and update every hit.

- [ ] **Step 6: Commit and push the branch; open the PR as a draft**

```bash
git add .github/workflows/publish-badges.yml scripts/ci/publish-badges.sh test/publish-badges.bats packages/dev-config/interfaces.json docs/consumer-guide.md
git commit -m "feat(badges): publish a Security badge from check-security.yml's verdict"
git push -u origin feat/security-verdict-output
```

Both inputs default to empty and to `Security`, so every existing caller is unchanged. Say so in the PR description.

---

## Part C: template wiring, first as the evaluation

### Task 5: `ci.yml` feeds the verdict to the badges (draft PR pinned to the Part B branch)

**Files:**
- Modify: `.github/workflows/ci.yml` (all eleven `uses:` pins; the `badges` job)
- Modify: `package.json` / `pnpm-lock.yaml` (via `make fix-tooling-pin`)
- Modify: `scripts/ci-suite-gates.test.mjs`
- Modify: `README.md` (the badge row)
- Modify: `docs/ci.md` (the mermaid graph, the `ci.yml` row, `## Badges`)

**Interfaces:**
- Consumes: `check-security.yml` output `verdict` (Task 3), `publish-badges.yml` input `security-verdict` (Task 4), `BADGE_SECURITY` rendering (Task 2).

- [ ] **Step 1: Pin to the Part B branch head.** Set every `blinkbitcoin/shared-workflows/...@<sha>` in `.github/workflows/*.yml` to the head commit of `feat/security-verdict-output`, with the trailing comment `# evaluation: feat/security-verdict-output`. Then run `make fix-tooling-pin`. This commit is replaced in Task 7.

- [ ] **Step 2: Write the failing gate tests** (`scripts/ci-suite-gates.test.mjs`)

Split `compile` so value expressions can be evaluated too, and teach it `vars`:

```js
/** An expression as JavaScript, or a failed assertion naming a term it cannot evaluate. */
function translate(expression) {
  const js = expression
    .replace(/contains\(fromJSON\('(\[[^']*\])'\), (needs\.[\w-]+\.result)\)/g, '$1.includes($2)')
    .replace(/\bcancelled\(\)/g, 'cancelled')
    .replace(/\balways\(\)/g, 'true')
    .replace(/\bvars\.([A-Z_]+)/g, (_, name) => `vars[${JSON.stringify(name)}]`)
    .replace(
      /\bneeds\.([\w-]+)\.outputs\.([\w-]+)/g,
      (_, job, name) => `needs[${JSON.stringify(job)}].outputs[${JSON.stringify(name)}]`,
    )
    .replace(/\bneeds\.([\w-]+)\.result/g, (_, job) => `needs[${JSON.stringify(job)}].result`)
    .replace(/([!=])=/g, '$1==');
  const rest = js.replace(
    /needs\["[\w-]+"\]\.(?:result|outputs\["[\w-]+"\])|vars\["[A-Z_]+"\]|\[(?:"[a-z]+"(?:, )?)+\]\.includes|\bcancelled\b|\btrue\b|'[^']*'|[()!=&|\s]/g,
    '',
  );
  assert.equal(rest, '', `the gate uses a term this test cannot evaluate: ${expression}`);
  return js;
}

function compile(expression) {
  const gate = new Function('{ needs, cancelled, vars }', `return ${translate(expression)};`);
  if (/\b(?:success|failure|cancelled|always)\(\)/.test(expression)) return gate;
  return (context) =>
    Object.values(context.needs).every((job) => job.result === 'success') && gate(context);
}
```

Change `runCi` to take `vars = {}` and `securityVerdict`, pass `vars` into each gate, run the jobs `['unit', 'e2e', 'security', 'badges']`, and give security its outputs:

```js
function runCi({ checks = 'success', outputs, outcome = {}, cancelled = false, vars = {}, securityVerdict }) {
  const jobs = { checks: { result: checks, outputs } };
  for (const job of ['unit', 'e2e', 'security', 'badges']) {
    const needs = Object.fromEntries(needsOf(job).map((name) => [name, jobs[name]]));
    const runs = compile(unwrap(ci.jobs[job].if ?? 'true'))({ needs, cancelled, vars });
    const result = runs ? (outcome[job] ?? 'success') : 'skipped';
    const jobOutputs = job === 'security' && result !== 'skipped' ? { verdict: securityVerdict } : {};
    jobs[job] = { result, outputs: jobOutputs };
  }
  return Object.fromEntries(Object.entries(jobs).map(([job, { result }]) => [job, result]));
}
```

Add `security` to every existing expected object: `'skipped'` where checks failed or the change is docs-only, otherwise `'success'`. For `'a run cancelled during unit ...'`, add `security: 'cancelled'` to its `outcome` and expect `security: 'cancelled'`. Then add these cases to the table:

```js
    [
      'a Security run that failed on findings still gets its red badge',
      { outputs: classified(false, true, true), outcome: { security: 'failure' } },
      { unit: 'success', e2e: 'success', security: 'failure', badges: 'success' },
    ],
    [
      'Security switched off for the repository still publishes the suites',
      { outputs: classified(false, true, true), vars: { SECURITY_ENABLED: 'false' } },
      { unit: 'success', e2e: 'success', security: 'skipped', badges: 'success' },
    ],
    [
      'a run cancelled during Security publishes nothing',
      { outputs: classified(false, true, true), outcome: { security: 'cancelled' } },
      { unit: 'success', e2e: 'success', security: 'cancelled', badges: 'skipped' },
    ],
```

And a describe block for the value handed to publish-badges:

```js
describe('ci.yml hands the badges the security verdict, or nothing to keep the published one', () => {
  const value = new Function(
    '{ needs, vars }',
    `return ${translate(unwrap(ci.jobs.badges.with['security-verdict']))};`,
  );
  const verdict = '{"verdict":"pass","highest":"none","canBlock":true}';

  test('a verdict passes through as it is', () => {
    assert.equal(value({ needs: { security: { outputs: { verdict } } }, vars: {} }), verdict);
  });

  test('Security switched off for the repository reads as disabled', () => {
    assert.equal(
      value({ needs: { security: { outputs: {} } }, vars: { SECURITY_ENABLED: 'false' } }),
      '{"verdict":"disabled"}',
    );
  });

  test('a docs-only change, where Security skipped, hands over nothing', () => {
    assert.equal(value({ needs: { security: { outputs: {} } }, vars: {} }), '');
  });

  test('the badges wait for Security', () => {
    assert.ok(needsOf('badges').includes('security'));
  });
});
```

Add one evaluator test: `translate("vars.SECURITY_ENABLED == 'false'")` returns `vars["SECURITY_ENABLED"] === 'false'`.

- [ ] **Step 3: Run to verify it fails**

Run: `node --test scripts/ci-suite-gates.test.mjs`
Expected: FAIL. `badges` does not need `security`, and `with['security-verdict']` is undefined.

- [ ] **Step 4: Implement in `ci.yml`.** On the `badges` job:

```yaml
    needs: [checks, unit, e2e, security]
```

Add `needs.security.result != 'cancelled' &&` to its `if:` (next to the other cancelled checks), extend the comment above it with one sentence ("Security's verdict is a fourth badge; a skipped Security hands over nothing and its published badge stays."), and add under `with:`:

```yaml
      # The verdict's own word, never needs.security.result: the job succeeds
      # on pass, informational and skipped alike. Empty on a docs-only change,
      # so the published badge stays; disabled when the repository switched the
      # gate off, since a stale green badge for a gate that no longer runs lies.
      security-verdict: ${{ needs.security.outputs.verdict || (vars.SECURITY_ENABLED == 'false' && '{"verdict":"disabled"}') || '' }}
```

- [ ] **Step 5: Run to verify it passes**

Run: `node --test --experimental-test-coverage scripts/ci-suite-gates.test.mjs && make test-scripts && make check-ci`
Expected: PASS. `make check-ci` runs actionlint and zizmor over `ci.yml`. The workflow contract test checks `security-verdict` against the pinned branch's `interfaces.json`; it fails if Task 4's re-render was not pushed.

- [ ] **Step 6: README and docs.**
  - `README.md`: add after the Coverage badge:
    `[![Security](https://raw.githubusercontent.com/blinkbitcoin/react-native-mobile-template/gh-pages/badges/main/security.svg)](https://github.com/blinkbitcoin/react-native-mobile-template/actions/workflows/ci.yml)`
  - `docs/ci.md`: in the mermaid graph, add `security["Security"] --> badges`. In the `ci.yml` table row, say `badges` also needs `security`. In `## Badges`: "three badges" becomes "four", the tree becomes `{unit,e2e,coverage,security}.svg`, add a table row for `security.svg` (the source is `check-security.yml`'s `verdict` output, with the badge-words table from Design item 5), and add two bullets: "A skipped Security keeps its published badge" and "Security switched off shows `disabled`".
  - `git grep -n "three badges\|{unit,e2e,coverage}"` and fix every hit.

Run: `make check-docs`
Expected: PASS, including the mermaid parse and table widths.

- [ ] **Step 7: Commit, push, open as a draft PR**

```bash
git add .github/workflows package.json pnpm-lock.yaml scripts/ci-suite-gates.test.mjs README.md docs/ci.md
git commit -m "feat(ci): publish the security verdict as a Security badge"
git push -u origin HEAD
gh pr create --draft --title "feat(ci): publish the security verdict as a Security badge" --body "Evaluation: pinned to shared-workflows feat/security-verdict-output. Do not merge until Task 7 re-pins to a release."
```

### Task 6: Evaluate

Run the draft PR and record each result in the PR description. **Go** needs every item in 1 to 4 true.

- [ ] **1. The verdict reaches the badge.** In the run, the `Security / Verdict` job's "Verdict output" step logs a value, and the `Badges / Publish` job's "Render badges" log prints `badges: Security <message>`, matching the `security:` line in the run summary.
- [ ] **2. It is published.** `gh api repos/blinkbitcoin/react-native-mobile-template/contents/badges/<branch>/security.svg?ref=gh-pages` exists, and its text matches item 1.
- [ ] **3. docs-only keeps it.** Push a commit touching only `docs/`. Security skips, Badges runs, and the resulting `gh-pages` commit does not touch `badges/<branch>/security.*` (`git log -p origin/gh-pages -1 -- badges/<branch>/`).
- [ ] **4. Advisory reads right.** Push a commit setting `"failOn": []` in `security-policy.json`. The badge reads `passing (advisory)` or `<severity> findings (advisory)`. Revert the commit afterwards.
- [ ] **4b. A red badge reaches gh-pages.** Push a commit that makes the verdict `fail`, for example setting `"severity": "low"` in `security-policy.json` on a branch with a known low finding, or adding a dependency with a known advisory. The Security run fails, and `Render badges` still prints `badges: Security failing`, and `security.svg` on gh-pages is red. This is the one case that depends on GitHub carrying a failed called workflow's output to the caller (`needs.security.outputs.verdict` while `needs.security.result == 'failure'`). Revert the commit afterwards.
- [ ] **5. The cost in time.** For three runs, note how long `Badges` waited on `Security` after `E2E` finished (the Badges job's start time minus the later of E2E's and Unit's finish times). Rough bar: under two minutes on a normal pull request is fine. Longer means reconsider (see "If the evaluation says no").
- [ ] **6. It reads well.** Look at the four badges side by side (open the four raw URLs for the branch). Decide whether `medium findings` and `(advisory)` read clearly next to `passing`/`failing`, and adjust the words in Task 2 if not.

**If the evaluation says no:**
- If only the timing is the problem: keep Tasks 1 to 4, and instead publish the security badge from a second `publish-badges.yml` call that needs only `security`. That call has `unit-result` and `e2e-result` set to `skipped`, so it would need a relaxed guard in `publish-badges.yml`, which makes this a larger Part B change.
- If the concept is the problem: close both draft PRs. Part A (the `verdict.json` file and the renderer) can stay or be reverted; nothing depends on it.

### Task 7: Release and re-pin

- [ ] **Step 1:** Mark the shared-workflows PR ready and merge it (squash). Merge the release-please PR it produces and note the release commit SHA and tag.
- [ ] **Step 2:** In the template draft PR, drop the evaluation pin commit. Set all eleven pins to the release SHA with the `# vX.Y.Z` comment, then run `make fix-tooling-pin`. If Dependabot opened the bump PR first, rebase this branch onto `main` after that PR merges instead.
- [ ] **Step 3:** Run `make ci && make check-contract`. Expected: PASS.
- [ ] **Step 4:** Update the PR description: the tests (Task 2 render and security-badge tests, Task 5 gate tests) and the docs updated (`README.md`, `docs/ci.md`, `docs/security.md`, `AGENTS.md`). Mark it ready.
- [ ] **Step 5:** After merge, check that the first push to `main` publishes `badges/main/security.svg`. The README's Security badge is a broken image until that run finishes.

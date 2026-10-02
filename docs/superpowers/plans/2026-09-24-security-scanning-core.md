# Security Scanning Core Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the local half of the security gate — settings resolution, SARIF emission, the merge-and-verdict, and the three source scanners — so `make check-security` produces the same verdict a CI job will later produce.

**Architecture:** Every scanner is a small bash runner that writes one SARIF file into `.security/`. A single Node module merges those SARIFs, resolves severities, applies a threshold and decides pass or fail. Settings resolve in one order everywhere — environment variable, then `security-policy.json`, then a built-in default. Nothing in this plan touches CI: the reusable workflow and the call sites are later stages, and they will call exactly these scripts.

**Tech Stack:** Node 24 (`node:test`, zero runtime dependencies), bash, osv-scanner, Semgrep CE, pnpm, mise for tool pinning.

**Spec:** `docs/superpowers/specs/2026-09-24-security-scanning-design.md`

## Global Constraints

- **Zero dependencies in `scripts/security/*.mjs`.** The shared LLM jobs run consumer scripts with no `pnpm install`, so every module uses only `node:*` builtins.
- **100% coverage, lines, branches and functions,** for every `.mjs` under `scripts/`. `make test-scripts` enforces it. Gates are never lowered or excluded.
- **A finding never fails its own runner.** Exit 0 with findings. A crash — missing binary under CI, bad config, output that is not SARIF — is a failure.
- **Nothing to scan is never silence.** Write an empty run carrying a `toolExecutionNotifications` note with `executionSuccessful: false`, and print `::notice::`, so a summary reads "skipped: reason" and never "clean".
- **Locally a missing tool is a skip; under CI (`CI` is set) it is a failure.**
- **Resolution order is environment variable, then `security-policy.json`, then default.** A value that is not `true` or `false` fails the run rather than reading as off.
- **Commit scopes** must come from commitlint's enum: `app, ui, i18n, graphql, native, plugins, config, tooling, ci, release, deps, deps-dev, docs, e2e, web`. Anything else is rejected silently under a pipe — always confirm with `git log -1` after committing.
- **Every make target needs a row in AGENTS.md's command table.** `scripts/check-docs.sh` asserts the table and the Makefile agree in both directions.
- **Naming:** job, make target and policy key share one name. `deps`, `code`, `policy`, `sbom`, `bundle`, `mobile`, `binaries`, `review`, `openant`.
- Run `make ci` before any push touching `scripts/`.

---

### Task 1: Settings resolution

**Files:**
- Create: `security-policy.json`
- Create: `scripts/security/config.mjs`
- Test: `scripts/security/config.test.mjs`
- Modify: `.gitignore` (add `/.security`)

**Interfaces:**
- Consumes: nothing.
- Produces: `DEFAULTS`, `parseBoolean(value, source) -> boolean`, `resolve(policy, env) -> { enabled, jobs, severity, failOn }`, `load(file, env) -> settings`, `main(argv, io) -> exit code`. Later tasks call `node scripts/security/config.mjs get jobs.deps` from bash and import `resolve` in tests.

- [ ] **Step 1: Write the failing test**

Create `scripts/security/config.test.mjs`:

```js
import assert from 'node:assert/strict';
import { test } from 'node:test';
import { DEFAULTS, parseBoolean, resolve } from './config.mjs';

test('defaults apply when the file and the environment are silent', () => {
  const settings = resolve({}, {});
  assert.equal(settings.enabled, true);
  assert.equal(settings.severity, 'high');
  assert.deepEqual(settings.failOn, ['deterministic']);
  assert.equal(settings.jobs.deps, true);
  assert.equal(settings.jobs.review, false);
});

test('the file overrides a default', () => {
  const settings = resolve({ jobs: { deps: { enabled: false } }, severity: 'low' }, {});
  assert.equal(settings.jobs.deps, false);
  assert.equal(settings.severity, 'low');
});

test('the environment overrides the file', () => {
  const settings = resolve({ jobs: { deps: { enabled: false } } }, { SECURITY_DEPS: 'true' });
  assert.equal(settings.jobs.deps, true);
});

test('SECURITY_ENABLED is the master switch and follows the same order', () => {
  assert.equal(resolve({ enabled: false }, {}).enabled, false);
  assert.equal(resolve({ enabled: false }, { SECURITY_ENABLED: 'true' }).enabled, true);
});

test('a value that is not a boolean fails the run rather than reading as off', () => {
  assert.throws(() => parseBoolean('yes', 'SECURITY_DEPS'), /SECURITY_DEPS: expected true or false, got "yes"/);
  assert.throws(() => resolve({}, { SECURITY_CODE: '1' }), /SECURITY_CODE/);
  assert.throws(() => resolve({ jobs: { code: { enabled: 'on' } } }, {}), /security-policy.json: jobs.code/);
});

test('an unknown severity names itself in the error', () => {
  assert.throws(() => resolve({}, { SECURITY_SEVERITY: 'huge' }), /SECURITY_SEVERITY: expected one of none, low, medium, high, critical/);
  assert.throws(() => resolve({ severity: 'huge' }, {}), /^Error: severity: expected one of/);
});

test('failOn is a comma list from the environment and an array from the file', () => {
  assert.deepEqual(resolve({}, { SECURITY_FAIL_ON: 'deterministic,review' }).failOn, ['deterministic', 'review']);
  assert.deepEqual(resolve({ severity: 'high', failOn: ['review'] }, {}).failOn, ['review']);
  assert.deepEqual(resolve({}, { SECURITY_FAIL_ON: '' }).failOn, []);
});

test('every job in DEFAULTS has an environment twin', () => {
  for (const name of Object.keys(DEFAULTS.jobs)) {
    const env = { [`SECURITY_${name.toUpperCase()}`]: 'false' };
    assert.equal(resolve({}, env).jobs[name], false, name);
  }
});
```

- [ ] **Step 2: Run it and watch it fail**

Run: `mise exec -- node --test scripts/security/config.test.mjs`
Expected: FAIL, `Cannot find module .../config.mjs`.

- [ ] **Step 3: Write the module**

Create `scripts/security/config.mjs`:

```js
#!/usr/bin/env node
// The security scanning settings, resolved in one order everywhere: an
// environment variable wins over security-policy.json, which wins over the
// built-in default. Bash runners read one key at a time
//
//     node scripts/security/config.mjs get jobs.deps
//
// and CI reads the lot with `--json`. A value that is not a boolean throws
// rather than reading as off: a typo must not quietly disable a scanner.
import { readFileSync } from 'node:fs';

export const SEVERITIES = ['none', 'low', 'medium', 'high', 'critical'];

/** Built-in defaults. Deterministic scanners on, LLM engines dark until a key exists. */
export const DEFAULTS = {
  enabled: true,
  severity: 'high',
  failOn: ['deterministic'],
  jobs: {
    deps: true,
    code: true,
    policy: true,
    sbom: true,
    bundle: true,
    mobile: false,
    binaries: true,
    review: false,
    openant: false,
  },
};

export const parseBoolean = (value, source) => {
  if (value === true || value === 'true') return true;
  if (value === false || value === 'false') return false;
  throw new Error(`${source}: expected true or false, got ${JSON.stringify(value)}`);
};

const parseSeverity = (value, source) => {
  if (!SEVERITIES.includes(value)) {
    throw new Error(`${source}: expected one of ${SEVERITIES.join(', ')}, got ${JSON.stringify(value)}`);
  }
  return value;
};

const parseList = (value) =>
  Array.isArray(value) ? value : value.split(',').map((part) => part.trim()).filter(Boolean);

/** Settings from a parsed policy object and an environment. */
export const resolve = (policy = {}, env = process.env) => {
  const bool = (key, envKey, fileValue, fallback) => {
    if (env[envKey] !== undefined) return parseBoolean(env[envKey], envKey);
    if (fileValue !== undefined) return parseBoolean(fileValue, `security-policy.json: ${key}`);
    return fallback;
  };
  const jobs = Object.fromEntries(
    Object.entries(DEFAULTS.jobs).map(([name, fallback]) => [
      name,
      bool(`jobs.${name}`, `SECURITY_${name.toUpperCase()}`, policy.jobs?.[name]?.enabled, fallback),
    ]),
  );
  const severity =
    env.SECURITY_SEVERITY !== undefined
      ? parseSeverity(env.SECURITY_SEVERITY, 'SECURITY_SEVERITY')
      : parseSeverity(policy.severity ?? DEFAULTS.severity, 'severity');
  const failOn = parseList(env.SECURITY_FAIL_ON ?? policy.failOn ?? DEFAULTS.failOn);
  return {
    enabled: bool('enabled', 'SECURITY_ENABLED', policy.enabled, DEFAULTS.enabled),
    jobs,
    severity,
    failOn,
  };
};

/** Settings from the policy file on disk; a missing file is the defaults. */
export const load = (file = 'security-policy.json', env = process.env) => {
  let policy = {};
  try {
    policy = JSON.parse(readFileSync(file, 'utf8'));
  } catch (error) {
    if (error.code !== 'ENOENT') throw error;
  }
  return resolve(policy, env);
};

const at = (settings, dotted) =>
  dotted.split('.').reduce((value, key) => (value === undefined ? undefined : value[key]), settings);

/** Command-line entry; returns the exit code. */
export function main(argv = process.argv.slice(2), { log = console.log, error = console.error, env = process.env } = {}) {
  const settings = load('security-policy.json', env);
  if (argv[0] === '--json') {
    log(JSON.stringify(settings));
    return 0;
  }
  if (argv[0] === 'get' && argv[1]) {
    const value = at(settings, argv[1]);
    if (value === undefined) {
      error(`no such setting: ${argv[1]}`);
      return 2;
    }
    log(Array.isArray(value) ? value.join(',') : String(value));
    return 0;
  }
  error('usage: config.mjs get <dotted.key> | --json');
  return 2;
}

if (import.meta.main) process.exitCode = main();
```

- [ ] **Step 4: Run the test and watch it pass**

Run: `mise exec -- node --test scripts/security/config.test.mjs`
Expected: PASS, 8 tests.

- [ ] **Step 5: Add the CLI tests that reach 100%**

Append to `scripts/security/config.test.mjs`:

```js
import { main } from './config.mjs';

const capture = () => {
  const out = [];
  return { out, log: (line) => out.push(String(line)), error: (line) => out.push(String(line)) };
};

test('get prints one setting, a list comma-joined', () => {
  const io = capture();
  assert.equal(main(['get', 'jobs.deps'], { ...io, env: {} }), 0);
  assert.equal(main(['get', 'failOn'], { ...io, env: {} }), 0);
  assert.deepEqual(io.out, ['true', 'deterministic']);
});

test('--json prints every setting', () => {
  const io = capture();
  assert.equal(main(['--json'], { ...io, env: {} }), 0);
  assert.equal(JSON.parse(io.out[0]).severity, 'high');
});

test('an unknown key and a missing argument both exit 2', () => {
  const io = capture();
  assert.equal(main(['get', 'jobs.nope'], { ...io, env: {} }), 2);
  assert.equal(main([], { ...io, env: {} }), 2);
  assert.deepEqual(io.out, ['no such setting: jobs.nope', 'usage: config.mjs get <dotted.key> | --json']);
});
```

- [ ] **Step 6: Write the policy file**

Create `security-policy.json`. Every value here is a default made visible — the file exists so a consumer can see what there is to change:

```json
{
  "$comment": "Security scanning settings. Every key has an environment twin that wins over this file: SECURITY_ENABLED, SECURITY_SEVERITY, SECURITY_FAIL_ON, and SECURITY_<JOB> for each job. See docs/security.md.",
  "enabled": true,
  "severity": "high",
  "failOn": ["deterministic"],
  "jobs": {
    "deps": { "enabled": true },
    "code": { "enabled": true },
    "policy": { "enabled": true },
    "sbom": { "enabled": true },
    "bundle": { "enabled": true },
    "mobile": { "enabled": false },
    "binaries": { "enabled": true },
    "review": { "enabled": false },
    "openant": { "enabled": false }
  }
}
```

- [ ] **Step 7: Ignore the output directory**

Add to `.gitignore`, under the existing build-output entries:

```
# Local security scan output (make check-security)
/.security
```

- [ ] **Step 8: Run the full script gate**

Run: `mise exec -- make test-scripts`
Expected: PASS, coverage 100% lines, branches and functions. If a branch is uncovered, add the case to the test rather than lowering the gate.

- [ ] **Step 9: Commit**

```bash
git add security-policy.json scripts/security/config.mjs scripts/security/config.test.mjs .gitignore
git commit -m "feat(tooling): resolve security settings from env, file, then default

security-policy.json holds every tunable; an environment variable of the same
name wins over it. A value that is not a boolean throws, so a typo cannot
quietly disable a scanner.

Claude-Session: https://claude.ai/code/session_01SpyYZEnJaLFih75JB4EQAW"
git log -1 --format='%h %s'
```

---

### Task 2: SARIF emission

**Files:**
- Create: `scripts/security/sarif.mjs`
- Test: `scripts/security/sarif.test.mjs`

**Interfaces:**
- Consumes: nothing.
- Produces: `LEVEL_OF`, `SECURITY_SEVERITY_OF`, `skipped(tool, reason) -> document`, `fromFindings(tool, findings) -> document`, `parseLine(line) -> finding`, `main(argv, io)`. Bash runners call `node scripts/security/sarif.mjs skip <tool> <reason>` and `node scripts/security/sarif.mjs lines <tool>` with NDJSON on stdin. Task 3 consumes the documents.

- [ ] **Step 1: Write the failing test**

Create `scripts/security/sarif.test.mjs`:

```js
import assert from 'node:assert/strict';
import { test } from 'node:test';
import { fromFindings, parseLine, skipped } from './sarif.mjs';

test('a skipped run says why, and is not a clean run', () => {
  const doc = skipped('osv-scanner', 'osv-scanner is not installed');
  const [run] = doc.runs;
  assert.equal(doc.version, '2.1.0');
  assert.equal(run.tool.driver.name, 'osv-scanner');
  assert.deepEqual(run.results, []);
  assert.equal(run.invocations[0].executionSuccessful, false);
  assert.match(run.invocations[0].toolExecutionNotifications[0].message.text, /skipped: osv-scanner is not installed/);
});

test('findings become results with a level and a GitHub severity', () => {
  const doc = fromFindings('semgrep', [
    { ruleId: 'rn/cleartext-fetch', file: 'src/api.ts', line: 12, severity: 'high', message: 'http:// URL' },
    { ruleId: 'rn/webview-js', file: 'src/web.tsx', line: 3, severity: 'low', message: 'injected JavaScript' },
  ]);
  const [run] = doc.runs;
  assert.equal(run.invocations[0].executionSuccessful, true);
  assert.equal(run.results[0].level, 'error');
  assert.equal(run.results[0].properties['security-severity'], '7.0');
  assert.equal(run.results[0].locations[0].physicalLocation.artifactLocation.uri, 'src/api.ts');
  assert.equal(run.results[0].locations[0].physicalLocation.region.startLine, 12);
  assert.equal(run.results[1].level, 'note');
  assert.equal(run.results[1].properties['security-severity'], '1.0');
});

test('a finding with no findings at all is a clean run, not a skipped one', () => {
  const [run] = fromFindings('semgrep', []).runs;
  assert.deepEqual(run.results, []);
  assert.equal(run.invocations[0].executionSuccessful, true);
});

test('an unknown severity is rejected by name', () => {
  assert.throws(() => fromFindings('semgrep', [{ ruleId: 'r', file: 'f', line: 1, severity: 'spicy', message: 'm' }]), /spicy/);
});

test('parseLine reads the ok/warn/skip/FAIL line protocol', () => {
  assert.equal(parseLine('ok\tMASTG-TEST-0226\tandroid\tnot debuggable'), null);
  assert.deepEqual(parseLine('FAIL\tMASTG-TEST-0226\tandroid/AndroidManifest.xml:4\tdebuggable is true'), {
    ruleId: 'MASTG-TEST-0226',
    file: 'android/AndroidManifest.xml',
    line: 4,
    severity: 'high',
    message: 'debuggable is true',
  });
  assert.equal(parseLine('warn\tR\tf:2\tm').severity, 'medium');
  assert.equal(parseLine('skip\tR\tf\tno binary'), null);
  assert.equal(parseLine(''), null);
});

test('a line with no line number lands on line 1', () => {
  assert.equal(parseLine('FAIL\tR\tsome/file\tm').line, 1);
});

test('an unknown verb names the line', () => {
  assert.throws(() => parseLine('maybe\tR\tf\tm'), /unknown verb "maybe"/);
});
```

- [ ] **Step 2: Run it and watch it fail**

Run: `mise exec -- node --test scripts/security/sarif.test.mjs`
Expected: FAIL, `Cannot find module`.

- [ ] **Step 3: Write the module**

Create `scripts/security/sarif.mjs`:

```js
#!/usr/bin/env node
// SARIF 2.1.0 documents for the security scanners. Two shapes matter:
//
//   skipped(tool, reason)  - nothing to scan. An empty run carrying a
//                            toolExecutionNotifications note and
//                            executionSuccessful: false, so a summary reads
//                            "skipped: reason" and never "clean".
//   fromFindings(tool, []) - a clean run. Empty results, but the invocation
//                            succeeded. The distinction is the whole point.
//
// A scanner that already speaks SARIF writes its own; this is for the ones
// that do not. Bash runners use the CLI:
//
//     node scripts/security/sarif.mjs skip osv-scanner "not installed"
//     printf 'FAIL\tid\tfile:12\tmessage\n' | node scripts/security/sarif.mjs lines checks
import { readFileSync } from 'node:fs';

export const LEVEL_OF = { critical: 'error', high: 'error', medium: 'warning', low: 'note' };
// The GitHub code-scanning scale: 9+ critical, 7 high, 4 medium, below that low.
export const SECURITY_SEVERITY_OF = { critical: '9.0', high: '7.0', medium: '4.0', low: '1.0' };
const SEVERITY_OF_VERB = { FAIL: 'high', warn: 'medium' };

const document = (run) => ({
  $schema: 'https://json.schemastore.org/sarif-2.1.0.json',
  version: '2.1.0',
  runs: [run],
});

const driver = (tool) => ({ driver: { name: tool, informationUri: 'https://github.com/blinkbitcoin/react-native-mobile-template' } });

export const skipped = (tool, reason) =>
  document({
    tool: driver(tool),
    results: [],
    invocations: [
      {
        executionSuccessful: false,
        toolExecutionNotifications: [{ level: 'note', message: { text: `skipped: ${reason}` } }],
      },
    ],
  });

export const fromFindings = (tool, findings) =>
  document({
    tool: driver(tool),
    invocations: [{ executionSuccessful: true }],
    results: findings.map((finding) => {
      const level = LEVEL_OF[finding.severity];
      if (!level) throw new Error(`unknown severity ${JSON.stringify(finding.severity)} for ${finding.ruleId}`);
      return {
        ruleId: finding.ruleId,
        level,
        message: { text: finding.message },
        properties: { 'security-severity': SECURITY_SEVERITY_OF[finding.severity] },
        locations: [
          {
            physicalLocation: {
              artifactLocation: { uri: finding.file },
              region: { startLine: finding.line },
            },
          },
        ],
      };
    }),
  });

/** One `verb<TAB>rule<TAB>file[:line]<TAB>message` line, or null when it is not a finding. */
export const parseLine = (line) => {
  if (!line.trim()) return null;
  const [verb, ruleId, where = '', ...rest] = line.split('\t');
  if (verb === 'ok' || verb === 'skip') return null;
  const severity = SEVERITY_OF_VERB[verb];
  if (!severity) throw new Error(`unknown verb ${JSON.stringify(verb)} in: ${line}`);
  const match = /^(.*):(\d+)$/.exec(where);
  return {
    ruleId,
    file: match ? match[1] : where,
    line: match ? Number(match[2]) : 1,
    severity,
    message: rest.join('\t'),
  };
};

/** Command-line entry; returns the exit code. */
export function main(argv = process.argv.slice(2), { log = console.log, error = console.error, stdin = 0 } = {}) {
  const [command, tool, ...rest] = argv;
  if (command === 'skip' && tool && rest.length) {
    log(JSON.stringify(skipped(tool, rest.join(' ')), null, 2));
    return 0;
  }
  if (command === 'lines' && tool) {
    const findings = readFileSync(stdin, 'utf8').split('\n').map(parseLine).filter(Boolean);
    log(JSON.stringify(fromFindings(tool, findings), null, 2));
    return 0;
  }
  error('usage: sarif.mjs skip <tool> <reason> | sarif.mjs lines <tool> < findings');
  return 2;
}

if (import.meta.main) process.exitCode = main();
```

- [ ] **Step 4: Run the test and watch it pass**

Run: `mise exec -- node --test scripts/security/sarif.test.mjs`
Expected: PASS, 7 tests.

- [ ] **Step 5: Cover the CLI**

Append to `scripts/security/sarif.test.mjs`:

```js
import { spawnSync } from 'node:child_process';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { main } from './sarif.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));

test('the CLI writes a skipped document', () => {
  const out = [];
  assert.equal(main(['skip', 'osv-scanner', 'not', 'installed'], { log: (l) => out.push(l), error: () => {} }), 0);
  assert.equal(JSON.parse(out[0]).runs[0].invocations[0].executionSuccessful, false);
});

test('the CLI turns NDJSON lines into a document', () => {
  const dir = mkdtempSync(path.join(tmpdir(), 'sarif-'));
  const file = path.join(dir, 'lines');
  writeFileSync(file, 'FAIL\tR\tf.ts:9\tboom\nok\tR\tf.ts\tfine\n');
  const out = [];
  assert.equal(main(['lines', 'checks'], { log: (l) => out.push(l), error: () => {}, stdin: file }), 0);
  assert.equal(JSON.parse(out[0]).runs[0].results.length, 1);
  rmSync(dir, { recursive: true, force: true });
});

test('a bad invocation exits 2 and says how to call it', () => {
  const out = [];
  assert.equal(main(['nonsense'], { log: () => {}, error: (l) => out.push(l) }), 2);
  assert.match(out[0], /usage: sarif.mjs/);
});

test('runs as a script', () => {
  const run = spawnSync(process.execPath, [path.join(here, 'sarif.mjs'), 'skip', 't', 'r'], { encoding: 'utf8' });
  assert.equal(run.status, 0);
  assert.match(run.stdout, /skipped: r/);
});
```

- [ ] **Step 6: Run the script gate**

Run: `mise exec -- make test-scripts`
Expected: PASS at 100%.

- [ ] **Step 7: Commit**

```bash
git add scripts/security/sarif.mjs scripts/security/sarif.test.mjs
git commit -m "feat(tooling): emit SARIF for scanners that do not speak it

A skipped run carries executionSuccessful: false and a note saying why, so
nothing-to-scan can never be summarised as clean.

Claude-Session: https://claude.ai/code/session_01SpyYZEnJaLFih75JB4EQAW"
git log -1 --format='%h %s'
```

---

### Task 3: Merge and verdict

**Files:**
- Create: `scripts/security/verdict.mjs`
- Test: `scripts/security/verdict.test.mjs`

**Interfaces:**
- Consumes: `security-policy.json` settings via `load` from Task 1; SARIF documents from Task 2 and from the scanners.
- Produces: `ENGINE_OF`, `ORDER`, `severityOf(result) -> 'low'|'medium'|'high'|'critical'`, `summarize(entries) -> { counts, highest, skipped, findings }`, `verdict({ entries, severity, failOn }) -> { verdict, highest, counts, lines, exitCode }`, `main(argv, io)`. Task 7's `make check-security` runs it; stage 2's workflow runs the same file.

- [ ] **Step 1: Write the failing test**

Create `scripts/security/verdict.test.mjs`:

```js
import assert from 'node:assert/strict';
import { test } from 'node:test';
import { ENGINE_OF, severityOf, summarize, verdict } from './verdict.mjs';

const result = (severity, ruleId = 'r') => ({
  ruleId,
  level: severity === 'low' ? 'note' : severity === 'medium' ? 'warning' : 'error',
  message: { text: 'boom' },
  properties: { 'security-severity': { critical: '9.0', high: '7.0', medium: '4.0', low: '1.0' }[severity] },
  locations: [{ physicalLocation: { artifactLocation: { uri: 'f.ts' }, region: { startLine: 1 } } }],
});

const doc = (tool, results, successful = true) => ({
  version: '2.1.0',
  runs: [{ tool: { driver: { name: tool } }, results, invocations: [{ executionSuccessful: successful }] }],
});

const entry = (job, document) => ({ job, document });

test('severity comes from security-severity, then from level', () => {
  assert.equal(severityOf(result('critical')), 'critical');
  assert.equal(severityOf({ level: 'error' }), 'high');
  assert.equal(severityOf({ level: 'warning' }), 'medium');
  assert.equal(severityOf({ level: 'note' }), 'low');
  assert.equal(severityOf({}), 'medium');
  assert.equal(severityOf({ properties: { 'security-severity': 'not a number' }, level: 'note' }), 'low');
});

test('every job maps to an engine class', () => {
  assert.equal(ENGINE_OF.deps, 'deterministic');
  assert.equal(ENGINE_OF.binaries, 'deterministic');
  assert.equal(ENGINE_OF.review, 'review');
  assert.equal(ENGINE_OF.openant, 'openant');
});

test('counts, highest severity and skipped jobs', () => {
  const s = summarize([
    entry('deps', doc('osv-scanner', [result('high'), result('low')])),
    entry('code', doc('semgrep', [], false)),
  ]);
  assert.deepEqual(s.counts, { critical: 0, high: 1, medium: 0, low: 1 });
  assert.equal(s.highest, 'high');
  assert.deepEqual(s.skipped, ['code']);
});

test('a finding at the threshold from a fail-on engine fails', () => {
  const v = verdict({
    entries: [entry('deps', doc('osv-scanner', [result('high')]))],
    severity: 'high',
    failOn: ['deterministic'],
  });
  assert.equal(v.verdict, 'fail');
  assert.equal(v.exitCode, 1);
});

test('the same finding below the threshold passes', () => {
  const v = verdict({
    entries: [entry('deps', doc('osv-scanner', [result('medium')]))],
    severity: 'high',
    failOn: ['deterministic'],
  });
  assert.equal(v.verdict, 'pass');
  assert.equal(v.exitCode, 0);
});

test('a finding from an engine that is not in fail-on is informational', () => {
  const v = verdict({
    entries: [entry('review', doc('review', [result('critical')]))],
    severity: 'high',
    failOn: ['deterministic'],
  });
  assert.equal(v.verdict, 'informational');
  assert.equal(v.exitCode, 0);
});

test('severity none never fails', () => {
  const v = verdict({
    entries: [entry('deps', doc('osv-scanner', [result('critical')]))],
    severity: 'none',
    failOn: ['deterministic'],
  });
  assert.equal(v.verdict, 'informational');
  assert.equal(v.exitCode, 0);
});

test('a suppressed result is not a finding', () => {
  const suppressed = { ...result('critical'), suppressions: [{ kind: 'inSource' }] };
  const v = verdict({ entries: [entry('deps', doc('osv-scanner', [suppressed]))], severity: 'high', failOn: ['deterministic'] });
  assert.equal(v.verdict, 'pass');
  assert.equal(v.counts.critical, 0);
});

test('the summary names skipped jobs so they are never read as clean', () => {
  const v = verdict({ entries: [entry('code', doc('semgrep', [], false))], severity: 'high', failOn: ['deterministic'] });
  assert.ok(v.lines.some((line) => /code: skipped/.test(line)));
  assert.ok(!v.lines.some((line) => /code: clean/.test(line)));
});

test('a job that ran and found nothing is clean', () => {
  const v = verdict({ entries: [entry('deps', doc('osv-scanner', []))], severity: 'high', failOn: ['deterministic'] });
  assert.ok(v.lines.some((line) => /deps: clean/.test(line)));
});
```

- [ ] **Step 2: Run it and watch it fail**

Run: `mise exec -- node --test scripts/security/verdict.test.mjs`
Expected: FAIL, `Cannot find module`.

- [ ] **Step 3: Write the module**

Create `scripts/security/verdict.mjs`:

```js
#!/usr/bin/env node
// Merges the scanners' SARIF files into one verdict.
//
//     node scripts/security/verdict.mjs .security
//
// Exits 1 when a finding at or above the configured severity comes from a job
// whose engine class is listed in failOn. Every other case exits 0: a finding
// never fails its own scanner, and an engine outside failOn annotates only.
// The same file runs locally and in CI, so `make check-security` gives the
// answer the pipeline will give.
import { readFileSync, readdirSync } from 'node:fs';
import path from 'node:path';
import { load } from './config.mjs';

/** Which engine class each job belongs to. failOn names classes, not jobs. */
export const ENGINE_OF = {
  deps: 'deterministic',
  code: 'deterministic',
  policy: 'deterministic',
  sbom: 'deterministic',
  bundle: 'deterministic',
  mobile: 'deterministic',
  binaries: 'deterministic',
  review: 'review',
  openant: 'openant',
};

export const ORDER = ['low', 'medium', 'high', 'critical'];

const FROM_LEVEL = { error: 'high', warning: 'medium', note: 'low' };

/** GitHub's numeric scale first, the SARIF level second, medium as the last resort. */
export const severityOf = (result) => {
  const score = Number(result.properties?.['security-severity']);
  if (Number.isFinite(score)) {
    if (score >= 9) return 'critical';
    if (score >= 7) return 'high';
    if (score >= 4) return 'medium';
    return 'low';
  }
  return FROM_LEVEL[result.level] ?? 'medium';
};

const resultsOf = (document) =>
  (document.runs ?? []).flatMap((run) => (run.results ?? []).filter((r) => !(r.suppressions ?? []).length));

const ranOf = (document) =>
  (document.runs ?? []).every((run) => (run.invocations ?? []).every((i) => i.executionSuccessful !== false));

/** Counts, the highest severity seen, which jobs skipped, and every finding. */
export const summarize = (entries) => {
  const counts = { critical: 0, high: 0, medium: 0, low: 0 };
  const skipped = [];
  const findings = [];
  for (const { job, document } of entries) {
    if (!ranOf(document)) skipped.push(job);
    for (const result of resultsOf(document)) {
      const severity = severityOf(result);
      counts[severity] += 1;
      findings.push({ job, severity, ruleId: result.ruleId ?? '<no rule>', message: result.message?.text ?? '' });
    }
  }
  const highest = [...ORDER].reverse().find((s) => counts[s] > 0) ?? 'none';
  return { counts, highest, skipped, findings };
};

/** The verdict, its exit code and the lines to print. */
export const verdict = ({ entries, severity, failOn }) => {
  const { counts, highest, skipped, findings } = summarize(entries);
  const floor = ORDER.indexOf(severity);
  const blocking = findings.filter(
    (f) => floor >= 0 && ORDER.indexOf(f.severity) >= floor && failOn.includes(ENGINE_OF[f.job]),
  );
  const lines = entries.map(({ job, document }) => {
    if (skipped.includes(job)) {
      const note = (document.runs ?? [])
        .flatMap((run) => (run.invocations ?? []).flatMap((i) => i.toolExecutionNotifications ?? []))
        .map((n) => n.message?.text)
        .filter(Boolean)[0];
      return `${job}: ${note ?? 'skipped: no reason given'}`;
    }
    const mine = findings.filter((f) => f.job === job);
    if (mine.length === 0) return `${job}: clean`;
    const worst = [...ORDER].reverse().find((s) => mine.some((f) => f.severity === s));
    return `${job}: ${mine.length} finding(s), highest ${worst}`;
  });
  for (const finding of findings) {
    lines.push(`  ${finding.severity}\t${finding.job}\t${finding.ruleId}\t${finding.message}`);
  }
  const name = blocking.length > 0 ? 'fail' : findings.length > 0 ? 'informational' : 'pass';
  lines.push(`security: ${name}, highest ${highest}, ${findings.length} finding(s), ${skipped.length} job(s) skipped`);
  return { verdict: name, highest, counts, lines, exitCode: blocking.length > 0 ? 1 : 0 };
};

const read = (dir) =>
  readdirSync(dir)
    .filter((name) => name.endsWith('.sarif'))
    .sort()
    .map((name) => ({
      job: path.basename(name, '.sarif'),
      document: JSON.parse(readFileSync(path.join(dir, name), 'utf8')),
    }));

/** Command-line entry; returns the exit code. */
export function main(argv = process.argv.slice(2), { log = console.log, error = console.error, env = process.env, readEntries = read } = {}) {
  const dir = argv[0] ?? '.security';
  let entries;
  try {
    entries = readEntries(dir);
  } catch {
    error(`no SARIF files in ${dir}: run a scanner first`);
    return 2;
  }
  const settings = load('security-policy.json', env);
  const outcome = verdict({ entries, severity: settings.severity, failOn: settings.failOn });
  for (const line of outcome.lines) log(line);
  return outcome.exitCode;
}

if (import.meta.main) process.exitCode = main();
```

- [ ] **Step 4: Run the test and watch it pass**

Run: `mise exec -- node --test scripts/security/verdict.test.mjs`
Expected: PASS, 10 tests.

- [ ] **Step 5: Cover the CLI**

Append to `scripts/security/verdict.test.mjs`:

```js
import { main } from './verdict.mjs';

test('the CLI prints the summary and returns the exit code', () => {
  const out = [];
  const readEntries = () => [entry('deps', doc('osv-scanner', [result('critical')]))];
  const code = main(['.security'], { log: (l) => out.push(l), error: () => {}, env: {}, readEntries });
  assert.equal(code, 1);
  assert.ok(out.some((line) => /security: fail/.test(line)));
});

test('a missing directory exits 2 with advice', () => {
  const out = [];
  const readEntries = () => {
    throw new Error('ENOENT');
  };
  assert.equal(main([], { log: () => {}, error: (l) => out.push(l), env: {}, readEntries }), 2);
  assert.match(out[0], /run a scanner first/);
});
```

- [ ] **Step 6: Run the script gate**

Run: `mise exec -- make test-scripts`
Expected: PASS at 100%.

- [ ] **Step 7: Commit**

```bash
git add scripts/security/verdict.mjs scripts/security/verdict.test.mjs
git commit -m "feat(tooling): merge scanner SARIFs into one verdict

Only this step fails on findings: at or above the configured severity, from a
job whose engine class is in failOn. A skipped job is reported as skipped,
never as clean.

Claude-Session: https://claude.ai/code/session_01SpyYZEnJaLFih75JB4EQAW"
git log -1 --format='%h %s'
```

---

### Task 4: The runner harness and the dependency scanner

**Files:**
- Create: `scripts/security/lib/common.sh`
- Create: `scripts/security/deps.sh`
- Create: `osv-scanner.toml`
- Test: `scripts/security/runners.test.mjs`
- Modify: `.mise.toml` (pin `osv-scanner`)
- Modify: `Makefile` (add `check-security-deps`)
- Modify: `AGENTS.md` (command table row)

**Interfaces:**
- Consumes: `config.mjs get jobs.<job>`, `sarif.mjs skip`.
- Produces: `sec_out_dir`, `sec_enabled <job>`, `sec_skip <job> <reason>`, `sec_require <tool> <job>` for every later runner. `scripts/security/deps.sh` writes `$SECURITY_DIR/deps.sarif`.

- [ ] **Step 1: Write the failing test**

Create `scripts/security/runners.test.mjs`. The repo tests pure bash helpers by sourcing them through `bash -c`, the way `verify.test.mjs` does:

```js
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdirSync, mkdtempSync, readFileSync, rmSync, symlinkSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');

const run = (script, { env = {}, args = [] } = {}) =>
  spawnSync('bash', [path.join(root, 'scripts/security', script), ...args], {
    cwd: root,
    encoding: 'utf8',
    env: { ...process.env, CI: '', ...env },
  });

const withDir = (fn) => {
  const dir = mkdtempSync(path.join(tmpdir(), 'security-'));
  try {
    return fn(dir);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
};

// A PATH holding only what the runners themselves need, so the scanner binary
// is genuinely absent. Emptying PATH instead would take `node` with it, and
// the runner could not even write its skipped SARIF - the test would pass for
// the wrong reason.
const withoutScanners = (dir) => {
  const bin = path.join(dir, 'bin');
  mkdirSync(bin, { recursive: true });
  symlinkSync(process.execPath, path.join(bin, 'node'));
  for (const tool of ['bash', 'env', 'mkdir', 'grep', 'dirname', 'sed', 'cat']) {
    const found = spawnSync('/usr/bin/which', [tool], { encoding: 'utf8' }).stdout.trim();
    if (found) symlinkSync(found, path.join(bin, tool));
  }
  return bin;
};

test('a disabled job writes a skipped SARIF and exits 0', () => {
  withDir((dir) => {
    const result = run('deps.sh', { env: { SECURITY_DIR: dir, SECURITY_DEPS: 'false' } });
    assert.equal(result.status, 0, result.stderr);
    const sarif = JSON.parse(readFileSync(path.join(dir, 'deps.sarif'), 'utf8'));
    assert.equal(sarif.runs[0].invocations[0].executionSuccessful, false);
    assert.match(sarif.runs[0].invocations[0].toolExecutionNotifications[0].message.text, /disabled/);
  });
});

test('a missing tool is a skip locally', () => {
  withDir((dir) => {
    const result = run('deps.sh', { env: { SECURITY_DIR: dir, PATH: withoutScanners(dir) } });
    assert.equal(result.status, 0, result.stderr);
    const sarif = JSON.parse(readFileSync(path.join(dir, 'deps.sarif'), 'utf8'));
    assert.match(sarif.runs[0].invocations[0].toolExecutionNotifications[0].message.text, /osv-scanner is not installed/);
  });
});

test('a missing tool is a failure under CI', () => {
  withDir((dir) => {
    const result = run('deps.sh', { env: { SECURITY_DIR: dir, PATH: withoutScanners(dir), CI: 'true' } });
    assert.equal(result.status, 1);
    assert.match(result.stderr, /osv-scanner is not installed/);
  });
});
```

- [ ] **Step 2: Run it and watch it fail**

Run: `mise exec -- node --test scripts/security/runners.test.mjs`
Expected: FAIL, `No such file or directory` for `deps.sh`.

- [ ] **Step 3: Write the harness**

Create `scripts/security/lib/common.sh`:

```bash
#!/usr/bin/env bash
# Shared rules for every security runner. Source it, do not execute it.
#
#   - Output goes to $SECURITY_DIR (default .security), one <job>.sarif each.
#   - A disabled job writes a skipped SARIF and exits 0.
#   - A missing tool is a skip locally and a failure under CI, so "skipped"
#     can never pass for "clean" in the pipeline.
#   - A finding never fails the runner. Only verdict.mjs fails on findings.

sec_out_dir() {
  local dir="${SECURITY_DIR:-.security}"
  mkdir -p "$dir"
  printf '%s' "$dir"
}

# Writes the skipped SARIF for a job and leaves the caller to exit 0.
sec_skip() {
  local job="$1" reason="$2" dir
  dir="$(sec_out_dir)"
  node scripts/security/sarif.mjs skip "$job" "$reason" > "$dir/$job.sarif"
  echo "::notice::$job skipped: $reason"
}

# Exits the runner early when the job is switched off.
sec_enabled() {
  local job="$1"
  [ "$(node scripts/security/config.mjs get "jobs.$job")" = "true" ] && return 0
  sec_skip "$job" "disabled in security-policy.json or the environment"
  exit 0
}

# A tool the runner cannot work without.
sec_require() {
  local tool="$1" job="$2"
  command -v "$tool" >/dev/null 2>&1 && return 0
  if [ -n "${CI:-}" ]; then
    echo "$tool is not installed, and under CI that is a failure, not a skip" >&2
    exit 1
  fi
  sec_skip "$job" "$tool is not installed (mise install)"
  exit 0
}
```

- [ ] **Step 4: Write the dependency runner**

Create `scripts/security/deps.sh`:

```bash
#!/usr/bin/env bash
# Known vulnerabilities, OpenSSF malicious-package records and licences for
# everything in pnpm-lock.yaml, from OSV. Reasoned ignores live in
# osv-scanner.toml, never in a threshold. Findings do not fail this script.
set -euo pipefail
cd "$(dirname "$0")/../.."
# shellcheck source=scripts/security/lib/common.sh
source scripts/security/lib/common.sh

sec_enabled deps
sec_require osv-scanner deps

out="$(sec_out_dir)"
# --format sarif is osv-scanner's own SARIF; exit 1 means "findings", which is
# not a failure here. Anything above 1 is a real error and set -e catches it.
osv-scanner scan source --lockfile pnpm-lock.yaml --format sarif --output "$out/deps.sarif" || [ $? -eq 1 ]
echo "deps: wrote $out/deps.sarif"
```

Make both executable: `chmod +x scripts/security/deps.sh`.

- [ ] **Step 5: Write the scanner's own config**

Create `osv-scanner.toml`. The two image-size advisories are already reasoned in `pnpm-workspace.yaml`; repeat the reason rather than pointing at it, because a reader of an ignore needs the reason in front of them:

```toml
# Reasoned ignores for osv-scanner. One entry per advisory: what it is, why it
# cannot be reached from this app, and what should make us look again. An entry
# with no reason is not mergeable (docs/quality.md, "Suppressing something,
# correctly"). These mirror auditConfig.ignoreGhsas in pnpm-workspace.yaml.

[[IgnoredVulns]]
id = "GHSA-w3rx-r6r6-pgpr"
reason = "image-size <=2.0.2 ICNS infinite loop. Reached only by metro at bundle time, over assets already in this repo; the app binary does not ship metro. Blocked from patching by minimumReleaseAge and by metro's ^1.0.2 range. Re-evaluate when an Expo SDK bump moves metro off image-size 1.x."

[[IgnoredVulns]]
id = "GHSA-5p2g-fcmc-qvqq"
reason = "image-size <=2.0.2 JXL/HEIF infinite loop. Same single caller, same reachability argument and same blockers as GHSA-w3rx-r6r6-pgpr; listed separately so a fix for one cannot keep the other suppressed."
```

- [ ] **Step 6: Pin the tool**

Add to `.mise.toml` under the existing linters, keeping the comment style:

```toml
# Security scanners. Pinned for the same reason as the linters above: CI and a
# laptop must agree about what counts as a finding.
osv-scanner = "2.6.0"
```

Then verify the short name actually resolves, rather than assuming mise's
registry carries it:

Run: `mise install && mise which osv-scanner`
Expected: a path under `~/.local/share/mise`. If mise reports an unknown tool,
use the backend form instead — `"aqua:google/osv-scanner" = "2.6.0"` — and say
so in the commit body, because the same question applies to Semgrep in Task 5
(`"pipx:semgrep"`) and to mobsfscan in a later stage.

- [ ] **Step 7: Add the make target and its AGENTS.md row**

In `Makefile`, after `check-secrets`:

```make
# Security scanners are not in `make check`: external CLIs and minutes, the
# same reason `check-codeql` is out. Each writes a SARIF into .security/ and
# never fails on a finding; `check-security` is what applies the threshold.
check-security-deps: ## Known vulnerabilities and malicious packages in the lockfile (osv-scanner)
	bash scripts/security/deps.sh
```

In `AGENTS.md`, add the matching row to the command table, in the same column layout the table already uses:

```markdown
| `make check-security-deps` | Known vulnerabilities and malicious packages in the lockfile (osv-scanner) |
```

- [ ] **Step 8: Run the tests**

Run: `mise exec -- node --test scripts/security/runners.test.mjs`
Expected: PASS, 3 tests.

Run: `mise exec -- make check-docs`
Expected: PASS — this is the assertion that AGENTS.md and the Makefile agree.

- [ ] **Step 9: Run it for real**

Run: `mise exec -- make check-security-deps`
Expected: writes `.security/deps.sarif` and prints the path. If osv-scanner is not yet installed, `mise install` first. Inspect the file: `node -e "console.log(JSON.parse(require('fs').readFileSync('.security/deps.sarif','utf8')).runs[0].results.length)"`.

- [ ] **Step 10: Commit**

```bash
git add scripts/security/lib/common.sh scripts/security/deps.sh scripts/security/runners.test.mjs osv-scanner.toml .mise.toml Makefile AGENTS.md
git commit -m "feat(tooling): scan the lockfile with osv-scanner

Adds the shared runner harness: a disabled job or a missing tool writes a
skipped SARIF and exits 0 locally, while under CI a missing tool fails.

Claude-Session: https://claude.ai/code/session_01SpyYZEnJaLFih75JB4EQAW"
git log -1 --format='%h %s'
```

---

### Task 5: The source scanner

**Files:**
- Create: `scripts/security/code.sh`
- Create: `.semgrepignore`
- Create: `rules/react-native-secrets.yaml`
- Create: `rules/react-native-secrets.test.ts`
- Modify: `.mise.toml` (pin `semgrep`)
- Modify: `Makefile`, `AGENTS.md`
- Modify: `scripts/security/runners.test.mjs`

**Interfaces:**
- Consumes: the Task 4 harness.
- Produces: `$SECURITY_DIR/code.sarif`.

- [ ] **Step 1: Write the failing test**

Append to `scripts/security/runners.test.mjs`:

```js
test('the code scanner skips when semgrep is absent', () => {
  withDir((dir) => {
    const result = run('code.sh', { env: { SECURITY_DIR: dir, PATH: withoutScanners(dir) } });
    assert.equal(result.status, 0, result.stderr);
    const sarif = JSON.parse(readFileSync(path.join(dir, 'code.sarif'), 'utf8'));
    assert.match(sarif.runs[0].invocations[0].toolExecutionNotifications[0].message.text, /semgrep is not installed/);
  });
});
```

- [ ] **Step 2: Run it and watch it fail**

Run: `mise exec -- node --test scripts/security/runners.test.mjs`
Expected: FAIL on the new test, `code.sh` not found.

- [ ] **Step 3: Write the runner**

Create `scripts/security/code.sh`:

```bash
#!/usr/bin/env bash
# Semgrep CE over the app source: the community TypeScript, secrets and OWASP
# packs, plus this repo's React Native rules in rules/. No React Native ruleset
# exists upstream, which is why rules/ is ours. Findings do not fail this
# script. Paths to leave alone: .semgrepignore.
set -euo pipefail
cd "$(dirname "$0")/../.."
# shellcheck source=scripts/security/lib/common.sh
source scripts/security/lib/common.sh

sec_enabled code
sec_require semgrep code

out="$(sec_out_dir)"
# No --error: a finding is reported, not thrown. --metrics off keeps the run
# offline and tells Semgrep not to phone home with scan statistics.
semgrep scan \
  --config p/typescript --config p/secrets --config p/owasp-top-ten --config rules/ \
  --sarif --output "$out/code.sarif" --metrics off --quiet
echo "code: wrote $out/code.sarif"
```

`chmod +x scripts/security/code.sh`.

- [ ] **Step 4: Write the React Native rules**

Create `rules/react-native-secrets.yaml`. Three rules, each with the test cases Semgrep's own `--test` runner checks:

```yaml
rules:
  - id: rn-secret-in-async-storage
    languages: [typescript, javascript]
    severity: ERROR
    message: >-
      A token or key is being written to AsyncStorage, which is unencrypted on
      both platforms. Use expo-secure-store for secrets.
    metadata:
      category: security
      references:
        - https://docs.expo.dev/versions/latest/sdk/securestore/
    patterns:
      - pattern-either:
          - pattern: AsyncStorage.setItem("...", $VALUE)
          - pattern: AsyncStorage.setItem($KEY, $VALUE)
      - metavariable-regex:
          metavariable: $KEY
          regex: (?i).*(token|secret|password|key|credential).*

  - id: rn-cleartext-fetch
    languages: [typescript, javascript]
    severity: ERROR
    message: >-
      An http:// URL in app code. Cleartext traffic is blocked by App Transport
      Security and the Android network security config, and leaks in transit.
    pattern-regex: (?i)["']http://(?!localhost|127\.0\.0\.1)[^"']+["']

  - id: rn-webview-injected-javascript
    languages: [typescript, javascript]
    severity: WARNING
    message: >-
      injectedJavaScript runs with the page's privileges. Interpolating a value
      into it is an injection; pass data through postMessage instead.
    patterns:
      - pattern: <WebView injectedJavaScript={`...${$X}...`} ... />
```

Create `rules/react-native-secrets.test.ts` — Semgrep matches a rule id to a test file by name, and reads `// ruleid:` and `// ok:` comments:

```ts
// ruleid: rn-secret-in-async-storage
AsyncStorage.setItem('auth_token', token);

// ok: rn-secret-in-async-storage
AsyncStorage.setItem('last_screen', name);

// ruleid: rn-cleartext-fetch
const endpoint = 'http://api.example.com/graphql';

// ok: rn-cleartext-fetch
const local = 'http://localhost:8080/graphql';

// ok: rn-cleartext-fetch
const secure = 'https://api.example.com/graphql';
```

- [ ] **Step 5: Write the ignore list**

Create `.semgrepignore`:

```
# Generated, vendored or not-our-source paths. Everything else is scanned.
node_modules/
ios/
android/
dist/
coverage/
.expo/
src/i18n/locales/
src/graphql/__generated__/
*.test.ts
*.test.tsx
```

- [ ] **Step 6: Pin the tool**

Add to `.mise.toml` beside `osv-scanner`:

```toml
semgrep = "1.177.0"
```

Verify it resolves the same way as in Task 4:

Run: `mise install && mise which semgrep`
Expected: a path under `~/.local/share/mise`. Semgrep is a Python package, so
if the short name is unknown use `"pipx:semgrep" = "1.177.0"`.

- [ ] **Step 7: Add the make target and its AGENTS.md row**

In `Makefile`, after `check-security-deps`:

```make
check-security-code: ## Semgrep over app source: TypeScript, secrets, OWASP packs plus rules/
	bash scripts/security/code.sh
	@command -v semgrep >/dev/null 2>&1 && semgrep --test rules/ || echo "semgrep not installed: rule tests skipped"
```

In `AGENTS.md`:

```markdown
| `make check-security-code` | Semgrep over app source: TypeScript, secrets, OWASP packs plus `rules/` |
```

- [ ] **Step 8: Run the tests**

Run: `mise exec -- node --test scripts/security/runners.test.mjs`
Expected: PASS, 4 tests.

Run: `mise exec -- make check-docs`
Expected: PASS.

- [ ] **Step 9: Prove the rules work**

Run: `mise exec -- semgrep --test rules/`
Expected: every `ruleid:` line matches and every `ok:` line does not. Fix the rule, not the test file, if one fails.

Run: `mise exec -- make check-security-code`
Expected: `.security/code.sarif` written. Expect first-run findings on `localhost` URLs in test files — if any appear, they belong in `.semgrepignore` with a reason, not in a threshold change.

- [ ] **Step 10: Commit**

```bash
git add scripts/security/code.sh scripts/security/runners.test.mjs .semgrepignore rules .mise.toml Makefile AGENTS.md
git commit -m "feat(tooling): scan app source with semgrep and three React Native rules

No React Native ruleset exists upstream, so rules/ carries ours: secrets in
AsyncStorage, cleartext URLs, and interpolation into WebView injectedJavaScript.
Each has Semgrep test cases, run by make check-security-code.

Claude-Session: https://claude.ai/code/session_01SpyYZEnJaLFih75JB4EQAW"
git log -1 --format='%h %s'
```

---

### Task 6: The dependency-policy scanner

**Files:**
- Create: `scripts/security/policy.sh`
- Modify: `pnpm-workspace.yaml` (add `trustPolicy: no-downgrade`)
- Modify: `scripts/security/runners.test.mjs`
- Modify: `Makefile`, `AGENTS.md`

**Interfaces:**
- Consumes: the Task 4 harness, `sarif.mjs lines`.
- Produces: `$SECURITY_DIR/policy.sarif`.

- [ ] **Step 1: Write the failing test**

Append to `scripts/security/runners.test.mjs`:

```js
test('the policy scanner reports a weakened install policy as a finding, not a crash', () => {
  withDir((dir) => {
    const result = run('policy.sh', { env: { SECURITY_DIR: dir, SECURITY_POLICY_FILE: '/dev/null' } });
    assert.equal(result.status, 0, result.stderr);
    const sarif = JSON.parse(readFileSync(path.join(dir, 'policy.sarif'), 'utf8'));
    const rules = sarif.runs[0].results.map((r) => r.ruleId);
    assert.ok(rules.includes('pnpm/minimum-release-age'));
    assert.ok(rules.includes('pnpm/strict-dep-builds'));
    assert.ok(rules.includes('pnpm/trust-policy'));
  });
});

test('the policy scanner is clean against the real workspace file', () => {
  withDir((dir) => {
    const result = run('policy.sh', { env: { SECURITY_DIR: dir } });
    assert.equal(result.status, 0, result.stderr);
    const sarif = JSON.parse(readFileSync(path.join(dir, 'policy.sarif'), 'utf8'));
    assert.deepEqual(sarif.runs[0].results, []);
    assert.equal(sarif.runs[0].invocations[0].executionSuccessful, true);
  });
});
```

- [ ] **Step 2: Run it and watch it fail**

Run: `mise exec -- node --test scripts/security/runners.test.mjs`
Expected: FAIL, `policy.sh` not found.

- [ ] **Step 3: Write the runner**

Create `scripts/security/policy.sh`:

```bash
#!/usr/bin/env bash
# The install-time supply-chain policy, asserted rather than assumed: a
# cooldown before any new release is installed, no implicit build scripts, and
# no silent downgrade of a package's trust. These are settings a hurried pull
# request can weaken in one line, which is exactly why they are scanned.
# Findings do not fail this script.
set -euo pipefail
cd "$(dirname "$0")/../.."
# shellcheck source=scripts/security/lib/common.sh
source scripts/security/lib/common.sh

sec_enabled policy
out="$(sec_out_dir)"
file="${SECURITY_POLICY_FILE:-pnpm-workspace.yaml}"

check() {
  local id="$1" pattern="$2" message="$3"
  if grep -qE "$pattern" "$file" 2>/dev/null; then
    printf 'ok\t%s\t%s\t%s\n' "$id" "$file" "$message"
  else
    printf 'FAIL\t%s\t%s\t%s\n' "$id" "$file" "$message"
  fi
}

{
  check pnpm/minimum-release-age '^minimumReleaseAge: *[1-9]' \
    "minimumReleaseAge must stay set: it is what stops this repo being the first installer of a hijacked release"
  check pnpm/strict-dep-builds '^strictDepBuilds: *true' \
    "strictDepBuilds must stay true: without it a transitive dependency runs its install scripts unreviewed"
  check pnpm/trust-policy '^trustPolicy: *no-downgrade' \
    "trustPolicy must be no-downgrade: it refuses a package whose provenance got weaker than the version already installed"
} | node scripts/security/sarif.mjs lines policy > "$out/policy.sarif"

echo "policy: wrote $out/policy.sarif"
```

`chmod +x scripts/security/policy.sh`.

- [ ] **Step 4: Add the setting the scanner asserts**

In `pnpm-workspace.yaml`, after `strictDepBuilds: true`:

```yaml
# Refuses an install where a package's provenance is weaker than the version
# already in the lockfile - an unsigned or unattested republish of something
# that used to be signed. scripts/security/policy.sh asserts this line exists,
# because weakening it is a one-line change that would otherwise pass review.
trustPolicy: no-downgrade
```

- [ ] **Step 5: Add the make target and its AGENTS.md row**

In `Makefile`:

```make
check-security-policy: ## Assert the pnpm install policy: release cooldown, no implicit builds, no trust downgrade
	bash scripts/security/policy.sh
```

In `AGENTS.md`:

```markdown
| `make check-security-policy` | Assert the pnpm install policy: release cooldown, no implicit builds, no trust downgrade |
```

- [ ] **Step 6: Run the tests**

Run: `mise exec -- node --test scripts/security/runners.test.mjs`
Expected: PASS, 6 tests.

Run: `mise exec -- make check-docs && mise exec -- make check-deps`
Expected: PASS — `check-deps` proves the new `trustPolicy` line does not break a real install.

- [ ] **Step 7: Commit**

```bash
git add scripts/security/policy.sh scripts/security/runners.test.mjs pnpm-workspace.yaml Makefile AGENTS.md
git commit -m "feat(tooling): assert the pnpm supply-chain install policy

Release cooldown, strict dependency builds and a no-downgrade trust policy are
one-line settings a hurried change can weaken, so they are scanned rather than
trusted. Adds trustPolicy: no-downgrade, which the scanner now requires.

Claude-Session: https://claude.ai/code/session_01SpyYZEnJaLFih75JB4EQAW"
git log -1 --format='%h %s'
```

---

### Task 7: The aggregate target and the documentation

**Files:**
- Create: `scripts/security/local.sh`
- Create: `docs/security.md`
- Create: `docs/decisions/0022-security-scanning-before-release.md`
- Modify: `Makefile`, `AGENTS.md`, `docs/quality.md`, `docs/testing.md`, `docs/README.md`, `docs/decisions/README.md`
- Modify: `scripts/security/runners.test.mjs`

**Interfaces:**
- Consumes: every runner from Tasks 4-6, `verdict.mjs` from Task 3.
- Produces: `make check-security`, the documented contract later stages extend.

- [ ] **Step 1: Write the failing test**

Append to `scripts/security/runners.test.mjs`:

```js
test('the aggregate runs the enabled jobs and reports a verdict', () => {
  withDir((dir) => {
    const result = run('local.sh', {
      env: { SECURITY_DIR: dir, SECURITY_CODE: 'false', SECURITY_DEPS: 'false', SECURITY_POLICY: 'true' },
    });
    assert.equal(result.status, 0, result.stderr);
    assert.match(result.stdout, /security: (pass|informational)/);
    assert.match(result.stdout, /deps: skipped/);
  });
});
```

- [ ] **Step 2: Run it and watch it fail**

Run: `mise exec -- node --test scripts/security/runners.test.mjs`
Expected: FAIL, `local.sh` not found.

- [ ] **Step 3: Write the aggregate**

Create `scripts/security/local.sh`:

```bash
#!/usr/bin/env bash
# Every enabled scanner, then the verdict - the same scripts and the same
# verdict CI runs, so a green laptop means a green pipeline. Locally a missing
# tool is a skip; under CI it is a failure.
set -euo pipefail
cd "$(dirname "$0")/../.."
# shellcheck source=scripts/security/lib/common.sh
source scripts/security/lib/common.sh

if [ "$(node scripts/security/config.mjs get enabled)" != "true" ]; then
  echo "security scanning is disabled (SECURITY_ENABLED or security-policy.json)"
  exit 0
fi

out="$(sec_out_dir)"
rm -f "$out"/*.sarif
# Only the source-side jobs exist so far. The binary and LLM jobs join this
# list in their own stages; each is responsible for its own skip line.
for job in deps code policy; do
  bash "scripts/security/$job.sh"
done

node scripts/security/verdict.mjs "$out"
```

`chmod +x scripts/security/local.sh`.

- [ ] **Step 4: Add the make targets and their AGENTS.md rows**

In `Makefile`, before the per-scanner targets:

```make
# Not in `make check` or `make ci`: external CLIs and minutes, the same reason
# `check-codeql` is out. This is the deliberate deeper pass; the pre-push gate
# stays `make check && make test-unit && make test-scripts`.
check-security: ## Every enabled security scanner, then the verdict (see docs/security.md)
	bash scripts/security/local.sh
```

In `AGENTS.md`:

```markdown
| `make check-security` | Every enabled security scanner, then the verdict (see `docs/security.md`) |
```

- [ ] **Step 5: Write the guide**

Create `docs/security.md`:

```markdown
# Security scanning

`make check-security` runs every enabled scanner and prints one verdict. CI
runs the same scripts, so the answer is the same in both places.

## What runs, and where

| Scanner | Make target | Reads | Runs in CI |
| --- | --- | --- | --- |
| osv-scanner | `check-security-deps` | `pnpm-lock.yaml` | every pull request |
| Semgrep CE | `check-security-code` | app source, `rules/` | every pull request |
| pnpm policy | `check-security-policy` | `pnpm-workspace.yaml` | every pull request |

gitleaks and zizmor are security gates too, but they are fast and binary, so
they stay in `make check` as `check-secrets` and `check-ci`. The line is:
`check` owns reproducible pass/fail gates, `check-security*` owns the
SARIF-producing scanners that cost minutes.

## Turning things off

Three layers, resolved in one order: an environment variable wins over
`security-policy.json`, which wins over the built-in default.

| To do this | Do it like this |
| --- | --- |
| Turn everything off for a repository | `SECURITY_ENABLED=false`, or `"enabled": false` in `security-policy.json` |
| Turn one scanner off | `SECURITY_CODE=false`, or `"jobs": { "code": { "enabled": false } }` |
| Change what fails a run | `"severity": "critical"`, or `SECURITY_SEVERITY=critical` |
| Give an engine class teeth | `"failOn": ["deterministic", "review"]` |

A value that is not `true` or `false` fails the run rather than reading as
off, so a typo cannot silently disable a scanner.

## Skipped is not clean

A scanner with nothing to scan - no tool installed, no binary, no key - writes
a SARIF whose run says `executionSuccessful: false` and carries the reason.
The verdict prints `skipped: <reason>` for it and never counts it as clean.
Locally a missing tool is a skip; under CI it is a failure, because a
pipeline that quietly scans nothing is worse than one that is red.

## Suppressing a finding, correctly

Each scanner reads its own config, and every suppression carries a reason:
`osv-scanner.toml` for advisories, `.semgrepignore` and `rules/` for source
patterns, `.gitleaks.toml` for secrets, `.github/zizmor.yml` for workflows.
Never raise the severity threshold to hide one finding - that hides the next
one too.
```

- [ ] **Step 6: Write the decision record**

Create `docs/decisions/0022-security-scanning-before-release.md`, matching the length and shape of the existing records:

```markdown
# 22. Security scanning before release

Date: 2026-09-24

## Status

Accepted

## Context

The family scans for some things already - `pnpm audit`, a licence allowlist,
CodeQL, gitleaks, zizmor - but nothing reads the dependency graph for known
vulnerabilities or malicious-package records, nothing pattern-matches app
source for mobile-specific mistakes, and the install-time supply-chain
settings are trusted rather than asserted. AI-driven supply-chain attacks were
the prompt for looking at this.

## Decision

Scanners write SARIF; a single verdict step applies the threshold. Place each
check by what it reads: source on every pull request, built binaries at the
production dispatch. Deterministic scanners can block; an LLM reviewer
annotates until a consumer explicitly gives it teeth, because a gate that
flakes gets disabled or teaches people to merge past red.

Tunables live in `security-policy.json`, one file in the repository, with an
environment variable able to override any of them. Everything runs locally
through `make check-security*`, so CI and a laptop execute the same scripts.

Jev is excluded: a closed, waitlisted decision model whose own documentation
says adversarial input moves its verdicts, offering no detection an LLM
reviewer or gitleaks lacks.

## Consequences

A first run produces a baseline of findings; each gets a reasoned ignore in
its scanner's own config, never a threshold change. Scanners are external
CLIs, so `make check-security` is minutes and stays out of `make check` and
`make ci`, like `check-codeql`. A repository that finds it overkill sets
`SECURITY_ENABLED=false`.
```

- [ ] **Step 7: Register the new docs**

- `docs/README.md`: add a row for `security.md` in the index table, next to `quality.md`.
- `docs/decisions/README.md`: add the row for record 0022.
- `docs/quality.md`: in the "Who owns what" table, add rows for osv-scanner (`osv-scanner.toml`), Semgrep (`rules/`, `.semgrepignore`) and the pnpm policy scanner (`security-policy.json`), and a sentence pointing at `docs/security.md`.
- `docs/testing.md`: add the rows for `scripts/security/*.test.mjs` in the table of what runs in `make ci`.

- [ ] **Step 8: Run every gate**

Run: `mise exec -- make check-docs`
Expected: PASS — the AGENTS.md assertion plus table widths and doc freshness.

Run: `mise exec -- make test-scripts`
Expected: PASS at 100% coverage.

Run: `mise exec -- make ci`
Expected: PASS. This is the gate that must be green before pushing anything under `scripts/`.

Run: `mise exec -- make check-security`
Expected: the three scanners run and a verdict line prints. Record the baseline findings — they are the subject of the pull request description, and each needs a reasoned ignore in its own config file before this merges.

- [ ] **Step 9: Commit**

```bash
git add scripts/security/local.sh scripts/security/runners.test.mjs docs/security.md docs/decisions/0022-security-scanning-before-release.md docs/README.md docs/decisions/README.md docs/quality.md docs/testing.md Makefile AGENTS.md
git commit -m "feat(tooling): add make check-security and document the gate

Runs every enabled scanner and prints one verdict, from the same scripts CI
will run. ADR 0022 records why scanning is placed by what each check reads,
and why an LLM reviewer annotates rather than blocks.

Claude-Session: https://claude.ai/code/session_01SpyYZEnJaLFih75JB4EQAW"
git log -1 --format='%h %s'
```

---

## What this plan deliberately leaves out

Each is its own plan, stacked after this one, because each is independently
reviewable and none blocks the others:

- **Binary and MASTG checks** (`binaries`, `mobile`, `bundle`, `sbom`): needs
  built artifacts, `apksigner`/`aapt2`/`plistlib`/`openssl`, and the rewrite of
  `check-bundle-secrets.sh` into `bundle-strings.sh`.
- **The LLM engines** (`review`, `openant`): moving the adapters to
  `scripts/lib/llm/`, the effort knob shared with the store-notes rewrite, the
  prompt file, and provider portability through `OPENAI_BASE_URL`.
- **The reusable workflow and the call sites**: `check-security.yml` in
  shared-workflows, then `ci.yml` and `cd-production.yml` here. Stage 3 cannot
  merge until `v0` carries the workflow file — a `uses:` of a missing workflow
  is a `startup_failure` for the whole run, on `main` too.

import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdirSync, mkdtempSync, readFileSync, rmSync, symlinkSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { after, test } from 'node:test';
import { fileURLToPath } from 'node:url';
import {
  activeProfiles,
  callerCalls,
  callerInputs,
  callersUse,
  callProblems,
  check,
  checkCalls,
  checkRequirement,
  defaultIo,
  formatResult,
  isProgram,
  main,
  parseArgs,
  parseMiseTools,
  readCallers,
  readConsumer,
  readContract,
  readInterfaces,
  readMakefile,
  readMiseTools,
  scalarType,
  skeleton,
  summaryTable,
  toggleOn,
} from './bin/check-contract.mjs';

// A consumer, as the checks see one. No temp directories: `io` is the only way
// any check reaches a disk, so a fixture is an object literal.
function consumer({ files = {}, dirs = [], pkg = {}, callers = {} } = {}) {
  const io = {
    read: (file) => (file in files ? files[file] : null),
    exists: (file) => file in files || dirs.includes(file),
    isNonEmptyDir: (dir) => dirs.includes(dir),
    list: (dir) => {
      const prefix = `${dir}/`;
      return [...Object.keys(files), ...dirs]
        .filter((f) => f.startsWith(prefix))
        .map((f) => f.slice(prefix.length))
        .filter((f) => !f.includes('/'));
    },
  };
  const callerList = Object.entries(callers).map(([name, text]) => ({ name, text }));
  return {
    root: '',
    io,
    pkg,
    scripts: pkg.scripts ?? {},
    deps: { ...(pkg.dependencies ?? {}), ...(pkg.devDependencies ?? {}) },
    miseTools: { file: '.mise.toml', tools: new Set(['node', 'pnpm']) },
    callers: callerList,
    uses: callersUse(callerList),
    inputs: callerInputs(callerList),
  };
}

const req = (id) => readContract().requirements.find((r) => r.id === id);

// --- the contract itself -----------------------------------------------------

test('every requirement declares the fields the report depends on', () => {
  const kinds = new Set([
    'package-script',
    'package-dep',
    'file',
    'dir-nonempty',
    'pinned-tool',
    'ignores-workflows',
    'ignores-workflows-or-narrow',
    'caller-path',
    'lane',
    'make-ci-reaches-ci',
    'ci-runs-make-ci',
    'lane-environment',
    'no-copy',
    'one-pin',
  ]);
  const profiles = new Set(readContract().profiles);
  for (const r of readContract().requirements) {
    assert.ok(kinds.has(r.kind), `${r.id}: unknown kind ${r.kind}`);
    assert.ok(profiles.has(r.profile), `${r.id}: unknown profile ${r.profile}`);
    assert.ok(['required', 'degrades', 'optional'].includes(r.severity), `${r.id}: bad severity`);
    assert.ok(r.fix && r.fix.length > 20, `${r.id}: needs a fix that says what to do`);
    assert.ok(r.guide, `${r.id}: needs a guide anchor`);
    assert.ok(r.neededBy, `${r.id}: needs to say what wants it`);
    assert.equal(typeof r.defaultOn, 'boolean', `${r.id}: defaultOn must be a boolean`);
  }
});

test('requirement ids are unique', () => {
  const ids = readContract().requirements.map((r) => r.id);
  assert.deepEqual([...new Set(ids)].length, ids.length);
});

// --- reading the caller ------------------------------------------------------

const CALLER = `name: CI
on: [push]
jobs:
  checks:
    name: Checks
    uses: blinkbitcoin/shared-workflows/.github/workflows/check.yml@v0
    with:
      docs: false
      release: true
  unit:
    name: Unit
    uses: blinkbitcoin/shared-workflows/.github/workflows/test-unit.yml@v0
  e2e:
    name: E2E
    uses: blinkbitcoin/shared-workflows/.github/workflows/test-e2e.yml@v0
    with:
      ios: \${{ vars.E2E_IOS == 'true' }}
      e2e-setup-script: scripts/e2e/up.sh
`;

test('the caller parser finds which reusable workflows a repository calls', () => {
  const uses = callersUse([{ name: 'ci.yml', text: CALLER }]);
  assert.deepEqual([...uses].sort(), ['check.yml', 'test-e2e.yml', 'test-unit.yml']);
});

test('the caller parser attributes each with: key to its own workflow', () => {
  const inputs = callerInputs([{ name: 'ci.yml', text: CALLER }]);
  assert.equal(inputs.get('check.yml:docs'), 'false');
  assert.equal(inputs.get('check.yml:release'), 'true');
  assert.equal(inputs.get('test-e2e.yml:e2e-setup-script'), 'scripts/e2e/up.sh');
  // test-unit.yml has no with: block, so nothing may leak into it from its neighbours
  assert.equal(inputs.get('test-unit.yml:docs'), undefined);
});

test('a top-level key after a caller job ends that job, with or without a with: block', () => {
  const inputs = callerInputs([
    {
      name: 'ci.yml',
      text: `jobs:
  plain:
    uses: blinkbitcoin/shared-workflows/.github/workflows/test-unit.yml@v0
env:
  coverage: false
---
jobs:
  checks:
    uses: blinkbitcoin/shared-workflows/.github/workflows/check.yml@v0
    with:
      lint: false
concurrency:
  spell: false
`,
    },
  ]);
  assert.deepEqual([...inputs], [['check.yml:lint', 'false']]);
});

test('a profile is active only when the repository calls that workflow', () => {
  const uses = callersUse([{ name: 'ci.yml', text: CALLER }]);
  const active = activeProfiles(uses);
  assert.ok(active.has('checks') && active.has('unit') && active.has('e2e'));
  assert.ok(!active.has('web'), 'build-web.yml is not called, so web must not be checked');
  assert.ok(!active.has('release'));
});

test('a repository with no caller yet is checked against what every consumer needs', () => {
  assert.deepEqual([...activeProfiles(new Set())].sort(), ['checks', 'unit']);
});

test('an explicit --profile overrides what the callers say', () => {
  assert.deepEqual([...activeProfiles(new Set(['check.yml']), ['release'])], ['release']);
});

// --- toggles -----------------------------------------------------------------

test('a gate the caller switched off is not a finding', () => {
  const inputs = callerInputs([{ name: 'ci.yml', text: CALLER }]);
  assert.equal(toggleOn(req('package-script.check-docs'), inputs), false);
});

test('a gate the caller switched on is checked even when it defaults off', () => {
  const inputs = callerInputs([{ name: 'ci.yml', text: CALLER }]);
  assert.equal(req('package-script.check-release').defaultOn, false);
  assert.equal(toggleOn(req('package-script.check-release'), inputs), true);
});

test('an input the caller leaves alone falls back to the workflow default', () => {
  assert.equal(toggleOn(req('package-script.check-types'), new Map()), true);
  assert.equal(toggleOn(req('package-script.check-prebuild'), new Map()), false);
});

test('a toggle wired to an expression is neither on nor off', () => {
  const inputs = new Map([['check.yml:types', '${{ vars.TYPES }}']]);
  assert.equal(toggleOn(req('package-script.check-types'), inputs), 'unknown');
});

test('a requirement behind an expression is reported but never blocks', () => {
  // This job gates every other job in check.yml. Blocking ten of them because
  // a `${{ vars.X }}` could not be read here would be a false failure - and
  // staying silent would hide a real one. So: warn, and say why.
  const caller = [
    'jobs:',
    '  checks:',
    '    uses: blinkbitcoin/shared-workflows/.github/workflows/check.yml@v0',
    '    with:',
    '      types: ${{ vars.TYPES }}',
  ].join('\n');
  const c = consumer({ callers: { 'ci.yml': caller } });
  const result = check(readContract(), c).find((r) => r.req.id === 'package-script.check-types');
  assert.equal(result.level, 'warn');
  assert.match(result.reason, /cannot evaluate/);
});

// --- individual checks -------------------------------------------------------

test('a package script is found by name', () => {
  const c = consumer({ pkg: { scripts: { 'check:types': 'tsc --noEmit' } } });
  assert.equal(checkRequirement(req('package-script.check-types'), c).status, 'ok');
  assert.equal(checkRequirement(req('package-script.check-lint'), c).status, 'missing');
});

test('the unused-code gate is a package script like every other gate', () => {
  // Not the knip binary: a script named for the stem, which a package.json
  // may hold without tripping expo-doctor's check on a script named `knip`.
  const asScript = consumer({ pkg: { scripts: { 'check:unused': 'knip' } } });
  assert.equal(checkRequirement(req('package-script.check-unused'), asScript).status, 'ok');
  const asDep = consumer({ pkg: { devDependencies: { knip: '^6' } } });
  assert.equal(checkRequirement(req('package-script.check-unused'), asDep).status, 'missing');
});

test('the mise check names the tool that is missing, not just the file', () => {
  const c = consumer();
  c.miseTools = { file: '.mise.toml', tools: new Set(['node']) };
  const result = checkRequirement(req('pinned-tool.node-pnpm'), c);
  assert.equal(result.status, 'missing');
  assert.match(result.reason, /pins no pnpm/);
});

test('no mise config at all is reported as the missing file', () => {
  const c = consumer();
  c.miseTools = { file: null, tools: new Set() };
  assert.match(checkRequirement(req('pinned-tool.node-pnpm'), c).reason, /no mise config/);
});

test('the mise reader takes only the [tools] table', () => {
  const tools = parseMiseTools(`
[tools]
node = "24"
pnpm = "12"

[env]
NODE_ENV = "test"
EXPO_NO_TELEMETRY = "1"
`);
  assert.deepEqual([...tools].sort(), ['node', 'pnpm']);
});

test('a file requirement is satisfied by any one of its alternatives', () => {
  assert.equal(checkRequirement(req('file.expo-configuration'), consumer({ files: { 'app.json': '{}' } })).status, 'ok');
  assert.equal(checkRequirement(req('file.expo-configuration'), consumer()).status, 'missing');
});

test('an e2e hook input naming a file that does not exist is a finding', () => {
  const c = consumer({ callers: { 'ci.yml': CALLER } });
  const result = checkRequirement(req('caller-path.e2e-hooks'), c);
  assert.equal(result.status, 'missing');
  assert.match(result.reason, /scripts\/e2e\/up\.sh, which does not exist/);
});

test('an e2e hook input left empty is not a finding', () => {
  const c = consumer({ callers: { 'ci.yml': CALLER.replace('e2e-setup-script: scripts/e2e/up.sh', "e2e-setup-script: ''") } });
  assert.equal(checkRequirement(req('caller-path.e2e-hooks'), c).status, 'ok');
});

test('a config this repository does not have is skipped, not failed', () => {
  // A consumer with no biome.json does not use biome, so nothing of ours is in
  // its reach and there is nothing for it to exclude.
  assert.equal(checkRequirement(req('ignores-workflows.biome-json'), consumer()).status, 'skip');
});

test('a config that globs the whole tree must exclude the .workflows checkout', () => {
  const blind = consumer({ files: { 'biome.json': '{"files":{"includes":["**/*.ts"]}}' } });
  assert.equal(checkRequirement(req('ignores-workflows.biome-json'), blind).status, 'missing');
  const excluded = consumer({ files: { 'biome.json': '{"files":{"includes":["**/*.ts","!**/.workflows"]}}' } });
  assert.equal(checkRequirement(req('ignores-workflows.biome-json'), excluded).status, 'ok');
});

test('knip is satisfied by globs that never reach into .workflows', () => {
  // The guide accepts either answer for knip, and the template ships the second
  // one. Demanding the ignore entry would report a finding the consumer would be
  // right to ignore.
  const narrow = consumer({ files: { 'knip.json': '{"project":["src/**/*.ts","scripts/**/*.mjs"]}' } });
  assert.equal(checkRequirement(req('ignores-workflows-or-narrow.knip-json'), narrow).status, 'ok');
  const treeWide = consumer({ files: { 'knip.json': '{"project":["**/*.ts"]}' } });
  assert.equal(checkRequirement(req('ignores-workflows-or-narrow.knip-json'), treeWide).status, 'missing');
});

test('a missing fastlane lane is named, and no fastlane at all is skipped', () => {
  const noFastlane = consumer();
  assert.equal(checkRequirement(req('lane.build-verify'), noFastlane).status, 'skip');
  const partial = consumer({
    dirs: ['fastlane'],
    files: { 'fastlane/Fastfile': 'platform :ios do\n  lane :build do\n  end\nend\n' },
  });
  const result = checkRequirement(req('lane.build-verify'), partial);
  assert.equal(result.status, 'missing');
  assert.match(result.reason, /verify/);
});

// --- severity ----------------------------------------------------------------

test('a missing required item blocks and a missing fallback item only degrades', () => {
  const c = consumer({ callers: { 'ci.yml': 'uses: blinkbitcoin/shared-workflows/.github/workflows/check.yml@v0\n' } });
  const results = check(readContract(), c);
  const byId = new Map(results.map((r) => [r.req.id, r]));
  assert.equal(byId.get('package-script.check-types').level, 'fail');
  assert.equal(byId.get('package-script.check-audit').level, 'warn');
});

test('a workflow this repository does not call produces no findings at all', () => {
  const c = consumer({ callers: { 'ci.yml': 'uses: blinkbitcoin/shared-workflows/.github/workflows/check.yml@v0\n' } });
  const results = check(readContract(), c);
  for (const result of results.filter((r) => r.req.profile === 'release')) {
    assert.equal(result.level, 'skip', `${result.req.id} should be skipped`);
  }
});

// --- reporting ---------------------------------------------------------------

test('every finding carries its fix, and a pass carries none', () => {
  const c = consumer({ callers: { 'ci.yml': 'uses: blinkbitcoin/shared-workflows/.github/workflows/check.yml@v0\n' } });
  for (const result of check(readContract(), c)) {
    const line = formatResult(result);
    if (result.level === 'fail' || result.level === 'warn') {
      assert.match(line, /Fix: /, `${result.req.id} must tell the reader what to do`);
    } else {
      assert.doesNotMatch(line, /Fix: /);
    }
  }
});

test('the skeleton names each missing gate script by its family-stem name', () => {
  const c = consumer({ callers: { 'ci.yml': 'uses: blinkbitcoin/shared-workflows/.github/workflows/check.yml@v0\n' } });
  const text = skeleton(check(readContract(), c));
  assert.match(text, /"check:unused":/);
  assert.doesNotMatch(text, /"knip":/);
});

test('the skeleton lists a missing required dependency as a devDependency', () => {
  const c = consumer({ callers: { 'ci.yml': 'uses: blinkbitcoin/shared-workflows/.github/workflows/build-web.yml@v0\n' } });
  assert.match(skeleton(check(readContract(), c)), /devDependencies: @playwright\/test/);
});

test('the job summary distinguishes a blocked row from a degraded one', () => {
  const c = consumer({ callers: { 'ci.yml': 'uses: blinkbitcoin/shared-workflows/.github/workflows/check.yml@v0\n' } });
  const table = summaryTable(check(readContract(), c));
  assert.match(table, /\*\*blocked\*\*/);
  assert.match(table, /degraded/);
  assert.match(table, /consumer-guide\.md#/);
});

test('a clean consumer gets a summary that says so rather than an empty table', () => {
  const table = summaryTable([{ req: req('package-script.check-lint'), level: 'ok' }]);
  assert.doesNotMatch(table, /\| --- \|/);
  assert.match(table, /satisfied/);
});

// --- make ci and CI run the same gates ---------------------------------------
//
// These are the rules that used to live in this repository's own bats suite and
// ran against a checkout of one consumer's main. They run in each consumer's
// Contract job instead, so a consumer that drifts fails its own PR.

const GATE_CALLER = {
  'ci.yml': `jobs:
  checks:
    uses: blinkbitcoin/shared-workflows/.github/workflows/check.yml@v0
    with:
      docs: false
      spell: false
      unused: false
      licenses: false
      expo-health: false
      audit: false
      ci: false
      secrets: false
  unit:
    uses: blinkbitcoin/shared-workflows/.github/workflows/test-unit.yml@v0
`,
};

// With the caller above, CI runs check:types, check:lint, check:format,
// test:coverage and test:scripts - and nothing else.
const ALIGNED_MAKEFILE = `check: check-types check-lint check-format ## gates
check-types: ## types
\tpnpm check:types
check-lint:
\tpnpm check:lint
check-format:
\tpnpm check:format
coverage:
\tpnpm test:coverage
test-scripts:
\tpnpm test:scripts
ci: check coverage test-scripts ## everything
`;

const gateResults = (makefile, callers = GATE_CALLER) => {
  const c = consumer({ files: makefile === null ? {} : { Makefile: makefile }, callers });
  const byId = new Map(check(readContract(), c).map((r) => [r.req.id, r]));
  return { reaches: byId.get('make-ci-reaches-ci.ci'), runs: byId.get('ci-runs-make-ci.ci') };
};

test('an aligned Makefile passes both gate-set rules', () => {
  const { reaches, runs } = gateResults(ALIGNED_MAKEFILE);
  assert.equal(reaches.level, 'ok', reaches.reason);
  assert.equal(runs.level, 'ok', runs.reason);
});

test('a make ci target no CI step runs fails, naming the target', () => {
  const { runs } = gateResults(`${ALIGNED_MAKEFILE}check-skills:\n\tbash scripts/check-skills.sh\nci: check coverage test-scripts check-skills\n`);
  assert.equal(runs.level, 'fail');
  assert.match(runs.reason, /check-skills/);
});

test('a pnpm script make ci runs and CI does not fails, naming the script', () => {
  const { runs } = gateResults(ALIGNED_MAKEFILE.replace('\tpnpm test:coverage\n', '\tpnpm test:coverage\n\tpnpm check:coverage-empty\n'));
  assert.equal(runs.level, 'fail');
  assert.match(runs.reason, /coverage \(pnpm check:coverage-empty\)/);
});

test('a script CI runs that make ci cannot reach fails, naming the script', () => {
  const { reaches } = gateResults(ALIGNED_MAKEFILE.replace('ci: check coverage test-scripts', 'ci: check coverage'));
  assert.equal(reaches.level, 'fail');
  assert.match(reaches.reason, /"test:scripts"/);
});

test('a gate the caller switched off is neither required locally nor an orphan when present', () => {
  // spell is off in GATE_CALLER: `make ci` need not reach it...
  assert.equal(gateResults(ALIGNED_MAKEFILE).reaches.level, 'ok');
  // ...but a make ci target running it is a local-only gate, which is the drift.
  const { runs } = gateResults(`${ALIGNED_MAKEFILE}check-spell:\n\tpnpm check:spell\nci: check coverage test-scripts check-spell\n`);
  assert.equal(runs.level, 'fail');
  assert.match(runs.reason, /spell/);
});

test('a toggle wired to an expression never fails the gate-set rules', () => {
  const callers = { 'ci.yml': GATE_CALLER['ci.yml'].replace('spell: false', 'spell: ${{ vars.SPELL }}') };
  const withSpell = `${ALIGNED_MAKEFILE}check-spell:\n\tpnpm check:spell\nci: check coverage test-scripts check-spell\n`;
  assert.equal(gateResults(withSpell, callers).runs.level, 'ok');
  assert.equal(gateResults(ALIGNED_MAKEFILE, callers).reaches.level, 'ok');
});

test('no Makefile skips both gate-set rules rather than failing', () => {
  const { reaches, runs } = gateResults(null);
  assert.equal(reaches.level, 'skip');
  assert.equal(runs.level, 'skip');
});

test('the Makefile reader follows prerequisites and keeps recipes per target', () => {
  const c = consumer({ files: { Makefile: ALIGNED_MAKEFILE } });
  const make = readMakefile('', c.io);
  assert.deepEqual([...make.reachable('ci')].sort(), ['check', 'check-format', 'check-lint', 'check-types', 'ci', 'coverage', 'test-scripts']);
  assert.equal(make.rules.get('check').recipe, '');
  assert.match(make.rules.get('coverage').recipe, /pnpm test:coverage/);
});

// --- the lanes read only the App Review names the lane workflow passes -------

const laneResult = (ruby) => {
  const c = consumer({
    files: { 'fastlane/Fastfile': ruby },
    dirs: ['fastlane'],
    callers: { 'r.yml': 'uses: blinkbitcoin/shared-workflows/.github/workflows/publish-store.yml@v0\n' },
  });
  return check(readContract(), c).find((r) => r.req.id === 'lane-environment.app-review');
};

test('lanes reading only passed App Review names pass', () => {
  const result = laneResult("x = ENV['APP_REVIEW_EMAIL']\ny = ENV.fetch('APP_REVIEW_NOTES', '')\n");
  assert.equal(result.level, 'ok', result.reason);
});

test('a lane reading an App Review name the workflow does not pass fails, naming it', () => {
  const result = laneResult("x = ENV['APP_REVIEW_EMAIL']\ny = ENV['APP_REVIEW_COMPANY']\n");
  assert.equal(result.level, 'fail');
  assert.match(result.reason, /APP_REVIEW_COMPANY/);
});

// --- the real filesystem -----------------------------------------------------
//
// Everything above reaches the disk through an object literal. The cases below
// hold the real `defaultIo`, and the program around it, to the same contract
// against a temporary directory.

const BIN = fileURLToPath(new URL('./bin/check-contract.mjs', import.meta.url));
const GUIDE = 'https://github.com/blinkbitcoin/shared-workflows/blob/v0/docs/consumer-guide.md';
const temporaryDirectories = [];
after(() => {
  for (const dir of temporaryDirectories) rmSync(dir, { recursive: true, force: true });
});

/** A real directory holding `files` (path to text), for the code that reads a disk. */
function tree(files = {}) {
  const root = mkdtempSync(path.join(tmpdir(), 'app-tooling-contract-'));
  temporaryDirectories.push(root);
  for (const [name, text] of Object.entries(files)) {
    mkdirSync(path.dirname(path.join(root, name)), { recursive: true });
    writeFileSync(path.join(root, name), text);
  }
  return root;
}

/** A writable stream that keeps what it was given, as `.text`. */
function sink() {
  return {
    text: '',
    write(chunk) {
      this.text += chunk;
      return true;
    },
  };
}

/** Runs `main` against a real directory; the environment is empty unless given. */
function runMain(argv, { env = {}, io, cwd = '/' } = {}) {
  const stdout = sink();
  const stderr = sink();
  const code = main(argv, { stdout, stderr, env, cwd, ...(io ? { io } : {}) });
  return { code, stdout: stdout.text, stderr: stderr.text };
}

const CHECKS_CALLER = 'uses: blinkbitcoin/shared-workflows/.github/workflows/check.yml@v0\n';

test('the default io reads a file, and answers null for one that is not there', () => {
  const root = tree({ 'a.txt': 'hello' });
  assert.equal(defaultIo.read(path.join(root, 'a.txt')), 'hello');
  assert.equal(defaultIo.read(path.join(root, 'absent.txt')), null);
});

test('the default io says whether a path exists', () => {
  const root = tree({ 'a.txt': '' });
  assert.equal(defaultIo.exists(path.join(root, 'a.txt')), true);
  assert.equal(defaultIo.exists(path.join(root, 'absent.txt')), false);
});

test('the default io counts only a directory with entries as a non-empty directory', () => {
  const root = tree({ 'full/a.txt': '', 'file.txt': '' });
  mkdirSync(path.join(root, 'empty'));
  assert.equal(defaultIo.isNonEmptyDir(path.join(root, 'full')), true);
  assert.equal(defaultIo.isNonEmptyDir(path.join(root, 'empty')), false);
  assert.equal(defaultIo.isNonEmptyDir(path.join(root, 'file.txt')), false);
  assert.equal(defaultIo.isNonEmptyDir(path.join(root, 'absent')), false);
});

test('the default io lists a directory, and a missing one as empty', () => {
  const root = tree({ 'dir/a.txt': '', 'dir/b.txt': '' });
  assert.deepEqual(defaultIo.list(path.join(root, 'dir')).sort(), ['a.txt', 'b.txt']);
  assert.deepEqual(defaultIo.list(path.join(root, 'absent')), []);
});

test('the default io appends to a file rather than replacing it', () => {
  const root = tree({ 'summary.md': 'first\n' });
  defaultIo.append(path.join(root, 'summary.md'), 'second\n');
  assert.equal(readFileSync(path.join(root, 'summary.md'), 'utf8'), 'first\nsecond\n');
});

// --- reading a consumer from disk ---------------------------------------------

test('a consumer is read from disk: scripts, both dependency tables, mise and callers', () => {
  const root = tree({
    'package.json': JSON.stringify({
      scripts: { lint: 'biome check' },
      dependencies: { react: '19.0.0' },
      devDependencies: { knip: '5.0.0' },
    }),
    '.mise.toml': '[tools]\nnode = "24"\n',
    '.github/workflows/ci.yml': `jobs:\n  checks:\n    uses: blinkbitcoin/shared-workflows/.github/workflows/check.yml@v0\n    with:\n      lint: false\n`,
  });
  const read = readConsumer(root);
  assert.equal(read.root, root);
  assert.equal(read.io, defaultIo);
  assert.deepEqual(read.scripts, { lint: 'biome check' });
  assert.deepEqual(read.deps, { react: '19.0.0', knip: '5.0.0' });
  assert.equal(read.miseTools.file, '.mise.toml');
  assert.deepEqual([...read.miseTools.tools], ['node']);
  assert.deepEqual(read.callers.map((c) => c.name), ['ci.yml']);
  assert.deepEqual([...read.uses], ['check.yml']);
  assert.equal(read.inputs.get('check.yml:lint'), 'false');
});

test('a consumer with no package.json has no scripts and no dependencies', () => {
  const read = readConsumer(tree());
  assert.equal(read.pkg, null);
  assert.deepEqual(read.scripts, {});
  assert.deepEqual(read.deps, {});
});

test('a package.json with neither scripts nor dependencies reads as empty tables', () => {
  const read = readConsumer(tree({ 'package.json': '{"name":"hello-world"}' }));
  assert.deepEqual(read.pkg, { name: 'hello-world' });
  assert.deepEqual(read.scripts, {});
  assert.deepEqual(read.deps, {});
});

test('a package.json that does not parse is an error naming the file, not a report', () => {
  const root = tree({ 'package.json': '{ not json' });
  assert.throws(() => readConsumer(root), (error) => {
    assert.match(error.message, /^::error::.*package\.json is not valid JSON: /);
    assert.ok(error.message.includes(path.join(root, 'package.json')));
    return true;
  });
});

test('the mise reader tries each config name in order, and reports none as no file', () => {
  assert.deepEqual(readMiseTools(tree()), { file: null, tools: new Set() });
  assert.equal(readMiseTools(tree({ 'mise.toml': '[tools]\nnode = "24"\n' })).file, 'mise.toml');
  assert.equal(readMiseTools(tree({ '.config/mise/config.toml': '[tools]\nnode = "24"\n' })).file, '.config/mise/config.toml');
  const both = readMiseTools(tree({ '.mise.toml': '[tools]\npnpm = "10"\n', 'mise.toml': '[tools]\nnode = "24"\n' }));
  assert.equal(both.file, '.mise.toml');
  assert.deepEqual([...both.tools], ['pnpm']);
});

test('the caller reader takes .yml and .yaml files only', () => {
  const root = tree({
    '.github/workflows/a.yml': 'one',
    '.github/workflows/b.yaml': 'two',
    '.github/workflows/README.md': 'three',
  });
  assert.deepEqual(
    readCallers(root).sort((x, y) => x.name.localeCompare(y.name)),
    [
      { name: 'a.yml', text: 'one' },
      { name: 'b.yaml', text: 'two' },
    ],
  );
});

test('a repository with no workflows directory has no callers', () => {
  assert.deepEqual(readCallers(tree()), []);
});

test('a caller file that cannot be read counts as an empty caller', () => {
  const io = { list: () => ['ci.yml'], read: () => null };
  assert.deepEqual(readCallers('', io), [{ name: 'ci.yml', text: '' }]);
});

// --- the checks the cases above do not reach ----------------------------------

test('a directory requirement wants the directory to hold something', () => {
  const withFlows = consumer({ dirs: ['.maestro'] });
  assert.deepEqual(checkRequirement(req('dir-nonempty.maestro'), withFlows), { status: 'ok', detail: undefined });
  assert.deepEqual(checkRequirement(req('dir-nonempty.maestro'), consumer()), { status: 'missing', reason: '.maestro/ is missing or empty' });
});

const PIN = '1'.repeat(40);
const pinnedCaller = (sha = PIN) => ({
  'ci.yml': `jobs:\n  code:\n    uses: blinkbitcoin/shared-workflows/.github/workflows/check.yml@${sha} # v1.0.0\n`,
});
const pinnedPkg = (sha = PIN) => ({
  devDependencies: { '@blinkbitcoin/app-tooling': `github:blinkbitcoin/shared-workflows#${sha}&path:/packages/app-tooling` },
});
const pinnedLock = (sha = PIN) => ({
  'pnpm-lock.yaml': `    version: https://codeload.github.com/blinkbitcoin/shared-workflows/tar.gz/${sha}#path:/packages/app-tooling\n`,
});

test('the one-pin requirement passes when calls, package.json and the lockfile share one commit', () => {
  const c = consumer({ callers: pinnedCaller(), pkg: pinnedPkg(), files: pinnedLock() });
  assert.deepEqual(checkRequirement(req('one-pin.one-commit'), c), { status: 'ok', detail: undefined });
});

test('the one-pin requirement names a package left behind by a pin bump', () => {
  const old = '2'.repeat(40);
  const c = consumer({ callers: pinnedCaller(), pkg: pinnedPkg(old), files: pinnedLock(old) });
  assert.deepEqual(checkRequirement(req('one-pin.one-commit'), c), {
    status: 'missing',
    reason: `package.json takes @blinkbitcoin/app-tooling at ${old}, but the workflows pin ${PIN}: run \`pnpm exec fix-tooling-pin\``,
  });
});

test('the one-pin requirement joins every problem into one reason', () => {
  const c = consumer({ callers: { ...pinnedCaller(), 'cd.yml': pinnedCaller('v0')['ci.yml'] } });
  const result = checkRequirement(req('one-pin.one-commit'), c);
  assert.equal(result.status, 'missing');
  assert.match(result.reason, /the calls pin 2 refs/);
});

test('a no-copy requirement passes when the consumer holds none of the copies', () => {
  assert.deepEqual(checkRequirement(req('no-copy.check-diagrams'), consumer()), { status: 'ok', detail: undefined });
});

test('a no-copy requirement names the one copy the consumer still holds', () => {
  const c = consumer({ files: { 'scripts/check-diagrams.test.mjs': '' } });
  assert.deepEqual(checkRequirement(req('no-copy.check-diagrams'), c), {
    status: 'missing',
    reason: 'scripts/check-diagrams.test.mjs is a copy of what this family ships',
  });
});

test('a no-copy requirement names every copy the consumer still holds', () => {
  const c = consumer({ files: { 'scripts/check-diagrams.mjs': '', 'scripts/check-diagrams.test.mjs': '' } });
  assert.deepEqual(checkRequirement(req('no-copy.check-diagrams'), c), {
    status: 'missing',
    reason: 'scripts/check-diagrams.mjs, scripts/check-diagrams.test.mjs are copies of what this family ships',
  });
});

test('a copy blocks the contract check wherever check.yml is called, named by what it copies', () => {
  const c = consumer({
    files: { 'scripts/release/resolve-version.sh': '' },
    callers: { 'ci.yml': CALLER },
  });
  const result = check(readContract(), c).find((r) => r.req.id === 'no-copy.resolve-version');
  assert.equal(result.level, 'fail');
  assert.match(
    formatResult(result),
    /^FAIL {2}no copy of resolve-version\.sh: scripts\/release\/resolve-version\.sh is a copy of what this family ships\. Fix: Delete /,
  );
});

test('every no-copy requirement lists paths, names what it copies and starts its fix with the deletion', () => {
  const copies = readContract().requirements.filter((r) => r.kind === 'no-copy');
  assert.ok(copies.length > 0);
  for (const r of copies) {
    assert.ok(Array.isArray(r.target) && r.target.length > 0, `${r.id}: target must be a list of paths`);
    assert.match(r.label, /^no copy of /, `${r.id}: the report names what the files copy`);
    assert.equal(r.guide, 'no-copies-of-this-family', `${r.id}: points at the guide section that explains the rule`);
    assert.match(r.fix, /^Delete /, `${r.id}: the fix starts with what to delete`);
  }
});

test('a requirement of a kind this version does not know is skipped, naming the kind', () => {
  assert.deepEqual(checkRequirement({ kind: 'from-the-future', target: 'x' }, consumer()), {
    status: 'skip',
    reason: 'unknown kind: from-the-future',
  });
});

test('an unindented line that is not a rule ends the recipe before it', () => {
  const makefile = 'lint:\n\tpnpm lint\n# a comment keeps the rule open\n\tpnpm lint:more\nPNPM := pnpm\n\tpnpm orphan\n\ncheck: lint\n';
  const make = readMakefile('', consumer({ files: { Makefile: makefile } }).io);
  assert.equal(make.rules.get('lint').recipe, '\tpnpm lint\n\tpnpm lint:more\n');
  assert.equal(make.rules.has('PNPM'), false);
  assert.deepEqual(make.rules.get('check'), { deps: ['lint'], recipe: '' });
  assert.deepEqual([...make.reachable('absent')], ['absent']);
});

test('fastlane lanes are read from subdirectories, two levels deep and no deeper', () => {
  const lanes = (files) =>
    checkRequirement(
      req('lane.build-verify'),
      consumer({ files, dirs: Object.keys(files).flatMap((f) => f.split('/').slice(0, -1).map((_, i, parts) => parts.slice(0, i + 1).join('/'))) }),
    );
  const all = 'lane :build do\nend\nlane :verify do\nend\n';
  assert.equal(lanes({ 'fastlane/lanes/ios.rb': all, 'fastlane/notes.txt': 'lane :nothing' }).status, 'ok');
  assert.equal(lanes({ 'fastlane/a/b/ios.rb': all }).status, 'ok');
  assert.equal(lanes({ 'fastlane/a/b/c/ios.rb': all }).status, 'missing');
});

test('a lane file that cannot be read counts as empty', () => {
  const io = { list: (dir) => (dir === 'fastlane' ? ['Fastfile'] : []), read: () => null, isNonEmptyDir: () => false };
  const c = { ...consumer(), io };
  assert.equal(checkRequirement(req('lane.build-verify'), c).status, 'missing');
});

test('each reusable workflow a repository calls switches on its own profile', () => {
  const profileOf = (workflow) => [...activeProfiles(new Set([workflow]))];
  assert.deepEqual(profileOf('build-web.yml'), ['web']);
  assert.deepEqual(profileOf('publish-badges.yml'), ['badges']);
  assert.deepEqual(profileOf('check-code-scanning.yml'), ['code-scanning']);
  for (const workflow of ['build-prepare.yml', 'build-ios.yml', 'build-android.yml', 'publish-store.yml', 'publish-ota.yml']) {
    assert.deepEqual(profileOf(workflow), ['release'], workflow);
  }
});

test('a make ci prerequisite that is a file, not a rule, reaches nothing and breaks nothing', () => {
  const { reaches, runs } = gateResults(ALIGNED_MAKEFILE.replace('ci: check coverage test-scripts', 'ci: check coverage test-scripts node_modules'));
  assert.equal(reaches.level, 'ok', reaches.reason);
  assert.equal(runs.level, 'ok', runs.reason);
});

test('the Makefile reader follows include and -include to the fragments that exist', () => {
  const files = { Makefile: 'include make/gates.mk make/gone.mk\n-include local.mk\nci: check\n', 'make/gates.mk': 'check:\n\tpnpm lint\n' };
  const make = readMakefile('', consumer({ files }).io);
  assert.deepEqual([...make.reachable('ci')], ['ci', 'check']);
  assert.equal(make.rules.get('check').recipe, '\tpnpm lint\n');
});

test('the Makefile reader visits a prerequisite shared by two targets once, and survives a cycle', () => {
  const make = readMakefile('', consumer({ files: { Makefile: 'ci: a b\na: shared\nb: shared\nshared: ci\n' } }).io);
  assert.deepEqual([...make.reachable('ci')], ['ci', 'a', 'shared', 'b']);
});

// --- the command line ----------------------------------------------------------

test('arguments default to the working directory, every profile and the text report', () => {
  assert.deepEqual(parseArgs([], '/work'), { root: '/work', profiles: null, json: false, skeleton: false });
  assert.equal(parseArgs([]).root, process.cwd());
});

test('every flag is read', () => {
  assert.deepEqual(parseArgs(['--root', '/app', '--profile', 'checks, unit,,', '--json', '--skeleton'], '/work'), {
    root: '/app',
    profiles: ['checks', 'unit'],
    json: true,
    skeleton: true,
  });
});

test('an unknown argument is refused by name', () => {
  assert.throws(() => parseArgs(['--verbose']), { message: '::error::unknown argument: --verbose' });
});

test('the program refuses an unknown argument with one error line and exit 1', () => {
  assert.deepEqual(runMain(['--nope']), { code: 1, stdout: '', stderr: '::error::unknown argument: --nope\n' });
});

test('the program refuses an unknown profile, listing the known ones', () => {
  const { profiles } = readContract();
  assert.deepEqual(runMain(['--root', tree(), '--profile', 'checks,nonesuch']), {
    code: 1,
    stdout: '',
    stderr: `::error::unknown profile(s): nonesuch (known: ${profiles.join(', ')})\n`,
  });
});

test('the program reports an unreadable package.json as one error line, not a stack trace', () => {
  const root = tree({ 'package.json': '{' });
  const { code, stdout, stderr } = runMain(['--root', root]);
  assert.equal(code, 1);
  assert.equal(stdout, '');
  assert.match(stderr, /^::error::.*package\.json is not valid JSON: [^\n]*\n$/);
});

test('a flag missing its value exits 1 with a message and no stack trace', () => {
  const { code, stdout, stderr } = runMain(['--root']);
  assert.equal(code, 1);
  assert.equal(stdout, '');
  assert.equal(stderr.split('\n').length, 2, stderr);
});

test('a consumer meeting every requirement exits 0 and says so', () => {
  const root = tree({ 'package.json': JSON.stringify({ scripts: {} }) });
  assert.deepEqual(runMain(['--root', root, '--profile', 'badges']), {
    code: 0,
    stdout: 'ok    no copy of gen-badges\n\nEvery requirement of the workflows this repository calls is satisfied.\n',
    stderr: '',
  });
});

test('the root defaults to the working directory the program was given', () => {
  // A copy only that directory holds, so passing would mean it read another.
  const root = tree({ 'package.json': '{}', 'scripts/badges/render.mjs': '' });
  const { code, stdout } = runMain(['--profile', 'badges'], { cwd: root });
  assert.equal(code, 1);
  assert.match(stdout, /^FAIL {2}no copy of gen-badges: scripts\/badges\/render\.mjs is a copy of what this family ships\./);
});

// publish-badges.yml renders with the package's gen-badges now, so calling
// it asks nothing of the consumer's package.json; the copy it replaced blocks.
test('calling publish-badges.yml needs no gen:badges script, and a copy of the renderer blocks', () => {
  const badges = (files) =>
    check(readContract(), readConsumer(tree(files)), { profiles: ['badges'] }).filter((r) => r.req.profile === 'badges');
  assert.deepEqual(badges({ 'package.json': '{}' }).map((r) => [r.req.id, r.level]), [['no-copy.gen-badges', 'ok']]);
  const copied = badges({ 'package.json': '{}', 'scripts/badges/badge.mjs': '', 'scripts/badges/status-badge.test.mjs': '' });
  assert.deepEqual(copied.map((r) => [r.req.id, r.level]), [['no-copy.gen-badges', 'fail']]);
  assert.match(copied[0].reason, /scripts\/badges\/badge\.mjs, scripts\/badges\/status-badge\.test\.mjs are copies/);
});

test('a degraded-only consumer exits 0 and counts what degraded', () => {
  const { code, stdout, stderr } = runMain(['--root', tree(), '--profile', 'code-scanning']);
  assert.equal(code, 0);
  assert.equal(stderr, '');
  const codeql = check(readContract(), readConsumer(tree()), { profiles: ['code-scanning'] }).find((r) => r.req.id === 'file.code-scanning-configuration');
  assert.equal(codeql.level, 'warn');
  assert.equal(stdout, `${formatResult(codeql)}\n\n1 degraded. See ${GUIDE}\n`);
});

test('a consumer missing required items exits 1, lists each finding and counts both kinds', () => {
  const root = tree({ '.github/workflows/ci.yml': CHECKS_CALLER });
  const { code, stdout, stderr } = runMain(['--root', root]);
  const results = check(readContract(), readConsumer(root));
  const failures = results.filter((r) => r.level === 'fail').length;
  const warnings = results.filter((r) => r.level === 'warn').length;
  assert.equal(code, 1);
  const expected = results.filter((r) => r.level !== 'skip').map((r) => `${formatResult(r)}\n`).join('');
  assert.equal(stdout, `${expected}\n${failures} blocked, ${warnings} degraded. See ${GUIDE}\n`);
  assert.equal(stderr, `::error::consumer contract: ${failures} requirement(s) of the workflows this repository calls are not met\n`);
});

test('--skeleton adds what would clear the failures', () => {
  const root = tree({ '.github/workflows/ci.yml': CHECKS_CALLER });
  const { stdout } = runMain(['--root', root, '--skeleton']);
  assert.ok(stdout.includes(`\n${skeleton(check(readContract(), readConsumer(root)))}`));
  assert.match(stdout, /Either add these to package\.json:/);
});

test('--skeleton prints nothing extra when nothing fails', () => {
  const plain = runMain(['--root', tree(), '--profile', 'code-scanning']);
  const withSkeleton = runMain(['--root', tree(), '--profile', 'code-scanning', '--skeleton']);
  assert.equal(withSkeleton.stdout, plain.stdout);
});

test('skipped requirements are printed only when WORKFLOWS_CONTRACT_VERBOSE is set', () => {
  const root = tree({ '.github/workflows/ci.yml': CHECKS_CALLER });
  assert.doesNotMatch(runMain(['--root', root]).stdout, /^skip  /m);
  assert.match(runMain(['--root', root], { env: { WORKFLOWS_CONTRACT_VERBOSE: '1' } }).stdout, /^skip  /m);
});

test('--json prints every result by id and no text summary, keeping the exit code', () => {
  const root = tree({ '.github/workflows/ci.yml': CHECKS_CALLER });
  const { code, stdout, stderr } = runMain(['--root', root, '--json', '--skeleton']);
  const expected = check(readContract(), readConsumer(root)).map(({ req: r, level, reason, detail }) => ({ id: r.id, level, reason, detail }));
  assert.equal(stdout, `${JSON.stringify(expected, null, 2)}\n`);
  assert.equal(code, 1);
  assert.match(stderr, /^::error::consumer contract: /);
});

test('--json exits 0 when nothing fails', () => {
  const { code, stderr } = runMain(['--root', tree(), '--profile', 'code-scanning', '--json']);
  assert.equal(code, 0);
  assert.equal(stderr, '');
});

test('the job summary is appended to GITHUB_STEP_SUMMARY when it is set', () => {
  const root = tree({ '.github/workflows/ci.yml': CHECKS_CALLER, 'summary.md': 'before\n' });
  const summary = path.join(root, 'summary.md');
  runMain(['--root', root], { env: { GITHUB_STEP_SUMMARY: summary } });
  assert.equal(readFileSync(summary, 'utf8'), `before\n${summaryTable(check(readContract(), readConsumer(root)))}\n`);
});

test('no job summary is written without GITHUB_STEP_SUMMARY', () => {
  const appended = [];
  const io = { ...defaultIo, append: (file, text) => appended.push([file, text]) };
  runMain(['--root', tree(), '--profile', 'code-scanning'], { io });
  assert.deepEqual(appended, []);
});

test('an io that cannot append skips the job summary rather than failing the run', () => {
  const { append, ...readOnly } = defaultIo;
  assert.equal(typeof append, 'function');
  const { code } = runMain(['--root', tree(), '--profile', 'code-scanning'], { io: readOnly, env: { GITHUB_STEP_SUMMARY: '/nonexistent/summary.md' } });
  assert.equal(code, 0);
});

// --- run as a program, not imported ---------------------------------------------

// The inherited environment, so node's coverage reaches the child, minus the
// two variables that would change what the program prints.
const { GITHUB_STEP_SUMMARY: _summary, WORKFLOWS_CONTRACT_VERBOSE: _verbose, ...CHILD_ENV } = process.env;

test('the file counts as a program only when node was started on it, through any symlink', () => {
  const url = new URL('./bin/check-contract.mjs', import.meta.url).href;
  const link = path.join(tree(), 'check-contract');
  symlinkSync(BIN, link);
  assert.equal(isProgram(url, BIN), true);
  assert.equal(isProgram(url, link), true);
  assert.equal(isProgram(url, fileURLToPath(import.meta.url)), false);
  assert.equal(isProgram(url, undefined), false);
  assert.equal(isProgram(url, path.join(tree(), 'absent.mjs')), false);
});

test('run as a program, it prints the report and exits with the report\'s code', () => {
  const failing = spawnSync(process.execPath, [BIN, '--root', tree({ '.github/workflows/ci.yml': CHECKS_CALLER })], { encoding: 'utf8', env: CHILD_ENV });
  assert.equal(failing.status, 1);
  assert.match(failing.stdout, /^FAIL  /m);
  assert.match(failing.stderr, /^::error::consumer contract: /);
  const passing = spawnSync(process.execPath, [BIN, '--root', tree(), '--profile', 'code-scanning'], { encoding: 'utf8', env: CHILD_ENV });
  assert.equal(passing.status, 0);
  assert.match(passing.stdout, /1 degraded/);
});

// --- calls against the workflows' interfaces --------------------------------

const RELEASE = `name: CD
on: push
jobs:
  prepare:
    name: Prepare
    uses: blinkbitcoin/shared-workflows/.github/workflows/build-prepare.yml@abc # v0.14.0
    with: # what to prepare
      stage: internal
      reserve-tag: true
      environment-variables: >-
        {"A": "b",
        stage: not-a-key}
      nested:
        deeper: not-a-key
    secrets:
      ANTHROPIC_API_KEY: \${{ secrets.ANTHROPIC_API_KEY }}

  store:
    uses: blinkbitcoin/shared-workflows/.github/workflows/publish-store.yml@abc
    secrets: inherit
    with: {}
  local:
    uses: ./.github/workflows/local.yml
  steps-only:
    runs-on: ubuntu-latest
    steps:
      - uses: blinkbitcoin/shared-workflows/.github/workflows/not-a-call.yml@abc
  - not a job key
    uses: blinkbitcoin/shared-workflows/.github/workflows/ignored.yml@abc
  flow:
    uses: blinkbitcoin/shared-workflows/.github/workflows/pr-title.yml@abc
    with: {repository: x}
  flow-secrets:
    uses: blinkbitcoin/shared-workflows/.github/workflows/pr-title.yml@abc
    secrets: {consumer-token: x}
  empty-secrets:
    uses: blinkbitcoin/shared-workflows/.github/workflows/pr-title.yml@abc
    secrets: {}
  after:
    if: \${{ needs.prepare.outputs.version != '' && needs.prepare.outputs.version-code }}
    runs-on: ubuntu-latest
permissions: {}
`;

const calls = () => callerCalls([{ name: 'cd.yml', text: RELEASE }]);
const call = (job) => calls().find((c) => c.job === job);

test('the interfaces ship in the package, keyed by workflow file', () => {
  const { workflows } = readInterfaces();
  assert.equal(workflows['publish-store.yml'].inputs.version.required, true);
  assert.equal(workflows['check.yml'].outputs.includes('docs-only'), true);
});

test('each job that calls a shared workflow is found, with its inputs, secrets and the outputs read from it', () => {
  assert.deepEqual(
    calls().map((c) => c.job),
    ['prepare', 'store', 'flow', 'flow-secrets', 'empty-secrets'],
  );
  const prepare = call('prepare');
  assert.equal(prepare.file, 'cd.yml');
  assert.equal(prepare.workflow, 'build-prepare.yml');
  assert.deepEqual([...prepare.with.keys()], ['stage', 'reserve-tag', 'environment-variables', 'nested']);
  assert.equal(prepare.with.get('reserve-tag'), 'true');
  assert.deepEqual([...prepare.secrets], ['ANTHROPIC_API_KEY']);
  assert.deepEqual([...prepare.reads].sort(), ['version', 'version-code']);
  assert.equal(prepare.unreadable, false);
});

test('secrets: inherit reads as null, and an empty with: or secrets: as nothing passed', () => {
  assert.equal(call('store').secrets, null);
  assert.deepEqual([...call('store').with], []);
  assert.deepEqual([...call('empty-secrets').secrets], []);
  assert.deepEqual([...call('store').reads], []);
});

test('an inline with: or secrets: mapping marks the call unreadable instead of guessing', () => {
  assert.equal(call('flow').unreadable, true);
  assert.equal(call('flow-secrets').unreadable, true);
});

test('a caller with no jobs, and a job indented under another shape, yield no calls', () => {
  assert.deepEqual(callerCalls([{ name: 'x.yml', text: 'on: push\n' }]), []);
  const odd = 'jobs:\n    deep:\n      uses: blinkbitcoin/shared-workflows/.github/workflows/pr-title.yml@a\n  shallow: {}\n';
  assert.deepEqual(
    callerCalls([{ name: 'x.yml', text: odd }]).map((c) => c.job),
    ['deep'],
  );
});

test('a scalar is typed the way YAML types it, and an expression or empty value is unknown', () => {
  for (const [raw, type] of [
    ['${{ inputs.x }}', 'unknown'],
    ['', 'unknown'],
    ['~', 'unknown'],
    ['null', 'unknown'],
    ['# only a comment', 'unknown'],
    ["'true'", 'string'],
    ['"10"', 'string'],
    ['"a # b"', 'string'],
    ['>-', 'string'],
    ['|', 'string'],
    ['true', 'boolean'],
    ['False', 'boolean'],
    ['TRUE # a comment', 'boolean'],
    ['10', 'number'],
    ['-1.5e3', 'number'],
    ['.5', 'number'],
    ['v1.2.3', 'string'],
    ['internal', 'string'],
  ]) {
    assert.equal(scalarType(raw), type, raw);
  }
});

const FACE = {
  inputs: {
    stage: { type: 'string', required: false },
    'dry-run': { type: 'boolean', required: false },
    version: { type: 'string', required: true },
  },
  secrets: { TOKEN: { required: false }, KEY: { required: true } },
  outputs: ['sha'],
};
const aCall = (overrides = {}) => ({
  workflow: 'x.yml',
  with: new Map([['version', '${{ needs.p.outputs.version }}']]),
  secrets: new Set(['KEY']),
  reads: new Set(),
  ...overrides,
});

test('a call that fits its interface has no problems', () => {
  assert.deepEqual(callProblems(aCall({ reads: new Set(['sha']) }), FACE), []);
});

test('a workflow the interfaces do not know is one problem, naming it', () => {
  assert.deepEqual(callProblems(aCall(), undefined), ['shared-workflows publishes no reusable x.yml at this version']);
});

test('an undeclared input, a literal of the wrong type and a missing required input are each named', () => {
  const problems = callProblems(
    aCall({ with: new Map([['nope', 'a'], ['dry-run', "'true'"], ['stage', 'true']]) }),
    FACE,
  );
  assert.deepEqual(problems, [
    'passes input nope, which x.yml does not declare',
    "passes dry-run as a string ('true'), but x.yml declares it a boolean",
    'passes stage as a boolean (true), but x.yml declares it a string',
    'does not pass version, which x.yml requires',
  ]);
});

test('an undeclared secret and a missing required one are named, and inherit passes them all', () => {
  assert.deepEqual(callProblems(aCall({ secrets: new Set(['OTHER']) }), FACE), [
    'passes secret OTHER, which x.yml does not declare',
    'does not pass secret KEY, which x.yml requires',
  ]);
  assert.deepEqual(callProblems(aCall({ secrets: null }), FACE), []);
});

test('reading an output the workflow does not declare is named', () => {
  assert.deepEqual(callProblems(aCall({ reads: new Set(['sha', 'version']) }), FACE), [
    'reads output version, which x.yml does not declare',
  ]);
});

const interfaces = { workflows: { 'build-prepare.yml': { inputs: {}, secrets: {}, outputs: [] } } };

test('a repository that calls no shared workflow gets no call findings at all', () => {
  assert.deepEqual(checkCalls(consumer({ callers: { 'ci.yml': 'on: push\n' } }), interfaces), []);
});

test('fitting calls are one pass naming how many, and an unreadable call is skipped, not counted', () => {
  const text = `jobs:
  a:
    uses: blinkbitcoin/shared-workflows/.github/workflows/build-prepare.yml@x
  b:
    uses: blinkbitcoin/shared-workflows/.github/workflows/build-prepare.yml@x
    with: {stage: internal}
`;
  const results = checkCalls(consumer({ callers: { 'cd.yml': text } }), interfaces);
  assert.deepEqual(
    results.map(({ level, req, reason, detail }) => [level, req.label, reason ?? detail]),
    [
      ['skip', 'cd.yml: b -> build-prepare.yml', 'its with: or secrets: is an inline mapping this cannot read'],
      ['ok', 'calls to shared workflows', "1 within their workflows' interfaces"],
    ],
  );
});

test('each problem is a blocking finding that reads, sums up and serializes like a requirement', () => {
  const text = `jobs:
  a:
    uses: blinkbitcoin/shared-workflows/.github/workflows/build-prepare.yml@x
    with:
      nope: 1
`;
  const [finding, ...rest] = checkCalls(consumer({ callers: { 'cd.yml': text } }), interfaces);
  assert.deepEqual(rest, []);
  assert.equal(finding.level, 'fail');
  assert.equal(finding.req.id, 'calls.interface');
  assert.match(formatResult(finding), /^FAIL {2}cd\.yml: a -> build-prepare\.yml: passes input nope, which build-prepare\.yml does not declare\. Fix: pass only/);
  assert.match(summaryTable([finding]), /\*\*blocked\*\* \| `cd\.yml: a -> build-prepare\.yml`<br>passes input nope/);
  assert.equal(skeleton([finding]), '');
});

test('the program fails on a call that does not fit, and --json carries the call rule id', () => {
  const root = tree({
    'package.json': '{}',
    '.github/workflows/cd.yml':
      'jobs:\n  store:\n    uses: blinkbitcoin/shared-workflows/.github/workflows/publish-store.yml@x\n    with:\n      lane: upload\n',
  });
  const { code, stdout } = runMain(['--root', root, '--profile', 'badges']);
  assert.equal(code, 1);
  assert.match(stdout, /FAIL {2}cd\.yml: store -> publish-store\.yml: does not pass version, which publish-store\.yml requires/);
  const json = JSON.parse(runMain(['--root', root, '--profile', 'badges', '--json']).stdout);
  assert.ok(json.some((r) => r.id === 'calls.interface' && r.level === 'fail'), JSON.stringify(json));
});

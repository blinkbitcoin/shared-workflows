import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdirSync, mkdtempSync, readFileSync, rmSync, symlinkSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { after, test } from 'node:test';
import { fileURLToPath } from 'node:url';
import {
  activeProfiles,
  RELEASE_WORKFLOWS,
  callerCalls,
  callerInputs,
  callersUse,
  callProblems,
  environmentVariablesProblems,
  environmentVariablesText,
  check,
  checkCalls,
  checkRequirement,
  ciScripts,
  defaultIo,
  fastlaneInput,
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
  literalInput,
  stackInput,
  stackLine,
  summaryTable,
  resolved,
  toggleOn,
  workingDirectoryInput,
} from './bin/check-contract.mjs';

// A consumer, as the checks see one. No temp directories: `io` is the only way
// any check reaches a disk, so a fixture is an object literal.
// `stack` is the resolved native stack; the fixtures are the Expo template's
// shape unless a case says otherwise. `tracked` lists the directories git tracks.
const EXPO_STACK = { stack: 'expo', reason: 'expo is a dependency and git tracks no ios/' };
const BARE_STACK = { stack: 'bare', reason: 'expo is not a dependency in package.json' };
// What the program prints first for a temporary directory with no expo dependency.
const BARE_LINE = 'native stack: bare (expo is not a dependency in package.json)';
function consumer({ files = {}, dirs = [], pkg = {}, callers = {}, stack = EXPO_STACK, tracked = [] } = {}) {
  const io = {
    tracked: (_root, dir) => tracked.includes(dir),
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
    fastlaneDirectory: fastlaneInput(callerInputs(callerList)),
    stack,
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
    'tracked-dir',
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
    assert.ok(r.stack === undefined || ['expo', 'bare'].includes(r.stack), `${r.id}: stack must be expo or bare`);
    assert.ok(r.workflow === undefined || [r.workflow].flat().every((name) => /^[a-z-]+\.yml$/.test(name)), `${r.id}: workflow must be a workflow file, or a list of them`);
    assert.ok(r.toggleValue === undefined || (r.toggleValue === 'script-name' && r.toggle), `${r.id}: toggleValue is script-name, on a toggle`);
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

// test-unit.yml's scripts-script names the script the step runs; '' skips the step.
const unitCaller = (line) =>
  ['jobs:', '  unit:', '    uses: blinkbitcoin/shared-workflows/.github/workflows/test-unit.yml@v0', ...(line ? ['    with:', `      ${line}`] : [])].join('\n');
const scriptsRow = (line, scripts = {}) =>
  check(readContract(), consumer({ pkg: { scripts }, callers: { 'ci.yml': unitCaller(line) } })).find(
    (r) => r.req.id === 'package-script.test-scripts',
  );

test('test:scripts is required while scripts-script is unset', () => {
  const result = scriptsRow(null);
  assert.equal(result.level, 'fail');
  assert.match(result.reason, /no "test:scripts" script in package\.json/);
  assert.equal(scriptsRow(null, { 'test:scripts': 'node --test' }).level, 'ok');
});

test("scripts-script: '' skips the scripts row, as it skips the step", () => {
  for (const line of ["scripts-script: ''", 'scripts-script: ""']) {
    const result = scriptsRow(line);
    assert.equal(result.level, 'skip');
    assert.equal(result.reason, 'test-unit.yml:scripts-script is empty');
  }
});

test('scripts-script set to another script requires that script instead', () => {
  const result = scriptsRow('scripts-script: test:tools');
  assert.equal(result.level, 'fail');
  assert.equal(result.req.target, 'test:tools');
  assert.match(result.reason, /no "test:tools" script in package\.json/);
  assert.match(formatResult(result), /^FAIL {2}test:tools: /);
  assert.equal(scriptsRow('scripts-script: test:tools', { 'test:tools': 'node --test' }).level, 'ok');
  assert.equal(scriptsRow("scripts-script: 'test:tools'", { 'test:scripts': 'node --test' }).level, 'fail');
});

test('scripts-script wired to an expression is reported against the default script, never blocking', () => {
  const inputs = new Map([['test-unit.yml:scripts-script', '${{ vars.SCRIPTS }}']]);
  assert.equal(toggleOn(req('package-script.test-scripts'), inputs), 'unknown');
  assert.equal(resolved(req('package-script.test-scripts'), inputs).target, 'test:scripts');
  const result = scriptsRow('scripts-script: ${{ vars.SCRIPTS }}');
  assert.equal(result.level, 'warn');
  assert.match(result.reason, /no "test:scripts" script.*cannot evaluate/);
});

test('a boolean toggle leaves the target as the contract writes it', () => {
  const types = req('package-script.check-types');
  assert.equal(resolved(types, new Map([['check.yml:types', 'true']])), types);
  assert.equal(toggleOn(req('package-script.check-types'), new Map([['check.yml:types', 'false']])), false);
});

test('the scripts script make ci must reach follows scripts-script', () => {
  const contract = readContract();
  const uses = new Set(['test-unit.yml']);
  const at = (value) => ciScripts(contract, uses, new Map([['test-unit.yml:scripts-script', value]]), null);
  assert.ok(ciScripts(contract, uses, new Map(), null).on.has('test:scripts'));
  assert.ok(!at('').maybe.has('test:scripts'));
  assert.ok(at('test:tools').on.has('test:tools'));
  assert.ok(!at('test:tools').maybe.has('test:scripts'));
  assert.ok(at('${{ vars.SCRIPTS }}').maybe.has('test:scripts'));
  assert.ok(!at('${{ vars.SCRIPTS }}').on.has('test:scripts'));
});

test("the skeleton turns scripts-script off with '' and a boolean gate with false", () => {
  const callers = {
    'ci.yml': [
      'jobs:',
      '  unit:',
      '    uses: blinkbitcoin/shared-workflows/.github/workflows/test-unit.yml@v0',
      '  checks:',
      '    uses: blinkbitcoin/shared-workflows/.github/workflows/check.yml@v0',
    ].join('\n'),
  };
  const text = skeleton(check(readContract(), consumer({ callers })));
  assert.match(text, /^ {6}scripts-script: ''$/m);
  assert.match(text, /^ {6}types: false$/m);
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

test('a config that takes the exclusion from the shared Expo preset is satisfied by naming it', () => {
  const via = (target, id, text) => checkRequirement(req(id), consumer({ files: { [target]: text } }));
  const biome = via('biome.json', 'ignores-workflows.biome-json', '{"extends":["@blinkbitcoin/app-tooling/expo/biome"]}');
  assert.deepEqual([biome.status, biome.detail], ['ok', 'through expo/biome']);
  assert.equal(via('biome.json', 'ignores-workflows.biome-json', '{"extends":["@blinkbitcoin/app-tooling/expo/biome.json"]}').status, 'ok');
  assert.equal(
    via('eslint.config.mjs', 'ignores-workflows.eslint-configuration', "import { createEslintConfig } from '@blinkbitcoin/app-tooling/expo/eslint';").status,
    'ok',
  );
  assert.equal(
    via('jest.config.ts', 'ignores-workflows.jest-configuration', "import { createJestConfig } from '@blinkbitcoin/app-tooling/expo/jest';").status,
    'ok',
  );
  // Only the preset for that tool counts: another tool's preset, a sub-path and a prefix do not.
  for (const text of ['{"extends":["@blinkbitcoin/app-tooling/expo/jest"]}', '@blinkbitcoin/app-tooling/expo/biomes"', '@blinkbitcoin/app-tooling/expo/biome/x"']) {
    assert.equal(via('biome.json', 'ignores-workflows.biome-json', text).status, 'missing', text);
  }
  // A tool with no preset that excludes it still has to name the directory.
  assert.equal(via('tsconfig.json', 'ignores-workflows.tsconfig-json', '{"extends":["@blinkbitcoin/app-tooling/expo/tsconfig.base.json"]}').status, 'missing');
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

test('a lane two platforms need is named once when it is missing', () => {
  const none = consumer({ dirs: ['fastlane'], files: { 'fastlane/Fastfile': 'platform :ios do\nend\n' } });
  assert.deepEqual(checkRequirement(req('lane.build-verify'), none), {
    status: 'missing',
    reason: 'fastlane/ defines no lane named build, verify',
  });
});

// An app's Fastfile is one import of the package's, so its lanes are not under
// its fastlane/ directory: the lane scans read them from the package.
const IMPORT_FASTFILE = "import '../node_modules/@blinkbitcoin/app-tooling/fastlane/Fastfile'\n";

test('a Fastfile that imports the package lanes has every lane the build needs', () => {
  const c = consumer({ dirs: ['fastlane'], files: { 'fastlane/Fastfile': IMPORT_FASTFILE } });
  assert.equal(checkRequirement(req('lane.build-verify'), c).status, 'ok');
});

test('the imported lanes are held to the same App Review names the workflow passes', () => {
  const c = consumer({
    dirs: ['fastlane'],
    files: { 'fastlane/Fastfile': IMPORT_FASTFILE },
    callers: { 'r.yml': 'uses: blinkbitcoin/shared-workflows/.github/workflows/publish-store.yml@v0\n' },
  });
  const result = check(readContract(), c).find((r) => r.req.id === 'lane-environment.app-review');
  assert.equal(result.level, 'ok', result.reason);
});

test('only the Fastfile that names the package is given its lanes: another one missing them still fails', () => {
  const c = consumer({ dirs: ['fastlane'], files: { 'fastlane/Fastfile': "import 'lanes/mine.rb'\n" } });
  assert.equal(checkRequirement(req('lane.build-verify'), c).status, 'missing');
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

test('the one-pin requirement passes on the lockfile entry pnpm writes with a peer suffix', () => {
  const lock = pinnedLock()['pnpm-lock.yaml'].replace('\n', '(5dfd4c12eb1b14f8f0fa10ac317d7ad0)\n');
  const c = consumer({ callers: pinnedCaller(), pkg: pinnedPkg(), files: { 'pnpm-lock.yaml': lock } });
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
  for (const workflow of RELEASE_WORKFLOWS) {
    assert.deepEqual(profileOf(workflow), ['release'], workflow);
  }
  // The pipelines are release callers too: a repository that calls only them never names a leaf.
  for (const pipeline of ['publish-internal.yml', 'publish-beta.yml', 'publish-production.yml', 'publish-store-listing.yml']) {
    assert.ok(RELEASE_WORKFLOWS.includes(pipeline), pipeline);
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
  assert.deepEqual(parseArgs([], '/work'), { root: '/work', profiles: null, json: false, skeleton: false, nativeStack: '' });
  assert.equal(parseArgs([]).root, process.cwd());
});

test('every flag is read', () => {
  assert.deepEqual(parseArgs(['--root', '/app', '--profile', 'checks, unit,,', '--json', '--skeleton', '--native-stack', 'bare'], '/work'), {
    root: '/app',
    profiles: ['checks', 'unit'],
    json: true,
    skeleton: true,
    nativeStack: 'bare',
  });
  // A trailing --native-stack with no value is the empty input: detect it.
  assert.equal(parseArgs(['--native-stack'], '/work').nativeStack, '');
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
    stdout: 'native stack: bare (expo is not a dependency in package.json)\nok    no copy of gen-badges\n\nEvery requirement of the workflows this repository calls is satisfied.\n',
    stderr: '',
  });
});

test('the root defaults to the working directory the program was given', () => {
  // A copy only that directory holds, so passing would mean it read another.
  const root = tree({ 'package.json': '{}', 'scripts/badges/render.mjs': '' });
  const { code, stdout } = runMain(['--profile', 'badges'], { cwd: root });
  assert.equal(code, 1);
  assert.match(stdout, /^native stack: bare \(expo is not a dependency in package\.json\)\nFAIL {2}no copy of gen-badges: scripts\/badges\/render\.mjs is a copy of what this family ships\./);
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
  assert.equal(stdout, `${BARE_LINE}\n${formatResult(codeql)}\n\n1 degraded. See ${GUIDE}\n`);
});

test('a consumer missing required items exits 1, lists each finding and counts both kinds', () => {
  const root = tree({ '.github/workflows/ci.yml': CHECKS_CALLER });
  const { code, stdout, stderr } = runMain(['--root', root]);
  const results = check(readContract(), readConsumer(root));
  const failures = results.filter((r) => r.level === 'fail').length;
  const warnings = results.filter((r) => r.level === 'warn').length;
  assert.equal(code, 1);
  const expected = results.filter((r) => r.level !== 'skip').map((r) => `${formatResult(r)}\n`).join('');
  assert.equal(stdout, `${BARE_LINE}\n${expected}\n${failures} blocked, ${warnings} degraded. See ${GUIDE}\n`);
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
  const consumerRead = readConsumer(root);
  assert.equal(readFileSync(summary, 'utf8'), `before\n${summaryTable(check(readContract(), consumerRead), consumerRead.stack)}\n`);
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

test("a block scalar under with: is kept as text, folded or literal, and the call still lists its key", () => {
  const text = `jobs:
  a:
    uses: blinkbitcoin/shared-workflows/.github/workflows/x.yml@abc
    with:
      folded: >-
        {"A": "1",

        "B": "2"}

      literal: |
        {"A": "1",
          "B": "2"}
      plain: value
      - not a key
  b:
    uses: blinkbitcoin/shared-workflows/.github/workflows/x.yml@abc
    secrets:
      folded: >-
        not kept
`;
  const [a, b] = callerCalls([{ name: 'x.yml', text }]);
  assert.deepEqual([...a.with.keys()], ['folded', 'literal', 'plain']);
  assert.equal(a.with.get('folded'), '>-');
  assert.deepEqual(Object.fromEntries(a.blocks), { folded: '{"A": "1", "B": "2"}', literal: '{"A": "1",\n"B": "2"}' });
  assert.deepEqual([...b.blocks], [], 'a secrets: block is not an input');
  assert.deepEqual([...call('prepare').blocks.keys()], ['environment-variables']);
});

test('environment-variables is read from a block or a quoted literal, never from an expression', () => {
  assert.equal(environmentVariablesText('>-', '{"A":"1"}'), '{"A":"1"}');
  assert.equal(environmentVariablesText(`'{"A":"it''s"}'`, undefined), `{"A":"it's"}`);
  assert.equal(environmentVariablesText('"{\\"A\\":\\"1\\"}"', undefined), '{"A":"1"}');
  assert.equal(environmentVariablesText('"\\q"', undefined), null, 'a double-quoted value that does not unescape');
  assert.equal(environmentVariablesText('${{ vars.BUILD_ENV }}', undefined), null);
  assert.equal(environmentVariablesText('{}', undefined), null);
});

test('environment-variables passes when every expression in it renders to valid build environment JSON', () => {
  assert.deepEqual(
    environmentVariablesProblems(
      '{"APP_VARIANT":"production", "OTA_ENABLED":"${{ vars.OTA_ENABLED }}", "EXTRA":${{ toJSON(vars.EXTRA || \'\') }}, "N":"${{ format(\'{0}\', vars.N) }}"}',
    ),
    [],
  );
});

test('environment-variables is refused the way build-env.sh would refuse it, before any release', () => {
  for (const [text, problem] of [
    ['{"A":"${{ vars.A }}",}', /^environment-variables is not valid JSON: /],
    ['{"A":${{ vars.A }}}', /^environment-variables is not valid JSON: /],
    ['["A"]', /^environment-variables must be a flat JSON object$/],
    ['{"A":{"B":"1"}}', /^environment-variables value for A must be a scalar$/],
    ['{"lower":"1"}', /^environment-variables key is not an upper-case env name: lower$/],
    ['{"OPENAI_API_KEY":"x"}', /^environment-variables key OPENAI_API_KEY looks like a credential; pass it as a secret instead/],
    ['{"WORKFLOWS_FINGERPRINT_IOS":"x"}', /^environment-variables key WORKFLOWS_FINGERPRINT_IOS is reserved/],
  ]) {
    const problems = environmentVariablesProblems(text);
    assert.equal(problems.length, 1, text);
    assert.match(problems[0], problem, text);
  }
});

test('a quoted toJSON is named as the double-encoding it is', () => {
  assert.deepEqual(environmentVariablesProblems('{"EXTRA":"${{ toJSON(vars.EXTRA) }}"}'), [
    'environment-variables quotes a ${{ toJSON(...) }}, which is a JSON string already: drop the quotes around it',
  ]);
});

test('a call reports what is wrong with its environment-variables, and skips one it cannot read', () => {
  const face = { inputs: { 'environment-variables': { type: 'string', required: false } }, secrets: {}, outputs: [] };
  const withEnv = (raw, block) =>
    callProblems(
      { workflow: 'x.yml', with: new Map([['environment-variables', raw]]), blocks: new Map(block === undefined ? [] : [['environment-variables', block]]), secrets: new Set(), reads: new Set() },
      face,
    );
  assert.deepEqual(withEnv('>-', '{"A":"1"}'), []);
  assert.match(withEnv('>-', '{"A_TOKEN":"1"}')[0], /looks like a credential/);
  assert.match(withEnv(`'{"A":}'`)[0], /is not valid JSON/);
  assert.deepEqual(withEnv('${{ vars.BUILD_ENV }}'), []);
  const bare = { workflow: 'x.yml', with: new Map([['environment-variables', `'{"A":"1"}'`]]), secrets: new Set(), reads: new Set() };
  assert.deepEqual(callProblems(bare, face), [], 'a call built without blocks still reads a quoted literal');
  const lower = { workflow: 'publish-store.yml', with: new Map([['environment-variables', `'{"track":"beta"}'`]]), secrets: new Set(), reads: new Set() };
  assert.deepEqual(callProblems(lower, face), [], "publish-store.yml's keys reach a fastlane lane and may be lower-case");
  assert.match(callProblems({ ...lower, workflow: 'build-prepare.yml' }, face)[0], /not an upper-case env name: track/);
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

// --- the native stack: Expo or bare React Native ------------------------------

const ids = (results, level) => results.filter((r) => r.level === level).map((r) => r.req.id);
const caller = (workflow, withBlock = '') =>
  `jobs:\n  job:\n    uses: blinkbitcoin/shared-workflows/.github/workflows/${workflow}@v0\n${withBlock ? `    with:\n${withBlock}` : ''}`;

test('the contract tags exactly the Expo rows expo, and the committed-project rows bare', () => {
  const tagged = (stack) => readContract().requirements.filter((r) => r.stack === stack).map((r) => r.id);
  // Not check:prebuild: CI runs the consumer's own script whenever prebuild is
  // on, whatever the stack, so make ci must reach it on either.
  assert.deepEqual(tagged('expo'), [
    'package-script.check-expo-health',
    'file.expo-configuration',
    'package-dep.fingerprint',
  ]);
  assert.deepEqual(tagged('bare'), ['tracked-dir.ios-e2e', 'tracked-dir.android-e2e', 'tracked-dir.ios-build', 'tracked-dir.android-build']);
  for (const r of readContract().requirements.filter((x) => x.kind === 'tracked-dir')) {
    assert.ok(['ios', 'android'].includes(r.target), `${r.id}: a native project directory`);
  }
});

test('the callers pass no stack when none of them passes a literal native-stack', () => {
  assert.equal(stackInput(new Map()), '');
  assert.equal(stackInput(new Map([['check.yml:types', 'bare']])), '');
  assert.equal(stackInput(new Map([['check.yml:native-stack', '']])), '');
  assert.equal(stackInput(new Map([['check.yml:native-stack', '${{ vars.NATIVE_STACK }}']])), '');
});

test('the callers\' native-stack is the one literal they agree on', () => {
  assert.equal(stackInput(new Map([['check.yml:native-stack', 'bare']])), 'bare');
  assert.equal(
    stackInput(new Map([['check.yml:native-stack', 'bare'], ['test-e2e.yml:native-stack', 'bare'], ['build-ios.yml:native-stack', '${{ vars.X }}']])),
    'bare',
  );
});

test('callers passing two different stacks is an error naming each and where', () => {
  assert.throws(() => stackInput(new Map([['check.yml:native-stack', 'bare'], ['test-e2e.yml:native-stack', 'expo'], ['build-ios.yml:native-stack', 'bare']])), {
    message:
      '::error::the callers pass different native-stack inputs: bare (check.yml, build-ios.yml), expo (test-e2e.yml). A repository is one stack: pass the same value to every workflow that takes it',
  });
});

test('a consumer read from disk carries its stack, detected from package.json and git', () => {
  const expo = JSON.stringify({ devDependencies: { expo: '~57.0.0' } });
  assert.deepEqual(readConsumer(tree({ 'package.json': expo })).stack, { stack: 'expo', reason: 'expo is a dependency and git tracks no ios/' });
  assert.equal(readConsumer(tree({ 'package.json': '{}' })).stack.stack, 'bare');
  assert.equal(readConsumer(tree()).stack.stack, 'bare');
  const tracked = { ...defaultIo, tracked: (_root, dir) => dir === 'ios' };
  assert.equal(readConsumer(tree({ 'package.json': expo }), tracked).stack.stack, 'bare');
});

test('the callers\' input, then --native-stack, decide over the repository, and then git is not asked', () => {
  const io = { ...defaultIo, tracked: () => assert.fail('git was asked although an input decides') };
  const expo = JSON.stringify({ dependencies: { expo: '1' } });
  const root = tree({ 'package.json': expo, '.github/workflows/ci.yml': caller('check.yml', '      native-stack: bare\n') });
  assert.deepEqual(readConsumer(root, io).stack, { stack: 'bare', reason: 'the native-stack input' });
  assert.equal(readConsumer(root, io, { nativeStack: 'expo' }).stack.stack, 'expo');
  assert.equal(readConsumer(tree({ 'package.json': '{}' }), io, { nativeStack: ' bare ' }).stack.stack, 'bare');
});

test('an Expo-only row is skipped on the bare stack, saying which stack and why', () => {
  const callers = { 'ci.yml': caller('check.yml') };
  const health = check(readContract(), consumer({ callers, stack: BARE_STACK })).find((r) => r.req.id === 'package-script.check-expo-health');
  assert.deepEqual([health.level, health.reason], ['skip', 'only the expo stack needs it, and this repository is bare (expo is not a dependency in package.json)']);
  // The same caller on the Expo stack is held to it.
  assert.equal(check(readContract(), consumer({ callers })).find((r) => r.req.id === 'package-script.check-expo-health').level, 'warn');
});

test('the e2e and release Expo rows apply on the Expo stack only', () => {
  const callers = { 'ci.yml': caller('test-e2e.yml'), 'cd.yml': caller('build-prepare.yml') };
  const expo = check(readContract(), consumer({ callers }));
  assert.ok(ids(expo, 'fail').includes('file.expo-configuration'));
  assert.ok(ids(expo, 'fail').includes('package-dep.fingerprint'));
  const bare = check(readContract(), consumer({ callers, stack: BARE_STACK }));
  assert.ok(ids(bare, 'skip').includes('file.expo-configuration'));
  assert.ok(ids(bare, 'skip').includes('package-dep.fingerprint'));
});

test('a bare app must track the ios/ and android/ its callers build, and only those', () => {
  const e2e = { 'ci.yml': caller('test-e2e.yml') };
  // test-e2e.yml builds Android by default and iOS only when asked.
  const androidOnly = check(readContract(), consumer({ callers: e2e, stack: BARE_STACK }));
  const android = androidOnly.find((r) => r.req.id === 'tracked-dir.android-e2e');
  assert.deepEqual([android.level, android.reason], ['fail', 'git tracks nothing under android/']);
  assert.equal(androidOnly.find((r) => r.req.id === 'tracked-dir.ios-e2e').reason, 'test-e2e.yml:ios is off');
  const both = { 'ci.yml': caller('test-e2e.yml', '      ios: true\n') };
  assert.deepEqual(ids(check(readContract(), consumer({ callers: both, stack: BARE_STACK, tracked: ['ios', 'android'] })), 'ok').filter((id) => id.startsWith('tracked-dir.')), [
    'tracked-dir.ios-e2e',
    'tracked-dir.android-e2e',
  ]);
});

test('a release row naming a workflow applies only when that workflow is called', () => {
  const callers = { 'cd.yml': caller('build-android.yml') };
  const results = check(readContract(), consumer({ callers, stack: BARE_STACK, tracked: ['android'] }));
  const ios = results.find((r) => r.req.id === 'tracked-dir.ios-build');
  assert.deepEqual([ios.level, ios.reason], ['skip', 'build-ios.yml or publish-internal.yml is not called from this repository']);
  assert.equal(results.find((r) => r.req.id === 'tracked-dir.android-build').level, 'ok');
  const untracked = check(readContract(), consumer({ callers: { 'cd.yml': caller('build-ios.yml') }, stack: BARE_STACK }));
  assert.equal(untracked.find((r) => r.req.id === 'tracked-dir.ios-build').level, 'fail');
  // On the Expo stack the native projects are generated, so neither is asked for.
  assert.equal(check(readContract(), consumer({ callers })).find((r) => r.req.id === 'tracked-dir.android-build').level, 'skip');
});

test('a release row naming a leaf and its pipeline applies to a caller of either', () => {
  const callers = { 'cd.yml': caller('publish-internal.yml') };
  const results = check(readContract(), consumer({ callers, stack: BARE_STACK, tracked: ['android'] }));
  assert.equal(results.find((r) => r.req.id === 'tracked-dir.android-build').level, 'ok');
  const ios = results.find((r) => r.req.id === 'tracked-dir.ios-build');
  assert.deepEqual([ios.level, ios.reason], ['fail', 'git tracks nothing under ios/']);
  // A caller of the beta pipeline builds nothing, so neither project is asked for.
  const beta = check(readContract(), consumer({ callers: { 'cd.yml': caller('publish-beta.yml') }, stack: BARE_STACK }));
  assert.equal(beta.find((r) => r.req.id === 'tracked-dir.ios-build').level, 'skip');
});

test('the default io asks git which directories it tracks', () => {
  assert.equal(defaultIo.tracked(tree({ 'ios/Podfile': '' }), 'ios'), false);
});

test('an Expo-only gate script CI skips on the bare stack is not a script make ci must reach', () => {
  const contract = readContract();
  const uses = new Set(['check.yml']);
  assert.ok(ciScripts(contract, uses, new Map(), null).on.has('check:expo-health'));
  assert.ok(ciScripts(contract, uses, new Map(), null, 'expo').on.has('check:expo-health'));
  assert.ok(!ciScripts(contract, uses, new Map(), null, 'bare').on.has('check:expo-health'));
  assert.ok(ciScripts(contract, uses, new Map(), null, 'bare').on.has('check:types'));
});

test('the report, the job summary and the skeleton each name the stack they judged', () => {
  assert.equal(stackLine(BARE_STACK), 'native stack: bare (expo is not a dependency in package.json)');
  assert.match(summaryTable([], EXPO_STACK), /^## Consumer contract\n\nNative stack: \*\*expo\*\* \(expo is a dependency and git tracks no ios\/\)\.\n\nEvery requirement/);
  assert.doesNotMatch(summaryTable([]), /Native stack/);
  assert.match(skeleton([], BARE_STACK), /^Judged as the bare stack \(expo is not a dependency in package\.json\)\. If this repository is expo, pass native-stack: expo to the workflows that take it\.\n/);
  assert.match(skeleton([], EXPO_STACK), /If this repository is bare, pass native-stack: bare/);
  assert.equal(skeleton([]), '');
});

test('the program prints the stack first, takes --native-stack, and puts the stack in the skeleton', () => {
  const root = tree({ '.github/workflows/ci.yml': CHECKS_CALLER });
  const { stdout } = runMain(['--root', root, '--native-stack', 'expo', '--skeleton']);
  assert.match(stdout, /^native stack: expo \(the native-stack input\)\n/);
  assert.match(stdout, /\nJudged as the expo stack \(the native-stack input\)\./);
  // On expo the Expo health script is asked for; on the detected bare stack it is not.
  assert.match(stdout, /^warn {2}check:expo-health: /m);
  assert.doesNotMatch(runMain(['--root', root]).stdout, /check:expo-health/);
});

test('callers disagreeing on the stack is one error line and exit 1', () => {
  const root = tree({
    '.github/workflows/ci.yml': caller('check.yml', '      native-stack: bare\n'),
    '.github/workflows/e2e.yml': caller('test-e2e.yml', '      native-stack: expo\n'),
  });
  const { code, stdout, stderr } = runMain(['--root', root]);
  assert.equal(code, 1);
  assert.equal(stdout, '');
  assert.match(stderr, /^::error::the callers pass different native-stack inputs: bare \(check\.yml\), expo \(test-e2e\.yml\)\.[^\n]*\n$/);
});

test('a --native-stack that is not a stack is one error line and exit 1', () => {
  const { code, stderr } = runMain(['--root', tree(), '--native-stack', 'native']);
  assert.equal(code, 1);
  assert.match(stderr, /^::error::native-stack is "native": /);
});

// --- the fastlane rows read the callers' fastlane-directory ------------------

test('the fastlane directory is the one literal the callers agree on, else fastlane', () => {
  assert.equal(fastlaneInput(new Map()), 'fastlane');
  assert.equal(fastlaneInput(new Map([['build-ios.yml:fastlane-directory', '']])), 'fastlane');
  assert.equal(fastlaneInput(new Map([['build-ios.yml:fastlane-directory', '${{ vars.FASTLANE }}']])), 'fastlane');
  assert.equal(fastlaneInput(new Map([['build-ios.yml:native-stack', 'mobile/fastlane']])), 'fastlane');
  // A trailing slash is the same directory, so two spellings of it agree.
  assert.equal(
    fastlaneInput(new Map([['build-ios.yml:fastlane-directory', 'mobile/fastlane/'], ['publish-store.yml:fastlane-directory', 'mobile/fastlane']])),
    'mobile/fastlane',
  );
});

test('callers passing two different fastlane directories is an error naming each and where', () => {
  assert.throws(
    () =>
      fastlaneInput(
        new Map([
          ['build-ios.yml:fastlane-directory', 'mobile/fastlane'],
          ['build-android.yml:fastlane-directory', 'fastlane'],
          ['publish-store.yml:fastlane-directory', 'mobile/fastlane'],
        ]),
      ),
    {
      message:
        '::error::the callers pass different fastlane-directory inputs: mobile/fastlane (build-ios.yml, publish-store.yml), fastlane (build-android.yml). A repository has one Fastfile: pass the same fastlane-directory to every workflow that takes it',
    },
  );
});

test('literalInput reads one input by name and leaves every other alone', () => {
  const inputs = new Map([['a.yml:x', '1'], ['b.yml:y', '2'], ['c.yml:x', '1']]);
  assert.equal(literalInput(inputs, 'x', 'unused'), '1');
  assert.equal(literalInput(inputs, 'z', 'unused'), '');
  assert.throws(() => literalInput(new Map([['a.yml:x', '1'], ['b.yml:x', '2']]), 'x', 'Why.'), {
    message: '::error::the callers pass different x inputs: 1 (a.yml), 2 (b.yml). Why.',
  });
});

test('a consumer read from disk carries the callers\' fastlane directory, and refuses two', () => {
  const ios = (directory) => caller('build-ios.yml', `      fastlane-directory: ${directory}\n`);
  assert.equal(readConsumer(tree({ 'package.json': '{}' })).fastlaneDirectory, 'fastlane');
  assert.equal(readConsumer(tree({ '.github/workflows/cd.yml': ios('mobile/fastlane') })).fastlaneDirectory, 'mobile/fastlane');
  const two = tree({
    '.github/workflows/cd.yml': ios('mobile/fastlane'),
    '.github/workflows/store.yml': caller('publish-store.yml', '      fastlane-directory: fastlane\n'),
  });
  assert.throws(() => readConsumer(two), /the callers pass different fastlane-directory inputs/);
});

const LANES = 'platform :ios do\n  lane :build do\n  end\n  lane :verify do\n  end\nend\nplatform :android do\n  lane :build do\n  end\n  lane :verify do\n  end\nend\n';
const mobile = (files = {}) =>
  consumer({
    files,
    dirs: Object.keys(files).length > 0 ? ['mobile/fastlane'] : [],
    callers: { 'cd.yml': caller('build-ios.yml', '      fastlane-directory: mobile/fastlane\n') },
  });

test('the Fastfile is looked for under the callers\' fastlane directory', () => {
  const found = checkRequirement(req('file.fastfile'), mobile({ 'mobile/fastlane/Fastfile': LANES }));
  assert.deepEqual(found, { status: 'ok', detail: 'mobile/fastlane/Fastfile' });
  // A root fastlane/ is not where the lanes run, so it does not count.
  const root = checkRequirement(req('file.fastfile'), mobile({ 'fastlane/Fastfile': LANES }));
  assert.deepEqual(root, { status: 'missing', reason: 'none of mobile/fastlane/Fastfile exists' });
  // Paths outside fastlane/ are untouched.
  assert.equal(checkRequirement(req('file.gemfile'), mobile({ Gemfile: '' })).status, 'ok');
});

test('the lanes are read under the callers\' fastlane directory, and named by it', () => {
  assert.equal(checkRequirement(req('lane.build-verify'), mobile({ 'mobile/fastlane/Fastfile': LANES })).status, 'ok');
  assert.deepEqual(checkRequirement(req('lane.build-verify'), mobile({ 'fastlane/Fastfile': LANES })), {
    status: 'skip',
    reason: 'no mobile/fastlane/',
  });
  assert.deepEqual(checkRequirement(req('lane.build-verify'), mobile({ 'mobile/fastlane/Fastfile': 'lane :build do\nend\n' })), {
    status: 'missing',
    reason: 'mobile/fastlane/ defines no lane named verify',
  });
});

test('the App Review names are read from the lanes under the callers\' fastlane directory', () => {
  const lanes = (files) => checkRequirement(req('lane-environment.app-review'), mobile(files));
  assert.deepEqual(lanes({ 'fastlane/Fastfile': "ENV['APP_REVIEW_NICKNAME']\n" }), { status: 'skip', reason: 'no mobile/fastlane/' });
  assert.equal(lanes({ 'mobile/fastlane/Fastfile': "ENV['APP_REVIEW_EMAIL']\n" }).status, 'ok');
  assert.equal(lanes({ 'mobile/fastlane/Fastfile': "ENV['APP_REVIEW_NICKNAME']\n" }).status, 'missing');
});

// --- everything but the callers is read under the callers' working-directory --

test('the working directory is the one literal the callers agree on, else the repository root', () => {
  assert.equal(workingDirectoryInput(new Map()), '');
  assert.equal(workingDirectoryInput(new Map([['check.yml:working-directory', '']])), '');
  assert.equal(workingDirectoryInput(new Map([['check.yml:working-directory', '${{ vars.APP_DIRECTORY }}']])), '');
  assert.equal(workingDirectoryInput(new Map([['check.yml:fastlane-directory', 'app']])), '');
  // Trailing slashes are the same directory, so they never read as a conflict.
  assert.equal(
    workingDirectoryInput(
      new Map([
        ['check.yml:working-directory', 'app/'],
        ['build-ios.yml:working-directory', 'app'],
        ['test-e2e.yml:working-directory', '${{ vars.X }}'],
      ]),
    ),
    'app',
  );
});

test('callers passing two different working directories is an error naming each and where', () => {
  assert.throws(
    () =>
      workingDirectoryInput(
        new Map([
          ['check.yml:working-directory', 'app'],
          ['build-ios.yml:working-directory', 'mobile/'],
          ['publish-store.yml:working-directory', 'app/'],
        ]),
      ),
    {
      message:
        '::error::the callers pass different working-directory inputs: app (check.yml, publish-store.yml), mobile (build-ios.yml). A repository has one app directory: pass the same working-directory to every workflow that takes it',
    },
  );
});

test('a consumer read from disk is read under the callers\' working directory, its callers at the root', () => {
  const appCaller = (directory) => caller('check.yml', `      working-directory: ${directory}\n`);
  const repository = tree({
    'package.json': JSON.stringify({ scripts: { root: 'x' } }),
    '.github/workflows/ci.yml': appCaller('app/'),
    '.github/workflows/cd.yml': caller('build-ios.yml', '      working-directory: app\n      fastlane-directory: mobile/fastlane\n'),
    'app/package.json': JSON.stringify({ scripts: { 'check:lint': 'biome check' }, devDependencies: { knip: '5.0.0' } }),
    'app/.mise.toml': '[tools]\nnode = "24"\n',
    'app/mobile/fastlane/Fastfile': 'lane :build do\nend\nlane :verify do\nend\n',
  });
  const read = readConsumer(repository);
  assert.equal(read.repository, repository);
  assert.equal(read.workingDirectory, 'app');
  assert.equal(read.root, path.join(repository, 'app'));
  assert.deepEqual(read.callers.map((c) => c.name).sort(), ['cd.yml', 'ci.yml']);
  assert.deepEqual(read.scripts, { 'check:lint': 'biome check' });
  assert.deepEqual(read.deps, { knip: '5.0.0' });
  assert.equal(read.miseTools.file, '.mise.toml');
  assert.equal(read.fastlaneDirectory, 'mobile/fastlane');
  // The Fastfile and the lanes are found under app/mobile/fastlane, and the
  // repository's own fastlane/ (there is none) is not looked at.
  assert.deepEqual(checkRequirement(req('file.fastfile'), read), { status: 'ok', detail: 'mobile/fastlane/Fastfile' });
  assert.deepEqual(checkRequirement(req('lane.build-verify'), read), { status: 'ok', detail: undefined });
  assert.deepEqual(checkRequirement(req('package-script.check-lint'), read), { status: 'ok', detail: undefined });
});

test('a consumer whose callers pass no literal working directory is read at the repository root', () => {
  const repository = tree({
    'package.json': JSON.stringify({ scripts: { lint: 'biome check' } }),
    '.github/workflows/ci.yml': caller('check.yml', '      working-directory: ${{ vars.APP_DIRECTORY }}\n'),
  });
  const read = readConsumer(repository);
  assert.equal(read.workingDirectory, '');
  assert.equal(read.root, repository);
  assert.deepEqual(read.scripts, { lint: 'biome check' });
});

test('a consumer whose callers pass two working directories is refused, and the program says why', () => {
  const repository = tree({
    '.github/workflows/ci.yml': caller('check.yml', '      working-directory: app\n'),
    '.github/workflows/cd.yml': caller('build-ios.yml', '      working-directory: mobile\n'),
  });
  assert.throws(() => readConsumer(repository), /the callers pass different working-directory inputs/);
  let stderr = '';
  const code = main(['--root', repository], { stdout: { write() {} }, stderr: { write: (text) => { stderr += text; } }, env: {} });
  assert.equal(code, 1);
  assert.match(stderr, /^::error::the callers pass different working-directory inputs: (app \(check\.yml\), mobile \(build-ios\.yml\)|mobile \(build-ios\.yml\), app \(check\.yml\))\.[^\n]*\n$/);
});

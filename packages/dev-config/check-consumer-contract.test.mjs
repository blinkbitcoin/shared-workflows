import assert from 'node:assert/strict';
import { test } from 'node:test';
import {
  activeProfiles,
  callerInputs,
  callersUse,
  check,
  checkRequirement,
  formatResult,
  parseMiseTools,
  readContract,
  readMakefile,
  skeleton,
  summaryTable,
  toggleOn,
} from './bin/check-consumer-contract.mjs';

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
    'script-or-dep',
    'file',
    'dir-nonempty',
    'mise-tool',
    'ignores-workflows',
    'ignores-workflows-or-narrow',
    'caller-path',
    'fastlane-lane',
    'make-ci-reaches-ci',
    'ci-runs-make-ci',
    'fastlane-env-subset',
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
    uses: blinkbitcoin/shared-workflows/.github/workflows/check-code.yml@v0
    with:
      docs-check: false
      release-checks: true
  unit:
    name: Unit
    uses: blinkbitcoin/shared-workflows/.github/workflows/check-unit.yml@v0
  e2e:
    name: E2E
    uses: blinkbitcoin/shared-workflows/.github/workflows/check-e2e.yml@v0
    with:
      ios: \${{ vars.E2E_IOS == 'true' }}
      e2e-setup-script: scripts/e2e/up.sh
`;

test('the caller parser finds which reusable workflows a repository calls', () => {
  const uses = callersUse([{ name: 'ci.yml', text: CALLER }]);
  assert.deepEqual([...uses].sort(), ['check-code.yml', 'check-e2e.yml', 'check-unit.yml']);
});

test('the caller parser attributes each with: key to its own workflow', () => {
  const inputs = callerInputs([{ name: 'ci.yml', text: CALLER }]);
  assert.equal(inputs.get('check-code.yml:docs-check'), 'false');
  assert.equal(inputs.get('check-code.yml:release-checks'), 'true');
  assert.equal(inputs.get('check-e2e.yml:e2e-setup-script'), 'scripts/e2e/up.sh');
  // check-unit.yml has no with: block, so nothing may leak into it from its neighbours
  assert.equal(inputs.get('check-unit.yml:docs-check'), undefined);
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
  assert.deepEqual([...activeProfiles(new Set(['check-code.yml']), ['release'])], ['release']);
});

// --- toggles -----------------------------------------------------------------

test('a gate the caller switched off is not a finding', () => {
  const inputs = callerInputs([{ name: 'ci.yml', text: CALLER }]);
  assert.equal(toggleOn(req('script.check-docs'), inputs), false);
});

test('a gate the caller switched on is checked even when it defaults off', () => {
  const inputs = callerInputs([{ name: 'ci.yml', text: CALLER }]);
  assert.equal(req('script.check-release').defaultOn, false);
  assert.equal(toggleOn(req('script.check-release'), inputs), true);
});

test('an input the caller leaves alone falls back to the workflow default', () => {
  assert.equal(toggleOn(req('script.typecheck'), new Map()), true);
  assert.equal(toggleOn(req('script.check-prebuild'), new Map()), false);
});

test('a toggle wired to an expression is neither on nor off', () => {
  const inputs = new Map([['check-code.yml:typecheck', '${{ vars.TYPECHECK }}']]);
  assert.equal(toggleOn(req('script.typecheck'), inputs), 'unknown');
});

test('a requirement behind an expression is reported but never blocks', () => {
  // This job gates every other job in check-code.yml. Blocking ten of them because
  // a `${{ vars.X }}` could not be read here would be a false failure - and
  // staying silent would hide a real one. So: warn, and say why.
  const caller = [
    'jobs:',
    '  checks:',
    '    uses: blinkbitcoin/shared-workflows/.github/workflows/check-code.yml@v0',
    '    with:',
    '      typecheck: ${{ vars.TYPECHECK }}',
  ].join('\n');
  const c = consumer({ callers: { 'ci.yml': caller } });
  const result = check(readContract(), c).find((r) => r.req.id === 'script.typecheck');
  assert.equal(result.level, 'warn');
  assert.match(result.reason, /cannot evaluate/);
});

// --- individual checks -------------------------------------------------------

test('a package script is found by name', () => {
  const c = consumer({ pkg: { scripts: { typecheck: 'tsc --noEmit' } } });
  assert.equal(checkRequirement(req('script.typecheck'), c).status, 'ok');
  assert.equal(checkRequirement(req('script.lint'), c).status, 'missing');
});

test('knip passes as a dependency and is never asked for as a script', () => {
  const asDep = consumer({ pkg: { devDependencies: { knip: '^6' } } });
  assert.equal(checkRequirement(req('script.knip'), asDep).status, 'ok');
  assert.equal(checkRequirement(req('script.knip'), consumer()).status, 'missing');
});

test('the mise check names the tool that is missing, not just the file', () => {
  const c = consumer();
  c.miseTools = { file: '.mise.toml', tools: new Set(['node']) };
  const result = checkRequirement(req('toolchain.mise'), c);
  assert.equal(result.status, 'missing');
  assert.match(result.reason, /pins no pnpm/);
});

test('no mise config at all is reported as the missing file', () => {
  const c = consumer();
  c.miseTools = { file: null, tools: new Set() };
  assert.match(checkRequirement(req('toolchain.mise'), c).reason, /no mise config/);
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
  assert.equal(checkRequirement(req('file.expo-config'), consumer({ files: { 'app.json': '{}' } })).status, 'ok');
  assert.equal(checkRequirement(req('file.expo-config'), consumer()).status, 'missing');
});

test('an e2e hook input naming a file that does not exist is a finding', () => {
  const c = consumer({ callers: { 'ci.yml': CALLER } });
  const result = checkRequirement(req('caller.e2e-hooks'), c);
  assert.equal(result.status, 'missing');
  assert.match(result.reason, /scripts\/e2e\/up\.sh, which does not exist/);
});

test('an e2e hook input left empty is not a finding', () => {
  const c = consumer({ callers: { 'ci.yml': CALLER.replace('e2e-setup-script: scripts/e2e/up.sh', "e2e-setup-script: ''") } });
  assert.equal(checkRequirement(req('caller.e2e-hooks'), c).status, 'ok');
});

test('a config this repository does not have is skipped, not failed', () => {
  // A consumer with no biome.json does not use biome, so nothing of ours is in
  // its reach and there is nothing for it to exclude.
  assert.equal(checkRequirement(req('ignores.biome'), consumer()).status, 'skip');
});

test('a config that globs the whole tree must exclude the .workflows checkout', () => {
  const blind = consumer({ files: { 'biome.json': '{"files":{"includes":["**/*.ts"]}}' } });
  assert.equal(checkRequirement(req('ignores.biome'), blind).status, 'missing');
  const excluded = consumer({ files: { 'biome.json': '{"files":{"includes":["**/*.ts","!**/.workflows"]}}' } });
  assert.equal(checkRequirement(req('ignores.biome'), excluded).status, 'ok');
});

test('knip is satisfied by globs that never reach into .workflows', () => {
  // The guide accepts either answer for knip, and the template ships the second
  // one. Demanding the ignore entry would report a finding the consumer would be
  // right to ignore.
  const narrow = consumer({ files: { 'knip.json': '{"project":["src/**/*.ts","scripts/**/*.mjs"]}' } });
  assert.equal(checkRequirement(req('ignores.knip'), narrow).status, 'ok');
  const treeWide = consumer({ files: { 'knip.json': '{"project":["**/*.ts"]}' } });
  assert.equal(checkRequirement(req('ignores.knip'), treeWide).status, 'missing');
});

test('a missing fastlane lane is named, and no fastlane at all is skipped', () => {
  const noFastlane = consumer();
  assert.equal(checkRequirement(req('lane.ios-build'), noFastlane).status, 'skip');
  const partial = consumer({
    dirs: ['fastlane'],
    files: { 'fastlane/Fastfile': 'platform :ios do\n  lane :build do\n  end\nend\n' },
  });
  const result = checkRequirement(req('lane.ios-build'), partial);
  assert.equal(result.status, 'missing');
  assert.match(result.reason, /verify/);
});

// --- severity ----------------------------------------------------------------

test('a missing required item blocks and a missing fallback item only degrades', () => {
  const c = consumer({ callers: { 'ci.yml': 'uses: blinkbitcoin/shared-workflows/.github/workflows/check-code.yml@v0\n' } });
  const results = check(readContract(), c);
  const byId = new Map(results.map((r) => [r.req.id, r]));
  assert.equal(byId.get('script.typecheck').level, 'fail');
  assert.equal(byId.get('script.deps-audit').level, 'warn');
});

test('a workflow this repository does not call produces no findings at all', () => {
  const c = consumer({ callers: { 'ci.yml': 'uses: blinkbitcoin/shared-workflows/.github/workflows/check-code.yml@v0\n' } });
  const results = check(readContract(), c);
  for (const result of results.filter((r) => r.req.profile === 'release')) {
    assert.equal(result.level, 'skip', `${result.req.id} should be skipped`);
  }
});

// --- reporting ---------------------------------------------------------------

test('every finding carries its fix, and a pass carries none', () => {
  const c = consumer({ callers: { 'ci.yml': 'uses: blinkbitcoin/shared-workflows/.github/workflows/check-code.yml@v0\n' } });
  for (const result of check(readContract(), c)) {
    const line = formatResult(result);
    if (result.level === 'fail' || result.level === 'warn') {
      assert.match(line, /Fix: /, `${result.req.id} must tell the reader what to do`);
    } else {
      assert.doesNotMatch(line, /Fix: /);
    }
  }
});

test('the skeleton never suggests a package script named knip', () => {
  // The fix text two lines above it says not to: a script of that name fails
  // expo-doctor, which check-code.yml also runs.
  const c = consumer({ callers: { 'ci.yml': 'uses: blinkbitcoin/shared-workflows/.github/workflows/check-code.yml@v0\n' } });
  const text = skeleton(check(readContract(), c));
  assert.doesNotMatch(text, /"knip":/);
  assert.match(text, /devDependencies: .*knip/);
});

test('the job summary distinguishes a blocked row from a degraded one', () => {
  const c = consumer({ callers: { 'ci.yml': 'uses: blinkbitcoin/shared-workflows/.github/workflows/check-code.yml@v0\n' } });
  const table = summaryTable(check(readContract(), c));
  assert.match(table, /\*\*blocked\*\*/);
  assert.match(table, /degraded/);
  assert.match(table, /consumer-guide\.md#/);
});

test('a clean consumer gets a summary that says so rather than an empty table', () => {
  const table = summaryTable([{ req: req('script.lint'), level: 'ok' }]);
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
    uses: blinkbitcoin/shared-workflows/.github/workflows/check-code.yml@v0
    with:
      docs-check: false
      spell: false
      knip: false
      licenses: false
      expo-doctor: false
      audit: false
      actionlint: false
      secret-scan: false
  unit:
    uses: blinkbitcoin/shared-workflows/.github/workflows/check-unit.yml@v0
`,
};

// With the caller above, CI runs typecheck, lint, format:check, test:coverage
// and test:scripts - and nothing else.
const ALIGNED_MAKEFILE = `check: typecheck lint format-check ## gates
typecheck: ## types
\tpnpm typecheck
lint:
\tpnpm lint
format-check:
\tpnpm format:check
coverage:
\tpnpm test:coverage
test-scripts:
\tpnpm test:scripts
ci: check coverage test-scripts ## everything
`;

const gateResults = (makefile, callers = GATE_CALLER) => {
  const c = consumer({ files: makefile === null ? {} : { Makefile: makefile }, callers });
  const byId = new Map(check(readContract(), c).map((r) => [r.req.id, r]));
  return { reaches: byId.get('gate.make-ci-reaches-ci'), runs: byId.get('gate.ci-runs-make-ci') };
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
  const { runs } = gateResults(`${ALIGNED_MAKEFILE}spell:\n\tpnpm spell\nci: check coverage test-scripts spell\n`);
  assert.equal(runs.level, 'fail');
  assert.match(runs.reason, /spell/);
});

test('a toggle wired to an expression never fails the gate-set rules', () => {
  const callers = { 'ci.yml': GATE_CALLER['ci.yml'].replace('spell: false', 'spell: ${{ vars.SPELL }}') };
  const withSpell = `${ALIGNED_MAKEFILE}spell:\n\tpnpm spell\nci: check coverage test-scripts spell\n`;
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
  assert.deepEqual([...make.reachable('ci')].sort(), ['check', 'ci', 'coverage', 'format-check', 'lint', 'test-scripts', 'typecheck']);
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
  return check(readContract(), c).find((r) => r.req.id === 'lane.app-review-env');
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

#!/usr/bin/env node
// Answer "is this repository wired up for the shared workflows?" in one report,
// before a run spends twenty minutes answering it one red job at a time.
//
//   check-consumer-contract [--root DIR] [--profile checks,unit,...] [--json] [--skeleton]
//
// Why this exists. Every gate in this family already fails with a good message:
// `run-script.sh` names the script it wanted, `tool-version.sh` names the file.
// What none of them can do is tell you the *other* eight things that are also
// missing, because each one runs in its own job and dies on the first. A repo
// that was never generated from react-native-mobile-template therefore learns
// the contract serially - nine parallel reds, then the next seam one push later.
//
// So this reads the contract as data (../contract.json), checks the whole of it
// against a consumer checkout, and reports everything at once with a fix per
// finding. It runs before the setup action, so it may use nothing but node: no
// pnpm, no yq, no installed dependencies, no node_modules.
//
// It is deliberately conservative about what counts as a failure. A gate the
// caller turned off is not a finding. A gate shared-workflows has a fallback for
// is a warning, not a failure - the run will go green, just not measuring what
// the consumer would have measured. Only a requested gate that cannot run at all
// is a failure. A repository is allowed to use part of this family.
import { appendFileSync, existsSync, readdirSync, readFileSync, realpathSync, statSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));

/** The contract, as `{ profiles, requirements }`. */
export function readContract(file = path.join(HERE, '..', 'contract.json')) {
  return JSON.parse(readFileSync(file, 'utf8'));
}

// ---------------------------------------------------------------------------
// Reading the consumer
// ---------------------------------------------------------------------------

/**
 * Everything the checks need from a consumer checkout, read once. Injected as a
 * whole in the tests, so no case needs a temp directory unless it wants one.
 */
export function readConsumer(root, io = defaultIo) {
  const pkgText = io.read(path.join(root, 'package.json'));
  let pkg = null;
  if (pkgText !== null) {
    try {
      pkg = JSON.parse(pkgText);
    } catch (error) {
      // A package.json that does not parse is worth saying out loud rather than
      // reporting as "no scripts": every script finding below would be a lie.
      throw new Error(`::error::${path.join(root, 'package.json')} is not valid JSON: ${error.message}`);
    }
  }
  const callers = readCallers(root, io);
  return {
    root,
    io,
    pkg,
    scripts: pkg?.scripts ?? {},
    deps: { ...(pkg?.dependencies ?? {}), ...(pkg?.devDependencies ?? {}) },
    miseTools: readMiseTools(root, io),
    callers,
    uses: callersUse(callers),
    inputs: callerInputs(callers),
  };
}

/**
 * The real filesystem, as the checks reach it. Exported so the tests can hold
 * each method to its contract against a temporary directory.
 */
export const defaultIo = {
  read(file) {
    try {
      return readFileSync(file, 'utf8');
    } catch {
      return null;
    }
  },
  exists(file) {
    return existsSync(file);
  },
  isNonEmptyDir(dir) {
    try {
      return statSync(dir).isDirectory() && readdirSync(dir).length > 0;
    } catch {
      return false;
    }
  },
  list(dir) {
    try {
      return readdirSync(dir);
    } catch {
      return [];
    }
  },
  // Synchronous on purpose. This used to be a dynamic import() in the CLI
  // branch, and `process.exit()` two lines later killed the pending promise -
  // the job summary was written on a passing run and lost on exactly the
  // failing runs it exists for.
  append(file, text) {
    appendFileSync(file, text);
  },
};

/** Tool names in a mise config's `[tools]` table. Empty set when there is none. */
export function readMiseTools(root, io = defaultIo) {
  for (const name of ['.mise.toml', 'mise.toml', '.config/mise/config.toml']) {
    const text = io.read(path.join(root, name));
    if (text === null) continue;
    return { file: name, tools: parseMiseTools(text) };
  }
  return { file: null, tools: new Set() };
}

/**
 * The `[tools]` table only. A hand-rolled reader rather than a TOML dependency:
 * this runs before any install, from a package that must stay dependency-free.
 */
export function parseMiseTools(text) {
  const tools = new Set();
  let inTools = false;
  for (const raw of text.split('\n')) {
    const line = raw.trim();
    if (line.startsWith('#') || line === '') continue;
    if (line.startsWith('[')) {
      inTools = line === '[tools]';
      continue;
    }
    if (!inTools) continue;
    const match = /^["']?([A-Za-z0-9_.:@/-]+)["']?\s*=/.exec(line);
    if (match) tools.add(match[1]);
  }
  return tools;
}

/** The consumer's own workflow files, as `{ name, text }`. */
export function readCallers(root, io = defaultIo) {
  const dir = path.join(root, '.github', 'workflows');
  return io
    .list(dir)
    .filter((name) => name.endsWith('.yml') || name.endsWith('.yaml'))
    .map((name) => ({ name, text: io.read(path.join(dir, name)) ?? '' }));
}

/**
 * Which reusable workflows this repository actually calls, e.g. `check-code.yml`.
 * This is what makes the report honest: a repo with no e2e caller must not be
 * told it is missing `.maestro/`.
 */
export function callersUse(callers) {
  const used = new Set();
  const pattern = /shared-workflows\/\.github\/workflows\/([A-Za-z0-9._-]+\.yml)@/g;
  for (const { text } of callers) {
    for (const match of text.matchAll(pattern)) used.add(match[1]);
  }
  return used;
}

/**
 * Inputs the caller passes, keyed `<workflow>.yml:<input>`.
 *
 * Hand-rolled rather than a YAML parser, for the same reason as the mise reader.
 * It tracks which reusable workflow the current `with:` block belongs to by
 * remembering the most recent `uses:` at a shallower indent, which is the shape
 * every caller in the guide has. Anything it cannot read is simply absent from
 * the map, and an absent toggle falls back to the workflow's own default - so a
 * parse it gets wrong costs accuracy in the report, never a false failure.
 */
export function callerInputs(callers) {
  const inputs = new Map();
  for (const { text } of callers) {
    let workflow = null;
    let withIndent = null;
    for (const raw of text.split('\n')) {
      if (raw.trim() === '' || raw.trim().startsWith('#')) continue;
      const indent = raw.length - raw.trimStart().length;
      const uses = /^\s*uses:\s*\S*shared-workflows\/\.github\/workflows\/([A-Za-z0-9._-]+\.yml)@/.exec(raw);
      if (uses) {
        workflow = uses[1];
        withIndent = null;
        continue;
      }
      if (workflow === null) continue;
      if (/^\s*with:\s*$/.test(raw)) {
        withIndent = indent;
        continue;
      }
      if (withIndent === null) {
        // A `uses:` is only followed by its own keys; anything at or above its
        // own indent has ended the job block.
        if (indent === 0) workflow = null;
        continue;
      }
      if (indent <= withIndent) {
        withIndent = null;
        if (indent === 0) workflow = null;
        continue;
      }
      const pair = /^\s*([A-Za-z0-9._-]+):\s*(.*)$/.exec(raw);
      if (pair) inputs.set(`${workflow}:${pair[1]}`, stripQuotes(pair[2].trim()));
    }
  }
  return inputs;
}

function stripQuotes(value) {
  const match = /^(['"])(.*)\1$/.exec(value);
  return match ? match[2] : value;
}

// ---------------------------------------------------------------------------
// Deciding what applies
// ---------------------------------------------------------------------------

/**
 * Whether a requirement's gate is switched on, given what the caller passes:
 * `true`, `false`, or `'unknown'` for a toggle wired to an expression.
 *
 * `'unknown'` is its own answer rather than a guess in either direction. This
 * job blocks every other job in check-code.yml, so treating `${{ vars.X }}` as on
 * would let a repository that legitimately has that gate off be blocked by a
 * requirement it does not have - a false failure on ten jobs, from a value we
 * cannot read. Treating it as off would be the opposite mistake, and silence
 * about a gate that is in fact running. So it is reported, and never blocks:
 * `check()` turns an unknown-toggle finding into a warning whatever the
 * requirement's severity says.
 */
export function toggleOn(req, inputs) {
  if (!req.toggle) return true;
  const value = inputs.get(req.toggle);
  if (value === undefined) return req.defaultOn;
  if (value === 'false') return false;
  if (value === 'true') return true;
  return 'unknown';
}

/** The profiles to check: what the caller uses, or an explicit override. */
export function activeProfiles(uses, override) {
  if (override && override.length > 0) return new Set(override);
  const active = new Set();
  if (uses.has('check-code.yml')) active.add('checks');
  if (uses.has('check-unit.yml')) active.add('unit');
  if (uses.has('check-e2e.yml')) active.add('e2e');
  if (uses.has('build-web.yml')) active.add('web');
  if (uses.has('publish-badges.yml')) active.add('badges');
  if (uses.has('check-codeql.yml')) active.add('codeql');
  for (const name of ['build-prepare.yml', 'build-ios.yml', 'build-android.yml', 'publish-store.yml', 'publish-ota.yml']) {
    if (uses.has(name)) active.add('release');
  }
  // No caller found at all: a repository being checked before it has written
  // one. Check what every consumer needs rather than nothing.
  if (active.size === 0) return new Set(['checks', 'unit']);
  return active;
}

// ---------------------------------------------------------------------------
// The checks
// ---------------------------------------------------------------------------

/** `{ status, reason }` for one requirement. `status` is ok | missing | skip. */
export function checkRequirement(req, consumer) {
  const { io, root, scripts, deps } = consumer;
  const has = (file) => io.exists(path.join(root, file));

  switch (req.kind) {
    case 'package-script':
      return scripts[req.target]
        ? ok()
        : missing(`no "${req.target}" script in package.json`);

    case 'package-dep':
      return deps[req.target]
        ? ok()
        : missing(`${req.target} is not a dependency`);

    case 'script-or-dep':
      if (scripts[req.target]) return ok(`"${req.target}" script`);
      return deps[req.target] ? ok(`${req.target} dependency`) : missing(`neither a "${req.target}" script nor a ${req.target} dependency`);

    case 'file': {
      const found = req.target.find(has);
      return found ? ok(found) : missing(`none of ${req.target.join(', ')} exists`);
    }

    case 'dir-nonempty':
      return io.isNonEmptyDir(path.join(root, req.target))
        ? ok()
        : missing(`${req.target}/ is missing or empty`);

    case 'mise-tool': {
      const { file, tools } = consumer.miseTools;
      if (file === null) return missing('no mise config (.mise.toml)');
      const absent = req.target.filter((tool) => !tools.has(tool));
      return absent.length === 0 ? ok(file) : missing(`${file} pins no ${absent.join(' or ')}`);
    }

    case 'ignores-workflows':
    case 'ignores-workflows-or-narrow': {
      const text = consumer.io.read(path.join(root, req.target));
      // A config this repository does not have is not a finding: the consumer
      // does not use that tool, so nothing of ours can walk into its glob.
      if (text === null) return skip(`no ${req.target}`);
      if (text.includes('.workflows')) return ok();
      // The guide accepts a second answer for globbed tools: globs that never
      // reach in. A config with no tree-wide `**/` pattern cannot walk into a
      // sibling directory, so there is nothing for it to exclude. Checking this
      // rather than demanding the entry keeps the report free of a finding the
      // consumer would be right to ignore.
      if (req.kind === 'ignores-workflows-or-narrow' && !/["'`]\*\*\//.test(text)) {
        return ok('no tree-wide glob to exclude it from');
      }
      return missing(`${req.target} does not exclude .workflows`);
    }

    case 'caller-path': {
      const unresolved = [];
      for (const key of req.target) {
        const value = consumer.inputs.get(key);
        if (!value || value.includes('${{')) continue;
        if (!has(value)) unresolved.push(`${key} names ${value}, which does not exist`);
      }
      return unresolved.length === 0 ? ok() : missing(unresolved.join('; '));
    }

    case 'fastlane-lane': {
      // A textual scan of fastlane/**.rb, not a Ruby parse: enough to catch a
      // lane that was never written, and honest about being no more than that.
      const dir = path.join(root, 'fastlane');
      const text = collectRuby(dir, consumer.io);
      if (text === null) return skip('no fastlane/');
      const absent = req.target.filter((lane) => !text.includes(`lane :${lane.split(':')[1]}`));
      return absent.length === 0 ? ok() : missing(`fastlane defines no lane named ${absent.map((l) => l.split(':')[1]).join(', ')}`);
    }

    case 'make-ci-reaches-ci': {
      // CI runs a gate `make ci` cannot reach: a developer has no one command
      // that makes the same checks CI does.
      const make = readMakefile(root, io);
      if (make === null) return skip('no Makefile');
      if (!make.rules.has(req.target)) return skip(`the Makefile has no ${req.target} target`);
      const targets = make.reachable(req.target);
      const recipes = [...targets].map((t) => make.rules.get(t)?.recipe ?? '').join('\n');
      const unreached = [...consumer.ciScripts.on].filter((name) => {
        const dashed = name.replaceAll(':', '-');
        return !(recipes.includes(name) || recipes.includes(dashed) || targets.has(dashed));
      });
      return unreached.length === 0
        ? ok()
        : missing(`CI runs ${unreached.map((n) => `"${n}"`).join(', ')}, and \`make ${req.target}\` does not reach ${unreached.length === 1 ? 'it' : 'them'}`);
    }

    case 'ci-runs-make-ci': {
      // The other direction: `make ci` runs a gate no CI step runs, so a green
      // laptop claims coverage CI does not have. Every target it reaches with a
      // recipe of its own must be a CI script by its dashed name, or run only
      // pnpm scripts CI runs. An aggregate has no recipe; its prerequisites are
      // visited on their own.
      const make = readMakefile(root, io);
      if (make === null) return skip('no Makefile');
      if (!make.rules.has(req.target)) return skip(`the Makefile has no ${req.target} target`);
      const inCi = consumer.ciScripts.maybe;
      const dashed = new Set([...inCi].map((n) => n.replaceAll(':', '-')));
      const orphans = [];
      for (const target of make.reachable(req.target)) {
        const recipe = make.rules.get(target)?.recipe ?? '';
        if (recipe === '' || dashed.has(target)) continue;
        const scripts = [...recipe.matchAll(/pnpm (?:run )?([A-Za-z0-9:_-]+)/g)].map((m) => m[1]);
        if (scripts.length === 0) orphans.push(target);
        for (const s of scripts) if (!inCi.has(s)) orphans.push(`${target} (pnpm ${s})`);
      }
      return orphans.length === 0
        ? ok()
        : missing(`\`make ${req.target}\` runs ${orphans.join(', ')}, and no CI step does`);
    }

    case 'fastlane-env-subset': {
      // A lane reading an environment variable the lane workflow never passes
      // gets an empty string, and fastlane uploads the empty value.
      const text = collectRuby(path.join(root, 'fastlane'), io);
      if (text === null) return skip('no fastlane/');
      const prefix = req.prefix;
      const read = new Set(
        [...text.matchAll(/ENV(?:\.fetch\(|\[)\s*['"]([A-Z0-9_]+)['"]/g)].map((m) => m[1]).filter((n) => n.startsWith(prefix)),
      );
      const unknown = [...read].filter((n) => !req.target.includes(n)).sort();
      return unknown.length === 0
        ? ok(`${read.size} ${prefix}* names`)
        : missing(`the lanes read ${unknown.join(', ')}, which publish-store.yml does not pass`);
    }

    default:
      return skip(`unknown kind: ${req.kind}`);
  }
}

/**
 * The consumer's Makefile as `{ rules, reachable(target) }`: each rule's
 * prerequisites and recipe text, and every target a `make TARGET` reaches by
 * following prerequisites. Parsed, not run - running `make` here would run the
 * gates themselves. `null` when there is no Makefile.
 */
export function readMakefile(root, io = defaultIo) {
  const text = io.read(path.join(root, 'Makefile'));
  if (text === null) return null;
  const rules = new Map();
  let current = null;
  for (const line of text.split('\n')) {
    // `target: dep dep ## description`. A recipe line is indented, so a line
    // with leading whitespace is never a rule, and `:=` is an assignment.
    const rule = /^([A-Za-z0-9_-]+):([^=]*)$/.exec(line);
    if (rule) {
      const rhs = rule[2].split('##')[0].trim();
      current = { deps: rhs ? rhs.split(/\s+/) : [], recipe: '' };
      rules.set(rule[1], current);
      continue;
    }
    if (current && /^\s/.test(line) && line.trim() !== '') {
      current.recipe += `${line}\n`;
    } else if (!/^\s/.test(line) && line.trim() !== '' && !line.startsWith('#')) {
      current = null;
    }
  }
  const reachable = (start) => {
    const seen = new Set();
    const walk = (t) => {
      if (seen.has(t)) return;
      seen.add(t);
      for (const d of rules.get(t)?.deps ?? []) walk(d);
    };
    walk(start);
    return seen;
  };
  return { rules, reachable };
}

/**
 * The package scripts CI runs for this caller, from the contract itself: every
 * script requirement of the check-code and check-unit workflows whose workflow is called
 * and whose toggle is on. `on` holds the toggles known to be on; `maybe` adds
 * the ones wired to an expression, so neither direction of the gate-set check
 * fails on a value it cannot read.
 */
export function ciScripts(contract, uses, inputs, profiles) {
  const active = activeProfiles(uses, profiles);
  const on = new Set();
  const maybe = new Set();
  for (const req of contract.requirements) {
    if (!['package-script', 'script-or-dep'].includes(req.kind)) continue;
    if (!['checks', 'unit'].includes(req.profile) || !active.has(req.profile)) continue;
    const state = toggleOn(req, inputs);
    if (state === true) on.add(req.target);
    if (state !== false) maybe.add(req.target);
  }
  return { on, maybe };
}

function collectRuby(dir, io, depth = 0) {
  const entries = io.list(dir);
  if (entries.length === 0 && depth === 0) return null;
  let text = '';
  for (const entry of entries) {
    const full = path.join(dir, entry);
    if (entry.endsWith('.rb') || entry === 'Fastfile') text += `${io.read(full) ?? ''}\n`;
    // Below the top level this always returns text: only an empty fastlane/
    // itself is `null`, meaning "no fastlane at all".
    else if (depth < 2 && io.isNonEmptyDir(full)) text += collectRuby(full, io, depth + 1);
  }
  return text;
}

const ok = (detail) => ({ status: 'ok', detail });
const missing = (reason) => ({ status: 'missing', reason });
const skip = (reason) => ({ status: 'skip', reason });

/** Every requirement, resolved against one consumer. */
export function check(contract, consumer, { profiles } = {}) {
  const active = activeProfiles(consumer.uses, profiles);
  consumer.ciScripts = ciScripts(contract, consumer.uses, consumer.inputs, profiles);
  return contract.requirements.map((req) => {
    if (!active.has(req.profile)) {
      return { req, level: 'skip', reason: `${req.profile} workflows are not called from this repository` };
    }
    const on = toggleOn(req, consumer.inputs);
    if (on === false) {
      return { req, level: 'skip', reason: `${req.toggle} is off` };
    }
    const result = checkRequirement(req, consumer);
    if (result.status === 'ok') return { req, level: 'ok', detail: result.detail };
    if (result.status === 'skip') return { req, level: 'skip', reason: result.reason };
    if (on === 'unknown') {
      return {
        req,
        level: 'warn',
        reason: `${result.reason} - and ${req.toggle} is an expression this cannot evaluate, so it is reported rather than blocked`,
      };
    }
    return { req, level: req.severity === 'required' ? 'fail' : 'warn', reason: result.reason };
  });
}

// ---------------------------------------------------------------------------
// Reporting
// ---------------------------------------------------------------------------

export function formatResult(result) {
  const { req, level, reason, detail } = result;
  const name = nameOf(req);
  if (level === 'ok') return `ok    ${name}${detail ? ` (${detail})` : ''}`;
  if (level === 'skip') return `skip  ${name}: ${reason}`;
  const label = level === 'fail' ? 'FAIL' : 'warn';
  return `${label}  ${name}: ${reason}. Fix: ${req.fix}`;
}

/**
 * How a finding is named. A rule whose target is not the thing it is about -
 * `make ci` for the gate-set rules, a list of names for the lane rule - carries
 * a `label` of its own.
 */
function nameOf(req) {
  if (req.label) return req.label;
  return Array.isArray(req.target) ? req.target[0] : req.target;
}

const GUIDE = 'https://github.com/blinkbitcoin/shared-workflows/blob/v0/docs/consumer-guide.md';

export function summaryTable(results) {
  const notable = results.filter((r) => r.level === 'fail' || r.level === 'warn');
  const lines = ['## Consumer contract', ''];
  if (notable.length === 0) {
    lines.push('Every requirement of the workflows this repository calls is satisfied.', '');
    return lines.join('\n');
  }
  lines.push('| | Requirement | Needed by | What to do |', '| --- | --- | --- | --- |');
  for (const { req, level, reason } of notable) {
    const name = req.label ?? (Array.isArray(req.target) ? req.target.join(' / ') : req.target);
    const icon = level === 'fail' ? '**blocked**' : 'degraded';
    lines.push(`| ${icon} | \`${name}\`<br>${reason} | ${req.neededBy} | ${req.fix} [Contract](${GUIDE}#${req.guide}) |`);
  }
  lines.push('', `A **blocked** row fails the job that needs it. A degraded row does not: shared-workflows has a fallback, so the gate runs, but not the one this repository defined.`, '');
  return lines.join('\n');
}

/** The package.json scripts and caller inputs that would clear every failure. */
export function skeleton(results) {
  const failed = results.filter((r) => r.level === 'fail');
  // `script-or-dep` is deliberately not in here. knip is the only member, and
  // its whole point is that a package.json script of that name breaks a
  // different gate - a skeleton that suggested one would contradict the fix
  // printed two lines above it.
  const scripts = failed.filter((r) => r.req.kind === 'package-script');
  const deps = failed.filter((r) => r.req.kind === 'package-dep' || r.req.kind === 'script-or-dep');
  const toggles = failed.filter((r) => r.req.toggle && r.req.defaultOn);
  const lines = [];
  if (scripts.length > 0) {
    lines.push('Either add these to package.json:', '', '  "scripts": {');
    lines.push(scripts.map((r) => `    "${r.req.target}": "echo TODO && exit 1"`).join(',\n'));
    lines.push('  }', '');
  }
  if (deps.length > 0) {
    lines.push(`Add these as devDependencies: ${deps.map((r) => r.req.target).join(', ')}`, '');
  }
  if (toggles.length > 0) {
    const byWorkflow = new Map();
    for (const { req } of toggles) {
      const [workflow, input] = req.toggle.split(':');
      if (!byWorkflow.has(workflow)) byWorkflow.set(workflow, []);
      byWorkflow.get(workflow).push(input);
    }
    lines.push('Or turn the gates off in your caller until you have them:', '');
    for (const [workflow, list] of byWorkflow) {
      lines.push(`  # the job calling ${workflow}`);
      lines.push('    with:');
      for (const input of [...new Set(list)]) lines.push(`      ${input}: false`);
    }
    lines.push('');
  }
  return lines.join('\n');
}

// ---------------------------------------------------------------------------
// CLI
// ---------------------------------------------------------------------------

export function parseArgs(argv, cwd = process.cwd()) {
  const options = { root: cwd, profiles: null, json: false, skeleton: false };
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    if (arg === '--root') options.root = argv[++i];
    else if (arg === '--profile') options.profiles = argv[++i].split(',').map((s) => s.trim()).filter(Boolean);
    else if (arg === '--json') options.json = true;
    else if (arg === '--skeleton') options.skeleton = true;
    else throw new Error(`::error::unknown argument: ${arg}`);
  }
  return options;
}

/**
 * The whole program, returning its exit code. Everything it touches outside
 * itself arrives through the second argument, so the tests run every path of
 * it in-process; the defaults are the real process. `cwd` is the root checked
 * when there is no `--root`.
 */
export function main(
  argv,
  { io = defaultIo, stdout = process.stdout, stderr = process.stderr, env = process.env, cwd = process.cwd() } = {},
) {
  // Every throw below is already a finished ::error:: line - an unreadable
  // package.json, an unknown argument. Printing the message and nothing else is
  // the whole point of this file: a node stack trace here would be the same
  // failure it exists to replace.
  try {
    return run(argv, { io, stdout, stderr, env, cwd });
  } catch (error) {
    stderr.write(`${error.message}\n`);
    return 1;
  }
}

function run(argv, { io, stdout, stderr, env, cwd }) {
  const options = parseArgs(argv, cwd);
  const contract = readContract();
  // A profile name with a typo matches no requirement, so every check would be
  // skipped and the run would end "every requirement is satisfied" - a green
  // answer to a question nobody asked. Refuse it instead.
  const unknown = (options.profiles ?? []).filter((p) => !contract.profiles.includes(p));
  if (unknown.length > 0) {
    throw new Error(`::error::unknown profile(s): ${unknown.join(', ')} (known: ${contract.profiles.join(', ')})`);
  }
  const consumer = readConsumer(path.resolve(options.root), io);
  const results = check(contract, consumer, { profiles: options.profiles });

  if (options.json) {
    stdout.write(`${JSON.stringify(results.map(({ req, level, reason, detail }) => ({ id: req.id, level, reason, detail })), null, 2)}\n`);
  } else {
    for (const result of results) {
      if (result.level === 'skip' && !env.WORKFLOWS_CONTRACT_VERBOSE) continue;
      stdout.write(`${formatResult(result)}\n`);
    }
  }

  const failures = results.filter((r) => r.level === 'fail');
  const warnings = results.filter((r) => r.level === 'warn');

  if (env.GITHUB_STEP_SUMMARY) {
    io.append?.(env.GITHUB_STEP_SUMMARY, `${summaryTable(results)}\n`);
  }

  if (!options.json) {
    if (failures.length > 0 && options.skeleton) stdout.write(`\n${skeleton(results)}`);
    const parts = [];
    if (failures.length > 0) parts.push(`${failures.length} blocked`);
    if (warnings.length > 0) parts.push(`${warnings.length} degraded`);
    stdout.write(parts.length > 0 ? `\n${parts.join(', ')}. See ${GUIDE}\n` : '\nEvery requirement of the workflows this repository calls is satisfied.\n');
  }

  if (failures.length > 0) {
    stderr.write(`::error::consumer contract: ${failures.length} requirement(s) of the workflows this repository calls are not met\n`);
    return 1;
  }
  return 0;
}

/**
 * Whether the module at `moduleUrl` was run as a program, given the script path
 * node was started with (`process.argv[1]`), rather than imported.
 *
 * `realpathSync`, not `path.resolve` alone: node resolves symlinks when it
 * loads a module, so `import.meta.url` is the real path while `process.argv[1]`
 * is whatever the caller typed. Any symlink anywhere in that path made the two
 * differ, and the comparison then quietly said "imported" - the program
 * produced no output and exited 0. A gate that silently passes is worse than
 * one that fails, and this one runs behind a `bash .workflows/...` path that a
 * consumer is free to make a link.
 */
export function isProgram(moduleUrl, scriptPath) {
  if (!scriptPath) return false;
  try {
    return fileURLToPath(moduleUrl) === realpathSync(path.resolve(scriptPath));
  } catch {
    return false;
  }
}

// `exitCode`, not `process.exit()`: the process ends on its own once stdout has
// drained, so a long report piped to a slow reader is never cut short.
if (isProgram(import.meta.url, process.argv[1])) process.exitCode = main(process.argv.slice(2));

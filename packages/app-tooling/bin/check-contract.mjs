#!/usr/bin/env node
// Answer "is this repository wired up for the shared workflows?" in one report,
// before a run spends twenty minutes answering it one red job at a time.
//
//   check-contract [--root DIR] [--profile checks,unit,...] [--native-stack expo|bare]
//                  [--json] [--skeleton]
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
// pnpm, no yq, no installed dependencies, no node_modules. (It does ask git
// which directories it tracks, to tell an Expo app from a bare React Native
// one; git is on every runner image, and a checkout without it reads as
// tracking nothing.)
//
// It is deliberately conservative about what counts as a failure. A gate the
// caller turned off is not a finding. A gate shared-workflows has a fallback for
// is a warning, not a failure - the run will go green, just not measuring what
// the consumer would have measured. Only a requested gate that cannot run at all
// is a failure. A repository is allowed to use part of this family.
import { appendFileSync, existsSync, readdirSync, readFileSync, realpathSync, statSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { expandIncludes } from '../lib/makefile.mjs';
import { isTracked, resolveNativeStack } from '../lib/native-stack.mjs';
import { pinProblems } from '../lib/pin.mjs';

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
export function readConsumer(repository, io = defaultIo, { nativeStack = '' } = {}) {
  // The callers are the repository's own: GitHub reads .github/workflows/ at
  // the root whatever directory the app lives in. Everything else is the app's,
  // read under the working-directory the callers pass.
  const callers = readCallers(repository, io);
  const inputs = callerInputs(callers);
  const workingDirectory = workingDirectoryInput(inputs);
  const root = workingDirectory ? path.join(repository, workingDirectory) : repository;
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
  const deps = { ...(pkg?.dependencies ?? {}), ...(pkg?.devDependencies ?? {}) };
  const input = nativeStack.trim() || stackInput(inputs);
  return {
    // Where the Fastfile, the lanes and the store metadata live: the callers'
    // fastlane-directory, else fastlane.
    fastlaneDirectory: fastlaneInput(inputs),
    // The repository checked out, and the app's directory inside it: the
    // callers' working-directory, '' when they pass none. `root` is where every
    // check below reads.
    repository,
    workingDirectory,
    root,
    io,
    pkg,
    scripts: pkg?.scripts ?? {},
    deps,
    miseTools: readMiseTools(root, io),
    callers,
    uses: callersUse(callers),
    inputs,
    // The rule every consumer of lib/native-stack.mjs applies; git is asked
    // only when no input decides.
    stack: resolveNativeStack({ input, dependencies: deps, iosTracked: input === '' && io.tracked(root, 'ios') }),
  };
}

/**
 * The literal value the callers pass for one input, or '' when none passes a
 * literal one. An expression is decided at run time and cannot be read here,
 * so it is left out. Two different literals are an error naming each value
 * and the workflows that pass it, then `why`.
 */
export function literalInput(inputs, input, why) {
  const values = new Map();
  for (const [key, value] of inputs) {
    const [workflow, name] = key.split(':');
    if (name !== input || value === '' || value.includes('${{')) continue;
    values.set(value, [...(values.get(value) ?? []), workflow]);
  }
  if (values.size > 1) {
    const each = [...values].map(([value, workflows]) => `${value} (${workflows.join(', ')})`).join(', ');
    throw new Error(`::error::the callers pass different ${input} inputs: ${each}. ${why}`);
  }
  return values.size === 1 ? [...values.keys()][0] : '';
}

/**
 * The native-stack input the callers pass, or '' when none passes a literal
 * one, which leaves the stack to the rule. Two different literals are an
 * error: a repository is one stack, and a caller that says otherwise to one
 * workflow would build what the others do not check.
 */
export function stackInput(inputs) {
  return literalInput(inputs, 'native-stack', 'A repository is one stack: pass the same value to every workflow that takes it');
}

/**
 * The directory holding the Fastfile, the lanes and the store metadata: the
 * fastlane-directory the callers pass (relative to the working directory, its
 * trailing slashes dropped), else `fastlane`, the workflows' default. Two
 * different literals are an error: the lanes the build runs and the ones
 * publish-store.yml runs would be two different Fastfiles.
 */
export function fastlaneInput(inputs) {
  const value = literalInput(
    trimSlashes(inputs, 'fastlane-directory'),
    'fastlane-directory',
    'A repository has one Fastfile: pass the same fastlane-directory to every workflow that takes it',
  );
  return value || 'fastlane';
}

/**
 * The directory the app lives in, relative to the repository root: the
 * working-directory the callers pass (its trailing slashes dropped), else ''
 * for the root itself, the workflows' default. Two different literals are an
 * error: the gates one workflow runs and the build another makes would be two
 * different apps.
 */
export function workingDirectoryInput(inputs) {
  return literalInput(
    trimSlashes(inputs, 'working-directory'),
    'working-directory',
    'A repository has one app directory: pass the same working-directory to every workflow that takes it',
  );
}

/** The inputs, with one input's trailing slashes dropped wherever it is passed. */
function trimSlashes(inputs, input) {
  return new Map([...inputs].map(([key, value]) => [key, key.endsWith(`:${input}`) ? value.replace(/\/+$/, '') : value]));
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
  tracked(root, dir) {
    return isTracked(root, dir);
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
 * Which reusable workflows this repository actually calls, e.g. `check.yml`.
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
// The calls themselves
// ---------------------------------------------------------------------------

/** The reusable workflows' interfaces, as `{ workflows: { 'x.yml': { inputs, secrets, outputs } } }`. */
export function readInterfaces(file = path.join(HERE, '..', 'interfaces.json')) {
  return JSON.parse(readFileSync(file, 'utf8'));
}

const SHARED_USES = /^\s*uses:\s*\S*shared-workflows\/\.github\/workflows\/([A-Za-z0-9._-]+\.yml)@/;
const KEY_LINE = /^\s*([A-Za-z0-9._-]+):\s*(.*)$/;
const indentOf = (raw) => raw.length - raw.trimStart().length;
const isBlank = (raw) => raw.trim() === '' || raw.trim().startsWith('#');

/**
 * The keys of the mapping that starts after line `at`, as `Map(name -> raw value)`:
 * the lines at the first indent deeper than `parent`, up to the first line at
 * `parent` or shallower. Deeper lines are a value's own continuation (a block
 * scalar, a nested mapping) and are not keys of this one.
 */
function childKeys(lines, at, parent) {
  const keys = new Map();
  let child = null;
  for (let i = at + 1; i < lines.length; i++) {
    const raw = lines[i];
    if (isBlank(raw)) continue;
    const indent = indentOf(raw);
    if (indent <= parent) break;
    child ??= indent;
    if (indent !== child) continue;
    const pair = KEY_LINE.exec(raw);
    if (pair) keys.set(pair[1], pair[2].trim());
  }
  return keys;
}

/**
 * Every job that calls a shared workflow, from the caller's text:
 * `{ file, job, workflow, with, secrets, reads, unreadable }`. `with` maps each
 * input to its raw YAML value; `secrets` is a Set of names, or null when the
 * job passes `secrets: inherit`; `reads` is the outputs of that job the file
 * reads (`needs.<job>.outputs.<name>`).
 *
 * Hand-rolled, like the rest of this file, and conservative in the same way: a
 * `with:` or `secrets:` written inline as a flow mapping is not parsed, and the
 * call is marked `unreadable` so it is skipped rather than failed for inputs it
 * seems not to pass.
 */
export function callerCalls(callers) {
  const calls = [];
  for (const { name, text } of callers) {
    const lines = text.split('\n');
    const reads = new Map();
    for (const [, job, output] of text.matchAll(/\bneeds\.([\w-]+)\.outputs\.([\w-]+)/g)) {
      if (!reads.has(job)) reads.set(job, new Set());
      reads.get(job).add(output);
    }
    const jobsAt = lines.findIndex((raw) => /^jobs:\s*$/.test(raw));
    if (jobsAt === -1) continue;
    let jobIndent = null;
    let current = null;
    let propIndent = null;
    const finish = () => {
      if (current?.workflow) calls.push({ ...current, reads: reads.get(current.job) ?? new Set() });
    };
    for (let i = jobsAt + 1; i < lines.length; i++) {
      const raw = lines[i];
      if (isBlank(raw)) continue;
      const indent = indentOf(raw);
      if (indent === 0) break;
      jobIndent ??= indent;
      if (indent === jobIndent) {
        finish();
        const job = /^\s*([A-Za-z0-9_-]+):\s*$/.exec(raw);
        current = job ? { file: name, job: job[1], workflow: null, with: new Map(), secrets: new Set(), unreadable: false } : null;
        propIndent = null;
        continue;
      }
      if (!current || indent < jobIndent) continue;
      propIndent ??= indent;
      if (indent !== propIndent) continue;
      const uses = SHARED_USES.exec(raw);
      if (uses) {
        current.workflow = uses[1];
        continue;
      }
      const pair = KEY_LINE.exec(raw);
      if (!pair || (pair[1] !== 'with' && pair[1] !== 'secrets')) continue;
      const value = pair[2].replace(/(^|\s+)#.*$/, '').trim();
      if (pair[1] === 'secrets' && value === 'inherit') current.secrets = null;
      else if (value === '' || value === '{}') {
        const keys = childKeys(lines, i, indent);
        if (pair[1] === 'with') current.with = keys;
        else current.secrets = new Set(keys.keys());
      } else current.unreadable = true;
    }
    finish();
  }
  return calls;
}

/**
 * What a raw YAML scalar is, as far as an input's type is concerned:
 * `boolean`, `number`, `string`, or `unknown` - an expression decided at run
 * time, or an empty value - which no type check applies to.
 */
export function scalarType(raw) {
  const value = /^['"]/.test(raw) ? raw : raw.replace(/(^|\s+)#.*$/, '').trim();
  if (value.includes('${{')) return 'unknown';
  if (value === '' || value === '~' || value === 'null') return 'unknown';
  if (/^['"]/.test(value) || /^[|>][-+0-9]*$/.test(value)) return 'string';
  if (/^(true|True|TRUE|false|False|FALSE)$/.test(value)) return 'boolean';
  if (/^[-+]?(\.[0-9]+|[0-9]+(\.[0-9]*)?)([eE][-+]?[0-9]+)?$/.test(value)) return 'number';
  return 'string';
}

/**
 * Why a call does not fit the interface its workflow declares, one sentence per
 * problem, or none. GitHub checks all of this only when the run starts, on
 * main, after the change merged - and a renamed output is worse: it reads as
 * empty, so a `!= 'false'` gate on it quietly runs every time.
 */
export function callProblems(call, face) {
  if (!face) return [`shared-workflows publishes no reusable ${call.workflow} at this version`];
  const problems = [];
  for (const [name, raw] of call.with) {
    const input = face.inputs[name];
    if (!input) {
      problems.push(`passes input ${name}, which ${call.workflow} does not declare`);
      continue;
    }
    const type = scalarType(raw);
    if (type !== 'unknown' && type !== input.type) {
      problems.push(`passes ${name} as a ${type} (${raw}), but ${call.workflow} declares it a ${input.type}`);
    }
  }
  for (const [name, input] of Object.entries(face.inputs)) {
    if (input.required && !call.with.has(name)) problems.push(`does not pass ${name}, which ${call.workflow} requires`);
  }
  if (call.secrets !== null) {
    for (const name of call.secrets) {
      if (!face.secrets[name]) problems.push(`passes secret ${name}, which ${call.workflow} does not declare`);
    }
    for (const [name, secret] of Object.entries(face.secrets)) {
      if (secret.required && !call.secrets.has(name)) problems.push(`does not pass secret ${name}, which ${call.workflow} requires`);
    }
  }
  for (const name of call.reads) {
    if (!face.outputs.includes(name)) problems.push(`reads output ${name}, which ${call.workflow} does not declare`);
  }
  return problems;
}

const CALL_FIX =
  "pass only the inputs and secrets the called workflow declares, every one it requires, each literal of the declared type, and read only the outputs it declares; the guide lists every workflow's interface";

/** The call rule as a requirement, so a finding reads, sums up and serializes like every other. */
const callRule = (label) => ({
  id: 'calls.interface',
  kind: 'call-interface',
  label,
  neededBy: 'every reusable workflow, at startup',
  fix: CALL_FIX,
  guide: 'inputs-outputs-and-secrets-per-workflow',
  severity: 'required',
});

/** One failure per problem in any call, or one pass naming how many calls fit. */
export function checkCalls(consumer, interfaces) {
  const calls = callerCalls(consumer.callers);
  if (calls.length === 0) return [];
  const results = [];
  let checked = 0;
  for (const call of calls) {
    const label = `${call.file}: ${call.job} -> ${call.workflow}`;
    if (call.unreadable) {
      results.push({ req: callRule(label), level: 'skip', reason: 'its with: or secrets: is an inline mapping this cannot read' });
      continue;
    }
    checked += 1;
    for (const reason of callProblems(call, interfaces.workflows[call.workflow])) {
      results.push({ req: callRule(label), level: 'fail', reason });
    }
  }
  if (!results.some((r) => r.level === 'fail')) {
    results.push({ req: callRule('calls to shared workflows'), level: 'ok', detail: `${checked} within their workflows' interfaces` });
  }
  return results;
}

// ---------------------------------------------------------------------------
// Deciding what applies
// ---------------------------------------------------------------------------

/**
 * Whether a requirement's gate is switched on, given what the caller passes:
 * `true`, `false`, or `'unknown'` for a toggle wired to an expression.
 *
 * `'unknown'` is its own answer rather than a guess in either direction. This
 * job blocks every other job in check.yml, so treating `${{ vars.X }}` as on
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
  if (uses.has('check.yml')) active.add('checks');
  if (uses.has('test-unit.yml')) active.add('unit');
  if (uses.has('test-e2e.yml')) active.add('e2e');
  if (uses.has('build-web.yml')) active.add('web');
  if (uses.has('publish-badges.yml')) active.add('badges');
  if (uses.has('check-code-scanning.yml')) active.add('code-scanning');
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

    case 'file': {
      const targets = req.target.map((file) => fastlanePath(file, consumer));
      const found = targets.find(has);
      return found ? ok(found) : missing(`none of ${targets.join(', ')} exists`);
    }

    case 'dir-nonempty':
      return io.isNonEmptyDir(path.join(root, req.target))
        ? ok()
        : missing(`${req.target}/ is missing or empty`);

    case 'pinned-tool': {
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

    case 'no-copy': {
      // The reverse of every other kind: something this family already ships,
      // which a consumer must therefore not hold. A copy is compared with the
      // original by nothing, so it drifts, and the next fix lands in one place
      // and not the other. The template carried seven of these for months.
      const found = req.target.filter(has);
      return found.length === 0
        ? ok()
        : missing(`${found.join(', ')} ${found.length === 1 ? 'is a copy' : 'are copies'} of what this family ships`);
    }

    case 'one-pin': {
      // One commit of shared-workflows everywhere: every workflow call, and each
      // of this family's packages in package.json and the lockfile. A pin bump
      // that moves one and not the others runs CI on one commit and a laptop on
      // another, and the contract below is then read from neither.
      const problems = pinProblems({
        callers: consumer.callers,
        pkg: consumer.pkg,
        lockfile: io.read(path.join(root, 'pnpm-lock.yaml')),
      });
      return problems.length === 0 ? ok() : missing(problems.join('; '));
    }

    case 'tracked-dir':
      // A bare app builds the ios/ and android/ it commits. One that is only
      // on a laptop is a build that works there and nowhere else.
      return io.tracked(root, req.target) ? ok() : missing(`git tracks nothing under ${req.target}/`);

    case 'lane': {
      // A textual scan of <fastlane-directory>/**.rb, not a Ruby parse: enough to catch a
      // lane that was never written, and honest about being no more than that.
      const text = collectRuby(path.join(root, consumer.fastlaneDirectory), consumer.io);
      if (text === null) return skip(`no ${consumer.fastlaneDirectory}/`);
      // Named once each: the scan is not per platform, so a lane two platforms
      // need is either there for both or absent for both.
      const names = [...new Set(req.target.map((lane) => lane.split(':')[1]))];
      const absent = names.filter((lane) => !text.includes(`lane :${lane}`));
      return absent.length === 0
        ? ok()
        : missing(`${consumer.fastlaneDirectory}/ defines no lane named ${absent.join(', ')}`);
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

    case 'lane-environment': {
      // A lane reading an environment variable the lane workflow never passes
      // gets an empty string, and fastlane uploads the empty value.
      const text = collectRuby(path.join(root, consumer.fastlaneDirectory), io);
      if (text === null) return skip(`no ${consumer.fastlaneDirectory}/`);
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
 * gates themselves. `null` when there is no Makefile. Its `include` and
 * `-include` lines are followed to the files that exist, so a gate defined in a
 * shared `.mk` fragment is part of what `make ci` reaches.
 */
export function readMakefile(root, io = defaultIo) {
  const text = expandIncludes(path.join(root, 'Makefile'), (file) => io.read(file), root);
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
 * script requirement of the check and test-unit workflows whose workflow is called
 * and whose toggle is on. `on` holds the toggles known to be on; `maybe` adds
 * the ones wired to an expression, so neither direction of the gate-set check
 * fails on a value it cannot read.
 */
export function ciScripts(contract, uses, inputs, profiles, stack = null) {
  const active = activeProfiles(uses, profiles);
  const on = new Set();
  const maybe = new Set();
  for (const req of contract.requirements) {
    if (req.kind !== 'package-script') continue;
    if (!['checks', 'unit'].includes(req.profile) || !active.has(req.profile)) continue;
    if (req.stack && stack && req.stack !== stack) continue;
    const state = toggleOn(req, inputs);
    if (state === true) on.add(req.target);
    if (state !== false) maybe.add(req.target);
  }
  return { on, maybe };
}

/**
 * A contract path under `fastlane/`, moved under the callers'
 * fastlane-directory; any other path as it is.
 */
function fastlanePath(file, consumer) {
  return file.startsWith('fastlane/') ? `${consumer.fastlaneDirectory}${file.slice('fastlane'.length)}` : file;
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
  const { stack, reason } = consumer.stack;
  consumer.ciScripts = ciScripts(contract, consumer.uses, consumer.inputs, profiles, stack);
  return contract.requirements.map((req) => {
    if (!active.has(req.profile)) {
      return { req, level: 'skip', reason: `${req.profile} workflows are not called from this repository` };
    }
    if (req.stack && req.stack !== stack) {
      return { req, level: 'skip', reason: `only the ${req.stack} stack needs it, and this repository is ${stack} (${reason})` };
    }
    if (req.workflow && !consumer.uses.has(req.workflow)) {
      return { req, level: 'skip', reason: `${req.workflow} is not called from this repository` };
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

/** The stack line every report starts with, so a skipped row's reason is never a surprise. */
export const stackLine = ({ stack, reason }) => `native stack: ${stack} (${reason})`;

export function summaryTable(results, stack = null) {
  const notable = results.filter((r) => r.level === 'fail' || r.level === 'warn');
  const lines = ['## Consumer contract', ''];
  if (stack) lines.push(`Native stack: **${stack.stack}** (${stack.reason}).`, '');
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

/**
 * The package.json scripts and caller inputs that would clear every failure,
 * after the stack they were judged against: a wrong stack is the one mistake
 * that makes every other line of it wrong.
 */
export function skeleton(results, stack = null) {
  const failed = results.filter((r) => r.level === 'fail');
  const scripts = failed.filter((r) => r.req.kind === 'package-script');
  const deps = failed.filter((r) => r.req.kind === 'package-dep');
  const toggles = failed.filter((r) => r.req.toggle && r.req.defaultOn);
  const lines = [];
  if (stack) {
    const other = stack.stack === 'expo' ? 'bare' : 'expo';
    lines.push(`Judged as the ${stack.stack} stack (${stack.reason}). If this repository is ${other}, pass native-stack: ${other} to the workflows that take it.`, '');
  }
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
  const options = { root: cwd, profiles: null, json: false, skeleton: false, nativeStack: '' };
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    if (arg === '--root') options.root = argv[++i];
    else if (arg === '--profile') options.profiles = argv[++i].split(',').map((s) => s.trim()).filter(Boolean);
    else if (arg === '--json') options.json = true;
    else if (arg === '--skeleton') options.skeleton = true;
    else if (arg === '--native-stack') options.nativeStack = argv[++i] ?? '';
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
  const consumer = readConsumer(path.resolve(options.root), io, { nativeStack: options.nativeStack });
  const results = [...check(contract, consumer, { profiles: options.profiles }), ...checkCalls(consumer, readInterfaces())];

  if (!options.json) stdout.write(`${stackLine(consumer.stack)}\n`);
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
    io.append?.(env.GITHUB_STEP_SUMMARY, `${summaryTable(results, consumer.stack)}\n`);
  }

  if (!options.json) {
    if (failures.length > 0 && options.skeleton) stdout.write(`\n${skeleton(results, consumer.stack)}`);
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

#!/usr/bin/env node
// The security scanning settings, resolved in one order everywhere: an
// environment variable wins over security-settings.json, which wins over the
// built-in default. Bash runners read one key at a time
//
//     node lib/security-settings.mjs get jobs.dependencies
//
// and CI reads the lot with `--json`. A value that is not a boolean throws
// rather than reading as off: a typo must not quietly disable a scanner.
import { readFileSync } from 'node:fs';
import { isProgram } from './is-program.mjs';
import { EFFORTS } from './llm.mjs';

// The efforts the LLM adapters accept. Imported from the package's own module,
// never from an installed dependency: check-security.yml's Settings job runs
// this file from the workflows checkout before any install.
export { EFFORTS };

export const SEVERITIES = ['none', 'low', 'medium', 'high', 'critical'];
export const PROVIDERS = ['', 'openai', 'anthropic'];

/**
 * Built-in defaults. Every deterministic scanner is on; the two LLM engines
 * send source to a third party and cost money per run, so they stay off until
 * a repository opts in and configures a provider and a key.
 */
export const DEFAULTS = {
  enabled: true,
  severity: 'high',
  failOn: ['deterministic'],
  jobs: {
    dependencies: true,
    code: true,
    policy: true,
    sbom: true,
    bundle: true,
    mobile: true,
    binaries: true,
    review: false,
    'review-codebase': false,
  },
};

// The tunables beside each job's `enabled`, with their type and default. One
// schema, so every option resolves the same way the switches do: the
// environment twin SECURITY_<JOB>_<KEY> beats security-settings.json, which beats
// the default here, and a value of the wrong type fails the run.
export const OPTIONS = {
  code: {
    rules: { type: 'list', default: [] },
  },
  bundle: {
    platforms: { type: 'list', of: ['ios', 'android'], default: ['ios', 'android'] },
    hosts: { type: 'list', default: [] },
    cleartextHosts: { type: 'list', default: ['localhost', '127.0.0.1'] },
  },
  binaries: {
    androidPermissions: { type: 'list', default: [] },
    exportedComponents: { type: 'list', default: [] },
    atsExceptionDomains: { type: 'list', default: [] },
  },
  review: {
    maxDiffBytes: { type: 'int', default: 200000 },
  },
  'review-codebase': {
    limit: { type: 'int', default: 0 },
    verify: { type: 'bool', default: false },
  },
};

/** The provider, model and effort both LLM jobs use, and their environment twins. */
export const LLM = {
  provider: { type: 'enum', of: PROVIDERS, default: '' },
  model: { type: 'string', default: '' },
  effort: { type: 'enum', of: EFFORTS, default: 'max' },
};

/** `androidPermissions` -> `ANDROID_PERMISSIONS`, `review-codebase` -> `REVIEW_CODEBASE`. */
export const snake = (key) =>
  key
    .replace(/([a-z0-9])([A-Z])/g, '$1_$2')
    .replace(/-/g, '_')
    .toUpperCase();

export const parseBoolean = (value, source) => {
  if (value === true || value === 'true') return true;
  if (value === false || value === 'false') return false;
  throw new Error(`${source}: expected true or false, got ${JSON.stringify(value)}`);
};

const parseSeverity = (value, source) => {
  if (!SEVERITIES.includes(value)) {
    throw new Error(
      `${source}: expected one of ${SEVERITIES.join(', ')}, got ${JSON.stringify(value)}`,
    );
  }
  return value;
};

const parseList = (value) =>
  Array.isArray(value)
    ? value
    : value
        .split(',')
        .map((part) => part.trim())
        .filter(Boolean);

const describe = (value) => JSON.stringify(value);

/** One value of a schema entry, from the environment's string or the file's JSON. */
export const parseTyped = (spec, value, source) => {
  if (spec.type === 'bool') return parseBoolean(value, source);
  if (spec.type === 'int') {
    const number = typeof value === 'number' ? value : Number(value);
    if (!Number.isInteger(number) || number < 0 || value === '') {
      throw new Error(`${source}: expected a whole number of zero or more, got ${describe(value)}`);
    }
    return number;
  }
  if (spec.type === 'list') {
    if (!Array.isArray(value) && typeof value !== 'string') {
      throw new Error(`${source}: expected a list, got ${describe(value)}`);
    }
    const list = parseList(value);
    for (const entry of list) {
      if (typeof entry !== 'string') {
        throw new Error(`${source}: expected a list of strings, got ${describe(entry)}`);
      }
      if (spec.of && !spec.of.includes(entry)) {
        throw new Error(
          `${source}: expected entries from ${spec.of.join(', ')}, got ${describe(entry)}`,
        );
      }
    }
    return list;
  }
  if (typeof value !== 'string') {
    throw new Error(`${source}: expected a string, got ${describe(value)}`);
  }
  if (spec.type === 'enum' && !spec.of.includes(value)) {
    throw new Error(
      `${source}: expected one of ${spec.of.map((v) => v || '(empty)').join(', ')}, got ${describe(value)}`,
    );
  }
  return value;
};

// An option's key under a job that the schema does not know is a typo, and a
// typo in an allowlist ("androidPermission") would otherwise leave the real
// key at its default with no sign anything was wrong.
const assertKnownKeys = (block, known, where) => {
  for (const key of Object.keys(block ?? {})) {
    if (key.startsWith('$') || known.includes(key)) continue;
    throw new Error(`security-settings.json: unknown setting ${where}.${key}`);
  }
};

// An empty environment twin is an unset one. CI hands every twin over through
// environment-variables as `"KEY":"${{ vars.KEY }}"`, and an unset repository variable
// arrives there as "" - reading that as a value would fail every run of a
// repository that simply has not set it. A non-empty value that does not parse
// still fails the run; to empty a list, set it to [] in the file.
const resolveBlock = (schema, fileBlock, envPrefix, where, env) =>
  Object.fromEntries(
    Object.entries(schema).map(([key, spec]) => {
      const envKey = `${envPrefix}_${snake(key)}`;
      if (env[envKey] !== undefined && env[envKey] !== '') {
        return [key, parseTyped(spec, env[envKey], envKey)];
      }
      if (fileBlock?.[key] !== undefined) {
        return [key, parseTyped(spec, fileBlock[key], `security-settings.json: ${where}.${key}`)];
      }
      return [key, spec.default];
    }),
  );

/** Settings from a parsed policy object and an environment. */
export const resolve = (policy = {}, env = process.env) => {
  const bool = (key, envKey, fileValue, fallback) => {
    if (env[envKey] !== undefined) return parseBoolean(env[envKey], envKey);
    if (fileValue !== undefined) return parseBoolean(fileValue, `security-settings.json: ${key}`);
    return fallback;
  };
  const jobs = Object.fromEntries(
    Object.entries(DEFAULTS.jobs).map(([name, fallback]) => [
      name,
      bool(`jobs.${name}`, `SECURITY_${snake(name)}`, policy.jobs?.[name]?.enabled, fallback),
    ]),
  );
  const severity =
    env.SECURITY_SEVERITY !== undefined
      ? parseSeverity(env.SECURITY_SEVERITY, 'SECURITY_SEVERITY')
      : parseSeverity(policy.severity ?? DEFAULTS.severity, 'severity');
  const failOn = parseList(env.SECURITY_FAIL_ON ?? policy.failOn ?? DEFAULTS.failOn);
  for (const name of Object.keys(policy.jobs ?? {})) {
    if (!(name in DEFAULTS.jobs))
      throw new Error(`security-settings.json: unknown job jobs.${name}`);
    assertKnownKeys(
      policy.jobs[name],
      ['enabled', ...Object.keys(OPTIONS[name] ?? {})],
      `jobs.${name}`,
    );
  }
  assertKnownKeys(policy.llm, Object.keys(LLM), 'llm');
  const options = Object.fromEntries(
    Object.entries(OPTIONS).map(([name, schema]) => [
      name,
      resolveBlock(schema, policy.jobs?.[name], `SECURITY_${snake(name)}`, `jobs.${name}`, env),
    ]),
  );
  return {
    enabled: bool('enabled', 'SECURITY_ENABLED', policy.enabled, DEFAULTS.enabled),
    jobs,
    severity,
    failOn,
    options,
    llm: resolveBlock(LLM, policy.llm, 'SECURITY_LLM', 'llm', env),
  };
};

// SECURITY_SETTINGS_FILE overrides the path, the same override policy.sh
// already uses for its own target file. Tests point it at a temp fixture so
// nothing ever has to write to the tracked security-settings.json on disk -
// two node:test files reading and writing that one real file concurrently
// is a race, not a test.
/** Settings from the policy file on disk; a missing file is the defaults. */
export const load = (file = 'security-settings.json', env = process.env) => {
  const path = env.SECURITY_SETTINGS_FILE ?? file;
  let policy = {};
  try {
    policy = JSON.parse(readFileSync(path, 'utf8'));
  } catch (error) {
    if (error.code !== 'ENOENT') throw error;
  }
  return resolve(policy, env);
};

const at = (settings, dotted) =>
  dotted
    .split('.')
    .reduce((value, key) => (value === undefined ? undefined : value[key]), settings);

/** Command-line entry; returns the exit code. */
export function main(
  argv = process.argv.slice(2),
  { log = console.log, error = console.error, env = process.env } = {},
) {
  const settings = load('security-settings.json', env);
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
  error('usage: security-settings.mjs get <dotted.key> | --json');
  return 2;
}

if (isProgram(import.meta.url, process.argv[1])) process.exitCode = main();

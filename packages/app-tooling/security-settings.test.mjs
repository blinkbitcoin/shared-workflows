import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { existsSync, readFileSync } from 'node:fs';
import path from 'node:path';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';
import {
  DEFAULTS,
  EFFORTS,
  LLM,
  load,
  main,
  OPTIONS,
  parseBoolean,
  parseTyped,
  resolve,
  snake,
} from './lib/security-settings.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));

// Every SECURITY_* variable settings.mjs reads, so tests that rely on the
// default `env = process.env` parameter aren't hostage to whatever a
// developer or runner happens to have exported.
const SECURITY_ENV_KEYS = [
  'SECURITY_ENABLED',
  'SECURITY_SEVERITY',
  'SECURITY_FAIL_ON',
  ...Object.keys(DEFAULTS.jobs).map((name) => `SECURITY_${name.toUpperCase()}`),
  ...Object.entries(OPTIONS).flatMap(([job, schema]) =>
    Object.keys(schema).map((key) => `SECURITY_${snake(job)}_${snake(key)}`),
  ),
  ...Object.keys(LLM).map((key) => `SECURITY_LLM_${snake(key)}`),
];

/** Runs `fn` with every SECURITY_* variable removed from process.env, then restores them. */
const withoutSecurityEnv = (fn) => {
  const saved = {};
  for (const key of SECURITY_ENV_KEYS) {
    if (key in process.env) {
      saved[key] = process.env[key];
      delete process.env[key];
    }
  }
  try {
    fn();
  } finally {
    for (const [key, value] of Object.entries(saved)) process.env[key] = value;
  }
};

test('defaults apply when the file and the environment are silent', () => {
  const settings = resolve({}, {});
  assert.equal(settings.enabled, true);
  assert.equal(settings.severity, 'high');
  assert.deepEqual(settings.failOn, ['deterministic']);
  assert.equal(settings.jobs.dependencies, true);
  assert.equal(settings.jobs.review, false);
});

test('the file overrides a default', () => {
  const settings = resolve({ jobs: { dependencies: { enabled: false } }, severity: 'low' }, {});
  assert.equal(settings.jobs.dependencies, false);
  assert.equal(settings.severity, 'low');
});

test('the environment overrides the file', () => {
  const settings = resolve(
    { jobs: { dependencies: { enabled: false } } },
    { SECURITY_DEPENDENCIES: 'true' },
  );
  assert.equal(settings.jobs.dependencies, true);
});

test('SECURITY_ENABLED is the master switch and follows the same order', () => {
  assert.equal(resolve({ enabled: false }, {}).enabled, false);
  assert.equal(resolve({ enabled: false }, { SECURITY_ENABLED: 'true' }).enabled, true);
});

test('a value that is not a boolean fails the run rather than reading as off', () => {
  assert.throws(
    () => parseBoolean('yes', 'SECURITY_DEPENDENCIES'),
    /SECURITY_DEPENDENCIES: expected true or false, got "yes"/,
  );
  assert.throws(() => resolve({}, { SECURITY_CODE: '1' }), /SECURITY_CODE/);
  assert.throws(
    () => resolve({ jobs: { code: { enabled: 'on' } } }, {}),
    /security-settings.json: jobs.code/,
  );
});

test('an unknown severity names itself in the error', () => {
  assert.throws(
    () => resolve({}, { SECURITY_SEVERITY: 'huge' }),
    /SECURITY_SEVERITY: expected one of none, low, medium, high, critical/,
  );
  assert.throws(() => resolve({ severity: 'huge' }, {}), /^Error: severity: expected one of/);
});

test('failOn is a comma list from the environment and an array from the file', () => {
  assert.deepEqual(resolve({}, { SECURITY_FAIL_ON: 'deterministic,review' }).failOn, [
    'deterministic',
    'review',
  ]);
  assert.deepEqual(resolve({ severity: 'high', failOn: ['review'] }, {}).failOn, ['review']);
  assert.deepEqual(resolve({}, { SECURITY_FAIL_ON: '' }).failOn, []);
});

test('every job in DEFAULTS has an environment twin', () => {
  for (const name of Object.keys(DEFAULTS.jobs)) {
    const env = { [`SECURITY_${name.toUpperCase()}`]: 'false' };
    assert.equal(resolve({}, env).jobs[name], false, name);
  }
});

const capture = () => {
  const out = [];
  return { out, log: (line) => out.push(String(line)), error: (line) => out.push(String(line)) };
};

test('get prints one setting, a list comma-joined', () => {
  const io = capture();
  assert.equal(main(['get', 'jobs.dependencies'], { ...io, env: {} }), 0);
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
  assert.deepEqual(io.out, [
    'no such setting: jobs.nope',
    'usage: security-settings.mjs get <dotted.key> | --json',
  ]);
});

test('load returns defaults when the file is missing', () => {
  const settings = load('/nonexistent/path.json', {});
  assert.equal(settings.enabled, true);
  assert.equal(settings.severity, 'high');
});

test('load rethrows non-ENOENT errors like when the path is a directory', () => {
  assert.throws(() => load('.', {}));
});

test('environment boolean string false is parsed correctly', () => {
  const settings = resolve({}, { SECURITY_ENABLED: 'false' });
  assert.equal(settings.enabled, false);
});

test('load reads and parses the policy file', () => {
  const settings = load('security-settings.json', {});
  assert.equal(settings.enabled, true);
  assert.equal(settings.severity, 'high');
});

test('parseBoolean accepts boolean true and false', () => {
  assert.equal(parseBoolean(true, 'test'), true);
  assert.equal(parseBoolean(false, 'test'), false);
});

test('parseBoolean accepts string true and false', () => {
  assert.equal(parseBoolean('true', 'test'), true);
  assert.equal(parseBoolean('false', 'test'), false);
});

test('resolve with string false in environment', () => {
  assert.equal(resolve({}, { SECURITY_DEPENDENCIES: 'false' }).jobs.dependencies, false);
});

test('get handles deeply nested nonexistent paths', () => {
  const io = capture();
  assert.equal(main(['get', 'jobs.nope.foo'], { ...io, env: {} }), 2);
  assert.equal(io.out[0], 'no such setting: jobs.nope.foo');
});

test('get without a key argument exits 2', () => {
  const io = capture();
  assert.equal(main(['get'], { ...io, env: {} }), 2);
  assert.equal(io.out[0], 'usage: security-settings.mjs get <dotted.key> | --json');
});

test('Array.isArray branch in value output', () => {
  const io = capture();
  // This tests the non-array case where value is a boolean
  assert.equal(main(['get', 'enabled'], { ...io, env: {} }), 0);
  // 'true' is the string representation of the boolean
  assert.equal(io.out[0], 'true');
});

test('parseList with single item string', () => {
  const settings = resolve({}, { SECURITY_FAIL_ON: 'review' });
  assert.deepEqual(settings.failOn, ['review']);
});

test('parseList with spaces in comma-separated values', () => {
  const settings = resolve({}, { SECURITY_FAIL_ON: 'deterministic , review , critical' });
  assert.deepEqual(settings.failOn, ['deterministic', 'review', 'critical']);
});

test('policy jobs object without a specific job falls back to default', () => {
  const settings = resolve({ jobs: {} }, {});
  assert.equal(settings.jobs.dependencies, true); // DEFAULTS.jobs.dependencies
  assert.equal(settings.jobs.review, false); // DEFAULTS.jobs.review
});

test('resolve with default env parameter', () => {
  withoutSecurityEnv(() => {
    const settings = resolve({});
    assert.equal(settings.enabled, true);
    assert.equal(settings.severity, 'high');
  });
});

test('load with default env parameter', () => {
  withoutSecurityEnv(() => {
    const settings = load('security-settings.json');
    assert.equal(settings.enabled, true);
  });
});

test('job in policy without enabled property falls back to default', () => {
  const settings = resolve({ jobs: { dependencies: {} } }, {});
  assert.equal(settings.jobs.dependencies, true); // Falls back to DEFAULTS.jobs.dependencies
});

test('file policy with string false value in job is parsed correctly', () => {
  const settings = resolve({ jobs: { code: { enabled: 'false' } } }, {});
  assert.equal(settings.jobs.code, false);
});

test('file policy with string true value in job', () => {
  const settings = resolve({ jobs: { policy: { enabled: 'true' } } }, {});
  assert.equal(settings.jobs.policy, true);
});

test('main with policy file and environment variable override', () => {
  const io = capture();
  // When we call main with SECURITY_ENABLED=true in env, it should enable the system
  assert.equal(main(['--json'], { ...io, env: { SECURITY_ENABLED: 'true' } }), 0);
  const parsed = JSON.parse(io.out[0]);
  assert.equal(parsed.enabled, true);
});

test('severity none is valid', () => {
  const settings = resolve({}, { SECURITY_SEVERITY: 'none' });
  assert.equal(settings.severity, 'none');
});

test('enabled with boolean value true from policy', () => {
  const settings = resolve({ enabled: true }, {});
  assert.equal(settings.enabled, true);
});

test('as a command it reads security-settings.json from the working directory', () => {
  const script = path.join(here, 'lib', 'security-settings.mjs');
  // The inherited environment keeps NODE_V8_COVERAGE, so the child counts,
  // and it also runs the file as the entry point rather than an import, so
  // `import.meta.main` is true here the way it never is under `node --test`.
  // SECURITY_* keys are stripped so a developer's or runner's real
  // environment can't change what the child reports for jobs.dependencies.
  const childEnv = { ...process.env };
  for (const key of SECURITY_ENV_KEYS) delete childEnv[key];
  const run = (...args) =>
    spawnSync(process.execPath, [script, ...args], { encoding: 'utf8', env: childEnv });
  const got = run('get', 'jobs.dependencies');
  assert.equal(got.status, 0);
  assert.equal(got.stdout.trim(), 'true');
});

// The defect this guards against: security-settings.json shipped sbom, bundle
// and binaries as enabled while DEFAULTS (and the fallback every consumer
// gets with no policy file at all) agreed - both wrong, in the same
// direction, so a reviewer comparing the two files saw no disagreement. Only
// comparing against the actual runners on disk (the next test) would have
// caught it; this test catches the narrower case of the two settings
// sources silently drifting apart from each other.
test('security-settings.json and DEFAULTS agree, key for key', () => {
  const policy = JSON.parse(readFileSync(path.join(here, 'security-settings.json'), 'utf8'));
  const policyNames = Object.keys(policy.jobs).sort();
  const defaultNames = Object.keys(DEFAULTS.jobs).sort();
  assert.deepEqual(
    policyNames,
    defaultNames,
    'security-settings.json and DEFAULTS.jobs must name exactly the same jobs',
  );
  for (const name of defaultNames) {
    assert.equal(
      policy.jobs[name].enabled,
      DEFAULTS.jobs[name],
      `jobs.${name}.enabled in security-settings.json disagrees with DEFAULTS.jobs.${name}`,
    );
  }
});

// The invariant that matters: a job on by default must have code that runs
// it. This is what would have caught sbom/bundle/binaries shipping enabled
// with no scripts/security/sbom.sh, bundle.sh or binaries.sh - and, unlike
// pinning today's true/false values, it keeps working as later stages add a
// runner and flip its job on.
test('every job enabled by default has a runner on disk', () => {
  for (const [name, enabled] of Object.entries(DEFAULTS.jobs)) {
    if (!enabled) continue;
    assert.ok(
      existsSync(path.join(here, 'security', `${name}.sh`)),
      `DEFAULTS.jobs.${name} is true but security/${name}.sh does not exist`,
    );
  }
});

// ---------- options and the llm block ----------

test('every option and the llm block resolve to their defaults', () => {
  const settings = resolve({}, {});
  assert.deepEqual(settings.options.bundle, {
    platforms: ['ios', 'android'],
    hosts: [],
    cleartextHosts: ['localhost', '127.0.0.1'],
  });
  assert.equal(settings.options.review.maxDiffBytes, 200000);
  assert.deepEqual(settings.options['review-codebase'], { limit: 0, verify: false });
  assert.deepEqual(settings.llm, { provider: '', model: '', effort: 'max' });
});

test('the deterministic jobs are on by default and the two LLM jobs are off', () => {
  const { jobs } = resolve({}, {});
  for (const name of ['sbom', 'bundle', 'mobile', 'binaries']) assert.equal(jobs[name], true);
  assert.equal(jobs.review, false);
  assert.equal(jobs['review-codebase'], false);
});

test('snake turns a camelCase key into its environment spelling', () => {
  assert.equal(snake('androidPermissions'), 'ANDROID_PERMISSIONS');
  assert.equal(snake('maxDiffBytes'), 'MAX_DIFF_BYTES');
  assert.equal(snake('limit'), 'LIMIT');
  assert.equal(snake('review-codebase'), 'REVIEW_CODEBASE');
});

test('an option comes from the file, and its environment twin wins over the file', () => {
  const policy = { jobs: { binaries: { androidPermissions: ['android.permission.CAMERA'] } } };
  assert.deepEqual(resolve(policy, {}).options.binaries.androidPermissions, [
    'android.permission.CAMERA',
  ]);
  const env = { SECURITY_BINARIES_ANDROID_PERMISSIONS: 'a, b' };
  assert.deepEqual(resolve(policy, env).options.binaries.androidPermissions, ['a', 'b']);
});

test('the llm block follows the same order', () => {
  const policy = { llm: { provider: 'anthropic', model: 'claude-opus-5', effort: 'high' } };
  assert.deepEqual(resolve(policy, {}).llm, policy.llm);
  const settings = resolve(policy, { SECURITY_LLM_PROVIDER: 'openai', SECURITY_LLM_EFFORT: 'low' });
  assert.equal(settings.llm.provider, 'openai');
  assert.equal(settings.llm.effort, 'low');
  assert.equal(settings.llm.model, 'claude-opus-5');
  assert.equal(resolve({ llm: { effort: 'none' } }, {}).llm.effort, 'none');
  assert.equal(resolve({}, { SECURITY_LLM_EFFORT: 'none' }).llm.effort, 'none');
});

test('parseTyped reads every type from a string and from JSON', () => {
  assert.equal(parseTyped({ type: 'int' }, '42', 'x'), 42);
  assert.equal(parseTyped({ type: 'int' }, 7, 'x'), 7);
  assert.equal(parseTyped({ type: 'bool' }, 'true', 'x'), true);
  assert.deepEqual(parseTyped({ type: 'list' }, '', 'x'), []);
  assert.deepEqual(parseTyped({ type: 'list', of: ['ios'] }, ['ios'], 'x'), ['ios']);
  assert.equal(parseTyped({ type: 'string' }, 'any', 'x'), 'any');
  assert.equal(parseTyped({ type: 'enum', of: ['', 'a'] }, '', 'x'), '');
});

test('an option of the wrong type fails the run, naming where it came from', () => {
  const cases = [
    [{ type: 'int' }, 'lots', /x: expected a whole number/],
    [{ type: 'int' }, '-1', /whole number/],
    [{ type: 'int' }, '1.5', /whole number/],
    [{ type: 'int' }, '', /whole number/],
    [{ type: 'list' }, 3, /x: expected a list, got 3/],
    [{ type: 'list' }, [1], /expected a list of strings, got 1/],
    [{ type: 'list', of: ['ios', 'android'] }, 'ios,web', /entries from ios, android, got "web"/],
    [{ type: 'string' }, 5, /expected a string, got 5/],
    [{ type: 'enum', of: ['', 'openai'] }, 'gemini', /one of \(empty\), openai, got "gemini"/],
  ];
  for (const [spec, value, message] of cases) {
    assert.throws(() => parseTyped(spec, value, 'x'), message);
  }
});

test('an invalid option reaches the error with its source', () => {
  assert.throws(
    () => resolve({ jobs: { review: { maxDiffBytes: 'big' } } }, {}),
    /security-settings.json: jobs.review.maxDiffBytes: expected a whole number/,
  );
  assert.throws(
    () => resolve({}, { SECURITY_REVIEW_CODEBASE_LIMIT: 'all' }),
    /SECURITY_REVIEW_CODEBASE_LIMIT: expected a whole number/,
  );
  assert.throws(() => resolve({}, { SECURITY_LLM_EFFORT: 'extreme' }), /SECURITY_LLM_EFFORT/);
});

test('a key the schema does not know is a typo, and fails the run', () => {
  assert.throws(
    () => resolve({ jobs: { binaries: { androidPermission: [] } } }, {}),
    /unknown setting jobs.binaries.androidPermission/,
  );
  assert.throws(
    () => resolve({ jobs: { dependencies: { hosts: [] } } }, {}),
    /unknown setting jobs.dependencies.hosts/,
  );
  assert.throws(() => resolve({ jobs: { lint: { enabled: true } } }, {}), /unknown job jobs.lint/);
  assert.throws(() => resolve({ llm: { temperature: 1 } }, {}), /unknown setting llm.temperature/);
});

test('a key starting with $ is a comment, not a setting', () => {
  const settings = resolve(
    { llm: { $comment: 'x' }, jobs: { bundle: { $hosts: 'why', enabled: true } } },
    {},
  );
  assert.equal(settings.jobs.bundle, true);
});

test('get prints an option list comma-joined and an empty setting as an empty line', () => {
  const lines = [];
  assert.equal(
    main(['get', 'options.bundle.platforms'], { log: (l) => lines.push(l), env: {} }),
    0,
  );
  assert.equal(main(['get', 'llm.provider'], { log: (l) => lines.push(l), env: {} }), 0);
  assert.deepEqual(lines, ['ios,android', '']);
});

test('the reference settings file is exactly the defaults', () => {
  withoutSecurityEnv(() => {
    const settings = load(path.join(here, 'security-settings.json'), {});
    assert.deepEqual(settings, resolve({}, {}));
  });
});

test('an empty option or llm twin is unset, as environment-variables delivers an unset repository variable', () => {
  const env = {
    SECURITY_LLM_PROVIDER: '',
    SECURITY_LLM_MODEL: '',
    SECURITY_LLM_EFFORT: '',
    SECURITY_BUNDLE_PLATFORMS: '',
    SECURITY_REVIEW_MAX_DIFF_BYTES: '',
    SECURITY_REVIEW_CODEBASE_VERIFY: '',
  };
  const fromFile = resolve({ llm: { effort: 'high', provider: 'openai' } }, env);
  assert.equal(fromFile.llm.effort, 'high');
  assert.equal(fromFile.llm.provider, 'openai');
  const defaults = resolve({}, env);
  assert.deepEqual(defaults.llm, { provider: '', model: '', effort: 'max' });
  assert.deepEqual(defaults.options.bundle.platforms, ['ios', 'android']);
  assert.equal(defaults.options.review.maxDiffBytes, 200000);
  assert.equal(defaults.options['review-codebase'].verify, false);
  // A value that is there and wrong still fails the run.
  assert.throws(() => resolve({}, { SECURITY_LLM_EFFORT: ' ' }), /SECURITY_LLM_EFFORT/);
});

test('the job switches and failOn keep their meaning for an empty value', () => {
  // An empty failOn is a deliberate "nothing blocks"; an empty switch is not a boolean.
  assert.deepEqual(resolve({}, { SECURITY_FAIL_ON: '' }).failOn, []);
  assert.throws(() => resolve({}, { SECURITY_CODE: '' }), /SECURITY_CODE: expected true or false/);
});

test('the efforts are the ones the shared LLM adapters accept', () => {
  assert.deepEqual(EFFORTS, ['none', 'low', 'medium', 'high', 'max']);
});

test('a dashed job name reads its environment twin with an underscore', () => {
  const settings = resolve(
    {},
    { SECURITY_REVIEW_CODEBASE: 'true', SECURITY_REVIEW_CODEBASE_LIMIT: '3' },
  );
  assert.equal(settings.jobs['review-codebase'], true);
  assert.equal(settings.options['review-codebase'].limit, 3);
});

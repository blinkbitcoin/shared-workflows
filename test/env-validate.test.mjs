// scripts/lib/env-validate.mjs: the one validator for the caller-supplied JSON
// objects whose keys become environment variables (build-env through
// scripts/lib/build-env.sh, env-json through scripts/release/env-json.sh).
//
// Covered here, through the exported function: the pairs it returns and how it
// stringifies values; JSON that does not parse; a document that is not a flat
// object; a key that is not an environment variable name, with and without
// lower-case keys allowed; every credential suffix and every name on the NEVER
// list, in either case; every reserved prefix and name, in either case; and a
// value that is not a scalar. Through the command-line entry, run as a child
// process: the NUL-separated output, the exit status and message on a refusal,
// the default label, the lower-case switch, and that importing the module runs
// nothing.
//
// The child processes get this process's environment spread into theirs, which
// carries NODE_V8_COVERAGE, so the command-line entry counts toward the 100%
// gate that `make test-node-scripts` holds over scripts/**/*.mjs.

import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';
import {
  NEVER,
  RESERVED,
  SECRETISH,
  VALID_NAME,
  VALID_NAME_ANY_CASE,
  validateEnvJson,
} from '../scripts/lib/env-validate.mjs';

const SCRIPT = fileURLToPath(new URL('../scripts/lib/env-validate.mjs', import.meta.url));

// This process's environment without the variables the entry reads, so a value
// set in the calling shell cannot decide a case.
function cleanEnvironment() {
  const env = { ...process.env };
  delete env.WORKFLOWS_ENV_VALIDATE_JSON;
  delete env.WORKFLOWS_ENV_VALIDATE_LABEL;
  delete env.WORKFLOWS_ENV_VALIDATE_ALLOW_LOWERCASE;
  return env;
}

// Runs the command-line entry with ENV added to the clean environment.
function runValidator(env) {
  return spawnSync(process.execPath, [SCRIPT], { env: { ...cleanEnvironment(), ...env }, encoding: 'utf8' });
}

// The message validateEnvJson throws for RAW, or undefined when it accepts it.
function refusal(raw, label = 'build-env', opts = {}) {
  try {
    validateEnvJson(raw, label, opts);
    return undefined;
  } catch (e) {
    return e.message;
  }
}

// --- the command-line entry --------------------------------------------------

test('env-validate refuses a credential-shaped name and accepts a plain one', () => {
  // The one validator behind both build-env and env-json. Its refusal is what
  // stops a secret being published through an input GitHub does not mask.
  let result = runValidator({
    WORKFLOWS_ENV_VALIDATE_JSON: '{"API_KEY":"x"}',
    WORKFLOWS_ENV_VALIDATE_LABEL: 'build-env',
  });
  assert.notEqual(result.status, 0, `a credential-shaped name must be refused: ${result.stderr}`);
  assert.match(result.stderr, /credential/);

  result = runValidator({
    WORKFLOWS_ENV_VALIDATE_JSON: '{"MONKEY":"x"}',
    WORKFLOWS_ENV_VALIDATE_LABEL: 'build-env',
  });
  assert.equal(result.status, 0, `MONKEY is not a credential - the boundary is ^ or _: ${result.stderr}`);
});

test('the command line writes each pair as key, NUL, value, NUL, keeping a newline inside a value', () => {
  const result = runValidator({
    WORKFLOWS_ENV_VALIDATE_JSON: JSON.stringify({ A: 'one', B: 'two\nlines', C: 3 }),
    WORKFLOWS_ENV_VALIDATE_LABEL: 'build-env',
  });
  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.stdout, 'A\0one\0B\0two\nlines\0C\x003\0');
  assert.equal(result.stderr, '');
});

test('an empty object on the command line writes nothing and succeeds', () => {
  const result = runValidator({ WORKFLOWS_ENV_VALIDATE_JSON: '{}' });
  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.stdout, '');
});

test('a refusal on the command line exits 1 with one annotation on stderr and nothing on stdout', () => {
  const result = runValidator({
    WORKFLOWS_ENV_VALIDATE_JSON: '{"GOOD":"1","GITHUB_SHA":"x"}',
    WORKFLOWS_ENV_VALIDATE_LABEL: 'env-json',
  });
  assert.equal(result.status, 1);
  assert.equal(result.stdout, '', 'a valid pair before the refused one must not be written');
  assert.equal(
    result.stderr,
    '::error::env-json key GITHUB_SHA is reserved by shared-workflows or by the runner; use the dedicated workflow input instead\n',
  );
});

test('with no label, or an empty one, the command line calls the input env', () => {
  for (const label of [undefined, '']) {
    const env = { WORKFLOWS_ENV_VALIDATE_JSON: 'not json' };
    if (label !== undefined) env.WORKFLOWS_ENV_VALIDATE_LABEL = label;
    const result = runValidator(env);
    assert.equal(result.status, 1);
    assert.match(result.stderr, /^::error::env is not valid JSON: /);
  }
});

test('lower-case keys pass the command line only when the switch is exactly 1', () => {
  let result = runValidator({
    WORKFLOWS_ENV_VALIDATE_JSON: '{"track":"beta"}',
    WORKFLOWS_ENV_VALIDATE_LABEL: 'env-json',
    WORKFLOWS_ENV_VALIDATE_ALLOW_LOWERCASE: '1',
  });
  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.stdout, 'track\0beta\0');

  for (const value of [undefined, 'true', '0']) {
    const env = { WORKFLOWS_ENV_VALIDATE_JSON: '{"track":"beta"}', WORKFLOWS_ENV_VALIDATE_LABEL: 'env-json' };
    if (value !== undefined) env.WORKFLOWS_ENV_VALIDATE_ALLOW_LOWERCASE = value;
    result = runValidator(env);
    assert.equal(result.status, 1, `switch ${value} must not allow lower-case keys`);
    assert.match(result.stderr, /env-json key is not an upper-case env name: track/);
  }
});

test('importing the module runs nothing: the command line needs WORKFLOWS_ENV_VALIDATE_JSON', () => {
  const result = spawnSync(
    process.execPath,
    ['--input-type=module', '-e', `import(${JSON.stringify(SCRIPT)}).then((m) => console.log(typeof m.validateEnvJson))`],
    { env: cleanEnvironment(), encoding: 'utf8' },
  );
  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.stdout, 'function\n');
});

// --- validateEnvJson: what it returns -----------------------------------------

test('accepted pairs come back in order, every value a string and null an empty one', () => {
  assert.deepEqual(
    validateEnvJson('{"NAME":"app","COUNT":2,"ENABLED":true,"OFF":false,"EMPTY":null}', 'build-env'),
    [
      ['NAME', 'app'],
      ['COUNT', '2'],
      ['ENABLED', 'true'],
      ['OFF', 'false'],
      ['EMPTY', ''],
    ],
  );
});

test('an empty object is valid and yields no pairs', () => {
  assert.deepEqual(validateEnvJson('{}', 'build-env'), []);
});

// --- validateEnvJson: the document ---------------------------------------------

test('text that is not JSON is refused with the parser message and the label', () => {
  const message = refusal('{"A":', 'build-env');
  assert.match(message, /^::error::build-env is not valid JSON: /);
  assert.ok(message.length > '::error::build-env is not valid JSON: '.length, 'the parser message is missing');
});

test('JSON that is not a flat object is refused', () => {
  for (const raw of ['null', '[]', '["A"]', '1', '"text"', 'true']) {
    assert.equal(refusal(raw, 'env-json'), '::error::env-json must be a flat JSON object', raw);
  }
});

test('a value that is an object or an array is refused as not a scalar', () => {
  assert.equal(refusal('{"NESTED":{"A":1}}'), '::error::build-env value for NESTED must be a scalar');
  assert.equal(refusal('{"LIST":[1,2]}'), '::error::build-env value for LIST must be a scalar');
});

// --- validateEnvJson: the key name ---------------------------------------------

test('without the lower-case switch a key must be an upper-case name', () => {
  for (const key of ['track', 'Mixed', '1ABC', '_LEADING', 'A-B', 'A B', '']) {
    assert.equal(
      refusal(JSON.stringify({ [key]: 'x' })),
      `::error::build-env key is not an upper-case env name: ${key}`,
      key,
    );
  }
  assert.deepEqual(validateEnvJson('{"A1_B":"x"}', 'build-env'), [['A1_B', 'x']]);
});

test('with the lower-case switch any valid name passes and an invalid one is refused', () => {
  assert.deepEqual(validateEnvJson('{"track":"beta","_lane":"x","Mixed1":"y"}', 'env-json', { allowLowerCase: true }), [
    ['track', 'beta'],
    ['_lane', 'x'],
    ['Mixed1', 'y'],
  ]);
  for (const key of ['1abc', 'a-b', 'a b', '']) {
    assert.equal(
      refusal(JSON.stringify({ [key]: 'x' }), 'env-json', { allowLowerCase: true }),
      `::error::env-json key is not a valid env name: ${key}`,
      key,
    );
  }
});

// --- validateEnvJson: credentials ----------------------------------------------

test('every credential suffix is refused, alone or after an underscore', () => {
  for (const suffix of ['KEY', 'TOKEN', 'PASSWORD', 'PASSPHRASE', 'SECRET', 'CREDENTIAL', 'CREDENTIALS']) {
    for (const key of [suffix, `SENTRY_${suffix}`]) {
      assert.equal(
        refusal(JSON.stringify({ [key]: 'x' })),
        `::error::build-env key ${key} looks like a credential; pass it as a secret instead - build-env is a workflow input and is not masked`,
        key,
      );
    }
  }
});

test('a suffix that is only the end of a longer word is not a credential', () => {
  for (const key of ['MONKEY', 'TURKEY', 'KEYBOARD', 'TOKENS', 'SECRETARY']) {
    assert.equal(refusal(JSON.stringify({ [key]: 'x' })), undefined, key);
  }
});

test('every name on the NEVER list is refused though no suffix rule catches it', () => {
  assert.equal(NEVER.size, 4);
  for (const key of NEVER) {
    assert.equal(SECRETISH.test(key), false, `${key} is caught by the suffix rule, so the list is not what refuses it`);
    assert.match(refusal(JSON.stringify({ [key]: 'x' })), new RegExp(`key ${key} looks like a credential`), key);
  }
});

test('with the lower-case switch a lower-case credential name is still refused', () => {
  for (const key of ['sentry_auth_token', 'play_service_account_json']) {
    assert.match(refusal(JSON.stringify({ [key]: 'x' }), 'env-json', { allowLowerCase: true }), /looks like a credential/, key);
  }
});

test('a name that is both a credential and reserved is refused as a credential', () => {
  assert.match(refusal('{"GITHUB_TOKEN":"x"}'), /key GITHUB_TOKEN looks like a credential/);
});

// --- validateEnvJson: reserved names -------------------------------------------

test('every reserved prefix and name is refused', () => {
  for (const key of [
    'WORKFLOWS_FINGERPRINT_IOS',
    'GITHUB_SHA',
    'RUNNER_TEMP',
    'ACTIONS_STEP_DEBUG',
    'LD_PRELOAD',
    'DYLD_INSERT_LIBRARIES',
    'PATH',
    'HOME',
    'NODE_OPTIONS',
  ]) {
    assert.equal(
      refusal(JSON.stringify({ [key]: 'x' })),
      `::error::build-env key ${key} is reserved by shared-workflows or by the runner; use the dedicated workflow input instead`,
      key,
    );
  }
});

test('a name that only starts like a reserved one is not reserved', () => {
  for (const key of ['PATHS', 'HOMEPAGE', 'NODE_OPTIONS_EXTRA', 'MY_GITHUB_URL', 'WORKFLOWS']) {
    assert.equal(RESERVED.test(key), false, key);
    assert.equal(refusal(JSON.stringify({ [key]: 'x' })), undefined, key);
  }
});

test('with the lower-case switch a lower-case reserved name is still refused', () => {
  for (const key of ['workflows_fingerprint_ios', 'path', 'github_sha']) {
    assert.match(refusal(JSON.stringify({ [key]: 'x' }), 'env-json', { allowLowerCase: true }), /is reserved/, key);
  }
});

test('the two name patterns differ only in case', () => {
  assert.equal(VALID_NAME.test('track'), false);
  assert.equal(VALID_NAME_ANY_CASE.test('track'), true);
  assert.equal(VALID_NAME.test('TRACK_1'), true);
  assert.equal(VALID_NAME_ANY_CASE.test('TRACK_1'), true);
});

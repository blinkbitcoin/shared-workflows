// The one validator for caller-supplied JSON objects whose keys become
// environment variables. Two inputs feed this: $WORKFLOWS_BUILD_ENV (via
// scripts/lib/build-env.sh) and $WORKFLOWS_ENV_JSON (via scripts/release/env-json.sh),
// and check-contract applies it to a caller's environment-variables before any
// release does. It lives in the package for that reason; the two scripts reach
// it at packages/app-tooling/lib/ in this checkout.
//
// They used to carry a copy of these rules each, and the copies had drifted in
// the direction that matters: env-json had no credential-name refusal and no
// NEVER list, so {"SENTRY_AUTH_TOKEN": "..."} was published straight into
// $GITHUB_ENV from an input GitHub does not mask. env-json.sh's own header
// claimed the two could not drift because the same assertions covered both; in
// fact that file had no credential assertion at all.
//
// One difference between the two inputs is deliberate and stays: env-json
// permits lower-case keys, because they reach a fastlane lane whose own option
// names are lower-case. See VALID_NAME_ANY_CASE below.
//
// Both inputs arrive as workflow `inputs:` values. GitHub does not mask those:
// they show in the run's parameters and are readable by anyone who can see the
// run. Refusing a credential-shaped name here is the difference between the
// caller noticing immediately and a credential quietly landing in a public log.
//
// Usage as a CLI (what the two shell scripts do):
//   WORKFLOWS_ENV_VALIDATE_JSON='{"A":"1"}' WORKFLOWS_ENV_VALIDATE_LABEL=build-env \
//     node packages/app-tooling/lib/env-validate.mjs
// It writes `key\0value\0` pairs to stdout and exits non-zero, with an ::error::
// annotation naming the offending key, on any violation.

import { isProgram } from './is-program.mjs';

/** Names that read as a credential by their suffix. */
export const SECRETISH = /(^|_)(KEY|TOKEN|PASSWORD|PASSPHRASE|SECRET|CREDENTIALS?)$/;

/** Known credential names that the suffix rule alone would not catch. */
export const NEVER = new Set([
  'PLAY_SERVICE_ACCOUNT_JSON',
  'ASC_KEY_P8_BASE64',
  'ANDROID_UPLOAD_KEYSTORE_BASE64',
  'MATCH_GIT_BASIC_AUTHORIZATION',
]);

// Names owned by this workflow family or by the runner. WORKFLOWS_FINGERPRINT_IOS /
// WORKFLOWS_FINGERPRINT_ANDROID are the sharp end: build-env is published before fingerprint.sh
// runs, so a caller-supplied value there hands the OTA fingerprint gate a
// constant to compare its baseline against. WORKFLOWS_ASSETS_DIR and
// WORKFLOWS_RELEASE_META_DIR would repoint the artifact paths mid-job.
export const RESERVED = /^(WORKFLOWS_|GITHUB_|RUNNER_|ACTIONS_|LD_|DYLD_)|^(PATH|HOME|NODE_OPTIONS)$/;

// Two name rules, because the case difference between the two inputs is
// deliberate and documented, not drift. build-env feeds prebuild, the verify
// scripts and the notes generator, where every name is upper-case. env-json
// feeds a fastlane lane, and fastlane's own option names (`track`, `lane`) are
// lower-case - docs/consumer-guide.md says so explicitly.
//
// What is NOT allowed to differ is everything below this line: the credential
// refusal, the NEVER list, the reserved-name rule and the scalar check. Those
// were the real drift.
export const VALID_NAME = /^[A-Z][A-Z0-9_]*$/;
export const VALID_NAME_ANY_CASE = /^[A-Za-z_][A-Za-z0-9_]*$/;

/**
 * Validates a flat JSON object of environment variables.
 *
 * @param {string} raw JSON text.
 * @param {string} label the input's name, used in every message.
 * @param {{allowLowerCase?: boolean}} [opts] `allowLowerCase` for env-json,
 *   whose keys reach a fastlane lane and may be lower-case by design.
 * @returns {Array<[string, string]>} key/value pairs, values stringified.
 * @throws {Error} with a message already formatted as a ::error:: annotation.
 */
export function validateEnvJson(raw, label, opts = {}) {
  const namePattern = opts.allowLowerCase ? VALID_NAME_ANY_CASE : VALID_NAME;
  let obj;
  try {
    obj = JSON.parse(raw);
  } catch (e) {
    throw new Error(`::error::${label} is not valid JSON: ${e.message}`);
  }
  if (obj === null || typeof obj !== 'object' || Array.isArray(obj)) {
    throw new Error(`::error::${label} must be a flat JSON object`);
  }
  const pairs = [];
  for (const [k, v] of Object.entries(obj)) {
    if (!namePattern.test(k)) {
      throw new Error(
        opts.allowLowerCase
          ? `::error::${label} key is not a valid env name: ${k}`
          : `::error::${label} key is not an upper-case env name: ${k}`,
      );
    }
    // Upper-cased before the credential and reserved checks: with lower-case
    // names permitted, a case-sensitive rule would wave `sentry_auth_token` and
    // `workflows_fp_ios` straight through the two checks that exist to stop them.
    const upper = k.toUpperCase();
    if (SECRETISH.test(upper) || NEVER.has(upper)) {
      throw new Error(
        `::error::${label} key ${k} looks like a credential; pass it as a secret instead - ${label} is a workflow input and is not masked`,
      );
    }
    if (RESERVED.test(upper)) {
      throw new Error(
        `::error::${label} key ${k} is reserved by shared-workflows or by the runner; use the dedicated workflow input instead`,
      );
    }
    if (v !== null && typeof v === 'object') {
      throw new Error(`::error::${label} value for ${k} must be a scalar`);
    }
    pairs.push([k, v === null ? '' : String(v)]);
  }
  return pairs;
}

// CLI. Guarded so the module can be imported by tests without running.
// Only as a program: check-contract imports this module, and an inherited
// WORKFLOWS_ENV_VALIDATE_JSON must not turn that import into a run that exits.
if (isProgram(import.meta.url, process.argv[1]) && process.env.WORKFLOWS_ENV_VALIDATE_JSON !== undefined) {
  const label = process.env.WORKFLOWS_ENV_VALIDATE_LABEL || 'env';
  try {
    const allowLowerCase = process.env.WORKFLOWS_ENV_VALIDATE_ALLOW_LOWERCASE === '1';
    for (const [k, v] of validateEnvJson(process.env.WORKFLOWS_ENV_VALIDATE_JSON, label, {
      allowLowerCase,
    })) {
      // NUL-separated, not line-separated: a value may legitimately contain a
      // newline, and a line-based reader would split it into a second variable.
      process.stdout.write(`${k}\0${v}\0`);
    }
  } catch (e) {
    console.error(e.message);
    process.exit(1);
  }
}

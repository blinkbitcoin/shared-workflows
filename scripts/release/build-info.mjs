#!/usr/bin/env node
// Write build-info.json, the record of what a release build is, for
// scripts/release/build-info.sh. The shell script settles where the record goes,
// which consumer it describes and the values the environment does not carry yet
// (the sha, the stage, --standalone's version and fingerprints); this program
// only assembles the record and writes it. See build-info.sh for the schema and
// for who reads each key.
//
//   build-info.mjs DEST CONSUMER_ROOT
//
// Env: BUILD_INFO_SHA, BUILD_INFO_STAGE, APP_VERSION, APP_BUILD_NUMBER,
//      FINGERPRINT_IOS, FINGERPRINT_ANDROID, GITHUB_RUN_ID.
//
// Shipped byte-identical in @blinkbitcoin/app-tooling as release/build-info.mjs
// beside its build-info.sh (scripts/self/package-copies.sh), so it imports
// nothing outside node itself.
import { realpathSync, writeFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

export const USAGE = 'usage: build-info.mjs DEST CONSUMER_ROOT';

/**
 * The version of package `name` as installed for the consumer at `root`, or
 * null when it is not installed.
 *
 * A provenance record must say what actually went into the build, so this is
 * the installed package, not the range in package.json. The shell copy once
 * read the declared range and stripped its operator, which reported 57.0.20 for
 * a build that actually ran on 57.0.22. Resolution starts at the consumer root,
 * so the pnpm layout is followed the way the app itself follows it.
 */
export function installedVersion(root, name) {
  const requireFromRoot = createRequire(path.join(root, 'package.json'));
  try {
    return requireFromRoot(`${name}/package.json`).version ?? null;
  } catch {
    // A consumer without that package installed still gets a build-info.json;
    // the field is null rather than failing the release over provenance.
    return null;
  }
}

/**
 * The record, from the environment and `installed(name)`. Key order is the
 * schema's order, and it is what the file shows.
 */
export function buildRecord(env, installed) {
  return {
    sha: env.BUILD_INFO_SHA,
    version: env.APP_VERSION,
    buildNumber: Number(env.APP_BUILD_NUMBER),
    stage: env.BUILD_INFO_STAGE,
    fingerprint: {
      ios: env.FINGERPRINT_IOS || null,
      android: env.FINGERPRINT_ANDROID || null,
    },
    expoSdk: installed('expo'),
    reactNative: installed('react-native'),
    workflowRunId: env.GITHUB_RUN_ID || null,
    artifacts: {},
  };
}

/** The record as the file holds it: two-space JSON and a final newline. */
export function serialize(record) {
  return `${JSON.stringify(record, null, 2)}\n`;
}

/**
 * The whole program, returning its exit code. The environment, the writer and
 * the error stream arrive through the second argument, so the tests run every
 * path of it in-process; the defaults are the real ones.
 */
export function main(argv, { env = process.env, write = writeFileSync, stderr = process.stderr } = {}) {
  if (argv.length !== 2) {
    stderr.write(`::error::${USAGE}\n`);
    return 2;
  }
  const [dest, root] = argv;
  const record = buildRecord(env, (name) => installedVersion(root, name));
  try {
    write(dest, serialize(record));
  } catch (error) {
    stderr.write(`::error::cannot write ${dest}: ${error.message}\n`);
    return 1;
  }
  return 0;
}

// Run as a program rather than imported. Not `import.meta.main`: the package
// copy runs on a consumer's laptop under the package's node floor (22.12),
// which predates it, and there it is undefined - the program would write
// nothing and exit 0. realpathSync because node loads a module by its real
// path, while argv[1] is the path the caller typed.
if (process.argv[1] && fileURLToPath(import.meta.url) === realpathSync(path.resolve(process.argv[1]))) {
  process.exitCode = main(process.argv.slice(2));
}

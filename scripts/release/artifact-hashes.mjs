#!/usr/bin/env node
// Write a copy of a build-info record with digests merged into its `artifacts`,
// for scripts/release/artifact-hashes.sh. The shell script finds the binaries
// for its platform and hashes them; this program only records what it is
// handed, so it knows no platform and no file type.
//
//   artifact-hashes.mjs SOURCE DEST [NAME=SHA256...]
//
// Each NAME=SHA256 becomes artifacts.NAME. An empty SHA256 means that binary was
// not built, and is recorded as absent rather than as an empty digest.
import { readFileSync, realpathSync, writeFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { readJson, writeJson } from './merge-build-info.mjs';

export const USAGE = 'usage: artifact-hashes.mjs SOURCE DEST [NAME=SHA256...]';

/**
 * The digests named by `pairs` (`NAME=SHA256`), in order, leaving out the ones
 * with no digest. Throws on a pair with no `=` or no name.
 */
export function parseDigests(pairs) {
  const digests = {};
  for (const pair of pairs) {
    const at = pair.indexOf('=');
    if (at < 1) throw new Error(`not NAME=SHA256: ${JSON.stringify(pair)}`);
    const sha = pair.slice(at + 1);
    if (sha) digests[pair.slice(0, at)] = sha;
  }
  return digests;
}

/**
 * `info` with `digests` merged into its `artifacts`. Merged, not replaced:
 * build-info.json ships an `artifacts` object precisely so each stage can add
 * what it knows without dropping what another wrote.
 */
export function withArtifacts(info, digests) {
  return { ...info, artifacts: { ...(info.artifacts ?? {}), ...digests } };
}

/**
 * The whole program, returning its exit code. The reader, the writer and the
 * error stream arrive through the second argument, so the tests run every path
 * of it in-process; the defaults are the real ones.
 */
export function main(argv, { read = readFileSync, write = writeFileSync, stderr = process.stderr } = {}) {
  if (argv.length < 2) {
    stderr.write(`::error::${USAGE}\n`);
    return 2;
  }
  const [source, dest, ...pairs] = argv;
  let digests;
  try {
    digests = parseDigests(pairs);
  } catch (error) {
    stderr.write(`::error::${error.message} (${USAGE})\n`);
    return 2;
  }
  try {
    writeJson(dest, withArtifacts(readJson(source, read), digests), write);
  } catch (error) {
    stderr.write(`::error::${error.message}\n`);
    return 1;
  }
  return 0;
}

// Run as a program rather than imported - the same guard as build-info.mjs.
if (process.argv[1] && fileURLToPath(import.meta.url) === realpathSync(path.resolve(process.argv[1]))) {
  process.exitCode = main(process.argv.slice(2));
}

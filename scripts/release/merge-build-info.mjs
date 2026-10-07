#!/usr/bin/env node
// Fold the `artifacts` of each per-platform build-info record into the base
// record, in place, for scripts/release/merge-build-info.sh. The shell script
// finds the records and seeds a missing base; the precedence rule lives here
// (see merge-build-info.sh's header for why): only `artifacts` is taken from a
// platform copy, later copies win key by key, and everything else stays as the
// base has it.
//
//   merge-build-info.mjs BASE OVERLAY...
//
// readJson and writeJson are also what artifact-hashes.mjs reads and writes a
// record with, so every build-info.json is written the same way.
import { readFileSync, realpathSync, writeFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

export const USAGE = 'usage: merge-build-info.mjs BASE OVERLAY...';

/**
 * The parsed JSON in `file`. A file that is not JSON is a wrong artifact or a
 * truncated download, so the error says which file rather than leaving the
 * reader a parser's stack trace.
 */
export function readJson(file, read = readFileSync) {
  try {
    return JSON.parse(read(file, 'utf8'));
  } catch (error) {
    throw new Error(`${file} is not readable as JSON: ${error.message}`);
  }
}

/** A record as every build-info.json holds it: two-space JSON and a final newline. */
export function writeJson(file, record, write = writeFileSync) {
  write(file, `${JSON.stringify(record, null, 2)}\n`);
}

/**
 * `info` with each overlay's `artifacts` merged into its own, in order. Nothing
 * but `artifacts` is read from an overlay: a platform copy is a snapshot of the
 * base record and must not be able to put a stale sha or stage back on it.
 */
export function mergeArtifacts(info, overlays) {
  let artifacts = { ...(info.artifacts ?? {}) };
  for (const overlay of overlays) artifacts = { ...artifacts, ...(overlay.artifacts ?? {}) };
  return { ...info, artifacts };
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
  const [base, ...files] = argv;
  try {
    const info = readJson(base, read);
    const overlays = files.map((file) => readJson(file, read));
    writeJson(base, mergeArtifacts(info, overlays), write);
  } catch (error) {
    stderr.write(`::error::${error.message}\n`);
    return 1;
  }
  return 0;
}

// Run as a program rather than imported - the same guard as build-info.mjs,
// whose package copy cannot rely on `import.meta.main`.
if (process.argv[1] && fileURLToPath(import.meta.url) === realpathSync(path.resolve(process.argv[1]))) {
  process.exitCode = main(process.argv.slice(2));
}

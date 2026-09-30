#!/usr/bin/env node
// Every package in pnpm-lock.yaml must come from the npm registry with an
// integrity hash, except this family's own packages at the one commit the
// workflows pin.
//
// An allowlist of shapes, not a list of bad ones. A registry package resolves to
// `{integrity: ...}`, or to `{integrity: ..., tarball: <registry.npmjs.org URL>}`
// when its tarball sits off the standard path; anything else is some other
// source. pnpm 12 writes a git dependency as `{gitHosted: true, integrity: ...,
// path: ..., tarball: https://codeload.github.com/...}`, which a denylist of
// `type: git` and `repo:` passed as "lockfile ok".
//
// The one git source allowed is shared-workflows' packages/<name> at the
// workflows pin: CI already runs that commit's code with the consumer's token,
// so installing it adds no trust. Another repository, path or commit fails, and
// so does every git source when the workflows pin no single commit (a tag such
// as @v0 moves, so it allows none either).
//
// Usage: check-lockfile [--root DIR]   (default: the working directory)
import { readFileSync } from 'node:fs';
import path from 'node:path';
import { isProgram } from '../lib/is-program.mjs';
import { isCommit, SHARED, workflowsPin } from '../lib/pin.mjs';
import { parseArgs, readCallers } from './fix-tooling-pin.mjs';

const HASH = '[^,{}\\s]+';
const REGISTRY = new RegExp(`^resolution: \\{integrity: ${HASH}(, tarball: https://registry\\.npmjs\\.org/${HASH})?\\}$`);

/** The allowed git resolution for this family's packages at `pin`. */
function sharedResolution(pin) {
  const repo = SHARED.replace('/', '\\/');
  return new RegExp(
    `^resolution: \\{gitHosted: true, integrity: ${HASH}, path: /packages/[\\w.-]+, tarball: https://codeload\\.github\\.com/${repo}/tar\\.gz/${pin}\\}$`,
  );
}

/**
 * Every resolution line in `lockfile` that is neither the registry nor this
 * family at `pin`, as `line: text`. With no single pin, or a tag that moves,
 * no git source is allowed.
 */
export function foreignResolutions(lockfile, pin) {
  const shared = pin !== null && isCommit(pin) ? sharedResolution(pin) : null;
  const found = [];
  for (const [index, raw] of lockfile.split('\n').entries()) {
    const line = raw.trim();
    if (!line.startsWith('resolution:')) continue;
    if (REGISTRY.test(line) || shared?.test(line)) continue;
    found.push(`${index + 1}: ${line}`);
  }
  return found;
}

/** Command-line entry; returns the exit code. */
export function main(argv = [], { cwd = process.cwd(), log = console.log, error = console.error } = {}) {
  const args = parseArgs(argv, cwd);
  if (args.error) {
    error(args.error.replace('fix-tooling-pin', 'check-lockfile'));
    return 2;
  }
  let lockfile;
  try {
    lockfile = readFileSync(path.join(args.root, 'pnpm-lock.yaml'), 'utf8');
  } catch {
    error(`no pnpm-lock.yaml in ${args.root}`);
    return 1;
  }
  const { pin } = workflowsPin(readCallers(args.root));
  const foreign = foreignResolutions(lockfile, pin);
  if (foreign.length > 0) {
    error('pnpm-lock.yaml resolves packages from outside the npm registry:');
    for (const line of foreign) error(line);
    return 1;
  }
  log('lockfile ok');
  return 0;
}

if (isProgram(import.meta.url, process.argv[1])) process.exitCode = main(process.argv.slice(2));

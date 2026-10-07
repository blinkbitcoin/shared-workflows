#!/usr/bin/env node
// Every enabled security scanner, then the verdict, over the repository in the
// current directory: the same runners check-security.yml runs, from the copies
// this package ships (security/), so a green laptop means a green pipeline.
//
//   check-security              every job security-settings.json switches on
//   check-security JOB...       those jobs only, then their own verdict
//
// JOB is one of dependencies, code, policy, sbom, bundle, mobile, binaries,
// review or review-codebase. Output lands in .security/ (SECURITY_DIR), one
// SARIF per job. A tool that is not installed is a skip here and a failure
// under CI. Exits with the verdict's code: 1 while a finding blocks.
import { spawnSync } from 'node:child_process';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { isProgram } from '../lib/is-program.mjs';
import { answerHelp } from '../lib/usage.mjs';

export const SCAN = path.join(path.dirname(fileURLToPath(import.meta.url)), '..', 'security', 'scan.sh');

/** Command-line entry; returns the exit code. */
export function main(argv = process.argv.slice(2), { run = spawnSync, cwd = process.cwd(), log = console.log } = {}) {
  if (answerHelp(argv, import.meta.url, log)) return 0;
  const result = run('bash', [SCAN, ...argv], { cwd, stdio: 'inherit' });
  if (result.error) throw result.error;
  return result.status ?? 1;
}

if (isProgram(import.meta.url, process.argv[1])) process.exitCode = main();

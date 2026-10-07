#!/usr/bin/env node
// Every production dependency is under a license the organisation accepts.
//
//   check-licenses [--allow SPDX ...] [--root DIR]
//
// Reads `pnpm licenses list --json --prod` in DIR and fails naming each package
// whose license is outside the allowlist: the organisation's default below,
// plus each --allow the repository adds for itself. An --allow widens the list
// for that repository only; it never narrows the default.
//
// A license is an SPDX expression. A package must satisfy every conjunct of an
// AND, and one alternative of an OR, so the two are not interchangeable:
// `GPL-3.0 AND MIT` needs both allowed, `MIT OR GPL-3.0` needs either. One outer
// pair of parentheses is read; a nested or mixed group is refused rather than
// parsed wrongly.
import { execFileSync } from 'node:child_process';
import path from 'node:path';
import { isProgram } from '../lib/is-program.mjs';
import { answerHelp } from '../lib/usage.mjs';

/** The licenses every repository of the organisation accepts, as SPDX identifiers. */
export const DEFAULT_ALLOWED = [
  'MIT',
  'Apache-2.0',
  'BSD-2-Clause',
  'BSD-3-Clause',
  'ISC',
  '0BSD',
  'CC0-1.0',
  'Unlicense',
  'MPL-2.0',
  'CC-BY-4.0',
  'Python-2.0',
  'BlueOak-1.0.0',
];

/** Whether the SPDX expression `expression` is satisfied by the licenses in `allowed`. */
export function licenseAllowed(expression, allowed = DEFAULT_ALLOWED) {
  const stripped = expression.replace(/^\(/, '').replace(/\)$/, '');
  if (stripped.includes('(') || stripped.includes(')')) return false;
  return stripped
    .split(/\s+OR\s+/i)
    .some((alternative) => alternative.split(/\s+AND\s+/i).every((license) => allowed.includes(license.trim())));
}

/** Each package of a `pnpm licenses list --json` report whose license is not allowed, as `{ name, license }`. */
export function findViolations(report, allowed = DEFAULT_ALLOWED) {
  const out = [];
  for (const [license, packages] of Object.entries(report)) {
    if (licenseAllowed(license, allowed)) continue;
    for (const { name } of packages) out.push({ name, license });
  }
  return out;
}

/** `--allow SPDX` (repeatable) and `--root DIR`, as `{ root, extra }`. */
export function parseArgs(argv, cwd) {
  let root = cwd;
  const extra = [];
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    const value = argv[++i];
    if (arg === '--root' && value) root = path.resolve(cwd, value);
    else if (arg === '--allow' && /^[A-Za-z0-9.+-]+$/.test(value ?? '')) extra.push(value);
    else throw new Error(`unexpected ${[arg, value].filter(Boolean).join(' ')}: pass --allow SPDX-IDENTIFIER and --root DIR`);
  }
  return { root, extra };
}

const pnpmLicenses = (root) =>
  execFileSync('pnpm', ['licenses', 'list', '--json', '--prod'], { cwd: root, encoding: 'utf8', maxBuffer: 64 * 1024 * 1024 });

/** Command-line entry; returns the exit code. */
export function main(
  argv = process.argv.slice(2),
  { log = console.log, error = console.error, cwd = process.cwd(), licenses = pnpmLicenses } = {},
) {
  if (answerHelp(argv, import.meta.url, log)) return 0;
  let options;
  try {
    options = parseArgs(argv, cwd);
  } catch (e) {
    error(`licenses: ${e.message}`);
    return 1;
  }
  const { root, extra } = options;
  let report;
  try {
    report = JSON.parse(licenses(root));
  } catch (e) {
    error(`licenses: could not read \`pnpm licenses list --json --prod\` in ${root}: ${e.message}`);
    return 1;
  }
  const violations = findViolations(report, [...DEFAULT_ALLOWED, ...extra]);
  if (violations.length > 0) {
    for (const { name, license } of violations) error(`disallowed license ${license}: ${name}`);
    error(`licenses: ${violations.length} package(s) outside the allowlist; a license this repository accepts goes in an --allow`);
    return 1;
  }
  log(`licenses ok (${Object.values(report).flat().length} packages)`);
  return 0;
}

if (isProgram(import.meta.url, process.argv[1])) process.exitCode = main();

#!/usr/bin/env node
// Renders a pass/fail badge for a CI job group (Unit, E2E) from the result
// GitHub hands a dependent job (`needs.<job>.result`), so a branch's README can
// show "Unit: passing" the same way it shows measured coverage.
//
//   gen-status-badge <name> <label> <result> [--out DIR]
//   e.g. gen-status-badge unit Unit success
//
// An unknown result is an error, not a green badge: a typo or a result value
// GitHub adds later must be visible, and "we could not tell" is not "passing".
// gen-badges calls the same writer.
import { mkdirSync, writeFileSync } from 'node:fs';
import path from 'node:path';
import { BadgeError, renderBadgeJson, renderBadgeSvg, STATUS_RESULTS } from '../lib/badge.mjs';
import { isProgram } from '../lib/is-program.mjs';
import { argValue, BADGE_DIR } from './gen-coverage-badge.mjs';
import { answerHelp } from '../lib/usage.mjs';

/** Write `<name>.svg` + `<name>.json` into `outDir`; returns the badge. */
export function writeStatusBadge({ outDir = BADGE_DIR, name, label, result }) {
  if (!/^[a-z0-9-]+$/.test(String(name))) {
    throw new BadgeError(`gen-status-badge: name must be a file-safe slug, got "${name}"`);
  }
  if (!label) throw new BadgeError('gen-status-badge: a label is required');
  const known = STATUS_RESULTS[result];
  if (!known) {
    throw new BadgeError(
      `gen-status-badge: unknown job result "${result}" — expected one of ${Object.keys(STATUS_RESULTS).join(', ')}`,
    );
  }
  const badge = { label, message: known.message, color: known.color };
  mkdirSync(outDir, { recursive: true });
  writeFileSync(path.join(outDir, `${name}.svg`), renderBadgeSvg(badge));
  writeFileSync(path.join(outDir, `${name}.json`), renderBadgeJson(badge));
  return badge;
}

/** Command-line entry; returns the exit code. */
export function main(
  argv = process.argv.slice(2),
  { log = console.log, error = console.error } = {},
) {
  if (answerHelp(argv, import.meta.url, log)) return 0;
  const [name, label, result] = argv;
  try {
    const badge = writeStatusBadge({
      outDir: argValue(argv, '--out', BADGE_DIR),
      name,
      label,
      result,
    });
    log(`gen-status-badge: ${badge.label}: ${badge.message}`);
    return 0;
  } catch (e) {
    if (!(e instanceof BadgeError)) throw e;
    error(e.message);
    error(
      'usage: gen-status-badge <name> <label> <' +
        `${Object.keys(STATUS_RESULTS).join('|')}> [--out DIR]`,
    );
    return 1;
  }
}

if (isProgram(import.meta.url, process.argv[1])) process.exitCode = main();

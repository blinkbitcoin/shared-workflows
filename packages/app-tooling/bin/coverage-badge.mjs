#!/usr/bin/env node
// Renders the coverage badge from the measured number instead of a hardcoded
// shields.io URL. The number comes from Jest's `json-summary` reporter
// (`coverage/coverage-summary.json`), never from scraping the HTML report.
//
//   coverage-badge                    measure
//   coverage-badge --status failing   red placeholder
//   coverage-badge --status pending   yellow placeholder
//
// A placeholder is what CI writes when Unit *failed*; a Unit that merely
// skipped writes nothing at all, so a red checks run leaves the branch's
// badge as it was. `--out` and `--summary` exist for tests and for a CI layout
// that keeps its artifacts elsewhere. render-badges calls the same writer.
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import path from 'node:path';
import {
  BADGE_DIR,
  BadgeError,
  coverageFrom,
  PLACEHOLDERS,
  parseStatus,
  renderBadgeJson,
  renderBadgeSvg,
  SUMMARY_PATH,
} from '../lib/badge.mjs';
import { isProgram } from '../lib/is-program.mjs';

export { BADGE_DIR, SUMMARY_PATH };

/** `--name value` out of argv, or `fallback`. */
export function argValue(argv, name, fallback) {
  const i = argv.indexOf(name);
  return i === -1 || argv[i + 1] === undefined ? fallback : argv[i + 1];
}

/**
 * Write `coverage.svg` + `coverage.json` into `outDir` and return the rendered
 * `{ message, color, detail }`. `status` non-null renders a placeholder and
 * reads no summary at all.
 */
export function writeCoverageBadge({
  outDir = BADGE_DIR,
  summaryFile = SUMMARY_PATH,
  status = null,
} = {}) {
  let result;
  if (status) {
    result = { message: status, color: PLACEHOLDERS[status], detail: 'placeholder' };
  } else {
    let summary;
    try {
      summary = JSON.parse(readFileSync(summaryFile, 'utf8'));
    } catch (e) {
      throw new BadgeError(
        `coverage-badge: ${summaryFile} is missing or unreadable (${e.message}) — run \`make test-coverage\` first`,
      );
    }
    result = coverageFrom(summary);
  }
  const badge = { label: 'Coverage', message: result.message, color: result.color };
  mkdirSync(outDir, { recursive: true });
  writeFileSync(path.join(outDir, 'coverage.svg'), renderBadgeSvg(badge));
  writeFileSync(path.join(outDir, 'coverage.json'), renderBadgeJson(badge));
  return result;
}

/** Command-line entry; returns the exit code. */
export function main(
  argv = process.argv.slice(2),
  { log = console.log, error = console.error } = {},
) {
  try {
    const status = parseStatus(argv);
    const { message, detail } = writeCoverageBadge({
      outDir: argValue(argv, '--out', BADGE_DIR),
      summaryFile: argValue(argv, '--summary', SUMMARY_PATH),
      status,
    });
    log(`coverage-badge: ${message} (${detail})`);
    return 0;
  } catch (e) {
    if (!(e instanceof BadgeError)) throw e;
    error(e.message);
    return 1;
  }
}

if (isProgram(import.meta.url, process.argv[1])) process.exitCode = main();

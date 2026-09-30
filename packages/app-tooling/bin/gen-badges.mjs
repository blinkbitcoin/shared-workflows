#!/usr/bin/env node
// Renders every CI badge a branch publishes: coverage, Unit, E2E and Security.
// `publish-badges.yml` runs it from its own checkout of shared-workflows
// (scripts/ci/gen-badges.sh), in the consumer's root, unless the caller names
// a script of its own in `render-script`; a consumer runs the same program on a
// laptop as `pnpm exec gen-badges`. It takes no arguments - the workflow and
// a consumer's `make` target both hand it everything as environment:
//
//   BADGE_UNIT / BADGE_E2E        GitHub job results (`needs.<job>.result`)
//   BADGE_UNIT_LABEL / ..._E2E_   badge labels (default Unit / E2E)
//   BADGE_COVERAGE                measure | failing | pending | skip
//                                 (default: derived from BADGE_UNIT)
//   BADGE_COVERAGE_SUMMARY        coverage/coverage-summary.json
//   BADGE_OUT_DIR                 coverage/badge
//   BADGE_SECURITY                check-security.yml's verdict line, or empty
//   BADGE_SECURITY_LABEL          badge label (default Security)
//
// The coverage default: only a Unit *failure* writes the red placeholder. A
// skipped Unit — a red checks run, a cancelled upstream — renders no coverage
// badge at all, so publishing leaves the branch's existing one untouched
// instead of blanking it.
import { BadgeError } from '../lib/badge.mjs';
import { isProgram } from '../lib/is-program.mjs';
import { writeSecurityBadge } from '../lib/security-badge.mjs';
import { BADGE_DIR, SUMMARY_PATH, writeCoverageBadge } from './gen-coverage-badge.mjs';
import { writeStatusBadge } from './gen-status-badge.mjs';

/** What to do about the coverage badge, given the Unit job's result. */
export function coverageModeFor(unitResult) {
  if (unitResult === 'success') return 'measure';
  if (unitResult === 'failure') return 'failing';
  return 'skip';
}

/** Render every badge the environment asks for; returns the file names written. */
export function renderBadges(env = process.env) {
  const outDir = env.BADGE_OUT_DIR || BADGE_DIR;
  const unit = env.BADGE_UNIT || '';
  const e2e = env.BADGE_E2E || '';
  const written = [];

  const mode = env.BADGE_COVERAGE || coverageModeFor(unit);
  if (mode !== 'skip') {
    const { message, detail } = writeCoverageBadge({
      outDir,
      summaryFile: env.BADGE_COVERAGE_SUMMARY || SUMMARY_PATH,
      status: mode === 'measure' ? null : mode,
    });
    console.log(`badges: Coverage ${message} (${detail})`);
    written.push('coverage.svg');
  } else {
    console.log(`badges: no coverage badge (unit result "${unit}") — leaving the published one`);
  }

  for (const [name, label, result] of [
    ['unit', env.BADGE_UNIT_LABEL || 'Unit', unit],
    ['e2e', env.BADGE_E2E_LABEL || 'E2E', e2e],
  ]) {
    const badge = writeStatusBadge({ outDir, name, label, result });
    console.log(`badges: ${badge.label} ${badge.message}`);
    written.push(`${name}.svg`);
  }

  // check-security.yml's verdict output, passed on by publish-badges.yml. No
  // verdict (a docs-only change skipped Security) renders nothing, and
  // publish-badges.sh copies only what was rendered, so the published badge stays.
  const security = env.BADGE_SECURITY || '';
  if (security) {
    const badge = writeSecurityBadge({
      outDir,
      label: env.BADGE_SECURITY_LABEL || 'Security',
      verdict: security,
    });
    console.log(`badges: ${badge.label} ${badge.message}`);
    written.push('security.svg');
  } else {
    console.log('badges: no security verdict — leaving the published one');
  }
  return written;
}

/** Command-line entry; returns the exit code. */
export function main(env = process.env, { error = console.error } = {}) {
  try {
    renderBadges(env);
    return 0;
  } catch (e) {
    if (!(e instanceof BadgeError)) throw e;
    error(e.message);
    return 1;
  }
}

if (isProgram(import.meta.url, process.argv[1])) process.exitCode = main();

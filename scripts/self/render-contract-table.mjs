#!/usr/bin/env node
// Render packages/dev-config/contract.json as the requirement table in
// docs/adopting-an-existing-repo.md.
//
// Generated rather than written, because this is the third place the same facts
// would otherwise live - the checker reads contract.json, the consumer guide
// describes the same requirements in prose, and an adoption checklist is
// exactly the kind of list that is right on the day it is written and wrong six
// months later. The prose around the table is written by hand; only the table
// between the markers comes from here, and test/contract-doctor.bats fails when
// the committed file and this output disagree.
import { readFileSync, writeFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.join(HERE, '..', '..');

export const START = '<!-- contract-table:start -->';
export const END = '<!-- contract-table:end -->';

export const PROFILE_TITLE = {
  checks: '`check-code.yml`',
  unit: '`check-unit.yml`',
  e2e: '`check-e2e.yml`',
  web: '`build-web.yml`',
  badges: '`publish-badges.yml`',
  codeql: '`check-codeql.yml`',
  release: 'the release workflows',
};

/** What a reader has to do about one requirement, in a sentence. */
export function need(req) {
  if (req.severity === 'degrades') return 'optional — a fallback runs';
  if (req.toggle && req.defaultOn) return `required, or pass \`${req.toggle.split(':')[1]}: false\``;
  if (req.toggle) return `only if you set \`${req.toggle.split(':')[1]}: true\``;
  return 'required';
}

/**
 * How a requirement's target reads in the table.
 *
 * The join is not cosmetic: a list of alternatives and a list of things all of
 * which are needed look identical as data. An Expo config is satisfied by any
 * one of app.config.ts / app.json; a mise config has to pin node AND pnpm, and
 * "node or pnpm" would read as a choice the reader does not have.
 */
export function targetOf(req) {
  const all = Array.isArray(req.target) ? req.target : [req.target];
  const quoted = all.map((t) => `\`${t}\``);
  const conjunction = req.kind === 'file' ? 'or' : 'and';
  const joined =
    quoted.length <= 2
      ? quoted.join(` ${conjunction} `)
      : `${quoted.slice(0, -1).join(', ')} ${conjunction} ${quoted.at(-1)}`;
  if (req.kind === 'mise-tool') return `${joined} in your mise config`;
  if (req.kind === 'fastlane-lane') return `the ${joined} lanes`;
  if (req.kind === 'make-ci-reaches-ci') return 'every gate CI runs, reachable from `make ci`';
  if (req.kind === 'ci-runs-make-ci') return 'every gate `make ci` runs, run by CI';
  if (req.kind === 'fastlane-env-subset') return `lanes that read only these \`${req.prefix}*\` names: ${joined}`;
  return joined;
}

export function renderTable(contract) {
  const lines = [];
  for (const profile of contract.profiles) {
    const rows = contract.requirements.filter((r) => r.profile === profile);
    if (rows.length === 0) continue;
    lines.push('', `### If you call ${PROFILE_TITLE[profile] ?? profile}`, '');
    lines.push('| What | You need | Why |', '| --- | --- | --- |');
    for (const req of rows) {
      lines.push(`| ${targetOf(req)} | ${need(req)} | ${req.neededBy} |`);
    }
  }
  return lines.join('\n');
}

/** The file's text with the generated block replaced. */
export function splice(text, table) {
  const start = text.indexOf(START);
  const end = text.indexOf(END);
  if (start === -1 || end === -1) {
    throw new Error(`::error::the adoption doc has lost its ${START} / ${END} markers`);
  }
  return `${text.slice(0, start + START.length)}\n${table}\n\n${text.slice(end)}`;
}

if (process.argv[1] && fileURLToPath(import.meta.url) === path.resolve(process.argv[1])) {
  const contract = JSON.parse(readFileSync(path.join(ROOT, 'packages/dev-config/contract.json'), 'utf8'));
  const doc = path.join(ROOT, 'docs/adopting-an-existing-repo.md');
  const text = readFileSync(doc, 'utf8');
  const next = splice(text, renderTable(contract));
  if (process.argv.includes('--write')) {
    writeFileSync(doc, next);
    console.log(next === text ? 'adoption doc already up to date' : 'adoption doc rewritten');
  } else {
    process.stdout.write(next);
  }
}

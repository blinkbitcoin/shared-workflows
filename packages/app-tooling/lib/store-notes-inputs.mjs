// What the store-notes suite (suites/store-notes.suite.mjs) holds an app to, as
// data and pure functions, so they are tested on their own here and the suite
// is left with the running. The app's half of the store notes is its prompt
// addendum and its store listing's locales; the generator and the release
// chain around it are this repository's, and tested here.
import { readdirSync } from 'node:fs';
import { discoverLocales } from '../bin/gen-store-notes.mjs';

/**
 * Directories under fastlane/metadata/ios that are not locales: deliver keeps
 * the review contact, the trade representative and the defaults beside them.
 */
export const NOT_LOCALES = ['default', 'review_information', 'trade_representative_contact_information'];

/**
 * A release-please body with one change of each kind the notes render: what
 * the suite asks the generator for notes about.
 */
export const RELEASE_BODY = `## [1.1.0](https://github.com/acme/app/compare/v1.0.0...v1.1.0) (2026-10-01)

### Features

* **app:** add a dark theme ([#12](https://github.com/acme/app/issues/12)) ([abc1234](https://github.com/acme/app/commit/abc1234))

### Bug Fixes

* **app:** keep the draft when the connection drops ([#13](https://github.com/acme/app/issues/13)) ([def5678](https://github.com/acme/app/commit/def5678))
`;

/**
 * The environment the generator runs with in the suite: the caller's, less
 * every setting that would choose a provider, a model or the locales for it.
 */
export function generatorEnvironment(env, overrides = {}) {
  const kept = Object.fromEntries(Object.entries(env).filter(([name]) => !/^(STORE_NOTES_|OPENAI_|ANTHROPIC_)/.test(name)));
  return { ...kept, ...overrides };
}

/** What is wrong with the app's store-notes.prompt.md text, or '' when nothing is. */
export function promptProblem(text) {
  if (text.trim() === '') {
    return "store-notes.prompt.md is empty: it adds nothing to the generator's prompt. Write what this app's notes need, or delete the file";
  }
  return '';
}

/**
 * The directories under `dir` (the app's fastlane/metadata/ios) that look like
 * a listing locale to a person but that the generator does not take as one, so
 * that locale would ship without notes. `[]` when the directory is missing.
 */
export function skippedLocaleDirectories(dir, list = (at) => readdirSync(at, { withFileTypes: true })) {
  let entries;
  try {
    entries = list(dir);
  } catch {
    return [];
  }
  const taken = new Set(discoverLocales(dir));
  return entries
    .filter((entry) => entry.isDirectory() && !NOT_LOCALES.includes(entry.name) && !taken.has(entry.name))
    .map((entry) => entry.name)
    .sort();
}

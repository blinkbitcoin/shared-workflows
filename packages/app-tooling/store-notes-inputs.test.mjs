import assert from 'node:assert/strict';
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { test } from 'node:test';
import { parseBody } from './bin/gen-store-notes.mjs';
import { generatorEnvironment, NOT_LOCALES, promptProblem, RELEASE_BODY, skippedLocaleDirectories } from './lib/store-notes-inputs.mjs';

test("deliver's own directories under metadata/ios are not locales", () => {
  assert.deepEqual(NOT_LOCALES, ['default', 'review_information', 'trade_representative_contact_information']);
});

test('the release body gives the generator one new thing and one fix to write about', () => {
  assert.deepEqual(
    parseBody(RELEASE_BODY).map((item) => item.group),
    ['New', 'Fixed'],
  );
});

test("the generator's environment drops every provider, model and locale setting, and takes the overrides", () => {
  assert.deepEqual(
    generatorEnvironment(
      { PATH: '/bin', STORE_NOTES_LOCALES: 'en-US', STORE_NOTES_LLM_PROVIDER: 'openai', OPENAI_BASE_URL: 'x', ANTHROPIC_API_KEY: 'k' },
      { OPENAI_API_KEY: 'suite' },
    ),
    { PATH: '/bin', OPENAI_API_KEY: 'suite' },
  );
  assert.deepEqual(generatorEnvironment({ HOME: '/h' }), { HOME: '/h' });
});

test('a prompt with something in it is fine, and an empty or blank one is named', () => {
  assert.equal(promptProblem('Write for budgeters.'), '');
  for (const text of ['', ' \n\t\n']) assert.match(promptProblem(text), /^store-notes\.prompt\.md is empty: /);
});

test('a directory the generator does not take as a locale is named, and its own directories and files are not', (t) => {
  const dir = mkdtempSync(path.join(tmpdir(), 'store-notes-inputs-'));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  for (const name of ['en-US', 'de', 'review_information', 'default', 'english', 'Fr']) mkdirSync(path.join(dir, name));
  writeFileSync(path.join(dir, 'copyright.txt'), '2026\n');
  assert.deepEqual(skippedLocaleDirectories(dir), ['Fr', 'english']);
});

test('a store listing that is not there skips nothing', () => {
  assert.deepEqual(skippedLocaleDirectories('/nowhere/at/all'), []);
  assert.deepEqual(
    skippedLocaleDirectories('/x', () => {
      throw new Error('EACCES');
    }),
    [],
  );
});

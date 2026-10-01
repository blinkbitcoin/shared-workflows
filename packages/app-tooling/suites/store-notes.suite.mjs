// The app's half of the store notes: its store-notes.prompt.md and its store
// listing's locales, run through this package's gen-store-notes the way the
// release does. The chain around the generator (the release PR's section, the
// read-back by the release lanes) is shared-workflows' own and tested there.
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';
import { discoverLocales } from '../bin/gen-store-notes.mjs';
import { startOpenAiStub, systemPrompt } from '../lib/openai-stub.mjs';
import { generatorEnvironment, promptProblem, RELEASE_BODY, skippedLocaleDirectories } from '../lib/store-notes-inputs.mjs';

const root = process.env.APP_ROOT;
if (!root) throw new Error('APP_ROOT is not set: run the app suites through test-app');
const GENERATOR = fileURLToPath(new URL('../bin/gen-store-notes.mjs', import.meta.url));
const METADATA = path.join(root, 'fastlane', 'metadata', 'ios');
const prompt = readFileSync(path.join(root, 'store-notes.prompt.md'), 'utf8');
const locales = discoverLocales(METADATA);

const scratch = mkdtempSync(path.join(tmpdir(), 'store-notes-suite-'));
const body = path.join(scratch, 'release-body.md');
writeFileSync(body, RELEASE_BODY);
process.on('exit', () => rmSync(scratch, { recursive: true, force: true }));

/** The generator on RELEASE_BODY from the app root: its notes by locale, and what it said. */
function generate(overrides = {}) {
  return new Promise((resolve) => {
    const child = spawn(process.execPath, [GENERATOR, '--from-body', body, '--out', '-'], {
      cwd: root,
      env: generatorEnvironment(process.env, overrides),
    });
    let stdout = '';
    let stderr = '';
    child.stdout.on('data', (chunk) => {
      stdout += chunk;
    });
    child.stderr.on('data', (chunk) => {
      stderr += chunk;
    });
    child.on('close', (code) => resolve({ code, stderr, notes: code === 0 ? JSON.parse(stdout) : null }));
  });
}

test('store-notes.prompt.md says something', () => {
  assert.equal(promptProblem(prompt), '');
});

test('every locale directory of the store listing is one the generator writes notes for', () => {
  const skipped = skippedLocaleDirectories(METADATA);
  assert.deepEqual(
    skipped,
    [],
    `fastlane/metadata/ios/${skipped.join(', ')} would ship without notes: the generator takes only directories named like en-US or de`,
  );
});

test('without a model, every locale gets notes for a release', async () => {
  const { code, stderr, notes } = await generate();
  assert.equal(code, 0, stderr);
  assert.deepEqual(Object.keys(notes).sort(), [...locales].sort());
  for (const locale of locales) {
    for (const store of ['testflight', 'play', 'appstore']) assert.notEqual(notes[locale][store].trim(), '', `${locale} ${store}`);
  }
});

test("with a model, the app's prompt reaches it and every locale takes its answer", async () => {
  const stub = await startOpenAiStub(() => ({
    status: 200,
    content: JSON.stringify(Object.fromEntries(locales.map((locale) => [locale, `Notes for ${locale}.`]))),
  }));
  try {
    const { code, stderr, notes } = await generate({
      STORE_NOTES_LLM_PROVIDER: 'openai',
      STORE_NOTES_LLM_MODEL: 'suite-model',
      OPENAI_BASE_URL: stub.baseUrl,
      OPENAI_API_KEY: 'suite',
    });
    assert.equal(code, 0, stderr);
    assert.doesNotMatch(stderr, /rewrite failed/);
    assert.equal(stub.requests.length, 1);
    assert.ok(
      systemPrompt(stub.requests[0].body).includes(prompt.trim()),
      "the model's system prompt does not carry store-notes.prompt.md",
    );
    for (const locale of locales) assert.equal(notes[locale].testflight, `Notes for ${locale}.`);
  } finally {
    await stub.close();
  }
});

import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import path from 'node:path';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';
import { maxTokensFor, renderPrompt, rewriteNotes, TESTFLIGHT_LIMIT, validate } from './lib/store-notes-rewrite.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));
const fixture = (name) => readFileSync(path.join(here, 'fixtures', 'store-notes', name), 'utf8');

/** Runs `fn` with `globalThis.fetch` replaced, and restores it afterwards. */
async function withFetch(impl, fn) {
  const original = globalThis.fetch;
  globalThis.fetch = impl;
  try {
    return await fn();
  } finally {
    globalThis.fetch = original;
  }
}

/** A fetch that answers once with `payload`, recording the call it received. */
function stubFetch(payload, calls, ok = true) {
  return async (url, init) => {
    calls.push({ url, init });
    return { ok, status: ok ? 200 : 500, json: async () => payload };
  };
}

/** Runs `fn` with the given environment variables set (undefined or empty deletes one), then restores them. */
async function withEnv(vars, fn) {
  const saved = Object.fromEntries(Object.keys(vars).map((key) => [key, process.env[key]]));
  for (const [key, value] of Object.entries(vars)) {
    if (value === undefined || value === '') delete process.env[key];
    else process.env[key] = value;
  }
  try {
    return await fn();
  } finally {
    for (const [key, value] of Object.entries(saved)) {
      if (value === undefined) delete process.env[key];
      else process.env[key] = value;
    }
  }
}

/** Runs `fn` with console.warn captured into `sink`. */
async function withWarnings(sink, fn) {
  const original = console.warn;
  console.warn = (message) => sink.push(String(message));
  try {
    return await fn();
  } finally {
    console.warn = original;
  }
}

// ---------- rewrite: validation and fallback ----------

test('a valid rewrite replaces the deterministic prose', async () => {
  const notes = await withEnv({ ANTHROPIC_API_KEY: 'sk-ant-test' }, () =>
    withFetch(stubFetch(JSON.parse(fixture('anthropic-response.json')), []), () =>
      rewriteNotes({
        items: [{ group: 'New', text: 'Stay signed in after a cold start.' }],
        prompt: 'Write for {{locales}} within {{limit}} characters.',
        locales: ['en-US'],
        provider: 'anthropic',
      }),
    ),
  );
  assert.match(notes['en-US'], /^Signing in sticks now/);
});

test('a rewrite that is not strict JSON is rejected and falls back', async () => {
  const warnings = [];
  const notes = await withEnv({ ANTHROPIC_API_KEY: 'sk-ant-test' }, () =>
    withFetch(stubFetch(JSON.parse(fixture('anthropic-invalid-response.json')), []), () =>
      withWarnings(warnings, () =>
        rewriteNotes({ items: [], prompt: 'p', locales: ['en-US'], provider: 'anthropic' }),
      ),
    ),
  );
  assert.equal(notes, null);
  assert.match(warnings.join('\n'), /not JSON/);
});

test('markdown, hashes and a missing locale each reject the whole rewrite', async () => {
  const cases = [
    ['{"en-US": "New\\n# Heading"}', /contains "#"/],
    ['{"en-US": "See [the notes](https://x)"}', /markdown link/],
    ['{"en-US": "Fixed the crash (9f2c1ab)"}', /hash/],
    ['{"en-US": "ok"}', /missing locale sv-SE/],
    ['["en-US"]', /not a JSON object/],
  ];
  for (const [payload, expected] of cases) {
    const warnings = [];
    const locales = expected.source.includes('sv-SE') ? ['en-US', 'sv-SE'] : ['en-US'];
    const notes = await withEnv({ ANTHROPIC_API_KEY: 'sk-ant-test' }, () =>
      withFetch(stubFetch({ content: [{ type: 'text', text: payload }] }, []), () =>
        withWarnings(warnings, () =>
          rewriteNotes({ items: [], prompt: 'p', locales, provider: 'anthropic' }),
        ),
      ),
    );
    assert.equal(notes, null, payload);
    assert.match(warnings.join('\n'), expected);
  }
});

test('a missing api key warns and falls back instead of throwing', async () => {
  const warnings = [];
  const notes = await withEnv({ ANTHROPIC_API_KEY: '' }, () =>
    withWarnings(warnings, () =>
      rewriteNotes({ items: [], prompt: 'p', locales: ['en-US'], provider: 'anthropic' }),
    ),
  );
  assert.equal(notes, null);
  assert.match(warnings.join('\n'), /ANTHROPIC_API_KEY is not set/);
});

test('an http failure warns and falls back', async () => {
  const warnings = [];
  const notes = await withEnv({ OPENAI_API_KEY: 'sk-test' }, () =>
    withFetch(stubFetch({}, [], false), () =>
      withWarnings(warnings, () =>
        rewriteNotes({ items: [], prompt: 'p', locales: ['en-US'], provider: 'openai' }),
      ),
    ),
  );
  assert.equal(notes, null);
  assert.match(warnings.join('\n'), /HTTP 500/);
});

test('no provider means no network call at all', async () => {
  const notes = await withFetch(
    () => {
      throw new Error('fetch must not be called');
    },
    () => rewriteNotes({ items: [], prompt: 'p', locales: ['en-US'], provider: 'none' }),
  );
  assert.equal(notes, null);
});

test('a rewrite carrying a rule line or html is rejected', () => {
  const cases = [
    ['Fixed\n---\nMore', /contains a horizontal rule/],
    ['<details>hidden</details>', /contains html/],
    ['Fixed <!-- x --> things', /contains html/],
  ];
  for (const [text, expected] of cases) {
    const result = validate(JSON.stringify({ 'en-US': text }), ['en-US']);
    assert.equal(result.notes, undefined, text);
    assert.match(result.error, expected);
  }
});

test('links, bare domains with a path and markdown are rejected', () => {
  const cases = [
    ['Visit https://example.com/promo for details.', /contains a link/],
    ['Now at example.com/promo.', /contains a domain/],
    ['* markdown bullet\n- another', /contains markdown/],
    ['Now with **bold**.', /contains markdown/],
  ];
  for (const [text, expected] of cases) {
    const result = validate(JSON.stringify({ 'en-US': text }), ['en-US']);
    assert.equal(result.notes, undefined, text);
    assert.match(result.error, expected);
  }
  // A sentence that merely names a product is not a link.
  assert.equal(
    validate('{"en-US": "Faster on iOS 26."}', ['en-US']).notes['en-US'],
    'Faster on iOS 26.',
  );
});

test('an empty or over-long rewrite is rejected', () => {
  assert.deepEqual(validate(JSON.stringify({ 'en-US': '  ' }), ['en-US']), {
    error: 'en-US: empty',
  });
  assert.deepEqual(
    validate(JSON.stringify({ 'en-US': 'a'.repeat(TESTFLIGHT_LIMIT + 1) }), ['en-US']),
    { error: `en-US: longer than ${TESTFLIGHT_LIMIT} characters` },
  );
});

test('a fenced answer is unwrapped, and its text still goes through every check', () => {
  const fence = (object) => `\`\`\`json\n${JSON.stringify(object)}\n\`\`\``;
  assert.deepEqual(validate(fence({ 'en-US': 'Faster sync.' }), ['en-US']), {
    notes: { 'en-US': 'Faster sync.' },
  });
  const rejected = validate(fence({ 'en-US': 'See https://example.com' }), ['en-US']);
  assert.equal(rejected.notes, undefined);
  assert.match(rejected.error, /contains a link/);
});

// ---------- output budget ----------

test('the output budget grows with the number of locales', () => {
  assert.equal(maxTokensFor(['en-US']), 2524);
  assert.equal(maxTokensFor(['en-US', 'sv-SE', 'de-DE']), 5524);
  assert.equal(maxTokensFor(new Array(20).fill('x')), 8192);
  assert.equal(maxTokensFor(['en-US'], 'none'), 2524);
});

test('an effort that thinks gets room to think on top of the text budget', () => {
  assert.equal(maxTokensFor(['en-US'], 'low'), 18524);
  assert.equal(maxTokensFor(['en-US'], 'max'), 18524);
  assert.equal(maxTokensFor(new Array(20).fill('x'), 'max'), 24192);
});

test('the budget reaches the adapter as max_tokens', async () => {
  const calls = [];
  await withEnv({ ANTHROPIC_API_KEY: 'sk-ant-test' }, () =>
    withFetch(stubFetch(JSON.parse(fixture('anthropic-response.json')), calls), () =>
      rewriteNotes({ items: [], prompt: 'p', locales: ['en-US', 'sv-SE'], provider: 'anthropic' }),
    ),
  );
  assert.equal(JSON.parse(calls[0].init.body).max_tokens, maxTokensFor(['en-US', 'sv-SE']));
});

test('the budget an effort buys reaches the adapter too', async () => {
  const calls = [];
  await withEnv({ ANTHROPIC_API_KEY: 'sk-ant-test' }, () =>
    withFetch(stubFetch(JSON.parse(fixture('anthropic-response.json')), calls), () =>
      rewriteNotes({
        items: [],
        prompt: 'p',
        locales: ['en-US'],
        provider: 'anthropic',
        effort: 'max',
      }),
    ),
  );
  assert.equal(JSON.parse(calls[0].init.body).max_tokens, maxTokensFor(['en-US'], 'max'));
});

// ---------- the prompt template ----------

test('the prompt template is rendered with the locales and the limit', () => {
  const rendered = renderPrompt('Locales: {{locales}}. At most {{limit}} characters.', {
    locales: 'en-US, sv-SE',
    limit: 4000,
  });
  assert.equal(rendered, 'Locales: en-US, sv-SE. At most 4000 characters.');
  assert.throws(
    () => renderPrompt('{{nope}}', { locales: 'en-US', limit: 1 }),
    /unknown placeholder/,
  );
});

test('the rendered template is the whole system prompt the adapter receives', async () => {
  const calls = [];
  await withEnv({ ANTHROPIC_API_KEY: 'sk-ant-test' }, () =>
    withFetch(stubFetch(JSON.parse(fixture('anthropic-response.json')), calls), () =>
      rewriteNotes({
        items: [],
        prompt: 'Rules for {{locales}}, {{limit}} max.',
        locales: ['en-US', 'sv-SE'],
        provider: 'anthropic',
      }),
    ),
  );
  assert.equal(
    JSON.parse(calls[0].init.body).system,
    `Rules for en-US, sv-SE, ${TESTFLIGHT_LIMIT} max.`,
  );
});

test('an empty prompt means no rewrite, with a warning', async () => {
  const calls = [];
  const warnings = [];
  const notes = await withEnv({ ANTHROPIC_API_KEY: 'sk-ant-test' }, () =>
    withFetch(stubFetch({}, calls), () =>
      withWarnings(warnings, () =>
        rewriteNotes({ items: [], prompt: '', locales: ['en-US'], provider: 'anthropic' }),
      ),
    ),
  );
  assert.equal(notes, null);
  assert.equal(calls.length, 0);
  assert.match(warnings.join('\n'), /the prompt is empty/);
});

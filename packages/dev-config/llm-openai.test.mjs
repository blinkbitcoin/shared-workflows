import assert from 'node:assert/strict';
import { test } from 'node:test';
import { EFFORTS } from './lib/llm.mjs';
import * as openai from './lib/llm-openai.mjs';

/** A fetch that answers with `payload` and keeps the last request it saw. */
const respond =
  (payload, ok = true, status = 200) =>
  async (url, init) => {
    respond.last = { url, init, body: JSON.parse(init.body) };
    return { ok, status, json: async () => payload };
  };

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

const CHAT = { choices: [{ message: { content: '{"a":1}' } }] };

const ANSWER = { choices: [{ message: { content: '{"en-US": "Faster."}' } }] };

test('the openai adapter posts a json-object chat completion', async () => {
  const calls = [];
  const text = await withEnv({ OPENAI_API_KEY: 'sk-test', OPENAI_BASE_URL: '' }, () =>
    withFetch(stubFetch(ANSWER, calls), () =>
      openai.complete({ system: 'be brief', user: 'the changes', model: 'gpt-5-mini' }),
    ),
  );

  const [{ url, init }] = calls;
  assert.equal(url, 'https://api.openai.com/v1/chat/completions');
  assert.equal(init.headers.authorization, 'Bearer sk-test');
  const sent = JSON.parse(init.body);
  assert.equal(sent.model, 'gpt-5-mini');
  assert.deepEqual(sent.response_format, { type: 'json_object' });
  assert.deepEqual(sent.messages[0], { role: 'system', content: 'be brief' });
  assert.equal(text, '{"en-US": "Faster."}');
});

test('OPENAI_BASE_URL redirects the adapter at a compatible gateway', async () => {
  const calls = [];
  await withEnv({ OPENAI_API_KEY: 'sk-test', OPENAI_BASE_URL: 'https://gateway.internal/v1' }, () =>
    withFetch(stubFetch(ANSWER, calls), () => openai.complete({ system: 's', user: 'u' })),
  );
  assert.equal(calls[0].url, 'https://gateway.internal/v1/chat/completions');
});

test('openai: the official endpoint gets max_completion_tokens, a compatible one max_tokens', async () => {
  await withEnv({ OPENAI_BASE_URL: undefined }, () =>
    openai.complete({ system: 's', user: 'u', maxTokens: 99, fetchImpl: respond(CHAT) }),
  );
  assert.equal(respond.last.url, 'https://api.openai.com/v1/chat/completions');
  assert.equal(respond.last.body.max_completion_tokens, 99);
  assert.equal(respond.last.body.max_tokens, undefined);

  await withEnv({ OPENAI_BASE_URL: 'https://api.moonshot.ai/v1' }, () =>
    openai.complete({ system: 's', user: 'u', maxTokens: 99, fetchImpl: respond(CHAT) }),
  );
  assert.equal(respond.last.url, 'https://api.moonshot.ai/v1/chat/completions');
  assert.equal(respond.last.body.max_tokens, 99);
  assert.equal(respond.last.body.max_completion_tokens, undefined);
});

test('openai: effort maps onto reasoning_effort, max to high', async () => {
  const sent = [];
  for (const effort of EFFORTS) {
    await openai.complete({ system: 's', user: 'u', effort, fetchImpl: respond(CHAT) });
    sent.push(respond.last.body.reasoning_effort);
  }
  assert.deepEqual(sent, [undefined, 'low', 'medium', 'high', 'high']);
  await openai.complete({ system: 's', user: 'u', fetchImpl: respond(CHAT) });
  assert.equal(respond.last.body.reasoning_effort, undefined);
});

test('openai: null extra parameters drop a default, and a replacement is sent', async () => {
  await withEnv({ OPENAI_BASE_URL: 'https://models.github.ai/inference' }, () =>
    openai.complete({
      system: 's',
      user: 'u',
      maxTokens: 99,
      extraParams: { response_format: null, max_tokens: null, max_completion_tokens: 4000 },
      fetchImpl: respond(CHAT),
    }),
  );
  const { body } = respond.last;
  assert.equal('response_format' in body, false);
  assert.equal('max_tokens' in body, false);
  assert.equal(body.max_completion_tokens, 4000);
  assert.equal(body.messages.length, 2);
});

test('openai: extra parameters are merged, and failures throw', async () => {
  await openai.complete({
    system: 's',
    user: 'u',
    extraParams: { enable_thinking: true },
    fetchImpl: respond(CHAT),
  });
  assert.equal(respond.last.body.enable_thinking, true);
  await assert.rejects(
    openai.complete({ system: 's', user: 'u', fetchImpl: respond({}, false, 401) }),
    /HTTP 401/,
  );
  await assert.rejects(
    openai.complete({ system: 's', user: 'u', fetchImpl: respond({ choices: [] }) }),
    /no message content/,
  );
});

test('the openai adapter sends an empty bearer and the default model and endpoint', async () => {
  const calls = [];
  await withEnv({ OPENAI_API_KEY: '', OPENAI_BASE_URL: '' }, () =>
    withFetch(stubFetch({ choices: [{ message: { content: 'ok' } }] }, calls), () =>
      openai.complete({ system: 's', user: 'u', maxTokens: 10 }),
    ),
  );
  assert.equal(calls[0].url, 'https://api.openai.com/v1/chat/completions');
  assert.equal(calls[0].init.headers.authorization, 'Bearer ');
  const sent = JSON.parse(calls[0].init.body);
  assert.equal(sent.model, 'gpt-5');
  assert.equal(sent.max_completion_tokens, 10);
});

test('the openai adapter throws when the response has no message content', async () => {
  for (const payload of [
    null,
    {},
    { choices: [] },
    { choices: [{}] },
    { choices: [{ message: {} }] },
  ]) {
    await assert.rejects(
      withFetch(stubFetch(payload, []), () => openai.complete({ system: 's', user: 'u' })),
      /openai: no message content in response/,
      JSON.stringify(payload),
    );
  }
});

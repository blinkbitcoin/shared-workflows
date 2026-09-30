import assert from 'node:assert/strict';
import { test } from 'node:test';
import * as anthropic from './lib/llm-anthropic.mjs';

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

const TEXT = {
  stop_reason: 'end_turn',
  content: [
    { type: 'thinking', thinking: '' },
    { type: 'text', text: 'ok' },
  ],
};

const ANSWER = {
  stop_reason: 'end_turn',
  content: [{ type: 'text', text: '{"en-US": "Faster."}' }],
};

test('the anthropic adapter posts the documented Messages API request', async () => {
  const calls = [];
  const text = await withEnv({ ANTHROPIC_API_KEY: 'sk-ant-test' }, () =>
    withFetch(stubFetch(ANSWER, calls), () =>
      anthropic.complete({ system: 'be brief', user: 'the changes' }),
    ),
  );

  assert.equal(calls.length, 1);
  const [{ url, init }] = calls;
  assert.equal(url, 'https://api.anthropic.com/v1/messages');
  assert.equal(init.method, 'POST');
  assert.equal(init.headers['x-api-key'], 'sk-ant-test');
  assert.equal(init.headers['anthropic-version'], '2023-06-01');
  assert.equal(init.headers['content-type'], 'application/json');
  const sent = JSON.parse(init.body);
  assert.equal(sent.model, 'claude-sonnet-5');
  assert.equal(sent.system, 'be brief');
  assert.deepEqual(sent.messages, [{ role: 'user', content: 'the changes' }]);
  assert.equal(typeof sent.max_tokens, 'number');
  assert.equal(text, '{"en-US": "Faster."}');
});

test('anthropic: effort asks for adaptive thinking at that effort', async () => {
  const text = await anthropic.complete({
    system: 's',
    user: 'u',
    effort: 'max',
    fetchImpl: respond(TEXT),
  });
  assert.equal(text, 'ok');
  const { body } = respond.last;
  assert.deepEqual(body.thinking, { type: 'adaptive' });
  assert.deepEqual(body.output_config, { effort: 'max' });
});

test('anthropic: without an effort the request carries neither field', async () => {
  await anthropic.complete({ system: 's', user: 'u', fetchImpl: respond(TEXT) });
  assert.equal(respond.last.body.thinking, undefined);
  assert.equal(respond.last.body.output_config, undefined);
});

test('anthropic: effort none carries neither field', async () => {
  await anthropic.complete({ system: 's', user: 'u', effort: 'none', fetchImpl: respond(TEXT) });
  assert.equal(respond.last.body.thinking, undefined);
  assert.equal(respond.last.body.output_config, undefined);
});

test('anthropic: a null extra parameter removes that field', async () => {
  await anthropic.complete({
    system: 's',
    user: 'u',
    effort: 'high',
    extraParams: { thinking: null },
    fetchImpl: respond(TEXT),
  });
  assert.equal('thinking' in respond.last.body, false);
  assert.deepEqual(respond.last.body.output_config, { effort: 'high' });
});

test('anthropic: extra parameters are merged into the body', async () => {
  await anthropic.complete({
    system: 's',
    user: 'u',
    extraParams: { metadata: { user_id: 'ci' } },
    fetchImpl: respond(TEXT),
  });
  assert.deepEqual(respond.last.body.metadata, { user_id: 'ci' });
});

test('anthropic: a refusal, an HTTP error and a missing text block all throw', async () => {
  await assert.rejects(
    anthropic.complete({
      system: 's',
      user: 'u',
      fetchImpl: respond({ stop_reason: 'refusal', content: [] }),
    }),
    /declined the request/,
  );
  await assert.rejects(
    anthropic.complete({ system: 's', user: 'u', fetchImpl: respond({}, false, 500) }),
    /HTTP 500/,
  );
  await assert.rejects(
    anthropic.complete({ system: 's', user: 'u', fetchImpl: respond({ content: [] }) }),
    /no text block/,
  );
});

test('the anthropic adapter sends an empty key rather than "undefined" and honours a model', async () => {
  const calls = [];
  await withEnv({ ANTHROPIC_API_KEY: '' }, () =>
    withFetch(stubFetch({ content: [{ type: 'text', text: 'ok' }] }, calls), () =>
      anthropic.complete({ system: 's', user: 'u', model: 'claude-haiku-5' }),
    ),
  );
  assert.equal(calls[0].init.headers['x-api-key'], '');
  assert.equal(JSON.parse(calls[0].init.body).model, 'claude-haiku-5');
});

test('the anthropic adapter throws on an HTTP failure', async () => {
  await assert.rejects(
    withFetch(stubFetch({}, [], false), () => anthropic.complete({ system: 's', user: 'u' })),
    /anthropic: HTTP 500/,
  );
});

test('the anthropic adapter throws when the response has no text block', async () => {
  for (const payload of [
    {},
    null,
    { content: 'not a list' },
    { content: [null, { type: 'tool_use' }] },
    { content: [{ type: 'text', text: 42 }] },
  ]) {
    await assert.rejects(
      withFetch(stubFetch(payload, []), () => anthropic.complete({ system: 's', user: 'u' })),
      /anthropic: no text block in response/,
      JSON.stringify(payload),
    );
  }
});

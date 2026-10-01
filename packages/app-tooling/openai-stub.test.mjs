import assert from 'node:assert/strict';
import { test } from 'node:test';
import { startOpenAiStub, systemPrompt } from './lib/openai-stub.mjs';

test('the stub records each request and answers it with the reply for its body', async () => {
  const stub = await startOpenAiStub((body) => ({ status: body.model === 'bad' ? 500 : 200, content: `for ${body.model}` }));
  try {
    assert.match(stub.baseUrl, /^http:\/\/127\.0\.0\.1:\d+\/v1$/);
    const ask = (model) =>
      fetch(`${stub.baseUrl}/chat/completions`, { method: 'POST', body: JSON.stringify({ model }) }).then(async (r) => ({
        status: r.status,
        json: await r.json(),
      }));
    assert.deepEqual(await ask('m'), { status: 200, json: { choices: [{ message: { content: 'for m' } }] } });
    assert.equal((await ask('bad')).status, 500);
    assert.deepEqual(stub.requests, [
      { url: '/v1/chat/completions', body: { model: 'm' } },
      { url: '/v1/chat/completions', body: { model: 'bad' } },
    ]);
  } finally {
    await stub.close();
  }
});

test('systemPrompt is the system message, or empty without one', () => {
  assert.equal(systemPrompt({ messages: [{ role: 'user', content: 'u' }, { role: 'system', content: 's' }] }), 's');
  assert.equal(systemPrompt({ messages: [{ role: 'user', content: 'u' }] }), '');
  assert.equal(systemPrompt({}), '');
});

import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { test } from 'node:test';
import * as anthropic from './lib/llm-anthropic.mjs';
import * as openai from './lib/llm-openai.mjs';
import { adapterFor, KEY_ENV, parseEffort, parseExtraParams } from './lib/llm.mjs';

test('parseEffort defaults to max and refuses anything outside the vocabulary', () => {
  assert.equal(parseEffort(undefined, 'X'), 'max');
  assert.equal(parseEffort('', 'X'), 'max');
  assert.equal(parseEffort('low', 'X'), 'low');
  assert.equal(parseEffort('none', 'X'), 'none');
  assert.throws(
    () => parseEffort('xhigh', 'X'),
    /X: expected one of none, low, medium, high, max, got "xhigh"/,
  );
});

test('parseExtraParams accepts an object, nested values included', () => {
  assert.deepEqual(parseExtraParams(undefined, 'X'), {});
  assert.deepEqual(parseExtraParams('', 'X'), {});
  assert.deepEqual(parseExtraParams('{"reasoning":{"effort":"high"},"top_k":5}', 'X'), {
    reasoning: { effort: 'high' },
    top_k: 5,
  });
  assert.deepEqual(parseExtraParams('{"response_format":null}', 'X'), { response_format: null });
});

test('parseExtraParams refuses what is not an object, and the fields that choose what is asked', () => {
  assert.throws(() => parseExtraParams('{oops', 'X'), /^Error: X: not valid JSON$/);
  assert.throws(() => parseExtraParams('[1]', 'X'), /expected a JSON object/);
  assert.throws(() => parseExtraParams('null', 'X'), /expected a JSON object/);
  assert.throws(() => parseExtraParams('"s"', 'X'), /expected a JSON object/);
  for (const key of ['model', 'messages', 'system']) {
    for (const value of [1, null]) {
      assert.throws(
        () => parseExtraParams(JSON.stringify({ [key]: value }), 'X'),
        new RegExp(`may not set ${key}`),
      );
    }
  }
});

test('the value of a bad extra-parameters setting never reaches the error', () => {
  assert.throws(
    () => parseExtraParams('{"api_key": "sk-secret"', 'X'),
    (error) => !error.message.includes('sk-secret'),
  );
});

test('adapterFor knows the two providers and nothing else', () => {
  assert.equal(adapterFor('anthropic'), anthropic);
  assert.equal(adapterFor('openai'), openai);
  assert.equal(adapterFor(''), null);
  assert.equal(adapterFor('toString'), null);
  assert.deepEqual(KEY_ENV, { anthropic: 'ANTHROPIC_API_KEY', openai: 'OPENAI_API_KEY' });
});

test('the package exports this module and the request helpers by name', async () => {
  const pkg = JSON.parse(readFileSync(new URL('./package.json', import.meta.url), 'utf8'));
  assert.equal(pkg.exports['./llm'], './lib/llm.mjs');
  assert.equal(pkg.exports['./llm-request'], './lib/llm-request.mjs');
  assert.equal((await import('./lib/llm.mjs')).adapterFor, adapterFor);
});

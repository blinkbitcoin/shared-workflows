import assert from 'node:assert/strict';
import { test } from 'node:test';
import { EFFORTS } from './lib/llm.mjs';
import { mergeRequest, thinks, unfence } from './lib/llm-request.mjs';

test('thinks is true for every effort but none and unset', () => {
  assert.deepEqual(
    EFFORTS.map((effort) => thinks(effort)),
    [false, true, true, true, true],
  );
  assert.equal(thinks(undefined), false);
  assert.equal(thinks(''), false);
});

test('mergeRequest overrides, adds and removes top-level fields', () => {
  assert.deepEqual(mergeRequest({ a: 1, b: 2 }), { a: 1, b: 2 });
  assert.deepEqual(mergeRequest({ a: 1, b: 2 }, { a: 3, b: null, c: { d: null } }), {
    a: 3,
    c: { d: null },
  });
  assert.deepEqual(mergeRequest({ a: 1 }, { missing: null }), { a: 1 });
});

test('unfence removes one surrounding code fence and nothing else', () => {
  assert.equal(unfence('```json\n{"a":1}\n```'), '{"a":1}');
  assert.equal(unfence('  ```\n{"a":1}\n```  \n'), '{"a":1}');
  assert.equal(unfence('{"a":1}'), '{"a":1}');
  assert.equal(unfence('text ```json\n{}\n```'), 'text ```json\n{}\n```');
});

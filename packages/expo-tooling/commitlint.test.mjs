import assert from 'node:assert/strict';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';
import future from './fixtures/template/commitlint/future.mjs';
import today from './fixtures/template/commitlint/today.mjs';
import base from './lib/commitlint.mjs';

// commitlint's resolveExtends merges each `extends` before the file naming it,
// depth first: plain objects deep-merged, arrays replaced, the later file
// winning. Both chains end in @commitlint/config-conventional, which is the
// app's in both cases and so drops out of the comparison.
const CONVENTIONAL = '@commitlint/config-conventional';

test("the template's future commitlint.config.mjs ends in the same conventional base as today's", () => {
  assert.deepEqual(today.extends, [CONVENTIONAL]);
  assert.deepEqual(future.extends, ['@blinkbitcoin/expo-tooling/commitlint']);
  assert.deepEqual(base.extends, [CONVENTIONAL]);
});

test('its extends names this package, and resolves to this base', () => {
  assert.equal(fileURLToPath(import.meta.resolve(future.extends[0])), fileURLToPath(new URL('./lib/commitlint.mjs', import.meta.url)));
});

test("and its rules merged over this base's are today's rules", () => {
  assert.deepStrictEqual({ ...base.rules, ...future.rules }, today.rules);
});

test('the base holds no scope list: that is each app\'s own', () => {
  assert.equal(base.rules['scope-enum'], undefined);
});

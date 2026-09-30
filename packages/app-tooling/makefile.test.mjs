import assert from 'node:assert/strict';
import { test } from 'node:test';
import { documentedTargets, expandIncludes, includedPaths } from './lib/makefile.mjs';

/** A `read` over an in-memory tree. */
const tree = (files) => (file) => files[file] ?? null;

test('includedPaths reads include, -include and sinclude, without variables or a trailing comment', () => {
  assert.deepEqual(includedPaths('include make/a.mk make/b.mk'), ['make/a.mk', 'make/b.mk']);
  assert.deepEqual(includedPaths('-include local.mk # optional'), ['local.mk']);
  assert.deepEqual(includedPaths('sinclude $(DIR)/x.mk other.mk'), ['other.mk']);
  assert.equal(includedPaths('included: ## a target, not an include'), null);
  assert.equal(includedPaths('\tinclude x.mk'), null);
});

test('expandIncludes puts each existing include in place, from where make runs, once each', () => {
  const read = tree({
    '/repo/Makefile': 'a: ## A\ninclude make/shared.mk make/gone.mk\n-include local.mk\nz: ## Z\n',
    '/repo/make/shared.mk': 'include make/nested.mk\nshared: ## Shared\n',
    '/repo/make/nested.mk': 'include make/shared.mk\nnested: ## Nested\n',
    '/repo/local.mk': 'local: ## Local',
  });
  assert.equal(
    expandIncludes('/repo/Makefile', read),
    'a: ## A\nnested: ## Nested\nshared: ## Shared\nlocal: ## Local\nz: ## Z\n',
  );
});

test('expandIncludes of a Makefile that is not there is null', () => {
  assert.equal(expandIncludes('/repo/Makefile', tree({})), null);
});

test('expandIncludes takes an absolute include as written, and a relative root stays relative', () => {
  const read = tree({ Makefile: 'include /shared/x.mk\ninclude y.mk\n', '/shared/x.mk': 'x:\n', 'y.mk': 'y:\n' });
  assert.equal(expandIncludes('Makefile', read, ''), 'x:\ny:\n');
});

test('documentedTargets reads name and description, and skips undocumented rules and assignments', () => {
  const text = [
    'check: lint test ## Every gate',
    'lint:',
    '\ttrue',
    'VAR := x ## not a target',
    'gen-i18n:##Catalogs',
    'check-e2e.ios: ## Dotted',
  ].join('\n');
  assert.deepEqual(documentedTargets(text), [
    { target: 'check', description: 'Every gate' },
    { target: 'gen-i18n', description: 'Catalogs' },
    { target: 'check-e2e.ios', description: 'Dotted' },
  ]);
});
